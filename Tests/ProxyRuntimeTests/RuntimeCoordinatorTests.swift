import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
import ProxyCore
import ProxyMCP
import XcodeMCPTestSupport
@testable import ProxySession

@Suite(.serialized)
struct RuntimeCoordinatorTests {
    @Test func defaultUpstreamsDoNotInjectXcodePIDEnvironment() async throws {
        let environment = try defaultUpstreamEnvironment(sharedSessionID: nil)

        #expect(environment["MCP_XCODE_PID"] == nil)
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

    @Test func xcodeReadinessRequiresWorkspaceWindow() {
        let pids: Set<pid_t> = [1234]

        #expect(
            XcodeReadinessProbe.hasReadyWorkspaceWindow(
                xcodeProcessIDs: pids,
                windows: []
            ) == false
        )
        #expect(
            XcodeReadinessProbe.hasReadyWorkspaceWindow(
                xcodeProcessIDs: pids,
                windows: [
                    .init(ownerPID: 1234, title: "Welcome to Xcode", layer: 0, alpha: 1)
                ]
            ) == false
        )
        #expect(
            XcodeReadinessProbe.hasReadyWorkspaceWindow(
                xcodeProcessIDs: pids,
                windows: [
                    .init(ownerPID: 5678, title: "XcodeMCPKit — xcode", layer: 0, alpha: 1)
                ]
            ) == false
        )
        #expect(
            XcodeReadinessProbe.hasReadyWorkspaceWindow(
                xcodeProcessIDs: pids,
                windows: [
                    .init(ownerPID: 1234, title: "XcodeMCPKit — xcode", layer: 1, alpha: 1)
                ]
            ) == false
        )
        #expect(
            XcodeReadinessProbe.hasReadyWorkspaceWindow(
                xcodeProcessIDs: pids,
                windows: [
                    .init(ownerPID: 1234, title: "XcodeMCPKit — xcode", layer: 0, alpha: 1)
                ]
            ) == true
        )
    }

    @Test func xcodeReadinessFallsBackToProcessWhenAccessibilityWindowsAreUnavailable() {
        #expect(
            XcodeReadinessProbe.isReady(
                xcodeProcessIDs: [1234],
                windows: nil
            )
        )
        #expect(
            XcodeReadinessProbe.isReady(
                xcodeProcessIDs: [],
                windows: nil
            ) == false
        )
        #expect(
            XcodeReadinessProbe.isReady(
                xcodeProcessIDs: [1234],
                windows: [
                    .init(ownerPID: 1234, title: "Welcome to Xcode", layer: 0, alpha: 1)
                ]
            ) == false
        )
    }

    @Test func xcodeReadinessParsesPGrepOutput() {
        let output = ProcessOutput(terminationStatus: 0, stdout: "1234\n\n5678\n", stderr: "")

        #expect(XcodeReadinessProbe.processIDs(fromPGrepOutput: output) == [1234, 5678])
        #expect(
            XcodeReadinessProbe.processIDs(
                fromPGrepOutput: ProcessOutput(terminationStatus: 1, stdout: "1234\n", stderr: "")
            ).isEmpty
        )
    }

    @Test func defaultReadinessGateRecognizesFlaggedXcrunMCPBridgeInvocation() {
        var config = makeConfig(requestTimeout: 5)
        config.upstreamArgs = ["--sdk", "macosx", "mcpbridge"]
        #expect(RuntimeCoordinator.isDefaultXcrunMCPBridgeInvocation(config: config))

        config.upstreamCommand = "/usr/bin/xcrun"
        config.upstreamArgs = ["--sdk=macosx", "--toolchain", "default", "mcpbridge"]
        #expect(RuntimeCoordinator.isDefaultXcrunMCPBridgeInvocation(config: config))
    }

    @Test func defaultReadinessGateIgnoresNonMCPBridgeAndCustomWrapperInvocations() {
        var config = makeConfig(requestTimeout: 5)
        config.upstreamArgs = ["--sdk", "macosx", "swift"]
        #expect(RuntimeCoordinator.isDefaultXcrunMCPBridgeInvocation(config: config) == false)

        config.upstreamCommand = "/bin/echo"
        config.upstreamArgs = ["xcrun", "mcpbridge"]
        #expect(RuntimeCoordinator.isDefaultXcrunMCPBridgeInvocation(config: config) == false)

        config.upstreamCommand = "xcrun"
        config.upstreamArgs = ["--sdk", "mcpbridge"]
        #expect(RuntimeCoordinator.isDefaultXcrunMCPBridgeInvocation(config: config) == false)
    }

    @Test func readinessGateDefersStartupUntilXcodeIsAvailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: false)
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(readiness: readiness)
        )
        defer { manager.shutdownAndWait() }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await upstream.startCount() == 0)
        #expect(await upstream.sentCount() == 0)

        await readiness.setReady(true)
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: sent) == "initialize")
        #expect(await upstream.startCount() > 0)
    }

    @Test func readinessGateLaunchesXcodeWhenUnavailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: false)
        let launchRecorder = XcodeLaunchRecorder()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                launchRecorder: launchRecorder
            )
        )
        defer { manager.shutdownAndWait() }

        #expect(await waitUntil(timeout: .seconds(2)) {
            await launchRecorder.launchCount() == 1
        })
        #expect(await upstream.startCount() == 0)
        #expect(await upstream.sentCount() == 0)

        await readiness.setReady(true)
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        #expect(await launchRecorder.launchCount() == 1)
        #expect(await upstream.startCount() > 0)
    }

    @Test func readinessGateRetriesLaunchAfterFailedAutoLaunch() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: false)
        let launchRecorder = XcodeLaunchRecorder(outcomes: [false, true])
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                launchRecorder: launchRecorder
            )
        )
        defer { manager.shutdownAndWait() }

        #expect(await waitUntil(timeout: .seconds(2)) {
            await launchRecorder.launchCount() == 2
        })
        #expect(await upstream.startCount() == 0)

        await readiness.setReady(true)
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
    }

    @Test func readinessGateRetriesLaunchWhenSuccessfulOpenDoesNotProduceXcodeProcess() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: false)
        let availability = AvailabilityFlag(isAvailable: false)
        let launchRecorder = XcodeLaunchRecorder()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                availability: availability,
                launchRetryIntervalNanoseconds: 2_000_000,
                launchRecorder: launchRecorder
            )
        )
        defer { manager.shutdownAndWait() }

        #expect(await waitUntil(timeout: .seconds(2)) {
            await launchRecorder.launchCount() >= 2
        })
        #expect(await upstream.startCount() == 0)

        await availability.setAvailable(true)
        await readiness.setReady(true)
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        #expect(await upstream.startCount() > 0)
    }

    @Test func readinessGateRetriesLaunchWhenXcodeQuitsWhileWaiting() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: false)
        let availability = AvailabilityFlag(isAvailable: true)
        let launchRecorder = XcodeLaunchRecorder()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                availability: availability,
                launchRecorder: launchRecorder
            )
        )
        defer { manager.shutdownAndWait() }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await launchRecorder.launchCount() == 0)
        #expect(await upstream.startCount() == 0)

        await availability.setAvailable(false)
        #expect(await waitUntil(timeout: .seconds(2)) {
            await launchRecorder.launchCount() == 1
        })
        #expect(await upstream.startCount() == 0)

        await availability.setAvailable(true)
        await readiness.setReady(true)
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        #expect(await upstream.startCount() > 0)
    }

    @Test func readinessGateCompletesPendingInitializeAfterXcodeAppears() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: false)
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(readiness: readiness)
        )
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await upstream.sentCount() == 0)

        await readiness.setReady(true)
        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: sent) == "initialize")
        let upstreamID = try extractUpstreamID(from: sent)
        await upstream.yield(.message(try makeInitializeResponse(id: upstreamID)))

        let response = try decodeJSON(
            from: try await waitWithTimeout(
                "waiting for deferred initialize response",
                timeout: .seconds(2)
            ) {
                try await future.get()
            }
        )
        #expect((response["id"] as? NSNumber)?.intValue == 1)
        let initializeRequests = await upstream.sent().filter { methodName(from: $0) == "initialize" }
        #expect(initializeRequests.count == 1)
    }

    @Test func readinessGateDebugResetDropsWaitingEagerInitialize() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: false)
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(readiness: readiness)
        )
        defer { manager.shutdownAndWait() }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await upstream.sentCount() == 0)

        manager.debugReset()
        await readiness.setReady(true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(await upstream.sentCount() == 0)
        #expect(await upstream.startCount() == 0)
    }

    @Test func readinessGateDoesNotSendTimedOutInitializeWaiterWhenXcodeAppears() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: false)
        let clock = TestClock()
        let config = makeConfig(requestTimeout: 0.05)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(readiness: readiness),
            scheduleRuntimeTimeout: makeDeterministicRuntimeTimeoutScheduler(clock: clock)
        )
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(60))
        await #expect(throws: TimeoutError.self) {
            _ = try await future.get()
        }
        #expect(await upstream.sentCount() == 0)

        let retryFuture = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(60))
        await #expect(throws: TimeoutError.self) {
            _ = try await retryFuture.get()
        }
        #expect(await upstream.sentCount() == 0)

        await readiness.setReady(true)
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        #expect(await upstream.sentCount() == 1)
        #expect(await upstream.startCount() == 2)
        let initializeRequests = await upstream.sent().filter { methodName(from: $0) == "initialize" }
        #expect(initializeRequests.count == 1)
    }

    @Test func readinessGateWaitsInsteadOfTightRetryingWhenXcodeDisappears() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: true)
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(readiness: readiness)
        )
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID = try extractUpstreamID(from: sent)
        await upstream.yield(.message(try makeInitializeResponse(id: upstreamID)))
        #expect(await waitUntil(timeout: .seconds(2)) {
            manager.isInitialized()
        })

        await readiness.setReady(false)
        await upstream.yield(.exit(1))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await upstream.sentCount() == 2)

        await readiness.setReady(true)
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
    }

    @Test func readinessGateBacksOffBeforeRetryingWhenXcodeIsStillAvailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: true)
        let sleepRecorder = ControlledReadinessSleep()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                sleepRecorder: sleepRecorder
            )
        )
        defer { manager.shutdownAndWait() }

        let firstInit = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let firstInitID = try extractUpstreamID(from: firstInit)
        await upstream.yield(.message(try makeInitializeResponse(id: firstInitID)))
        #expect(await waitUntil(timeout: .seconds(2)) {
            manager.isInitialized()
        })

        await upstream.yield(.exit(1))
        _ = try await waitWithTimeout(
            "waiting for readiness retry backoff",
            timeout: .seconds(2)
        ) {
            try await sleepRecorder.nextSleep(at: 0)
        }
        #expect(await upstream.sentCount() == 2)

        await sleepRecorder.resumeNext()
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let secondInit = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        let secondInitID = try extractUpstreamID(from: secondInit)
        await upstream.yield(.message(try makeInitializeResponse(id: secondInitID)))
        #expect(await waitUntil(timeout: .seconds(2)) {
            manager.isInitialized()
        })

        await upstream.yield(.exit(1))
        let secondDelay = try await waitWithTimeout(
            "waiting for second readiness retry backoff",
            timeout: .seconds(2)
        ) {
            try await sleepRecorder.nextSleep(at: 1)
        }
        #expect(secondDelay == 1_000_000_000)
        await sleepRecorder.resumeNext()
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        manager.handleUpstreamStderr("repeated stderr", upstreamIndex: 0)
        manager.handleUpstreamStderr("repeated stderr", upstreamIndex: 0)

        let snapshot = manager.debugSnapshot()
        #expect(snapshot.upstreams[0].recentStderr.count == 2)
    }

    @Test func sessionManagerQueuesInitializeRequests() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let request1 = makeInitializeRequest(id: 1)
        let request2 = makeInitializeRequest(id: 2)
        let future1 = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: request1,
            on: eventLoop
        )
        let future2 = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 2))!,
            requestObject: request2,
            on: eventLoop
        )

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

    @Test func sessionManagerMarksPrimaryUsableBeforeInitializeReturns() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID = try extractUpstreamID(from: sent)
        await upstream.yield(.message(try makeInitializeResponse(id: upstreamID)))

        _ = try await future.get()
        #expect(manager.chooseUpstreamIndex() == 0)
    }

    @Test func sessionManagerRestoresPendingInitializeWhenInitializedNotificationOverloads()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initialInitialize = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)

        await upstream.overloadNextInitializedNotificationSend()
        await upstream.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let retriedInitialize = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)

        await upstream.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))

        _ = try await future.get()
    }

    @Test func sessionManagerCancelsOriginalInitTimeoutBeforeRetryingInitializedNotificationOverload()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
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
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let initialInitialize = try #require(await upstream.sentValue(at: 0))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)

        await upstream.overloadNextInitializedNotificationSend()
        await timeoutClock.sleep(untilSuspendedBy: 1)
        timeoutClock.advance(by: .milliseconds(150))
        await upstream.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let retriedInitialize = try #require(await upstream.sentValue(at: 2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)

        await timeoutClock.sleep(untilSuspendedBy: 1)
        timeoutClock.advance(by: .milliseconds(180))
        await upstream.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))
        try await waitForSentCount(upstream, count: 4, timeoutSeconds: 2)

        let response = try decodeJSON(from: try await future.get())
        #expect(response["result"] != nil, "initializeResponse=\(response)")
    }

    @Test func sessionManagerRunsSecondaryWarmupAfterRecoveredInitializedNotification()
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

        let future = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initialInitialize = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await waitForSentCount(upstream0, count: 3, timeoutSeconds: 2)
        let retriedInitialize = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let retriedUpstreamID = try extractUpstreamID(from: retriedInitialize)

        await upstream0.yield(.message(try makeInitializeResponse(id: retriedUpstreamID)))

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
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
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

        try await waitForSentCount(upstream1, count: 3, timeoutSeconds: 2)
        let rejectedInitialized = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))
        #expect(methodName(from: rejectedInitialized) == "notifications/initialized")
        let retriedWarmInitialize = try await sentValue(from: upstream1, at: 2, timeout: .seconds(2))
        #expect(methodName(from: retriedWarmInitialize) == "initialize")
    }

    @Test func sessionManagerDropsUnmappedNotificationsAfterInitializeCompletes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-A"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()

        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: RPCID(any: NSNumber(value: 1))!,
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
        await upstream.yield(.message(notification))
        #expect(
            await staysTrue(for: .milliseconds(200)) {
                session.router.drainBufferedNotifications().isEmpty
            }
        )
    }

    @Test func sessionManagerRoutesUnmappedNotificationsDuringInitializeHandshake() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-handshake"
        let session = manager.session(id: sessionID)
        _ = session.router.drainBufferedNotifications()

        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: RPCID(any: NSNumber(value: 1))!,
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
        await upstream.yield(.message(notification))

        let received = try await nextBufferedNotifications(from: session.router)
        #expect(received.count == 1)
        #expect(received.first == notification)

        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        _ = try await future.get()
    }

    @Test func sessionManagerDropsUnmappedNotificationsForCachedInitializeSessions() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let firstFuture = manager.registerInitialize(
            sessionID: "session-A",
            originalID: RPCID(any: NSNumber(value: 1))!,
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
            originalID: RPCID(any: NSNumber(value: 2))!,
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
        await upstream.yield(.message(notification))

        _ = try await cachedFuture.get()
        #expect(
            await staysTrue(for: .milliseconds(200)) {
                session.router.drainBufferedNotifications().isEmpty
            }
        )
    }

    @Test func sessionManagerDoesNotRecreateRemovedSessionWhenInitializeCompletes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-removed"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        manager.removeSession(id: sessionID)

        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))

        _ = try await future.get()
        #expect(manager.hasSession(id: sessionID) == false)
    }

    @Test func sessionManagerDoesNotApplyRemovedInitializeStateToRecreatedSession() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-recreated"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        manager.removeSession(id: sessionID)
        let replacement = manager.session(id: sessionID)
        _ = replacement.router.drainBufferedNotifications()

        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 7],
            ],
            options: []
        )
        await upstream.yield(.message(notification))

        _ = try await future.get()
        #expect(
            await staysTrue(for: .milliseconds(200)) {
                replacement.router.drainBufferedNotifications().isEmpty
            }
        )
    }

    @Test func sessionManagerDoesNotRouteUnmappedNotificationsToCachedInitializeSessions() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
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
            originalID: RPCID(any: NSNumber(value: 1))!,
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
        await upstream0.yield(.message(notification0))
        await upstream1.yield(.message(notification1))

        #expect(
            await staysTrue(for: .milliseconds(200)) {
                session.router.drainBufferedNotifications().isEmpty
            }
        )
    }

    @Test func sessionManagerTimeoutResetsInitState() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let timeoutClock = TestClock()
        let config = makeConfig(requestTimeout: 1)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            scheduleRuntimeTimeout: makeDeterministicRuntimeTimeoutScheduler(clock: timeoutClock)
        )
        defer { manager.shutdownAndWait() }

        let request = makeInitializeRequest(id: 1)
        let future = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: request,
            on: eventLoop
        )

        try await spinUntilSentCount(
            upstream,
            count: 1,
            description: "waiting for initial initialize request"
        )
        #expect((await upstream.sent()).count == 1)

        await timeoutClock.sleep(untilSuspendedBy: 1)
        timeoutClock.advance(by: .seconds(1))
        await #expect(throws: TimeoutError.self) {
            try await future.get()
        }
        #expect(manager.testStateSnapshot().initInFlight == false)

        _ = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 2))!,
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
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)

        await manager.shutdown()

        await #expect(throws: CancellationError.self) {
            try await future.get()
        }
    }

    @Test func controlPlaneInitializeTimeoutDoesNotAbortLongerWaiter() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let shortTask = Task {
            try await manager.controlPlaneCoordinator.clientInitialize(
                deadlineUptimeNs: RuntimeCoordinator.timeoutDeadline(for: .milliseconds(50))
            )
        }
        let longTask = Task {
            try await manager.controlPlaneCoordinator.clientInitialize(
                deadlineUptimeNs: RuntimeCoordinator.timeoutDeadline(for: .seconds(1))
            )
        }

        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)

        await #expect(throws: TimeoutError.self) {
            _ = try await shortTask.value
        }

        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))

        let longResult = try await longTask.value
        guard case .object(let object) = longResult else {
            Issue.record("initialize result should be an object")
            return
        }
        #expect(object["capabilities"] != nil)
    }

    @Test func controlPlaneInitializeCancellationDoesNotAbortLongerWaiter() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let cancelledTask = Task {
            try await manager.controlPlaneCoordinator.clientInitialize(
                deadlineUptimeNs: RuntimeCoordinator.timeoutDeadline(for: .seconds(1))
            )
        }
        let longTask = Task {
            try await manager.controlPlaneCoordinator.clientInitialize(
                deadlineUptimeNs: RuntimeCoordinator.timeoutDeadline(for: .seconds(1))
            )
        }

        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        cancelledTask.cancel()

        do {
            _ = try await cancelledTask.value
            Issue.record("cancelled initialize waiter should not complete successfully")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError but received \(error)")
        }

        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))

        let longResult = try await longTask.value
        guard case .object(let object) = longResult else {
            Issue.record("initialize result should be an object")
            return
        }
        #expect(object["capabilities"] != nil)
    }

    @Test func sessionManagerTimeoutDoesNotClearRecreatedSessionInitializeRoutingState()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 0.1)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-timeout-recreated"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)

        manager.removeSession(id: sessionID)
        _ = manager.session(id: sessionID)
        manager.testSetInitializeRoutingState(
            sessionID: sessionID,
            upstreamIndex: 0,
            preferOnNextPin: true,
            didReceiveInitializeUpstreamMessage: true
        )
        let replacementSnapshotBeforeTimeout = try #require(manager.testSessionSnapshot(id: sessionID))

        await #expect(throws: TimeoutError.self) {
            try await future.get()
        }

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
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-error-recreated"
        _ = manager.session(id: sessionID)
        let future = manager.registerInitialize(
            sessionID: sessionID,
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let sent = await upstream.sent()
        let initID = try extractUpstreamID(from: sent[0])

        manager.removeSession(id: sessionID)
        _ = manager.session(id: sessionID)
        manager.testSetInitializeRoutingState(
            sessionID: sessionID,
            upstreamIndex: 0,
            preferOnNextPin: true,
            didReceiveInitializeUpstreamMessage: true
        )
        let replacementSnapshotBeforeError = try #require(manager.testSessionSnapshot(id: sessionID))

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

        let response = try decodeJSON(from: try await future.get())
        let errorObject = try #require(response["error"] as? [String: Any])
        #expect(errorObject["message"] as? String == "boom")

        let replacementSnapshotAfterError = try #require(manager.testSessionSnapshot(id: sessionID))
        #expect(replacementSnapshotAfterError.generation == replacementSnapshotBeforeError.generation)
    }

    @Test func sessionManagerSharedToolsListTimeoutStartsFreshControlPlaneLoad() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
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
                requestTimeoutOverride: .milliseconds(50)
            )
        }
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let firstRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: firstRequest) == "tools/list")
        await #expect(throws: TimeoutError.self) {
            _ = try await firstTask.value
        }

        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0
            }
        )

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .milliseconds(50)
            )
        }
        try await waitForSentCount(upstream, count: 4, timeoutSeconds: 2)
        let secondRequest = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        #expect(methodName(from: secondRequest) == "tools/list")
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
            originalID: RPCID(any: NSNumber(value: 1))!,
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

        #expect(
            await staysTrue(for: .milliseconds(200)) {
                await upstream.sentCount() == 3
            }
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
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

        try await Task.sleep(nanoseconds: 120_000_000)

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }

        #expect(
            await waitUntil(timeout: .seconds(2)) {
                await upstream.sentCount() >= 4
            }
        )
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
            originalID: RPCID(any: NSNumber(value: 1))!,
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
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0
            }
        )
    }

    @Test func sessionManagerSharedToolsListStopsPromotingAfterLoadBecomesShared() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
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

        try await Task.sleep(nanoseconds: 120_000_000)

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))

        try await Task.sleep(nanoseconds: 120_000_000)

        let thirdTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .seconds(5)
            )
        }

        #expect(
            await staysTrue(for: .milliseconds(250)) {
                await upstream.sentCount() == 4
            }
        )

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
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
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

        try await Task.sleep(nanoseconds: 120_000_000)

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

        secondTask.cancel()
        do {
            _ = try await secondTask.value
            Issue.record("second promoted tools/list waiter should be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for promoted waiter but received \(error)")
        }

        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0
            }
        )
    }

    @Test func sessionManagerSharedToolsListTimeoutCancelsStalePrewarmLoad() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.prewarmToolsList = true
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
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
                requestTimeoutOverride: .milliseconds(50)
            )
        }

        await #expect(throws: TimeoutError.self) {
            _ = try await firstTask.value
        }
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0
            }
        )

        let secondTask = Task {
            try await manager.sharedToolsList(
                sessionID: sessionID,
                requestTimeoutOverride: .milliseconds(50)
            )
        }
        try await waitForSentCount(upstream, count: 4, timeoutSeconds: 2)
        let secondRequest = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        #expect(methodName(from: secondRequest) == "tools/list")
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
            originalID: RPCID(any: NSNumber(value: 1))!,
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

    @Test func sessionManagerLiveXcodeListWindowsTimeoutStartsFreshControlPlaneLoad()
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
            originalID: RPCID(any: NSNumber(value: 1))!,
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
                requestTimeoutOverride: .milliseconds(50)
            )
        }
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let firstRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: firstRequest) == "tools/call")
        await #expect(throws: TimeoutError.self) {
            _ = try await firstTask.value
        }

        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0
            }
        )

        let secondTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .milliseconds(50)
            )
        }
        try await waitForSentCount(upstream, count: 4, timeoutSeconds: 2)
        let secondRequest = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        #expect(methodName(from: secondRequest) == "tools/call")
        await #expect(throws: TimeoutError.self) {
            _ = try await secondTask.value
        }
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
            originalID: RPCID(any: NSNumber(value: 1))!,
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

        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0
            }
        )
    }

    @Test func sessionManagerPromotedLiveXcodeListWindowsCancellationRemovesMigratedWaiter()
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
            originalID: RPCID(any: NSNumber(value: 1))!,
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

        try await Task.sleep(nanoseconds: 120_000_000)

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

        secondTask.cancel()
        do {
            _ = try await secondTask.value
            Issue.record("second promoted XcodeListWindows waiter should be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for promoted XcodeListWindows waiter but received \(error)")
        }

        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0
            }
        )
    }

    @Test func controlPlaneRPCHandleCancelBeforeQueueStartCapturesQueuedState() {
        let handle = ControlPlaneRPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlaneRPCCancelSnapshot?>(nil)

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == nil)
        #expect(snapshot?.upstreamIndex == nil)
        #expect(snapshot?.requestIDKey == nil)
        #expect(handle.markRegistered(registrationToken: UUID(), upstreamIndex: 0) == false)
    }

    @Test func controlPlaneRPCHandleCancelAfterRegisterCapturesRegistrationState() {
        let handle = ControlPlaneRPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlaneRPCCancelSnapshot?>(nil)
        let token = UUID()

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        #expect(handle.markRegistered(registrationToken: token, upstreamIndex: 2))

        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == token)
        #expect(snapshot?.upstreamIndex == 2)
        #expect(snapshot?.requestIDKey == nil)
        #expect(handle.markAssigned(registrationToken: token, upstreamIndex: 2, requestIDKey: "req") == false)
    }

    @Test func controlPlaneRPCHandleCancelAfterAssignCapturesRequestMappingState() {
        let handle = ControlPlaneRPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlaneRPCCancelSnapshot?>(nil)
        let token = UUID()

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        #expect(handle.markRegistered(registrationToken: token, upstreamIndex: 1))
        #expect(handle.markAssigned(registrationToken: token, upstreamIndex: 1, requestIDKey: "req-1"))

        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == token)
        #expect(snapshot?.upstreamIndex == 1)
        #expect(snapshot?.requestIDKey == "req-1")
    }

    @Test func controlPlaneRPCHandleCancelAfterSendUsesAssignedSnapshotUntilFinished() {
        let handle = ControlPlaneRPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlaneRPCCancelSnapshot?>(nil)
        let token = UUID()

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        #expect(handle.markRegistered(registrationToken: token, upstreamIndex: 0))
        #expect(handle.markAssigned(registrationToken: token, upstreamIndex: 0, requestIDKey: "req-after-send"))

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
        let timeout = MCPMethodDispatcher.timeoutForInitialize(defaultSeconds: 0)
        #expect(timeout?.nanoseconds == TimeAmount.seconds(60).nanoseconds)
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
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])

        #expect(params["protocolVersion"] as? String == "2025-03-26")
        #expect(clientInfo["name"] as? String == "custom-proxy")
        #expect(clientInfo["version"] as? String == manager.defaultProxyClientVersion())
        #expect(capabilities["roots"] as? Bool == true)
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
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])

        #expect(clientInfo["name"] as? String == "Claude")
        #expect(clientInfo["version"] as? String == manager.defaultClientVersion(for: "Claude"))
    }

    @Test func xcodeChatClientVersionFallsBackToCodeAliasWhenExactStemMissing() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let version = manager.xcodeChatClientVersion(
            for: "Claude",
            defaults: [
                "IDEChatClaudeCodeVersion": #"{"version":"9.9.9"}"#,
            ]
        )

        #expect(version == "9.9.9")
    }

    @Test func xcodeChatClientVersionPrefersExactStemMatchOverGenericCodeAlias() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let version = manager.xcodeChatClientVersion(
            for: "Claude",
            defaults: [
                "IDEChatClaudeVersion": #"{"version":"1.2.3"}"#,
                "IDEChatClaudeCodeVersion": #"{"version":"9.9.9"}"#,
            ]
        )

        #expect(version == "1.2.3")
    }

    @Test func sessionManagerFallsBackToDefaultInitializeParamsWhenConfigFileIsInvalid()
        async throws
    {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake
            protocolVersion = "broken"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        var config = makeConfig(requestTimeout: 5)
        config.configPath = configPath
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])

        #expect(params["protocolVersion"] as? String == "2025-03-26")
        #expect(clientInfo["name"] as? String == manager.defaultProxyClientName())
        #expect(clientInfo["version"] as? String == manager.defaultProxyClientVersion())
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
        var config = makeConfig(requestTimeout: 0.1)
        config.configPath = configPath
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            scheduleRuntimeTimeout: makeDeterministicRuntimeTimeoutScheduler(clock: timeoutClock)
        )
        defer { manager.shutdownAndWait() }

        try await spinUntilSentCount(
            upstream,
            count: 1,
            description: "waiting for eager initialize request"
        )
        await timeoutClock.sleep(untilSuspendedBy: 1)
        timeoutClock.advance(by: .milliseconds(100))
        try await spinUntil("waiting for eager initialize timeout", maxIterations: 1_000) {
            let snapshot = manager.testStateSnapshot()
            return snapshot.initInFlight == false && snapshot.hasInitResult == false
        }

        _ = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
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
        #expect(params["protocolVersion"] as? String == "2025-03-26")
        #expect(clientInfo["name"] as? String == "configured-proxy")
        #expect(clientInfo["version"] as? String == manager.defaultProxyClientVersion())
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
            originalID: RPCID(any: NSNumber(value: 1))!,
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
            originalID: RPCID(any: NSNumber(value: 2))!,
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
            originalID: RPCID(any: NSNumber(value: 1))!,
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

        let activeDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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
                upstreamIndex: selectedUpstreamIndex,
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
        let queuedDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-queued",
            label: "tools/list",
            isBatch: false,
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
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            manager.sendUpstream(queuedRequestData, upstreamIndex: selectedUpstreamIndex)
            return eventLoop.makeSucceededFuture(())
        }

        try await waitForCondition(timeoutSeconds: 2) {
            manager.debugSnapshot().queuedRequestCount == 1
        }

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
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        // First init establishes the cached init result.
        let init1 = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
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
        await upstream.yield(.exit(1))
        try await waitForCondition(timeoutSeconds: 2) {
            manager.testStateSnapshot().hasInitResult == false
        }

        // A new downstream initialize must trigger a new upstream initialize (no cached response).
        let init2 = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 2))!,
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
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        manager.setCachedToolsListResult(try #require(JSONValue(any: ["tools": []])))
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
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let activeDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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
                upstreamIndex: selectedUpstreamIndex,
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
        let queuedDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-queued",
            label: "tools/list",
            isBatch: false,
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
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            manager.sendUpstream(queuedRequestData, upstreamIndex: selectedUpstreamIndex)
            return eventLoop.makeSucceededFuture(())
        }

        try await waitForCondition(timeoutSeconds: 2) {
            manager.debugSnapshot().queuedRequestCount == 1
        }

        await upstream.yield(.exit(1))
        try await waitForCondition(timeoutSeconds: 2) {
            manager.testStateSnapshot().upstreams[0].initInFlight
                && manager.debugSnapshot().queuedRequestCount == 1
        }

        let reinitRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
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
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdownAndWait() }

        // First init establishes the cached init result (primary only).
        let init1 = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
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
        await upstream0.yield(.exit(1))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.testStateSnapshot().upstreams[0].isInitialized == false
            }
        )

        // Now simulate the last initialized upstream dying too.
        await upstream1.yield(.exit(1))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.testStateSnapshot().upstreams[1].isInitialized == false
            }
        )

        // Ensure the cached init result is cleared before asserting that a new downstream initialize
        // triggers a fresh upstream initialize. This avoids race/flakiness where the exit event hasn't
        // been processed yet on the event loop.
        try await waitForCondition(timeoutSeconds: 2) {
            manager.testStateSnapshot().hasInitResult == false
        }

        // A new downstream initialize must trigger a new upstream initialize (no cached response).
        let init2 = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        try await waitForSentCount(upstream0, count: 3, timeoutSeconds: 2)
        let upstreamID2 = try extractUpstreamID(from: (await upstream0.sent())[2])
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
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
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
            .message(try makeInitializeResponse(id: init1ID, serverName: "secondary-ready"))
        )

        // Wait for per-upstream notifications/initialized.
        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))

        // Simulate primary dying first (cached init result should remain because upstream1 is still initialized).
        await upstream0.yield(.exit(1))

        // Primary warm init should be attempted, but we simulate it failing.
        let retry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let retryID = try extractUpstreamID(from: retry)
        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": retryID,
            "error": [
                "code": -1,
                "message": "warm init failed",
            ],
        ]
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: [])))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.testStateSnapshot().upstreams[0].initInFlight == false
            }
        )

        // Now simulate the last initialized upstream dying too. Eager init should kick the global init path again.
        await upstream1.yield(.exit(1))
        _ = try await sentValue(from: upstream0, at: 3, timeout: .seconds(2))
        _ = manager
    }

    @Test
    func
        sessionManagerRetriesEagerInitializeAfterPrimaryWarmInitErrorWhenLastInitializedUpstreamExited()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
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

        // Primary exit triggers warm init on primary.
        await upstream0.yield(.exit(1))
        let retry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let retryID = try extractUpstreamID(from: retry)

        // While primary warm init is in flight, last initialized upstream exits.
        await upstream1.yield(.exit(1))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.testStateSnapshot().upstreams[1].isInitialized == false
            }
        )

        // Warm init fails with JSON-RPC error.
        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": retryID,
            "error": [
                "code": -1,
                "message": "warm init failed",
            ],
        ]
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: [])))

        // Proxy should restart eager/global init automatically.
        _ = try await sentValue(from: upstream0, at: 3, timeout: .seconds(2))
        _ = manager
    }

    @Test func sessionManagerPinsSessionsRoundRobinAcrossUpstreams() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
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

        let originalA = RPCID(any: NSNumber(value: 100))!
        let originalB = RPCID(any: NSNumber(value: 101))!

        let upstreamIndexA = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionIDA, shouldPin: true))
        let upstreamIndexB = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionIDB, shouldPin: true))
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

        await yieldMessage(notification, to: upstream0)
        #expect(
            await staysTrue(for: .milliseconds(200)) {
                sessionA.router.drainBufferedNotifications().isEmpty
                    && sessionB.router.drainBufferedNotifications().isEmpty
            }
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

        await yieldMessage(notification, to: upstream0)

        #expect(
            await staysTrue(for: .milliseconds(200)) {
                session.router.drainBufferedNotifications().isEmpty
            }
        )
    }

    @Test func sessionManagerDropsUnmappedResponsesEvenWhenPinnedTargetsExist() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-A"
        let session = manager.session(id: sessionID)
        _ = manager.chooseUpstreamIndex(sessionID: sessionID, shouldPin: true)

        _ = session.router.drainBufferedNotifications()

        // Unmapped JSON-RPC response (no `method`) must never be routed to sessions.
        await yieldMessage(try makeToolListResponse(id: 9_999_999), to: upstream)

        #expect(
            await staysTrue(for: .milliseconds(200)) {
                session.router.drainBufferedNotifications().isEmpty
            }
        )
    }

    @Test func sessionManagerDebugSnapshotCapturesTrafficAndStderr() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let initMessages = await upstream.sent()
        let initID = try extractUpstreamID(from: initMessages[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let sessionID = "session-debug"
        let session = manager.session(id: sessionID)
        let upstreamIndex = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionID, shouldPin: true))
        let original = RPCID(any: NSNumber(value: 301))!
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

        await upstream.yield(.message(try makeToolListResponse(id: 9_999_999)))
        await upstream.yield(
            .stderr("Could not decode agent message: Error Domain=mcpbridge.DecodeError Code=1"))
        await upstream.yield(
            .stderr(
                "callTool request for 'DocumentationSearch' failed: Error Domain=IDEIntelligenceMessaging.BridgeError Code=1"
            ))
        await upstream.yield(
            .stdoutProtocolViolation(
                StdioFramerProtocolViolation(
                    reason: .invalidJSON,
                    bufferedByteCount: 1024,
                    preview: "...broken"
                )
            )
        )
        await upstream.yield(.stdoutBufferSize(2048))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                let snapshot = manager.debugSnapshot()
                return snapshot.upstreams[0].bufferedStdoutBytes == 2048
                    && snapshot.upstreams[0].protocolViolationCount == 1
                    && snapshot.upstreams[0].recentStderr.count == 2
            }
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

        await upstream.yield(.exit(1))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                let snapshot = manager.debugSnapshot()
                return snapshot.upstreams[0].recentStderr.isEmpty
                    && snapshot.upstreams[0].lastDecodeError == nil
                    && snapshot.upstreams[0].lastBridgeError == nil
                    && snapshot.upstreams[0].protocolViolationCount == 0
                    && snapshot.upstreams[0].lastProtocolViolationPreview == nil
                    && snapshot.upstreams[0].lastProtocolViolationPreviewHex == nil
                    && snapshot.upstreams[0].lastProtocolViolationLeadingByteHex == nil
                    && snapshot.upstreams[0].bufferedStdoutBytes == 0
            }
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
        var config = makeConfig(requestTimeout: 2)
        config.prewarmToolsList = true
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
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
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: warmup0Response, options: [])))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                switch manager.testStateSnapshot().upstreams[0].healthState {
                case .healthy:
                    return false
                case .degraded, .quarantined:
                    return true
                }
            }
        )

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
        await upstream1.yield(
            .message(try JSONSerialization.data(withJSONObject: warmup1Response, options: [])))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.chooseUpstreamIndex(sessionID: "session-A", shouldPin: true) == nil
            }
        )

        let chosen = manager.chooseUpstreamIndex(sessionID: "session-A", shouldPin: true)
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
            originalID: RPCID(any: NSNumber(value: 1))!,
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

        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)

        let descriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-quarantine-recovery",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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

        await #expect(throws: UpstreamSlotAcquisitionError.self) {
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

        let initFuture = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        try await spinUntilSentCount(
            upstream0,
            count: 1,
            description: "waiting for primary initialize request"
        )
        let init0 = try #require(await upstream0.sentValue(at: 0))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))
        _ = try await initFuture.get()
        try await spinUntilSentCount(
            upstream0,
            count: 2,
            description: "waiting for primary initialized notification"
        )

        try await spinUntilSentCount(
            upstream1,
            count: 1,
            description: "waiting for secondary warm initialize request"
        )
        let warmInitialize = try #require(await upstream1.sentValue(at: 0))
        let warmInitID = try extractUpstreamID(from: warmInitialize)

        let activeDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        await upstream1.yield(.message(try makeInitializeResponse(id: warmInitID)))
        try await spinUntilSentCount(
            upstream1,
            count: 2,
            description: "waiting for secondary initialized notification"
        )
        let initializedNotification = try #require(await upstream1.sentValue(at: 1))
        #expect(methodName(from: initializedNotification) == "notifications/initialized")

        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)

        let queuedRequestData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": NSNumber(value: 99),
                "method": "tools/list",
            ],
            options: []
        )
        let queuedDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-queued",
            label: "tools/list",
            isBatch: false,
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
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            manager.sendUpstream(queuedRequestData, upstreamIndex: selectedUpstreamIndex)
            return eventLoop.makeSucceededFuture(())
        }

        try await spinUntil("waiting for queued request to be visible") {
            manager.debugSnapshot().queuedRequestCount == 1
        }

        try await spinUntilSentCount(
            upstream1,
            count: 3,
            description: "waiting for recovery probe request"
        )
        let probeRequest = try #require(await upstream1.sentValue(at: 2))
        #expect(methodName(from: probeRequest) == "tools/list")
        let probeID = try extractUpstreamID(from: probeRequest)
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
            count: 4,
            description: "waiting for queued request dispatch after probe recovery"
        )
        let queuedRequest = try #require(await upstream1.sentValue(at: 3))
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
            originalID: RPCID(any: NSNumber(value: 1))!,
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

        let activeDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            #expect(selectedUpstreamIndex == 0)
            return activePromise.futureResult
        }
        _ = activeFuture

        let preferredDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-preferred",
            label: "tools/call:XcodeListWindows",
            isBatch: false,
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
            preferredStartedUpstream.withLockedValue { $0 = selectedUpstreamIndex }
            return eventLoop.makeSucceededFuture(())
        }

        try await waitForCondition(timeoutSeconds: 2) {
            manager.debugSnapshot().queuedRequestCount == 1
        }

        let genericDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-generic",
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
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
            genericStartedUpstream.withLockedValue { $0 = selectedUpstreamIndex }
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

    @Test func sessionManagerRepinsAfterUpstreamExit() async throws {
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

        // Pin two sessions to different upstreams.
        let sessionIDA = "session-A"
        let sessionIDB = "session-B"
        _ = manager.session(id: sessionIDA)
        _ = manager.session(id: sessionIDB)

        let upstreamIndexA = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionIDA, shouldPin: true))
        let upstreamIndexB = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionIDB, shouldPin: true))
        #expect(upstreamIndexA != upstreamIndexB)

        await upstream1.yield(.exit(1))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.testStateSnapshot().upstreams[1].isInitialized == false
            }
        )

        let repinned = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionIDA, shouldPin: true))
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
            manager.chooseUpstreamIndex(sessionID: sessionID, shouldPin: true))

        manager.onRequestTimeout(
            sessionID: sessionID, requestIDKey: "dummy-1", upstreamIndex: pinned)
        manager.onRequestTimeout(
            sessionID: sessionID, requestIDKey: "dummy-2", upstreamIndex: pinned)
        manager.onRequestTimeout(
            sessionID: sessionID, requestIDKey: "dummy-3", upstreamIndex: pinned)

        let repinned = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionID, shouldPin: true))
        #expect(repinned != pinned)
    }

    @Test func sessionManagerExitClearsMappingsAndKeepsServingOnOtherUpstreams() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
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
        let originalA = RPCID(any: NSNumber(value: 200))!
        let futureA = session.router.registerRequest(idKey: originalA.key, on: eventLoop)
        let upstreamIDA = manager.assignUpstreamID(
            sessionID: sessionID, originalID: originalA, upstreamIndex: 1)
        manager.sendUpstream(try makeToolListRequest(id: upstreamIDA), upstreamIndex: 1)

        await upstream1.yield(.exit(1))
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.testStateSnapshot().upstreams[1].isInitialized == false
            }
        )

        // The proxy should continue serving on upstream0.
        let originalB = RPCID(any: NSNumber(value: 201))!
        let futureB = session.router.registerRequest(idKey: originalB.key, on: eventLoop)
        let upstreamIndexB = try #require(
            manager.chooseUpstreamIndex(sessionID: sessionID, shouldPin: true))
        #expect(upstreamIndexB == 0)
        let upstreamIDB = manager.assignUpstreamID(
            sessionID: sessionID, originalID: originalB, upstreamIndex: upstreamIndexB)
        manager.sendUpstream(
            try makeToolListRequest(id: upstreamIDB), upstreamIndex: upstreamIndexB)
        await upstream0.yield(.message(try makeToolListResponse(id: upstreamIDB)))
        _ = try await futureB.get()

        // A should time out (mapping is cleared on exit, and no response arrives).
        do {
            _ = try await waitWithTimeout(
                "request routed to exited upstream should fail with TimeoutError",
                timeout: .seconds(2)
            ) {
                try await futureA.get()
            }
            #expect(Bool(false))
        } catch {
            #expect(error is TimeoutError)
        }
    }

    @Test func sessionManagerReturnsOverloadedErrorWhenUpstreamRejectsSend() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = AlwaysOverloadedUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sessionID = "session-overloaded"
        let session = manager.session(id: sessionID)
        let original = RPCID(any: NSNumber(value: 910))!
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

        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.debugSnapshot().recentTraffic.contains { $0.direction == "outbound" }
                    == false
            }
        )
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

        let original = RPCID(any: NSNumber(value: 1001))!
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
            manager.chooseUpstreamIndex(sessionID: sessionID, shouldPin: true))
        #expect(pinned == 0)

        await upstream0.setOverloaded(true)

        let original = RPCID(any: NSNumber(value: 920))!
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
            manager.chooseUpstreamIndex(sessionID: sessionID, shouldPin: true))
        #expect(repinned == 1)

        let original2 = RPCID(any: NSNumber(value: 921))!
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

    @Test func sessionManagerRetriesPrimaryInitializeWhenInitializedNotificationSendOverloads()
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

        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let retriedInitialize = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: retriedInitialize) == "initialize")
        #expect(
            await waitUntil(timeout: .seconds(2)) {
                let snapshot = manager.testStateSnapshot()
                return snapshot.hasInitResult == false
            }
        )
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
        manager.setCachedToolsListResult(cachedToolsList)

        let initialInitialize = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let initialUpstreamID = try extractUpstreamID(from: initialInitialize)
        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(.message(try makeInitializeResponse(id: initialUpstreamID)))

        try await waitForSentCount(upstream0, count: 3, timeoutSeconds: 2)
        #expect(manager.cachedToolsListResult() == nil)
        #expect(
            await staysTrue(for: .milliseconds(200)) {
                manager.testStateSnapshot().upstreams[1].isInitialized == false
            }
        )
        #expect(
            await staysTrue(for: .milliseconds(200)) {
                await upstream1.sentCount() == 0
            }
        )
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
        manager.setCachedToolsListResult(cachedToolsList)

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
        #expect(
            await staysTrue(for: .milliseconds(200)) {
                manager.testStateSnapshot().upstreams[1].isInitialized
            }
        )
        let chosen = manager.chooseUpstreamIndex(sessionID: "session-secondary", shouldPin: true)
        #expect(chosen == 1)
    }

    @Test func sessionManagerPrimaryWarmReinitOverloadReturnsPendingInitializeUsingHealthySecondary()
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

        manager.initializeGate.resetCachedInitializeResult()
        let cachedHandshake = try #require(JSONValue(any: [
            "capabilities": [String: Any](),
            "serverInfo": ["name": "cached-handshake"],
        ]))
        manager.initializeGate.restoreCachedInitializeResultForTests(cachedHandshake)
        let future = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 77))!,
            requestObject: makeInitializeRequest(id: 77),
            on: eventLoop
        )

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(
            .message(try makeInitializeResponse(id: warmRetryID, serverName: "primary-retry"))
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

        let secondWarmRetry = try await nextValue(
            "primary should start another warm initialize after overload",
            timeout: .seconds(2)
        ) {
            let sent = await upstream0.sent()
            return sent.dropFirst(3).first(where: { methodName(from: $0) == "initialize" })
        }
        #expect(methodName(from: secondWarmRetry) == "initialize")
    }

    @Test func sessionManagerPrimaryWarmReinitOverloadResetsCacheWhenSecondaryIsQuarantined()
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
        manager.setCachedToolsListResult(cachedToolsList)

        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))

        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)

        try await waitForCondition(timeoutSeconds: 2) {
            if case .quarantined = manager.testStateSnapshot().upstreams[1].healthState {
                return true
            }
            return false
        }

        await upstream0.yield(.exit(1))
        let warmRetry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let warmRetryID = try extractUpstreamID(from: warmRetry)

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(.message(try makeInitializeResponse(id: warmRetryID)))

        try await waitForSentCount(upstream0, count: 5, timeoutSeconds: 2)
        let eagerRetry = try await sentValue(from: upstream0, at: 4, timeout: .seconds(2))
        #expect(methodName(from: eagerRetry) == "initialize")
        #expect(manager.cachedToolsListResult() == nil)
        #expect(
            await staysTrue(for: .milliseconds(200)) {
                manager.testStateSnapshot().upstreams[1].isInitialized == false
            }
        )
    }

    @Test func sessionManagerPrimaryWarmReinitOverloadFallsBackToEagerInitAfterWarmRetryFailure()
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
        let firstWarmRetry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let firstWarmRetryID = try extractUpstreamID(from: firstWarmRetry)

        await upstream0.overloadNextInitializedNotificationSend()
        await upstream0.yield(.message(try makeInitializeResponse(id: firstWarmRetryID)))

        try await waitForSentCount(upstream0, count: 5, timeoutSeconds: 2)
        let secondWarmRetry = try await sentValue(from: upstream0, at: 4, timeout: .seconds(2))
        let secondWarmRetryID = try extractUpstreamID(from: secondWarmRetry)

        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: secondWarmRetryID),
            "error": [
                "code": -1,
                "message": "warm init failed",
            ],
        ]
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: []))
        )

        try await waitForCondition(timeoutSeconds: 2) {
            let snapshot = manager.testStateSnapshot()
            return snapshot.shouldRetryEagerInitializePrimaryAfterWarmInitFailure
                && snapshot.upstreams[0].isInitialized == false
                && snapshot.upstreams[0].initInFlight == false
        }

        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)

        let descriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-recovery-trigger",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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

        try await waitForSentCount(upstream0, count: 6, timeoutSeconds: 5)
        let eagerRetry = try await sentValue(from: upstream0, at: 5, timeout: .seconds(2))
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
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let activeDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        let queuedDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-queued",
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
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

        try await waitForCondition(timeoutSeconds: 2) {
            manager.debugSnapshot().queuedRequestCount == 1
        }

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
        let descriptor = SessionPipelineRequestDescriptor(
            sessionID: sessionID,
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let originalID = try #require(RPCID(any: NSNumber(value: 1)))
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
            descriptor: SessionPipelineRequestDescriptor(
                sessionID: "session-terminal-lease",
                label: "tools/call:DocumentationSearch",
                isBatch: false,
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
        let descriptor = SessionPipelineRequestDescriptor(
            sessionID: sessionID,
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let originalID = try #require(RPCID(any: NSNumber(value: 41)))
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
            StdioFramerProtocolViolation(
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
        let nextOriginalID = try #require(RPCID(any: NSNumber(value: 42)))
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
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        manager.handleUpstreamProtocolViolation(
            StdioFramerProtocolViolation(
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
        #expect(manager.chooseUpstreamIndex(sessionID: "session-A", shouldPin: true) == nil)
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
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        manager.setCachedToolsListResult(try #require(JSONValue(any: ["tools": []])))
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
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        manager.setCachedToolsListResult(try #require(JSONValue(any: ["tools": []])))
        #expect(manager.cachedToolsListResult() != nil)

        manager.handleUpstreamProtocolViolation(
            StdioFramerProtocolViolation(
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
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        manager.handleUpstreamProtocolViolation(
            StdioFramerProtocolViolation(
                reason: .invalidJSON,
                bufferedByteCount: 128,
                preview: "{broken"
            ),
            upstreamIndex: 0
        )

        #expect(
            await waitUntil(timeout: .seconds(2)) {
                await upstream.sentCount() >= 3
            }
        )

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
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let activeDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        let queuedDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-queued",
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
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
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return eventLoop.makeSucceededFuture(())
        }

        try await waitForCondition(timeoutSeconds: 2) {
            manager.debugSnapshot().queuedRequestCount == 1
        }

        manager.handleUpstreamProtocolViolation(
            StdioFramerProtocolViolation(
                reason: .invalidJSON,
                bufferedByteCount: 128,
                preview: "{broken"
            ),
            upstreamIndex: 0
        )

        await #expect(throws: UpstreamSlotAcquisitionError.self) {
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
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.upstreamSelectionPolicy.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.chooseUpstreamIndex()

        let descriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-probe-failure",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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

        await #expect(throws: UpstreamSlotAcquisitionError.self) {
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
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let activeDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-timeout-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        let queuedDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-timeout-queued",
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
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

        try await waitForCondition(timeoutSeconds: 2) {
            manager.debugSnapshot().queuedRequestCount == 1
        }

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

        #expect(
            await waitUntil(timeout: .seconds(2)) {
                manager.debugSnapshot().queuedRequestCount == 0
            }
        )
        await #expect(throws: UpstreamSlotAcquisitionError.self) {
            try await queuedFuture.get()
        }

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
        manager.setCachedToolsListResult(.object(["tools": .array([])]))

        let leaseID = manager.createRequestLease(
            descriptor: SessionPipelineRequestDescriptor(
                sessionID: "session-debug-reset",
                label: "tools/call:DocumentationSearch",
                isBatch: false,
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

    @Test func sessionManagerDebugResetCancelsQueuedRequests() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: RPCID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let activeDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture

        let queuedDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-queued",
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
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

        try await waitForCondition(timeoutSeconds: 2) {
            manager.debugSnapshot().queuedRequestCount == 1
        }

        manager.debugReset()

        await #expect(throws: CancellationError.self) {
            try await queuedFuture.get()
        }

        activePromise.fail(CancellationError())
    }

    @Test func requestLeaseRegistryKeepsOnlyBoundedReleasedHistory() async throws {
        let registry = RequestLeaseRegistry(releasedHistoryLimit: 2)
        let descriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-bounded-history",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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
        let registry = RequestLeaseRegistry()
        let descriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-requeue",
            label: "tools/call:XcodeRefreshCodeIssuesInFile",
            isBatch: false,
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
        let registry = RequestLeaseRegistry(releasedHistoryLimit: 1)
        let descriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-abandon-history",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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
        let startedLeaseIDs = NIOLockedValueBox<[RequestLeaseID]>([])
        let cancelledLeaseIDs = NIOLockedValueBox<[RequestLeaseID]>([])

        let firstDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-race-1",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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

        let secondDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-race-2",
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
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
        let startedLeaseIDs = NIOLockedValueBox<[RequestLeaseID]>([])
        let failedLeaseIDs = NIOLockedValueBox<[RequestLeaseID]>([])

        let descriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-fail-race",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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
        let startedLeaseIDs = NIOLockedValueBox<[RequestLeaseID]>([])
        let cancelledLeaseIDs = NIOLockedValueBox<[RequestLeaseID]>([])

        let descriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-reset-race",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
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

        let firstDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-a",
            label: "tools/call:DocumentationSearch",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let firstLeaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: firstLeaseID,
            descriptor: firstDescriptor,
            on: eventLoop,
            starter: { upstreamIndex in
                started.withLockedValue { $0.append("first@\(upstreamIndex)") }
            },
            failUnavailable: {
                Issue.record("first request should start")
            },
            failCancelled: {
                Issue.record("first request should not be cancelled")
            }
        )
        eventLoop.run()

        let secondDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-a",
            label: "tools/call:ExecuteSnippet",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let secondLeaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: secondLeaseID,
            descriptor: secondDescriptor,
            on: eventLoop,
            starter: { upstreamIndex in
                started.withLockedValue { $0.append("second@\(upstreamIndex)") }
            },
            failUnavailable: {
                Issue.record("second request should wait for the session slot, not fail unavailable")
            },
            failCancelled: {
                Issue.record("second request should not be cancelled")
            }
        )

        let thirdDescriptor = SessionPipelineRequestDescriptor(
            sessionID: "session-b",
            label: "tools/call:XcodeListWindows",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let thirdLeaseID = UUID()
        scheduler.enqueueRequest(
            leaseID: thirdLeaseID,
            descriptor: thirdDescriptor,
            on: eventLoop,
            starter: { upstreamIndex in
                started.withLockedValue { $0.append("third@\(upstreamIndex)") }
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

}

private func makeTestUpstreamSlotScheduler(upstreamCount: Int) -> UpstreamSlotScheduler {
    UpstreamSlotScheduler(
        upstreamCount: upstreamCount,
        defaultCapacity: 1,
        canUseUpstream: { _ in true },
        selectUpstream: { occupied in
            (0..<upstreamCount).first { occupied.contains($0) == false }
        }
    )
}

private func makeConfig(requestTimeout: TimeInterval) -> ProxyConfig {
    ProxyConfig(
        listenHost: "127.0.0.1",
        listenPort: 0,
        upstreamCommand: "xcrun",
        upstreamArgs: ["mcpbridge"],
        upstreamSessionID: nil,
        maxBodyBytes: 1024,
        requestTimeout: requestTimeout,
        prewarmToolsList: false
    )
}

private func defaultUpstreamEnvironment(sharedSessionID: String?) throws -> [String: String] {
    var config = makeConfig(requestTimeout: 5)
    config.upstreamSessionID = sharedSessionID
    let upstreams = RuntimeCoordinator.makeDefaultUpstreams(
        config: config,
        sharedSessionID: sharedSessionID,
        count: 1
    )
    let upstream = try #require(upstreams.first)
    return try upstreamEnvironment(from: upstream)
}

private func upstreamEnvironment(from upstream: ManagedUpstreamSlot) throws -> [String: String] {
    let upstreamMirror = Mirror(reflecting: upstream)
    let factory = try #require(
        upstreamMirror.children.first(where: { $0.label == "factory" })?.value,
        "ManagedUpstreamSlot should expose a stored factory for tests"
    )
    let factoryMirror = Mirror(reflecting: factory)
    let config = try #require(
        factoryMirror.children.first(where: { $0.label == "config" })?.value,
        "UpstreamProcess factory should expose a stored config for tests"
    )
    let configMirror = Mirror(reflecting: config)
    return try #require(
        configMirror.children.first(where: { $0.label == "environment" })?.value
            as? [String: String],
        "UpstreamProcess.Config should include environment for tests"
    )
}

private func withEnvironmentVariables<T>(
    _ values: [String: String],
    body: () throws -> T
) throws -> T {
    let originalValues = values.keys.reduce(into: [String: String?]()) { result, key in
        result[key] = ProcessInfo.processInfo.environment[key]
    }

    for (key, value) in values {
        _ = unsafe setenv(key, value, 1)
    }

    defer {
        for (key, value) in originalValues {
            if let value {
                _ = unsafe setenv(key, value, 1)
            } else {
                _ = unsafe unsetenv(key)
            }
        }
    }

    return try body()
}

private actor AlwaysOverloadedUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<UpstreamEvent>
    private let continuation: AsyncStream<UpstreamEvent>.Continuation
    private let sentMessages = RecordedValues<Data>()

    init() {
        var streamContinuation: AsyncStream<UpstreamEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func send(_ data: Data) async -> UpstreamSendResult {
        await sentMessages.append(data)
        return .overloaded
    }

    func sent() async -> [Data] {
        await sentMessages.snapshot()
    }

    func sentCount() async -> Int {
        await sentMessages.count()
    }

    func sentValue(at index: Int) async -> Data? {
        await sentMessages.value(at: index)
    }

    func nextSent(at index: Int) async throws -> Data {
        try await sentMessages.nextValue(at: index)
    }
}

private actor ToggleableOverloadUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<UpstreamEvent>
    private let continuation: AsyncStream<UpstreamEvent>.Continuation
    private let sentMessages = RecordedValues<Data>()
    private var overloaded = false
    private var overloadBudget = 0
    private var overloadNextInitializedNotification = false

    init() {
        var streamContinuation: AsyncStream<UpstreamEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func setOverloaded(_ value: Bool) {
        overloaded = value
    }

    func overloadNextSend() {
        overloadBudget &+= 1
    }

    func overloadNextInitializedNotificationSend() {
        overloadNextInitializedNotification = true
    }

    func send(_ data: Data) async -> UpstreamSendResult {
        await sentMessages.append(data)
        if overloadNextInitializedNotification,
            methodName(from: data) == "notifications/initialized"
        {
            overloadNextInitializedNotification = false
            return .overloaded
        }
        if overloadBudget > 0 {
            overloadBudget -= 1
            return .overloaded
        }
        return overloaded ? .overloaded : .accepted
    }

    func yield(_ event: UpstreamEvent) async {
        continuation.yield(event)
    }

    func sent() async -> [Data] {
        await sentMessages.snapshot()
    }

    func sentCount() async -> Int {
        await sentMessages.count()
    }

    func sentValue(at index: Int) async -> Data? {
        await sentMessages.value(at: index)
    }

    func nextSent(at index: Int) async throws -> Data {
        try await sentMessages.nextValue(at: index)
    }
}

private actor ReadinessFlag {
    private var ready: Bool

    init(isReady: Bool) {
        self.ready = isReady
    }

    func setReady(_ value: Bool) {
        ready = value
    }

    func isReady() -> Bool {
        ready
    }
}

private actor AvailabilityFlag {
    private var available: Bool

    init(isAvailable: Bool) {
        self.available = isAvailable
    }

    func setAvailable(_ value: Bool) {
        available = value
    }

    func isAvailable() -> Bool {
        available
    }
}

private actor ControlledReadinessSleep {
    private var sleeps: [UInt64] = []
    private var sleepContinuations: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(index: Int, continuation: CheckedContinuation<UInt64, Error>)] = []

    func sleep(nanoseconds: UInt64) async {
        sleeps.append(nanoseconds)
        resumeReadyWaiters()
        await withCheckedContinuation { continuation in
            sleepContinuations.append(continuation)
        }
    }

    func nextSleep(at index: Int) async throws -> UInt64 {
        if index < sleeps.count {
            return sleeps[index]
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append((index, continuation))
        }
    }

    func resumeNext() {
        guard !sleepContinuations.isEmpty else { return }
        sleepContinuations.removeFirst().resume()
    }

    private func resumeReadyWaiters() {
        var remaining: [(index: Int, continuation: CheckedContinuation<UInt64, Error>)] = []
        for waiter in waiters {
            if waiter.index < sleeps.count {
                waiter.continuation.resume(returning: sleeps[waiter.index])
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

private actor XcodeLaunchRecorder {
    private var count = 0
    private var outcomes: [Bool]

    init(outcomes: [Bool] = []) {
        self.outcomes = outcomes
    }

    func launch() -> Bool {
        count += 1
        guard outcomes.isEmpty == false else {
            return true
        }
        return outcomes.removeFirst()
    }

    func launchCount() -> Int {
        count
    }
}

private func makeTestReadinessGate(
    readiness: ReadinessFlag,
    availability: AvailabilityFlag? = nil,
    sleepRecorder: ControlledReadinessSleep? = nil,
    launchRetryIntervalNanoseconds: UInt64 = 5_000_000_000,
    launchRecorder: XcodeLaunchRecorder? = nil
) -> UpstreamReadinessGate {
    let launchIfUnavailable: (@Sendable () async -> Bool)?
    if let launchRecorder {
        launchIfUnavailable = {
            await launchRecorder.launch()
        }
    } else {
        launchIfUnavailable = nil
    }

    let isAvailable: (@Sendable () async -> Bool)?
    if let availability {
        isAvailable = {
            await availability.isAvailable()
        }
    } else {
        isAvailable = nil
    }

    return UpstreamReadinessGate(
        isEnabled: true,
        targetName: "mcpbridge",
        pollIntervalNanoseconds: 1_000_000,
        progressLogIntervalNanoseconds: 5_000_000_000,
        launchRetryIntervalNanoseconds: launchRetryIntervalNanoseconds,
        initialRetryBackoffNanoseconds: 1_000_000_000,
        maxRetryBackoffNanoseconds: 8_000_000_000,
        uptimeNanoseconds: {
            DispatchTime.now().uptimeNanoseconds
        },
        sleepNanoseconds: { nanoseconds in
            if let sleepRecorder, nanoseconds >= 1_000_000_000 {
                await sleepRecorder.sleep(nanoseconds: nanoseconds)
            } else {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        },
        isAvailable: isAvailable,
        launchIfUnavailable: launchIfUnavailable,
        isReady: {
            await readiness.isReady()
        }
    )
}

private func makeInitializeRequest(id: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "session-manager-tests",
                "version": "0.0",
            ],
        ],
    ]
}

private func makeTempProxyConfigFile(_ contents: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("proxy-config.toml")
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL.path
}

private func makeInitializeResponse(id: Int64) throws -> Data {
    try makeInitializeResponse(id: id, serverName: nil)
}

private func makeInitializeResponse(id: Int64, serverName: String?) throws -> Data {
    var result: [String: Any] = [
        "capabilities": [String: Any]()
    ]
    if let serverName {
        result["serverInfo"] = ["name": serverName]
    }
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "result": result,
    ]
    return try JSONSerialization.data(withJSONObject: response, options: [])
}

private func extractUpstreamID(from data: Data) throws -> Int64 {
    let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    return (object?["id"] as? NSNumber)?.int64Value ?? 0
}

private func decodeJSON(from buffer: ByteBuffer) throws -> [String: Any] {
    var buffer = buffer
    guard let data = buffer.readData(length: buffer.readableBytes) else {
        return [:]
    }
    return (try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]) ?? [:]
}

private func waitForSentCount(
    _ upstream: TestUpstreamClient,
    count: Int,
    timeoutSeconds: UInt64
) async throws {
    do {
        _ = try await waitWithTimeout(
            "waiting for sent message \(count)",
            timeout: .seconds(Int64(timeoutSeconds))
        ) {
            try await upstream.nextSent(at: count - 1)
        }
    } catch {
        let actual = await upstream.sentCount()
        throw WaitForSentCountError.timeout(expected: count, actual: actual)
    }
}

private func waitForSentCount(
    _ upstream: ToggleableOverloadUpstreamClient,
    count: Int,
    timeoutSeconds: UInt64
) async throws {
    do {
        _ = try await waitWithTimeout(
            "waiting for sent message \(count)",
            timeout: .seconds(Int64(timeoutSeconds))
        ) {
            try await upstream.nextSent(at: count - 1)
        }
    } catch {
        let actual = await upstream.sentCount()
        throw WaitForSentCountError.timeout(expected: count, actual: actual)
    }
}

private func makeDeterministicRuntimeTimeoutScheduler(
    clock: TestClock
) -> @Sendable (TimeAmount, @escaping @Sendable () -> Void) -> RuntimeScheduledTimeout {
    { amount, operation in
        let task = Task {
            do {
                try await clock.sleep(for: .nanoseconds(amount.nanoseconds))
                operation()
            } catch {
                return
            }
        }
        return RuntimeScheduledTimeout {
            task.cancel()
        }
    }
}

private func spinUntilSentCount(
    _ upstream: TestUpstreamClient,
    count: Int,
    description: String
) async throws {
    try await spinUntil(description, maxIterations: 1_000) {
        await upstream.sentCount() >= count
    }
}

private func spinUntilSentCount(
    _ upstream: ToggleableOverloadUpstreamClient,
    count: Int,
    description: String
) async throws {
    try await spinUntil(description, maxIterations: 1_000) {
        await upstream.sentCount() >= count
    }
}

private enum WaitForSentCountError: Error {
    case timeout(expected: Int, actual: Int)
}

private func waitForCondition(
    timeoutSeconds: UInt64,
    pollNanoseconds: UInt64 = 50_000_000,
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    _ = pollNanoseconds
    let reached = await waitUntil(timeout: .seconds(Int64(timeoutSeconds))) {
        condition()
    }
    if !reached {
        throw WaitForConditionError.timeout
    }
}

private enum WaitForConditionError: Error {
    case timeout
}

private func methodName(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    else {
        return nil
    }
    return object["method"] as? String
}

private func makeToolListRequest(id: Int64) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/list",
        ],
        options: []
    )
}

