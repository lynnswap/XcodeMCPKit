import Foundation

package enum JSONRPCMessageKind: Sendable {
    case request(method: String, id: RPCID)
    case notification(method: String)
    case response(id: RPCID)
    case invalidOrOther
}

package struct JSONRPCRequestMetadata: Sendable {
    package let ids: [RPCID]
    package let isBatch: Bool
}

package enum JSONRPCMessageInspector {
    package static func kind(of object: [String: Any]) -> JSONRPCMessageKind {
        if let method = object["method"] as? String {
            guard let idValue = object["id"],
                let id = RPCID(any: idValue)
            else {
                return .notification(method: method)
            }
            return .request(method: method, id: id)
        }

        guard object["method"] == nil,
            let idValue = object["id"],
            let id = RPCID(any: idValue),
            object["result"] != nil || object["error"] != nil
        else {
            return .invalidOrOther
        }
        return .response(id: id)
    }

    package static func method(from object: [String: Any]) -> String? {
        switch kind(of: object) {
        case .request(let method, _), .notification(let method):
            return method
        case .response, .invalidOrOther:
            return nil
        }
    }

    package static func requestID(from object: [String: Any]) -> RPCID? {
        guard case .request(_, let id) = kind(of: object) else {
            return nil
        }
        return id
    }

    package static func responseID(from object: [String: Any]) -> RPCID? {
        guard case .response(let id) = kind(of: object) else {
            return nil
        }
        return id
    }

    package static func isResponse(_ object: [String: Any]) -> Bool {
        responseID(from: object) != nil
    }

    package static func requestMetadata(fromParsed json: Any?) -> JSONRPCRequestMetadata {
        guard let json else {
            return JSONRPCRequestMetadata(ids: [], isBatch: false)
        }
        if let object = json as? [String: Any] {
            return JSONRPCRequestMetadata(
                ids: requestID(from: object).map { [$0] } ?? [],
                isBatch: false
            )
        }
        if let array = json as? [Any] {
            let ids = array.compactMap { item -> RPCID? in
                guard let object = item as? [String: Any] else {
                    return nil
                }
                return requestID(from: object)
            }
            return JSONRPCRequestMetadata(ids: ids, isBatch: true)
        }
        return JSONRPCRequestMetadata(ids: [], isBatch: false)
    }
}
