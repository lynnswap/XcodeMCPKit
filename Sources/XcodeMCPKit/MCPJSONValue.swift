import Foundation

public enum MCPJSONValue: Codable, Equatable, Sendable {
    case object([String: MCPJSONValue])
    case array([MCPJSONValue])
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([MCPJSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: MCPJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

extension MCPJSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension MCPJSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension MCPJSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) {
        self = .integer(value)
    }
}

extension MCPJSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension MCPJSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: MCPJSONValue...) {
        self = .array(elements)
    }
}

extension MCPJSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, MCPJSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension MCPJSONValue {
    package init?(foundationObject value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .integer(number.int64Value)
            }
        case let array as [Any]:
            var values: [MCPJSONValue] = []
            values.reserveCapacity(array.count)
            for item in array {
                guard let value = MCPJSONValue(foundationObject: item) else {
                    return nil
                }
                values.append(value)
            }
            self = .array(values)
        case let object as [String: Any]:
            var values: [String: MCPJSONValue] = [:]
            values.reserveCapacity(object.count)
            for (key, item) in object {
                guard let value = MCPJSONValue(foundationObject: item) else {
                    return nil
                }
                values[key] = value
            }
            self = .object(values)
        default:
            return nil
        }
    }

    package var foundationObject: Any {
        switch self {
        case .object(let value):
            return value.mapValues(\.foundationObject)
        case .array(let value):
            return value.map(\.foundationObject)
        case .string(let value):
            return value
        case .integer(let value):
            return NSNumber(value: value)
        case .double(let value):
            return NSNumber(value: value)
        case .bool(let value):
            return NSNumber(value: value)
        case .null:
            return NSNull()
        }
    }

    package var objectValue: [String: MCPJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    package var arrayValue: [MCPJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    package var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    package var doubleValue: Double? {
        switch self {
        case .integer(let value):
            return Double(value)
        case .double(let value):
            return value
        case .object, .array, .string, .bool, .null:
            return nil
        }
    }
}
