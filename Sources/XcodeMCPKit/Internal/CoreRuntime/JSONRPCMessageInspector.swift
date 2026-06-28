import Foundation

extension JSONRPC {
    package enum Message {
        package enum Kind: Sendable {
            case request(method: String, id: JSONRPC.ID)
            case notification(method: String)
            case response(id: JSONRPC.ID)
            case malformed(id: JSONRPC.ID?)
            case other

            package var requestID: JSONRPC.ID? {
                guard case .request(_, let id) = self else { return nil }
                return id
            }

            package var responseID: JSONRPC.ID? {
                guard case .response(let id) = self else { return nil }
                return id
            }

            package var malformedID: JSONRPC.ID? {
                guard case .malformed(let id) = self else { return nil }
                return id
            }

            package var responseCorrelationID: JSONRPC.ID? {
                switch self {
                case .response(let id):
                    return id
                case .malformed(let id):
                    return id
                case .request, .notification, .other:
                    return nil
                }
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

        package enum Inspector {
            package static func kind(of object: [String: Any]) -> JSONRPC.Message.Kind {
                let rawID = object["id"]
                let parsedID = rawID.flatMap { JSONRPC.ID(any: $0) }

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

            package static func requestID(from object: [String: Any]) -> JSONRPC.ID? {
                kind(of: object).requestID
            }

            package static func responseID(from object: [String: Any]) -> JSONRPC.ID? {
                kind(of: object).responseID
            }

            package static func responseCorrelationID(from object: [String: Any]) -> JSONRPC.ID? {
                kind(of: object).responseCorrelationID
            }

            package static func invalidMessageID(from object: [String: Any]) -> JSONRPC.ID? {
                kind(of: object).malformedID
            }

            package static func isResponse(_ object: [String: Any]) -> Bool {
                responseID(from: object) != nil
            }

            package static func requestMetadata(fromParsed json: Any?) -> JSONRPC.Request.Metadata {
                guard let json else {
                    return JSONRPC.Request.Metadata(ids: [], isBatch: false)
                }
                if let object = json as? [String: Any] {
                    return JSONRPC.Request.Metadata(
                        ids: requestID(from: object).map { [$0] } ?? [],
                        isBatch: false
                    )
                }
                if let array = json as? [Any] {
                    let ids = array.compactMap { item -> JSONRPC.ID? in
                        guard let object = item as? [String: Any] else {
                            return nil
                        }
                        return requestID(from: object)
                    }
                    return JSONRPC.Request.Metadata(ids: ids, isBatch: true)
                }
                return JSONRPC.Request.Metadata(ids: [], isBatch: false)
            }
        }
    }

    package enum Request {
        package struct Metadata: Sendable {
            package let ids: [JSONRPC.ID]
            package let isBatch: Bool
        }
    }
}
