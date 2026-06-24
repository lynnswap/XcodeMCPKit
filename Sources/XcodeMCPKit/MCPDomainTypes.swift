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

    public init(from decoder: Decoder) throws {
        let value = try MCPJSONValue(from: decoder)
        self = try MCPTool(json: value)
    }

    public func encode(to encoder: Encoder) throws {
        try MCPJSONValue.object(toolObject()).encode(to: encoder)
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

    public init(from decoder: Decoder) throws {
        let value = try MCPJSONValue(from: decoder)
        self = try MCPToolResult(json: value)
    }

    public func encode(to encoder: Encoder) throws {
        try MCPJSONValue.object(resultObject()).encode(to: encoder)
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

    public init(from decoder: Decoder) throws {
        let value = try MCPJSONValue(from: decoder)
        guard let progress = MCPProgress(json: value) else {
            throw XcodeMCPError.invalidResponse("progress notification is missing progressToken")
        }
        self = progress
    }

    public func encode(to encoder: Encoder) throws {
        try MCPJSONValue.object(progressObject()).encode(to: encoder)
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

private extension MCPTool {
    func toolObject() -> [String: MCPJSONValue] {
        var object = raw.objectValue ?? [:]
        object["name"] = .string(name)
        if let description {
            object["description"] = .string(description)
        } else {
            object.removeValue(forKey: "description")
        }
        if let inputSchema {
            object["inputSchema"] = inputSchema
        } else {
            object.removeValue(forKey: "inputSchema")
        }
        return object
    }
}

private extension MCPToolResult {
    func resultObject() -> [String: MCPJSONValue] {
        var object = raw.objectValue ?? [:]
        object["content"] = .array(content.map(\.rawValue))
        if let structuredContent {
            object["structuredContent"] = structuredContent
        } else {
            object.removeValue(forKey: "structuredContent")
        }
        object["isError"] = .bool(isError)
        return object
    }
}

private extension MCPProgress {
    func progressObject() -> [String: MCPJSONValue] {
        var object = raw.objectValue ?? [:]
        object["progressToken"] = .string(progressToken)
        if let progress {
            object["progress"] = .double(progress)
        } else {
            object.removeValue(forKey: "progress")
        }
        if let total {
            object["total"] = .double(total)
        } else {
            object.removeValue(forKey: "total")
        }
        if let message {
            object["message"] = .string(message)
        } else {
            object.removeValue(forKey: "message")
        }
        return object
    }
}
