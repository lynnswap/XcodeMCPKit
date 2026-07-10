import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyKit
import XcodeMCPProxyTestSupport
@testable import XcodeMCPProxyInternalTestSupport

@Suite(.serialized)
struct RuntimeCoordinatorTests {
    @Test func defaultUpstreamsDoNotInjectXcodePIDEnvironment() async throws {
        let environment = try defaultUpstreamEnvironment(sharedSessionID: nil)

        #expect(environment["MCP_XCODE_PID"] == nil)
    }

    @Test func upstreamPlanDefaultsToStaticFallbackWhenNoTargetsAreProvided() {
        let plan = MCPBridgeRuntime.makeUpstreamPlan(
            config: makeBridgeRuntimeConfig(makeConfig(requestTimeout: 0)),
            xcodeTargets: []
        )

        #expect(plan.upstreams.count == 1)
        #expect(plan.xcodeProcessRoutes.isEmpty)
    }

    @Test func upstreamPlanExplicitProcessRoutingCanStartWithoutInitialTargets() {
        let plan = MCPBridgeRuntime.makeUpstreamPlan(
            config: makeBridgeRuntimeConfig(makeConfig(requestTimeout: 0)),
            xcodeTargets: [],
            processBoundRoutingEnabled: true
        )

        #expect(plan.upstreams.isEmpty)
        #expect(plan.xcodeProcessRoutes.isEmpty)
    }

