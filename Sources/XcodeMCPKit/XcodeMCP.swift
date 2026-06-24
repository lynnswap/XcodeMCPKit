import Foundation
import ProxyMCP
import ProxyMCPContract

private final class XcodeMCPPendingRequests: @unchecked Sendable {
    private struct PendingRequest {
        let continuation: CheckedContinuation<MCPJSONValue, Error>
    }

    private let lock = NSLock()
    private var requests: [String: PendingRequest] = [:]

    func add(
        idKey: String,
        continuation: CheckedContinuation<MCPJSONValue, Error>
    ) {
        lock.withLock {
            requests[idKey] = PendingRequest(continuation: continuation)
        }
    }

    func complete(idKey: String, result: MCPJSONValue) {
        let request = lock.withLock {
            requests.removeValue(forKey: idKey)
        }
        request?.continuation.resume(returning: result)
    }

    func fail(idKey: String, error: Error) {
        let request = lock.withLock {
            requests.removeValue(forKey: idKey)
        }
        request?.continuation.resume(throwing: error)
    }

    func failAll(error: Error) {
        let pending = lock.withLock {
            let current = requests
            requests.removeAll()
            return current
        }
        for request in pending.values {
            request.continuation.resume(throwing: error)
        }
    }
}

/// A high-level client for the local Xcode MCP bridge.
///
/// `XcodeMCP` starts an `mcpbridge` process, performs the MCP initialize
/// handshake, and exposes the dynamic Xcode tool catalog through
/// ``listTools()`` and ``callTool(_:arguments:onProgress:)``.
///
/// The tool catalog is discovered at runtime. This package intentionally does
/// not promise tool-specific Swift methods or typed request/response models for
/// individual Xcode tools. Pass tool arguments as ``MCPJSONValue`` and inspect
/// the returned ``MCPToolResult`` for the final MCP response.
///
/// Server-to-client handlers such as roots, sampling, and elicitation are not
/// exposed by this v1 API. Progress notifications are delivered only through
/// the callback supplied to ``callTool(_:arguments:onProgress:)``; the streaming
/// transport itself is an implementation detail.
///
/// ```swift
/// import XcodeMCPKit
///
/// let xcode = try await XcodeMCP()
///
/// let tools = try await xcode.listTools()
/// guard tools.contains(where: { $0.name == "DocumentationSearch" }) else {
///     throw XcodeMCPError.invalidResponse("DocumentationSearch is unavailable")
/// }
///
/// _ = try await xcode.callTool(
///     "DocumentationSearch",
///     arguments: ["query": "NavigationStack"]
/// )
///
/// await xcode.close()
/// ```
public actor XcodeMCP {
    /// Settings used to launch and initialize the local MCP bridge.
    ///
    /// The default configuration starts `xcrun mcpbridge` with the current
    /// process environment and a conservative per-request timeout.
    public struct Configuration: Equatable, Sendable {
        /// Upstream bridge process policy.
        public enum Bridge: Equatable, Sendable {
            /// Use Xcode's default `xcrun mcpbridge` invocation.
            case defaultMCPBridge

            /// Use an explicit upstream bridge command.
            case custom(
                command: String,
                arguments: [String],
                environment: [String: String]
            )

            package var command: String {
                switch self {
                case .defaultMCPBridge:
                    return "/usr/bin/xcrun"
                case .custom(let command, _, _):
                    return command
                }
            }

            package var arguments: [String] {
                switch self {
                case .defaultMCPBridge:
                    return ["mcpbridge"]
                case .custom(_, let arguments, _):
                    return arguments
                }
            }

            package var environment: [String: String] {
                switch self {
                case .defaultMCPBridge:
                    return ProcessInfo.processInfo.environment
                case .custom(_, _, let environment):
                    return environment
                }
            }

            package var maxQueuedWriteBytes: Int {
                4 * 1024 * 1024
            }
        }

        /// Bridge process policy.
        public var bridge: Bridge

        /// Client name sent in the MCP `initialize` request.
        public var clientName: String

        /// Client version sent in the MCP `initialize` request.
        public var clientVersion: String

        /// Additional MCP client capabilities sent during initialization.
        ///
        /// Values are encoded as raw MCP JSON. Capabilities that require
        /// server-to-client handlers, such as `roots`, `sampling`, and
        /// `elicitation`, are intentionally not exposed by this API.
        public var capabilities: [String: MCPJSONValue]

        /// Maximum duration to wait for each request.
        ///
        /// Set this to `nil` to disable client-side request timeouts.
        public var requestTimeout: Duration?

        /// Creates a bridge configuration.
        ///
        /// - Parameters:
        ///   - bridge: Upstream bridge process policy.
        ///   - clientName: Client name sent in the MCP `initialize` request.
        ///   - clientVersion: Client version sent in the MCP `initialize`
        ///     request.
        ///   - capabilities: Additional MCP client capabilities encoded as raw
        ///     MCP JSON.
        ///   - requestTimeout: Maximum duration to wait for each request, or
        ///     `nil` to disable client-side request timeouts.
        public init(
            bridge: Bridge = .defaultMCPBridge,
            clientName: String = "XcodeMCPKit",
            clientVersion: String = "dev",
            capabilities: [String: MCPJSONValue] = [:],
            requestTimeout: Duration? = .seconds(60)
        ) {
            self.bridge = bridge
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.capabilities = capabilities
            self.requestTimeout = requestTimeout
        }
    }

    private let config: Configuration
    private let transport: any XcodeMCPTransport
    private let pendingRequests = XcodeMCPPendingRequests()
    private var nextRequestID: Int64 = 1
    private var isClosed = false
    private var eventTask: Task<Void, Never>?
    private var progressHandlers: [String: @Sendable (MCPProgress) async -> Void] = [:]

    /// Starts the local MCP bridge and returns an initialized client.
    ///
    /// The initializer launches the configured process, sends MCP
    /// `initialize`, then sends `notifications/initialized`. If initialization
    /// fails, the process is closed before the error is rethrown.
    ///
    /// - Parameter config: Launch and initialization settings for the bridge.
    public init(config: Configuration = Configuration()) async throws {
        let transport = try await UpstreamProcessXcodeMCPTransport.start(
            config: UpstreamProcess.Config(
                command: config.bridge.command,
                args: config.bridge.arguments,
                environment: config.bridge.environment,
                maxQueuedWriteBytes: config.bridge.maxQueuedWriteBytes
            )
        )
        try await self.init(config: config, transport: transport)
    }

    package init(config: Configuration = Configuration(), transport: any XcodeMCPTransport) async throws {
        self.config = config
        self.transport = transport
        self.eventTask = nil
        self.eventTask = Task { [weak self, transport] in
            for await event in transport.events {
                await self?.handle(event)
            }
        }

        do {
            try await initialize()
        } catch {
            eventTask?.cancel()
            await transport.close()
            throw error
        }
    }

    deinit {
        eventTask?.cancel()
    }

    /// Returns the currently available Xcode MCP tools.
    ///
    /// The returned catalog is dynamic and comes from the running Xcode MCP
    /// server. Use the tool `name` with ``callTool(_:arguments:onProgress:)``
    /// and treat `inputSchema` and `raw` as MCP JSON supplied by the server.
    public func listTools() async throws -> [MCPTool] {
        let result = try await request("tools/list")
        guard let tools = result.objectValue?["tools"]?.arrayValue else {
            throw XcodeMCPError.invalidResponse("tools/list result is missing tools")
        }
        return try tools.map { try MCPTool(json: $0) }
    }

    /// Calls an Xcode MCP tool and returns its final result.
    ///
    /// This method sends an MCP `tools/call` request using the supplied raw JSON
    /// arguments. It waits for the final `tools/call` response and returns it as
    /// ``MCPToolResult``. Incremental transport events are not exposed as a
    /// public stream; progress notifications are delivered through
    /// `onProgress` when the server emits them.
    ///
    /// - Parameters:
    ///   - name: Tool name from ``listTools()``.
    ///   - arguments: Tool arguments encoded as MCP JSON.
    ///   - onProgress: Optional callback for MCP progress notifications
    ///     associated with this call.
    /// - Returns: The final tool result, including content, structured content,
    ///   error status, and the raw MCP JSON response.
    public func callTool(
        _ name: String,
        arguments: [String: MCPJSONValue] = [:],
        onProgress: (@Sendable (MCPProgress) async -> Void)? = nil
    ) async throws -> MCPToolResult {
        guard name.isEmpty == false else {
            throw XcodeMCPError.invalidRequest("tool name must not be empty")
        }

        var params: [String: MCPJSONValue] = [
            "name": .string(name),
            "arguments": .object(arguments),
        ]
        let progressToken: String?
        if let onProgress {
            let token = "xcode-mcp-\(UUID().uuidString)"
            progressToken = token
            progressHandlers[token] = onProgress
            params["_meta"] = .object([
                "progressToken": .string(token)
            ])
        } else {
            progressToken = nil
        }

        defer {
            if let progressToken {
                progressHandlers.removeValue(forKey: progressToken)
            }
        }

        let result = try await request("tools/call", params: .object(params))
        return try MCPToolResult(json: result)
    }

    /// Closes the client and terminates the underlying transport.
    ///
    /// Closing is idempotent. Pending requests fail with ``XcodeMCPError/closed``,
    /// registered progress callbacks are discarded, and no further requests may
    /// be sent through this client.
    public func close() async {
        guard isClosed == false else {
            return
        }
        isClosed = true
        eventTask?.cancel()
        eventTask = nil
        progressHandlers.removeAll()
        pendingRequests.failAll(error: XcodeMCPError.closed)
        await transport.close()
    }
}

