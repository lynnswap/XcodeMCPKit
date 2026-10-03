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
        #expect(inputs.count == 4)
        #expect(outputs.count == 3)
        #expect(origins.count == 3)
        #expect(input["type"] == .string("object"))
        #expect(input["required"] == .array([]))
        #expect(origins.contains { origin in
            guard case .object(let value) = origin else { return false }
            return value["xcodeVersion"] == .string("26.6") && value["descriptor"] == oldGUI.toolsByName["DynamicTool"]
        })
    }

    @Test func anAlternativeClosedSchemaRequiresAnOwnerSelector() throws {
        let native = closedProvider(index: 0, field: "a")
        let gui = closedProvider(index: 1, field: "b", guiVersion: "27.0")
        let result = try #require(ProcessToolCatalogCodec.toolsListResult(from: [gui, native]))
        let tool = try #require(ProcessToolCatalogCodec.toolsByName(in: result)["DynamicTool"])
        guard case .object(let fields) = tool,
              case .object(let schema)? = fields["inputSchema"],
              case .array(let branches)? = schema["anyOf"],
              case .object(let noHint)? = branches.first,
              case .array(let defaultParts)? = noHint["allOf"],
              case .object(let defaultInput)? = defaultParts.first,
              case .object(let defaultCondition)? = defaultParts.last else {
            Issue.record("Missing default branch"); return
        }
        #expect(defaultInput["required"] == .array([.string("a")]))
        #expect(defaultInput["additionalProperties"] == .bool(false))
        #expect(defaultCondition["not"] != nil)
        // {b: ...} lacks the default's required a; the GUI branch also needs an owner hint.
        guard case .object(let alternative)? = branches.last,
              case .array(let guiParts)? = alternative["allOf"],
              case .object(let guiInput)? = guiParts.first,
              case .object(let guiProperties)? = guiInput["properties"],
              case .object(let guiCondition) = guiParts[1],
              case .array(let hints)? = guiCondition["anyOf"] else {
            Issue.record("Missing selected GUI branch"); return
        }
        #expect(guiInput["required"] == .array([.string("b")]))
        #expect(guiInput["additionalProperties"] == .bool(false))
        #expect(guiInput["x-native-schema"] == .string("preserved"))
        #expect(guiProperties["workspaceIdentifier"] != nil)
        #expect(guiProperties["tabIdentifier"] != nil)
        #expect(hints.count == 2)
        #expect(defaultCondition["not"] == .object(guiCondition))
        #expect(ProcessToolCatalogCodec.isOwnerBoundTool(tool) == false)
        #expect(gui.toolsByName["DynamicTool"] == descriptor(in: tool, providerIndex: 1))
    }

    @Test func ambiguousGUIOnlyScopedSchemasRequireAnOwnerAndAllowBothAliases() throws {
        let first = closedProvider(index: 1, field: "a", guiVersion: "26.6", selector: "tabIdentifier")
        let second = closedProvider(index: 2, field: "b", guiVersion: "27.0", selector: "workspaceIdentifier")
        let result = try #require(ProcessToolCatalogCodec.toolsListResult(from: [second, first]))
        let tool = try #require(ProcessToolCatalogCodec.toolsByName(in: result)["DynamicTool"])
        guard case .object(let fields) = tool,
              case .object(let schema)? = fields["inputSchema"],
              case .array(let branches)? = schema["anyOf"] else {
            Issue.record("Missing selected scoped variants"); return
        }
        #expect(branches.count == 2)
        for branch in branches {
            guard case .object(let object) = branch, case .array(let parts)? = object["allOf"],
                  case .object(let input)? = parts.first, case .object(let properties)? = input["properties"],
                  case .object(let condition) = parts[1] else {
                Issue.record("Missing owner branch"); return
            }
            #expect(properties["workspaceIdentifier"] != nil)
            #expect(properties["tabIdentifier"] != nil)
            #expect(condition["not"] == nil)
            #expect(condition["anyOf"] != nil)
            #expect(input["required"] == .array([.string(properties["a"] != nil ? "a" : "b")]))
            #expect(input["additionalProperties"] == .bool(false))
        }
    }

    @Test(arguments: ["DeviceInteractionSynthesize", "DeviceInteractionInstallAndRun", "DeviceInteractionEndSession"])
    func sessionAffinityExposesTheActualContinuationSelector(name: String) throws {
        let key = try #require(DeviceInteractionToolCall.continuationSelector(for: name)?.argumentName)
        let native = closedProvider(index: 0, field: "a", name: name, sessionKey: key)
        let gui = closedProvider(index: 1, field: "b", guiVersion: "27.0", name: name, sessionKey: key)
        let result = try #require(ProcessToolCatalogCodec.toolsListResult(from: [native, gui]))
        guard case .object(let fields)? = ProcessToolCatalogCodec.toolsByName(in: result)[name],
              case .object(let schema)? = fields["inputSchema"],
              case .array(let branches)? = schema["anyOf"] else {
            Issue.record("Missing affinity variants"); return
        }
        #expect(branches.count == 5)
        let affinityBranches = branches.compactMap { branch -> [JSONValue]? in
            guard case .object(let object) = branch, case .array(let parts)? = object["allOf"], parts.count == 3 else { return nil }
            guard case .object(let condition)? = parts.last,
                  condition["required"] == .array([.string(key)]) else { return nil }
            return parts
        }
        #expect(affinityBranches.count == 2)
        for parts in affinityBranches {
            guard case .object(let condition)? = parts.last else { continue }
            #expect(condition["required"] == .array([.string(key)]))
        }
    }

    @Test(arguments: [false, true])
    func publicSchemaMatchesOrdinaryOwnerSelectorCombinations(identicalSchemas: Bool) throws {
        let native = closedProvider(index: 0, field: "value")
        let gui = closedProvider(index: 1, field: identicalSchemas ? "value" : "guiValue", guiVersion: "27.0")
        let schema = try inputSchema(name: "DynamicTool", providers: [native, gui])
        let guiField = identicalSchemas ? "value" : "guiValue"
        let cases: [(String, [String: JSONValue], Bool)] = [
            ("no hint", ["value": .string("native")], true),
            ("opaque workspace", [guiField: .string("gui"), "workspaceIdentifier": .string("gui-opaque")], true),
            ("tab", [guiField: .string("gui"), "tabIdentifier": .string("gui-tab")], true),
            ("opaque workspace and tab", [guiField: .string("gui"), "workspaceIdentifier": .string("gui-opaque"), "tabIdentifier": .string("gui-tab")], false),
            ("absolute workspace and tab", [guiField: .string("gui"), "workspaceIdentifier": .string("/Work/App.xcodeproj"), "tabIdentifier": .string("gui-tab")], true),
            ("absolute workspace", [guiField: .string("gui"), "workspaceIdentifier": .string("/Work/App.xcodeproj")], true),
            ("empty hints", ["value": .string("native"), "workspaceIdentifier": .string(""), "tabIdentifier": .string("")], true),
            ("empty workspace and tab", [guiField: .string("gui"), "workspaceIdentifier": .string(""), "tabIdentifier": .string("gui-tab")], true),
            ("opaque workspace and empty tab", [guiField: .string("gui"), "workspaceIdentifier": .string("gui-opaque"), "tabIdentifier": .string("")], true)
        ]
        for (label, arguments, expected) in cases {
            #expect(try acceptsFixtureInput(.object(arguments), schema: schema) == expected, Comment(rawValue: label))
        }
    }

    @Test(arguments: [false, true])
    func identicalAffinitySchemasPreserveTheirProviderOwnerPolicy(includesGUI: Bool) throws {
        let name = "DeviceInteractionSynthesize"
        let key = "interactSessionKey"
        let native = closedProvider(index: 0, field: "value", name: name, sessionKey: key)
        let gui = closedProvider(index: 1, field: "value", guiVersion: "27.0", name: name, sessionKey: key)
        let schema = try inputSchema(name: name, providers: includesGUI ? [native, gui] : [native])
        let base: [String: JSONValue] = ["value": .string("input"), key: .string("existing-session")]
        #expect(try acceptsFixtureInput(.object(base), schema: schema))
        for workspace in ["gui-opaque", "/Work/App.xcodeproj"] {
            var arguments = base
            arguments["workspaceIdentifier"] = .string(workspace)
            arguments["tabIdentifier"] = .string("gui-tab")
            #expect(try acceptsFixtureInput(.object(arguments), schema: schema) == includesGUI)
        }
        var empty = base
        empty["workspaceIdentifier"] = .string("")
        empty["tabIdentifier"] = .string("")
        #expect(try acceptsFixtureInput(.object(empty), schema: schema))
        empty[key] = .string("")
        #expect(try acceptsFixtureInput(.object(empty), schema: schema))
        empty["workspaceIdentifier"] = .string("gui-opaque")
        empty["tabIdentifier"] = .string("gui-tab")
        #expect(try !acceptsFixtureInput(.object(empty), schema: schema))
        empty["workspaceIdentifier"] = .string("/Work/App.xcodeproj")
        #expect(try acceptsFixtureInput(.object(empty), schema: schema))
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

    private func closedProvider(index: Int, field: String, guiVersion: String? = nil,
                                selector: String? = nil, name: String = "DynamicTool", sessionKey: String? = nil) -> ToolCatalogProvider {
        var properties: [String: JSONValue] = [field: .object(["type": .string("string")])]
        var required = [JSONValue.string(field)]
        for extra in [selector, sessionKey].compactMap({ $0 }) {
            properties[extra] = .object(["type": .string("string")])
            required.append(.string(extra))
        }
        return ToolCatalogProvider(
            sourceProof: .init(slotID: .init(rawValue: index), slotGeneration: 1),
            routeID: guiVersion.map { _ in .init(processID: Int32(100 + index), instanceGeneration: 1) },
            target: guiVersion.map { target(pid: Int32(100 + index), version: $0) },
            rawResult: .object(["tools": .array([.object([
                "name": .string(name), "inputSchema": .object([
                    "type": .string("object"), "properties": .object(properties),
                    "required": .array(required), "additionalProperties": .bool(false),
                    "x-native-schema": .string("preserved")
                ])
            ])])])
        )
    }

    private func descriptor(in tool: JSONValue, providerIndex: Int) -> JSONValue? {
        guard case .object(let fields) = tool, case .object(let metadata)? = fields["_meta"],
              case .array(let providers)? = metadata[ToolCatalogProvider.providersMetadataKey],
              case .object(let origin) = providers[providerIndex] else { return nil }
        return origin["descriptor"]
    }

    private func inputSchema(name: String, providers: [ToolCatalogProvider]) throws -> JSONValue {
        let result = try #require(ProcessToolCatalogCodec.toolsListResult(from: providers))
        guard case .object(let tool)? = ProcessToolCatalogCodec.toolsByName(in: result)[name] else {
            throw NSError(domain: "ToolCatalogProviderTests", code: 1)
        }
        return try #require(tool["inputSchema"])
    }

    // This test consumer evaluates the JSON Schema keywords used by the fixtures;
    // production routing never validates or selects a provider from input shape.
    private func acceptsFixtureInput(_ value: JSONValue, schema: JSONValue) throws -> Bool {
        guard case .object(let fields) = schema else {
            if case .bool(let allowed) = schema { return allowed }
            throw NSError(domain: "ToolCatalogProviderTests", code: 2)
        }
        if case .array(let constraints)? = fields["allOf"],
           try !constraints.allSatisfy({ try acceptsFixtureInput(value, schema: $0) }) { return false }
        if case .array(let choices)? = fields["anyOf"],
           try !choices.contains(where: { try acceptsFixtureInput(value, schema: $0) }) { return false }
        if let negated = fields["not"], try acceptsFixtureInput(value, schema: negated) { return false }
        if case .string(let type)? = fields["type"] {
            switch (type, value) {
            case ("object", .object), ("string", .string): break
            default: return false
            }
        }
        if case .string(let text) = value {
            if case .number(.int(let minimum))? = fields["minLength"], Int64(text.unicodeScalars.count) < minimum { return false }
            if case .string(let pattern)? = fields["pattern"] {
                let expression = try NSRegularExpression(pattern: pattern)
                if expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil { return false }
            }
        }
        if case .object(let object) = value {
            if case .array(let required)? = fields["required"], required.contains(where: {
                if case .string(let name) = $0 { return object[name] == nil }
                return false
            }) { return false }
            var properties: [String: JSONValue] = [:]
            if case .object(let declared)? = fields["properties"] { properties = declared }
            if fields["additionalProperties"] == .bool(false), object.keys.contains(where: { properties[$0] == nil }) { return false }
            for (name, property) in properties {
                if let field = object[name], try !acceptsFixtureInput(field, schema: property) { return false }
            }
        }
        return true
    }

    private func target(pid: Int32, version: String) -> XcodeProcessTarget {
        .init(processID: pid, appPath: "/Xcode\(pid).app", developerDir: "/Xcode\(pid).app/Contents/Developer", xcodeVersion: version)
    }
}
