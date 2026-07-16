import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import XcodeMCPKit
import XcodeMCPProxyRuntime

struct HTTPNotificationOverflowWarning: Equatable, Sendable {
    let sessionID: ProxySessionID
    let droppedNotificationCount: UInt64
    let droppedSinceLastWarning: UInt64
    let droppedMethodsSinceLastWarning: [String: UInt64]
    let bufferLimit: Int
}

final class HTTPEventDeliveryStore: Sendable {
    private static let maxDroppedMethodBuckets = 16
    private static let additionalDroppedMethodsBucket = "<additional-methods>"

    private struct BufferedNotification: Sendable {
        let data: Data
        let method: String
    }

    private struct SessionDelivery: Sendable {
        let hub = SSEHub()
        var bufferedNotifications: [BufferedNotification] = []
        var droppedNotificationCount: UInt64 = 0
        var droppedSinceLastWarning: UInt64 = 0
        var droppedMethodsSinceLastWarning: [String: UInt64] = [:]
        var lastNotificationOverflowWarningUptimeNanoseconds: UInt64?
    }

    private let sessions = NIOLockedValueBox<[ProxySessionID: SessionDelivery]>([:])
    private let logger = ProxyLogging.make("http.sse")
    private let bufferLimit: Int
    private let notificationOverflowWarningIntervalNanoseconds: UInt64
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let overflowWarningSink: (@Sendable (HTTPNotificationOverflowWarning) -> Void)?

    init(
        bufferLimit: Int = 50,
        notificationOverflowWarningInterval: TimeAmount = .seconds(30),
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        overflowWarningSink: (@Sendable (HTTPNotificationOverflowWarning) -> Void)? = nil
    ) {
        precondition(bufferLimit >= 0)
        precondition(notificationOverflowWarningInterval.nanoseconds >= 0)
        self.bufferLimit = bufferLimit
        self.notificationOverflowWarningIntervalNanoseconds = UInt64(
            notificationOverflowWarningInterval.nanoseconds
        )
        self.uptimeNanoseconds = uptimeNanoseconds
        self.overflowWarningSink = overflowWarningSink
    }

    func receive(_ event: ProxyRuntimeEvent) {
        switch event {
        case .notification(let sessionID, let data):
            receiveNotification(data, sessionID: sessionID)
        case .sessionClosed(let sessionID):
            let delivery = sessions.withLockedValue { $0.removeValue(forKey: sessionID) }
            delivery?.hub.closeAll()
        }
    }

    func open(sessionID: ProxySessionID, channel: Channel) {
        sessions.withLockedValue { sessions in
            var delivery = sessions[sessionID] ?? SessionDelivery()
            switch delivery.hub.add(channel) {
            case .firstActiveClient:
                let bufferedNotifications = delivery.bufferedNotifications
                delivery.bufferedNotifications.removeAll(keepingCapacity: true)
                for notification in bufferedNotifications {
                    if case .unavailable = broadcast(
                        notification,
                        sessionID: sessionID,
                        hub: delivery.hub
                    ) {
                        delivery.bufferedNotifications.append(notification)
                    }
                }
            case .additionalActiveClient, .inactive:
                break
            }
            sessions[sessionID] = delivery
        }
    }

    func close(sessionID: ProxySessionID, channel: Channel) {
        sessions.withLockedValue { sessions in
            sessions[sessionID]?.hub.remove(channel)
        }
    }

    func waitForClient(sessionID: ProxySessionID) async throws {
        let hub = sessions.withLockedValue { sessions -> SSEHub in
            let delivery = sessions[sessionID] ?? SessionDelivery()
            sessions[sessionID] = delivery
            return delivery.hub
        }
        try await hub.waitForClient()
    }

    func closeAll() {
        let deliveries = sessions.withLockedValue { sessions -> [SessionDelivery] in
            let deliveries = Array(sessions.values)
            sessions.removeAll()
            return deliveries
        }
        for delivery in deliveries {
            delivery.hub.closeAll()
        }
    }

    private func receiveNotification(_ data: Data, sessionID: ProxySessionID) {
        deliverOrBuffer(
            BufferedNotification(data: data, method: Self.messageMethod(from: data)),
            sessionID: sessionID,
            expectedHub: nil
        )
    }

