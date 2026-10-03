@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Foundation
import NIO
import NIOEmbedded
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

@Suite(.serialized, .timeLimit(.minutes(1)), .asyncTestCleanup)
struct CatalogLeaseCleanupTests {
    @Test(arguments: [false, true])
    func aCancelledOrReplacedReadReleasesItsLeaseBeforeAnEmptyCatalogAndRetry(replacesRead: Bool) async throws {
        let fixture = try CatalogLeaseCleanupFixture()
        defer { fixture.manager.shutdownAndWait() }
        let original = fixture.loadCatalog(timeout: .seconds(5))
        defer { original.cancel() }
        try await fixture.waitForCallerCount(1)
        let originalRequest = try await fixture.nextCatalogRequest()
        let oldLoad = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
        let nextRequestOffset = await fixture.gui.sentCount()
        let next: Task<JSONValue, any Error>
        let callers: [Task<JSONValue, any Error>]
        if replacesRead {
            next = fixture.loadCatalog(timeout: .seconds(10))
            try await fixture.waitForCallerCount(2)
            let replacement = try #require(await fixture.manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting())
            #expect(replacement.loadID != oldLoad.loadID)
            #expect(replacement.foregroundWaiterCount == 2)
            callers = [original, next]
        } else {
            original.cancel()
            await #expect(throws: CancellationError.self) { try await fixture.result(of: original) }
            try await fixture.waitForReadCompletion(oldLoad.loadID)
            next = fixture.loadCatalog(timeout: .seconds(5))
            try await fixture.waitForCallerCount(1)
            callers = [next]
        }
        defer { next.cancel() }
        let emptyRequest = try await fixture.nextCatalogRequest(startingAt: nextRequestOffset)
        #expect(try extractUpstreamID(from: emptyRequest) != extractUpstreamID(from: originalRequest))
        try await fixture.waitForReadCompletion(oldLoad.loadID)
        #expect(toolNames(in: fixture.manager.cachedToolsListResult() ?? .null).contains("OldGUITool"))

        let retryEventOffset = fixture.timeoutScheduler.scheduledEventCount()
        await fixture.gui.yield(.message(try JSONRPC.Wire.resultResponseData(
            id: try #require(JSONRPC.ID(any: extractUpstreamID(from: emptyRequest))),
            result: .object(["tools": .array([])])
        )))
        for caller in callers {
            let outcome = try await waitWithTimeout("waiting for the empty catalog read to fail", timeout: .seconds(2)) {
                await caller.result
            }
            if case .success(let result) = outcome {
                Issue.record("An empty catalog kept its obsolete cached tools as success: \(toolNames(in: result))")
            }
        }
        let scheduler = fixture.timeoutScheduler
        let retryIndex = try await waitWithTimeout("waiting for the existing empty-catalog retry to be armed", timeout: .seconds(2)) {
            try await scheduler.nextScheduled(at: retryEventOffset)
        }
        #expect(fixture.manager.processControlPlane.catalog(forProcessID: fixture.target.processID) == nil)
        #expect(fixture.manager.cachedToolsListResult() == nil)
        #expect(fixture.manager.processControlPlane.pendingCatalogProcessIDs(
            nowUptimeNs: fixture.uptimeClock.now()).contains(fixture.target.processID))
        #expect(!scheduler.isCancelled(at: retryIndex))

        let retryRequestOffset = await fixture.gui.sentCount()
        let commitOffset = fixture.guiCommits.count()
        let delay = try #require(scheduler.delay(at: retryIndex))
        fixture.uptimeClock.advance(by: .nanoseconds(delay.nanoseconds))
        fixture.timeoutClock.advance(by: .nanoseconds(delay.nanoseconds))
        #expect(scheduler.fire(at: retryIndex))
        let retryRequest = try await fixture.nextCatalogRequest(startingAt: retryRequestOffset)
        await fixture.gui.yield(.message(try JSONRPC.Wire.resultResponseData(
            id: try #require(JSONRPC.ID(any: extractUpstreamID(from: retryRequest))),
            result: try jsonValue(["tools": [toolDescriptor(name: "RetriedGUIToolV2")]])
        )))
        let commits = fixture.guiCommits
        let committed = try await waitWithTimeout("waiting for the retry's actual GUI catalog commit", timeout: .seconds(2)) {
            try await commits.nextValue(at: commitOffset)
        }
        #expect(committed == 1)
        #expect(toolNames(in: fixture.manager.cachedToolsListResult() ?? .null) == ["RetriedGUIToolV2"])
        #expect(fixture.manager.processControlPlane.catalog(forProcessID: fixture.target.processID)?.toolNames == Set(["RetriedGUIToolV2"]))
        #expect(await fixture.native.sentCount() == 0)
        #expect(await fixture.gui.sent().filter { methodName(from: $0) == "tools/list" }.count == 3)
    }
}

