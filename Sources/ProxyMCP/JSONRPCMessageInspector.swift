import Foundation

package enum JSONRPCMessageKind: Sendable {
    case request(method: String, id: RPCID)
    case notification(method: String)
    case response(id: RPCID)
    case malformed(id: RPCID?)
    case other

    package var requestID: RPCID? {
        guard case .request(_, let id) = self else { return nil }
        return id
    }

    package var responseID: RPCID? {
        guard case .response(let id) = self else { return nil }
        return id
    }

    package var malformedID: RPCID? {
        guard case .malformed(let id) = self else { return nil }
        return id
    }

    package var isServerInitiated: Bool {
        switch self {
        case .request, .notification:
            return true
        case .response, .malformed, .other:
            return false
        }
    }
}

package struct JSONRPCRequestMetadata: Sendable {
    package let ids: [RPCID]
    package let isBatch: Bool
}

package enum JSONRPCMessageInspector {
    package static func kind(of object: [String: Any]) -> JSONRPCMessageKind {
        let rawID = object["id"]
        let parsedID = rawID.flatMap { RPCID(any: $0) }

        if let methodValue = object["method"] {
            guard let method = methodValue as? String else {
                return .malformed(id: parsedID)
            }
            guard rawID != nil else {
                return .notification(method: method)
            }
            guard let parsedID else {
                return .notification(method: method)
            }
            return .request(method: method, id: parsedID)
        }

        guard let id = parsedID,
            object["result"] != nil || object["error"] != nil
        else {
            if rawID != nil {
                return .malformed(id: parsedID)
            }
            return .other
        }
        return .response(id: id)
    }

    package static func method(from object: [String: Any]) -> String? {
        switch kind(of: object) {
        case .request(let method, _), .notification(let method):
            return method
        case .response, .malformed, .other:
            return nil
        }
    }

    package static func requestID(from object: [String: Any]) -> RPCID? {
        kind(of: object).requestID
    }

    package static func responseID(from object: [String: Any]) -> RPCID? {
        kind(of: object).responseID
    }

    package static func invalidMessageID(from object: [String: Any]) -> RPCID? {
        kind(of: object).malformedID
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
