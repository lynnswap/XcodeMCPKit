import Foundation
import XcodeMCPCore
import XcodeMCPProxyRuntimeContract

struct NativeHostBrokerReplyError: Error, CustomStringConvertible {
    let description: String
    let reply: ProxyRuntimeReply
}

extension NativeHostBroker {
    static var managementTools: [JSONValue] {
        [
            tool(listTool,
                description: "List available Xcode installations and running GUI hosts. Only needed to choose a non-default host when opening a workspace.",
                properties: [:]),
            tool(listWorkspacesTool,
                description: "List headless workspaces and open Xcode windows. Each workspaceIdentifier names one execution context; use it with workspace tools. Errors identify hosts whose workspaces could not be listed.",
                properties: [:]),
            tool(openWorkspaceTool,
                description: "Open a saved project, workspace, or Swift package and return its workspaceIdentifier. Defaults to the default installation's headless host. Optionally choose a host from XcodeMCPKitListHosts; a GUI host attaches an already open window. Each installation has one headless host; sessions opening the same path share its model, scheme, run destination, and test plan.",
                properties: [
                    "path": .object(["type": .string("string"), "description": .string("Absolute project, workspace, or Swift package path.")]),
                    "hostIdentifier": .object(["type": .string("string")]),
                ], required: ["path"]),
            tool(closeWorkspaceTool,
                description: "Close an owned headless workspace, or release a GUI workspace reference while leaving its Xcode window open.",
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

    static func rewritePayload(_ payload: JSONValue, workspace: NativeBrokerWorkspace?,
                                deviceSession: NativeBrokerDeviceSession?,
                                launchSession: NativeBrokerLaunchSession? = nil) -> JSONValue {
        guard case .object(var fields) = payload else { return payload }
        if let workspace {
            let nativeKey = workspace.gui ? "tabIdentifier" : "workspaceIdentifier"
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

    static func rewriteReply(_ reply: ProxyRuntimeReply, workspace: NativeBrokerWorkspace?,
                             deviceSession: NativeBrokerDeviceSession?,
                             launchSession: NativeBrokerLaunchSession? = nil,
                             toolName: String? = nil) throws -> ProxyRuntimeReply {
        guard workspace != nil || deviceSession != nil || launchSession != nil || toolName == "RenderPreview",
              case .response(let data, let session, let stream) = reply else { return reply }
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
        return .response(data: try JSONRPC.Wire.data(from: object), sessionID: session, prefersEventStream: stream)
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

    static func response(id: JSONRPC.ID?, result: JSONValue,
                         session: ProxySessionID, eventStream: Bool) throws -> ProxyRuntimeReply {
        .response(data: try JSONRPC.Wire.data(from: JSONRPC.Wire.resultResponseObject(
            idValue: id?.value, result: result)), sessionID: session, prefersEventStream: eventStream)
    }

    static func result(in reply: ProxyRuntimeReply) throws -> JSONValue {
        switch reply {
        case .response(let data, _, _):
            let object = try JSONRPC.Wire.object(fromData: data)
            if let error = object["error"] as? [String: Any] {
                throw NativeHostBrokerReplyError(description: "Native request failed: \(error)", reply: reply)
            }
            guard let value = object["result"], let result = JSONValue(any: value) else {
                throw NativeHostBrokerError("Native reply has no result")
            }
            return result
        case .mcpError(_, let code, let message, _, _):
            throw NativeHostBrokerReplyError(description: "Native request failed (\(code)): \(message)", reply: reply)
        case .failure(_, let message, _):
            throw NativeHostBrokerReplyError(description: message, reply: reply)
        case .accepted:
            throw NativeHostBrokerError("Native request did not return a response")
        }
    }

    static func externalReply(_ reply: ProxyRuntimeReply, session: ProxySessionID,
                              hostIdentifier: String? = nil, requestID: JSONRPC.ID? = nil) throws -> ProxyRuntimeReply {
        switch reply {
        case .response(let data, _, let stream):
            var object = try JSONRPC.Wire.object(fromData: data)
            if let requestID { object["id"] = requestID.value.foundationObject }
            if let hostIdentifier, var result = object["result"] as? [String: Any] {
                var metadata = result["_meta"] as? [String: Any] ?? [:]
                metadata["com.lynnswap.xcode-mcpkit/hostIdentifier"] = hostIdentifier
                result["_meta"] = metadata
                object["result"] = result
            }
            return .response(data: try JSONRPC.Wire.data(from: object),
                             sessionID: session, prefersEventStream: stream)
        case .mcpError(let id, let code, let message, _, let stream):
            return .mcpError(id: requestID ?? id, code: code, message: message, sessionID: session, prefersEventStream: stream)
        case .failure(let kind, let message, _):
            return .failure(kind: kind, message: message, sessionID: session)
        case .accepted: return .accepted(sessionID: session)
        }
    }
}
