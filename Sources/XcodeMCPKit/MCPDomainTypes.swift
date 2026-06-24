import Foundation

/// A tool advertised by the running Xcode MCP server.
///
/// Tool availability and schemas are dynamic. Use ``name`` with
/// ``XcodeMCP/callTool(_:arguments:onProgress:)`` and inspect ``inputSchema``
/// or ``raw`` when building arguments for a tool.
public struct MCPTool: Codable, Equatable, Sendable {
    /// The server-defined tool name.
    public var name: String

    /// The server-provided human-readable description, when available.
    public var description: String?

    /// The server-provided JSON schema for tool arguments, when available.
    public var inputSchema: MCPJSONValue?

    /// The complete raw MCP tool object.
    ///
    /// This preserves dynamic fields and future MCP extensions that are not
    /// modeled as first-class properties.
    public var raw: MCPJSONValue

    /// Creates a tool value.
    ///
    /// - Parameters:
    ///   - name: Server-defined tool name.
    ///   - description: Optional human-readable description.
    ///   - inputSchema: Optional JSON schema for tool arguments.
    ///   - raw: Complete raw MCP tool object. When omitted, a minimal object is
    ///     synthesized from `name`.
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

    /// Decodes a tool from its raw MCP JSON object.
    public init(from decoder: Decoder) throws {
        let value = try MCPJSONValue(from: decoder)
        self = try MCPTool(json: value)
    }

    /// Encodes the tool as an MCP JSON object, preserving raw fields where
    /// possible.
    public func encode(to encoder: Encoder) throws {
        try MCPJSONValue.object(toolObject()).encode(to: encoder)
    }
}

/// A content item returned by an MCP tool call.
///
/// Known MCP content shapes are projected into typed cases. Unknown or
/// malformed content is preserved as ``raw(_:)`` so clients can still inspect
/// the original server response.
public enum MCPContent: Codable, Equatable, Sendable {
    /// Text content.
    ///
    /// The associated `raw` value contains the original MCP content object.
    case text(String, raw: MCPJSONValue)

    /// Base64-encoded image content.
    ///
    /// The associated `raw` value contains the original MCP content object.
    case image(data: String, mimeType: String?, raw: MCPJSONValue)

    /// Embedded resource content.
    ///
    /// The associated `raw` value contains the original MCP content object.
    case resource(uri: String?, text: String?, mimeType: String?, raw: MCPJSONValue)

    /// Content that is not recognized by this package.
    case raw(MCPJSONValue)

    /// Decodes a content item from raw MCP JSON.
    public init(from decoder: Decoder) throws {
        let value = try MCPJSONValue(from: decoder)
        self = try MCPContent(json: value)
    }

    /// Encodes the original MCP content JSON.
    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }

    /// The original MCP content JSON.
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

/// The final result returned by an MCP `tools/call` request.
///
/// `XcodeMCP` returns only this final result from
/// ``XcodeMCP/callTool(_:arguments:onProgress:)``. Progress notifications are
/// delivered through the call's callback and are not stored here.
public struct MCPToolResult: Codable, Equatable, Sendable {
    /// Content items returned by the tool.
    public var content: [MCPContent]

    /// Optional structured content returned by the tool.
    ///
    /// This value is raw MCP JSON because each tool may define its own shape.
    public var structuredContent: MCPJSONValue?

    /// Whether the tool reported an error result.
    ///
    /// This is the MCP `isError` flag from the final tool response, not a Swift
    /// transport error. Transport, timeout, and protocol failures are thrown.
    public var isError: Bool

    /// The complete raw MCP tool result object.
    ///
    /// This preserves dynamic fields and future MCP extensions that are not
    /// modeled as first-class properties.
    public var raw: MCPJSONValue

    /// Creates a tool result value.
    ///
    /// - Parameters:
    ///   - content: Content items returned by the tool.
    ///   - structuredContent: Optional structured content returned by the tool.
    ///   - isError: Whether the tool reported an error result.
    ///   - raw: Complete raw MCP result object. When omitted, a minimal object
    ///     is synthesized from the modeled properties.
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

    /// Decodes a tool result from its raw MCP JSON object.
    public init(from decoder: Decoder) throws {
        let value = try MCPJSONValue(from: decoder)
        self = try MCPToolResult(json: value)
    }

    /// Encodes the result as an MCP JSON object, preserving raw fields where
    /// possible.
    public func encode(to encoder: Encoder) throws {
        try MCPJSONValue.object(resultObject()).encode(to: encoder)
    }
}

/// A progress notification associated with a tool call.
///
/// Progress values are delivered only through the `onProgress` callback passed
/// to ``XcodeMCP/callTool(_:arguments:onProgress:)``. They are not exposed as a
/// public stream and are not included in ``MCPToolResult``.
public struct MCPProgress: Codable, Equatable, Sendable {
    /// Token that associates the notification with a specific tool call.
    public var progressToken: String

    /// Current progress value, when provided by the server.
    public var progress: Double?

    /// Total progress value, when provided by the server.
    public var total: Double?

    /// Optional server-provided progress message.
    public var message: String?

    /// The complete raw MCP progress notification payload.
    ///
    /// This preserves dynamic fields and future MCP extensions that are not
    /// modeled as first-class properties.
    public var raw: MCPJSONValue

    /// Creates a progress notification value.
    ///
    /// - Parameters:
    ///   - progressToken: Token that associates the notification with a tool
    ///     call.
    ///   - progress: Optional current progress value.
    ///   - total: Optional total progress value.
    ///   - message: Optional progress message.
    ///   - raw: Complete raw MCP progress payload. When omitted, a minimal
    ///     object is synthesized from `progressToken`.
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

    /// Decodes a progress notification from raw MCP JSON.
    public init(from decoder: Decoder) throws {
        let value = try MCPJSONValue(from: decoder)
        guard let progress = MCPProgress(json: value) else {
            throw XcodeMCPError.invalidResponse("progress notification is missing progressToken")
        }
        self = progress
    }

    /// Encodes the progress notification as MCP JSON, preserving raw fields
    /// where possible.
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
