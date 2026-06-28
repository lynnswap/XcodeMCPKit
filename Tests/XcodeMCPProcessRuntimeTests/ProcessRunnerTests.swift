import Foundation
import Testing
import XcodeMCPCoreTestSupport

@testable import XcodeMCPProcessRuntime

@Suite
struct ProcessRunnerTests {
    @Test func processRunnerCollectsStdoutAndStderrAfterTerminationAndDrain() async throws {
        let fakeDriver = FakeProcessRunnerDriver()
        let runner = ProcessRunner(processDriverFactory: StaticProcessRunnerDriverFactory(fakeDriver))
        let task = Task {
            try await runner.run(
                ProcessRequest(
                    label: "fake-output",
                    executablePath: "/fake/tool",
                    arguments: ["--flag"],
                    input: nil
                )
            )
        }
        defer {
            task.cancel()
        }

        let request = await fakeDriver.nextStartedRequest()
        #expect(request.label == "fake-output")
        #expect(request.executablePath == "/fake/tool")
        #expect(request.arguments == ["--flag"])

        fakeDriver.emitStdout(Data("out-1".utf8))
        fakeDriver.emitStderr(Data("err-1".utf8))
        fakeDriver.emitTermination(status: 7)
        fakeDriver.emitStdout(Data("-out-2".utf8))
        fakeDriver.emitStderr(Data("-err-2".utf8))
        fakeDriver.finishStdout()
        fakeDriver.finishStderr()

        let output = try await task.value
        #expect(output.terminationStatus == 7)
        #expect(output.stdout == "out-1-out-2")
        #expect(output.stderr == "err-1-err-2")
    }

    @Test func processRunnerWritesStdinAndClosesItBeforeCompletion() async throws {
        let fakeDriver = FakeProcessRunnerDriver()
        let runner = ProcessRunner(processDriverFactory: StaticProcessRunnerDriverFactory(fakeDriver))
        let task = Task {
            try await runner.run(
                ProcessRequest(
                    label: "fake-input",
                    executablePath: "/fake/tool",
                    arguments: [],
                    input: "request-body"
                )
            )
        }
        defer {
            task.cancel()
        }

        _ = await fakeDriver.nextStartedRequest()
        #expect(await fakeDriver.nextInputWrite() == "request-body")
        _ = await fakeDriver.nextStdinClose()
        #expect(fakeDriver.snapshot().closeStdinCount == 1)

        fakeDriver.emitTermination(status: 0)
        fakeDriver.finishStdout()
        fakeDriver.finishStderr()

        let output = try await task.value
        #expect(output.terminationStatus == 0)
    }

    @Test func processRunnerTimeoutTerminatesWithoutWaitingForOutputDrain() async throws {
        let scheduler = TestProcessRunnerDelayScheduler()
        let fakeDriver = FakeProcessRunnerDriver()
        let runner = ProcessRunner(
            delayScheduler: scheduler,
            processDriverFactory: StaticProcessRunnerDriverFactory(fakeDriver)
        )
        let timeoutNanoseconds: Int64 = 10_000_000_000
        let task = Task {
            try await runner.run(
                ProcessRequest(
                    label: "timeout",
                    executablePath: "/fake/hang",
                    arguments: [],
                    input: nil,
                    timeoutNanoseconds: timeoutNanoseconds
                )
            )
        }
        defer {
            task.cancel()
        }

        _ = await fakeDriver.nextStartedRequest()
        let timeout = try await scheduler.nextScheduled(.timeout)
        #expect(timeout.delayNanoseconds == timeoutNanoseconds)
        timeout.fire()

        await #expect(throws: ProcessTimeoutError.self) {
            _ = try await task.value
        }
        let snapshot = fakeDriver.snapshot()
        #expect(snapshot.terminateCount == 1)
        #expect(snapshot.stopOutputCount == 1)

