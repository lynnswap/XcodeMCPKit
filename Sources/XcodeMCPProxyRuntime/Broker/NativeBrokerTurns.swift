import Foundation
import NIOConcurrencyHelpers

/// Runs one operation at a time for each key, in arrival order.
final class NativeBrokerTurns<Key: Hashable & Sendable>: Sendable {
    private struct State {
        var queues: [Key: [UUID]] = [:]
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
        /// Turns cancelled before they joined their queue.
        var cancelled: Set<UUID> = []
    }

    private let state = NIOLockedValueBox(State())

    func run<T: Sendable>(_ key: Key, _ operation: () async throws -> T) async throws -> T {
        let id = UUID()
        try await wait(for: id, key: key)
        defer { release(id, key: key) }
        return try await operation()
    }

    private func wait(for id: UUID, key: Key) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let admitted: Result<Bool, any Error> = state.withLockedValue { state in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    state.queues[key, default: []].append(id)
                    if state.queues[key]?.first == id { return .success(true) }
                    state.waiters[id] = continuation
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
                    return waiter
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
            return state.waiters.removeValue(forKey: head)
        }
        next?.resume()
    }
}
