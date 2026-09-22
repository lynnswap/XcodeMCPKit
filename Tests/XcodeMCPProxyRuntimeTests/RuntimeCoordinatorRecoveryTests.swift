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
        #expect(await upstream.sentCount() == 3)
        await upstream.releaseBlockedSend()
        try await upstream.waitForBlockedCancellation()
        #expect(await upstream.sentCount() == 4)
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
                requestTimeoutOverride: .seconds(1)
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

    @Test func controlPlaneRejectsExpiredLoadsBeforeStartingUnobservedWork() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
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

        let expiredDeadline = clocks.uptimeClock.now()
        await #expect(throws: TimeoutError.self) {
            _ = try await manager.controlPlaneCoordinator.toolsCatalog(
                deadlineUptimeNs: expiredDeadline
            )
        }
        #expect(
            await manager.controlPlaneCoordinator.prewarmToolsCatalogIfNeeded(
                deadlineUptimeNs: expiredDeadline
            ) == nil
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await manager.controlPlaneCoordinator.listWindows(
                route: .anyHealthy,
                deadlineUptimeNs: expiredDeadline
            )
        }

        #expect(
            await manager.controlPlaneCoordinator.requestToolsCatalogLoadSnapshotForTesting()?
                .loadID == nil
        )
        #expect(
            await manager.controlPlaneCoordinator.prewarmToolsCatalogLoadSnapshotForTesting()?
                .loadID == nil
        )
        #expect(
            await manager.controlPlaneCoordinator.windowLoadSnapshotForTesting(route: .anyHealthy)?
                .loadID == nil
        )
        #expect(await upstream.sentCount() == 2)
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

    @Test func malformedCatalogReturnsProtocolErrorWithoutWaitingForTimeout() async throws {
        let config = makeConfig(requestTimeout: 30)
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(config: config, upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let sessionID = "invalid-catalog"
        _ = try await fixture.initializePrimary(on: upstream, sessionID: sessionID)
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
        let executor = ClientMCPRequestExecutor(
            config: config, sessionManager: fixture.manager,
            refreshCodeIssuesCoordinator: .makeDefault(),
            refreshCodeIssuesDebugState: .init(defaultRequestTimeoutSeconds: config.requestTimeout)
        )
        let sentCount = await upstream.sentCount()
        let operation = try executor.handle(
            bodyData: JSONRPC.Wire.data(from: JSONRPC.Wire.requestObject(id: 81, method: "tools/list")),
            headerSessionID: sessionID, headerSessionExists: true,
            prefersEventStream: false, eventLoop: fixture.eventLoop
        )
        let request = try await sentValue(from: upstream, at: sentCount, timeout: .seconds(2))
        let requestID = try #require(JSONRPC.ID(any: extractUpstreamID(from: request)))
        await upstream.yield(.message(try JSONRPC.Wire.resultResponseData(
            id: requestID, result: .object(["tools": .string("private malformed catalog")])
        )))
        let resolution = try await waitWithTimeout("malformed catalog should fail immediately", timeout: .seconds(2)) {
            try await operation.future.get()
        }
        guard case .responseData(let data, _, _) = resolution else {
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

    @Test func processRoutedToolsListRetriesSiblingUpstreamAfterExit() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 713, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-single-xcode-tools-retry",
                requestTimeoutOverride: .seconds(5)
            )
        }

        let firstRequest = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        #expect(methodName(from: firstRequest) == "tools/list")

        manager.handleUpstreamExit(1, upstreamIndex: 0)

        let retryRequest = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        #expect(methodName(from: retryRequest) == "tools/list")
        await upstream1.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: retryRequest),
                    tools: [
                        toolDescriptor(name: "XcodeListWindows")
                    ]
                )
            )
        )

        let result = try await waitWithTimeout("waiting for process-routed tools/list retry") {
            try await task.value
        }
        #expect(toolNames(in: result) == ["XcodeListWindows"])
        #expect(manager.debugSnapshot().controlPlane?.phase == "idle")
        #expect(manager.debugSnapshot().processToolCatalogs.map(\.processID) == [target.processID])
    }

    @Test func sessionManagerLiveXcodeListWindowsTimeoutStartsFreshControlPlaneLoad()
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

        let firstTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let firstRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: firstRequest) == "tools/call")
        _ = try await waitWithTimeout("waiting for first XcodeListWindows waiter to attach") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.windows == 1
            }
        }
        #expect(
            await manager.controlPlaneCoordinator.timeoutWindowWaiterForTesting(route: .anyHealthy)
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await firstTask.value
        }

        _ = try await waitWithTimeout("waiting for timed-out XcodeListWindows load cleanup") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.windows == 0 && $0.inFlightControlPlaneRequests.isEmpty
            }
        }
        _ = try await waitWithTimeout("waiting for timed-out XcodeListWindows request cleanup") {
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
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 5, timeoutSeconds: 2)
        let secondRequest = try await sentValue(from: upstream, at: 4, timeout: .seconds(2))
        #expect(methodName(from: secondRequest) == "tools/call")
        _ = try await waitWithTimeout("waiting for second XcodeListWindows waiter to attach") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.windows == 1
            }
        }
        #expect(
            await manager.controlPlaneCoordinator.timeoutWindowWaiterForTesting(route: .anyHealthy)
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await secondTask.value
        }
    }

    @Test func sessionManagerToolsListReturnsAvailableCatalogDespiteKnownOwner()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let olderUpstream = TestUpstreamClient()
        let latestUpstream = TestUpstreamClient()
        let latestTarget = xcodeProcessTarget(processID: 80422, xcodeVersion: "27.0")
        let olderTarget = xcodeProcessTarget(processID: 66333, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 0),
            eventLoop: eventLoop,
            upstreams: [olderUpstream, latestUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: latestTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "known-owner-first-success"],
            ]),
            sourceUpstream: 1
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-latest, workspacePath: /tmp/Latest.xcworkspace"
                    ]
                ]),
                upstreamIndex: 1
            )
        )

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-available-owner",
                requestTimeoutOverride: nil
            )
        }

        let latestRequest = try await sentValue(from: latestUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: latestRequest) == "tools/list")
        let olderRequest = try await sentValue(from: olderUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: olderRequest) == "tools/list")
        await latestUpstream.yield(.message(try JSONRPC.Wire.resultResponseData(
            id: JSONRPC.ID(any: try extractUpstreamID(from: latestRequest))!,
            result: try jsonValue([
                "tools": [toolDescriptor(name: "SharedTool", description: "from-27")],
                "nextCursor": "latest-second-page",
            ])
        )))
        let latestSecondRequest = try await sentValue(from: latestUpstream, at: 1, timeout: .seconds(2))
        #expect(manager.cachedToolsListResult(forUpstreamIndex: 1) == nil)
        await latestUpstream.yield(.message(try makeDocumentationToolsListResponse(
            id: try extractUpstreamID(from: latestSecondRequest),
            tools: [toolDescriptor(name: "Only27", description: "new-only")]
        )))
        let partial = try await waitWithTimeout("waiting for available process catalog") {
            try await task.value
        }
        #expect(Set(toolNames(in: partial)) == Set(["Only27", "SharedTool"]))
        #expect(toolDescription(in: partial, name: "SharedTool") == "from-27")
        #expect(manager.cachedToolsListResult() == nil)
        let cancellation = try await olderUpstream.nextSent(
            startingAt: 1,
            matching: { methodName(from: $0) == "notifications/cancelled" }
        )
        #expect(
            try extractCancellationRequestID(from: cancellation)
                == extractUpstreamID(from: olderRequest)
        )
        let backgroundRequest = try await olderUpstream.nextSent(
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" }
        )
        await olderUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: backgroundRequest),
                    tools: [
                        toolDescriptor(name: "Only26", description: "old-only")
                    ]
                )
            )
        )
        _ = try await waitWithTimeout("waiting for complete process catalog") {
            await manager.drainRuntimeTasksForTesting()
        }
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == 1)
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set(["Only26", "Only27", "SharedTool"])
        )
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult(forUpstreamIndex: 1) ?? .null))
                == Set([
                    "Only27",
                    "SharedTool",
                ]))
        #expect(await olderUpstream.sentCount() == 3)
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)

        let catalogs = manager.debugSnapshot().processToolCatalogs
        #expect(catalogs.count == 2)
        let latestCatalog = try #require(catalogs.first { $0.processID == latestTarget.processID })
        #expect(latestCatalog.toolCount == 2)
        #expect(latestCatalog.tabOwnerCount == 1)
        #expect(latestCatalog.workspaceOwnerCount == 1)
        #expect(latestCatalog.isCanonicalSource)
        #expect(latestCatalog.exposurePolicy == "available_route_catalog_surface")
        #expect(latestCatalog.extraBeyondExposedCatalog == ["Only26"])
        #expect(latestCatalog.schemaConflicts == [])

        manager.routeUpstreamMessage(
            try JSONRPC.Wire.data(from: JSONRPC.Wire.notificationObject(method: "notifications/tools/list_changed")),
            upstreamIndex: 1
        )
        #expect(manager.processControlPlane.catalog(forProcessID: latestTarget.processID) == nil)
        #expect(toolNames(in: manager.processControlPlane.catalog(forProcessID: olderTarget.processID)!.rawResult) == ["Only26"])
    }

    @Test func sessionManagerToolsListUnionsFallbackCatalogAfterOwnerIsLearned()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let fallbackUpstream = TestUpstreamClient()
        let ownerUpstream = TestUpstreamClient()
        let ownerTarget = xcodeProcessTarget(processID: 80424, xcodeVersion: "27.0")
        let fallbackTarget = xcodeProcessTarget(processID: 66337, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [fallbackUpstream, ownerUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: fallbackTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: ownerTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "fallback-owner"],
            ]),
            sourceUpstream: 0
        )

        let fallbackTask = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-before-owner",
                requestTimeoutOverride: .seconds(5)
            )
        }
        let fallbackRequest = try await sentValue(from: fallbackUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: fallbackRequest) == "tools/list")
        #expect(await ownerUpstream.sentCount() == 0)
        await fallbackUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: fallbackRequest),
                    tools: [
                        toolDescriptor(name: "FallbackOnly")
                    ]
                )
            )
        )
        let fallbackResult = try await waitWithTimeout("waiting for fallback tools/list") {
            try await fallbackTask.value
        }
        #expect(toolNames(in: fallbackResult) == ["FallbackOnly"])
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["FallbackOnly"])

        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-owner-late, workspacePath: /tmp/LateOwner.xcworkspace"
                    ]
                ]),
                upstreamIndex: 1
            )
        )
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["FallbackOnly"])
        manager.markUpstreamInitialized(upstreamIndex: 1)
        #expect(manager.cachedToolsListResult() == nil)
        manager.refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "test_owner_catalog_background_refresh",
            processIDs: [ownerTarget.processID]
        )
        let ownerRequest = try await sentValue(from: ownerUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: ownerRequest) == "tools/list")
        let ownerResult = try await manager.sharedToolsList(
            sessionID: "session-process-catalog-after-owner",
            requestTimeoutOverride: nil
        )
        #expect(toolNames(in: ownerResult) == ["FallbackOnly"])
        await ownerUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: ownerRequest),
                    tools: [
                        toolDescriptor(name: "OwnerOnly")
                    ]
                )
            )
        )
        _ = try await waitWithTimeout("waiting for owner catalog completion") {
            await manager.drainRuntimeTasksForTesting()
        }
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set([
                    "FallbackOnly",
                    "OwnerOnly",
                ]))
        #expect(await fallbackUpstream.sentCount() == 1)
        #expect(await ownerUpstream.sentCount() == 1)
    }

    @Test func sessionManagerToolsListReturnsFirstCatalogAndCompletesMissingRouteInBackground()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let olderUpstream = TestUpstreamClient()
        let newerUpstream = TestUpstreamClient()
        let olderTarget = xcodeProcessTarget(processID: 66338, xcodeVersion: "26.6")
        let newerTarget = xcodeProcessTarget(processID: 80425, xcodeVersion: "27.0")
        let catalogCommits = LockedRecordedValues<(pid_t, Int)>()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 0),
            eventLoop: eventLoop,
            upstreams: [olderUpstream, newerUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: newerTarget, upstreamIndices: [1]),
            ],
            testHooks: RuntimeCoordinatorTestHooks(
                processRouteCatalogCommitted: { catalogCommits.append(($0, $1)) }
            ),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "catalog-first-success"],
            ]),
            sourceUpstream: 1
        )
        let notificationSessionID = "session-process-catalog-first-success-notifications"
        let notificationSession = manager.session(id: notificationSessionID)
        manager.sessionRegistry.markInitialized(
            id: notificationSessionID,
            negotiatedProtocolVersion: MCP.ProtocolVersion.current
        )
        _ = notificationSession.router.drainBufferedNotifications()

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-later-usable-route",
                requestTimeoutOverride: nil
            )
        }

        let olderRequest = try await sentValue(from: olderUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: olderRequest) == "tools/list")
        let newerRequest = try await sentValue(from: newerUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: newerRequest) == "tools/list")
        await newerUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: newerRequest),
                    tools: [
                        toolDescriptor(name: "NewerRouteOnly"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                )
            )
        )
        let partial = try await waitWithTimeout(
            "waiting for first usable process catalog"
        ) {
            try await task.value
        }
        #expect(Set(toolNames(in: partial)) == Set(["NewerRouteOnly", "XcodeListWindows"]))
        #expect(manager.cachedToolsListResult() == nil)
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult(forUpstreamIndex: 1) ?? .null))
                == Set(["NewerRouteOnly", "XcodeListWindows"])
        )
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == nil)
        let cancellation = try await olderUpstream.nextSent(
            startingAt: 1,
            matching: { methodName(from: $0) == "notifications/cancelled" }
        )
        #expect(
            try extractCancellationRequestID(from: cancellation)
                == extractUpstreamID(from: olderRequest)
        )
        let backgroundRequest = try await olderUpstream.nextSent(
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" }
        )
        #expect(try extractUpstreamID(from: backgroundRequest) != extractUpstreamID(from: olderRequest))
        #expect(await olderUpstream.sentCount() == 3)
        #expect(await newerUpstream.sentCount() == 1)
        _ = notificationSession.router.drainBufferedNotifications()

        let windowsTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: nil
            )
        }
        let windowsRequest = try await newerUpstream.nextSent(
            startingAt: 1,
            matching: {
                methodName(from: $0) == "tools/call"
                    && toolCallName(from: $0) == "XcodeListWindows"
            }
        )
        #expect(await olderUpstream.sentCount() == 3)
        await newerUpstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: windowsRequest),
                    message: "* tabIdentifier: tab-newer, workspacePath: /Work/Newer.xcworkspace"
                )
            )
        )
        _ = try await waitWithTimeout("waiting for cataloged-route window discovery") {
            try await windowsTask.value
        }

        let repeatedPartial = try await manager.sharedToolsList(
            sessionID: "session-process-catalog-existing-partial",
            requestTimeoutOverride: nil
        )
        #expect(
            Set(toolNames(in: repeatedPartial))
                == Set(["NewerRouteOnly", "XcodeListWindows"])
        )
        #expect(await olderUpstream.sentCount() == 3)
        let abandonedLease = try #require(
            manager.debugSnapshot().leases.first {
                $0.label == "tools/list"
                    && $0.upstreamIndex == 0
                    && $0.state == .abandoned
                    && $0.releaseReason == "clientDisconnected"
            }
        )
        #expect(abandonedLease.requestIDKey != nil)
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 1)

        await olderUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: backgroundRequest),
                    tools: [
                        toolDescriptor(name: "OlderRouteOnly")
                    ]
                )
            )
        )
        let backgroundCommit = try await nextRecordedValue(catalogCommits, at: 1)
        #expect(backgroundCommit.0 == olderTarget.processID)
        #expect(backgroundCommit.1 == 0)
        _ = try await waitWithTimeout("waiting for background catalog completion") {
            await manager.drainRuntimeTasksForTesting()
        }
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set(["NewerRouteOnly", "OlderRouteOnly", "XcodeListWindows"])
        )
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
        let notificationMethods = notificationSession.router.drainBufferedNotifications().compactMap {
            methodName(from: $0)
        }
        #expect(notificationMethods == ["notifications/tools/list_changed"])
        #expect(notificationSession.router.drainBufferedNotifications().isEmpty)
    }

    @Test func sessionManagerToolsListCompletesCachedProcessCatalogWithFreshRoutes()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let olderUpstream = TestUpstreamClient()
        let middleUpstream = TestUpstreamClient()
        let latestUpstream = TestUpstreamClient()
        let olderTarget = xcodeProcessTarget(processID: 66339, xcodeVersion: "26.6")
        let middleTarget = xcodeProcessTarget(processID: 70339, xcodeVersion: "26.9")
        let latestTarget = xcodeProcessTarget(processID: 80426, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [olderUpstream, middleUpstream, latestUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: latestTarget, upstreamIndices: [2]),
                XcodeProcessRoute(target: middleTarget, upstreamIndices: [1]),
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        manager.markUpstreamInitialized(upstreamIndex: 2)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "cached-fresh-routes"],
            ]),
            sourceUpstream: 0
        )
        try seedProcessToolCatalogs(
            on: manager,
            entries: [(olderTarget, 0, [toolDescriptor(name: "OlderRouteOnly")])]
        )
        manager.refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "test_cached_fresh_routes_background_refresh",
            processIDs: [middleTarget.processID, latestTarget.processID]
        )

        let middleRequest = try await sentValue(from: middleUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: middleRequest) == "tools/list")
        let latestRequest = try await sentValue(from: latestUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: latestRequest) == "tools/list")
        let partial = try await manager.sharedToolsList(
            sessionID: "session-process-catalog-cached-union",
            requestTimeoutOverride: nil
        )
        #expect(toolNames(in: partial) == ["OlderRouteOnly"])
        await latestUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: latestRequest),
                    tools: [
                        toolDescriptor(name: "LatestRouteOnly")
                    ]
                )
            )
        )
        await middleUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: middleRequest),
                    tools: [
                        toolDescriptor(name: "MiddleRouteOnly")
                    ]
                )
            )
        )
        _ = try await waitWithTimeout("waiting for complete cached process catalog") {
            await manager.drainRuntimeTasksForTesting()
        }
        #expect(manager.cachedToolsListResult() != nil)
        #expect(await olderUpstream.sentCount() == 0)
        #expect(await middleUpstream.sentCount() == 1)
        #expect(await latestUpstream.sentCount() == 1)
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set([
                    "LatestRouteOnly",
                    "MiddleRouteOnly",
                    "OlderRouteOnly",
                ]))
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == 2)
        let catalogs = manager.debugSnapshot().processToolCatalogs
        #expect(catalogs.count == 3)
        #expect(try #require(catalogs.first { $0.processID == olderTarget.processID }).toolCount == 1)
        #expect(try #require(catalogs.first { $0.processID == middleTarget.processID }).toolCount == 1)
        #expect(try #require(catalogs.first { $0.processID == latestTarget.processID }).toolCount == 1)
    }

    @Test func sessionManagerToolsListKeepsCachedProcessCatalogWhenFreshRouteFails()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let olderUpstream = TestUpstreamClient()
        let latestUpstream = TestUpstreamClient()
        let olderTarget = xcodeProcessTarget(processID: 66340, xcodeVersion: "26.6")
        let latestTarget = xcodeProcessTarget(processID: 80427, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [olderUpstream, latestUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: latestTarget, upstreamIndices: [1]),
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "cached-fresh-failure"],
            ]),
            sourceUpstream: 0
        )
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (olderTarget, 0, [toolDescriptor(name: "OlderRouteOnly")])
            ]
        )
        manager.refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "test_cached_fresh_failure_background_refresh",
            processIDs: [latestTarget.processID]
        )

        let latestRequest = try await sentValue(from: latestUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: latestRequest) == "tools/list")
        let result = try await manager.sharedToolsList(
            sessionID: "session-process-catalog-cached-fresh-fails",
            requestTimeoutOverride: nil
        )
        #expect(toolNames(in: result) == ["OlderRouteOnly"])
        await latestUpstream.yield(
            .message(
                try JSONSerialization.data(
                    withJSONObject: [
                        "jsonrpc": "2.0",
                        "id": try extractUpstreamID(from: latestRequest),
                        "result": [
                            "tools": "invalid"
                        ],
                    ],
                    options: []
                )
            )
        )
        _ = try await waitWithTimeout("waiting for failed background catalog cleanup") {
            await manager.drainRuntimeTasksForTesting()
        }
        #expect(manager.cachedToolsListResult() == nil)
        #expect(toolNames(in: manager.cachedToolsListResult(forUpstreamIndex: 0) ?? .null) == ["OlderRouteOnly"])
        #expect(await olderUpstream.sentCount() == 0)
        #expect(await latestUpstream.sentCount() == 1)
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == nil)
        #expect(
            manager.debugSnapshot().processToolCatalogs.map(\.processID) == [
                olderTarget.processID
            ])
    }

    @Test func sessionManagerRetriesPendingProcessCatalogAfterQuarantinedRouteRecovers()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 80429, xcodeVersion: "27.0")
        let uptimeClock = TestUptimeClock()
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let toolsListRefreshes = LockedRecordedValues<(Int, Bool)>()
        var config = makeConfig(requestTimeout: 0)
        config.prewarmToolsList = false
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: uptimeClock.now,
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            testHooks: RuntimeCoordinatorTestHooks(
                toolsListRefreshCompleted: { upstreamIndex, succeeded in
                    toolsListRefreshes.append((upstreamIndex, succeeded))
                }
            ),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let cachedInitialize = try jsonValue([
            "protocolVersion": MCP.ProtocolVersion.current,
            "capabilities": [String: Any](),
            "serverInfo": ["name": "cached-source"],
        ])
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: cachedInitialize,
            sourceUpstream: 0
        )
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [toolDescriptor(name: "BeforeQuarantine")])
            ]
        )
        let operationLease = manager.operationLeaseForTest(upstreamIndex: 0)
        manager.markToolsListRefreshFailed(
            upstreamIndex: 0,
            nowUptimeNs: uptimeClock.now(),
            reason: "test_catalog_failure"
        )
        #expect(manager.canonicalHandshakeState.initializeResult() == nil)
        #expect(manager.canonicalHandshakeState.snapshot().supporterProofs.isEmpty)
        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) == nil)
        #expect(
            manager.processControlPlane.attemptSnapshot(processID: target.processID)?.phase
                == .abandoned
        )

        manager.markRequestSucceeded(operationLease)
        #expect(manager.canonicalHandshakeState.initializeResult() == nil)
        guard let quarantined = manager.testStateSnapshot().upstream(id: 0),
            case .quarantined = quarantined.healthState
        else {
            Issue.record("generic request success must not restore a quarantined supporter")
            return
        }

        let initialRecoverySearchIndex = timeoutScheduler.scheduledEventCount()
        let pendingInitialize = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 80429))!,
            requestObject: makeInitializeRequest(id: 80429),
            on: eventLoop
        )
        let pendingCompletionCount = NIOLockedValueBox(0)
        pendingInitialize.whenComplete { _ in
            pendingCompletionCount.withLockedValue { $0 += 1 }
        }
        #expect(await upstream.sentCount() == 0)
        let initialRecoveryIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .seconds(30),
            startingAtEventIndex: initialRecoverySearchIndex
        )

        uptimeClock.advance(by: .seconds(31))
        #expect(timeoutScheduler.fire(at: initialRecoveryIndex))
        let probeRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: probeRequest) == "tools/list")
        let nextRecoverySearchIndex = timeoutScheduler.scheduledEventCount()
        await upstream.yield(
            .message(
                try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": try extractUpstreamID(from: probeRequest),
                    "result": [:],
                ]))
        )
        await manager.drainRuntimeTasksForTesting()
        #expect(manager.canonicalHandshakeState.initializeResult() == nil)
        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) == nil)
        #expect(pendingCompletionCount.withLockedValue { $0 } == 0)
        let nextRecoveryIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .seconds(15),
            startingAtEventIndex: nextRecoverySearchIndex
        )

        uptimeClock.advance(by: .seconds(16))
        #expect(timeoutScheduler.fire(at: nextRecoveryIndex))
        let validProbeRequest = try await sentValue(
            from: upstream,
            at: 1,
            timeout: .seconds(2)
        )
        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: validProbeRequest),
                    tools: []
                ))
        )

        let initializeResponse = try decodeJSON(
            from: try await waitWithTimeout(
                "waiting for recovered raw initialize publication",
                timeout: .seconds(2)
            ) {
                try await pendingInitialize.get()
            }
        )
        #expect(initializeResponse["result"] != nil)
        #expect(manager.canonicalHandshakeState.initializeResult() == cachedInitialize)
        #expect(
            manager.canonicalHandshakeState.snapshot().supporterProofs == [operationLease.proof]
        )
        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) == nil)

        let catalogRequest = try await sentValue(
            from: upstream,
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2),
            description: "waiting for pending process catalog refresh after health probe"
        )
        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: catalogRequest),
                    tools: [
                        toolDescriptor(name: "RecoveredRouteOnly")
                    ]
                )
            )
        )
        await manager.drainRuntimeTasksForTesting()

        let failedRefresh = try await nextRecordedValue(toolsListRefreshes, at: 0)
        #expect(failedRefresh.0 == 0)
        #expect(failedRefresh.1 == false)
        let recoveredRefresh = try await nextRecordedValue(toolsListRefreshes, at: 1)
        #expect(recoveredRefresh.0 == 0)
        #expect(recoveredRefresh.1 == true)
        #expect(
            manager.processControlPlane.pendingCatalogProcessIDs(
                nowUptimeNs: manager.nowUptimeNanoseconds()
            ).isEmpty)
        #expect(manager.debugSnapshot().processToolCatalogs.map(\.processID) == [target.processID])
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["RecoveredRouteOnly"])
        #expect(timeoutScheduler.isCancelled(at: 0))
        let sentCountAfterRecovery = await upstream.sentCount()
        #expect(timeoutScheduler.fireIgnoringCancellation(at: initialRecoveryIndex))
        #expect(timeoutScheduler.fireIgnoringCancellation(at: nextRecoveryIndex))
        await manager.drainRuntimeTasksForTesting()
        #expect(await upstream.sentCount() == sentCountAfterRecovery)
    }

    @Test func quarantiningNonSourceSupporterPreservesWinnerAndEvictsOnlyExactCatalog()
        throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let firstTarget = xcodeProcessTarget(processID: 80450, xcodeVersion: "27.0")
        let secondTarget = xcodeProcessTarget(processID: 66350, xcodeVersion: "26.6")
        var config = makeConfig(requestTimeout: 5)
        config.prewarmToolsList = false
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: firstTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: secondTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        let firstResult = try jsonValue([
            "protocolVersion": MCP.ProtocolVersion.current,
            "capabilities": [String: Any](),
            "serverInfo": ["name": "Xcode 27"],
        ])
        let secondResult = try jsonValue([
            "protocolVersion": MCP.ProtocolVersion.current,
            "capabilities": [String: Any](),
            "serverInfo": ["name": "Xcode 26.6"],
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (firstTarget, 0, [toolDescriptor(name: "WinnerTool")]),
                (secondTarget, 1, [toolDescriptor(name: "QuarantinedTool")]),
            ]
        )
        let firstProof = manager.operationLeaseForTest(upstreamIndex: 0).proof
        let secondLease = manager.operationLeaseForTest(upstreamIndex: 1)

        manager.markRequestTimedOut(secondLease)
        manager.markRequestTimedOut(secondLease)
        manager.markRequestTimedOut(secondLease)

        let handshake = manager.canonicalHandshakeState.snapshot()
        #expect(handshake.initializeResult == firstResult)
        #expect(handshake.initializeSourceProof == firstProof)
        #expect(handshake.supporterProofs == [firstProof])
        #expect(manager.processControlPlane.catalog(forProcessID: firstTarget.processID) != nil)
        #expect(manager.processControlPlane.catalog(forProcessID: secondTarget.processID) == nil)
        #expect(
            manager.processControlPlane.attemptSnapshot(processID: firstTarget.processID)?.phase
                == .cataloged
        )
        #expect(
            manager.processControlPlane.attemptSnapshot(processID: secondTarget.processID)?.phase
                == .abandoned
        )
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

    @Test func sessionManagerToolsListReturnsCachedPartialWhileBackgroundCatalogIsIncomplete()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let olderUpstream = TestUpstreamClient()
        let latestUpstream = TestUpstreamClient()
        let olderTarget = xcodeProcessTarget(processID: 66341, xcodeVersion: "26.6")
        let latestTarget = xcodeProcessTarget(processID: 80428, xcodeVersion: "27.0")
        let toolsListRefreshes = NIOLockedValueBox<[String]>([])
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 0),
            eventLoop: eventLoop,
            upstreams: [olderUpstream, latestUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: latestTarget, upstreamIndices: [1]),
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0]),
            ],
            testHooks: RuntimeCoordinatorTestHooks(
                toolsListRefreshCompleted: { upstreamIndex, succeeded in
                    toolsListRefreshes.withLockedValue {
                        $0.append("\(upstreamIndex):\(succeeded)")
                    }
                }
            ),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "cached-partial"],
            ]),
            sourceUpstream: 0
        )
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (olderTarget, 0, [toolDescriptor(name: "OlderRouteOnly")])
            ]
        )
        manager.refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "test_cached_partial_background_refresh",
            processIDs: [latestTarget.processID]
        )

        let latestRequest = try await sentValue(from: latestUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: latestRequest) == "tools/list")
        #expect(await olderUpstream.sentCount() == 0)
        #expect(await latestUpstream.sentCount() == 1)
        #expect(manager.cachedToolsListResult() == nil)
        #expect(
            manager.debugSnapshot().processToolCatalogs.map(\.processID) == [
                olderTarget.processID
            ])
        let partial = try await manager.sharedToolsList(
            sessionID: "session-process-catalog-cached-partial",
            requestTimeoutOverride: nil
        )
        #expect(toolNames(in: partial) == ["OlderRouteOnly"])
        let repeatedPartial = try await manager.sharedToolsList(
            sessionID: "session-process-catalog-cached-partial-repeat",
            requestTimeoutOverride: nil
        )
        #expect(toolNames(in: repeatedPartial) == ["OlderRouteOnly"])
        #expect(await latestUpstream.sentCount() == 1)

        await latestUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: latestRequest),
                    tools: [
                        toolDescriptor(name: "LatestRouteOnly")
                    ]
                )
            )
        )
        _ = try await waitWithTimeout("waiting for complete background process catalog") {
            await manager.drainRuntimeTasksForTesting()
        }
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set(["LatestRouteOnly", "OlderRouteOnly"])
        )
        #expect(toolsListRefreshes.withLockedValue { $0 } == ["1:true"])
    }

    @Test func sessionManagerEmptyProcessCatalogPreservesExistingCatalogButInvalidatesIncompleteSurface()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let existingUpstream = TestUpstreamClient()
        let emptyUpstream = TestUpstreamClient()
        let existingTarget = xcodeProcessTarget(processID: 66342, xcodeVersion: "26.6")
        let emptyTarget = xcodeProcessTarget(processID: 80430, xcodeVersion: "27.0")
        let toolsListRefreshes = NIOLockedValueBox<[String]>([])
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [existingUpstream, emptyUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: emptyTarget, upstreamIndices: [1]),
                XcodeProcessRoute(target: existingTarget, upstreamIndices: [0]),
            ],
            testHooks: RuntimeCoordinatorTestHooks(
                toolsListRefreshCompleted: { upstreamIndex, succeeded in
                    toolsListRefreshes.withLockedValue {
                        $0.append("\(upstreamIndex):\(succeeded)")
                    }
                }
            ),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "cached-source"],
            ]),
            sourceUpstream: 0
        )
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (existingTarget, 0, [toolDescriptor(name: "ExistingOnlyTool")])
            ]
        )

        manager.refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "test_empty_process_catalog",
            processIDs: [emptyTarget.processID]
        )
        let emptyRequest = try await sentValue(from: emptyUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: emptyRequest) == "tools/list")
        await emptyUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: emptyRequest),
                    tools: []
                )
            )
        )
        await manager.drainRuntimeTasksForTesting()

        #expect(manager.cachedToolsListResult() == nil)
        #expect(
            manager.debugSnapshot().processToolCatalogs.map(\.processID)
                == [existingTarget.processID]
        )
        #expect(manager.processControlPlane.catalog(forProcessID: emptyTarget.processID) == nil)
        #expect(toolsListRefreshes.withLockedValue { $0 == ["1:true"] })
        #expect(
            manager.processControlPlane.pendingCatalogProcessIDs(
                nowUptimeNs: manager.nowUptimeNanoseconds()
            ).contains(emptyTarget.processID)
        )
        guard let upstream = manager.testStateSnapshot().upstream(id: 1),
            case .healthy = upstream.healthState
        else {
            Issue.record("empty process catalog should leave upstream health usable")
            return
        }
        #expect(await existingUpstream.sentCount() == 0)
    }

    @Test func sessionManagerRecordsProcessCatalogBeforeDisabledToolFiltering()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 80434, xcodeVersion: "27.0")
        var config = makeConfig(requestTimeout: 5)
        config.disabledToolNames = ["HiddenOnlyTool"]
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-before-disabled-filtering",
                requestTimeoutOverride: .seconds(5)
            )
        }
        defer { task.cancel() }

        let request = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: request) == "tools/list")
        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: request),
                    tools: [
                        toolDescriptor(name: "HiddenOnlyTool")
                    ]
                )
            )
        )

        let rawResult = try await waitWithTimeout(
            "waiting for hidden-only process catalog",
            timeout: .seconds(2)
        ) {
            try await task.value
        }
        await manager.drainRuntimeTasksForTesting()

        #expect(toolNames(in: rawResult) == ["HiddenOnlyTool"])
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["HiddenOnlyTool"])
        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) != nil)
        #expect(
            manager.processControlPlane.pendingCatalogProcessIDs(
                nowUptimeNs: manager.nowUptimeNanoseconds()
            ).contains(target.processID) == false
        )

        let clientVisibleResult = RefreshCodeIssues.ToolsListRewriter.rewriteResult(
            rawResult,
            mode: config.refreshCodeIssuesMode,
            hiddenToolNames: config.disabledToolNames
        )
        #expect(toolNames(in: clientVisibleResult).isEmpty)
    }

    @Test func sessionManagerTreatsSingleProcessEmptyToolsCatalogAsMissingSurface()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 80431, xcodeVersion: "27.0")
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "cached-source"],
            ]),
            sourceUpstream: 0
        )

        manager.refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "test_single_empty_process_catalog",
            processIDs: [target.processID]
        )
        let emptyRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: emptyRequest) == "tools/list")
        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: emptyRequest),
                    tools: []
                )
            )
        )
        await manager.drainRuntimeTasksForTesting()

        #expect(manager.cachedToolsListResult() == nil)
        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) == nil)
        #expect(manager.debugSnapshot().processToolCatalogs.isEmpty)
        #expect(
            manager.processControlPlane.pendingCatalogProcessIDs(
                nowUptimeNs: manager.nowUptimeNanoseconds()
            ).contains(target.processID)
        )
        #expect(timeoutScheduler.scheduledCount() == 1)
        #expect(
            timeoutScheduler.delay(at: 0)?.nanoseconds
                == TimeAmount.milliseconds(250).nanoseconds
        )
        guard let upstream = manager.testStateSnapshot().upstream(id: 0),
            case .healthy = upstream.healthState
        else {
            Issue.record("empty process catalog should not quarantine the upstream")
            return
        }
    }

    @Test func sessionManagerCancelsCatalogRetryButPreservesMissingRouteOnDebugReset()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 80444, xcodeVersion: "27.0")
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "cached-source"],
            ]),
            sourceUpstream: 0
        )

        manager.refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "test_empty_process_catalog_reset",
            processIDs: [target.processID]
        )
        let emptyRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: emptyRequest) == "tools/list")
        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: emptyRequest),
                    tools: []
                )
            )
        )
        await manager.drainRuntimeTasksForTesting()

        #expect(timeoutScheduler.scheduledCount() == 1)
        #expect(timeoutScheduler.isCancelled(at: 0) == false)
        #expect(
            manager.processControlPlane.pendingCatalogProcessIDs(
                nowUptimeNs: manager.nowUptimeNanoseconds()
            ).contains(target.processID)
        )

        manager.debugReset()

        #expect(timeoutScheduler.isCancelled(at: 0))
        #expect(timeoutScheduler.fire(at: 0) == false)
        #expect(
            manager.processControlPlane.pendingCatalogProcessIDs(
                nowUptimeNs: manager.nowUptimeNanoseconds()
            ) == [target.processID]
        )
        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) == nil)
    }

    @Test func sessionManagerCancelsStaleCatalogRetryAndKeepsMonotonicAttemptBackoff()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 80445, xcodeVersion: "27.0")
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "cached-source"],
            ]),
            sourceUpstream: 0
        )

        func prepareEmptyCatalogLease() throws -> CatalogLease {
            let route = try #require(
                manager.processControlPlane.route(forProcessID: target.processID)
            )
            let (lease, transition) = try #require(
                manager.processControlPlane.beginCatalogAttempt(
                    routeID: route.id,
                    preferredUpstreamProof: testTopologyProof(0),
                    nowUptimeNanoseconds: manager.nowUptimeNanoseconds()
                )
            )
            manager.applyProcessControlPlaneTransition(transition)
            guard
                case .accepted(_, let completion) = manager.processControlPlane.completeCatalog(
                    .unusable,
                    lease: lease,
                    nowUptimeNanoseconds: manager.nowUptimeNanoseconds()
                )
            else {
                Issue.record("failed to prepare empty catalog retry")
                return lease
            }
            manager.applyProcessControlPlaneTransition(completion)
            return lease
        }

        let firstLease = try prepareEmptyCatalogLease()
        manager.scheduleMissingProcessToolsCatalogRetry(
            processID: target.processID,
            lease: firstLease,
            reason: "test_stale_generation_first"
        )
        #expect(timeoutScheduler.scheduledCount() == 1)
        #expect(timeoutScheduler.isCancelled(at: 0) == false)

        manager.clearCanonicalToolsCatalogForTesting()
        let secondLease = try prepareEmptyCatalogLease()
        manager.scheduleMissingProcessToolsCatalogRetry(
            processID: target.processID,
            lease: secondLease,
            reason: "test_stale_generation_second"
        )

        #expect(timeoutScheduler.isCancelled(at: 0))
        #expect(timeoutScheduler.fire(at: 0) == false)
        #expect(timeoutScheduler.scheduledCount() == 2)
        #expect(timeoutScheduler.isCancelled(at: 1) == false)
        #expect(
            timeoutScheduler.delay(at: 1)?.nanoseconds
                == TimeAmount.milliseconds(500).nanoseconds
        )
        #expect(timeoutScheduler.fire(at: 1))

        let retryRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: retryRequest) == "tools/list")
        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: retryRequest),
                    tools: [
                        toolDescriptor(name: "RecoveredAfterStaleRetry")
                    ]
                )
            )
        )
        await manager.drainRuntimeTasksForTesting()
        #expect(
            toolNames(in: manager.cachedToolsListResult() ?? .null) == [
                "RecoveredAfterStaleRetry"
            ])
    }

    @Test func sessionManagerToolsListSkipsUnavailableProcessRouteCatalog() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let badUpstream = TestUpstreamClient()
        let goodUpstream = TestUpstreamClient()
        let badTarget = xcodeProcessTarget(processID: 80422, xcodeVersion: "27.0")
        let goodTarget = xcodeProcessTarget(processID: 66333, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [badUpstream, goodUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: badTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: goodTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_no_workspace"
        )

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-skip",
                requestTimeoutOverride: .seconds(5)
            )
        }

        let goodRequest = try await sentValue(from: goodUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: goodRequest) == "tools/list")
        await goodUpstream.yield(
            .message(
                try JSONSerialization.data(
                    withJSONObject: [
                        "jsonrpc": "2.0",
                        "id": try extractUpstreamID(from: goodRequest),
                        "result": [
                            "tools": [
                                [
                                    "name": "XcodeRead",
                                    "description": "read",
                                ]
                            ]
                        ],
                    ],
                    options: []
                )
            )
        )

        let result = try await waitWithTimeout("waiting for process-routed tools/list") {
            try await task.value
        }
        #expect(toolNames(in: result) == ["XcodeRead"])
        #expect(await badUpstream.sentCount() == 0)
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["XcodeRead"])
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == 1)
    }

    @Test func clearingLastCatalogSourceInvalidatesCatalogBeforeSlotGenerationReplacement()
        throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let target = xcodeProcessTarget(processID: 80446, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let sourceProof = manager.operationLeaseForTest(upstreamIndex: 0).proof
        let route = try #require(
            manager.processControlPlane.route(forProcessID: target.processID)
        )
        let (lease, transition) = try #require(
            manager.processControlPlane.beginCatalogAttempt(
                routeID: route.id,
                preferredUpstreamProof: sourceProof,
                nowUptimeNanoseconds: manager.nowUptimeNanoseconds()
            )
        )
        manager.applyProcessControlPlaneTransition(transition)
        manager.applyCatalogCommit(
            manager.processControlPlane.completeCatalog(
                .usable(
                    try jsonValue([
                        "tools": [toolDescriptor(name: "GenerationBoundTool")]
                    ]),
                    source: sourceProof
                ),
                lease: lease,
                nowUptimeNanoseconds: manager.nowUptimeNanoseconds()
            ))
        #expect(
            manager.processControlPlane.catalog(forProcessID: target.processID)?.upstreamProof
                == sourceProof
        )

        #expect(manager.clearUpstreamState(proof: sourceProof))
        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) == nil)
        #expect(manager.processControlPlane.canonicalSourceProof() == nil)

        let topologyTransition = try #require(
            manager.upstreamTopology.replace(sourceProof, with: TestUpstreamClient())
        )
        manager.publishUpstreamTopology(topologyTransition.snapshot)
        manager.markUpstreamInitialized(upstreamIndex: 0)

        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) == nil)
        #expect(manager.processControlPlane.canonicalToolsCatalogRaw() == nil)
        #expect(
            manager.processControlPlane.pendingCatalogProcessIDs(
                nowUptimeNs: manager.nowUptimeNanoseconds()
            ).contains(target.processID)
        )
    }

    @Test func catalogSourceLossInvalidatesCatalogWhenSiblingProofWasReplaced() throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let target = xcodeProcessTarget(processID: 80447, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        let sourceProof = manager.operationLeaseForTest(upstreamIndex: 0).proof
        let siblingProof = manager.operationLeaseForTest(upstreamIndex: 1).proof
        let route = try #require(
            manager.processControlPlane.route(forProcessID: target.processID)
        )
        let (lease, transition) = try #require(
            manager.processControlPlane.beginCatalogAttempt(
                routeID: route.id,
                preferredUpstreamProof: sourceProof,
                nowUptimeNanoseconds: manager.nowUptimeNanoseconds()
            )
        )
        manager.applyProcessControlPlaneTransition(transition)
        manager.applyCatalogCommit(
            manager.processControlPlane.completeCatalog(
                .usable(
                    try jsonValue([
                        "tools": [toolDescriptor(name: "TopologyBoundTool")]
                    ]),
                    source: sourceProof
                ),
                lease: lease,
                nowUptimeNanoseconds: manager.nowUptimeNanoseconds()
            ))

        _ = try #require(
            manager.upstreamTopology.replace(siblingProof, with: TestUpstreamClient())
        )
        #expect(manager.clearUpstreamState(proof: sourceProof))

        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) == nil)
        #expect(manager.processControlPlane.canonicalSourceProof() == nil)
    }

    @Test func processRouteCatalogCooldownSurvivesRouteAvailabilitySuccess() async throws {
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 80423, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)

        manager.markXcodeProcessRouteUnavailableAfterCatalogFailure(
            upstreamIndex: 0,
            reason: "catalog_timeout"
        )
        manager.markXcodeProcessRouteAvailable(upstreamIndex: 0)

        #expect(manager.unavailableXcodeProcessIDs().contains(target.processID))

        manager.markXcodeProcessRouteCatalogAvailable(upstreamIndex: 0)
        #expect(manager.unavailableXcodeProcessIDs().contains(target.processID) == false)
    }

    @Test func processRouteCatalogCooldownExcludesSiblingSlotsFromScheduling()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let failedTarget = xcodeProcessTarget(processID: 80424, xcodeVersion: "27.0")
        let healthyTarget = xcodeProcessTarget(processID: 80425, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [
                TestUpstreamClient(),
                TestUpstreamClient(),
                TestUpstreamClient(),
            ],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: failedTarget, upstreamIndices: [0, 1]),
                XcodeProcessRoute(target: healthyTarget, upstreamIndices: [2]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        manager.markUpstreamInitialized(upstreamIndex: 2)

        manager.markXcodeProcessRouteUnavailableAfterCatalogFailure(
            upstreamIndex: 0,
            reason: "catalog_timeout"
        )

        #expect(manager.unavailableXcodeProcessIDs().contains(failedTarget.processID))
        #expect(manager.chooseUpstreamIndex() == 2)

        let preferredDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-catalog-cooldown-preferred",
            label: "tools/call:BuildProject",
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let preferredLeaseID = manager.createRequestLease(descriptor: preferredDescriptor)
        let preferredStartedUpstream = NIOLockedValueBox<Int?>(nil)
        let preferredFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: preferredLeaseID,
            descriptor: preferredDescriptor,
            on: eventLoop,
            preferredUpstreamIndices: [1]
        ) { selectedOperationLease in
            preferredStartedUpstream.withLockedValue {
                $0 = selectedOperationLease.upstreamIndex
            }
            return eventLoop.makeSucceededFuture(())
        }

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            try await preferredFuture.get()
        }
        #expect(preferredStartedUpstream.withLockedValue { $0 } == nil)

        let genericDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-catalog-cooldown-generic",
            label: "tools/call:XcodeRead",
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let genericLeaseID = manager.createRequestLease(descriptor: genericDescriptor)
        let genericStartedUpstream = NIOLockedValueBox<Int?>(nil)
        let genericFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: genericLeaseID,
            descriptor: genericDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            genericStartedUpstream.withLockedValue { $0 = selectedUpstreamIndex.upstreamIndex }
            return eventLoop.makeSucceededFuture(())
        }

        _ = try await genericFuture.get()
        #expect(genericStartedUpstream.withLockedValue { $0 } == 2)
        manager.completeRequestLease(genericLeaseID)
    }

    @Test func sessionManagerToolsListRetriesSiblingBeforeDroppingProcessCatalog()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let unavailableUpstream = AlwaysUnavailableUpstreamClient(reason: .startFailed)
        let siblingUpstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 80433, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [unavailableUpstream, siblingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-sibling-retry",
                requestTimeoutOverride: .seconds(5)
            )
        }

        try await waitForSentCount(unavailableUpstream, count: 1, timeoutSeconds: 2)
        let siblingRequest = try await sentValue(from: siblingUpstream, at: 0, timeout: .seconds(2))
        await siblingUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: siblingRequest),
                    tools: [
                        toolDescriptor(name: "SiblingTool")
                    ]
                )
            )
        )

        let result = try await waitWithTimeout("waiting for sibling process tools/list") {
            try await task.value
        }
        #expect(toolNames(in: result) == ["SiblingTool"])
        #expect(
            manager.debugSnapshot().processToolCatalogs.map(\.processID) == [
                target.processID
            ])
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == 1)
        #expect(manager.documentationCandidateProcessIDs() == Set([target.processID]))
    }

    @Test func sessionManagerToolsListSiblingRetryUsesSharedDeadline()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let firstUpstream = TestUpstreamClient()
        let siblingUpstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 80434, xcodeVersion: "27.0")
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [firstUpstream, siblingUpstream],
            clock: clocks.clock,
            scheduleRuntimeTimeout: makeDeterministicRuntimeTimeoutScheduler(
                clock: clocks.timeoutClock
            ),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-sibling-deadline",
                requestTimeoutOverride: .milliseconds(100)
            )
        }

        _ = try await sentValue(from: firstUpstream, at: 0, timeout: .seconds(2))
        try await clocks.timeoutClock.sleep(untilSuspendedFor: .milliseconds(100))
        clocks.uptimeClock.advance(by: .milliseconds(100))
        clocks.timeoutClock.advance(by: .milliseconds(100))

        do {
            _ = try await waitWithTimeout("waiting for shared deadline timeout") {
                try await task.value
            }
            Issue.record("expected tools/list to fail when sibling deadline is exhausted")
        } catch {
            #expect(error is TimeoutError)
        }
        #expect(await siblingUpstream.sentCount() == 0)
        try await waitWithTimeout(
            "waiting for exhausted sibling deadline retry scheduling",
            timeout: .seconds(2)
        ) {
            await manager.drainRuntimeTasksForTesting()
        }
    }

    @Test func sessionManagerProcessToolsListPropagatesCancellation() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 80435, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 80436, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-cancel",
                requestTimeoutOverride: .seconds(5)
            )
        }

        let request0 = try await upstream0.nextSent {
            methodName(from: $0) == "tools/list"
        }
        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/list"
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let cancellation0 = try await upstream0.nextSent(
            startingAt: 1,
            matching: { methodName(from: $0) == "notifications/cancelled" }
        )
        let cancellation1 = try await upstream1.nextSent(
            startingAt: 1,
            matching: { methodName(from: $0) == "notifications/cancelled" }
        )
        #expect(
            try extractCancellationRequestID(from: cancellation0)
                == extractUpstreamID(from: request0)
        )
        #expect(
            try extractCancellationRequestID(from: cancellation1)
                == extractUpstreamID(from: request1)
        )
        #expect(await upstream0.sentCount() == 2)
        #expect(await upstream1.sentCount() == 2)
    }

    @Test func sessionManagerUnavailableUncatalogedRouteRecomputesRemainingProcessSurface()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let catalogedTarget = xcodeProcessTarget(processID: 80463, xcodeVersion: "27.0")
        let uncatalogedTarget = xcodeProcessTarget(processID: 80464, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: catalogedTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: uncatalogedTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [(catalogedTarget, 0, [toolDescriptor(name: "RemainingSurfaceTool")])]
        )
        #expect(manager.cachedToolsListResult() == nil)

        manager.markXcodeProcessRouteUnavailableAfterCatalogFailure(
            upstreamIndex: 1,
            reason: "test_uncataloged_route_unavailable"
        )

        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["RemainingSurfaceTool"])
        #expect(manager.processControlPlane.canonicalSourceUpstream() == 0)
        #expect(manager.processControlPlane.catalog(forProcessID: uncatalogedTarget.processID) == nil)
    }

    @Test func sessionManagerForegroundProcessCatalogSucceedsAfterOverlappingActivationCatalogCompletes()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 80438, xcodeVersion: "27.0")
        let upstream = TestUpstreamClient()
        let uptimeClock = TestUptimeClock()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: uptimeClock.now,
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "cached-source"],
            ]),
            sourceUpstream: 0
        )
        _ = manager.beginProcessRouteAttachingForTesting(
            processID: target.processID,
            upstreamIndex: 0,
            nowUptimeNs: 0
        )
        let route = try #require(manager.processControlPlane.route(forProcessID: target.processID))
        _ = manager.processControlPlane.markInitialized(
            routeID: route.id,
            upstreamProof: manager.operationLeaseForTest(upstreamIndex: 0).proof
        )

        manager.refreshProcessRouteToolsCatalog(
            route: route,
            upstreamProof: manager.operationLeaseForTest(upstreamIndex: 0).proof,
            reason: "test_overlap_background_refresh"
        )
        let backgroundRequest = try await sentValue(
            from: upstream,
            at: 0,
            timeout: .seconds(2)
        )
        #expect(methodName(from: backgroundRequest) == "tools/list")

        let foregroundTask = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-overlap",
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await waitWithTimeout(
            "waiting for overlapping foreground tools/list waiter",
            timeout: .seconds(2)
        ) {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.toolsCatalog == 1
            }
        }

        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: backgroundRequest),
                    tools: [
                        toolDescriptor(name: "SharedOverlapTool")
                    ]
                )
            )
        )
        _ = try await waitWithTimeout(
            "waiting for overlapping background process catalog",
            timeout: .seconds(2)
        ) {
            while manager.processControlPlane.catalog(forProcessID: target.processID) == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        let result = try await waitWithTimeout(
            "waiting for overlapping foreground process catalog result",
            timeout: .seconds(2)
        ) {
            try await foregroundTask.value
        }
        #expect(toolNames(in: result) == ["SharedOverlapTool"])
        #expect(
            manager.debugSnapshot().processToolCatalogs.map(\.processID) == [
                target.processID
            ])
    }

    @Test func sessionManagerToolsListClearsSiblingCanonicalCatalogWhenProcessRouteUnavailable()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 80431, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [(target, 1, [toolDescriptor(name: "StaleSiblingOnlyTool")])]
        )

        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_process_route_unavailable"
        )

        #expect(manager.cachedToolsListResult() == nil)
        #expect(manager.debugSnapshot().processToolCatalogs.isEmpty)
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == nil)
    }

    @Test func sessionManagerToolsListResyncsRemainingCatalogWhenProcessRouteUnavailable()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let badTarget = xcodeProcessTarget(processID: 80432, xcodeVersion: "27.0")
        let goodTarget = xcodeProcessTarget(processID: 66336, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: badTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: goodTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (badTarget, 0, [toolDescriptor(name: "BadOnlyTool")]),
                (goodTarget, 1, [toolDescriptor(name: "GoodOnlyTool")]),
            ]
        )
        #expect(manager.cachedToolsListResult() != nil)

        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_process_route_unavailable"
        )

        #expect(manager.processToolCatalogExposedProcessIDs() == Set([goodTarget.processID]))
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["GoodOnlyTool"])
        #expect(
            manager.debugSnapshot().processToolCatalogs.map(\.processID)
                == [goodTarget.processID]
        )
        #expect(manager.processControlPlane.canonicalSourceUpstream() == 1)
    }

    @Test func sessionManagerToolsListResyncsRemainingCatalogWhenProcessRouteRetires()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let retiredUpstream = TestUpstreamClient()
        let remainingUpstream = TestUpstreamClient()
        let retiredTarget = xcodeProcessTarget(processID: 80433, xcodeVersion: "27.0")
        let remainingTarget = xcodeProcessTarget(processID: 66337, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [retiredUpstream, remainingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: retiredTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: remainingTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (retiredTarget, 0, [toolDescriptor(name: "RetiredOnlyTool")]),
                (remainingTarget, 1, [toolDescriptor(name: "RemainingOnlyTool")]),
            ]
        )
        #expect(manager.cachedToolsListResult() != nil)

        manager.reconcileXcodeProcessTargets(
            [remainingTarget],
            reason: "test_process_route_retired"
        )
        #expect(try await retiredUpstream.nextStopCount() == 1)

        #expect(
            toolNames(in: manager.cachedToolsListResult() ?? .null) == [
                "RemainingOnlyTool"
            ])
        #expect(
            manager.debugSnapshot().processToolCatalogs.map(\.processID)
                == [remainingTarget.processID]
        )
        #expect(manager.processControlPlane.canonicalSourceUpstream() == 1)
        let result = try await manager.sharedToolsList(
            sessionID: "session-process-catalog-after-retire",
            requestTimeoutOverride: .seconds(5)
        )
        #expect(toolNames(in: result) == ["RemainingOnlyTool"])
        #expect(await remainingUpstream.sentCount() == 0)
    }

    @Test func sessionManagerRetiringCatalogedProcessRoutePublishesToolsListChangedOnce()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 80445, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let sessionID = "session-process-catalog-retire-notification-count"
        let session = manager.session(id: sessionID)
        manager.sessionRegistry.markInitialized(
            id: sessionID,
            negotiatedProtocolVersion: MCP.ProtocolVersion.current
        )
        _ = session.router.drainBufferedNotifications()
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [toolDescriptor(name: "RetiredOnlyTool")])
            ]
        )
        _ = session.router.drainBufferedNotifications()
        let exposureBeforeRetire = manager.processControlPlane.currentExposureEpoch()
        let catalogEpochBeforeRetire = manager.processControlPlane.currentCatalogEpoch()

        manager.reconcileXcodeProcessTargets(
            [],
            reason: "test_cataloged_process_route_retired_once"
        )
        #expect(try await upstream.nextStopCount() == 1)

        let notificationMethods = session.router.drainBufferedNotifications().compactMap {
            methodName(from: $0)
        }
        #expect(notificationMethods == ["notifications/tools/list_changed"])
        #expect(manager.processControlPlane.currentExposureEpoch() != exposureBeforeRetire)
        #expect(manager.processControlPlane.currentCatalogEpoch() == catalogEpochBeforeRetire)
        #expect(manager.cachedToolsListResult() == nil)
        #expect(manager.debugSnapshot().processToolCatalogs.isEmpty)
    }

    @Test func sessionManagerRouteUnavailableAfterUpstreamClearDoesNotRepublishToolsListChanged()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 80446, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let sessionID = "session-process-catalog-duplicate-unavailable-after-clear"
        let session = manager.session(id: sessionID)
        manager.sessionRegistry.markInitialized(
            id: sessionID,
            negotiatedProtocolVersion: MCP.ProtocolVersion.current
        )
        _ = session.router.drainBufferedNotifications()
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [toolDescriptor(name: "ClearedOnlyTool")])
            ]
        )
        _ = session.router.drainBufferedNotifications()
        let exposureBeforeClear = manager.processControlPlane.currentExposureEpoch()
        let catalogEpochBeforeClear = manager.processControlPlane.currentCatalogEpoch()

        #expect(manager.clearUpstreamState(upstreamIndex: 0))
        let exposureAfterClear = manager.processControlPlane.currentExposureEpoch()
        let notificationsAfterClear = session.router.drainBufferedNotifications().compactMap {
            methodName(from: $0)
        }
        #expect(notificationsAfterClear == ["notifications/tools/list_changed"])
        #expect(exposureAfterClear != exposureBeforeClear)
        #expect(manager.processControlPlane.currentCatalogEpoch() == catalogEpochBeforeClear)
        #expect(manager.cachedToolsListResult() == nil)

        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_duplicate_unavailable_after_clear"
        )

        #expect(session.router.drainBufferedNotifications().isEmpty)
        #expect(manager.cachedToolsListResult() == nil)
    }

    @Test func sessionManagerMarkingSameProcessRouteUnavailableTwiceDoesNotRepublishToolsListChanged()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 80447, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let sessionID = "session-process-catalog-duplicate-unavailable"
        let session = manager.session(id: sessionID)
        manager.sessionRegistry.markInitialized(
            id: sessionID,
            negotiatedProtocolVersion: MCP.ProtocolVersion.current
        )
        _ = session.router.drainBufferedNotifications()
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [toolDescriptor(name: "UnavailableOnlyTool")])
            ]
        )
        _ = session.router.drainBufferedNotifications()
        let exposureBeforeUnavailable = manager.processControlPlane.currentExposureEpoch()
        let catalogEpochBeforeUnavailable = manager.processControlPlane.currentCatalogEpoch()

        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_first_unavailable"
        )
        let exposureAfterUnavailable = manager.processControlPlane.currentExposureEpoch()
        let notificationsAfterUnavailable =
            session.router.drainBufferedNotifications().compactMap {
                methodName(from: $0)
            }
        #expect(notificationsAfterUnavailable == ["notifications/tools/list_changed"])
        #expect(exposureAfterUnavailable != exposureBeforeUnavailable)
        #expect(manager.processControlPlane.currentCatalogEpoch() == catalogEpochBeforeUnavailable)
        #expect(manager.cachedToolsListResult() == nil)

        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_second_unavailable"
        )

        #expect(session.router.drainBufferedNotifications().isEmpty)
        #expect(manager.cachedToolsListResult() == nil)
    }

    @Test func shutdownRejectsWarmInitializeAndRouteActivationRegeneration() async {
        let target = xcodeProcessTarget(processID: 80448, xcodeVersion: "27.0")
        let upstream = TestUpstreamClient()
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let route = XcodeProcessRoute(target: target, upstreamIndices: [0])
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 5),
            upstreams: [upstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [route],
            processRoutingEnabled: true,
            startImmediately: false
        )
        let manager = fixture.manager

        await manager.shutdown()
        let scheduledTimeoutCount = timeoutScheduler.scheduledCount()

        manager.startUpstreamWarmInitialize(upstreamIndex: 0)
        manager.startProcessRouteActivation(for: route)

        #expect(await upstream.sentCount() == 0)
        #expect(timeoutScheduler.scheduledCount() == scheduledTimeoutCount)
        #expect(manager.testStateSnapshot().upstream(id: 0) == nil)
        #expect(manager.processControlPlane.attemptSnapshot(processID: target.processID) == nil)
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
            admission: nil,
            requestSendCompletion: requestSendCompletion,
            onRejected: {
                rejected.withLockedValue { $0 = true }
            }
        )

        #expect(scheduled == false)
        #expect(rejected.withLockedValue { $0 })
        #expect(await requestSendCompletion.wait() == .notSent)
        await manager.drainRuntimeTasksForTesting()
        #expect(await upstream.sentCount() == 0)
    }

    @Test func processReconcileCannotAppendTopologyAfterInitializeShutdownBegins() async {
        let upstream = TestUpstreamClient()
        let lateUpstream = TestUpstreamClient()
        let factoryCallCount = NIOLockedValueBox(0)
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 5),
            upstreams: [upstream],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                factoryCallCount.withLockedValue { $0 += 1 }
                return [lateUpstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        let target = xcodeProcessTarget(processID: 80449, xcodeVersion: "27.0")

        _ = manager.initializeManager.beginShutdown()
        manager.reconcileXcodeProcessTargets(
            [target],
            reason: "test_shutdown_append_gate"
        )

        #expect(factoryCallCount.withLockedValue { $0 } == 0)
        #expect(manager.processControlPlane.activeRoutes().isEmpty)
        #expect(manager.upstreamTopology.snapshot().entries.count == 1)
        #expect(await lateUpstream.startCount() == 0)
        #expect(await lateUpstream.stopCount() == 0)
    }

    @Test func shutdownAndRouteRetirementStopEachSlotExactlyOnce() async throws {
        let target = xcodeProcessTarget(processID: 80450, xcodeVersion: "27.0")
        let upstream = TestUpstreamClient()
        let retirementReachedDetach = TestSignal()
        let allowRetirementDetach = DispatchSemaphore(value: 0)
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 5),
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            processRoutingEnabled: true,
            testHooks: RuntimeCoordinatorTestHooks(
                processRouteRetirementWillDetach: {
                    retirementReachedDetach.signal()
                    allowRetirementDetach.wait()
                }
            ),
            startImmediately: false
        )
        let manager = fixture.manager
        await upstream.blockStop()
        defer {
            allowRetirementDetach.signal()
            Task {
                await upstream.releaseBlockedStop()
            }
            fixture.shutdownAndWait()
        }

        let retirement = Task {
            manager.reconcileXcodeProcessTargets(
                [],
                reason: "test_shutdown_retirement_arbitration"
            )
        }
        try await retirementReachedDetach.wait(
            description: "waiting for route retirement before topology detach"
        )

        let shutdown = Task {
            await manager.shutdown()
        }
        try await upstream.waitForBlockedStop()
        allowRetirementDetach.signal()
        await upstream.releaseBlockedStop()
        await retirement.value
        await shutdown.value

        #expect(await upstream.stopCount() == 1)
        #expect(manager.upstreamTopology.snapshot().entries.isEmpty)
    }

}
