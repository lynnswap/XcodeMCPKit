import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOConcurrencyHelpers
import ProxyCore
import ProxyMCP

final class SSEHub: Sendable {
    private struct State: Sendable {
        var clients: [ObjectIdentifier: Channel] = [:]
        var clientOrder: [ObjectIdentifier] = []
        var nextClientIndex = 0

        mutating func add(_ channel: Channel) {
            let id = ObjectIdentifier(channel)
            if clients[id] == nil {
                clientOrder.append(id)
            }
            clients[id] = channel
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
    }

    private let state = NIOLockedValueBox(State())
    private let logger: Logger = ProxyLogging.make("sse")

    var hasClients: Bool {
        state.withLockedValue { !$0.clients.isEmpty }
    }

    func add(_ channel: Channel) {
        state.withLockedValue { state in
            state.add(channel)
        }
    }

    func remove(_ channel: Channel) {
        state.withLockedValue { state in
            state.remove(channel)
        }
    }

    func broadcast(_ data: Data) {
        guard let payload = SSECodec.encodeDataEvent(data) else {
            logger.warning("Dropping non-UTF8 SSE payload", metadata: ["bytes": "\(data.count)"])
            return
        }
        guard let channel = state.withLockedValue({ $0.nextActiveClient() }) else {
            return
        }
        channel.eventLoop.execute {
            guard channel.isActive else { return }
            var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
            buffer.writeString(payload)
            _ = channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
        }
    }

    func closeAll() {
        let channels = state.withLockedValue { Array($0.clients.values) }
        state.withLockedValue { state in
            state.clients.removeAll()
            state.clientOrder.removeAll()
            state.nextClientIndex = 0
        }
        for channel in channels {
            channel.eventLoop.execute {
                channel.close(promise: nil)
            }
        }
    }
}
