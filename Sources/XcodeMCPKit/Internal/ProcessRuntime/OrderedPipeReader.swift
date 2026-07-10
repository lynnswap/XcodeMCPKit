import Dispatch
import Foundation
import NIOConcurrencyHelpers

package final class AsyncTerminalSignal: @unchecked Sendable {
    private struct State {
        var isTerminal = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = NIOLockedValueBox(State())

    package init() {}

    package func signal() {
        let waiters = state.withLockedValue { state -> [CheckedContinuation<Void, Never>] in
            guard state.isTerminal == false else { return [] }
            state.isTerminal = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    package func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLockedValue { state in
                guard state.isTerminal == false else { return true }
                state.waiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }
}

package final class OrderedPipeReader: @unchecked Sendable {
    package nonisolated let chunks: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let fileHandle: FileHandle
    private let queue: DispatchQueue
    private let state = NIOLockedValueBox(State())
    private let terminal = AsyncTerminalSignal()

    private struct State: Sendable {
        var isStarted = false
        var isFinished = false
        var source: DispatchSourceRead?
    }

    package init(
        fileHandle: FileHandle,
        label: String
    ) {
        self.fileHandle = fileHandle
        self.queue = DispatchQueue(label: label)

        var streamContinuation: AsyncStream<Data>.Continuation!
        self.chunks = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    package func start() {
        let source = state.withLockedValue { state -> DispatchSourceRead? in
            guard !state.isStarted, !state.isFinished else {
                return nil
            }
            state.isStarted = true
            let source = DispatchSource.makeReadSource(
                fileDescriptor: fileHandle.fileDescriptor,
                queue: queue
            )
            state.source = source
            return source
        }
        guard let source else { return }

        source.setEventHandler { [weak self] in
            self?.consumeAvailableData()
        }
        let terminal = terminal
        source.setCancelHandler { [fileHandle] in
            try? fileHandle.close()
            terminal.signal()
        }
        source.resume()
    }

    package func stop() {
        finish()
    }

    package func waitUntilStopped() async {
        await terminal.wait()
    }

    private func consumeAvailableData() {
        guard state.withLockedValue({ !$0.isFinished }) else {
            return
        }

        let chunk = fileHandle.availableData
        if chunk.isEmpty {
            finish()
            return
        }

        guard state.withLockedValue({ !$0.isFinished }) else {
            return
        }
        continuation.yield(chunk)
    }

    private func finish() {
        let result = state.withLockedValue { state -> (shouldFinish: Bool, source: DispatchSourceRead?) in
            guard !state.isFinished else {
                return (false, nil)
            }
            state.isFinished = true
            let source = state.source
            state.source = nil
            return (true, source)
        }
        guard result.shouldFinish else { return }
        continuation.finish()
        if let source = result.source {
            source.cancel()
        } else {
            try? fileHandle.close()
            terminal.signal()
        }
    }
}
