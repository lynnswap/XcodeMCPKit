import Darwin
import Dispatch
import Foundation
import Logging
import Synchronization

private final class StdioOutputChannel: @unchecked Sendable {
    private final class Terminal: Sendable {
        private struct State {
            var isFinished = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        private let state = Mutex(State())

        func finish() {
            let waiters: [CheckedContinuation<Void, Never>] = state.withLock { state in
                guard state.isFinished == false else { return [] }
                state.isFinished = true
                let waiters = state.waiters
                state.waiters.removeAll()
                return waiters
            }
            for waiter in waiters { waiter.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let shouldResume = state.withLock { state in
                    guard state.isFinished == false else { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if shouldResume { continuation.resume() }
            }
        }
    }

    private let channel: DispatchIO
    private let callbackQueue = DispatchQueue(label: "XcodeMCPProxy.StdioWriter.io")
    private let terminal: Terminal

    init(handle: FileHandle) {
        let descriptor = dup(handle.fileDescriptor)
        precondition(descriptor >= 0, "STDIO output FileHandle must be open")
        let terminal = Terminal()
        self.terminal = terminal
        self.channel = DispatchIO(
            type: .stream,
            fileDescriptor: descriptor,
            queue: callbackQueue
        ) { _ in
            _ = Darwin.close(descriptor)
            terminal.finish()
        }
    }

    func write(_ data: Data) async -> Int32 {
        let dispatchData = unsafe data.withUnsafeBytes { bytes in
            unsafe DispatchData(bytes: bytes)
        }
        return await withCheckedContinuation { continuation in
            channel.write(
                offset: 0,
                data: dispatchData,
                queue: callbackQueue
            ) { done, _, error in
                guard done else { return }
                continuation.resume(returning: error)
            }
        }
    }

    func cancel() {
        channel.close(flags: .stop)
    }

    func waitUntilClosed() async {
        await terminal.wait()
    }
}

private final class StdioWriterAdmission: Sendable {
    private let isAccepting = Mutex(true)

    func close() {
        isAccepting.withLock { $0 = false }
    }

    func acceptsWrites() -> Bool {
        isAccepting.withLock { $0 }
    }
}

actor StdioWriter {
    private enum Lifecycle {
        case running
        case closing
        case closed
    }

    private let channel: StdioOutputChannel
    private nonisolated let admission = StdioWriterAdmission()
    private let logger: Logger
    private let maxQueuedBytes = 4 * 1024 * 1024
    private var lifecycle: Lifecycle = .running
    private var tail: Task<Int32, Never>?
    private var writes: [UUID: Task<Int32, Never>] = [:]
    private var queuedBytes = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(handle: FileHandle, logger: Logger) {
        self.channel = StdioOutputChannel(handle: handle)
        self.logger = logger
    }

    func send(_ data: Data) async -> Bool {
        guard lifecycle == .running, admission.acceptsWrites() else { return false }
        var payload = data
        if payload.last != 0x0A {
            payload.append(0x0A)
        }
        guard queuedBytes + payload.count <= maxQueuedBytes else {
            logger.error(
                "STDIO output queue exceeded its byte limit",
                metadata: [
                    "queued_bytes": "\(queuedBytes)",
                    "payload_bytes": "\(payload.count)",
                    "limit_bytes": "\(maxQueuedBytes)",
                ]
            )
            return false
        }

        let id = UUID()
        let writePayload = payload
        let payloadByteCount = writePayload.count
        let previous = tail
        let channel = channel
        let task = Task<Int32, Never> {
            if let previous { _ = await previous.value }
            guard Task.isCancelled == false else { return ECANCELED }
            return await channel.write(writePayload)
        }
        writes[id] = task
        queuedBytes += payloadByteCount
        tail = task
        let error = await task.value
        writeFinished(id: id, bytes: payloadByteCount)
        if error != 0, error != ECANCELED {
            logger.warning(
                "STDIO output write failed",
                metadata: ["errno": "\(error)"]
            )
        }
        return error == 0
    }

    func close() async {
        switch lifecycle {
        case .closed:
            return
        case .closing:
            await withCheckedContinuation { closeWaiters.append($0) }
            return
        case .running:
            lifecycle = .closing
        }

        admission.close()
        channel.cancel()
        let tasks = Array(writes.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        await channel.waitUntilClosed()

        tail = nil
        writes.removeAll()
        queuedBytes = 0
        lifecycle = .closed
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    nonisolated func cancel() {
        admission.close()
        channel.cancel()
    }

    func pendingByteCount() -> Int {
        queuedBytes
    }

    isolated deinit {
        admission.close()
        channel.cancel()
        for task in writes.values { task.cancel() }
        for waiter in closeWaiters { waiter.resume() }
    }

    private func writeFinished(id: UUID, bytes: Int) {
        writes.removeValue(forKey: id)
        queuedBytes = max(0, queuedBytes - bytes)
    }
}