    @Test func processRoutingWithoutInitialTargetsRunsReadinessAutoLaunch() async throws {
        let readiness = ReadinessFlag(isReady: false)
        let sleepRecorder = ControlledReadinessSleep()
        let launchRecorder = XcodeLaunchRecorder()
        let discovery = RecordingXcodeTargetDiscovery(targets: [])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                sleepRecorder: sleepRecorder,
                recordPollSleeps: true,
                launchRecorder: launchRecorder
            ),
            processRoutingEnabled: true,
            xcodeTargetDiscovery: discovery
        )
        defer { fixture.shutdownAndWait() }

        _ = try await waitWithTimeout("waiting for no-target Xcode launch", timeout: .seconds(2)) {
            try await launchRecorder.nextLaunch(at: 0)
        }
        let sleep = try await waitWithTimeout(
            "waiting for no-target readiness poll",
            timeout: .seconds(2)
        ) {
            try await sleepRecorder.nextSleep(at: 0)
        }

        #expect(sleep == 1_000_000)
        #expect(fixture.manager.debugSnapshot().upstreams.isEmpty)
        #expect(fixture.manager.debugSnapshot().processRoutes.isEmpty)
    }

    @Test func defaultCoordinatorWithoutDiscoveryUsesStaticFallbackUpstream() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 0),
            eventLoop: group.next(),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        #expect(manager.processRoutingEnabled == false)
        #expect(manager.debugSnapshot().upstreams.count == 1)
        #expect(manager.debugSnapshot().processRoutes.isEmpty)
    }

    @Test func defaultUpstreamsPassThroughInheritedMCPXcodePIDEnvironment() async throws {
        let environment = try withEnvironmentVariables(
            [
                "XCODE_PID": "1234",
                "MCP_XCODE_PID": "5678",
            ]
        ) {
            try defaultUpstreamEnvironment(sharedSessionID: nil)
        }

        #expect(environment["XCODE_PID"] == nil)
        #expect(environment["MCP_XCODE_PID"] == "5678")
    }

    @Test func defaultUpstreamsDoNotInjectSessionIDWhenConfigDoesNotSpecifyOne() async throws {
        let environment = try defaultUpstreamEnvironment(sharedSessionID: nil)

        #expect(environment["MCP_XCODE_SESSION_ID"] == nil)
    }

    @Test func defaultUpstreamsInjectExplicitSessionIDWhenConfigured() async throws {
        let environment = try defaultUpstreamEnvironment(sharedSessionID: "session-explicit")

        #expect(environment["MCP_XCODE_SESSION_ID"] == "session-explicit")
    }

    @Test func upstreamStderrClassifierTreatsNoXcodeFatalAsAvailabilityWait() {
        let message =
            "mcpbridge/MCPBridge.swift:125: Fatal error: MCP_XCODE_PID environment variable not set and no running Xcode processes found"

        #expect(UpstreamStderrClassifier.classify(message) == .xcodeUnavailable)
    }

    @Test func upstreamStderrLogLimiterSuppressesRepeatedMessages() {
        let limiter = UpstreamStderrLogLimiter(duplicateLogIntervalNanoseconds: 1_000_000_000)
        let message = "some upstream stderr"
        let first = limiter.decision(
            upstreamIndex: 0,
            message: message,
            classification: .unknown,
            nowUptimeNs: 0
        )
        let second = limiter.decision(
            upstreamIndex: 0,
            message: message,
            classification: .unknown,
            nowUptimeNs: 100_000_000
        )
        let third = limiter.decision(
            upstreamIndex: 0,
            message: message,
            classification: .unknown,
            nowUptimeNs: 1_100_000_000
        )

        #expect(first.shouldLog)
        #expect(!second.shouldLog)
        #expect(third.shouldLog)
        #expect(third.suppressedDuplicateCount == 1)
    }

    @Test func upstreamStderrStillRecordsInDebugSnapshotWhenRateLimited() async throws {
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        manager.handleUpstreamStderr("repeated stderr", upstreamIndex: 0)
        manager.handleUpstreamStderr("repeated stderr", upstreamIndex: 0)

        let snapshot = manager.debugSnapshot()
        #expect(snapshot.upstreams[0].recentStderr.count == 2)
    }

    @Test func sessionManagerQueuesInitializeRequests() async throws {
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { fixture.shutdownAndWait() }

        let future1 = fixture.registerInitialize(requestID: 1)
        let future2 = fixture.registerInitialize(requestID: 2)

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let sent = await upstream.sent()
        #expect(sent.count == 1)
        guard sent.count == 1 else { return }

        let upstreamID = try extractUpstreamID(from: sent[0])
        let response = try makeInitializeResponse(id: upstreamID)
        await upstream.yield(.message(response))

        let response1 = try decodeJSON(
            from: try await waitWithTimeout(
                "waiting for first queued initialize response",
                timeout: .seconds(2)
            ) {
                try await future1.get()
            }
        )
        let response2 = try decodeJSON(
            from: try await waitWithTimeout(
                "waiting for second queued initialize response",
                timeout: .seconds(2)
            ) {
                try await future2.get()
            }
        )
        let id1 = (response1["id"] as? NSNumber)?.intValue
        let id2 = (response2["id"] as? NSNumber)?.intValue
        #expect(id1 == 1)
        #expect(id2 == 2)
    }

    @Test func sessionManagerJoinsEagerProcessInitializeInFlight() async throws {
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 27001, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ]
        )
        defer { fixture.shutdownAndWait() }

        let eagerInitialize = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let eagerUpstreamID = try extractUpstreamID(from: eagerInitialize)
        let future = fixture.registerInitialize(requestID: 1)
        #expect(await upstream.sentCount() == 1)

        await upstream.yield(.message(try makeInitializeResponse(id: eagerUpstreamID)))

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil)
    }

    @Test func sessionManagerDoesNotCancelEagerInitializeWhenJoinedSessionIsRemoved() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let eagerInitialize = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let eagerUpstreamID = try extractUpstreamID(from: eagerInitialize)
        let sessionID = "session-eager-removed"
        let future = fixture.registerInitialize(requestID: 1, sessionID: sessionID)
        #expect(await upstream.sentCount() == 1)

        manager.removeSession(id: sessionID)
        await #expect(throws: CancellationError.self) {
            try await future.get()
        }

        await upstream.yield(.message(try makeInitializeResponse(id: eagerUpstreamID)))
        let initializedNotification = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        await manager.drainRuntimeTasksForTesting()

        #expect(manager.hasSession(id: sessionID) == false)
        #expect(manager.testStateSnapshot().hasInitResult)
    }

    @Test func processRoutingWaitsForLateXcodeBeforeCompletingInitialize()
        async throws
    {
        let target = xcodeProcessTarget(processID: 27002, xcodeVersion: "27.0")
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let future = fixture.registerInitialize(requestID: 1)
        #expect(manager.testStateSnapshot().initInFlight == false)

        manager.reconcileXcodeProcessTargets([target], reason: "test_late_xcode")

        let upstream = try #require(createdUpstreams.withLockedValue { $0.first })
        let initializeRequest = try await upstream.nextSent(at: 0)
        let upstreamID = try extractUpstreamID(from: initializeRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: upstreamID)))

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil)
        let snapshot = manager.debugSnapshot()
        #expect(snapshot.processRoutes.map(\.processID) == [target.processID])
        #expect(snapshot.processRoutes.map(\.state) == ["active"])
    }

    @Test func processRoutingSerializesTriggeredReconciles() async throws {
        let olderTarget = xcodeProcessTarget(processID: 27004, xcodeVersion: "26.6")
        let newerTarget = xcodeProcessTarget(processID: 27005, xcodeVersion: "27.0")
        let discovery = BlockingSequencedXcodeTargetDiscovery(
            firstTargets: [olderTarget],
            secondTargets: [newerTarget]
        )
        let routeCreations = LockedRecordedValues<pid_t>()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            processRoutingEnabled: true,
            xcodeTargetDiscovery: discovery,
            dynamicUpstreamFactory: { target in
                routeCreations.append(target.processID)
                return [TestUpstreamClient()]
            },
            startImmediately: false
        )
        defer {
            discovery.releaseFirst()
            fixture.shutdownAndWait()
        }
        let manager = fixture.manager

        manager.triggerXcodeProcessReconcile(reason: "first_snapshot")
        try await discovery.firstStarted.waitUntilSignaled()
        manager.triggerXcodeProcessReconcile(reason: "second_snapshot")

        #expect(discovery.callCount() == 1)
        discovery.releaseFirst()

        try await discovery.secondStarted.waitUntilSignaled()
        #expect(try await nextRecordedValue(routeCreations, at: 1) == newerTarget.processID)
        #expect(discovery.callCount() == 2)
        _ = try await waitWithTimeout("waiting for second reconcile commit") {
            while manager.xcodeProcessRoutes.map(\.target.processID) != [newerTarget.processID] {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(manager.xcodeProcessRoutes.map(\.target.processID) == [newerTarget.processID])
        let processRoutes = manager.debugSnapshot().processRoutes
        #expect(processRoutes.map(\.processID) == [
            newerTarget.processID,
            olderTarget.processID,
        ])
        #expect(processRoutes.map(\.state) == ["active", "retired"])
    }

    @Test func processRoutingReschedulesQueuedReconcileAfterWorkerCancellation() async throws {
        let canceledTarget = xcodeProcessTarget(processID: 27006, xcodeVersion: "26.6")
        let recoveredTarget = xcodeProcessTarget(processID: 27007, xcodeVersion: "27.0")
        let discovery = BlockingSequencedXcodeTargetDiscovery(
            firstTargets: [canceledTarget],
            secondTargets: [recoveredTarget]
        )
        let routeCreations = LockedRecordedValues<pid_t>()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            processRoutingEnabled: true,
            xcodeTargetDiscovery: discovery,
            dynamicUpstreamFactory: { target in
                routeCreations.append(target.processID)
                return [TestUpstreamClient()]
            },
            startImmediately: false
        )
        defer {
            discovery.releaseFirst()
            fixture.shutdownAndWait()
        }
        let manager = fixture.manager

        manager.triggerXcodeProcessReconcile(reason: "cancelled_snapshot")
        try await discovery.firstStarted.waitUntilSignaled()
        manager.debugReset()
        manager.triggerXcodeProcessReconcile(reason: "queued_after_cancel")

        #expect(discovery.callCount() == 1)
        discovery.releaseFirst()

        try await discovery.secondStarted.waitUntilSignaled()
        #expect(try await nextRecordedValue(routeCreations, at: 0) == recoveredTarget.processID)
        #expect(discovery.callCount() == 2)
        _ = try await waitWithTimeout("waiting for recovered reconcile commit") {
            while manager.xcodeProcessRoutes.map(\.target.processID) != [recoveredTarget.processID] {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(manager.xcodeProcessRoutes.map(\.target.processID) == [recoveredTarget.processID])
        let processRoutes = manager.debugSnapshot().processRoutes
        #expect(processRoutes.map(\.processID) == [recoveredTarget.processID])
        #expect(processRoutes.map(\.state) == ["active"])
    }

    @Test func processRoutingNoXcodeInitializeWaitDoesNotRescheduleTimeoutForJoinedClient()
        async throws
    {
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            processRoutingEnabled: true,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }

        let firstFuture = fixture.registerInitialize(
            requestID: 1,
            sessionID: "session-no-xcode-timeout-1"
        )
        #expect(timeoutScheduler.scheduledCount() == 1)

        let secondFuture = fixture.registerInitialize(
            requestID: 2,
            sessionID: "session-no-xcode-timeout-2"
        )
        #expect(timeoutScheduler.scheduledCount() == 1)

        timeoutScheduler.fire(at: 0)
        await #expect(throws: TimeoutError.self) {
            try await firstFuture.get()
        }
        await #expect(throws: TimeoutError.self) {
            try await secondFuture.get()
        }
    }

    @Test func processRoutingLateXcodeKeepsClientInitializeTimeoutSeparateFromActivationTimeout()
        async throws
    {
        let target = xcodeProcessTarget(processID: 27008, xcodeVersion: "27.0")
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let future = fixture.registerInitialize(
            requestID: 1,
            sessionID: "session-late-xcode-timeout"
        )
        #expect(timeoutScheduler.scheduledCount() == 1)

        manager.reconcileXcodeProcessTargets([target], reason: "test_late_xcode_timeout")
        let upstream = try #require(createdUpstreams.withLockedValue { $0.first })
        _ = try await upstream.nextSent(at: 0)

        #expect(timeoutScheduler.scheduledCount() == 2)
        #expect(timeoutScheduler.delay(at: 0)?.nanoseconds == TimeAmount.seconds(5).nanoseconds)
        #expect(timeoutScheduler.delay(at: 1)?.nanoseconds == TimeAmount.seconds(5).nanoseconds)
        #expect(timeoutScheduler.fire(at: 1))
        #expect(timeoutScheduler.scheduledCount() == 3)

        let replacement = try #require(createdUpstreams.withLockedValue { $0.dropFirst().first })
        #expect(try await upstream.nextStopCount() == 1)
        #expect(timeoutScheduler.delay(at: 2)?.nanoseconds == TimeAmount.milliseconds(250).nanoseconds)
        #expect(timeoutScheduler.fire(at: 2))
        _ = try await replacement.nextSent(at: 0)

        timeoutScheduler.fire(at: 0)
        await #expect(throws: TimeoutError.self) {
            try await future.get()
        }
    }

    @Test func processRouteActivationUsesShortTimeoutWhenAutoApproveEnabled() async throws {
        var config = makeConfig(requestTimeout: 5)
        config.autoApproveXcodeDialog = true
        let target = xcodeProcessTarget(processID: 27009, xcodeVersion: "27.0")
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            config: config,
            upstreams: [],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }

        fixture.manager.reconcileXcodeProcessTargets([target], reason: "test_auto_approve_timeout")
        let upstream = try #require(createdUpstreams.withLockedValue { $0.first })
        _ = try await upstream.nextSent(at: 0)

        #expect(timeoutScheduler.scheduledCount() == 1)
        #expect(timeoutScheduler.delay(at: 0)?.nanoseconds == TimeAmount.seconds(3).nanoseconds)
    }

    @Test func processRouteActivationCatalogTimeoutReplacesSlotAndDropsStaleCatalog()
        async throws
    {
        var config = makeConfig(requestTimeout: 20)
        config.autoApproveXcodeDialog = true
        let olderUpstream = TestUpstreamClient()
        let olderTarget = xcodeProcessTarget(processID: 26626, xcodeVersion: "26.6")
        let newerTarget = xcodeProcessTarget(processID: 27026, xcodeVersion: "27.0")
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let uptimeClock = TestUptimeClock()
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            config: config,
            upstreams: [olderUpstream],
            nowUptimeNanoseconds: uptimeClock.now,
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0]),
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let olderInitializeFuture = fixture.registerInitialize(requestID: 1)
        let olderInitialize = try await waitWithTimeout(
            "waiting for initial primary initialize",
            timeout: .seconds(2)
        ) {
            try await olderUpstream.nextSent(at: 0)
        }
        await olderUpstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: olderInitialize)))
        )
        _ = try await waitWithTimeout(
            "waiting for initial primary initialize response",
            timeout: .seconds(2)
        ) {
            try await olderInitializeFuture.get()
        }
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (olderTarget, 0, [toolDescriptor(name: "Only26")]),
            ]
        )

        manager.reconcileXcodeProcessTargets(
            [olderTarget, newerTarget],
            reason: "test_catalog_timeout"
        )

        let firstAttempt = try #require(createdUpstreams.withLockedValue { $0.first })
        let firstInitialize = try await waitWithTimeout(
            "waiting for first activation initialize",
            timeout: .seconds(2)
        ) {
            try await firstAttempt.nextSent(at: 0)
        }
        await firstAttempt.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: firstInitialize)))
        )
        _ = try await waitWithTimeout(
            "waiting for first activation initialized notification",
            timeout: .seconds(2)
        ) {
            try await firstAttempt.nextSent(at: 1)
        }
        let staleToolsRequest = try await waitWithTimeout(
            "waiting for first activation tools/list",
            timeout: .seconds(2)
        ) {
            try await firstAttempt.nextSent(
                startingAt: 2,
                matching: { methodName(from: $0) == "tools/list" }
            )
        }

        #expect(timeoutScheduler.scheduledCount() == 3)
        #expect(timeoutScheduler.delay(at: 1)?.nanoseconds == TimeAmount.seconds(3).nanoseconds)
        #expect(timeoutScheduler.delay(at: 2)?.nanoseconds == TimeAmount.seconds(10).nanoseconds)
        #expect(timeoutScheduler.fire(at: 2))
        #expect(try await waitWithTimeout(
            "waiting for timed-out activation slot to stop",
            timeout: .seconds(2)
        ) {
            try await firstAttempt.nextStopCount()
        } == 1)
        #expect(timeoutScheduler.scheduledCount() == 4)
        #expect(timeoutScheduler.delay(at: 3)?.nanoseconds == TimeAmount.milliseconds(250).nanoseconds)
        #expect(createdUpstreams.withLockedValue(\.count) == 2)

        #expect(timeoutScheduler.fire(at: 3))
        let retryAttempt = try #require(createdUpstreams.withLockedValue { $0.dropFirst().first })
        let retryInitialize = try await waitWithTimeout(
            "waiting for retry activation initialize",
            timeout: .seconds(2)
        ) {
            try await retryAttempt.nextSent(at: 0)
        }
        await retryAttempt.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: retryInitialize)))
        )
        _ = try await waitWithTimeout(
            "waiting for retry activation initialized notification",
            timeout: .seconds(2)
        ) {
            try await retryAttempt.nextSent(at: 1)
        }
        let retryToolsRequest = try await waitWithTimeout(
            "waiting for retry activation tools/list",
            timeout: .seconds(2)
        ) {
            try await retryAttempt.nextSent(
                startingAt: 2,
                matching: { methodName(from: $0) == "tools/list" }
            )
        }

        await firstAttempt.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: staleToolsRequest),
                    tools: [
                        toolDescriptor(name: "Stale27"),
                    ]
                )
            )
        )
        #expect(manager.processControlPlane.catalog(forProcessID: newerTarget.processID) == nil)

        await retryAttempt.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: retryToolsRequest),
                    tools: [
                        toolDescriptor(name: "Only27"),
                    ]
                )
            )
        )
        _ = try await waitWithTimeout(
            "waiting for retry process catalog completion",
            timeout: .seconds(2)
        ) {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.canonicalToolsSourceUpstream == 1
            }
        }

        #expect(Set(toolNames(in: manager.cachedToolsListResult() ?? .null)) == Set([
            "Only26",
            "Only27",
        ]))
        #expect(Set(manager.debugSnapshot().processToolCatalogs.map(\.processID)) == Set([
            olderTarget.processID,
            newerTarget.processID,
        ]))
    }

    @Test func processRouteActivationEmptyCatalogRetryPreservesCatalogTimeout()
        async throws
    {
        var config = makeConfig(requestTimeout: 20)
        config.autoApproveXcodeDialog = true
        let olderUpstream = TestUpstreamClient()
        let olderTarget = xcodeProcessTarget(processID: 26629, xcodeVersion: "26.6")
        let newerTarget = xcodeProcessTarget(processID: 27029, xcodeVersion: "27.0")
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            config: config,
            upstreams: [olderUpstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0]),
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let olderInitializeFuture = fixture.registerInitialize(requestID: 1)
        let olderInitialize = try await olderUpstream.nextSent(at: 0)
        await olderUpstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: olderInitialize)))
        )
        _ = try await olderInitializeFuture.get()
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (olderTarget, 0, [toolDescriptor(name: "Only26")]),
            ]
        )

        manager.reconcileXcodeProcessTargets(
            [olderTarget, newerTarget],
            reason: "test_empty_catalog_retry_preserves_catalog_timeout"
        )

        let activationUpstream = try #require(createdUpstreams.withLockedValue { $0.first })
        let initialize = try await waitWithTimeout(
            "waiting for activation initialize",
            timeout: .seconds(2)
        ) {
            try await activationUpstream.nextSent(at: 0)
        }
        await activationUpstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: initialize)))
        )
        _ = try await waitWithTimeout(
            "waiting for activation initialized notification",
            timeout: .seconds(2)
        ) {
            try await activationUpstream.nextSent(at: 1)
        }
        try await waitForProcessRouteActivationInitialized(
            manager,
            processID: newerTarget.processID,
            upstreamIndex: 1,
            attempt: 1,
            message: "waiting for activation initialized state"
        )
        let firstToolsRequest = try await waitWithTimeout(
            "waiting for activation tools/list",
            timeout: .seconds(2)
        ) {
            try await activationUpstream.nextSent(
                startingAt: 2,
                matching: { methodName(from: $0) == "tools/list" }
            )
        }
        let catalogTimeoutIndex = try #require((0..<timeoutScheduler.scheduledCount()).first {
            timeoutScheduler.delay(at: $0)?.nanoseconds == TimeAmount.seconds(10).nanoseconds
                && timeoutScheduler.isCancelled(at: $0) == false
        })

        await activationUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: firstToolsRequest),
                    tools: []
                )
            )
        )

        let retryIndex = try await waitWithTimeout(
            "waiting for empty catalog retry timeout",
            timeout: .seconds(2)
        ) {
            while true {
                if let index = (0..<timeoutScheduler.scheduledCount()).first(where: {
                    $0 != catalogTimeoutIndex
                        && timeoutScheduler.delay(at: $0)?.nanoseconds
                            == TimeAmount.milliseconds(250).nanoseconds
                        && timeoutScheduler.isCancelled(at: $0) == false
                }) {
                    return index
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        #expect(timeoutScheduler.isCancelled(at: catalogTimeoutIndex) == false)
        #expect(createdUpstreams.withLockedValue(\.count) == 1)
        #expect(timeoutScheduler.fire(at: retryIndex))
        let retryToolsRequest = try await waitWithTimeout(
            "waiting for retry tools/list",
            timeout: .seconds(2)
        ) {
            try await activationUpstream.nextSent(
                startingAt: 3,
                matching: { methodName(from: $0) == "tools/list" }
            )
        }
        await activationUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: retryToolsRequest),
                    tools: [
                        toolDescriptor(name: "Only27Recovered"),
                    ]
                )
            )
        )
        _ = try await waitWithTimeout(
            "waiting for retry process catalog completion",
            timeout: .seconds(2)
        ) {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.canonicalToolsSourceUpstream == 1
            }
        }

        #expect(createdUpstreams.withLockedValue(\.count) == 1)
        let recoveredAttempt = try #require(
            manager.processControlPlane.attemptSnapshot(processID: newerTarget.processID)
        )
        #expect(recoveredAttempt.phase == .cataloged)
        #expect(recoveredAttempt.upstreamID.rawValue == 1)
        #expect(recoveredAttempt.attemptID.rawValue == 1)
        #expect(timeoutScheduler.isCancelled(at: catalogTimeoutIndex))
        #expect(timeoutScheduler.fire(at: catalogTimeoutIndex) == false)
        #expect(Set(toolNames(in: manager.cachedToolsListResult() ?? .null)) == Set([
            "Only26",
            "Only27Recovered",
        ]))
    }







    @Test func processRouteActivationClearingPreCatalogInitializedUpstreamAllowsRetry()
        async throws
    {
        let target = xcodeProcessTarget(processID: 27019, xcodeVersion: "27.0")
        let upstream = TestUpstreamClient()
        let route = XcodeProcessRoute(target: target, upstreamIndices: [0])
        let uptimeClock = TestUptimeClock()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            nowUptimeNanoseconds: uptimeClock.now,
            xcodeProcessRoutes: [route],
            processRoutingEnabled: true,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        _ = manager.beginProcessRouteAttachingForTesting(
            processID: target.processID,
            upstreamIndex: 0,
            nowUptimeNs: 0
        )
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.clearUpstreamState(upstreamIndex: 0)

        #expect(manager.processControlPlane.attemptSnapshot(processID: target.processID) == nil)
        let currentRoute = try #require(
            manager.processControlPlane.route(forProcessID: target.processID)
        )
        manager.startProcessRouteActivation(for: currentRoute)
        let retryInitialize = try await waitWithTimeout(
            "waiting for process route activation retry",
            timeout: .seconds(2)
        ) {
            try await upstream.nextSent(at: 0)
        }
        #expect(methodName(from: retryInitialize) == "initialize")
    }

    @Test func processRouteActivationUnsupportedInitializeCompletesPendingClient()
        async throws
    {
        let target = xcodeProcessTarget(processID: 27021, xcodeVersion: "27.0")
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        manager.reconcileXcodeProcessTargets([target], reason: "test_unsupported_activation")
        let upstream = try #require(createdUpstreams.withLockedValue { $0.first })
        let initialize = try await upstream.nextSent(at: 0)
        let initializeFuture = fixture.registerInitialize(
            requestID: 1,
            sessionID: "session-unsupported-activation"
        )
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": try extractUpstreamID(from: initialize),
            "result": [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: Any](),
            ],
        ]
        await upstream.yield(
            .message(try JSONSerialization.data(withJSONObject: response, options: []))
        )

        let responseObject = try decodeJSON(from: try await initializeFuture.get())
        let error = try #require(responseObject["error"] as? [String: Any])
        #expect(error["message"] as? String == "unsupported upstream protocol version")
        #expect(manager.isInitialized() == false)
    }

    @Test func processRouteActivationTimeoutStopsUnusedReplacementUpstreams()
        async throws
    {
        let target = xcodeProcessTarget(processID: 27022, xcodeVersion: "27.0")
        let upstream = TestUpstreamClient()
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let replacement = TestUpstreamClient()
                let unused = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(contentsOf: [replacement, unused]) }
                return [replacement, unused]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let currentRoute = try #require(
            manager.processControlPlane.route(forProcessID: target.processID)
        )
        manager.startProcessRouteActivation(for: currentRoute)
        _ = try await upstream.nextSent(at: 0)
        #expect(timeoutScheduler.fire(at: 0))

        let replacements = createdUpstreams.withLockedValue { $0 }
        #expect(replacements.count == 2)
        #expect(try await upstream.nextStopCount() == 1)
        #expect(try await replacements[1].nextStopCount() == 1)
        #expect(await replacements[0].stopCount() == 0)
    }

    @Test func processRouteActivationRecoversAfterReplacementFactoryIsTemporarilyEmpty()
        async throws
    {
        let target = xcodeProcessTarget(processID: 27023, xcodeVersion: "27.0")
        let initialUpstream = TestUpstreamClient()
        let recoveredUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let factoryCallCount = NIOLockedValueBox(0)
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [initialUpstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let call = factoryCallCount.withLockedValue { count in
                    count += 1
                    return count
                }
                guard call > 1 else { return [] }
                let upstream = TestUpstreamClient()
                recoveredUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let route = try #require(
            manager.processControlPlane.route(forProcessID: target.processID)
        )
        manager.startProcessRouteActivation(for: route)
        _ = try await initialUpstream.nextSent(at: 0)
        #expect(timeoutScheduler.fire(at: 0))
        #expect(try await initialUpstream.nextStopCount() == 1)
        #expect(manager.processControlPlane.route(forProcessID: target.processID) == nil)
        #expect(manager.upstreamTopology.snapshot().slotIDs.isEmpty)

        manager.reconcileXcodeProcessTargets(
            [target],
            reason: "test_recover_after_empty_replacement"
        )

        let recoveredUpstream = try #require(recoveredUpstreams.withLockedValue { $0.first })
        let initialize = try await waitWithTimeout(
            "waiting for activation after replacement factory recovery",
            timeout: .seconds(2)
        ) {
            try await recoveredUpstream.nextSent(at: 0)
        }
        #expect(methodName(from: initialize) == "initialize")
        let recoveredRoute = try #require(
            manager.processControlPlane.route(forProcessID: target.processID)
        )
        #expect(recoveredRoute.upstreamIndices == [1])
        #expect(manager.upstreamTopology.snapshot().slotIDs == [UpstreamSlotID(rawValue: 1)])
    }

    @Test func processRouteActivationOwnsInitializeWhileReadinessWaits() async throws {
        let readiness = ReadinessFlag(isReady: false)
        let sleepRecorder = ControlledReadinessSleep()
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let target = xcodeProcessTarget(processID: 27010, xcodeVersion: "27.0")
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                sleepRecorder: sleepRecorder,
                recordPollSleeps: true
            ),
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        manager.reconcileXcodeProcessTargets([target], reason: "test_activation_waiting")
        let upstream = try #require(createdUpstreams.withLockedValue { $0.first })
        _ = try await sleepRecorder.nextSleep(at: 0)

        let initializeFuture = fixture.registerInitialize(
            requestID: 1,
            sessionID: "session-joins-waiting-activation"
        )
        manager.startEagerInitializePrimary()
        #expect(timeoutScheduler.scheduledCount() == 1)

        await readiness.setReady(true)
        await sleepRecorder.resumeNext()
        await sleepRecorder.resumeNext()
        let initialize = try await upstream.nextSent(at: 0)
        #expect(methodName(from: initialize) == "initialize")
        await upstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: initialize)))
        )
        let initializedNotification = try await upstream.nextSent(at: 1)
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        _ = try await waitWithTimeout(
            "waiting for client initialize to join route activation",
            timeout: .seconds(2)
        ) {
            try await initializeFuture.get()
        }
        await manager.drainRuntimeTasksForTesting()

        let methods = await upstream.sent().compactMap { methodName(from: $0) }
        #expect(methods.filter { $0 == "initialize" }.count == 1)
        let attempt = try #require(
            manager.processControlPlane.attemptSnapshot(processID: target.processID)
        )
        #expect(attempt.phase == .initialized)
        #expect(attempt.readinessWaiterCount == 0)
    }

    @Test func processRouteActivationStartsSingleRouteBeforeGlobalInitialize() async throws {
        let firstTarget = xcodeProcessTarget(processID: 27017, xcodeVersion: "27.0")
        let secondTarget = xcodeProcessTarget(processID: 26617, xcodeVersion: "26.6")
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }

        fixture.manager.reconcileXcodeProcessTargets(
            [firstTarget, secondTarget],
            reason: "test_multiple_routes_before_initialize"
        )

        _ = try await waitWithTimeout(
            "waiting for one pre-initialize route activation",
            timeout: .seconds(2)
        ) {
            while true {
                let upstreams = createdUpstreams.withLockedValue { $0 }
                var sentCount = 0
                for upstream in upstreams {
                    sentCount += await upstream.sentCount()
                }
                if sentCount > 0 {
                    return sentCount
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        await fixture.manager.drainRuntimeTasksForTesting()
        let upstreams = createdUpstreams.withLockedValue { $0 }
        var initializeCount = 0
        for upstream in upstreams {
            let methods = await upstream.sent().compactMap { methodName(from: $0) }
            initializeCount += methods.filter { $0 == "initialize" }.count
        }
        #expect(initializeCount == 1)
    }

    @Test func processRouteActivationWarmsSecondarySlotsForLateAddedRouteAfterInitialize()
        async throws
    {
        let existingUpstream = TestUpstreamClient()
        let existingTarget = xcodeProcessTarget(processID: 26615, xcodeVersion: "26.6")
        let newTarget = xcodeProcessTarget(processID: 27015, xcodeVersion: "27.0")
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [existingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: existingTarget, upstreamIndices: [0]),
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let primary = TestUpstreamClient()
                let secondary = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(contentsOf: [primary, secondary]) }
                return [primary, secondary]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let initializeFuture = fixture.registerInitialize(requestID: 1)
        let existingInitialize = try await existingUpstream.nextSent(at: 0)
        await existingUpstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: existingInitialize)))
        )
        _ = try await initializeFuture.get()
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (existingTarget, 0, [toolDescriptor(name: "ExistingOnly")]),
            ]
        )

        manager.reconcileXcodeProcessTargets(
            [existingTarget, newTarget],
            reason: "test_late_multi_upstream_route"
        )

        let newUpstreams = createdUpstreams.withLockedValue { $0 }
        #expect(newUpstreams.count == 2)
        let primaryInitialize = try await newUpstreams[0].nextSent(at: 0)
        let secondaryInitialize = try await newUpstreams[1].nextSent(at: 0)
        #expect(methodName(from: primaryInitialize) == "initialize")
        #expect(methodName(from: secondaryInitialize) == "initialize")
    }

    @Test func processRoutingNoXcodeRemovedInitializeDoesNotSuppressNextTimeout()
        async throws
    {
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            processRoutingEnabled: true,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }

        let removedFuture = fixture.registerInitialize(
            requestID: 1,
            sessionID: "session-no-xcode-removed"
        )
        #expect(timeoutScheduler.scheduledCount() == 1)

        fixture.manager.removeSession(id: "session-no-xcode-removed")
        await #expect(throws: CancellationError.self) {
            try await removedFuture.get()
        }
        #expect(timeoutScheduler.isCancelled(at: 0))

        let nextFuture = fixture.registerInitialize(
            requestID: 2,
            sessionID: "session-no-xcode-next"
        )
        #expect(timeoutScheduler.scheduledCount() == 2)

        #expect(timeoutScheduler.fire(at: 0) == false)
        timeoutScheduler.fire(at: 1)
        await #expect(throws: TimeoutError.self) {
            try await nextFuture.get()
        }
    }

    @Test func processRoutingDebugResetRestartsPeriodicReconcileLoop() async throws {
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let discovery = RecordingXcodeTargetDiscovery(targets: [])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            clock: clocks.clock,
            processRoutingEnabled: true,
            xcodeTargetDiscovery: discovery,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        manager.start()
        #expect(
            try await waitForRecordedValue(
                discovery.calls,
                at: 0,
                description: "waiting for startup process reconcile"
            ) == 1
        )
        try await waitForSuspendedSleepers(on: clocks.timeoutClock)

        manager.debugReset()
        try await waitForSuspendedSleepers(on: clocks.timeoutClock)
        clocks.timeoutClock.advance(by: .seconds(2))

        #expect(
            try await waitForRecordedValue(
                discovery.calls,
                at: 1,
                description: "waiting for periodic process reconcile after debug reset"
            ) == 2
        )
    }




    @Test func processRoutingAddsLateXcodeProcessWithoutRestart() async throws {
        let olderUpstream = TestUpstreamClient()
        let olderTarget = xcodeProcessTarget(processID: 26610, xcodeVersion: "26.6")
        let newerTarget = xcodeProcessTarget(processID: 27010, xcodeVersion: "27.0")
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [olderUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0]),
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let olderInitializeFuture = fixture.registerInitialize(requestID: 1)
        let olderInitialize = try await olderUpstream.nextSent(at: 0)
        await olderUpstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: olderInitialize)))
        )
        _ = try await olderInitializeFuture.get()
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (olderTarget, 0, [toolDescriptor(name: "Only26")]),
            ]
        )
        manager.reconcileXcodeProcessTargets(
            [olderTarget, newerTarget],
            reason: "test_add_late_xcode"
        )

        let newerUpstream = try #require(createdUpstreams.withLockedValue { $0.first })
        let warmInitialize = try await newerUpstream.nextSent(at: 0)
        let warmUpstreamID = try extractUpstreamID(from: warmInitialize)
        await newerUpstream.yield(.message(try makeInitializeResponse(id: warmUpstreamID)))
        let initializedNotification = try await newerUpstream.nextSent(at: 1)
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        let toolsRequest = try await newerUpstream.nextSent(
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" }
        )
        await newerUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: toolsRequest),
                    tools: [
                        toolDescriptor(name: "Only27"),
                    ]
                )
            )
        )
        _ = try await manager.controlPlaneDebugMirror.waitForSnapshot {
            $0.canonicalToolsSourceUpstream == 1
        }

        let snapshot = manager.debugSnapshot()
        #expect(snapshot.processRoutes.map(\.state) == ["active", "active"])
        #expect(snapshot.processRoutes.map(\.toolsCatalogState) == ["available", "available"])
        #expect(snapshot.processRoutes.map(\.processID) == [
            newerTarget.processID,
            olderTarget.processID,
        ])
        #expect(manager.documentationCandidateProcessIDs() == Set([
            olderTarget.processID,
            newerTarget.processID,
        ]))
        #expect(Set(snapshot.processToolCatalogs.map(\.processID)) == Set([
            olderTarget.processID,
            newerTarget.processID,
        ]))
        #expect(Set(toolNames(in: manager.cachedToolsListResult() ?? .null)) == Set([
            "Only26",
            "Only27",
        ]))
    }

    @Test func processRoutingRetriesLateXcodeUntilMCPBridgeCanConnect() async throws {
        let olderUpstream = TestUpstreamClient()
        let olderTarget = xcodeProcessTarget(processID: 26611, xcodeVersion: "26.6")
        let newerTarget = xcodeProcessTarget(processID: 27011, xcodeVersion: "27.0")
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [olderUpstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0]),
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let olderInitializeFuture = fixture.registerInitialize(requestID: 1)
        let olderInitialize = try await olderUpstream.nextSent(at: 0)
        await olderUpstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: olderInitialize)))
        )
        _ = try await olderInitializeFuture.get()
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (olderTarget, 0, [toolDescriptor(name: "Only26")]),
            ]
        )
        manager.reconcileXcodeProcessTargets(
            [olderTarget, newerTarget],
            reason: "test_add_late_xcode_before_workspace"
        )

        let newerUpstream = try #require(createdUpstreams.withLockedValue { $0.first })
        _ = try await newerUpstream.nextSent(at: 0)
        #expect(timeoutScheduler.scheduledCount() == 2)
        #expect(timeoutScheduler.fire(at: 1))
        #expect(timeoutScheduler.scheduledCount() == 3)
        #expect(try await newerUpstream.nextStopCount() == 1)
        let pendingSnapshot = manager.debugSnapshot()
        #expect(pendingSnapshot.processRoutes.map(\.toolsCatalogState) == [
            "pending",
            "available",
        ])

        let replacementUpstream = try #require(createdUpstreams.withLockedValue { $0.dropFirst().first })
        #expect(timeoutScheduler.delay(at: 2)?.nanoseconds == TimeAmount.milliseconds(250).nanoseconds)
        manager.reconcileXcodeProcessTargets(
            [olderTarget, newerTarget],
            reason: "test_spurious_reconcile_before_activation_retry"
        )
        await manager.drainRuntimeTasksForTesting()
        #expect(timeoutScheduler.scheduledCount() == 3)
        #expect(await replacementUpstream.sentCount() == 0)
        #expect(timeoutScheduler.fire(at: 2))
        let retriedInitialize = try await replacementUpstream.nextSent(at: 0)
        await replacementUpstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: retriedInitialize)))
        )
        _ = try await replacementUpstream.nextSent(at: 1)
        let toolsRequest = try await replacementUpstream.nextSent(
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" }
        )
        await replacementUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: toolsRequest),
                    tools: [
                        toolDescriptor(name: "Only27"),
                    ]
                )
            )
        )
        _ = try await manager.controlPlaneDebugMirror.waitForSnapshot {
            $0.canonicalToolsSourceUpstream == 1
        }

        let snapshot = manager.debugSnapshot()
        #expect(snapshot.processRoutes.map(\.toolsCatalogState) == ["available", "available"])
        #expect(Set(snapshot.processToolCatalogs.map(\.processID)) == Set([
            olderTarget.processID,
            newerTarget.processID,
        ]))
        #expect(Set(toolNames(in: manager.cachedToolsListResult() ?? .null)) == Set([
            "Only26",
            "Only27",
        ]))
    }

    @Test func processRoutingRetriesPendingRouteAsPrimaryUntilInitializeCompletes()
        async throws
    {
        let target = xcodeProcessTarget(processID: 27012, xcodeVersion: "27.0")
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let initializeFuture = fixture.registerInitialize(requestID: 1)
        #expect(timeoutScheduler.scheduledCount() == 1)
        manager.reconcileXcodeProcessTargets([target], reason: "test_initial_route")
        let upstream = try #require(createdUpstreams.withLockedValue { $0.first })
        _ = try await upstream.nextSent(at: 0)

        #expect(timeoutScheduler.scheduledCount() == 2)
        #expect(timeoutScheduler.fire(at: 1))
        #expect(timeoutScheduler.scheduledCount() == 3)
        #expect(try await upstream.nextStopCount() == 1)
        #expect(manager.testStateSnapshot().hasInitResult == false)

        let replacement = try #require(createdUpstreams.withLockedValue { $0.dropFirst().first })
        #expect(timeoutScheduler.delay(at: 2)?.nanoseconds == TimeAmount.milliseconds(250).nanoseconds)
        #expect(timeoutScheduler.fire(at: 2))
        let retriedInitialize = try await replacement.nextSent(at: 0)
        #expect(methodName(from: retriedInitialize) == "initialize")

        await replacement.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: retriedInitialize)))
        )
        let initializedNotification = try await replacement.nextSent(at: 1)
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        await manager.drainRuntimeTasksForTesting()

        #expect(manager.testStateSnapshot().hasInitResult)
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 0)
        let responseForPendingClient = try decodeJSON(from: try await initializeFuture.get())
        #expect(responseForPendingClient["result"] != nil)
        let cachedFuture = fixture.registerInitialize(requestID: 2)
        let response = try decodeJSON(from: try await cachedFuture.get())
        #expect(response["result"] != nil)
    }

    @Test func processRoutingRetriesUnchangedRouteAfterUnavailableCooldown()
        async throws
    {
        let uptimeClock = TestUptimeClock()
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let target = xcodeProcessTarget(processID: 27013, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            nowUptimeNanoseconds: uptimeClock.now,
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        _ = try await fixture.initializePrimary(on: upstream)
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [toolDescriptor(name: "RecoveredProcessTool")]),
            ]
        )

        let exitEventIndex = upstreamEvents.count()
        await upstream.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: exitEventIndex,
            description: "waiting for process route upstream exit"
        )
        let sentCountAfterExit = await upstream.sentCount()
        #expect(manager.testStateSnapshot().hasInitResult == false)
        #expect(manager.debugSnapshot().processToolCatalogs.isEmpty)

        manager.reconcileXcodeProcessTargets([target], reason: "test_before_cooldown")
        #expect(await upstream.sentCount() == sentCountAfterExit)

        uptimeClock.advance(by: .seconds(3))
        manager.reconcileXcodeProcessTargets([target], reason: "test_after_cooldown")
        let restartedInitialize = try await upstream.nextSent(at: sentCountAfterExit)
        #expect(methodName(from: restartedInitialize) == "initialize")

        await upstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: restartedInitialize)))
        )
        let initializedNotification = try await upstream.nextSent(at: sentCountAfterExit + 1)
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        await manager.drainRuntimeTasksForTesting()

        #expect(manager.testStateSnapshot().hasInitResult)
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 0)
    }

    @Test func processRoutingRetiresCrashedPIDAndAddsRelaunchedPID() async throws {
        let oldUpstream = TestUpstreamClient()
        let oldTarget = xcodeProcessTarget(processID: 27020, xcodeVersion: "27.0")
        let relaunchedTarget = xcodeProcessTarget(processID: 27021, xcodeVersion: "27.0")
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [oldUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: oldTarget, upstreamIndices: [0]),
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let oldInitializeFuture = fixture.registerInitialize(requestID: 1)
        let oldInitialize = try await oldUpstream.nextSent(at: 0)
        await oldUpstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: oldInitialize)))
        )
        _ = try await oldInitializeFuture.get()
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (oldTarget, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        #expect(manager.recordXcodeWindowOwners(
            from: try jsonValue([
                "structuredContent": [
                    "message": "* tabIdentifier: old-tab, workspacePath: /Old/App.xcworkspace",
                ],
            ]),
            upstreamIndex: 0
        ))

        manager.reconcileXcodeProcessTargets(
            [relaunchedTarget],
            reason: "test_relaunch"
        )
        _ = try await oldUpstream.nextStopCount()

        let relaunchedUpstream = try #require(createdUpstreams.withLockedValue { $0.first })
        let initialize = try await relaunchedUpstream.nextSent(at: 0)
        let upstreamID = try extractUpstreamID(from: initialize)
        await relaunchedUpstream.yield(.message(try makeInitializeResponse(id: upstreamID)))
        _ = try await relaunchedUpstream.nextSent(at: 1)

        let snapshot = manager.debugSnapshot()
        #expect(snapshot.processRoutes.map(\.state) == ["active", "retired"])
        #expect(snapshot.processRoutes.map(\.processID) == [
            relaunchedTarget.processID,
            oldTarget.processID,
        ])
        #expect(snapshot.processToolCatalogs.isEmpty)
        #expect(await oldUpstream.stopCount() == 1)
        #expect(manager.documentationCandidateProcessIDs() == Set([relaunchedTarget.processID]))

        let oldSentCountAfterRetire = await oldUpstream.sentCount()
        manager.warmUpSecondaryUpstreams(excluding: 1)
        #expect(await oldUpstream.sentCount() == oldSentCountAfterRetire)
    }

    @Test func processRoutingRetriesRelaunchedProcessCatalogAfterWorkspaceBecomesReady()
        async throws
    {
        let olderUpstream = TestUpstreamClient()
        let oldNewerUpstream = TestUpstreamClient()
        let olderTarget = xcodeProcessTarget(processID: 26632, xcodeVersion: "26.6")
        let oldNewerTarget = xcodeProcessTarget(processID: 27032, xcodeVersion: "27.0")
        let relaunchedTarget = xcodeProcessTarget(processID: 27033, xcodeVersion: "27.0")
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [olderUpstream, oldNewerUpstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: oldNewerTarget, upstreamIndices: [1]),
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0]),
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.canonicalHandshakeState.syncCanonicalInitialize(
            try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "cached-source"],
            ]),
            sourceUpstream: 0
        )
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (olderTarget, 0, [toolDescriptor(name: "Only26")]),
                (oldNewerTarget, 1, [toolDescriptor(name: "OldOnly27")]),
            ]
        )

        manager.reconcileXcodeProcessTargets(
            [olderTarget],
            reason: "test_terminate_newer_before_relaunch"
        )
        _ = try await oldNewerUpstream.nextStopCount()
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["Only26"])

        manager.reconcileXcodeProcessTargets(
            [olderTarget, relaunchedTarget],
            reason: "test_relaunch_before_workspace_ready"
        )
        let relaunchedUpstream = try #require(createdUpstreams.withLockedValue { $0.first })
        let initialize = try await relaunchedUpstream.nextSent(at: 0)
        await relaunchedUpstream.yield(
            .message(try makeInitializeResponse(
                id: try extractUpstreamID(from: initialize),
                serverName: "cached-source"
            ))
        )
        _ = try await relaunchedUpstream.nextSent(at: 1)
        let emptyCatalogRequest = try await relaunchedUpstream.nextSent(
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" }
        )
        await relaunchedUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: emptyCatalogRequest),
                    tools: []
                )
            )
        )
        await manager.drainRuntimeTasksForTesting()

        let relaunchedHealth = try #require(
            manager.upstreamHealthManager.activeStatesSnapshot().first {
                $0.id == UpstreamSlotID(rawValue: 2)
            }?.state.healthState
        )
        guard case .healthy = relaunchedHealth else {
            Issue.record("empty process catalog should not quarantine a live relaunched route")
            return
        }
        let retryIndex = try #require((0..<timeoutScheduler.scheduledCount()).first {
            timeoutScheduler.delay(at: $0)?.nanoseconds
                == TimeAmount.milliseconds(250).nanoseconds
                && timeoutScheduler.isCancelled(at: $0) == false
        })
        #expect(timeoutScheduler.fire(at: retryIndex))
        let readyCatalogRequest = try await relaunchedUpstream.nextSent(
            startingAt: 3,
            matching: { methodName(from: $0) == "tools/list" }
        )
        await relaunchedUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: readyCatalogRequest),
                    tools: [
                        toolDescriptor(name: "Only27Relaunched"),
                    ]
                )
            )
        )
        _ = try await manager.controlPlaneDebugMirror.waitForSnapshot {
            $0.canonicalToolsSourceUpstream == 2
        }

        let snapshot = manager.debugSnapshot()
        #expect(Set(snapshot.processRoutes.map(\.processID)) == Set([
            olderTarget.processID,
            relaunchedTarget.processID,
            oldNewerTarget.processID,
        ]))
        #expect(Set(snapshot.processToolCatalogs.map(\.processID)) == Set([
            olderTarget.processID,
            relaunchedTarget.processID,
        ]))
        #expect(Set(toolNames(in: manager.cachedToolsListResult() ?? .null)) == Set([
            "Only26",
            "Only27Relaunched",
        ]))
    }

    @Test func processRoutingRetriesRelaunchedProcessCatalogAfterCatalogTimeout()
        async throws
    {
        var config = makeConfig(requestTimeout: 20)
        config.autoApproveXcodeDialog = true
        let old26Upstream = TestUpstreamClient()
        let xcode27Upstream = TestUpstreamClient()
        let old26Target = XcodeProcessTarget(
            processID: 26642,
            appPath: "/Applications/Xcode.app",
            developerDir: "/Applications/Xcode.app/Contents/Developer",
            mcpbridgePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge",
            xcodeVersion: "26.6"
        )
        let relaunched26Target = XcodeProcessTarget(
            processID: 26643,
            appPath: "/Applications/Xcode.app",
            developerDir: "/Applications/Xcode.app/Contents/Developer",
            mcpbridgePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge",
            xcodeVersion: "26.6"
        )
        let xcode27Target = XcodeProcessTarget(
            processID: 27043,
            appPath: "/Applications/Xcode_27.app",
            developerDir: "/Applications/Xcode_27.app/Contents/Developer",
            mcpbridgePath: "/Applications/Xcode_27.app/Contents/Developer/usr/bin/mcpbridge",
            xcodeVersion: "27.0"
        )
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            config: config,
            upstreams: [old26Upstream, xcode27Upstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: old26Target, upstreamIndices: [0]),
                XcodeProcessRoute(target: xcode27Target, upstreamIndices: [1]),
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.canonicalHandshakeState.syncCanonicalInitialize(
            try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "cached-source"],
            ]),
            sourceUpstream: 1
        )
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (old26Target, 0, [toolDescriptor(name: "OldOnly26")]),
                (xcode27Target, 1, [toolDescriptor(name: "Only27")]),
            ]
        )

        manager.reconcileXcodeProcessTargets(
            [xcode27Target],
            reason: "test_terminate_26_before_relaunch"
        )
        _ = try await waitWithTimeout(
            "waiting for retired 26 upstream stop",
            timeout: .seconds(2)
        ) {
            try await old26Upstream.nextStopCount()
        }
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["Only27"])

        manager.reconcileXcodeProcessTargets(
            [xcode27Target, relaunched26Target],
            reason: "test_relaunch_26_before_workspace_ready"
        )
        let firstAttempt = try #require(createdUpstreams.withLockedValue { $0.first })
        let initialize = try await waitWithTimeout(
            "waiting for relaunched 26 activation initialize",
            timeout: .seconds(2)
        ) {
            try await firstAttempt.nextSent(at: 0)
        }
        await firstAttempt.yield(
            .message(try makeInitializeResponse(
                id: try extractUpstreamID(from: initialize),
                serverName: "cached-source"
            ))
        )
        _ = try await waitWithTimeout(
            "waiting for relaunched 26 initialized notification",
            timeout: .seconds(2)
        ) {
            try await firstAttempt.nextSent(at: 1)
        }
        let staleCatalogRequest = try await waitWithTimeout(
            "waiting for relaunched 26 first tools/list",
            timeout: .seconds(2)
        ) {
            try await firstAttempt.nextSent(
                startingAt: 2,
                matching: { methodName(from: $0) == "tools/list" }
            )
        }

        let catalogTimeoutIndex = try #require((0..<timeoutScheduler.scheduledCount()).first {
            timeoutScheduler.delay(at: $0)?.nanoseconds == TimeAmount.seconds(10).nanoseconds
                && timeoutScheduler.isCancelled(at: $0) == false
        })
        let scheduledBeforeCatalogTimeout = timeoutScheduler.scheduledCount()
        #expect(timeoutScheduler.fire(at: catalogTimeoutIndex))
        #expect(try await waitWithTimeout(
            "waiting for timed-out 26 upstream stop",
            timeout: .seconds(2)
        ) {
            try await firstAttempt.nextStopCount()
        } == 1)
        #expect(manager.unavailableXcodeProcessIDs().contains(
            relaunched26Target.processID
        ) == false)
        #expect(timeoutScheduler.scheduledCount() == scheduledBeforeCatalogTimeout + 1)
        #expect(
            timeoutScheduler.delay(at: scheduledBeforeCatalogTimeout)?.nanoseconds
                == TimeAmount.milliseconds(250).nanoseconds
        )
        #expect(createdUpstreams.withLockedValue(\.count) == 2)

        await firstAttempt.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: staleCatalogRequest),
                    tools: [
                        toolDescriptor(name: "StaleOnly26"),
                    ]
                )
            )
        )
        #expect(manager.processControlPlane.catalog(
            forProcessID: relaunched26Target.processID
        ) == nil)

        #expect(timeoutScheduler.fire(at: scheduledBeforeCatalogTimeout))
        let retryAttempt = try #require(createdUpstreams.withLockedValue { $0.dropFirst().first })
        let retryInitialize = try await waitWithTimeout(
            "waiting for relaunched 26 retry initialize",
            timeout: .seconds(2)
        ) {
            try await retryAttempt.nextSent(at: 0)
        }
        await retryAttempt.yield(
            .message(try makeInitializeResponse(
                id: try extractUpstreamID(from: retryInitialize),
                serverName: "cached-source"
            ))
        )
        _ = try await waitWithTimeout(
            "waiting for relaunched 26 retry initialized notification",
            timeout: .seconds(2)
        ) {
            try await retryAttempt.nextSent(at: 1)
        }
        let readyCatalogRequest = try await waitWithTimeout(
            "waiting for relaunched 26 retry tools/list",
            timeout: .seconds(2)
        ) {
            try await retryAttempt.nextSent(
                startingAt: 2,
                matching: { methodName(from: $0) == "tools/list" }
            )
        }
        await retryAttempt.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: readyCatalogRequest),
                    tools: [
                        toolDescriptor(name: "Only26Relaunched"),
                    ]
                )
            )
        )
        _ = try await waitWithTimeout(
            "waiting for relaunched 26 catalog surface",
            timeout: .seconds(2)
        ) {
            while manager.processControlPlane.catalog(
                forProcessID: relaunched26Target.processID
            ) == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        let snapshot = manager.debugSnapshot()
        #expect(Set(snapshot.processToolCatalogs.map(\.processID)) == Set([
            xcode27Target.processID,
            relaunched26Target.processID,
        ]))
        #expect(Set(toolNames(in: manager.cachedToolsListResult() ?? .null)) == Set([
            "Only27",
            "Only26Relaunched",
        ]))
    }

    @Test func processRoutingRetiresInFlightPrimaryStopsOldSlotAndRetriesActiveRoute()
        async throws
    {
        let oldUpstream = TestUpstreamClient()
        let activeUpstream = TestUpstreamClient()
        let oldTarget = xcodeProcessTarget(processID: 27022, xcodeVersion: "27.0")
        let activeTarget = xcodeProcessTarget(processID: 26622, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [oldUpstream, activeUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: oldTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: activeTarget, upstreamIndices: [1]),
            ],
            processRoutingEnabled: true,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let initializeFuture = fixture.registerInitialize(requestID: 1)
        _ = try await oldUpstream.nextSent(at: 0)

        manager.reconcileXcodeProcessTargets([activeTarget], reason: "test_remove_inflight")
        _ = try await oldUpstream.nextStopCount()

        let retriedInitialize = try await activeUpstream.nextSent(at: 0)
        await activeUpstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: retriedInitialize)))
        )

        let response = try decodeJSON(from: try await initializeFuture.get())
        #expect(response["result"] != nil)
        #expect(await oldUpstream.stopCount() == 1)
        #expect(manager.debugSnapshot().processRoutes.map(\.state) == ["active", "retired"])
    }

    @Test func processRoutingReadinessGateSkipsRetiredPrimaryRoute()
        async throws
    {
        let oldUpstream = TestUpstreamClient()
        let oldTarget = xcodeProcessTarget(processID: 27027, xcodeVersion: "27.0")
        let readiness = ReadinessFlag(isReady: false)
        let sleepRecorder = ControlledReadinessSleep()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [oldUpstream],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                sleepRecorder: sleepRecorder,
                recordPollSleeps: true
            ),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: oldTarget, upstreamIndices: [0]),
            ],
            processRoutingEnabled: true
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        _ = try await readiness.nextCheck(at: 0)
        _ = try await waitWithTimeout(
            "waiting for primary readiness poll",
            timeout: .seconds(2)
        ) {
            try await sleepRecorder.nextSleep(at: 0)
        }

        manager.reconcileXcodeProcessTargets([], reason: "test_retire_waiting_primary")
        _ = try await oldUpstream.nextStopCount()

        await readiness.setReady(true)
        await sleepRecorder.resumeNext()
        _ = try await readiness.nextCheck(at: 1)
        await Task.yield()
        await manager.drainRuntimeTasksForTesting()

        #expect(await oldUpstream.startCount() == 0)
        #expect(await oldUpstream.sentCount() == 0)
    }

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
        manager.canonicalHandshakeState.syncCanonicalInitialize(
            cachedHandshake,
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
        await manager.drainRuntimeTasksForTesting()

        #expect(manager.testStateSnapshot().hasInitResult)
        #expect(manager.testStateSnapshot().upstreams.count == 1)
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == true)
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 1)
    }

    @Test func processRoutingRetiringCachedInitializeSourceRestartsPrimaryOverWarmRoute()
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
        manager.canonicalHandshakeState.syncCanonicalInitialize(
            cachedHandshake,
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

        let restartedInitialize = try await activeUpstream.nextSent(at: 1)
        let restartedUpstreamID = try extractUpstreamID(from: restartedInitialize)
        #expect(methodName(from: restartedInitialize) == "initialize")
        await activeUpstream.yield(
            .message(try makeInitializeResponse(id: warmUpstreamID, serverName: "stale-warm"))
        )
        await manager.drainRuntimeTasksForTesting()
        #expect(manager.testStateSnapshot().hasInitResult == false)
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == nil)

        await activeUpstream.yield(
            .message(
                try makeInitializeResponse(
                    id: restartedUpstreamID,
                    serverName: "active-primary"
                )
            )
        )
        let initializedNotification = try await activeUpstream.nextSent(at: 2)
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        await manager.drainRuntimeTasksForTesting()

        #expect(manager.testStateSnapshot().hasInitResult)
        #expect(manager.testStateSnapshot().upstreams.count == 1)
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == true)
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 1)
    }

    @Test func processRoutingRetiringNonPrimaryRouteDoesNotStealPrimaryInitialize()
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
        await manager.drainRuntimeTasksForTesting()
        #expect(await alternateUpstream.sentCount() == 0)

        await primaryUpstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: primaryInitialize)))
        )
        let response = try decodeJSON(from: try await initializeFuture.get())
        #expect(response["result"] != nil)
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 0)
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
        let initializedUpstreams = LockedRecordedValues<Int>()
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let newerTarget = xcodeProcessTarget(processID: 27100, xcodeVersion: "27.0")
        let olderTarget = xcodeProcessTarget(processID: 26600, xcodeVersion: "26.6")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: newerTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [1]),
            ],
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamInitialized: { upstreamIndex in
                    initializedUpstreams.append(upstreamIndex)
                }
            ),
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

        let recoveryUpstream = try #require(createdUpstreams.withLockedValue { $0.first })
        let recoveryInitialize = try await sentValue(
            from: recoveryUpstream,
            at: 0,
            timeout: .seconds(2)
        )
        let recoveryUpstreamID = try extractUpstreamID(from: recoveryInitialize)
        await recoveryUpstream.yield(.message(try makeInitializeResponse(id: recoveryUpstreamID)))
        _ = try await sentValue(from: recoveryUpstream, at: 1, timeout: .seconds(2))
        let expectedCandidateProcessIDs = Set([
            newerTarget.processID,
            olderTarget.processID,
        ])
        let recoveredUpstreamIndex = try await waitWithTimeout(
            "waiting for recovered primary upstream initialization"
        ) {
            try await initializedUpstreams.nextValue(at: 1)
        }
        #expect(recoveredUpstreamIndex == 0)
        #expect(manager.testStateSnapshot().upstream(id: 0)?.isInitialized == true)
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 1)
        #expect(manager.documentationCandidateProcessIDs() == expectedCandidateProcessIDs)
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
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
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
        #expect(route.upstreamID.key == "server-request-1")
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
        #expect(firstRoute.upstreamID.key == "duplicate")
        #expect(secondRoute.upstreamID.key == "duplicate")
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
        #expect(tracker.consume(clientID: second, now: now)?.upstreamID.key == "second")
        #expect(tracker.consume(clientID: third, now: now)?.upstreamID.key == "third")
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
        _ = try await secondFuture.get()

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
        #expect(route.upstreamID.key == "server-request-1")
    }

    @Test func sessionManagerRestoresPendingInitializeWhenInitializedNotificationOverloads()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        _ = try await future.get()
    }

    @Test func sessionManagerCancelsOriginalInitTimeoutBeforeRetryingInitializedNotificationOverload()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

    @Test func initializeManagerRearmsRetryTimeoutOnlyWhilePendingInitializesRemain() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let manager = InitializeManager(brokerState: CanonicalHandshakeState())
        let factoryCalls = NIOLockedValueBox(0)

        let staleCancelled = NIOLockedValueBox(false)
        _ = manager.replaceInitTimeout(
            RuntimeScheduledTimeout { staleCancelled.withLockedValue { $0 = true } }
        )
        manager.rearmInitTimeoutForRetry {
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
        _ = manager.replaceInitTimeout(
            RuntimeScheduledTimeout { replacedCancelled.withLockedValue { $0 = true } }
        )
        manager.rearmInitTimeoutForRetry {
            factoryCalls.withLockedValue { $0 += 1 }
            return RuntimeScheduledTimeout {}
        }?.cancel()
        #expect(replacedCancelled.withLockedValue { $0 })
        #expect(factoryCalls.withLockedValue { $0 } == 1)

        let keptCancelled = NIOLockedValueBox(false)
        _ = manager.replaceInitTimeout(
            RuntimeScheduledTimeout { keptCancelled.withLockedValue { $0 = true } }
        )
        #expect(manager.rearmInitTimeoutForRetry { nil } == nil)
        #expect(keptCancelled.withLockedValue { $0 } == false)

        let shutdownState = manager.beginShutdown()
        shutdownState.timeout?.cancel()
        for pending in shutdownState.pending {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }
    }

    @Test func initializeManagerAllowsOnlyOneCrossSourcePrimaryPublicationWinner() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let result: JSONValue = .object([
            "protocolVersion": .string(MCP.ProtocolVersion.current)
        ])
        let first = try #require(manager.preparePrimaryInitializeSuccess(
            upstreamIndex: 0,
            upstreamID: 100,
            allowsPromotion: true
        ))
        #expect(manager.preparePrimaryInitializeSuccess(
            upstreamIndex: 1,
            upstreamID: 101,
            allowsPromotion: true
        ) == nil)

        let completion = try #require(manager.finishPrimaryInitializeSuccess(
            first.lease,
            commit: {
                canonical.publishCanonicalInitialize(
                    result,
                    lease: first.publicationLease
                ) != nil
            }
        ))
        #expect(completion.pending.count == 1)
        #expect(canonical.initializeSourceUpstream() == 0)
        #expect(canonical.initializeResult() == result)
        #expect(canonical.prepareInitializePublication(sourceUpstream: 1) == nil)
        for pending in completion.pending {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }
    }

    @Test func sessionManagerRunsSecondaryWarmupAfterRecoveredInitializedNotification()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

    @Test func sessionManagerBuffersUnmappedNotificationsAfterInitializeUntilNotificationClientConnects()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        manager.markNotificationClientConnected(sessionID: sessionID)
        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        #expect(session.router.drainBufferedNotifications().isEmpty)
    }

    @Test func sessionManagerRoutesUnmappedNotificationsDuringInitializeHandshake() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

    @Test func sessionManagerBuffersUnmappedNotificationsForCachedInitializeSessionsUntilClientConnects()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        manager.markNotificationClientConnected(sessionID: sessionID)
        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        #expect(session.router.drainBufferedNotifications().isEmpty)
    }

    @Test func sessionManagerDoesNotRecreateRemovedSessionWhenInitializeCompletes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        let context = manager.sessionRegistry.removeSession(id: sessionID)
        context?.notificationHub.closeAll()
        let pendingInitializes = manager.initializeManager.removePendingInitializes(
            sessionID: sessionID
        )
        pendingInitializes.timeout?.cancel()
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        manager.initializeManager.reopenPrimaryInitializeForRetry()
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: false)
        let sleepRecorder = ControlledReadinessSleep()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                sleepRecorder: sleepRecorder,
                recordPollSleeps: true
            ),
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
        _ = try await sleepRecorder.nextSleep(at: 0)

        let context = manager.sessionRegistry.removeSession(id: removedSessionID)
        context?.notificationHub.closeAll()
        let pendingInitializes = manager.initializeManager.removePendingInitializes(
            sessionID: removedSessionID
        )
        pendingInitializes.timeout?.cancel()
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
        await sleepRecorder.resumeNext()
        let replacementInitialize = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let replacementID = try extractUpstreamID(from: replacementInitialize)
        await upstream.yield(.message(try makeInitializeResponse(id: replacementID)))
        _ = try await replacementFuture.get()
    }

    @Test func sessionManagerRoutesUnmappedNotificationsToCachedInitializeSessionsUntilClientConnects()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        manager.markNotificationClientConnected(sessionID: sessionID)
        manager.routeUpstreamMessage(notification0, upstreamIndex: 0)
        manager.routeUpstreamMessage(notification1, upstreamIndex: 1)
        #expect(session.router.drainBufferedNotifications().isEmpty)
    }

    @Test func sessionManagerTimeoutResetsInitState() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

    @Test func sessionManagerInitializeErrorDoesNotClearRecreatedSessionInitializeRoutingState()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        let firstTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let firstRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: firstRequest) == "tools/list")
        try await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .seconds(5)
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await firstTask.value
        }

        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 4, timeoutSeconds: 2)
        let secondRequest = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        #expect(methodName(from: secondRequest) == "tools/list")
        try await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .seconds(5)
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await secondTask.value
        }
    }

    @Test func sessionManagerSharedToolsListReusesInFlightPrewarm() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        manager.refreshToolsListIfNeeded()
        let prewarmRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: prewarmRequest) == "tools/list")

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
        #expect(await upstream.sentCount() == 3)

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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let uptimeClock = TestUptimeClock()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: uptimeClock.now
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

        uptimeClock.advance(by: .nanoseconds(120_000_001))

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }

        try await waitForSentCount(upstream, count: 4, timeoutSeconds: 2)
        let secondRequest = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        #expect(methodName(from: secondRequest) == "tools/list")

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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let uptimeClock = TestUptimeClock()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: uptimeClock.now
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
        _ = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))

        uptimeClock.advance(by: .nanoseconds(120_000_001))

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))

        uptimeClock.advance(by: .nanoseconds(120_000_001))

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
        #expect(await upstream.sentCount() == 4)

        firstTask.cancel()
        secondTask.cancel()
        thirdTask.cancel()
        _ = try? await firstTask.value
        _ = try? await secondTask.value
        _ = try? await thirdTask.value
    }

    @Test func sessionManagerPromotedToolsListCancellationRemovesMigratedWaiter() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let uptimeClock = TestUptimeClock()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: uptimeClock.now
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

        uptimeClock.advance(by: .nanoseconds(120_000_001))

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))

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
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func sessionManagerSharedToolsListTimeoutCancelsStalePrewarmLoad() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.prewarmToolsList = true
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

        manager.refreshToolsListIfNeeded()
        let prewarmRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: prewarmRequest) == "tools/list")

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
        try await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .seconds(5),
            suspendedSleepers: 2
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await firstTask.value
        }
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 4, timeoutSeconds: 2)
        let secondRequest = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        #expect(methodName(from: secondRequest) == "tools/list")
        try await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .seconds(5)
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await secondTask.value
        }
    }

    @Test func sessionManagerLateToolsListResponseDoesNotReseedCanonicalCatalog() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
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
                        toolDescriptor(name: "XcodeListWindows"),
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        try await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .seconds(5)
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await firstTask.value
        }

        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)

        let secondTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 4, timeoutSeconds: 2)
        let secondRequest = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        #expect(methodName(from: secondRequest) == "tools/call")
        try await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .seconds(5)
        )
        await #expect(throws: TimeoutError.self) {
            _ = try await secondTask.value
        }
    }

    @Test func sessionManagerToolsListWaitsForCompleteCatalogDespiteKnownOwner()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let olderUpstream = TestUpstreamClient()
        let latestUpstream = TestUpstreamClient()
        let latestTarget = xcodeProcessTarget(processID: 80422, xcodeVersion: "27.0")
        let olderTarget = xcodeProcessTarget(processID: 66333, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
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
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-latest, workspacePath: /tmp/Latest.xcworkspace",
                    ],
                ]),
                upstreamIndex: 1
            )
        )

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-available-owner",
                requestTimeoutOverride: .seconds(5)
            )
        }

        let latestRequest = try await sentValue(from: latestUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: latestRequest) == "tools/list")
        let olderRequest = try await sentValue(from: olderUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: olderRequest) == "tools/list")
        await latestUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: latestRequest),
                    tools: [
                        toolDescriptor(name: "SharedTool", description: "from-27"),
                        toolDescriptor(name: "Only27", description: "new-only"),
                    ],
                )
            )
        )
        #expect(manager.cachedToolsListResult() == nil)
        await olderUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: olderRequest),
                    tools: [
                        toolDescriptor(name: "Only26", description: "old-only"),
                    ]
                )
            )
        )

        let result = try await waitWithTimeout("waiting for process-routed tools/list") {
            try await task.value
        }
        #expect(Set(toolNames(in: result)) == Set(["Only26", "Only27", "SharedTool"]))
        #expect(toolDescription(in: result, name: "SharedTool") == "from-27")
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == 1)
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set(["Only26", "Only27", "SharedTool"])
        )
        #expect(Set(toolNames(in: manager.cachedToolsListResult(forUpstreamIndex: 1) ?? .null)) == Set([
            "Only27",
            "SharedTool",
        ]))
        #expect(await olderUpstream.sentCount() == 1)
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
    }

    @Test func sessionManagerToolsListUnionsFallbackCatalogAfterOwnerIsLearned()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
                        toolDescriptor(name: "FallbackOnly"),
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
                        "message": "* tabIdentifier: tab-owner-late, workspacePath: /tmp/LateOwner.xcworkspace",
                    ],
                ]),
                upstreamIndex: 1
            )
        )
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["FallbackOnly"])
        manager.markUpstreamInitialized(upstreamIndex: 1)
        #expect(manager.cachedToolsListResult() == nil)

        let ownerTask = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-after-owner",
                requestTimeoutOverride: .seconds(5)
            )
        }
        let ownerRequest = try await sentValue(from: ownerUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: ownerRequest) == "tools/list")
        await ownerUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: ownerRequest),
                    tools: [
                        toolDescriptor(name: "OwnerOnly"),
                    ]
                )
            )
        )
        let ownerResult = try await waitWithTimeout("waiting for owner tools/list") {
            try await ownerTask.value
        }
        #expect(Set(toolNames(in: ownerResult)) == Set(["FallbackOnly", "OwnerOnly"]))
        #expect(Set(toolNames(in: manager.cachedToolsListResult() ?? .null)) == Set([
            "FallbackOnly",
            "OwnerOnly",
        ]))
        #expect(await fallbackUpstream.sentCount() == 1)
        #expect(await ownerUpstream.sentCount() == 1)
    }

    @Test func sessionManagerToolsListWaitsForStalledRouteBeforePublishingCompleteCatalog()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let olderUpstream = TestUpstreamClient()
        let newerUpstream = TestUpstreamClient()
        let olderTarget = xcodeProcessTarget(processID: 66338, xcodeVersion: "26.6")
        let newerTarget = xcodeProcessTarget(processID: 80425, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [olderUpstream, newerUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: newerTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-later-usable-route",
                requestTimeoutOverride: .seconds(5)
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
                    ]
                )
            )
        )
        #expect(manager.cachedToolsListResult() == nil)
        #expect(await olderUpstream.sentCount() == 1)
        #expect(await newerUpstream.sentCount() == 1)
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == nil)

        await olderUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: olderRequest),
                    tools: [
                        toolDescriptor(name: "OlderRouteOnly"),
                    ]
                )
            )
        )
        let result = try await waitWithTimeout("waiting for complete process catalog") {
            try await task.value
        }
        #expect(Set(toolNames(in: result)) == Set(["NewerRouteOnly", "OlderRouteOnly"]))
        #expect(Set(toolNames(in: manager.cachedToolsListResult() ?? .null)) == Set(["NewerRouteOnly", "OlderRouteOnly"]))
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
    }


    @Test func sessionManagerToolsListCompletesCachedProcessCatalogWithFreshRoutes()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [(olderTarget, 0, [toolDescriptor(name: "OlderRouteOnly")])]
        )

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-cached-union",
                requestTimeoutOverride: .seconds(5)
            )
        }

        let middleRequest = try await sentValue(from: middleUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: middleRequest) == "tools/list")
        let latestRequest = try await sentValue(from: latestUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: latestRequest) == "tools/list")
        await latestUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: latestRequest),
                    tools: [
                        toolDescriptor(name: "LatestRouteOnly"),
                    ]
                )
            )
        )
        await middleUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: middleRequest),
                    tools: [
                        toolDescriptor(name: "MiddleRouteOnly"),
                    ]
                )
            )
        )

        let result = try await waitWithTimeout("waiting for cached process catalog surface") {
            try await task.value
        }

        #expect(Set(toolNames(in: result)) == Set([
            "LatestRouteOnly",
            "MiddleRouteOnly",
            "OlderRouteOnly",
        ]))
        #expect(manager.cachedToolsListResult() != nil)
        #expect(await olderUpstream.sentCount() == 0)
        #expect(await middleUpstream.sentCount() == 1)
        #expect(await latestUpstream.sentCount() == 1)
        #expect(Set(toolNames(in: manager.cachedToolsListResult() ?? .null)) == Set([
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (olderTarget, 0, [toolDescriptor(name: "OlderRouteOnly")]),
            ]
        )

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-cached-fresh-fails",
                requestTimeoutOverride: .seconds(5)
            )
        }

        let latestRequest = try await sentValue(from: latestUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: latestRequest) == "tools/list")
        await latestUpstream.yield(
            .message(
                try JSONSerialization.data(
                    withJSONObject: [
                        "jsonrpc": "2.0",
                        "id": try extractUpstreamID(from: latestRequest),
                        "result": [
                            "tools": "invalid",
                        ],
                    ],
                    options: []
                )
            )
        )

        let result = try await waitWithTimeout("waiting for cached process catalog fallback") {
            try await task.value
        }

        #expect(toolNames(in: result) == ["OlderRouteOnly"])
        #expect(manager.cachedToolsListResult() == nil)
        #expect(toolNames(in: manager.cachedToolsListResult(forUpstreamIndex: 0) ?? .null) == ["OlderRouteOnly"])
        #expect(await olderUpstream.sentCount() == 0)
        #expect(await latestUpstream.sentCount() == 1)
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == nil)
        #expect(manager.debugSnapshot().processToolCatalogs.map(\.processID) == [
            olderTarget.processID,
        ])
    }

    @Test func sessionManagerRetriesPendingProcessCatalogAfterQuarantinedRouteRecovers()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 80429, xcodeVersion: "27.0")
        let uptimeClock = TestUptimeClock()
        let toolsListRefreshes = LockedRecordedValues<(Int, Bool)>()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: uptimeClock.now,
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
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
        manager.canonicalHandshakeState.syncCanonicalInitialize(
            try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "cached-source"],
            ]),
            sourceUpstream: 0
        )
        manager.markToolsListRefreshFailed(
            upstreamIndex: 0,
            nowUptimeNs: uptimeClock.now(),
            reason: "test_catalog_failure"
        )
        _ = manager.beginProcessRouteAttachingForTesting(
            processID: target.processID,
            upstreamIndex: 0,
            nowUptimeNs: uptimeClock.now()
        )
        manager.refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "test_before_quarantine_expired",
            processIDs: [target.processID]
        )
        #expect(await upstream.sentCount() == 0)

        uptimeClock.advance(by: .seconds(31))
        manager.refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "test_after_quarantine_expired",
            processIDs: [target.processID]
        )
        let probeRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: probeRequest) == "tools/list")
        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: probeRequest),
                    tools: []
                )
            )
        )

        let catalogRequest = try await sentValue(
            from: upstream,
            startingAt: 1,
            matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2),
            description: "waiting for pending process catalog refresh after health probe"
        )
        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: catalogRequest),
                    tools: [
                        toolDescriptor(name: "RecoveredRouteOnly"),
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
        #expect(manager.processControlPlane.pendingCatalogProcessIDs(
                nowUptimeNs: manager.nowUptimeNanoseconds()
            ).isEmpty)
        #expect(manager.debugSnapshot().processToolCatalogs.map(\.processID) == [target.processID])
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["RecoveredRouteOnly"])
    }

    @Test func sessionManagerToolsListWaitsWhileCachedProcessCatalogIsIncomplete()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let olderUpstream = TestUpstreamClient()
        let latestUpstream = TestUpstreamClient()
        let olderTarget = xcodeProcessTarget(processID: 66341, xcodeVersion: "26.6")
        let latestTarget = xcodeProcessTarget(processID: 80428, xcodeVersion: "27.0")
        let toolsListRefreshes = NIOLockedValueBox<[String]>([])
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (olderTarget, 0, [toolDescriptor(name: "OlderRouteOnly")]),
            ]
        )

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-cached-fresh-cancelled",
                requestTimeoutOverride: .seconds(5)
            )
        }

        let latestRequest = try await sentValue(from: latestUpstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: latestRequest) == "tools/list")
        #expect(await olderUpstream.sentCount() == 0)
        #expect(await latestUpstream.sentCount() == 1)
        #expect(manager.cachedToolsListResult() == nil)
        #expect(manager.debugSnapshot().processToolCatalogs.map(\.processID) == [
            olderTarget.processID,
        ])

        await latestUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: latestRequest),
                    tools: [
                        toolDescriptor(name: "LatestRouteOnly"),
                    ]
                )
            )
        )
        let result = try await waitWithTimeout("waiting for complete process catalog") {
            try await task.value
        }
        #expect(Set(toolNames(in: result)) == Set(["LatestRouteOnly", "OlderRouteOnly"]))
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set(["LatestRouteOnly", "OlderRouteOnly"])
        )
        #expect(toolsListRefreshes.withLockedValue { $0 } == ["1:true"])
    }

    @Test func sessionManagerEmptyProcessCatalogPreservesExistingCatalogButInvalidatesIncompleteSurface()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        manager.canonicalHandshakeState.syncCanonicalInitialize(
            try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "cached-source"],
            ]),
            sourceUpstream: 0
        )
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (existingTarget, 0, [toolDescriptor(name: "ExistingOnlyTool")]),
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
              case .healthy = upstream.healthState else {
            Issue.record("empty process catalog should leave upstream health usable")
            return
        }
        #expect(await existingUpstream.sentCount() == 0)
    }

    @Test func sessionManagerRecordsProcessCatalogBeforeDisabledToolFiltering()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
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
                        toolDescriptor(name: "HiddenOnlyTool"),
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.canonicalHandshakeState.syncCanonicalInitialize(
            try jsonValue([
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
              case .healthy = upstream.healthState else {
            Issue.record("empty process catalog should not quarantine the upstream")
            return
        }
    }

    @Test func sessionManagerCancelsCatalogRetryButPreservesMissingRouteOnDebugReset()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.canonicalHandshakeState.syncCanonicalInitialize(
            try jsonValue([
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.canonicalHandshakeState.syncCanonicalInitialize(
            try jsonValue([
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
            guard case .accepted(_, let completion) = manager.processControlPlane.completeCatalog(
                .unusable,
                lease: lease,
                nowUptimeNanoseconds: manager.nowUptimeNanoseconds()
            ) else {
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
                        toolDescriptor(name: "RecoveredAfterStaleRetry"),
                    ]
                )
            )
        )
        await manager.drainRuntimeTasksForTesting()
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == [
            "RecoveredAfterStaleRetry",
        ])
    }

    @Test func sessionManagerToolsListSkipsUnavailableProcessRouteCatalog() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
                                ],
                            ],
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

    @Test func processRouteCatalogCooldownSurvivesRouteAvailabilitySuccess() async throws {
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 80423, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
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
                        toolDescriptor(name: "SiblingTool"),
                    ]
                )
            )
        )

        let result = try await waitWithTimeout("waiting for sibling process tools/list") {
            try await task.value
        }
        #expect(toolNames(in: result) == ["SiblingTool"])
        #expect(manager.debugSnapshot().processToolCatalogs.map(\.processID) == [
            target.processID,
        ])
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == 1)
        #expect(manager.documentationCandidateProcessIDs() == Set([target.processID]))
    }

    @Test func sessionManagerToolsListSiblingRetryUsesSharedDeadline()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
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
        try await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .milliseconds(100)
        )

        do {
            _ = try await waitWithTimeout("waiting for shared deadline timeout") {
                try await task.value
            }
            Issue.record("expected tools/list to fail when sibling deadline is exhausted")
        } catch {
            #expect(error is TimeoutError)
        }
        #expect(await siblingUpstream.sentCount() == 0)
    }

    @Test func sessionManagerProcessToolsListPropagatesCancellation() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        _ = try await upstream0.nextSent {
            methodName(from: $0) == "tools/list"
        }
        _ = try await upstream1.nextSent {
            methodName(from: $0) == "tools/list"
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await upstream0.sentCount() == 1)
        #expect(await upstream1.sentCount() == 1)
    }







    @Test func sessionManagerUnavailableUncatalogedRouteRecomputesRemainingProcessSurface()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.canonicalHandshakeState.syncCanonicalInitialize(
            try jsonValue([
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

        manager.refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "test_overlap_background_refresh",
            processIDs: [target.processID]
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
                        toolDescriptor(name: "SharedOverlapTool"),
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
        #expect(manager.debugSnapshot().processToolCatalogs.map(\.processID) == [
            target.processID,
        ])
    }

    @Test func sessionManagerToolsListClearsSiblingCanonicalCatalogWhenProcessRouteUnavailable()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 80431, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        await manager.drainRuntimeTasksForTesting()
        #expect(await retiredUpstream.stopCount() == 1)

        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == [
            "RemainingOnlyTool",
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 80445, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let sessionID = "session-process-catalog-retire-notification-count"
        let session = manager.session(id: sessionID)
        manager.sessionRegistry.markInitialized(
            id: sessionID,
            negotiatedProtocolVersion: MCP.ProtocolVersion.current,
            buffersUnmappedNotificationsUntilClientConnects: true
        )
        _ = session.router.drainBufferedNotifications()
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [toolDescriptor(name: "RetiredOnlyTool")]),
            ]
        )
        _ = session.router.drainBufferedNotifications()
        let exposureBeforeRetire = manager.processControlPlane.currentExposureEpoch()
        let catalogEpochBeforeRetire = manager.processControlPlane.currentCatalogEpoch()

        manager.reconcileXcodeProcessTargets(
            [],
            reason: "test_cataloged_process_route_retired_once"
        )
        await manager.drainRuntimeTasksForTesting()
        #expect(await upstream.stopCount() == 1)

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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 80446, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let sessionID = "session-process-catalog-duplicate-unavailable-after-clear"
        let session = manager.session(id: sessionID)
        manager.sessionRegistry.markInitialized(
            id: sessionID,
            negotiatedProtocolVersion: MCP.ProtocolVersion.current,
            buffersUnmappedNotificationsUntilClientConnects: true
        )
        _ = session.router.drainBufferedNotifications()
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [toolDescriptor(name: "ClearedOnlyTool")]),
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 80447, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let sessionID = "session-process-catalog-duplicate-unavailable"
        let session = manager.session(id: sessionID)
        manager.sessionRegistry.markInitialized(
            id: sessionID,
            negotiatedProtocolVersion: MCP.ProtocolVersion.current,
            buffersUnmappedNotificationsUntilClientConnects: true
        )
        _ = session.router.drainBufferedNotifications()
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [toolDescriptor(name: "UnavailableOnlyTool")]),
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

    @Test func sessionManagerToolsListResyncsRemainingCatalogWhenUncatalogedProcessRouteRetires()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let uncatalogedUpstream = TestUpstreamClient()
        let remainingUpstream = TestUpstreamClient()
        let uncatalogedTarget = xcodeProcessTarget(processID: 80435, xcodeVersion: "27.0")
        let remainingTarget = xcodeProcessTarget(processID: 66339, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [uncatalogedUpstream, remainingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: uncatalogedTarget, upstreamIndices: [0]),
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
                (remainingTarget, 1, [toolDescriptor(name: "RemainingOnlyTool")]),
            ]
        )
        #expect(manager.cachedToolsListResult() == nil)

        manager.reconcileXcodeProcessTargets(
            [remainingTarget],
            reason: "test_uncataloged_process_route_retired"
        )
        await manager.drainRuntimeTasksForTesting()
        #expect(await uncatalogedUpstream.stopCount() == 1)

        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == [
            "RemainingOnlyTool",
        ])
        #expect(
            manager.debugSnapshot().processToolCatalogs.map(\.processID)
                == [remainingTarget.processID]
        )
        #expect(manager.processControlPlane.canonicalSourceUpstream() == 1)
    }


    @Test func sessionManagerToolsListResyncsSurfaceAndRetainsCatalogWhenUpstreamStateClears()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let clearedTarget = xcodeProcessTarget(processID: 80434, xcodeVersion: "27.0")
        let remainingTarget = xcodeProcessTarget(processID: 66338, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: clearedTarget, upstreamIndices: [0]),
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
                (clearedTarget, 0, [toolDescriptor(name: "ClearedOnlyTool")]),
                (remainingTarget, 1, [toolDescriptor(name: "RemainingOnlyTool")]),
            ]
        )
        #expect(manager.cachedToolsListResult() != nil)

        #expect(manager.clearUpstreamState(upstreamIndex: 0))

        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == [
            "RemainingOnlyTool",
        ])
        #expect(
            manager.debugSnapshot().processToolCatalogs.map(\.processID)
                == [clearedTarget.processID, remainingTarget.processID]
        )
        #expect(manager.processControlPlane.canonicalSourceUpstream() == 1)
    }

    @Test func sessionManagerToolsListDoesNotFallbackWhenAllProcessRoutesUnavailable()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 80426, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 66335, xcodeVersion: "26.6")
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
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_unavailable"
        )
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 1,
            reason: "test_unavailable"
        )

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            _ = try await manager.sharedToolsList(
                sessionID: "session-process-catalog-all-unavailable",
                requestTimeoutOverride: .seconds(5)
            )
        }
        #expect(await upstream0.sentCount() == 0)
        #expect(await upstream1.sentCount() == 0)
        #expect(manager.cachedToolsListResult() == nil)
    }

    @Test func sessionManagerToolsListSkipsColdProcessRouteCatalog() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let coldUpstream = TestUpstreamClient()
        let warmUpstream = TestUpstreamClient()
        let coldTarget = xcodeProcessTarget(processID: 80423, xcodeVersion: "27.0")
        let warmTarget = xcodeProcessTarget(processID: 66334, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [coldUpstream, warmUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: coldTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: warmTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-skip-cold",
                requestTimeoutOverride: .seconds(5)
            )
        }

        let warmRequest = try await warmUpstream.nextSent {
            methodName(from: $0) == "tools/list"
        }
        await warmUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: warmRequest),
                    tools: [
                        toolDescriptor(name: "WarmOnlyTool"),
                    ]
                )
            )
        )

        let result = try await waitWithTimeout("waiting for warm process tools/list") {
            try await task.value
        }
        #expect(toolNames(in: result) == ["WarmOnlyTool"])
        #expect(await coldUpstream.sentCount() == 0)
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["WarmOnlyTool"])
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == 1)
        #expect(manager.debugSnapshot().processToolCatalogs.map(\.processID) == [warmTarget.processID])

        manager.markUpstreamInitialized(upstreamIndex: 0)
        #expect(manager.cachedToolsListResult() == nil)
        let completeTask = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-after-cold-warms",
                requestTimeoutOverride: .seconds(5)
            )
        }
        let coldRequest = try await sentValue(from: coldUpstream, at: 0, timeout: .seconds(2))
        await coldUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: coldRequest),
                    tools: [toolDescriptor(name: "ColdOnlyTool")]
                )
            )
        )
        let complete = try await waitWithTimeout("waiting for newly warm process catalog") {
            try await completeTask.value
        }
        #expect(Set(toolNames(in: complete)) == Set(["ColdOnlyTool", "WarmOnlyTool"]))
        #expect(await coldUpstream.sentCount() == 1)
        #expect(await warmUpstream.sentCount() == 1)
    }


    @Test func documentationCandidatesIgnoreWorkspaceOwnersAndKeepUsableProcesses()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let badTarget = xcodeProcessTarget(processID: 80422, xcodeVersion: "27.0")
        let goodTarget = xcodeProcessTarget(processID: 66333, xcodeVersion: "26.6")
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

        let result = try jsonValue([
            "structuredContent": [
                "message": "* tabIdentifier: tab-good, workspacePath: /tmp/Good.xcworkspace",
            ],
        ])
        #expect(manager.recordXcodeWindowOwners(from: result, upstreamIndex: 1))

        #expect(
            manager.documentationCandidateProcessIDs() == Set([
                badTarget.processID,
                goodTarget.processID,
            ])
        )
    }

    @Test func runtimeDocumentationDiscoveryPreservesDiscoveryOrderExceptUnavailableProcessIDs()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let routeFirst = xcodeProcessTarget(processID: 80430, xcodeVersion: "26.6")
        let unavailable = xcodeProcessTarget(processID: 80431, xcodeVersion: "27.0")
        let routeLast = xcodeProcessTarget(processID: 80432, xcodeVersion: "25.4")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: routeFirst, upstreamIndices: [0]),
                XcodeProcessRoute(target: unavailable, upstreamIndices: [1]),
                XcodeProcessRoute(target: routeLast, upstreamIndices: [2]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        manager.markUpstreamInitialized(upstreamIndex: 2)
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-route-last, workspacePath: /tmp/RouteLast.xcworkspace",
                    ],
                ]),
                upstreamIndex: 2
            )
        )
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 1,
            reason: "test_discovery_filter"
        )

        let runtimeBox = WeakRuntimeCoordinatorBox()
        runtimeBox.value = manager
        let discovery = RuntimeDocumentationTargetDiscovery(
            base: StubXcodeTargetDiscovery(targets: [routeLast, unavailable, routeFirst]),
            runtimeBox: runtimeBox
        )

        #expect(discovery.runningXcodeTargets().map(\.processID) == [
            routeLast.processID,
            routeFirst.processID,
        ])
    }

    @Test func documentationCandidatesSkipUnavailableWorkspaceOwner() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let badTarget = xcodeProcessTarget(processID: 80422, xcodeVersion: "27.0")
        let goodTarget = xcodeProcessTarget(processID: 66333, xcodeVersion: "26.6")
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

        let result = try jsonValue([
            "structuredContent": [
                "message": "* tabIdentifier: tab-good, workspacePath: /tmp/Good.xcworkspace",
            ],
        ])
        #expect(manager.recordXcodeWindowOwners(from: result, upstreamIndex: 1))
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 1,
            reason: "test_owner_terminated"
        )

        #expect(manager.documentationCandidateProcessIDs() == Set([badTarget.processID]))
    }

    @Test func runtimeDocumentationDiscoveryKeepsLiveTargetsOutsideUsableRouteCandidates()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let ownerTarget = xcodeProcessTarget(processID: 80428, xcodeVersion: "27.0")
        let fallbackTarget = xcodeProcessTarget(processID: 80429, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: ownerTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: fallbackTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let result = try jsonValue([
            "structuredContent": [
                "message": "* tabIdentifier: tab-owner, workspacePath: /tmp/Owner.xcworkspace",
            ],
        ])
        #expect(manager.recordXcodeWindowOwners(from: result, upstreamIndex: 0))

        let runtimeBox = WeakRuntimeCoordinatorBox()
        runtimeBox.value = manager
        let discovery = RuntimeDocumentationTargetDiscovery(
            base: StubXcodeTargetDiscovery(targets: [fallbackTarget, ownerTarget]),
            runtimeBox: runtimeBox
        )

        #expect(discovery.runningXcodeTargets().map(\.processID) == [
            fallbackTarget.processID,
            ownerTarget.processID,
        ])

        manager.markUpstreamInitialized(upstreamIndex: 1)

        #expect(discovery.runningXcodeTargets().map(\.processID) == [
            fallbackTarget.processID,
            ownerTarget.processID,
        ])
    }

    @Test func runtimeDocumentationDiscoveryKeepsLiveTargetsOutsideRuntimeRoutes()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let staleTarget = xcodeProcessTarget(processID: 80424, xcodeVersion: "27.0")
        let relaunchedTarget = xcodeProcessTarget(processID: 80425, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: staleTarget, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_relaunch"
        )

        let runtimeBox = WeakRuntimeCoordinatorBox()
        runtimeBox.value = manager
        let discovery = RuntimeDocumentationTargetDiscovery(
            base: StubXcodeTargetDiscovery(targets: [relaunchedTarget]),
            runtimeBox: runtimeBox
        )

        #expect(discovery.runningXcodeTargets().map(\.processID) == [
            relaunchedTarget.processID,
        ])
    }

    @Test func runtimeDocumentationDiscoveryDoesNotReaddUnavailableRuntimeRouteTargets()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let unavailableTarget = xcodeProcessTarget(processID: 80426, xcodeVersion: "27.0")
        let outsideTarget = xcodeProcessTarget(processID: 80427, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: unavailableTarget, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_route_unavailable"
        )

        let runtimeBox = WeakRuntimeCoordinatorBox()
        runtimeBox.value = manager
        let discovery = RuntimeDocumentationTargetDiscovery(
            base: StubXcodeTargetDiscovery(targets: [unavailableTarget, outsideTarget]),
            runtimeBox: runtimeBox
        )

        #expect(discovery.runningXcodeTargets().map(\.processID) == [
            outsideTarget.processID,
        ])
    }

    @Test func sessionManagerFansOutXcodeListWindowsAcrossProcessRoutesAndCachesOwners()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 510, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 511, xcodeVersion: "26.6")
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        func nextWindowsRequest(
            from upstream: TestUpstreamClient,
            startingAt startIndex: Int
        ) async throws -> Data {
            for index in startIndex..<(startIndex + 3) {
                let request = try await sentValue(
                    from: upstream,
                    at: index,
                    timeout: .seconds(2)
                )
                if methodName(from: request) == "tools/list" {
                    await upstream.yield(
                        .message(
                            try makeDocumentationToolsListResponse(
                                id: try extractUpstreamID(from: request),
                                tools: [toolDescriptor(name: "XcodeRead")]
                            )
                        )
                    )
                    continue
                }
                return request
            }
            throw TimeoutError()
        }

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await nextWindowsRequest(from: upstream0, startingAt: 0)
        #expect(methodName(from: request0) == "tools/call")
        #expect(toolCallName(from: request0) == "XcodeListWindows")
        let message0 = "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"

        let request1 = try await nextWindowsRequest(from: upstream1, startingAt: 0)
        #expect(methodName(from: request1) == "tools/call")
        #expect(toolCallName(from: request1) == "XcodeListWindows")
        let message1 = "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: message0
                )
            )
        )
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: message1
                )
            )
        )

        let result = try await task.value
        guard case .object(let resultObject) = result,
              case .object(let structuredContent)? = resultObject["structuredContent"],
              case .string(let mergedMessage)? = structuredContent["message"] else {
            Issue.record("expected merged XcodeListWindows structuredContent")
            return
        }
        #expect(mergedMessage.components(separatedBy: "xcode-mcpkit:").count == 3)
        #expect(mergedMessage.contains("/Work/A.xcworkspace"))
        #expect(mergedMessage.contains("/Work/B.xcworkspace"))

        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target0,
                    0,
                    [
                        ownerBoundToolDescriptor(name: "XcodeListNavigatorIssues"),
                        ownerBoundToolDescriptor(name: "XcodeSomeWorkspaceScopedTool"),
                        toolDescriptor(name: "XcodeRead"),
                    ]
                ),
                (
                    target1,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "XcodeListNavigatorIssues"),
                        ownerBoundToolDescriptor(name: "XcodeSomeWorkspaceScopedTool"),
                        toolDescriptor(name: "XcodeRead"),
                    ]
                ),
            ]
        )

        let tabARequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeListNavigatorIssues",
                "arguments": [
                    "tabIdentifier": "tab-a",
                ],
            ],
        ]
        let tabBRequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeListNavigatorIssues",
                "arguments": [
                    "tabIdentifier": "tab-b",
                ],
            ],
        ]
        let workspaceBRequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeSomeWorkspaceScopedTool",
                "arguments": [
                    "workspacePath": "/Work/B.xcworkspace",
                ],
            ],
        ]
        let genericTabARequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeRead",
                "arguments": [
                    "tabIdentifier": "tab-a",
                ],
            ],
        ]
        let genericWorkspaceBRequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeRead",
                "arguments": [
                    "workspacePath": "/Work/B.xcworkspace",
                ],
            ],
        ]
        #expect(manager.preferredUpstreamIndex(for: tabARequest) == 0)
        #expect(manager.preferredUpstreamIndex(for: tabBRequest) == 1)
        #expect(manager.preferredUpstreamIndex(for: workspaceBRequest) == 1)
        #expect(manager.preferredUpstreamIndex(for: genericTabARequest) == nil)
        #expect(manager.preferredUpstreamIndex(for: genericWorkspaceBRequest) == nil)
        await manager.shutdown()
    }

    @Test func sessionManagerXcodeListWindowsRetriesSiblingBeforeDroppingProcessRoute()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let unavailableUpstream = AlwaysUnavailableUpstreamClient(reason: .startFailed)
        let siblingUpstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 515, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [unavailableUpstream, siblingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }

        try await waitForSentCount(unavailableUpstream, count: 1, timeoutSeconds: 2)
        let siblingRequest = try await sentValue(from: siblingUpstream, at: 0, timeout: .seconds(2))
        #expect(toolCallName(from: siblingRequest) == "XcodeListWindows")
        let message = "* tabIdentifier: tab-sibling, workspacePath: /Work/S.xcworkspace"
        await siblingUpstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: siblingRequest),
                    message: message
                )
            )
        )

        let result = try await task.value
        guard case .object(let resultObject) = result,
              case .object(let structuredContent)? = resultObject["structuredContent"],
              case .string(let resultMessage)? = structuredContent["message"] else {
            Issue.record("expected XcodeListWindows structuredContent")
            return
        }
        #expect(resultMessage.contains("xcode-mcpkit:"))
        #expect(resultMessage.contains("/Work/S.xcworkspace"))
        #expect(manager.documentationCandidateProcessIDs() == Set([target.processID]))
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 1, [ownerBoundToolDescriptor(name: "XcodeListNavigatorIssues")]),
            ]
        )
        #expect(manager.preferredUpstreamIndex(for: [
            "method": "tools/call",
            "params": [
                "name": "XcodeListNavigatorIssues",
                "arguments": [
                    "tabIdentifier": "tab-sibling",
                ],
            ],
        ]) == 1)
    }

    @Test func sessionManagerXcodeListWindowsRetriesSiblingAfterToolError()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let firstUpstream = TestUpstreamClient()
        let siblingUpstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 516, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [firstUpstream, siblingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }

        let firstRequest = try await sentValue(from: firstUpstream, at: 0, timeout: .seconds(2))
        #expect(toolCallName(from: firstRequest) == "XcodeListWindows")
        await firstUpstream.yield(
            .message(
                try makeXcodeListWindowsToolErrorResponse(
                    id: try extractUpstreamID(from: firstRequest),
                    message: "XcodeListWindows failed"
                )
            )
        )

        let siblingRequest = try await sentValue(from: siblingUpstream, at: 0, timeout: .seconds(2))
        #expect(toolCallName(from: siblingRequest) == "XcodeListWindows")
        let message = "* tabIdentifier: tab-tool-error, workspacePath: /Work/T.xcworkspace"
        await siblingUpstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: siblingRequest),
                    message: message
                )
            )
        )

        let result = try await task.value
        guard case .object(let resultObject) = result,
              case .object(let structuredContent)? = resultObject["structuredContent"],
              case .string(let resultMessage)? = structuredContent["message"] else {
            Issue.record("expected XcodeListWindows structuredContent")
            return
        }
        #expect(resultMessage.contains("xcode-mcpkit:"))
        #expect(resultMessage.contains("/Work/T.xcworkspace"))
        #expect(manager.documentationCandidateProcessIDs() == Set([target.processID]))
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 1, [ownerBoundToolDescriptor(name: "XcodeListNavigatorIssues")]),
            ]
        )
        #expect(manager.preferredUpstreamIndex(for: [
            "method": "tools/call",
            "params": [
                "name": "XcodeListNavigatorIssues",
                "arguments": [
                    "tabIdentifier": "tab-tool-error",
                ],
            ],
        ]) != nil)
    }

    @Test func sessionManagerRejectsDuplicateWorkspaceOwnersAcrossProcesses() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 512, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 513, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ]
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        await upstream0.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: init0)))
        )
        _ = try await initFuture.get()
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        await upstream1.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: init1)))
        )
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let request1 = try await sentValue(from: upstream1, at: 2, timeout: .seconds(2))
        let workspacePath = "/Work/Shared.xcworkspace"
        let message0 = "* tabIdentifier: tab-a, workspacePath: \(workspacePath)"
        let message1 = "* tabIdentifier: tab-b, workspacePath: \(workspacePath)"
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: message0
                )
            )
        )
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: message1
                )
            )
        )

        let result = try await task.value
        guard case .object(let resultObject) = result,
              case .object(let structuredContent)? = resultObject["structuredContent"],
              case .string(let mergedMessage)? = structuredContent["message"] else {
            Issue.record("expected merged XcodeListWindows structuredContent")
            return
        }
        #expect(mergedMessage.components(separatedBy: "xcode-mcpkit:").count == 3)
        #expect(mergedMessage.contains(workspacePath))

        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target0,
                    0,
                    [
                        ownerBoundToolDescriptor(name: "XcodeSomeWorkspaceScopedTool"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
                (
                    target1,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "XcodeSomeWorkspaceScopedTool"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )

        let workspaceRequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeSomeWorkspaceScopedTool",
                "arguments": [
                    "workspacePath": workspacePath,
                ],
            ],
        ]
        #expect(manager.preferredUpstreamIndex(for: workspaceRequest) == nil)
        let refreshStart0 = await upstream0.sentCount()
        let refreshStart1 = await upstream1.sentCount()
        let decisionTask = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 8701,
                    name: "XcodeSomeWorkspaceScopedTool",
                    arguments: ["workspacePath": workspacePath]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }
        let refreshRequest0 = try await upstream0.nextSent(
            startingAt: refreshStart0,
            matching: {
                methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
            }
        )
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: refreshRequest0),
                    message: message0
                )
            )
        )
        let refreshRequest1 = try await upstream1.nextSent(
            startingAt: refreshStart1,
            matching: {
                methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
            }
        )
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: refreshRequest1),
                    message: message1
                )
            )
        )
        let decision = await decisionTask.value
        guard case .reject(let errors) = decision else {
            Issue.record("expected duplicate workspace owner to reject")
            return
        }
        #expect(errors.map(\.id.key) == ["8701"])
        #expect(errors.first?.message.contains("conflicting Xcode window owners") == true)
    }

    @Test func unavailableCachedWorkspaceOwnerDoesNotConflictWithAvailableOwner()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let unavailableTarget = xcodeProcessTarget(processID: 616, xcodeVersion: "27.0")
        let availableTarget = xcodeProcessTarget(processID: 617, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: unavailableTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: availableTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (unavailableTarget, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (availableTarget, 1, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_unavailable_stale_owner"
        )
        #expect(manager.unavailableXcodeProcessIDs().contains(unavailableTarget.processID))

        let workspacePath = "/Work/SharedAfterUnavailable.xcworkspace"
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: stale-tab, workspacePath: \(workspacePath)",
                    ],
                ]),
                upstreamIndex: 0
            )
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: live-tab, workspacePath: \(workspacePath)",
                    ],
                ]),
                upstreamIndex: 1
            )
        )

        let request = toolsCallObject(
            id: 8702,
            name: "BuildProject",
            arguments: ["workspacePath": workspacePath]
        )
        #expect(manager.preferredUpstreamIndex(for: request) == 1)
        let decision = await manager.toolRoutingDecision(
            for: request,
            requestTimeoutOverride: .seconds(2)
        )
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func unusableCachedWorkspaceOwnerDoesNotConflictWithUsableOwner()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let unusableTarget = xcodeProcessTarget(processID: 636, xcodeVersion: "27.0")
        let usableTarget = xcodeProcessTarget(processID: 637, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: unusableTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: usableTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (unusableTarget, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (usableTarget, 1, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )

        let workspacePath = "/Work/SharedAfterUnusable.xcworkspace"
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: stale-tab, workspacePath: \(workspacePath)",
                    ],
                ]),
                upstreamIndex: 0
            )
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: live-tab, workspacePath: \(workspacePath)",
                    ],
                ]),
                upstreamIndex: 1
            )
        )

        let request = toolsCallObject(
            id: 8708,
            name: "BuildProject",
            arguments: ["workspacePath": workspacePath]
        )
        #expect(manager.preferredUpstreamIndex(for: request) == 1)
        let decision = await manager.toolRoutingDecision(
            for: request,
            requestTimeoutOverride: .seconds(2)
        )
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func proxyTabIdentifierDisambiguatesDuplicateWorkspaceOwners() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 618, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 619, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )

        let workspacePath = "/Work/SharedWithProxyTab.xcworkspace"
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: \(workspacePath)",
                    ],
                ]),
                upstreamIndex: 0
            )
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-b, workspacePath: \(workspacePath)",
                    ],
                ]),
                upstreamIndex: 1
            )
        )

        let proxyTabIdentifier = WindowOwnershipIdentity.makeProxyTabIdentifier(
            processID: target1.processID,
            rawTabIdentifier: "tab-b",
            workspacePath: workspacePath
        )
        let request = toolsCallObject(
            id: 8703,
            name: "BuildProject",
            arguments: [
                "tabIdentifier": proxyTabIdentifier,
                "workspacePath": workspacePath,
            ]
        )
        #expect(manager.preferredUpstreamIndex(for: request) == 1)
        let decision = await manager.toolRoutingDecision(
            for: request,
            requestTimeoutOverride: .seconds(2)
        )
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func proxyTabIdentifierDisambiguatesRawTabCollisionWithinProcess() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 620, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target,
                    0,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )

        let workspaceA = "/Work/RawCollisionA.xcworkspace"
        let workspaceB = "/Work/RawCollisionB.xcworkspace"
        let windowsMessage = "* tabIdentifier: reused-tab, workspacePath: \(workspaceA)\n"
            + "* tabIdentifier: reused-tab, workspacePath: \(workspaceB)"
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": windowsMessage,
                    ],
                ]),
                upstreamIndex: 0
            )
        )

        let ambiguousTask = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 8705,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "reused-tab"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }
        let refreshRequest = try await upstream.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: refreshRequest),
                    message: windowsMessage
                )
            )
        )
        let ambiguousDecision = await ambiguousTask.value
        guard case .reject(let errors) = ambiguousDecision else {
            Issue.record("expected raw tab collision within one process to reject")
            return
        }
        #expect(errors.map(\.id.key) == ["8705"])
        #expect(errors.first?.message.contains("ambiguous raw Xcode tabIdentifier") == true)

        let proxyTabA = WindowOwnershipIdentity.makeProxyTabIdentifier(
            processID: target.processID,
            rawTabIdentifier: "reused-tab",
            workspacePath: workspaceA
        )
        let proxyTabB = WindowOwnershipIdentity.makeProxyTabIdentifier(
            processID: target.processID,
            rawTabIdentifier: "reused-tab",
            workspacePath: workspaceB
        )
        #expect(proxyTabA != proxyTabB)
        let request = toolsCallObject(
            id: 8704,
            name: "BuildProject",
            arguments: [
                "tabIdentifier": proxyTabB,
                "workspacePath": workspaceB,
            ]
        )
        #expect(manager.preferredUpstreamIndex(for: request) == 0)
        let decision = await manager.toolRoutingDecision(
            for: request,
            requestTimeoutOverride: .seconds(2)
        )
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [0])
    }

    @Test func sessionManagerSkipsUninitializedProcessRoutesDuringWindowFanout()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 514, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 515, xcodeVersion: "26.6")
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

        let firstUpstream0StartIndex = await upstream0.sentCount()
        let firstUpstream1StartIndex = await upstream1.sentCount()
        let firstTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }
        let firstRequest = try await sentValue(
            from: upstream0,
            startingAt: firstUpstream0StartIndex,
            matching: {
                methodName(from: $0) == "tools/call"
                    && toolCallName(from: $0) == "XcodeListWindows"
            },
            timeout: .seconds(2),
            description: "waiting for first XcodeListWindows fanout request"
        )
        #expect(await upstream1.sentCount() == firstUpstream1StartIndex)
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: firstRequest),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        _ = try await firstTask.value
        #expect(await upstream1.sentCount() == firstUpstream1StartIndex)

        manager.markUpstreamInitialized(upstreamIndex: 1)
        let secondUpstream0StartIndex = await upstream0.sentCount()
        let secondUpstream1StartIndex = await upstream1.sentCount()
        let secondTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }
        let secondRequest0 = try await sentValue(
            from: upstream0,
            startingAt: secondUpstream0StartIndex,
            matching: {
                methodName(from: $0) == "tools/call"
                    && toolCallName(from: $0) == "XcodeListWindows"
            },
            timeout: .seconds(2),
            description: "waiting for second XcodeListWindows fanout request on upstream 0"
        )
        let secondRequest1 = try await sentValue(
            from: upstream1,
            startingAt: secondUpstream1StartIndex,
            matching: {
                methodName(from: $0) == "tools/call"
                    && toolCallName(from: $0) == "XcodeListWindows"
            },
            timeout: .seconds(2),
            description: "waiting for second XcodeListWindows fanout request on upstream 1"
        )
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: secondRequest0),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: secondRequest1),
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )
        _ = try await secondTask.value
    }

    @Test func mergedXcodeListWindowsPreservesToolErrors() throws {
        let successMessage = "* tabIdentifier: tab-ok, workspacePath: /Work/OK.xcworkspace"
        let success = try jsonValue([
            "content": [
                [
                    "type": "text",
                    "text": "{\"message\":\"\(successMessage)\"}",
                ],
            ],
            "structuredContent": [
                "message": successMessage,
            ],
        ])
        let error = try jsonValue([
            "content": [
                [
                    "type": "text",
                    "text": "XcodeListWindows failed",
                ],
            ],
            "isError": true,
        ])

        let partialMerge = try #require(
            RuntimeCoordinator.mergedXcodeListWindowsResult([error, success])
        )
        guard case .object(let partialObject) = partialMerge,
              case .object(let structuredContent)? = partialObject["structuredContent"],
              case .string(let mergedMessage)? = structuredContent["message"] else {
            Issue.record("expected merged success result")
            return
        }
        #expect(mergedMessage == successMessage)

        let failedMerge = try #require(
            RuntimeCoordinator.mergedXcodeListWindowsResult([error])
        )
        guard case .object(let failedObject) = failedMerge else {
            Issue.record("expected tool error result")
            return
        }
        guard case .bool(true)? = failedObject["isError"] else {
            Issue.record("expected merged failure to preserve isError")
            return
        }
    }

    @Test func sessionManagerKeepsWindowlessProcessRouteAvailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 600, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 601, xcodeVersion: "26.6")
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target0,
                    0,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
                (
                    target1,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: stale-tab, workspacePath: /Work/Stale.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await upstream0.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: ""
                )
            )
        )
        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )
        _ = try await task.value

        let processIDs = Set(manager.debugSnapshot().processToolCatalogs.map(\.processID))
        #expect(processIDs == Set([Int32(target0.processID), Int32(target1.processID)]))
        #expect(
            manager.documentationCandidateProcessIDs() == Set([
                target0.processID,
                target1.processID,
            ])
        )
        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 1001,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "stale-tab"]
                )
            ) == nil
        )
    }

    @Test func ownerBoundRefreshSkipsUnavailableProcessRoutes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 602, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 603, xcodeVersion: "26.6")
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target0,
                    0,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
                (
                    target1,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_unavailable"
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 1002,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-b"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )

        let decision = await task.value
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundRefreshUsesUsableSiblingWhenPrimaryUnavailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let primaryUpstream = TestUpstreamClient()
        let siblingUpstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 604, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [primaryUpstream, siblingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 1003,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-sibling"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request = try await siblingUpstream.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        #expect(await primaryUpstream.sentCount() == 0)
        await siblingUpstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request),
                    message: "* tabIdentifier: tab-sibling, workspacePath: /Work/S.xcworkspace"
                )
            )
        )

        let decision = await task.value
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundToolWithoutOwnerHintRoutesWhenSingleProcess() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 605, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 1004,
                name: "BuildProject",
                arguments: [:]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [0])
        #expect(await upstream.sentCount() == 0)
    }

    @Test func ownerBoundToolWithoutOwnerHintRoutesWhenSingleCatalogCandidate() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 606, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 607, xcodeVersion: "26.6")
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [toolDescriptor(name: "XcodeRead")]),
            ]
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 1005,
                name: "BuildProject",
                arguments: [:]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [0])
        #expect(await upstream0.sentCount() == 0)
        #expect(await upstream1.sentCount() == 0)
    }

    @Test func ownerBoundToolRoutesToCachedWindowOwner() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 610, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 611, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target0,
                    0,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
                (
                    target1,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 101,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-a"]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [0])
    }

    @Test func rawTabCollisionRequiresWorkspaceDisambiguation() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 612, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 613, xcodeVersion: "26.6")
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target0,
                    0,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
                (
                    target1,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: windowtab1, workspacePath: /Work/A.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: windowtab1, workspacePath: /Work/B.xcworkspace",
                    ],
                ]),
                upstreamIndex: 1
            )
        )

        let ambiguousTask = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 9301,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "windowtab1"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }
        let refresh0 = try await upstream0.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: refresh0),
                    message: "* tabIdentifier: windowtab1, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        let refresh1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: refresh1),
                    message: "* tabIdentifier: windowtab1, workspacePath: /Work/B.xcworkspace"
                )
            )
        )
        let ambiguousDecision = await ambiguousTask.value
        guard case .reject(let errors) = ambiguousDecision else {
            Issue.record("expected raw tab-only request to reject")
            return
        }
        #expect(errors.map(\.id.key) == ["9301"])
        #expect(errors.first?.message.contains("ambiguous raw Xcode tabIdentifier") == true)

        let disambiguatedDecision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 9302,
                name: "BuildProject",
                arguments: [
                    "tabIdentifier": "windowtab1",
                    "workspacePath": "/Work/B.xcworkspace",
                ]
            ),
            requestTimeoutOverride: .seconds(2)
        )
        let preferredUpstreamIndices = try #require(disambiguatedDecision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func workspacePathTakesPrecedenceOverRawTabFallback() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 615, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: windowtab1, workspacePath: /Work/A.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )

        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 9401,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "windowtab1"]
                )
            ) == 0
        )
        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 9402,
                    name: "BuildProject",
                    arguments: [
                        "tabIdentifier": "windowtab1",
                        "workspacePath": "/Work/Other.xcworkspace",
                    ]
                )
            ) == nil
        )
    }

    @Test func proxyTabIdentifierIsRewrittenBeforeForwarding() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 614, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target,
                    0,
                    [
                        toolDescriptor(name: "XcodeListWindows"),
                        toolDescriptor(
                            name: "BuildProject",
                            inputProperties: [
                                "tabIdentifier": ["type": "string"],
                                "workspacePath": ["type": "string"],
                            ],
                            required: ["tabIdentifier"]
                        ),
                    ]
                ),
            ]
        )

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }
        let listRequest = try await upstream.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: listRequest),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        let result = try await task.value
        guard case .object(let resultObject) = result,
              case .object(let structuredContent)? = resultObject["structuredContent"],
              case .string(let message)? = structuredContent["message"],
              let proxyTab = firstTabIdentifier(in: message) else {
            Issue.record("expected proxied XcodeListWindows tab")
            return
        }
        #expect(proxyTab.hasPrefix("xcode-mcpkit:"))
        #expect(proxyTab != "tab-a")

        let proxyTabRequest = toolsCallObject(
            id: 9303,
            name: "BuildProject",
            arguments: ["tabIdentifier": proxyTab]
        )
        let proxyTabData = try JSONSerialization.data(withJSONObject: proxyTabRequest, options: [])
        let rewrittenProxyTab = manager.rewriteOwnerBoundRequest(
            bodyData: proxyTabData,
            parsedRequestJSON: proxyTabRequest,
            upstreamIndex: 0
        )
        #expect(tabIdentifier(in: rewrittenProxyTab.bodyData) == "tab-a")

        let workspaceOnlyRequest = toolsCallObject(
            id: 9304,
            name: "BuildProject",
            arguments: ["workspacePath": "/Work/A.xcworkspace"]
        )
        let workspaceOnlyData = try JSONSerialization.data(
            withJSONObject: workspaceOnlyRequest,
            options: []
        )
        let rewrittenWorkspaceOnly = manager.rewriteOwnerBoundRequest(
            bodyData: workspaceOnlyData,
            parsedRequestJSON: workspaceOnlyRequest,
            upstreamIndex: 0
        )
        #expect(tabIdentifier(in: rewrittenWorkspaceOnly.bodyData) == "tab-a")

        let emptyTabWorkspaceRequest = toolsCallObject(
            id: 9305,
            name: "BuildProject",
            arguments: [
                "tabIdentifier": "",
                "workspacePath": "/Work/A.xcworkspace",
            ]
        )
        let emptyTabWorkspaceData = try JSONSerialization.data(
            withJSONObject: emptyTabWorkspaceRequest,
            options: []
        )
        let rewrittenEmptyTabWorkspace = manager.rewriteOwnerBoundRequest(
            bodyData: emptyTabWorkspaceData,
            parsedRequestJSON: emptyTabWorkspaceRequest,
            upstreamIndex: 0
        )
        #expect(tabIdentifier(in: rewrittenEmptyTabWorkspace.bodyData) == "tab-a")

        let decision = await manager.toolRoutingDecision(
            for: proxyTabRequest,
            requestTimeoutOverride: .seconds(2)
        )
        guard case .forwardAdmitted(_, let admission) = decision else {
            Issue.record("expected exact window-route admission")
            return
        }
        _ = manager.windowOwnershipAuthority.record(
            processID: target.processID,
            entries: [
                XcodeListWindowsEntry(
                    tabIdentifier: "tab-after-admission",
                    workspacePath: "/Work/A.xcworkspace"
                )
            ]
        )
        let admittedRewrite = manager.rewriteOwnerBoundRequest(
            bodyData: proxyTabData,
            parsedRequestJSON: proxyTabRequest,
            operationLease: try #require(
                manager.upstreamTopology.operationLease(for: UpstreamSlotID(rawValue: 0))
            ),
            admission: admission
        )
        #expect(tabIdentifier(in: admittedRewrite.bodyData) == "tab-a")
    }

    @Test func ownerRoutingReResolvesWindowAndRouteSnapshotsWhenProofRouteChanges() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let target = xcodeProcessTarget(processID: 615, xcodeVersion: "27.0")
        let managerBox = WeakRuntimeCoordinatorBox()
        let hookCount = NIOLockedValueBox(0)
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            testHooks: RuntimeCoordinatorTestHooks(ownerRouteProofsResolved: {
                let shouldReplace = hookCount.withLockedValue { count in
                    defer { count += 1 }
                    return count == 0
                }
                guard shouldReplace, let manager = managerBox.value else { return }
                _ = manager.processControlPlane.reconcileRoutes(
                    [XcodeProcessRoute(target: target, upstreamIndices: [1])],
                    reason: "route_change_after_window_proof",
                    nowUptimeNs: manager.nowUptimeNanoseconds(),
                    usability: .init(
                        snapshotUsableUpstreamIDs: [UpstreamSlotID(rawValue: 1)],
                        recoveryAwareUsableUpstreamIDs: [UpstreamSlotID(rawValue: 1)]
                    )
                )
            }),
            startImmediately: false
        )
        managerBox.value = manager
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [(target, 0, [ownerBoundToolDescriptor(name: "BuildProject")])]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: route-race-tab, workspacePath: /Work/Race.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 9306,
                name: "BuildProject",
                arguments: ["tabIdentifier": "route-race-tab"]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        guard case .forwardAdmitted(let preferred, let admission) = decision else {
            Issue.record("expected routing to re-resolve against the replacement route")
            return
        }
        #expect(preferred == [1])
        #expect(manager.processControlPlane.validate(admission.route))
        #expect(admission.window?.proof.route.routeID == admission.route.routeID)
    }

    @Test func ownerHintRoutesBeforeProcessToolCatalogIsAvailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 628, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 629, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        manager.seedCanonicalToolsCatalog(
            try jsonValue([
                "tools": [
                    ownerBoundToolDescriptor(name: "BuildProject"),
                ],
            ]),
            sourceUpstream: 2
        )
        #expect(manager.debugSnapshot().processToolCatalogs.isEmpty)
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-before-catalog, "
                            + "workspacePath: /Work/BeforeCatalog.xcworkspace",
                    ],
                ]),
                upstreamIndex: 1
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 102,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-before-catalog"]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundToolRoutesToUsableSlotInOwningProcess() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 612, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 109,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-a"]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundProcessRouteUsesIdleSiblingWhenPrimaryIsBusy() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 614, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 112,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-a"]
            ),
            requestTimeoutOverride: .seconds(2)
        )
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [0, 1])

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:LongRunningBuild",
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop,
            preferredUpstreamIndex: 0
        ) { selectedUpstreamIndex in
            #expect(selectedUpstreamIndex.upstreamIndex == 0)
            return activePromise.futureResult
        }

        let routedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-routed",
            label: "tools/call:BuildProject",
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let routedLeaseID = manager.createRequestLease(descriptor: routedDescriptor)
        let selectedUpstream = NIOLockedValueBox<Int?>(nil)
        let routedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: routedLeaseID,
            descriptor: routedDescriptor,
            on: eventLoop,
            preferredUpstreamIndices: preferredUpstreamIndices
        ) { selectedUpstreamIndex in
            selectedUpstream.withLockedValue { $0 = selectedUpstreamIndex.upstreamIndex }
            return eventLoop.makeSucceededFuture(())
        }

        _ = try await routedFuture.get()
        #expect(selectedUpstream.withLockedValue { $0 } == 1)
        manager.completeRequestLease(routedLeaseID)

        manager.completeRequestLease(activeLeaseID)
        activePromise.succeed(())
        _ = try await activeFuture.get()
    }

    @Test func ownerBoundToolKeepsProcessRouteWhenSiblingSlotExits() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 615, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )

        manager.handleUpstreamExit(1, upstreamIndex: 0)

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 111,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-a"]
            ),
            requestTimeoutOverride: .seconds(2)
        )
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func sessionManagerProcessCatalogRebindsSourceAndSurvivesLastSlotExit()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 615, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [toolDescriptor(name: "SharedTool")]),
            ]
        )

        #expect(manager.clearUpstreamState(upstreamIndex: 0))

        var snapshot = manager.debugSnapshot()
        let catalog = try #require(snapshot.processToolCatalogs.first)
        #expect(catalog.upstreamIndex == 1)
        #expect(catalog.isCanonicalSource)
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["SharedTool"])

        #expect(manager.clearUpstreamState(upstreamIndex: 1))

        snapshot = manager.debugSnapshot()
        #expect(manager.cachedToolsListResult() == nil)
        let retainedCatalog = try #require(snapshot.processToolCatalogs.first)
        #expect(retainedCatalog.upstreamIndex == 1)
        #expect(retainedCatalog.isCanonicalSource == false)
    }

    @Test func nonOwnerUnionToolRoutesToCatalogOwnerProcess() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 613, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 614, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [toolDescriptor(name: "Xcode27OnlyTool")]),
                (target1, 1, [toolDescriptor(name: "SharedTool")]),
            ]
        )

        let decision = try #require(
            manager.immediateToolRoutingDecision(
                for: [
                    "jsonrpc": "2.0",
                    "id": 110,
                    "method": "tools/call",
                    "params": [
                        "name": "Xcode27OnlyTool",
                    ],
                ]
            )
        )

        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [0])
    }

    @Test func publicXcodeListWindowsRoutesToLocalAggregation() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 618, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 619, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [toolDescriptor(name: "XcodeListWindows")]),
                (target1, 1, [toolDescriptor(name: "XcodeListWindows")]),
            ]
        )

        let decision = try #require(
            manager.immediateToolRoutingDecision(
                for: toolsCallObject(
                    id: 118,
                    name: "XcodeListWindows",
                    arguments: [:]
                )
            )
        )

        guard case .localXcodeListWindows = decision else {
            Issue.record("expected XcodeListWindows to resolve through local aggregation")
            return
        }
    }

    @Test func liveXcodeListWindowsAggregatesOnlyCatalogAdvertisedRoutes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 620, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 621, xcodeVersion: "26.6")
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [toolDescriptor(name: "XcodeListWindows")]),
            ]
        )

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }

        let request = try await upstream0.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        #expect(await upstream1.sentCount() == 0)

        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )

        let result = try await task.value
        #expect(await upstream1.sentCount() == 0)
        guard case .object(let object) = result,
              case .object(let structuredContent)? = object["structuredContent"],
              case .string(let message)? = structuredContent["message"] else {
            Issue.record("expected structured XcodeListWindows message")
            return
        }
        #expect(message.contains("xcode-mcpkit:"))
        #expect(message.contains("/Work/A.xcworkspace"))
    }

    @Test func pinnedLiveXcodeListWindowsReturnsClientProxyTabIdentifiers()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 634, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target,
                    0,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .pinnedUpstream(0),
                requestTimeoutOverride: .seconds(5)
            )
        }
        let request = try await upstream.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request),
                    message: "* tabIdentifier: raw-pinned-tab, "
                        + "workspacePath: /Work/Pinned.xcworkspace"
                )
            )
        )

        let result = try await task.value
        guard case .object(let object) = result,
              case .object(let structuredContent)? = object["structuredContent"],
              case .string(let message)? = structuredContent["message"],
              let proxyTabIdentifier = firstTabIdentifier(in: message) else {
            Issue.record("expected pinned XcodeListWindows to return a proxied tab")
            return
        }
        #expect(proxyTabIdentifier.hasPrefix("xcode-mcpkit:"))
        #expect(proxyTabIdentifier != "raw-pinned-tab")
        #expect(message.contains("/Work/Pinned.xcworkspace"))

        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 8707,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": proxyTabIdentifier]
                )
            ) == 0
        )
    }

    @Test func liveXcodeListWindowsIgnoresCatalogsFromUnavailableRoutes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 624, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 625, xcodeVersion: "26.6")
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [toolDescriptor(name: "DocumentationSearch")]),
            ]
        )
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_unavailable"
        )

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }

        let request = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        #expect(await upstream0.sentCount() == 0)

        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request),
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )

        let result = try await task.value
        #expect(await upstream0.sentCount() == 0)
        guard case .object(let object) = result,
              case .object(let structuredContent)? = object["structuredContent"],
              case .string(let message)? = structuredContent["message"] else {
            Issue.record("expected structured XcodeListWindows message")
            return
        }
        #expect(message.contains("xcode-mcpkit:"))
        #expect(message.contains("/Work/B.xcworkspace"))
    }

    @Test func liveXcodeListWindowsClearsOwnersForCatalogFilteredRoutes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 626, xcodeVersion: "26.6")
        let target1 = xcodeProcessTarget(processID: 627, xcodeVersion: "27.0")
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [toolDescriptor(name: "XcodeListWindows")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: stale-tab, workspacePath: /Work/Stale.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )
        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 1101,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "stale-tab"]
                )
            ) == 0
        )

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }

        let request = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        #expect(await upstream0.sentCount() == 0)

        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request),
                    message: "* tabIdentifier: live-tab, workspacePath: /Work/Live.xcworkspace"
                )
            )
        )

        _ = try await task.value
        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 1102,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "stale-tab"]
                )
            ) == nil
        )
    }

    @Test func liveXcodeListWindowsSkipsCatalogedRoutesWithoutTool() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 622, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 623, xcodeVersion: "26.6")
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [toolDescriptor(name: "DocumentationSearch")]),
                (target1, 1, [toolDescriptor(name: "BuildProject")]),
            ]
        )

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.unavailable) {
            _ = try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        #expect(await upstream0.sentCount() == 0)
        #expect(await upstream1.sentCount() == 0)
    }

    @Test func ownerBoundToolRefreshesWindowsOnCacheMissBeforeRouting() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 620, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 621, xcodeVersion: "26.6")
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target0,
                    0,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
                (
                    target1,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 102,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-b"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await upstream0.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )

        let decision = await task.value
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundToolRefreshesStaleWorkspaceConflictBeforeRejecting()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 632, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 633, xcodeVersion: "26.6")
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target0,
                    0,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
                (
                    target1,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )

        let workspacePath = "/Work/StaleConflict.xcworkspace"
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: stale-tab, workspacePath: \(workspacePath)",
                    ],
                ]),
                upstreamIndex: 0
            )
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: live-tab, workspacePath: \(workspacePath)",
                    ],
                ]),
                upstreamIndex: 1
            )
        )
        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 8706,
                    name: "BuildProject",
                    arguments: ["workspacePath": workspacePath]
                )
            ) == nil
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 8706,
                    name: "BuildProject",
                    arguments: ["workspacePath": workspacePath]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await upstream0.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: ""
                )
            )
        )
        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: "* tabIdentifier: live-tab, workspacePath: \(workspacePath)"
                )
            )
        )

        let decision = await task.value
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundRefreshUsesUncatalogedRoutesForOwnerDiscovery() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 625, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 626, xcodeVersion: "26.6")
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 109,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-uncataloged"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        #expect(await upstream0.sentCount() == 0)
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: "* tabIdentifier: tab-uncataloged, "
                        + "workspacePath: /Work/Uncataloged.xcworkspace"
                )
            )
        )

        let decision = await task.value
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundToolRejectsWhenOwnerCannotBeResolvedAfterRefresh() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 630, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 631, xcodeVersion: "26.6")
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
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target0,
                    0,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
                (
                    target1,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 103,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "missing-tab"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await upstream0.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )

        let decision = await task.value
        guard case .reject(let errors) = decision else {
            Issue.record("expected unresolved owner-bound request to reject")
            return
        }
        #expect(errors.map(\.id.key) == ["103"])
        #expect(errors.first?.message.contains("unable to resolve Xcode window owner") == true)
    }

    @Test func ownerBoundToolRejectsWhenOwnerProcessLacksTool() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 640, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 641, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [ownerBoundToolDescriptor(name: "XcodeRead")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace",
                    ],
                ]),
                upstreamIndex: 1
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 104,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-b"]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        guard case .reject(let errors) = decision else {
            Issue.record("expected missing owner capability to reject")
            return
        }
        #expect(errors.map(\.id.key) == ["104"])
        #expect(errors.first?.message.contains("not available") == true)
    }

    @Test func sessionManagerLiveXcodeListWindowsCancellationCancelsLastWaiterLoad()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let request = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: request) == "tools/call")

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled XcodeListWindows waiter should not complete successfully")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError but received \(error)")
        }

        _ = try await waitWithTimeout("waiting for cancelled XcodeListWindows waiter cleanup") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.windows == 0 && $0.inFlightControlPlaneRequests.isEmpty
            }
        }
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func sessionManagerPromotedLiveXcodeListWindowsCancellationRemovesMigratedWaiter()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let uptimeClock = TestUptimeClock()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: uptimeClock.now
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
        _ = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))

        uptimeClock.advance(by: .nanoseconds(120_000_001))

        let secondTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))

        firstTask.cancel()
        do {
            _ = try await firstTask.value
            Issue.record("first promoted XcodeListWindows waiter should be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for promoted XcodeListWindows waiter but received \(error)")
        }

        _ = try await waitWithTimeout("waiting for first promoted XcodeListWindows waiter cleanup") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.windows == 1
            }
        }

        secondTask.cancel()
        do {
            _ = try await secondTask.value
            Issue.record("second promoted XcodeListWindows waiter should be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for promoted XcodeListWindows waiter but received \(error)")
        }

        _ = try await waitWithTimeout("waiting for promoted XcodeListWindows waiter cleanup") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.windows == 0 && $0.inFlightControlPlaneRequests.isEmpty
            }
        }
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func shutdownDrainsCancelledLiveXcodeListWindowsLoadWithoutUpstreamResponse()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        var didShutdown = false
        defer {
            if didShutdown == false {
                manager.shutdownAndWait()
            }
        }

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

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        let request = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: request) == "tools/call")

        task.cancel()
        try await waitWithTimeout(
            "waiting for shutdown to drain cancelled XcodeListWindows load",
            timeout: .seconds(2)
        ) {
            await manager.shutdown()
        }
        didShutdown = true

        do {
            _ = try await waitWithTimeout(
                "waiting for cancelled XcodeListWindows task",
                timeout: .seconds(2)
            ) {
                try await task.value
            }
            Issue.record("cancelled XcodeListWindows waiter should not complete successfully")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError but received \(error)")
        }
    }

    @Test func controlPlaneRPCHandleCancelBeforeQueueStartCapturesQueuedState() {
        let handle = ControlPlane.RPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlane.RPCCancelSnapshot?>(nil)

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == nil)
        #expect(snapshot?.upstreamIndex == nil)
        #expect(snapshot?.requestIDKey == nil)
        #expect(handle.markRegistered(registrationToken: UUID(), operationLease: testOperationLease(0)) == false)
    }

    @Test func controlPlaneRPCHandleCancelAfterRegisterCapturesRegistrationState() {
        let handle = ControlPlane.RPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlane.RPCCancelSnapshot?>(nil)
        let token = UUID()

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        #expect(handle.markRegistered(registrationToken: token, operationLease: testOperationLease(2)))

        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == token)
        #expect(snapshot?.upstreamIndex == 2)
        #expect(snapshot?.requestIDKey == nil)
        #expect(handle.markAssigned(registrationToken: token, operationLease: testOperationLease(2), requestIDKey: "req") == false)
    }

    @Test func controlPlaneRPCHandleCancelAfterAssignCapturesRequestMappingState() {
        let handle = ControlPlane.RPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlane.RPCCancelSnapshot?>(nil)
        let token = UUID()

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        #expect(handle.markRegistered(registrationToken: token, operationLease: testOperationLease(1)))
        #expect(handle.markAssigned(registrationToken: token, operationLease: testOperationLease(1), requestIDKey: "req-1"))

        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == token)
        #expect(snapshot?.upstreamIndex == 1)
        #expect(snapshot?.requestIDKey == "req-1")
    }

    @Test func controlPlaneRPCHandleCancelAfterSendUsesAssignedSnapshotUntilFinished() {
        let handle = ControlPlane.RPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlane.RPCCancelSnapshot?>(nil)
        let token = UUID()

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        #expect(handle.markRegistered(registrationToken: token, operationLease: testOperationLease(0)))
        #expect(handle.markAssigned(registrationToken: token, operationLease: testOperationLease(0), requestIDKey: "req-after-send"))

        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == token)
        #expect(snapshot?.upstreamIndex == 0)
        #expect(snapshot?.requestIDKey == "req-after-send")

        handle.markFinished()
        handle.cancel()
        let repeatedSnapshot = cancellation.withLockedValue { $0 }
        #expect(repeatedSnapshot?.requestIDKey == "req-after-send")
    }

    @Test func sessionManagerEagerInitializeRestartsAfterExit() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }
        #expect(manager.isInitialized() == false)

        _ = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))

        await upstream.yield(.exit(1))
        _ = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))
        _ = manager
    }

    @Test func initializeTimeoutRemainsBoundedWhenRequestTimeoutIsDisabled() throws {
        let timeout = MCP.MethodDispatcher.timeoutForInitialize(defaultSeconds: 0)
        #expect(timeout?.nanoseconds == TimeAmount.seconds(60).nanoseconds)
    }

    @Test func controlPlaneTimeoutStaysShortForSlowDiscoveryWork() throws {
        let disabledDefault = MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: 0)
        #expect(disabledDefault?.nanoseconds == TimeAmount.seconds(10).nanoseconds)

        let longDefault = MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: 300)
        #expect(longDefault?.nanoseconds == TimeAmount.seconds(10).nanoseconds)

        let shortDefault = MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: 3)
        #expect(shortDefault?.nanoseconds == TimeAmount.seconds(3).nanoseconds)
    }

    @Test func sessionManagerStillAutoInitializesWhenRequestTimeoutIsDisabled() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 0)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        _ = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
    }




    @Test func sessionManagerUsesInitializeParamsOverrideFromConfigFile() async throws {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake]
            clientName = "custom-proxy"

            [upstream_handshake.capabilities]
            roots = true
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.configPath = configPath
        config.applyFileConfiguration(
            try ProxyConfig.File.Loader.loadStrict(
                configURL: URL(fileURLWithPath: configPath)
            )
        )
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])

        #expect(params["protocolVersion"] as? String == "2025-06-18")
        #expect(clientInfo["name"] as? String == "custom-proxy")
        #expect(clientInfo["version"] as? String == InitializeHandshakeParams.defaultProxyClientVersion())
        #expect(capabilities["roots"] as? Bool == true)
    }

    @Test func sessionManagerAppliesPublicInitializeHandshakeOverrideAfterConfigFile()
        async throws
    {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake]
            protocolVersion = "2025-06-18"
            clientName = "file-proxy"
            clientVersion = "file-version"

            [upstream_handshake.capabilities]
            roots = true
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let publicConfiguration = XcodeMCPProxyServerConfiguration(
            configurationFileURL: URL(fileURLWithPath: configPath),
            initializeHandshake: .init(
                clientInfo: .init(name: "typed-proxy"),
                capabilities: [
                    "sampling": [
                        "enabled": true,
                    ],
                ]
            ),
            featurePolicy: .init(prewarmToolsList: false)
        )
        let config = try ProxyConfig.resolving(publicConfiguration)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        let sampling = try #require(capabilities["sampling"] as? [String: Any])

        #expect(params["protocolVersion"] as? String == "2025-06-18")
        #expect(clientInfo["name"] as? String == "typed-proxy")
        #expect(clientInfo["version"] as? String == "file-version")
        #expect(capabilities["roots"] == nil)
        #expect(sampling["enabled"] as? Bool == true)
    }

    @Test func sessionManagerAutoResolvesInitializeVersionFromConfiguredClientName() async throws {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake]
            clientName = "Claude"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.configPath = configPath
        config.applyFileConfiguration(
            try ProxyConfig.File.Loader.loadStrict(
                configURL: URL(fileURLWithPath: configPath)
            )
        )
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])

        #expect(clientInfo["name"] as? String == "Claude")
        #expect(clientInfo["version"] as? String == InitializeHandshakeParams.defaultClientVersion(for: "Claude"))
    }

    @Test func xcodeChatClientVersionFallsBackToCodeAliasWhenExactStemMissing() {
        let version = InitializeHandshakeParams.xcodeChatClientVersion(
            for: "Claude",
            defaults: [
                "IDEChatClaudeCodeVersion": #"{"version":"9.9.9"}"#,
            ]
        )

        #expect(version == "9.9.9")
    }

    @Test func xcodeChatClientVersionPrefersExactStemMatchOverGenericCodeAlias() {
        let version = InitializeHandshakeParams.xcodeChatClientVersion(
            for: "Claude",
            defaults: [
                "IDEChatClaudeVersion": #"{"version":"1.2.3"}"#,
                "IDEChatClaudeCodeVersion": #"{"version":"9.9.9"}"#,
            ]
        )

        #expect(version == "1.2.3")
    }

    @Test func strictConfigLoaderRejectsInvalidInitializeConfiguration() async throws {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake
            protocolVersion = "broken"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        #expect(throws: ProxyConfig.File.LoadError.self) {
            _ = try ProxyConfig.File.Loader.loadStrict(
                configURL: URL(fileURLWithPath: configPath)
            )
        }
    }

    @Test func sessionManagerUsesConfiguredInitializeParamsAfterEagerInitTimesOut()
        async throws
    {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake]
            clientName = "configured-proxy"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let timeoutClock = TestClock()
        let initializeCleanupCompleted = TestSignal()
        var config = makeConfig(requestTimeout: 0.1)
        config.configPath = configPath
        config.applyFileConfiguration(
            try ProxyConfig.File.Loader.loadStrict(
                configURL: URL(fileURLWithPath: configPath)
            )
        )
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            scheduleRuntimeTimeout: makeDeterministicRuntimeTimeoutScheduler(clock: timeoutClock),
            testHooks: RuntimeCoordinatorTestHooks(
                primaryInitializeFailureCleanupCompleted: { _ in
                    initializeCleanupCompleted.signal()
                }
            )
        )
        defer { manager.shutdownAndWait() }

        try await spinUntilSentCount(
            upstream,
            count: 1,
            description: "waiting for eager initialize request"
        )
        try await waitForSuspendedSleepers(on: timeoutClock)
        timeoutClock.advance(by: .milliseconds(100))
        try await initializeCleanupCompleted.wait(
            description: "waiting for eager initialize timeout cleanup"
        )
        #expect(manager.testStateSnapshot().initInFlight == false)

        _ = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2099-01-01",
                    "capabilities": [String: Any](),
                    "clientInfo": [
                        "name": "downstream-client",
                        "version": "9.9",
                    ],
                ],
            ],
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
        let resent = try #require(await upstream.sentValue(at: 1))
        let object = try JSONSerialization.jsonObject(with: resent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])

        let snapshot = manager.testStateSnapshot()
        #expect(snapshot.hasInitResult == false)
        #expect(params["protocolVersion"] as? String == "2025-06-18")
        #expect(clientInfo["name"] as? String == "configured-proxy")
        #expect(clientInfo["version"] as? String == InitializeHandshakeParams.defaultProxyClientVersion())
    }

    @Test func sessionManagerSendsInitializedOnce() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let request = makeInitializeRequest(id: 1)
        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: request,
            on: eventLoop
        )

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID = try extractUpstreamID(from: sent)
        let response = try makeInitializeResponse(id: upstreamID)
        await upstream.yield(.message(response))

        _ = try await future.get()
        _ = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))

        let cached = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        let cachedResponse = try decodeJSON(from: try await cached.get())
        let cachedID = (cachedResponse["id"] as? NSNumber)?.intValue
        #expect(cachedID == 2)
        #expect((await upstream.sent()).count == 2)
    }

    @Test func sessionManagerSendsInitializedBeforeQueuedRequestAfterWarmInit() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex.upstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        let queuedRequestData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": NSNumber(value: 99),
                "method": "tools/list",
            ],
            options: []
        )
        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/list",
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
            manager.sendUpstream(
                queuedRequestData,
                operationLease: selectedUpstreamIndex,
                ensureRunning: false,
                admission: nil,
                onRejected: {}
            )
            return eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))
        _ = try await queuedFuture.get()

        let initializedNotification = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))
        let queuedRequest = try await sentValue(from: upstream1, at: 2, timeout: .seconds(2))
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        #expect(methodName(from: queuedRequest) == "tools/list")

        activePromise.fail(CancellationError())
    }

    @Test func sessionManagerPrimaryExitClearsCachedInitializeResult() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        // First init establishes the cached init result.
        let init1 = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let firstInit = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID1 = try extractUpstreamID(from: firstInit)
        await upstream.yield(.message(try makeInitializeResponse(id: upstreamID1)))
        _ = try await init1.get()

        // Wait for notifications/initialized.
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        // Simulate primary upstream dying after init succeeded.
        let exitEventIndex = upstreamEvents.count()
        await upstream.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: exitEventIndex,
            description: "waiting for primary upstream exit"
        )
        #expect(manager.testStateSnapshot().hasInitResult == false)

        // A new downstream initialize must trigger a new upstream initialize (no cached response).
        let init2 = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let upstreamID2 = try extractUpstreamID(from: (await upstream.sent())[2])
        await upstream.yield(.message(try makeInitializeResponse(id: upstreamID2)))
        _ = try await init2.get()
    }

    @Test func sessionManagerPrimaryEagerRetryClearsCanonicalToolsCatalog() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        manager.startPrimaryEagerRetry()

        #expect(manager.cachedToolsListResult() == nil)
    }

    @Test func sessionManagerKeepsQueuedRequestsWaitingWhileReinitializeIsInFlight() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex.upstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        let queuedRequestData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": NSNumber(value: 199),
                "method": "tools/list",
            ],
            options: []
        )
        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/list",
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
            manager.sendUpstream(
                queuedRequestData,
                operationLease: selectedUpstreamIndex,
                ensureRunning: false,
                admission: nil,
                onRejected: {}
            )
            return eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        await upstream.yield(.exit(1))

        let reinitRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(manager.testStateSnapshot().upstream(id: 0)?.initInFlight == true)
        #expect(manager.debugSnapshot().queuedRequestCount == 1)
        let reinitUpstreamID = try extractUpstreamID(from: reinitRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: reinitUpstreamID)))
        _ = try await queuedFuture.get()

        let initializedNotification = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        let queuedRequest = try await sentValue(from: upstream, at: 4, timeout: .seconds(2))
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        #expect(methodName(from: queuedRequest) == "tools/list")

        activePromise.fail(CancellationError())
    }

    @Test func sessionManagerSecondaryExitClearsCachedInitializeResultWhenPrimaryAlreadyDown()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        // First init establishes the cached init result (primary only).
        let init1 = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let firstInit = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let upstreamID0 = try extractUpstreamID(from: firstInit)
        await upstream0.yield(.message(try makeInitializeResponse(id: upstreamID0)))
        _ = try await init1.get()

        // Warm init -> upstream1
        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1Messages = await upstream1.sent()
        let upstreamID1 = try extractUpstreamID(from: init1Messages[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: upstreamID1)))

        // Wait for per-upstream notifications/initialized.
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        // Simulate primary dying first (cached init result should remain because upstream1 is still initialized).
        let primaryExitEventIndex = upstreamEvents.count()
        await upstream0.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: primaryExitEventIndex,
            description: "waiting for primary upstream exit"
        )
        #expect(manager.testStateSnapshot().upstream(id: 0)?.isInitialized == false)
        let primaryRecoveryInitialize = try await sentValue(
            from: upstream0,
            at: 2,
            timeout: .seconds(2)
        )

        // Now simulate the last initialized upstream dying too.
        let secondaryExitEventIndex = upstreamEvents.count()
        await upstream1.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: secondaryExitEventIndex,
            description: "waiting for secondary upstream exit"
        )
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == false)

        // Ensure the cached init result is cleared before asserting that a new downstream initialize
        // triggers a fresh upstream initialize. This avoids race/flakiness where the exit event hasn't
        // been processed yet on the event loop.
        #expect(manager.testStateSnapshot().hasInitResult == false)

        // A new downstream initialize joins the already in-flight primary recovery initialize.
        let init2 = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        #expect(await upstream0.sentCount() == 3)
        let upstreamID2 = try extractUpstreamID(from: primaryRecoveryInitialize)
        await upstream0.yield(.message(try makeInitializeResponse(id: upstreamID2)))
        _ = try await init2.get()
    }

    @Test func sessionManagerEagerInitializeRerunsPrimaryInitWhenLastInitializedUpstreamExits()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let upstream0Initialized = TestSignal()
        let upstream1Initialized = TestSignal()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) },
                upstreamInitialized: { upstreamIndex in
                    if upstreamIndex == 0 {
                        upstream0Initialized.signal()
                    } else if upstreamIndex == 1 {
                        upstream1Initialized.signal()
                    }
                }
            )
        )
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(
            .message(try makeInitializeResponse(id: init0ID, serverName: "cached-handshake"))
        )

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(
            .message(try makeInitializeResponse(id: init1ID, serverName: "cached-handshake"))
        )

        // Wait for per-upstream notifications/initialized.
        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))
        try await upstream0Initialized.wait(
            description: "waiting for primary upstream initialization"
        )
        try await upstream1Initialized.wait(
            description: "waiting for secondary upstream initialization"
        )

        // Simulate primary dying first (cached init result should remain because upstream1 is still initialized).
        await upstream0.yield(.exit(1))

        // Primary warm init remains in flight while the last initialized secondary exits.
        _ = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        #expect(manager.testStateSnapshot().upstream(id: 0)?.initInFlight == true)

        // Now simulate the last initialized upstream dying too. Eager init should kick the global init path again.
        let secondaryExitEventIndex = upstreamEvents.count()
        await upstream1.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: secondaryExitEventIndex,
            description: "waiting for secondary upstream exit"
        )
        #expect(
            manager.testStateSnapshot()
                .shouldRetryEagerInitializePrimaryAfterWarmInitFailure
        )
        // Its bounded timeout consumes the recovery intent and restarts eager initialize.
        manager.failInitPending(error: TimeoutError())
        _ = try await sentValue(from: upstream0, at: 3, timeout: .seconds(2))
        _ = manager
    }

    @Test
    func
        sessionManagerRetiresStaticUpstreamAfterPrimaryWarmInitErrorWhenLastInitializedUpstreamExited()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let upstream0Initialized = TestSignal()
        let upstream1Initialized = TestSignal()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) },
                upstreamInitialized: { upstreamIndex in
                    if upstreamIndex == 0 {
                        upstream0Initialized.signal()
                    } else if upstreamIndex == 1 {
                        upstream1Initialized.signal()
                    }
                }
            )
        )
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        // Wait for per-upstream notifications/initialized.
        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))
        try await upstream0Initialized.wait(
            description: "waiting for primary upstream initialization"
        )
        try await upstream1Initialized.wait(
            description: "waiting for secondary upstream initialization"
        )

        // Primary exit triggers warm init on primary.
        await upstream0.yield(.exit(1))
        let retry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let retryID = try extractUpstreamID(from: retry)

        // While primary warm init is in flight, last initialized upstream exits.
        let secondaryExitEventIndex = upstreamEvents.count()
        await upstream1.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: secondaryExitEventIndex,
            description: "waiting for secondary upstream exit"
        )
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == false)

        // Warm init fails with JSON-RPC error.
        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": retryID,
            "error": [
                "code": -1,
                "message": "warm init failed",
            ],
        ]
        let errorEventIndex = upstreamEvents.count()
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: [])))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: errorEventIndex,
            description: "waiting for primary warm init failure"
        )

        // A static slot has no factory for a fresh channel generation, so recovery is terminal.
        #expect(await upstream0.sentCount() == 3)
        #expect(manager.testStateSnapshot().upstream(id: 0)?.isInitialized == nil)
        #expect(manager.testStateSnapshot().hasInitResult == false)
    }

    @Test func sessionManagerPinsSessionsRoundRobinAcrossUpstreams() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // Eager init -> upstream0
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        // Warm init -> upstream1
        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        // Wait for per-upstream notifications/initialized.
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let sessionIDA = "session-A"
        let sessionIDB = "session-B"
        let sessionA = manager.session(id: sessionIDA)
        let sessionB = manager.session(id: sessionIDB)

        let originalA = JSONRPC.ID(any: NSNumber(value: 100))!
        let originalB = JSONRPC.ID(any: NSNumber(value: 101))!

        let upstreamIndexA = try #require(
            manager.chooseUpstreamIndex())
        let upstreamIndexB = try #require(
            manager.chooseUpstreamIndex())
        #expect(upstreamIndexA != upstreamIndexB)

        let futureA = sessionA.router.registerRequest(idKey: originalA.key, on: eventLoop)
        let upstreamIDA = manager.assignUpstreamID(
            sessionID: sessionIDA,
            originalID: originalA,
            upstreamIndex: upstreamIndexA
        )
        manager.sendUpstream(
            try makeToolListRequest(id: upstreamIDA), upstreamIndex: upstreamIndexA)

        let futureB = sessionB.router.registerRequest(idKey: originalB.key, on: eventLoop)
        let upstreamIDB = manager.assignUpstreamID(
            sessionID: sessionIDB,
            originalID: originalB,
            upstreamIndex: upstreamIndexB
        )
        manager.sendUpstream(
            try makeToolListRequest(id: upstreamIDB), upstreamIndex: upstreamIndexB)

        await yieldMessage(
            try makeToolListResponse(id: upstreamIDA),
            to: upstreamIndexA == 0 ? upstream0 : upstream1
        )
        await yieldMessage(
            try makeToolListResponse(id: upstreamIDB),
            to: upstreamIndexB == 0 ? upstream0 : upstream1
        )

        _ = try await futureA.get()
        _ = try await futureB.get()

        let methods0 = await upstream0.sent().compactMap(methodName(from:))
        let methods1 = await upstream1.sent().compactMap(methodName(from:))
        #expect(methods0.filter { $0 == "tools/list" }.count == 1)
        #expect(methods1.filter { $0 == "tools/list" }.count == 1)
    }

    @Test func sessionManagerDropsUnmappedNotificationsAfterInitializeRoutingEnds() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
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

        let sessionIDA = "session-A"
        let sessionIDB = "session-B"
        let sessionA = manager.session(id: sessionIDA)
        let sessionB = manager.session(id: sessionIDB)

        // Ensure we're starting from a clean buffer state.
        _ = sessionA.router.drainBufferedNotifications()
        _ = sessionB.router.drainBufferedNotifications()

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 1],
            ],
            options: []
        )

        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        #expect(
            sessionA.router.drainBufferedNotifications().isEmpty
                && sessionB.router.drainBufferedNotifications().isEmpty
        )
    }

    @Test func sessionManagerDropsUnmappedNotificationsWhenNoPinnedTargetsExist()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
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

        // Create a session, but do not pin it yet.
        let sessionID = "session-A"
        let session = manager.session(id: sessionID)

        // Ensure we're starting from a clean buffer state.
        _ = session.router.drainBufferedNotifications()

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 1],
            ],
            options: []
        )

        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        #expect(session.router.drainBufferedNotifications().isEmpty)
    }

    @Test func sessionManagerDropsUnmappedResponsesEvenWhenPinnedTargetsExist() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        let sessionID = "session-A"
        let session = manager.session(id: sessionID)
        _ = manager.chooseUpstreamIndex()

        _ = session.router.drainBufferedNotifications()

        // Unmapped JSON-RPC response (no `method`) must never be routed to sessions.
        manager.routeUpstreamMessage(try makeToolListResponse(id: 9_999_999), upstreamIndex: 0)
        #expect(session.router.drainBufferedNotifications().isEmpty)
    }

    @Test func sessionManagerDebugSnapshotCapturesTrafficAndStderr() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let initMessages = await upstream.sent()
        let initID = try extractUpstreamID(from: initMessages[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-debug"
        let session = manager.session(id: sessionID)
        let upstreamIndex = try #require(
            manager.chooseUpstreamIndex())
        let original = JSONRPC.ID(any: NSNumber(value: 301))!
        let future = session.router.registerRequest(
            idKey: original.key, on: eventLoop, timeout: .seconds(1))
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: original,
            upstreamIndex: upstreamIndex
        )
        manager.sendUpstream(try makeToolListRequest(id: upstreamID), upstreamIndex: upstreamIndex)
        await upstream.yield(.message(try makeToolListResponse(id: upstreamID)))
        _ = try await future.get()

        let debugEventIndex = upstreamEvents.count()
        await upstream.yield(.message(try makeToolListResponse(id: 9_999_999)))
        await upstream.yield(
            .stderr("Could not decode agent message: Error Domain=mcpbridge.DecodeError Code=1"))
        await upstream.yield(
            .stderr(
                "callTool request for 'DocumentationSearch' failed: Error Domain=IDEIntelligenceMessaging.BridgeError Code=1"
            ))
        await upstream.yield(
            .stdoutProtocolViolation(
                StdioFramer.ProtocolViolation(
                    reason: .invalidJSON,
                    bufferedByteCount: 1024,
                    preview: "...broken"
                )
            )
        )
        await upstream.yield(.stdoutBufferSize(2048))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: debugEventIndex + 4,
            description: "waiting for upstream debug events"
        )

        let snapshot = manager.debugSnapshot()
        #expect(snapshot.upstreams.count == 1)
        #expect(snapshot.upstreams[0].lastDecodeError?.message == "<redacted>")
        #expect(snapshot.upstreams[0].lastBridgeError?.message == "<redacted>")
        #expect(snapshot.upstreams[0].protocolViolationCount == 1)
        #expect(snapshot.upstreams[0].lastProtocolViolationReason == "invalidJSON")
        #expect(snapshot.upstreams[0].lastProtocolViolationBufferedBytes == 1024)
        #expect(snapshot.upstreams[0].lastProtocolViolationPreview == "<redacted>")
        #expect(snapshot.upstreams[0].lastProtocolViolationPreviewHex == "<redacted>")
        #expect(snapshot.upstreams[0].lastProtocolViolationLeadingByteHex == nil)
        #expect(snapshot.upstreams[0].bufferedStdoutBytes == 2048)
        #expect(snapshot.recentTraffic.contains { $0.direction == "outbound" && $0.bytes > 0 })
        #expect(
            snapshot.recentTraffic.contains {
                $0.direction == "inbound" && $0.preview == "<redacted>"
            })
        #expect(
            snapshot.recentTraffic.contains {
                $0.direction == "inbound_unmapped" && $0.preview == "<redacted>"
            })
        #expect(snapshot.upstreams[0].recentStderr.allSatisfy { $0.message == "<redacted>" })

        let exitEventIndex = upstreamEvents.count()
        await upstream.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: exitEventIndex,
            description: "waiting for upstream exit debug reset"
        )

        let clearedSnapshot = manager.debugSnapshot()
        #expect(clearedSnapshot.upstreams[0].recentStderr.isEmpty)
        #expect(clearedSnapshot.upstreams[0].lastDecodeError == nil)
        #expect(clearedSnapshot.upstreams[0].lastBridgeError == nil)
        #expect(clearedSnapshot.upstreams[0].protocolViolationCount == 0)
        #expect(clearedSnapshot.upstreams[0].lastProtocolViolationPreview == nil)
        #expect(clearedSnapshot.upstreams[0].lastProtocolViolationPreviewHex == nil)
        #expect(clearedSnapshot.upstreams[0].lastProtocolViolationLeadingByteHex == nil)
        #expect(clearedSnapshot.upstreams[0].bufferedStdoutBytes == 0)
    }

    @Test func sessionManagerReturnsNilWhenAllUpstreamsAreQuarantined() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let toolsListRefreshes = LockedRecordedValues<(Int, Bool)>()
        var config = makeConfig(requestTimeout: 2)
        config.prewarmToolsList = true
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) },
                toolsListRefreshCompleted: { toolsListRefreshes.append(($0, $1)) }
            )
        )
        defer { manager.shutdownAndWait() }

        // Initialize primary upstream0.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        // Warm init -> upstream1.
        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        // Wait for per-upstream notifications/initialized.
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        // Fail tools/list warmup on upstream0 to mark it unhealthy.
        manager.refreshToolsListIfNeeded()
        let warmup0 = try await sentMessage(
            from: upstream0,
            matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2)
        )
        let warmup0ID = try extractUpstreamID(from: warmup0)
        let warmup0Response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": warmup0ID,
            "result": [:],  // invalid (no `tools` array) -> marks upstream unhealthy
        ]
        let warmup0RefreshIndex = toolsListRefreshes.count()
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: warmup0Response, options: [])))
        _ = try await waitForRecordedValue(
            toolsListRefreshes,
            at: warmup0RefreshIndex,
            description: "waiting for first tools/list warmup failure"
        )
        let upstream0Health = try #require(
            manager.testStateSnapshot().upstream(id: 0)?.healthState
        )
        switch upstream0Health {
        case .healthy:
            Issue.record("upstream0 should be degraded after invalid tools/list warmup")
        case .degraded, .quarantined:
            break
        }

        // Trigger another warmup; it should prefer upstream1 and fail there too so no healthy upstream exists.
        manager.refreshToolsListIfNeeded()
        let warmup1 = try await sentMessage(
            from: upstream1,
            matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2)
        )
        let warmup1ID = try extractUpstreamID(from: warmup1)
        let warmup1Response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": warmup1ID,
            "result": [:],
        ]
        let warmup1RefreshIndex = toolsListRefreshes.count()
        await upstream1.yield(
            .message(try JSONSerialization.data(withJSONObject: warmup1Response, options: [])))
        _ = try await waitForRecordedValue(
            toolsListRefreshes,
            at: warmup1RefreshIndex,
            description: "waiting for second tools/list warmup failure"
        )

        let chosen = manager.chooseUpstreamIndex()
        #expect(chosen == nil)
    }

    @Test func sessionManagerEnqueueOnUpstreamSlotStartsRecoveryProbeWhenAllUpstreamsAreQuarantined() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let uptimeClock = TestUptimeClock(nowUptimeNanoseconds: 20_000_000_000)
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: { uptimeClock.now() }
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        try await spinUntilSentCount(
            upstream,
            count: 1,
            description: "waiting for eager initialize request"
        )
        let initRequest = try #require(await upstream.sentValue(at: 0))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await spinUntilSentCount(
            upstream,
            count: 2,
            description: "waiting for initialized notification"
        )

        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-quarantine-recovery",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let future: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop
        ) { _ in
            eventLoop.makeSucceededFuture(())
        }

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            try await future.get()
        }

        try await spinUntilSentCount(
            upstream,
            count: 3,
            description: "waiting for recovery probe request"
        )
        let probe = try #require(await upstream.sentValue(at: 2))
        #expect(methodName(from: probe) == "tools/list")
    }

    @Test func sessionManagerQueuedRequestStartsProbeForExpiredQuarantinedUpstream() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let uptimeClock = TestUptimeClock(nowUptimeNanoseconds: 20_000_000_000)
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            nowUptimeNanoseconds: { uptimeClock.now() }
        )
        defer { manager.shutdownAndWait() }

        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex.upstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        guard let upstream = manager.testStateSnapshot().upstream(id: 1),
              case .quarantined = upstream.healthState else {
            Issue.record("expected upstream1 to be quarantined before queueing request")
            return
        }

        let queuedRequestData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": NSNumber(value: 99),
                "method": "tools/list",
            ],
            options: []
        )
        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/list",
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
            manager.sendUpstream(
                queuedRequestData,
                operationLease: selectedUpstreamIndex,
                ensureRunning: false,
                admission: nil,
                onRejected: {}
            )
            return eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        try await spinUntilSentCount(
            upstream1,
            count: 1,
            description: "waiting for recovery probe request"
        )
        let probeRequest = try #require(await upstream1.sentValue(at: 0))
        #expect(methodName(from: probeRequest) == "tools/list")
        let probeID = try extractUpstreamID(from: probeRequest)
        #expect(probeID != 99)
        let probeResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: probeID),
            "result": [
                "tools": [Any]()
            ],
        ]
        await upstream1.yield(
            .message(try JSONSerialization.data(withJSONObject: probeResponse, options: []))
        )

        _ = try await queuedFuture.get()
        try await spinUntilSentCount(
            upstream1,
            count: 2,
            description: "waiting for queued request dispatch after probe recovery"
        )
        let queuedRequest = try #require(await upstream1.sentValue(at: 1))
        #expect(methodName(from: queuedRequest) == "tools/list")
        #expect(try extractUpstreamID(from: queuedRequest) == 99)

        activePromise.fail(CancellationError())
    }

    @Test func sessionManagerQueuedPreferredRequestDoesNotBlockLaterGenericDispatch()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex.upstreamIndex,
                timeout: nil
            )
            #expect(selectedUpstreamIndex.upstreamIndex == 0)
            return activePromise.futureResult
        }
        _ = activeFuture

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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let timeoutEventLoop = NIOAsyncTestingEventLoop()
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

    @Test func sessionManagerInitializeReturnsOverloadedErrorWhenUpstreamRejectsSend() async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
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

    @Test func sessionManagerRetiresStaticUpstreamWhenInitializedNotificationSendOverloads()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initialInitialize = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)
        await upstream.overloadNextInitializedNotificationSend()
        await upstream.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
        await manager.drainRuntimeTasksForTesting()
        #expect(await upstream.sentCount() == 2)
        #expect(manager.testStateSnapshot().upstream(id: 0)?.isInitialized == nil)
        #expect(manager.testStateSnapshot().hasInitResult == false)
    }

    @Test func sessionManagerPrimaryInitializedNotificationOverloadClearsSecondaryStateAndToolsCache()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        #expect(manager.cachedToolsListResult() != nil)
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == true)
        let chosen = manager.chooseUpstreamIndex()
        #expect(chosen == 1)
    }

    @Test func sessionManagerPrimaryWarmReinitOverloadReturnsPendingInitializeAndRetiresStaticPrimary()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        manager.canonicalHandshakeState.clearInitialize()
        manager.initializeManager.resetWarmSecondaryForRetry()
        let cachedHandshake = try #require(JSONValue(any: [
            "protocolVersion": MCP.ProtocolVersion.current,
            "capabilities": [String: Any](),
            "serverInfo": ["name": "cached-handshake"],
        ]))
        manager.canonicalHandshakeState.syncCanonicalInitialize(cachedHandshake, sourceUpstream: 0)
        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 77))!,
            requestObject: makeInitializeRequest(id: 77),
            on: eventLoop
        )

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(
            .message(try makeInitializeResponse(
                id: warmRetryID,
                serverName: "cached-handshake"
            ))
        )

        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "healthy secondary should satisfy pending initialize during primary warm retry",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        #expect(response["result"] != nil)
        let result = try #require(response["result"] as? [String: Any])
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "cached-handshake")

        try await waitForSentCount(upstream0, count: 4, timeoutSeconds: 2)
        await manager.drainRuntimeTasksForTesting()
        #expect(await upstream0.sentCount() == 4)
        #expect(manager.testStateSnapshot().upstream(id: 0)?.isInitialized == nil)
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == true)
    }

    @Test func sessionManagerPrimaryWarmReinitOverloadRetiresStaticPrimaryWhenSecondaryIsQuarantined()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)

        guard let upstream = manager.testStateSnapshot().upstream(id: 1),
              case .quarantined = upstream.healthState else {
            Issue.record("expected upstream1 to be quarantined")
            return
        }

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
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == false)
    }

    @Test func sessionManagerIgnoresStaleSecondaryInitializedNotificationAfterReset()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

    @Test func sessionManagerPrimaryWarmReinitOverloadFallsBackToEagerInitAfterWarmRetryFailure()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = ToggleableOverloadUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let replacementUpstreams = NIOLockedValueBox<[ToggleableOverloadUpstreamClient]>([])
        let primaryTarget = xcodeProcessTarget(processID: 27120, xcodeVersion: "27.0")
        let secondaryTarget = xcodeProcessTarget(processID: 26620, xcodeVersion: "26.6")
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: primaryTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: secondaryTarget, upstreamIndices: [1]),
            ],
            dynamicUpstreamFactory: { target in
                guard target.processID == primaryTarget.processID else {
                    return [TestUpstreamClient()]
                }
                let upstream = ToggleableOverloadUpstreamClient()
                replacementUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))

        let cachedInitialize = try #require(manager.canonicalHandshakeState.initializeResult())
        let primaryProof = manager.operationLeaseForTest(upstreamIndex: 0).proof
        #expect(manager.clearUpstreamState(proof: primaryProof))
        manager.canonicalHandshakeState.syncCanonicalInitialize(
            cachedInitialize,
            sourceUpstream: 0
        )
        manager.startUpstreamWarmInitialize(upstreamIndex: 0)
        let firstWarmRetry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let firstWarmRetryID = try extractUpstreamID(from: firstWarmRetry)

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(.message(try makeInitializeResponse(id: firstWarmRetryID)))

        let firstReplacement = try await waitWithTimeout(
            "waiting for primary replacement after initialized notification overload"
        ) {
            while true {
                if let upstream = replacementUpstreams.withLockedValue({ $0.first }) {
                    return upstream
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(
            manager.testStateSnapshot()
                .shouldRetryEagerInitializePrimaryAfterWarmInitFailure
        )
        let secondWarmRetry = try await sentValue(
            from: firstReplacement,
            startingAt: 0,
            matching: { methodName(from: $0) == "initialize" },
            timeout: .seconds(2),
            description: "waiting for warm initialize on first replacement"
        )
        let secondWarmRetryID = try extractUpstreamID(from: secondWarmRetry)

        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: secondWarmRetryID),
            "error": [
                "code": -1,
                "message": "warm init failed",
            ],
        ]
        let errorEventIndex = upstreamEvents.count()
        await firstReplacement.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: []))
        )
        _ = try await nextRecordedValue(upstreamEvents, at: errorEventIndex)
        #expect(
            manager.testStateSnapshot()
                .shouldRetryEagerInitializePrimaryAfterWarmInitFailure
        )

        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        manager.failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
        #expect(manager.testStateSnapshot().initInFlight)

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-recovery-trigger",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let future: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop
        ) { _ in
            eventLoop.makeSucceededFuture(())
        }
        defer {
            manager.abandonRequestLease(
                leaseID,
                sessionID: "session-recovery-trigger",
                requestIDKeys: [],
                upstreamIndex: nil
            )
        }
        _ = future

        let secondReplacement = try await waitWithTimeout(
            "waiting for primary replacement after warm initialize failure"
        ) {
            while true {
                if let upstream = replacementUpstreams.withLockedValue({ $0.dropFirst().first }) {
                    return upstream
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let eagerRetry = try await sentValue(
            from: secondReplacement,
            startingAt: 0,
            matching: { methodName(from: $0) == "initialize" },
            timeout: .seconds(2),
            description: "waiting for eager initialize on second replacement"
        )
        #expect(methodName(from: eagerRetry) == "initialize")

        manager.abandonRequestLease(
            leaseID,
            sessionID: "session-recovery-trigger",
            requestIDKeys: [],
            upstreamIndex: nil
        )
        await #expect(throws: CancellationError.self) {
            try await future.get()
        }
    }

    @Test func sessionManagerAbandonQueuedRequestFailsPendingFuture() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex.upstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

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

        activePromise.fail(CancellationError())
    }

    @Test func sessionManagerAbandonRequestLeaseDropsLateResponseAndReleasesSlot() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

    @Test func sessionManagerDoesNotReactivateAbandonedLease() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

    @Test func sessionManagerUpstreamExitClearsCanonicalToolsCatalogImmediately() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex.upstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

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
        activePromise.fail(CancellationError())
    }

    @Test func sessionManagerFailsQueuedRequestsWhenHealthProbeRecoveryFails() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: "active-request",
                upstreamIndex: selectedUpstreamIndex.upstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

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

        activePromise.fail(CancellationError())
    }

    @Test func sessionManagerDebugResetClearsSessionsLeasesAndCache() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 523, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 522, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace",
                    ],
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex.upstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

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

        activePromise.fail(CancellationError())
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
            timeoutAt: Date().addingTimeInterval(30)
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

    @Test func upstreamSlotSchedulerSerializesTopLevelRequestsPerSessionAcrossUpstreams()
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
                Issue.record("second request should wait for the session slot, not fail unavailable")
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
                Issue.record("third request should use the other upstream")
            },
            failCancelled: {
                Issue.record("third request should not be cancelled")
            }
        )
        eventLoop.run()

        #expect(started.withLockedValue { $0 } == ["first@0", "third@1"])
        #expect(scheduler.debugSnapshot().queuedRequestCount == 1)

        scheduler.releaseUpstreamSlot(upstreamIndex: 0, leaseID: firstLeaseID)
        eventLoop.run()

        #expect(started.withLockedValue { $0 } == ["first@0", "third@1", "second@0"])
        #expect(scheduler.debugSnapshot().queuedRequestCount == 0)
    }

    private func waitForProcessRouteActivationInitialized(
        _ manager: RuntimeCoordinator,
        processID: pid_t,
        upstreamIndex expectedUpstreamIndex: Int,
        attempt expectedAttempt: Int,
        message: String
    ) async throws {
        _ = try await waitWithTimeout(message, timeout: .seconds(2)) {
            while true {
                if let snapshot = manager.processControlPlane.attemptSnapshot(processID: processID),
                   [.initialized, .loadingCatalog].contains(snapshot.phase),
                   snapshot.upstreamID.rawValue == expectedUpstreamIndex,
                   snapshot.attemptID.rawValue == expectedAttempt {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

}

private actor AutoToolsListUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let sentMessages = RecordedValues<Data>()
    private let toolNames: [String]

    init(toolNames: [String]) {
        self.toolNames = toolNames
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        await sentMessages.append(data)
        guard methodName(from: data) == "tools/list",
              let upstreamID = try? extractUpstreamID(from: data),
              let response = try? makeDocumentationToolsListResponse(
                  id: upstreamID,
                  tools: toolNames.map { toolDescriptor(name: $0) }
              )
        else {
            return .accepted
        }
        continuation.yield(.message(response))
        return .accepted
    }

    func sentCount() async -> Int {
        await sentMessages.count()
    }
}

private func firstTabIdentifier(in message: String) -> String? {
    for line in message.split(separator: "\n") {
        let prefix = "* tabIdentifier: "
        guard line.hasPrefix(prefix),
              let delimiter = line.range(of: ", workspacePath: ") else {
            continue
        }
        return String(line[line.index(line.startIndex, offsetBy: prefix.count)..<delimiter.lowerBound])
    }
    return nil
}

private func tabIdentifier(in data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
          let params = object["params"] as? [String: Any],
          let arguments = params["arguments"] as? [String: Any] else {
        return nil
    }
    return arguments["tabIdentifier"] as? String
}

private final class BlockingSequencedXcodeTargetDiscovery:
    XcodeTargetDiscovering,
    @unchecked Sendable
{
    let firstStarted = TestSignal()
    let secondStarted = TestSignal()

    private let lock = NSLock()
    private let firstTargets: [XcodeProcessTarget]
    private let secondTargets: [XcodeProcessTarget]
    private let releaseFirstSemaphore = DispatchSemaphore(value: 0)
    private var callCountValue = 0
    private var firstReleased = false

    init(
        firstTargets: [XcodeProcessTarget],
        secondTargets: [XcodeProcessTarget]
    ) {
        self.firstTargets = firstTargets
        self.secondTargets = secondTargets
    }

    func runningXcodeTargets() -> [XcodeProcessTarget] {
        let call = nextCallCount()
        if call == 1 {
            firstStarted.signal()
            releaseFirstSemaphore.wait()
            return firstTargets
        }
        if call == 2 {
            secondStarted.signal()
        }
        return secondTargets
    }

    func releaseFirst() {
        let shouldRelease = lock.withLock { () -> Bool in
            guard firstReleased == false else {
                return false
            }
            firstReleased = true
            return true
        }
        if shouldRelease {
            releaseFirstSemaphore.signal()
        }
    }

    func callCount() -> Int {
        lock.withLock { callCountValue }
    }

    private func nextCallCount() -> Int {
        lock.withLock {
            callCountValue += 1
            return callCountValue
        }
    }
}

private final class RecordingXcodeTargetDiscovery: XcodeTargetDiscovering, @unchecked Sendable {
    let calls = LockedRecordedValues<Int>()

    private let lock = NSLock()
    private let targets: [XcodeProcessTarget]
    private var callCountValue = 0

    init(targets: [XcodeProcessTarget]) {
        self.targets = targets
    }

    func runningXcodeTargets() -> [XcodeProcessTarget] {
        let call = lock.withLock {
            callCountValue += 1
            return callCountValue
        }
        calls.append(call)
        return targets
    }
}
