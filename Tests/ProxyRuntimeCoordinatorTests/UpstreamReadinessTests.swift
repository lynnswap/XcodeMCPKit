import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyKit
import XcodeMCPProxyTestSupport
@testable import XcodeMCPProxyInternalTestSupport

extension RuntimeCoordinatorTests {
    @discardableResult
    private func waitForReadinessPollSleep(
        _ sleepRecorder: ControlledReadinessSleep,
        at index: Int,
        timeout: Duration = .seconds(2)
    ) async throws -> UInt64 {
        let sleep = try await waitWithTimeout(
            "waiting for readiness poll sleep",
            timeout: timeout
        ) {
            try await sleepRecorder.nextSleep(at: index)
        }
        #expect(sleep == 1_000_000)
        return sleep
    }

    @Test func xcodeReadinessRequiresRunningXcodeProcess() {
        #expect(XcodeReadinessProbe.isReady(xcodeProcessIDs: [1234]))
        #expect(XcodeReadinessProbe.isReady(xcodeProcessIDs: []) == false)
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
        #expect(XcrunArguments.isDefaultMCPBridgeInvocation(config: config))

        config.upstreamCommand = "/usr/bin/xcrun"
        config.upstreamArgs = ["--sdk=macosx", "--toolchain", "default", "mcpbridge"]
        #expect(XcrunArguments.isDefaultMCPBridgeInvocation(config: config))
    }

    @Test func defaultReadinessGateIgnoresNonMCPBridgeAndCustomWrapperInvocations() {
        var config = makeConfig(requestTimeout: 5)
        config.upstreamArgs = ["--sdk", "macosx", "swift"]
        #expect(XcrunArguments.isDefaultMCPBridgeInvocation(config: config) == false)

        config.upstreamCommand = "/bin/echo"
        config.upstreamArgs = ["xcrun", "mcpbridge"]
        #expect(XcrunArguments.isDefaultMCPBridgeInvocation(config: config) == false)

        config.upstreamCommand = "xcrun"
        config.upstreamArgs = ["--sdk", "mcpbridge"]
        #expect(XcrunArguments.isDefaultMCPBridgeInvocation(config: config) == false)
    }

