import Foundation
import ProxyMCPContract
import ProxySessionUpstream

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

public actor XcodeMCP {
    public struct Configuration: Equatable, Sendable {
        public var command: String
        public var arguments: [String]
        public var environment: [String: String]
        public var clientName: String
        public var clientVersion: String
        public var capabilities: [String: MCPJSONValue]
        public var requestTimeout: Duration?
        public var maxQueuedWriteBytes: Int

        public init(
            command: String = "/usr/bin/xcrun",
            arguments: [String] = ["mcpbridge"],
            environment: [String: String] = ProcessInfo.processInfo.environment,
            clientName: String = "XcodeMCPKit",
            clientVersion: String = "dev",
            capabilities: [String: MCPJSONValue] = [:],
            requestTimeout: Duration? = .seconds(60),
            maxQueuedWriteBytes: Int = 4 * 1024 * 1024
        ) {
            self.command = command
            self.arguments = arguments
            self.environment = environment
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.capabilities = capabilities
            self.requestTimeout = requestTimeout
            self.maxQueuedWriteBytes = maxQueuedWriteBytes
        }
    }

    private let config: Configuration
    private let transport: any XcodeMCPTransport
    private let pendingRequests = XcodeMCPPendingRequests()
    private var nextRequestID: Int64 = 1
    private var isClosed = false
    private var eventTask: Task<Void, Never>?
    private var progressHandlers: [String: @Sendable (MCPProgress) async -> Void] = [:]

    public init(config: Configuration = Configuration()) async throws {
        let transport = try await UpstreamProcessXcodeMCPTransport.start(
            config: UpstreamProcess.Config(
                command: config.command,
                args: config.arguments,
                environment: config.environment,
                maxQueuedWriteBytes: config.maxQueuedWriteBytes
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

    public func listTools() async throws -> [MCPTool] {
        let result = try await request("tools/list")
        guard let tools = result.objectValue?["tools"]?.arrayValue else {
            throw XcodeMCPError.invalidResponse("tools/list result is missing tools")
        }
        return try tools.map { try MCPTool(json: $0) }
    }

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
        let idValue = MCPJSONValue.integer(requestID)
        let idKey = String(requestID)
        let payload = try makeJSONRPCPayload(id: idValue, method: method, params: params)

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
                "capabilities": .object(config.capabilities),
            ])
        )
        try await notify("notifications/initialized")
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
                await handler(progress)
            }
        } catch {
            pendingRequests.failAll(error: error)
        }
    }

    func respondToUnsupportedServerRequest(id: MCPJSONValue, method _: String) async throws {
        let payload = try makeJSONRPCResponse(
            id: id,
            error: .object([
                "code": .integer(-32601),
                "message": .string("Unsupported server request"),
            ])
        )
        try await transport.send(payload)
    }

    func makeJSONRPCPayload(
        id: MCPJSONValue?,
        method: String,
        params: MCPJSONValue?
    ) throws -> Data {
        var object: [String: MCPJSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let id {
            object["id"] = id
        }
        if let params {
            object["params"] = params
        }
        return try JSONSerialization.data(withJSONObject: MCPJSONValue.object(object).foundationObject)
    }

    func makeJSONRPCResponse(
        id: MCPJSONValue,
        result: MCPJSONValue? = nil,
        error: MCPJSONValue? = nil
    ) throws -> Data {
        var object: [String: MCPJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id,
        ]
        if let error {
            object["error"] = error
        } else {
            object["result"] = result ?? .null
        }
        return try JSONSerialization.data(withJSONObject: MCPJSONValue.object(object).foundationObject)
    }

    func parseJSONObject(_ data: Data) throws -> [String: MCPJSONValue] {
        let raw = try JSONSerialization.jsonObject(with: data)
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
