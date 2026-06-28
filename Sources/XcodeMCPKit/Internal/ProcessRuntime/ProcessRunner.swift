import Foundation
import Darwin
import NIOConcurrencyHelpers

package enum ProcessRunnerScheduledDelayKind: Sendable {
    case timeout
    case terminationKillFallback
}

package final class ProcessRunnerScheduledDelay: @unchecked Sendable {
    private let cancelImpl: @Sendable () -> Void

    package init(cancel: @escaping @Sendable () -> Void) {
        self.cancelImpl = cancel
    }

    package func cancel() {
        cancelImpl()
    }
}

package protocol ProcessRunnerDelayScheduling: Sendable {
    @discardableResult
    func schedule(
        _ kind: ProcessRunnerScheduledDelayKind,
        afterNanoseconds delayNanoseconds: Int64,
        operation: @escaping @Sendable () -> Void
    ) -> ProcessRunnerScheduledDelay
}

private struct DispatchProcessRunnerDelayScheduler: ProcessRunnerDelayScheduling {
    @discardableResult
    func schedule(
        _ kind: ProcessRunnerScheduledDelayKind,
        afterNanoseconds delayNanoseconds: Int64,
        operation: @escaping @Sendable () -> Void
    ) -> ProcessRunnerScheduledDelay {
        let workItem = DispatchWorkItem(block: operation)
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .nanoseconds(Int(delayNanoseconds)),
            execute: workItem
        )
        let cancellation = DispatchWorkItemCancellation(workItem: workItem)
        return ProcessRunnerScheduledDelay {
            cancellation.cancel()
        }
    }
}

private final class DispatchWorkItemCancellation: @unchecked Sendable {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

private final class ProcessTimeoutController: @unchecked Sendable {
    typealias Action = @Sendable () -> Void

    private struct State {
        var timeoutNanoseconds: Int64?
        var scheduledDelay: ProcessRunnerScheduledDelay?
        var action: Action?
        var scheduled = false
    }

    private let scheduler: any ProcessRunnerDelayScheduling
    private let state = NIOLockedValueBox(State())

    init(scheduler: any ProcessRunnerDelayScheduling) {
        self.scheduler = scheduler
    }

    func configure(timeoutNanoseconds: Int64?, action: @escaping Action) {
        guard let timeoutNanoseconds, timeoutNanoseconds > 0 else {
            return
        }
        state.withLockedValue { state in
            state.timeoutNanoseconds = timeoutNanoseconds
            state.action = action
        }
    }

    func schedule() {
        let timeoutNanoseconds = state.withLockedValue { state -> Int64? in
            guard
                state.scheduled == false,
                let timeoutNanoseconds = state.timeoutNanoseconds,
                state.action != nil
            else {
                return nil
            }
            state.scheduled = true
            return timeoutNanoseconds
        }
        guard let timeoutNanoseconds else {
            return
        }
        let scheduledDelay = scheduler.schedule(
            .timeout,
            afterNanoseconds: timeoutNanoseconds
        ) { [self] in
            fire()
        }
        let shouldCancel = state.withLockedValue { state in
            guard state.action != nil else {
                return true
            }
            state.scheduledDelay = scheduledDelay
            return false
        }
        if shouldCancel {
            scheduledDelay.cancel()
        }
    }

    func cancel() {
        let scheduledDelay = state.withLockedValue { state -> ProcessRunnerScheduledDelay? in
            let scheduledDelay = state.scheduledDelay
            state.scheduledDelay = nil
            state.timeoutNanoseconds = nil
            state.action = nil
            return scheduledDelay
        }
        scheduledDelay?.cancel()
    }

    private func fire() {
        let action = state.withLockedValue { state -> Action? in
            guard let action = state.action else {
                return nil
            }
            state.timeoutNanoseconds = nil
            state.scheduledDelay = nil
            state.action = nil
            return action
        }
        action?()
    }
}

private final class ProcessCancellationState: @unchecked Sendable {
    private struct Registered: Sendable {
        let cleanup: @Sendable () -> Void
        let resume: @Sendable (Result<ProcessOutput, Error>) -> Void
    }

