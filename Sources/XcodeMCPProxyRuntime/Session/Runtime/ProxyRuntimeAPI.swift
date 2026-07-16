import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPKit

package struct ProxySessionID: Hashable, Sendable {
    package let rawValue: String

    package init(rawValue: String) {
        precondition(rawValue.isEmpty == false, "proxy session ID must not be empty")
        self.rawValue = rawValue
    }
}

package enum ProxyRuntimeEvent: Sendable {
    case notification(sessionID: ProxySessionID, data: Data)
    case sessionClosed(sessionID: ProxySessionID)
}

package struct ProxyRuntimeRequest: Sendable {
    package let data: Data
    package let headerSessionExists: Bool
    package let prefersEventStream: Bool

    package init(
        data: Data,
        headerSessionExists: Bool,
        prefersEventStream: Bool
    ) {
        self.data = data
        self.headerSessionExists = headerSessionExists
        self.prefersEventStream = prefersEventStream
    }
}

package enum ProxyRuntimeReply: Sendable {
    case response(
        data: Data,
        sessionID: ProxySessionID?,
        prefersEventStream: Bool
    )
    case mcpError(
        id: JSONRPC.ID?,
        code: Int,
        message: String,
        sessionID: ProxySessionID?,
        prefersEventStream: Bool
    )
    case failure(
        kind: ProxyRuntimeFailureKind,
        message: String,
        sessionID: ProxySessionID?
    )
    case accepted(sessionID: ProxySessionID)
}

package enum ProxyRuntimeFailureKind: Sendable {
    case invalidRequest
    case sessionNotFound
    case unprocessableRequest
    case invalidUpstreamResponse
    case runtimeUnavailable
}

package enum ProxyRuntimeCancellationReason: String, Sendable {
    case channelInactive
    case responseWriteFailure
}

package enum ProxyRuntimeSessionState: Sendable, Equatable {
    case missing
    case uninitialized
    case initialized(protocolVersion: String?)
}

package struct ProxyRuntimeSnapshot: Sendable {
    package struct Upstream: Sendable {
        package let id: Int
        package let healthState: String
        package let isInitialized: Bool
        package let activeRequestCount: Int
    }

    package let generatedAt: Date
    package let proxyInitialized: Bool
    package let catalogAvailable: Bool
    package let queuedRequestCount: Int
    package let upstreams: [Upstream]
}

package struct ProxyRuntimeInventorySnapshot: Sendable {
    package struct XcodeTarget: Sendable {
        package let processID: pid_t
        package let appPath: String
        package let mcpBridgePath: String

        package init(processID: pid_t, appPath: String, mcpBridgePath: String) {
            self.processID = processID
            self.appPath = appPath
            self.mcpBridgePath = mcpBridgePath
        }
    }

    package let xcodeTargets: [XcodeTarget]
    package let permissionDialogProcessIDs: [pid_t]
}

package protocol ProxyRuntimeRequestOperating: Sendable {
    func whenComplete(
        _ completion: @escaping @Sendable (Result<ProxyRuntimeReply, any Error>) -> Void
    )
    func cancel(reason: ProxyRuntimeCancellationReason)
}

package protocol ProxyRuntimeServing: Sendable {
    func start()
    func cancelForDeinit()
    func shutdown() async
    func subscribeToEvents(
        _ receive: @escaping @Sendable (ProxyRuntimeEvent) -> Void
    ) -> @Sendable () -> Void
    func beginRequest(
        _ message: ProxyRuntimeRequest,
        in sessionID: ProxySessionID?
    ) -> any ProxyRuntimeRequestOperating
    func clientRequestFinished(_ id: ProxySessionID)
    func sessionState(_ id: ProxySessionID) -> ProxyRuntimeSessionState
    func clientEventStreamOpened(_ id: ProxySessionID) -> Bool
    func clientEventStreamClosed(_ id: ProxySessionID)
    func expireInactiveSessions(inactiveFor: TimeAmount)
    func removeSession(_ id: ProxySessionID)
    func snapshot() -> ProxyRuntimeSnapshot
    func inventorySnapshot() -> ProxyRuntimeInventorySnapshot
    func debugSnapshotData(includeSensitivePayloads: Bool) -> Data?
    func reset() async
}

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

