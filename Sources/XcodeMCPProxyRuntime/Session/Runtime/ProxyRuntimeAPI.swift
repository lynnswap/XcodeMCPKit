import XcodeMCPProxyRuntimeContract
import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPCore

final class ProxyRuntimeEventSource: Sendable {
    private struct Subscriber: Sendable {
        let id: UUID
        let receive: @Sendable (ProxyRuntimeEvent) -> Void
    }

    private enum Phase: Sendable {
        case waiting
        case subscribed(Subscriber)
        case detached
        case finished
    }

    private let phase = NIOLockedValueBox<Phase>(.waiting)

    func subscribe(
        _ receive: @escaping @Sendable (ProxyRuntimeEvent) -> Void
    ) -> @Sendable () -> Void {
        let subscriber = Subscriber(id: UUID(), receive: receive)
        phase.withLockedValue { phase in
            guard case .waiting = phase else {
                preconditionFailure("runtime event source accepts exactly one subscriber")
            }
            phase = .subscribed(subscriber)
        }
        return { [self] in
            detach(subscriberID: subscriber.id)
        }
    }

    func emit(_ event: ProxyRuntimeEvent) {
        phase.withLockedValue { phase in
            switch phase {
            case .waiting:
                preconditionFailure("runtime emitted an event before HTTP subscribed")
            case .subscribed(let subscriber):
                subscriber.receive(event)
            case .detached, .finished:
                break
            }
        }
    }

    func finish() {
        phase.withLockedValue { $0 = .finished }
    }

    private func detach(subscriberID: UUID) {
        phase.withLockedValue { phase in
            guard case .subscribed(let subscriber) = phase,
                subscriber.id == subscriberID
            else {
                return
            }
            phase = .detached
        }
    }
}

final class ProxyRuntimeRequestOperation: ProxyRuntimeRequestOperating, Sendable {
    private let executor: ClientMCPRequestExecutor
    private let operation: ClientMCPRequestExecutor.Operation

    init(
        executor: ClientMCPRequestExecutor,
        operation: ClientMCPRequestExecutor.Operation
    ) {
        self.executor = executor
        self.operation = operation
    }

    package func whenComplete(
        _ completion: @escaping @Sendable (Result<ProxyRuntimeReply, any Error>) -> Void
    ) {
        let cancellationHandle = operation.cancellationHandle
        operation.future.whenComplete { result in
            switch result {
            case .success(let resolution):
                completion(.success(Self.reply(from: resolution)))
            case .failure(let error):
                cancellationHandle?.markCompleted()
                completion(.failure(error))
            }
        }
    }

    package func cancel(reason: ProxyRuntimeCancellationReason) {
        guard let handle = operation.cancellationHandle else { return }
        let source: ClientMCPRequestExecutor.CancellationSource
        switch reason {
        case .channelInactive: source = .channelInactive
        case .responseWriteFailure: source = .responseWriteFailure
        case .clientNotification: source = .clientNotification
        }
        executor.cancel(handle, source: source)
    }

    private static func reply(
        from resolution: ClientMCPRequestExecutor.Resolution
    ) -> ProxyRuntimeReply {
        switch resolution {
        case .responseData(let data, let sessionID, let prefersEventStream):
            return .response(
                data: data,
                sessionID: sessionID.map(ProxySessionID.init(rawValue:)),
                prefersEventStream: prefersEventStream
            )
        case .mcpError(let id, let code, let message, let sessionID, let prefersEventStream):
            return .mcpError(
                id: id,
                code: code,
                message: message,
                sessionID: sessionID.map(ProxySessionID.init(rawValue:)),
                prefersEventStream: prefersEventStream
            )
        case .plain(let status, let body, let sessionID):
            return .failure(
                kind: Self.failureKind(from: status),
                message: body,
                sessionID: sessionID.map(ProxySessionID.init(rawValue:))
            )
        case .empty(_, let sessionID):
            return .accepted(sessionID: ProxySessionID(rawValue: sessionID))
        }
    }

