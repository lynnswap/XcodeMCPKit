# XcodeMCPKit

Swift client API for talking to Xcode's local MCP bridge from an app or tool.

## Status

`XcodeMCPKit` is the public client-side library target. It launches the
configured `mcpbridge` process, performs the MCP initialize handshake, and
exposes the dynamic Xcode MCP tool catalog through a small Swift API.

This target owns:

- `XcodeMCP`, the top-level async client
- `MCPJSONValue`, the raw JSON value used for dynamic MCP payloads
- `MCPTool`, `MCPToolResult`, `MCPContent`, and `MCPProgress`
- `XcodeMCPError`

It intentionally does not expose tool-specific Swift wrappers, JSON-RPC framing,
transport streams, or server-to-client handlers such as roots, sampling, and
elicitation.

## Quickstart

Add the `XcodeMCPKit` product to your target, then construct a client:

```swift
import XcodeMCPKit

let config = XcodeMCP.Configuration(
    command: "/usr/bin/xcrun",
    arguments: ["mcpbridge"],
    clientName: "MyApp",
    clientVersion: "1.0"
)

let xcode = try await XcodeMCP(config: config)
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

## Dynamic Tools And Raw Values

The Xcode MCP server decides which tools are available at runtime. Call
`listTools()` to discover names, descriptions, and input schemas, then pass the
selected tool name to `callTool(_:arguments:onProgress:)`.

Arguments and dynamic response fields use `MCPJSONValue` so clients can send and
inspect MCP data that this package does not model as a fixed Swift type. Domain
models keep raw values for unknown fields and future MCP extensions.

## Configuration

`XcodeMCP.Configuration` controls process launch and MCP initialization:

- `command` and `arguments` choose the upstream process. The default is
  `/usr/bin/xcrun mcpbridge`.
- `environment` is passed to the process.
- `clientName`, `clientVersion`, and `capabilities` are sent in `initialize`.
- `requestTimeout` bounds requests when non-`nil`.
- `maxQueuedWriteBytes` limits queued outbound transport data.

Capabilities that require server-to-client handlers are filtered because this
v1 API does not expose those handlers.

## Lifecycle

Create one `XcodeMCP` per bridge session. The async initializer starts the
process and completes initialization before returning. `callTool` returns the
final MCP result; progress is callback-only and the underlying event stream is
not public API. Call `close()` when finished. Closing is idempotent and rejects
future requests.
