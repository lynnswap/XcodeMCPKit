import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing

@testable import ProxySession

@Suite
struct ProxyRouterTests {
    @Test func proxyRouterMatchesID() async throws {
        let eventLoop = EmbeddedEventLoop()

        let router = ProxyRouter(
            requestTimeout: .seconds(5),
            hasActiveClients: { false },
            sendNotification: { _ in }
        )

        let future = router.registerRequest(idKey: "1", on: eventLoop)
        let response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"
        router.handleIncoming(Data(response.utf8))

        let buffer = try await future.get()
        let string = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)
        #expect(string == response)
    }

    @Test func proxyRouterBuffersNotifications() async throws {
        let router = ProxyRouter(
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

    @Test func proxyRouterSendsNotifications() async throws {
        let received = NIOLockedValueBox<[String]>([])
        let router = ProxyRouter(
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

    @Test func proxyRouterHandlesBatchResponse() async throws {
        let eventLoop = EmbeddedEventLoop()
        let router = ProxyRouter(
            requestTimeout: .seconds(5),
            hasActiveClients: { false },
            sendNotification: { _ in }
        )

        let future = router.registerBatch(on: eventLoop)
        let response = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}]"
        router.handleIncoming(Data(response.utf8))

        let buffer = try await future.get()
        let string = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)
        #expect(string == response)
    }

    @Test func proxyRouterTimesOutRequests() async throws {
        let eventLoop = EmbeddedEventLoop()
        let router = ProxyRouter(
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

    @Test func proxyRouterDisablesTimeoutWhenRequestTimeoutIsNil() async throws {
        let eventLoop = EmbeddedEventLoop()
        let router = ProxyRouter(
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

    @Test func proxyRouterEnforcesNotificationBufferLimit() async throws {
        let router = ProxyRouter(
            requestTimeout: .seconds(5),
            notificationBufferLimit: 2,
            hasActiveClients: { false },
            sendNotification: { _ in }
        )

        router.handleIncoming(Data("{\"jsonrpc\":\"2.0\",\"method\":\"n1\"}".utf8))
        router.handleIncoming(Data("{\"jsonrpc\":\"2.0\",\"method\":\"n2\"}".utf8))
        router.handleIncoming(Data("{\"jsonrpc\":\"2.0\",\"method\":\"n3\"}".utf8))

        let buffered = router.drainBufferedNotifications()
        #expect(buffered.count == 2)
        #expect(String(data: buffered[0], encoding: .utf8)?.contains("n2") == true)
        #expect(String(data: buffered[1], encoding: .utf8)?.contains("n3") == true)
    }
}
