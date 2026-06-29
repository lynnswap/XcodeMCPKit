# XcodeMCPProxyKit

Swift API for embedding the Xcode MCP proxy server, STDIO adapter, and source
installer flow.

## Overview

Use `XcodeMCPProxyKit` when Swift code needs to host the proxy, build a custom
launcher around the same command-line behavior as `xcode-mcp-proxy-server`, or
compose the STDIO adapter and installer flows.

The public API includes:

- `XcodeMCPProxyServer`, the embeddable proxy server lifecycle object
- `XcodeMCPProxyServerConfiguration`, the embeddable server configuration
- `XcodeMCPProxyServer.resolveLaunchPlan(...)` for launcher argv/environment
  normalization
- `XcodeMCPProxyStdioAdapter`, the STDIO compatibility adapter
- `XcodeMCPProxyStdioAdapterConfiguration`, the adapter configuration
- `XcodeMCPProxyAdapterEndpointResolver`, the adapter endpoint resolver
- `XcodeMCPProxyAdapterEndpointResolutionOptions`, endpoint resolution inputs
- `XcodeMCPProxyInstaller`, the install plan and copy/build API

For most users, the root README's `xcode-mcp-proxy-server` command is simpler.
Use this API when the proxy has to be embedded in another Swift process or when
a custom launcher needs the same parsing, dry-run, force-restart, and version
behavior as the bundled executables.

## Server Quickstart

Depend on the `XcodeMCPProxyKit` library product, then construct the server
directly:

```swift
import XcodeMCPProxyKit

let config = XcodeMCPProxyServerConfiguration(
    bindAddress: .localhost(port: 8765),
    upstream: .defaultMCPBridge(processesPerXcode: 1),
    limits: .init(maxBodyBytes: 1_048_576, requestTimeout: 300),
    discovery: .init(fileURL: URL(fileURLWithPath: "/tmp/xcode-mcp-proxy.json")),
    approvalPolicy: .manual
)

let server = XcodeMCPProxyServer(configuration: config)
let endpoint = try server.startAndWriteDiscovery()
print("Listening on \(endpoint.url)")

let waiter = Task {
    try await server.wait()
}

// Keep your application alive here, then shut down on your own signal.
try await server.shutdown()
try await waiter.value
```

After startup, MCP clients can connect to `http://<host>:<port>/mcp`. The
discovery file is written by `startAndWriteDiscovery()` for local adapters that
look up the running HTTP endpoint.

## Configuration

Use `XcodeMCPProxyServerConfiguration` to configure the server:

- `bindAddress` chooses the HTTP bind address.
- `upstream` chooses the upstream MCP bridge and process count.
- `limits` bounds request timeout and body size.
- `discovery` overrides the endpoint discovery file.
- `approvalPolicy` controls Xcode permission dialog automation.
- `featurePolicy.refreshCodeIssuesMode` selects proxy diagnostics or upstream
  forwarding for `XcodeRefreshCodeIssuesInFile`.
- `toolPolicy.disabledToolNames` hides tools from `tools/list` and rejects
  matching `tools/call` requests locally.
- `initializeHandshake` overrides the protocol version, client info, or
  capabilities sent when the proxy initializes upstream `mcpbridge` processes.

The server can also load TOML-backed initialize overrides and disabled tools
when `configurationFilePath` is set. If typed configuration and a file are both
set, typed values override the matching file-backed disabled-tools and
initialize handshake fields.

```swift
import XcodeMCPKit
import XcodeMCPProxyKit

let config = XcodeMCPProxyServerConfiguration(
    configurationFilePath: "/etc/xcode-mcp/proxy.toml",
    toolPolicy: .init(
        disabledToolNames: ["RunAllTests", "RunSomeTests"]
    ),
    initializeHandshake: .init(
        clientInfo: .init(name: "EmbeddingClient", version: "1.0"),
        capabilities: [
            "roots": [
                "listChanged": true,
            ],
        ]
    )
)
```

The `capabilities` dictionary uses `MCPJSONValue` from `XcodeMCPKit`, so Swift
JSON literals remain concise while proxy internals still translate to the
runtime config format.

