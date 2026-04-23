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
    }

    private let state = NIOLockedValueBox(State())
    private let logger: Logger = ProxyLogging.make("sse")

    var hasClients: Bool {
        state.withLockedValue { !$0.clients.isEmpty }
    }

    func add(_ channel: Channel) {
        state.withLockedValue { state in
            state.clients[ObjectIdentifier(channel)] = channel
        }
    }

    func remove(_ channel: Channel) {
        _ = state.withLockedValue { state in
            state.clients.removeValue(forKey: ObjectIdentifier(channel))
        }
    }

    func broadcast(_ data: Data) {
        guard let payload = SSECodec.encodeDataEvent(data) else {
            logger.warning("Dropping non-UTF8 SSE payload", metadata: ["bytes": "\(data.count)"])
            return
        }
        let channels = state.withLockedValue { Array($0.clients.values) }
        for channel in channels {
            channel.eventLoop.execute {
                guard channel.isActive else { return }
                var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
                buffer.writeString(payload)
                _ = channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
            }
        }
    }

    func closeAll() {
        let channels = state.withLockedValue { Array($0.clients.values) }
        state.withLockedValue { $0.clients.removeAll() }
        for channel in channels {
            channel.eventLoop.execute {
                channel.close(promise: nil)
            }
        }
    }
}
