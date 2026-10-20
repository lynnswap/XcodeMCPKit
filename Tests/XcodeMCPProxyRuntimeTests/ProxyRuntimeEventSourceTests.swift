@testable import XcodeMCPProxyRuntimeTestSupport
import XcodeMCPProxyRuntimeContract
import Foundation
import NIO
import NIOConcurrencyHelpers
import Testing
import XcodeMCPCore
import XcodeMCPProxyTestSupport

@testable import XcodeMCPProxyRuntime

@Suite(.serialized, .asyncTestCleanup)
struct ProxyRuntimeEventSourceTests {
    @Test func eventsReachHTTPWithoutAnIntermediateQueue() {
        let source = ProxyRuntimeEventSource()
        let sessionID = ProxySessionID(rawValue: "session-bounded-events")
        let payloads = NIOLockedValueBox<[Data]>([])
        let cancel = source.subscribe { event in
            guard case .notification(_, let data) = event else { return }
            payloads.withLockedValue { $0.append(data) }
        }
        defer { cancel() }

        for index in 0..<100 {
            source.emit(
                .notification(
                    sessionID: sessionID,
                    data: Data("payload-\(index)".utf8)
                )
            )
        }

        #expect(payloads.withLockedValue(\.count) == 100)
    }

    @Test func cancellationStopsEventDeliveryBeforeReturning() {
        let source = ProxyRuntimeEventSource()
        let sessionID = ProxySessionID(rawValue: "session-event-cancellation")
        let payloads = NIOLockedValueBox<[Data]>([])
        let cancel = source.subscribe { event in
            guard case .notification(_, let data) = event else { return }
            payloads.withLockedValue { $0.append(data) }
        }

        source.emit(.notification(sessionID: sessionID, data: Data("before".utf8)))
        cancel()
        source.emit(.notification(sessionID: sessionID, data: Data("after".utf8)))

        #expect(payloads.withLockedValue { $0 } == [Data("before".utf8)])
    }

    @Test func debugResetPublishesClosureForEveryRemovedSession() async throws {
        let installation = XcodeHostInstallation(developerDirectory: URL(filePath: "/Fixture/Default.app"))
        let broker = try NativeHostBroker(
            configuration: makeConfig(requestTimeout: 0),
            inventory: XcodeHostInventory(defaultInstallation: installation) { [installation] },
            sessionFactory: { _ in FakeHostSessionFactory() })
        let closedSessionIDs = NIOLockedValueBox<[String]>([])
        let cancel = broker.subscribeToEvents { event in
            guard case .sessionClosed(let sessionID) = event else { return }
            closedSessionIDs.withLockedValue { $0.append(sessionID.rawValue) }
        }
        defer { cancel() }
        #expect(registerAsyncTestCleanup(description: "broker shutdown") { await broker.shutdown() })
        for name in ["session-b", "session-a"] {
            let request = try ProxyRuntimeRequest(json: .object([
                "jsonrpc": .string("2.0"), "id": .number(.int(1)), "method": .string("initialize"),
                "params": .object(["protocolVersion": .string(MCPProtocolVersion.current)]),
            ]), headerSessionExists: false, prefersEventStream: false)
            let operation = try #require(broker.beginRequest(request, in: ProxySessionID(rawValue: name)))
            _ = try await withCheckedThrowingContinuation { continuation in
                operation.whenComplete { continuation.resume(with: $0) }
            }
            broker.clientRequestFinished(ProxySessionID(rawValue: name))
        }

        await broker.reset()

        #expect(closedSessionIDs.withLockedValue { $0 }.sorted() == ["session-a", "session-b"])
    }
}
