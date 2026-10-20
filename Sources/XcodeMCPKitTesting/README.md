# XcodeMCPKitTesting

`XcodeMCPKitTesting` provides an in-memory MCP runtime for tests that should use
the real `XcodeMCP` public API without launching Xcode, a native helper, or a proxy server.

Use it from app or SDK tests when the production code accepts an `XcodeMCP`
client and you want deterministic tool catalogs, progress notifications, and
tool results.

```swift
import XcodeMCPKit
import XcodeMCPKitTesting

let runtime = XcodeMCPTestRuntime()
await runtime.setToolResult(
    MCPToolResult(
        content: [.text("NavigationStack documentation")],
        structuredContent: [
            "matches": 1,
        ]
    ),
    forToolNamed: "DocumentationSearch"
)

let xcode = try await runtime.makeClient()
let tools = try await xcode.listTools()
let result = try await xcode.callTool(
    "DocumentationSearch",
    arguments: [
        "query": "NavigationStack",
    ]
)

await xcode.close()
```

Raw MCP requests can be handled without creating a tool wrapper:

```swift
await runtime.setRequestHandler({ method, params in
    [
        "method": .string(method),
        "echo": params ?? .null,
    ]
}, forMethod: "workspace/symbols")
```

The testing runtime owns the fake transport and JSON-RPC response loop. Test
code should interact with `XcodeMCP`, `MCPTool`, `MCPToolResult`, and
`MCPJSONValue` instead of building raw JSON-RPC messages.

Use `recordedToolCalls()` for decoded name/argument assertions and
`recordedMessages()` when testing the wire request itself. `makeClient` accepts
its default local test transport; it rejects an explicit production transport
rather than silently replacing it.
