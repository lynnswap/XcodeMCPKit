# XcodeMCPKit

Swift client API for talking to Xcode's local MCP bridge from an app or tool.

## Status

`XcodeMCPKit` is the public client-side library target. It connects to the
configured MCP transport, performs the MCP initialize handshake, and exposes the
dynamic Xcode MCP tool catalog through a small Swift API. The default transport
launches `xcrun mcpbridge`; clients can also connect to a proxy Streamable HTTP
endpoint.

This target owns:

- `XcodeMCP`, the top-level async client
- `MCPJSONValue`, the raw JSON value used for dynamic MCP payloads
- `MCPTool`, `MCPToolResult`, `MCPContent`, and `MCPProgress`
- `XcodeMCPError`

It intentionally does not expose tool-specific Swift wrappers, JSON-RPC framing,
transport streams, or server-to-client handlers such as roots, sampling, and
elicitation.

MCP wire values and configured transports live in internal targets:
`XcodeMCPCore` owns JSON/MCP protocol contracts, `XcodeMCPProcessRuntime` owns
local process IO, and `XcodeMCPClientRuntime` owns the initialized single-client
session. `XcodeMCPKit` uses those targets without making runtime types part of
the public library product surface.

Use the separate `XcodeMCPKitTesting` product when tests need deterministic
tool catalogs, progress notifications, and tool results through the same
`XcodeMCP` public API without launching `mcpbridge`.

## Quickstart

Add the `XcodeMCPKit` product to your target, then construct a client:

```swift
import XcodeMCPKit

let config = XcodeMCP.Configuration(
    transport: .localBridge(.defaultMCPBridge),
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

To use a running `xcode-mcp-proxy-server`, configure Streamable HTTP:

```swift
let config = XcodeMCP.Configuration(
    transport: .streamableHTTP(
        endpoint: URL(string: "http://127.0.0.1:8765/mcp")!
    ),
    clientName: "MyApp",
    clientVersion: "1.0"
)

let xcode = try await XcodeMCP(config: config)
```

Discovery files written by the proxy are supported as well:

```swift
let config = XcodeMCP.Configuration(
    transport: .streamableHTTP(
        discoveryFile: URL(fileURLWithPath: "/tmp/xcode-mcp/endpoint.json")
    )
)
```

## Dynamic Tools And Raw Values

The Xcode MCP server decides which tools are available at runtime. Call
`listTools()` to discover names, descriptions, and input schemas, then pass the
selected tool name to `callTool(_:arguments:onProgress:)`.

Arguments and dynamic response fields use `MCPJSONValue` so clients can send and
inspect MCP data that this package does not model as a fixed Swift type. Domain
models keep raw values for unknown fields and future MCP extensions. Use public
accessors such as `objectValue`, `arrayValue`, `stringValue`, `boolValue`,
`integerValue`, `doubleValue`, and `isNull` when inspecting dynamic responses.

## Configuration

`XcodeMCP.Configuration` controls transport selection and MCP initialization:

- `transport` chooses `.localBridge(...)`, `.streamableHTTP(endpoint:)`, or
  `.streamableHTTP(discoveryFile:)`.
- The compatibility `bridge` property still chooses the upstream bridge for
  local process transport. The default is Xcode's `/usr/bin/xcrun mcpbridge`.
- Use bridge `.custom(command:arguments:environment:)` only when embedding a
  non-default bridge command.
- `clientName`, `clientVersion`, and `capabilities` are sent in `initialize`.
- `requestTimeout` bounds requests when non-`nil`.

Capabilities that require server-to-client handlers are filtered because this
v1 API does not expose those handlers. For Streamable HTTP, the transport owns
`MCP-Session-Id`, `MCP-Protocol-Version`, POST response parsing, long-lived SSE
GET parsing, and best-effort session DELETE during `close()`.

## Lifecycle

Create one `XcodeMCP` per MCP session. The async initializer connects the
transport and completes initialization before returning. `callTool` returns the
final MCP result; progress is callback-only and the underlying event stream is
not public API. Call `close()` when finished. Closing is idempotent and rejects
future requests.

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
            .text(
                "Result text",
                raw: ["type": "text", "text": "Result text"]
            )
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

The runtime owns the fake transport and JSON-RPC response loop. Tests can read
`recordedMessages()` to assert request shape while keeping production code on
the public SDK surface.
