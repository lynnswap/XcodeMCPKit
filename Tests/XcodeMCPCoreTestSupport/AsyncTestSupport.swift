import Foundation
import NIOConcurrencyHelpers
import XcodeMCPKit

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

    package func count() -> Int {
        values.count
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
    let race = TimeoutRace<T>()
    let clock = ContinuousClock()
    let operationTask = Task {
        do {
            race.complete(.success(try await operation()))
        } catch {
            race.complete(.failure(error))
        }
    }
    let timeoutTask = Task {
        do {
            try await clock.sleep(until: clock.now.advanced(by: timeout))
            race.complete(.failure(AsyncTestTimeoutError(description: description)))
        } catch {
            return
        }
    }

    return try await withTaskCancellationHandler {
        defer {
            operationTask.cancel()
            timeoutTask.cancel()
        }
        return try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
        }
    } onCancel: {
        operationTask.cancel()
        timeoutTask.cancel()
        race.complete(.failure(CancellationError()))
    }
}

private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var result: Result<T, Error>?
    }

    private let state = NIOLockedValueBox(State())

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let result = state.withLockedValue { state -> Result<T, Error>? in
            guard let result = state.result else {
                state.continuation = continuation
                return nil
            }
            return result
        }
        if let result {
            continuation.resume(with: result)
        }
    }

    func complete(_ result: Result<T, Error>) {
        let continuation = state.withLockedValue { state -> CheckedContinuation<T, Error>? in
            guard state.result == nil else {
                return nil
            }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
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
        let continuation: CheckedContinuation<Void, Error>
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
                var shouldCancel = false
                let continuations = state.withLockedValue { state -> [CheckedContinuation<Void, Error>] in
                    guard Task.isCancelled == false else {
                        shouldCancel = true
                        return []
                    }
                    state.sleepers[token] = SleepWaiter(deadline: deadline, continuation: continuation)
                    return Self.resumeReadySuspensionWaiters(state: &state)
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                for continuation in continuations {
                    continuation.resume(returning: ())
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

    package func sleep(
        untilSuspendedBy minimumSleepers: Int,
        timeout: Duration = .seconds(5),
        description: String? = nil
    ) async throws {
        let description = description
            ?? "timed out waiting for \(minimumSleepers) suspended fake clock sleeper(s)"
        try await waitWithTimeout(description, timeout: timeout) {
            try await self.waitUntilSuspendedBy(minimumSleepers)
        }
    }

    private func waitUntilSuspendedBy(_ minimumSleepers: Int) async throws {
        guard minimumSleepers > 0 else {
            return
        }

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

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var shouldCancel = false
                let shouldResume = state.withLockedValue { state in
                    if state.sleepers.count >= minimumSleepers {
                        return true
                    }
                    guard Task.isCancelled == false else {
                        shouldCancel = true
                        return false
                    }
                    state.suspensionWaiters[token] = SuspensionWaiter(
                        minimumSleepers: minimumSleepers,
                        continuation: continuation
                    )
                    return false
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                } else if shouldResume {
                    continuation.resume(returning: ())
                }
            }
        } onCancel: {
            let waiter = state.withLockedValue { state in
                state.suspensionWaiters.removeValue(forKey: token)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    private static func resumeReadySuspensionWaiters(
        state: inout State
    ) -> [CheckedContinuation<Void, Error>] {
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
