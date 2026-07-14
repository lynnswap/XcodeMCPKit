import Testing
import XcodeMCPKit
@testable import XcodeMCPCoreTestSupport

@Suite struct AsyncTaskSupervisorTests {
    @Test func runReportsAcceptedBeforeShutdown() async throws {
        let supervisor = AsyncTaskSupervisor()
        let ran = RecordedValues<Bool>()

        let scheduled = supervisor.run {
            await ran.append(true)
        }

        #expect(scheduled)
        _ = try await waitWithTimeout("waiting for scheduled task to run") {
            try await ran.nextValue(at: 0)
        }
        await supervisor.shutdown()
    }

    @Test func runReportsRejectedAfterShutdownBegins() async {
        let supervisor = AsyncTaskSupervisor()

        let drain = supervisor.beginShutdown()
        let scheduled = supervisor.run {}

        #expect(scheduled == false)
        await drain.wait()
    }

    @Test func waitUntilIdleIncludesTasksSpawnedByRunningTasks() async throws {
        let supervisor = AsyncTaskSupervisor()
        let releaseParent = ManualGate()
        let parentStarted = RecordedValues<Void>()
        let childScheduled = RecordedValues<Bool>()
        let childFinished = RecordedValues<Void>()

        #expect(supervisor.run {
            await parentStarted.append(())
            await releaseParent.wait()
            let scheduled = supervisor.run {
                await childFinished.append(())
            }
            await childScheduled.append(scheduled)
        })

        _ = try await waitWithTimeout("waiting for parent task to start") {
            try await parentStarted.nextValue(at: 0)
        }
        await releaseParent.open()
        await supervisor.waitUntilIdle()

        #expect(try await childScheduled.nextValue(at: 0))
        #expect(await childFinished.count() == 1)
    }

    @Test func cancellingIdleWaitDoesNotLeaveAContinuationRegistered() async throws {
        let supervisor = AsyncTaskSupervisor()
        let releaseOperation = ManualGate()
        let operationStarted = RecordedValues<Void>()

        #expect(supervisor.run {
            await operationStarted.append(())
            await releaseOperation.wait()
        })
        _ = try await waitWithTimeout("waiting for supervised operation to start") {
            try await operationStarted.nextValue(at: 0)
        }

        let idleWait = Task {
            await supervisor.waitUntilIdle()
        }
        idleWait.cancel()
        try await waitWithTimeout("waiting for cancelled idle wait") {
            await idleWait.value
        }

        await releaseOperation.open()
        await supervisor.waitUntilIdle()
    }
}

private actor ManualGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard isOpen == false else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        guard isOpen == false else { return }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
