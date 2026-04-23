import Dispatch
import Foundation
import NIO
import NIOConcurrencyHelpers

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

    private var values: [Value] = []
    private var waiters: [Waiter] = []

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
                waiters.append(Waiter(id: waiterID, index: index, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
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

package func waitUntil(
    timeout: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(10),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        if Task.isCancelled {
            return false
        }
        if await condition() {
            return true
        }
        try? await clock.sleep(until: clock.now.advanced(by: pollInterval))
    }

    return await condition()
}

package func spinUntil(
    _ description: String = "condition was not satisfied",
    maxIterations: Int = 200,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<maxIterations {
        if await condition() {
            return
        }
        await Task.yield()
    }
    throw AsyncTestTimeoutError(description: description)
}

package func waitUntilCount(
    _ expectedCount: Int,
    count: @escaping @Sendable () async -> Int,
    timeout: Duration = .seconds(5)
) async -> Bool {
    await waitUntil(timeout: timeout) {
        await count() >= expectedCount
    }
}

package func nextValue<Value: Sendable>(
    _ description: String,
    timeout: Duration = .seconds(5),
    value: @escaping @Sendable () async throws -> Value?
) async throws -> Value {
    try await waitWithTimeout(description, timeout: timeout) {
        while true {
            try Task.checkCancellation()
            if let next = try await value() {
                return next
            }
            await Task.yield()
        }
    }
}

package func staysTrue(
    for duration: Duration,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)

    while clock.now < deadline {
        if Task.isCancelled {
            return false
        }
        guard await condition() else {
            return false
        }
        await Task.yield()
    }

    return await condition()
}

package func shutdown(_ group: EventLoopGroup) async {
    await withCheckedContinuation { continuation in
        group.shutdownGracefully { _ in
            continuation.resume()
        }
    }
}

package func shutdownAndWait(_ group: EventLoopGroup) {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
        await shutdown(group)
        semaphore.signal()
    }
    semaphore.wait()
}

package func makeTestURLSession(
    timeout: TimeInterval = 5,
    waitsForConnectivity: Bool = false
) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = waitsForConnectivity
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.httpShouldUsePipelining = false
    configuration.httpMaximumConnectionsPerHost = 20
    return URLSession(configuration: configuration)
}

package func withTestURLSession<T>(
    timeout: TimeInterval = 5,
    waitsForConnectivity: Bool = false,
    operation: (URLSession) async throws -> T
) async throws -> T {
    let session = makeTestURLSession(
        timeout: timeout,
        waitsForConnectivity: waitsForConnectivity
    )
    defer {
        session.invalidateAndCancel()
    }

    return try await operation(session)
}

package final class HTTPTestServerChannelTracker: @unchecked Sendable {
    private let channels = NIOLockedValueBox([ObjectIdentifier: Channel]())

    package init() {}

    package func register(_ channel: Channel) {
        let id = ObjectIdentifier(channel)
        channels.withLockedValue { $0[id] = channel }
        channel.closeFuture.whenComplete { [weak self] _ in
            _ = self?.channels.withLockedValue { $0.removeValue(forKey: id) }
        }
    }

    package func snapshot() -> [Channel] {
        channels.withLockedValue { Array($0.values) }
    }
}

package final class HTTPTestServerAcceptedChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    package typealias InboundIn = Channel

    private let tracker: HTTPTestServerChannelTracker

    package init(tracker: HTTPTestServerChannelTracker) {
        self.tracker = tracker
    }

    package func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channel = unwrapInboundIn(data)
        tracker.register(channel)
        context.fireChannelRead(data)
    }
}

package func shutdownHTTPTestServer(
    listenChannel: Channel,
    childChannelTracker: HTTPTestServerChannelTracker,
    group: EventLoopGroup,
    timeout: Duration = .seconds(5),
    beforeClose: @escaping () -> Void = {}
) async throws {
    beforeClose()

    var shutdownError: Error?

    do {
        let listenerCloseFuture = listenChannel.closeFuture
        listenChannel.close(mode: .all, promise: nil)

        try await waitWithTimeout(
            "timed out waiting for HTTP test server listener to close",
            timeout: timeout
        ) {
            try await listenerCloseFuture.get()
        }
        try await waitWithTimeout(
            "timed out waiting for HTTP test server accept loop to drain",
            timeout: timeout
        ) {
            try await listenChannel.eventLoop.submit { () }.get()
        }

        while true {
            let childChannels = childChannelTracker.snapshot()
            guard !childChannels.isEmpty else { break }

            let childCloseFutures = childChannels.map(\.closeFuture)
            for channel in childChannels {
                channel.close(mode: .all, promise: nil)
            }

            try await waitWithTimeout(
                "timed out waiting for HTTP test server channels to close",
                timeout: timeout
            ) {
                try await EventLoopFuture.andAllSucceed(childCloseFutures, on: listenChannel.eventLoop).get()
            }
        }
    } catch {
        shutdownError = error
    }

    await shutdown(group)

    if let shutdownError {
        throw shutdownError
    }
}

package final class TestSignal: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var signaled = false
        var waiters: [Waiter] = []
    }

    private let state = NIOLockedValueBox(State())

    package init() {}

    package func wait(
        timeout: Duration = .seconds(2),
        description: String
    ) async throws {
        if state.withLockedValue({ $0.signaled }) {
            return
        }

        let waiterID = UUID()
        try await waitWithTimeout(description, timeout: timeout) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    let shouldResume = self.state.withLockedValue { state in
                        if state.signaled {
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
    }

    package func signal() {
        let waiters = state.withLockedValue { state -> [Waiter] in
            guard state.signaled == false else {
                return []
            }
            state.signaled = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }

        for waiter in waiters {
            waiter.continuation.resume(returning: ())
        }
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

package final class TestUptimeClock: @unchecked Sendable {
    private let value: NIOLockedValueBox<UInt64>

    package init(nowUptimeNanoseconds: UInt64 = 0) {
        self.value = NIOLockedValueBox(nowUptimeNanoseconds)
    }

    package func now() -> UInt64 {
        value.withLockedValue { $0 }
    }

    package func advance(by duration: Duration) {
        let delta = durationToNanoseconds(duration)
        value.withLockedValue { current in
            current &+= delta
        }
    }
}

private func durationToNanoseconds(_ duration: Duration) -> UInt64 {
    let components = duration.components
    let seconds = max(0, components.seconds)
    let attoseconds = max(0, components.attoseconds)
    let secondsComponent = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
    if secondsComponent.overflow {
        return UInt64.max
    }

    let attosecondsComponent = UInt64(attoseconds / 1_000_000_000)
    let total = secondsComponent.partialValue.addingReportingOverflow(attosecondsComponent)
    return total.overflow ? UInt64.max : total.partialValue
}
