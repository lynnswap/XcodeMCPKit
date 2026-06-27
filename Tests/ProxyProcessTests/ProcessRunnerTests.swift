import Darwin
import Foundation
import Testing
import XcodeMCPProxyTestSupport

@testable import XcodeMCPRuntime

@Suite(.serialized, .enabled(if: ProcessTestEnvironment.isEnabled))
struct ProcessRunnerTests {
    @Test func dispatchGroupLeaveGuardLeavesOnlyOnce() {
        let group = DispatchGroup()
        let guarder = DispatchGroupLeaveGuard(group: group)

        guarder.leaveIfNeeded()
        guarder.leaveIfNeeded()

        #expect(group.wait(timeout: .now()) == .success)
    }

    @Test func processRunnerDrainsLargeStdoutWithoutHanging() async throws {
        let runner = ProcessRunner()
        let output = try await waitWithTimeout(
            "ProcessRunner should finish draining large stdout",
            timeout: .seconds(5)
        ) {
            try await runner.run(
                ProcessRequest(
                    label: "large-stdout",
                    executablePath: "/bin/sh",
                    arguments: ["-c", "yes x | head -c 200000"],
                    input: nil
                )
            )
        }

        #expect(output.terminationStatus == 0)
        #expect(output.stdout.utf8.count == 200000)
    }

    @Test func processRunnerPreservesLargeChunkedStdoutOrder() async throws {
        let runner = ProcessRunner()
        let segments = (0..<64).map { index in
            let prefix = "[\(String(index).leftPadding(toLength: 3, withPad: "0"))]"
            let scalar = UnicodeScalar(65 + (index % 26))!
            return prefix + String(repeating: Character(scalar), count: 2048)
        }
        let expected = segments.joined()
        let output = try await waitWithTimeout(
            "ProcessRunner should preserve large chunk ordering",
            timeout: .seconds(5)
        ) {
            try await runner.run(
                ProcessRequest(
                    label: "ordered-large-stdout",
                    executablePath: "/usr/bin/python3",
                    arguments: makePythonSegmentEmitterArgs(segments: segments, pauseSeconds: 0.0005),
                    input: nil
                )
            )
        }

        #expect(output.terminationStatus == 0)
        #expect(output.stdout == expected)
    }

    @Test func processRunnerTerminatesTimedOutProcess() async throws {
        let scheduler = TestProcessRunnerDelayScheduler()
        let runner = ProcessRunner(delayScheduler: scheduler)
        let timeoutNanoseconds: Int64 = 10_000_000_000
        let task = Task {
            try await runner.run(
                ProcessRequest(
                    label: "timeout",
                    executablePath: "/usr/bin/python3",
                    arguments: makePythonPausedProcessArgs(),
                    input: nil,
                    timeoutNanoseconds: timeoutNanoseconds
                )
            )
        }
        defer {
            task.cancel()
        }

        let timeout = try await waitWithTimeout("ProcessRunner should schedule timeout") {
            try await scheduler.nextScheduled(.timeout)
        }
        #expect(timeout.delayNanoseconds == timeoutNanoseconds)
        timeout.fire()

        await #expect(throws: ProcessTimeoutError.self) {
            _ = try await waitWithTimeout(
                "ProcessRunner should terminate a timed out process",
                timeout: .seconds(3)
            ) {
                try await task.value
            }
        }

