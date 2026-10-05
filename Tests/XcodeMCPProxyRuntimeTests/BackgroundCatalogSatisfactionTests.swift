@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Foundation
import NIO
import NIOEmbedded
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

@Suite(.serialized, .timeLimit(.minutes(1)), .asyncTestCleanup)
struct BackgroundCatalogSatisfactionTests {
    @Test func aBackgroundGUICommitSatisfiesItsConcurrentForegroundReadUsingTheActualFreshSource() async throws {
        let fixture = try BackgroundSatisfactionFixture()
        defer { fixture.manager.shutdownAndWait() }
        let pending = try await fixture.beginConcurrentRefresh()
        defer { pending.foreground.cancel() }
        try await fixture.acceptBackgroundReply(pending)
        #expect(fixture.manager.processControlPlane.canonicalSourceProof() == fixture.otherGUIProof)
        #expect(await fixture.native.sentCount() == 0)

        await fixture.advance(byMilliseconds: 2_500)
        let result = try await fixture.result(of: pending.foreground)
        #expect(toolNames(in: result).contains("GUI1V2"))
        #expect(!toolNames(in: result).contains("GUI1V1"))
        #expect(toolNames(in: result).contains("GUI2Cached"))
        #expect(fixture.uptimeClock.now() == 2_500_000_000)
        // The silent GUI keeps the real load alive after its partial publication.
        let freshSources = try #require(await fixture.manager.controlPlaneCoordinator.backgroundSatisfactionFreshSourcesForTesting())
        #expect(freshSources == Set([fixture.freshGUIProof]))
        #expect(!freshSources.contains(fixture.otherGUIProof))
        let background = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
        #expect(background.waiterCount == 0)
        #expect(background.rpcHandle.isCancelled() == false)
        #expect(await fixture.freshGUI.sent().filter { methodName(from: $0) == "tools/list" }.count == 2)
        #expect(await fixture.otherGUI.sent().filter { methodName(from: $0) == "tools/list" }.count == 1)
    }

    @Test func shutdownCancelsTheCallerBeforeProviderTeardownCanFinishTheRead() async throws {
        let fixture = try BackgroundSatisfactionFixture(drainReadsAfterRouteReset: true)
        defer { fixture.manager.shutdownAndWait() }
        let pending = try await fixture.beginConcurrentRefresh()
        defer { pending.foreground.cancel() }
        try await fixture.acceptBackgroundReply(pending)

        await fixture.manager.shutdown()

        #expect(fixture.shutdownReadDrains.count() == 1)
        await #expect(throws: CancellationError.self) { try await fixture.result(of: pending.foreground) }
        #expect(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting() == nil)
        await #expect(throws: CancellationError.self) {
            try await fixture.manager.sharedToolsList(sessionID: "after-shutdown", requestTimeoutOverride: .seconds(5))
        }
    }

    @Test(arguments: [false, true])
    func aRealCallerCancellationOrShutdownRemainsAnErrorAfterBackgroundSatisfaction(shutdown: Bool) async throws {
        let fixture = try BackgroundSatisfactionFixture()
        defer { fixture.manager.shutdownAndWait() }
        let pending = try await fixture.beginConcurrentRefresh()
        defer { pending.foreground.cancel() }
        try await fixture.acceptBackgroundReply(pending)
        #expect(fixture.uptimeClock.now() == 0)
        if shutdown {
            await fixture.manager.shutdown()
        } else {
            pending.foreground.cancel()
        }
        await #expect(throws: CancellationError.self) { try await fixture.result(of: pending.foreground) }
    }
}

extension ControlPlaneCoordinator {
    func backgroundSatisfactionFreshSourcesForTesting() -> Set<UpstreamTopologyProof>? {
        toolsCatalogLoad?.freshSources
    }
}

private struct PendingBackgroundSatisfaction: Sendable {
    let backgroundRequest: Data
    let foregroundRequest: Data
    let foreground: Task<JSONValue, any Error>
    let nextCommitIndex: Int
}

private struct BackgroundSatisfactionFixture {
    let eventLoop: NIOAsyncTestingEventLoop
    let timeoutClock: TestClock
    let uptimeClock: TestUptimeClock
    let native: TestUpstreamClient
    let freshGUI: TestUpstreamClient
    let otherGUI: TestUpstreamClient
    let freshTarget: XcodeProcessTarget
    let manager: RuntimeCoordinator
    let guiCommits: LockedRecordedValues<Int>
    let shutdownReadDrains: LockedRecordedValues<Void>

    var freshGUIProof: UpstreamTopologyProof { manager.operationLeaseForTest(upstreamIndex: 1).proof }
    var otherGUIProof: UpstreamTopologyProof { manager.operationLeaseForTest(upstreamIndex: 2).proof }

