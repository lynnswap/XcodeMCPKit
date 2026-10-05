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
struct NativeHostRuntimeTests {
    @Test func defaultCoordinatorOwnsOneHeadlessHost() async throws {
        let manager = RuntimeCoordinator(config: makeConfig(requestTimeout: 0),
            eventLoop: MultiThreadedEventLoopGroup.singleton.next(), startImmediately: false)
        defer { manager.shutdownAndWait() }
        #expect(manager.debugSnapshot().upstreams.count == 1)
    }

    @Test func nativeHostIgnoresInheritedGUIRoutingConfiguration() throws {
        let configuration = try NativeHostRuntime.makeDefaultUpstreamConfig(
            config: makeBridgeRuntimeConfig(makeConfig(requestTimeout: 5)),
            baseEnvironment: ["MCP_XCODE_PID": "9876", "MCP_XCODE_SESSION_ID": "parent-session",
                "XCODE_PID": "legacy", "DEVELOPER_DIR": "/Parent/Developer", "PATH": "/usr/bin"])
        #expect(configuration.environment["MCP_XCODE_PID"] == nil)
        #expect(configuration.environment["MCP_XCODE_SESSION_ID"] == nil)
        #expect(configuration.environment["XCODE_PID"] == nil)
        #expect(configuration.environment["DEVELOPER_DIR"] == "/Parent/Developer")
        #expect(configuration.environment["PATH"] == "/usr/bin")
    }


    @Test func nativeHostSlotUsesConfiguredHelper() throws {
        let slot = try NativeHostRuntime.makeUpstreamSlot(
            config: makeBridgeRuntimeConfig(makeConfig(requestTimeout: 0)))
        #expect(try upstreamCommand(from: slot).hasSuffix("/xcode-mcp-native-host"))
    }


    @Test func upstreamStderrLogLimiterSuppressesRepeatedMessages() {
        let limiter = UpstreamStderrLogLimiter(duplicateLogIntervalNanoseconds: 1_000_000_000)
        let message = "some upstream stderr"
        let first = limiter.decision(
            upstreamIndex: 0,
            message: message,
            nowUptimeNs: 0
        )
        let second = limiter.decision(
            upstreamIndex: 0,
            message: message,
            nowUptimeNs: 100_000_000
        )
        let third = limiter.decision(
            upstreamIndex: 0,
            message: message,
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

    @Test func processRoutingNoXcodeInitializeWaitDoesNotRescheduleTimeoutForJoinedClient()
        async throws
    {
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
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

    @Test func processRoutingNoXcodeRemovedInitializeDoesNotSuppressNextTimeout()
        async throws
    {
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
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

}
