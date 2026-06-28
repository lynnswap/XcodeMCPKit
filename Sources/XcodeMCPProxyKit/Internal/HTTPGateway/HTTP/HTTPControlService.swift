import Foundation
import NIO
import XcodeMCPKit

final class HTTPControlService: Sendable {
    struct DebugSnapshot: Codable, Sendable {
        let generatedAt: Date
        let proxyInitialized: Bool
        let cachedToolsListAvailable: Bool
        let warmupInFlight: Bool
        let controlPlane: ControlPlane.DebugSnapshot?
        let upstreams: [ProxyDebug.UpstreamSnapshot]
        let processToolCatalogs: [ProcessToolCatalogRegistry.DebugSnapshot]
        let recentTraffic: [ProxyDebug.TrafficEvent]
        let sessions: [SessionRequestPipeline.DebugSnapshot]
        let leases: [LeaseManager.DebugSnapshot]
        let queuedRequestCount: Int
        let refreshCodeIssues: RefreshCodeIssues.DebugSnapshot?

        init(
            base: ProxyDebug.Snapshot,
            refreshCodeIssues: RefreshCodeIssues.DebugSnapshot?
        ) {
            self.generatedAt = base.generatedAt
            self.proxyInitialized = base.proxyInitialized
            self.cachedToolsListAvailable = base.cachedToolsListAvailable
            self.warmupInFlight = base.warmupInFlight
            self.controlPlane = base.controlPlane
            self.upstreams = base.upstreams
            self.processToolCatalogs = base.processToolCatalogs
            self.recentTraffic = base.recentTraffic
            self.sessions = base.sessions
            self.leases = base.leases
            self.queuedRequestCount = base.queuedRequestCount
            self.refreshCodeIssues = refreshCodeIssues
        }
    }

    struct SSEOpenResult {
        let bufferedNotifications: [Data]

        init(bufferedNotifications: [Data]) {
            self.bufferedNotifications = bufferedNotifications
        }
    }

    private let runtimeCoordinator: any RuntimeHTTPControlPort
    private let refreshCodeIssuesCoordinator: RefreshCodeIssues.Coordinator?
    private let refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState?

    init(
        runtimeCoordinator: any RuntimeHTTPControlPort,
        refreshCodeIssuesCoordinator: RefreshCodeIssues.Coordinator? = nil,
        refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState? = nil
    ) {
        self.runtimeCoordinator = runtimeCoordinator
        self.refreshCodeIssuesCoordinator = refreshCodeIssuesCoordinator
        self.refreshCodeIssuesDebugState = refreshCodeIssuesDebugState
    }

    func debugSnapshotData(includeSensitiveDebugPayloads: Bool = false) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(
            HTTPControlService.DebugSnapshot(
                base: runtimeCoordinator.debugSnapshot(
                    includeSensitiveDebugPayloads: includeSensitiveDebugPayloads
                ),
                refreshCodeIssues: includeSensitiveDebugPayloads
                    ? refreshCodeIssuesDebugState?.snapshot()
                    : nil
            )
        )
    }

    func openSSE(sessionID: String, channel: Channel) -> HTTPControlService.SSEOpenResult {
        let session = runtimeCoordinator.session(id: sessionID)
        let hadClients = session.notificationHub.hasSseClients
        session.notificationHub.addSse(channel)
        runtimeCoordinator.markNotificationClientConnected(sessionID: sessionID)
        let bufferedNotifications = hadClients ? [] : session.router.drainBufferedNotifications()
        return HTTPControlService.SSEOpenResult(bufferedNotifications: bufferedNotifications)
    }

    func closeSSE(sessionID: String, channel: Channel) {
        guard runtimeCoordinator.hasSession(id: sessionID) else { return }
        let session = runtimeCoordinator.session(id: sessionID)
        session.notificationHub.removeSse(channel)
    }

    func deleteSession(id sessionID: String) {
        guard runtimeCoordinator.hasSession(id: sessionID) else { return }
        runtimeCoordinator.removeSession(id: sessionID)
    }

    func hasSession(id sessionID: String) -> Bool {
        runtimeCoordinator.hasSession(id: sessionID)
    }

    func negotiatedProtocolVersion(id sessionID: String) -> String? {
        runtimeCoordinator.negotiatedProtocolVersion(id: sessionID)
    }

    func debugReset(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        promise.completeWithTask { [runtimeCoordinator, refreshCodeIssuesCoordinator, refreshCodeIssuesDebugState] in
            await refreshCodeIssuesCoordinator?.reset()
            refreshCodeIssuesDebugState?.reset()
            runtimeCoordinator.debugReset()
        }
        return promise.futureResult
    }
}