        let killFallback = try await waitWithTimeout("ProcessRunner should schedule kill fallback") {
            try await scheduler.nextScheduled(.terminationKillFallback)
        }
        #expect(killFallback.delayNanoseconds == 1_000_000_000)
        killFallback.fire()
    }

    @Test func processRunnerTimeoutDoesNotWaitForChildHeldPipeAfterParentExit() async throws {
        let scheduler = TestProcessRunnerDelayScheduler()
        let runner = ProcessRunner(delayScheduler: scheduler)
        let timeoutNanoseconds: Int64 = 10_000_000_000
        let fifo = try TemporaryFIFO()
        var childPID: pid_t?
        defer {
            if let childPID {
                kill(childPID, SIGKILL)
            }
            fifo.cleanup()
        }
        let task = Task {
            try await runner.run(
                ProcessRequest(
                    label: "timeout-inherited-pipe",
                    executablePath: "/usr/bin/python3",
                    arguments: makePythonForkingPipeHolderArgs(readyFIFOPath: fifo.path),
                    input: nil,
                    timeoutNanoseconds: timeoutNanoseconds
                )
            )
        }
        defer {
            task.cancel()
        }

        let childPIDLine = try await waitWithTimeout("pipe-holding child should start") {
            try await fifo.reader.readLine()
        }
        childPID = try parsePID(childPIDLine)

        let timeout = try await waitWithTimeout("ProcessRunner should schedule inherited-pipe timeout") {
            try await scheduler.nextScheduled(.timeout)
        }
        #expect(timeout.delayNanoseconds == timeoutNanoseconds)
        timeout.fire()

        await #expect(throws: ProcessTimeoutError.self) {
            _ = try await waitWithTimeout(
                "ProcessRunner should time out without waiting for child-held pipes",
                timeout: .seconds(2)
            ) {
                try await task.value
            }
        }
    }

    @Test func processRunnerCancelsRunningProcessPromptly() async throws {
        let scheduler = TestProcessRunnerDelayScheduler()
        let runner = ProcessRunner(delayScheduler: scheduler)
        let fifo = try TemporaryFIFO()
        defer {
            fifo.cleanup()
        }
        let task = Task {
            try await runner.run(
                ProcessRequest(
                    label: "cancel",
                    executablePath: "/usr/bin/python3",
                    arguments: makePythonPausedProcessArgs(readyFIFOPath: fifo.path),
                    input: nil
                )
            )
        }
        defer {
            task.cancel()
        }

        _ = try await waitWithTimeout("ProcessRunner child should be running before cancellation") {
            try await fifo.reader.readLine()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await waitWithTimeout(
                "ProcessRunner should finish promptly when cancelled",
                timeout: .seconds(1)
            ) {
                try await task.value
            }
        }

        let killFallback = try await waitWithTimeout(
            "ProcessRunner should own the cancellation kill delay"
        ) {
            try await scheduler.nextScheduled(.terminationKillFallback)
        }
        #expect(killFallback.delayNanoseconds == 1_000_000_000)
        killFallback.fire()
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

private struct TemporaryFIFO: Sendable {
    let path: String
    let reader: FIFOMessageReader

    private let directoryURL: URL

    init() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let path = directoryURL.appendingPathComponent("ready").path
        guard unsafe mkfifo(path, mode_t(0o600)) == 0 else {
            throw currentPOSIXError()
        }
        self.path = path
        self.reader = try FIFOMessageReader(path: path)
        self.directoryURL = directoryURL
    }

    func cleanup() {
        reader.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private final class FIFOMessageReader: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: CInt?

    init(path: String) throws {
        let fd = unsafe Darwin.open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else {
            throw currentPOSIXError()
        }
        self.fd = fd
    }

    deinit {
        close()
    }

    func readLine() async throws -> String {
        let fd = try currentFileDescriptor()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try readFIFOMessageLine(from: fd)
            }.value
        } onCancel: {
            self.close()
        }
    }

    func close() {
        let fd = locked {
            defer {
                self.fd = nil
            }
            return self.fd
        }
        if let fd {
            Darwin.close(fd)
        }
    }

    private func currentFileDescriptor() throws -> CInt {
        try locked {
            guard let fd else {
                throw POSIXError(.EBADF)
            }
            return fd
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return try body()
    }
}

private extension String {
    func leftPadding(toLength length: Int, withPad pad: String) -> String {
        guard count < length else { return self }
        return String(repeating: pad, count: length - count) + self
    }
}

private func makePythonPausedProcessArgs(readyFIFOPath: String? = nil) -> [String] {
    let script = """
    import signal
    import sys

    if len(sys.argv) > 1:
        with open(sys.argv[1], "w") as ready:
            ready.write("ready\\n")
            ready.flush()

    signal.pause()
    """
    if let readyFIFOPath {
        return ["-c", script, readyFIFOPath]
    }
    return ["-c", script]
}

private func makePythonForkingPipeHolderArgs(readyFIFOPath: String) -> [String] {
    let script = """
    import os
    import signal
    import sys

    parent_pid = os.getpid()
    pid = os.fork()
    if pid == 0:
        while os.getppid() == parent_pid:
            pass
        with open(sys.argv[1], "w") as ready:
            ready.write(str(os.getpid()) + "\\n")
            ready.flush()
        signal.pause()
        os._exit(0)

    os._exit(0)
    """
    return ["-c", script, readyFIFOPath]
}

private func makePythonSegmentEmitterArgs(
    segments: [String],
    pauseSeconds: Double
) -> [String] {
    let script = """
    import sys
    import time

    pause = float(sys.argv[1])
    for segment in sys.argv[2:]:
        sys.stdout.write(segment)
        sys.stdout.flush()
        time.sleep(pause)
    """
    return ["-c", script, "\(pauseSeconds)"] + segments
}

private func parsePID(_ line: String) throws -> pid_t {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Int32(trimmed) else {
        throw ProcessRunnerTestError.invalidPID(trimmed)
    }
    return pid_t(value)
}

private func readFIFOMessageLine(from fd: CInt) throws -> String {
    var bytes: [UInt8] = []
    while true {
        var byte: UInt8 = 0
        let readCount = unsafe Darwin.read(fd, &byte, 1)
        if readCount == 1 {
            if byte == UInt8(ascii: "\n") {
                return String(decoding: bytes, as: UTF8.self)
            }
            bytes.append(byte)
            continue
        }
        if readCount == 0 {
            throw POSIXError(.EPIPE)
        }
        if errno == EINTR {
            continue
        }
        throw currentPOSIXError()
    }
}

private func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

private enum ProcessRunnerTestError: Error {
    case invalidPID(String)
}