    init(drainReadsAfterRouteReset: Bool = false) throws {
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        timeoutClock = clocks.timeoutClock
        uptimeClock = clocks.uptimeClock
        let eventLoop = NIOAsyncTestingEventLoop()
        self.eventLoop = eventLoop
        let native = TestUpstreamClient()
        let freshGUI = TestUpstreamClient()
        let otherGUI = TestUpstreamClient()
        self.native = native
        self.freshGUI = freshGUI
        self.otherGUI = otherGUI
        let freshTarget = xcodeProcessTarget(processID: 7462, xcodeVersion: "26.6")
        let otherTarget = xcodeProcessTarget(processID: 7461, xcodeVersion: "27.0")
        self.freshTarget = freshTarget
        let guiCommits = LockedRecordedValues<Int>()
        self.guiCommits = guiCommits
        let shutdownReadDrains = LockedRecordedValues<Void>()
        self.shutdownReadDrains = shutdownReadDrains
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5), eventLoop: eventLoop,
            upstreams: [native, freshGUI, otherGUI], clock: clocks.clock,
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: freshTarget, upstreamIndices: [1]),
                XcodeProcessRoute(target: otherTarget, upstreamIndices: [2]),
            ],
            testHooks: .init(
                processRouteCatalogCommitted: { _, index in guiCommits.append(index) },
                processRoutesResetForShutdown: {
                    guard drainReadsAfterRouteReset else { return }
                    guard let coordinator = runtimeBox.value?.controlPlaneCoordinator else {
                        Issue.record("Runtime disappeared before its shutdown read barrier")
                        return
                    }
                    // Drain read completions before teardown continues; their callers
                    // must already be cancelled at this boundary.
                    let completions = await coordinator.completionTasks
                    for completion in completions.values { await completion.value }
                    shutdownReadDrains.append(())
                }
            ),
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        self.manager = manager
        manager.markUpstreamInitialized(upstreamIndex: 1)
        manager.markUpstreamInitialized(upstreamIndex: 2)
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]),
            sourceUpstream: 2)
        try seedProcessToolCatalogs(on: manager, entries: [
            (freshTarget, 1, [toolDescriptor(name: "GUI1V1")]),
            (otherTarget, 2, [toolDescriptor(name: "GUI2Cached")]),
        ])
        #expect(manager.processControlPlane.canonicalSourceProof() == manager.operationLeaseForTest(upstreamIndex: 2).proof)
    }

    func beginConcurrentRefresh() async throws -> PendingBackgroundSatisfaction {
        let nextCommitIndex = guiCommits.count()
        manager.refreshProcessToolsCatalogsIfNeeded(
            reason: "test_background_satisfies_foreground", processIDs: [freshTarget.processID], refreshCached: true
        )
        let backgroundRequest = try await nextCatalogRequest(on: freshGUI)
        let manager = manager
        let foreground = Task {
            try await manager.sharedToolsList(sessionID: "background-satisfaction-caller", requestTimeoutOverride: .seconds(5))
        }
        do {
            _ = try await waitWithTimeout("waiting for the actual foreground catalog caller", timeout: .seconds(2)) {
                try await manager.controlPlaneDebugMirror.waitForSnapshot { $0.waiterCounts.toolsCatalog == 1 }
            }
            try await waitForSuspendedSleepers(on: timeoutClock)
            let foregroundRequest = try await nextCatalogRequest(on: freshGUI, startingAt: 1)
            _ = try await nextCatalogRequest(on: otherGUI)
            #expect(try extractUpstreamID(from: backgroundRequest) != extractUpstreamID(from: foregroundRequest))
            return PendingBackgroundSatisfaction(
                backgroundRequest: backgroundRequest, foregroundRequest: foregroundRequest,
                foreground: foreground, nextCommitIndex: nextCommitIndex
            )
        } catch {
            foreground.cancel()
            throw error
        }
    }

    func acceptBackgroundReply(_ pending: PendingBackgroundSatisfaction) async throws {
        await freshGUI.yield(.message(try JSONRPC.Wire.resultResponseData(
            id: try #require(JSONRPC.ID(any: extractUpstreamID(from: pending.backgroundRequest))),
            result: try jsonValue(["tools": [toolDescriptor(name: "GUI1V2")]])
        )))
        let guiCommits = guiCommits
        let committed = try await waitWithTimeout("waiting for the fresh background GUI commit", timeout: .seconds(2)) {
            try await guiCommits.nextValue(at: pending.nextCommitIndex)
        }
        #expect(committed == 1)
        let foregroundID = try extractUpstreamID(from: pending.foregroundRequest)
        let freshGUI = freshGUI
        let cancellation = try await waitWithTimeout("waiting for the satisfied foreground RPC cancellation", timeout: .seconds(2)) {
            try await freshGUI.nextSent(matching: {
                methodName(from: $0) == "notifications/cancelled"
                    && (try? extractCancellationRequestID(from: $0)) == foregroundID
            })
        }
        #expect(try extractCancellationRequestID(from: cancellation) == foregroundID)
        #expect(toolNames(in: manager.processControlPlane.catalog(forProcessID: freshTarget.processID)?.rawResult ?? .null) == ["GUI1V2"])
    }

    func nextCatalogRequest(on upstream: TestUpstreamClient, startingAt offset: Int = 0) async throws -> Data {
        try await waitWithTimeout("waiting for an actual background or foreground catalog RPC", timeout: .seconds(2)) {
            try await upstream.nextSent(startingAt: offset, matching: { methodName(from: $0) == "tools/list" })
        }
    }

    func advance(byMilliseconds amount: Int64) async {
        uptimeClock.advance(by: .milliseconds(amount))
        timeoutClock.advance(by: .milliseconds(amount))
        await eventLoop.advanceTime(by: .milliseconds(amount))
        await eventLoop.run()
    }

    func result(of load: Task<JSONValue, any Error>) async throws -> JSONValue {
        try await waitWithTimeout("waiting for the public foreground catalog result", timeout: .seconds(2)) {
            try await load.value
        }
    }
}
