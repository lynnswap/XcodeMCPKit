@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Foundation
import NIO
import NIOEmbedded
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

@Suite(.serialized, .timeLimit(.minutes(1)), .asyncTestCleanup)
struct CatalogRefreshDeadlineTests {
    @Test func freshNativeAndHealthyGUIResultsPublishBeforeTheCallerDeadlineWhenAnotherGUIIsSilent() async throws {
        let fixture = try CatalogDeadlineFixture(hasNative: true, guiCount: 2)
        defer { fixture.manager.shutdownAndWait() }
        let load = fixture.loadCatalog()
        defer { load.cancel() }
        try await fixture.waitForCallerCount(1)
        let nativeRequest = try await fixture.nextCatalogRequest(upstreamIndex: 0)
        let healthyRequest = try await fixture.nextCatalogRequest(upstreamIndex: 1)
        _ = try await fixture.nextCatalogRequest(upstreamIndex: 2)
        try await fixture.reply(to: nativeRequest, upstreamIndex: 0, toolName: "FreshNativeTool")
        try await fixture.reply(to: healthyRequest, upstreamIndex: 1, toolName: "FreshGUITool")
        try await fixture.waitForRefreshSuccess(upstreamIndex: 0)
        try await fixture.waitForRefreshSuccess(upstreamIndex: 1)

        try await fixture.timeoutClock.sleep(untilSuspendedFor: .seconds(5))
        await fixture.advance(byMilliseconds: 2_500)
        let result = try await fixture.result(of: load)
        let names = Set(toolNames(in: result))
        #expect(names.contains("FreshNativeTool"))
        #expect(names.contains("FreshGUITool"))
        #expect(!names.contains("CachedNativeTool"))
        #expect(!names.contains("CachedGUITool1"))
        #expect(fixture.uptimeClock.now() == 2_500_000_000)
        fixture.uptimeClock.advance(by: .milliseconds(2_500))
        fixture.timeoutClock.advance(by: .milliseconds(2_500))
        #expect(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting() == nil)
    }

    @Test(arguments: [false, true])
    func aGUIOnlyCatalogRequiresAFreshResponseInsteadOfReturningOnlyCachedTools(replies: Bool) async throws {
        let fixture = try CatalogDeadlineFixture(hasNative: false, guiCount: 1)
        defer { fixture.manager.shutdownAndWait() }
        let load = fixture.loadCatalog()
        defer { load.cancel() }
        try await fixture.waitForCallerCount(1)
        let request = try await fixture.nextCatalogRequest(upstreamIndex: 0)
        if replies {
            await fixture.advance(byMilliseconds: 1_000)
            try await fixture.reply(to: request, upstreamIndex: 0, toolName: "FreshGUIOnlyTool")
            let result = try await fixture.result(of: load)
            #expect(Set(toolNames(in: result)) == Set(["FreshGUIOnlyTool"]))
            #expect(fixture.uptimeClock.now() == 1_000_000_000)
        } else {
            await fixture.advance(byMilliseconds: 2_500)
            let outcome = try await waitWithTimeout("waiting for a catalog with no fresh provider to fail", timeout: .seconds(2)) {
                await load.result
            }
            if case .success(let result) = outcome {
                Issue.record("A silent GUI returned its cached catalog as a successful refresh: \(toolNames(in: result))")
            }
            #expect(fixture.uptimeClock.now() == 2_500_000_000)
        }
    }

    @Test func errorsFromEveryActualOriginDoNotTurnCachedToolsIntoASuccessfulRefresh() async throws {
        let fixture = try CatalogDeadlineFixture(hasNative: true, guiCount: 1)
        defer { fixture.manager.shutdownAndWait() }
        let load = fixture.loadCatalog()
        defer { load.cancel() }
        try await fixture.waitForCallerCount(1)
        for index in fixture.upstreams.indices {
            let request = try await fixture.nextCatalogRequest(upstreamIndex: index)
            await fixture.upstreams[index].yield(.message(try JSONRPC.Wire.errorResponseData(
                id: try #require(JSONRPC.ID(any: extractUpstreamID(from: request))),
                code: -32603, message: "Origin \(index) catalog failed"
            )))
        }
        let outcome = try await waitWithTimeout("waiting for errors from every catalog origin", timeout: .seconds(2)) {
            await load.result
        }
        switch outcome {
        case .success(let result):
            Issue.record("Origin RPC errors returned cached tools as success: \(toolNames(in: result))")
        case .failure(let error):
            #expect(ControlPlane.ErrorMapper.jsonRPCError(for: error).code == -32603)
        }
    }

    @Test func equalDeadlinesShareOneRefreshAndAShorterCallerKeepsTheLongWaiters() async throws {
        let fixture = try CatalogDeadlineFixture(hasNative: true, guiCount: 1)
        defer { fixture.manager.shutdownAndWait() }
        let first = fixture.loadCatalog()
        defer { first.cancel() }
        try await fixture.waitForCallerCount(1)
        _ = try await fixture.nextCatalogRequest(upstreamIndex: 0)
        _ = try await fixture.nextCatalogRequest(upstreamIndex: 1)
        let originalLoad = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())

        let second = fixture.loadCatalog()
        defer { second.cancel() }
        try await fixture.waitForCallerCount(2)
        let sharedLoad = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
        #expect(sharedLoad.loadID == originalLoad.loadID)
        for upstream in fixture.upstreams {
            #expect(await upstream.sent().filter { methodName(from: $0) == "tools/list" }.count == 1)
        }

