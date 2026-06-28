# XcodeMCPProxyKit

Swift library API for embedding and composing the Xcode MCP proxy products.

## Status

`XcodeMCPProxyKit` is the public product kit used by the proxy executables. The
CLIs hand argv/environment and output sinks to high-level facade types from this
target, so the package boundary is real and does not rely on private wrappers in
executable targets.

This target owns:

- `XcodeMCPProxyServer`, the embeddable proxy server lifecycle object
- server launch plan resolution and launch runtime orchestration from
  argv/environment
- product metadata, version line, dry-run, force-restart, server start/wait, and
  port-in-use diagnostics for server launchers
- `XcodeMCPProxyStdioAdapter`, the STDIO compatibility adapter facade
- `XcodeMCPProxyAdapterEndpointResolver`, the adapter endpoint resolver
- `XcodeMCPProxyInstaller`, the install plan and copy/build policy facade
- HTTP channel setup and request handling integration
- startup, discovery writing, waiting, shutdown, adapter, and installer entry
  points

External embedders configure the server through
`XcodeMCPProxyServer.Configuration`, configure the adapter through
`XcodeMCPProxyStdioAdapter.Configuration`, and compose installs through
`XcodeMCPProxyInstaller.Configuration`. Lower-level session routing, upstream
process management, broker/runtime primitives, Xcode support, MCP HTTP
behavior, and STDIO transport details stay in internal implementation folders
behind this kit boundary. They are not published as a standalone SwiftPM target.

This target intentionally does not expose the executable CLI parsers, per-tool
typed wrappers, a public stream API, or direct access to the internal session
router.

## Server Quickstart

Depend on the `XcodeMCPProxyKit` library product, then construct the server
directly:

```swift
import XcodeMCPProxyKit

let config = XcodeMCPProxyServer.Configuration(
    bind: .localhost(port: 8765),
    upstream: .defaultMCPBridge(processesPerXcode: 1),
    limits: .init(maxBodyBytes: 1_048_576, requestTimeout: 300),
    discovery: .init(fileURL: URL(fileURLWithPath: "/tmp/xcode-mcp-proxy.json")),
    approval: .manual
)

let server = XcodeMCPProxyServer(config: config)
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

Use `XcodeMCPProxyServer.Configuration` to configure the server:

- `bind` chooses the HTTP bind address.
- `upstream` chooses the upstream MCP bridge and process count.
- `limits` bounds request timeout and body size.
- `discovery` overrides the endpoint discovery file.
- `approval` controls Xcode permission dialog automation.
- `features.refreshCodeIssuesMode` selects proxy diagnostics or upstream
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
let config = XcodeMCPProxyServer.Configuration(
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
high-level launch plan instead of composing the lower-level parser and config
types:

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
    let server = XcodeMCPProxyServer(config: plan.configuration!)
    _ = try server.startAndWriteDiscovery()
    try await server.wait()
}
```

`LaunchPlan` exposes the resolved public server `Configuration`, normalized
`LaunchOptions`, stable dry-run command line, and display text. Port-in-use
messages are represented by `XcodeMCPProxyServer.PortInUseError`, and product
version information is available through
`XcodeMCPProxyServer.productMetadata`.
The package executable uses a package-level launcher facade to execute the same
plan, keeping force-restart, start/wait, and port-in-use diagnostics inside this
target.

Executable-style hosts can delegate directly to the public runner facade:

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

Command-line hosts can run the same adapter facade with
`XcodeMCPProxyStdioAdapter.run(arguments:environment:stdout:stderr:)`.

## Installer

`XcodeMCPProxyInstaller` owns the source install composition used by
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

Command-line hosts can run the installer facade with
`XcodeMCPProxyInstaller.run(arguments:environment:stdout:stderr:)`.
