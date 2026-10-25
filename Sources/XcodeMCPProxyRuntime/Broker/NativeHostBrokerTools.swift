import Foundation
import XcodeMCPCore
import XcodeMCPWire
import XcodeMCPProxyRuntimeContract

/// A reply that the broker builds before it hands the client the request's JSON-RPC response.
enum NativeBrokerReply: Sendable {
    /// A JSON-RPC response object from a host or the broker.
    case response(Data)
    /// A JSON-RPC error that the broker reports for the request.
    case error(id: JSONRPC.ID?, code: Int, message: String)
    /// A client notification or response, which has no reply.
    case accepted

    /// The error for a host response that is not valid JSON-RPC for its request.
    static func invalidUpstreamResponse(id: JSONRPC.ID? = nil) -> Self {
        .error(id: id, code: -32603, message: "invalid upstream response")
    }

    /// The message HTTP sends to the client.
    var clientReply: ProxyRuntimeReply {
        switch self {
        case .response(let data):
            return .response(data)
        case .error(let id, let code, let message):
            // An error object of a string and numbers always serializes.
            return .response((try? JSONRPC.Wire.errorResponseData(id: id, code: code, message: message)) ?? Data())
        case .accepted:
            return .accepted
        }
    }
}

struct NativeHostBrokerReplyError: Error, CustomStringConvertible {
    let description: String
    let reply: NativeBrokerReply
}

extension NativeHostBroker {
    static var managementTools: [JSONValue] {
        [
            tool(listTool,
                description: "List available Xcode installations. Only needed to choose a non-default installation when opening a workspace.",
                properties: [:]),
            tool(listWorkspacesTool,
                description: "List loaded headless workspaces. Open a saved project, workspace, or Swift package with XcodeOpenWorkspace first. Each workspaceIdentifier names one execution context; use it with workspace tools. Errors identify hosts whose workspaces could not be listed.",
                properties: [:]),
            tool(openWorkspaceTool,
                description: "Open a saved project, workspace, or Swift package in an owned headless host and return its workspaceIdentifier. Defaults to the default Xcode installation. Optionally choose another installation from XcodeMCPKitListHosts. Each installation has one headless host; sessions opening the same path share its model, and each session keeps its own scheme, run destination, and test plan in it.",
                properties: [
                    "path": .object(["type": .string("string"), "description": .string("Absolute project, workspace, or Swift package path.")]),
                    "hostIdentifier": .object(["type": .string("string")]),
                ], required: ["path"]),
            tool(closeWorkspaceTool,
                description: "Close an owned headless workspace, or release this session's reference if another session still uses it.",
                properties: ["workspaceIdentifier": .object(["type": .string("string")])],
                required: ["workspaceIdentifier"]),
        ]
    }

