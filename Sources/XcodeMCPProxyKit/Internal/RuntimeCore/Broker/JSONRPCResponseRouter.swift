import XcodeMCPKit
import Foundation
import NIO
import NIOConcurrencyHelpers

final class JSONRPCResponseRouter: Sendable {
    struct PendingRegistration {
        let token: UUID
        let future: EventLoopFuture<ByteBuffer>
    }

    private struct Pending: Sendable {
        var token: UUID
        var eventLoop: EventLoop
        var promise: EventLoopPromise<ByteBuffer>
        var timeout: Scheduled<Void>?
        var onTimeout: (@Sendable () -> Void)?
        var responseIDKeys: Set<String>?
    }

    private struct State: Sendable {
        var pendingByID: [String: Pending] = [:]
        var pendingBatches: [Pending] = []
        var notificationBuffer: [Data] = []
        var droppedNotificationCount: UInt64 = 0
        var lastNotificationOverflowWarningUptimeNanoseconds: UInt64?
    }

    private let state = NIOLockedValueBox(State())
    private let notificationBufferLimit: Int
    private let requestTimeout: TimeAmount?
    private let hasActiveClients: @Sendable () -> Bool
    private let sendNotification: @Sendable (Data) -> Void
    private let notificationOverflowWarningIntervalNanoseconds: UInt64
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let onNotificationBufferOverflow: @Sendable (_ droppedNotificationCount: UInt64) -> Void

    init(
        requestTimeout: TimeAmount?,
        notificationBufferLimit: Int = 50,
        notificationOverflowWarningInterval: TimeAmount = .seconds(30),
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        hasActiveClients: @escaping @Sendable () -> Bool,
        sendNotification: @escaping @Sendable (Data) -> Void,
        onNotificationBufferOverflow: @escaping @Sendable (
            _ droppedNotificationCount: UInt64
        ) -> Void = { _ in }
    ) {
        precondition(notificationBufferLimit >= 0)
        precondition(notificationOverflowWarningInterval.nanoseconds >= 0)
        self.requestTimeout = requestTimeout
        self.notificationBufferLimit = notificationBufferLimit
        self.notificationOverflowWarningIntervalNanoseconds = UInt64(
            notificationOverflowWarningInterval.nanoseconds
        )
        self.uptimeNanoseconds = uptimeNanoseconds
        self.hasActiveClients = hasActiveClients
        self.sendNotification = sendNotification
        self.onNotificationBufferOverflow = onNotificationBufferOverflow
    }

    func registerRequest(
        idKey: String,
        on eventLoop: EventLoop,
        timeout: TimeAmount? = nil,
        onTimeout: (@Sendable () -> Void)? = nil
    ) -> EventLoopFuture<ByteBuffer> {
        registerRequestPending(
            idKey: idKey,
            on: eventLoop,
            timeout: timeout,
            onTimeout: onTimeout
        ).future
    }

    func registerRequestPending(
        idKey: String,
        on eventLoop: EventLoop,
        timeout: TimeAmount? = nil,
        onTimeout: (@Sendable () -> Void)? = nil
    ) -> PendingRegistration {
        let promise = eventLoop.makePromise(of: ByteBuffer.self)
        let token = UUID()
        let effectiveTimeout = timeout ?? requestTimeout
        let timeout = effectiveTimeout.map { timeout in
            eventLoop.scheduleTask(in: timeout) { [weak self] in
                guard let self else { return }
                self.failTimeout(idKey: idKey, token: token)
            }
        }
        let displaced = state.withLockedValue { state -> Pending? in
            let existing = state.pendingByID[idKey]
            state.pendingByID[idKey] = Pending(
                token: token,
                eventLoop: eventLoop,
                promise: promise,
                timeout: timeout,
                onTimeout: onTimeout,
                responseIDKeys: nil
            )
            return existing
        }
        // A client reusing an in-flight request id supersedes the older
        // request; fail it explicitly instead of leaking its promise and
        // leaving its timer armed against the new registration.
        if let displaced {
            failOnEventLoop(displaced, error: CancellationError())
        }
        return PendingRegistration(token: token, future: promise.futureResult)
    }

    /// `responseIDKeys` must be the exact ids the proxy forwarded; batch
    /// responses are correlated only by id overlap, never by guessing.
    func registerBatchPending(
        on eventLoop: EventLoop,
        timeout: TimeAmount? = nil,
        responseIDKeys: [String],
        onTimeout: (@Sendable () -> Void)? = nil
    ) -> PendingRegistration {
        let promise = eventLoop.makePromise(of: ByteBuffer.self)
        let token = UUID()
        let effectiveTimeout = timeout ?? requestTimeout
        let timeout = effectiveTimeout.map { timeout in
            eventLoop.scheduleTask(in: timeout) { [weak self] in
                guard let self else { return }
                self.failBatchTimeout(token: token)
            }
        }
        state.withLockedValue { state in
            state.pendingBatches.append(
                Pending(
                    token: token,
                    eventLoop: eventLoop,
                    promise: promise,
                    timeout: timeout,
                    onTimeout: onTimeout,
                    responseIDKeys: Set(responseIDKeys)
                )
            )
        }
        return PendingRegistration(token: token, future: promise.futureResult)
    }

