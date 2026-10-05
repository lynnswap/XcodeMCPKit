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
    private static let terminalCoreSimulatorDiagnostic =
        "2026-10-05 23:53:55.624 xcode-mcp-native-host[43311:36380528] Loaded CoreSimulatorService is no longer valid for this process.  Simulator services will no longer be available.  Error=Error Domain=NSPOSIXErrorDomain Code=61 \"Connection refused\""

    @Test(arguments: [
        terminalCoreSimulatorDiagnostic,
        "2026-10-05 23:53:55.624 xcode-mcp-native-host[43311:36380528] CoreSimulatorService connection became invalid.  Simulator services will no longer be available.",
    ])
    func terminalCoreSimulatorDiagnosticsIdentifyAnUnusableNativeHost(message: String) {
        #expect(NativeHostRuntime.isTerminalCoreSimulatorDiagnostic(message))
    }

    @Test(arguments: [
        "2026-10-05 23:53:55.624 xcode-mcp-native-host[43311:36380528] CoreSimulatorService connection was interrupted.",
        "2026-10-05 23:53:55.624 xcode-mcp-native-host[43311:36380528] Error Domain=NSPOSIXErrorDomain Code=61 \"Connection refused\"",
        "[-[SimLaunchHostConnection _connectToServiceName:]_block_invoke:250] ERROR : Lost connection to com.apple.CoreSimulator.SimLaunchHost-arm64",
        "Loaded CoreSimulatorService is no longer valid for this process.  Simulator services will no longer be available.  Error=Error Domain=NSPOSIXErrorDomain Code=61",
        "2026-10-05 23:53:55.624 xcodebuild[43311:36380528] Loaded CoreSimulatorService is no longer valid for this process.  Simulator services will no longer be available.  Error=Error Domain=NSPOSIXErrorDomain Code=61",
        "2026-10-05 23:53:55.624 xcode-mcp-native-host[43311:36380528] xcodebuild output: Loaded CoreSimulatorService is no longer valid for this process.  Simulator services will no longer be available.  Error=Error Domain=NSPOSIXErrorDomain Code=61",
    ])
    func otherSimulatorDiagnosticsDoNotRequireNativeHostReplacement(message: String) {
        #expect(!NativeHostRuntime.isTerminalCoreSimulatorDiagnostic(message))
    }

    @Test func terminalCoreSimulatorDiagnosticReplacesHostWithoutReplayingActiveMutation() async throws {
        let initial = TestUpstreamClient()
        let replacement = TestUpstreamClient()
        let replacementCount = NIOLockedValueBox(0)
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 0),
            upstreams: [initial],
            nativeUpstreamFactory: {
                replacementCount.withLockedValue { $0 += 1 }
                return replacement
            }
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        let sessionID = "terminal-core-simulator"
        _ = try await fixture.initializePrimary(on: initial, sessionID: sessionID)
        _ = try await initial.nextSent(matching: { methodName(from: $0) == "notifications/initialized" })
        await manager.drainRuntimeTasksForTesting()
        manager.seedCanonicalToolsCatalog(.object(["tools": .array([documentationDescriptor(version: "old")])]), sourceUpstream: 0)
        let oldProof = manager.operationLeaseForTest(upstreamIndex: 0).proof

        let requestID = try #require(JSONRPC.ID(any: NSNumber(value: 501)))
        let session = manager.session(id: sessionID)
        let pending = session.router.registerRequest(idKey: requestID.key, on: fixture.eventLoop)
        let leaseID = manager.createRequestLease(descriptor: .init(
            sessionID: sessionID, label: "tools/call:XcodeUpdate",
            expectsResponse: true, isTopLevelClientRequest: true
        ))
        manager.activateRequestLease(leaseID, requestIDKey: requestID.key, upstreamIndex: 0, timeout: nil)
        let upstreamID = manager.assignUpstreamID(sessionID: sessionID, originalID: requestID, upstreamIndex: 0)
        let mutation = try JSONRPC.Wire.data(from: [
            "jsonrpc": "2.0", "id": upstreamID, "method": "tools/call",
            "params": ["name": "XcodeUpdate", "arguments": ["filePath": "/tmp/Project/File.swift", "newString": "updated"]],
        ])
        manager.sendUpstream(mutation, upstreamIndex: 0)
        _ = try await initial.nextSent(matching: { methodName(from: $0) == "tools/call" })
        await initial.blockStop()
        defer { Task { await initial.releaseBlockedStop() } }

        await initial.yield(.stderr(Self.terminalCoreSimulatorDiagnostic))
        try await initial.waitForBlockedStop()
        #expect(replacementCount.withLockedValue { $0 } == 1)
        #expect(manager.cachedToolsListResult() == nil)
        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            try await waitWithTimeout("terminal diagnostic should fail the active mutation") { try await pending.get() }
        }
        #expect(await replacement.sentCount() == 0)
        let newProof = manager.operationLeaseForTest(upstreamIndex: 0).proof
        #expect(newProof != oldProof)

        manager.handleUpstreamStderr(Self.terminalCoreSimulatorDiagnostic, upstreamIndex: 0, proof: oldProof)
        manager.handleUpstreamStderr(Self.terminalCoreSimulatorDiagnostic, upstreamIndex: 0, proof: oldProof)
        manager.handleUpstreamExit(1, upstreamIndex: 0, proof: oldProof)
        #expect(replacementCount.withLockedValue { $0 } == 1)
        #expect(manager.operationLeaseForTest(upstreamIndex: 0).proof == newProof)
        #expect(await replacement.sentCount() == 0)

        await initial.releaseBlockedStop()
        let initialize = try await replacement.nextSent(matching: { methodName(from: $0) == "initialize" })
        await replacement.yield(.message(try makeInitializeResponse(id: extractUpstreamID(from: initialize))))
        _ = try await replacement.nextSent(matching: { methodName(from: $0) == "notifications/initialized" })
        await manager.drainRuntimeTasksForTesting()
        #expect(manager.isInitialized())
        #expect(manager.hasSession(id: sessionID))

        await replacement.respondToToolsLists(with: .object(["tools": .array([documentationDescriptor(version: "replacement")])]))
        let catalog = try await manager.sharedToolsList(sessionID: sessionID, requestTimeoutOverride: .seconds(5))
        #expect(documentationDescriptorDescription(in: catalog) == "docs-replacement")
        #expect(manager.cachedToolsListResult() != nil)
        #expect(await replacement.sent().allSatisfy { methodName(from: $0) != "tools/call" })
        let lease = try #require(manager.debugSnapshot().leases.first { $0.leaseID == leaseID.uuidString })
        #expect(lease.releaseReason == "upstreamUnavailable")
    }

    @Test func terminalCoreSimulatorDiagnosticDoesNotRetireAnUnownedUpstream() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.seedCanonicalToolsCatalog(try jsonValue(["tools": []]), sourceUpstream: 0)
        let proof = manager.operationLeaseForTest(upstreamIndex: 0).proof

        manager.handleUpstreamStderr(Self.terminalCoreSimulatorDiagnostic, upstreamIndex: 0, proof: proof)

        #expect(manager.operationLeaseForTest(upstreamIndex: 0).proof == proof)
        #expect(manager.cachedToolsListResult() != nil)
        #expect(await upstream.stopCount() == 0)
    }

    @Test func terminalCoreSimulatorDiagnosticDuringInitializeFailsCallerAndRecovers() async throws {
        let initial = TestUpstreamClient()
        let replacement = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 0), upstreams: [initial],
            nativeUpstreamFactory: { replacement }
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        let failed = fixture.registerInitialize(requestID: 1, sessionID: "failed-initialize")
        _ = try await initial.nextSent(matching: { methodName(from: $0) == "initialize" })

        await initial.yield(.stderr(Self.terminalCoreSimulatorDiagnostic))

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            try await waitWithTimeout("terminal diagnostic should fail the initial handshake") { try await failed.get() }
        }
        #expect(!manager.hasSession(id: "failed-initialize"))
        let retry = try await replacement.nextSent(matching: { methodName(from: $0) == "initialize" })
        let recovered = fixture.registerInitialize(requestID: 2, sessionID: "recovered-initialize")
        await replacement.yield(.message(try makeInitializeResponse(id: extractUpstreamID(from: retry))))
        _ = try await waitWithTimeout("replacement should complete the next initialize") { try await recovered.get() }
        #expect(manager.isInitialized())
        #expect(manager.hasSession(id: "recovered-initialize"))
        #expect(await initial.stopCount() == 1)
    }

    @Test func replacementInitializeFailureReachesCallerAndAllowsLaterRecovery() async throws {
        let initial = TestUpstreamClient()
        let failedReplacement = TestUpstreamClient()
        let successfulReplacement = TestUpstreamClient()
        let replacementCount = NIOLockedValueBox(0)
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 5), upstreams: [initial],
            nativeUpstreamFactory: {
                let count = replacementCount.withLockedValue { count in
                    count += 1
                    return count
                }
                return count == 1 ? failedReplacement : successfulReplacement
            }
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        _ = try await fixture.initializePrimary(on: initial)
        await initial.yield(.stderr(Self.terminalCoreSimulatorDiagnostic))
        let retry = try await failedReplacement.nextSent(matching: { methodName(from: $0) == "initialize" })
        let pending = fixture.registerInitialize(requestID: 2, sessionID: "replacement-failed")

        await failedReplacement.yield(.message(try makeInitializeErrorResponse(
            id: extractUpstreamID(from: retry), message: "replacement initialization failed"
        )))

        let response = try decodeJSON(from: try await waitWithTimeout("replacement initialize failure should reach the caller") {
            try await pending.get()
        })
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["message"] as? String == "replacement initialization failed")
        #expect(!manager.hasSession(id: "replacement-failed"))
        let nextInitialize = try await successfulReplacement.nextSent(matching: { methodName(from: $0) == "initialize" })
        let recovered = fixture.registerInitialize(requestID: 3, sessionID: "replacement-recovered")
        await successfulReplacement.yield(.message(try makeInitializeResponse(id: extractUpstreamID(from: nextInitialize))))
        _ = try await waitWithTimeout("later native host should complete initialize") { try await recovered.get() }
        #expect(manager.isInitialized())
        #expect(manager.hasSession(id: "replacement-recovered"))
        #expect(replacementCount.withLockedValue { $0 } == 2)
    }

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

        let proof = manager.operationLeaseForTest(upstreamIndex: 0).proof
        manager.handleUpstreamStderr("repeated stderr", upstreamIndex: 0, proof: proof)
        manager.handleUpstreamStderr("repeated stderr", upstreamIndex: 0, proof: proof)

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