        let killFallback = try await scheduler.nextScheduled(.terminationKillFallback)
        #expect(killFallback.delayNanoseconds == 1_000_000_000)
        killFallback.fire()
        #expect(fakeDriver.snapshot().killCount == 1)
    }

    @Test func processRunnerCancellationTerminatesAndClosesOutput() async throws {
        let scheduler = TestProcessRunnerDelayScheduler()
        let fakeDriver = FakeProcessRunnerDriver()
        let runner = ProcessRunner(
            delayScheduler: scheduler,
            processDriverFactory: StaticProcessRunnerDriverFactory(fakeDriver)
        )
        let task = Task {
            try await runner.run(
                ProcessRequest(
                    label: "cancel",
                    executablePath: "/fake/hang",
                    arguments: [],
                    input: nil
                )
            )
        }

        _ = await fakeDriver.nextStartedRequest()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let snapshot = fakeDriver.snapshot()
        #expect(snapshot.terminateCount == 1)
        #expect(snapshot.stopOutputCount == 1)

        let killFallback = try await scheduler.nextScheduled(.terminationKillFallback)
        #expect(killFallback.delayNanoseconds == 1_000_000_000)
        killFallback.fire()
        #expect(fakeDriver.snapshot().killCount == 1)
    }
}

@Suite(.serialized, .enabled(if: ProcessTestEnvironment.isEnabled))
struct LiveProcessRunnerSmokeTests {
    @Test func processRunnerLiveSmokeCollectsOutput() async throws {
        let runner = ProcessRunner()
        let output = try await waitWithTimeout(
            "live ProcessRunner smoke should finish",
            timeout: .seconds(5)
        ) {
            try await runner.run(
                ProcessRequest(
                    label: "live-smoke",
                    executablePath: "/bin/sh",
                    arguments: ["-c", "printf 'stdout'; printf 'stderr' >&2"],
                    input: nil
                )
            )
        }

        #expect(output.terminationStatus == 0)
        #expect(output.stdout == "stdout")
        #expect(output.stderr == "stderr")
    }
}

private struct StaticProcessRunnerDriverFactory: ProcessRunnerProcessDriverMaking {
    private let driver: FakeProcessRunnerDriver

    init(_ driver: FakeProcessRunnerDriver) {
        self.driver = driver
    }

    func makeDriver() -> any ProcessRunnerProcessDriving {
        driver
    }
}

private final class FakeProcessRunnerDriver: ProcessRunnerProcessDriving, @unchecked Sendable {
    struct Snapshot: Sendable {
        let terminateCount: Int
        let stopOutputCount: Int
        let closeStdinCount: Int
        let killCount: Int
    }

    private struct State {
        var onTermination: (@Sendable (Int32) -> Void)?
        var isRunning = false
        var terminateCount = 0
        var stopOutputCount = 0
        var closeStdinCount = 0
        var killCount = 0
    }

    private let lock = NSLock()
    private var state = State()
    private let startedRequests = DeterministicRecorder<ProcessRequest>()
    private let inputWrites = DeterministicRecorder<String>()
    private let stdinCloses = DeterministicRecorder<Int>()
    private let stdoutContinuation: AsyncStream<Data>.Continuation
    private let stderrContinuation: AsyncStream<Data>.Continuation
    private let stdoutChunks: AsyncStream<Data>
    private let stderrChunks: AsyncStream<Data>

    init() {
        var stdoutContinuation: AsyncStream<Data>.Continuation!
        self.stdoutChunks = AsyncStream { continuation in
            stdoutContinuation = continuation
        }
        self.stdoutContinuation = stdoutContinuation

        var stderrContinuation: AsyncStream<Data>.Continuation!
        self.stderrChunks = AsyncStream { continuation in
            stderrContinuation = continuation
        }
        self.stderrContinuation = stderrContinuation
    }

    func start(
        request: ProcessRequest,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> ProcessRunnerStartedProcessIO {
        lock.withLock {
            state.onTermination = onTermination
            state.isRunning = true
        }
        startedRequests.record(request)
        return ProcessRunnerStartedProcessIO(
            stdoutChunks: stdoutChunks,
            stderrChunks: stderrChunks
        )
    }

    func writeInput(_ input: String) throws {
        inputWrites.record(input)
    }

    func closeStdin() {
        let count = lock.withLock { () -> Int in
            state.closeStdinCount += 1
            return state.closeStdinCount
        }
        stdinCloses.record(count)
    }

    func terminate() {
        lock.withLock {
            state.terminateCount += 1
        }
    }

    func stopOutput() {
        lock.withLock {
            state.stopOutputCount += 1
        }
        finishStdout()
        finishStderr()
    }

    func killIfRunning() {
        let shouldRecord = lock.withLock { () -> Bool in
            guard state.isRunning else {
                return false
            }
            state.killCount += 1
            state.isRunning = false
            return true
        }
        _ = shouldRecord
    }

    func emitStdout(_ data: Data) {
        stdoutContinuation.yield(data)
    }

    func emitStderr(_ data: Data) {
        stderrContinuation.yield(data)
    }

    func emitTermination(status: Int32) {
        let onTermination = lock.withLock { () -> (@Sendable (Int32) -> Void)? in
            state.isRunning = false
            return state.onTermination
        }
        onTermination?(status)
    }

    func finishStdout() {
        stdoutContinuation.finish()
    }

    func finishStderr() {
        stderrContinuation.finish()
    }

    func nextStartedRequest() async -> ProcessRequest {
        await startedRequests.nextValue(at: 0)
    }

    func nextInputWrite() async -> String {
        await inputWrites.nextValue(at: 0)
    }

    func nextStdinClose() async -> Int {
        await stdinCloses.nextValue(at: 0)
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                terminateCount: state.terminateCount,
                stopOutputCount: state.stopOutputCount,
                closeStdinCount: state.closeStdinCount,
                killCount: state.killCount
            )
        }
    }
}

