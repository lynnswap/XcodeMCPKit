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
struct RuntimeCoordinatorRecoveryTests {
    @Test func sessionManagerInitializeErrorDoesNotClearRecreatedSessionInitializeRoutingState()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        let sessionID = "session-error-recreated"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])

        manager.removeSession(id: sessionID)
        _ = manager.session(id: sessionID)
        let replacementSnapshotBeforeError = try #require(manager.testSessionSnapshot(id: sessionID))

        let errorEventIndex = upstreamEvents.count()
        await upstream.yield(
            .message(
                try JSONSerialization.data(
                    withJSONObject: [
                        "jsonrpc": "2.0",
                        "id": initID,
                        "error": [
                            "code": -32000,
                            "message": "boom",
                        ],
                    ],
                    options: []
                )
            )
        )
        _ = try await nextRecordedValue(upstreamEvents, at: errorEventIndex)
        await #expect(throws: CancellationError.self) {
            try await future.get()
        }

        let replacementSnapshotAfterError = try #require(manager.testSessionSnapshot(id: sessionID))
        #expect(replacementSnapshotAfterError.generation == replacementSnapshotBeforeError.generation)
    }

    @Test func sessionManagerSharedToolsListTimeoutStartsFreshControlPlaneLoad() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            clock: clocks.clock
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-tools-timeout"
        _ = manager.session(id: sessionID)
        await upstream.blockNextSend(method: "tools/list")
        await upstream.blockNextCancellation()

        let firstTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let firstRequest = try await sentValue(
            from: upstream,
            at: 2,
            timeout: .seconds(2)
        )
        #expect(methodName(from: firstRequest) == "tools/list")
        try await upstream.waitForBlockedSend()
        _ = try await waitWithTimeout("waiting for first tools/list waiter to attach") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 1
            }
        }
        #expect(
            await manager.controlPlaneCoordinator.timeoutForegroundToolsCatalogWaiterForTesting()
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await firstTask.value
        }
        #expect(await upstream.sent().filter { methodName(from: $0) != "notifications/cancelled" }.count == 3)
        await upstream.releaseBlockedSend()
        try await upstream.waitForBlockedCancellation()
        #expect(await upstream.sent().filter { methodName(from: $0) != "notifications/cancelled" }.count == 3)
        await upstream.releaseBlockedCancellation()

        _ = try await waitWithTimeout("waiting for timed-out tools/list load cleanup") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 0 && $0.inFlightControlPlaneRequests.isEmpty
            }
        }
        _ = try await waitWithTimeout("waiting for timed-out tools/list request cleanup") {
            await manager.drainControlPlaneLoadsForTesting()
        }
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
        let firstCancellation = try await sentValue(
            from: upstream,
            at: 3,
            timeout: .seconds(2)
        )
        #expect(
            try extractCancellationRequestID(from: firstCancellation)
                == extractUpstreamID(from: firstRequest)
        )

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 5, timeoutSeconds: 2)
        let secondRequest = try await sentValue(from: upstream, at: 4, timeout: .seconds(2))
        #expect(methodName(from: secondRequest) == "tools/list")
        _ = try await waitWithTimeout("waiting for second tools/list waiter to attach") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 1
            }
        }
        #expect(
            await manager.controlPlaneCoordinator.timeoutForegroundToolsCatalogWaiterForTesting()
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await secondTask.value
        }
    }

    @Test func sessionManagerSharedToolsListReusesInFlightPrewarm() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.prewarmToolsList = true
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let prewarmRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: prewarmRequest) == "tools/list")
        let prewarmLoad = try #require(
            await manager.controlPlaneCoordinator.prewarmToolsCatalogLoadSnapshotForTesting()
        )
        #expect(prewarmLoad.waiterCount == 1)
        #expect(prewarmLoad.foregroundWaiterCount == 0)

        let sessionID = "session-tools-prewarm"
        _ = manager.session(id: sessionID)
        let foregroundTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }

        try await waitWithTimeout("waiting for foreground tools/list waiter to reuse prewarm load") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 1
            }
        }
        let reusedLoad = try #require(
            await manager.controlPlaneCoordinator.prewarmToolsCatalogLoadSnapshotForTesting()
        )
        #expect(reusedLoad.loadID == prewarmLoad.loadID)
        #expect(reusedLoad.waiterCount == 2)
        #expect(reusedLoad.foregroundWaiterCount == 1)
        #expect(
            await manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting()?
                .loadID == nil
        )

        let prewarmUpstreamID = try extractUpstreamID(from: prewarmRequest)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": prewarmUpstreamID,
            "result": ["tools": []],
        ]
        await upstream.yield(.message(try JSONSerialization.data(withJSONObject: response)))

        let result = try await foregroundTask.value
        guard case .object(let object) = result else {
            Issue.record("tools/list result should be an object")
            return
        }
        #expect(object["tools"] != nil)
    }

    @Test func sessionManagerSharedToolsListPromotesPartlyConsumedSharedTimeout()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            clock: clocks.clock
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-tools-promote-same-timeout"
        _ = manager.session(id: sessionID)

        let firstTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        let firstRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: firstRequest) == "tools/list")
        _ = try await waitWithTimeout("waiting for first tools/list waiter to attach") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 1
            }
        }
        let firstLoad = try #require(
            await manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting()
        )
        #expect(firstLoad.waiterCount == 1)
        #expect(firstLoad.foregroundWaiterCount == 1)

        clocks.uptimeClock.advance(by: .nanoseconds(120_000_001))

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await waitWithTimeout("waiting for promoted tools/list waiters to attach") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 2
            }
        }
        let promotedLoad = try #require(
            await manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting()
        )
        #expect(promotedLoad.loadID != firstLoad.loadID)
        #expect(promotedLoad.waiterCount == 2)
        #expect(promotedLoad.foregroundWaiterCount == 2)
        #expect(firstLoad.rpcHandle.isCancelled())

        firstTask.cancel()
        secondTask.cancel()

        do {
            _ = try await firstTask.value
            Issue.record("first tools/list waiter should be cancelled after promotion test")
        } catch is CancellationError {
        } catch is TimeoutError {
        } catch {
            Issue.record("expected CancellationError or TimeoutError for first waiter but received \(error)")
        }
        do {
            _ = try await secondTask.value
            Issue.record("second tools/list waiter should be cancelled after promotion test")
        } catch is CancellationError {
        } catch is TimeoutError {
        } catch {
            Issue.record("expected CancellationError or TimeoutError for second waiter but received \(error)")
        }
    }

    @Test func sessionManagerSharedToolsListCancellationCancelsLastWaiterLoad() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-tools-cancel"
        _ = manager.session(id: sessionID)
        let task = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        _ = try await waitWithTimeout("waiting for cancelled tools/list waiter cleanup") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 0 && $0.inFlightControlPlaneRequests.isEmpty
            }
        }
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func sessionManagerSharedToolsListStopsPromotingAfterLoadBecomesShared() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            clock: clocks.clock
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-tools-shared-no-starvation"
        _ = manager.session(id: sessionID)

        let firstTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        let firstRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: firstRequest) == "tools/list")
        _ = try await waitWithTimeout("waiting for first tools/list waiter to attach") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 1
            }
        }
        let firstLoad = try #require(
            await manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting()
        )

        clocks.uptimeClock.advance(by: .nanoseconds(120_000_001))

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await waitWithTimeout("waiting for promoted tools/list waiters to attach") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 2
            }
        }
        let sharedLoad = try #require(
            await manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting()
        )
        #expect(sharedLoad.loadID != firstLoad.loadID)
        #expect(sharedLoad.waiterCount == 2)
        #expect(sharedLoad.foregroundWaiterCount == 2)
        #expect(firstLoad.rpcHandle.isCancelled())

        clocks.uptimeClock.advance(by: .nanoseconds(120_000_001))

        let thirdTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }

        try await waitWithTimeout("waiting for third tools/list waiter to share the in-flight load") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 3
            }
        }
        let unchangedLoad = try #require(
            await manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting()
        )
        #expect(unchangedLoad.loadID == sharedLoad.loadID)
        #expect(unchangedLoad.waiterCount == 3)
        #expect(unchangedLoad.foregroundWaiterCount == 3)
        #expect(sharedLoad.rpcHandle.isCancelled() == false)

        firstTask.cancel()
        secondTask.cancel()
        thirdTask.cancel()
        _ = try? await firstTask.value
        _ = try? await secondTask.value
        _ = try? await thirdTask.value
        _ = try await waitWithTimeout("waiting for shared tools/list load cancellation") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 0 && $0.inFlightControlPlaneRequests.isEmpty
            }
        }
        #expect(
            await manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting()?
                .loadID == nil
        )
        #expect(sharedLoad.rpcHandle.isCancelled())
    }

    @Test func sessionManagerPromotedToolsListCancellationRemovesMigratedWaiter() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            clock: clocks.clock
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-tools-promoted-cancel"
        _ = manager.session(id: sessionID)
        let firstTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        _ = try await waitWithTimeout("waiting for first promoted tools/list waiter to attach") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 1
            }
        }
        let firstLoad = try #require(
            await manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting()
        )

        clocks.uptimeClock.advance(by: .nanoseconds(120_000_001))

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await waitWithTimeout("waiting for promoted tools/list waiters to attach") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 2
            }
        }
        let promotedLoad = try #require(
            await manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting()
        )
        #expect(promotedLoad.loadID != firstLoad.loadID)
        #expect(promotedLoad.waiterCount == 2)
        #expect(promotedLoad.foregroundWaiterCount == 2)
        #expect(firstLoad.rpcHandle.isCancelled())

        firstTask.cancel()
        do {
            _ = try await firstTask.value
            Issue.record("first promoted tools/list waiter should be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for promoted waiter but received \(error)")
        }

        _ = try await waitWithTimeout("waiting for first promoted tools/list waiter cleanup") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 1
            }
        }
        let remainingLoad = try #require(
            await manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting()
        )
        #expect(remainingLoad.loadID == promotedLoad.loadID)
        #expect(remainingLoad.waiterCount == 1)
        #expect(remainingLoad.foregroundWaiterCount == 1)
        #expect(promotedLoad.rpcHandle.isCancelled() == false)

        secondTask.cancel()
        do {
            _ = try await secondTask.value
            Issue.record("second promoted tools/list waiter should be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for promoted waiter but received \(error)")
        }

        _ = try await waitWithTimeout("waiting for promoted tools/list waiter cleanup") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 0 && $0.inFlightControlPlaneRequests.isEmpty
            }
        }
        #expect(
            await manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting()?
                .loadID == nil
        )
        #expect(promotedLoad.rpcHandle.isCancelled())
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func sessionManagerSharedToolsListTimeoutCancelsStalePrewarmLoad() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let prewarmCompletions = LockedRecordedValues<Void>()
        var config = makeConfig(requestTimeout: 5)
        config.prewarmToolsList = true
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            clock: clocks.clock,
            testHooks: RuntimeCoordinatorTestHooks(
                toolsListPrewarmCompleted: { prewarmCompletions.append(()) }
            )
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let prewarmRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: prewarmRequest) == "tools/list")
        await upstream.blockNextCancellation()

        let sessionID = "session-tools-prewarm-timeout"
        _ = manager.session(id: sessionID)
        let firstTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }

        try await waitWithTimeout("waiting for foreground tools/list waiter to attach to prewarm load") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 1
            }
        }
        #expect(
            await manager.controlPlaneCoordinator.timeoutForegroundToolsCatalogWaiterForTesting()
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await firstTask.value
        }
        try await upstream.waitForBlockedCancellation()
        let prewarmCancellation = try await sentValue(
            from: upstream,
            at: 3,
            timeout: .seconds(2)
        )
        #expect(
            try extractCancellationRequestID(from: prewarmCancellation)
                == extractUpstreamID(from: prewarmRequest)
        )
        await upstream.releaseBlockedCancellation()
        _ = try await waitForRecordedValue(
            prewarmCompletions,
            at: 0,
            description: "waiting for timed-out tools/list prewarm completion"
        )
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 5, timeoutSeconds: 2)
        let secondRequest = try await sentValue(from: upstream, at: 4, timeout: .seconds(2))
        #expect(methodName(from: secondRequest) == "tools/list")
        _ = try await waitWithTimeout("waiting for fresh tools/list waiter to attach") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 1
            }
        }
        #expect(
            await manager.controlPlaneCoordinator.timeoutForegroundToolsCatalogWaiterForTesting()
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await secondTask.value
        }
    }

    @Test(arguments: ["catalog", "missing-payload", "invalid-method"])
    func malformedReplyReturnsProtocolErrorWithoutWaitingForTimeout(kind: String) async throws {
        let config = makeConfig(requestTimeout: 30)
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(config: config, upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let sessionID = "invalid-catalog"
        _ = try await fixture.initializePrimary(on: upstream, sessionID: sessionID)
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
        let executor = ClientMCPRequestExecutor(
            config: config, sessionManager: fixture.manager,
)
        let sentCount = await upstream.sentCount()
        let operation = try executor.handle(
            bodyData: JSONRPC.Wire.data(from: JSONRPC.Wire.requestObject(
                id: 81, method: kind == "catalog" ? "tools/list" : "tools/call",
                params: kind == "catalog" ? nil : .object(["name": .string("Echo"), "arguments": .object([:])])
            )),
            headerSessionID: sessionID, headerSessionExists: true,
            prefersEventStream: false, eventLoop: fixture.eventLoop
        )
        let request = try await sentValue(from: upstream, at: sentCount, timeout: .seconds(2))
        let requestID = try #require(JSONRPC.ID(any: extractUpstreamID(from: request)))
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": requestID.value.foundationObject]
        switch kind {
        case "catalog": reply["result"] = ["tools": "private malformed catalog"]
        case "invalid-method": reply["method"] = 1
        default: break
        }
        await upstream.yield(.message(try JSONRPC.Wire.data(from: reply)))
        let resolution = try await waitWithTimeout("malformed catalog should fail immediately", timeout: .seconds(2)) {
            try await operation.future.get()
        }
        let data: Data
        switch resolution {
        case .responseData(let responseData, _, _): data = responseData
        case .mcpError(let id, let code, let message, _, _):
            data = try JSONRPC.Wire.errorResponseData(id: id, code: code, message: message)
        default:
            Issue.record("expected JSON-RPC response")
            return
        }
        let response = try JSONRPC.Wire.object(fromData: data)
        let error = try #require(JSONRPC.Wire.errorPayload(inResponseObject: response))
        #expect(error.code == -32603)
        #expect(error.message == "invalid upstream response")
        #expect((response["id"] as? NSNumber)?.intValue == 81)
        #expect(!String(decoding: data, as: UTF8.self).contains("private malformed catalog"))
    }

    @Test func sessionManagerLateToolsListResponseDoesNotReseedCanonicalCatalog() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-tools-late-response"
        _ = manager.session(id: sessionID)
        let task = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        let toolsRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        let toolsUpstreamID = try extractUpstreamID(from: toolsRequest)

        manager.handleUpstreamExit(1, upstreamIndex: 0)

        do {
            _ = try await task.value
            Issue.record("tools/list should fail when the only upstream exits")
        } catch {
        }

        let lateResponse = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": toolsUpstreamID,
                "result": ["tools": []],
            ],
            options: []
        )
        manager.routeUpstreamMessage(lateResponse, upstreamIndex: 0)

        #expect(manager.cachedToolsListResult() == nil)
    }

    @Test func pendingInitializeArmsNextQuarantinedSupporterWhileFirstProbeIsInFlight()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let firstUpstream = TestUpstreamClient()
        let secondUpstream = TestUpstreamClient()
        let uptimeClock = TestUptimeClock()
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        var config = makeConfig(requestTimeout: 0)
        config.prewarmToolsList = false
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [firstUpstream, secondUpstream],
            nowUptimeNanoseconds: uptimeClock.now,
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        let firstResult = try jsonValue([
            "protocolVersion": MCP.ProtocolVersion.current,
            "capabilities": [String: Any](),
            "serverInfo": ["name": "first"],
        ])
        let secondResult = try jsonValue([
            "protocolVersion": MCP.ProtocolVersion.current,
            "capabilities": [String: Any](),
            "serverInfo": ["name": "second"],
        ])
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: firstResult,
            sourceUpstream: 0
        )
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: secondResult,
            sourceUpstream: 1
        )
        manager.markToolsListRefreshFailed(
            upstreamIndex: 0,
            nowUptimeNs: uptimeClock.now(),
            reason: "first_quarantine"
        )
        manager.markToolsListRefreshFailed(
            upstreamIndex: 1,
            nowUptimeNs: uptimeClock.now(),
            reason: "second_quarantine"
        )
        #expect(manager.canonicalHandshakeState.initializeResult() == nil)

        let initialRecoverySearchIndex = timeoutScheduler.scheduledEventCount()
        let pending = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 80500))!,
            requestObject: makeInitializeRequest(id: 80500),
            on: eventLoop
        )
        let initialRecoveryIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .seconds(30),
            startingAtEventIndex: initialRecoverySearchIndex
        )
        let nextRecoverySearchIndex = timeoutScheduler.scheduledEventCount()
        uptimeClock.advance(by: .seconds(31))
        #expect(timeoutScheduler.fire(at: initialRecoveryIndex))
        let firstProbe = try await sentValue(
            from: firstUpstream,
            at: 0,
            timeout: .seconds(2)
        )
        let nextRecoveryIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .nanoseconds(0),
            startingAtEventIndex: nextRecoverySearchIndex
        )
        #expect(timeoutScheduler.fire(at: nextRecoveryIndex))
        let secondProbe = try await sentValue(
            from: secondUpstream,
            at: 0,
            timeout: .seconds(2)
        )

        await secondUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: secondProbe),
                    tools: []
                ))
        )
        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "waiting for second quarantined supporter recovery",
                timeout: .seconds(2)
            ) {
                try await pending.get()
            }
        )
        #expect(response["result"] != nil)
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 1)

        await firstUpstream.yield(
            .message(
                try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": try extractUpstreamID(from: firstProbe),
                    "result": [:],
                ]))
        )
        await manager.drainRuntimeTasksForTesting()
    }

    @Test func upstreamSendAdmissionRejectsAfterInitializeShutdownBegins() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 5),
            upstreams: [upstream],
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let operationLease = manager.operationLeaseForTest(upstreamIndex: 0)
        let rejected = NIOLockedValueBox(false)
        let requestSendCompletion = UpstreamRequestSendCompletion()

        _ = manager.initializeManager.beginShutdown()
        let scheduled = manager.sendUpstream(
            try makeToolListRequest(id: 1),
            operationLease: operationLease,
            ensureRunning: false,
            requestSendCompletion: requestSendCompletion,
            onRejected: {
                rejected.withLockedValue { $0 = true }
            }
        )

        #expect(scheduled == false)
        #expect(rejected.withLockedValue { $0 })
        #expect(await requestSendCompletion.wait() == .notSent)
        await manager.drainRuntimeTasksForTesting()
        #expect(await upstream.sent().filter { methodName(from: $0) != "notifications/cancelled" }.count == 0)
    }

}
