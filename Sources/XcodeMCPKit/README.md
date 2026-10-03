# XcodeMCPKit

Swift client API for calling Xcode MCP from an app or tool.

## Overview

Use `XcodeMCPKit` when Swift code needs to discover and call Xcode MCP tools.
The default transport discovers a running `xcode-mcp-proxy-server` endpoint.
The proxy chooses an open GUI workspace owner or lazily loads its native model.
Start the proxy before constructing a default client.

The public API is intentionally small:

- `XcodeMCP`, the top-level async client
- `XcodeMCPConfiguration`, for transport and initialize settings
- `XcodeMCPRequestOptions`, for per-operation deadlines and safe replay policy
- `XcodeMCPConnectionSnapshot`, for atomic lifecycle observation
- `MCPJSONValue`, for dynamic MCP payloads
- `MCPTool`, `MCPToolResult`, `MCPContent`, and `MCPProgress`
- `XcodeMCPError`

Xcode decides the available tools at runtime, so the SDK does not provide
tool-specific Swift wrappers. Use `listTools()` to discover tools, `callTool`
to call them, and `request(_:params:)` for dynamic MCP methods outside
`tools/call`.

Use `XcodeMCPKitTesting` when tests need deterministic tool catalogs, progress
notifications, and tool results through the same `XcodeMCP` API without
launching Xcode or the native helper.

## Quickstart

Add the `XcodeMCPKit` product to your target and start `xcode-mcp-proxy-server`,
then construct a client:

```swift
import Foundation
import XcodeMCPKit

let config = XcodeMCPConfiguration(
    clientName: "MyApp",
    clientVersion: "1.0"
)

let xcode = try await XcodeMCP(configuration: config)
let tools = try await xcode.listTools()

if tools.contains(where: { $0.name == "DocumentationSearch" }) {
    let result = try await xcode.callTool(
        "DocumentationSearch",
        arguments: ["query": "NavigationStack"]
    ) { progress in
        if let message = progress.message {
            print(message)
        }
    }

    for item in result.content {
        if case .text(let text, _) = item {
            print(text)
        }
    }
}

await xcode.close()
```

To choose an explicit running proxy endpoint, configure Streamable HTTP:

```swift
let config = XcodeMCPConfiguration(
    transport: .streamableHTTP(
        endpoint: URL(string: "http://127.0.0.1:8765/mcp")!
    ),
    clientName: "MyApp",
    clientVersion: "1.0"
)

let xcode = try await XcodeMCP(configuration: config)
```

Discovery files written by the proxy are supported as well:

```swift
let config = XcodeMCPConfiguration(
    transport: .streamableHTTP(
        discoveryFile: URL(fileURLWithPath: "/tmp/xcode-mcp/endpoint.json")
    )
)
```

For the standard proxy discovery location, including
`XCODE_MCP_PROXY_DISCOVERY_FILE` and `XCODE_MCP_PROXY_CACHE_ROOT` overrides, use:

```swift
let config = XcodeMCPConfiguration(
    transport: .streamableHTTPProxyDiscovery()
)
```

### Workspace routing

Use the proxy transport when a request should follow an existing GUI workspace:

```swift
let result = try await xcode.callTool("XcodeRead", arguments: [
    "workspaceIdentifier": "/Users/me/Projects/App/App.xcworkspace",
    "filePath": "App/Sources/App.swift"
])
```

An absolute path selects its GUI owner first. With no GUI owner, the proxy's
native host loads the model for the operation. You do not need to open a GUI
window or call Open first. Native workspace IDs and explicit GUI tab IDs are
also supported. Ambiguous or unavailable known GUI owners return errors.

### Standalone native session

A standalone client starts its own headless native host. It needs the signed
`XcodeMCPNativeHost.app`, found from installation paths or supplied explicitly:

```swift
let config = XcodeMCPConfiguration(
    transport: .localBridge(.nativeHost(
        bundleURL: URL(fileURLWithPath: "/opt/xcode-mcp/XcodeMCPNativeHost.app"),
        developerDirectoryURL: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer")
    ))
)
let standalone = try await XcodeMCP(configuration: config)
let tools = try await standalone.listTools()
await standalone.close()
```

This transport exposes the host's native tools and owns its process lifecycle.
Automatic routing to existing GUI owners is provided by the proxy transport.
The verified Xcode 27 headless catalog contains 57 tools; the catalog remains
dynamic, so callers should discover capabilities with `listTools()`.

## Dynamic tools and raw values

The Xcode MCP server decides which tools are available at runtime. Call
`listTools(options:)` to load every page of the catalog, then pass the selected
tool name to `callTool(_:arguments:options:onProgress:)`. A pagination failure
never returns a partial catalog, and a cursor cycle is treated as an invalid
response.

