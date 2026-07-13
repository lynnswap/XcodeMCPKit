import Foundation
import NIO
import NIOConcurrencyHelpers
import Testing

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

    @Test func debugResetPublishesClosureForEveryRemovedSession() {
        let source = ProxyRuntimeEventSource()
        let closedSessionIDs = NIOLockedValueBox<[String]>([])
        let cancel = source.subscribe { event in
            guard case .sessionClosed(let sessionID) = event else { return }
            closedSessionIDs.withLockedValue { $0.append(sessionID.rawValue) }
        }
        defer { cancel() }
        let config = makeConfig(requestTimeout: 0)
        let coordinator = RuntimeCoordinator(
            config: config,
            eventLoop: MultiThreadedEventLoopGroup.singleton.next(),
            upstreams: [TestUpstreamClient()],
            sessionClosedSink: { sessionID in
                source.emit(
                    .sessionClosed(sessionID: ProxySessionID(rawValue: sessionID))
                )
            },
            startImmediately: false
        )
        defer { coordinator.shutdownAndWait() }
        _ = coordinator.session(id: "session-b")
        _ = coordinator.session(id: "session-a")

        coordinator.debugReset()

        #expect(closedSessionIDs.withLockedValue { $0 } == ["session-a", "session-b"])
    }
}
