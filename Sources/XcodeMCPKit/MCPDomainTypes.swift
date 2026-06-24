import Foundation

public struct MCPTool: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var inputSchema: MCPJSONValue?
    public var raw: MCPJSONValue

    public init(
        name: String,
        description: String? = nil,
        inputSchema: MCPJSONValue? = nil,
        raw: MCPJSONValue? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.raw = raw ?? .object([
            "name": .string(name)
        ])
    }
}

public enum MCPContent: Codable, Equatable, Sendable {
    case text(String, raw: MCPJSONValue)
    case image(data: String, mimeType: String?, raw: MCPJSONValue)
    case resource(uri: String?, text: String?, mimeType: String?, raw: MCPJSONValue)
    case raw(MCPJSONValue)

    public init(from decoder: Decoder) throws {
        let value = try MCPJSONValue(from: decoder)
        self = try MCPContent(json: value)
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }

    public var rawValue: MCPJSONValue {
        switch self {
        case .text(_, let raw),
             .image(_, _, let raw),
             .resource(_, _, _, let raw),
             .raw(let raw):
            return raw
        }
    }
}

public struct MCPToolResult: Codable, Equatable, Sendable {
    public var content: [MCPContent]
    public var structuredContent: MCPJSONValue?
    public var isError: Bool
    public var raw: MCPJSONValue

    public init(
        content: [MCPContent],
        structuredContent: MCPJSONValue? = nil,
        isError: Bool = false,
        raw: MCPJSONValue? = nil
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
        self.raw = raw ?? .object([
            "content": .array(content.map(\.rawValue)),
            "isError": .bool(isError),
        ])
    }
}

public struct MCPProgress: Codable, Equatable, Sendable {
    public var progressToken: String
    public var progress: Double?
    public var total: Double?
    public var message: String?
    public var raw: MCPJSONValue

    public init(
        progressToken: String,
        progress: Double? = nil,
        total: Double? = nil,
        message: String? = nil,
        raw: MCPJSONValue? = nil
    ) {
        self.progressToken = progressToken
        self.progress = progress
        self.total = total
        self.message = message
        self.raw = raw ?? .object([
            "progressToken": .string(progressToken)
        ])
    }
}

extension MCPTool {
    package init(json value: MCPJSONValue) throws {
        guard let object = value.objectValue else {
            throw XcodeMCPError.invalidResponse("tool entry is not an object")
        }
        guard let name = object["name"]?.stringValue, name.isEmpty == false else {
            throw XcodeMCPError.invalidResponse("tool entry is missing name")
        }
        self.init(
            name: name,
            description: object["description"]?.stringValue,
            inputSchema: object["inputSchema"],
            raw: value
        )
    }
}

extension MCPContent {
    package init(json value: MCPJSONValue) throws {
        guard let object = value.objectValue else {
            self = .raw(value)
            return
        }
        guard let type = object["type"]?.stringValue, type.isEmpty == false else {
            self = .raw(value)
            return
        }

        switch type {
        case "text":
            if let text = object["text"]?.stringValue {
                self = .text(text, raw: value)
            } else {
                self = .raw(value)
            }
        case "image":
            if let data = object["data"]?.stringValue {
                self = .image(
                    data: data,
                    mimeType: object["mimeType"]?.stringValue,
                    raw: value
                )
            } else {
                self = .raw(value)
            }
        case "resource", "embeddedResource":
            let uri = object["uri"]?.stringValue
                ?? object["resource"]?.objectValue?["uri"]?.stringValue
            let text = object["text"]?.stringValue
                ?? object["resource"]?.objectValue?["text"]?.stringValue
            let mimeType = object["mimeType"]?.stringValue
                ?? object["resource"]?.objectValue?["mimeType"]?.stringValue
            self = .resource(uri: uri, text: text, mimeType: mimeType, raw: value)
        default:
            self = .raw(value)
        }
    }
}

extension MCPToolResult {
    package init(json value: MCPJSONValue) throws {
        guard let object = value.objectValue else {
            throw XcodeMCPError.invalidResponse("tools/call result is not an object")
        }
        let contentValues = object["content"]?.arrayValue ?? []
        let content = try contentValues.map { try MCPContent(json: $0) }
        let isError: Bool
        if case .bool(let value) = object["isError"] {
            isError = value
        } else {
            isError = false
        }
        self.init(
            content: content,
            structuredContent: object["structuredContent"],
            isError: isError,
            raw: value
        )
    }
}

extension MCPProgress {
    package init?(json value: MCPJSONValue) {
        guard let object = value.objectValue,
              let progressToken = object["progressToken"]?.stringValue
        else {
            return nil
        }
        self.init(
            progressToken: progressToken,
            progress: object["progress"]?.doubleValue,
            total: object["total"]?.doubleValue,
            message: object["message"]?.stringValue,
            raw: value
        )
    }
}