Arguments and dynamic response fields use `MCPJSONValue` so clients can send and
inspect MCP data that this package does not model as a fixed Swift type. Domain
models keep raw values for unknown fields and future MCP extensions. Use public
accessors such as `objectValue`, `arrayValue`, `stringValue`, `boolValue`,
`integerValue`, `doubleValue`, and `isNull` when inspecting dynamic responses.
Use `MCPJSONValue(jsonObject:)`, `MCPJSONValue(_:)`, and `jsonObject` to
bridge between Foundation or Codable values and raw MCP JSON.

For dynamic MCP methods that are not tool calls, use the raw request escape
hatch:

```swift
struct SymbolParams: Encodable {
    var query: String
    var limit: Int
}

let symbols = try await xcode.request(
    "workspace/symbols",
    params: try MCPJSONValue(SymbolParams(
        query: "NavigationStack",
        limit: 5
    ))
)
```

## Configuration

`XcodeMCPConfiguration` controls transport selection and MCP initialization:

- `transport` chooses `.localBridge(...)`, `.streamableHTTP(endpoint:)`,
  `.streamableHTTP(discoveryFile:)`, or `.streamableHTTPProxyDiscovery()`.
- The default transport is `.streamableHTTPProxyDiscovery()` and requires a
  running proxy with a discovery record.
- `.localBridge(.nativeHost(bundleURL:developerDirectoryURL:))` launches an owned
  standalone headless host. `nil` URLs use helper and Xcode discovery.
- `.localBridge(.custom(command:arguments:environment:))` supports an explicit
  generic MCP process.
- `clientName`, `clientVersion`, and `capabilities` are sent in `initialize`.
- `requestTimeout: Duration?` is the default logical deadline. `nil` disables
  the default timeout; nonpositive durations are rejected.

Each request can override the default with `XcodeMCPRequestOptions.Timeout`:

```swift
let tools = try await xcode.listTools(
    options: .init(timeout: .after(.seconds(30)))
)
```

The same absolute deadline covers the initial send, session recovery, one safe
replay, and all pagination requests. `.disabled` is the explicit per-operation
opt-out. Replay is limited to a request that the HTTP server rejected before
processing; delivery-unknown failures are never replayed.

Capabilities that require server-to-client handlers are filtered because this
v1 API does not expose those handlers. For Streamable HTTP, the transport
handles `MCP-Session-Id`, `MCP-Protocol-Version`, POST response parsing,
long-lived SSE GET parsing, and best-effort session DELETE during `close()`.

## Lifecycle

Create one `XcodeMCP` per MCP session. The async initializer connects the
transport and completes initialization before returning. A typed HTTP session
expiry starts one shared recovery handshake; concurrent callers join it and a
safe operation is replayed at most once. After recovery fails, normal requests
remain unavailable until `reconnect(options:)` succeeds.

Use `connectionState()` for one atomic snapshot or `connectionStates()` for an
independent stream. Every stream starts with the current snapshot, uses
`bufferingNewest(1)`, and finishes after the terminal `closed` state. A gap in
`sequence` means an intermediate state was coalesced; `generation` changes when
a fresh transport becomes current.

`callTool` drains accepted progress callbacks before returning, so a callback
never runs after the result is delivered and may safely make another request
through the same client. Timeout and caller cancellation send a best-effort MCP
cancellation notification for the original request ID; server errors do not.

Call `close()` when finished. It is the graceful completion boundary: close is
idempotent, rejects future requests, cancels and awaits owned work, closes the
transport, then publishes the terminal state. Deinitialization is only a
synchronous cancellation backstop.

`XcodeMCPError` conforms to `LocalizedError`. Use `errorDescription` and
`recoverySuggestion` for consumer-facing diagnostics; missing or stale proxy
discovery is reported as `transportUnavailable`, not as an invalid request.

## Testing

`XcodeMCPKitTesting` provides `XcodeMCPTestRuntime`, an in-memory MCP runtime
that creates initialized `XcodeMCP` clients:

```swift
import XcodeMCPKit
import XcodeMCPKitTesting

let runtime = XcodeMCPTestRuntime()
await runtime.setToolResult(
    MCPToolResult(
        content: [
            .text("Result text")
        ]
    ),
    forToolNamed: "DocumentationSearch"
)

let xcode = try await runtime.makeClient()
let result = try await xcode.callTool(
    "DocumentationSearch",
    arguments: ["query": "NavigationStack"]
)
await xcode.close()
```

The runtime provides the fake transport and JSON-RPC response loop. Tests can
read `recordedMessages()` and `recordedToolCalls()` to assert request shape while
keeping production code on the public SDK surface. A non-default transport in
`makeClient(configuration:)` is rejected instead of being silently ignored.

See [`XcodeMCPKitTesting`](../XcodeMCPKitTesting/README.md) for the focused
testing API guide.
