import Foundation

/// A JSON value used by MCP requests, responses, and dynamic metadata.
///
/// Xcode MCP tools are discovered at runtime, so this package preserves tool
/// arguments, input schemas, structured content, and unknown fields as raw JSON
/// instead of projecting every value into tool-specific Swift types.
///
/// Literal conformances make small argument dictionaries concise:
///
/// ```swift
/// let arguments: [String: MCPJSONValue] = [
///     "query": "SwiftUI toolbar",
///     "includeBeta": true,
///     "limit": 5
/// ]
/// ```
public enum MCPJSONValue: Codable, Equatable, Sendable {
    /// A JSON object with string keys.
    case object([String: MCPJSONValue])

    /// A JSON array.
    case array([MCPJSONValue])

    /// A JSON string.
    case string(String)

    /// A JSON number represented as an integer.
    case integer(Int64)

    /// A JSON number represented as a floating-point value.
    case double(Double)

    /// A JSON boolean.
    case bool(Bool)

    /// A JSON null value.
    case null

    /// Decodes a JSON value while preserving its dynamic shape.
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

    /// Encodes the value as JSON.
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
    /// Creates a JSON string from a Swift string literal.
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension MCPJSONValue: ExpressibleByBooleanLiteral {
    /// Creates a JSON boolean from a Swift boolean literal.
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension MCPJSONValue: ExpressibleByIntegerLiteral {
    /// Creates a JSON integer from a Swift integer literal.
    public init(integerLiteral value: Int64) {
        self = .integer(value)
    }
}

extension MCPJSONValue: ExpressibleByFloatLiteral {
    /// Creates a JSON floating-point number from a Swift float literal.
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension MCPJSONValue: ExpressibleByArrayLiteral {
    /// Creates a JSON array from a Swift array literal.
    public init(arrayLiteral elements: MCPJSONValue...) {
        self = .array(elements)
    }
}

extension MCPJSONValue: ExpressibleByDictionaryLiteral {
    /// Creates a JSON object from a Swift dictionary literal.
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
