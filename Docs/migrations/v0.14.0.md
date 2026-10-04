# Breaking API Migration — v0.14.0

This release replaces the previous proxy embedding and client lifecycle APIs.
It does not provide deprecated wrappers for removed symbols.

The wire-level MCP methods, JSON schemas, and discovery-record schema are
unchanged. The migration is required for Swift API consumers and for callers
that used the removed STDIO CLI flag.

## XcodeMCPKit client

Create one client, observe its typed connection state when needed, and close it
explicitly:

```swift
import XcodeMCPKit

let client = try await XcodeMCP(
    configuration: .init(transport: .streamableHTTPProxyDiscovery())
)
let tools = try await client.listTools(
    options: .init(timeout: .after(.seconds(30)))
)
await client.close()
```

Behavior and symbol changes:

| Previous | Replacement |
|---|---|
| Per-call fixed configuration timeout only | `XcodeMCPRequestOptions.Timeout` with `.configurationDefault`, `.disabled`, or `.after(Duration)` |
| No public replay choice | `XcodeMCPRequestOptions.ReplayPolicy`; replay remains limited to one request rejected before processing |
| No typed connection state or explicit reconnect | `connectionState()`, `connectionStates()`, and `reconnect(options:)` |
| Public `XcodeMCPConnectionSnapshot` memberwise initializer | Obtain authority-owned snapshots from `connectionState()` or `connectionStates()`; consumers no longer construct semantic connection state |
| `listTools()` returned the first page | `listTools(options:)` returns the complete catalog within one logical deadline and never returns a partial catalog |
| `callTool` without progress | `callTool(_:arguments:options:onProgress:)` |
| Public `notify(_:params:)` escape hatch | Use the typed SDK operations or `request(_:params:options:)`; arbitrary client notifications are no longer part of the supported public surface |
| `MCPJSONValue.init(encoding:)` | `MCPJSONValue.init(_:)` |
| `MCPJSONValue.intValue` | `MCPJSONValue.integerValue` |
| Manual text-content extraction | `MCPContent.text(_:)` and `MCPToolResult.text` |
| Generic error text only | `XcodeMCPError` now conforms to `LocalizedError` and distinguishes `sessionRecoveryFailed` from transport unavailability |

`close()` is the graceful completion boundary. Dropping a client without
calling `close()` only requests synchronous cancellation; it does not promise a
graceful protocol shutdown.

`XcodeMCPKitTesting` now exposes `recordedToolCalls()` for decoded
`tools/call` assertions. `XcodeMCPTestRuntime.makeClient(configuration:)`
accepts only the default `.localBridge()` transport configuration; a different
transport is rejected instead of being silently replaced by the test
transport.

## Embedded proxy server

```swift
import XcodeMCPProxyKit

let server = XcodeMCPProxyServer(
    configuration: .init(
        requestTimeout: .seconds(300),
        discovery: .defaultLocation
    )
)
let endpoint = try await server.start()
let status = await server.snapshot()

// Use endpoint.url and status as needed.

try await server.shutdown()
```

| Removed or changed | Replacement |
|---|---|
| `XcodeMCPProxyServerConfiguration.Limits` | Top-level `maxBodyBytes` and `requestTimeout: Duration?` properties |
| `configurationFilePath: String?` | `configurationFileURL: URL?` |
| Struct-style discovery configuration | `.disabled`, `.defaultLocation`, or `.file(URL)` |
| Synchronous `start()` | `try await start()` |
| `startAndWriteDiscovery()` | Configure `discovery`, then call `try await start()` |
| `wait()` | `waitUntilShutdown()` |
| No public status read model | `snapshot()` returning sanitized `XcodeMCPProxyServer.Status` |
| Public `LaunchAction`, `LaunchOptions`, `LaunchPlan`, and `LaunchResolutionError` | `XcodeMCPProxyServer.run(arguments:environment:stdout:stderr:)` for CLI hosting, or the embedding API above |
| Public `XcodeMCPProxyProductMetadata` and `PortInUseError` | CLI exit code and `stderr` output from `run(...)` |

`requestTimeout == nil` is the only programmatic way to disable the timeout.
Zero or negative `Duration` values are invalid. For the server CLI,
`--request-timeout 0` is normalized to disabled before configuration is built.

## Embedded STDIO adapter

```swift
import XcodeMCPProxyKit

let adapter = try XcodeMCPProxyStdioAdapter(
    configuration: .init(endpoint: .url(endpoint.url))
)
try await adapter.start()
await adapter.stop()
```

| Removed or changed | Replacement |
|---|---|
| `XcodeMCPProxyAdapterEndpointResolutionOptions` | `XcodeMCPProxyStdioAdapterConfiguration.Endpoint` |
| `XcodeMCPProxyAdapterEndpoint` and public endpoint source metadata | Configure `.url(URL)`, `.discoveryFile(URL)`, or `.proxyDefault(environment:)` |
| `XcodeMCPProxyAdapterEndpointResolver` | Endpoint resolution is internal to `XcodeMCPProxyStdioAdapter` |
| `requestTimeout: TimeInterval` | `requestTimeout: Duration?` |
| Nonthrowing `start()` | `try await start()` |
| `wait()` | `waitUntilStopped()` |
| Public adapter launch plan/parser types | `XcodeMCPProxyStdioAdapter.run(arguments:environment:stdout:stderr:)` |
| `--stdio URL` and `rewriteURLFlagToStdio` | `--url URL` |

As with the client and server, `stop()` is the graceful completion boundary.

## Installer

The installer is an executable-only consumer story. The following Swift
library surfaces are removed:

- `XcodeMCPProxyInstallerConfiguration`
- `XcodeMCPProxyInstaller`
- Installer launch-plan, install-plan, binary-plan, and public install methods

Use the shipped command instead:

```bash
xcode-mcp-proxy-install
xcode-mcp-proxy-install --dry-run
```

The executable behavior and dry-run output remain supported.

## STDIO CLI

Use `--url` as the only explicit endpoint flag:

```bash
xcode-mcp-proxy --url http://localhost:8765/mcp
```

`--stdio` is removed and is not redirected. Invalid, negative, non-finite, or
nonnumeric timeout values fail argument parsing; `--request-timeout 0` disables
the timeout.
