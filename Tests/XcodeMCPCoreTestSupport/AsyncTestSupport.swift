import Foundation
import NIOConcurrencyHelpers
import Testing
import XcodeMCPKit

/// Runs synchronous `defer`-registered test cleanup without blocking the
/// cooperative executor that must make the cleanup operation progress.
package struct AsyncTestCleanupTrait: SuiteTrait, TestTrait, TestScoping {
    package let isRecursive = true

    package init() {}

    package func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let context = AsyncTestCleanupContext()
        do {
            try await AsyncTestCleanupContext.$current.withValue(context) {
                try await function()
            }
        } catch {
            // A fresh task shields cleanup from cancellation of the test body.
            await Task { await context.run() }.value
            throw error
        }
        await Task { await context.run() }.value
    }
}

extension Trait where Self == AsyncTestCleanupTrait {
    package static var asyncTestCleanup: Self { Self() }
}

private final class AsyncTestCleanupContext: @unchecked Sendable {
    private struct Entry: Sendable {
        let description: String
        let operation: @Sendable () async throws -> Void
    }

    private struct State: Sendable {
        var entries: [Entry] = []
        var hasStarted = false
    }

    @TaskLocal static var current: AsyncTestCleanupContext?

    private let state = NIOLockedValueBox(State())

    func register(
        description: String,
        operation: @escaping @Sendable () async throws -> Void
    ) -> Bool {
        state.withLockedValue { state in
            guard state.hasStarted == false else {
                return false
            }
            state.entries.append(Entry(description: description, operation: operation))
            return true
        }
    }

    func run() async {
        let entries = state.withLockedValue { state -> [Entry] in
            precondition(state.hasStarted == false, "async test cleanup may only run once")
            state.hasStarted = true
            let entries = state.entries
            state.entries.removeAll()
            return entries
        }

        // `defer` blocks register while unwinding, so their LIFO order is already
        // represented by insertion order (for example: manager, then its event loop).
        for entry in entries {
            do {
                try await entry.operation()
            } catch {
                Issue.record("\(entry.description): \(error)")
            }
        }
    }
}

/// Registers cleanup with the active ``AsyncTestCleanupTrait`` scope.
@discardableResult
package func registerAsyncTestCleanup(
    description: String,
    operation: @escaping @Sendable () async throws -> Void
) -> Bool {
    guard let context = AsyncTestCleanupContext.current else {
        return false
    }
    guard context.register(description: description, operation: operation) else {
        Issue.record("async test cleanup registered after cleanup started: \(description)")
        return true
    }
    return true
}

/// Registers terminal client cleanup with the active test scope.
package func closeAfterTest(_ client: XcodeMCP) {
    precondition(
        registerAsyncTestCleanup(
            description: "XcodeMCP client close failed",
            operation: { await client.close() }
        ),
        "closeAfterTest requires an AsyncTestCleanupTrait scope"
    )
}

/// Registers terminal session cleanup with the active test scope.
package func closeAfterTest(_ session: InitializedMCPClientSession) {
    precondition(
        registerAsyncTestCleanup(
            description: "initialized MCP session close failed",
            operation: { await session.close() }
        ),
        "closeAfterTest requires an AsyncTestCleanupTrait scope"
    )
}

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

package enum TestResourceGate {
    private static let processHeavyStdioAdapterGate = AsyncResourceGate()

    package static func withProcessHeavyStdioAdapterAccess<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try await processHeavyStdioAdapterGate.withAccess(operation)
    }

}

