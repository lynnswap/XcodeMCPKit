import Foundation

extension JSONRPC {
    package actor ResponseCompletionTracker {
        private enum ResponseIDKey: Hashable {
            case string(String)
            case int(Int64)
            case double(Double)
        }

        private var remainingIDKeys: Set<ResponseIDKey>

        package init(ids: [JSONValue]) {
            self.remainingIDKeys = Set(ids.compactMap(Self.idKey))
        }

        package init(ids: [JSONRPC.ID]) {
            self.init(ids: ids.map(\.value))
        }

        package func record(_ payload: Data) -> Bool {
            guard remainingIDKeys.isEmpty == false,
                  let json = try? JSONSerialization.jsonObject(with: payload, options: [])
            else {
                return false
            }

            if let object = json as? [String: Any] {
                recordResponseObject(object)
            } else if let array = json as? [Any] {
                for item in array {
                    guard let object = item as? [String: Any] else {
                        continue
                    }
                    recordResponseObject(object)
                }
            }
            return remainingIDKeys.isEmpty
        }

        private func recordResponseObject(_ object: [String: Any]) {
            guard object["method"] == nil,
                  object["result"] != nil || object["error"] != nil,
                  let id = JSONRPC.Message.Inspector.responseID(from: object),
                  let idKey = Self.idKey(id.value)
            else {
                return
            }
            remainingIDKeys.remove(idKey)
        }

        private static func idKey(_ value: JSONValue) -> ResponseIDKey? {
            switch value {
            case .string(let value):
                return .string(value)
            case .number(let value):
                switch value {
                case .int(let value):
                    return .int(value)
                case .double(let value):
                    return .double(value)
                }
            case .object, .array, .bool, .null:
                return nil
            }
        }
    }
}