    private static func tool(_ name: String, description: String,
                             properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["name": .string(name), "description": .string(description),
            "inputSchema": .object(["type": .string("object"), "properties": .object(properties),
                                    "required": .array(required.map(JSONValue.string))])])
    }

    static func requestID(_ request: ProxyRuntimeRequest) -> JSONRPC.ID? {
        (request.decodedJSON?.foundationObject as? [String: Any]).flatMap {
            JSONRPC.Message.Inspector.requestID(from: $0)
        }
    }

    static func string(_ value: JSONValue?) -> String? {
        if case .string(let value) = value { value } else { nil }
    }

    static func isToolError(_ value: JSONValue) -> Bool {
        if case .object(let fields) = value, case .bool(true)? = fields["isError"] { true } else { false }
    }

    static func toolPayload(_ result: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let fields) = result else { throw NativeHostBrokerError("Native tool result is not an object") }
        if case .object(let payload)? = fields["structuredContent"] { return payload }
        if case .array(let content)? = fields["content"] {
            for item in content {
                guard case .object(let item) = item, case .string(let text)? = item["text"],
                      let data = text.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      case .object(let payload)? = JSONValue(any: object) else { continue }
                return payload
            }
        }
        throw NativeHostBrokerError("Native tool returned no structured result")
    }

    /// The client's request with another tool name and arguments, keeping its `id` and `_meta`.
    static func toolRequest(_ request: ProxyRuntimeRequest, name: String,
                            arguments: [String: JSONValue]) throws -> JSONValue {
        guard case .object(var object)? = request.decodedJSON else { throw NativeHostBrokerError("Invalid request") }
        var parameters: [String: JSONValue]
        if case .object(let existing)? = object["params"] { parameters = existing } else { parameters = [:] }
        parameters["name"] = .string(name)
        parameters["arguments"] = .object(arguments)
        object["params"] = .object(parameters)
        return .object(object)
    }

    /// The `_meta` key that names the calling MCP session to a headless host.
    static let conversationKey = "com.lynnswap.xcode-mcpkit/conversation"
    /// The `_meta` key of a session's selection in a headless workspace.
    static let selectionKey = "com.lynnswap.xcode-mcpkit/selection"

    /// Adds `fields` to the request's `params._meta`, keeping the client's entries such as its progress token.
    static func addingMetadata(_ fields: [String: JSONValue], to request: JSONValue) -> JSONValue {
        guard case .object(var object) = request, case .object(var parameters)? = object["params"] else { return request }
        var metadata: [String: JSONValue] = [:]
        if case .object(let existing)? = parameters["_meta"] { metadata = existing }
        metadata.merge(fields) { _, new in new }
        parameters["_meta"] = .object(metadata)
        object["params"] = .object(parameters)
        return .object(object)
    }

    /// Removes the host's report of the session's selection from a reply and returns it.
    static func takingSelection(from reply: NativeBrokerReply) throws -> (reply: NativeBrokerReply, selection: JSONValue?) {
        guard case .response(let data) = reply else { return (reply, nil) }
        var object = try JSONRPC.Wire.object(fromData: data)
        guard var result = object["result"] as? [String: Any], var metadata = result["_meta"] as? [String: Any],
              let selection = metadata.removeValue(forKey: selectionKey) else { return (reply, nil) }
        result["_meta"] = metadata.isEmpty ? nil : metadata
        object["result"] = result
        return (.response(try JSONRPC.Wire.data(from: object)),
                JSONValue(any: selection))
    }

    static func rewritePayload(_ payload: JSONValue, workspace: NativeBrokerWorkspace?,
                                deviceSession: NativeBrokerDeviceSession?,
                                launchSession: NativeBrokerLaunchSession? = nil) -> JSONValue {
        guard case .object(var fields) = payload else { return payload }
        if let workspace {
            let nativeKey = "workspaceIdentifier"
            if fields[nativeKey] == .string(workspace.nativeIdentifier) {
                fields.removeValue(forKey: nativeKey)
                fields["workspaceIdentifier"] = .string(workspace.identifier)
            }
        }
        if let deviceSession {
            for key in ["interactionSessionKey", "interactSessionKey"]
                where fields[key] == .string(deviceSession.nativeIdentifier) {
                fields.removeValue(forKey: key)
                fields["interactionSessionKey"] = .string(deviceSession.identifier)
            }
        }
        if let launchSession, fields["launchSessionReference"] == .string(launchSession.nativeIdentifier) {
            fields["launchSessionReference"] = .string(launchSession.identifier)
        }
        return .object(fields)
    }

    static func rewriteReply(_ reply: NativeBrokerReply, workspace: NativeBrokerWorkspace?,
                             deviceSession: NativeBrokerDeviceSession?,
                             launchSession: NativeBrokerLaunchSession? = nil,
                             toolName: String? = nil) throws -> NativeBrokerReply {
        guard workspace != nil || deviceSession != nil || launchSession != nil || toolName == "RenderPreview",
              case .response(let data) = reply else { return reply }
        var object = try JSONRPC.Wire.object(fromData: data)
        guard var result = object["result"] as? [String: Any] else { return reply }
        if let raw = result["structuredContent"], let payload = JSONValue(any: raw) {
            result["structuredContent"] = rewritePayload(XcodeToolCatalog.publicPayload(name: toolName ?? "", payload: payload), workspace: workspace,
                                                         deviceSession: deviceSession, launchSession: launchSession).foundationObject
        }
        if let content = result["content"] as? [[String: Any]] {
            result["content"] = try content.map { item in
                guard let text = item["text"] as? String, let data = text.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let payload = JSONValue(any: object) else { return item }
                var rewritten = item
                rewritten["text"] = String(decoding: try JSONSerialization.data(
                    withJSONObject: rewritePayload(XcodeToolCatalog.publicPayload(name: toolName ?? "", payload: payload), workspace: workspace,
                        deviceSession: deviceSession, launchSession: launchSession).foundationObject, options: [.sortedKeys]), as: UTF8.self)
                return rewritten
            }
        }
        object["result"] = result
        return .response(try JSONRPC.Wire.data(from: object))
    }

    static func cancellationID(from raw: Any?) -> JSONRPC.ID? {
        guard let raw, let value = JSONValue(any: raw) else { return nil }
        switch value {
        case .string, .number: return JSONRPC.ID(any: raw)
        case .array, .object, .bool, .null: return nil
        }
    }

    static func toolName(in request: ProxyRuntimeRequest) -> String? {
        guard case .object(let object)? = request.decodedJSON,
              case .object(let parameters)? = object["params"],
              case .string(let name)? = parameters["name"] else { return nil }
        return name
    }

    static func toolResult(_ result: JSONValue, isError: Bool = false) throws -> JSONValue {
        let text = String(decoding: try JSONSerialization.data(
            withJSONObject: result.foundationObject, options: [.sortedKeys]), as: UTF8.self)
        return .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "structuredContent": result,
            "isError": .bool(isError),
        ])
    }

    static func response(id: JSONRPC.ID?, result: JSONValue) throws -> NativeBrokerReply {
        .response(try JSONRPC.Wire.data(from: JSONRPC.Wire.resultResponseObject(
            idValue: id?.value, result: result)))
    }

    static func result(in reply: NativeBrokerReply) throws -> JSONValue {
        switch reply {
        case .response(let data):
            let object = try JSONRPC.Wire.object(fromData: data)
            if let error = object["error"] as? [String: Any] {
                throw NativeHostBrokerReplyError(description: "Native request failed: \(error)", reply: reply)
            }
            guard let value = object["result"], let result = JSONValue(any: value) else {
                throw NativeHostBrokerError("Native reply has no result")
            }
            return result
        case .error(_, let code, let message):
            throw NativeHostBrokerReplyError(description: "Native request failed (\(code)): \(message)", reply: reply)
        case .accepted:
            throw NativeHostBrokerError("Native request did not return a response")
        }
    }

    static func externalReply(_ reply: NativeBrokerReply, hostIdentifier: String? = nil,
                              requestID: JSONRPC.ID? = nil) throws -> NativeBrokerReply {
        switch reply {
        case .response(let data):
            var object = try JSONRPC.Wire.object(fromData: data)
            if let requestID { object["id"] = requestID.value.foundationObject }
            if let hostIdentifier, var result = object["result"] as? [String: Any] {
                var metadata = result["_meta"] as? [String: Any] ?? [:]
                metadata["com.lynnswap.xcode-mcpkit/hostIdentifier"] = hostIdentifier
                result["_meta"] = metadata
                object["result"] = result
            }
            return .response(try JSONRPC.Wire.data(from: object))
        case .error(let id, let code, let message):
            return .error(id: requestID ?? id, code: code, message: message)
        case .accepted: return .accepted
        }
    }
}