extension ControlPlaneCoordinator {
    func awaitCatalogReadCompletionForLeaseCleanupTest(_ loadID: UUID) async {
        await completionTasks[loadID]?.value
    }
}

private struct CatalogLeaseCleanupFixture {
    let eventLoop: NIOAsyncTestingEventLoop
    let timeoutClock: TestClock
    let uptimeClock: TestUptimeClock
    let timeoutScheduler: RecordingRuntimeTimeoutScheduler
    let native: TestUpstreamClient
    let gui: TestUpstreamClient
    let target: XcodeProcessTarget
    let manager: RuntimeCoordinator
    let guiCommits: LockedRecordedValues<Int>

    init() throws {
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        timeoutClock = clocks.timeoutClock
        uptimeClock = clocks.uptimeClock
        let eventLoop = NIOAsyncTestingEventLoop()
        self.eventLoop = eventLoop
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        self.timeoutScheduler = timeoutScheduler
        let native = TestUpstreamClient()
        let gui = TestUpstreamClient()
        self.native = native
        self.gui = gui
        let target = xcodeProcessTarget(processID: 7581, xcodeVersion: "27.0")
        self.target = target
        let guiCommits = LockedRecordedValues<Int>()
        self.guiCommits = guiCommits
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5), eventLoop: eventLoop,
            upstreams: [native, gui], clock: clocks.clock,
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [1])],
            testHooks: .init(processRouteCatalogCommitted: { _, index in guiCommits.append(index) }),
            startImmediately: false
        )
        self.manager = manager
        manager.markUpstreamInitialized(upstreamIndex: 1)
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]),
            sourceUpstream: 1)
        try seedProcessToolCatalogs(on: manager, entries: [(target, 1, [toolDescriptor(name: "OldGUITool")])])
    }

    func loadCatalog(timeout: TimeAmount) -> Task<JSONValue, any Error> {
        let manager = manager
        return Task {
            try await manager.sharedToolsList(sessionID: "catalog-lease-cleanup", requestTimeoutOverride: timeout)
        }
    }

    func waitForCallerCount(_ count: Int) async throws {
        let manager = manager
        _ = try await waitWithTimeout("waiting for the actual catalog callers", timeout: .seconds(2)) {
            try await manager.controlPlaneDebugMirror.waitForSnapshot { $0.waiterCounts.toolsCatalog == count }
        }
    }

    func nextCatalogRequest(startingAt offset: Int = 0) async throws -> Data {
        let gui = gui
        return try await waitWithTimeout("waiting for the actual GUI catalog RPC", timeout: .seconds(2)) {
            try await gui.nextSent(startingAt: offset, matching: { methodName(from: $0) == "tools/list" })
        }
    }

    func waitForReadCompletion(_ loadID: UUID) async throws {
        let coordinator = manager.controlPlaneCoordinator
        try await waitWithTimeout("waiting for the retired read and its owned route task to finish", timeout: .seconds(2)) {
            await coordinator.awaitCatalogReadCompletionForLeaseCleanupTest(loadID)
        }
    }

    func result(of task: Task<JSONValue, any Error>) async throws -> JSONValue {
        try await waitWithTimeout("waiting for the public catalog caller", timeout: .seconds(2)) {
            try await task.value
        }
    }
}
