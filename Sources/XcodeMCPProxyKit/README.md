# XcodeMCPProxyKit

Swift library API for embedding the Xcode MCP Streamable HTTP proxy server.

## Status

`XcodeMCPProxyKit` is the public server-side kit used by the
`xcode-mcp-proxy-server` executable. The CLI parses command-line options and
then constructs `XcodeMCPProxyServer(config:)` from this target, so the package
boundary is real and does not rely on a private server wrapper.

This target owns:

- `XcodeMCPProxyServer`, the embeddable proxy server lifecycle object
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
