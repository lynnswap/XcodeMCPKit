import Foundation
import NIOConcurrencyHelpers

/// A limit on the size of waiting requests, shared by every queue that reserves from it.
final class NativeBrokerByteBudget: Sendable {
    private let limit: Int
    private let reserved = NIOLockedValueBox(0)

    init(limit: Int) {
        self.limit = limit
    }

    var reservedBytes: Int { reserved.withLockedValue { $0 } }

    func reserve(_ bytes: Int) -> Bool {
        reserved.withLockedValue { reserved in
            guard bytes <= limit - reserved else { return false }
            reserved += bytes
            return true
        }
    }

    func release(_ bytes: Int) {
        reserved.withLockedValue { $0 -= bytes }
    }
}

/// Runs one operation at a time for each key, in arrival order.
final class NativeBrokerTurns<Key: Hashable & Sendable>: Sendable {
    /// The waiting operations' requests would exceed their budget.
    struct Full: Error {}

    private struct Waiter {
        let continuation: CheckedContinuation<Void, any Error>
        let bytes: Int
        let budget: NativeBrokerByteBudget
    }

    private struct State {
        var queues: [Key: [UUID]] = [:]
        var waiters: [UUID: Waiter] = [:]
        /// Turns cancelled before they joined their queue.
        var cancelled: Set<UUID> = []
    }

    private let state = NIOLockedValueBox(State())

    /// Runs `operation` after the earlier operations for `key`. While it waits, its request's
    /// `bytes` count against `budget`; an operation that would exceed it fails with ``Full``.
    func run<T: Sendable>(_ key: Key, bytes: Int, budget: NativeBrokerByteBudget,
                          _ operation: () async throws -> T) async throws -> T {
        let id = UUID()
        try await wait(for: id, key: key, bytes: bytes, budget: budget)
        defer { release(id, key: key) }
        return try await operation()
    }

    private func wait(for id: UUID, key: Key, bytes: Int, budget: NativeBrokerByteBudget) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let admitted: Result<Bool, any Error> = state.withLockedValue { state in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if state.queues[key]?.isEmpty ?? true {
                        state.queues[key] = [id]
                        return .success(true)
                    }
                    guard budget.reserve(bytes) else { return .failure(Full()) }
                    state.queues[key]?.append(id)
                    state.waiters[id] = Waiter(continuation: continuation, bytes: bytes, budget: budget)
                    return .success(false)
                }
                switch admitted {
                case .success(true): continuation.resume()
                case .success(false): break
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            let waiter = state.withLockedValue { state -> Waiter? in
                if let waiter = state.waiters.removeValue(forKey: id) {
                    state.queues[key]?.removeAll { $0 == id }
                    return waiter
                }
                // A turn that already runs observes cancellation itself.
                if state.queues[key]?.contains(id) != true { state.cancelled.insert(id) }
                return nil
            }
            guard let waiter else { return }
            waiter.budget.release(waiter.bytes)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func release(_ id: UUID, key: Key) {
        let next = state.withLockedValue { state -> Waiter? in
            state.queues[key]?.removeAll { $0 == id }
            guard let head = state.queues[key]?.first else {
                state.queues[key] = nil
                return nil
            }
            return state.waiters.removeValue(forKey: head)
        }
        guard let next else { return }
        next.budget.release(next.bytes)
        next.continuation.resume()
    }
}
