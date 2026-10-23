# XcodeMCPProxyKit

Swift API for embedding the Xcode MCP proxy server.

Use the bundled executables when a library host is unnecessary:

- `xcode-mcp-proxy-server` runs the HTTP proxy.
- `xcode-mcp-proxy-install` installs the server and the signed native app. Installer internals are
  not a public library API.

## Server

Construct one server, start it once, and shut it down explicitly:

```swift
import XcodeMCPProxyKit

let server = XcodeMCPProxyServer(
    configuration: .init(
        bindAddress: .localhost(port: 0),
        discovery: .defaultLocation
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
after listener and accepted channels, runtime activity,
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
- `developerDirectoryURL`: preferred Xcode app/developer directory. Unavailable selections fall through to installed-Xcode discovery.
- `sharesCompilationCache`: enables shared compilation caching and Swift/Clang prefix mapping in native hosts. Defaults to `false`; see [compilation caching](../../Docs/configuration.md#compilation-caching) for behavior and limits.
- `approvalPolicy`: `.manual` by default. `.automatic` approves GUI Xcode MCP connection dialogs for all agents, including clients outside this proxy, using macOS Accessibility access.
- `maxBodyBytes`: positive maximum HTTP request body size.
- `requestTimeout`: a positive `Duration`, or `nil` for no timeout, the default. A client that gives up cancels its request or disconnects, which also ends the work; starting a host stays bounded either way.
- `initializeHandshake`: typed upstream initialization for embedding.
- `discovery`: `.disabled`, `.defaultLocation`, or `.file(URL)`.
- `prewarmToolsList`: whether discovery begins during startup.

The server owns the public tool contract and routes workspace handles to their
headless model or GUI Xcode process. `XcodeListWorkspaces` discovers existing
workspaces; `XcodeOpenWorkspace` loads a saved model in the default headless host
unless another host is requested. Workspace and device-session handles retain
their native context without a client-side host switch. See
[workspace usage](../../Docs/usage.md) for the tool contract.

Install `XcodeMCPNativeHost.app` beside the proxy executable, or supply its bundle
URL. Missing helpers or required native contracts return diagnostics. The helper
owns its AppKit event loop. Server startup does not require a GUI workspace or
Xcode Service. With `.automatic` approval, a separate monitor presses `Allow` on
GUI Xcode MCP connection dialogs until server shutdown. It does not change tool
routing or directly rewrite Xcode's agent permission store.

Inherited `MCP_XCODE_PID` and `MCP_XCODE_SESSION_ID` do not select a proxy backend.
For a standalone headless or generic MCP process, use `XcodeMCPKit`'s explicit
`.localBridge(.nativeHost(...))` or `.localBridge(.custom(...))` transport.
See [native routing migration](../../Docs/migrations/native-backend.md).

```swift
import Foundation
import XcodeMCPKit
import XcodeMCPProxyKit

let configuration = XcodeMCPProxyServerConfiguration(
    initializeHandshake: .init(
        clientInfo: .init(name: "EmbeddingClient", version: "1.0"),
        capabilities: ["experimental": ["embedding": true]]
    )
)
```

The handshake omits `roots`, `sampling`, and `elicitation`: every client
session shares an Xcode host, so no client can answer the host requests those
capabilities allow.

`snapshot()` returns a sanitized read model: lifecycle phase, endpoint, and one
entry per Xcode host with its identifier, kind (headless or GUI Xcode process),
state, and active request count. It does not expose traffic payloads, tool
arguments, or stderr.

`XcodeMCPProxyServer.run(...)` handles `SIGINT` and `SIGTERM` while the server
runs: the first signal shuts the server down, stopping every host process, and
a second one terminates the process immediately.

## Command facades

Swift hosts that need executable-compatible argument parsing can use the public
`run(...)` facade without depending on parser or launch-plan types:

```swift
let exitCode = await XcodeMCPProxyServer.run(
    arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment,
    stdout: { print($0) },
    stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
)
```

The installer is command-only and stages the signed helper beside the server binary:

```bash
xcode-mcp-proxy-install
xcode-mcp-proxy-install --dry-run
```

See the [migration guide](../../Docs/migrations/native-backend.md) for removed
Swift APIs, configuration, and older tool-routing sequences.