    @discardableResult
    func cancelPending(token: UUID) -> Bool {
        let pending = state.withLockedValue { state -> Pending? in
            if let idKey = state.pendingByID.first(where: { $0.value.token == token })?.key {
                return state.pendingByID.removeValue(forKey: idKey)
            }
            if let index = state.pendingBatches.firstIndex(where: { $0.token == token }) {
                return state.pendingBatches.remove(at: index)
            }
            return nil
        }
        if let pending {
            failOnEventLoop(pending, error: CancellationError())
        }
        return pending != nil
    }

    @discardableResult
    func failPending(idKey: String, error: Error) -> Bool {
        let pending = state.withLockedValue { state -> Pending? in
            if let pending = state.pendingByID.removeValue(forKey: idKey) {
                return pending
            }
            guard let index = state.pendingBatches.firstIndex(where: { pending in
                pending.responseIDKeys?.contains(idKey) == true
            }) else {
                return nil
            }
            return state.pendingBatches.remove(at: index)
        }
        if let pending {
            failOnEventLoop(pending, error: error)
        }
        return pending != nil
    }

    func handleIncoming(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            notify(data)
            return
        }

        if let array = json as? [Any] {
            let responseIDKeys = Self.responseIDKeys(from: array)
            if let pending = popBatch(matching: responseIDKeys) {
                complete(pending: pending, data: data)
            } else if responseIDKeys.count == 1,
                let idKey = responseIDKeys.first,
                let pending = pop(idKey: idKey)
            {
                complete(pending: pending, data: data)
            } else {
                notify(data)
            }
            return
        }

        if let object = json as? [String: Any] {
            if let idKey = Self.responseIDKey(from: object), let pending = pop(idKey: idKey) {
                complete(pending: pending, data: data)
            } else if let idKey = Self.responseIDKey(from: object),
                let pending = popBatch(matching: [idKey])
            {
                complete(pending: pending, data: data)
            } else {
                notify(data)
            }
            return
        }

        notify(data)
    }

    func drainBufferedNotifications() -> [Data] {
        state.withLockedValue { state in
            let drained = state.notificationBuffer
            state.notificationBuffer.removeAll()
            return drained
        }
    }

    func droppedNotificationCount() -> UInt64 {
        state.withLockedValue(\.droppedNotificationCount)
    }

    private func failTimeout(idKey: String, token: UUID) {
        let pending = state.withLockedValue { state -> Pending? in
            guard state.pendingByID[idKey]?.token == token else { return nil }
            return state.pendingByID.removeValue(forKey: idKey)
        }
        pending?.onTimeout?()
        pending?.promise.fail(TimeoutError())
    }

    private func failBatchTimeout(token: UUID) {
        let pending = state.withLockedValue { state -> Pending? in
            guard let index = state.pendingBatches.firstIndex(where: { $0.token == token }) else {
                return nil
            }
            return state.pendingBatches.remove(at: index)
        }
        pending?.onTimeout?()
        pending?.promise.fail(TimeoutError())
    }

    private func pop(idKey: String) -> Pending? {
        state.withLockedValue { state -> Pending? in
            state.pendingByID.removeValue(forKey: idKey)
        }
    }

    private func popBatch(matching responseIDKeys: Set<String>) -> Pending? {
        guard responseIDKeys.isEmpty == false else {
            return nil
        }
        return state.withLockedValue { state in
            guard let index = state.pendingBatches.firstIndex(where: { pending in
                guard let expected = pending.responseIDKeys else {
                    return false
                }
                return expected.isDisjoint(with: responseIDKeys) == false
            }) else {
                return nil
            }
            return state.pendingBatches.remove(at: index)
        }
    }

    private func complete(pending: Pending, data: Data) {
        pending.eventLoop.execute {
            pending.timeout?.cancel()
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            pending.promise.succeed(buffer)
        }
    }

    private func failOnEventLoop(_ pending: Pending, error: Error) {
        pending.eventLoop.execute {
            pending.timeout?.cancel()
            pending.promise.fail(error)
        }
    }

    private func notify(_ data: Data) {
        if hasActiveClients() {
            sendNotification(data)
        } else {
            bufferNotification(data)
        }
    }

    private func bufferNotification(_ data: Data) {
        let warningCount = state.withLockedValue { state -> UInt64? in
            state.notificationBuffer.append(data)
            let overflowCount = state.notificationBuffer.count - notificationBufferLimit
            guard overflowCount > 0 else {
                return nil
            }

            state.notificationBuffer.removeFirst(overflowCount)
            let (nextDroppedCount, overflowed) = state.droppedNotificationCount.addingReportingOverflow(
                UInt64(overflowCount)
            )
            precondition(!overflowed, "notification drop counter overflow")
            state.droppedNotificationCount = nextDroppedCount

            let now = uptimeNanoseconds()
            if let lastWarning = state.lastNotificationOverflowWarningUptimeNanoseconds,
                now &- lastWarning < notificationOverflowWarningIntervalNanoseconds
            {
                return nil
            }
            state.lastNotificationOverflowWarningUptimeNanoseconds = now
            return nextDroppedCount
        }
        if let warningCount {
            onNotificationBufferOverflow(warningCount)
        }
    }

    private static func responseIDKey(from object: [String: Any]) -> String? {
        JSONRPC.Message.Inspector.responseCorrelationID(from: object)?.key
    }

    private static func responseIDKeys(from array: [Any]) -> Set<String> {
        Set(
            array.compactMap { item -> String? in
                guard let object = item as? [String: Any] else {
                    return nil
                }
                return responseIDKey(from: object)
            }
        )
    }
}
