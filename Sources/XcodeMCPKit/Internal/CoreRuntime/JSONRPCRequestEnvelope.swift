import Foundation

extension JSONRPC.Request {
    package struct Envelope: Sendable {
        package let method: String?
        package let ids: [JSONValue]
        package let isBatch: Bool

        package var expectsResponse: Bool {
            !ids.isEmpty
        }

        package init(method: String?, ids: [JSONValue], isBatch: Bool) {
            self.method = method
            self.ids = ids
            self.isBatch = isBatch
        }

        package static func inspect(_ data: Data) -> Self {
            inspect(parsed: try? JSONSerialization.jsonObject(with: data, options: []))
        }

        package static func inspect(parsed json: Any?) -> Self {
            guard let json else {
                return Envelope(method: nil, ids: [], isBatch: false)
            }
            if let object = json as? [String: Any] {
                let method = JSONRPC.Message.Inspector.method(from: object)
                let ids = JSONRPC.Message.Inspector.requestID(from: object).map {
                    [$0.value]
                } ?? []
                return Envelope(method: method, ids: ids, isBatch: false)
            }
            if let array = json as? [Any] {
                let ids = array.compactMap { item -> JSONValue? in
                    guard let object = item as? [String: Any] else {
                        return nil
                    }
                    return JSONRPC.Message.Inspector.requestID(from: object)?.value
                }
                return Envelope(method: nil, ids: ids, isBatch: true)
            }
            return Envelope(method: nil, ids: [], isBatch: false)
        }
    }
}
