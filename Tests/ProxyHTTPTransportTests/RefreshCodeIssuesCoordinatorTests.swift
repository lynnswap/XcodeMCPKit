import NIO
import Testing
import XcodeMCPTestSupport

@testable import ProxyXcodeFeatures

@Suite(.serialized)
struct RefreshCodeIssuesCoordinatorTests {
    @Test func refreshCoordinatorSerializesRequestsForSameKey() async throws {
        let clock = TestClock()
        let coordinator = RefreshCodeIssuesCoordinator(waitClock: clock)
        let releaseFirst = AsyncGate()
        let acquisitions = RecordedValues<String>()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-same",
                requestTimeout: .seconds(5)
            ) { _ in
                await acquisitions.append("first")
                await releaseFirst.wait()
            }
        }
        try await spinUntil("waiting for first acquisition") {
            await acquisitions.count() == 1
        }

        let secondTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-same",
                requestTimeout: .seconds(5)
            ) { _ in
                await acquisitions.append("second")
            }
        }

        await clock.sleep(untilSuspendedBy: 1)
        #expect(await acquisitions.snapshot() == ["first"])
        await releaseFirst.signal()

        _ = await firstTask.value
        _ = await secondTask.value
        #expect(await acquisitions.snapshot() == ["first", "second"])
    }

    @Test func refreshCoordinatorAllowsDifferentKeysToAcquireConcurrently() async throws {
        let coordinator = RefreshCodeIssuesCoordinator()
        let releaseFirst = AsyncGate()
        let acquisitions = RecordedValues<String>()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-a",
                requestTimeout: .seconds(5)
            ) { _ in
                await acquisitions.append("first")
                await releaseFirst.wait()
            }
        }
        try await spinUntil("waiting for first acquisition") {
            await acquisitions.count() == 1
        }

        let secondTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-b",
                requestTimeout: .seconds(5)
            ) { _ in
                await acquisitions.append("second")
            }
        }

        try await spinUntil("waiting for second acquisition") {
            await acquisitions.count() == 2
        }

        await releaseFirst.signal()
        _ = await firstTask.value
        _ = await secondTask.value
        #expect(await acquisitions.snapshot() == ["first", "second"])
    }

    @Test func refreshCoordinatorAcceptsManyQueuedWaitersForSameKey() async throws {
        let clock = TestClock()
        let coordinator = RefreshCodeIssuesCoordinator(waitClock: clock)
        let releaseFirst = AsyncGate()
        let completionCount = RecordedValues<String>()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-many",
                requestTimeout: nil
            ) { _ in
                await completionCount.append("first")
                await releaseFirst.wait()
            }
        }
        try await spinUntil("waiting for first acquisition") {
            await completionCount.count() == 1
        }

        let queuedTasks = (0..<100).map { index in
            Task<String, Never> {
                do {
                    _ = try await coordinator.withPermit(
                        key: "windowtab-many",
                        requestTimeout: nil
                    ) { _ in
                        await completionCount.append("queued-\(index)")
                    }
                    return "success"
                } catch {
                    return "failed"
                }
            }
        }

        await Task.yield()
        await Task.yield()
        #expect(await completionCount.count() == 1)

        await releaseFirst.signal()
        _ = await firstTask.value
        for task in queuedTasks {
            #expect(await task.value == "success")
        }

        try await spinUntil("waiting for queued completions") {
            await completionCount.count() == 101
        }
    }

    @Test func refreshCoordinatorTimeoutRemovesQueuedWaiterDeterministically() async throws {
        let clock = TestClock()
        let coordinator = RefreshCodeIssuesCoordinator(waitClock: clock)
        let releaseFirst = AsyncGate()
        let acquisitions = RecordedValues<String>()
        let outcomes = RecordedValues<String>()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-timeout",
                requestTimeout: .seconds(5)
            ) { _ in
                await acquisitions.append("first")
                await releaseFirst.wait()
            }
        }
        try await spinUntil("waiting for first acquisition") {
            await acquisitions.count() == 1
        }

        let secondTask = Task<Void, Never> {
            do {
                _ = try await coordinator.withPermit(
                    key: "windowtab-timeout",
                    requestTimeout: .milliseconds(50)
                ) { _ in
                    await outcomes.append("success")
                }
                await outcomes.append("unexpected-success")
            } catch RefreshCodeIssuesCoordinator.AcquireError.queueWaitTimedOut {
                await outcomes.append("timed-out")
            } catch {
                await outcomes.append("unexpected")
            }
        }

        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(50))
        try await spinUntil("waiting for timed-out waiter to finish") {
            await outcomes.count() == 1
        }
        #expect(await outcomes.snapshot() == ["timed-out"])

        let thirdTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-timeout",
                requestTimeout: .seconds(5)
            ) { _ in
                await acquisitions.append("third")
            }
        }

        await releaseFirst.signal()
        _ = await firstTask.value
        _ = await secondTask.value
        _ = await thirdTask.value
        #expect(await acquisitions.snapshot() == ["first", "third"])
    }

    @Test func refreshCoordinatorNilRequestTimeoutKeepsQueuedWaiterWaiting() async throws {
        let clock = TestClock()
        let coordinator = RefreshCodeIssuesCoordinator(waitClock: clock)
        let releaseFirst = AsyncGate()
        let outcomes = RecordedValues<String>()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-unbounded",
                requestTimeout: nil
            ) { _ in
                await releaseFirst.wait()
            }
        }

        let secondTask = Task<Void, Never> {
            do {
                _ = try await coordinator.withPermit(
                    key: "windowtab-unbounded",
                    requestTimeout: nil
                ) { _ in
                    await outcomes.append("success")
                }
            } catch {
                await outcomes.append("unexpected")
            }
        }

        await Task.yield()
        await Task.yield()
        clock.advance(by: .seconds(10))
        await Task.yield()
        #expect(await outcomes.count() == 0)

        await releaseFirst.signal()
        _ = await firstTask.value
        _ = await secondTask.value
        #expect(await outcomes.snapshot() == ["success"])
    }

    @Test func refreshCoordinatorCancellationRemovesQueuedWaiterDeterministically() async throws {
        let clock = TestClock()
        let coordinator = RefreshCodeIssuesCoordinator(waitClock: clock)
        let releaseFirst = AsyncGate()
        let acquisitions = RecordedValues<String>()
        let outcomes = RecordedValues<String>()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-cancel",
                requestTimeout: .seconds(5)
            ) { _ in
                await acquisitions.append("first")
                await releaseFirst.wait()
            }
        }
        try await spinUntil("waiting for first acquisition") {
            await acquisitions.count() == 1
        }

        let cancelledTask = Task<Void, Never> {
            do {
                _ = try await coordinator.withPermit(
                    key: "windowtab-cancel",
                    requestTimeout: .seconds(5)
                ) { _ in
                    await outcomes.append("success")
                }
            } catch is CancellationError {
                await outcomes.append("cancelled")
            } catch {
                await outcomes.append("unexpected")
            }
        }

        await clock.sleep(untilSuspendedBy: 1)
        cancelledTask.cancel()
        try await spinUntil("waiting for cancelled waiter to finish") {
            await outcomes.count() == 1
        }
        #expect(await outcomes.snapshot() == ["cancelled"])

        let thirdTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-cancel",
                requestTimeout: .seconds(5)
            ) { _ in
                await acquisitions.append("third")
            }
        }

        await releaseFirst.signal()
        _ = await firstTask.value
        _ = await cancelledTask.value
        _ = await thirdTask.value
        #expect(await acquisitions.snapshot() == ["first", "third"])
    }

    @Test func refreshCoordinatorResetCancelsQueuedWaiters() async throws {
        let clock = TestClock()
        let coordinator = RefreshCodeIssuesCoordinator(waitClock: clock)
        let acquisitions = RecordedValues<String>()
        let outcomes = RecordedValues<String>()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-reset",
                requestTimeout: .seconds(5)
            ) { _ in
                await acquisitions.append("first")
                try await Task.sleep(for: .seconds(5))
            }
        }
        try await spinUntil("waiting for first acquisition") {
            await acquisitions.count() == 1
        }

        let queuedTask = Task<Void, Never> {
            do {
                _ = try await coordinator.withPermit(
                    key: "windowtab-reset",
                    requestTimeout: .seconds(5)
                ) { _ in () }
                await outcomes.append("success")
            } catch is CancellationError {
                await outcomes.append("cancelled")
            } catch {
                await outcomes.append("unexpected")
            }
        }

        await clock.sleep(untilSuspendedBy: 1)
        await coordinator.reset()

        try await spinUntil("waiting for queued waiter to cancel") {
            await outcomes.count() == 1
        }
        #expect(await outcomes.snapshot() == ["cancelled"])

        let thirdTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-reset",
                requestTimeout: .seconds(5)
            ) { _ in
                await acquisitions.append("third")
            }
        }

        _ = await queuedTask.value
        _ = await thirdTask.value
        _ = await firstTask.value
        #expect(await acquisitions.snapshot() == ["first", "third"])
    }

    @Test func refreshCoordinatorResetCancelsActiveExecution() async throws {
        let coordinator = RefreshCodeIssuesCoordinator()
        let started = TestSignal()
        let outcomes = RecordedValues<String>()

        let activeTask = Task<Void, Never> {
            do {
                _ = try await coordinator.withPermit(
                    key: "windowtab-active-reset",
                    requestTimeout: .seconds(5)
                ) { _ in
                    started.signal()
                    try await Task.sleep(for: .seconds(5))
                    await outcomes.append("completed")
                }
            } catch is CancellationError {
                await outcomes.append("cancelled")
            } catch {
                await outcomes.append("unexpected")
            }
        }

        try await started.wait(description: "waiting for active execution to start")
        await coordinator.reset()

        try await spinUntil("waiting for active execution to cancel") {
            await outcomes.count() == 1
        }
        #expect(await outcomes.snapshot() == ["cancelled"])
        _ = await activeTask.value
    }

    @Test func refreshCoordinatorResetKeepsSameKeySerializedUntilCancelledExecutionExits()
        async throws
    {
        let coordinator = RefreshCodeIssuesCoordinator()
        let activeStarted = TestSignal()
        let activeCancellationObserved = TestSignal()
        let allowActiveExit = AsyncGate()
        let acquisitions = RecordedValues<String>()

        let activeTask = Task<Void, Never> {
            do {
                _ = try await coordinator.withPermit(
                    key: "windowtab-reset-serialization",
                    requestTimeout: .seconds(5)
                ) { _ in
                    await acquisitions.append("first")
                    activeStarted.signal()
                    do {
                        try await Task.sleep(for: .seconds(5))
                    } catch is CancellationError {
                        await acquisitions.append("first-cancelling")
                        activeCancellationObserved.signal()
                        await allowActiveExit.wait()
                        throw CancellationError()
                    }
                }
            } catch is CancellationError {
                await acquisitions.append("first-cancelled")
            } catch {
                await acquisitions.append("unexpected")
            }
        }

        try await activeStarted.wait(description: "waiting for active execution to start")

        let resetTask = Task {
            await coordinator.reset()
        }

        try await activeCancellationObserved.wait(
            description: "waiting for active execution to observe cancellation"
        )

        let secondStarted = TestSignal()
        let secondTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-reset-serialization",
                requestTimeout: .seconds(5)
            ) { _ in
                await acquisitions.append("second")
                secondStarted.signal()
            }
        }

        await Task.yield()
        await Task.yield()
        #expect(await acquisitions.snapshot() == ["first", "first-cancelling"])

        await allowActiveExit.signal()
        _ = await resetTask.value
        try await secondStarted.wait(description: "waiting for second execution to start")

        _ = await secondTask.value
        _ = await activeTask.value
        #expect(await acquisitions.snapshot() == [
            "first",
            "first-cancelling",
            "first-cancelled",
            "second",
        ])
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard isOpen == false else {
            return
        }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
