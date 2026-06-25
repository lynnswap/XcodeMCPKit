# XcodeMCPProxyKit

Swift library API for embedding the Xcode MCP Streamable HTTP proxy server.

## Status

`XcodeMCPProxyKit` is the public server-side kit used by the
`xcode-mcp-proxy-server` executable. The kit resolves command-line arguments and
environment variables into `XcodeMCPProxyServer.LaunchPlan`, then the executable
acts as a thin composition root that executes that plan.

This target owns:

- `XcodeMCPProxyServer`, the embeddable proxy server lifecycle object
- server launch plan resolution from argv/environment
- product metadata, version line, dry-run, force-restart, and port-in-use
  diagnostics for server launchers
- HTTP channel setup and request handling integration
- startup, discovery writing, waiting, and shutdown entry points

External embedders configure the server through
`XcodeMCPProxyServer.Configuration`. Lower-level session routing, upstream
process management, Xcode support, and MCP HTTP behavior stay in their own
internal targets behind this kit boundary.

This target intentionally does not expose the executable CLI parser, the STDIO
adapter, per-tool typed wrappers, or direct access to the internal session
router.

## Quickstart

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

The server can also load TOML-backed initialize overrides and disabled tools
when `configurationFilePath` is set.

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
