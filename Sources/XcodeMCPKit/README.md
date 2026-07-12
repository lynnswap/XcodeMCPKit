# XcodeMCPKit

Swift client API for calling Xcode MCP from an app or tool.

## Overview

Use `XcodeMCPKit` when Swift code needs to discover and call Xcode MCP tools.
The default transport launches `xcrun mcpbridge`; clients can also connect to a
running `xcode-mcp-proxy-server` Streamable HTTP endpoint.

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
launching `mcpbridge`.

## Quickstart

Add the `XcodeMCPKit` product to your target, then construct a client:

```swift
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

To use a running `xcode-mcp-proxy-server`, configure Streamable HTTP:

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

## Dynamic Tools And Raw Values

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
- The default transport is Xcode's `/usr/bin/xcrun mcpbridge`.
- Use `.localBridge(.custom(command:arguments:environment:))` only when
  embedding a non-default bridge command.
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