private final class TestProcessRunnerDelayScheduler: ProcessRunnerDelayScheduling, @unchecked Sendable {
    fileprivate struct ScheduledDelay: Sendable {
        let id: UInt64
        let kind: ProcessRunnerScheduledDelayKind
        let delayNanoseconds: Int64
        let fireImpl: @Sendable () -> Void

        func fire() {
            fireImpl()
        }
    }

    private struct Waiter {
        let id: UUID
        let kind: ProcessRunnerScheduledDelayKind
        let continuation: CheckedContinuation<ScheduledDelay, Error>
    }

    private let lock = NSLock()
    private var scheduledDelays: [ScheduledDelay] = []
    private var waiters: [Waiter] = []
    private var completedIDs = Set<UInt64>()
    private var nextID: UInt64 = 0

    @discardableResult
    func schedule(
        _ kind: ProcessRunnerScheduledDelayKind,
        afterNanoseconds delayNanoseconds: Int64,
        operation: @escaping @Sendable () -> Void
    ) -> ProcessRunnerScheduledDelay {
        let id = reserveID()
        let scheduledDelay = ScheduledDelay(
            id: id,
            kind: kind,
            delayNanoseconds: delayNanoseconds,
            fireImpl: { [weak self] in
                self?.fire(id: id, operation: operation)
            }
        )
        let waiter = appendOrReserveWaiter(for: scheduledDelay)
        waiter?.continuation.resume(returning: scheduledDelay)
        return ProcessRunnerScheduledDelay { [weak self] in
            self?.cancel(id: id)
        }
    }

    fileprivate func nextScheduled(
        _ kind: ProcessRunnerScheduledDelayKind
    ) async throws -> ScheduledDelay {
        if let scheduledDelay = removeScheduledDelay(kind) {
            return scheduledDelay
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let scheduledDelay = removeScheduledDelay(kind) {
                    continuation.resume(returning: scheduledDelay)
                    return
                }
                appendWaiter(Waiter(id: waiterID, kind: kind, continuation: continuation))
            }
        } onCancel: {
            self.cancelWaiter(id: waiterID)
        }
    }

    private func reserveID() -> UInt64 {
        locked {
            let id = nextID
            nextID += 1
            return id
        }
    }

    private func appendOrReserveWaiter(for scheduledDelay: ScheduledDelay) -> Waiter? {
        locked {
            guard let index = waiters.firstIndex(where: { $0.kind == scheduledDelay.kind }) else {
                scheduledDelays.append(scheduledDelay)
                return nil
            }
            return waiters.remove(at: index)
        }
    }

    private func removeScheduledDelay(_ kind: ProcessRunnerScheduledDelayKind) -> ScheduledDelay? {
        locked {
            guard let index = scheduledDelays.firstIndex(where: { $0.kind == kind }) else {
                return nil
            }
            return scheduledDelays.remove(at: index)
        }
    }

    private func appendWaiter(_ waiter: Waiter) {
        locked {
            waiters.append(waiter)
        }
    }

    private func cancelWaiter(id: UUID) {
        let waiter = locked {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                return nil as Waiter?
            }
            return waiters.remove(at: index)
        }
        waiter?.continuation.resume(throwing: CancellationError())
    }

    private func cancel(id: UInt64) {
        locked {
            completedIDs.insert(id)
            scheduledDelays.removeAll { $0.id == id }
        }
    }

    private func fire(id: UInt64, operation: @escaping @Sendable () -> Void) {
        let shouldFire = locked {
            completedIDs.insert(id).inserted
        }
        guard shouldFire else {
            return
        }
        operation()
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return try body()
    }
}
