import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyKit

@Suite
struct JSONRPCResponseRouterTests {
    @Test func responseRouterMatchesID() async throws {
        let eventLoop = EmbeddedEventLoop()

        let router = JSONRPCResponseRouter(
            requestTimeout: .seconds(5),
            hasActiveClients: { false },
            sendNotification: { _ in }
        )

        let future = router.registerRequest(idKey: "1", on: eventLoop)
        let response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"
        router.handleIncoming(Data(response.utf8))
        eventLoop.run()

        let buffer = try await future.get()
        let string = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)
        #expect(string == response)
    }

    @Test func responseRouterBuffersNotifications() async throws {
        let router = JSONRPCResponseRouter(
            requestTimeout: .seconds(5),
            hasActiveClients: { false },
            sendNotification: { _ in }
        )

        let notification = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}"
        router.handleIncoming(Data(notification.utf8))

        let buffered = router.drainBufferedNotifications()
        #expect(buffered.count == 1)
        #expect(String(data: buffered[0], encoding: .utf8) == notification)
    }

    @Test func responseRouterSendsNotifications() async throws {
        let received = NIOLockedValueBox<[String]>([])
        let router = JSONRPCResponseRouter(
            requestTimeout: .seconds(5),
            hasActiveClients: { true },
            sendNotification: { data in
                received.withLockedValue { values in
                    values.append(String(decoding: data, as: UTF8.self))
                }
            }
        )

        let notification = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}"
        router.handleIncoming(Data(notification.utf8))
        #expect(received.withLockedValue { $0 } == [notification])
    }

    @Test func responseRouterIgnoresTopLevelArrays() async throws {
        let eventLoop = EmbeddedEventLoop()
        let router = JSONRPCResponseRouter(
            requestTimeout: .seconds(5),
            hasActiveClients: { false },
            sendNotification: { _ in }
        )
        let completed = NIOLockedValueBox(false)

        let future = router.registerRequest(idKey: "1", on: eventLoop)
        future.whenSuccess { _ in completed.withLockedValue { $0 = true } }
        router.handleIncoming(Data("[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}]".utf8))
        eventLoop.run()

        #expect(completed.withLockedValue { $0 } == false)
        #expect(router.drainBufferedNotifications().isEmpty)

        router.handleIncoming(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".utf8))
        eventLoop.run()
        #expect(completed.withLockedValue { $0 })
        _ = try await future.get()
    }

    @Test func responseRouterTimesOutRequests() async throws {
        let eventLoop = EmbeddedEventLoop()
        let router = JSONRPCResponseRouter(
            requestTimeout: .seconds(1),
            hasActiveClients: { false },
            sendNotification: { _ in }
        )

        let future = router.registerRequest(idKey: "1", on: eventLoop)
        eventLoop.advanceTime(by: .seconds(1))
        eventLoop.run()

        do {
            _ = try await future.get()
            #expect(Bool(false))
        } catch {
            #expect(error is TimeoutError)
        }
    }

    @Test func responseRouterTokenFailureCannotFailReplacementRegistration() async throws {
        let eventLoop = EmbeddedEventLoop()
        let router = JSONRPCResponseRouter(
            requestTimeout: nil,
            hasActiveClients: { false },
            sendNotification: { _ in }
        )

        let displaced = router.registerRequestPending(idKey: "1", on: eventLoop)
        let replacement = router.registerRequestPending(idKey: "1", on: eventLoop)

        #expect(
            router.failPending(
                token: displaced.token,
                error: ProxyUpstreamRequestRuntime.Error.staleUpstreamTopology
            ) == false
        )
        let response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"
        router.handleIncoming(Data(response.utf8))
        eventLoop.run()

        await #expect(throws: CancellationError.self) {
            _ = try await displaced.future.get()
        }
        let buffer = try await replacement.future.get()
        #expect(bufferString(buffer) == response)
    }

    @Test func responseRouterDisablesTimeoutWhenRequestTimeoutIsNil() async throws {
        let eventLoop = EmbeddedEventLoop()
        let router = JSONRPCResponseRouter(
            requestTimeout: nil,
            hasActiveClients: { false },
            sendNotification: { _ in }
        )

        let future = router.registerRequest(idKey: "1", on: eventLoop)
        let failed = NIOLockedValueBox(false)
        let succeeded = NIOLockedValueBox(false)
        future.whenFailure { _ in
            failed.withLockedValue { $0 = true }
        }
        future.whenSuccess { _ in
            succeeded.withLockedValue { $0 = true }
        }

        eventLoop.advanceTime(by: .seconds(5))
        eventLoop.run()

        #expect(failed.withLockedValue { $0 } == false)
        #expect(succeeded.withLockedValue { $0 } == false)
    }

    @Test func responseRouterCountsDropsAndRateLimitsOverflowWarnings() async throws {
        let uptimeNanoseconds = NIOLockedValueBox<UInt64>(0)
        let warningCounts = NIOLockedValueBox<[UInt64]>([])
        let router = JSONRPCResponseRouter(
            requestTimeout: .seconds(5),
            notificationBufferLimit: 2,
            notificationOverflowWarningInterval: .seconds(10),
            uptimeNanoseconds: { uptimeNanoseconds.withLockedValue { $0 } },
            hasActiveClients: { false },
            sendNotification: { _ in },
            onNotificationBufferOverflow: { droppedNotificationCount in
                warningCounts.withLockedValue { $0.append(droppedNotificationCount) }
            }
        )

        router.handleIncoming(Data("{\"jsonrpc\":\"2.0\",\"method\":\"n1\"}".utf8))
        router.handleIncoming(Data("{\"jsonrpc\":\"2.0\",\"method\":\"n2\"}".utf8))
        router.handleIncoming(Data("{\"jsonrpc\":\"2.0\",\"method\":\"n3\"}".utf8))
        router.handleIncoming(Data("{\"jsonrpc\":\"2.0\",\"method\":\"n4\"}".utf8))

        #expect(router.droppedNotificationCount() == 2)
        #expect(warningCounts.withLockedValue { $0 } == [1])

        uptimeNanoseconds.withLockedValue { $0 = 10_000_000_000 }
        router.handleIncoming(Data("{\"jsonrpc\":\"2.0\",\"method\":\"n5\"}".utf8))

        let buffered = router.drainBufferedNotifications()
        #expect(buffered.count == 2)
        #expect(String(data: buffered[0], encoding: .utf8)?.contains("n4") == true)
        #expect(String(data: buffered[1], encoding: .utf8)?.contains("n5") == true)
        #expect(router.droppedNotificationCount() == 3)
        #expect(warningCounts.withLockedValue { $0 } == [1, 3])
    }

    private func bufferString(_ buffer: ByteBuffer) -> String {
        buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
    }
}
