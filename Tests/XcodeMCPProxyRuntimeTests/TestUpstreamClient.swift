import Foundation
import XcodeMCPKit
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport


actor TestUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let sentMessages = RecordedValues<Data>()
    private let startEvents = RecordedValues<Int>()
    private let stopEvents = RecordedValues<Int>()
    private let blockedCancellationSignal = TestSignal()
    private var startCountValue = 0
    private var stopCountValue = 0
    private var shouldBlockNextCancellation = false
    private var blockedCancellation: CheckedContinuation<Upstream.SendResult, Never>?

    init() {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {
        startCountValue += 1
        await startEvents.append(startCountValue)
    }

    func stop() async {
        stopCountValue += 1
        await stopEvents.append(stopCountValue)
        releaseBlockedCancellation()
        continuation.finish()
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        await sentMessages.append(data)
        guard shouldBlockNextCancellation,
              methodName(from: data) == "notifications/cancelled"
        else {
            return .accepted
        }
        shouldBlockNextCancellation = false
        blockedCancellationSignal.signal()
        return await withCheckedContinuation { continuation in
            blockedCancellation = continuation
        }
    }

    func blockNextCancellation() {
        shouldBlockNextCancellation = true
    }

    func waitForBlockedCancellation() async throws {
        if blockedCancellation != nil {
            return
        }
        try await blockedCancellationSignal.wait(
            description: "waiting for blocked cancellation"
        )
    }

    func releaseBlockedCancellation() {
        blockedCancellation?.resume(returning: .accepted)
        blockedCancellation = nil
    }

    func yield(_ event: Upstream.Event) async {
        continuation.yield(event)
    }

    func sent() async -> [Data] {
        await sentMessages.snapshot()
    }

    func sentCount() async -> Int {
        await sentMessages.count()
    }

    func sentValue(at index: Int) async -> Data? {
        await sentMessages.value(at: index)
    }

    func nextSent(at index: Int) async throws -> Data {
        try await sentMessages.nextValue(at: index)
    }

    func nextSent(
        matching predicate: @escaping @Sendable (Data) -> Bool
    ) async throws -> Data {
        try await sentMessages.nextValue(matching: predicate)
    }

    func nextSent(
        startingAt index: Int,
        matching predicate: @escaping @Sendable (Data) -> Bool
    ) async throws -> Data {
        try await sentMessages.nextValue(startingAt: index, matching: predicate)
    }

    func startCount() async -> Int {
        startCountValue
    }

    func nextStartCount(at index: Int = 0) async throws -> Int {
        try await startEvents.nextValue(at: index)
    }

    func stopCount() async -> Int {
        stopCountValue
    }

    func nextStopCount(
        at index: Int = 0,
        timeout: Duration = .seconds(2)
    ) async throws -> Int {
        try await waitWithTimeout(
            "waiting for upstream stop event at index \(index)",
            timeout: timeout
        ) {
            try await self.stopEvents.nextValue(at: index)
        }
    }
}

actor BlockingInitializedNotificationUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let sentMessages = RecordedValues<Data>()
    private let blockedSignal = TestSignal()
    private let stopStarted: TestSignal?
    private var shouldBlockInitializedNotification = false
    private var blockedInitializedNotification: CheckedContinuation<Upstream.SendResult, Never>?

    init(stopStarted: TestSignal? = nil) {
        self.stopStarted = stopStarted
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        stopStarted?.signal()
        continuation.finish()
        releaseBlockedInitializedNotification(.backpressure)
    }

    func blockNextInitializedNotification() {
        shouldBlockInitializedNotification = true
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        await sentMessages.append(data)
        guard shouldBlockInitializedNotification,
              methodName(from: data) == "notifications/initialized"
        else {
            return .accepted
        }

        shouldBlockInitializedNotification = false
        return await withCheckedContinuation { continuation in
            blockedInitializedNotification = continuation
            blockedSignal.signal()
        }
    }

    func waitForBlockedInitializedNotification() async throws {
        if blockedInitializedNotification != nil {
            return
        }
        try await blockedSignal.wait(description: "waiting for blocked initialized notification")
    }

    func releaseBlockedInitializedNotification(_ result: Upstream.SendResult = .accepted) {
        guard let continuation = blockedInitializedNotification else {
            return
        }
        blockedInitializedNotification = nil
        continuation.resume(returning: result)
    }

    func yield(_ event: Upstream.Event) async {
        continuation.yield(event)
    }

    func sent() async -> [Data] {
        await sentMessages.snapshot()
    }

    func sentCount() async -> Int {
        await sentMessages.count()
    }

    func sentValue(at index: Int) async -> Data? {
        await sentMessages.value(at: index)
    }

    func nextSent(at index: Int) async throws -> Data {
        try await sentMessages.nextValue(at: index)
    }
}