package final class ProxyRuntimeRequestOperation: ProxyRuntimeRequestOperating, Sendable {
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
        executor.cancel(
            handle,
            source: reason == .channelInactive
                ? .channelInactive
                : .responseWriteFailure
        )
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
    package static func supportsProcessBoundRouting(configuration: ProxyRuntimeConfiguration) -> Bool {
        XcrunArguments.isDefaultMCPBridgeInvocation(config: configuration)
    }

    package static func documentationSearchIsConfigured(configuration: ProxyRuntimeConfiguration) -> Bool {
        RuntimeCoordinator.documentationProviderServiceIsConfigured(config: configuration)
    }

    private struct DebugSnapshot: Codable, Sendable {
        let generatedAt: Date
        let proxyInitialized: Bool
        let cachedToolsListAvailable: Bool
        let warmupInFlight: Bool
        let controlPlane: ControlPlane.DebugSnapshot?
        let upstreams: [ProxyDebug.UpstreamSnapshot]
        let processRoutes: [ProxyDebug.ProcessRouteSnapshot]
        let processToolCatalogs: [ProcessControlPlaneAuthority.CatalogDebugSnapshot]
        let recentTraffic: [ProxyDebug.TrafficEvent]
        let sessions: [SessionRequestPipeline.DebugSnapshot]
        let leases: [LeaseManager.DebugSnapshot]
        let queuedRequestCount: Int
        let refreshCodeIssues: RefreshCodeIssues.DebugSnapshot?
    }

    private let coordinator: any RuntimeCoordinating
    private let eventLoop: EventLoop
    private let eventSource: ProxyRuntimeEventSource
    private let refreshCoordinator: RefreshCodeIssues.Coordinator
    private let refreshDebugState: RefreshCodeIssues.DebugState
    private let requestExecutor: ClientMCPRequestExecutor
    private let ownedEventLoopGroup: EventLoopGroup?
    private let processEventMonitor: (any XcodeProcessEventMonitoring)?

    init(
        config: ProxyRuntimeConfiguration,
        coordinator: any RuntimeCoordinating,
        eventLoop: EventLoop,
        eventSource: ProxyRuntimeEventSource,
        refreshCoordinator: RefreshCodeIssues.Coordinator = .makeDefault(),
        refreshTargetResolver: RefreshCodeIssues.TargetResolver = .init(),
        refreshDebugState: RefreshCodeIssues.DebugState? = nil,
        refreshClock: ClockClient = .liveValue,
        eventLoopCompletionExecutor: EventLoopCompletionExecutor = .eventLoop,
        ownedEventLoopGroup: EventLoopGroup? = nil,
        processEventMonitor: (any XcodeProcessEventMonitoring)? = nil
    ) {
        let debugState =
            refreshDebugState
            ?? RefreshCodeIssues.DebugState(
                defaultRequestTimeoutSeconds: config.requestTimeout
            )
        self.coordinator = coordinator
        self.eventLoop = eventLoop
        self.eventSource = eventSource
        self.refreshCoordinator = refreshCoordinator
        self.refreshDebugState = debugState
        self.requestExecutor = ClientMCPRequestExecutor(
            config: config,
            sessionManager: coordinator,
            refreshCodeIssuesCoordinator: refreshCoordinator,
            refreshCodeIssuesTargetResolver: refreshTargetResolver,
            refreshCodeIssuesDebugState: debugState,
            refreshCodeIssuesClock: refreshClock,
            eventLoopCompletionExecutor: eventLoopCompletionExecutor,
            logger: ProxyLogging.make("runtime.request")
        )
        self.ownedEventLoopGroup = ownedEventLoopGroup
        self.processEventMonitor = processEventMonitor
    }

    package convenience init(configuration config: ProxyRuntimeConfiguration) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let eventSource = ProxyRuntimeEventSource()
        let processEventMonitor = XcodeProcessEventMonitor()
        let coordinator = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreamReadinessGate: .liveDefault(
                config: config,
                clock: .liveValue,
                processEventMonitor: processEventMonitor
            ),
            xcodeTargetDiscovery: processEventMonitor,
            xcodeProcessEventMonitor: processEventMonitor,
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
            ownedEventLoopGroup: group,
            processEventMonitor: processEventMonitor
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
        coordinator.cancelForDeinit()
        eventSource.finish()
        ownedEventLoopGroup?.shutdownGracefully { _ in }
    }

    package func shutdown() async {
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
    ) -> any ProxyRuntimeRequestOperating {
        if let sessionID {
            _ = coordinator.beginClientRequest(
                id: sessionID.rawValue,
                createIfMissing: message.headerSessionExists == false
            )
        }
        return ProxyRuntimeRequestOperation(
            executor: requestExecutor,
            operation: requestExecutor.handle(
                bodyData: message.data,
                headerSessionID: sessionID?.rawValue,
                headerSessionExists: message.headerSessionExists,
                prefersEventStream: message.prefersEventStream,
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
            }
        )
    }

    package func inventorySnapshot() -> ProxyRuntimeInventorySnapshot {
        ProxyRuntimeInventorySnapshot(
            xcodeTargets: processEventMonitor?.runningXcodeTargets().map {
                ProxyRuntimeInventorySnapshot.XcodeTarget(
                    processID: $0.processID,
                    appPath: $0.appPath,
                    mcpBridgePath: $0.mcpbridgePath
                )
            } ?? [],
            permissionDialogProcessIDs: processEventMonitor?.permissionDialogProcessIDs() ?? []
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
            processRoutes: base.processRoutes,
            processToolCatalogs: base.processToolCatalogs,
            recentTraffic: base.recentTraffic,
            sessions: base.sessions,
            leases: base.leases,
            queuedRequestCount: base.queuedRequestCount,
            refreshCodeIssues: includeSensitivePayloads
                ? refreshDebugState.snapshot()
                : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot)
    }

    package func reset() async {
        await refreshCoordinator.reset()
        refreshDebugState.reset()
        coordinator.debugReset()
    }
}
