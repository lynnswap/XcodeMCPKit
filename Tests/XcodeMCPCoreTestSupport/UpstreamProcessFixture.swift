import Foundation
import Testing
@testable import XcodeMCPCore

struct StaticUpstreamProcessDriverFactory: UpstreamProcessDriverMaking {
    private let driver: FakeUpstreamProcessDriver

    init(_ driver: FakeUpstreamProcessDriver) {
        self.driver = driver
    }

    func makeDriver() -> any UpstreamProcessDriving {
        driver
    }
}

final class ControlledTerminationDelay: @unchecked Sendable {
    private struct State {
        var isCancelled = false
        var hasFired = false
    }

    private let lock = NSLock()
    private let terminal = AsyncTerminalSignal()
    private let operation: @Sendable () -> Void

    init(operation: @escaping @Sendable () -> Void) {
        self.operation = operation
    }

    func makeDelay() -> UpstreamTerminationDelay {
        UpstreamTerminationDelay(terminal: terminal) { [weak self] in
            self?.cancel()
        }
    }

    func fire() {
        let shouldFire = lock.withLock { () -> Bool in
            guard state.isCancelled == false, state.hasFired == false else { return false }
            state.hasFired = true
            return true
        }
        guard shouldFire else { return }
        operation()
        terminal.signal()
    }

    func isCancelled() -> Bool {
        lock.withLock { state.isCancelled }
    }

    private var state = State()

    private func cancel() {
        lock.withLock { state.isCancelled = true }
        terminal.signal()
    }
}

final class ControlledTerminationDelayScheduler:
    UpstreamTerminationDelayScheduling,
    @unchecked Sendable
{
    private let scheduled = DeterministicRecorder<ControlledTerminationDelay>()

    func schedule(
        after delay: Duration,
        operation: @escaping @Sendable () -> Void
    ) -> UpstreamTerminationDelay {
        _ = delay
        let controlled = ControlledTerminationDelay(operation: operation)
        scheduled.record(controlled)
        return controlled.makeDelay()
    }

    func nextScheduledDelay() async throws -> ControlledTerminationDelay {
        try await scheduled.nextValue(at: 0)
    }
}

final class FakeUpstreamProcessDriver: UpstreamProcessDriving, @unchecked Sendable {
    struct Snapshot: Sendable {
        let closeStdinCount: Int
        let terminateCount: Int
        let forceTerminateCount: Int
        let stopOutputCount: Int
        let queuedStdinBytes: Int
        let stdinWriteCompletionCount: Int
    }

    private struct State {
        var isRunning = false
        var maxQueuedWriteBytes = 0
        var queuedStdinBytes = 0
        var closeStdinCount = 0
        var terminateCount = 0
        var forceTerminateCount = 0
        var stopOutputCount = 0
        var onTermination: (@Sendable (Int32) -> Void)?
        var stdinWrites: [Data] = []
        var queuedWriteSizes: [Int] = []
        var isStdinClosing = false
        var stdinWriteCompletionCount = 0
    }

    private let lock = NSLock()
    private var state = State()
    private let finishesOutputOnStop: Bool
    private let terminatesOnTerminate: Bool
    private let terminatesOnForceTerminate: Bool
    private let stopOutputRecorder = DeterministicRecorder<Void>()
    private let stdinRecorder = DeterministicRecorder<Data>()
    private let stdinTerminal = AsyncTerminalSignal()
    private let stdoutTerminal = AsyncTerminalSignal()
    private let stderrTerminal = AsyncTerminalSignal()
    private let stdoutContinuation: AsyncStream<Data>.Continuation
    private let stderrContinuation: AsyncStream<Data>.Continuation
    private let stdoutChunks: AsyncStream<Data>
    private let stderrChunks: AsyncStream<Data>

