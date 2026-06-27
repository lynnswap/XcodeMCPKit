# XcodeMCPKitTesting

`XcodeMCPKitTesting` provides an in-memory MCP runtime for tests that should use
the real `XcodeMCP` public API without launching `mcpbridge`.

Use it from app or SDK tests when the production code accepts an `XcodeMCP`
client and you want deterministic tool catalogs, progress notifications, and
tool results.

```swift
import XcodeMCPKit
import XcodeMCPKitTesting

let runtime = XcodeMCPTestRuntime()
await runtime.setToolResult(
    MCPToolResult(
        content: [
            .text(
                "NavigationStack documentation",
                raw: [
                    "type": "text",
                    "text": "NavigationStack documentation",
                ]
            )
        ],
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

The testing runtime owns the fake transport and JSON-RPC response loop. Test
code should interact with `XcodeMCP`, `MCPTool`, `MCPToolResult`, and
`MCPJSONValue` instead of building raw JSON-RPC messages.
