import Foundation
import XcodeMCPCore

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

extension MCPJSONValue {
    /// Creates an MCP JSON value from a Foundation JSON object.
    ///
    /// Pass values returned by `JSONSerialization.jsonObject(with:)` or values
    /// that can be serialized as JSON: `String`, `NSNumber`, `Bool`, `NSNull`,
    /// arrays, and dictionaries with `String` keys. Non-JSON values throw
    /// ``XcodeMCPError/invalidRequest(_:)``.
    ///
    /// - Parameter value: A Foundation object that represents a JSON value.
    public init(jsonObject value: Any) throws {
        guard let jsonValue = JSONValue(any: value),
              Self.isValidJSONValue(jsonValue)
        else {
            throw XcodeMCPError.invalidRequest(
                "value is not a JSON-compatible Foundation object"
            )
        }
        self.init(jsonValue)
    }

    /// Creates an MCP JSON value by encoding an `Encodable` value with
    /// `JSONEncoder`.
    ///
    /// Encoding errors from the value are rethrown. This initializer is useful
    /// for building dynamic MCP params from local request structs without
    /// writing a tool-specific wrapper.
    ///
    /// - Parameter value: The value to encode into MCP JSON.
    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(MCPJSONValue.self, from: data)
    }

    /// A Foundation JSON object suitable for `JSONSerialization`.
    ///
    /// Objects are returned as `[String: Any]`, arrays as `[Any]`, strings as
    /// `String`, numbers as `NSNumber`, booleans as `Bool`, and null as
    /// `NSNull`.
    public var jsonObject: Any {
        jsonValue.foundationObject
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
    /// Returns the object dictionary when this value is a JSON object.
    public var objectValue: [String: MCPJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    /// Returns the array elements when this value is a JSON array.
    public var arrayValue: [MCPJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    /// Returns the Swift string when this value is a JSON string.
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// Returns the Swift boolean when this value is a JSON boolean.
    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    /// Returns the integer when this value is an integer JSON number.
    public var integerValue: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    /// Returns the integer when this value is an integer JSON number.
    public var intValue: Int64? {
        integerValue
    }

    /// Returns the numeric value as a `Double` when this value is any JSON
    /// number.
    public var doubleValue: Double? {
        switch self {
        case .integer(let value):
            return Double(value)
        case .double(let value):
            return value
        case .object, .array, .string, .bool, .null:
            return nil
        }
    }

    /// Whether this value is JSON null.
    public var isNull: Bool {
        self == .null
    }
}

extension MCPJSONValue {
    package init(_ value: JSONValue) {
        switch value {
        case .object(let values):
            self = .object(values.mapValues(MCPJSONValue.init))
        case .array(let values):
            self = .array(values.map(MCPJSONValue.init))
        case .string(let value):
            self = .string(value)
        case .number(let value):
            switch value {
            case .int(let value):
                self = .integer(value)
            case .double(let value):
                self = .double(value)
            }
        case .bool(let value):
            self = .bool(value)
        case .null:
            self = .null
        }
    }

    package init?(foundationObject value: Any) {
        try? self.init(jsonObject: value)
    }

    package var foundationObject: Any {
        jsonObject
    }

    package var jsonValue: JSONValue {
        switch self {
        case .object(let value):
            return .object(value.mapValues(\.jsonValue))
        case .array(let value):
            return .array(value.map(\.jsonValue))
        case .string(let value):
            return .string(value)
        case .integer(let value):
            return .number(.int(value))
        case .double(let value):
            return .number(.double(value))
        case .bool(let value):
            return .bool(value)
        case .null:
            return .null
        }
    }

}

private extension MCPJSONValue {
    static func isValidJSONValue(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let values):
            return values.values.allSatisfy(isValidJSONValue)
        case .array(let values):
            return values.allSatisfy(isValidJSONValue)
        case .number(.double(let value)):
            return value.isFinite
        case .number(.int), .string, .bool, .null:
            return true
        }
    }
}
