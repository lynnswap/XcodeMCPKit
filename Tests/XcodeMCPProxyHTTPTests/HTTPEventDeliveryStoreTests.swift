import Foundation
import NIO
import NIOEmbedded
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
        let firstOpen = store.open(sessionID: sessionID, channel: firstChannel)
        #expect(firstOpen.bufferedNotifications == [buffered])

        store.close(sessionID: sessionID, channel: firstChannel)
        store.receive(.notification(sessionID: sessionID, data: afterDisconnect))
        let secondOpen = store.open(sessionID: sessionID, channel: secondChannel)
        #expect(secondOpen.bufferedNotifications == [afterDisconnect])
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

        let open = store.open(sessionID: sessionID, channel: channel)
        #expect(open.bufferedNotifications == [second, third])
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

        _ = store.open(sessionID: sessionID, channel: disconnectedChannel)
        try disconnectedChannel.close().wait()

        store.receive(.notification(sessionID: sessionID, data: notification))
        let open = store.open(sessionID: sessionID, channel: reconnectedChannel)

        #expect(open.bufferedNotifications == [notification])
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

        _ = store.open(sessionID: sessionID, channel: disconnectedChannel)
        store.receive(.notification(sessionID: sessionID, data: notification))
        try disconnectedChannel.close().wait()
        disconnectedChannel.embeddedEventLoop.run()

        let open = store.open(sessionID: sessionID, channel: reconnectedChannel)
        #expect(open.bufferedNotifications == [notification])
    }

    @Test func sessionClosureClosesItsSSEChannels() throws {
        let store = HTTPEventDeliveryStore()
        let sessionID = ProxySessionID(rawValue: "session-closed")
        let channel = EmbeddedChannel()
        defer {
            store.closeAll()
            _ = try? channel.finish()
        }
        try activate(channel, port: 8)
        _ = store.open(sessionID: sessionID, channel: channel)

        store.receive(.sessionClosed(sessionID: sessionID))
        channel.embeddedEventLoop.run()

        #expect(channel.isActive == false)
    }
}

private func activate(_ channel: EmbeddedChannel, port: Int) throws {
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: port)).wait()
}
