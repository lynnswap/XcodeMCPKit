import Foundation

final class DeterministicRecorder<Value: Sendable>: @unchecked Sendable {
    private struct IndexedWaiter {
        let id: UUID
        let index: Int
        let continuation: CheckedContinuation<Value, Never>
    }

    private struct MatchingWaiter {
        let id: UUID
        let startingAt: Int
        let predicate: @Sendable (Value) -> Bool
        let continuation: CheckedContinuation<Value, Never>
    }

    private let lock = NSLock()
    private var values: [Value] = []
    private var indexedWaiters: [IndexedWaiter] = []
    private var matchingWaiters: [MatchingWaiter] = []

    func record(_ value: Value) {
        let resumes = lock.withLock { () -> (indexed: [CheckedContinuation<Value, Never>], matching: [CheckedContinuation<Value, Never>]) in
            let index = values.count
            values.append(value)

            var indexedResumes: [CheckedContinuation<Value, Never>] = []
            indexedWaiters.removeAll { waiter in
                guard waiter.index <= index else {
                    return false
                }
                indexedResumes.append(waiter.continuation)
                return true
            }

            var matchingResumes: [CheckedContinuation<Value, Never>] = []
            matchingWaiters.removeAll { waiter in
                guard index >= waiter.startingAt, waiter.predicate(value) else {
                    return false
                }
                matchingResumes.append(waiter.continuation)
                return true
            }

            return (indexedResumes, matchingResumes)
        }

        for continuation in resumes.indexed {
            continuation.resume(returning: value)
        }
        for continuation in resumes.matching {
            continuation.resume(returning: value)
        }
    }

    func nextValue(at index: Int) async -> Value {
        if let existing = value(at: index) {
            return existing
        }

        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            let existing = lock.withLock { () -> Value? in
                if values.indices.contains(index) {
                    return values[index]
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
            }
        }
    }

    func nextValue(
        startingAt startIndex: Int = 0,
        matching predicate: @escaping @Sendable (Value) -> Bool
    ) async -> Value {
        if let existing = firstValue(startingAt: startIndex, matching: predicate) {
            return existing
        }

        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            let existing = lock.withLock { () -> Value? in
                if let existing = firstValueLocked(startingAt: startIndex, matching: predicate) {
                    return existing
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
            }
        }
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
