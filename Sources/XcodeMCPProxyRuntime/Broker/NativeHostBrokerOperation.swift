import Foundation
import NIOConcurrencyHelpers
import XcodeMCPCore
import XcodeMCPProxyRuntimeContract

final class NativeHostBrokerOperation: ProxyRuntimeRequestOperating, Sendable {
    private struct State: Sendable {
        var result: Result<ProxyRuntimeReply, any Error>?
        var callbacks: [@Sendable (Result<ProxyRuntimeReply, any Error>) -> Void] = []
        var task: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var workFinished = false
        var workCallbacks: [@Sendable () -> Void] = []
    }

    private let state = NIOLockedValueBox(State())
    private let workCompletion = AsyncTerminalSignal()
    private let cancelledReply: ProxyRuntimeReply
    let requestIDKey: String?

    init(
        cancelledReply: ProxyRuntimeReply,
        requestIDKey: String? = nil,
        deadline: Date? = nil,
        clock: ClockClient = .liveValue,
        timeoutReply: ProxyRuntimeReply? = nil,
        work: @escaping @Sendable () async -> ProxyRuntimeReply
    ) {
        self.cancelledReply = cancelledReply
        self.requestIDKey = requestIDKey
        let task = Task { [self] in
            let reply = await work()
            finish(.success(reply))
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
            guard state.result == nil else { return false }
            state.task = task
            state.timer = timer
            return true
        }
        if !retained { task.cancel(); timer?.cancel() }
    }

    func whenComplete(_ completion: @escaping @Sendable (Result<ProxyRuntimeReply, any Error>) -> Void) {
        let result = state.withLockedValue { state -> Result<ProxyRuntimeReply, any Error>? in
            if let result = state.result { return result }
            state.callbacks.append(completion)
            return nil
        }
        if let result { completion(result) }
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

    func cancel(reason: ProxyRuntimeCancellationReason) {
        interrupt(with: cancelledReply)
    }

    private func interrupt(with reply: ProxyRuntimeReply) {
        let task = state.withLockedValue { $0.task }
        guard finish(.success(reply)) else { return }
        // Cancelling the work task reaches the host connection, which cancels the host request.
        task?.cancel()
    }

    @discardableResult
    private func finish(_ result: Result<ProxyRuntimeReply, any Error>) -> Bool {
        let resources = state.withLockedValue { state -> (
            [@Sendable (Result<ProxyRuntimeReply, any Error>) -> Void], Task<Void, Never>?
        )? in
            guard state.result == nil else { return nil }
            state.result = result
            state.task = nil
            let callbacks = state.callbacks
            let timer = state.timer
            state.callbacks.removeAll()
            state.timer = nil
            return (callbacks, timer)
        }
        guard let resources else { return false }
        resources.1?.cancel()
        for callback in resources.0 { callback(result) }
        return true
    }
}