    private func deliverOrBuffer(
        _ notification: BufferedNotification,
        sessionID: ProxySessionID,
        expectedHub: SSEHub?
    ) {
        var warning: HTTPNotificationOverflowWarning?
        sessions.withLockedValue { sessions in
            let currentDelivery = sessions[sessionID]
            if let expectedHub {
                guard let currentDelivery, currentDelivery.hub === expectedHub else {
                    return
                }
            }

            var delivery = currentDelivery ?? SessionDelivery()
            if case .unavailable = broadcast(
                notification,
                sessionID: sessionID,
                hub: delivery.hub
            ) {
                delivery.bufferedNotifications.append(notification)
                if delivery.bufferedNotifications.count > bufferLimit {
                    let droppedCount = delivery.bufferedNotifications.count - bufferLimit
                    let droppedNotifications = Array(
                        delivery.bufferedNotifications.prefix(droppedCount)
                    )
                    delivery.bufferedNotifications.removeFirst(droppedCount)

                    let increment = UInt64(droppedCount)
                    let (nextTotal, totalOverflowed) =
                        delivery.droppedNotificationCount.addingReportingOverflow(increment)
                    precondition(!totalOverflowed, "notification drop counter overflow")
                    delivery.droppedNotificationCount = nextTotal

                    let (nextDelta, deltaOverflowed) =
                        delivery.droppedSinceLastWarning.addingReportingOverflow(increment)
                    precondition(!deltaOverflowed, "notification warning delta overflow")
                    delivery.droppedSinceLastWarning = nextDelta
                    for droppedNotification in droppedNotifications {
                        let methodBucket = Self.droppedMethodBucket(
                            for: droppedNotification.method,
                            counts: delivery.droppedMethodsSinceLastWarning
                        )
                        let current = delivery.droppedMethodsSinceLastWarning[
                            methodBucket,
                            default: 0
                        ]
                        let (nextCount, methodCountOverflowed) =
                            current.addingReportingOverflow(1)
                        precondition(!methodCountOverflowed, "notification method counter overflow")
                        delivery.droppedMethodsSinceLastWarning[methodBucket] = nextCount
                    }

                    let now = uptimeNanoseconds()
                    let shouldWarn: Bool
                    if let lastWarning =
                        delivery.lastNotificationOverflowWarningUptimeNanoseconds
                    {
                        shouldWarn =
                            now &- lastWarning
                            >= notificationOverflowWarningIntervalNanoseconds
                    } else {
                        shouldWarn = true
                    }
                    if shouldWarn {
                        warning = HTTPNotificationOverflowWarning(
                            sessionID: sessionID,
                            droppedNotificationCount: delivery.droppedNotificationCount,
                            droppedSinceLastWarning: delivery.droppedSinceLastWarning,
                            droppedMethodsSinceLastWarning:
                                delivery.droppedMethodsSinceLastWarning,
                            bufferLimit: bufferLimit
                        )
                        delivery.lastNotificationOverflowWarningUptimeNanoseconds = now
                        delivery.droppedSinceLastWarning = 0
                        delivery.droppedMethodsSinceLastWarning.removeAll(
                            keepingCapacity: true
                        )
                    }
                }
            }
            sessions[sessionID] = delivery
        }
        if let warning {
            if let overflowWarningSink {
                overflowWarningSink(warning)
            } else {
                log(warning)
            }
        }
    }

    private func broadcast(
        _ notification: BufferedNotification,
        sessionID: ProxySessionID,
        hub: SSEHub
    ) -> SSEHub.BroadcastResult {
        hub.broadcast(notification.data) { [weak self] in
            self?.deliverOrBuffer(
                notification,
                sessionID: sessionID,
                expectedHub: hub
            )
        }
    }

    private func log(_ warning: HTTPNotificationOverflowWarning) {
        let methods = warning.droppedMethodsSinceLastWarning
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        logger.warning(
            "SSE notification buffer overflow",
            metadata: [
                "session": .string(warning.sessionID.rawValue),
                "dropped_notifications": .string("\(warning.droppedNotificationCount)"),
                "dropped_since_last_warning": .string("\(warning.droppedSinceLastWarning)"),
                "dropped_methods_since_last_warning": .string(methods),
                "buffer_limit": .string("\(warning.bufferLimit)"),
            ]
        )
    }

    private static func messageMethod(from data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String,
            method.isEmpty == false,
            method.utf8.count <= 128,
            method.utf8.allSatisfy({ (0x21...0x7e).contains($0) })
        else {
            return "<unknown>"
        }
        return method
    }

    private static func droppedMethodBucket(
        for method: String,
        counts: [String: UInt64]
    ) -> String {
        if counts[method] != nil || counts.count < maxDroppedMethodBuckets - 1 {
            return method
        }
        return additionalDroppedMethodsBucket
    }
}

final class HTTPSessionExpirySweep: Sendable {
    private struct State: Sendable {
        var isStarted = false
        var isCancelled = false
        var timeout: RuntimeScheduledTimeout?
    }

    private let state = NIOLockedValueBox(State())
    private let interval: TimeAmount
    private let expire: @Sendable () -> Void

