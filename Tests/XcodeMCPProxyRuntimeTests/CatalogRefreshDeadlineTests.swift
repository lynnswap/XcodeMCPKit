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
    @Test func freshResultsPublishBeforeTheCallerDeadlineAndTheLateGUIStillCommits() async throws {
        let fixture = try CatalogDeadlineFixture(hasNative: true, guiCount: 2)
        defer { fixture.manager.shutdownAndWait() }
        let observer = fixture.manager.session(id: "deadline-observer")
        fixture.manager.sessionRegistry.markInitialized(id: observer.id, negotiatedProtocolVersion: MCP.ProtocolVersion.current)
        _ = observer.router.drainBufferedNotifications()
        let load = fixture.loadCatalog()
        defer { load.cancel() }
        try await fixture.waitForCallerCount(1)
        let nativeRequest = try await fixture.nextCatalogRequest(upstreamIndex: 0)
        let healthyRequest = try await fixture.nextCatalogRequest(upstreamIndex: 1)
        let lateRequest = try await fixture.nextCatalogRequest(upstreamIndex: 2)
        try await fixture.reply(to: nativeRequest, upstreamIndex: 0, toolName: "FreshNativeTool")
        try await fixture.reply(to: healthyRequest, upstreamIndex: 1, toolName: "FreshGUITool")
        try await fixture.waitForCatalogCommit(upstreamIndex: 0)
        try await fixture.waitForCatalogCommit(upstreamIndex: 1)

        await fixture.advance(byMilliseconds: 2_500)
        let result = try await fixture.result(of: load)
        #expect(Set(toolNames(in: result)).isSuperset(of: ["FreshNativeTool", "FreshGUITool"]))
        let background = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
        #expect(background.waiterCount == 0)
        _ = observer.router.drainBufferedNotifications()
        await fixture.advance(byMilliseconds: 500)
        try await fixture.reply(to: lateRequest, upstreamIndex: 2, toolName: "LateFreshGUITool")
        try await fixture.waitForCatalogCommit(upstreamIndex: 2)
        #expect(toolNames(in: fixture.manager.cachedToolsListResult() ?? .null).contains("LateFreshGUITool"))
        #expect(!observer.router.drainBufferedNotifications().isEmpty)
    }

    @Test(arguments: [false, true])
    func aLaterCallersCancellationCannotAbandonUpdatesOwnedByAnEarlierPartialPublication(extendsReadBudget: Bool) async throws {
        let fixture = try CatalogDeadlineFixture(hasNative: true, guiCount: 1)
        defer { fixture.manager.shutdownAndWait() }
        let observer = fixture.manager.session(id: "partial-background-observer")
        fixture.manager.sessionRegistry.markInitialized(id: observer.id, negotiatedProtocolVersion: MCP.ProtocolVersion.current)
        let first = fixture.loadCatalog()
        defer { first.cancel() }
        try await fixture.waitForCallerCount(1)
        let nativeRequest = try await fixture.nextCatalogRequest(upstreamIndex: 0)
        let guiRequest = try await fixture.nextCatalogRequest(upstreamIndex: 1)
        try await fixture.reply(to: nativeRequest, upstreamIndex: 0, toolName: "PublishedPartialNative")
        try await fixture.waitForCatalogCommit(upstreamIndex: 0)
        await fixture.advance(byMilliseconds: 2_500)
        #expect(toolNames(in: try await fixture.result(of: first)).contains("PublishedPartialNative"))
        let background = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
        #expect(background.waiterCount == 0)
        _ = observer.router.drainBufferedNotifications()
        let later = fixture.loadCatalog(timeout: extendsReadBudget ? .seconds(10) : .seconds(1))
        defer { later.cancel() }
        try await fixture.waitForCallerCount(1)
        let joined = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
        #expect((joined.loadID != background.loadID) == extendsReadBudget)
        let pendingGUIRequest: Data
        if extendsReadBudget {
            let newNativeRequest = try await fixture.nextCatalogRequest(upstreamIndex: 0, startingAt: 1)
            pendingGUIRequest = try await fixture.nextCatalogRequest(upstreamIndex: 1, startingAt: 1)
            try await fixture.reply(to: newNativeRequest, upstreamIndex: 0, toolName: "RefreshedExtendedNative")
        } else {
            pendingGUIRequest = guiRequest
        }
        later.cancel()
        await #expect(throws: CancellationError.self) { try await fixture.result(of: later) }
        let preserved = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
        #expect(preserved.loadID == joined.loadID)
        #expect(preserved.waiterCount == 0)
        #expect(preserved.rpcHandle.isCancelled() == false)
        await fixture.advance(byMilliseconds: 500)
        try await fixture.reply(to: pendingGUIRequest, upstreamIndex: 1, toolName: "GUIUpdateAfterLaterCancel")
        try await fixture.waitForCatalogCommit(upstreamIndex: 1)
        #expect(toolNames(in: fixture.manager.cachedToolsListResult() ?? .null).contains("GUIUpdateAfterLaterCancel"))
        #expect(!observer.router.drainBufferedNotifications().isEmpty)
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
            #expect(Set(toolNames(in: try await fixture.result(of: load))) == Set(["FreshGUIOnlyTool"]))
        } else {
            await fixture.advance(byMilliseconds: 2_500)
            let pending = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
            #expect(pending.foregroundWaiterCount == 1)
            try await fixture.timeoutClock.sleep(untilSuspendedFor: .milliseconds(2_500))
            await fixture.advance(byMilliseconds: 2_500)
            await #expect(throws: TimeoutError.self) { try await fixture.result(of: load) }
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
                id: JSONRPC.ID(any: try extractUpstreamID(from: request)),
                code: -32603, message: "Origin \(index) catalog failed"
            )))
        }
        let outcome = try await waitWithTimeout("waiting for errors from every catalog origin", timeout: .seconds(2)) {
            await load.result
        }
        switch outcome {
        case .success(let result): Issue.record("Cached tools were treated as a fresh reply: \(toolNames(in: result))")
        case .failure(let error): #expect(ControlPlane.ErrorMapper.jsonRPCError(for: error).code == -32603)
        }
    }

    @Test(arguments: [false, true])
    func aShortCallerCannotReduceTheLongCallersReadBudget(cancelShort: Bool) async throws {
        let fixture = try CatalogDeadlineFixture(hasNative: true, guiCount: 1)
        defer { fixture.manager.shutdownAndWait() }
        let long = fixture.loadCatalog()
        defer { long.cancel() }
        try await fixture.waitForCallerCount(1)
        let nativeRequest = try await fixture.nextCatalogRequest(upstreamIndex: 0)
        _ = try await fixture.nextCatalogRequest(upstreamIndex: 1)
        let original = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
        let short = fixture.loadCatalog(timeout: .seconds(1))
        defer { short.cancel() }
        try await fixture.waitForCallerCount(2)
        let shared = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
        #expect(shared.loadID == original.loadID)
        for origin in fixture.upstreams {
            #expect(await origin.sent().filter { methodName(from: $0) == "tools/list" }.count == 1)
        }
        if cancelShort {
            short.cancel()
            await #expect(throws: CancellationError.self) { try await fixture.result(of: short) }
        } else {
            await fixture.advance(byMilliseconds: 500)
            try await fixture.timeoutClock.sleep(untilSuspendedFor: .milliseconds(500))
            await fixture.advance(byMilliseconds: 500)
            await #expect(throws: TimeoutError.self) { try await fixture.result(of: short) }
        }
        let preserved = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
        #expect(preserved.loadID == original.loadID)
        #expect(preserved.foregroundWaiterCount == 1)
        await fixture.advance(byMilliseconds: cancelShort ? 2_000 : 1_000)
        try await fixture.reply(to: nativeRequest, upstreamIndex: 0, toolName: "NativeReplyAfterTwoSeconds")
        try await fixture.waitForCatalogCommit(upstreamIndex: 0)
        await fixture.advance(byMilliseconds: 500)
        #expect(toolNames(in: try await fixture.result(of: long)).contains("NativeReplyAfterTwoSeconds"))
        #expect(fixture.uptimeClock.now() == 2_500_000_000)
    }

    @Test func aFreshCommitAfterTheShortCallersPublicationPhaseCanReturnPartialBeforeItsHardDeadline() async throws {
        let fixture = try CatalogDeadlineFixture(hasNative: true, guiCount: 1)
        defer { fixture.manager.shutdownAndWait() }
        let long = fixture.loadCatalog()
        defer { long.cancel() }
        try await fixture.waitForCallerCount(1)
        let nativeRequest = try await fixture.nextCatalogRequest(upstreamIndex: 0)
        _ = try await fixture.nextCatalogRequest(upstreamIndex: 1)
        let short = fixture.loadCatalog(timeout: .seconds(1))
        defer { short.cancel() }
        try await fixture.waitForCallerCount(2)
        await fixture.advance(byMilliseconds: 500)
        try await fixture.timeoutClock.sleep(untilSuspendedFor: .milliseconds(500))
        await fixture.advance(byMilliseconds: 250)
        try await fixture.reply(to: nativeRequest, upstreamIndex: 0, toolName: "FreshBeforeOneSecond")
        #expect(toolNames(in: try await fixture.result(of: short)).contains("FreshBeforeOneSecond"))
        #expect(fixture.uptimeClock.now() == 750_000_000)
        await fixture.advance(byMilliseconds: 1_750)
        #expect(toolNames(in: try await fixture.result(of: long)).contains("FreshBeforeOneSecond"))
    }

    @Test func equalDeadlineCallersShareOneReadOperation() async throws {
        let fixture = try CatalogDeadlineFixture(hasNative: true, guiCount: 1)
        defer { fixture.manager.shutdownAndWait() }
        let first = fixture.loadCatalog()
        defer { first.cancel() }
        try await fixture.waitForCallerCount(1)
        let request = try await fixture.nextCatalogRequest(upstreamIndex: 0)
        _ = try await fixture.nextCatalogRequest(upstreamIndex: 1)
        let original = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
        let second = fixture.loadCatalog()
        defer { second.cancel() }
        try await fixture.waitForCallerCount(2)
        #expect(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting()?.loadID == original.loadID)
        for origin in fixture.upstreams {
            #expect(await origin.sent().filter { methodName(from: $0) == "tools/list" }.count == 1)
        }
        try await fixture.reply(to: request, upstreamIndex: 0, toolName: "SharedFreshNative")
        try await fixture.waitForCatalogCommit(upstreamIndex: 0)
        await fixture.advance(byMilliseconds: 2_500)
        for caller in [first, second] {
            #expect(toolNames(in: try await fixture.result(of: caller)).contains("SharedFreshNative"))
        }
    }
}


