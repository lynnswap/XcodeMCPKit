@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Foundation
import NIO
import NIOConcurrencyHelpers
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

@Suite(.serialized, .timeLimit(.minutes(1)), .asyncTestCleanup)
struct CatalogFreshnessTests {
    @Test(arguments: ["cold", "ready", "unavailable"])
    func explicitRequestReturnsTheNewGUICatalog(nativePhase: String) async throws {
        let native = TestUpstreamClient()
        let gui = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 7301, xcodeVersion: "26.6")
        var config = makeConfig(requestTimeout: 5)
        config.prewarmToolsList = false
        let fixture = RuntimeCoordinatorFixture(config: config, upstreams: [native, gui],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [1])],
            startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 1)
        if nativePhase != "cold" { manager.markUpstreamInitialized(upstreamIndex: 0) }
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]),
            sourceUpstream: 1)
        try seedProcessToolCatalogs(on: manager, entries: [(target, 1, [descriptor(version: 1)])])
        let returned = NIOLockedValueBox(false)
        let request = Task {
            let result = try await manager.sharedToolsList(sessionID: "fresh-\(nativePhase)",
                requestTimeoutOverride: .seconds(5))
            returned.withLockedValue { $0 = true }
            return result
        }
        defer { request.cancel() }
        let guiRequest = try await sentMessage(from: gui, matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2))
        if nativePhase != "cold" {
            let nativeRequest = try await sentMessage(from: native, matching: { methodName(from: $0) == "tools/list" },
                timeout: .seconds(2))
            if nativePhase == "ready" {
                await native.yield(.message(try makeDocumentationToolsListResponse(
                    id: extractUpstreamID(from: nativeRequest), tools: [toolDescriptor(name: "NativeTool")])))
            } else {
                await native.yield(.message(try JSONRPC.Wire.errorResponseData(
                    id: JSONRPC.ID(any: extractUpstreamID(from: nativeRequest)),
                    code: -32001, message: "upstream unavailable")))
            }
        }
        #expect(returned.withLockedValue { $0 } == false)
        await gui.yield(.message(try makeDocumentationToolsListResponse(
            id: extractUpstreamID(from: guiRequest), tools: [descriptor(version: 2)])))
        let result = try await request.value
        try expectVersion2(in: result)
        #expect(returned.withLockedValue { $0 })
        #expect(await gui.sentCount() == 1)
        #expect(await native.sentCount() == (nativePhase == "cold" ? 0 : 1))
    }

    @Test func concurrentRequestsShareTheInFlightRefreshAndReturnTheNewVersion() async throws {
        let native = TestUpstreamClient()
        let gui = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 7302, xcodeVersion: "26.6")
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let fixture = RuntimeCoordinatorFixture(upstreams: [native, gui], clock: clocks.clock,
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [1])],
            startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 1)
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]),
            sourceUpstream: 1)
        try seedProcessToolCatalogs(on: manager, entries: [(target, 1, [descriptor(version: 1)])])
        let first = Task { try await manager.sharedToolsList(sessionID: "fresh-shared-first",
            requestTimeoutOverride: .seconds(5)) }
        defer { first.cancel() }
        let lowerRequest = try await sentMessage(from: gui, matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2))
        let load = try #require(await manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
        let second = Task { try await manager.sharedToolsList(sessionID: "fresh-shared-second",
            requestTimeoutOverride: .seconds(5)) }
        defer { second.cancel() }
        _ = try await waitWithTimeout("waiting for both catalog callers", timeout: .seconds(2)) {
            try await manager.controlPlaneDebugMirror.waitForSnapshot { $0.waiterCounts.toolsCatalog == 2 }
        }
        let shared = try #require(await manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
        #expect(shared.loadID == load.loadID)
        #expect(await gui.sentCount() == 1)
        await gui.yield(.message(try makeDocumentationToolsListResponse(
            id: extractUpstreamID(from: lowerRequest), tools: [descriptor(version: 2)])))
        try expectVersion2(in: try await first.value)
        try expectVersion2(in: try await second.value)
        #expect(await gui.sentCount() == 1)
        #expect(await native.sentCount() == 0)
    }

    @Test func aFailedGUIRefreshDoesNotHideAnotherGUIsNewCatalog() async throws {
        let native = TestUpstreamClient()
        let healthy = TestUpstreamClient()
        let failed = TestUpstreamClient()
        let healthyTarget = xcodeProcessTarget(processID: 7303, xcodeVersion: "26.6")
        let failedTarget = xcodeProcessTarget(processID: 7304, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(upstreams: [native, healthy, failed],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: healthyTarget, upstreamIndices: [1]),
                XcodeProcessRoute(target: failedTarget, upstreamIndices: [2]),
            ], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        for index in 1...2 { manager.markUpstreamInitialized(upstreamIndex: index) }
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]),
            sourceUpstream: 1)
        try seedProcessToolCatalogs(on: manager, entries: [
            (healthyTarget, 1, [descriptor(version: 1)]),
            (failedTarget, 2, [toolDescriptor(name: "FailedProviderTool")]),
        ])
        let request = Task { try await manager.sharedToolsList(sessionID: "fresh-partial",
            requestTimeoutOverride: .seconds(5)) }
        defer { request.cancel() }
        let healthyRequest = try await sentMessage(from: healthy, matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2))
        let failedRequest = try await sentMessage(from: failed, matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2))
        await failed.yield(.message(try JSONRPC.Wire.errorResponseData(
            id: JSONRPC.ID(any: extractUpstreamID(from: failedRequest)),
            code: -32001, message: "upstream unavailable")))
        await healthy.yield(.message(try makeDocumentationToolsListResponse(
            id: extractUpstreamID(from: healthyRequest), tools: [descriptor(version: 2)])))
        try expectVersion2(in: try await request.value)
        #expect(await native.sentCount() == 0)
    }

    private func descriptor(version: Int) -> [String: Any] {
        toolDescriptor(name: "ChangingTool", description: "GUI version \(version)",
            inputProperties: ["argument\(version)": ["type": "string"]])
    }

    private func expectVersion2(in result: JSONValue) throws {
        guard case .object(let tool)? = ProcessToolCatalogCodec.toolsByName(in: result)["ChangingTool"],
              case .object(let input)? = tool["inputSchema"],
              case .object(let properties)? = input["properties"] else {
            Issue.record("Missing refreshed tool"); return
        }
        #expect(tool["description"] == .string("GUI version 2"))
        #expect(properties["argument2"] != nil)
        #expect(properties["argument1"] == nil)
    }
}