    init(
        finishesOutputOnStop: Bool = true,
        terminatesOnTerminate: Bool = true,
        terminatesOnForceTerminate: Bool = true
    ) {
        self.finishesOutputOnStop = finishesOutputOnStop
        self.terminatesOnTerminate = terminatesOnTerminate
        self.terminatesOnForceTerminate = terminatesOnForceTerminate
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
        command: String,
        args: [String],
        environment: [String: String],
        maxQueuedWriteBytes: Int,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> UpstreamProcessStartedIO {
        _ = command
        _ = args
        _ = environment
        lock.withLock {
            state.isRunning = true
            state.maxQueuedWriteBytes = maxQueuedWriteBytes
            state.onTermination = onTermination
        }
        return UpstreamProcessStartedIO(
            stdoutChunks: stdoutChunks,
            stderrChunks: stderrChunks
        )
    }

    func sendStdin(_ payload: Data) -> Upstream.SendResult {
        let result: Upstream.SendResult = lock.withLock {
            guard state.isRunning else {
                return .unavailable(.terminated)
            }
            guard state.queuedStdinBytes + payload.count <= state.maxQueuedWriteBytes else {
                return .backpressure
            }
            state.queuedStdinBytes += payload.count
            state.stdinWrites.append(payload)
            state.queuedWriteSizes.append(payload.count)
            return .accepted
        }
        if result == .accepted { stdinRecorder.record(payload) }
        return result
    }

    func nextStdinMessage(method: String) async throws -> [String: JSONValue] {
        let data = try await stdinRecorder.nextValue(matching: { data in
            (try? JSONRPC.Wire.object(fromData: data)["method"] as? String) == method
        })
        return try JSONRPC.Wire.object(fromData: data).mapValues { try #require(JSONValue(any: $0)) }
    }

    func closeStdin() {
        let shouldSignal = lock.withLock {
            state.closeStdinCount += 1
            state.isStdinClosing = true
            return state.queuedStdinBytes == 0
        }
        if shouldSignal { stdinTerminal.signal() }
    }

    func terminate() -> Bool {
        let result = lock.withLock { () -> ProcessExitCallbacks? in
            state.terminateCount += 1
            guard state.isRunning else {
                return nil
            }
            guard terminatesOnTerminate else {
                return ProcessExitCallbacks(signalAccepted: true)
            }
            state.isRunning = false
            return takeExitCallbacksLocked(status: 143)
        }
        perform(result)
        return result?.signalAccepted == true
    }

    func forceTerminate() -> Bool {
        let result = lock.withLock { () -> ProcessExitCallbacks? in
            state.forceTerminateCount += 1
            guard state.isRunning else {
                return nil
            }
            guard terminatesOnForceTerminate else {
                return ProcessExitCallbacks(signalAccepted: true)
            }
            state.isRunning = false
            return takeExitCallbacksLocked(status: 137)
        }
        perform(result)
        return result?.signalAccepted == true
    }

    func stopOutput() {
        lock.withLock {
            state.stopOutputCount += 1
        }
        stopOutputRecorder.record(())
        if finishesOutputOnStop {
            finishStdout()
            finishStderr()
        }
    }

    func waitForStdinClosed() async {
        await stdinTerminal.wait()
    }

    func waitForOutputStopped() async {
        await stdoutTerminal.wait()
        await stderrTerminal.wait()
    }

    func nextStopOutput() async throws {
        _ = try await stopOutputRecorder.nextValue(at: 0)
    }

    func emitStdout(_ data: Data) {
        stdoutContinuation.yield(data)
    }

    func emitStderr(_ data: Data) {
        stderrContinuation.yield(data)
    }

    func emitTermination(status: Int32) {
        let result = lock.withLock { () -> ProcessExitCallbacks in
            state.isRunning = false
            return takeExitCallbacksLocked(status: status)
        }
        perform(result)
    }

    func finishStdout() {
        stdoutContinuation.finish()
        stdoutTerminal.signal()
    }

    func finishStderr() {
        stderrContinuation.finish()
        stderrTerminal.signal()
    }

    func completeQueuedStdinWrite(bytes: Int) {
        let shouldSignal = lock.withLock { () -> Bool in
            state.queuedStdinBytes = max(0, state.queuedStdinBytes - bytes)
            if state.queuedWriteSizes.first == bytes {
                state.queuedWriteSizes.removeFirst()
            }
            state.stdinWriteCompletionCount += 1
            return state.isStdinClosing && state.queuedStdinBytes == 0
        }
        if shouldSignal { stdinTerminal.signal() }
    }

    func stdinWrites() -> [Data] {
        lock.withLock {
            state.stdinWrites
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                closeStdinCount: state.closeStdinCount,
                terminateCount: state.terminateCount,
                forceTerminateCount: state.forceTerminateCount,
                stopOutputCount: state.stopOutputCount,
                queuedStdinBytes: state.queuedStdinBytes,
                stdinWriteCompletionCount: state.stdinWriteCompletionCount
            )
        }
    }

    private struct ProcessExitCallbacks {
        let signalAccepted: Bool
        let status: Int32?
        let onTermination: (@Sendable (Int32) -> Void)?
        let shouldSignalStdin: Bool

        init(
            signalAccepted: Bool,
            status: Int32? = nil,
            onTermination: (@Sendable (Int32) -> Void)? = nil,
            shouldSignalStdin: Bool = false
        ) {
            self.signalAccepted = signalAccepted
            self.status = status
            self.onTermination = onTermination
            self.shouldSignalStdin = shouldSignalStdin
        }
    }

    private func takeExitCallbacksLocked(status: Int32) -> ProcessExitCallbacks {
        let queuedWriteSizes = state.queuedWriteSizes
        state.queuedWriteSizes.removeAll()
        state.queuedStdinBytes = 0
        state.stdinWriteCompletionCount += queuedWriteSizes.count
        return ProcessExitCallbacks(
            signalAccepted: true,
            status: status,
            onTermination: state.onTermination,
            shouldSignalStdin: state.isStdinClosing
        )
    }

    private func perform(_ callbacks: ProcessExitCallbacks?) {
        guard let callbacks else { return }
        if callbacks.shouldSignalStdin { stdinTerminal.signal() }
        if let status = callbacks.status {
            callbacks.onTermination?(status)
        }
    }
}
