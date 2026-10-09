import Foundation
import NIOConcurrencyHelpers
import XcodeMCPProxyRuntimeContract

final class NativeHostBrokerCancellation: Sendable {
    private struct State: Sendable {
        var reason: ProxyRuntimeCancellationReason?
        var child: (UUID, any ProxyRuntimeRequestOperating)?
    }
    private let state = NIOLockedValueBox(State())

    func install(_ child: any ProxyRuntimeRequestOperating) -> UUID {
        let token = UUID()
        let reason = state.withLockedValue { state in
            state.child = (token, child)
            return state.reason
        }
        if let reason { child.cancel(reason: reason) }
        return token
    }

    func remove(_ token: UUID) {
        state.withLockedValue { state in
            if state.child?.0 == token { state.child = nil }
        }
    }

    func cancel(reason: ProxyRuntimeCancellationReason) {
        let child = state.withLockedValue { state in
            if state.reason == nil { state.reason = reason }
            return (state.child?.1, state.reason ?? reason)
        }
        child.0?.cancel(reason: child.1)
    }
}

final class NativeHostBrokerOperation: ProxyRuntimeRequestOperating, Sendable {
    private struct State: Sendable {
        var result: Result<ProxyRuntimeReply, any Error>?
        var callbacks: [@Sendable (Result<ProxyRuntimeReply, any Error>) -> Void] = []
        var task: Task<Void, Never>?
    }

    private let state = NIOLockedValueBox(State())
    let cancellation = NativeHostBrokerCancellation()
    private let cancelledReply: ProxyRuntimeReply
    let requestIDKey: String?

    init(
        cancelledReply: ProxyRuntimeReply,
        requestIDKey: String? = nil,
        work: @escaping @Sendable (NativeHostBrokerCancellation) async -> ProxyRuntimeReply
    ) {
        self.cancelledReply = cancelledReply
        self.requestIDKey = requestIDKey
        let task = Task { [self] in
            let reply = await work(cancellation)
            finish(.success(reply))
        }
        state.withLockedValue { state in
            if state.result == nil { state.task = task }
        }
    }

    func whenComplete(_ completion: @escaping @Sendable (Result<ProxyRuntimeReply, any Error>) -> Void) {
        let result = state.withLockedValue { state -> Result<ProxyRuntimeReply, any Error>? in
            if let result = state.result { return result }
            state.callbacks.append(completion)
            return nil
        }
        if let result { completion(result) }
    }

    func cancel(reason: ProxyRuntimeCancellationReason) {
        let task = state.withLockedValue { $0.task }
        finish(.success(cancelledReply))
        cancellation.cancel(reason: reason)
        task?.cancel()
    }

    private func finish(_ result: Result<ProxyRuntimeReply, any Error>) {
        let callbacks = state.withLockedValue { state in
            guard state.result == nil else { return [@Sendable (Result<ProxyRuntimeReply, any Error>) -> Void]() }
            state.result = result
            state.task = nil
            let callbacks = state.callbacks
            state.callbacks.removeAll()
            return callbacks
        }
        for callback in callbacks { callback(result) }
    }
}

func nativeHostBrokerReply(
    from runtime: any ProxyRuntimeServing,
    request: ProxyRuntimeRequest,
    sessionID: ProxySessionID,
    cancellation: NativeHostBrokerCancellation
) async throws -> ProxyRuntimeReply {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard let operation = runtime.beginRequest(request, in: sessionID) else {
                continuation.resume(throwing: NativeHostBrokerError("Backend session is unavailable"))
                return
            }
            let token = cancellation.install(operation)
            operation.whenComplete { result in
                cancellation.remove(token)
                runtime.clientRequestFinished(sessionID)
                continuation.resume(with: result)
            }
        }
    } onCancel: {
        cancellation.cancel(reason: .channelInactive)
    }
}
