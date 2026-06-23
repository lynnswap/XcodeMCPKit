import Foundation
import ProxySessionUpstream
import XcodeMCPTestSupport

@testable import ProxySession

actor TestUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let sentMessages = RecordedValues<Data>()
    private var startCountValue = 0
    private var stopCountValue = 0

    init() {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {
        startCountValue += 1
    }

    func stop() async {
        stopCountValue += 1
        continuation.finish()
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        await sentMessages.append(data)
        return .accepted
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

    func startCount() async -> Int {
        startCountValue
    }

    func stopCount() async -> Int {
        stopCountValue
    }
}

actor BlockingInitializedNotificationUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let sentMessages = RecordedValues<Data>()
    private let blockedSignal = TestSignal()
    private var shouldBlockInitializedNotification = false
    private var blockedInitializedNotification: CheckedContinuation<Upstream.SendResult, Never>?

    init() {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
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
