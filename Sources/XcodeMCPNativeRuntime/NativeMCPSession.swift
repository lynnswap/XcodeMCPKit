import Foundation
import XcodeMCPWire

@MainActor
package final class NativeMCPSession {
    private let backend: any NativeToolBackend
    private let output: @MainActor (Data) throws -> Void
    package var onOutputFailure: (@MainActor (any Error) -> Void)?
    private let artifactsRoot: URL
    private let conversationID = UUID().uuidString
    private var initialized = false
    private var stopping = false
    private var outputFailed = false
    private var requests: [String: Task<Void, Never>] = [:]

    package init(backend: any NativeToolBackend, artifactsRoot: URL,
                 output: @escaping @MainActor (Data) throws -> Void) {
        self.backend = backend
        self.artifactsRoot = artifactsRoot
        self.output = output
    }

    package func receive(_ data: Data) throws {
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
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
            requests[id.key] = Task { @MainActor in
                defer { requests[id.key] = nil }
                do {
                    try Task.checkCancellation()
                    let result = try await perform(method, params: params)
                    try Task.checkCancellation()
                    try sendResult(id: id, result: result)
                } catch is CancellationError {
                    reportError(id: id, code: -32800, message: "Request cancelled")
                } catch let error as NativeRuntimeError {
                    let code: Int
                    switch error {
                    case .invalidRequest: code = -32602
                    case .methodNotFound: code = -32601
                    case .unavailable, .unsupportedContract, .invocation: code = -32603
                    }
                    reportError(id: id, code: code, message: error.description)
                } catch {
                    reportError(id: id, code: -32603, message: String(describing: error))
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

    private func perform(_ method: String, params: JSONValue?) async throws -> JSONValue {
        if method == "initialize" {
            guard case .object(let fields) = params,
                  case .string = fields["protocolVersion"],
                  case .object = fields["capabilities"],
                  case .object(let clientInfo) = fields["clientInfo"],
                  case .string = clientInfo["name"], case .string = clientInfo["version"] else {
                throw NativeRuntimeError.invalidRequest("initialize requires protocolVersion, capabilities and clientInfo name/version")
            }
            initialized = true
            return .object([
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
            return .object(["tools": .array(tools.map(\.descriptor))])
        case "tools/call":
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
            let directory = artifactsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let context = NativeToolContext(artifactsDirectory: directory, conversationID: conversationID)
            let updates: AsyncStream<Data>
            do {
                updates = try await backend.execute(name, arguments: arguments, context: context)
            } catch let error as NativeToolExecutionError {
                try Task.checkCancellation()
                return try toolResult(.string(error.message), isError: true)
            }
            var completed: JSONValue?
            for await data in updates {
                guard let event = JSONValue(any: try JSONSerialization.jsonObject(with: data)),
                      case .object(let fields) = event, case .string(let type) = fields["type"] else {
                    throw NativeRuntimeError.unsupportedContract("Native action emitted an unsupported event")
                }
                backend.observe(toolName: name, arguments: arguments, event: event)
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
                    completed = try toolResult(result, isError: false)
                case "error":
                    completed = try toolResult(fields["data"] ?? .string("Native tool failed"), isError: true)
                default:
                    throw NativeRuntimeError.unsupportedContract("Unsupported native event '\(type)'")
                }
            }
            try Task.checkCancellation()
            guard let completed else { throw NativeRuntimeError.invocation("Native action ended without a completion result") }
            return completed
        default:
            throw NativeRuntimeError.methodNotFound("Unsupported MCP method '\(method)'")
        }
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
        catch { FileHandle.standardError.write(Data(("Native MCP output failed: \(error)\n").utf8)) }
    }

    private func send(_ value: JSONValue) throws {
        try write(JSONRPC.Wire.data(from: value.foundationObject))
    }

    private func write(_ data: Data) throws {
        do { try output(data) }
        catch {
            if !outputFailed {
                outputFailed = true
                stopping = true
                onOutputFailure?(error)
            }
            throw error
        }
    }

    package func shutdown() async throws {
        stopping = true
        let pending = Array(requests.values)
        for request in pending { request.cancel() }
        for request in pending { await request.value }
        try await backend.shutdown()
    }
}