    @Test func readinessGateDefersStartupUntilXcodeIsAvailable() async throws {
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
            )
        )
        defer { manager.shutdownAndWait() }

        _ = try await readiness.nextCheck(at: 0)
        _ = try await waitForReadinessPollSleep(sleepRecorder, at: 0)
        #expect(await upstream.startCount() == 0)
        #expect(await upstream.sentCount() == 0)

        await readiness.setReady(true)
        await sleepRecorder.resumeNext()
        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: sent) == "initialize")
        #expect(await upstream.startCount() > 0)
    }

    @Test func readinessGateStartsOnlyPrimaryUpstreamBeforePrimaryAttachCompletes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: false)
        let sleepRecorder = ControlledReadinessSleep()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                sleepRecorder: sleepRecorder,
                recordPollSleeps: true
            )
        )
        defer { manager.shutdownAndWait() }

        _ = try await readiness.nextCheck(at: 0)
        _ = try await waitForReadinessPollSleep(sleepRecorder, at: 0)
        await readiness.setReady(true)
        await sleepRecorder.resumeNext()
        let sent = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        #expect(methodName(from: sent) == "initialize")
        #expect(await upstream0.startCount() > 0)
        #expect(await upstream1.startCount() == 0)
        #expect(await upstream1.sentCount() == 0)
    }

    @Test func readinessGateLaunchesXcodeWhenUnavailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: false)
        let launchRecorder = XcodeLaunchRecorder()
        let sleepRecorder = ControlledReadinessSleep()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                sleepRecorder: sleepRecorder,
                recordPollSleeps: true,
                launchRecorder: launchRecorder
            )
        )
        defer { manager.shutdownAndWait() }

        _ = try await waitWithTimeout("waiting for Xcode launch attempt", timeout: .seconds(2)) {
            try await launchRecorder.nextLaunch(at: 0)
        }
        _ = try await waitForReadinessPollSleep(sleepRecorder, at: 0)
        #expect(await upstream.startCount() == 0)
        #expect(await upstream.sentCount() == 0)

        await readiness.setReady(true)
        await sleepRecorder.resumeNext()
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
        let sleepRecorder = ControlledReadinessSleep()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                sleepRecorder: sleepRecorder,
                recordPollSleeps: true,
                launchRecorder: launchRecorder
            )
        )
        defer { manager.shutdownAndWait() }

        _ = try await waitWithTimeout("waiting for first Xcode launch attempt", timeout: .seconds(2)) {
            try await launchRecorder.nextLaunch(at: 0)
        }
        _ = try await waitForReadinessPollSleep(sleepRecorder, at: 0)
        await sleepRecorder.resumeNext()
        _ = try await waitWithTimeout("waiting for retried Xcode launch attempt", timeout: .seconds(2)) {
            try await launchRecorder.nextLaunch(at: 1)
        }
        _ = try await waitForReadinessPollSleep(sleepRecorder, at: 1)
        #expect(await upstream.startCount() == 0)

        await readiness.setReady(true)
        await sleepRecorder.resumeNext()
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
        let sleepRecorder = ControlledReadinessSleep()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                availability: availability,
                sleepRecorder: sleepRecorder,
                recordPollSleeps: true,
                launchRetryIntervalNanoseconds: 0,
                launchRecorder: launchRecorder
            )
        )
        defer { manager.shutdownAndWait() }

        _ = try await waitWithTimeout("waiting for first Xcode launch attempt", timeout: .seconds(2)) {
            try await launchRecorder.nextLaunch(at: 0)
        }
        _ = try await waitForReadinessPollSleep(sleepRecorder, at: 0)
        await sleepRecorder.resumeNext()
        _ = try await waitWithTimeout("waiting for retried Xcode launch attempt", timeout: .seconds(2)) {
            try await launchRecorder.nextLaunch(at: 1)
        }
        #expect(await upstream.startCount() == 0)

        await availability.setAvailable(true)
        await readiness.setReady(true)
        _ = try await waitForReadinessPollSleep(sleepRecorder, at: 1)
        await sleepRecorder.resumeNext()
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
        let sleepRecorder = ControlledReadinessSleep()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                availability: availability,
                sleepRecorder: sleepRecorder,
                recordPollSleeps: true,
                launchRecorder: launchRecorder
            )
        )
        defer { manager.shutdownAndWait() }

        _ = try await availability.nextCheck(at: 0)
        #expect(await launchRecorder.launchCount() == 0)
        #expect(await upstream.startCount() == 0)

        _ = try await waitForReadinessPollSleep(sleepRecorder, at: 0)
        await availability.setAvailable(false)
        await sleepRecorder.resumeNext()
        _ = try await waitWithTimeout("waiting for Xcode launch after quit", timeout: .seconds(2)) {
            try await launchRecorder.nextLaunch(at: 0)
        }
        _ = try await waitForReadinessPollSleep(sleepRecorder, at: 1)
        #expect(await upstream.startCount() == 0)

        await availability.setAvailable(true)
        await readiness.setReady(true)
        await sleepRecorder.resumeNext()
        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        #expect(await upstream.startCount() > 0)
    }

    @Test func readinessGateCompletesPendingInitializeAfterXcodeAppears() async throws {
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
            )
        )
        defer { manager.shutdownAndWait() }

        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        _ = try await readiness.nextCheck(at: 0)
        _ = try await waitForReadinessPollSleep(sleepRecorder, at: 0)
        #expect(await upstream.sentCount() == 0)

        await readiness.setReady(true)
        await sleepRecorder.resumeNext()
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
            )
        )
        defer { manager.shutdownAndWait() }

        _ = try await readiness.nextCheck(at: 0)
        _ = try await waitForReadinessPollSleep(sleepRecorder, at: 0)
        #expect(await upstream.sentCount() == 0)

        manager.debugReset()
        await readiness.setReady(true)
        try await waitWithTimeout(
            "waiting for debug reset to drain readiness work",
            timeout: .seconds(2)
        ) {
            try await eventLoop.submit { () }.get()
        }

        #expect(await upstream.sentCount() == 0)
        #expect(await upstream.startCount() == 0)
    }

    @Test func readinessGateDoesNotSendTimedOutInitializeWaiterWhenXcodeAppears() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let readiness = ReadinessFlag(isReady: false)
        let sleepRecorder = ControlledReadinessSleep()
        let clock = TestClock()
        let config = makeConfig(requestTimeout: 0.05)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            upstreamReadinessGate: makeTestReadinessGate(
                readiness: readiness,
                sleepRecorder: sleepRecorder,
                recordPollSleeps: true
            ),
            scheduleRuntimeTimeout: makeDeterministicRuntimeTimeoutScheduler(clock: clock)
        )
        defer { manager.shutdownAndWait() }

        _ = try await readiness.nextCheck(at: 0)
        _ = try await waitForReadinessPollSleep(sleepRecorder, at: 0)

        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
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
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
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
        await sleepRecorder.resumeNext()
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
            )
        )
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID = try extractUpstreamID(from: sent)
        await upstream.yield(.message(try makeInitializeResponse(id: upstreamID)))
        _ = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))

        await readiness.setReady(false)
        await upstream.yield(.exit(1))
        _ = try await readiness.nextCheck(at: 1)
        _ = try await waitForReadinessPollSleep(sleepRecorder, at: 0)
        #expect(await upstream.sentCount() == 2)

        await readiness.setReady(true)
        await sleepRecorder.resumeNext()
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
        _ = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))

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
        _ = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))

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
}