extension XcodeMCP {
    package func request(_ method: String, params: MCPJSONValue? = nil) async throws -> MCPJSONValue {
        guard method.isEmpty == false else {
            throw XcodeMCPError.invalidRequest("method must not be empty")
        }
        try ensureOpen()

        let requestID = nextRequestID
        nextRequestID += 1
        let id = JSONRPC.ID(any: NSNumber(value: requestID))!
        let idKey = id.key
        let payload = try makeJSONRPCPayload(id: id, method: method, params: params)

        return try await withRequestTimeout(method: method) { [self] in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.pendingRequests.add(idKey: idKey, continuation: continuation)
                    Task {
                        do {
                            try await self.transport.send(payload)
                        } catch {
                            self.pendingRequests.fail(idKey: idKey, error: error)
                        }
                    }
                }
            } onCancel: {
                self.pendingRequests.fail(idKey: idKey, error: CancellationError())
            }
        }
    }

    package func notify(_ method: String, params: MCPJSONValue? = nil) async throws {
        guard method.isEmpty == false else {
            throw XcodeMCPError.invalidRequest("method must not be empty")
        }
        try ensureOpen()
        let payload = try makeJSONRPCPayload(id: nil, method: method, params: params)
        try await transport.send(payload)
    }
}

private extension XcodeMCP {
    func initialize() async throws {
        _ = try await request(
            "initialize",
            params: .object([
                "protocolVersion": .string(MCP.ProtocolVersion.current),
                "clientInfo": .object([
                    "name": .string(config.clientName),
                    "version": .string(config.clientVersion),
                ]),
                "capabilities": .object(initializeCapabilities()),
            ])
        )
        try await notify("notifications/initialized")
    }

