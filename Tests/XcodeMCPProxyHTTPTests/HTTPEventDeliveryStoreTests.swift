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

    @Test func overflowWarningsAreRateLimitedAndDescribeEvictedNotifications() throws {
        let state = HTTPDeliveryTestState()
        let store = HTTPEventDeliveryStore(
            bufferLimit: 1,
            notificationOverflowWarningInterval: .seconds(30),
            uptimeNanoseconds: { state.uptimeNanoseconds },
            overflowWarningSink: { state.record($0) }
        )
        defer { store.closeAll() }
        let sessionID = ProxySessionID(rawValue: "session-overflow-warning")

        store.receive(
            .notification(
                sessionID: sessionID,
                data: notification(method: "notifications/first")
            ))
        store.receive(
            .notification(
                sessionID: sessionID,
                data: notification(method: "notifications/second")
            ))
        store.receive(
            .notification(
                sessionID: sessionID,
                data: notification(method: "notifications/third")
            ))

        var warnings = state.warnings
        #expect(warnings.count == 1)
        let firstWarning = try #require(warnings.first)
        #expect(firstWarning.droppedNotificationCount == 1)
        #expect(firstWarning.droppedSinceLastWarning == 1)
        #expect(
            firstWarning.droppedMethodsSinceLastWarning
                == ["notifications/first": 1]
        )

        state.uptimeNanoseconds = 30_000_000_000
        store.receive(
            .notification(
                sessionID: sessionID,
                data: notification(method: "notifications/fourth")
            ))

        warnings = state.warnings
        #expect(warnings.count == 2)
        let secondWarning = try #require(warnings.last)
        #expect(secondWarning.droppedNotificationCount == 3)
        #expect(secondWarning.droppedSinceLastWarning == 2)
        #expect(
            secondWarning.droppedMethodsSinceLastWarning
                == [
                    "notifications/second": 1,
                    "notifications/third": 1,
                ]
        )
    }

    @Test func overflowAccountingIsPerSessionAndResetsWhenSessionCloses() throws {
        let state = HTTPDeliveryTestState()
        let store = HTTPEventDeliveryStore(
            bufferLimit: 0,
            notificationOverflowWarningInterval: .seconds(30),
            uptimeNanoseconds: { state.uptimeNanoseconds },
            overflowWarningSink: { state.record($0) }
        )
        defer { store.closeAll() }
        let firstSessionID = ProxySessionID(rawValue: "session-overflow-a")
        let secondSessionID = ProxySessionID(rawValue: "session-overflow-b")

        store.receive(
            .notification(
                sessionID: firstSessionID,
                data: notification(method: "notifications/a-1")
            ))
        store.receive(
            .notification(
                sessionID: firstSessionID,
                data: notification(method: "notifications/a-2")
            ))
        store.receive(
            .notification(
                sessionID: secondSessionID,
                data: notification(method: "notifications/b-1")
            ))

        var warnings = state.warnings
        #expect(warnings.map(\.sessionID) == [firstSessionID, secondSessionID])
        #expect(warnings.map(\.droppedNotificationCount) == [1, 1])

        store.receive(.sessionClosed(sessionID: firstSessionID))
        store.receive(
            .notification(
                sessionID: firstSessionID,
                data: notification(method: "notifications/a-new")
            ))

        warnings = state.warnings
        #expect(warnings.count == 3)
        let resetWarning = try #require(warnings.last)
        #expect(resetWarning.sessionID == firstSessionID)
        #expect(resetWarning.droppedNotificationCount == 1)
        #expect(
            resetWarning.droppedMethodsSinceLastWarning
                == ["notifications/a-new": 1]
        )
    }

    @Test func overflowMethodAggregationHasBoundedCardinality() throws {
        let state = HTTPDeliveryTestState()
        let store = HTTPEventDeliveryStore(
            bufferLimit: 0,
            notificationOverflowWarningInterval: .seconds(30),
            uptimeNanoseconds: { state.uptimeNanoseconds },
            overflowWarningSink: { state.record($0) }
        )
        defer { store.closeAll() }
        let sessionID = ProxySessionID(rawValue: "session-overflow-method-cardinality")

        store.receive(
            .notification(
                sessionID: sessionID,
                data: notification(method: "notifications/initial")
            ))
        for index in 1...20 {
            store.receive(
                .notification(
                    sessionID: sessionID,
                    data: notification(method: "notifications/method-\(index)")
                ))
        }
        state.uptimeNanoseconds = 30_000_000_000
        store.receive(
            .notification(
                sessionID: sessionID,
                data: notification(method: "notifications/method-21")
            ))

        let warning = try #require(state.warnings.last)
        #expect(warning.droppedSinceLastWarning == 21)
        #expect(warning.droppedMethodsSinceLastWarning.count == 16)
        #expect(warning.droppedMethodsSinceLastWarning["<additional-methods>"] == 6)
    }

    @Test func sessionExpirySweepRepeatsUntilCancelled() {
        let eventLoop = EmbeddedEventLoop()
        let state = HTTPDeliveryTestState()
        let sweep = HTTPSessionExpirySweep(interval: .seconds(60)) {
            state.recordExpirySweep()
        }

        sweep.start(on: eventLoop)
        sweep.start(on: eventLoop)
        eventLoop.advanceTime(by: .seconds(59))
        #expect(state.expirySweepCount == 0)
        eventLoop.advanceTime(by: .seconds(1))
        #expect(state.expirySweepCount == 1)
        eventLoop.advanceTime(by: .seconds(60))
        #expect(state.expirySweepCount == 2)

        sweep.cancel()
        eventLoop.advanceTime(by: .seconds(60))
        #expect(state.expirySweepCount == 2)
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

private func notification(method: String) -> Data {
    Data(#"{"jsonrpc":"2.0","method":"\#(method)"}"#.utf8)
}

private final class HTTPDeliveryTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var uptimeNanosecondsStorage: UInt64 = 0
    private var warningsStorage: [HTTPNotificationOverflowWarning] = []
    private var expirySweepCountStorage = 0

    var uptimeNanoseconds: UInt64 {
        get { lock.withLock { uptimeNanosecondsStorage } }
        set { lock.withLock { uptimeNanosecondsStorage = newValue } }
    }

    var warnings: [HTTPNotificationOverflowWarning] {
        lock.withLock { warningsStorage }
    }

    var expirySweepCount: Int {
        lock.withLock { expirySweepCountStorage }
    }

    func record(_ warning: HTTPNotificationOverflowWarning) {
        lock.withLock { warningsStorage.append(warning) }
    }

    func recordExpirySweep() {
        lock.withLock { expirySweepCountStorage += 1 }
    }
}
