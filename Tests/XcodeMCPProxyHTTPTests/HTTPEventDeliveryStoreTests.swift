import Foundation
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

        store.receive(.notification(sessionID: sessionID, data: first))
        store.receive(.notification(sessionID: sessionID, data: second))
        store.receive(.notification(sessionID: sessionID, data: third))

        let open = store.open(sessionID: sessionID, channel: channel)
        #expect(open.bufferedNotifications == [second, third])
    }

    @Test func sessionClosureClosesItsSSEChannels() throws {
        let store = HTTPEventDeliveryStore()
        let sessionID = ProxySessionID(rawValue: "session-closed")
        let channel = EmbeddedChannel()
        defer {
            store.closeAll()
            _ = try? channel.finish()
        }
        _ = store.open(sessionID: sessionID, channel: channel)

        store.receive(.sessionClosed(sessionID: sessionID))
        channel.embeddedEventLoop.run()

        #expect(channel.isActive == false)
    }
}