        let shorter = fixture.loadCatalog(timeout: .seconds(4))
        defer { shorter.cancel() }
        try await fixture.waitForCallerCount(3)
        let replannedLoad = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
        #expect(replannedLoad.loadID != originalLoad.loadID)
        #expect(replannedLoad.foregroundWaiterCount == 3)
        let nativeRequest = try await fixture.nextCatalogRequest(upstreamIndex: 0, startingAt: 1)
        _ = try await fixture.nextCatalogRequest(upstreamIndex: 1, startingAt: 1)
        for upstream in fixture.upstreams {
            #expect(await upstream.sent().filter { methodName(from: $0) == "tools/list" }.count == 2)
        }
        try await fixture.reply(to: nativeRequest, upstreamIndex: 0, toolName: "FreshReplannedNativeTool")
        try await fixture.waitForRefreshSuccess(upstreamIndex: 0)
        try await fixture.timeoutClock.sleep(untilSuspendedFor: .seconds(4))
        await fixture.advance(byMilliseconds: 2_000)
        for waiter in [first, second, shorter] {
            let result = try await fixture.result(of: waiter)
            #expect(toolNames(in: result).contains("FreshReplannedNativeTool"))
            #expect(!toolNames(in: result).contains("CachedNativeTool"))
        }
        #expect(fixture.uptimeClock.now() == 2_000_000_000)
        fixture.uptimeClock.advance(by: .milliseconds(3_000))
        fixture.timeoutClock.advance(by: .milliseconds(3_000))
        #expect(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting() == nil)
    }
}

private struct CatalogDeadlineFixture {
    let eventLoop: NIOAsyncTestingEventLoop
    let timeoutClock: TestClock
    let uptimeClock: TestUptimeClock
    let upstreams: [TestUpstreamClient]
    let manager: RuntimeCoordinator
    let refreshEvents: LockedRecordedValues<(Int, Bool)>

    init(hasNative: Bool, guiCount: Int) throws {
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        timeoutClock = clocks.timeoutClock
        uptimeClock = clocks.uptimeClock
        let eventLoop = NIOAsyncTestingEventLoop()
        self.eventLoop = eventLoop
        let nativeCount = hasNative ? 1 : 0
        let upstreams = (0..<(nativeCount + guiCount)).map { _ in TestUpstreamClient() }
        self.upstreams = upstreams
        let guiEntries = (nativeCount..<upstreams.count).map { index in
            (target: xcodeProcessTarget(processID: Int32(7200 + index), xcodeVersion: "27.0"), index: index)
        }
        let refreshEvents = LockedRecordedValues<(Int, Bool)>()
        self.refreshEvents = refreshEvents
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5), eventLoop: eventLoop, upstreams: upstreams,
            clock: clocks.clock,
            xcodeProcessRoutes: guiEntries.map { XcodeProcessRoute(target: $0.target, upstreamIndices: [$0.index]) },
            testHooks: .init(toolsListRefreshCompleted: { refreshEvents.append(($0, $1)) }),
            startImmediately: false
        )
        self.manager = manager
        for index in upstreams.indices { manager.markUpstreamInitialized(upstreamIndex: index) }
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]),
            sourceUpstream: 0)
        if hasNative {
            try seedUnboundToolCatalog(on: manager, upstreamIndex: 0, tools: [toolDescriptor(name: "CachedNativeTool")])
        }
        try seedProcessToolCatalogs(on: manager, entries: guiEntries.map {
            ($0.target, $0.index, [toolDescriptor(name: "CachedGUITool\($0.index)")])
        })
    }

    func loadCatalog(timeout: TimeAmount = .seconds(5)) -> Task<JSONValue, any Error> {
        let manager = manager
        return Task { try await manager.sharedToolsList(sessionID: "deadline-caller", requestTimeoutOverride: timeout) }
    }

    func waitForCallerCount(_ count: Int) async throws {
        let manager = manager
        _ = try await waitWithTimeout("waiting for \(count) actual catalog callers", timeout: .seconds(2)) {
            try await manager.controlPlaneDebugMirror.waitForSnapshot { $0.waiterCounts.toolsCatalog == count }
        }
        try await waitForSuspendedSleepers(on: timeoutClock, count: count)
    }

    func nextCatalogRequest(upstreamIndex: Int, startingAt offset: Int = 0) async throws -> Data {
        let upstream = upstreams[upstreamIndex]
        return try await waitWithTimeout("waiting for an actual catalog RPC on origin \(upstreamIndex)", timeout: .seconds(2)) {
            try await upstream.nextSent(startingAt: offset, matching: { methodName(from: $0) == "tools/list" })
        }
    }

    func reply(to request: Data, upstreamIndex: Int, toolName: String) async throws {
        await upstreams[upstreamIndex].yield(.message(try JSONRPC.Wire.resultResponseData(
            id: try #require(JSONRPC.ID(any: extractUpstreamID(from: request))),
            result: try jsonValue(["tools": [toolDescriptor(name: toolName)]])
        )))
    }

    func waitForRefreshSuccess(upstreamIndex: Int) async throws {
        let events = refreshEvents
        try await waitWithTimeout("waiting for a successful refresh from origin \(upstreamIndex)", timeout: .seconds(2)) {
            var index = 0
            while true {
                let event = try await events.nextValue(at: index)
                if event.0 == upstreamIndex && event.1 { return }
                index += 1
            }
        }
    }

    func advance(byMilliseconds amount: Int64) async {
        // Deadline arithmetic, caller sleeps, and origin RPC timers have separate clocks.
        uptimeClock.advance(by: .milliseconds(amount))
        timeoutClock.advance(by: .milliseconds(amount))
        await eventLoop.advanceTime(by: .milliseconds(amount))
        await eventLoop.run()
    }

    func result(of load: Task<JSONValue, any Error>) async throws -> JSONValue {
        try await waitWithTimeout("waiting for the public caller's refreshed catalog", timeout: .seconds(2)) {
            try await load.value
        }
    }
}
