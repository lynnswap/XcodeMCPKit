import XcodeMCPCore
import XcodeMCPProcessRuntime
import Foundation

private final class MCPClientPendingRequests: @unchecked Sendable {
    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        var sendTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var requests: [String: PendingRequest] = [:]

    func add(idKey: String, continuation: CheckedContinuation<JSONValue, Error>) {
        lock.withLock {
            requests[idKey] = PendingRequest(continuation: continuation)
        }
    }

    func setSendTask(idKey: String, task: Task<Void, Never>) -> Bool {
        lock.withLock {
            guard requests[idKey] != nil else {
                return false
            }
            requests[idKey]?.sendTask = task
            return true
        }
    }

    func complete(idKey: String, result: JSONValue) {
        let request = lock.withLock {
            requests.removeValue(forKey: idKey)
        }
        request?.sendTask?.cancel()
        request?.continuation.resume(returning: result)
    }

    func fail(idKey: String, error: any Error) {
        let request = lock.withLock {
            requests.removeValue(forKey: idKey)
        }
        request?.sendTask?.cancel()
        request?.continuation.resume(throwing: error)
    }

    func failAll(error: any Error) {
        let pending = lock.withLock {
            let current = requests
            requests.removeAll()
            return current
        }
        for request in pending.values {
            request.sendTask?.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}

package actor InitializedMCPClientSession {
    package struct Configuration: Sendable {
        package var clientName: String
        package var clientVersion: String
        package var capabilities: [String: JSONValue]
        package var requestTimeout: Duration?
        package var clock: ClockClient

        package init(
            clientName: String,
            clientVersion: String,
            capabilities: [String: JSONValue],
            requestTimeout: Duration?,
            clock: ClockClient = .liveValue
        ) {
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.capabilities = capabilities
            self.requestTimeout = requestTimeout
            self.clock = clock
        }
    }

    package typealias ProgressHandler = @Sendable (JSONValue) async -> Void

    private let configuration: Configuration
    private let transport: any XcodeMCPTransport
    private let pendingRequests = MCPClientPendingRequests()
    private var nextRequestID: Int64 = 1
    private var isClosed = false
    private var eventTask: Task<Void, Never>?
    private var progressHandlers: [String: ProgressHandler] = [:]
    private var progressDeliveryTasks: [String: Task<Void, Never>] = [:]

    package init(transport: any XcodeMCPTransport, configuration: Configuration) async throws {
        self.configuration = configuration
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

    isolated deinit {
        eventTask?.cancel()
        let transport = transport
        Task {
            await transport.close()
        }
    }

    package func request(
        _ method: String,
        params: JSONValue? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws -> JSONValue {
        guard method.isEmpty == false else {
            throw MCPBridgeRuntimeError.invalidRequest("method must not be empty")
        }
        try ensureOpen()

        let requestID = nextRequestID
        nextRequestID += 1
        let id = JSONRPC.ID(any: NSNumber(value: requestID))!
        let idKey = id.key

        let progressToken: String?
        let requestParams: JSONValue?
        if let onProgress {
            let token = "xcode-mcp-\(UUID().uuidString)"
            progressToken = token
            requestParams = try paramsByAddingProgressToken(token, to: params)
            progressHandlers[token] = onProgress
        } else {
            progressToken = nil
            requestParams = params
        }

        defer {
            if let progressToken {
                progressHandlers.removeValue(forKey: progressToken)
                progressDeliveryTasks.removeValue(forKey: progressToken)
            }
        }

        let payload = try makeJSONRPCPayload(id: id, method: method, params: requestParams)

        return try await withRequestTimeout(method: method) { [self] in
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.pendingRequests.add(idKey: idKey, continuation: continuation)
                    let sendTask = Task {
                        do {
                            try await self.transport.send(payload)
                        } catch {
                            self.pendingRequests.fail(
                                idKey: idKey,
                                error: Self.runtimeError(from: error)
                            )
                        }
                    }
                    if self.pendingRequests.setSendTask(idKey: idKey, task: sendTask) == false {
                        sendTask.cancel()
                    }
                }
            } onCancel: {
                self.pendingRequests.fail(idKey: idKey, error: CancellationError())
            }
        }
    }

    package func notify(_ method: String, params: JSONValue? = nil) async throws {
        guard method.isEmpty == false else {
            throw MCPBridgeRuntimeError.invalidRequest("method must not be empty")
        }
        try ensureOpen()
        let payload = try makeJSONRPCPayload(id: nil, method: method, params: params)
        do {
            try await transport.send(payload)
        } catch {
            throw Self.runtimeError(from: error)
        }
    }

    package func close() async {
        guard isClosed == false else {
            return
        }
        isClosed = true
        eventTask?.cancel()
        eventTask = nil
        progressHandlers.removeAll()
        cancelProgressDeliveryTasks()
        pendingRequests.failAll(error: MCPBridgeRuntimeError.closed)
        await transport.close()
    }
}

private extension InitializedMCPClientSession {
    static func runtimeError(from error: any Error) -> any Error {
        if let error = error as? MCPBridgeRuntimeError {
            return error
        }
        if error is CancellationError {
            return error
        }
        return MCPBridgeRuntimeError.transportUnavailable(errorDescription(error))
    }

    static func errorDescription(_ error: any Error) -> String {
        let nsError = error as NSError
        if nsError.localizedDescription.isEmpty == false {
            return nsError.localizedDescription
        }
        return String(describing: error)
    }

    func initialize() async throws {
        let result = try await request(
            "initialize",
            params: .object([
                "protocolVersion": .string(MCPProtocolVersion.current),
                "clientInfo": .object([
                    "name": .string(configuration.clientName),
                    "version": .string(configuration.clientVersion),
                ]),
                "capabilities": .object(initializeCapabilities()),
            ])
        )
        try validateInitializeResult(result)
        try await notify("notifications/initialized")
    }

    func validateInitializeResult(_ result: JSONValue) throws {
        guard case .object(let object) = result else {
            throw MCPBridgeRuntimeError.invalidResponse("initialize result is not an object")
        }
        guard case .string(let protocolVersion) = object["protocolVersion"],
              protocolVersion.isEmpty == false else {
            throw MCPBridgeRuntimeError.invalidResponse("initialize result is missing protocolVersion")
        }
        guard MCPProtocolVersion.isSupported(protocolVersion) else {
            throw MCPBridgeRuntimeError.invalidResponse(
                "initialize result has unsupported protocolVersion \(protocolVersion)"
            )
        }
    }

    func initializeCapabilities() -> [String: JSONValue] {
        var capabilities = configuration.capabilities
        capabilities.removeValue(forKey: "roots")
        capabilities.removeValue(forKey: "sampling")
        capabilities.removeValue(forKey: "elicitation")
        return capabilities
    }

    func withRequestTimeout<T: Sendable>(
        method: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let requestTimeout = configuration.requestTimeout else {
            return try await operation()
        }
        let clock = configuration.clock
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                await clock.sleep(requestTimeout)
                try Task.checkCancellation()
                throw MCPBridgeRuntimeError.requestTimedOut(method: method)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func ensureOpen() throws {
        if isClosed {
            throw MCPBridgeRuntimeError.closed
        }
    }

    func handle(_ event: XcodeMCPTransportEvent) async {
        switch event {
        case .message(let data):
            await handleMessage(data)
        case .closed(let reason):
            isClosed = true
            progressHandlers.removeAll()
            cancelProgressDeliveryTasks()
            pendingRequests.failAll(
                error: MCPBridgeRuntimeError.transportUnavailable(reason ?? "mcpbridge closed")
            )
        }
    }

    func handleMessage(_ data: Data) async {
        do {
            let object = try parseJSONObject(data)
            if let id = object["id"], let idKey = jsonRPCIDKey(id) {
                if object["method"]?.stringValue != nil {
                    try await respondToUnsupportedServerRequest(id: id)
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
               let progressToken = params.progressToken,
               let handler = progressHandlers[progressToken]
            {
                let previousDelivery = progressDeliveryTasks[progressToken]
                let delivery = Task {
                    if let previousDelivery {
                        await previousDelivery.value
                    }
                    guard Task.isCancelled == false else {
                        return
                    }
                    await handler(params)
                }
                progressDeliveryTasks[progressToken] = delivery
            }
        } catch {
            pendingRequests.failAll(error: Self.runtimeError(from: error))
        }
    }

    func cancelProgressDeliveryTasks() {
        for task in progressDeliveryTasks.values {
            task.cancel()
        }
        progressDeliveryTasks.removeAll()
    }

    func respondToUnsupportedServerRequest(id: JSONValue) async throws {
        let payload = try JSONRPC.Wire.errorResponseData(
            idValue: id,
            code: -32601,
            message: "Unsupported server request"
        )
        try await transport.send(payload)
    }

    func makeJSONRPCPayload(id: JSONRPC.ID?, method: String, params: JSONValue?) throws -> Data {
        let object: [String: Any]
        if let id {
            object = JSONRPC.Wire.requestObject(id: id, method: method, params: params)
        } else {
            object = JSONRPC.Wire.notificationObject(method: method, params: params)
        }
        return try JSONRPC.Wire.data(from: object)
    }

    func paramsByAddingProgressToken(_ token: String, to params: JSONValue?) throws -> JSONValue {
        guard let params else {
            return .object(["_meta": .object(["progressToken": .string(token)])])
        }
        guard case .object(var object) = params else {
            throw MCPBridgeRuntimeError.invalidRequest("progress requests require object params")
        }
        var meta: [String: JSONValue]
        if case .object(let existingMeta) = object["_meta"] {
            meta = existingMeta
        } else {
            meta = [:]
        }
        meta["progressToken"] = .string(token)
        object["_meta"] = .object(meta)
        return .object(object)
    }

    func parseJSONObject(_ data: Data) throws -> [String: JSONValue] {
        let raw: [String: Any]
        do {
            raw = try JSONRPC.Wire.object(fromData: data)
        } catch JSONRPC.Wire.DecodingFailure.messageWasNotObject {
            throw MCPBridgeRuntimeError.invalidResponse("JSON-RPC message is not an object")
        } catch {
            throw MCPBridgeRuntimeError.invalidResponse(
                "invalid JSON-RPC message: \(Self.errorDescription(error))"
            )
        }
        guard let value = JSONValue(any: raw),
              case .object(let object) = value
        else {
            throw MCPBridgeRuntimeError.invalidResponse("JSON-RPC message is not an object")
        }
        return object
    }

    func jsonRPCIDKey(_ value: JSONValue) -> String? {
        switch value {
        case .string(let value):
            return value
        case .number(let value):
            return value.stringValue
        case .object, .array, .bool, .null:
            return nil
        }
    }

    func parseServerError(_ value: JSONValue) -> MCPBridgeRuntimeError {
        guard case .object(let object) = value else {
            return .invalidResponse("JSON-RPC error is not an object")
        }
        let code: Int
        switch object["code"] {
        case .number(.int(let value)):
            code = Int(value)
        case .number(.double(let value)):
            code = Int(value)
        default:
            code = 0
        }
        let message: String
        if case .string(let value) = object["message"] {
            message = value
        } else {
            message = "MCP server error"
        }
        return .serverError(code: code, message: message, data: object["data"])
    }
}

private extension JSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var progressToken: String? {
        guard case .object(let object) = self,
              case .string(let token) = object["progressToken"]
        else {
            return nil
        }
        return token
    }
}
