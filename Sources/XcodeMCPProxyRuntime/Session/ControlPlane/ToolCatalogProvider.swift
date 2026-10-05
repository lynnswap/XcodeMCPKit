import Foundation
import XcodeMCPCore

/// One catalog remains tied to the exact connection that supplied its definitions.
struct ToolCatalogProvider: Sendable {
    static let providersMetadataKey = "com.lynnswap.xcode-mcpkit/providers"
    static let originMetadataKey = "com.lynnswap.xcode-mcpkit/origin"

    let sourceProof: UpstreamTopologyProof
    let rawResult: JSONValue
    let toolsByName: [String: JSONValue]

    init(sourceProof: UpstreamTopologyProof, rawResult: JSONValue) {
        self.sourceProof = sourceProof
        self.rawResult = rawResult
        self.toolsByName = ToolCatalogCodec.toolsByName(in: rawResult)
    }

    func definition(named name: String) -> ToolDefinitionSnapshot? {
        toolsByName[name].map { ToolDefinitionSnapshot(sourceProof: sourceProof, descriptor: $0) }
    }
}

struct ToolDefinitionSnapshot: Sendable {
    let sourceProof: UpstreamTopologyProof
    let descriptor: JSONValue

    var catalogResult: JSONValue {
        .object(["tools": .array([descriptor])])
    }

    func declaresArgument(_ name: String) -> Bool {
        guard case .object(let fields) = descriptor,
              case .object(let schema)? = fields["inputSchema"] else { return false }
        if case .object(let properties)? = schema["properties"], properties[name] != nil { return true }
        if case .array(let required)? = schema["required"] { return required.contains(.string(name)) }
        return false
    }
}