## Lifecycle

`start()` binds HTTP channels, starts the proxy runtime, and returns the
resolved ``XcodeMCPProxyServer/Endpoint``. `startAndWriteDiscovery()` does the
same startup work, then writes the endpoint discovery file and logs a startup
summary.
`wait()` suspends until the listening channels close. `shutdown()` stops
permission automation, closes listening and accepted channels, shuts down the
runtime, and terminates the event loop group.

Use one `XcodeMCPProxyServer` per proxy server instance. Create a new instance
after shutdown instead of restarting the same object.

## Launch Plans

Launchers that want the same behavior as `xcode-mcp-proxy-server` can resolve a
high-level launch plan from argv and environment:

```swift
let plan = try XcodeMCPProxyServer.resolveLaunchPlan(
    arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment
)

switch plan.action {
case .showHelp:
    print(plan.usage)
case .showVersion:
    print(plan.versionLine)
case .dryRun:
    print(plan.resolvedDryRunCommandLine ?? "")
case .start:
    let server = XcodeMCPProxyServer(configuration: plan.configuration!)
    _ = try server.startAndWriteDiscovery()
    try await server.wait()
}
```

`LaunchPlan` exposes the resolved server `XcodeMCPProxyServerConfiguration`, normalized
`LaunchOptions`, stable dry-run command line, and display text. Port-in-use
messages are represented by `XcodeMCPProxyServer.PortInUseError`, and product
version information is available through `XcodeMCPProxyServer.productMetadata`.

Executable-style hosts can also run the server command behavior directly:

```swift
let exitCode = await XcodeMCPProxyServer.run(
    arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment,
    stdout: { print($0) },
    stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
)
```

## STDIO Adapter

`XcodeMCPProxyStdioAdapter` forwards MCP STDIO messages to a running
Streamable HTTP proxy endpoint. The endpoint resolver uses this order:

1. Explicit URL, such as a CLI `--url` value.
2. `XCODE_MCP_PROXY_ENDPOINT`.
3. The discovery file written by `XcodeMCPProxyServer.startAndWriteDiscovery()`.
4. `http://localhost:8765/mcp`.

```swift
import Foundation
import XcodeMCPProxyKit

let endpoint = try XcodeMCPProxyAdapterEndpointResolver().resolve(
    .init(
        explicitURL: nil,
        environment: ProcessInfo.processInfo.environment
    )
)

let adapter = XcodeMCPProxyStdioAdapter(
    endpoint: endpoint,
    requestTimeout: 300,
    input: .standardInput,
    output: .standardOutput
)

await adapter.start()
await adapter.wait()
```

The adapter preserves the proxy's modern MCP HTTP contract: initialize is sent
without a session header, subsequent POST/GET/DELETE requests include the
server-issued `MCP-Session-Id`, and the negotiated
`MCP-Protocol-Version` is forwarded after initialize.

Command-line hosts can run the same adapter behavior with
`XcodeMCPProxyStdioAdapter.run(arguments:environment:stdout:stderr:)`.

## Installer

`XcodeMCPProxyInstaller` provides the source install composition used by
`xcode-mcp-proxy-install`. It installs the STDIO adapter and proxy server
binaries:

```swift
import Foundation
import XcodeMCPProxyKit

let installer = XcodeMCPProxyInstaller(
    configuration: .init(prefix: "\(NSHomeDirectory())/.local", dryRun: true)
)
let plan = installer.plan(
    executableURL: URL(fileURLWithPath: "/path/to/xcode-mcp-proxy-install")
)
print(plan.dryRunLines.joined(separator: "\n"))
```

`--bindir` has priority over `--prefix`; otherwise the default destination is
`~/.local/bin`. A non-dry-run install builds release products when the installer
is running from a SwiftPM `.build` directory and then copies
`XcodeMCPProxyInstaller.binaryNames` into the resolved bin directory.

Command-line hosts can run the installer behavior with
`XcodeMCPProxyInstaller.run(arguments:environment:stdout:stderr:)`.
