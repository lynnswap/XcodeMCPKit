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
struct RuntimeCoordinatorInitializationTests {
    @Test func processRoutingRetiringCachedInitializeSourceRestartsPrimaryOnIdleActiveRoute()
        async throws
    {
        let cachedUpstream = TestUpstreamClient()
        let activeUpstream = TestUpstreamClient()
        let cachedTarget = xcodeProcessTarget(processID: 27025, xcodeVersion: "27.0")
        let activeTarget = xcodeProcessTarget(processID: 26625, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [cachedUpstream, activeUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: cachedTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: activeTarget, upstreamIndices: [1]),
            ],
            processRoutingEnabled: true,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        let cachedHandshake = try jsonValue([
            "protocolVersion": MCP.ProtocolVersion.current,
            "capabilities": [String: Any](),
            "serverInfo": ["name": "cached-source"],
        ])
        manager.markUpstreamInitialized(upstreamIndex: 0)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: cachedHandshake,
            sourceUpstream: 0
        )

        manager.reconcileXcodeProcessTargets(
            [activeTarget],
            reason: "test_remove_cached_initialize_source"
        )
        _ = try await cachedUpstream.nextStopCount()

        #expect(manager.testStateSnapshot().hasInitResult == false)
        let restartedInitialize = try await activeUpstream.nextSent(at: 0)
        #expect(methodName(from: restartedInitialize) == "initialize")
        await activeUpstream.yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: restartedInitialize),
                    serverName: "active-primary"
                )
            )
        )
        let initializedNotification = try await activeUpstream.nextSent(at: 1)
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        let toolsRequest = try await waitWithTimeout(
            "waiting for restarted primary route tools/list",
            timeout: .seconds(2)
        ) {
            try await activeUpstream.nextSent(
                startingAt: 2,
                matching: { methodName(from: $0) == "tools/list" }
            )
        }
        await activeUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: toolsRequest),
                    tools: [ownerBoundToolDescriptor(name: "BuildProject")]
                ))
        )
        await manager.drainRuntimeTasksForTesting()

        #expect(manager.testStateSnapshot().hasInitResult)
        #expect(manager.testStateSnapshot().upstreams.count == 1)
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == true)
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 1)
        #expect(
            manager.processControlPlane.catalog(forProcessID: activeTarget.processID) != nil
        )
    }

    @Test func processRoutingRetiringCachedInitializeSourceKeepsIndependentWarmRoute()
        async throws
    {
        let cachedUpstream = TestUpstreamClient()
        let activeUpstream = TestUpstreamClient()
        let cachedTarget = xcodeProcessTarget(processID: 27026, xcodeVersion: "27.0")
        let activeTarget = xcodeProcessTarget(processID: 26626, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [cachedUpstream, activeUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: cachedTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: activeTarget, upstreamIndices: [1]),
            ],
            processRoutingEnabled: true,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        let cachedHandshake = try jsonValue([
            "protocolVersion": MCP.ProtocolVersion.current,
            "capabilities": [String: Any](),
            "serverInfo": ["name": "cached-source"],
        ])
        manager.markUpstreamInitialized(upstreamIndex: 0)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: cachedHandshake,
            sourceUpstream: 0
        )
        manager.startUpstreamWarmInitialize(upstreamIndex: 1)
        let warmInitialize = try await activeUpstream.nextSent(at: 0)
        let warmUpstreamID = try extractUpstreamID(from: warmInitialize)
        #expect(manager.testStateSnapshot().upstream(id: 1)?.initInFlight == true)

        manager.reconcileXcodeProcessTargets(
            [activeTarget],
            reason: "test_remove_cached_initialize_source_during_warm_init"
        )
        _ = try await cachedUpstream.nextStopCount()

        await manager.drainRuntimeTasksForTesting()
        #expect(await activeUpstream.sentCount() == 1)
        await activeUpstream.yield(
            .message(
                try makeInitializeResponse(
                    id: warmUpstreamID,
                    serverName: "active-primary"
                ))
        )
        let initializedNotification = try await waitWithTimeout(
            "waiting for surviving warm initialize notification",
            timeout: .seconds(2)
        ) {
            try await activeUpstream.nextSent(at: 1)
        }
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        let toolsRequest = try await waitWithTimeout(
            "waiting for surviving warm route tools/list",
            timeout: .seconds(2)
        ) {
            try await activeUpstream.nextSent(
                startingAt: 2,
                matching: { methodName(from: $0) == "tools/list" }
            )
        }
        await activeUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: toolsRequest),
                    tools: [ownerBoundToolDescriptor(name: "BuildProject")]
                ))
        )
        await manager.drainRuntimeTasksForTesting()

        #expect(manager.testStateSnapshot().hasInitResult)
        #expect(manager.testStateSnapshot().upstreams.count == 1)
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == true)
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 1)
        #expect(
            manager.processControlPlane.catalog(forProcessID: activeTarget.processID) != nil
        )
    }

    @Test func processRoutingRetiringRouteKeepsIndependentAlternateActivation()
        async throws
    {
        let primaryUpstream = TestUpstreamClient()
        let retiringUpstream = TestUpstreamClient()
        let alternateUpstream = TestUpstreamClient()
        let primaryTarget = xcodeProcessTarget(processID: 27024, xcodeVersion: "27.0")
        let retiringTarget = xcodeProcessTarget(processID: 26624, xcodeVersion: "26.6")
        let alternateTarget = xcodeProcessTarget(processID: 26524, xcodeVersion: "26.5")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [primaryUpstream, retiringUpstream, alternateUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: primaryTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: retiringTarget, upstreamIndices: [1]),
                XcodeProcessRoute(target: alternateTarget, upstreamIndices: [2]),
            ],
            processRoutingEnabled: true,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let initializeFuture = fixture.registerInitialize(requestID: 1)
        let primaryInitialize = try await primaryUpstream.nextSent(at: 0)

        manager.reconcileXcodeProcessTargets(
            [primaryTarget, alternateTarget],
            reason: "test_remove_non_primary_during_initialize"
        )
        _ = try await retiringUpstream.nextStopCount()
        let alternateInitialize = try await alternateUpstream.nextSent(at: 0)
        #expect(methodName(from: alternateInitialize) == "initialize")

        await primaryUpstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: primaryInitialize)))
        )
        let response = try decodeJSON(from: try await initializeFuture.get())
        #expect(response["result"] != nil)
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 0)
        let primaryTools = try await primaryUpstream.nextSent(
            matching: { methodName(from: $0) == "tools/list" }
        )
        await primaryUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: primaryTools),
                    tools: [ownerBoundToolDescriptor(name: "BuildProject")]
                ))
        )
        await alternateUpstream.yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: alternateInitialize)
                ))
        )
        let alternateInitialized = try await alternateUpstream.nextSent(at: 1)
        #expect(methodName(from: alternateInitialized) == "notifications/initialized")
        let alternateTools = try await alternateUpstream.nextSent(
            matching: { methodName(from: $0) == "tools/list" }
        )
        await alternateUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: alternateTools),
                    tools: [ownerBoundToolDescriptor(name: "BuildProject")]
                ))
        )
        await manager.drainRuntimeTasksForTesting()
        #expect(
            manager.canonicalHandshakeState.snapshot().supporterProofs
                .map(\.slotID.rawValue).sorted() == [0, 2]
        )
    }

    @Test func processRoutingDoesNotSelectRetiredSlotEvenIfHealthLooksInitialized()
        async throws
    {
        let retiredUpstream = TestUpstreamClient()
        let activeUpstream = TestUpstreamClient()
        let retiredTarget = xcodeProcessTarget(processID: 27023, xcodeVersion: "27.0")
        let activeTarget = xcodeProcessTarget(processID: 26623, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [retiredUpstream, activeUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: retiredTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: activeTarget, upstreamIndices: [1]),
            ],
            processRoutingEnabled: true,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        manager.reconcileXcodeProcessTargets([activeTarget], reason: "test_retire_slot")
        _ = try await retiredUpstream.nextStopCount()
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-retired-slot",
            label: "tools/call:GenericTool",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let selectedUpstream = NIOLockedValueBox<Int?>(nil)
        let future: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: fixture.eventLoop
        ) { operationLease in
            selectedUpstream.withLockedValue { $0 = operationLease.upstreamIndex }
            return fixture.eventLoop.makeSucceededFuture(())
        }

        _ = try await future.get()
        #expect(selectedUpstream.withLockedValue { $0 } == 1)
        manager.completeRequestLease(leaseID)
    }

    @Test func sessionManagerRetriesProcessPrimaryInitializeOnNextXcodeProcessAfterError()
        async throws
    {
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let newerTarget = xcodeProcessTarget(processID: 27100, xcodeVersion: "27.0")
        let olderTarget = xcodeProcessTarget(processID: 26600, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: newerTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let future = fixture.registerInitialize(requestID: 1)
        let failedInitialize = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let failedUpstreamID = try extractUpstreamID(from: failedInitialize)
        await upstream0.yield(.message(try makeInitializeErrorResponse(id: failedUpstreamID)))

        let retriedInitialize = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)
        await upstream1.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil)
        #expect(manager.testStateSnapshot().upstream(id: 0)?.isInitialized != true)
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == true)
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 1)
        #expect(manager.documentationCandidateProcessIDs() == Set([olderTarget.processID]))
    }

    @Test func sessionManagerRoutesInitializeHandshakeNotificationsFromRetriedPrimaryProcess()
        async throws
    {
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let newerTarget = xcodeProcessTarget(processID: 27104, xcodeVersion: "27.0")
        let olderTarget = xcodeProcessTarget(processID: 26604, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: newerTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [1]),
            ],
            dynamicUpstreamFactory: { _ in [TestUpstreamClient()] },
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let sessionID = "session-retried-primary-handshake"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()

        let future = fixture.registerInitialize(requestID: 1, sessionID: sessionID)
        let failedInitialize = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let failedUpstreamID = try extractUpstreamID(from: failedInitialize)
        await upstream0.yield(.message(try makeInitializeErrorResponse(id: failedUpstreamID)))

        let retriedInitialize = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)
        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 27104],
            ],
            options: []
        )
        let notificationEventIndex = upstreamEvents.count()
        await upstream1.yield(.message(notification))

        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: notificationEventIndex,
            description: "waiting for retried-primary initialize notification"
        )
        let received = session.router.drainBufferedNotifications()
        #expect(received == [notification])

        await upstream1.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))
        _ = try await future.get()
    }

    @Test func sessionManagerRetriesProcessPrimaryInitializeOnSiblingBeforeDroppingProcessAfterError()
        async throws
    {
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 27103, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            dynamicUpstreamFactory: { _ in [TestUpstreamClient()] },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let future = fixture.registerInitialize(requestID: 1)
        let failedInitialize = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let failedUpstreamID = try extractUpstreamID(from: failedInitialize)
        await upstream0.yield(.message(try makeInitializeErrorResponse(id: failedUpstreamID)))

        let retriedInitialize = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)
        await upstream1.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil)
        #expect(manager.testStateSnapshot().upstream(id: 0)?.isInitialized != true)
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == true)
        #expect(manager.documentationCandidateProcessIDs() == Set([target.processID]))
    }

    @Test func sessionManagerRetriesProcessPrimaryInitializeOnNextXcodeProcessAfterExit()
        async throws
    {
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let newerTarget = xcodeProcessTarget(processID: 27101, xcodeVersion: "27.0")
        let olderTarget = xcodeProcessTarget(processID: 26601, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: newerTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [1]),
            ],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let future = fixture.registerInitialize(requestID: 1)
        _ = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let exitEventIndex = upstreamEvents.count()
        await upstream0.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: exitEventIndex,
            description: "waiting for primary process-bound upstream exit"
        )

        let retriedInitialize = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)
        await upstream1.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil)
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == true)
    }

    @Test(arguments: [false, true])
    func processRetirementPreservesOnlyClientOwnedInitializeDeadlines(hasPendingClient: Bool)
        async throws
    {
        let upstream = TestUpstreamClient()
        let timeouts = RecordingRuntimeTimeoutScheduler()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            scheduleRuntimeTimeout: timeouts.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(
                    target: xcodeProcessTarget(processID: 27104, xcodeVersion: "27.0"),
                    upstreamIndices: [0]
                )
            ],
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        fixture.manager.startEagerInitializePrimary()
        _ = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let existingClient = hasPendingClient ? fixture.registerInitialize(requestID: 1) : nil
        fixture.manager.reconcileXcodeProcessTargets([], reason: "test_process_disappeared")
        let newClient = fixture.registerInitialize(requestID: 2, sessionID: "new-client")

        if let existingClient {
            #expect(timeouts.scheduledCount() == 1)
            #expect(timeouts.fire(at: 0))
            await #expect(throws: TimeoutError.self) { try await existingClient.get() }
        } else {
            #expect(timeouts.scheduledCount() == 2)
            #expect(timeouts.fire(at: 0) == false)
            #expect(timeouts.fire(at: 1))
        }
        await #expect(throws: TimeoutError.self) { try await newClient.get() }
    }

    @Test func sessionManagerEagerExitGivesReplacementInitializeANewTimeout() async throws {
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let timeouts = RecordingRuntimeTimeoutScheduler()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream0, upstream1],
            scheduleRuntimeTimeout: timeouts.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(
                    target: xcodeProcessTarget(processID: 27103, xcodeVersion: "27.0"),
                    upstreamIndices: [0]
                ),
                XcodeProcessRoute(
                    target: xcodeProcessTarget(processID: 26603, xcodeVersion: "26.6"),
                    upstreamIndices: [1]
                ),
            ],
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        fixture.manager.startEagerInitializePrimary()
        _ = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        #expect(timeouts.scheduledCount() == 1)

        await upstream0.yield(.exit(1))
        let replacement = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let client = fixture.registerInitialize(requestID: 1)
        timeouts.fire(at: 0)
        await upstream1.yield(.message(try makeInitializeResponse(
            id: extractUpstreamID(from: replacement)
        )))
        let response = try decodeJSON(from: try await client.get())
        #expect(response["result"] != nil)
        #expect(fixture.manager.isInitialized())
    }

    @Test func sessionManagerRetriesProcessPrimaryInitializeWhenSendIsUnavailable()
        async throws
    {
        let unavailableUpstream = AlwaysUnavailableUpstreamClient(reason: .startFailed)
        let retryUpstream = TestUpstreamClient()
        let newerTarget = xcodeProcessTarget(processID: 27102, xcodeVersion: "27.0")
        let olderTarget = xcodeProcessTarget(processID: 26602, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [unavailableUpstream, retryUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: newerTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let future = fixture.registerInitialize(requestID: 1)

        try await waitForSentCount(unavailableUpstream, count: 1, timeoutSeconds: 2)
        let retriedInitialize = try await sentValue(from: retryUpstream, at: 0, timeout: .seconds(2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)
        await retryUpstream.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil)
        #expect(manager.testStateSnapshot().upstream(id: 0)?.isInitialized != true)
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == true)
    }

    @Test func sessionManagerMarksPrimaryUsableBeforeInitializeReturns() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        _ = try await fixture.initializePrimary(on: upstream)
        #expect(manager.chooseUpstreamIndex() == 0)
    }

    @Test func sessionManagerRejectsUnsupportedInitializeProtocolBeforeIssuingSession()
        async throws
    {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let sessionID = "session-unsupported-protocol"
        let future = fixture.registerInitialize(requestID: 1, sessionID: sessionID)
        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID = try extractUpstreamID(from: sent)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": upstreamID,
            "result": [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: Any](),
            ],
        ]
        let responseData = try JSONSerialization.data(withJSONObject: response, options: [])
        await upstream.yield(.message(responseData))

        let responseObject = try decodeJSON(
            from: try await waitWithTimeout(
                "waiting for unsupported initialize response",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        let error = try #require(responseObject["error"] as? [String: Any])
        #expect(error["message"] as? String == "unsupported upstream protocol version")
        #expect(manager.hasSession(id: sessionID) == false)
        #expect(manager.isInitialized() == false)
        guard let upstreamHealth = manager.testStateSnapshot().upstream(id: 0),
            case .quarantined = upstreamHealth.healthState
        else {
            Issue.record("unsupported upstream did not remain quarantined")
            return
        }
    }

    @Test func sessionManagerRemovesPendingInitializeSessionOnFailure() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let sessionID = "session-failed-initialize"
        let future = fixture.registerInitialize(requestID: 1, sessionID: sessionID)
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)

        manager.failInitPending(error: TimeoutError())

        do {
            _ = try await future.get()
            #expect(Bool(false), "initialize future should fail")
        } catch {
            #expect(manager.hasSession(id: sessionID) == false)
        }
    }

    @Test func sessionManagerRecordsServerInitiatedRequestUpstreamForClientResponses()
        async throws
    {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let sessionID = "session-server-request"
        let session = manager.session(id: sessionID)
        _ = try await fixture.initializePrimary(on: upstream, sessionID: sessionID)

        let serverRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "server-request-1",
            "method": "sampling/createMessage",
            "params": [String: Any](),
        ]
        let serverRequestData = try JSONSerialization.data(
            withJSONObject: serverRequest,
            options: []
        )
        manager.routeUnmappedUpstreamMessage(
            serverRequestData,
            operationLease: try #require(
                manager.upstreamTopology.operationLease(for: UpstreamSlotID(rawValue: 0))
            )
        )

        let clientID = JSONRPC.ID(any: "xcode-mcp-proxy.server-request.1")!
        let route = try #require(session.serverRequestTracker.consume(clientID: clientID))
        #expect(route.upstreamIndex == 0)
        #expect(route.upstreamID.value == .string("server-request-1"))
        #expect(session.serverRequestTracker.consume(clientID: clientID) == nil)
    }

    @Test func sessionManagerDoesNotTreatServerRequestIDAsPendingResponseID()
        async throws
    {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let eventLoop = fixture.eventLoop
        let manager = fixture.manager

        let sessionID = "session-server-request-id-collision"
        let session = manager.session(id: sessionID)
        _ = try await fixture.initializePrimary(on: upstream, sessionID: sessionID)

        let originalID = JSONRPC.ID(any: NSNumber(value: 42))!
        let responseFuture = session.router.registerRequest(
            idKey: originalID.key,
            on: eventLoop
        )
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: originalID,
            upstreamIndex: 0
        )

        let serverRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: upstreamID),
            "method": "sampling/createMessage",
            "params": [String: Any](),
        ]
        manager.routeUpstreamMessage(
            try JSONSerialization.data(withJSONObject: serverRequest, options: []),
            upstreamIndex: 0
        )

        let clientID = JSONRPC.ID(any: "xcode-mcp-proxy.server-request.1")!
        let route = try #require(session.serverRequestTracker.consume(clientID: clientID))
        #expect(route.upstreamIndex == 0)
        #expect(route.upstreamID.key == String(upstreamID))

        manager.routeUpstreamMessage(try makeToolListResponse(id: upstreamID), upstreamIndex: 0)
        _ = try await responseFuture.get()
    }

    @Test func sessionManagerCompletesMalformedMappedUpstreamResponseWithError()
        async throws
    {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let eventLoop = fixture.eventLoop
        let manager = fixture.manager

        let sessionID = "session-malformed-mapped-response"
        let session = manager.session(id: sessionID)
        _ = try await fixture.initializePrimary(on: upstream, sessionID: sessionID)

        let originalID = JSONRPC.ID(any: NSNumber(value: 42))!
        let responseFuture = session.router.registerRequest(
            idKey: originalID.key,
            on: eventLoop
        )
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: originalID,
            upstreamIndex: 0
        )
        let malformedResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: upstreamID),
        ]

        manager.routeUpstreamMessage(
            try JSONSerialization.data(withJSONObject: malformedResponse, options: []),
            upstreamIndex: 0
        )

        let response = try decodeJSON(from: try await responseFuture.get())
        #expect((response["id"] as? NSNumber)?.intValue == 42)
        let error = try #require(response["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == -32000)
        #expect(error["message"] as? String == "invalid upstream response")
    }

    @Test func sessionManagerPreservesServerRequestRouteUntilForwardingSendAccepted()
        async throws
    {
        let upstream = ToggleableOverloadUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let eventLoop = fixture.eventLoop
        let manager = fixture.manager

        let sessionID = "session-server-response-retry"
        let session = manager.session(id: sessionID)
        _ = try await fixture.initializePrimary(on: upstream, sessionID: sessionID)

        let serverRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "server-request-1",
            "method": "sampling/createMessage",
            "params": [String: Any](),
        ]
        manager.routeUnmappedUpstreamMessage(
            try JSONSerialization.data(withJSONObject: serverRequest, options: []),
            operationLease: try #require(
                manager.upstreamTopology.operationLease(for: UpstreamSlotID(rawValue: 0))
            )
        )

        let clientID = JSONRPC.ID(any: "xcode-mcp-proxy.server-request.1")!
        #expect(session.serverRequestTracker.lookup(clientID: clientID) != nil)

        let clientResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": clientID.value.foundationObject,
            "result": ["ok": true],
        ]
        let clientResponseData = try JSONSerialization.data(
            withJSONObject: clientResponse,
            options: []
        )

        await upstream.overloadNextSend()
        let rejectedResult = try await manager.forwardServerRequestResponse(
            responseData: clientResponseData,
            sessionID: sessionID,
            responseID: clientID,
            on: eventLoop
        ).get()
        #expect(rejectedResult == .upstreamUnavailable)
        #expect(session.serverRequestTracker.lookup(clientID: clientID) != nil)

        let acceptedResult = try await manager.forwardServerRequestResponse(
            responseData: clientResponseData,
            sessionID: sessionID,
            responseID: clientID,
            on: eventLoop
        ).get()
        #expect(acceptedResult == .accepted)
        #expect(session.serverRequestTracker.lookup(clientID: clientID) == nil)

        let forwarded = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        let forwardedObject = try #require(
            JSONSerialization.jsonObject(with: forwarded, options: []) as? [String: Any]
        )
        #expect(forwardedObject["id"] as? String == "server-request-1")
    }

    @Test func serverRequestTrackerPreservesDuplicateUpstreamIDsAcrossUpstreams()
        async throws
    {
        let tracker = ServerRequestTracker()
        let upstreamID = JSONRPC.ID(any: "duplicate")!

        let firstClientID = tracker.record(
            upstreamID: upstreamID,
            operationLease: testOperationLease(0)
        )
        let secondClientID = tracker.record(
            upstreamID: upstreamID,
            operationLease: testOperationLease(1)
        )

        #expect(firstClientID.key != secondClientID.key)
        let firstRoute = try #require(tracker.consume(clientID: firstClientID))
        let secondRoute = try #require(tracker.consume(clientID: secondClientID))
        #expect(firstRoute.upstreamIndex == 0)
        #expect(secondRoute.upstreamIndex == 1)
        #expect(firstRoute.upstreamID.value == .string("duplicate"))
        #expect(secondRoute.upstreamID.value == .string("duplicate"))
    }

    @Test func serverRequestTrackerExpiresUnansweredRoutes() async throws {
        let tracker = ServerRequestTracker(routeTimeout: .seconds(1))
        let upstreamID = JSONRPC.ID(any: "stale")!
        let now = Date()

        let clientID = tracker.record(
            upstreamID: upstreamID,
            operationLease: testOperationLease(0),
            now: now
        )

        let expired = tracker.consume(
            clientID: clientID,
            now: now.addingTimeInterval(2)
        )
        #expect(expired == nil)
    }

    @Test func serverRequestTrackerEvictsOldestRoutesAtCapacity() async throws {
        let tracker = ServerRequestTracker(routeTimeout: .seconds(60), maxRoutes: 2)
        let now = Date()
        let first = tracker.record(
            upstreamID: JSONRPC.ID(any: "first")!,
            operationLease: testOperationLease(0),
            now: now
        )
        let second = tracker.record(
            upstreamID: JSONRPC.ID(any: "second")!,
            operationLease: testOperationLease(0),
            now: now
        )
        let third = tracker.record(
            upstreamID: JSONRPC.ID(any: "third")!,
            operationLease: testOperationLease(0),
            now: now
        )

        #expect(tracker.consume(clientID: first, now: now) == nil)
        #expect(tracker.consume(clientID: second, now: now)?.upstreamID.value == .string("second"))
        #expect(tracker.consume(clientID: third, now: now)?.upstreamID.value == .string("third"))
    }

    @Test func sessionManagerRoutesServerInitiatedRequestToOwningSession() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let firstSessionID = "session-server-request-a"
        let firstSession = manager.session(id: firstSessionID)
        _ = try await fixture.initializePrimary(on: upstream, sessionID: firstSessionID)

        let secondSessionID = "session-server-request-b"
        let secondSession = manager.session(id: secondSessionID)
        let secondFuture = fixture.registerInitialize(requestID: 2, sessionID: secondSessionID)
        _ = try await waitWithTimeout(
            "waiting for second session initialize response",
            timeout: .seconds(2)
        ) {
            try await secondFuture.get()
        }

        let ownerLeaseID = manager.createRequestLease(
            descriptor: SessionRequestPipeline.Descriptor(
                sessionID: secondSessionID,
                label: "tools/call:owner",
                expectsResponse: true,
                isTopLevelClientRequest: true
            )
        )
        manager.activateRequestLease(
            ownerLeaseID,
            requestIDKey: "owner",
            upstreamIndex: 0,
            timeout: .seconds(5)
        )
        defer { manager.completeRequestLease(ownerLeaseID) }

        let serverRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "server-request-1",
            "method": "sampling/createMessage",
            "params": [String: Any](),
        ]
        let serverRequestData = try JSONSerialization.data(
            withJSONObject: serverRequest,
            options: []
        )
        manager.routeUnmappedUpstreamMessage(
            serverRequestData,
            operationLease: try #require(
                manager.upstreamTopology.operationLease(for: UpstreamSlotID(rawValue: 0))
            )
        )

        let clientID = JSONRPC.ID(any: "xcode-mcp-proxy.server-request.1")!
        #expect(firstSession.serverRequestTracker.consume(clientID: clientID) == nil)
        let route = try #require(secondSession.serverRequestTracker.consume(clientID: clientID))
        #expect(route.upstreamIndex == 0)
        #expect(route.upstreamID.value == .string("server-request-1"))
    }

    @Test func sessionManagerRoutesProgressNotificationOnlyToOwningSession() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let firstSessionID = "session-progress-owner-a"
        let firstSession = manager.session(id: firstSessionID)
        _ = try await fixture.initializePrimary(on: upstream, sessionID: firstSessionID)

        let secondSessionID = "session-progress-owner-b"
        let secondSession = manager.session(id: secondSessionID)
        let secondFuture = fixture.registerInitialize(requestID: 2, sessionID: secondSessionID)
        _ = try await waitWithTimeout(
            "waiting for second progress session initialize response",
            timeout: .seconds(2)
        ) {
            try await secondFuture.get()
        }
        _ = firstSession.router.drainBufferedNotifications()
        _ = secondSession.router.drainBufferedNotifications()

        let firstLeaseID = manager.createRequestLease(
            descriptor: SessionRequestPipeline.Descriptor(
                sessionID: firstSessionID,
                label: "tools/call:first-progress-owner",
                expectsResponse: true,
                isTopLevelClientRequest: true
            )
        )
        manager.activateRequestLease(
            firstLeaseID,
            requestIDKey: "first-progress-owner",
            upstreamIndex: 0,
            timeout: .seconds(5),
            progressTokenMapping: ProgressTokenMapping(
                clientToken: .string("client-progress-token-a"),
                upstreamToken: "proxy-progress-token-a"
            )
        )
        defer { manager.completeRequestLease(firstLeaseID) }

        let ownerLeaseID = manager.createRequestLease(
            descriptor: SessionRequestPipeline.Descriptor(
                sessionID: secondSessionID,
                label: "tools/call:progress-owner",
                expectsResponse: true,
                isTopLevelClientRequest: true
            )
        )
        manager.activateRequestLease(
            ownerLeaseID,
            requestIDKey: "progress-owner",
            upstreamIndex: 0,
            timeout: .seconds(5),
            progressTokenMapping: ProgressTokenMapping(
                clientToken: .string("client-progress-token-b"),
                upstreamToken: "proxy-progress-token-b"
            )
        )
        defer { manager.completeRequestLease(ownerLeaseID) }

        let progressNotification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/progress",
                "params": [
                    "progressToken": "proxy-progress-token-b",
                    "progress": 1,
                    "total": 2,
                ],
            ],
            options: []
        )
        manager.routeUpstreamMessage(progressNotification, upstreamIndex: 0)

        #expect(firstSession.router.drainBufferedNotifications().isEmpty)
        let routedNotifications = secondSession.router.drainBufferedNotifications()
        let routedNotification = try #require(routedNotifications.first)
        #expect(routedNotifications.count == 1)
        let routedObject = try #require(
            try JSONSerialization.jsonObject(with: routedNotification) as? [String: Any]
        )
        let routedParams = try #require(routedObject["params"] as? [String: Any])
        #expect(routedParams["progressToken"] as? String == "client-progress-token-b")
    }

    @Test func sessionManagerDropsProgressNotificationWithoutActiveOwner() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let sessionID = "session-progress-without-owner"
        let session = manager.session(id: sessionID)
        _ = try await fixture.initializePrimary(on: upstream, sessionID: sessionID)
        _ = session.router.drainBufferedNotifications()
        let droppedBefore = manager.debugSnapshot().upstreams[0]
            .droppedUnmappedNotificationCount

        let progressNotification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/progress",
                "params": [
                    "progressToken": "orphaned-progress-token",
                    "progress": 1,
                ],
            ],
            options: []
        )
        manager.routeUpstreamMessage(progressNotification, upstreamIndex: 0)

        #expect(session.router.drainBufferedNotifications().isEmpty)
        #expect(
            manager.debugSnapshot().upstreams[0].droppedUnmappedNotificationCount
                == droppedBefore + 1
        )
    }

    @Test func sessionManagerBroadcastsGlobalNotificationWithActiveOwner() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let firstSessionID = "session-global-notification-a"
        let firstSession = manager.session(id: firstSessionID)
        _ = try await fixture.initializePrimary(on: upstream, sessionID: firstSessionID)

        let secondSessionID = "session-global-notification-b"
        let secondSession = manager.session(id: secondSessionID)
        let secondFuture = fixture.registerInitialize(requestID: 2, sessionID: secondSessionID)
        _ = try await waitWithTimeout(
            "waiting for second global notification session initialize response",
            timeout: .seconds(2)
        ) {
            try await secondFuture.get()
        }
        _ = firstSession.router.drainBufferedNotifications()
        _ = secondSession.router.drainBufferedNotifications()

        let ownerLeaseID = manager.createRequestLease(
            descriptor: SessionRequestPipeline.Descriptor(
                sessionID: secondSessionID,
                label: "tools/call:global-notification-owner",
                expectsResponse: true,
                isTopLevelClientRequest: true
            )
        )
        manager.activateRequestLease(
            ownerLeaseID,
            requestIDKey: "global-notification-owner",
            upstreamIndex: 0,
            timeout: .seconds(5)
        )
        defer { manager.completeRequestLease(ownerLeaseID) }

        let globalNotification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/tools/list_changed",
            ],
            options: []
        )
        manager.routeUpstreamMessage(globalNotification, upstreamIndex: 0)

        #expect(firstSession.router.drainBufferedNotifications() == [globalNotification])
        #expect(secondSession.router.drainBufferedNotifications() == [globalNotification])
    }

    @Test func sessionManagerRestoresPendingInitializeWhenInitializedNotificationOverloads()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
        let replacementUpstreams = NIOLockedValueBox<[ToggleableOverloadUpstreamClient]>([])
        let target = xcodeProcessTarget(processID: 27130, xcodeVersion: "27.0")
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [0])],
            dynamicUpstreamFactory: { _ in
                let replacement = ToggleableOverloadUpstreamClient()
                replacementUpstreams.withLockedValue { $0.append(replacement) }
                return [replacement]
            }
        )
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initialInitialize = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)

        await upstream.overloadNextInitializedNotificationSend()
        await upstream.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
        let replacement = try await waitWithTimeout("waiting for initialize replacement") {
            while true {
                if let replacement = replacementUpstreams.withLockedValue({ $0.first }) {
                    return replacement
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let retriedInitialize = try await sentValue(
            from: replacement,
            at: 0,
            timeout: .seconds(2)
        )
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)

        await replacement.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))

        _ = try await waitWithTimeout(
            "waiting for initialize response after overload recovery",
            timeout: .seconds(2)
        ) {
            try await future.get()
        }
    }

    @Test func sessionManagerCancelsOriginalInitTimeoutBeforeRetryingInitializedNotificationOverload()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
        let replacementUpstreams = NIOLockedValueBox<[ToggleableOverloadUpstreamClient]>([])
        let target = xcodeProcessTarget(processID: 27131, xcodeVersion: "27.0")
        let timeoutClock = TestClock()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            scheduleRuntimeTimeout: makeDeterministicRuntimeTimeoutScheduler(clock: timeoutClock),
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [0])],
            dynamicUpstreamFactory: { _ in
                let replacement = ToggleableOverloadUpstreamClient()
                replacementUpstreams.withLockedValue { $0.append(replacement) }
                return [replacement]
            }
        )
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let initialInitialize = try #require(await upstream.sentValue(at: 0))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)

        await upstream.overloadNextInitializedNotificationSend()
        try await waitForSuspendedSleepers(on: timeoutClock)
        timeoutClock.advance(by: .milliseconds(150))
        await upstream.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
        let replacement = try await waitWithTimeout("waiting for timed initialize replacement") {
            while true {
                if let replacement = replacementUpstreams.withLockedValue({ $0.first }) {
                    return replacement
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let retriedInitialize = try await sentValue(
            from: replacement,
            at: 0,
            timeout: .seconds(2)
        )
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)

        try await waitForSuspendedSleepers(on: timeoutClock)
        timeoutClock.advance(by: .milliseconds(180))
        await replacement.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))
        try await waitForSentCount(replacement, count: 2, timeoutSeconds: 2)

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil, "initializeResponse=\(response)")
    }

    @Test func sessionManagerInitializeTimeoutStaysArmedWhileInitializedNotificationIsInFlight()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = BlockingInitializedNotificationUpstreamClient()
        let timeoutClock = TestClock()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            scheduleRuntimeTimeout: makeDeterministicRuntimeTimeoutScheduler(clock: timeoutClock)
        )
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID = try extractUpstreamID(from: sent)

        await upstream.blockNextInitializedNotification()
        await upstream.yield(.message(try makeInitializeResponse(id: upstreamID)))
        try await upstream.waitForBlockedInitializedNotification()

        try await waitForSuspendedSleepers(on: timeoutClock)
        timeoutClock.advance(by: .milliseconds(300))

        do {
            _ = try await waitWithTimeout(
                "initialize should fail at its deadline while the initialized notification is in flight",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
            Issue.record("initialize must not remain pending past its deadline")
        } catch is TimeoutError {
        }

        await upstream.releaseBlockedInitializedNotification()
        await Task.yield()
        #expect(manager.canonicalHandshakeState.initializeResult() == nil)
        #expect(manager.initializeManager.pendingInitializes().isEmpty)
    }

    @Test func duplicateInitializeResponseCannotClearAcceptedResponseOwnership() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = BlockingInitializedNotificationUpstreamClient()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream]
        )
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID = try extractUpstreamID(from: sent)
        let valid = try #require(
            JSONSerialization.jsonObject(
                with: makeInitializeResponse(id: upstreamID)
            ) as? [String: Any]
        )

        await upstream.blockNextInitializedNotification()
        manager.handleInitializeResponse(valid, upstreamIndex: 0, upstreamID: upstreamID)
        try await upstream.waitForBlockedInitializedNotification()
        manager.handleInitializeResponse(
            [
                "jsonrpc": "2.0",
                "id": upstreamID,
                "error": ["code": -32000, "message": "duplicate"],
            ],
            upstreamIndex: 0,
            upstreamID: upstreamID
        )

        await upstream.releaseBlockedInitializedNotification(.accepted)
        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil)
        #expect(manager.canonicalHandshakeState.initializeResult() != nil)
    }

    @Test func sessionManagerReleasedInitializeTimeoutCannotFailReplacement() async throws {
        let upstream = TestUpstreamClient()
        let timeouts = RecordingRuntimeTimeoutScheduler()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            scheduleRuntimeTimeout: timeouts.scheduler(),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.startEagerInitializePrimary()
        let first = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(manager.initializeManager.releasePrimaryInitialize(
            upstreamIndex: 0,
            upstreamID: try extractUpstreamID(from: first)
        ))
        #expect(manager.clearUpstreamState(upstreamIndex: 0))
        #expect(timeouts.isCancelled(at: 0))

        let client = fixture.registerInitialize(requestID: 2, sessionID: "replacement-client")
        let replacement = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))
        #expect(timeouts.fireIgnoringCancellation(at: 0))
        await upstream.yield(.message(try makeInitializeResponse(
            id: extractUpstreamID(from: replacement)
        )))
        let response = try decodeJSON(from: try await client.get())
        #expect(response["result"] != nil)
        #expect(manager.isInitialized())
    }

    @Test(arguments: [false, true])
    func sessionManagerRearmedInitializeTimeoutIgnoresPriorCallback(completeWithResponse: Bool)
        async throws
    {
        let upstream = TestUpstreamClient()
        let timeouts = RecordingRuntimeTimeoutScheduler()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            scheduleRuntimeTimeout: timeouts.scheduler(),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        let client = fixture.registerInitialize(requestID: 1)
        let request = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        manager.initializeManager.rearmInitTimeoutForRetry { manager.makeInitTimeout(id: $0) }?.cancel()
        #expect(timeouts.isCancelled(at: 0))
        #expect(timeouts.fireIgnoringCancellation(at: 0))
        #expect(manager.initializeManager.pendingInitializes().count == 1)

        if completeWithResponse {
            await upstream.yield(.message(try makeInitializeResponse(
                id: extractUpstreamID(from: request)
            )))
            let response = try decodeJSON(from: try await client.get())
            #expect(response["result"] != nil)
        } else {
            #expect(timeouts.fire(at: 1))
            await #expect(throws: TimeoutError.self) { try await client.get() }
        }
    }

    @Test func initializeManagerRearmsRetryTimeoutOnlyWhilePendingInitializesRemain() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let manager = InitializeManager(brokerState: CanonicalHandshakeState())
        let factoryCalls = NIOLockedValueBox(0)

        let staleCancelled = NIOLockedValueBox(false)
        _ = manager.replaceInitTimeout { _ in
            RuntimeScheduledTimeout { staleCancelled.withLockedValue { $0 = true } }
        }
        manager.rearmInitTimeoutForRetry { _ in
            factoryCalls.withLockedValue { $0 += 1 }
            return RuntimeScheduledTimeout {}
        }?.cancel()
        #expect(staleCancelled.withLockedValue { $0 })
        #expect(factoryCalls.withLockedValue { $0 } == 0)

        _ = manager.registerInitialize(
            sessionID: "session-rearm-retry-timeout",
            sessionGeneration: 0,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            primaryUpstreamIndex: 0,
            on: eventLoop
        )
        let replacedCancelled = NIOLockedValueBox(false)
        _ = manager.replaceInitTimeout { _ in
            RuntimeScheduledTimeout { replacedCancelled.withLockedValue { $0 = true } }
        }
        manager.rearmInitTimeoutForRetry { _ in
            factoryCalls.withLockedValue { $0 += 1 }
            return RuntimeScheduledTimeout {}
        }?.cancel()
        #expect(replacedCancelled.withLockedValue { $0 })
        #expect(factoryCalls.withLockedValue { $0 } == 1)

        let keptCancelled = NIOLockedValueBox(false)
        _ = manager.replaceInitTimeout { _ in
            RuntimeScheduledTimeout { keptCancelled.withLockedValue { $0 = true } }
        }
        #expect(manager.rearmInitTimeoutForRetry { _ in nil } == nil)
        #expect(keptCancelled.withLockedValue { $0 } == false)

        let shutdownState = manager.beginShutdown()
        shutdownState.timeout?.cancel()
        shutdownState.recoveryTimeout?.cancel()
        for pending in shutdownState.pending {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }
    }

    @Test func canonicalInitializePublishesFirstCommittedParticipantAndJoinsSibling() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let canonical = CanonicalHandshakeState()
        let manager = InitializeManager(brokerState: canonical)
        _ = manager.registerInitialize(
            sessionID: "cross-source-primary",
            sessionGeneration: 0,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            primaryUpstreamIndex: nil,
            on: eventLoop
        )
        let firstResult: JSONValue = .object([
            "protocolVersion": .string(MCP.ProtocolVersion.current),
            "serverInfo": .object(["version": .string("27.0")]),
        ])
        let secondResult: JSONValue = .object([
            "protocolVersion": .string(MCP.ProtocolVersion.current),
            "serverInfo": .object(["version": .string("26.6")]),
        ])
        let firstProof = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 0),
            slotGeneration: 1
        )
        let secondProof = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 1),
            slotGeneration: 1
        )
        guard
            case .accepted(let first) = canonical.offerInitializeResult(
                firstResult,
                sourceProof: firstProof
            ),
            case .accepted(let second) = canonical.offerInitializeResult(
                secondResult,
                sourceProof: secondProof
            )
        else {
            Issue.record("compatible initialize participants were rejected")
            return
        }

        let publication = manager.finishInitializeParticipant {
            canonical.commitInitializeParticipant(second)
        }
        guard
            case .published(let publishedResult, let publishedSource) =
                publication.commit
        else {
            Issue.record("first committed participant did not publish")
            return
        }
        let completion = try #require(publication.publication)
        #expect(completion.pending.count == 1)
        #expect(completion.result == secondResult)
        #expect(publishedResult == secondResult)
        #expect(publishedSource == secondProof)
        #expect(canonical.initializeSourceUpstream() == 1)
        #expect(canonical.initializeResult() == secondResult)
        let join = manager.finishInitializeParticipant {
            canonical.commitInitializeParticipant(first)
        }
        guard case .joined = join.commit else {
            Issue.record("compatible sibling did not join")
            return
        }
        #expect(join.publication == nil)
        #expect(canonical.snapshot().supporterProofs == [firstProof, secondProof])
        for pending in completion.pending {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }
    }

    @Test func initializeParticipantPublicationDrainsPendingAtomicallyAgainstTimeout() throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let canonical = CanonicalHandshakeState()
        let manager = InitializeManager(brokerState: canonical)
        _ = manager.registerInitialize(
            sessionID: "atomic-publication",
            sessionGeneration: 0,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            primaryUpstreamIndex: nil,
            on: eventLoop
        )
        let proof = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 0),
            slotGeneration: 1
        )
        let result: JSONValue = .object([
            "protocolVersion": .string(MCP.ProtocolVersion.current)
        ])
        guard
            case .accepted(let participant) = canonical.offerInitializeResult(
                result,
                sourceProof: proof
            )
        else {
            Issue.record("initialize participant was rejected")
            return
        }

        let canonicalCommitted = DispatchSemaphore(value: 0)
        let allowWaiterDrain = DispatchSemaphore(value: 0)
        let publicationFinished = DispatchSemaphore(value: 0)
        let failureStarted = DispatchSemaphore(value: 0)
        let failureFinished = DispatchSemaphore(value: 0)
        let publicationBox = NIOLockedValueBox<InitializeManager.ParticipantCompletion?>(nil)
        let failureBox = NIOLockedValueBox<InitializeManager.FailureResult?>(nil)

        DispatchQueue.global().async {
            let publication = manager.finishInitializeParticipant {
                let commit = canonical.commitInitializeParticipant(participant)
                canonicalCommitted.signal()
                allowWaiterDrain.wait()
                return commit
            }
            publicationBox.withLockedValue { $0 = publication }
            publicationFinished.signal()
        }
        #expect(canonicalCommitted.wait(timeout: .now() + 2) == .success)

        DispatchQueue.global().async {
            failureStarted.signal()
            let failure = manager.completePrimaryInitializeFailure()
            failureBox.withLockedValue { $0 = failure }
            failureFinished.signal()
        }
        #expect(failureStarted.wait(timeout: .now() + 2) == .success)
        #expect(failureFinished.wait(timeout: .now() + 0.1) == .timedOut)

        allowWaiterDrain.signal()
        #expect(publicationFinished.wait(timeout: .now() + 2) == .success)
        #expect(failureFinished.wait(timeout: .now() + 2) == .success)

        let publication = try #require(publicationBox.withLockedValue { $0 })
        let completion = try #require(publication.publication)
        #expect(completion.pending.count == 1)
        #expect(completion.result == result)
        #expect(failureBox.withLockedValue { $0?.pending.isEmpty } == true)
        for pending in completion.pending {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }
    }

    @Test func concurrentInitializeParticipantCommitsPublishAndDrainExactlyOnce() throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let canonical = CanonicalHandshakeState()
        let manager = InitializeManager(brokerState: canonical)
        _ = manager.registerInitialize(
            sessionID: "concurrent-publication",
            sessionGeneration: 0,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            primaryUpstreamIndex: nil,
            on: eventLoop
        )
        let firstProof = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 0),
            slotGeneration: 1
        )
        let secondProof = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 1),
            slotGeneration: 1
        )
        let firstResult: JSONValue = .object([
            "protocolVersion": .string(MCP.ProtocolVersion.current),
            "serverInfo": .object(["name": .string("Xcode 27")]),
        ])
        let secondResult: JSONValue = .object([
            "protocolVersion": .string(MCP.ProtocolVersion.current),
            "serverInfo": .object(["name": .string("Xcode 26.6")]),
        ])
        guard
            case .accepted(let first) = canonical.offerInitializeResult(
                firstResult,
                sourceProof: firstProof
            ),
            case .accepted(let second) = canonical.offerInitializeResult(
                secondResult,
                sourceProof: secondProof
            )
        else {
            Issue.record("concurrent participants were rejected")
            return
        }

        let ready = DispatchSemaphore(value: 0)
        let start = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let completions = NIOLockedValueBox<[InitializeManager.ParticipantCompletion]>([])
        DispatchQueue.global().async {
            ready.signal()
            start.wait()
            let completion = manager.finishInitializeParticipant {
                canonical.commitInitializeParticipant(first)
            }
            completions.withLockedValue { $0.append(completion) }
            finished.signal()
        }
        DispatchQueue.global().async {
            ready.signal()
            start.wait()
            let completion = manager.finishInitializeParticipant {
                canonical.commitInitializeParticipant(second)
            }
            completions.withLockedValue { $0.append(completion) }
            finished.signal()
        }
        #expect(ready.wait(timeout: .now() + 2) == .success)
        #expect(ready.wait(timeout: .now() + 2) == .success)
        start.signal()
        start.signal()
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(finished.wait(timeout: .now() + 2) == .success)

        let committed = completions.withLockedValue { $0 }
        #expect(committed.count == 2)
        #expect(
            committed.filter {
                if case .published = $0.commit { return true }
                return false
            }.count == 1)
        #expect(
            committed.filter {
                if case .joined = $0.commit { return true }
                return false
            }.count == 1)
        let publications = committed.compactMap(\.publication)
        #expect(publications.count == 1)
        let publication = try #require(publications.first)
        #expect(publication.pending.count == 1)
        #expect(canonical.snapshot().supporterProofs == [firstProof, secondProof])
        for pending in publication.pending {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }
    }

    @Test func canonicalInitializeRebindsRawResultAndRejectsOldGenerationRemoval() throws {
        let canonical = CanonicalHandshakeState()
        let oldSource = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 0),
            slotGeneration: 1
        )
        let survivor = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 1),
            slotGeneration: 1
        )
        let replacement = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 0),
            slotGeneration: 2
        )
        let sourceResult = try #require(
            JSONValue(any: [
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["version": "27.0"],
            ]))
        let survivorResult = try #require(
            JSONValue(any: [
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["version": "26.6"],
            ]))

        guard
            case .accepted(let sourceLease) = canonical.offerInitializeResult(
                sourceResult,
                sourceProof: oldSource
            ),
            case .accepted(let survivorLease) = canonical.offerInitializeResult(
                survivorResult,
                sourceProof: survivor
            )
        else {
            Issue.record("compatible supporters were rejected")
            return
        }
        guard case .published = canonical.commitInitializeParticipant(sourceLease),
            case .joined = canonical.commitInitializeParticipant(survivorLease)
        else {
            Issue.record("supporters did not publish and join")
            return
        }

        _ = canonical.removeInitializeParticipantAndSupporter(
            sourceProof: oldSource,
            retaining: [survivor]
        )
        #expect(canonical.initializeSourceUpstream() == 1)
        #expect(canonical.initializeResult() == survivorResult)

        guard
            case .accepted(let replacementLease) = canonical.offerInitializeResult(
                sourceResult,
                sourceProof: replacement
            ), case .joined = canonical.commitInitializeParticipant(replacementLease)
        else {
            Issue.record("replacement generation did not join")
            return
        }
        _ = canonical.removeInitializeParticipantAndSupporter(
            sourceProof: oldSource,
            retaining: [survivor, replacement]
        )
        let snapshot = canonical.snapshot()
        #expect(snapshot.initializeSourceProof == survivor)
        #expect(snapshot.supporterProofs == [survivor, replacement])
        #expect(snapshot.initializeResult == survivorResult)
    }

    @Test func canonicalInitializeRetainsSemanticBaselineWhileSupportIsSuspended() throws {
        let canonical = CanonicalHandshakeState()
        let suspendedProof = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 0),
            slotGeneration: 1
        )
        let recoveredProof = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 1),
            slotGeneration: 1
        )
        let replacementSemanticProof = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 2),
            slotGeneration: 1
        )
        let originalResult = try jsonValue([
            "protocolVersion": MCP.ProtocolVersion.current,
            "capabilities": ["experimental": ["stable": true]],
            "serverInfo": ["name": "Xcode 27"],
        ])
        let compatibleResult = try jsonValue([
            "protocolVersion": MCP.ProtocolVersion.current,
            "capabilities": ["experimental": ["stable": true]],
            "serverInfo": ["name": "Xcode 26.6"],
        ])
        let incompatibleResult = try jsonValue([
            "protocolVersion": MCP.ProtocolVersion.current,
            "capabilities": ["experimental": ["different": true]],
            "serverInfo": ["name": "Other"],
        ])

        guard
            case .accepted(let original) = canonical.offerInitializeResult(
                originalResult,
                sourceProof: suspendedProof
            ), case .published = canonical.commitInitializeParticipant(original)
        else {
            Issue.record("initial supporter did not publish")
            return
        }
        _ = canonical.updateSupportEligibility(retaining: [])
        #expect(canonical.initializeResult() == nil)
        #expect(canonical.snapshot().supporterProofs.isEmpty)

        guard
            case .incompatible = canonical.offerInitializeResult(
                incompatibleResult,
                sourceProof: replacementSemanticProof
            )
        else {
            Issue.record("suspended raw evidence did not reject a semantic mismatch")
            return
        }
        guard
            case .accepted(let recovered) = canonical.offerInitializeResult(
                compatibleResult,
                sourceProof: recoveredProof
            ),
            case .published(let recoveredResult, let sourceProof) =
                canonical.commitInitializeParticipant(recovered)
        else {
            Issue.record("compatible participant did not restore suspended support")
            return
        }
        #expect(recoveredResult == compatibleResult)
        #expect(sourceProof == recoveredProof)

        _ = canonical.removeInitializeParticipantAndSupporter(
            sourceProof: recoveredProof,
            retaining: []
        )
        guard
            case .incompatible = canonical.offerInitializeResult(
                incompatibleResult,
                sourceProof: replacementSemanticProof
            )
        else {
            Issue.record("remaining suspended evidence lost its semantic baseline")
            return
        }
        _ = canonical.removeInitializeParticipantAndSupporter(
            sourceProof: suspendedProof,
            retaining: []
        )
        guard
            case .accepted(let replacement) = canonical.offerInitializeResult(
                incompatibleResult,
                sourceProof: replacementSemanticProof
            ), case .published = canonical.commitInitializeParticipant(replacement)
        else {
            Issue.record("detaching the last raw supporter did not release the semantic baseline")
            return
        }
    }

    @Test func initializeRegistrationLinearizesAfterCanonicalSupportWithdrawal() throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let canonical = CanonicalHandshakeState()
        let manager = InitializeManager(brokerState: canonical)
        let proof = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 0),
            slotGeneration: 1
        )
        let result: JSONValue = .object([
            "protocolVersion": .string(MCP.ProtocolVersion.current)
        ])
        guard
            case .accepted(let participant) = canonical.offerInitializeResult(
                result,
                sourceProof: proof
            ), case .published = canonical.commitInitializeParticipant(participant)
        else {
            Issue.record("fixture supporter did not publish")
            return
        }

        let canonicalHidden = DispatchSemaphore(value: 0)
        let allowEligibilityCommit = DispatchSemaphore(value: 0)
        let eligibilityFinished = DispatchSemaphore(value: 0)
        let registrationStarted = DispatchSemaphore(value: 0)
        let registrationFinished = DispatchSemaphore(value: 0)
        let decision = NIOLockedValueBox<InitializeManager.RegisterDecision?>(nil)
        DispatchQueue.global().async {
            _ = manager.finishSupportEligibilityUpdate {
                let update = canonical.updateSupportEligibility(retaining: [])
                canonicalHidden.signal()
                allowEligibilityCommit.wait()
                return update
            }
            eligibilityFinished.signal()
        }
        #expect(canonicalHidden.wait(timeout: .now() + 2) == .success)

        DispatchQueue.global().async {
            registrationStarted.signal()
            let registered = manager.registerInitialize(
                sessionID: "withdrawal-linearization",
                sessionGeneration: 0,
                originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
                primaryUpstreamIndex: nil,
                on: eventLoop
            )
            decision.withLockedValue { $0 = registered }
            registrationFinished.signal()
        }
        #expect(registrationStarted.wait(timeout: .now() + 2) == .success)
        #expect(registrationFinished.wait(timeout: .now() + 0.1) == .timedOut)

        allowEligibilityCommit.signal()
        #expect(eligibilityFinished.wait(timeout: .now() + 2) == .success)
        #expect(registrationFinished.wait(timeout: .now() + 2) == .success)
        let registered = try #require(decision.withLockedValue { $0 })
        #expect(registered.cachedResult == nil)
        #expect(registered.promise != nil)

        let shutdown = manager.beginShutdown()
        shutdown.timeout?.cancel()
        for pending in shutdown.pending {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }
    }

    @Test func pendingRecoveryLeaseRejectsTimeoutAttachedAfterCallbackConsumption() throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let manager = InitializeManager(brokerState: CanonicalHandshakeState())
        _ = manager.registerInitialize(
            sessionID: "pending-recovery-attach-race",
            sessionGeneration: 0,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            primaryUpstreamIndex: nil,
            on: group.next()
        )
        let proof = UpstreamTopologyProof(
            slotID: UpstreamSlotID(rawValue: 0),
            slotGeneration: 1
        )
        let recovery = UpstreamHealthManager.QuarantineRecoveryLease(
            topologyProof: proof,
            healthProbeGeneration: 7,
            deadlineUptimeNs: 0
        )
        let preparation = try #require(
            manager.preparePendingQuarantineRecovery { recovery }
        )
        #expect(
            manager.withPendingQuarantineRecovery(preparation.lease) { true } == true
        )
        let cancelled = NIOLockedValueBox(false)
        let timeout = RuntimeScheduledTimeout {
            cancelled.withLockedValue { $0 = true }
        }
        let attachment = manager.attachPendingQuarantineRecoveryTimeout(
            timeout,
            lease: preparation.lease
        )
        #expect(attachment.accepted == false)
        timeout.cancel()
        #expect(cancelled.withLockedValue { $0 })

        let shutdown = manager.beginShutdown()
        shutdown.timeout?.cancel()
        shutdown.recoveryTimeout?.cancel()
        for pending in shutdown.pending {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }
    }

    @Test func sessionManagerRunsSecondaryWarmupAfterRecoveredInitializedNotification()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let replacementUpstreams = NIOLockedValueBox<[ToggleableOverloadUpstreamClient]>([])
        let primaryTarget = xcodeProcessTarget(processID: 27132, xcodeVersion: "27.0")
        let secondaryTarget = xcodeProcessTarget(processID: 26632, xcodeVersion: "26.6")
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: primaryTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: secondaryTarget, upstreamIndices: [1]),
            ],
            dynamicUpstreamFactory: { _ in
                let replacement = ToggleableOverloadUpstreamClient()
                replacementUpstreams.withLockedValue { $0.append(replacement) }
                return [replacement]
            }
        )
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initialInitialize = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        let replacement = try await waitWithTimeout("waiting for primary warmup replacement") {
            while true {
                if let replacement = replacementUpstreams.withLockedValue({ $0.first }) {
                    return replacement
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let retriedInitialize = try await sentValue(
            from: replacement,
            at: 0,
            timeout: .seconds(2)
        )
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)

        await replacement.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil, "initializeResponse=\(response)")
        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 5)
        let warmInitialize = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        #expect(methodName(from: warmInitialize) == "initialize")
    }

    @Test func sessionManagerSecondaryWarmInitRetriesWhenInitializedNotificationSendOverloads()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = ToggleableOverloadUpstreamClient()
        let replacementUpstreams = NIOLockedValueBox<[ToggleableOverloadUpstreamClient]>([])
        let target = xcodeProcessTarget(processID: 27133, xcodeVersion: "27.0")
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [0, 1])],
            dynamicUpstreamFactory: { _ in
                let replacement = ToggleableOverloadUpstreamClient()
                replacementUpstreams.withLockedValue { $0.append(replacement) }
                return [replacement]
            }
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let primaryInitialize = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let primaryUpstreamID = try extractUpstreamID(from: primaryInitialize)
        await upstream0.yield(.message(try makeInitializeResponse(id: primaryUpstreamID)))
        _ = try await initFuture.get()

        let firstWarmInitialize = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let firstWarmUpstreamID = try extractUpstreamID(from: firstWarmInitialize)
        await upstream1.overloadNextInitializedNotificationSend()
        await upstream1.yield(.message(try makeInitializeResponse(id: firstWarmUpstreamID)))

        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)
        let rejectedInitialized = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))
        #expect(methodName(from: rejectedInitialized) == "notifications/initialized")
        let replacement = try await waitWithTimeout("waiting for secondary warm replacement") {
            while true {
                if let replacement = replacementUpstreams.withLockedValue({ $0.first }) {
                    return replacement
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let retriedWarmInitialize = try await sentValue(
            from: replacement,
            at: 0,
            timeout: .seconds(2)
        )
        #expect(methodName(from: retriedWarmInitialize) == "initialize")
    }

    @Test func sessionManagerProducesEveryUnmappedNotificationAfterInitialize()
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
            ),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        let sessionID = "session-A"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()

        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])

        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 1],
            ],
            options: []
        )
        _ = try await future.get()
        let notificationEventIndex = upstreamEvents.count()
        await upstream.yield(.message(notification))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: notificationEventIndex,
            description: "waiting for cached initialize notification"
        )
        let received = session.router.drainBufferedNotifications()
        #expect(received.count == 1)
        #expect(received.first == notification)

        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        #expect(session.router.drainBufferedNotifications() == [notification])
    }

    @Test func sessionManagerRoutesUnmappedNotificationsDuringInitializeHandshake() async throws {
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
            ),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        let sessionID = "session-handshake"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()

        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 99],
            ],
            options: []
        )
        let notificationEventIndex = upstreamEvents.count()
        await upstream.yield(.message(notification))

        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: notificationEventIndex,
            description: "waiting for initialize-handshake notification"
        )
        let received = session.router.drainBufferedNotifications()
        #expect(received.count == 1)
        #expect(received.first == notification)

        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        _ = try await future.get()
    }

    @Test func sessionManagerProducesEveryUnmappedNotificationForCachedInitializeSessions()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream]
        )
        defer { manager.shutdownAndWait() }

        let firstFuture = manager.registerInitialize(
            sessionID: "session-A",
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let firstSent = await upstream.sent()
        let firstInitID = try extractUpstreamID(from: firstSent[0])
        await upstream.yield(.message(try makeInitializeResponse(id: firstInitID)))
        _ = try await firstFuture.get()

        let sessionID = "session-B"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()
        let cachedFuture = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 2],
            ],
            options: []
        )
        _ = try await cachedFuture.get()
        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        let received = session.router.drainBufferedNotifications()
        #expect(received.count == 1)
        #expect(received.first == notification)

        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        #expect(session.router.drainBufferedNotifications() == [notification])
    }

    @Test func sessionManagerDoesNotRecreateRemovedSessionWhenInitializeCompletes() async throws {
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
            ),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        let sessionID = "session-removed"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        manager.removeSession(id: sessionID)
        await #expect(throws: CancellationError.self) {
            try await future.get()
        }

        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])
        let responseEventIndex = upstreamEvents.count()
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        _ = try await nextRecordedValue(upstreamEvents, at: responseEventIndex)

        #expect(manager.hasSession(id: sessionID) == false)
        let snapshot = manager.testStateSnapshot()
        #expect(snapshot.hasInitResult == false)
        #expect(snapshot.initInFlight == false)
        #expect(snapshot.upstream(id: 0)?.isInitialized == false)
    }

    @Test func sessionManagerDoesNotApplyRemovedInitializeStateToRecreatedSession() async throws {
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
            ),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        let sessionID = "session-recreated"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        manager.removeSession(id: sessionID)
        let replacement = manager.session(id: sessionID)
        _ = replacement.router.drainBufferedNotifications()

        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])
        let responseEventIndex = upstreamEvents.count()
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        _ = try await nextRecordedValue(upstreamEvents, at: responseEventIndex)

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 7],
            ],
            options: []
        )
        await #expect(throws: CancellationError.self) {
            try await future.get()
        }
        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        #expect(replacement.router.drainBufferedNotifications().isEmpty)
        let snapshot = manager.testStateSnapshot()
        #expect(snapshot.hasInitResult == false)
        #expect(snapshot.initInFlight == false)
        #expect(snapshot.upstream(id: 0)?.isInitialized == false)
    }

    @Test func sessionManagerIgnoresRemovedInitializeResponseBeforeUpstreamStateClears() async throws {
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
            ),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        let sessionID = "session-removed-before-clear"
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

        _ = manager.sessionRegistry.removeSession(id: sessionID)
        let pendingInitializes = manager.initializeManager.removePendingInitializes(
            sessionID: sessionID
        )
        pendingInitializes.timeout?.cancel()
        pendingInitializes.recoveryTimeout?.cancel()
        for pending in pendingInitializes.pending {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }

        let responseEventIndex = upstreamEvents.count()
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        _ = try await nextRecordedValue(upstreamEvents, at: responseEventIndex)

        await #expect(throws: CancellationError.self) {
            try await future.get()
        }
        let snapshot = manager.testStateSnapshot()
        #expect(snapshot.hasInitResult == false)
        #expect(snapshot.initInFlight == false)
        #expect(snapshot.upstream(id: 0)?.isInitialized == false)
    }

    @Test func sessionManagerCancelsWaiterOwnedPrimaryRetryWhenSessionIsRemoved()
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
            ),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        let sessionID = "session-removed-primary-retry"
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let initialSent = await upstream.sent()
        let initialID = try extractUpstreamID(from: initialSent[0])

        #expect(manager.initializeManager.releasePrimaryInitialize(
            upstreamIndex: 0,
            upstreamID: initialID
        ))
        manager.handleInitializedNotificationSendOverload(
            upstreamIndex: 0,
            expectedUpstreamID: initialID,
            treatsAsPrimary: true
        )
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
        let retrySent = await upstream.sent()
        let retryID = try extractUpstreamID(from: retrySent[1])

        manager.removeSession(id: sessionID)
        await #expect(throws: CancellationError.self) {
            try await future.get()
        }

        let responseEventIndex = upstreamEvents.count()
        await upstream.yield(.message(try makeInitializeResponse(id: retryID)))
        _ = try await nextRecordedValue(upstreamEvents, at: responseEventIndex)

        let snapshot = manager.testStateSnapshot()
        #expect(snapshot.hasInitResult == false)
        #expect(snapshot.initInFlight == false)
        #expect(snapshot.upstream(id: 0)?.isInitialized == false)
    }

    @Test func sessionManagerCancelsOnlyRemovedInitializeReadinessWaiter() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: false)
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(readiness: readiness),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        let removedSessionID = "session-readiness-removed"
        let removedFuture = manager.registerInitialize(
            sessionID: removedSessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        _ = try await readiness.nextChangeWait(at: 0)

        _ = manager.sessionRegistry.removeSession(id: removedSessionID)
        let pendingInitializes = manager.initializeManager.removePendingInitializes(
            sessionID: removedSessionID
        )
        pendingInitializes.timeout?.cancel()
        pendingInitializes.recoveryTimeout?.cancel()
        for pending in pendingInitializes.pending {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }

        let replacementFuture = manager.registerInitialize(
            sessionID: "session-readiness-replacement",
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        #expect(pendingInitializes.cancelledPrimaryUpstreamIndex == 0)
        #expect(pendingInitializes.cancelledPrimaryUpstreamID == nil)
        let readinessToken = try #require(pendingInitializes.cancelledPrimaryReadinessToken)
        manager.cancelPrimaryInitializeReadinessWaiter(readinessToken)

        await #expect(throws: CancellationError.self) {
            try await removedFuture.get()
        }

        await readiness.setReady(true)
        let replacementInitialize = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let replacementID = try extractUpstreamID(from: replacementInitialize)
        await upstream.yield(.message(try makeInitializeResponse(id: replacementID)))
        _ = try await replacementFuture.get()
    }

    @Test func sessionManagerRoutesUnmappedNotificationsToCachedInitializeSessionsUntilClientConnects()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
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

        let sessionID = "session-hinted-pin"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()

        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        _ = try await future.get()

        let notification0 = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 0],
            ],
            options: []
        )
        let notification1 = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 1],
            ],
            options: []
        )
        let eventIndex = upstreamEvents.count()
        await upstream0.yield(.message(notification0))
        await upstream1.yield(.message(notification1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: eventIndex,
            description: "waiting for first cached initialize notification"
        )
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: eventIndex + 1,
            description: "waiting for second cached initialize notification"
        )

        let received = session.router.drainBufferedNotifications()
        #expect(Set(received) == Set([notification0, notification1]))

        manager.routeUpstreamMessage(notification0, upstreamIndex: 0)
        manager.routeUpstreamMessage(notification1, upstreamIndex: 1)
        #expect(
            Set(session.router.drainBufferedNotifications())
                == Set([notification0, notification1])
        )
    }

    @Test func sessionManagerTimeoutResetsInitState() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let config = makeConfig(requestTimeout: 1)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler()
        )
        defer { manager.shutdownAndWait() }

        let request = makeInitializeRequest(id: 1)
        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: request,
            on: eventLoop
        )

        try await spinUntilSentCount(
            upstream,
            count: 1,
            description: "waiting for initial initialize request"
        )
        #expect((await upstream.sent()).count == 1)

        #expect(timeoutScheduler.scheduledCount() == 1)
        timeoutScheduler.fire(at: 0)
        await #expect(throws: TimeoutError.self) {
            try await future.get()
        }
        #expect(manager.testStateSnapshot().initInFlight == false)

        _ = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        try await spinUntilSentCount(
            upstream,
            count: 2,
            description: "waiting for second initialize request after timeout reset"
        )
        #expect((await upstream.sent()).count == 2)
    }

    @Test func sessionManagerShutdownFailsPendingInitializeRequests() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)

        await manager.shutdown()

        await #expect(throws: CancellationError.self) {
            try await future.get()
        }
    }

    @Test func sessionManagerTimeoutDoesNotClearRecreatedSessionInitializeRoutingState()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let config = makeConfig(requestTimeout: 1)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler()
        )
        defer { manager.shutdownAndWait() }

        let sessionID = "session-timeout-recreated"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        #expect(timeoutScheduler.scheduledCount() == 1)

        manager.removeSession(id: sessionID)
        _ = manager.session(id: sessionID)
        let replacementSnapshotBeforeTimeout = try #require(manager.testSessionSnapshot(id: sessionID))
        await #expect(throws: CancellationError.self) {
            try await future.get()
        }

        timeoutScheduler.fire(at: 0)

        let replacementSnapshotAfterTimeout = try #require(manager.testSessionSnapshot(id: sessionID))
        #expect(replacementSnapshotAfterTimeout.generation == replacementSnapshotBeforeTimeout.generation)
    }

}
