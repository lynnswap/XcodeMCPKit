# XcodeMCPProxyKit

Swift API for embedding the Xcode MCP proxy server or its Streamable HTTP to
STDIO adapter.

Use the bundled executables when a library host is unnecessary:

- `xcode-mcp-proxy-server` runs the HTTP proxy.
- `xcode-mcp-proxy` adapts MCP STDIO to a running proxy.
- `xcode-mcp-proxy-install` installs those executables and the signed native app. Installer internals are
  not a public library API.

## Server

Construct one server, start it once, and shut it down explicitly:

```swift
import XcodeMCPProxyKit

let server = XcodeMCPProxyServer(
    configuration: .init(
        bindAddress: .localhost(port: 0),
        requestTimeout: .seconds(300),
        discovery: .defaultLocation,
        approvalPolicy: .manual
    )
)

let endpoint = try await server.start()
print("Listening on \(endpoint.url)")

let status = await server.snapshot()
print("Lifecycle: \(status.phase)")

try await server.shutdown()
```

`start()` binds the listener, starts the runtime, and publishes the requested
discovery record. Native initialization and catalog availability are observed
through `snapshot()` and MCP requests. A discovery write failure unwinds acquired resources and
throws. Use `waitUntilShutdown()` when another task owns the shutdown signal.

`shutdown()` is idempotent and is the graceful completion boundary. It returns
after listener and accepted channels, runtime activity, permission automation,
and event-loop resources have stopped. A server instance is one-shot; construct
a new instance after shutdown.

Concurrent and repeated `shutdown()` calls return the same shutdown result.
If startup and its cleanup both fail, `XcodeMCPProxyServer.CleanupError` retains
both errors and any bound endpoint. A cleanup failure means resource release
may be incomplete, even though the server lifecycle has stopped.

### Server configuration

`XcodeMCPProxyServerConfiguration` exposes the supported embedding choices:

- `bindAddress`: host and port; port `0` requests an ephemeral port.
- `nativeHostBundleURL`: signed native helper app bundle, or `nil` for automatic lookup.
- `developerDirectoryURL`: selected Xcode app/developer directory, or `nil` for the selected installation.
- `maxBodyBytes`: positive maximum HTTP request body size.
- `requestTimeout`: a positive `Duration`, or `nil` to disable the timeout.
- `initializeHandshake`: typed upstream initialization for embedding.
- `discovery`: `.disabled`, `.defaultLocation`, or `.file(URL)`.
- `approvalPolicy`: manual or automatic Xcode permission handling.
- `prewarmToolsList`: whether discovery begins during startup.

The server starts one owned headless native host and one connection for each
GUI Xcode owner. Concurrent requests multiplex on each connection. Pass an
absolute `workspaceIdentifier` to prefer its open GUI owner; otherwise the host
loads its model lazily. Discovery preserves the actual provider catalogs and their schema variants.
Usable GUI catalogs remain available when headless contracts are missing.

`start()` does not require an open GUI workspace or Xcode Service enable/status.
Install `XcodeMCPNativeHost.app` beside the proxy executable, or supply its bundle
URL. Missing helper or required native contracts return diagnostics. Embedded
hosts must keep AppKit's main run loop available for GUI process observation.

`approvalPolicy: .automatic` handles recognized connection dialogs for all
agents. It requires Accessibility permission for the embedding host. Agent
identity candidates include the native helper executable and child process IDs.

Inherited `MCP_XCODE_PID` and `MCP_XCODE_SESSION_ID` do not select a proxy backend.
For a standalone headless or generic MCP process, use `XcodeMCPKit`'s explicit
`.localBridge(.nativeHost(...))` or `.localBridge(.custom(...))` transport.
See [native routing migration](../../Docs/automatic-routing-migration.md).

```swift
import Foundation
import XcodeMCPKit
import XcodeMCPProxyKit

let configuration = XcodeMCPProxyServerConfiguration(
    initializeHandshake: .init(
        clientInfo: .init(name: "EmbeddingClient", version: "1.0"),
        capabilities: ["roots": ["listChanged": true]]
    )
)
```

`snapshot()` returns a sanitized aggregate read model: lifecycle phase,
endpoint, proxy/catalog readiness, queued request count, and per-upstream
health. It does not expose traffic payloads, tool arguments, or stderr.

## STDIO adapter

The adapter resolves one HTTP endpoint when it is constructed, forwards STDIO
messages after `start()`, and owns session recovery:

```swift
import Foundation
import XcodeMCPProxyKit

let adapter = try XcodeMCPProxyStdioAdapter(
    configuration: .init(
        endpoint: .url(URL(string: "http://localhost:8765/mcp")!),
        requestTimeout: .seconds(300)
    )
)

try await adapter.start()
let state = await adapter.connectionState()
print("Connection: \(state.phase)")

await adapter.stop()
```

Endpoint policies are:

- `.url(URL)` for one concrete HTTP or HTTPS endpoint.
- `.discoveryFile(URL)` for one explicit proxy discovery record.
- `.proxyDefault(environment:)` for
  `XCODE_MCP_PROXY_ENDPOINT` → default discovery file →
  `http://localhost:8765/mcp` resolution.

`start()` is one-shot. `waitUntilStopped()` waits for EOF-driven or explicit
shutdown. `stop()` is idempotent and returns only after input, output, pending
requests, event delivery, recovery, network activity, and file-descriptor I/O
have reached terminal state.

When a request carrying the active MCP session ID is rejected with HTTP 404,
the adapter shares one bounded recovery, performs a hidden fresh initialize,
and never writes that internal response to STDIO. A request is replayed at most
once and only when the transport proves it was rejected before processing.
Delivery-unknown operations are not replayed. Connection state is available
through `connectionState()`.

## Command facades

Swift hosts that need executable-compatible argument parsing can use the two
public `run(...)` facades without depending on parser or launch-plan types:

```swift
let exitCode = await XcodeMCPProxyServer.run(
    arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment,
    stdout: { print($0) },
    stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
)
```

`XcodeMCPProxyStdioAdapter.run(...)` has the same callback and exit-code shape.
The adapter CLI accepts `--url` as its only explicit endpoint flag.
`--request-timeout 0` disables its timeout; negative, non-finite, or nonnumeric
values are rejected. The removed `--stdio` spelling is not redirected.

The installer is command-only and stages the signed helper beside both binaries:

```bash
xcode-mcp-proxy-install
xcode-mcp-proxy-install --dry-run
```

See [native routing migration](../../Docs/automatic-routing-migration.md) for
the current transport and configuration changes. The earlier
[breaking migration guide](../../Docs/migration-2026-07.md) records the v0.14.0 API changes.
