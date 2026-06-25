import Foundation
import Darwin
import NIOConcurrencyHelpers

final class DispatchGroupLeaveGuard: @unchecked Sendable {
    private let group: DispatchGroup
    private let didLeave = NIOLockedValueBox(false)

    init(group: DispatchGroup) {
        self.group = group
        self.group.enter()
    }

    func leaveIfNeeded() {
        let shouldLeave = didLeave.withLockedValue { didLeave in
            guard didLeave == false else { return false }
            didLeave = true
            return true
        }
        guard shouldLeave else { return }
        group.leave()
    }
}

private final class PipeCollector: @unchecked Sendable {
    private let reader: OrderedPipeReader
    private let drainGuard: DispatchGroupLeaveGuard
    private let buffer = NIOLockedValueBox(Data())
    private var task: Task<Void, Never>?

    init(fileHandle: FileHandle, drainGroup: DispatchGroup, label: String) {
        self.reader = OrderedPipeReader(fileHandle: fileHandle, label: label)
        self.drainGuard = DispatchGroupLeaveGuard(group: drainGroup)
    }

    func start() {
        reader.start()
        task = Task { [buffer, drainGuard, reader] in
            for await chunk in reader.chunks {
                buffer.withLockedValue { data in
                    data.append(chunk)
                }
            }
            drainGuard.leaveIfNeeded()
        }
    }

    func collectedData() -> Data {
        buffer.withLockedValue { $0 }
    }

    func cancel() {
        reader.stop()
        task?.cancel()
        task = nil
        drainGuard.leaveIfNeeded()
    }
}

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

package struct ProcessRunner: ProcessRunning {
    private static let terminationKillFallbackDelayNanoseconds: Int64 = 1_000_000_000

    private let delayScheduler: any ProcessRunnerDelayScheduling

    package init(
        delayScheduler: any ProcessRunnerDelayScheduling = DispatchProcessRunnerDelayScheduler()
    ) {
        self.delayScheduler = delayScheduler
    }

    package func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        let cancellationState = ProcessCancellationState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let stdinPipe = Pipe()
                let drainGroup = DispatchGroup()
                let timeoutController = ProcessTimeoutController(scheduler: delayScheduler)
                let stdoutCollector = PipeCollector(
                    fileHandle: stdoutPipe.fileHandleForReading,
                    drainGroup: drainGroup,
                    label: "XcodeMCPProxy.ProcessRunner.stdout"
                )
                let stderrCollector = PipeCollector(
                    fileHandle: stderrPipe.fileHandleForReading,
                    drainGroup: drainGroup,
                    label: "XcodeMCPProxy.ProcessRunner.stderr"
                )
                let didResume = NIOLockedValueBox(false)
                let reserveResume: @Sendable () -> Bool = {
                    let shouldResume = didResume.withLockedValue { didResume in
                        guard didResume == false else { return false }
                        didResume = true
                        return true
                    }
                    return shouldResume
                }
                let resumeReserved: @Sendable (Result<ProcessOutput, Error>) -> Void = { result in
                    timeoutController.cancel()
                    cancellationState.complete()
                    continuation.resume(with: result)
                }
                let resumeOnce: @Sendable (Result<ProcessOutput, Error>) -> Void = { result in
                    guard reserveResume() else { return }
                    resumeReserved(result)
                }

                process.executableURL = URL(fileURLWithPath: request.executablePath)
                process.arguments = request.arguments
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                if request.input != nil {
                    process.standardInput = stdinPipe
                }
                stdoutCollector.start()
                stderrCollector.start()
                let cancelResources: @Sendable () -> Void = {
                    process.terminationHandler = nil
                    if process.isRunning {
                        process.terminate()
                        delayScheduler.schedule(
                            .terminationKillFallback,
                            afterNanoseconds: Self.terminationKillFallbackDelayNanoseconds
                        ) {
                            guard process.isRunning else {
                                return
                            }
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                    stdoutCollector.cancel()
                    stderrCollector.cancel()
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    try? stdinPipe.fileHandleForWriting.close()
                }
                timeoutController.configure(timeoutNanoseconds: request.timeoutNanoseconds) {
                    guard reserveResume() else {
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

                process.terminationHandler = { process in
                    DispatchQueue.global().async {
                        drainGroup.wait()
                        let output = ProcessOutput(
                            terminationStatus: process.terminationStatus,
                            stdout: String(decoding: stdoutCollector.collectedData(), as: UTF8.self),
                            stderr: String(decoding: stderrCollector.collectedData(), as: UTF8.self)
                        )
                        resumeOnce(.success(output))
                    }
                }

                do {
                    try process.run()
                    if cancellationState.isCancelled() {
                        cancelResources()
                        return
                    }
                    timeoutController.schedule()
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    if let input = request.input {
                        if let inputData = input.data(using: .utf8) {
                            try stdinPipe.fileHandleForWriting.write(contentsOf: inputData)
                        }
                        try stdinPipe.fileHandleForWriting.close()
                    }
                } catch {
                    process.terminationHandler = nil
                    if process.isRunning {
                        process.terminate()
                    }
                    stdoutCollector.cancel()
                    stderrCollector.cancel()
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    try? stdinPipe.fileHandleForWriting.close()
                    resumeOnce(.failure(error))
                }
            }
        } onCancel: {
            cancellationState.cancel()
        }
    }
}
