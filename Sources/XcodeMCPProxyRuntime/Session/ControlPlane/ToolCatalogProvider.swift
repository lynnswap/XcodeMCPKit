import Foundation
import XcodeMCPCore

/// One catalog remains tied to the exact connection that supplied its definitions.
struct ToolCatalogProvider: Sendable {
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

}
