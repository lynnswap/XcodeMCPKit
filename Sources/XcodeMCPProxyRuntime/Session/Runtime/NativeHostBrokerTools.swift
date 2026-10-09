import Foundation
import XcodeMCPCore
import XcodeMCPProxyRuntimeContract

extension NativeHostBroker {
    static var managementTools: [JSONValue] {
        [
            .object([
                "name": .string(listTool),
                "description": .string("List native Xcode hosts and installed Xcode candidates. Shows host identities, the terminal-default host, and the host selected for this MCP session. Listing does not launch all hosts."),
                "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
            ]),
            .object([
                "name": .string(selectTool),
                "description": .string("Select a host returned by XcodeMCPKitListHosts for this MCP session. Starts an available candidate when needed. Set createsNewHost to true to create an independent instance using that host's Xcode installation. Other sessions and already admitted requests retain their hosts."),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "hostIdentifier": .object(["type": .string("string")]),
                        "createsNewHost": .object(["type": .string("boolean"), "default": .bool(false)]),
                    ]),
                    "required": .array([.string("hostIdentifier")]),
                ]),
            ]),
        ]
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
                throw NativeHostBrokerError("Native request failed: \(error)")
            }
            guard let value = object["result"], let result = JSONValue(any: value) else {
                throw NativeHostBrokerError("Native reply has no result")
            }
            return result
        case .mcpError(_, let code, let message, _, _):
            throw NativeHostBrokerError("Native request failed (\(code)): \(message)")
        case .failure(_, let message, _):
            throw NativeHostBrokerError(message)
        case .accepted:
            throw NativeHostBrokerError("Native request did not return a response")
        }
    }

    static func externalReply(_ reply: ProxyRuntimeReply, session: ProxySessionID,
                              hostIdentifier: String? = nil) throws -> ProxyRuntimeReply {
        switch reply {
        case .response(let data, _, let stream):
            var object = try JSONRPC.Wire.object(fromData: data)
            if let hostIdentifier, var result = object["result"] as? [String: Any] {
                var metadata = result["_meta"] as? [String: Any] ?? [:]
                metadata["com.lynnswap.xcode-mcpkit/hostIdentifier"] = hostIdentifier
                result["_meta"] = metadata
                object["result"] = result
            }
            return .response(data: try JSONRPC.Wire.data(from: object),
                             sessionID: session, prefersEventStream: stream)
        case .mcpError(let id, let code, let message, _, let stream):
            return .mcpError(id: id, code: code, message: message, sessionID: session, prefersEventStream: stream)
        case .failure(let kind, let message, _):
            return .failure(kind: kind, message: message, sessionID: session)
        case .accepted: return .accepted(sessionID: session)
        }
    }
}
