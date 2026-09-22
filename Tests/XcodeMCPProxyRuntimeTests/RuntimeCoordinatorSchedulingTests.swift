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
struct RuntimeCoordinatorSchedulingTests {
    @Test func sessionManagerQueuedPreferredRequestDoesNotBlockLaterGenericDispatch()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeUpstreamIndex = try await occupyUpstreamSlot(
            on: manager,
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            eventLoop: eventLoop,
            completionPromise: activePromise
        )
        #expect(activeUpstreamIndex == 0)

        let preferredDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-preferred",
            label: "tools/call:XcodeListWindows",
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let preferredLeaseID = manager.createRequestLease(descriptor: preferredDescriptor)
        let preferredStartedUpstream = NIOLockedValueBox<Int?>(nil)
        let preferredFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: preferredLeaseID,
            descriptor: preferredDescriptor,
            on: eventLoop,
            preferredUpstreamIndex: 0
        ) { selectedUpstreamIndex in
            preferredStartedUpstream.withLockedValue { $0 = selectedUpstreamIndex.upstreamIndex }
            return eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        let genericDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-generic",
            label: "tools/call:ExecuteSnippet",
            expectsResponse: true,
            isTopLevelClientRequest: true
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
        #expect(genericStartedUpstream.withLockedValue { $0 } == 1)
        #expect(preferredStartedUpstream.withLockedValue { $0 } == nil)
        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        manager.completeRequestLease(activeLeaseID)
        activePromise.succeed(())
        _ = try await preferredFuture.get()
        #expect(preferredStartedUpstream.withLockedValue { $0 } == 0)
    }

    @Test func sessionManagerPreferredRequestFailsWhenAllPreferredUpstreamsUnusable()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let uptimeClock = TestUptimeClock(nowUptimeNanoseconds: 20_000_000_000)
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            nowUptimeNanoseconds: { uptimeClock.now() },
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        _ = manager.upstreamHealthManager.markRequestTimedOut(
            upstreamIndex: 0,
            nowUptimeNs: uptimeClock.now()
        )
        _ = manager.upstreamHealthManager.markRequestTimedOut(
            upstreamIndex: 0,
            nowUptimeNs: uptimeClock.now()
        )
        _ = manager.upstreamHealthManager.markRequestTimedOut(
            upstreamIndex: 0,
            nowUptimeNs: uptimeClock.now()
        )

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-preferred-unusable",
            label: "tools/call:BuildProject",
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let startedUpstream = NIOLockedValueBox<Int?>(nil)
        let future: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop,
            preferredUpstreamIndices: [0]
        ) { selectedUpstreamIndex in
            startedUpstream.withLockedValue { $0 = selectedUpstreamIndex.upstreamIndex }
            return eventLoop.makeSucceededFuture(())
        }

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            try await future.get()
        }
        #expect(startedUpstream.withLockedValue { $0 } == nil)
        #expect(manager.debugSnapshot().queuedRequestCount == 0)
    }

    @Test func sessionManagerRepinsAfterUpstreamExit() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let initializedUpstreams = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) },
                upstreamInitialized: { initializedUpstreams.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)
        try await waitForInitializedUpstreams(initializedUpstreams, expected: [0, 1])

        // Pin two sessions to different upstreams.
        let sessionIDA = "session-A"
        let sessionIDB = "session-B"
        _ = manager.session(id: sessionIDA)
        _ = manager.session(id: sessionIDB)

        let upstreamIndexA = try #require(
            manager.chooseUpstreamIndex())
        let upstreamIndexB = try #require(
            manager.chooseUpstreamIndex())
        #expect(upstreamIndexA != upstreamIndexB)

        let exitEventIndex = upstreamEvents.count()
        await upstream1.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: exitEventIndex,
            description: "waiting for secondary upstream exit"
        )
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == false)

        let repinned = try #require(
            manager.chooseUpstreamIndex())
        #expect(repinned == 0)
    }

    @Test func sessionManagerRepinsWhenPinnedUpstreamIsQuarantinedByTimeouts() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let initializedUpstreams = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamInitialized: { initializedUpstreams.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)
        try await waitForInitializedUpstreams(initializedUpstreams, expected: [0, 1])

        let sessionID = "session-timeout-repin"
        _ = manager.session(id: sessionID)
        let pinned = try #require(
            manager.chooseUpstreamIndex())

        manager.onRequestTimeout(
            sessionID: sessionID, requestIDKey: "dummy-1", upstreamIndex: pinned)
        manager.onRequestTimeout(
            sessionID: sessionID, requestIDKey: "dummy-2", upstreamIndex: pinned)
        manager.onRequestTimeout(
            sessionID: sessionID, requestIDKey: "dummy-3", upstreamIndex: pinned)

        let repinned = try #require(
            manager.chooseUpstreamIndex())
        #expect(repinned != pinned)
    }

    @Test func sessionManagerExitClearsMappingsAndKeepsServingOnOtherUpstreams() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let timeoutEventLoop = NIOAsyncTestingEventLoop()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let initializedUpstreams = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) },
                upstreamInitialized: { initializedUpstreams.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        await upstream0.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: init0[0]))))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        await upstream1.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: init1[0]))))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)
        try await waitForInitializedUpstreams(initializedUpstreams, expected: [0, 1])

        let sessionID = "session-1"
        let session = manager.session(id: sessionID)

        // Send a request to upstream1, then kill upstream1 before it can respond.
        let originalA = JSONRPC.ID(any: NSNumber(value: 200))!
        let futureA = session.router.registerRequest(idKey: originalA.key, on: timeoutEventLoop)
        let upstreamIDA = manager.assignUpstreamID(
            sessionID: sessionID, originalID: originalA, upstreamIndex: 1)
        manager.sendUpstream(try makeToolListRequest(id: upstreamIDA), upstreamIndex: 1)

        let exitEventIndex = upstreamEvents.count()
        await upstream1.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: exitEventIndex,
            description: "waiting for secondary upstream exit"
        )
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == false)

        // The proxy should continue serving on upstream0.
        let originalB = JSONRPC.ID(any: NSNumber(value: 201))!
        let futureB = session.router.registerRequest(idKey: originalB.key, on: eventLoop)
        let upstreamIndexB = try #require(
            manager.chooseUpstreamIndex())
        #expect(upstreamIndexB == 0)
        let upstreamIDB = manager.assignUpstreamID(
            sessionID: sessionID, originalID: originalB, upstreamIndex: upstreamIndexB)
        manager.sendUpstream(
            try makeToolListRequest(id: upstreamIDB), upstreamIndex: upstreamIndexB)
        try await waitForSentCount(upstream0, count: 3, timeoutSeconds: 2)
        let responseEventIndex = upstreamEvents.count()
        await upstream0.yield(.message(try makeToolListResponse(id: upstreamIDB)))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: responseEventIndex,
            description: "waiting for surviving upstream response"
        )
        _ = try await waitWithTimeout(
            "waiting for request routed to surviving upstream",
            timeout: .seconds(2)
        ) {
            try await futureB.get()
        }

        // A should time out (mapping is cleared on exit, and no response arrives).
        await timeoutEventLoop.advanceTime(by: .seconds(5))
        try await waitWithTimeout(
            "waiting for exited upstream request timeout",
            timeout: .seconds(2)
        ) {
            await #expect(throws: TimeoutError.self) {
                try await futureA.get()
            }
        }
    }

    @Test func sessionManagerReturnsOverloadedErrorWhenUpstreamRejectsSend() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = AlwaysOverloadedUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        let sessionID = "session-overloaded"
        let session = manager.session(id: sessionID)
        let original = JSONRPC.ID(any: NSNumber(value: 910))!
        let future = session.router.registerRequest(
            idKey: original.key, on: eventLoop, timeout: .seconds(5))
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID, originalID: original, upstreamIndex: 0)
        manager.sendUpstream(try makeToolListRequest(id: upstreamID), upstreamIndex: 0)

        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "overloaded upstream should fail request immediately",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        let error = response["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32002)
        #expect((error?["message"] as? String) == "upstream overloaded")

        let snapshot = manager.debugSnapshot()
        #expect(snapshot.recentTraffic.contains { $0.direction == "outbound" } == false)
    }

    @Test func sessionManagerInitializeReturnsOverloadedErrorWhenUpstreamRejectsSend() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = AlwaysOverloadedUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let original = JSONRPC.ID(any: NSNumber(value: 1001))!
        let future = manager.registerInitialize(
            originalID: original,
            requestObject: makeInitializeRequest(id: 1001),
            on: eventLoop
        )

        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "initialize should surface overloaded upstream error",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        let error = response["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32002)
        #expect((error?["message"] as? String) == "upstream overloaded")
    }

    @Test func sessionManagerRepinsWhenPinnedUpstreamBecomesOverloaded() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let initializedUpstreams = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamInitialized: { initializedUpstreams.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)
        try await waitForInitializedUpstreams(initializedUpstreams, expected: [0, 1])

        let sessionID = "session-overload-repin"
        let session = manager.session(id: sessionID)
        let pinned = try #require(
            manager.chooseUpstreamIndex())
        #expect(pinned == 0)

        await upstream0.setOverloaded(true)

        let original = JSONRPC.ID(any: NSNumber(value: 920))!
        let future = session.router.registerRequest(
            idKey: original.key, on: eventLoop, timeout: .seconds(5))
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID, originalID: original, upstreamIndex: pinned)
        manager.sendUpstream(try makeToolListRequest(id: upstreamID), upstreamIndex: pinned)

        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "overloaded pinned upstream should fail request immediately",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        let error = response["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32002)
        #expect((error?["message"] as? String) == "upstream overloaded")

        let repinned = try #require(
            manager.chooseUpstreamIndex())
        #expect(repinned == 1)

        let original2 = JSONRPC.ID(any: NSNumber(value: 921))!
        let future2 = session.router.registerRequest(
            idKey: original2.key, on: eventLoop, timeout: .seconds(5))
        let upstreamID2 = manager.assignUpstreamID(
            sessionID: sessionID, originalID: original2, upstreamIndex: repinned)
        manager.sendUpstream(try makeToolListRequest(id: upstreamID2), upstreamIndex: repinned)
        await upstream1.yield(.message(try makeToolListResponse(id: upstreamID2)))
        _ = try await waitWithTimeout(
            "repinned upstream should return response",
            timeout: .seconds(2)
        ) {
            try await future2.get()
        }
    }

    @Test func sessionManagerReplacesStaticUpstreamWhenInitializedNotificationSendOverloads()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let replacements = NIOLockedValueBox<[TestUpstreamClient]>([])
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            unboundUpstreamFactory: {
                let replacement = TestUpstreamClient()
                replacements.withLockedValue { $0.append(replacement) }
                return replacement
            }
        )
        defer { manager.shutdownAndWait() }
        await upstream.blockStop()
        defer {
            Task {
                await upstream.releaseBlockedStop()
            }
        }

        let initialInitialize = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)
        await upstream.blockNextSend(method: "notifications/initialized")
        await upstream.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await upstream.waitForBlockedSend()
        await upstream.releaseBlockedSend(.backpressure)
        try await upstream.waitForBlockedStop()
        let replacement = try await waitWithTimeout(
            "waiting for static initialized-notification replacement"
        ) {
            while true {
                if let replacement = replacements.withLockedValue({ $0.first }) {
                    return replacement
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(await replacement.startCount() == 0)
        #expect(await replacement.sentCount() == 0)

        await upstream.releaseBlockedStop()
        #expect(try await upstream.nextStopCount(timeout: .seconds(2)) == 1)
        let replacementInitialize = try await sentValue(
            from: replacement,
            at: 0,
            timeout: .seconds(2)
        )
        await replacement.yield(
            .message(
                try makeInitializeResponse(
                    id: extractUpstreamID(from: replacementInitialize),
                    serverName: "static-notification-replacement"
                )
            )
        )
        _ = try await replacement.nextSent(
            startingAt: 1,
            matching: { methodName(from: $0) == "notifications/initialized" }
        )
        await manager.drainRuntimeTasksForTesting()
        #expect(await upstream.sentCount() == 2)
        #expect(manager.testStateSnapshot().upstream(id: 0)?.isInitialized == true)
        #expect(manager.testStateSnapshot().hasInitResult)
    }

    @Test func sessionManagerPrimaryInitializedNotificationOverloadClearsSecondaryStateAndToolsCache()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let cachedToolsList = try #require(JSONValue(any: ["tools": []]))
        manager.seedCanonicalToolsCatalog(cachedToolsList, sourceUpstream: 0)

        let initialInitialize = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)
        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        await manager.drainRuntimeTasksForTesting()
        #expect(manager.cachedToolsListResult() == nil)
        #expect(manager.testStateSnapshot().upstream(id: 0)?.isInitialized == nil)
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == false)
        #expect(await upstream1.sentCount() == 0)
    }

    @Test func sessionManagerPrimaryWarmReinitOverloadKeepsHealthySecondaryAvailable() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let cachedToolsList = try #require(JSONValue(any: ["tools": []]))
        manager.seedCanonicalToolsCatalog(cachedToolsList, sourceUpstream: 0)

        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))

        await upstream0.yield(.exit(1))
        let warmRetry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let warmRetryID = try extractUpstreamID(from: warmRetry)

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(.message(try makeInitializeResponse(id: warmRetryID)))

        try await waitForSentCount(upstream0, count: 4, timeoutSeconds: 2)
        let overloadedInitialized = try await sentValue(from: upstream0, at: 3, timeout: .seconds(2))
        #expect(methodName(from: overloadedInitialized) == "notifications/initialized")
        await manager.drainRuntimeTasksForTesting()
        #expect(manager.cachedToolsListResult() == nil)
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == true)
        let chosen = manager.chooseUpstreamIndex()
        #expect(chosen == 1)

        let freshCatalogTask = Task {
            try await manager.sharedToolsList(
                sessionID: "session-warm-reinit-survivor-catalog",
                requestTimeoutOverride: .seconds(5)
            )
        }
        let freshToolsList = try await sentValue(
            from: upstream1,
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2),
            description: "waiting for fresh catalog from surviving secondary"
        )
        await upstream1.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: freshToolsList),
                    tools: []
                ))
        )
        _ = try await waitWithTimeout("waiting for fresh catalog result") {
            try await freshCatalogTask.value
        }
        #expect(manager.cachedToolsListResult() != nil)
    }

    @Test func sessionManagerConcurrentWarmSecondarySatisfiesPendingAfterPrimaryNotificationOverload()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        manager.startUpstreamWarmInitialize(upstreamIndex: 1)
        let primaryInitialize = try await sentValue(
            from: upstream0,
            at: 0,
            timeout: .seconds(2)
        )
        let secondaryInitialize = try await sentValue(
            from: upstream1,
            at: 0,
            timeout: .seconds(2)
        )
        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 77))!,
            requestObject: makeInitializeRequest(id: 77),
            on: eventLoop
        )

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: primaryInitialize),
                    serverName: "failed-primary"
                ))
        )
        await upstream1.yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: secondaryInitialize),
                    serverName: "surviving-secondary"
                ))
        )

        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "concurrent secondary should satisfy pending initialize",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        #expect(response["result"] != nil)
        let result = try #require(response["result"] as? [String: Any])
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "surviving-secondary")

        await manager.drainRuntimeTasksForTesting()
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == true)
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 1)
    }

    @Test func sessionManagerPrimaryWarmReinitDoesNotUseQuarantinedSecondaryAsSupporter()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let cachedToolsList = try #require(JSONValue(any: ["tools": []]))
        manager.seedCanonicalToolsCatalog(cachedToolsList, sourceUpstream: 0)

        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))

        let secondaryLease = manager.operationLeaseForTest(upstreamIndex: 1)
        manager.markRequestTimedOut(secondaryLease)
        manager.markRequestTimedOut(secondaryLease)
        manager.markRequestTimedOut(secondaryLease)

        guard let upstream = manager.testStateSnapshot().upstream(id: 1),
            case .quarantined = upstream.healthState
        else {
            Issue.record("expected upstream1 to be quarantined")
            return
        }
        #expect(
            manager.canonicalHandshakeState.snapshot().supporterProofs.contains(
                secondaryLease.proof
            ) == false
        )

        await upstream0.yield(.exit(1))
        let warmRetry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let warmRetryID = try extractUpstreamID(from: warmRetry)

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(.message(try makeInitializeResponse(id: warmRetryID)))

        try await waitForSentCount(upstream0, count: 4, timeoutSeconds: 2)
        await manager.drainRuntimeTasksForTesting()
        #expect(await upstream0.sentCount() == 4)
        #expect(manager.testStateSnapshot().upstream(id: 0)?.isInitialized == nil)
        #expect(manager.cachedToolsListResult() == nil)
        #expect(manager.canonicalHandshakeState.initializeResult() == nil)
        #expect(manager.hasUsableInitializedSecondaryUpstreams(excluding: 0) == false)
    }

    @Test func sessionManagerIgnoresStaleSecondaryInitializedNotificationAfterReset()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = BlockingInitializedNotificationUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream1.blockNextInitializedNotification()
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))
        try await upstream1.waitForBlockedInitializedNotification()

        #expect(manager.testStateSnapshot().upstream(id: 1)?.initInFlight == true)
        manager.clearUpstreamState(upstreamIndex: 1)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)

        await upstream1.releaseBlockedInitializedNotification(.accepted)
        await manager.drainRuntimeTasksForTesting()

        let snapshot = try #require(manager.testStateSnapshot().upstream(id: 1))
        #expect(snapshot.isInitialized == false)
        guard case .quarantined = snapshot.healthState else {
            Issue.record("expected upstream to remain quarantined")
            return
        }
    }

    @Test func sessionManagerShutdownStopsUpstreamsBeforeDrainingRuntimeTasks() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1StopStarted = TestSignal()
        let upstream1 = BlockingInitializedNotificationUpstreamClient(stopStarted: upstream1StopStarted)
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )

        var didShutdown = false
        defer {
            if !didShutdown {
                manager.shutdownAndWait()
            }
        }

        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream1.blockNextInitializedNotification()
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))
        try await upstream1.waitForBlockedInitializedNotification()

        let shutdownFinished = TestSignal()
        let shutdownTask = Task {
            await manager.shutdown()
            shutdownFinished.signal()
        }

        do {
            try await upstream1StopStarted.wait(
                description: "shutdown should stop upstreams before draining blocked runtime tasks"
            )
            try await shutdownFinished.wait(description: "waiting for runtime shutdown")
        } catch {
            await upstream1.releaseBlockedInitializedNotification(.backpressure)
            await shutdownTask.value
            throw error
        }
        await shutdownTask.value
        didShutdown = true
    }

    @Test func upstreamHealthManagerIgnoresStaleInitializeCompletionAfterStateReset() {
        let topology = UpstreamTopologyAuthority([TestUpstreamClient()])
        let manager = UpstreamHealthManager()
        manager.applyTopology(topology.snapshot())
        manager.markInitInFlight(upstreamIndex: 0, upstreamID: 10)
        guard let _ = manager.clearUpstreamState(upstreamIndex: 0) else {
            Issue.record("expected initial reset to clear the active initialize attempt")
            return
        }

        if let _ = manager.markInitialized(upstreamIndex: 0, expectedUpstreamID: 10) {
            Issue.record("expected stale initialize completion to be ignored")
        }
        if let _ = manager.clearUpstreamState(upstreamIndex: 0, expectedUpstreamID: 10) {
            Issue.record("expected stale initialized notification rejection to be ignored")
        }
        guard let snapshot = manager.state(for: UpstreamSlotID(rawValue: 0)) else {
            Issue.record("expected active upstream health state")
            return
        }
        #expect(snapshot.isInitialized == false)
        #expect(snapshot.initInFlight == false)
    }

    @Test func upstreamHealthManagerRejectsStaleProbeGenerationAndTopologyProof() throws {
        let topology = UpstreamTopologyAuthority([TestUpstreamClient()])
        let manager = UpstreamHealthManager()
        manager.applyTopology(topology.snapshot())
        let originalProof = try #require(
            topology.operationLease(for: UpstreamSlotID(rawValue: 0))?.proof
        )
        _ = try #require(manager.markInitialized(originalProof))
        _ = manager.markRequestTimedOut(originalProof, nowUptimeNs: 0)
        _ = manager.markRequestTimedOut(originalProof, nowUptimeNs: 0)
        _ = manager.markRequestTimedOut(originalProof, nowUptimeNs: 0)
        let evaluation = manager.evaluateUsableInitialized(
            index: 0,
            nowUptimeNs: 16_000_000_000
        )
        let probes: [UpstreamHealthManager.ProbeRequest] = evaluation.effects.compactMap { effect in
            guard case .startHealthProbe(let probe) = effect else { return nil }
            return probe
        }
        let staleGenerationProbe = try #require(probes.first)

        _ = manager.markRequestTimedOut(originalProof, nowUptimeNs: 16_000_000_000)
        #expect(
            manager.finishHealthProbe(
                staleGenerationProbe,
                success: true,
                nowUptimeNs: 16_000_000_000
            ) == false
        )
        guard let stillQuarantined = manager.state(for: UpstreamSlotID(rawValue: 0)),
            case .quarantined = stillQuarantined.healthState
        else {
            Issue.record("stale probe generation restored health")
            return
        }

        let replacement = try #require(
            topology.replace(originalProof, with: TestUpstreamClient())
        )
        manager.applyTopology(replacement.snapshot)
        let replacementProof = try #require(
            topology.operationLease(for: UpstreamSlotID(rawValue: 0))?.proof
        )
        _ = try #require(manager.markInitialized(replacementProof))
        #expect(
            manager.finishHealthProbe(
                staleGenerationProbe,
                success: true,
                nowUptimeNs: 16_000_000_000
            ) == false
        )
        guard let replacementState = manager.state(for: UpstreamSlotID(rawValue: 0)),
            case .healthy = replacementState.healthState
        else {
            Issue.record("stale topology proof mutated replacement health")
            return
        }

        _ = manager.markRequestTimedOut(replacementProof, nowUptimeNs: 0)
        _ = manager.markRequestTimedOut(replacementProof, nowUptimeNs: 0)
        _ = manager.markRequestTimedOut(replacementProof, nowUptimeNs: 0)
        let refreshRaceEvaluation = manager.evaluateUsableInitialized(
            index: 0,
            nowUptimeNs: 16_000_000_000
        )
        let refreshRaceProbes: [UpstreamHealthManager.ProbeRequest] =
            refreshRaceEvaluation.effects.compactMap { effect in
                guard case .startHealthProbe(let probe) = effect else { return nil }
                return probe
            }
        let refreshRaceProbe = try #require(refreshRaceProbes.first)
        #expect(
            manager.markToolsListRefreshSucceeded(
                replacementProof,
                nowUptimeNs: 16_000_000_000
            )
        )
        #expect(
            manager.finishHealthProbe(
                refreshRaceProbe,
                success: false,
                nowUptimeNs: 16_000_000_000
            ) == false
        )

        _ = manager.markRequestTimedOut(replacementProof, nowUptimeNs: 16_000_000_000)
        _ = manager.markRequestTimedOut(replacementProof, nowUptimeNs: 16_000_000_000)
        _ = manager.markRequestTimedOut(replacementProof, nowUptimeNs: 16_000_000_000)
        let duplicateEvaluation = manager.evaluateUsableInitialized(
            index: 0,
            nowUptimeNs: 32_000_000_000
        )
        let duplicateProbes: [UpstreamHealthManager.ProbeRequest] =
            duplicateEvaluation.effects.compactMap { effect in
                guard case .startHealthProbe(let probe) = effect else { return nil }
                return probe
            }
        let duplicateProbe = try #require(duplicateProbes.first)
        #expect(
            manager.finishHealthProbe(
                duplicateProbe,
                success: false,
                nowUptimeNs: 32_000_000_000
            )
        )
        #expect(
            manager.finishHealthProbe(
                duplicateProbe,
                success: true,
                nowUptimeNs: 32_000_000_000
            ) == false
        )
        guard let duplicateState = manager.state(for: UpstreamSlotID(rawValue: 0)),
            case .quarantined = duplicateState.healthState
        else {
            Issue.record("duplicate probe completion restored health")
            return
        }
    }

    @Test func upstreamHealthManagerRejectsPreResetProbeAfterNewProbeStarts() throws {
        let topology = UpstreamTopologyAuthority([TestUpstreamClient()])
        let manager = UpstreamHealthManager()
        manager.applyTopology(topology.snapshot())
        let proof = try #require(
            topology.operationLease(for: UpstreamSlotID(rawValue: 0))?.proof
        )
        _ = try #require(manager.markInitialized(proof))
        _ = manager.markRequestTimedOut(proof, nowUptimeNs: 0)
        _ = manager.markRequestTimedOut(proof, nowUptimeNs: 0)
        _ = manager.markRequestTimedOut(proof, nowUptimeNs: 0)
        let preResetEvaluation = manager.evaluateUsableInitialized(
            index: 0,
            nowUptimeNs: 16_000_000_000
        )
        let preResetProbes: [UpstreamHealthManager.ProbeRequest] =
            preResetEvaluation.effects.compactMap { effect in
                guard case .startHealthProbe(let probe) = effect else { return nil }
                return probe
            }
        let preResetProbe = try #require(preResetProbes.first)

        _ = manager.resetForDebug()
        _ = try #require(manager.markInitialized(proof))
        _ = manager.markRequestTimedOut(proof, nowUptimeNs: 0)
        _ = manager.markRequestTimedOut(proof, nowUptimeNs: 0)
        _ = manager.markRequestTimedOut(proof, nowUptimeNs: 0)
        let postResetEvaluation = manager.evaluateUsableInitialized(
            index: 0,
            nowUptimeNs: 16_000_000_000
        )
        let postResetProbes: [UpstreamHealthManager.ProbeRequest] =
            postResetEvaluation.effects.compactMap { effect in
                guard case .startHealthProbe(let probe) = effect else { return nil }
                return probe
            }
        let postResetProbe = try #require(postResetProbes.first)

        #expect(preResetProbe.probeGeneration != postResetProbe.probeGeneration)
        #expect(
            manager.finishHealthProbe(
                preResetProbe,
                success: true,
                nowUptimeNs: 16_000_000_000
            ) == false
        )
        #expect(manager.state(for: proof.slotID)?.healthProbeInFlight == true)
        #expect(
            manager.finishHealthProbe(
                postResetProbe,
                success: false,
                nowUptimeNs: 16_000_000_000
            )
        )
    }

    @Test func processRouteInitializeErrorRetriesLocallyAndPreservesWinnerCatalog()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let failingUpstream = TestUpstreamClient()
        let winningUpstream = TestUpstreamClient()
        let replacementUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let failingTarget = xcodeProcessTarget(processID: 27120, xcodeVersion: "27.0")
        let winningTarget = xcodeProcessTarget(processID: 26620, xcodeVersion: "26.6")
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [failingUpstream, winningUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: failingTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: winningTarget, upstreamIndices: [1]),
            ],
            dynamicUpstreamFactory: { target in
                guard target.processID == failingTarget.processID else {
                    return [TestUpstreamClient()]
                }
                let upstream = TestUpstreamClient()
                replacementUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            }
        )
        defer { manager.shutdownAndWait() }

        let failingInitialize = try await sentValue(
            from: failingUpstream,
            at: 0,
            timeout: .seconds(2)
        )
        let winningInitialize = try await sentValue(
            from: winningUpstream,
            at: 0,
            timeout: .seconds(2)
        )
        await winningUpstream.yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: winningInitialize),
                    serverName: "Xcode 26.6"
                ))
        )
        _ = try await sentValue(
            from: winningUpstream,
            startingAt: 1,
            matching: { methodName(from: $0) == "notifications/initialized" },
            timeout: .seconds(2),
            description: "waiting for winner initialized notification"
        )
        let winningTools = try await sentValue(
            from: winningUpstream,
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2),
            description: "waiting for winner tools catalog"
        )
        await winningUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: winningTools),
                    tools: [ownerBoundToolDescriptor(name: "BuildProject")]
                ))
        )
        await manager.drainRuntimeTasksForTesting()
        let winningCatalog = try #require(
            manager.processControlPlane.catalog(forProcessID: winningTarget.processID)
        )

        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: try extractUpstreamID(from: failingInitialize)),
            "error": [
                "code": -1,
                "message": "route-local initialize failure",
            ],
        ]
        await failingUpstream.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: []))
        )

        let replacement = try await waitWithTimeout(
            "waiting for route-local replacement after initialize error"
        ) {
            while true {
                if let upstream = replacementUpstreams.withLockedValue({ $0.first }) {
                    return upstream
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let replacementInitialize = try await sentValue(
            from: replacement,
            startingAt: 0,
            matching: { methodName(from: $0) == "initialize" },
            timeout: .seconds(2),
            description: "waiting for replacement initialize"
        )
        await replacement.yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: replacementInitialize),
                    serverName: "Xcode 27"
                ))
        )
        _ = try await sentValue(
            from: replacement,
            startingAt: 1,
            matching: { methodName(from: $0) == "notifications/initialized" },
            timeout: .seconds(2),
            description: "waiting for replacement initialized notification"
        )
        let replacementTools = try await sentValue(
            from: replacement,
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2),
            description: "waiting for replacement tools catalog"
        )
        await replacement.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: replacementTools),
                    tools: [ownerBoundToolDescriptor(name: "BuildProject")]
                ))
        )
        await manager.drainRuntimeTasksForTesting()

        #expect(
            manager.processControlPlane.catalog(forProcessID: winningTarget.processID)?.rawResult
                == winningCatalog.rawResult
        )
        #expect(
            manager.processControlPlane.catalog(forProcessID: failingTarget.processID) != nil
        )
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 1)
        #expect(
            manager.canonicalHandshakeState.snapshot().supporterProofs
                .map(\.slotID.rawValue).sorted() == [0, 1]
        )
        #expect(
            manager.processControlPlane.attemptSnapshot(
                processID: winningTarget.processID
            )?.phase == .cataloged
        )
        #expect(
            manager.processControlPlane.attemptSnapshot(
                processID: failingTarget.processID
            )?.phase == .cataloged
        )
    }

    @Test func sessionManagerAbandonQueuedRequestFailsPendingFuture() async throws {
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

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        defer { activePromise.fail(CancellationError()) }
        try await occupyUpstreamSlot(
            on: manager,
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            eventLoop: eventLoop,
            completionPromise: activePromise
        )

        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/call:ExecuteSnippet",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let queuedLeaseID = manager.createRequestLease(descriptor: queuedDescriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: queuedDescriptor,
            on: eventLoop
        ) { _ in
            eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        manager.abandonRequestLease(
            queuedLeaseID,
            sessionID: "session-queued",
            requestIDKeys: [],
            upstreamIndex: nil
        )

        await #expect(throws: CancellationError.self) {
            try await queuedFuture.get()
        }

    }

    @Test func sessionManagerAbandonRequestLeaseDropsLateResponseAndReleasesSlot() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-disconnect"
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: sessionID,
            label: "tools/call:ExecuteSnippet",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let originalID = try #require(JSONRPC.ID(any: NSNumber(value: 1)))
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: originalID,
            upstreamIndex: 0
        )

        manager.activateRequestLease(
            leaseID,
            requestIDKey: originalID.key,
            upstreamIndex: 0,
            timeout: .seconds(5)
        )
        manager.abandonRequestLease(
            leaseID,
            sessionID: sessionID,
            requestIDKeys: [originalID.key],
            upstreamIndex: 0
        )
        let cancellation = try await waitWithTimeout(
            "waiting for abandoned request cancellation",
            timeout: .seconds(2)
        ) {
            try await upstream.nextSent(
                startingAt: 0,
                matching: { methodName(from: $0) == "notifications/cancelled" }
            )
        }
        let cancellationObject = try #require(
            JSONSerialization.jsonObject(with: cancellation, options: []) as? [String: Any]
        )
        let cancellationParams = try #require(
            cancellationObject["params"] as? [String: Any]
        )
        #expect((cancellationParams["requestId"] as? NSNumber)?.int64Value == upstreamID)

        let releaseSnapshot = manager.debugSnapshot()
        let releasedLease = try #require(
            releaseSnapshot.leases.first(where: { $0.requestIDKey == originalID.key })
        )
        #expect(releasedLease.releaseReason == "clientDisconnected")
        #expect(releaseSnapshot.upstreams[0].activeCorrelatedRequestCount == 0)

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: upstreamID),
            "result": [String: Any](),
        ]
        manager.routeUpstreamMessage(
            try JSONSerialization.data(withJSONObject: response, options: []),
            upstreamIndex: 0
        )

        let lateSnapshot = manager.debugSnapshot()
        let lateLease = try #require(
            lateSnapshot.leases.first(where: { $0.requestIDKey == originalID.key })
        )
        #expect(lateLease.releaseReason == "clientDisconnected")
    }

    @Test func requestTimeoutKeepsSlotReservedUntilRejectedCancellationRecoversChannel()
        async throws
    {
        try await assertRejectedCancellationRecoversBeforeSlotRelease(.timeout)
    }

    @Test func requestAbandonKeepsSlotReservedUntilRejectedCancellationRecoversChannel()
        async throws
    {
        try await assertRejectedCancellationRecoversBeforeSlotRelease(.abandon)
    }

    @Test func rejectedCancellationReplacesAndReinitializesStaticUpstream() async throws {
        let initial = TestUpstreamClient()
        let replacements = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 300),
            upstreams: [initial],
            processRoutingEnabled: false,
            unboundUpstreamFactory: {
                let replacement = TestUpstreamClient()
                replacements.withLockedValue { $0.append(replacement) }
                return replacement
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        await initial.blockStop()
        defer {
            Task {
                await initial.releaseBlockedStop()
            }
        }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "static-cancellation-source"],
            ]),
            sourceUpstream: 0
        )

        let sessionID = "static-rejected-cancellation"
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: sessionID,
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let activePromise = fixture.eventLoop.makePromise(of: Void.self)
        defer { activePromise.fail(CancellationError()) }
        let requestID = try #require(JSONRPC.ID(any: NSNumber(value: 1)))
        _ = try await occupyUpstreamSlot(
            on: manager,
            leaseID: leaseID,
            descriptor: descriptor,
            eventLoop: fixture.eventLoop,
            completionPromise: activePromise,
            requestIDKey: requestID.key
        )
        let failedLease = manager.operationLeaseForTest(upstreamIndex: 0)
        _ = try #require(manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: requestID,
            operationLease: failedLease
        ))

        let queuedStarts = LockedRecordedValues<UpstreamTopologyProof>()
        let queuedLeaseID = manager.createRequestLease(descriptor: descriptor)
        _ = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: descriptor,
            on: fixture.eventLoop
        ) { selected in
            queuedStarts.append(selected.proof)
            return fixture.eventLoop.makeSucceededFuture(())
        }

        await initial.blockNextCancellation()
        manager.handleRequestLeaseTimeout(
            leaseID,
            sessionID: sessionID,
            requestIDKeys: [requestID.key],
            operationLease: failedLease
        )
        try await initial.waitForBlockedCancellation()
        await initial.releaseBlockedCancellation(.backpressure)

        try await initial.waitForBlockedStop()
        let replacement = try await waitWithTimeout(
            "waiting for static replacement channel"
        ) {
            while true {
                if let replacement = replacements.withLockedValue({ $0.first }) {
                    return replacement
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let replacementProof = try #require(
            manager.upstreamTopology.operationLease(
                for: UpstreamSlotID(rawValue: 0)
            )?.proof
        )
        #expect(replacementProof != failedLease.proof)
        manager.startUpstreamWarmInitialize(
            upstreamIndex: replacementProof.slotID.rawValue,
            applyBackoff: false
        )
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(await replacement.sentCount() == 0)
        #expect(
            manager.upstreamSlotScheduler.debugSnapshot()
                .activeLeaseCountByUpstream[0] == 1
        )
        #expect(queuedStarts.count() == 0)

        await initial.releaseBlockedStop()
        #expect(try await initial.nextStopCount(timeout: .seconds(2)) == 1)
        let initialize = try await replacement.nextSent(
            matching: { methodName(from: $0) == "initialize" }
        )
        await replacement.yield(
            .message(
                try makeInitializeResponse(
                    id: extractUpstreamID(from: initialize),
                    serverName: "static-replacement"
                )
            )
        )
        _ = try await replacement.nextSent(
            startingAt: 1,
            matching: { methodName(from: $0) == "notifications/initialized" }
        )
        let queuedProof = try await waitForRecordedValue(
            queuedStarts,
            at: 0,
            description: "waiting for queued request on static replacement"
        )
        #expect(queuedProof == replacementProof)
    }

    @Test func forwardedRequestTimeoutWaitsForOriginalSendBeforeCancellation() async throws {
        try await assertForwardedCancellationWaitsForOriginalSend(.timeout)
    }

    @Test func forwardedRequestAbandonWaitsForOriginalSendBeforeCancellation() async throws {
        try await assertForwardedCancellationWaitsForOriginalSend(.abandon)
    }

    @Test func forwardedRequestTimeoutDoesNotCancelBackpressuredOriginalSend() async throws {
        try await assertForwardedCancellationSkipsUnsentRequest(.timeout)
    }

    @Test func forwardedRequestAbandonDoesNotCancelBackpressuredOriginalSend() async throws {
        try await assertForwardedCancellationSkipsUnsentRequest(.abandon)
    }

    private enum RejectedCancellationTrigger: Equatable {
        case timeout
        case abandon
    }

    private func assertRejectedCancellationRecoversBeforeSlotRelease(
        _ trigger: RejectedCancellationTrigger
    ) async throws {
        let initial = TestUpstreamClient()
        let replacements = NIOLockedValueBox<[TestUpstreamClient]>([])
        let target = xcodeProcessTarget(processID: 27091, xcodeVersion: "27.0")
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 300),
            upstreams: [initial],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let replacement = TestUpstreamClient()
                replacements.withLockedValue { $0.append(replacement) }
                return [replacement]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "request-cancellation-source"],
            ]),
            sourceUpstream: 0
        )
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [toolDescriptor(name: "DocumentationSearch")])
            ]
        )

        let sessionID = "session-rejected-\(trigger)"
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: sessionID,
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let activePromise = fixture.eventLoop.makePromise(of: Void.self)
        defer { activePromise.fail(CancellationError()) }
        let requestID = try #require(JSONRPC.ID(any: NSNumber(value: 1)))
        _ = try await occupyUpstreamSlot(
            on: manager,
            leaseID: leaseID,
            descriptor: descriptor,
            eventLoop: fixture.eventLoop,
            completionPromise: activePromise,
            requestIDKey: requestID.key
        )
        let operationLease = manager.operationLeaseForTest(upstreamIndex: 0)
        _ = try #require(manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: requestID,
            operationLease: operationLease
        ))

        let queuedStarts = LockedRecordedValues<UpstreamTopologyProof>()
        let queuedLeaseID = manager.createRequestLease(descriptor: descriptor)
        _ = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: descriptor,
            on: fixture.eventLoop
        ) { selected in
            queuedStarts.append(selected.proof)
            return fixture.eventLoop.makeSucceededFuture(())
        }
        #expect(manager.upstreamSlotScheduler.debugSnapshot().queuedRequestCount == 1)

        await initial.blockNextCancellation()
        switch trigger {
        case .timeout:
            manager.handleRequestLeaseTimeout(
                leaseID,
                sessionID: sessionID,
                requestIDKeys: [requestID.key],
                operationLease: operationLease
            )
        case .abandon:
            manager.abandonRequestLease(
                leaseID,
                sessionID: sessionID,
                requestIDKeys: [requestID.key],
                operationLease: operationLease
            )
        }
        try await initial.waitForBlockedCancellation()

        #expect(
            manager.upstreamSlotScheduler.debugSnapshot()
                .activeLeaseCountByUpstream[0] == 1
        )
        #expect(queuedStarts.count() == 0)

        await initial.releaseBlockedCancellation(.backpressure)
        #expect(try await initial.nextStopCount(timeout: .seconds(2)) == 1)
        await manager.drainRuntimeTasksForTesting()

        #expect(queuedStarts.count() == 0)
        #expect(
            manager.upstreamSlotScheduler.debugSnapshot()
                .activeLeaseCountByUpstream.isEmpty
        )
        #expect(replacements.withLockedValue(\.count) == 1)
        #expect(manager.upstreamTopology.validate(operationLease) == false)

        let activationRetryIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .milliseconds(250),
            startingAtEventIndex: 0
        )
        #expect(timeoutScheduler.fire(at: activationRetryIndex))
        let replacement = try #require(replacements.withLockedValue { $0.first })
        _ = try await replacement.nextSent(
            matching: { methodName(from: $0) == "initialize" }
        )
        #expect(queuedStarts.count() == 0)
    }

    private func assertForwardedCancellationWaitsForOriginalSend(
        _ trigger: RejectedCancellationTrigger
    ) async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 300),
            upstreams: [upstream],
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let sessionID = "session-send-barrier-\(trigger)"
        let parentCancellationHandle: ClientMCPRequestExecutor.CancellationHandle?
        switch trigger {
        case .timeout:
            parentCancellationHandle = nil
        case .abandon:
            let parentLeaseID = manager.createRequestLease(
                descriptor: SessionRequestPipeline.Descriptor(
                    sessionID: sessionID,
                    label: "parent",
                    expectsResponse: true,
                    isTopLevelClientRequest: true
                )
            )
            parentCancellationHandle = ClientMCPRequestExecutor.CancellationHandle(
                leaseID: parentLeaseID,
                sessionID: sessionID,
                requestIDKeys: []
            )
        }
        let forwardingService = MCPForwardingService(
            configuration: makeConfig(requestTimeout: 300),
            sessionManager: manager
        )
        await upstream.blockNextSend(method: "tools/call")
        let request = Task {
            let result = await forwardingService.callInternalTool(
                name: "XcodeListNavigatorIssues",
                arguments: ["tabIdentifier": "windowtab-send-barrier"],
                sessionID: sessionID,
                eventLoop: fixture.eventLoop,
                cancellationHandle: parentCancellationHandle,
                upstreamIndexOverride: 0,
                requestTimeoutOverride: trigger == .timeout ? .milliseconds(20) : .seconds(300)
            )
            switch (trigger, result) {
            case (.timeout, .timeout), (.abandon, .cancelled):
                return true
            default:
                return false
            }
        }
        try await upstream.waitForBlockedSend()
        parentCancellationHandle?.cancel(using: manager)
        #expect(try await waitWithTimeout("waiting for forwarded cancellation") {
            await request.value
        })

        let beforeOriginalSendCompletion = await upstream.sent()
        #expect(beforeOriginalSendCompletion.count == 1)
        let originalRequest = try #require(beforeOriginalSendCompletion.first)
        #expect(methodName(from: originalRequest) == "tools/call")
        #expect(
            beforeOriginalSendCompletion.contains {
                methodName(from: $0) == "notifications/cancelled"
            } == false
        )

        await upstream.releaseBlockedSend()
        let cancellation = try await upstream.nextSent(
            matching: { methodName(from: $0) == "notifications/cancelled" }
        )
        #expect(
            try extractCancellationRequestID(from: cancellation)
                == extractUpstreamID(from: originalRequest)
        )
        await manager.drainRuntimeTasksForTesting()
        #expect(
            manager.upstreamSlotScheduler.debugSnapshot()
                .activeLeaseCountByUpstream.isEmpty
        )
    }

    private func assertForwardedCancellationSkipsUnsentRequest(
        _ trigger: RejectedCancellationTrigger
    ) async throws {
        let upstream = TestUpstreamClient()
        let replacements = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 300),
            upstreams: [upstream],
            unboundUpstreamFactory: {
                let replacement = TestUpstreamClient()
                replacements.withLockedValue { $0.append(replacement) }
                return replacement
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let originalLease = manager.operationLeaseForTest(upstreamIndex: 0)
        let sessionID = "session-unsent-cancellation-\(trigger)"
        let parentCancellationHandle: ClientMCPRequestExecutor.CancellationHandle?
        switch trigger {
        case .timeout:
            parentCancellationHandle = nil
        case .abandon:
            let parentLeaseID = manager.createRequestLease(
                descriptor: SessionRequestPipeline.Descriptor(
                    sessionID: sessionID,
                    label: "parent",
                    expectsResponse: true,
                    isTopLevelClientRequest: true
                )
            )
            parentCancellationHandle = ClientMCPRequestExecutor.CancellationHandle(
                leaseID: parentLeaseID,
                sessionID: sessionID,
                requestIDKeys: []
            )
        }
        let forwardingService = MCPForwardingService(
            configuration: makeConfig(requestTimeout: 300),
            sessionManager: manager
        )
        await upstream.blockNextSend(method: "tools/call")
        let request = Task {
            let result = await forwardingService.callInternalTool(
                name: "XcodeListNavigatorIssues",
                arguments: ["tabIdentifier": "windowtab-unsent-cancellation"],
                sessionID: sessionID,
                eventLoop: fixture.eventLoop,
                cancellationHandle: parentCancellationHandle,
                upstreamIndexOverride: 0,
                requestTimeoutOverride: trigger == .timeout
                    ? .milliseconds(20)
                    : .seconds(300)
            )
            switch (trigger, result) {
            case (.timeout, .timeout), (.abandon, .cancelled):
                return true
            default:
                return false
            }
        }
        try await upstream.waitForBlockedSend()
        parentCancellationHandle?.cancel(using: manager)
        let matchedExpectedResult = try await waitWithTimeout(
            "waiting for unsent request cancellation"
        ) {
            await request.value
        }
        #expect(matchedExpectedResult)
        await upstream.releaseBlockedSend(.backpressure)

        await manager.drainRuntimeTasksForTesting()
        let messages = await upstream.sent()
        #expect(messages.count == 1)
        #expect(messages.first.map { methodName(from: $0) } == "tools/call")
        #expect(
            messages.contains {
                methodName(from: $0) == "notifications/cancelled"
            } == false
        )
        #expect(replacements.withLockedValue(\.count) == 0)
        #expect(manager.upstreamTopology.validate(originalLease))
        #expect(
            manager.upstreamSlotScheduler.debugSnapshot()
                .activeLeaseCountByUpstream.isEmpty
        )
    }

    @Test func sessionManagerDoesNotReactivateAbandonedLease() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let leaseID = manager.createRequestLease(
            descriptor: SessionRequestPipeline.Descriptor(
                sessionID: "session-terminal-lease",
                label: "tools/call:DocumentationSearch",
                expectsResponse: true,
                isTopLevelClientRequest: true
            )
        )

        manager.abandonRequestLease(
            leaseID,
            sessionID: "session-terminal-lease",
            requestIDKeys: [],
            upstreamIndex: nil
        )
        manager.activateRequestLease(
            leaseID,
            requestIDKey: "reactivated",
            upstreamIndex: 0,
            timeout: .seconds(5)
        )

        let snapshot = manager.debugSnapshot()
        let lease = try #require(
            snapshot.leases.first(where: { $0.leaseID == leaseID.uuidString })
        )
        #expect(lease.state == .abandoned)
        #expect(lease.releaseReason == "clientDisconnected")
        #expect(snapshot.upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func sessionManagerProtocolViolationReleasesActiveLeaseAndAllowsNextRequest() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-protocol-violation"
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: sessionID,
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let originalID = try #require(JSONRPC.ID(any: NSNumber(value: 41)))
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: originalID,
            upstreamIndex: 0
        )

        manager.activateRequestLease(
            leaseID,
            requestIDKey: originalID.key,
            upstreamIndex: 0,
            timeout: .seconds(5)
        )
        manager.handleUpstreamProtocolViolation(
            StdioFramer.ProtocolViolation(
                reason: .invalidJSON,
                bufferedByteCount: 128,
                preview: "{broken"
            ),
            upstreamIndex: 0
        )

        let releaseSnapshot = manager.debugSnapshot()
        let releasedLease = try #require(
            releaseSnapshot.leases.first(where: { $0.requestIDKey == originalID.key })
        )
        #expect(releasedLease.releaseReason == "stdoutProtocolViolation")
        #expect(releaseSnapshot.upstreams[0].activeCorrelatedRequestCount == 0)

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: upstreamID),
            "result": [String: Any](),
        ]
        manager.routeUpstreamMessage(
            try JSONSerialization.data(withJSONObject: response, options: []),
            upstreamIndex: 0
        )

        let lateSnapshot = manager.debugSnapshot()
        let lateLease = try #require(
            lateSnapshot.leases.first(where: { $0.requestIDKey == originalID.key })
        )
        #expect(lateLease.releaseReason == "stdoutProtocolViolation")

        let nextLeaseID = manager.createRequestLease(descriptor: descriptor)
        let nextOriginalID = try #require(JSONRPC.ID(any: NSNumber(value: 42)))
        let nextUpstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: nextOriginalID,
            upstreamIndex: 0
        )
        manager.activateRequestLease(
            nextLeaseID,
            requestIDKey: nextOriginalID.key,
            upstreamIndex: 0,
            timeout: .seconds(5)
        )
        _ = nextUpstreamID
        manager.completeRequestLease(nextLeaseID)

        let successSnapshot = manager.debugSnapshot()
        let nextLease = try #require(
            successSnapshot.leases.first(where: { $0.requestIDKey == nextOriginalID.key })
        )
        #expect(nextLease.releaseReason == "completed")
        #expect(successSnapshot.upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func sessionManagerProtocolViolationQuarantinesBrokenUpstream() async throws {
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

        manager.handleUpstreamProtocolViolation(
            StdioFramer.ProtocolViolation(
                reason: .invalidJSON,
                bufferedByteCount: 128,
                preview: "{broken"
            ),
            upstreamIndex: 0
        )

        let snapshot = manager.testStateSnapshot()
        let isQuarantined: Bool
        if case .quarantined = snapshot.upstreams[0].healthState {
            isQuarantined = true
        } else {
            isQuarantined = false
        }
        #expect(isQuarantined)
        #expect(manager.chooseUpstreamIndex() == nil)
    }

    @Test func sessionManagerStdoutClosureFailsUnboundedPendingRequests() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 0), eventLoop: eventLoop,
            upstreams: [upstream], startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        let operationLease = manager.operationLeaseForTest(upstreamIndex: 0)
        manager.observeUpstreamEvents(operationLease)
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.seedCanonicalToolsCatalog(try #require(JSONValue(any: ["tools": []])), sourceUpstream: 0)
        let sessionID = "stdout-eof"
        let session = manager.session(id: sessionID)
        let originalID = try #require(JSONRPC.ID(any: NSNumber(value: 1)))
        let pending = session.router.registerRequest(idKey: originalID.key, on: eventLoop)
        let leaseID = manager.createRequestLease(descriptor: .init(
            sessionID: sessionID, label: "tools/call:Pending",
            expectsResponse: true, isTopLevelClientRequest: true
        ))
        manager.activateRequestLease(
            leaseID, requestIDKey: originalID.key, upstreamIndex: 0, timeout: nil
        )
        _ = manager.assignUpstreamID(
            sessionID: sessionID, originalID: originalID, upstreamIndex: 0
        )
        await upstream.yield(.stdoutClosed)
        do {
            _ = try await waitWithTimeout("stdout EOF should fail pending request") {
                try await pending.get()
            }
            Issue.record("pending request survived stdout EOF")
        } catch {
            #expect(error is UpstreamSlotScheduler.AcquisitionError)
        }
        #expect(manager.cachedToolsListResult() == nil)
        let snapshot = manager.debugSnapshot()
        let lease = try #require(snapshot.leases.first { $0.leaseID == leaseID.uuidString })
        #expect(lease.releaseReason == "upstreamUnavailable")
        #expect(snapshot.upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func sessionManagerUpstreamExitClearsCanonicalToolsCatalogImmediately() async throws {
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

        manager.seedCanonicalToolsCatalog(try #require(JSONValue(any: ["tools": []])), sourceUpstream: 0)
        #expect(manager.cachedToolsListResult() != nil)

        manager.handleUpstreamExit(1, upstreamIndex: 0)

        #expect(manager.cachedToolsListResult() == nil)
    }

    @Test func sessionManagerProtocolViolationClearsCanonicalToolsCatalogImmediately()
        async throws
    {
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

        manager.seedCanonicalToolsCatalog(try #require(JSONValue(any: ["tools": []])), sourceUpstream: 0)
        #expect(manager.cachedToolsListResult() != nil)

        manager.handleUpstreamProtocolViolation(
            StdioFramer.ProtocolViolation(
                reason: .invalidJSON,
                bufferedByteCount: 64,
                preview: "{broken"
            ),
            upstreamIndex: 0
        )

        #expect(manager.cachedToolsListResult() == nil)
    }

    @Test func sessionManagerProtocolViolationRestartsWarmInitializeForPrimary() async throws {
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

        manager.handleUpstreamProtocolViolation(
            StdioFramer.ProtocolViolation(
                reason: .invalidJSON,
                bufferedByteCount: 128,
                preview: "{broken"
            ),
            upstreamIndex: 0
        )

        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)

        let restartedInitRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        let object = try #require(
            JSONSerialization.jsonObject(with: restartedInitRequest, options: []) as? [String: Any]
        )
        #expect(object["method"] as? String == "initialize")
    }

    @Test func sessionManagerProtocolViolationFailsQueuedRequestsWhenNoHealthyUpstreamRemains() async throws {
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

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        defer { activePromise.fail(CancellationError()) }
        try await occupyUpstreamSlot(
            on: manager,
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            eventLoop: eventLoop,
            completionPromise: activePromise
        )

        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/call:ExecuteSnippet",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let queuedLeaseID = manager.createRequestLease(descriptor: queuedDescriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: queuedDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                queuedLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex.upstreamIndex,
                timeout: nil
            )
            return eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        manager.handleUpstreamProtocolViolation(
            StdioFramer.ProtocolViolation(
                reason: .invalidJSON,
                bufferedByteCount: 128,
                preview: "{broken"
            ),
            upstreamIndex: 0
        )

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            try await queuedFuture.get()
        }
    }

    @Test func sessionManagerFailsQueuedRequestsWhenHealthProbeRecoveryFails() async throws {
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

        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.chooseUpstreamIndex()

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-probe-failure",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop
        ) { _ in
            eventLoop.makeSucceededFuture(())
        }

        let probeRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        let probeUpstreamID = try extractUpstreamID(from: probeRequest)
        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: probeUpstreamID),
            "error": [
                "code": NSNumber(value: -32000),
                "message": "probe failed",
            ],
        ]
        await upstream.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: []))
        )

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            try await queuedFuture.get()
        }
    }

    @Test func sessionManagerTimeoutQuarantineFailsQueuedRequestsWhenNoHealthyUpstreamRemains()
        async throws
    {
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

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-timeout-active",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        defer { activePromise.fail(CancellationError()) }
        try await occupyUpstreamSlot(
            on: manager,
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            eventLoop: eventLoop,
            completionPromise: activePromise,
            requestIDKey: "active-request"
        )

        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-timeout-queued",
            label: "tools/call:ExecuteSnippet",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let queuedLeaseID = manager.createRequestLease(descriptor: queuedDescriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: queuedDescriptor,
            on: eventLoop
        ) { _ in
            eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        manager.onRequestTimeout(
            sessionID: activeDescriptor.sessionID,
            requestIDKey: "timeout-1",
            upstreamIndex: 0
        )
        manager.onRequestTimeout(
            sessionID: activeDescriptor.sessionID,
            requestIDKey: "timeout-2",
            upstreamIndex: 0
        )
        manager.handleRequestLeaseTimeout(
            activeLeaseID,
            sessionID: activeDescriptor.sessionID,
            requestIDKeys: ["active-request"],
            upstreamIndex: 0
        )

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            try await queuedFuture.get()
        }
        #expect(manager.debugSnapshot().queuedRequestCount == 0)

    }

    @Test func sessionManagerDebugResetClearsSessionsLeasesAndCache() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: group.next(), upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        _ = manager.session(id: "session-debug-reset")
        manager.seedCanonicalToolsCatalog(.object(["tools": .array([])]), sourceUpstream: 0)

        let leaseID = manager.createRequestLease(
            descriptor: SessionRequestPipeline.Descriptor(
                sessionID: "session-debug-reset",
                label: "tools/call:DocumentationSearch",
                expectsResponse: true,
                isTopLevelClientRequest: true
            )
        )
        manager.activateRequestLease(
            leaseID,
            requestIDKey: "123",
            upstreamIndex: 0,
            timeout: .seconds(5)
        )

        manager.debugReset()

        #expect(manager.hasSession(id: "session-debug-reset") == false)
        let snapshot = manager.debugSnapshot()
        #expect(snapshot.cachedToolsListAvailable == false)
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.leases.isEmpty)
    }

    @Test func sessionManagerDebugResetClearsProcessRouteCooldowns() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 523, xcodeVersion: "27.0")
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

        manager.markXcodeProcessRouteUnavailableAfterCatalogFailure(
            upstreamIndex: 0,
            reason: "test_debug_reset"
        )
        #expect(manager.unavailableXcodeProcessIDs().contains(target.processID))

        manager.debugReset()

        #expect(manager.unavailableXcodeProcessIDs().contains(target.processID) == false)
    }

    @Test func sessionManagerDebugResetClearsXcodeWindowOwners() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 522, xcodeVersion: "27.0")
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")])
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                    ]
                ]),
                upstreamIndex: 0
            )
        )
        let request = toolsCallObject(
            id: 1000,
            name: "BuildProject",
            arguments: ["tabIdentifier": "tab-a"]
        )
        #expect(manager.preferredUpstreamIndex(for: request) == 0)

        manager.debugReset()

        #expect(manager.preferredUpstreamIndex(for: request) == nil)
    }

    @Test func sessionManagerDebugResetCancelsQueuedRequests() async throws {
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

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        defer { activePromise.fail(CancellationError()) }
        try await occupyUpstreamSlot(
            on: manager,
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            eventLoop: eventLoop,
            completionPromise: activePromise
        )

        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/call:ExecuteSnippet",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let queuedLeaseID = manager.createRequestLease(descriptor: queuedDescriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: queuedDescriptor,
            on: eventLoop
        ) { _ in
            eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        manager.debugReset()

        await #expect(throws: CancellationError.self) {
            try await queuedFuture.get()
        }

    }

    @Test func requestLeaseRegistryKeepsOnlyBoundedReleasedHistory() async throws {
        let registry = LeaseManager(releasedHistoryLimit: 2)
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-bounded-history",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )

        let lease1 = registry.createLease(descriptor: descriptor)
        registry.activateLease(lease1, requestIDKey: "1", upstreamIndex: 0, timeoutAt: nil)
        _ = registry.completeLease(lease1)

        let lease2 = registry.createLease(descriptor: descriptor)
        registry.activateLease(lease2, requestIDKey: "2", upstreamIndex: 0, timeoutAt: nil)
        _ = registry.failLease(lease2, terminalState: .failed, reason: .upstreamUnavailable)

        let lease3 = registry.createLease(descriptor: descriptor)
        registry.activateLease(lease3, requestIDKey: "3", upstreamIndex: 0, timeoutAt: nil)
        _ = registry.completeLease(lease3)
        _ = registry.completeLease(lease3)

        let snapshots = registry.debugSnapshots()
        #expect(snapshots.count == 2)
        #expect(Set(snapshots.map(\.leaseID)) == Set([lease2.uuidString, lease3.uuidString]))
        let latest = try #require(snapshots.first { $0.leaseID == lease3.uuidString })
        #expect(latest.lateResponseCount == 1)
    }

    @Test func requestLeaseRegistryRequeueLeaseReleasesActiveSlotAndKeepsLeaseQueued()
        async throws
    {
        let registry = LeaseManager()
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-requeue",
            label: "tools/call:XcodeRefreshCodeIssuesInFile",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )

        let lease = registry.createLease(descriptor: descriptor)
        registry.activateLease(
            lease,
            requestIDKey: "refresh-1",
            upstreamIndex: 0,
            timeoutAt: Date().addingTimeInterval(30),
            progressTokenMapping: ProgressTokenMapping(
                clientToken: .string("client-refresh-token"),
                upstreamToken: "proxy-refresh-token"
            )
        )
        #expect(
            registry.activeProgressTarget(
                upstreamIndex: 0,
                upstreamToken: "proxy-refresh-token"
            )?.sessionID == "session-requeue"
        )

        let releaseAction = try #require(registry.requeueLease(lease))
        #expect(releaseAction.leaseID == lease)
        #expect(releaseAction.upstreamIndex == 0)

        let snapshot = try #require(registry.debugSnapshots().first { $0.leaseID == lease.uuidString })
        #expect(snapshot.state == .queued)
        #expect(snapshot.requestIDKey == nil)
        #expect(snapshot.upstreamIndex == nil)
        #expect(snapshot.timeoutAt == nil)
        #expect(snapshot.releaseReason == nil)
        #expect(
            registry.activeProgressTarget(
                upstreamIndex: 0,
                upstreamToken: "proxy-refresh-token"
            ) == nil
        )
    }

    @Test func requestLeaseRegistryAbandonActiveLeasesUsesBoundedReleasedHistory()
        async throws
    {
        let registry = LeaseManager(releasedHistoryLimit: 1)
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-abandon-history",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )

        let abandonedLease = registry.createLease(descriptor: descriptor)
        registry.activateLease(
            abandonedLease,
            requestIDKey: "abandon-1",
            upstreamIndex: 0,
            timeoutAt: nil
        )
        let abandonActions = registry.abandonActiveLeases(
            upstreamIndex: 0,
            reason: .stdoutProtocolViolation
        )
        #expect(abandonActions.count == 1)

        let completedLease = registry.createLease(descriptor: descriptor)
        registry.activateLease(
            completedLease,
            requestIDKey: "complete-1",
            upstreamIndex: 1,
            timeoutAt: nil
        )
        _ = registry.completeLease(completedLease)

        let snapshots = registry.debugSnapshots()
        #expect(snapshots.count == 1)
        let snapshot = try #require(snapshots.first)
        #expect(snapshot.leaseID == completedLease.uuidString)
        #expect(snapshot.state == .completed)
    }

    @Test func upstreamSlotSchedulerCancelsReservedDispatchBeforeStartWithoutLeakingSlot()
        async throws
    {
        let eventLoop = EmbeddedEventLoop()
        let scheduler = makeTestUpstreamSlotScheduler(upstreamCount: 1)
        let startedLeaseIDs = NIOLockedValueBox<[LeaseManager.ID]>([])
        let cancelledLeaseIDs = NIOLockedValueBox<[LeaseManager.ID]>([])

        let firstDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-race-1",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let firstLeaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: firstLeaseID,
            descriptor: firstDescriptor,
            on: eventLoop,
            starter: { _ in
                startedLeaseIDs.withLockedValue { $0.append(firstLeaseID) }
            },
            failUnavailable: {
                Issue.record("first request should be cancelled, not failed unavailable")
            },
            failCancelled: {
                cancelledLeaseIDs.withLockedValue { $0.append(firstLeaseID) }
            }
        )

        scheduler.cancelQueuedRequest(leaseID: firstLeaseID)

        let secondDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-race-2",
            label: "tools/call:ExecuteSnippet",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let secondLeaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: secondLeaseID,
            descriptor: secondDescriptor,
            on: eventLoop,
            starter: { _ in
                startedLeaseIDs.withLockedValue { $0.append(secondLeaseID) }
            },
            failUnavailable: {
                Issue.record("second request should start after the cancelled reservation releases")
            },
            failCancelled: {
                Issue.record("second request should not be cancelled")
            }
        )

        eventLoop.run()

        #expect(cancelledLeaseIDs.withLockedValue { $0 } == [firstLeaseID])
        #expect(startedLeaseIDs.withLockedValue { $0 } == [secondLeaseID])
        #expect(scheduler.debugSnapshot().queuedRequestCount == 0)
    }

    @Test func upstreamSlotSchedulerFailsReservedDispatchBeforeStartWhenQueueFails()
        async throws
    {
        let eventLoop = EmbeddedEventLoop()
        let scheduler = makeTestUpstreamSlotScheduler(upstreamCount: 1)
        let startedLeaseIDs = NIOLockedValueBox<[LeaseManager.ID]>([])
        let failedLeaseIDs = NIOLockedValueBox<[LeaseManager.ID]>([])

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-fail-race",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop,
            starter: { _ in
                startedLeaseIDs.withLockedValue { $0.append(leaseID) }
            },
            failUnavailable: {
                failedLeaseIDs.withLockedValue { $0.append(leaseID) }
            },
            failCancelled: {
                Issue.record("reserved request should fail unavailable when queue is drained")
            }
        )

        scheduler.failQueuedRequests()
        eventLoop.run()

        #expect(failedLeaseIDs.withLockedValue { $0 } == [leaseID])
        #expect(startedLeaseIDs.withLockedValue { $0 }.isEmpty)
        #expect(scheduler.debugSnapshot().queuedRequestCount == 0)
    }

    @Test func upstreamSlotSchedulerCancelsReservedDispatchBeforeStartWhenResetting()
        async throws
    {
        let eventLoop = EmbeddedEventLoop()
        let scheduler = makeTestUpstreamSlotScheduler(upstreamCount: 1)
        let startedLeaseIDs = NIOLockedValueBox<[LeaseManager.ID]>([])
        let cancelledLeaseIDs = NIOLockedValueBox<[LeaseManager.ID]>([])

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-reset-race",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop,
            starter: { _ in
                startedLeaseIDs.withLockedValue { $0.append(leaseID) }
            },
            failUnavailable: {
                Issue.record("reserved request should be cancelled during reset")
            },
            failCancelled: {
                cancelledLeaseIDs.withLockedValue { $0.append(leaseID) }
            }
        )

        scheduler.reset()
        eventLoop.run()

        #expect(cancelledLeaseIDs.withLockedValue { $0 } == [leaseID])
        #expect(startedLeaseIDs.withLockedValue { $0 }.isEmpty)
        #expect(scheduler.debugSnapshot().queuedRequestCount == 0)
    }

    @Test func upstreamSlotSchedulerUsesIdleUpstreamForTheSameSession()
        async throws
    {
        let eventLoop = EmbeddedEventLoop()
        let scheduler = makeTestUpstreamSlotScheduler(upstreamCount: 2)
        let started = NIOLockedValueBox<[String]>([])

        let firstDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-a",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let firstLeaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: firstLeaseID,
            descriptor: firstDescriptor,
            on: eventLoop,
            starter: { operationLease in
                started.withLockedValue {
                    $0.append("first@\(operationLease.upstreamIndex)")
                }
            },
            failUnavailable: {
                Issue.record("first request should start")
            },
            failCancelled: {
                Issue.record("first request should not be cancelled")
            }
        )
        eventLoop.run()

        let secondDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-a",
            label: "tools/call:ExecuteSnippet",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let secondLeaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: secondLeaseID,
            descriptor: secondDescriptor,
            on: eventLoop,
            starter: { operationLease in
                started.withLockedValue {
                    $0.append("second@\(operationLease.upstreamIndex)")
                }
            },
            failUnavailable: {
                Issue.record("second request should use the idle upstream")
            },
            failCancelled: {
                Issue.record("second request should not be cancelled")
            }
        )

        let thirdDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-b",
            label: "tools/call:XcodeListWindows",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let thirdLeaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: thirdLeaseID,
            descriptor: thirdDescriptor,
            on: eventLoop,
            starter: { operationLease in
                started.withLockedValue {
                    $0.append("third@\(operationLease.upstreamIndex)")
                }
            },
            failUnavailable: {
                Issue.record("third request should wait for an occupied upstream to be released")
            },
            failCancelled: {
                Issue.record("third request should not be cancelled")
            }
        )
        eventLoop.run()

        #expect(started.withLockedValue { $0 } == ["first@0", "second@1"])
        #expect(scheduler.debugSnapshot().queuedRequestCount == 1)

        scheduler.releaseUpstreamSlot(upstreamIndex: 1, leaseID: secondLeaseID)
        eventLoop.run()

        #expect(started.withLockedValue { $0 } == ["first@0", "second@1", "third@1"])
        #expect(scheduler.debugSnapshot().queuedRequestCount == 0)
    }

}
