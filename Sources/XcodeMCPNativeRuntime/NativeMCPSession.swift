import Foundation
import XcodeMCPWire

package actor NativeMCPSession {
    private let backend: any NativeToolBackend
    private let output: @Sendable (Data) throws -> Void
    private var onFailure: (@Sendable (any Error) -> Void)?
    private var failed = false
    private var shutdownTask: Task<Void, any Error>?
    private let artifactsRoot: URL
    private let crashCacheRoot: URL
    private let executionQueue: NativeExecutionQueue
    /// The `_meta` key that names the calling MCP session.
    package static let conversationKey = "com.lynnswap.xcode-mcpkit/conversation"
    /// Used when a request does not name its session.
    private let conversationID = UUID().uuidString
    private var initialized = false
    private var stopping = false
    private var requests: [String: Task<Void, Never>] = [:]

    package init(backend: any NativeToolBackend, artifactsRoot: URL,
                 maximumConcurrentOperations: Int = 4, maximumHeavyOperations: Int = 1,
                 maximumQueuedBytes: Int = 32 * 1024 * 1024,
                 crashCacheRoot: URL? = nil,
                 output: @escaping @Sendable (Data) throws -> Void) {
        self.backend = backend
        self.artifactsRoot = artifactsRoot
        self.crashCacheRoot = crashCacheRoot ?? artifactsRoot.appendingPathComponent("CrashCache", isDirectory: true)
        self.output = output
        executionQueue = NativeExecutionQueue(maximumConcurrentOperations: maximumConcurrentOperations,
            maximumHeavyOperations: maximumHeavyOperations, maximumQueuedBytes: maximumQueuedBytes)
    }

    /// Receives the first failure after which this process cannot serve requests: MCP output
    /// failed, or Xcode's state in this process is no longer reliable. The owner shuts down.
    package func setFailureHandler(_ handler: (@Sendable (any Error) -> Void)?) {
        onFailure = handler
    }

    package func receive(_ messages: [Data]) throws {
        for message in messages { try receive(message) }
    }

    package func receive(_ data: Data) throws {
        let value: Any
        do {
            value = try StdioFramer.jsonObject(from: data)
        }
        catch {
            try sendError(id: nil, code: -32700, message: "Invalid JSON")
            return
        }
        guard let object = value as? [String: Any] else {
            try sendError(id: nil, code: -32600, message: "JSON-RPC messages must be objects")
            return
        }
        let id = requestID(object["id"])
        guard object["jsonrpc"] as? String == "2.0", object["id"] == nil || id != nil else {
            try sendError(id: id, code: -32600, message: "Invalid JSON-RPC envelope")
            return
        }
        let kind = JSONRPC.Message.Inspector.kind(of: object)
        switch kind {
        case .notification(let method):
            if method == "notifications/cancelled",
               let parameters = object["params"] as? [String: Any],
               let id = requestID(parameters["requestId"]) {
                requests[id.key]?.cancel()
            }
        case .request(let method, let id):
            guard !stopping else {
                try sendError(id: id, code: -32000, message: "Native host is shutting down")
                return
            }
            guard requests[id.key] == nil else {
                try sendError(id: id, code: -32600, message: "Request ID is already in use")
                return
            }
            let params = object["params"].flatMap(JSONValue.init(any:))
            let requestBytes = data.count
            requests[id.key] = Task {
                do {
                    try Task.checkCancellation()
                    let result = try await perform(method, params: params, requestBytes: requestBytes)
                    try Task.checkCancellation()
                    try sendResult(id: id, result: result)
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        let message = error is CancellationError ? "Request cancelled" : "Request cancelled: \(error)"
                        reportError(id: id, code: -32800, message: message)
                    } else if let error = error as? NativeRuntimeError {
                        let code: Int
                        switch error {
                        case .invalidRequest: code = -32602
                        case .methodNotFound: code = -32601
                        case .unavailable, .unsupportedContract, .invocation: code = -32603
                        }
                        reportError(id: id, code: code, message: error.description)
                    } else {
                        reportError(id: id, code: -32603, message: String(describing: error))
                    }
                }
                // The client may reuse the ID as soon as it reads the reply.
                requests[id.key] = nil
                // The reply above reports the failure to its caller; later callers need a new process.
                if let failure = await backend.processFailure {
                    fail(NativeRuntimeError.unavailable("The native host cannot continue: \(failure)"))
                }
            }
        case .malformed(let id):
            try sendError(id: id, code: -32600, message: "Invalid JSON-RPC request")
        case .other:
            try sendError(id: nil, code: -32600, message: "Invalid JSON-RPC request")
        case .response:
            break
        }
    }

    private func requestID(_ raw: Any?) -> JSONRPC.ID? {
        guard let raw, let value = JSONValue(any: raw) else { return nil }
        switch value {
        case .string, .number: return JSONRPC.ID(any: raw)
        case .object, .array, .bool, .null: return nil
        }
    }

    private func perform(_ method: String, params: JSONValue?, requestBytes: Int) async throws -> JSONValue {
        if method == "initialize" {
            guard case .object(let fields) = params,
                  case .string = fields["protocolVersion"],
                  case .object = fields["capabilities"],
                  case .object(let clientInfo) = fields["clientInfo"],
                  case .string = clientInfo["name"], case .string = clientInfo["version"] else {
                throw NativeRuntimeError.invalidRequest("initialize requires protocolVersion, capabilities and clientInfo name/version")
            }
            initialized = true
            return await withOrigin([
                "protocolVersion": .string(MCPProtocolVersion.current),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("XcodeMCPKit Native Host"), "version": .string("1")]),
            ])
        }
        if method == "ping" { return .object([:]) }
        guard initialized else { throw NativeRuntimeError.invalidRequest("Initialize the native MCP session first") }
        switch method {
        case "tools/list":
            let tools = try await backend.listTools()
            return await withOrigin(["tools": .array(tools.map(\.descriptor))])
        case "tools/call":
            let capture = NativeErrorPresentation.Capture()
            return try await NativeErrorPresentation.$capture.withValue(capture) {
                await capture.addingDiagnostics(to: try await performTool(params: params, requestBytes: requestBytes))
            }
        default:
            throw NativeRuntimeError.methodNotFound("Unsupported MCP method '\(method)'")
        }
    }

    private func performTool(params: JSONValue?, requestBytes: Int) async throws -> JSONValue {
        guard case .object(let fields) = params, case .string(let name) = fields["name"] else {
            throw NativeRuntimeError.invalidRequest("tools/call requires a tool name")
        }
        var arguments: [String: JSONValue] = [:]
        if let value = fields["arguments"] {
            guard case .object(let object) = value else {
                throw NativeRuntimeError.invalidRequest("Tool arguments must be an object")
            }
            arguments = object
        }
        try Task.checkCancellation()
        let resource = try await backend.executionResource(for: name, arguments: arguments)
        let permit = try await executionQueue.acquire(resource, requestBytes: requestBytes)
        do {
            try Task.checkCancellation()
            let result = try await executeTool(params: params, name: name, arguments: arguments, resource: resource)
            await executionQueue.release(permit)
            return result
        } catch {
            await executionQueue.release(permit)
            throw error
        }
    }

    private func executeTool(params: JSONValue?, name: String, arguments: [String: JSONValue],
                             resource: NativeExecutionResource) async throws -> JSONValue {
        let directory = artifactsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The proxy identifies the calling MCP session and its selection for a headless workspace.
        var metadata: [String: JSONValue] = [:]
        if case .object(let fields)? = fieldsForMetadata(params) { metadata = fields }
        // Results can name files in the directory, so only a directory nothing was written to is removed.
        defer {
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let context = NativeToolContext(
            artifactsDirectory: directory, artifactsRoot: artifactsRoot,
            conversationID: NativeWorkspaceSelection.string(metadata[Self.conversationKey]) ?? conversationID,
            selection: NativeWorkspaceSelection(json: metadata[NativeWorkspaceSelection.metadataKey]),
            executionResource: resource, crashCacheRoot: crashCacheRoot)
        return try await NativeExecutionOperations.$scope.withValue(context.executionScope) {
            try await withTaskCancellationHandler {
                try await executeTool(params: params, name: name, arguments: arguments, context: context)
            } onCancel: {
                context.executionScope.cancel()
            }
        }
    }

    private func executeTool(params: JSONValue?, name: String, arguments: [String: JSONValue],
                             context: NativeToolContext) async throws -> JSONValue {
        do {
            let result = try await consumeTool(params: params, name: name, arguments: arguments, context: context)
            do { try await backend.finishExecution(context: context) }
            catch { await NativeErrorPresentation.report(error as NSError) }
            return result
        } catch {
            let original = error
            do { try await backend.finishExecution(context: context) }
            catch {
                throw NativeRuntimeError.invocation("\(original); workspace cleanup failed: \(error)")
            }
            throw original
        }
    }

    private func consumeTool(params: JSONValue?, name: String, arguments: [String: JSONValue],
                             context: NativeToolContext) async throws -> JSONValue {
        let updates: AsyncStream<Data>
        do {
            updates = try await backend.execute(name, arguments: arguments, context: context)
        } catch let error as NativeToolExecutionError {
            try Task.checkCancellation()
            return try toolResult(.string(error.message), isError: true)
        }
        var completed: JSONValue?
        var output: JSONValue?
        for await data in updates {
            guard let event = JSONValue(any: try JSONSerialization.jsonObject(with: data)),
                  case .object(let fields) = event, case .string(let type) = fields["type"] else {
                throw NativeRuntimeError.unsupportedContract("Native action emitted an unsupported event")
            }
            try Task.checkCancellation()
            switch type {
            case "update":
                if case .object(let metadata) = fieldsForMetadata(params), let token = metadata["progressToken"],
                   requestID(token.foundationObject) != nil,
                   case .object(var progress) = fields["data"] {
                    progress["progressToken"] = token
                    try send(.object([
                        "jsonrpc": .string("2.0"), "method": .string("notifications/progress"),
                        "params": .object(progress),
                    ]))
                }
            case "completed":
                guard let result = fields["data"] else {
                    throw NativeRuntimeError.unsupportedContract("Native completion has no output")
                }
                output = result
                completed = try toolResult(result, isError: false)
            case "error":
                completed = try toolResult(fields["data"] ?? .string("Native tool failed"), isError: true)
            default:
                throw NativeRuntimeError.unsupportedContract("Unsupported native event '\(type)'")
            }
        }
        try Task.checkCancellation()
        guard case .object(var result)? = completed else {
            throw NativeRuntimeError.invocation("Native action ended without a completion result")
        }
        let metadata = await backend.resultMetadata(for: name, output: output, context: context)
        if !metadata.isEmpty { result["_meta"] = .object(metadata) }
        return .object(result)
    }

    private func withOrigin(_ fields: [String: JSONValue]) async -> JSONValue {
        var result = fields
        if let origin = await backend.origin {
            result["_meta"] = .object(["com.lynnswap.xcode-mcpkit/origin": .object(origin)])
        }
        return .object(result)
    }

    private func fieldsForMetadata(_ params: JSONValue?) -> JSONValue? {
        guard case .object(let fields) = params else { return nil }
        return fields["_meta"]
    }

    private func toolResult(_ data: JSONValue, isError: Bool) throws -> JSONValue {
        let text: String
        if case .string(let message) = data {
            text = message
        } else {
            let encoded = try JSONSerialization.data(withJSONObject: data.foundationObject, options: [.fragmentsAllowed, .sortedKeys])
            text = String(decoding: encoded, as: UTF8.self)
        }
        var result: [String: JSONValue] = [
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ]
        if case .object = data { result["structuredContent"] = data }
        return .object(result)
    }

    private func sendResult(id: JSONRPC.ID, result: JSONValue) throws {
        try write(JSONRPC.Wire.data(from: JSONRPC.Wire.resultResponseObject(id: id, result: result)))
    }

    private func sendError(id: JSONRPC.ID?, code: Int, message: String) throws {
        try write(JSONRPC.Wire.data(from: JSONRPC.Wire.errorResponseObject(id: id, code: code, message: message)))
    }

    private func reportError(id: JSONRPC.ID, code: Int, message: String) {
        do { try sendError(id: id, code: code, message: message) }
        catch {
            // The parent can close stderr with stdout; diagnostics must not interrupt cleanup.
            NativeHostDiagnostic.report("Native MCP output failed: \(error)")
        }
    }

    private func send(_ value: JSONValue) throws {
        try write(JSONRPC.Wire.data(from: value.foundationObject))
    }

    private func write(_ data: Data) throws {
        do { try output(data) }
        catch {
            fail(error)
            throw error
        }
    }

    private func fail(_ error: any Error) {
        stopping = true
        guard !failed else { return }
        failed = true
        onFailure?(error)
    }

    /// Cancels requests, waits for them, and releases native resources. Concurrent and repeated
    /// calls share the first shutdown and its result.
    package func shutdown() async throws {
        if let shutdownTask { return try await shutdownTask.value }
        stopping = true
        let task = Task {
            let pending = Array(requests.values)
            for request in pending { request.cancel() }
            await executionQueue.shutdown()
            await backend.beginShutdown()
            for request in pending { await request.value }
            try await backend.shutdown()
        }
        shutdownTask = task
        try await task.value
    }
}
