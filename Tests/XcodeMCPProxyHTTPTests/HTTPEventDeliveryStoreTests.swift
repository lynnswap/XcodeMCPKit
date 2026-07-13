import Foundation
import NIO
import NIOEmbedded
import NIOHTTP1
import Testing

@testable import XcodeMCPProxyHTTP
import XcodeMCPProxyRuntime

@Suite
struct HTTPEventDeliveryStoreTests {
    @Test func notificationsBufferAcrossSSEReconnects() throws {
        let store = HTTPEventDeliveryStore()
        let sessionID = ProxySessionID(rawValue: "session-buffer-owner")
        let buffered = Data(#"{"jsonrpc":"2.0","method":"buffered"}"#.utf8)
        let afterDisconnect = Data(#"{"jsonrpc":"2.0","method":"reconnected"}"#.utf8)
        let firstChannel = EmbeddedChannel()
        let secondChannel = EmbeddedChannel()
        defer {
            store.closeAll()
            _ = try? firstChannel.finish()
            _ = try? secondChannel.finish()
        }
        try activate(firstChannel, port: 1)
        try activate(secondChannel, port: 2)

        store.receive(.notification(sessionID: sessionID, data: buffered))
        store.open(sessionID: sessionID, channel: firstChannel)
        firstChannel.embeddedEventLoop.run()
        let firstBodies = try drainSSEBodies(from: firstChannel)
        #expect(firstBodies.count == 1)
        #expect(firstBodies[0].contains(String(decoding: buffered, as: UTF8.self)))

        store.close(sessionID: sessionID, channel: firstChannel)
        store.receive(.notification(sessionID: sessionID, data: afterDisconnect))
        store.open(sessionID: sessionID, channel: secondChannel)
        secondChannel.embeddedEventLoop.run()
        let secondBodies = try drainSSEBodies(from: secondChannel)
        #expect(secondBodies.count == 1)
        #expect(secondBodies[0].contains(String(decoding: afterDisconnect, as: UTF8.self)))
    }

    @Test func notificationBufferDropsOldestPayloadPastItsLimit() throws {
        let store = HTTPEventDeliveryStore(bufferLimit: 2)
        let sessionID = ProxySessionID(rawValue: "session-bounded-buffer")
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let third = Data("third".utf8)
        let channel = EmbeddedChannel()
        defer {
            store.closeAll()
            _ = try? channel.finish()
        }
        try activate(channel, port: 3)

        store.receive(.notification(sessionID: sessionID, data: first))
        store.receive(.notification(sessionID: sessionID, data: second))
        store.receive(.notification(sessionID: sessionID, data: third))

        store.open(sessionID: sessionID, channel: channel)
        channel.embeddedEventLoop.run()
        let bodies = try drainSSEBodies(from: channel)
        #expect(bodies.count == 2)
        #expect(bodies[0].contains(String(decoding: second, as: UTF8.self)))
        #expect(bodies[1].contains(String(decoding: third, as: UTF8.self)))
    }

    @Test func notificationBuffersWhileChannelInactiveCallbackIsPending() throws {
        let store = HTTPEventDeliveryStore()
        let sessionID = ProxySessionID(rawValue: "session-inactive-race")
        let notification = Data(#"{"jsonrpc":"2.0","method":"during-disconnect"}"#.utf8)
        let disconnectedChannel = EmbeddedChannel()
        let reconnectedChannel = EmbeddedChannel()
        defer {
            store.closeAll()
            _ = try? disconnectedChannel.finish()
            _ = try? reconnectedChannel.finish()
        }
        try activate(disconnectedChannel, port: 4)
        try activate(reconnectedChannel, port: 5)

        store.open(sessionID: sessionID, channel: disconnectedChannel)
        try disconnectedChannel.close().wait()

        store.receive(.notification(sessionID: sessionID, data: notification))
        store.open(sessionID: sessionID, channel: reconnectedChannel)
        reconnectedChannel.embeddedEventLoop.run()
        let bodies = try drainSSEBodies(from: reconnectedChannel)
        #expect(bodies.count == 1)
        #expect(bodies[0].contains(String(decoding: notification, as: UTF8.self)))
    }

    @Test func notificationReturnsToBufferWhenSelectedChannelClosesBeforeWrite() throws {
        let store = HTTPEventDeliveryStore()
        let sessionID = ProxySessionID(rawValue: "session-write-race")
        let notification = Data(#"{"jsonrpc":"2.0","method":"during-write"}"#.utf8)
        let disconnectedChannel = EmbeddedChannel()
        let reconnectedChannel = EmbeddedChannel()
        defer {
            store.closeAll()
            _ = try? disconnectedChannel.finish()
            _ = try? reconnectedChannel.finish()
        }
        try activate(disconnectedChannel, port: 6)
        try activate(reconnectedChannel, port: 7)

        store.open(sessionID: sessionID, channel: disconnectedChannel)
        store.receive(.notification(sessionID: sessionID, data: notification))
        try disconnectedChannel.close().wait()
        disconnectedChannel.embeddedEventLoop.run()

        store.open(sessionID: sessionID, channel: reconnectedChannel)
        reconnectedChannel.embeddedEventLoop.run()
        let bodies = try drainSSEBodies(from: reconnectedChannel)
        #expect(bodies.count == 1)
        #expect(bodies[0].contains(String(decoding: notification, as: UTF8.self)))
    }

    @Test func bufferedNotificationsPrecedeEventsArrivingDuringReconnect() throws {
        let store = HTTPEventDeliveryStore()
        let sessionID = ProxySessionID(rawValue: "session-reconnect-order")
        let first = Data(#"{"jsonrpc":"2.0","method":"first"}"#.utf8)
        let second = Data(#"{"jsonrpc":"2.0","method":"second"}"#.utf8)
        let duringReconnect = Data(#"{"jsonrpc":"2.0","method":"during-reconnect"}"#.utf8)
        let channel = EmbeddedChannel()
        defer {
            store.closeAll()
            _ = try? channel.finish()
        }
        try activate(channel, port: 8)

        store.receive(.notification(sessionID: sessionID, data: first))
        store.receive(.notification(sessionID: sessionID, data: second))
        store.open(sessionID: sessionID, channel: channel)
        store.receive(.notification(sessionID: sessionID, data: duringReconnect))
        channel.embeddedEventLoop.run()

        let bodies = try drainSSEBodies(from: channel)
        #expect(bodies.count == 3)
        #expect(bodies[0].contains(String(decoding: first, as: UTF8.self)))
        #expect(bodies[1].contains(String(decoding: second, as: UTF8.self)))
        #expect(bodies[2].contains(String(decoding: duringReconnect, as: UTF8.self)))
    }

    @Test func sessionClosureClosesItsSSEChannels() throws {
        let store = HTTPEventDeliveryStore()
        let sessionID = ProxySessionID(rawValue: "session-closed")
        let channel = EmbeddedChannel()
        defer {
            store.closeAll()
            _ = try? channel.finish()
        }
        try activate(channel, port: 9)
        store.open(sessionID: sessionID, channel: channel)

        store.receive(.sessionClosed(sessionID: sessionID))
        channel.embeddedEventLoop.run()

        #expect(channel.isActive == false)
    }
}

private func activate(_ channel: EmbeddedChannel, port: Int) throws {
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: port)).wait()
}

private func drainSSEBodies(from channel: EmbeddedChannel) throws -> [String] {
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