    private static func failureKind(
        from status: ClientMCPRequestExecutor.Status
    ) -> ProxyRuntimeFailureKind {
        switch status {
        case .ok, .accepted, .badRequest:
            return .invalidRequest
        case .notFound:
            return .sessionNotFound
        case .unprocessableEntity:
            return .unprocessableRequest
        case .badGateway:
            return .invalidUpstreamResponse
        case .serviceUnavailable:
            return .runtimeUnavailable
        }
    }
}

package final class ProxyRuntime: ProxyRuntimeServing, Sendable {
    private struct DebugSnapshot: Codable, Sendable {
        let generatedAt: Date
        let proxyInitialized: Bool
        let cachedToolsListAvailable: Bool
        let warmupInFlight: Bool
        let controlPlane: ControlPlane.DebugSnapshot?
        let upstreams: [ProxyDebug.UpstreamSnapshot]
        let recentTraffic: [ProxyDebug.TrafficEvent]
        let sessions: [SessionRequestPipeline.DebugSnapshot]
        let leases: [LeaseManager.DebugSnapshot]
        let queuedRequestCount: Int
    }

    private let coordinator: any RuntimeCoordinating
    private let eventLoop: EventLoop
    private let eventSource: ProxyRuntimeEventSource
    private let requestExecutor: ClientMCPRequestExecutor
    private let ownedEventLoopGroup: EventLoopGroup?

    init(
        config: ProxyRuntimeConfiguration,
        coordinator: any RuntimeCoordinating,
        eventLoop: EventLoop,
        eventSource: ProxyRuntimeEventSource,
        eventLoopCompletionExecutor: EventLoopCompletionExecutor = .eventLoop,
        ownedEventLoopGroup: EventLoopGroup? = nil
    ) {
        self.coordinator = coordinator
        self.eventLoop = eventLoop
        self.eventSource = eventSource
        self.requestExecutor = ClientMCPRequestExecutor(
            config: config,
            sessionManager: coordinator,
            eventLoopCompletionExecutor: eventLoopCompletionExecutor,
            logger: ProxyLogging.make("runtime.request")
        )
        self.ownedEventLoopGroup = ownedEventLoopGroup
    }

    package convenience init(configuration config: ProxyRuntimeConfiguration) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let eventSource = ProxyRuntimeEventSource()
        let coordinator = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreamReadinessGate: .liveDefault(clock: .liveValue),
            notificationSink: { sessionID, data in
                eventSource.emit(
                    .notification(
                        sessionID: ProxySessionID(rawValue: sessionID),
                        data: data
                    )
                )
            },
            sessionClosedSink: { sessionID in
                eventSource.emit(
                    .sessionClosed(sessionID: ProxySessionID(rawValue: sessionID))
                )
            },
            startImmediately: false
        )
        self.init(
            config: config,
            coordinator: coordinator,
            eventLoop: eventLoop,
            eventSource: eventSource,
            ownedEventLoopGroup: group
        )
    }

    static func testing(
        configuration config: ProxyRuntimeConfiguration,
        makeCoordinator:
            @Sendable (
                _ eventLoop: EventLoop,
                _ notificationSink: @escaping @Sendable (String, Data) -> Void,
                _ sessionClosedSink: @escaping @Sendable (String) -> Void
            ) -> any RuntimeCoordinating
    ) -> ProxyRuntime {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let eventSource = ProxyRuntimeEventSource()
        let coordinator = makeCoordinator(
            eventLoop,
            { sessionID, data in
                eventSource.emit(
                    .notification(
                        sessionID: ProxySessionID(rawValue: sessionID),
                        data: data
                    )
                )
            },
            { sessionID in
                eventSource.emit(
                    .sessionClosed(sessionID: ProxySessionID(rawValue: sessionID))
                )
            }
        )
        return ProxyRuntime(
            config: config,
            coordinator: coordinator,
            eventLoop: eventLoop,
            eventSource: eventSource,
            ownedEventLoopGroup: group
        )
    }

    package func start() {
        coordinator.start()
    }

    package func cancelForDeinit() {
        requestExecutor.cancelRequests()
        coordinator.cancelForDeinit()
        eventSource.finish()
        ownedEventLoopGroup?.shutdownGracefully { _ in }
    }

    package func shutdown() async {
        requestExecutor.cancelRequests()
        await coordinator.shutdown()
        eventSource.finish()
        try? await ownedEventLoopGroup?.shutdownGracefully()
    }

    package func subscribeToEvents(
        _ receive: @escaping @Sendable (ProxyRuntimeEvent) -> Void
    ) -> @Sendable () -> Void {
        eventSource.subscribe(receive)
    }

    package func beginRequest(
        _ message: ProxyRuntimeRequest,
        in sessionID: ProxySessionID?
    ) -> (any ProxyRuntimeRequestOperating)? {
        let createsSession = sessionID != nil && message.headerSessionExists == false
        if let sessionID, createsSession {
            // Reserve delivery before admission so a concurrent close cannot overtake
            // the open event. Generated session IDs are not exposed until the response.
            eventSource.emit(.sessionOpened(sessionID: sessionID))
        }
        if let sessionID {
            guard coordinator.beginClientRequest(
                id: sessionID.rawValue,
                createIfMissing: message.headerSessionExists == false
            ) else {
                if createsSession {
                    eventSource.emit(.sessionClosed(sessionID: sessionID))
                }
                return nil
            }
        }
        return ProxyRuntimeRequestOperation(
            executor: requestExecutor,
            operation: requestExecutor.handle(
                request: message,
                headerSessionID: sessionID?.rawValue,
                eventLoop: eventLoop
            )
        )
    }

    package func clientRequestFinished(_ id: ProxySessionID) {
        coordinator.endClientRequest(id: id.rawValue)
    }

    package func sessionState(_ id: ProxySessionID) -> ProxyRuntimeSessionState {
        coordinator.sessionStateAndTouch(id: id.rawValue)
    }

    package func clientEventStreamOpened(_ id: ProxySessionID) -> Bool {
        coordinator.openClientEventStream(id: id.rawValue)
    }

    package func clientEventStreamClosed(_ id: ProxySessionID) {
        coordinator.closeClientEventStream(id: id.rawValue)
    }

    package func expireInactiveSessions(inactiveFor: TimeAmount) {
        precondition(inactiveFor.nanoseconds > 0)
        coordinator.expireInactiveSessions(
            inactiveForNanoseconds: UInt64(inactiveFor.nanoseconds)
        )
    }

    package func removeSession(_ id: ProxySessionID) {
        guard coordinator.hasSession(id: id.rawValue) else { return }
        requestExecutor.cancelRequests(in: id.rawValue)
        coordinator.removeSession(id: id.rawValue)
    }

    package func snapshot() -> ProxyRuntimeSnapshot {
        let snapshot = coordinator.debugSnapshot()
        return ProxyRuntimeSnapshot(
            generatedAt: snapshot.generatedAt,
            proxyInitialized: snapshot.proxyInitialized,
            catalogAvailable: snapshot.cachedToolsListAvailable,
            queuedRequestCount: snapshot.queuedRequestCount,
            upstreams: snapshot.upstreams.map {
                ProxyRuntimeSnapshot.Upstream(
                    id: $0.upstreamIndex,
                    healthState: $0.healthState,
                    isInitialized: $0.isInitialized,
                    activeRequestCount: $0.activeCorrelatedRequestCount
                )
            },
            originMetadata: {
                guard case .object(let result)? = coordinator.cachedToolsListResult(),
                      case .object(let metadata)? = result["_meta"] else { return nil }
                return metadata["com.lynnswap.xcode-mcpkit/origin"]
            }()
        )
    }

    package func debugSnapshotData(includeSensitivePayloads: Bool) -> Data? {
        let base = coordinator.debugSnapshot(
            includeSensitiveDebugPayloads: includeSensitivePayloads
        )
        let snapshot = DebugSnapshot(
            generatedAt: base.generatedAt,
            proxyInitialized: base.proxyInitialized,
            cachedToolsListAvailable: base.cachedToolsListAvailable,
            warmupInFlight: base.warmupInFlight,
            controlPlane: base.controlPlane,
            upstreams: base.upstreams,
            recentTraffic: base.recentTraffic,
            sessions: base.sessions,
            leases: base.leases,
            queuedRequestCount: base.queuedRequestCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot)
    }

    package func reset() async {
        coordinator.debugReset()
    }
}
