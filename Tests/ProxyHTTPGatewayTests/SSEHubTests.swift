import Foundation
import NIO
import NIOEmbedded
import NIOHTTP1
import Testing

@testable import XcodeMCPProxyKit

@Suite
struct SSEHubTests {
    @Test func sseHubSendsEachBroadcastToOnlyOneClient() throws {
        let hub = SSEHub()
        let first = EmbeddedChannel()
        let second = EmbeddedChannel()
        defer {
            _ = try? first.finish()
            _ = try? second.finish()
        }
        try first.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        try second.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 2)).wait()

        hub.add(first)
        hub.add(second)

        let data = Data(#"{"jsonrpc":"2.0","method":"notifications/test"}"#.utf8)
        hub.broadcast(data)
        first.embeddedEventLoop.run()
        second.embeddedEventLoop.run()

        let firstBodies = try sseBodies(from: first)
        let secondBodies = try sseBodies(from: second)
        let allBodies = firstBodies + secondBodies
        #expect(allBodies.count == 1)
        #expect(allBodies.first?.contains(String(decoding: data, as: UTF8.self)) == true)
    }

    private func sseBodies(from channel: EmbeddedChannel) throws -> [String] {
        var bodies: [String] = []
        while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
            guard case .body(let body) = part else { continue }
            guard case .byteBuffer(var buffer) = body else { continue }
            if let string = buffer.readString(length: buffer.readableBytes) {
                bodies.append(string)
            }
        }
        return bodies
    }
}