    private struct State: Sendable {
        var registered: Registered?
        var cancelled = false
        var completed = false
    }

    private let state = NIOLockedValueBox(State())

    func install(
        cleanup: @escaping @Sendable () -> Void,
        resume: @escaping @Sendable (Result<ProcessOutput, Error>) -> Void
    ) -> Bool {
        state.withLockedValue { state in
            guard state.completed == false, state.cancelled == false else {
                return false
            }
            state.registered = Registered(cleanup: cleanup, resume: resume)
            return true
        }
    }

    func complete() {
        state.withLockedValue { state in
            state.completed = true
            state.registered = nil
        }
    }

    func isCancelled() -> Bool {
        state.withLockedValue { state in
            state.cancelled
        }
    }

    func cancel() {
        let registered = state.withLockedValue { state -> Registered? in
            guard state.completed == false else {
                return nil
            }
            state.cancelled = true
            guard let registered = state.registered else {
                return nil
            }
            state.completed = true
            state.registered = nil
            return registered
        }
        guard let registered else {
            return
        }
        registered.cleanup()
        registered.resume(.failure(CancellationError()))
    }
}

package struct ProcessRequest: Sendable {
    package let label: String
    package let executablePath: String
    package let arguments: [String]
    package let input: String?
    package let timeoutNanoseconds: Int64?

    package init(
        label: String,
        executablePath: String,
        arguments: [String],
        input: String?,
        timeoutNanoseconds: Int64? = nil
    ) {
        self.label = label
        self.executablePath = executablePath
        self.arguments = arguments
        self.input = input
        self.timeoutNanoseconds = timeoutNanoseconds
    }
}

package struct ProcessTimeoutError: Error, Sendable {
    package let label: String

    package init(label: String) {
        self.label = label
    }
}

package struct ProcessOutput: Sendable {
    package let terminationStatus: Int32
    package let stdout: String
    package let stderr: String

    package init(terminationStatus: Int32, stdout: String, stderr: String) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

package protocol ProcessRunning: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessOutput
}

package struct ProcessRunnerStartedProcessIO: Sendable {
    package let stdoutChunks: AsyncStream<Data>
    package let stderrChunks: AsyncStream<Data>

    package init(
        stdoutChunks: AsyncStream<Data>,
        stderrChunks: AsyncStream<Data>
    ) {
        self.stdoutChunks = stdoutChunks
        self.stderrChunks = stderrChunks
    }
}

package protocol ProcessRunnerProcessDriving: AnyObject, Sendable {
    func start(
        request: ProcessRequest,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> ProcessRunnerStartedProcessIO
    func writeInput(_ input: String) throws
    func closeStdin()
    func terminate()
    func stopOutput()
    func killIfRunning()
}

package protocol ProcessRunnerProcessDriverMaking: Sendable {
    func makeDriver() -> any ProcessRunnerProcessDriving
}

package struct LiveProcessRunnerProcessDriverFactory: ProcessRunnerProcessDriverMaking {
    package init() {}

    package func makeDriver() -> any ProcessRunnerProcessDriving {
        LiveProcessRunnerProcessDriver()
    }
}

private final class LiveProcessRunnerProcessDriver: ProcessRunnerProcessDriving, @unchecked Sendable {
    private struct State {
        var process: Process?
        var stdoutPipe: Pipe?
        var stderrPipe: Pipe?
        var stdinPipe: Pipe?
        var stdoutReader: OrderedPipeReader?
        var stderrReader: OrderedPipeReader?
    }

    private let lock = NSLock()
    private var state = State()

    func start(
        request: ProcessRequest,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> ProcessRunnerStartedProcessIO {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        let stdoutReader = OrderedPipeReader(
            fileHandle: stdoutPipe.fileHandleForReading,
            label: "XcodeMCPProxy.ProcessRunner.stdout"
        )
        let stderrReader = OrderedPipeReader(
            fileHandle: stderrPipe.fileHandleForReading,
            label: "XcodeMCPProxy.ProcessRunner.stderr"
        )

        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if request.input != nil {
            process.standardInput = stdinPipe
        }
        process.terminationHandler = { [weak self] process in
            self?.clearProcess()
            onTermination(process.terminationStatus)
        }

        stdoutReader.start()
        stderrReader.start()
        do {
            try process.run()
        } catch {
            stdoutReader.stop()
            stderrReader.stop()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdinPipe.fileHandleForWriting.close()
            throw error
        }

        lock.withLock {
            state.process = process
            state.stdoutPipe = stdoutPipe
            state.stderrPipe = stderrPipe
            state.stdinPipe = stdinPipe
            state.stdoutReader = stdoutReader
            state.stderrReader = stderrReader
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        return ProcessRunnerStartedProcessIO(
            stdoutChunks: stdoutReader.chunks,
            stderrChunks: stderrReader.chunks
        )
    }

    func writeInput(_ input: String) throws {
        guard let inputData = input.data(using: .utf8) else {
            return
        }
        let pipe = lock.withLock { state.stdinPipe }
        try pipe?.fileHandleForWriting.write(contentsOf: inputData)
    }

    func closeStdin() {
        let pipe = lock.withLock { state.stdinPipe }
        try? pipe?.fileHandleForWriting.close()
    }

    func terminate() {
        let process = lock.withLock { state.process }
        guard let process, process.isRunning else {
            return
        }
        process.terminate()
    }

    func stopOutput() {
        let snapshot = lock.withLock {
            (
                stdoutReader: state.stdoutReader,
                stderrReader: state.stderrReader,
                stdoutPipe: state.stdoutPipe,
                stderrPipe: state.stderrPipe
            )
        }
        snapshot.stdoutReader?.stop()
        snapshot.stderrReader?.stop()
        try? snapshot.stdoutPipe?.fileHandleForWriting.close()
        try? snapshot.stderrPipe?.fileHandleForWriting.close()
    }

    func killIfRunning() {
        let process = lock.withLock { state.process }
        guard let process, process.isRunning else {
            return
        }
        kill(process.processIdentifier, SIGKILL)
    }

    private func clearProcess() {
        lock.withLock {
            state.process = nil
        }
    }
}

private final class ProcessRunnerRunState: @unchecked Sendable {
    private struct State {
        var stdout = Data()
        var stderr = Data()
        var terminationStatus: Int32?
        var stdoutDrained = false
        var stderrDrained = false
        var didResume = false
    }

    private let state = NIOLockedValueBox(State())

    func appendStdout(_ data: Data) {
        state.withLockedValue { state in
            state.stdout.append(data)
        }
    }

    func appendStderr(_ data: Data) {
        state.withLockedValue { state in
            state.stderr.append(data)
        }
    }

    func markStdoutDrained() -> ProcessOutput? {
        state.withLockedValue { state in
            state.stdoutDrained = true
            return completeOutputIfReady(state: &state)
        }
    }

    func markStderrDrained() -> ProcessOutput? {
        state.withLockedValue { state in
            state.stderrDrained = true
            return completeOutputIfReady(state: &state)
        }
    }

    func markTerminated(status: Int32) -> ProcessOutput? {
        state.withLockedValue { state in
            state.terminationStatus = status
            return completeOutputIfReady(state: &state)
        }
    }

    func reserveResume() -> Bool {
        state.withLockedValue { state in
            guard state.didResume == false else {
                return false
            }
            state.didResume = true
            return true
        }
    }

    private func completeOutputIfReady(state: inout State) -> ProcessOutput? {
        guard
            state.didResume == false,
            let terminationStatus = state.terminationStatus,
            state.stdoutDrained,
            state.stderrDrained
        else {
            return nil
        }
        state.didResume = true
        return ProcessOutput(
            terminationStatus: terminationStatus,
            stdout: String(decoding: state.stdout, as: UTF8.self),
            stderr: String(decoding: state.stderr, as: UTF8.self)
        )
    }
}

private final class ProcessRunnerCleanupState: @unchecked Sendable {
    private let didCleanup = NIOLockedValueBox(false)

    func cleanupOnce(_ cleanup: () -> Void) {
        let shouldCleanup = didCleanup.withLockedValue { didCleanup in
            guard didCleanup == false else {
                return false
            }
            didCleanup = true
            return true
        }
        guard shouldCleanup else {
            return
        }
        cleanup()
    }
}

package struct ProcessRunner: ProcessRunning {
    private static let terminationKillFallbackDelayNanoseconds: Int64 = 1_000_000_000

    private let delayScheduler: any ProcessRunnerDelayScheduling
    private let processDriverFactory: any ProcessRunnerProcessDriverMaking

    package init(
        delayScheduler: any ProcessRunnerDelayScheduling = DispatchProcessRunnerDelayScheduler(),
        processDriverFactory: any ProcessRunnerProcessDriverMaking = LiveProcessRunnerProcessDriverFactory()
    ) {
        self.delayScheduler = delayScheduler
        self.processDriverFactory = processDriverFactory
    }

    package func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        let cancellationState = ProcessCancellationState()
        let runState = ProcessRunnerRunState()
        let cleanupState = ProcessRunnerCleanupState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let driver = processDriverFactory.makeDriver()
                let timeoutController = ProcessTimeoutController(scheduler: delayScheduler)
                let resumeReserved: @Sendable (Result<ProcessOutput, Error>) -> Void = { result in
                    timeoutController.cancel()
                    cancellationState.complete()
                    continuation.resume(with: result)
                }
                let resumeOnce: @Sendable (Result<ProcessOutput, Error>) -> Void = { result in
                    guard runState.reserveResume() else { return }
                    resumeReserved(result)
                }
                let resumeSuccessIfReady: @Sendable (ProcessOutput?) -> Void = { output in
                    guard let output else {
                        return
                    }
                    resumeReserved(.success(output))
                }

                let cancelResources: @Sendable () -> Void = {
                    cleanupState.cleanupOnce {
                        driver.terminate()
                        delayScheduler.schedule(
                            .terminationKillFallback,
                            afterNanoseconds: Self.terminationKillFallbackDelayNanoseconds
                        ) {
                            driver.killIfRunning()
                        }
                        driver.stopOutput()
                        driver.closeStdin()
                    }
                }
                timeoutController.configure(timeoutNanoseconds: request.timeoutNanoseconds) {
                    guard runState.reserveResume() else {
                        return
                    }
                    cancelResources()
                    resumeReserved(.failure(ProcessTimeoutError(label: request.label)))
                }
                guard cancellationState.install(cleanup: cancelResources, resume: resumeOnce) else {
                    cancelResources()
                    resumeOnce(.failure(CancellationError()))
                    return
                }

                do {
                    let io = try driver.start(request: request) { status in
                        resumeSuccessIfReady(runState.markTerminated(status: status))
                    }
                    Task {
                        for await chunk in io.stdoutChunks {
                            runState.appendStdout(chunk)
                        }
                        resumeSuccessIfReady(runState.markStdoutDrained())
                    }
                    Task {
                        for await chunk in io.stderrChunks {
                            runState.appendStderr(chunk)
                        }
                        resumeSuccessIfReady(runState.markStderrDrained())
                    }
                    if cancellationState.isCancelled() {
                        cancelResources()
                        return
                    }
                    timeoutController.schedule()
                    if let input = request.input {
                        try driver.writeInput(input)
                        driver.closeStdin()
                    }
                } catch {
                    driver.terminate()
                    driver.stopOutput()
                    driver.closeStdin()
                    resumeOnce(.failure(error))
                }
            }
        } onCancel: {
            cancellationState.cancel()
        }
    }
}
