import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOConcurrencyHelpers
import XcodeMCPKit
import XcodeMCPProxyRuntime

final class SSEHub: Sendable {
    enum AddResult {
        case firstActiveClient
        case additionalActiveClient
        case inactive
    }

    enum BroadcastResult {
        case scheduled
        case unavailable
        case discardedInvalidPayload
    }

    private struct Waiter: Sendable {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State: Sendable {
        var clients: [ObjectIdentifier: Channel] = [:]
        var clientOrder: [ObjectIdentifier] = []
        var nextClientIndex = 0
        var waiters: [Waiter] = []

        mutating func add(_ channel: Channel) -> Bool {
            let id = ObjectIdentifier(channel)
            guard channel.isActive else {
                remove(id: id)
                return false
            }
            if clients[id] == nil {
                clientOrder.append(id)
            }
            clients[id] = channel
            return true
        }

        mutating func remove(_ channel: Channel) {
            remove(id: ObjectIdentifier(channel))
        }

        mutating func remove(id: ObjectIdentifier) {
            clients.removeValue(forKey: id)
            guard let index = clientOrder.firstIndex(of: id) else { return }
            clientOrder.remove(at: index)
            if clientOrder.isEmpty {
                nextClientIndex = 0
            } else if index < nextClientIndex {
                nextClientIndex -= 1
            } else if nextClientIndex >= clientOrder.count {
                nextClientIndex = 0
            }
        }

        mutating func nextActiveClient() -> Channel? {
            guard clientOrder.isEmpty == false else { return nil }
            let originalCount = clientOrder.count
            var checked = 0
            while checked < originalCount, clientOrder.isEmpty == false {
                if nextClientIndex >= clientOrder.count {
                    nextClientIndex = 0
                }
                let id = clientOrder[nextClientIndex]
                nextClientIndex = (nextClientIndex + 1) % clientOrder.count
                checked += 1
                guard let channel = clients[id] else {
                    remove(id: id)
                    continue
                }
                guard channel.isActive else {
                    remove(id: id)
                    continue
                }
                return channel
            }
            return nil
        }

        mutating func hasActiveClients() -> Bool {
            let inactiveClientIDs = clientOrder.filter { id in
                clients[id]?.isActive != true
            }
            for id in inactiveClientIDs {
                remove(id: id)
            }
            return clients.isEmpty == false
        }
    }

    private let state = NIOLockedValueBox(State())
    private let logger: Logger = ProxyLogging.make("sse")

    var hasActiveClients: Bool {
        state.withLockedValue { $0.hasActiveClients() }
    }

    @discardableResult
    func add(_ channel: Channel) -> AddResult {
        let (result, waiters) = state.withLockedValue { state -> (AddResult, [Waiter]) in
            let hadActiveClients = state.hasActiveClients()
            guard state.add(channel) else {
                return (.inactive, [])
            }
            let waiters = state.waiters
            state.waiters.removeAll()
            return (
                hadActiveClients ? .additionalActiveClient : .firstActiveClient,
                waiters
            )
        }
        for waiter in waiters {
            waiter.continuation.resume(returning: ())
        }
        return result
    }

    func waitForClient() async throws {
        if hasActiveClients {
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldResume = state.withLockedValue { state in
                    guard state.hasActiveClients() == false else { return true }
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

    func remove(_ channel: Channel) {
        state.withLockedValue { state in
            state.remove(channel)
        }
    }

    @discardableResult
    func broadcast(
        _ data: Data,
        onUndelivered: @escaping @Sendable () -> Void = {}
    ) -> BroadcastResult {
        guard let payload = SSECodec.encodeDataEvent(data) else {
            logger.warning("Dropping non-UTF8 SSE payload", metadata: ["bytes": "\(data.count)"])
            return .discardedInvalidPayload
        }
        guard let channel = state.withLockedValue({ $0.nextActiveClient() }) else {
            return .unavailable
        }

        channel.eventLoop.execute { [weak self] in
            guard channel.isActive else {
                self?.remove(channel)
                onUndelivered()
                return
            }
            var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
            buffer.writeString(payload)
            channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).whenFailure {
                [weak self] _ in
                self?.remove(channel)
                onUndelivered()
            }
        }
        return .scheduled
    }

    func closeAll() {
        let channels = state.withLockedValue { state -> [Channel] in
            let channels = Array(state.clients.values)
            state.clients.removeAll()
            state.clientOrder.removeAll()
            state.nextClientIndex = 0
            return channels
        }
        for channel in channels {
            channel.eventLoop.execute {
                channel.close(promise: nil)
            }
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
