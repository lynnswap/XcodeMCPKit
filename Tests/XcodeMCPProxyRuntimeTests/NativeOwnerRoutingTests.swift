@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

@Suite(.serialized, .asyncTestCleanup)
struct NativeOwnerRoutingTests {
    @Test(arguments: ["workspace", "tab", "session", "native-empty", "native-opaque", "scoped-workspace", "scoped-workspace-argument"])
    func providerSelectorsForwardOnlyTheSelectedSDKArguments(selection: String) async throws {
        let native = TestUpstreamClient()
        let gui = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 990, xcodeVersion: "27.0")
        let config = makeConfig(requestTimeout: 5)
        let fixture = RuntimeCoordinatorFixture(config: config, upstreams: [native, gui],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [1])], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        for index in 0...1 { manager.markUpstreamInitialized(upstreamIndex: index) }
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]), sourceUpstream: 0)
        let name = selection == "session" ? "DeviceInteractionSynthesize" : "DynamicTool"
        var nativeFields: [String: Any] = ["a": ["type": "string"], "sdkExtra": ["type": "string"]]
        var guiFields: [String: Any] = ["b": ["type": "string"], "sdkExtra": ["type": "string"]]
        var nativeRequired = ["a"]
        var guiRequired = ["b"]
        if selection == "native-opaque" {
            nativeFields["workspaceIdentifier"] = ["type": "string"]
            nativeRequired.append("workspaceIdentifier")
        }
        if selection == "session" {
            nativeFields["interactSessionKey"] = ["type": "string"]
            guiFields["interactSessionKey"] = ["type": "string"]
            nativeRequired.append("interactSessionKey")
            guiRequired.append("interactSessionKey")
        }
        if selection == "scoped-workspace" {
            guiFields["tabIdentifier"] = ["type": "string"]
            guiRequired.append("tabIdentifier")
        }
        if selection == "scoped-workspace-argument" {
            guiFields["workspaceIdentifier"] = ["type": "string"]
            guiRequired.append("workspaceIdentifier")
        }
        func closedDescriptor(fields: [String: Any], required: [String]) -> [String: Any] {
            ["name": name, "inputSchema": ["type": "object", "properties": fields,
                "required": required, "additionalProperties": false]]
        }
        let nativeDescriptor = closedDescriptor(fields: nativeFields, required: nativeRequired)
        let guiDescriptor = closedDescriptor(fields: guiFields, required: guiRequired)
        try seedUnboundToolCatalog(on: manager, upstreamIndex: 0, tools: [nativeDescriptor])
        try seedProcessToolCatalogs(on: manager, entries: [(target, 1, [guiDescriptor, toolDescriptor(name: "XcodeListWindows")])])
        #expect(manager.recordXcodeWindowOwners(from: try jsonValue(["structuredContent": [
            "message": "* tabIdentifier: gui-tab, workspacePath: /Work/App.xcodeproj"]]), upstreamIndex: 1))
        let guiLease = manager.operationLeaseForTest(upstreamIndex: 1)
        if selection == "session" {
            manager.recordDeviceInteractionAffinityIfNeeded(
                requestData: try JSONRPC.Wire.data(from: toolsCallObject(id: 1, name: "DeviceInteractionStartSession",
                    arguments: ["sessionIdentifier": "Selected GUI"])),
                responseData: try JSONRPC.Wire.resultResponseData(id: try #require(JSONRPC.ID(any: 1)), result: .object([
                    "structuredContent": .object(["interactionSessionKey": .string("gui-session")])])),
                operationLease: guiLease)
        }
        let isNative = selection == "native-empty" || selection == "native-opaque"
        var arguments: [String: Any] = isNative ? ["a": "native-value"] : ["b": "gui-value"]
        arguments["sdkExtra"] = "preserved"
        switch selection {
        case "workspace", "scoped-workspace", "scoped-workspace-argument": arguments["workspaceIdentifier"] = "/Work/App.xcodeproj"
        case "tab": arguments["tabIdentifier"] = "gui-tab"
        case "session": arguments["interactSessionKey"] = "gui-session"
        case "native-opaque":
            arguments["workspaceIdentifier"] = "opaque-native"
            arguments["tabIdentifier"] = ""
        default: arguments["workspaceIdentifier"] = ""
        }
        let request = toolsCallObject(id: 220, name: name, arguments: arguments)
        let requestData = try JSONRPC.Wire.data(from: request)
        let routing = Task { await manager.toolRoutingDecision(
            for: try JSONRPC.Wire.object(fromData: requestData), requestTimeoutOverride: .seconds(2)) }
        if selection == "native-opaque" {
            let inventory = try await sentMessage(from: native, matching: {
                toolCallName(from: $0) == "XcodeListWorkspaces"
            }, timeout: .seconds(2))
            await native.yield(.message(try makeXcodeListWindowsResponse(id: extractUpstreamID(from: inventory),
                message: "* workspaceIdentifier: opaque-native, workspacePath: /Work/Owned.xcodeproj")))
        }
        let decision = try await routing.value
        guard case .forwardAdmitted(let indices, let admission) = decision else {
            Issue.record("The existing selector must choose its provider"); return
        }
        let selectedIndex = isNative ? 0 : 1
        let selected = selectedIndex == 0 ? native : gui
        #expect(indices == [selectedIndex])
        #expect(admission.toolDefinition?.descriptor == (try jsonValue(selectedIndex == 0 ? nativeDescriptor : guiDescriptor)))
        let sessionID = "selected-schema"
        _ = manager.session(id: sessionID)
        manager.sessionRegistry.markInitialized(id: sessionID, negotiatedProtocolVersion: MCP.ProtocolVersion.current)
        let executor = ClientMCPRequestExecutor(config: config, sessionManager: manager,
            refreshCodeIssuesCoordinator: .makeDefault(),
            refreshCodeIssuesDebugState: .init(defaultRequestTimeoutSeconds: config.requestTimeout))
        let operation = executor.handle(bodyData: try JSONRPC.Wire.data(from: request),
            headerSessionID: sessionID, headerSessionExists: true, prefersEventStream: false, eventLoop: fixture.eventLoop)
        if selection == "native-opaque" {
            let inventory = try await native.nextSent(at: 1)
            #expect(toolCallName(from: inventory) == "XcodeListWorkspaces")
            await native.yield(.message(try makeXcodeListWindowsResponse(id: extractUpstreamID(from: inventory),
                message: "* workspaceIdentifier: opaque-native, workspacePath: /Work/Owned.xcodeproj")))
        }
        let sent = try await sentMessage(from: selected, matching: {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == name
        }, timeout: .seconds(2))
        let params = try #require(try JSONRPC.Wire.object(fromData: sent)["params"] as? [String: Any])
        var expected: [String: JSONValue] = selectedIndex == 0 ? ["a": .string("native-value")] : ["b": .string("gui-value")]
        expected["sdkExtra"] = .string("preserved")
        if selection == "session" { expected["interactSessionKey"] = .string("gui-session") }
        if selection == "scoped-workspace" { expected["tabIdentifier"] = .string("gui-tab") }
        if selection == "scoped-workspace-argument" { expected["workspaceIdentifier"] = .string("gui-tab") }
        if selection == "native-opaque" { expected["workspaceIdentifier"] = .string("opaque-native") }
        #expect(JSONValue(any: try #require(params["arguments"])) == .object(expected))
        await selected.yield(.message(try makeJSONRPCResponse(id: extractUpstreamID(from: sent), result: [
            "content": [["type": "text", "text": "Selected provider completed"]]])))
        _ = try await waitWithTimeout("waiting for the selected provider", timeout: .seconds(2)) {
            try await operation.future.get()
        }
        await manager.drainRuntimeTasksForTesting()
        #expect(await native.sentCount() == (selection == "native-opaque" ? 3 : selectedIndex == 0 ? 1 : 0))
        #expect(await gui.sentCount() == (selectedIndex == 1 ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func availableGUIProviderSurvivesSelectedNativeCatalogFailure(fails: Bool) async throws {
        let native = TestUpstreamClient()
        let gui = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 992, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(upstreams: [native, gui],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [1])], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]), sourceUpstream: 1)
        try seedProcessToolCatalogs(on: manager, entries: [(target, 1, [toolDescriptor(name: "GUIAvailableTool")])])
        let load = Task {
            try await manager.sharedToolsList(sessionID: "native-catalog", requestTimeoutOverride: .seconds(2))
        }
        let guiRequest = try await gui.nextSent { methodName(from: $0) == "tools/list" }
        await gui.yield(.message(try makeDocumentationToolsListResponse(
            id: extractUpstreamID(from: guiRequest), tools: [toolDescriptor(name: "GUIAvailableTool")])))
        let request = try await native.nextSent { methodName(from: $0) == "tools/list" }
        let id = try extractUpstreamID(from: request)
        if fails {
            await native.yield(.message(try JSONRPC.Wire.errorResponseData(
                id: JSONRPC.ID(any: id), code: -32603, message: "Native catalog unavailable")))
            #expect(toolNames(in: try await load.value) == ["GUIAvailableTool"])
            #expect(manager.processControlPlane.unboundToolsCatalogRaw() == nil)
        } else {
            await native.yield(.message(try makeDocumentationToolsListResponse(
                id: id, tools: [toolDescriptor(name: "FutureNativeTool")])) )
            #expect(toolNames(in: try await load.value) == ["FutureNativeTool", "GUIAvailableTool"])
        }
    }

    @Test func ordinaryWorkspacePathIsPassedToTheOwnedHostWithoutInventoryOrOpenRPCs() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let path = "/Work/NewProject.xcodeproj"
        let decision = await manager.toolRoutingDecision(for: toolsCallObject(
            id: 100, name: "FutureWorkspaceTool", arguments: ["workspaceIdentifier": path]), requestTimeoutOverride: .seconds(1))
        guard case .forwardAdmitted(let indices, let admission) = decision else {
            Issue.record("A workspace path without a GUI owner must reach the owned host")
            return
        }
        #expect(indices == [0])
        #expect(admission.workspaceIdentifier == path)
        #expect(admission.route == nil)
        #expect(await upstream.sentCount() == 0)
    }

    @Test(arguments: [false, true])
    func nativeIdentifiersAndClosePathsRemainBoundToTheOwnedHost(close: Bool) async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        fixture.manager.markUpstreamInitialized(upstreamIndex: 0)
        let selector = close ? "/Work/Absent.xcodeproj" : "native-workspace-id"
        let routing = Task {
            await fixture.manager.toolRoutingDecision(for: toolsCallObject(
                id: 101, name: close ? "XcodeCloseWorkspace" : "FutureWorkspaceTool",
                arguments: ["workspaceIdentifier": selector]), requestTimeoutOverride: .seconds(1))
        }
        if !close {
            let inventory = try await upstream.nextSent { toolCallName(from: $0) == "XcodeListWorkspaces" }
            await upstream.yield(.message(try makeXcodeListWindowsResponse(
                id: extractUpstreamID(from: inventory),
                message: "* workspaceIdentifier: native-workspace-id, workspacePath: /Work/Owned.xcodeproj")))
        }
        let decision = await routing.value
        guard case .forwardAdmitted(let indices, let admission) = decision else {
            Issue.record("Owned native workspace identity must stay with its host")
            return
        }
        #expect(indices == [0])
        #expect(admission.route == nil)
        #expect(await upstream.sentCount() == (close ? 0 : 1))
    }

    @Test(arguments: ["path", "symlink", "failure"])
    func GUIInventorySelectsTheOwnerAndFailuresAreNotHiddenByTheNativeHost(kind: String) async throws {
        let native = TestUpstreamClient()
        let gui = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 991, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(upstreams: [native, gui],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [1])], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(on: manager, entries: [(target, 1, [
            toolDescriptor(name: "XcodeListWindows"), ownerBoundToolDescriptor(name: "FutureWorkspaceTool"),
        ])])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias.xcodeproj")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        let selector = kind == "identifier" ? "gui-tab" : kind == "symlink" ? alias.path : project.path
        let task = Task {
            await manager.toolRoutingDecision(for: toolsCallObject(id: 102, name: "FutureWorkspaceTool",
                arguments: ["workspaceIdentifier": selector]), requestTimeoutOverride: .seconds(2))
        }
        if kind == "identifier" {
            let inventory = try await native.nextSent { toolCallName(from: $0) == "XcodeListWorkspaces" }
            await native.yield(.message(try makeXcodeListWindowsResponse(
                id: extractUpstreamID(from: inventory), message: "No workspaces are open.")))
        }
        let request = try await gui.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        let id = try extractUpstreamID(from: request)
        if kind == "failure" {
            await gui.yield(.message(try JSONRPC.Wire.errorResponseData(
                id: JSONRPC.ID(any: id), code: -32603, message: "GUI inventory failed")))
        } else {
            await gui.yield(.message(try makeXcodeListWindowsResponse(id: id,
                message: "* tabIdentifier: gui-tab, workspacePath: \(project.path)")))
        }
        let decision = await task.value
        if kind == "failure" {
            guard case .reject(let errors) = decision else {
                Issue.record("Incomplete GUI inventory must fail instead of falling back")
                return
            }
            #expect(errors.first?.message.contains("Unable to determine GUI workspace ownership") == true)
        } else {
            guard case .forwardAdmitted(let indices, let admission) = decision else {
                Issue.record("Native GUI ownership must take precedence")
                return
            }
            #expect(indices == [1])
            #expect(admission.window?.rewritePlan.tabIdentifier == "gui-tab")
        }
        #expect(await native.sentCount() == (kind == "identifier" ? 1 : 0))
    }

    @Test func ownedNativeIdentifierDoesNotQueryAnUnrelatedColdGUI() async throws {
        let native = TestUpstreamClient()
        let coldGUI = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 993, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(upstreams: [native, coldGUI],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [1])], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let proof = manager.operationLeaseForTest(upstreamIndex: 0).proof
        let task = Task { await manager.toolRoutingDecision(for: toolsCallObject(id: 103, name: "FutureWorkspaceTool",
            arguments: ["workspaceIdentifier": "opaque-owned-token"]), requestTimeoutOverride: .seconds(1)) }
        let inventory = try await native.nextSent { toolCallName(from: $0) == "XcodeListWorkspaces" }
        await native.yield(.message(try makeJSONRPCResponse(id: extractUpstreamID(from: inventory),
            result: ["structuredContent": ["message": "* workspaceIdentifier: opaque-owned-token, workspacePath: /Work/App.xcodeproj"]])))
        guard case .forwardAdmitted(let indices, let admission) = await task.value else {
            Issue.record("Native ownership proof must not require unrelated GUI discovery")
            return
        }
        #expect(indices == [0])
        #expect(admission.upstreamProofs == [proof])
        #expect(admission.workspaceIdentifier == "opaque-owned-token")
        #expect(await coldGUI.sentCount() == 0)
    }

    @Test(arguments: [false, true])
    func cachedGUIIdentifiersTakePriorityOverNativeLookup(proxyIdentifier: Bool) async throws {
        let native = TestUpstreamClient()
        let gui = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 994, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(upstreams: [native, gui],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [1])], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(on: manager, entries: [(target, 1, [
            toolDescriptor(name: "XcodeListWindows"), ownerBoundToolDescriptor(name: "FutureWorkspaceTool")])])
        #expect(manager.recordXcodeWindowOwners(from: try jsonValue(["structuredContent": [
            "message": "* tabIdentifier: shared-opaque-token, workspacePath: /Work/App.xcodeproj"]]), upstreamIndex: 1))
        let proxyID = try #require(manager.windowOwnershipAuthority.snapshot().identities.first?.proxyTabIdentifier)
        let decision = await manager.toolRoutingDecision(for: toolsCallObject(id: 104, name: "FutureWorkspaceTool",
            arguments: ["workspaceIdentifier": proxyIdentifier ? proxyID : "shared-opaque-token"]), requestTimeoutOverride: .seconds(1))
        guard case .forwardAdmitted(let indices, let admission) = decision else {
            Issue.record("A cached GUI identity must select that GUI")
            return
        }
        #expect(indices == [1])
        #expect(admission.window?.rewritePlan.tabIdentifier == "shared-opaque-token")
        #expect(await native.sentCount() == 0)
    }

    @Test func unknownOpaqueIdentifierCannotBypassFailedGUIInventory() async throws {
        let native = TestUpstreamClient()
        let gui = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 995, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(upstreams: [native, gui],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [1])], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(on: manager, entries: [(target, 1, [toolDescriptor(name: "XcodeListWindows")])])
        let task = Task { await manager.toolRoutingDecision(for: toolsCallObject(id: 106, name: "FutureWorkspaceTool",
            arguments: ["workspaceIdentifier": "unknown-opaque-token"]), requestTimeoutOverride: .seconds(1)) }
        let inventory = try await native.nextSent { toolCallName(from: $0) == "XcodeListWorkspaces" }
        await native.yield(.message(try makeJSONRPCResponse(id: extractUpstreamID(from: inventory),
            result: ["structuredContent": ["message": "No native workspace is open."]])))
        let guiInventory = try await gui.nextSent { toolCallName(from: $0) == "XcodeListWindows" }
        await gui.yield(.message(try JSONRPC.Wire.errorResponseData(id: JSONRPC.ID(any: extractUpstreamID(from: guiInventory)),
            code: -32603, message: "GUI inventory unavailable")))
        guard case .reject(let errors) = await task.value else {
            Issue.record("An unknown identity requires complete ownership discovery")
            return
        }
        #expect(errors.first?.message.contains("Unable to determine GUI workspace ownership") == true)
        #expect(await native.sentCount() == 1)
    }

    @Test(arguments: ["FutureWorkspaceTool", "XcodeRefreshCodeIssuesInFile"])
    func selectedNativeOwnerBoundToolRunsWithoutASelectorAndDoesNotRetryGUIOnToolError(toolName: String) async throws {
        let native = TestUpstreamClient()
        let oldGUI = TestUpstreamClient()
        let newGUI = TestUpstreamClient()
        let oldTarget = xcodeProcessTarget(processID: 810, xcodeVersion: "26.6")
        let newTarget = xcodeProcessTarget(processID: 811, xcodeVersion: "27.0")
        let config = makeConfig(requestTimeout: 5)
        let fixture = RuntimeCoordinatorFixture(
            config: config, upstreams: [native, oldGUI, newGUI],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: oldTarget, upstreamIndices: [1]),
                XcodeProcessRoute(target: newTarget, upstreamIndices: [2]),
            ], startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        for index in 0...2 { manager.markUpstreamInitialized(upstreamIndex: index) }
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]),
            sourceUpstream: 0)
        let nativeDescriptor = toolDescriptor(
            name: toolName, description: "Selected native definition",
            inputProperties: ["workspaceIdentifier": ["type": "string"], "filePath": ["type": "string"]],
            required: ["filePath"], outputSchema: ["type": "object"]
        )
        try seedUnboundToolCatalog(on: manager, upstreamIndex: 0, tools: [nativeDescriptor])
        try seedProcessToolCatalogs(on: manager, entries: [
            (oldTarget, 1, [ownerBoundToolDescriptor(name: toolName), toolDescriptor(name: "XcodeListWindows")]),
            (newTarget, 2, [ownerBoundToolDescriptor(name: toolName), toolDescriptor(name: "XcodeListWindows")]),
        ])
        let request = toolsCallObject(id: 210, name: toolName, arguments: ["filePath": "Source.swift"])
        let decision = await manager.toolRoutingDecision(for: request, requestTimeoutOverride: .seconds(2))
        guard case .forwardAdmitted(let indices, let admission) = decision else {
            Issue.record("A native owner-bound tool must be usable without a workspace selector")
            return
        }
        let proof = manager.operationLeaseForTest(upstreamIndex: 0).proof
        #expect(indices == [0])
        #expect(admission.upstreamProofs == [proof])
        #expect(admission.route == nil)
        #expect(admission.workspaceIdentifier == nil)
        #expect(admission.toolDefinition?.sourceProof == proof)
        #expect(admission.toolDefinition?.descriptor == (try jsonValue(nativeDescriptor)))
        #expect(await native.sentCount() == 0)
        #expect(await oldGUI.sentCount() == 0)
        #expect(await newGUI.sentCount() == 0)

        let sessionID = "native-preferred-without-workspace"
        _ = manager.session(id: sessionID)
        manager.sessionRegistry.markInitialized(id: sessionID, negotiatedProtocolVersion: MCP.ProtocolVersion.current)
        let executor = ClientMCPRequestExecutor(
            config: config, sessionManager: manager
        )
        let operation = executor.handle(
            bodyData: try JSONRPC.Wire.data(from: request),
            headerSessionID: sessionID, headerSessionExists: true,
            prefersEventStream: false, eventLoop: fixture.eventLoop
        )
        let sent = try await sentMessage(from: native, matching: {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == toolName
        }, timeout: .seconds(2))
        let sentObject = try JSONRPC.Wire.object(fromData: sent)
        let params = try #require(sentObject["params"] as? [String: Any])
        #expect(JSONValue(any: try #require(params["arguments"])) == .object(["filePath": .string("Source.swift")]))
        let nativeError: JSONValue = .object([
            "isError": .bool(true),
            "content": .array([.object(["type": .string("text"), "text": .string("(SourceEditorServiceErrorDomain error 5.)")])]),
        ])
        await native.yield(.message(try JSONRPC.Wire.resultResponseData(
            id: try #require(JSONRPC.ID(any: extractUpstreamID(from: sent))), result: nativeError
        )))
        let resolution = try await waitWithTimeout("waiting for the native tool error without GUI retry", timeout: .seconds(2)) {
            try await operation.future.get()
        }
        guard case .responseData(let data, _, _) = resolution else {
            Issue.record("The native tool error must remain an MCP tool result")
            return
        }
        let response = try JSONRPC.Wire.object(fromData: data)
        #expect((response["id"] as? NSNumber)?.int64Value == 210)
        #expect(JSONValue(any: try #require(response["result"])) == nativeError)
        await manager.drainRuntimeTasksForTesting()
        #expect(await native.sentCount() == 1)
        #expect(await oldGUI.sentCount() == 0)
        #expect(await newGUI.sentCount() == 0)
    }

    @Test(arguments: [false, true])
    func anUnscopedToolSelectsAStableGUIProviderWhenNativeDoesNotOfferIt(nativeInitialized: Bool) async throws {
        let native = TestUpstreamClient()
        let newGUI = TestUpstreamClient()
        let oldGUI = TestUpstreamClient()
        let newTarget = xcodeProcessTarget(processID: 811, xcodeVersion: "27.0")
        let oldTarget = xcodeProcessTarget(processID: 810, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [native, newGUI, oldGUI],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: newTarget, upstreamIndices: [1]),
                XcodeProcessRoute(target: oldTarget, upstreamIndices: [2]),
            ], startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        for index in 1...2 { manager.markUpstreamInitialized(upstreamIndex: index) }
        if nativeInitialized {
            manager.markUpstreamInitialized(upstreamIndex: 0)
            try seedUnboundToolCatalog(on: manager, upstreamIndex: 0, tools: [toolDescriptor(name: "OtherNativeTool")])
        }
        let oldDescriptor = toolDescriptor(name: "DocumentationLikeTool", description: "Actual Xcode 26 provider",
            inputProperties: ["query": ["type": "string"]], required: ["query"])
        let newDescriptor = toolDescriptor(name: "DocumentationLikeTool", description: "Actual Xcode 27 provider",
            inputProperties: ["query": ["type": "string"]], required: ["query"])
        try seedProcessToolCatalogs(on: manager, entries: [
            (newTarget, 1, [newDescriptor]), (oldTarget, 2, [oldDescriptor]),
        ])
        let decision = await manager.toolRoutingDecision(for: toolsCallObject(
            id: 211, name: "DocumentationLikeTool", arguments: ["query": "read docs"]),
            requestTimeoutOverride: .seconds(2))
        guard case .forwardAdmitted(let indices, let admission) = decision else {
            Issue.record("An unscoped tool must select an available GUI provider when native does not offer it")
            return
        }
        let proof = manager.operationLeaseForTest(upstreamIndex: 2).proof
        #expect(indices == [2])
        #expect(admission.route?.routeID.processID == oldTarget.processID)
        #expect(admission.toolDefinition?.sourceProof == proof)
        #expect(admission.toolDefinition?.descriptor == (try jsonValue(oldDescriptor)))
        #expect(manager.processControlPlane.defaultToolProvider(named: "DocumentationLikeTool")?.sourceProof == proof)
        guard case .object(let published)? = ProcessToolCatalogCodec.toolsByName(
            in: manager.cachedToolsListResult())["DocumentationLikeTool"],
              case .object(let metadata)? = published["_meta"],
              case .array(let origins)? = metadata[ToolCatalogProvider.providersMetadataKey],
              case .object(let first)? = origins.first else {
            Issue.record("Missing published default provider"); return
        }
        #expect(first["descriptor"] == (try jsonValue(oldDescriptor)))
        #expect(await native.sentCount() == 0)
        #expect(await newGUI.sentCount() == 0)
        #expect(await oldGUI.sentCount() == 0)
    }

    @Test func anOwnerBoundToolWithoutANativeDefinitionRequiresAGUIWorkspaceSelector() async throws {
        let native = TestUpstreamClient()
        let oldGUI = TestUpstreamClient()
        let newGUI = TestUpstreamClient()
        let oldTarget = xcodeProcessTarget(processID: 810, xcodeVersion: "26.6")
        let newTarget = xcodeProcessTarget(processID: 811, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [native, oldGUI, newGUI],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: oldTarget, upstreamIndices: [1]),
                XcodeProcessRoute(target: newTarget, upstreamIndices: [2]),
            ], startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        for index in 0...2 { manager.markUpstreamInitialized(upstreamIndex: index) }
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]),
            sourceUpstream: 0)
        try seedUnboundToolCatalog(on: manager, upstreamIndex: 0, tools: [toolDescriptor(name: "OtherNativeTool")])
        let tools = [ownerBoundToolDescriptor(name: "FutureWorkspaceTool"), toolDescriptor(name: "XcodeListWindows")]
        try seedProcessToolCatalogs(on: manager, entries: [(oldTarget, 1, tools), (newTarget, 2, tools)])
        let routing = Task {
            await manager.toolRoutingDecision(for: toolsCallObject(id: 212, name: "FutureWorkspaceTool", arguments: [:]),
                requestTimeoutOverride: .seconds(2))
        }
        defer { routing.cancel() }
        for (upstream, tab, path) in [
            (oldGUI, "old-gui-tab", "/Work/Old.xcworkspace"),
            (newGUI, "new-gui-tab", "/Work/New.xcworkspace"),
        ] {
            let inventory = try await sentMessage(from: upstream, matching: {
                methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
            }, timeout: .seconds(2))
            await upstream.yield(.message(try makeXcodeListWindowsResponse(
                id: extractUpstreamID(from: inventory), message: "* tabIdentifier: \(tab), workspacePath: \(path)")))
        }
        let decision = try await waitWithTimeout("waiting for ambiguous GUI ownership rejection", timeout: .seconds(2)) {
            await routing.value
        }
        guard case .reject(let errors) = decision else {
            Issue.record("Two GUI owners must require a workspace selector when native does not offer the tool")
            return
        }
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("owner") == true)
        #expect(await native.sentCount() == 0)
        #expect(await oldGUI.sentCount() == 1)
        #expect(await newGUI.sentCount() == 1)
    }

    @Test func requestsShareOneNativeConnectionAndCancellingOneDoesNotBlockTheOthers() {
        let eventLoop = EmbeddedEventLoop()
        let topology = UpstreamTopologyAuthority([TestUpstreamClient()])
        let started = NIOLockedValueBox<[UUID]>([])
        let cancelled = NIOLockedValueBox<[UUID]>([])
        let scheduler = UpstreamSlotScheduler(isLeaseLive: { _ in true }, canUseUpstream: { index in
            .init(proof: topology.snapshot().proof(UpstreamSlotID(rawValue: index)), effects: [])
        }, selectUpstream: { _ in .init(proof: topology.snapshot().proof(UpstreamSlotID(rawValue: 0)), effects: []) },
            operationLease: { topology.operationLease(for: $0) }, validateOperationLease: { topology.validate($0) })
        defer { scheduler.reset(); eventLoop.run() }
        let leases = [UUID(), UUID(), UUID()]
        let descriptor = SessionRequestPipeline.Descriptor(sessionID: "native-multiplex", label: "tools/call",
            expectsResponse: true, isTopLevelClientRequest: true)
        for lease in leases {
            scheduler.enqueueRequest(leaseID: lease, descriptor: descriptor, on: eventLoop, preferredUpstreamIndex: 0,
                starter: { _ in started.withLockedValue { $0.append(lease) } },
                failUnavailable: { Issue.record("The live native connection must accept all requests") },
                failCancelled: { cancelled.withLockedValue { $0.append(lease) } })
        }
        scheduler.cancelQueuedRequest(leaseID: leases[2])
        eventLoop.run()
        #expect(Set(started.withLockedValue { $0 }) == Set(leases.prefix(2)))
        #expect(cancelled.withLockedValue { $0 } == [leases[2]])
        #expect(scheduler.debugSnapshot().activeLeaseCountByUpstream == [0: 2])
        scheduler.releaseUpstreamSlot(upstreamIndex: 0, leaseID: leases[0])
        #expect(scheduler.debugSnapshot().activeLeaseCountByUpstream == [0: 1])
    }
}
