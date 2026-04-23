import Foundation
import NIO
import NIOConcurrencyHelpers

package final class ProxyRouter: Sendable {
    package struct PendingRegistration {
        package let token: UUID
        package let future: EventLoopFuture<ByteBuffer>
    }

    private struct Pending: Sendable {
        var token: UUID
        var promise: EventLoopPromise<ByteBuffer>
        var timeout: Scheduled<Void>?
        var onTimeout: (@Sendable () -> Void)?
    }

    private struct State: Sendable {
        var pendingByID: [String: Pending] = [:]
        var pendingBatches: [Pending] = []
        var notificationBuffer: [Data] = []
    }

    private let state = NIOLockedValueBox(State())
    private let notificationBufferLimit: Int
    private let requestTimeout: TimeAmount?
    private let hasActiveClients: @Sendable () -> Bool
    private let sendNotification: @Sendable (Data) -> Void

    package init(
        requestTimeout: TimeAmount?,
        notificationBufferLimit: Int = 50,
        hasActiveClients: @escaping @Sendable () -> Bool,
        sendNotification: @escaping @Sendable (Data) -> Void
    ) {
        self.requestTimeout = requestTimeout
        self.notificationBufferLimit = notificationBufferLimit
        self.hasActiveClients = hasActiveClients
        self.sendNotification = sendNotification
    }

    package func registerRequest(
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

    package func registerRequestPending(
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
                self.failTimeout(idKey: idKey)
            }
        }
        state.withLockedValue { state in
            state.pendingByID[idKey] = Pending(
                token: token,
                promise: promise,
                timeout: timeout,
                onTimeout: onTimeout
            )
        }
        return PendingRegistration(token: token, future: promise.futureResult)
    }

    package func registerBatch(
        on eventLoop: EventLoop,
        timeout: TimeAmount? = nil,
        onTimeout: (@Sendable () -> Void)? = nil
    ) -> EventLoopFuture<ByteBuffer> {
        registerBatchPending(
            on: eventLoop,
            timeout: timeout,
            onTimeout: onTimeout
        ).future
    }

    package func registerBatchPending(
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
                self.failBatchTimeout()
            }
        }
        state.withLockedValue { state in
            state.pendingBatches.append(
                Pending(
                    token: token,
                    promise: promise,
                    timeout: timeout,
                    onTimeout: onTimeout
                )
            )
        }
        return PendingRegistration(token: token, future: promise.futureResult)
    }

    @discardableResult
    package func cancelPending(token: UUID) -> Bool {
        let pending = state.withLockedValue { state -> Pending? in
            if let idKey = state.pendingByID.first(where: { $0.value.token == token })?.key {
                return state.pendingByID.removeValue(forKey: idKey)
            }
            if let index = state.pendingBatches.firstIndex(where: { $0.token == token }) {
                return state.pendingBatches.remove(at: index)
            }
            return nil
        }
        pending?.timeout?.cancel()
        pending?.promise.fail(CancellationError())
        return pending != nil
    }

    package func handleIncoming(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            notify(data)
            return
        }

        if (json as? [Any]) != nil {
            if let pending = popBatch() {
                complete(pending: pending, data: data)
            } else {
                notify(data)
            }
            return
        }

        if let object = json as? [String: Any] {
            if let idKey = Self.idKey(from: object), let pending = pop(idKey: idKey) {
                complete(pending: pending, data: data)
            } else {
                notify(data)
            }
            return
        }

        notify(data)
    }

    package func drainBufferedNotifications() -> [Data] {
        state.withLockedValue { state in
            let drained = state.notificationBuffer
            state.notificationBuffer.removeAll()
            return drained
        }
    }

    private func failTimeout(idKey: String) {
        let pending = state.withLockedValue { state in
            state.pendingByID.removeValue(forKey: idKey)
        }
        pending?.onTimeout?()
        pending?.promise.fail(TimeoutError())
    }

    private func failBatchTimeout() {
        let pending = state.withLockedValue { state in
            state.pendingBatches.isEmpty ? nil : state.pendingBatches.removeFirst()
        }
        pending?.onTimeout?()
        pending?.promise.fail(TimeoutError())
    }

    private func pop(idKey: String) -> Pending? {
        state.withLockedValue { state in
            state.pendingByID.removeValue(forKey: idKey)
        }
    }

    private func popBatch() -> Pending? {
        state.withLockedValue { state in
            state.pendingBatches.isEmpty ? nil : state.pendingBatches.removeFirst()
        }
    }

    private func complete(pending: Pending, data: Data) {
        pending.timeout?.cancel()
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        pending.promise.succeed(buffer)
    }

    private func notify(_ data: Data) {
        if hasActiveClients() {
            sendNotification(data)
        } else {
            bufferNotification(data)
        }
    }

    private func bufferNotification(_ data: Data) {
        state.withLockedValue { state in
            state.notificationBuffer.append(data)
            if state.notificationBuffer.count > notificationBufferLimit {
                state.notificationBuffer.removeFirst(state.notificationBuffer.count - notificationBufferLimit)
            }
        }
    }

    private static func idKey(from object: [String: Any]) -> String? {
        guard let id = object["id"], !(id is NSNull) else { return nil }
        if let stringID = id as? String {
            return stringID
        }
        if let numberID = id as? NSNumber {
            return numberID.stringValue
        }
        return String(describing: id)
    }
}

struct TimeoutError: Error {}
