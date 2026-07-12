import Foundation
import XcodeMCPKit

/// An in-memory MCP runtime for tests that need an ``XcodeMCP`` client without
/// launching `mcpbridge`.
///
/// Use this target from app or SDK tests when the code under test should talk
/// to the real ``XcodeMCP`` public API, while tool catalogs, tool responses,
/// progress notifications, and server errors stay deterministic.
public actor XcodeMCPTestRuntime {
    /// A JSON-RPC message sent by ``XcodeMCP`` to the test runtime.
    public struct RecordedMessage: Equatable, Sendable {
        /// The JSON-RPC `id`, when the message is a request or response.
        public var id: MCPJSONValue?

        /// The JSON-RPC method, when the message is a request or notification.
        public var method: String?

        /// The JSON-RPC `params`, when supplied.
        public var params: MCPJSONValue?

        /// The JSON-RPC `result`, when the message is a response.
        public var result: MCPJSONValue?

        /// The JSON-RPC `error`, when the message is an error response.
        public var error: MCPJSONValue?

        /// Creates a recorded message.
        public init(
            id: MCPJSONValue? = nil,
            method: String? = nil,
            params: MCPJSONValue? = nil,
            result: MCPJSONValue? = nil,
            error: MCPJSONValue? = nil
        ) {
            self.id = id
            self.method = method
            self.params = params
            self.result = result
            self.error = error
        }
    }

    /// A decoded `tools/call` request received by the test runtime.
    public struct ToolCall: Equatable, Sendable {
        /// The requested tool name.
        public var name: String

        /// The raw MCP arguments object.
        public var arguments: [String: MCPJSONValue]

        /// The MCP progress token requested by the client, when present.
        public var progressToken: String?

        /// The complete `tools/call` params object.
        public var rawParams: MCPJSONValue

        /// Creates a decoded tool call.
        public init(
            name: String,
            arguments: [String: MCPJSONValue],
            progressToken: String? = nil,
            rawParams: MCPJSONValue
        ) {
            self.name = name
            self.arguments = arguments
            self.progressToken = progressToken
            self.rawParams = rawParams
        }
    }

    /// A progress update emitted before a tool call returns its final result.
    public struct ProgressUpdate: Equatable, Sendable {
        /// Current progress value, when supplied.
        public var progress: Double?

        /// Total progress value, when supplied.
        public var total: Double?

        /// Human-readable progress message, when supplied.
        public var message: String?

        /// Extra fields to preserve on the MCP progress payload.
        public var metadata: [String: MCPJSONValue]

        /// Creates a progress update prototype.
        public init(
            progress: Double? = nil,
            total: Double? = nil,
            message: String? = nil,
            metadata: [String: MCPJSONValue] = [:]
        ) {
            self.progress = progress
            self.total = total
            self.message = message
            self.metadata = metadata
        }
    }

    /// A JSON-RPC error returned by the test runtime.
    public struct ServerError: Error, Equatable, Sendable {
        /// JSON-RPC error code.
        public var code: Int

        /// JSON-RPC error message.
        public var message: String

        /// Optional JSON-RPC error data.
        public var data: MCPJSONValue?

        /// Creates a server error.
        public init(code: Int = -32000, message: String, data: MCPJSONValue? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }
    }

    public typealias ToolHandler = @Sendable (ToolCall) async throws -> MCPToolResult

    /// A handler for raw MCP requests sent through ``XcodeMCP/request(_:params:)``.
    ///
    /// Throw ``ServerError`` to return a JSON-RPC error response to the client.
    public typealias RequestHandler = @Sendable (
        _ method: String,
        _ params: MCPJSONValue?
    ) async throws -> MCPJSONValue

    private let initializeResult: MCPJSONValue
    private var tools: [MCPTool]
    private var toolResults: [String: MCPToolResult] = [:]
    private var progressUpdates: [String: [ProgressUpdate]] = [:]
    private var toolHandler: ToolHandler?
    private var requestHandlers: [String: RequestHandler] = [:]
    private var messages: [RecordedMessage] = []
    private var closeCount = 0
    private var transportContinuations: [UUID: AsyncStream<XcodeMCPTransportEvent>.Continuation] = [:]

    /// Creates an in-memory runtime.
    ///
    /// - Parameters:
    ///   - tools: Initial tool catalog returned by ``XcodeMCP/listTools()``.
    ///   - initializeResult: Raw result for MCP `initialize`. The default
    ///     matches the protocol version used by `XcodeMCPKit`.
    public init(
        tools: [MCPTool] = [XcodeMCPTestRuntime.defaultDocumentationSearchTool],
        initializeResult: MCPJSONValue = XcodeMCPTestRuntime.defaultInitializeResult
    ) {
        self.tools = tools
        self.initializeResult = initializeResult
    }

    /// Creates an initialized ``XcodeMCP`` client backed by this runtime.
    ///
    /// The returned client performs the normal MCP `initialize` and
    /// `notifications/initialized` handshake. Tests can inspect
    /// ``recordedMessages()`` to assert request shape.
    public func makeClient(
        configuration: XcodeMCPConfiguration = XcodeMCPConfiguration()
    ) async throws -> XcodeMCP {
        guard configuration.transport == .localBridge() else {
            throw XcodeMCPError.invalidRequest(
                "XcodeMCPTestRuntime requires the default localBridge transport configuration"
            )
        }
        let transport = XcodeMCPTestTransport(runtime: self)
        transportContinuations[transport.id] = transport.continuation
        return try await XcodeMCP(configuration: configuration, transport: transport)
    }

    /// Replaces the tool catalog returned from `tools/list`.
    public func setTools(_ tools: [MCPTool]) {
        self.tools = tools
    }

    /// Stores a fixed result for a tool.
    public func setToolResult(_ result: MCPToolResult, forToolNamed name: String) {
        toolResults[name] = result
    }

    /// Installs a dynamic tool handler.
    ///
    /// The handler receives a decoded tool call and may return a tool result or
    /// throw ``ServerError`` to produce a JSON-RPC error response.
    public func setToolHandler(_ handler: ToolHandler?) {
        toolHandler = handler
    }

    /// Installs a dynamic raw request handler for a method name.
    ///
    /// Use this when tests exercise ``XcodeMCP/request(_:params:)`` directly
    /// instead of going through `tools/call`. Passing `nil` removes the
    /// handler for that method.
    ///
    /// - Parameters:
    ///   - handler: Raw request handler to invoke.
    ///   - method: MCP method name handled by `handler`.
    public func setRequestHandler(
        _ handler: RequestHandler?,
        forMethod method: String
    ) {
        requestHandlers[method] = handler
    }

    /// Configures progress updates emitted for a named tool call.
    ///
    /// Updates are emitted only when the client supplied an MCP progress token
    /// by passing `onProgress` to ``XcodeMCP/callTool(_:arguments:onProgress:)``.
    public func setProgressUpdates(
        _ updates: [ProgressUpdate],
        forToolNamed name: String
    ) {
        progressUpdates[name] = updates
    }

    /// Returns all JSON-RPC messages sent by the client.
    public func recordedMessages() -> [RecordedMessage] {
        messages
    }

    /// Returns all decoded `tools/call` messages received by the runtime.
    public func recordedToolCalls() -> [ToolCall] {
        messages.compactMap { message in
            guard message.method == "tools/call",
                  let params = message.params,
                  let object = params.objectValue,
                  let name = object["name"]?.stringValue,
                  name.isEmpty == false
            else {
                return nil
            }
            return ToolCall(
                name: name,
                arguments: object["arguments"]?.objectValue ?? [:],
                progressToken: object["_meta"]?.objectValue?["progressToken"]?.stringValue,
                rawParams: params
            )
        }
    }

    /// Returns how many times the backing transport was closed.
    public func recordedCloseCount() -> Int {
        closeCount
    }

    /// Emits a server-to-client request.
    ///
    /// `XcodeMCP` does not expose server request handling in its public API.
    /// This helper lets tests verify that unsupported requests stay internal
    /// and are answered with a JSON-RPC method-not-found error.
    public func emitServerRequest(
        method: String,
        id: MCPJSONValue = .integer(1),
        params: MCPJSONValue = .object([:])
    ) {
        let object: [String: MCPJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id,
            "method": .string(method),
            "params": params,
        ]
        for transportID in transportContinuations.keys {
            emit(object, to: transportID)
        }
    }

    package func receive(_ data: Data, from transportID: UUID) async throws {
        let object = try parse(data)
        let message = RecordedMessage(
            id: object["id"],
            method: object["method"]?.stringValue,
            params: object["params"],
            result: object["result"],
            error: object["error"]
        )
        messages.append(message)

        guard let method = message.method,
              let id = message.id
        else {
            return
        }

        do {
            let result = try await result(
                for: method,
                params: message.params,
                transportID: transportID
            )
            emit([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": result,
            ], to: transportID)
        } catch let error as ServerError {
            emit(errorResponse(id: id, error: error), to: transportID)
        } catch {
            emit(errorResponse(
                id: id,
                error: ServerError(message: String(describing: error))
            ), to: transportID)
        }
    }

    package func closeTransport(id: UUID) {
        closeCount += 1
        guard let continuation = transportContinuations.removeValue(forKey: id) else {
            return
        }
        continuation.yield(.closed(nil))
        continuation.finish()
    }

    private func result(
        for method: String,
        params: MCPJSONValue?,
        transportID: UUID
    ) async throws -> MCPJSONValue {
        switch method {
        case "initialize":
            return initializeResult
        case "tools/list":
            return .object([
                "tools": try MCPJSONValue(tools)
            ])
        case "tools/call":
            let call = try decodeToolCall(params)
            if let token = call.progressToken {
                for update in progressUpdates[call.name] ?? [] {
                    emitProgress(update, token: token, to: transportID)
                }
            }
            if let toolHandler {
                return try await toolHandler(call).raw
            }
            if let result = toolResults[call.name] {
                return result.raw
            }
            throw ServerError(
                code: -32602,
                message: "No test result configured for tool \(call.name)"
            )
        default:
            if let handler = requestHandlers[method] {
                return try await handler(method, params)
            }
            throw ServerError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func decodeToolCall(_ params: MCPJSONValue?) throws -> ToolCall {
        guard let rawParams = params,
              let object = rawParams.objectValue
        else {
            throw ServerError(code: -32602, message: "tools/call params must be an object")
        }
        guard let name = object["name"]?.stringValue,
              name.isEmpty == false
        else {
            throw ServerError(code: -32602, message: "tools/call params missing name")
        }
        let arguments = object["arguments"]?.objectValue ?? [:]
        let progressToken = object["_meta"]?
            .objectValue?["progressToken"]?
            .stringValue
        return ToolCall(
            name: name,
            arguments: arguments,
            progressToken: progressToken,
            rawParams: rawParams
        )
    }

    private func emitProgress(_ update: ProgressUpdate, token: String, to transportID: UUID) {
        var object = update.metadata
        object["progressToken"] = .string(token)
        if let progress = update.progress {
            object["progress"] = .double(progress)
        }
        if let total = update.total {
            object["total"] = .double(total)
        }
        if let message = update.message {
            object["message"] = .string(message)
        }
        emit([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/progress"),
            "params": .object(object),
        ], to: transportID)
    }

    private func errorResponse(id: MCPJSONValue, error: ServerError) -> [String: MCPJSONValue] {
        var errorObject: [String: MCPJSONValue] = [
            "code": .integer(Int64(error.code)),
            "message": .string(error.message),
        ]
        if let data = error.data {
            errorObject["data"] = data
        }
        return [
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(errorObject),
        ]
    }

    private func emit(_ object: [String: MCPJSONValue], to transportID: UUID) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: MCPJSONValue.object(object).jsonObject
        ) else {
            return
        }
        transportContinuations[transportID]?.yield(.message(data))
    }

    private func parse(_ data: Data) throws -> [String: MCPJSONValue] {
        let raw = try JSONSerialization.jsonObject(with: data)
        let value = try MCPJSONValue(jsonObject: raw)
        guard let object = value.objectValue
        else {
            throw XcodeMCPError.invalidRequest("message is not an object")
        }
        return object
    }
}