private struct CatalogDeadlineFixture {
    let eventLoop: NIOAsyncTestingEventLoop
    let timeoutClock: TestClock
    let uptimeClock: TestUptimeClock
    let upstreams: [TestUpstreamClient]
    let manager: RuntimeCoordinator
    let catalogCommits: LockedRecordedValues<Int>

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
        let catalogCommits = LockedRecordedValues<Int>()
        self.catalogCommits = catalogCommits
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5), eventLoop: eventLoop, upstreams: upstreams,
            clock: clocks.clock,
            xcodeProcessRoutes: guiEntries.map { XcodeProcessRoute(target: $0.target, upstreamIndices: [$0.index]) },
            testHooks: .init(unboundToolsCatalogCommitted: { catalogCommits.append($0) },
                processRouteCatalogCommitted: { _, index in catalogCommits.append(index) }),
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

    func waitForCatalogCommit(upstreamIndex: Int) async throws {
        let commits = catalogCommits
        // RPC refresh success precedes publication; advance deadlines only after
        // the requested provider is present in the canonical catalog.
        try await waitWithTimeout("waiting for catalog commit from origin \(upstreamIndex)", timeout: .seconds(2)) {
            var index = 0
            while true {
                if try await commits.nextValue(at: index) == upstreamIndex { return }
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
