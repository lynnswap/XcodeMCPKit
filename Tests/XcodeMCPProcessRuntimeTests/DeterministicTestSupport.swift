import Foundation
import XcodeMCPCoreTestSupport

final class DeterministicRecorder<Value: Sendable>: @unchecked Sendable {
    private struct IndexedWaiter {
        let id: UUID
        let index: Int
        let continuation: CheckedContinuation<Value, Error>
    }

    private struct MatchingWaiter {
        let id: UUID
        let startingAt: Int
        let predicate: @Sendable (Value) -> Bool
        let continuation: CheckedContinuation<Value, Error>
    }

    private let lock = NSLock()
    private var values: [Value] = []
    private var indexedWaiters: [IndexedWaiter] = []
    private var matchingWaiters: [MatchingWaiter] = []

    func record(_ value: Value) {
        let resumes = lock.withLock { () -> (
            indexed: [(CheckedContinuation<Value, Error>, Value)],
            matching: [(CheckedContinuation<Value, Error>, Value)]
        ) in
            let index = values.count
            values.append(value)

            var indexedResumes: [(CheckedContinuation<Value, Error>, Value)] = []
            indexedWaiters.removeAll { waiter in
                guard waiter.index <= index else {
                    return false
                }
                indexedResumes.append((waiter.continuation, values[waiter.index]))
                return true
            }

            var matchingResumes: [(CheckedContinuation<Value, Error>, Value)] = []
            matchingWaiters.removeAll { waiter in
                guard index >= waiter.startingAt, waiter.predicate(value) else {
                    return false
                }
                matchingResumes.append((waiter.continuation, value))
                return true
            }

            return (indexedResumes, matchingResumes)
        }

        for (continuation, value) in resumes.indexed {
            continuation.resume(returning: value)
        }
        for (continuation, value) in resumes.matching {
            continuation.resume(returning: value)
        }
    }

    func nextValue(
        at index: Int,
        timeout: Duration = .seconds(2)
    ) async throws -> Value {
        try await waitWithTimeout(
            "timed out waiting for recorded value at index \(index)",
            timeout: timeout
        ) {
            try await self.waitForValue(at: index)
        }
    }

    private func waitForValue(at index: Int) async throws -> Value {
        if let existing = value(at: index) {
            return existing
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var shouldCancel = false
                let existing = lock.withLock { () -> Value? in
                    if values.indices.contains(index) {
                        return values[index]
                    }
                    guard Task.isCancelled == false else {
                        shouldCancel = true
                        return nil
                    }
                    indexedWaiters.append(
                        IndexedWaiter(
                            id: waiterID,
                            index: index,
                            continuation: continuation
                        )
                    )
                    return nil
                }
                if let existing {
                    continuation.resume(returning: existing)
                } else if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancelIndexedWaiter(id: waiterID)
        }
    }

    func nextValue(
        startingAt startIndex: Int = 0,
        timeout: Duration = .seconds(2),
        matching predicate: @escaping @Sendable (Value) -> Bool = { _ in true }
    ) async throws -> Value {
        try await waitWithTimeout(
            "timed out waiting for matching recorded value",
            timeout: timeout
        ) {
            try await self.waitForValue(startingAt: startIndex, matching: predicate)
        }
    }

    private func waitForValue(
        startingAt startIndex: Int,
        matching predicate: @escaping @Sendable (Value) -> Bool
    ) async throws -> Value {
        if let existing = firstValue(startingAt: startIndex, matching: predicate) {
            return existing
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var shouldCancel = false
                let existing = lock.withLock { () -> Value? in
                    if let existing = firstValueLocked(startingAt: startIndex, matching: predicate) {
                        return existing
                    }
                    guard Task.isCancelled == false else {
                        shouldCancel = true
                        return nil
                    }
                    matchingWaiters.append(
                        MatchingWaiter(
                            id: waiterID,
                            startingAt: startIndex,
                            predicate: predicate,
                            continuation: continuation
                        )
                    )
                    return nil
                }
                if let existing {
                    continuation.resume(returning: existing)
                } else if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancelMatchingWaiter(id: waiterID)
        }
    }

    private func cancelIndexedWaiter(id: UUID) {
        let waiter = lock.withLock { () -> IndexedWaiter? in
            guard let index = indexedWaiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return indexedWaiters.remove(at: index)
        }
        waiter?.continuation.resume(throwing: CancellationError())
    }

    private func cancelMatchingWaiter(id: UUID) {
        let waiter = lock.withLock { () -> MatchingWaiter? in
            guard let index = matchingWaiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return matchingWaiters.remove(at: index)
        }
        waiter?.continuation.resume(throwing: CancellationError())
    }

    func snapshot() -> [Value] {
        lock.withLock { values }
    }

    private func value(at index: Int) -> Value? {
        lock.withLock {
            guard values.indices.contains(index) else {
                return nil
            }
            return values[index]
        }
    }

    private func firstValue(
        startingAt startIndex: Int,
        matching predicate: @Sendable (Value) -> Bool
    ) -> Value? {
        lock.withLock {
            firstValueLocked(startingAt: startIndex, matching: predicate)
        }
    }

    private func firstValueLocked(
        startingAt startIndex: Int,
        matching predicate: @Sendable (Value) -> Bool
    ) -> Value? {
        guard startIndex < values.count else {
            return nil
        }
        for index in startIndex..<values.count where predicate(values[index]) {
            return values[index]
        }
        return nil
    }
}
