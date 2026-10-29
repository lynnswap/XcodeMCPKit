import Testing
@testable import XcodeMCPCore
@testable import XcodeMCPProxyRuntime

struct StableToolCatalogTests {
    @Test func workspaceContractPreservesNativePayloadSchemasAndAnnotations() throws {
        let annotations: JSONValue = .object(["readOnlyHint": .bool(true), "openWorldHint": .bool(false)])
        let output: JSONValue = .object(["type": .string("object"), "properties": .object([
            "records": .object(["type": .string("array"), "items": .object([
                "type": .string("object"), "properties": .object(["tabIdentifier": string]),
            ])]),
        ])])
        let native = tool("GetBuildLog", properties: ["workspaceIdentifier": string, "pattern": string],
                          required: [], extra: ["annotations": annotations, "outputSchema": output])
        let result = try XcodeToolCatalog.publicResult(from: catalog([native]), managementTools: [])
        let value = try #require(find("GetBuildLog", in: result))
        #expect(field(value, "inputSchema", "required") == .array([.string("workspaceIdentifier")]))
        #expect(field(value, "inputSchema", "properties", "tabIdentifier") == nil)
        #expect(field(value, "annotations") == annotations)
        #expect(field(value, "outputSchema") == output)
    }

    @Test func deviceSessionUsesOnePublicOperationAndOneKeySpelling() throws {
        let workspaceSessionLabel: JSONValue = .object([
            "type": .string("string"), "description": .string("Workspace session label."),
        ])
        let workspaceAnnotations: JSONValue = .object(["readOnlyHint": .bool(false)])
        let sessionOutput: JSONValue = .object(["type": .string("object"), "properties": .object([
            "interactionSessionKey": string,
        ])])
        let tools = [
            tool("DeviceInteractionStartSession", properties: ["deviceIdentifier": string, "sessionIdentifier": string],
                 required: ["deviceIdentifier", "sessionIdentifier"]),
            tool("DeviceInteractionStartWorkspaceSession", properties: [
                "sessionIdentifier": workspaceSessionLabel, "workspaceIdentifier": string], required: ["sessionIdentifier"],
                 extra: ["annotations": workspaceAnnotations, "outputSchema": sessionOutput]),
            tool("DeviceInteractionSynthesize", properties: ["interactSessionKey": string,
                "interactionCommand": string], required: ["interactSessionKey"]),
        ]
        let result = try XcodeToolCatalog.publicResult(from: catalog(tools), managementTools: [])
        #expect(find("DeviceInteractionStartWorkspaceSession", in: result) == nil)
        let start = try #require(find("DeviceInteractionStartSession", in: result))
        #expect(field(start, "inputSchema", "properties", "workspaceIdentifier") != nil)
        #expect(field(start, "inputSchema", "properties", "deviceIdentifier") == string)
        #expect(field(start, "inputSchema", "properties", "sessionIdentifier") == workspaceSessionLabel)
        #expect(field(start, "inputSchema", "required") == .array([.string("sessionIdentifier")]))
        #expect(field(start, "annotations") == workspaceAnnotations)
        #expect(field(start, "outputSchema") == sessionOutput)
        let synthesize = try #require(find("DeviceInteractionSynthesize", in: result))
        #expect(field(synthesize, "inputSchema", "properties", "interactSessionKey") == nil)
        #expect(field(synthesize, "inputSchema", "required") == .array([.string("interactionSessionKey")]))
        let scoped = try XcodeToolCatalog.nativeCall(name: "DeviceInteractionStartSession",
            arguments: ["workspaceIdentifier": .string("native-workspace")], nativeCatalog: catalog(tools))
        #expect(scoped.name == "DeviceInteractionStartWorkspaceSession")
        let guiCatalog = catalog([
            tools[0],
            tool("DeviceInteractionStartWorkspaceSession", properties: ["tabIdentifier": string,
                "sessionIdentifier": string], required: ["sessionIdentifier"]),
        ])
        let guiScoped = try XcodeToolCatalog.nativeCall(name: "DeviceInteractionStartSession",
            arguments: ["tabIdentifier": .string("native-tab")], nativeCatalog: guiCatalog)
        #expect(guiScoped.name == "DeviceInteractionStartWorkspaceSession")
        let standalone = try XcodeToolCatalog.nativeCall(name: "DeviceInteractionStartSession",
            arguments: ["deviceIdentifier": .string("device")], nativeCatalog: catalog(tools))
        #expect(standalone.name == "DeviceInteractionStartSession")
        let input = try XcodeToolCatalog.nativeCall(name: "DeviceInteractionSynthesize",
            arguments: ["interactionSessionKey": .string("native-key")], nativeCatalog: catalog(tools))
        #expect(input.arguments == ["interactSessionKey": .string("native-key")])
        let matchingNative = catalog([tool("DeviceInteractionSynthesize",
            properties: ["interactionSessionKey": string], required: ["interactionSessionKey"])])
        let unchanged = try XcodeToolCatalog.nativeCall(name: "DeviceInteractionSynthesize",
            arguments: ["interactionSessionKey": .string("native-key")], nativeCatalog: matchingNative)
        #expect(unchanged.arguments == ["interactionSessionKey": .string("native-key")])
    }

