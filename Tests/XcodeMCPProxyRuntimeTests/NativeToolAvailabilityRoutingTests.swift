@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Foundation
import NIO
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

@Suite(.serialized, .timeLimit(.minutes(1)), .asyncTestCleanup)
struct NativeToolAvailabilityRoutingTests {
    @Test(arguments: ["opaque", "session"])
    func aKnownNativeOwnerCannotUseAnotherProvidersAdvertisedTool(selector: String) async throws {
        let native = TestUpstreamClient()
        let gui = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 7802, xcodeVersion: "27.0")
        let config = makeConfig(requestTimeout: 5)
        let fixture = RuntimeCoordinatorFixture(config: config, upstreams: [native, gui],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [1])], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        for index in 0...1 { manager.markUpstreamInitialized(upstreamIndex: index) }
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]), sourceUpstream: 0)
        let name = selector == "session" ? "DeviceInteractionSynthesize" : "GUIOnlyTool"
        try seedUnboundToolCatalog(on: manager, upstreamIndex: 0, tools: [toolDescriptor(name: "NativeTool")])
        try seedProcessToolCatalogs(on: manager, entries: [(target, 1, [toolDescriptor(name: name)])])
        #expect(toolNames(in: try #require(manager.cachedToolsListResult())).contains(name))
        let nativeLease = manager.operationLeaseForTest(upstreamIndex: 0)
        if selector == "session" {
            manager.recordDeviceInteractionAffinityIfNeeded(
                requestData: try JSONRPC.Wire.data(from: toolsCallObject(id: 1, name: "DeviceInteractionStartSession", arguments: [:])),
                responseData: try makeJSONRPCResponse(id: 1, result: ["structuredContent": ["interactionSessionKey": "native-session"]]),
                operationLease: nativeLease)
        }
        let arguments: [String: Any] = selector == "session"
            ? ["interactSessionKey": "native-session"] : ["workspaceIdentifier": "native-workspace"]
        let sessionID = "native-owner-availability-\(selector)"
        _ = manager.session(id: sessionID)
        manager.sessionRegistry.markInitialized(id: sessionID, negotiatedProtocolVersion: MCP.ProtocolVersion.current)
        let executor = ClientMCPRequestExecutor(config: config, sessionManager: manager)
        let operation = executor.handle(bodyData: try JSONRPC.Wire.data(from: toolsCallObject(id: 231, name: name, arguments: arguments)),
            headerSessionID: sessionID, headerSessionExists: true, prefersEventStream: false, eventLoop: fixture.eventLoop)
        if selector == "opaque" {
            let inventory = try await sentMessage(from: native, matching: { toolCallName(from: $0) == "XcodeListWorkspaces" }, timeout: .seconds(2))
            await native.yield(.message(try makeXcodeListWindowsResponse(id: extractUpstreamID(from: inventory),
                message: "* workspaceIdentifier: native-workspace, workspacePath: /Work/Owned.xcodeproj")))
        }
        let resolution = try await waitWithTimeout("waiting for the native owner's advertised capability result", timeout: .seconds(2)) {
            try await operation.future.get()
        }
        guard case .responseData(let data, _, _) = resolution else {
            Issue.record("The native owner must report its missing capability")
            return
        }
        let result = try #require(try JSONRPC.Wire.object(fromData: data)["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "tool is not available in the selected native host")
        await manager.drainRuntimeTasksForTesting()
        #expect(await native.sent().filter { toolCallName(from: $0) == name }.isEmpty)
        #expect(await gui.sentCount() == 0)
    }

    @Test(arguments: ["guiOnly", "nativeKnown", "unknown", "missingCatalog"])
    func anAbsolutePathUsesTheSelectedNativeCatalogWithoutRejectingUnknownTools(kind: String) async throws {
        let native = TestUpstreamClient()
        let gui = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 7801, xcodeVersion: "27.0")
        let config = makeConfig(requestTimeout: 5)
        let fixture = RuntimeCoordinatorFixture(config: config, upstreams: [native, gui],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [1])], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        for index in 0...1 { manager.markUpstreamInitialized(upstreamIndex: index) }
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]), sourceUpstream: 0)
        let nativeDescriptor = toolDescriptor(name: "NativeWorkspaceTool", inputProperties: [
            "workspaceIdentifier": ["type": "string"]], required: ["workspaceIdentifier"])
        let load = Task { try await manager.sharedToolsList(sessionID: "availability-catalog", requestTimeoutOverride: .seconds(5)) }
        defer { load.cancel() }
        let nativeCatalog = try await sentMessage(from: native, matching: { methodName(from: $0) == "tools/list" }, timeout: .seconds(2))
        let guiCatalog = try await sentMessage(from: gui, matching: { methodName(from: $0) == "tools/list" }, timeout: .seconds(2))
        if kind == "missingCatalog" {
            await native.yield(.message(try JSONRPC.Wire.errorResponseData(
                id: JSONRPC.ID(any: extractUpstreamID(from: nativeCatalog)), code: -32603, message: "Native catalog is not available yet")))
        } else {
            await native.yield(.message(try makeDocumentationToolsListResponse(
                id: extractUpstreamID(from: nativeCatalog), tools: [nativeDescriptor])))
        }
        await gui.yield(.message(try makeDocumentationToolsListResponse(
            id: extractUpstreamID(from: guiCatalog), tools: [ownerBoundToolDescriptor(name: "GUIOnlyTool"), toolDescriptor(name: "XcodeListWindows")])))
        let advertised = try await load.value
        #expect(toolNames(in: advertised).contains("GUIOnlyTool"))
        #expect((manager.processControlPlane.unboundToolsCatalogProvider() != nil) == (kind != "missingCatalog"))

        let name = kind == "nativeKnown" ? "NativeWorkspaceTool" : kind == "unknown" ? "UnknownSDKTool" : "GUIOnlyTool"
        let path = "/Work/NoGUIOwner.xcodeproj"
        let request = toolsCallObject(id: 230, name: name, arguments: ["workspaceIdentifier": path])
        let sessionID = "availability-call-\(kind)"
        _ = manager.session(id: sessionID)
        manager.sessionRegistry.markInitialized(id: sessionID, negotiatedProtocolVersion: MCP.ProtocolVersion.current)
        let executor = ClientMCPRequestExecutor(config: config, sessionManager: manager)
        let operation = executor.handle(bodyData: try JSONRPC.Wire.data(from: request),
            headerSessionID: sessionID, headerSessionExists: true, prefersEventStream: false, eventLoop: fixture.eventLoop)
        let inventory = try await sentMessage(from: gui, matching: {
            toolCallName(from: $0) == "XcodeListWindows"
        }, timeout: .seconds(2))
        await gui.yield(.message(try makeXcodeListWindowsResponse(
            id: extractUpstreamID(from: inventory), message: "No Xcode windows are open.")))
        if kind != "guiOnly" {
            let call = try await sentMessage(from: native, matching: {
                methodName(from: $0) == "tools/call" && toolCallName(from: $0) == name
            }, timeout: .seconds(2))
            let params = try #require(try JSONRPC.Wire.object(fromData: call)["params"] as? [String: Any])
            #expect(JSONValue(any: try #require(params["arguments"])) == .object(["workspaceIdentifier": .string(path)]))
            if kind == "nativeKnown" {
                await native.yield(.message(try makeJSONRPCResponse(id: extractUpstreamID(from: call),
                    result: ["content": [["type": "text", "text": "Native completed"]], "isError": false])))
            } else {
                await native.yield(.message(try JSONRPC.Wire.errorResponseData(
                    id: JSONRPC.ID(any: extractUpstreamID(from: call)), code: -32602, message: "SDK rejected \(name)")))
            }
        }
        let resolution = try await waitWithTimeout("waiting for the selected native availability result", timeout: .seconds(2)) {
            try await operation.future.get()
        }
        guard case .responseData(let responseData, _, _) = resolution else {
            Issue.record("The tool must return its selected-owner availability or SDK result")
            return
        }
        let response = try JSONRPC.Wire.object(fromData: responseData)
        if kind == "guiOnly" {
            let result = try #require(response["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == true)
            let content = try #require(result["content"] as? [[String: Any]])
            #expect(content.first?["text"] as? String == "tool is not available in the selected native host")
        } else if kind == "nativeKnown" {
            #expect(response["result"] != nil)
        } else {
            let error = try #require(response["error"] as? [String: Any])
            #expect((error["code"] as? NSNumber)?.int64Value == -32602)
            #expect(error["message"] as? String == "SDK rejected \(name)")
        }
        await manager.drainRuntimeTasksForTesting()
        #expect(await native.sent().filter { methodName(from: $0) == "tools/call" }.count == (kind == "guiOnly" ? 0 : 1))
        #expect(await gui.sent().filter { methodName(from: $0) == "tools/call" }.count == 1)
    }
}
