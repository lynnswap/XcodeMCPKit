import Foundation
import XcodeMCPCore

/// One catalog remains tied to the exact connection that supplied its definitions.
struct ToolCatalogProvider: Sendable {
    static let providersMetadataKey = "com.lynnswap.xcode-mcpkit/providers"
    static let originMetadataKey = "com.lynnswap.xcode-mcpkit/origin"

    let sourceProof: UpstreamTopologyProof
    let routeID: ProcessRouteID?
    let target: XcodeProcessTarget?
    let rawResult: JSONValue
    let toolsByName: [String: JSONValue]

    init(sourceProof: UpstreamTopologyProof, routeID: ProcessRouteID? = nil,
         target: XcodeProcessTarget? = nil, rawResult: JSONValue) {
        self.sourceProof = sourceProof
        self.routeID = routeID
        self.target = target
        self.rawResult = rawResult
        self.toolsByName = ProcessToolCatalogCodec.toolsByName(in: rawResult)
    }

    var origin: JSONValue {
        var fields: [String: JSONValue] = [:]
        if case .object(let result) = rawResult,
           case .object(let metadata)? = result["_meta"],
           case .object(let actual)? = metadata[Self.originMetadataKey] {
            fields = actual
        }
        if fields.isEmpty,
           case .object(let tool)? = toolsByName.values.first,
           case .object(let metadata)? = tool["_meta"],
           case .object(let actual)? = metadata[Self.originMetadataKey] {
            fields = actual
        }
        fields["providerID"] = .string(providerID)
        fields["kind"] = fields["kind"] ?? .string(target == nil ? "nativeHost" : "gui")
        if let target {
            fields["processID"] = fields["processID"] ?? .number(.int(Int64(target.processID)))
            fields["xcodeVersion"] = fields["xcodeVersion"] ?? .string(target.xcodeVersion)
            fields["appPath"] = fields["appPath"] ?? .string(target.appPath)
            fields["developerDirectory"] = fields["developerDirectory"] ?? .string(target.developerDir)
        }
        return .object(fields)
    }

    var providerID: String {
        if let routeID {
            return "gui:\(routeID.processID):\(routeID.instanceGeneration):\(sourceProof.slotGeneration)"
        }
        return "native:\(sourceProof.slotID.rawValue):\(sourceProof.slotGeneration)"
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
