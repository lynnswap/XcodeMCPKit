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
struct RuntimeCoordinatorProcessRoutingTests {
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

    @Test func headlessStockBridgeBuildsOnlyUnboundUpstreamsDespiteGUITargets() throws {
        try withEnvironmentVariables(["MCP_XCODE_PID": "5678"]) {
            var config = makeConfig(requestTimeout: 0)
            config.xcodeMode = .headless

            let plan = MCPBridgeRuntime.makeUpstreamPlan(
                config: makeBridgeRuntimeConfig(config),
                xcodeTargets: [xcodeProcessTarget(processID: 101)]
            )

            #expect(ProxyRuntime.supportsProcessBoundRouting(configuration: config) == false)
            #expect(plan.upstreams.count == 1)
            #expect(plan.xcodeProcessRoutes.isEmpty)
            let upstream = try #require(plan.upstreams.first)
            let environment = try upstreamEnvironment(from: upstream)
            #expect(environment["MCP_XCODE_PID"] == nil)
            #expect(environment["DEVELOPER_DIR"] == nil)
        }
    }

    @Test func processRoutingWithoutInitialTargetsRunsReadinessAutoLaunch() async throws {
        let readiness = ReadinessFlag(isReady: false)
        let launchRecorder = XcodeLaunchRecorder()
        let discovery = RecordingXcodeTargetDiscovery(targets: [])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                launchRecorder: launchRecorder
            ),
            processRoutingEnabled: true,
            xcodeTargetDiscovery: discovery
        )
        defer { fixture.shutdownAndWait() }

        _ = try await waitWithTimeout("waiting for no-target Xcode launch", timeout: .seconds(2)) {
            try await launchRecorder.nextLaunch(at: 0)
        }
        let generation = try await readiness.nextChangeWait(at: 0)

        #expect(generation == 0)
        #expect(fixture.manager.debugSnapshot().upstreams.isEmpty)
        #expect(fixture.manager.debugSnapshot().processRoutes.isEmpty)
    }

    @Test func defaultCoordinatorWithoutDiscoveryUsesStaticFallbackUpstream() async throws {
        let group = borrowSharedTestEventLoopGroup()
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

    @Test(arguments: [
        ProxyRuntimeConfiguration.XcodeMode.gui,
        .headless,
        .custom,
    ])
    func autoApprovalStartsProcessInventoryOutsideProcessRouting(
        xcodeMode: ProxyRuntimeConfiguration.XcodeMode
    ) async {
        var config = makeConfig(requestTimeout: 0)
        config.xcodeMode = xcodeMode
        config.usesPermissionDialogAutomation = true
        let monitor = StartRecordingXcodeProcessMonitor()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: MultiThreadedEventLoopGroup.singleton.next(),
            upstreams: [TestUpstreamClient()],
            processRoutingEnabled: false,
            xcodeProcessEventMonitor: monitor,
            startImmediately: false
        )
        manager.start()

        #expect(monitor.startCount() == 1)
        #expect(monitor.changeHandlerCount() == 0)
        #expect(manager.processRoutingEnabled == false)
        #expect(manager.debugSnapshot().processRoutes.isEmpty)

        await manager.shutdown()
        #expect(monitor.stopCount() == 1)
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
                XcodeProcessRoute(target: target, upstreamIndices: [0])
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
        let discovery = ConcurrentSequencedXcodeTargetDiscovery(
            firstTargets: [olderTarget],
            secondTargets: [newerTarget]
        )
        let routeCreations = LockedRecordedValues<pid_t>()
        let reconcileCompletions = LockedRecordedValues<String>()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            processRoutingEnabled: true,
            xcodeTargetDiscovery: discovery,
            dynamicUpstreamFactory: { target in
                routeCreations.append(target.processID)
                return [TestUpstreamClient()]
            },
            testHooks: RuntimeCoordinatorTestHooks(
                xcodeProcessReconcileCompleted: { reconcileCompletions.append($0) }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        discovery.setFirstCallAction {
            #expect(discovery.callCount() == 1)
            manager.triggerXcodeProcessReconcile(reason: "second_snapshot")
            #expect(discovery.callCount() == 1)
        }
        manager.triggerXcodeProcessReconcile(reason: "first_snapshot")

        #expect(
            try await waitForRecordedValue(
                routeCreations,
                at: 1,
                description: "waiting for queued reconcile route creation"
            ) == newerTarget.processID
        )
        #expect(discovery.callCount() == 2)
        #expect(
            try await waitForRecordedValue(
                reconcileCompletions,
                at: 0,
                description: "waiting for first reconcile completion"
            ) == "first_snapshot"
        )
        #expect(
            try await waitForRecordedValue(
                reconcileCompletions,
                at: 1,
                description: "waiting for queued reconcile completion"
            ) == "second_snapshot"
        )
        #expect(manager.xcodeProcessRoutes.map(\.target.processID) == [newerTarget.processID])
        let processRoutes = manager.debugSnapshot().processRoutes
        #expect(
            processRoutes.map(\.processID) == [
                newerTarget.processID,
                olderTarget.processID,
            ])
        #expect(processRoutes.map(\.state) == ["active", "retired"])
    }

    @Test func processRoutingStartupConsumesInventoryChangeBeforeEagerInitialization() async throws {
        let olderTarget = xcodeProcessTarget(processID: 27045, xcodeVersion: "26.6")
        let newerTarget = xcodeProcessTarget(processID: 27046, xcodeVersion: "27.0")
        let createdUpstreams = NIOLockedValueBox<[pid_t: TestUpstreamClient]>([:])
        let monitor = StartupChangingXcodeProcessMonitor(
            firstTargets: [olderTarget],
            latestTargets: [newerTarget]
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: MultiThreadedEventLoopGroup.singleton.next(),
            upstreams: [],
            processRoutingEnabled: true,
            xcodeTargetDiscovery: monitor,
            xcodeProcessEventMonitor: monitor,
            dynamicUpstreamFactory: { target in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0[target.processID] = upstream }
                return [upstream]
            },
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }

        manager.start()

        #expect(monitor.discoveryCallCount() == 2)
        #expect(manager.xcodeProcessRoutes.map(\.target.processID) == [newerTarget.processID])
        let newerUpstream = try #require(
            createdUpstreams.withLockedValue { $0[newerTarget.processID] }
        )
        _ = try await newerUpstream.nextStartCount(at: 1)
        await manager.drainRuntimeTasksForTesting()
        #expect(await newerUpstream.startCount() == 2)
    }

    @Test func processRoutingReschedulesQueuedReconcileAfterWorkerCancellation() async throws {
        let canceledTarget = xcodeProcessTarget(processID: 27006, xcodeVersion: "26.6")
        let recoveredTarget = xcodeProcessTarget(processID: 27007, xcodeVersion: "27.0")
        let discovery = ConcurrentSequencedXcodeTargetDiscovery(
            firstTargets: [canceledTarget],
            secondTargets: [recoveredTarget]
        )
        let routeCreations = LockedRecordedValues<pid_t>()
        let reconcileCompletions = LockedRecordedValues<String>()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            processRoutingEnabled: true,
            xcodeTargetDiscovery: discovery,
            dynamicUpstreamFactory: { target in
                routeCreations.append(target.processID)
                return [TestUpstreamClient()]
            },
            testHooks: RuntimeCoordinatorTestHooks(
                xcodeProcessReconcileCompleted: { reconcileCompletions.append($0) }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        discovery.setFirstCallAction {
            #expect(discovery.callCount() == 1)
            manager.debugReset()
            manager.triggerXcodeProcessReconcile(reason: "queued_after_cancel")
            #expect(discovery.callCount() == 1)
        }
        manager.triggerXcodeProcessReconcile(reason: "cancelled_snapshot")

        #expect(
            try await waitForRecordedValue(
                routeCreations,
                at: 0,
                description: "waiting for post-cancellation reconcile route creation"
            ) == recoveredTarget.processID
        )
        #expect(discovery.callCount() == 2)
        #expect(
            try await waitForRecordedValue(
                reconcileCompletions,
                at: 0,
                description: "waiting for post-cancellation reconcile completion"
            )
                == "queued_after_cancel"
        )
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

        let replacement = try #require(createdUpstreams.withLockedValue { $0.dropFirst().first })
        #expect(try await upstream.nextStopCount() == 1)
        let retryTimeoutIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .milliseconds(250),
            startingAtEventIndex: 2
        )
        #expect(timeoutScheduler.fire(at: retryTimeoutIndex))
        _ = try await replacement.nextSent(at: 0)

        timeoutScheduler.fire(at: 0)
        await #expect(throws: TimeoutError.self) {
            try await future.get()
        }
    }

    @Test func processRouteActivationUsesShortTimeoutWhenAutoApproveEnabled() async throws {
        var config = makeConfig(requestTimeout: 5)
        config.usesPermissionDialogAutomation = true
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

    @Test func processRouteActivationPreservesDisabledCatalogTimeout() async throws {
        var config = makeConfig(requestTimeout: 0)
        config.usesPermissionDialogAutomation = true
        let target = xcodeProcessTarget(processID: 27025, xcodeVersion: "27.0")
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

        fixture.manager.reconcileXcodeProcessTargets(
            [target],
            reason: "test_disabled_catalog_timeout"
        )
        let upstream = try #require(createdUpstreams.withLockedValue { $0.first })
        let initialize = try await sentValue(
            from: upstream,
            startingAt: 0,
            matching: { methodName(from: $0) == "initialize" },
            description: "waiting for activation initialize"
        )
        await upstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: initialize)))
        )
        _ = try await sentValue(
            from: upstream,
            startingAt: 1,
            matching: { methodName(from: $0) == "tools/list" },
            description: "waiting for activation catalog"
        )

        #expect(timeoutScheduler.scheduledCount() == 1)
        #expect(timeoutScheduler.delay(at: 0)?.nanoseconds == TimeAmount.seconds(3).nanoseconds)
        #expect(timeoutScheduler.isCancelled(at: 0))
    }

    @Test func processRouteActivationCatalogTimeoutCancelsBeforeRetryingSameSlot()
        async throws
    {
        var config = makeConfig(requestTimeout: 300)
        config.usesPermissionDialogAutomation = true
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
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0])
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
                (olderTarget, 0, [toolDescriptor(name: "Only26")])
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
        await firstAttempt.blockNextCancellation()
        #expect(timeoutScheduler.fire(at: 2))
        try await firstAttempt.waitForBlockedCancellation()
        let cancellation = try await waitWithTimeout(
            "waiting for timed-out catalog cancellation",
            timeout: .seconds(2)
        ) {
            try await firstAttempt.nextSent(
                startingAt: 3,
                matching: { methodName(from: $0) == "notifications/cancelled" }
            )
        }
        let cancellationObject = try #require(
            JSONSerialization.jsonObject(with: cancellation, options: []) as? [String: Any]
        )
        let cancellationParams = try #require(
            cancellationObject["params"] as? [String: Any]
        )
        let staleToolsUpstreamID = try extractUpstreamID(from: staleToolsRequest)
        #expect(
            (cancellationParams["requestId"] as? NSNumber)?.int64Value
                == staleToolsUpstreamID
        )
        #expect(await firstAttempt.stopCount() == 0)
        #expect(createdUpstreams.withLockedValue(\.count) == 1)
        #expect(timeoutScheduler.scheduledCount() == 3)

        await firstAttempt.releaseBlockedCancellation()
        let retryTimeoutIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .milliseconds(250),
            startingAtEventIndex: 3
        )
        #expect(timeoutScheduler.fire(at: retryTimeoutIndex))
        let retryToolsRequest = try await waitWithTimeout(
            "waiting for catalog retry on the existing activation slot",
            timeout: .seconds(2)
        ) {
            try await firstAttempt.nextSent(
                startingAt: 4,
                matching: { methodName(from: $0) == "tools/list" }
            )
        }

        await firstAttempt.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: staleToolsRequest),
                    tools: [
                        toolDescriptor(name: "Stale27")
                    ]
                )
            )
        )
        #expect(manager.processControlPlane.catalog(forProcessID: newerTarget.processID) == nil)

        await firstAttempt.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: retryToolsRequest),
                    tools: [
                        toolDescriptor(name: "Only27")
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

        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set([
                    "Only26",
                    "Only27",
                ]))
        #expect(
            Set(manager.debugSnapshot().processToolCatalogs.map(\.processID))
                == Set([
                    olderTarget.processID,
                    newerTarget.processID,
                ]))
    }

    @Test func catalogCancellationOutcomeControlsRetryAndChannelRecovery()
        async throws
    {
        let target = xcodeProcessTarget(processID: 27027, xcodeVersion: "27.0")
        let initial = TestUpstreamClient()
        let replacements = NIOLockedValueBox<[TestUpstreamClient]>([])
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
                "serverInfo": ["name": "catalog-cancellation-source"],
            ]),
            sourceUpstream: 0
        )
        let route = try #require(manager.processControlPlane.route(
            forProcessID: target.processID
        ))
        let proof = try #require(manager.upstreamTopology.operationLease(
            for: UpstreamSlotID(rawValue: 0)
        )?.proof)

        func prepareRetryLease(at uptimeNanoseconds: UInt64) throws -> CatalogLease {
            let (lease, transition) = try #require(
                manager.processControlPlane.beginCatalogAttempt(
                    routeID: route.id,
                    preferredUpstreamProof: proof,
                    nowUptimeNanoseconds: uptimeNanoseconds
                )
            )
            manager.applyProcessControlPlaneTransition(transition)
            manager.applyCatalogCommit(manager.processControlPlane.completeCatalog(
                .unusable,
                lease: lease,
                nowUptimeNanoseconds: uptimeNanoseconds &+ 1
            ))
            return lease
        }

        let obsoleteLease = try prepareRetryLease(at: 1)
        let obsoleteCancellation = ControlPlane.RPCCancellationDelivery()
        manager.scheduleMissingProcessToolsCatalogRetry(
            processID: target.processID,
            lease: obsoleteLease,
            after: [obsoleteCancellation],
            reason: "test_obsolete_cancellation"
        )
        obsoleteCancellation.complete(.noLongerApplicable)
        let obsoleteRetryIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .milliseconds(250),
            startingAtEventIndex: 0
        )
        manager.applyProcessControlPlaneTransition(
            manager.processControlPlane.resetAttempt(processID: target.processID)
        )
        #expect(timeoutScheduler.isCancelled(at: obsoleteRetryIndex))

        let rejectedLease = try prepareRetryLease(at: 3)
        let operationLease = manager.operationLeaseForTest(upstreamIndex: 0)
        let sessionID = "rejected-catalog-cancellation"
        let originalID = try #require(JSONRPC.ID(any: NSNumber(value: 1)))
        let requestLeaseID = manager.createRequestLease(
            descriptor: SessionRequestPipeline.Descriptor(
                sessionID: sessionID,
                label: "tools/list",
                expectsResponse: true,
                isTopLevelClientRequest: false
            )
        )
        let upstreamID = try #require(manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: originalID,
            operationLease: operationLease
        ))
        manager.activateRequestLease(
            requestLeaseID,
            requestIDKey: originalID.key,
            upstreamIndex: 0,
            timeout: .seconds(300)
        )
        await initial.blockNextCancellation()
        let cancellation = try #require(
            manager.handleRequestLeaseTimeoutWithCancellationDelivery(
                requestLeaseID,
                sessionID: sessionID,
                requestIDKeys: [originalID.key],
                operationLease: operationLease
            )
        )
        manager.scheduleMissingProcessToolsCatalogRetry(
            processID: target.processID,
            lease: rejectedLease,
            after: [cancellation],
            reason: "test_rejected_cancellation"
        )
        try await initial.waitForBlockedCancellation()
        let cancellationData = try await initial.nextSent(
            matching: { methodName(from: $0) == "notifications/cancelled" }
        )
        #expect(try extractCancellationRequestID(from: cancellationData) == upstreamID)
        await initial.releaseBlockedCancellation(.backpressure)

        #expect(
            try await initial.nextStopCount(timeout: .seconds(2)) == 1
        )
        #expect(replacements.withLockedValue(\.count) == 1)
        #expect(
            manager.upstreamTopology.operationLease(
                for: UpstreamSlotID(rawValue: 0)
            )?.proof != proof
        )
        let activationRetryIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .milliseconds(500),
            startingAtEventIndex: obsoleteRetryIndex + 1
        )
        #expect(timeoutScheduler.fire(at: activationRetryIndex))
        let replacement = try #require(replacements.withLockedValue { $0.first })
        _ = try await replacement.nextSent(
            matching: { methodName(from: $0) == "initialize" }
        )
    }

    @Test func rejectedStaleCatalogCancellationRestartsCurrentAttempt() async throws {
        let target = xcodeProcessTarget(processID: 27028, xcodeVersion: "27.0")
        let initial = TestUpstreamClient()
        let replacements = NIOLockedValueBox<[TestUpstreamClient]>([])
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
                "serverInfo": ["name": "stale-catalog-cancellation-source"],
            ]),
            sourceUpstream: 0
        )
        let route = try #require(
            manager.processControlPlane.route(forProcessID: target.processID)
        )
        let operationLease = manager.operationLeaseForTest(upstreamIndex: 0)
        let proof = operationLease.proof
        let (staleLease, transition) = try #require(
            manager.processControlPlane.beginCatalogAttempt(
                routeID: route.id,
                preferredUpstreamProof: proof,
                nowUptimeNanoseconds: 1
            )
        )
        manager.applyProcessControlPlaneTransition(transition)
        manager.applyCatalogCommit(manager.processControlPlane.completeCatalog(
            .unusable,
            lease: staleLease,
            nowUptimeNanoseconds: 2
        ))

        let sessionID = "stale-catalog-cancellation"
        let originalID = try #require(JSONRPC.ID(any: NSNumber(value: 1)))
        let requestLeaseID = manager.createRequestLease(
            descriptor: SessionRequestPipeline.Descriptor(
                sessionID: sessionID,
                label: "tools/list",
                expectsResponse: true,
                isTopLevelClientRequest: false
            )
        )
        _ = try #require(manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: originalID,
            operationLease: operationLease
        ))
        manager.activateRequestLease(
            requestLeaseID,
            requestIDKey: originalID.key,
            upstreamIndex: 0,
            timeout: .seconds(300)
        )
        await initial.blockNextCancellation()
        let staleCancellation = try #require(
            manager.handleRequestLeaseTimeoutWithCancellationDelivery(
                requestLeaseID,
                sessionID: sessionID,
                requestIDKeys: [originalID.key],
                operationLease: operationLease
            )
        )
        manager.scheduleMissingProcessToolsCatalogRetry(
            processID: target.processID,
            lease: staleLease,
            after: [staleCancellation],
            reason: "test_stale_rejected_cancellation"
        )
        try await initial.waitForBlockedCancellation()
        manager.applyProcessControlPlaneTransition(
            manager.processControlPlane.resetAttempt(processID: target.processID)
        )
        let (currentLease, currentTransition) = try #require(
            manager.processControlPlane.beginCatalogAttempt(
                routeID: route.id,
                preferredUpstreamProof: proof,
                nowUptimeNanoseconds: 3
            )
        )
        manager.applyProcessControlPlaneTransition(currentTransition)

        await initial.releaseBlockedCancellation(.backpressure)

        #expect(try await initial.nextStopCount(timeout: .seconds(2)) == 1)
        #expect(manager.processControlPlane.validateCatalogLoad(currentLease) == false)
        #expect(manager.upstreamTopology.validate(proof) == false)
        #expect(replacements.withLockedValue(\.count) == 1)

        let activationRetryIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .milliseconds(500),
            startingAtEventIndex: 0
        )
        #expect(timeoutScheduler.fire(at: activationRetryIndex))
        let replacement = try #require(replacements.withLockedValue { $0.first })
        _ = try await replacement.nextSent(
            matching: { methodName(from: $0) == "initialize" }
        )
    }

    @Test func rejectedStaleCatalogCancellationPreservesSiblingAttempt() async throws {
        let target = xcodeProcessTarget(processID: 27029, xcodeVersion: "27.0")
        let failed = TestUpstreamClient()
        let sibling = TestUpstreamClient()
        let replacements = NIOLockedValueBox<[TestUpstreamClient]>([])
        let replacementFactoryEntered = TestSignal()
        let allowReplacementFactory = DispatchSemaphore(value: 0)
        let shouldBlockReplacementFactory = NIOLockedValueBox(true)
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 300),
            upstreams: [failed, sibling],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let shouldBlock = shouldBlockReplacementFactory.withLockedValue {
                    shouldBlock in
                    let value = shouldBlock
                    shouldBlock = false
                    return value
                }
                if shouldBlock {
                    replacementFactoryEntered.signal()
                    allowReplacementFactory.wait()
                }
                let replacement = TestUpstreamClient()
                replacements.withLockedValue { $0.append(replacement) }
                return [replacement]
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        defer { allowReplacementFactory.signal() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        let initializeResult = try jsonValue([
            "protocolVersion": MCP.ProtocolVersion.current,
            "capabilities": [String: Any](),
            "serverInfo": ["name": "sibling-catalog-cancellation-source"],
        ])
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: initializeResult,
            sourceUpstream: 0
        )
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: initializeResult,
            sourceUpstream: 1
        )
        let route = try #require(
            manager.processControlPlane.route(forProcessID: target.processID)
        )
        let failedOperationLease = manager.operationLeaseForTest(upstreamIndex: 0)
        let siblingProof = manager.operationLeaseForTest(upstreamIndex: 1).proof
        let (staleLease, staleTransition) = try #require(
            manager.processControlPlane.beginCatalogAttempt(
                routeID: route.id,
                preferredUpstreamProof: failedOperationLease.proof,
                nowUptimeNanoseconds: 1
            )
        )
        manager.applyProcessControlPlaneTransition(staleTransition)
        manager.applyCatalogCommit(manager.processControlPlane.completeCatalog(
            .unusable,
            lease: staleLease,
            nowUptimeNanoseconds: 2
        ))

        let sessionID = "stale-sibling-catalog-cancellation"
        let originalID = try #require(JSONRPC.ID(any: NSNumber(value: 1)))
        let requestLeaseID = manager.createRequestLease(
            descriptor: SessionRequestPipeline.Descriptor(
                sessionID: sessionID,
                label: "tools/list",
                expectsResponse: true,
                isTopLevelClientRequest: false
            )
        )
        _ = try #require(manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: originalID,
            operationLease: failedOperationLease
        ))
        manager.activateRequestLease(
            requestLeaseID,
            requestIDKey: originalID.key,
            upstreamIndex: 0,
            timeout: .seconds(300)
        )
        await failed.blockNextCancellation()
        let staleCancellation = try #require(
            manager.handleRequestLeaseTimeoutWithCancellationDelivery(
                requestLeaseID,
                sessionID: sessionID,
                requestIDKeys: [originalID.key],
                operationLease: failedOperationLease
            )
        )
        manager.scheduleMissingProcessToolsCatalogRetry(
            processID: target.processID,
            lease: staleLease,
            after: [staleCancellation],
            reason: "test_stale_sibling_rejected_cancellation"
        )
        try await failed.waitForBlockedCancellation()

        await failed.releaseBlockedCancellation(.backpressure)
        try await replacementFactoryEntered.wait(
            description: "waiting for rejected cancellation replacement"
        )
        manager.applyProcessControlPlaneTransition(
            manager.processControlPlane.resetAttempt(processID: target.processID)
        )
        let (currentLease, currentTransition) = try #require(
            manager.processControlPlane.beginCatalogAttempt(
                routeID: route.id,
                preferredUpstreamProof: siblingProof,
                nowUptimeNanoseconds: 3
            )
        )
        manager.applyProcessControlPlaneTransition(currentTransition)
        allowReplacementFactory.signal()

        #expect(try await failed.nextStopCount(timeout: .seconds(2)) == 1)
        await manager.drainRuntimeTasksForTesting()
        #expect(manager.processControlPlane.validateCatalogLoad(currentLease))
        let currentAttempt = try #require(
            manager.processControlPlane.attemptSnapshot(processID: target.processID)
        )
        #expect(currentAttempt.attemptID.rawValue == currentLease.attempt)
        #expect(currentAttempt.upstreamProof == siblingProof)
        #expect(manager.upstreamTopology.validate(siblingProof))
        #expect(manager.upstreamTopology.validate(failedOperationLease) == false)
        #expect(replacements.withLockedValue(\.count) == 1)
    }

    @Test
    func rejectedCancellationReplacementBlocksExistingActivationRetryUntilOldStopCompletes()
        async throws
    {
        let target = xcodeProcessTarget(processID: 27030, xcodeVersion: "27.0")
        let failed = TestUpstreamClient()
        let sibling = TestUpstreamClient()
        let replacements = NIOLockedValueBox<[TestUpstreamClient]>([])
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 300),
            upstreams: [failed, sibling],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
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
        await failed.blockStop()
        defer {
            Task {
                await failed.releaseBlockedStop()
            }
        }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        let initializeResult = try jsonValue([
            "protocolVersion": MCP.ProtocolVersion.current,
            "capabilities": [String: Any](),
            "serverInfo": ["name": "activation-retry-stop-barrier"],
        ])
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: initializeResult,
            sourceUpstream: 0
        )
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: initializeResult,
            sourceUpstream: 1
        )

        let failedOperationLease = manager.operationLeaseForTest(upstreamIndex: 0)
        let activationStart = try #require(
            manager.beginProcessRouteAttachingForTesting(
                processID: target.processID,
                upstreamIndex: failedOperationLease.upstreamIndex,
                nowUptimeNs: 1
            )
        )
        let activationTimeout = try #require(
            manager.processControlPlane.handleChannelInitializeTimeout(
                activationStart.lease
            )
        )
        manager.applyProcessControlPlaneTransition(activationTimeout.transition)
        manager.scheduleProcessRouteActivationRetry(
            processID: target.processID,
            retry: activationTimeout.retry,
            lease: activationTimeout.activationLease,
            reason: "test_existing_activation_retry"
        )
        let activationRetryIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: activationTimeout.retry.delay,
            startingAtEventIndex: 0
        )

        let sessionID = "rejected-cancellation-activation-retry-stop-barrier"
        let requestID = try #require(JSONRPC.ID(any: NSNumber(value: 1)))
        let requestLeaseID = manager.createRequestLease(
            descriptor: SessionRequestPipeline.Descriptor(
                sessionID: sessionID,
                label: "tools/list",
                expectsResponse: true,
                isTopLevelClientRequest: false
            )
        )
        _ = try #require(manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: requestID,
            operationLease: failedOperationLease
        ))
        manager.activateRequestLease(
            requestLeaseID,
            requestIDKey: requestID.key,
            upstreamIndex: failedOperationLease.upstreamIndex,
            timeout: .seconds(300)
        )
        await failed.blockNextCancellation()
        manager.handleRequestLeaseTimeout(
            requestLeaseID,
            sessionID: sessionID,
            requestIDKeys: [requestID.key],
            operationLease: failedOperationLease
        )
        try await failed.waitForBlockedCancellation()
        await failed.releaseBlockedCancellation(.backpressure)

        try await failed.waitForBlockedStop()
        let replacement = try await waitWithTimeout(
            "waiting for rejected cancellation replacement"
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
                for: failedOperationLease.proof.slotID
            )?.proof
        )
        #expect(replacementProof != failedOperationLease.proof)
        #expect(timeoutScheduler.isCancelled(at: activationRetryIndex) == false)
        #expect(timeoutScheduler.fire(at: activationRetryIndex))

        let retryAttempt = try #require(
            manager.processControlPlane.attemptSnapshot(processID: target.processID)
        )
        #expect(retryAttempt.upstreamProof == replacementProof)
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(await replacement.sentCount() == 0)

        await failed.releaseBlockedStop()
        #expect(try await failed.nextStopCount(timeout: .seconds(2)) == 1)
        _ = try await replacement.nextSent(
            matching: { methodName(from: $0) == "initialize" }
        )
    }

    @Test func processBridgeRecoveryRetriesAttachProbeWithBoundedCadence()
        async throws
    {
        var config = makeConfig(requestTimeout: 300)
        config.usesPermissionDialogAutomation = true
        let existingUpstream = TestUpstreamClient()
        let existingTarget = xcodeProcessTarget(processID: 26627, xcodeVersion: "26.6")
        let recoveringTarget = xcodeProcessTarget(processID: 27027, xcodeVersion: "27.0")
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let createdPools = NIOLockedValueBox<[[TestUpstreamClient]]>([])
        let fixture = RuntimeCoordinatorFixture(
            config: config,
            upstreams: [existingUpstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: existingTarget, upstreamIndices: [0])
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let pool = [TestUpstreamClient(), TestUpstreamClient()]
                createdPools.withLockedValue { $0.append(pool) }
                return pool
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
                "serverInfo": ["name": "cached-source"],
            ]),
            sourceUpstream: 0
        )
        try seedProcessToolCatalogs(
            on: manager,
            entries: [(existingTarget, 0, [toolDescriptor(name: "Only26")])]
        )

        manager.reconcileXcodeProcessTargets(
            [existingTarget, recoveringTarget],
            reason: "test_bridge_attach_retry_cadence"
        )
        let initialPool = try #require(createdPools.withLockedValue { $0.first })
        let primary = initialPool[0]
        let secondary = initialPool[1]
        let primaryInitialize = try await sentValue(
            from: primary,
            startingAt: 0,
            matching: { methodName(from: $0) == "initialize" },
            description: "waiting for route activation initialize"
        )
        await primary.yield(
            .message(
                try makeInitializeResponse(id: try extractUpstreamID(from: primaryInitialize))
            )
        )
        _ = try await sentValue(
            from: primary,
            startingAt: 1,
            matching: { methodName(from: $0) == "notifications/initialized" },
            description: "waiting for route activation initialized notification"
        )
        let primaryCatalog = try await sentValue(
            from: primary,
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" },
            description: "waiting for route activation catalog"
        )
        await primary.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: primaryCatalog),
                    tools: [toolDescriptor(name: "Only27")]
                )
            )
        )

        let secondaryInitialize = try await sentValue(
            from: secondary,
            startingAt: 0,
            matching: { methodName(from: $0) == "initialize" },
            description: "waiting for secondary initialize"
        )
        let probeTimeoutSearchIndex = timeoutScheduler.scheduledEventCount()
        await secondary.yield(
            .message(
                try makeInitializeResponse(id: try extractUpstreamID(from: secondaryInitialize))
            )
        )
        _ = try await sentValue(
            from: secondary,
            startingAt: 1,
            matching: { methodName(from: $0) == "notifications/initialized" },
            description: "waiting for secondary initialized notification"
        )
        _ = try await sentValue(
            from: secondary,
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" },
            description: "waiting for first attach probe"
        )
        let probeTimeoutIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .seconds(2),
            startingAtEventIndex: probeTimeoutSearchIndex
        )
        let firstRetrySearchIndex = timeoutScheduler.scheduledEventCount()
        #expect(timeoutScheduler.fire(at: probeTimeoutIndex))
        let firstRetryIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .seconds(1),
            startingAtEventIndex: firstRetrySearchIndex
        )
        #expect(try await secondary.nextStopCount() == 1)
        #expect(manager.canonicalHandshakeState.hasInitializeParticipants() == false)
        let firstReplacement = try #require(
            createdPools.withLockedValue { $0.dropFirst().first?.first }
        )
        #expect(await firstReplacement.sentCount() == 0)
        #expect(timeoutScheduler.fire(at: firstRetryIndex))

        let firstReplacementInitialize = try await sentValue(
            from: firstReplacement,
            startingAt: 0,
            matching: { methodName(from: $0) == "initialize" },
            description: "waiting for early retry initialize"
        )
        let secondRetrySearchIndex = timeoutScheduler.scheduledEventCount()
        await firstReplacement.yield(
            .message(
                try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": try extractUpstreamID(from: firstReplacementInitialize),
                    "result": [
                        "protocolVersion": "1900-01-01",
                        "capabilities": [String: Any](),
                    ],
                ])
            )
        )
        let secondRetryIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .seconds(10),
            startingAtEventIndex: secondRetrySearchIndex
        )
        #expect(try await firstReplacement.nextStopCount() == 1)
        let secondReplacement = try #require(
            createdPools.withLockedValue { $0.dropFirst(2).first?.first }
        )
        #expect(timeoutScheduler.fireIgnoringCancellation(at: firstRetryIndex))
        #expect(await secondReplacement.sentCount() == 0)
        #expect(timeoutScheduler.fire(at: secondRetryIndex))

        let incompatibleInitialize = try await sentValue(
            from: secondReplacement,
            startingAt: 0,
            matching: { methodName(from: $0) == "initialize" },
            description: "waiting for incompatible retry initialize"
        )
        let thirdRetrySearchIndex = timeoutScheduler.scheduledEventCount()
        await secondReplacement.yield(
            .message(
                try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": try extractUpstreamID(from: incompatibleInitialize),
                    "result": [
                        "protocolVersion": MCP.ProtocolVersion.current,
                        "capabilities": [
                            "experimental": ["different": true],
                        ],
                    ],
                ])
            )
        )
        let thirdRetryIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .seconds(10),
            startingAtEventIndex: thirdRetrySearchIndex
        )
        #expect(try await secondReplacement.nextStopCount() == 1)
        let finalReplacement = try #require(
            createdPools.withLockedValue { $0.dropFirst(3).first?.first }
        )
        #expect(timeoutScheduler.fireIgnoringCancellation(at: secondRetryIndex))
        #expect(await finalReplacement.sentCount() == 0)
        #expect(timeoutScheduler.fire(at: thirdRetryIndex))

        let finalInitialize = try await sentValue(
            from: finalReplacement,
            startingAt: 0,
            matching: { methodName(from: $0) == "initialize" },
            description: "waiting for final retry initialize"
        )
        await finalReplacement.yield(
            .message(
                try makeInitializeResponse(id: try extractUpstreamID(from: finalInitialize))
            )
        )
        _ = try await sentValue(
            from: finalReplacement,
            startingAt: 1,
            matching: { methodName(from: $0) == "notifications/initialized" },
            description: "waiting for periodic retry initialized notification"
        )
        let finalProbe = try await sentValue(
            from: finalReplacement,
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" },
            description: "waiting for final attach probe"
        )
        await finalReplacement.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: finalProbe),
                    tools: []
                )
            )
        )
        await manager.drainRuntimeTasksForTesting()

        let route = try #require(
            manager.debugSnapshot().processRoutes.first {
                $0.processID == recoveringTarget.processID
            }
        )
        #expect(route.upstreamIndices == [1, 2])
        #expect(route.usableSlotCount == 2)
    }

    @Test func healthProbeWaiterRegistrationRejectionSettlesProbe() throws {
        let upstream = TestUpstreamClient()
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            nowUptimeNanoseconds: { 15_000_000_000 },
            testHooks: RuntimeCoordinatorTestHooks(
                healthProbeResponseWaiterWillRegister: {
                    _ = runtimeBox.value?.runtimeTasks.beginShutdown()
                }
            ),
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let proof = manager.operationLeaseForTest(upstreamIndex: 0).proof
        _ = manager.upstreamHealthManager.markRequestTimedOut(proof, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(proof, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(proof, nowUptimeNs: 0)
        let lease = try #require(
            manager.upstreamHealthManager.earliestInitializedQuarantineRecovery()
        )
        let probe = try #require(
            manager.upstreamHealthManager.beginQuarantineRecovery(
                lease,
                nowUptimeNs: 15_000_000_000
            )
        )

        manager.probeUpstreamHealth(probe)

        #expect(
            manager.upstreamHealthManager.state(for: proof.slotID)?
                .healthProbeInFlight == false
        )
        #expect(manager.upstreamHealthManager.anyRecoveryInFlight() == false)
    }

    @Test func staleCatalogTimeoutCannotTerminateNewerRetryLoad()
        async throws
    {
        var config = makeConfig(requestTimeout: 20)
        config.usesPermissionDialogAutomation = true
        let olderUpstream = TestUpstreamClient()
        let olderTarget = xcodeProcessTarget(processID: 26629, xcodeVersion: "26.6")
        let newerTarget = xcodeProcessTarget(processID: 27029, xcodeVersion: "27.0")
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let activationInitializeHandled = TestSignal()
        let fixture = RuntimeCoordinatorFixture(
            config: config,
            upstreams: [olderUpstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0])
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamInitialized: { upstreamIndex in
                    if upstreamIndex == 1 {
                        activationInitializeHandled.signal()
                    }
                }
            ),
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
                (olderTarget, 0, [toolDescriptor(name: "Only26")])
            ]
        )

        manager.reconcileXcodeProcessTargets(
            [olderTarget, newerTarget],
            reason: "test_stale_catalog_timeout"
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
        try await activationInitializeHandled.wait(
            timeout: .seconds(5),
            description: "waiting for activation initialize commit"
        )
        let activation = try #require(
            manager.processControlPlane.attemptSnapshot(processID: newerTarget.processID)
        )
        #expect([.initialized, .loadingCatalog].contains(activation.phase))
        #expect(activation.upstreamID.rawValue == 1)
        #expect(activation.attemptID.rawValue == 1)
        let firstToolsRequest = try await waitWithTimeout(
            "waiting for activation tools/list",
            timeout: .seconds(2)
        ) {
            try await activationUpstream.nextSent(
                startingAt: 2,
                matching: { methodName(from: $0) == "tools/list" }
            )
        }
        let catalogTimeoutIndex = try #require(
            timeoutScheduler.activeTimeoutIndex(delay: .seconds(10))
        )

        let retryScheduleIndex = timeoutScheduler.scheduledEventCount()
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
            try await timeoutScheduler.nextScheduled(at: retryScheduleIndex)
        }

        #expect(retryIndex != catalogTimeoutIndex)
        #expect(
            timeoutScheduler.delay(at: retryIndex)?.nanoseconds
                == TimeAmount.milliseconds(250).nanoseconds
        )
        #expect(timeoutScheduler.isCancelled(at: retryIndex) == false)
        #expect(timeoutScheduler.isCancelled(at: catalogTimeoutIndex))
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
        let retryCatalogTimeoutIndex = try #require(
            timeoutScheduler.activeTimeoutIndex(
                delay: .seconds(10),
                startingAt: catalogTimeoutIndex + 1
            )
        )
        #expect(timeoutScheduler.fireIgnoringCancellation(at: catalogTimeoutIndex))
        #expect(timeoutScheduler.isCancelled(at: retryCatalogTimeoutIndex) == false)
        #expect(
            manager.processControlPlane.attemptSnapshot(
                processID: newerTarget.processID
            )?.phase == .loadingCatalog
        )
        await activationUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: retryToolsRequest),
                    tools: [
                        toolDescriptor(name: "Only27Recovered")
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
        #expect(timeoutScheduler.isCancelled(at: retryCatalogTimeoutIndex))
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set([
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

        #expect(
            manager.processControlPlane.attemptSnapshot(processID: target.processID)?.phase
                == .abandoned
        )
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

    @Test func processRouteRepublishStartsFreshCatalogWithoutPrewarmGate() async throws {
        let target = xcodeProcessTarget(processID: 27020, xcodeVersion: "27.0")
        let upstream = TestUpstreamClient()
        let initializedUpstreams = LockedRecordedValues<Int>()
        let catalogCommits = LockedRecordedValues<(pid_t, Int)>()
        var config = makeConfig(requestTimeout: 5)
        config.prewarmToolsList = false
        let fixture = RuntimeCoordinatorFixture(
            config: config,
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            processRoutingEnabled: true,
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamInitialized: { initializedUpstreams.append($0) },
                processRouteCatalogCommitted: { catalogCommits.append(($0, $1)) }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        let route = try #require(
            manager.processControlPlane.route(forProcessID: target.processID)
        )

        manager.startProcessRouteActivation(for: route)
        let firstInitialize = try await waitWithTimeout(
            "waiting for initial route initialize",
            timeout: .seconds(2)
        ) {
            try await upstream.nextSent(at: 0)
        }
        let firstCatalogCommitIndex = catalogCommits.count()
        await upstream.yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: firstInitialize),
                    serverName: "initial"
                ))
        )
        _ = try await waitWithTimeout(
            "waiting for initial initialized notification",
            timeout: .seconds(2)
        ) {
            try await upstream.nextSent(at: 1)
        }
        #expect(try await nextRecordedValue(initializedUpstreams, at: 0) == 0)
        #expect(
            manager.processControlPlane.attemptSnapshot(processID: target.processID)?.phase
                == .loadingCatalog
        )
        let firstCatalog = try await sentValue(
            from: upstream,
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" },
            description: "waiting for initial route catalog"
        )
        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: firstCatalog),
                    tools: [toolDescriptor(name: "BeforeDetach")]
                ))
        )
        #expect(
            try await nextRecordedValue(catalogCommits, at: firstCatalogCommitIndex)
                == (target.processID, 0)
        )
        await manager.drainRuntimeTasksForTesting()
        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) != nil)

        let sourceProof = manager.operationLeaseForTest(upstreamIndex: 0).proof
        #expect(manager.clearUpstreamState(proof: sourceProof))
        #expect(manager.canonicalHandshakeState.initializeResult() == nil)
        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) == nil)

        let currentRoute = try #require(
            manager.processControlPlane.route(forProcessID: target.processID)
        )
        manager.startProcessRouteActivation(for: currentRoute)
        let republishedInitialize = try await waitWithTimeout(
            "waiting for republished route initialize",
            timeout: .seconds(2)
        ) {
            try await upstream.nextSent(
                startingAt: 3,
                matching: { methodName(from: $0) == "initialize" }
            )
        }
        let republishedCatalogCommitIndex = catalogCommits.count()
        await upstream.yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: republishedInitialize),
                    serverName: "republished"
                ))
        )
        _ = try await waitWithTimeout(
            "waiting for republished initialized notification",
            timeout: .seconds(2)
        ) {
            try await upstream.nextSent(
                startingAt: 4,
                matching: { methodName(from: $0) == "notifications/initialized" }
            )
        }
        #expect(try await nextRecordedValue(initializedUpstreams, at: 1) == 0)
        #expect(
            manager.processControlPlane.attemptSnapshot(processID: target.processID)?.phase
                == .loadingCatalog
        )
        let freshCatalog = try await sentValue(
            from: upstream,
            startingAt: 5,
            matching: { methodName(from: $0) == "tools/list" },
            description: "waiting for republished route fresh catalog"
        )
        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) == nil)
        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: freshCatalog),
                    tools: [toolDescriptor(name: "AfterRepublish")]
                ))
        )
        #expect(
            try await nextRecordedValue(catalogCommits, at: republishedCatalogCommitIndex)
                == (target.processID, 0)
        )
        await manager.drainRuntimeTasksForTesting()

        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 0)
        #expect(
            toolNames(in: manager.cachedToolsListResult() ?? .null) == ["AfterRepublish"]
        )
        #expect(
            manager.processControlPlane.attemptSnapshot(processID: target.processID)?.phase
                == .cataloged
        )
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
        guard let upstreamHealth = manager.testStateSnapshot().upstream(id: 0),
            case .quarantined = upstreamHealth.healthState
        else {
            Issue.record("unsupported process route did not remain quarantined")
            return
        }
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
                XcodeProcessRoute(target: target, upstreamIndices: [0])
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
                XcodeProcessRoute(target: target, upstreamIndices: [0])
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
        await recoveredUpstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: initialize)))
        )
        let initializedNotification = try await recoveredUpstream.nextSent(at: 1)
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        let toolsRequest = try await recoveredUpstream.nextSent(
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" }
        )
        await recoveredUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: toolsRequest),
                    tools: [toolDescriptor(name: "RecoveredRouteTool")]
                )
            )
        )
        _ = try await waitWithTimeout(
            "waiting for recovered route catalog completion",
            timeout: .seconds(2)
        ) {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.canonicalToolsSourceUpstream == 1
            }
        }
        let recoveredRoute = try #require(
            manager.processControlPlane.route(forProcessID: target.processID)
        )
        #expect(recoveredRoute.upstreamIndices == [1])
        #expect(manager.upstreamTopology.snapshot().slotIDs == [UpstreamSlotID(rawValue: 1)])
        #expect(
            manager.processControlPlane.attemptSnapshot(processID: target.processID)?.phase
                == .cataloged
        )
    }

    @Test func processRouteActivationOwnsInitializeWhileReadinessWaits() async throws {
        let readiness = ReadinessFlag(isReady: false)
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let target = xcodeProcessTarget(processID: 27010, xcodeVersion: "27.0")
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            upstreamReadinessGate: makeTestReadinessGate(readiness: readiness),
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
        _ = try await readiness.nextChangeWait(at: 0)

        let initializeFuture = fixture.registerInitialize(
            requestID: 1,
            sessionID: "session-joins-waiting-activation"
        )
        manager.startEagerInitializePrimary()
        #expect(timeoutScheduler.scheduledCount() == 1)

        await readiness.setReady(true)
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
        let toolsRequest = try await upstream.nextSent(
            matching: { methodName(from: $0) == "tools/list" }
        )
        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: toolsRequest),
                    tools: [toolDescriptor(name: "XcodeListWindows")]
                )
            )
        )
        await manager.drainRuntimeTasksForTesting()

        let methods = await upstream.sent().compactMap { methodName(from: $0) }
        #expect(methods.filter { $0 == "initialize" }.count == 1)
        let attempt = try #require(
            manager.processControlPlane.attemptSnapshot(processID: target.processID)
        )
        #expect(attempt.phase == .cataloged)
        #expect(attempt.readinessWaiterCount == 0)
    }

    @Test func processRoutingInitializesAndCatalogsEveryRouteIndependently() async throws {
        let firstTarget = xcodeProcessTarget(processID: 27017, xcodeVersion: "27.0")
        let secondTarget = xcodeProcessTarget(processID: 26617, xcodeVersion: "26.6")
        let createdUpstreams = NIOLockedValueBox<[pid_t: TestUpstreamClient]>([:])
        let toolsListRefreshes = LockedRecordedValues<(Int, Bool)>()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { target in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0[target.processID] = upstream }
                return [upstream]
            },
            testHooks: RuntimeCoordinatorTestHooks(
                toolsListRefreshCompleted: { upstreamIndex, succeeded in
                    toolsListRefreshes.append((upstreamIndex, succeeded))
                }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }

        fixture.manager.reconcileXcodeProcessTargets(
            [firstTarget, secondTarget],
            reason: "test_multiple_routes_before_initialize"
        )

        let upstreams = createdUpstreams.withLockedValue { $0 }
        let firstUpstream = try #require(upstreams[firstTarget.processID])
        let secondUpstream = try #require(upstreams[secondTarget.processID])
        _ = try await firstUpstream.nextStartCount()
        _ = try await secondUpstream.nextStartCount()
        await fixture.manager.drainRuntimeTasksForTesting()

        let firstMethods = await firstUpstream.sent().compactMap { methodName(from: $0) }
        let secondMethods = await secondUpstream.sent().compactMap { methodName(from: $0) }
        #expect(firstMethods.filter { $0 == "initialize" }.count == 1)
        #expect(secondMethods.filter { $0 == "initialize" }.count == 1)

        let firstInitialize = try await firstUpstream.nextSent(
            matching: { methodName(from: $0) == "initialize" }
        )
        let secondInitialize = try await secondUpstream.nextSent(
            matching: { methodName(from: $0) == "initialize" }
        )
        await secondUpstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: secondInitialize)))
        )
        _ = try await secondUpstream.nextSent(
            matching: { methodName(from: $0) == "notifications/initialized" }
        )
        let secondToolsRequest = try await secondUpstream.nextSent(
            matching: { methodName(from: $0) == "tools/list" }
        )
        await secondUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: secondToolsRequest),
                    tools: [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                )
            )
        )
        await firstUpstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: firstInitialize)))
        )
        _ = try await firstUpstream.nextSent(
            matching: { methodName(from: $0) == "notifications/initialized" }
        )
        let firstToolsRequest = try await firstUpstream.nextSent(
            matching: { methodName(from: $0) == "tools/list" }
        )
        await firstUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: firstToolsRequest),
                    tools: [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                )
            )
        )

        let firstRefresh = try await nextRecordedValue(toolsListRefreshes, at: 0)
        let secondRefresh = try await nextRecordedValue(toolsListRefreshes, at: 1)
        #expect(firstRefresh.1)
        #expect(secondRefresh.1)
        await fixture.manager.drainRuntimeTasksForTesting()
        let routesByProcessID = Dictionary(
            uniqueKeysWithValues: fixture.manager.xcodeProcessRoutes.map {
                ($0.target.processID, $0)
            }
        )
        let firstRoute = try #require(routesByProcessID[firstTarget.processID])
        let secondRoute = try #require(routesByProcessID[secondTarget.processID])
        let firstUpstreamIndex = try #require(firstRoute.primaryUpstreamIndex)
        let secondUpstreamIndex = try #require(secondRoute.primaryUpstreamIndex)
        #expect(
            Set([firstRefresh.0, secondRefresh.0]) == [
                firstUpstreamIndex,
                secondUpstreamIndex,
            ])
        #expect(
            fixture.manager.processControlPlane.catalog(
                forProcessID: firstTarget.processID
            ) != nil)
        #expect(
            fixture.manager.processControlPlane.catalog(
                forProcessID: secondTarget.processID
            ) != nil)

        let firstWorkspacePath = "/Work/Xcode27.xcworkspace"
        #expect(
            fixture.manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: xcode-27-tab, workspacePath: \(firstWorkspacePath)"
                    ]
                ]),
                upstreamIndex: firstUpstreamIndex
            )
        )
        let secondWorkspacePath = "/Work/Xcode26.xcworkspace"
        #expect(
            fixture.manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: xcode-26-tab, workspacePath: \(secondWorkspacePath)"
                    ]
                ]),
                upstreamIndex: secondUpstreamIndex
            )
        )
        let routingDecision = await fixture.manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 27017,
                name: "BuildProject",
                arguments: ["workspacePath": secondWorkspacePath]
            ),
            requestTimeoutOverride: .seconds(2)
        )
        #expect(routingDecision.preferredUpstreamIndices == [secondUpstreamIndex])

        let firstToolCall = toolsCallObject(
            id: 270171,
            name: "BuildProject",
            arguments: [
                "tabIdentifier": fixture.manager.windowOwnershipAuthority.snapshot()
                    .proxyTabIdentifier(
                        processID: firstTarget.processID,
                        rawTabIdentifier: "xcode-27-tab",
                        workspacePath: firstWorkspacePath
                    )
            ]
        )
        let firstDecision = await fixture.manager.toolRoutingDecision(
            for: firstToolCall,
            requestTimeoutOverride: .seconds(2)
        )
        #expect(firstDecision.preferredUpstreamIndices == [firstUpstreamIndex])

        let sourceBeforeRetirement = try #require(
            fixture.manager.canonicalHandshakeState.snapshot().initializeSourceProof
        )
        #expect(sourceBeforeRetirement.slotID.rawValue == secondUpstreamIndex)
        fixture.manager.reconcileXcodeProcessTargets(
            [firstTarget],
            reason: "test_retire_canonical_source"
        )
        let handshakeAfterRetirement = fixture.manager.canonicalHandshakeState.snapshot()
        #expect(handshakeAfterRetirement.initializeSourceUpstream == firstUpstreamIndex)
        #expect(handshakeAfterRetirement.initializeResult != nil)
        #expect(
            handshakeAfterRetirement.supporterProofs.map(\.slotID.rawValue)
                == [firstUpstreamIndex]
        )

        let cachedInitialize = fixture.registerInitialize(requestID: 27018)
        let cachedResponse = try decodeJSON(from: try await cachedInitialize.get())
        #expect(cachedResponse["result"] != nil)
        #expect(
            fixture.manager.processControlPlane.catalog(
                forProcessID: firstTarget.processID
            ) != nil
        )
        let survivorDecision = await fixture.manager.toolRoutingDecision(
            for: firstToolCall,
            requestTimeoutOverride: .seconds(2)
        )
        #expect(survivorDecision.preferredUpstreamIndices == [firstUpstreamIndex])
    }

    @Test func processRoutingJoinsCompatibleServerInfoWhileSiblingNotificationIsBlocked()
        async throws
    {
        let firstTarget = xcodeProcessTarget(processID: 27022, xcodeVersion: "27.0")
        let secondTarget = xcodeProcessTarget(processID: 26622, xcodeVersion: "26.6")
        let firstUpstream = BlockingInitializedNotificationUpstreamClient()
        let secondUpstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [firstUpstream, secondUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: firstTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: secondTarget, upstreamIndices: [1]),
            ],
            processRoutingEnabled: true,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }

        await firstUpstream.blockNextInitializedNotification()
        fixture.manager.start()
        let firstInitialize = try await firstUpstream.nextSent(at: 0)
        let secondInitialize = try await secondUpstream.nextSent(
            matching: { methodName(from: $0) == "initialize" }
        )
        let pendingInitialize = fixture.registerInitialize(
            requestID: 27021,
            sessionID: "session-compatible-sibling-first-success"
        )

        await firstUpstream.yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: firstInitialize),
                    serverName: "Xcode 27"
                ))
        )
        try await firstUpstream.waitForBlockedInitializedNotification()

        await secondUpstream.yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: secondInitialize),
                    serverName: "Xcode 26.6"
                ))
        )
        _ = try await secondUpstream.nextSent(
            matching: { methodName(from: $0) == "notifications/initialized" }
        )
        let downstreamInitialize = try decodeJSON(
            from: try await waitWithTimeout(
                "waiting for compatible sibling to complete downstream initialize"
            ) {
                try await pendingInitialize.get()
            }
        )
        #expect(downstreamInitialize["result"] != nil)
        #expect(fixture.manager.canonicalHandshakeState.initializeSourceUpstream() == 1)
        let secondTools = try await secondUpstream.nextSent(
            matching: { methodName(from: $0) == "tools/list" }
        )
        await secondUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: secondTools),
                    tools: [ownerBoundToolDescriptor(name: "BuildProject")]
                ))
        )

        await firstUpstream.releaseBlockedInitializedNotification(.accepted)
        let firstTools = try await firstUpstream.nextSent(at: 2)
        #expect(methodName(from: firstTools) == "tools/list")
        await firstUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: firstTools),
                    tools: [ownerBoundToolDescriptor(name: "BuildProject")]
                ))
        )
        await fixture.manager.drainRuntimeTasksForTesting()

        let handshake = fixture.manager.canonicalHandshakeState.snapshot()
        #expect(handshake.initializeSourceUpstream == 1)
        #expect(handshake.supporterProofs.map(\.slotID.rawValue).sorted() == [0, 1])
        #expect(
            fixture.manager.processControlPlane.catalog(
                forProcessID: firstTarget.processID
            ) != nil
        )
        #expect(
            fixture.manager.processControlPlane.catalog(
                forProcessID: secondTarget.processID
            ) != nil
        )

        let canonicalBeforeNonSourceRetirement = handshake.initializeResult
        fixture.manager.reconcileXcodeProcessTargets(
            [secondTarget],
            reason: "test_retire_noncanonical_source"
        )
        let afterNonSourceRetirement = fixture.manager.canonicalHandshakeState.snapshot()
        #expect(afterNonSourceRetirement.initializeSourceUpstream == 1)
        #expect(afterNonSourceRetirement.initializeResult == canonicalBeforeNonSourceRetirement)
        let cachedInitialize = fixture.registerInitialize(requestID: 27022)
        #expect(try decodeJSON(from: try await cachedInitialize.get())["result"] != nil)
    }

    @Test func processRoutingMakesIncompatibleRouteTerminalWithoutReplacingCanonical()
        async throws
    {
        let compatibleTarget = xcodeProcessTarget(processID: 27023, xcodeVersion: "27.0")
        let incompatibleTarget = xcodeProcessTarget(processID: 26623, xcodeVersion: "26.6")
        let compatibleUpstream = TestUpstreamClient()
        let incompatibleUpstream = BlockingInitializedNotificationUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [compatibleUpstream, incompatibleUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: compatibleTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: incompatibleTarget, upstreamIndices: [1]),
            ],
            processRoutingEnabled: true,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        await incompatibleUpstream.blockNextInitializedNotification()
        fixture.manager.start()

        let compatibleInitialize = try await compatibleUpstream.nextSent(
            matching: { methodName(from: $0) == "initialize" }
        )
        let incompatibleInitialize = try await incompatibleUpstream.nextSent(at: 0)
        await incompatibleUpstream.yield(
            .message(
                try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": try extractUpstreamID(from: incompatibleInitialize),
                    "result": [
                        "protocolVersion": MCP.ProtocolVersion.current,
                        "capabilities": ["experimental": ["different": true]],
                        "serverInfo": ["name": "Xcode 26.6"],
                    ],
                ]))
        )
        try await incompatibleUpstream.waitForBlockedInitializedNotification()
        await compatibleUpstream.yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: compatibleInitialize),
                    serverName: "Xcode 27"
                ))
        )
        _ = try await compatibleUpstream.nextSent(
            matching: { methodName(from: $0) == "notifications/initialized" }
        )
        let compatibleTools = try await compatibleUpstream.nextSent(
            matching: { methodName(from: $0) == "tools/list" }
        )
        await compatibleUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: compatibleTools),
                    tools: [ownerBoundToolDescriptor(name: "BuildProject")]
                ))
        )
        await incompatibleUpstream.releaseBlockedInitializedNotification(.accepted)
        await fixture.manager.drainRuntimeTasksForTesting()

        let handshake = fixture.manager.canonicalHandshakeState.snapshot()
        #expect(handshake.initializeSourceUpstream == 0)
        #expect(handshake.lastIncompatibility?.upstreamIndex == 1)
        #expect(
            fixture.manager.processControlPlane.attemptSnapshot(
                processID: incompatibleTarget.processID
            )?.phase == .abandoned
        )
        #expect(
            fixture.manager.processControlPlane.attemptSnapshot(
                processID: compatibleTarget.processID
            )?.phase == .cataloged
        )
        #expect(
            fixture.manager.unavailableXcodeProcessIDs().contains(
                incompatibleTarget.processID
            )
        )
        #expect(
            await incompatibleUpstream.sent().compactMap { methodName(from: $0) }
                .filter { $0 == "notifications/initialized" }.count == 1
        )
        guard let incompatibleHealth = fixture.manager.testStateSnapshot().upstream(id: 1),
            case .quarantined = incompatibleHealth.healthState
        else {
            Issue.record("incompatible route did not remain quarantined")
            return
        }
    }

    @Test func processRoutingKeepsPendingInitializeForSiblingPublisherAfterPeerError()
        async throws
    {
        let errorTarget = xcodeProcessTarget(processID: 27024, xcodeVersion: "27.0")
        let publisherTarget = xcodeProcessTarget(processID: 26624, xcodeVersion: "26.6")
        let errorUpstream = TestUpstreamClient()
        let publisherUpstream = BlockingInitializedNotificationUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [errorUpstream, publisherUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: errorTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: publisherTarget, upstreamIndices: [1]),
            ],
            processRoutingEnabled: true,
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }

        await publisherUpstream.blockNextInitializedNotification()
        fixture.manager.start()
        let errorInitialize = try await errorUpstream.nextSent(
            matching: { methodName(from: $0) == "initialize" }
        )
        let publisherInitialize = try await publisherUpstream.nextSent(at: 0)
        let pendingInitialize = fixture.registerInitialize(
            requestID: 27024,
            sessionID: "session-peer-error"
        )
        let pendingCompletionCount = NIOLockedValueBox(0)
        pendingInitialize.whenComplete { _ in
            pendingCompletionCount.withLockedValue { $0 += 1 }
        }

        await publisherUpstream.yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: publisherInitialize),
                    serverName: "Xcode 26.6"
                ))
        )
        try await publisherUpstream.waitForBlockedInitializedNotification()

        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: try extractUpstreamID(from: errorInitialize)),
            "error": [
                "code": -1,
                "message": "peer initialize failed",
            ],
        ]
        let errorEventIndex = upstreamEvents.count()
        await errorUpstream.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: []))
        )
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: errorEventIndex,
            description: "waiting for peer initialize error handling"
        )
        #expect(pendingCompletionCount.withLockedValue { $0 } == 0)

        await publisherUpstream.releaseBlockedInitializedNotification(.accepted)
        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "waiting for sibling publisher to satisfy pending initialize",
                timeout: .seconds(2)
            ) {
                try await pendingInitialize.get()
            }
        )
        #expect(response["result"] != nil)
        #expect(pendingCompletionCount.withLockedValue { $0 } == 1)

        let publisherTools = try await waitWithTimeout(
            "waiting for sibling publisher tools/list",
            timeout: .seconds(2)
        ) {
            try await publisherUpstream.nextSent(at: 2)
        }
        #expect(methodName(from: publisherTools) == "tools/list")
        await publisherUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: publisherTools),
                    tools: [ownerBoundToolDescriptor(name: "BuildProject")]
                ))
        )
        await fixture.manager.drainRuntimeTasksForTesting()

        #expect(fixture.manager.canonicalHandshakeState.initializeSourceUpstream() == 1)
        #expect(
            fixture.manager.processControlPlane.catalog(
                forProcessID: publisherTarget.processID
            ) != nil
        )
        #expect(
            fixture.manager.processControlPlane.route(
                forProcessID: errorTarget.processID
            ) == nil
        )
    }

    @Test func processRoutingAttachesEveryInitialRouteAtStartup() async throws {
        let firstTarget = xcodeProcessTarget(processID: 27018, xcodeVersion: "27.0")
        let secondTarget = xcodeProcessTarget(processID: 26618, xcodeVersion: "26.6")
        let firstUpstream = TestUpstreamClient()
        let secondUpstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [firstUpstream, secondUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: firstTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: secondTarget, upstreamIndices: [1]),
            ],
            processRoutingEnabled: true,
            xcodeTargetDiscovery: StubXcodeTargetDiscovery(
                targets: [firstTarget, secondTarget]
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }

        fixture.manager.start()

        _ = try await firstUpstream.nextStartCount()
        _ = try await secondUpstream.nextStartCount()
        let firstInitialize = try await firstUpstream.nextSent(
            matching: { methodName(from: $0) == "initialize" }
        )
        #expect(methodName(from: firstInitialize) == "initialize")
        let secondInitialize = try await secondUpstream.nextSent(
            matching: { methodName(from: $0) == "initialize" }
        )
        #expect(methodName(from: secondInitialize) == "initialize")
    }

    @Test
    func processRouteActivationBootstrapsCatalogAndHandshakeFromVerifiedSecondaryAfterPrimaryFailure()
        async throws
    {
        let existingUpstream = TestUpstreamClient()
        let existingTarget = xcodeProcessTarget(processID: 26615, xcodeVersion: "26.6")
        let newTarget = xcodeProcessTarget(processID: 27015, xcodeVersion: "27.0")
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let toolsListRefreshes = LockedRecordedValues<(Int, Bool)>()
        let catalogCommits = LockedRecordedValues<(pid_t, Int)>()
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [existingUpstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: existingTarget, upstreamIndices: [0])
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let primary = TestUpstreamClient()
                let secondary = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(contentsOf: [primary, secondary]) }
                return [primary, secondary]
            },
            testHooks: RuntimeCoordinatorTestHooks(
                toolsListRefreshCompleted: { toolsListRefreshes.append(($0, $1)) },
                processRouteCatalogCommitted: { catalogCommits.append(($0, $1)) }
            ),
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
                (existingTarget, 0, [toolDescriptor(name: "ExistingOnly")])
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

        await newUpstreams[0].yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: primaryInitialize)
                )
            )
        )
        _ = try await newUpstreams[0].nextSent(
            matching: { methodName(from: $0) == "notifications/initialized" }
        )
        let primaryToolsList = try await newUpstreams[0].nextSent(
            matching: { methodName(from: $0) == "tools/list" }
        )
        let failedRefreshIndex = toolsListRefreshes.count()
        await newUpstreams[0].yield(
            .message(
                try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": NSNumber(value: try extractUpstreamID(from: primaryToolsList)),
                    "error": [
                        "code": -32000,
                        "message": "primary catalog failed",
                    ],
                ])
            )
        )
        let failedRefresh = try await nextRecordedValue(
            toolsListRefreshes,
            at: failedRefreshIndex
        )
        #expect(failedRefresh.0 == 1)
        #expect(failedRefresh.1 == false)

        manager.reconcileXcodeProcessTargets(
            [newTarget],
            reason: "test_retire_last_verified_initialize_source"
        )
        #expect(manager.canonicalHandshakeState.initializeResult() == nil)
        #expect(manager.canonicalHandshakeState.snapshot().supporterProofs.isEmpty)
        let pendingInitialize = fixture.registerInitialize(
            requestID: 2,
            sessionID: "session-awaiting-verified-recovery"
        )
        let pendingCompletionCount = NIOLockedValueBox(0)
        pendingInitialize.whenComplete { _ in
            pendingCompletionCount.withLockedValue { $0 += 1 }
        }

        await newUpstreams[1].yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: secondaryInitialize)
                )
            )
        )
        _ = try await newUpstreams[1].nextSent(
            matching: { methodName(from: $0) == "notifications/initialized" }
        )
        let attachProbe = try await newUpstreams[1].nextSent(
            matching: { methodName(from: $0) == "tools/list" }
        )
        let pendingRoute = try #require(
            manager.debugSnapshot().processRoutes.first {
                $0.processID == newTarget.processID
            }
        )
        #expect(pendingRoute.usableSlotCount == 0)
        #expect(manager.canonicalHandshakeState.initializeResult() == nil)
        #expect(manager.canonicalHandshakeState.snapshot().supporterProofs.isEmpty)
        #expect(manager.initializeManager.pendingInitializes().count == 1)
        #expect(pendingCompletionCount.withLockedValue { $0 } == 0)
        let recoveringRoute = try #require(
            manager.processControlPlane.route(forProcessID: newTarget.processID)
        )
        #expect(
            manager.upstreamHealthManager.state(for: UpstreamSlotID(rawValue: 2))?
                .initPhase == .initialized(.verifyingBridge(recoveringRoute.id))
        )

        await newUpstreams[1].yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: attachProbe),
                    tools: []
                )
            )
        )
        let secondaryCatalog = try await newUpstreams[1].nextSent(
            startingAt: 3,
            matching: { methodName(from: $0) == "tools/list" }
        )
        _ = try await pendingInitialize.get()
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 2)
        #expect(manager.initializeManager.pendingInitializes().isEmpty)
        #expect(pendingCompletionCount.withLockedValue { $0 } == 1)
        let catalogCommitIndex = catalogCommits.count()
        await newUpstreams[1].yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: secondaryCatalog),
                    tools: [toolDescriptor(name: "NewOnly")]
                )
            )
        )
        #expect(
            try await nextRecordedValue(catalogCommits, at: catalogCommitIndex)
                == (newTarget.processID, 2)
        )
        let attachedRoute = try #require(
            manager.debugSnapshot().processRoutes.first {
                $0.processID == newTarget.processID
            }
        )
        #expect(attachedRoute.usableSlotCount == 1)
        #expect(
            manager.processControlPlane.catalog(forProcessID: newTarget.processID)?
                .upstreamIndex == 2
        )
    }

    @Test func processBridgeRecoveryRejectsReadinessCallbackAfterCatalogReset()
        async throws
    {
        let readiness = ReadinessFlag(isReady: true)
        let existingUpstream = TestUpstreamClient()
        let existingTarget = xcodeProcessTarget(processID: 26616, xcodeVersion: "26.6")
        let newTarget = xcodeProcessTarget(processID: 27016, xcodeVersion: "27.0")
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [existingUpstream],
            upstreamReadinessGate: makeTestReadinessGate(readiness: readiness),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: existingTarget, upstreamIndices: [0])
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
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: existingInitialize)
                )
            )
        )
        _ = try await initializeFuture.get()
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (existingTarget, 0, [toolDescriptor(name: "ExistingOnly")])
            ]
        )

        await readiness.setReady(false)
        manager.reconcileXcodeProcessTargets(
            [existingTarget, newTarget],
            reason: "test_stale_bridge_readiness_callback"
        )

        let newUpstreams = createdUpstreams.withLockedValue { $0 }
        #expect(newUpstreams.count == 2)
        _ = try await readiness.nextChangeWait(at: 0)
        #expect(await newUpstreams[1].sentCount() == 0)

        let readinessCheckCount = await readiness.checkCount()
        manager.invalidateToolsCatalog(reason: "test_stale_bridge_readiness_callback")
        await readiness.setReady(true)
        _ = try await readiness.nextCheck(at: readinessCheckCount)
        await manager.drainRuntimeTasksForTesting()

        #expect(await newUpstreams[1].sentCount() == 0)
        #expect(
            manager.upstreamHealthManager.state(for: UpstreamSlotID(rawValue: 2))?
                .initPhase == .idle
        )
        #expect(
            manager.processControlPlane.catalog(forProcessID: newTarget.processID) == nil
        )
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

    @Test func processRoutingDebugResetDoesNotRescanXcodeProcesses() async throws {
        let discovery = RecordingXcodeTargetDiscovery(targets: [])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
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

        manager.debugReset()
        await manager.drainRuntimeTasksForTesting()

        #expect(discovery.calls.count() == 1)
    }

    @Test func processRoutingAddsLateXcodeProcessWithoutRestart() async throws {
        let olderUpstream = TestUpstreamClient()
        let olderTarget = xcodeProcessTarget(processID: 26610, xcodeVersion: "26.6")
        let newerTarget = xcodeProcessTarget(processID: 27010, xcodeVersion: "27.0")
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [olderUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0])
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
                (olderTarget, 0, [toolDescriptor(name: "Only26")])
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
                        toolDescriptor(name: "Only27")
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
        #expect(
            snapshot.processRoutes.map(\.processID) == [
                newerTarget.processID,
                olderTarget.processID,
            ])
        #expect(
            manager.documentationCandidateProcessIDs()
                == Set([
                    olderTarget.processID,
                    newerTarget.processID,
                ]))
        #expect(
            Set(snapshot.processToolCatalogs.map(\.processID))
                == Set([
                    olderTarget.processID,
                    newerTarget.processID,
                ]))
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set([
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
                XcodeProcessRoute(target: olderTarget, upstreamIndices: [0])
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
                (olderTarget, 0, [toolDescriptor(name: "Only26")])
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
        #expect(try await newerUpstream.nextStopCount() == 1)
        let pendingSnapshot = manager.debugSnapshot()
        #expect(
            pendingSnapshot.processRoutes.map(\.toolsCatalogState) == [
                "pending",
                "available",
            ])

        let replacementUpstream = try #require(createdUpstreams.withLockedValue { $0.dropFirst().first })
        let retryTimeoutIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .milliseconds(250),
            startingAtEventIndex: 2
        )
        let scheduledBeforeReconcile = timeoutScheduler.scheduledCount()
        manager.reconcileXcodeProcessTargets(
            [olderTarget, newerTarget],
            reason: "test_spurious_reconcile_before_activation_retry"
        )
        await manager.drainRuntimeTasksForTesting()
        #expect(timeoutScheduler.scheduledCount() == scheduledBeforeReconcile)
        #expect(await replacementUpstream.sentCount() == 0)
        #expect(timeoutScheduler.fire(at: retryTimeoutIndex))
        let replacementInitialize = try await replacementUpstream.nextSent(at: 0)
        await replacementUpstream.yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: replacementInitialize)
                ))
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
                        toolDescriptor(name: "Only27")
                    ]
                )
            )
        )
        _ = try await manager.controlPlaneDebugMirror.waitForSnapshot {
            $0.canonicalToolsSourceUpstream == 1
        }

        let snapshot = manager.debugSnapshot()
        #expect(snapshot.processRoutes.map(\.toolsCatalogState) == ["available", "available"])
        #expect(
            Set(snapshot.processToolCatalogs.map(\.processID))
                == Set([
                    olderTarget.processID,
                    newerTarget.processID,
                ]))
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set([
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
        let initializedUpstreams = LockedRecordedValues<Int>()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let upstream = TestUpstreamClient()
                createdUpstreams.withLockedValue { $0.append(upstream) }
                return [upstream]
            },
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamInitialized: { initializedUpstreams.append($0) }
            ),
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
        #expect(try await upstream.nextStopCount() == 1)
        #expect(manager.testStateSnapshot().hasInitResult == false)

        let replacement = try #require(createdUpstreams.withLockedValue { $0.dropFirst().first })
        let retryTimeoutIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .milliseconds(250),
            startingAtEventIndex: 2
        )
        #expect(timeoutScheduler.fire(at: retryTimeoutIndex))
        let replacementInitialize = try await replacement.nextSent(at: 0)
        #expect(methodName(from: replacementInitialize) == "initialize")

        await replacement.yield(
            .message(
                try makeInitializeResponse(
                    id: try extractUpstreamID(from: replacementInitialize)
                ))
        )
        let initializedNotification = try await replacement.nextSent(at: 1)
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        #expect(
            try await waitForRecordedValue(
                initializedUpstreams,
                at: 0,
                description: "waiting for retried primary initialize publication"
            ) == 0
        )

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
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let toolsListRefreshes = LockedRecordedValues<(Int, Bool)>()
        let initializedUpstreams = LockedRecordedValues<Int>()
        let target = xcodeProcessTarget(processID: 27013, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            nowUptimeNanoseconds: uptimeClock.now,
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) },
                toolsListRefreshCompleted: { toolsListRefreshes.append(($0, $1)) },
                upstreamInitialized: { initializedUpstreams.append($0) }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        _ = try await fixture.initializePrimary(on: upstream)
        #expect(
            try await waitForRecordedValue(
                initializedUpstreams,
                at: 0,
                description: "waiting for initial route initialization commit"
            ) == 0
        )
        let initialToolsRequest = try await sentValue(
            from: upstream,
            startingAt: 2,
            matching: { methodName(from: $0) == "tools/list" },
            description: "waiting for initial route tools catalog"
        )
        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: initialToolsRequest),
                    tools: [toolDescriptor(name: "RecoveredProcessTool")]
                )
            )
        )
        let initialRefresh = try await waitForRecordedValue(
            toolsListRefreshes,
            at: 0,
            description: "waiting for initial route catalog completion"
        )
        #expect(initialRefresh == (0, true))
        await manager.drainRuntimeTasksForTesting()
        #expect(
            manager.processControlPlane.attemptSnapshot(processID: target.processID)?.phase
                == .cataloged
        )

        let timeoutCountBeforeExit = timeoutScheduler.scheduledCount()
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
        #expect(timeoutScheduler.scheduledCount() == timeoutCountBeforeExit + 1)
        #expect(
            timeoutScheduler.delay(at: timeoutCountBeforeExit)?.nanoseconds
                == TimeAmount.seconds(2).nanoseconds
        )

        manager.reconcileXcodeProcessTargets([target], reason: "test_before_cooldown")
        #expect(await upstream.sentCount() == sentCountAfterExit)

        uptimeClock.advance(by: .seconds(2))
        #expect(timeoutScheduler.fire(at: timeoutCountBeforeExit))
        let restartedInitialize = try await upstream.nextSent(at: sentCountAfterExit)
        #expect(methodName(from: restartedInitialize) == "initialize")

        await upstream.yield(
            .message(try makeInitializeResponse(id: try extractUpstreamID(from: restartedInitialize)))
        )
        let initializedNotification = try await upstream.nextSent(at: sentCountAfterExit + 1)
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        #expect(
            try await waitForRecordedValue(
                initializedUpstreams,
                at: 1,
                description: "waiting for restarted route initialization commit"
            ) == 0
        )
        #expect(manager.testStateSnapshot().hasInitResult)
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 0)
    }

    @Test func processRouteUsabilityEvaluationDefersHealthProbeEffectsOutsideInitializeLock()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 27015, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: group.next(),
            upstreams: [upstream],
            nowUptimeNanoseconds: { 16_000_000_000 },
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let operationLease = manager.operationLeaseForTest(upstreamIndex: 0)
        for _ in 0..<3 {
            _ = manager.upstreamHealthManager.markRequestTimedOut(
                operationLease.proof,
                nowUptimeNs: 0
            )
        }

        var capturedEvaluation: RuntimeCoordinator.ProcessRouteUsabilityEvaluation?
        #expect(manager.initializeManager.performIfRunning {
            capturedEvaluation = manager.evaluateProcessRouteUpstreamUsability(
                policy: .toolsCatalog,
                nowUptimeNs: 16_000_000_000
            )
        })

        let evaluation = try #require(capturedEvaluation)
        #expect(evaluation.snapshot == .empty)
        #expect(await upstream.sentCount() == 0)
        let healthEffect = try #require(evaluation.effects.first)
        guard case .startHealthProbe = healthEffect else {
            Issue.record("expired quarantine should produce a deferred health probe")
            return
        }

        manager.applyHealthEffects(evaluation.effects)
        let probe = try await upstream.nextSent(at: 0)
        #expect(methodName(from: probe) == "tools/list")
        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: probe),
                    tools: []
                )
            )
        )
        await manager.drainRuntimeTasksForTesting()
        guard let healthState = manager.testStateSnapshot().upstream(id: 0)?.healthState,
              case .healthy = healthState
        else {
            Issue.record("successful deferred probe should restore healthy state")
            return
        }
    }

    @Test func deferredProcessRouteHealthProbeIsRejectedWhenInitializeShutdownWins()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let upstream = TestUpstreamClient()
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let eventLoop = group.next()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: { 16_000_000_000 },
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(
                    target: xcodeProcessTarget(processID: 27016, xcodeVersion: "27.0"),
                    upstreamIndices: [0]
                )
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let operationLease = manager.operationLeaseForTest(upstreamIndex: 0)
        for _ in 0..<3 {
            _ = manager.upstreamHealthManager.markRequestTimedOut(
                operationLease.proof,
                nowUptimeNs: 0
            )
        }

        var capturedEvaluation: RuntimeCoordinator.ProcessRouteUsabilityEvaluation?
        #expect(manager.initializeManager.performIfRunning {
            capturedEvaluation = manager.evaluateProcessRouteUpstreamUsability(
                policy: .toolsCatalog,
                nowUptimeNs: 16_000_000_000
            )
        })
        let evaluation = try #require(capturedEvaluation)
        let healthEffect = try #require(evaluation.effects.first)
        guard case .startHealthProbe = healthEffect else {
            Issue.record("expired quarantine should produce a deferred health probe")
            return
        }

        _ = manager.initializeManager.beginShutdown()
        manager.applyHealthEffects(evaluation.effects)
        await manager.drainRuntimeTasksForTesting()
        try await eventLoop.submit {}.get()

        #expect(await upstream.sentCount() == 0)
        #expect(timeoutScheduler.scheduledCount() == 1)
        #expect(timeoutScheduler.isCancelled(at: 0))
    }

    @Test func processRoutingCooldownTimersFollowRouteLifecycle() {
        let uptimeClock = TestUptimeClock()
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let target = xcodeProcessTarget(processID: 27014, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [TestUpstreamClient()],
            nowUptimeNanoseconds: uptimeClock.now,
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        manager.markXcodeProcessRouteUnavailable(upstreamIndex: 0, reason: "first")
        #expect(timeoutScheduler.scheduledCount() == 1)
        #expect(timeoutScheduler.isCancelled(at: 0) == false)

        uptimeClock.advance(by: .seconds(1))
        manager.markXcodeProcessRouteUnavailable(upstreamIndex: 0, reason: "extended")
        #expect(timeoutScheduler.scheduledCount() == 2)
        #expect(timeoutScheduler.isCancelled(at: 0))
        #expect(timeoutScheduler.fire(at: 0) == false)

        manager.markXcodeProcessRouteAvailable(upstreamIndex: 0)
        #expect(timeoutScheduler.isCancelled(at: 1))

        manager.markXcodeProcessRouteUnavailable(upstreamIndex: 0, reason: "retired")
        #expect(timeoutScheduler.scheduledCount() == 3)
        #expect(timeoutScheduler.fireIgnoringCancellation(at: 1))
        #expect(timeoutScheduler.scheduledCount() == 4)
        #expect(timeoutScheduler.isCancelled(at: 3))
        #expect(manager.unavailableXcodeProcessIDs() == [target.processID])

        uptimeClock.advance(by: .seconds(2))
        #expect(timeoutScheduler.fireIgnoringCancellation(at: 1))
        #expect(manager.unavailableXcodeProcessIDs() == [target.processID])

        manager.reconcileXcodeProcessTargets([], reason: "test_retire_cooldown")
        #expect(timeoutScheduler.isCancelled(at: 2))
    }

    @Test func processRoutingRetiresCrashedPIDAndAddsRelaunchedPID() async throws {
        let oldUpstream = TestUpstreamClient()
        let oldTarget = xcodeProcessTarget(processID: 27020, xcodeVersion: "27.0")
        let relaunchedTarget = xcodeProcessTarget(processID: 27021, xcodeVersion: "27.0")
        let createdUpstreams = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [oldUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: oldTarget, upstreamIndices: [0])
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
                (oldTarget, 0, [ownerBoundToolDescriptor(name: "BuildProject")])
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: old-tab, workspacePath: /Old/App.xcworkspace"
                    ]
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
        #expect(
            snapshot.processRoutes.map(\.processID) == [
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

    @Test func processOwnerRetiresEveryBridgeWhenXcodeCrashes() async throws {
        let oldBridges = [TestUpstreamClient(), TestUpstreamClient()]
        let oldTarget = xcodeProcessTarget(processID: 26652, xcodeVersion: "26.6")
        let relaunchedTarget = xcodeProcessTarget(processID: 26653, xcodeVersion: "26.6")
        let createdPools = NIOLockedValueBox<[[TestUpstreamClient]]>([])
        let fixture = RuntimeCoordinatorFixture(
            upstreams: oldBridges,
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: oldTarget, upstreamIndices: [0, 1])
            ],
            processRoutingEnabled: true,
            dynamicUpstreamFactory: { _ in
                let pool = [TestUpstreamClient(), TestUpstreamClient()]
                createdPools.withLockedValue { $0.append(pool) }
                return pool
            },
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }

        fixture.manager.reconcileXcodeProcessTargets(
            [relaunchedTarget],
            reason: "test_xcode_owner_relaunch"
        )

        #expect(try await oldBridges[0].nextStopCount() == 1)
        #expect(try await oldBridges[1].nextStopCount() == 1)
        #expect(createdPools.withLockedValue(\.count) == 1)
        let routes = fixture.manager.debugSnapshot().processRoutes
        #expect(routes.first { $0.processID == oldTarget.processID }?.state == "retired")
        #expect(
            routes.first { $0.processID == relaunchedTarget.processID }?.upstreamIndices
                == [2, 3]
        )
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
            .message(
                try makeInitializeResponse(
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
        let retryIndex = try #require(
            timeoutScheduler.activeTimeoutIndex(delay: .milliseconds(250))
        )
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
                        toolDescriptor(name: "Only27Relaunched")
                    ]
                )
            )
        )
        _ = try await manager.controlPlaneDebugMirror.waitForSnapshot {
            $0.canonicalToolsSourceUpstream == 2
        }

        let snapshot = manager.debugSnapshot()
        #expect(
            Set(snapshot.processRoutes.map(\.processID))
                == Set([
                    olderTarget.processID,
                    relaunchedTarget.processID,
                    oldNewerTarget.processID,
                ]))
        #expect(
            Set(snapshot.processToolCatalogs.map(\.processID))
                == Set([
                    olderTarget.processID,
                    relaunchedTarget.processID,
                ]))
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set([
                    "Only26",
                    "Only27Relaunched",
                ]))
    }

    @Test func processRoutingRetriesRelaunchedProcessCatalogAfterCatalogTimeout()
        async throws
    {
        var config = makeConfig(requestTimeout: 20)
        config.usesPermissionDialogAutomation = true
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
        let catalogCommits = LockedRecordedValues<(pid_t, Int)>()
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
            testHooks: RuntimeCoordinatorTestHooks(
                processRouteCatalogCommitted: { catalogCommits.append(($0, $1)) }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "cached-source"],
            ]),
            sourceUpstream: 1
        )
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
            .message(
                try makeInitializeResponse(
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

        let catalogTimeoutIndex = try #require(
            timeoutScheduler.activeTimeoutIndex(delay: .seconds(10))
        )
        let scheduledEventsBeforeCatalogTimeout = timeoutScheduler.scheduledEventCount()
        #expect(timeoutScheduler.fire(at: catalogTimeoutIndex))
        _ = try await waitWithTimeout(
            "waiting for timed-out 26 catalog cancellation",
            timeout: .seconds(2)
        ) {
            try await firstAttempt.nextSent(
                startingAt: 3,
                matching: { methodName(from: $0) == "notifications/cancelled" }
            )
        }
        #expect(await firstAttempt.stopCount() == 0)
        #expect(
            manager.unavailableXcodeProcessIDs().contains(
                relaunched26Target.processID
            ) == false)
        #expect(createdUpstreams.withLockedValue(\.count) == 1)
        let retryTimeoutIndex = try await timeoutScheduler.nextActiveTimeoutIndex(
            delay: .milliseconds(250),
            startingAtEventIndex: scheduledEventsBeforeCatalogTimeout
        )
        #expect(timeoutScheduler.fire(at: retryTimeoutIndex))
        let retryCatalogRequest = try await waitWithTimeout(
            "waiting for relaunched 26 catalog retry",
            timeout: .seconds(2)
        ) {
            try await firstAttempt.nextSent(
                startingAt: 4,
                matching: { methodName(from: $0) == "tools/list" }
            )
        }

        await firstAttempt.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: staleCatalogRequest),
                    tools: [
                        toolDescriptor(name: "StaleOnly26")
                    ]
                )
            )
        )
        #expect(
            manager.processControlPlane.catalog(
                forProcessID: relaunched26Target.processID
            ) == nil)

        let catalogCommitIndex = catalogCommits.count()
        await firstAttempt.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: retryCatalogRequest),
                    tools: [
                        toolDescriptor(name: "Only26Relaunched")
                    ]
                )
            )
        )
        #expect(
            try await nextRecordedValue(catalogCommits, at: catalogCommitIndex)
                == (relaunched26Target.processID, 2)
        )

        let snapshot = manager.debugSnapshot()
        #expect(
            Set(snapshot.processToolCatalogs.map(\.processID))
                == Set([
                    xcode27Target.processID,
                    relaunched26Target.processID,
                ]))
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set([
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
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [oldUpstream],
            upstreamReadinessGate: makeTestReadinessGate(readiness: readiness),
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: oldTarget, upstreamIndices: [0])
            ],
            processRoutingEnabled: true
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        _ = try await readiness.nextChangeWait(at: 0)

        manager.reconcileXcodeProcessTargets([], reason: "test_retire_waiting_primary")
        _ = try await oldUpstream.nextStopCount()

        await readiness.setReady(true)
        _ = try await readiness.nextCheck(at: 1)
        await manager.drainRuntimeTasksForTesting()

        #expect(await oldUpstream.startCount() == 0)
        #expect(await oldUpstream.sentCount() == 0)
    }

}