    init(interval: TimeAmount, expire: @escaping @Sendable () -> Void) {
        precondition(interval.nanoseconds > 0)
        self.interval = interval
        self.expire = expire
    }

    func start(on eventLoop: EventLoop) {
        let shouldSchedule = state.withLockedValue { state -> Bool in
            guard state.isStarted == false, state.isCancelled == false else {
                return false
            }
            state.isStarted = true
            return true
        }
        if shouldSchedule {
            scheduleNext(on: eventLoop)
        }
    }

    func cancel() {
        let timeout = state.withLockedValue { state -> RuntimeScheduledTimeout? in
            state.isCancelled = true
            let timeout = state.timeout
            state.timeout = nil
            return timeout
        }
        timeout?.cancel()
    }

    private func scheduleNext(on eventLoop: EventLoop) {
        let timeout = RuntimeScheduledTimeout.schedule(on: eventLoop, in: interval) {
            [weak self] in
            self?.fire(on: eventLoop)
        }
        let shouldCancel = state.withLockedValue { state -> Bool in
            guard state.isCancelled == false else { return true }
            state.timeout = timeout
            return false
        }
        if shouldCancel {
            timeout.cancel()
        }
    }

    private func fire(on eventLoop: EventLoop) {
        let shouldExpire = state.withLockedValue { state -> Bool in
            guard state.isCancelled == false else { return false }
            state.timeout = nil
            return true
        }
        guard shouldExpire else { return }
        expire()
        scheduleNext(on: eventLoop)
    }
}

final class HTTPControlService: Sendable {
    static let defaultSessionInactivityGrace: TimeAmount = .seconds(5 * 60)
    static let defaultSessionExpirySweepInterval: TimeAmount = .seconds(60)

    private let runtime: any ProxyRuntimeServing
    private let deliveryStore: HTTPEventDeliveryStore
    private let sessionExpirySweep: HTTPSessionExpirySweep
    private let cancelEventSubscription: @Sendable () -> Void

    init(
        runtime: any ProxyRuntimeServing,
        deliveryStore: HTTPEventDeliveryStore = HTTPEventDeliveryStore(),
        sessionInactivityGrace: TimeAmount = HTTPControlService.defaultSessionInactivityGrace,
        sessionExpirySweepInterval: TimeAmount =
            HTTPControlService.defaultSessionExpirySweepInterval
    ) {
        precondition(sessionInactivityGrace.nanoseconds > 0)
        self.runtime = runtime
        self.deliveryStore = deliveryStore
        self.sessionExpirySweep = HTTPSessionExpirySweep(
            interval: sessionExpirySweepInterval,
            expire: { [runtime] in
                runtime.expireInactiveSessions(inactiveFor: sessionInactivityGrace)
            }
        )
        self.cancelEventSubscription = runtime.subscribeToEvents { [deliveryStore] event in
            deliveryStore.receive(event)
        }
    }

    deinit {
        cancel()
    }

    func cancel() {
        sessionExpirySweep.cancel()
        cancelEventSubscription()
        deliveryStore.closeAll()
    }

    func shutdown() async {
        cancel()
    }

    func beginRequest(
        _ request: ProxyRuntimeRequest,
        sessionID: ProxySessionID?
    ) -> any ProxyRuntimeRequestOperating {
        runtime.beginRequest(request, in: sessionID)
    }

    func clientRequestFinished(_ sessionID: ProxySessionID) {
        runtime.clientRequestFinished(sessionID)
    }

    func startSessionExpirySweep(on eventLoop: EventLoop) {
        sessionExpirySweep.start(on: eventLoop)
    }

    func debugSnapshotData(includeSensitiveDebugPayloads: Bool = false) -> Data? {
        runtime.debugSnapshotData(
            includeSensitivePayloads: includeSensitiveDebugPayloads
        )
    }

    @discardableResult
    func openSSE(sessionID: ProxySessionID, channel: Channel) -> Bool {
        guard runtime.clientEventStreamOpened(sessionID) else { return false }
        deliveryStore.open(sessionID: sessionID, channel: channel)
        return true
    }

    func closeSSE(sessionID: ProxySessionID, channel: Channel) {
        deliveryStore.close(sessionID: sessionID, channel: channel)
        runtime.clientEventStreamClosed(sessionID)
    }

    func waitForSSEClient(sessionID: ProxySessionID) async throws {
        try await deliveryStore.waitForClient(sessionID: sessionID)
    }

    func deleteSession(_ sessionID: ProxySessionID) {
        runtime.removeSession(sessionID)
    }

    func sessionState(_ sessionID: ProxySessionID) -> ProxyRuntimeSessionState {
        runtime.sessionState(sessionID)
    }

    func debugReset(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        promise.completeWithTask { [runtime] in
            await runtime.reset()
        }
        return promise.futureResult
    }
}
