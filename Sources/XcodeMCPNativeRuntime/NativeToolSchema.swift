import Foundation
import XcodeMCPWire

package struct NativeTool: Equatable, Sendable {
    package let name: String
    package let descriptor: JSONValue
    package let workspaceScoped: Bool
}

package enum NativeSchemaConverter {
    private static let internalArguments: Set<String> = [
        "temporaryArtifactsPath", "conversationID", "tabIdentifier",
    ]

    package static func tool(from data: Data, workspaceScoped: Bool) throws -> NativeTool {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let native = JSONValue(any: object), case .object(let fields) = native,
              case .string(let name) = fields["name"],
              let input = fields["inputSchema"] else {
            throw NativeRuntimeError.unsupportedContract("Native tool schema has no name or input schema")
        }
        var inputSchema = try schema(input, excluding: internalArguments)
        if workspaceScoped, case .object(var inputFields) = inputSchema,
           case .object(var properties) = inputFields["properties"] {
            properties["workspaceIdentifier"] = .object([
                "type": .string("string"),
                "description": .string("Native workspace identifier or absolute path to a .xcworkspace or .xcodeproj. The project is loaded without a window when needed."),
            ])
            inputFields["properties"] = .object(properties)
            inputSchema = .object(inputFields)
        }
        var descriptor: [String: JSONValue] = ["name": .string(name), "inputSchema": inputSchema]
        for field in ["description", "title", "annotations"] {
            if let value = fields[field] { descriptor[field] = value }
        }
        if let output = fields["outputSchema"] {
            descriptor["outputSchema"] = try schema(output)
        }
        return NativeTool(name: name, descriptor: .object(descriptor), workspaceScoped: workspaceScoped)
    }

    private static func schema(_ value: JSONValue, excluding: Set<String> = []) throws -> JSONValue {
        guard case .object(let fields) = value, case .array(let nativeProperties) = fields["properties"] else {
            throw NativeRuntimeError.unsupportedContract("Native object schema has no property list")
        }
        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        for property in nativeProperties {
            guard case .object(let fields) = property,
                  case .string(let name) = fields["name"], let type = fields["type"],
                  case .bool(let isRequired) = fields["isRequired"] else {
                throw NativeRuntimeError.unsupportedContract("Native schema property has an unsupported contract")
            }
            if excluding.contains(name) { continue }
            guard case .object(var descriptor) = try propertyType(type) else {
                throw NativeRuntimeError.unsupportedContract("Native property type is not an object")
            }
            if let description = fields["description"] { descriptor["description"] = description }
            if case .array(let knownValues) = fields["knownValues"], !knownValues.isEmpty {
                descriptor["enum"] = .array(knownValues)
            }
            properties[name] = .object(descriptor)
            if isRequired { required.append(.string(name)) }
        }
        return .object([
            "type": .string("object"), "properties": .object(properties), "required": .array(required),
        ])
    }

    private static func propertyType(_ value: JSONValue) throws -> JSONValue {
        guard case .object(let cases) = value, cases.count == 1,
              let (kind, payload) = cases.first, case .object(let fields) = payload else {
            throw NativeRuntimeError.unsupportedContract("Unsupported native property type representation")
        }
        switch kind {
        case "string", "integer", "number", "boolean":
            return .object(["type": .string(kind)])
        case "array":
            guard let itemType = fields["itemType"] else {
                throw NativeRuntimeError.unsupportedContract("Native array schema has no item type")
            }
            return .object(["type": .string("array"), "items": try propertyType(itemType)])
        case "object":
            if let nested = fields["schema"] { return try schema(nested) }
            return .object(["type": .string("object")])
        default:
            throw NativeRuntimeError.unsupportedContract("Unsupported native schema type '\(kind)'")
        }
    }
}
