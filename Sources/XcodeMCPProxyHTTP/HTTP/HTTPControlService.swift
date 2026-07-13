import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import XcodeMCPProxyRuntime

final class HTTPEventDeliveryStore: Sendable {
    struct OpenResult {
        let bufferedNotifications: [Data]
    }

    private struct SessionDelivery: Sendable {
        let hub = SSEHub()
        var bufferedNotifications: [Data] = []
    }

    private let sessions = NIOLockedValueBox<[ProxySessionID: SessionDelivery]>([:])
    private let logger = ProxyLogging.make("http.sse")
    private let bufferLimit: Int

    init(bufferLimit: Int = 50) {
        precondition(bufferLimit >= 0)
        self.bufferLimit = bufferLimit
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

    func open(sessionID: ProxySessionID, channel: Channel) -> OpenResult {
        sessions.withLockedValue { sessions in
            var delivery = sessions[sessionID] ?? SessionDelivery()
            let hadClients = delivery.hub.hasClients
            delivery.hub.add(channel)
            let buffered = hadClients ? [] : delivery.bufferedNotifications
            if hadClients == false {
                delivery.bufferedNotifications.removeAll(keepingCapacity: true)
            }
            sessions[sessionID] = delivery
            return OpenResult(bufferedNotifications: buffered)
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
        var hub: SSEHub?
        var droppedNotificationCount = 0
        sessions.withLockedValue { sessions in
            var delivery = sessions[sessionID] ?? SessionDelivery()
            if delivery.hub.hasClients {
                hub = delivery.hub
            } else {
                delivery.bufferedNotifications.append(data)
                if delivery.bufferedNotifications.count > bufferLimit {
                    droppedNotificationCount = delivery.bufferedNotifications.count - bufferLimit
                    delivery.bufferedNotifications.removeFirst(droppedNotificationCount)
                }
            }
            sessions[sessionID] = delivery
        }
        if droppedNotificationCount > 0 {
            logger.warning(
                "SSE notification buffer overflow",
                metadata: [
                    "session": .string(sessionID.rawValue),
                    "dropped_notifications": .string("\(droppedNotificationCount)"),
                ]
            )
        }
        hub?.broadcast(data)
    }
}

final class HTTPControlService: Sendable {
    private let runtime: any ProxyRuntimeServing
    private let deliveryStore: HTTPEventDeliveryStore
    private let cancelEventSubscription: @Sendable () -> Void

    init(
        runtime: any ProxyRuntimeServing,
        deliveryStore: HTTPEventDeliveryStore = HTTPEventDeliveryStore()
    ) {
        self.runtime = runtime
        self.deliveryStore = deliveryStore
        self.cancelEventSubscription = runtime.subscribeToEvents { [deliveryStore] event in
            deliveryStore.receive(event)
        }
    }

    deinit {
        cancel()
    }

    func cancel() {
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

    func debugSnapshotData(includeSensitiveDebugPayloads: Bool = false) -> Data? {
        runtime.debugSnapshotData(
            includeSensitivePayloads: includeSensitiveDebugPayloads
        )
    }

    func openSSE(sessionID: ProxySessionID, channel: Channel) -> HTTPEventDeliveryStore.OpenResult {
        deliveryStore.open(sessionID: sessionID, channel: channel)
    }

    func closeSSE(sessionID: ProxySessionID, channel: Channel) {
        deliveryStore.close(sessionID: sessionID, channel: channel)
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
