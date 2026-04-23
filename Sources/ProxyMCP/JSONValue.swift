import Foundation

package enum JSONNumber: Sendable {
    case int(Int64)
    case double(Double)

    package init(_ number: NSNumber) {
        if CFNumberIsFloatType(number) {
            self = .double(number.doubleValue)
        } else {
            self = .int(number.int64Value)
        }
    }

    package var stringValue: String {
        switch self {
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        }
    }

    package var foundationObject: NSNumber {
        switch self {
        case .int(let value):
            return NSNumber(value: value)
        case .double(let value):
            return NSNumber(value: value)
        }
    }
}

package enum JSONValue: Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(JSONNumber)
    case bool(Bool)
    case null

    package init?(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(JSONNumber(number))
            }
        case let array as [Any]:
            var values: [JSONValue] = []
            values.reserveCapacity(array.count)
            for item in array {
                guard let value = JSONValue(any: item) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let object as [String: Any]:
            var values: [String: JSONValue] = [:]
            values.reserveCapacity(object.count)
            for (key, value) in object {
                guard let mapped = JSONValue(any: value) else { return nil }
                values[key] = mapped
            }
            self = .object(values)
        default:
            return nil
        }
    }

    package var foundationObject: Any {
        switch self {
        case .object(let values):
            return values.mapValues { $0.foundationObject }
        case .array(let values):
            return values.map { $0.foundationObject }
        case .string(let value):
            return value
        case .number(let value):
            return value.foundationObject
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }
}

package struct RPCID: Sendable {
    package let key: String
    package let value: JSONValue

    package init?(any: Any) {
        guard !(any is NSNull) else { return nil }

        if let string = any as? String {
            key = string
            value = .string(string)
            return
        }

        if let number = any as? NSNumber {
            key = number.stringValue
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                value = .bool(number.boolValue)
            } else {
                value = .number(JSONNumber(number))
            }
            return
        }

        let fallbackKey = String(describing: any)
        key = fallbackKey
        value = JSONValue(any: any) ?? .string(fallbackKey)
    }
}
