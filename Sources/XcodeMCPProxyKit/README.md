# XcodeMCPProxyKit

Swift API for embedding the Xcode MCP proxy server or its Streamable HTTP to
STDIO adapter.

Use the bundled executables when a library host is unnecessary:

- `xcode-mcp-proxy-server` runs the HTTP proxy.
- `xcode-mcp-proxy` adapts MCP STDIO to a running proxy.
- `xcode-mcp-proxy-install` installs those executables. Installer internals are
  not a public library API.

## Server

Construct one server, start it once, and shut it down explicitly:

```swift
import XcodeMCPProxyKit

let server = XcodeMCPProxyServer(
    configuration: .init(
        bindAddress: .localhost(port: 0),
        upstream: .defaultMCPBridge(processesPerXcode: 1),
        requestTimeout: .seconds(300),
        discovery: .defaultLocation,
        approvalPolicy: .manual,
        xcodeMode: .automatic
    )
)

let endpoint = try await server.start()
print("Listening on \(endpoint.url)")

let status = await server.snapshot()
print("Lifecycle: \(status.phase)")

try await server.shutdown()
```

`start()` returns only after the listener, runtime, and requested discovery
record are ready. A discovery write failure unwinds acquired resources and
throws. Use `waitUntilShutdown()` when another task owns the shutdown signal.

`shutdown()` is idempotent and is the graceful completion boundary. It returns
after listener and accepted channels, runtime activity, permission automation,
and event-loop resources have stopped. A server instance is one-shot; construct
a new instance after shutdown.

### Server configuration

`XcodeMCPProxyServerConfiguration` exposes the supported embedding choices:

- `bindAddress`: host and port; port `0` requests an ephemeral port.
- `upstream`: the default `xcrun mcpbridge` invocation or an explicit command.
  Its `processesPerXcode` value is per GUI Xcode process; headless and custom
  unbound routing use it as the total bridge-pool size.
- `maxBodyBytes`: positive maximum HTTP request body size.
- `requestTimeout`: a positive `Duration`, or `nil` to disable the timeout.
- `configurationFileURL`: optional TOML file. An explicit unreadable or invalid
  file makes `start()` fail before runtime resources are acquired.
- `toolPolicy` and `initializeHandshake`: typed overrides for file-backed tool
  visibility and upstream initialization.
- `discovery`: `.disabled`, `.defaultLocation`, or `.file(URL)`.
- `approvalPolicy`: manual or automatic Xcode permission handling.
- `featurePolicy`: tools-list prewarming and refresh-code-issues routing.
- `xcodeMode`: `.automatic` (the default), `.gui`, or `.headless` for the stock
  `mcpbridge` upstream. Automatic mode selects the enabled Xcode 27 headless
  service and otherwise preserves GUI routing.

Headless mode does not require a workspace to be open in the Xcode app. It
forwards workspace lifecycle and DocumentationSearch tools to Xcode Service,
does not run GUI permission automation, and never enables, approves, or stops
the shared service. If headless access is disabled, enable it separately with
`sudo xcrun mcp-server enable`; explicit `.headless` fails startup instead of
silently falling back. Xcode Service can request manual agent and folder
approval on the first `XcodeOpenWorkspace` call; `approvalPolicy: .automatic`
applies only to GUI Xcode dialogs.

Custom upstream commands keep their existing unbound behavior and require
`xcodeMode: .automatic`.

```swift
import Foundation
import XcodeMCPKit
import XcodeMCPProxyKit

let configuration = XcodeMCPProxyServerConfiguration(
    configurationFileURL: URL(fileURLWithPath: "/etc/xcode-mcp/proxy.toml"),
    toolPolicy: .init(disabledToolNames: ["RunAllTests"]),
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

The installer remains command-only:

```bash
xcode-mcp-proxy-install
xcode-mcp-proxy-install --dry-run
```

See [the breaking migration guide](../../Docs/migration-2026-07.md) for old to
new symbol and CLI mappings.