private final class AsyncResourceGate: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var isAvailable = true
        var waiters: [Waiter] = []
    }

    private let state = NIOLockedValueBox(State())

    func withAccess<T>(_ operation: () async throws -> T) async throws -> T {
        try await acquire()
        defer {
            release()
        }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldResume = state.withLockedValue { state -> Bool in
                    if state.isAvailable {
                        state.isAvailable = false
                        return true
                    }
                    state.waiters.append(Waiter(id: waiterID, continuation: continuation))
                    return false
                }
                if shouldResume {
                    continuation.resume(returning: ())
                }
            }
        } onCancel: {
            self.cancelWaiter(id: waiterID)
        }
    }

    private func release() {
        let waiter = state.withLockedValue { state -> Waiter? in
            guard !state.waiters.isEmpty else {
                state.isAvailable = true
                return nil
            }
            return state.waiters.removeFirst()
        }
        waiter?.continuation.resume(returning: ())
    }

    private func cancelWaiter(id: UUID) {
        let waiter = state.withLockedValue { state -> Waiter? in
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return state.waiters.remove(at: index)
        }
        waiter?.continuation.resume(throwing: CancellationError())
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

package func waitForSuspendedSleepers(
    on clock: TestClock,
    count: Int = 1,
    timeout: Duration = .seconds(5)
) async throws {
    try await waitWithTimeout(
        "timed out waiting for \(count) suspended test clock sleeper(s)",
        timeout: timeout
    ) {
        try await clock.sleep(untilSuspendedBy: count)
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

    private struct DeadlineSuspensionWaiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now: Instant
        var sleepers: [UInt64: SleepWaiter] = [:]
        var nextSleepToken: UInt64 = 0
        var suspensionWaiters: [UInt64: SuspensionWaiter] = [:]
        var nextSuspensionToken: UInt64 = 0
        var deadlineSuspensionWaiters: [UInt64: DeadlineSuspensionWaiter] = [:]
        var nextDeadlineSuspensionToken: UInt64 = 0
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
                var shouldResume = false
                let continuations = state.withLockedValue { state -> [CheckedContinuation<Void, Error>] in
                    guard deadline > state.now else {
                        shouldResume = true
                        return []
                    }
                    guard Task.isCancelled == false else {
                        shouldCancel = true
                        return []
                    }
                    state.sleepers[token] = SleepWaiter(deadline: deadline, continuation: continuation)
                    return Self.resumeReadySuspensionWaiters(state: &state)
                        + Self.resumeReadyDeadlineSuspensionWaiters(state: &state)
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if shouldResume {
                    continuation.resume(returning: ())
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

    package func sleep(
        untilSuspendedFor duration: Duration,
        timeout: Duration = .seconds(5),
        onWaiterRegistered: @escaping @Sendable () -> Void = {}
    ) async throws {
        let deadline = now.advanced(by: duration)
        try await waitWithTimeout(
            "timed out waiting for a fake clock sleeper with duration \(duration)",
            timeout: timeout
        ) {
            try await self.waitUntilSuspended(
                at: deadline,
                onWaiterRegistered: onWaiterRegistered
            )
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

    private func waitUntilSuspended(
        at deadline: Instant,
        onWaiterRegistered: @escaping @Sendable () -> Void
    ) async throws {
        let token = state.withLockedValue { state -> UInt64? in
            guard state.sleepers.values.contains(where: { $0.deadline == deadline }) == false else {
                return nil
            }
            let token = state.nextDeadlineSuspensionToken
            state.nextDeadlineSuspensionToken &+= 1
            return token
        }

        guard let token else {
            onWaiterRegistered()
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var shouldCancel = false
                let shouldResume = state.withLockedValue { state in
                    if state.sleepers.values.contains(where: { $0.deadline == deadline }) {
                        return true
                    }
                    guard Task.isCancelled == false else {
                        shouldCancel = true
                        return false
                    }
                    state.deadlineSuspensionWaiters[token] = DeadlineSuspensionWaiter(
                        deadline: deadline,
                        continuation: continuation
                    )
                    return false
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                } else {
                    onWaiterRegistered()
                    if shouldResume {
                        continuation.resume(returning: ())
                    }
                }
            }
        } onCancel: {
            let waiter = state.withLockedValue { state in
                state.deadlineSuspensionWaiters.removeValue(forKey: token)
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

    private static func resumeReadyDeadlineSuspensionWaiters(
        state: inout State
    ) -> [CheckedContinuation<Void, Error>] {
        let readyTokens = state.deadlineSuspensionWaiters.compactMap { token, waiter in
            state.sleepers.values.contains(where: { $0.deadline == waiter.deadline }) ? token : nil
        }
        return readyTokens.compactMap {
            state.deadlineSuspensionWaiters.removeValue(forKey: $0)?.continuation
        }
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
