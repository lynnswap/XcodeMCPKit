import Foundation
import NIOConcurrencyHelpers
import XcodeMCPCore
import XcodeMCPServerRuntimeContract

/// One admitted request. Its reply is the work's result, unless cancellation or the deadline
/// interrupts the work first with its own reply.
final class NativeHostBrokerOperation: ServerRuntimeCall {
    private struct State: Sendable {
        var reply: ServerRuntimeReply?
        var waiters: [CheckedContinuation<ServerRuntimeReply, Never>] = []
        var task: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var workFinished = false
        var workCallbacks: [@Sendable () -> Void] = []
    }

    private let state = NIOLockedValueBox(State())
    private let workCompletion = AsyncTerminalSignal()
    private let cancelledReply: ServerRuntimeReply
    let requestIDKey: String?

    init(
        cancelledReply: ServerRuntimeReply,
        requestIDKey: String? = nil,
        deadline: Date? = nil,
        clock: ClockClient = .liveValue,
        timeoutReply: ServerRuntimeReply? = nil,
        work: @escaping @Sendable () async -> ServerRuntimeReply
    ) {
        self.cancelledReply = cancelledReply
        self.requestIDKey = requestIDKey
        let task = Task { [self] in
            let reply = await work()
            finish(with: reply)
            finishWork()
        }
        let timer = deadline.flatMap { deadline -> Task<Void, Never>? in
            guard let timeoutReply else { return nil }
            return Task { [weak self] in
                await clock.sleep(.seconds(max(0, deadline.timeIntervalSince(clock.now()))))
                guard !Task.isCancelled else { return }
                self?.interrupt(with: timeoutReply)
            }
        }
        let retained = state.withLockedValue { state in
            guard state.reply == nil else { return false }
            state.task = task
            state.timer = timer
            return true
        }
        if !retained { task.cancel(); timer?.cancel() }
    }

    /// The request's reply, available as soon as the work finishes or is interrupted.
    var reply: ServerRuntimeReply {
        get async {
            await withCheckedContinuation { continuation in
                let reply = state.withLockedValue { state -> ServerRuntimeReply? in
                    if let reply = state.reply { return reply }
                    state.waiters.append(continuation)
                    return nil
                }
                if let reply { continuation.resume(returning: reply) }
            }
        }
    }

    func whenWorkComplete(_ completion: @escaping @Sendable () -> Void) {
        let finished = state.withLockedValue { state in
            if state.workFinished { return true }
            state.workCallbacks.append(completion)
            return false
        }
        if finished { completion() }
    }

    private func finishWork() {
        let callbacks = state.withLockedValue { state in
            state.workFinished = true
            let callbacks = state.workCallbacks
            state.workCallbacks.removeAll()
            return callbacks
        }
        for callback in callbacks { callback() }
        workCompletion.signal()
    }

    func waitForWorkCompletion() async { await workCompletion.wait() }

    func cancel() {
        interrupt(with: cancelledReply)
    }

    private func interrupt(with reply: ServerRuntimeReply) {
        let task = state.withLockedValue { $0.task }
        guard finish(with: reply) else { return }
        // Cancelling the work task reaches the host connection, which cancels the host request.
        task?.cancel()
    }

    @discardableResult
    private func finish(with reply: ServerRuntimeReply) -> Bool {
        let resources = state.withLockedValue { state -> ([CheckedContinuation<ServerRuntimeReply, Never>], Task<Void, Never>?)? in
            guard state.reply == nil else { return nil }
            state.reply = reply
            state.task = nil
            let waiters = state.waiters
            let timer = state.timer
            state.waiters.removeAll()
            state.timer = nil
            return (waiters, timer)
        }
        guard let resources else { return false }
        resources.1?.cancel()
        for waiter in resources.0 { waiter.resume(returning: reply) }
        return true
    }
}
