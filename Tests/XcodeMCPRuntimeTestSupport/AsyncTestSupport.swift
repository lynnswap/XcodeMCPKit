import Foundation
import NIOConcurrencyHelpers
import XcodeMCPRuntime

package struct AsyncTestTimeoutError: Error, CustomStringConvertible {
    package let description: String

    package init(description: String) {
        self.description = description
    }
}

package actor RecordedValues<Value: Sendable> {
    private struct Waiter {
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

    private var values: [Value] = []
    private var waiters: [Waiter] = []
    private var matchingWaiters: [MatchingWaiter] = []

    package init() {}

    package func append(_ value: Value) {
        let index = values.count
        values.append(value)

        var remaining: [Waiter] = []
        for waiter in waiters {
            if waiter.index == index {
                waiter.continuation.resume(returning: value)
            } else if values.indices.contains(waiter.index) {
                waiter.continuation.resume(returning: values[waiter.index])
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining

        var remainingMatchingWaiters: [MatchingWaiter] = []
        for waiter in matchingWaiters {
            if index >= waiter.startingAt, waiter.predicate(value) {
                waiter.continuation.resume(returning: value)
            } else {
                remainingMatchingWaiters.append(waiter)
            }
        }
        matchingWaiters = remainingMatchingWaiters
    }

    package func snapshot() -> [Value] {
        values
    }

    package func value(at index: Int) -> Value? {
        guard values.indices.contains(index) else {
            return nil
        }
        return values[index]
    }

    package func nextValue(at index: Int) async throws -> Value {
        if let existing = value(at: index) {
            return existing
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let existing = value(at: index) {
                    continuation.resume(returning: existing)
                    return
                }
                waiters.append(Waiter(id: waiterID, index: index, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    package func nextValue(
        startingAt startIndex: Int = 0,
        matching predicate: @escaping @Sendable (Value) -> Bool
    ) async throws -> Value {
        let startIndex = max(startIndex, 0)
        if let existing = firstValue(startingAt: startIndex, matching: predicate) {
            return existing
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let existing = firstValue(startingAt: startIndex, matching: predicate) {
                    continuation.resume(returning: existing)
                    return
                }
                matchingWaiters.append(
                    MatchingWaiter(
                        id: waiterID,
                        startingAt: startIndex,
                        predicate: predicate,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { await self.cancelMatchingWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelMatchingWaiter(id: UUID) {
        guard let index = matchingWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = matchingWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func firstValue(
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

@discardableResult
package func waitWithTimeout<T: Sendable>(
    _ description: String = "timed out waiting for async operation",
    timeout: Duration = .seconds(5),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let clock = ContinuousClock()

    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await clock.sleep(until: clock.now.advanced(by: timeout))
            throw AsyncTestTimeoutError(description: description)
        }

        guard let result = try await group.next() else {
            throw AsyncTestTimeoutError(description: description)
        }

        group.cancelAll()
        return result
    }
}

package final class TestClock: Clock, @unchecked Sendable {
    package typealias Instant = ContinuousClock.Instant
    package typealias Duration = Swift.Duration

    private struct SleepWaiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct SuspensionWaiter {
        let minimumSleepers: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now: Instant
        var sleepers: [UInt64: SleepWaiter] = [:]
        var nextSleepToken: UInt64 = 0
        var suspensionWaiters: [UInt64: SuspensionWaiter] = [:]
        var nextSuspensionToken: UInt64 = 0
    }

    private let state: NIOLockedValueBox<State>

    package init(now: Instant = ContinuousClock().now) {
        self.state = NIOLockedValueBox(State(now: now))
    }

    package var now: Instant {
        state.withLockedValue { $0.now }
    }

    package var minimumResolution: Duration {
        .zero
    }

    package func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        _ = tolerance
        let token = state.withLockedValue { state -> UInt64? in
            guard deadline > state.now else {
                return nil
            }
            let token = state.nextSleepToken
            state.nextSleepToken &+= 1
            return token
        }

        guard let token else {
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let continuations = state.withLockedValue { state -> [CheckedContinuation<Void, Never>] in
                    state.sleepers[token] = SleepWaiter(deadline: deadline, continuation: continuation)
                    return Self.resumeReadySuspensionWaiters(state: &state)
                }
                for continuation in continuations {
                    continuation.resume()
                }
            }
        } onCancel: {
            let waiter = state.withLockedValue { state in
                state.sleepers.removeValue(forKey: token)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    package func advance(by duration: Duration) {
        let continuations = state.withLockedValue { state -> [CheckedContinuation<Void, Error>] in
            state.now = state.now.advanced(by: duration)
            let readyTokens = state.sleepers.compactMap { token, waiter in
                waiter.deadline <= state.now ? token : nil
            }
            let readyWaiters = readyTokens.compactMap { state.sleepers.removeValue(forKey: $0) }
            return readyWaiters.map(\.continuation)
        }

        for continuation in continuations {
            continuation.resume()
        }
    }

    package func sleep(untilSuspendedBy minimumSleepers: Int) async {
        let token = state.withLockedValue { state -> UInt64? in
            guard state.sleepers.count < minimumSleepers else {
                return nil
            }
            let token = state.nextSuspensionToken
            state.nextSuspensionToken &+= 1
            return token
        }

        guard let token else {
            return
        }

        await withCheckedContinuation { continuation in
            let shouldResume = state.withLockedValue { state in
                if state.sleepers.count >= minimumSleepers {
                    return true
                }
                state.suspensionWaiters[token] = SuspensionWaiter(
                    minimumSleepers: minimumSleepers,
                    continuation: continuation
                )
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private static func resumeReadySuspensionWaiters(
        state: inout State
    ) -> [CheckedContinuation<Void, Never>] {
        let readyTokens = state.suspensionWaiters.compactMap { token, waiter in
            state.sleepers.count >= waiter.minimumSleepers ? token : nil
        }
        return readyTokens.compactMap { state.suspensionWaiters.removeValue(forKey: $0)?.continuation }
    }
}

package func makeTestClockClient(_ clock: TestClock) -> ClockClient {
    ClockClient(
        now: { Date(timeIntervalSince1970: 0) },
        uptimeNanoseconds: { 0 },
        sleep: { duration in
            try? await clock.sleep(for: duration)
        },
        sleepForTimeInterval: { _ in }
    )
}
