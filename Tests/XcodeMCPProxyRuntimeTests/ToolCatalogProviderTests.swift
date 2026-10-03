import Foundation
import Testing
@testable import XcodeMCPCore
@testable import XcodeMCPProxyRuntime

@Suite
struct ToolCatalogProviderTests {
    @Test func differentProviderOriginsShareTheSameMCPHandshake() throws {
        let state = CanonicalHandshakeState()
        let proofs = [UpstreamTopologyProof(slotID: .init(rawValue: 0), slotGeneration: 1),
                      UpstreamTopologyProof(slotID: .init(rawValue: 1), slotGeneration: 1)]
        for (index, proof) in proofs.enumerated() {
            let result: JSONValue = .object([
                "protocolVersion": .string("2025-06-18"), "capabilities": .object(["tools": .object([:])]),
                "_meta": .object([ToolCatalogProvider.originMetadataKey: .object([
                    "kind": .string(index == 0 ? "nativeHost" : "gui"),
                    "processID": .number(.int(Int64(100 + index))),
                    "xcodeVersion": .string(index == 0 ? "27.0" : "26.6")
                ])])
            ])
            guard case .accepted(let participant) = state.offerInitializeResult(result, sourceProof: proof) else {
                Issue.record("Per-provider origin metadata is not a protocol incompatibility"); return
            }
            #expect(state.commitInitializeParticipant(participant).isAccepted)
        }
        #expect(state.snapshot().supporterProofs == Set(proofs))
    }

    @Test func publicCatalogPreservesEveryProviderSchemaVariant() throws {
        let native = provider(index: 0, fields: ["shared": "string"], required: [], output: "nativeResult")
        let oldGUI = provider(index: 1, fields: ["shared": "string"], required: ["shared"], output: "oldResult", guiVersion: "26.6")
        let newGUI = provider(index: 2, fields: ["shared": "string", "newArgument": "boolean"], required: [], output: "newResult", guiVersion: "27.0")
        let result = try #require(ProcessToolCatalogCodec.toolsListResult(from: [native, oldGUI, newGUI]))
        let tool = try #require(ProcessToolCatalogCodec.toolsByName(in: result)["DynamicTool"])
        guard case .object(let fields) = tool,
              case .object(let input)? = fields["inputSchema"],
              case .object(let output)? = fields["outputSchema"],
              case .array(let inputs)? = input["anyOf"],
              case .array(let outputs)? = output["anyOf"],
              case .object(let metadata)? = fields["_meta"],
              case .array(let origins)? = metadata[ToolCatalogProvider.providersMetadataKey] else {
            Issue.record("Missing provider variants"); return
        }
        #expect(inputs.count == 3)
        #expect(outputs.count == 3)
        #expect(origins.count == 3)
        #expect(input["type"] == .string("object"))
        #expect(input["required"] == .array([]))
        #expect(origins.contains { origin in
            guard case .object(let value) = origin else { return false }
            return value["xcodeVersion"] == .string("26.6") && value["descriptor"] == oldGUI.toolsByName["DynamicTool"]
        })
    }

    @Test func identicalSchemasAreDeduplicatedWithoutDiscardingProviderOrigins() throws {
        let first = provider(index: 0, fields: ["value": "string"], required: ["value"], output: "result")
        let second = provider(index: 1, fields: ["value": "string"], required: ["value"], output: "result", guiVersion: "27.0")
        let result = try #require(ProcessToolCatalogCodec.toolsListResult(from: [first, second]))
        guard case .object(let tool)? = ProcessToolCatalogCodec.toolsByName(in: result)["DynamicTool"],
              case .object(let input)? = tool["inputSchema"],
              case .object(let metadata)? = tool["_meta"],
              case .array(let origins)? = metadata[ToolCatalogProvider.providersMetadataKey] else {
            Issue.record("Missing merged tool"); return
        }
        #expect(input["anyOf"] == nil)
        #expect(origins.count == 2)
    }

    @Test func actualOriginInformationOverridesDiscoveryMetadata() {
        let actual: JSONValue = .object(["xcodeVersion": .string("loaded-version"), "processID": .number(.int(999))])
        let catalog = ToolCatalogProvider(
            sourceProof: .init(slotID: .init(rawValue: 1), slotGeneration: 2),
            routeID: .init(processID: 111, instanceGeneration: 3),
            target: target(pid: 111, version: "discovered-version"),
            rawResult: .object(["tools": .array([]), "_meta": .object([ToolCatalogProvider.originMetadataKey: actual])])
        )
        guard case .object(let fields) = catalog.origin else { return }
        #expect(fields["xcodeVersion"] == .string("loaded-version"))
        #expect(fields["processID"] == .number(.int(999)))
        #expect(fields["developerDirectory"] != nil)
    }

    private func provider(index: Int, fields: [String: String], required: [String], output: String,
                          guiVersion: String? = nil) -> ToolCatalogProvider {
        let tool: JSONValue = .object([
            "name": .string("DynamicTool"),
            "inputSchema": .object(["type": .string("object"),
                                    "properties": .object(fields.mapValues { .object(["type": .string($0)]) }),
                                    "required": .array(required.map(JSONValue.string))]),
            "outputSchema": .object(["type": .string("object"),
                                     "properties": .object([output: .object(["type": .string("string")])]),
                                     "required": .array([.string(output)])])
        ])
        return ToolCatalogProvider(
            sourceProof: .init(slotID: .init(rawValue: index), slotGeneration: 1),
            routeID: guiVersion.map { _ in .init(processID: Int32(100 + index), instanceGeneration: 1) },
            target: guiVersion.map { target(pid: Int32(100 + index), version: $0) },
            rawResult: .object(["tools": .array([tool])])
        )
    }

    private func target(pid: Int32, version: String) -> XcodeProcessTarget {
        .init(processID: pid, appPath: "/Xcode\(pid).app", developerDir: "/Xcode\(pid).app/Contents/Developer", xcodeVersion: version)
    }
}
