import Dispatch
import Foundation
import NIO
import NIOConcurrencyHelpers
import Testing
import XcodeMCPCoreTestSupport

package typealias AsyncTestTimeoutError = XcodeMCPCoreTestSupport.AsyncTestTimeoutError
package typealias RecordedValues<Value: Sendable> = XcodeMCPCoreTestSupport.RecordedValues<Value>
package typealias TestResourceGate = XcodeMCPCoreTestSupport.TestResourceGate
package typealias TestClock = XcodeMCPCoreTestSupport.TestClock

package final class LockedRecordedValues<Value: Sendable>: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let index: Int
        let continuation: CheckedContinuation<Value, Error>
    }

    private struct State {
        var values: [Value] = []
        var waiters: [Waiter] = []
    }

    private let state = NIOLockedValueBox(State())

    package init() {}

    package func append(_ value: Value) {
        let waitersToResume = state.withLockedValue { state -> [(Waiter, Value)] in
            state.values.append(value)

            var remaining: [Waiter] = []
            var resumptions: [(Waiter, Value)] = []
            for waiter in state.waiters {
                if state.values.indices.contains(waiter.index) {
                    resumptions.append((waiter, state.values[waiter.index]))
                } else {
                    remaining.append(waiter)
                }
            }
            state.waiters = remaining
            return resumptions
        }

        for (waiter, value) in waitersToResume {
            waiter.continuation.resume(returning: value)
        }
    }

    package func count() -> Int {
        state.withLockedValue { $0.values.count }
    }

    private func value(at index: Int) -> Value? {
        state.withLockedValue { state in
            guard state.values.indices.contains(index) else {
                return nil
            }
            return state.values[index]
        }
    }

    package func nextValue(at index: Int) async throws -> Value {
        if let existing = value(at: index) {
            return existing
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let existing = state.withLockedValue { state -> Value? in
                    if state.values.indices.contains(index) {
                        return state.values[index]
                    }
                    state.waiters.append(
                        Waiter(id: waiterID, index: index, continuation: continuation)
                    )
                    return nil
                }
                if let existing {
                    continuation.resume(returning: existing)
                }
            }
        } onCancel: {
            self.cancelWaiter(id: waiterID)
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

package actor OperationGate<Key: Hashable & Sendable> {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct SuspensionWaiter {
        let id: UUID
        let key: Key
        let minimumWaiters: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waitersByKey: [Key: [Waiter]] = [:]
    private var releaseCreditsByKey: [Key: Int] = [:]
    private var suspensionWaiters: [SuspensionWaiter] = []

    package init() {}

    package func wait(for key: Key) async throws {
        if consumeReleaseCredit(for: key) {
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if consumeReleaseCredit(for: key) {
                    continuation.resume(returning: ())
                    return
                }
                waitersByKey[key, default: []].append(
                    Waiter(id: waiterID, continuation: continuation)
                )
                resumeReadySuspensionWaiters()
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID, key: key)
            }
        }
    }

    package func waitUntilWaiting(for key: Key, count minimumWaiters: Int) async throws {
        guard waitingCount(for: key) < minimumWaiters else {
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if waitingCount(for: key) >= minimumWaiters {
                    continuation.resume(returning: ())
                    return
                }
                suspensionWaiters.append(
                    SuspensionWaiter(
                        id: waiterID,
                        key: key,
                        minimumWaiters: minimumWaiters,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task {
                await self.cancelSuspensionWaiter(id: waiterID)
            }
        }
    }

    package func release(_ key: Key, count: Int = 1) {
        guard count > 0 else {
            return
        }

        var resumptions: [CheckedContinuation<Void, Error>] = []
        var remainingReleaseCount = count
        while remainingReleaseCount > 0 {
            guard var waiters = waitersByKey[key], waiters.isEmpty == false else {
                releaseCreditsByKey[key, default: 0] += remainingReleaseCount
                break
            }
            let waiter = waiters.removeFirst()
            if waiters.isEmpty {
                waitersByKey.removeValue(forKey: key)
            } else {
                waitersByKey[key] = waiters
            }
            resumptions.append(waiter.continuation)
            remainingReleaseCount -= 1
        }

        for continuation in resumptions {
            continuation.resume(returning: ())
        }
    }

    private func waitingCount(for key: Key) -> Int {
        waitersByKey[key]?.count ?? 0
    }

    private func consumeReleaseCredit(for key: Key) -> Bool {
        guard let credits = releaseCreditsByKey[key], credits > 0 else {
            return false
        }
        if credits == 1 {
            releaseCreditsByKey.removeValue(forKey: key)
        } else {
            releaseCreditsByKey[key] = credits - 1
        }
        return true
    }

    private func cancelWaiter(id: UUID, key: Key) {
        guard var waiters = waitersByKey[key],
              let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            waitersByKey.removeValue(forKey: key)
        } else {
            waitersByKey[key] = waiters
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelSuspensionWaiter(id: UUID) {
        guard let index = suspensionWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = suspensionWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeReadySuspensionWaiters() {
        var ready: [SuspensionWaiter] = []
        var remaining: [SuspensionWaiter] = []
        for waiter in suspensionWaiters {
            if waitingCount(for: waiter.key) >= waiter.minimumWaiters {
                ready.append(waiter)
            } else {
                remaining.append(waiter)
            }
        }
        suspensionWaiters = remaining
        for waiter in ready {
            waiter.continuation.resume(returning: ())
        }
    }
}

@discardableResult
package func waitWithTimeout<T: Sendable>(
    _ description: String = "timed out waiting for async operation",
    timeout: Duration = .seconds(5),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await XcodeMCPCoreTestSupport.waitWithTimeout(
        description,
        timeout: timeout,
        operation: operation
    )
}

package func waitForSuspendedSleepers(
    on clock: TestClock,
    count: Int = 1,
    timeout: Duration = .seconds(5)
) async throws {
    try await XcodeMCPCoreTestSupport.waitForSuspendedSleepers(
        on: clock,
        count: count,
        timeout: timeout
    )
}

package func shutdown(_ group: EventLoopGroup, timeout: Duration = .seconds(5)) async throws {
    try await waitWithTimeout(
        "timed out waiting for event loop group shutdown",
        timeout: timeout
    ) {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            group.shutdownGracefully { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

package func waitForTestSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval = 10,
    description: String
) {
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        Issue.record(AsyncTestTimeoutError(description: description))
    }
}

package func shutdownAndWait(_ group: EventLoopGroup) {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
        do {
            try await shutdown(group)
        } catch {
            Issue.record("event loop group shutdown failed: \(error)")
        }
        semaphore.signal()
    }
    waitForTestSemaphore(
        semaphore,
        description: "timed out waiting for event loop group shutdown task"
    )
}

package func makeTestURLSession(
    timeout: TimeInterval = 5,
    waitsForConnectivity: Bool = false
) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = waitsForConnectivity
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
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
    beforeClose: @escaping () async -> Void = {}
) async throws {
    await beforeClose()

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

    do {
        try await shutdown(group, timeout: timeout)
    } catch {
        if shutdownError == nil {
            shutdownError = error
        }
    }

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

    package func isSignaled() -> Bool {
        state.withLockedValue { $0.signaled }
    }

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

    package func waitUntilSignaled() async throws {
        if state.withLockedValue({ $0.signaled }) {
            return
        }
        let waiterID = UUID()
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

package actor AsyncGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isOpen = false
    private var waiters: [Waiter] = []

    package init() {}

    package func wait() async throws {
        if isOpen {
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if isOpen {
                    continuation.resume(returning: ())
                    return
                }
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    package func waitIgnoringCancellation() async {
        if isOpen {
            return
        }

        try? await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            if isOpen {
                continuation.resume(returning: ())
                return
            }
            waiters.append(Waiter(id: UUID(), continuation: continuation))
        }
    }

    package func signal() {
        guard isOpen == false else {
            return
        }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: ())
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
