import Foundation
import NIOConcurrencyHelpers

/// Runs one operation at a time for each key, in arrival order.
final class NativeBrokerTurns<Key: Hashable & Sendable>: Sendable {
    /// The waiting operations' requests would exceed the limit.
    struct Full: Error {}

    private struct State {
        var queues: [Key: [UUID]] = [:]
        var waiters: [UUID: (continuation: CheckedContinuation<Void, any Error>, bytes: Int)] = [:]
        var waitingBytes = 0
        /// Turns cancelled before they joined their queue.
        var cancelled: Set<UUID> = []
    }

    private let state = NIOLockedValueBox(State())
    private let maximumWaitingBytes: Int

    /// - Parameter maximumWaitingBytes: The limit on the size of the requests that wait for their turn.
    init(maximumWaitingBytes: Int) {
        self.maximumWaitingBytes = maximumWaitingBytes
    }

    var waitingBytes: Int { state.withLockedValue { $0.waitingBytes } }

    /// Runs `operation` after the earlier operations for `key`. An operation whose `bytes` would
    /// exceed the waiting limit fails with ``Full`` instead of waiting.
    func run<T: Sendable>(_ key: Key, bytes: Int, _ operation: () async throws -> T) async throws -> T {
        let id = UUID()
        try await wait(for: id, key: key, bytes: bytes)
        defer { release(id, key: key) }
        return try await operation()
    }

    private func wait(for id: UUID, key: Key, bytes: Int) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let admitted: Result<Bool, any Error> = state.withLockedValue { state in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if state.queues[key]?.isEmpty ?? true {
                        state.queues[key] = [id]
                        return .success(true)
                    }
                    guard bytes <= maximumWaitingBytes - state.waitingBytes else { return .failure(Full()) }
                    state.queues[key]?.append(id)
                    state.waiters[id] = (continuation, bytes)
                    state.waitingBytes += bytes
                    return .success(false)
                }
                switch admitted {
                case .success(true): continuation.resume()
                case .success(false): break
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            let waiter = state.withLockedValue { state -> CheckedContinuation<Void, any Error>? in
                if let waiter = state.waiters.removeValue(forKey: id) {
                    state.queues[key]?.removeAll { $0 == id }
                    state.waitingBytes -= waiter.bytes
                    return waiter.continuation
                }
                // A turn that already runs observes cancellation itself.
                if state.queues[key]?.contains(id) != true { state.cancelled.insert(id) }
                return nil
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    private func release(_ id: UUID, key: Key) {
        let next = state.withLockedValue { state -> CheckedContinuation<Void, any Error>? in
            state.queues[key]?.removeAll { $0 == id }
            guard let head = state.queues[key]?.first else {
                state.queues[key] = nil
                return nil
            }
            guard let waiter = state.waiters.removeValue(forKey: head) else { return nil }
            state.waitingBytes -= waiter.bytes
            return waiter.continuation
        }
        next?.resume()
    }
}
