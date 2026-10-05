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
    @Test func concurrentRequestsShareTheInFlightRefreshAndReturnTheNewVersion() async throws {
        let native = TestUpstreamClient()
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let fixture = RuntimeCoordinatorFixture(upstreams: [native], clock: clocks.clock,
            startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]),
            sourceUpstream: 0)
        try seedNativeToolCatalog(on: manager, upstreamIndex: 0, tools: [descriptor(version: 1)])
        let first = Task { try await manager.sharedToolsList(sessionID: "fresh-shared-first",
            requestTimeoutOverride: .seconds(5)) }
        defer { first.cancel() }
        let lowerRequest = try await sentMessage(from: native, matching: { methodName(from: $0) == "tools/list" },
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
        #expect(await native.sentCount() == 1)
        await native.yield(.message(try makeDocumentationToolsListResponse(
            id: extractUpstreamID(from: lowerRequest), tools: [descriptor(version: 2)])))
        try expectVersion2(in: try await first.value)
        try expectVersion2(in: try await second.value)
        #expect(await native.sentCount() == 1)
    }


    private func descriptor(version: Int) -> [String: Any] {
        toolDescriptor(name: "ChangingTool", description: "native version \(version)",
            inputProperties: ["argument\(version)": ["type": "string"]])
    }

    private func expectVersion2(in result: JSONValue) throws {
        guard case .object(let tool)? = ToolCatalogCodec.toolsByName(in: result)["ChangingTool"],
              case .object(let input)? = tool["inputSchema"],
              case .object(let properties)? = input["properties"] else {
            Issue.record("Missing refreshed tool"); return
        }
        #expect(tool["description"] == .string("native version 2"))
        #expect(properties["argument2"] != nil)
        #expect(properties["argument1"] == nil)
    }
}