private func makeToolListResponse(id: Int64) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": [:],
        ],
        options: []
    )
}

private func yieldMessage(_ data: Data, to upstream: TestUpstreamClient) async {
    await upstream.yield(.message(data))
}

private func sentValue(
    from upstream: TestUpstreamClient,
    at index: Int,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    try await nextValue(
        "waiting for sent message \(index + 1)",
        timeout: timeout
    ) {
        await upstream.sentValue(at: index)
    }
}

private func sentValue(
    from upstream: ToggleableOverloadUpstreamClient,
    at index: Int,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    try await nextValue(
        "waiting for sent message \(index + 1)",
        timeout: timeout
    ) {
        await upstream.sentValue(at: index)
    }
}

private func sentMessage(
    from upstream: TestUpstreamClient,
    matching predicate: @escaping @Sendable (Data) -> Bool,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    try await nextValue(
        "waiting for matching sent message",
        timeout: timeout
    ) {
        try Task.checkCancellation()
        let sent = await upstream.sent()
        return sent.first(where: predicate)
    }
}

private func nextBufferedNotifications(
    from router: ProxyRouter,
    timeout: Duration = .seconds(5)
) async throws -> [Data] {
    try await waitWithTimeout(
        "waiting for buffered notifications",
        timeout: timeout
    ) {
        while true {
            try Task.checkCancellation()
            let drained = router.drainBufferedNotifications()
            if !drained.isEmpty {
                return drained
            }
            await Task.yield()
        }
    }
}