    @Test func guiCallsKeepResolvedScopeAndSurfaceUnsupportedArguments() throws {
        let native = catalog([
            tool("DeviceInteractionStartSession", properties: ["tabIdentifier": string], required: ["tabIdentifier"]),
            tool("DocumentationSearch", properties: ["query": string], required: ["query"]),
        ])
        let start = try XcodeToolCatalog.nativeCall(name: "DeviceInteractionStartSession",
            arguments: ["tabIdentifier": .string("native-tab")], nativeCatalog: native)
        #expect(start.name == "DeviceInteractionStartSession")
        #expect(start.arguments == ["tabIdentifier": .string("native-tab")])
        let standaloneOnly = catalog([tool("DeviceInteractionStartSession",
            properties: ["deviceIdentifier": string], required: ["deviceIdentifier"])])
        #expect(throws: NativeHostBrokerError.self) {
            try XcodeToolCatalog.nativeCall(name: "DeviceInteractionStartSession",
                arguments: ["tabIdentifier": .string("native-tab")], nativeCatalog: standaloneOnly)
        }
        #expect(throws: NativeHostBrokerError.self) {
            try XcodeToolCatalog.nativeCall(name: "DocumentationSearch",
                arguments: ["query": .string("SwiftUI"), "frameworks": .array([.string("SwiftUI")])],
                nativeCatalog: native)
        }
        #expect(throws: NativeHostBrokerError.self) {
            try XcodeToolCatalog.nativeCall(name: "XcodeGetCurrentFile", arguments: [:], nativeCatalog: native)
        }
    }

    @Test func previewGroupIndexesBecomeCanonicalObjectsWithoutRewritingOtherData() throws {
        let groups: JSONValue = .array([.number(.int(0)), .number(.int(2))])
        let unrelated: JSONValue = .object(["groupItems": groups])
        let gui: JSONValue = .object([
            "supportedCanvasControlOverrides": .object(["groupItems": groups]),
            "unrelated": unrelated,
        ])
        let converted = XcodeToolCatalog.publicPayload(name: "RenderPreview", payload: gui)
        #expect(field(converted, "supportedCanvasControlOverrides", "groupItems") == .array([
            .object(["index": .number(.int(0))]), .object(["index": .number(.int(2))]),
        ]))
        #expect(field(converted, "unrelated") == unrelated)
        let headless: JSONValue = .object(["supportedCanvasControlOverrides": .object([
            "groupItems": .array([.object(["index": .number(.int(0)), "title": .string("First")])]),
        ])])
        #expect(XcodeToolCatalog.publicPayload(name: "RenderPreview", payload: headless) == headless)
        #expect(XcodeToolCatalog.publicPayload(name: "OtherTool", payload: gui) == gui)
        let previewTool = tool("RenderPreview", properties: ["workspaceIdentifier": string,
            "timeout": .object(["type": .string("integer")])], required: [], extra: [
            "outputSchema": .object(["type": .string("object"), "properties": .object([
                "supportedCanvasControlOverrides": .object(["type": .string("object"), "properties": .object([
                    "groupItems": .object(["type": .string("array"), "items": .object(["type": .string("integer")])]),
                ])]),
            ])]),
        ])
        let publicCatalog = try XcodeToolCatalog.publicResult(from: catalog([previewTool]), managementTools: [])
        let descriptor = try #require(find("RenderPreview", in: publicCatalog))
        #expect(field(descriptor, "outputSchema", "properties", "supportedCanvasControlOverrides", "properties",
                      "groupItems", "items", "required") == .array([.string("index")]))
        #expect(field(descriptor, "inputSchema", "properties", "timeout", "default") == .number(.int(300)))
        let call = try XcodeToolCatalog.nativeCall(name: "RenderPreview",
            arguments: ["tabIdentifier": .string("native-tab")], nativeCatalog: catalog([previewTool]))
        #expect(call.arguments["timeout"] == .number(.int(300)))
    }

    @Test func ownerReferencesAndExplicitAppIdentityDoNotRequireAnotherWorkspaceSelector() throws {
        let names = ["DeviceInteractionInstallAndRun", "GetConsoleOutput", "SyncCrashReports",
                     "ReadCrashChanges", "GetTopFieldPerformanceIssues", "GetFieldPerformanceIssueLogs"]
        let native = catalog(names.map { name in
            tool(name, properties: ["workspaceIdentifier": string], required: [])
        })
        let result = try XcodeToolCatalog.publicResult(from: native, managementTools: [])
        for name in names {
            let value = try #require(find(name, in: result))
            #expect(field(value, "inputSchema", "properties", "workspaceIdentifier") != nil)
            #expect(field(value, "inputSchema", "required") == .array([]))
        }
    }

    @Test func crashQueriesPreserveDurableTokensAndBoundsWithOptionalWorkspace() throws {
        let integer: JSONValue = .object(["type": .string("integer")])
        for name in ["SyncCrashReports", "ReadCrashChanges"] {
            let sync = name == "SyncCrashReports"
            var properties: [String: JSONValue] = ["workspaceIdentifier": string, "bundle_id": string,
                "platform": string, "collection": string, "issue_id": string, "cursor": string,
                "max_bytes": integer]
            let arguments: [String: JSONValue]
            if sync {
                properties["source"] = string
                properties["max_records"] = integer
                arguments = ["collection": .string("logs"), "issue_id": .string("native-issue-id"),
                    "bundle_id": .string("com.example.app"), "platform": .string("iOS"),
                    "source": .string("cache"), "max_records": .number(.int(100)),
                    "max_bytes": .number(.int(64 * 1024 * 1024))]
            } else {
                properties["checkpoint"] = string
                properties["limit"] = integer
                properties["order"] = string
                arguments = ["cursor": .string("durable-fixed-read-batch")]
            }
            let output: JSONValue = .object(["type": .string("object"), "properties": .object([
                "status": string, "cursor": string, "nextCursor": string, "checkpoint": string,
                "cacheInfo": .object(["type": .string("object")]),
            ])])
            let native = catalog([tool(name, properties: properties, required: [],
                extra: ["outputSchema": output])])
            let result = try XcodeToolCatalog.publicResult(from: native, managementTools: [])
            let descriptor = try #require(find(name, in: result))
            for (key, value) in properties where key != "workspaceIdentifier" {
                #expect(field(descriptor, "inputSchema", "properties", key) == value)
            }
            #expect(field(descriptor, "inputSchema", "required") == .array([]))
            #expect(field(descriptor, "outputSchema") == output)
            let call = try XcodeToolCatalog.nativeCall(name: name, arguments: arguments, nativeCatalog: native)
            #expect(call.name == name)
            #expect(call.arguments == arguments)
        }
    }

    @Test func crashJobsKeepExplicitIdentityAndJobControlsWithoutWorkspaceRouting() throws {
        for name in ["StartCrashSync", "WaitForCrashSync", "CancelCrashSync"] {
            let start = name == "StartCrashSync"
            let required = start ? ["bundle_id", "platform"] : ["job_id"]
            let properties = Dictionary(uniqueKeysWithValues: required.map { ($0, string) })
            let annotations: JSONValue = .object(["readOnlyHint": .bool(name == "WaitForCrashSync")])
            let native = catalog([tool(name, properties: properties, required: required,
                extra: ["annotations": annotations])])
            let result = try XcodeToolCatalog.publicResult(from: native, managementTools: [])
            let descriptor = try #require(find(name, in: result))
            #expect(field(descriptor, "inputSchema", "required") == .array(required.map(JSONValue.string)))
            #expect(field(descriptor, "inputSchema", "properties", "workspaceIdentifier") == nil)
            #expect(field(descriptor, "annotations") == annotations)
            let arguments: [String: JSONValue] = start
                ? ["bundle_id": .string("com.example.app"), "platform": .string("iOS")]
                : ["job_id": .string("persistent-job-id")]
            let call = try XcodeToolCatalog.nativeCall(name: name, arguments: arguments, nativeCatalog: native)
            #expect(call.name == name)
            #expect(call.arguments == arguments)
        }
    }

    @Test func stableCatalogKeepsNativeToolsAndManagementOverridesWithoutInventingEditorTools() throws {
        let native = catalog([
            tool("StringCatalogRead", properties: ["workspaceIdentifier": string], required: [], extra: [
                "description": .string("Native skill MUST be loaded before calling."),
            ]),
            tool("XcodeListWindows", properties: [:], required: []),
            tool("XcodeOpenWorkspace", properties: ["path": string], required: ["path"]),
        ])
        let open = tool("XcodeOpenWorkspace", properties: ["path": string, "hostIdentifier": string], required: ["path"])
        let result = try XcodeToolCatalog.publicResult(from: native, managementTools: [open])
        #expect(find("XcodeListWindows", in: result) == nil)
        #expect(find("XcodeOpenWorkspace", in: result) == open)
        #expect(find("XcodeGetCurrentFile", in: result) == nil)
        #expect(find("XcodeListNavigatorIssues", in: result) == nil)
        let read = try #require(find("StringCatalogRead", in: result))
        guard case .string(let description)? = field(read, "description") else {
            Issue.record("Missing public description"); return
        }
        #expect(!description.contains("MUST"))
        #expect(description.contains("String Catalog"))
    }

    private let string: JSONValue = .object(["type": .string("string")])

    private func tool(_ name: String, properties: [String: JSONValue], required: [String],
                      extra: [String: JSONValue] = [:]) -> JSONValue {
        var fields = extra
        fields["name"] = .string(name)
        fields["inputSchema"] = .object(["type": .string("object"), "properties": .object(properties),
            "required": .array(required.map(JSONValue.string))])
        return .object(fields)
    }

    private func catalog(_ tools: [JSONValue]) -> JSONValue { .object(["tools": .array(tools)]) }

    private func find(_ name: String, in catalog: JSONValue) -> JSONValue? {
        guard case .array(let tools)? = field(catalog, "tools") else { return nil }
        return tools.first { field($0, "name") == .string(name) }
    }

    private func field(_ value: JSONValue, _ path: String...) -> JSONValue? {
        var value = value
        for key in path {
            guard case .object(let fields) = value, let next = fields[key] else { return nil }
            value = next
        }
        return value
    }
}