    func initializeCapabilities() -> [String: MCPJSONValue] {
        var capabilities = config.capabilities
        capabilities.removeValue(forKey: "roots")
        capabilities.removeValue(forKey: "sampling")
        capabilities.removeValue(forKey: "elicitation")
        return capabilities
    }

    func withRequestTimeout<T: Sendable>(
        method: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let requestTimeout = config.requestTimeout else {
            return try await operation()
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: requestTimeout)
                throw XcodeMCPError.requestTimedOut(method: method)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func ensureOpen() throws {
        if isClosed {
            throw XcodeMCPError.closed
        }
    }

    func handle(_ event: XcodeMCPTransportEvent) async {
        switch event {
        case .message(let data):
            await handleMessage(data)
        case .closed(let reason):
            isClosed = true
            progressHandlers.removeAll()
            pendingRequests.failAll(
                error: XcodeMCPError.transportUnavailable(reason ?? "mcpbridge closed")
            )
        }
    }

    func handleMessage(_ data: Data) async {
        do {
            let object = try parseJSONObject(data)
            if let id = object["id"], let idKey = jsonRPCIDKey(id) {
                if let method = object["method"]?.stringValue {
                    try await respondToUnsupportedServerRequest(id: id, method: method)
                    return
                }
                if let errorValue = object["error"] {
                    pendingRequests.fail(idKey: idKey, error: parseServerError(errorValue))
                    return
                }
                let result = object["result"] ?? .null
                pendingRequests.complete(idKey: idKey, result: result)
                return
            }

            if object["method"]?.stringValue == "notifications/progress",
               let params = object["params"],
               let progress = MCPProgress(json: params),
               let handler = progressHandlers[progress.progressToken]
            {
                Task {
                    await handler(progress)
                }
            }
        } catch {
            pendingRequests.failAll(error: error)
        }
    }

    func respondToUnsupportedServerRequest(id: MCPJSONValue, method _: String) async throws {
        let payload = try JSONRPC.Wire.errorResponseData(
            idValue: id.jsonValue,
            code: -32601,
            message: "Unsupported server request"
        )
        try await transport.send(payload)
    }

    func makeJSONRPCPayload(
        id: JSONRPC.ID?,
        method: String,
        params: MCPJSONValue?
    ) throws -> Data {
        let object: [String: Any]
        if let id {
            object = JSONRPC.Wire.requestObject(
                id: id,
                method: method,
                params: params?.jsonValue
            )
        } else {
            object = JSONRPC.Wire.notificationObject(
                method: method,
                params: params?.jsonValue
            )
        }
        return try JSONRPC.Wire.data(from: object)
    }

    func parseJSONObject(_ data: Data) throws -> [String: MCPJSONValue] {
        let raw: [String: Any]
        do {
            raw = try JSONRPC.Wire.object(fromData: data)
        } catch JSONRPC.Wire.DecodingFailure.messageWasNotObject {
            throw XcodeMCPError.invalidResponse("JSON-RPC message is not an object")
        } catch {
            throw error
        }
        guard let value = MCPJSONValue(foundationObject: raw),
              let object = value.objectValue
        else {
            throw XcodeMCPError.invalidResponse("JSON-RPC message is not an object")
        }
        return object
    }

    func jsonRPCIDKey(_ value: MCPJSONValue) -> String? {
        switch value {
        case .string(let value):
            return value
        case .integer(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .object, .array, .bool, .null:
            return nil
        }
    }

    func parseServerError(_ value: MCPJSONValue) -> XcodeMCPError {
        guard let object = value.objectValue else {
            return .invalidResponse("JSON-RPC error is not an object")
        }
        let code: Int
        switch object["code"] {
        case .integer(let value):
            code = Int(value)
        case .double(let value):
            code = Int(value)
        default:
            code = 0
        }
        let message = object["message"]?.stringValue ?? "MCP server error"
        return .serverError(code: code, message: message, data: object["data"])
    }
}