extension XcodeMCPTestRuntime {
    /// Default initialize result used by the test runtime.
    public static let defaultInitializeResult: MCPJSONValue = .object([
        "protocolVersion": .string("2025-06-18"),
        "serverInfo": .object([
            "name": .string("xcode-mcp-test-runtime"),
            "version": .string("test"),
        ]),
        "capabilities": .object([:]),
    ])

    /// Default documentation search tool used by the test runtime.
    public static let defaultDocumentationSearchTool = MCPTool(
        name: "DocumentationSearch",
        description: "Search Apple developer documentation",
        inputSchema: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                ],
            ],
        ]
    )
}

package actor XcodeMCPTestTransport: XcodeMCPTransport {
    package nonisolated let events: AsyncStream<XcodeMCPTransportEvent>
    package let id = UUID()
    package let continuation: AsyncStream<XcodeMCPTransportEvent>.Continuation

    private let runtime: XcodeMCPTestRuntime
    private var closed = false

    package init(runtime: XcodeMCPTestRuntime) {
        let stream = AsyncStream<XcodeMCPTransportEvent>.makeStream()
        self.events = stream.stream
        self.continuation = stream.continuation
        self.runtime = runtime
    }

    package func send(
        _ data: Data,
        headers: MCPConnectionHeaders,
        deadline: Deadline?
    ) async throws {
        _ = headers
        _ = deadline
        guard closed == false else {
            throw XcodeMCPError.closed
        }
        try await runtime.receive(data, from: id)
    }

    package func startEventStream(headers: MCPConnectionHeaders) async {
        _ = headers
    }

    package func close(headers: MCPConnectionHeaders) async {
        _ = headers
        guard closed == false else {
            return
        }
        closed = true
        await runtime.closeTransport(id: id)
    }
}
