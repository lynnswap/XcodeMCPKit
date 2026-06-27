import Foundation
import NIO
import ProxyXcodeFeatures
import ProxySession

package final class HTTPControlService: Sendable {
    package struct DebugSnapshot: Codable, Sendable {
        package let generatedAt: Date
        package let proxyInitialized: Bool
        package let cachedToolsListAvailable: Bool
        package let warmupInFlight: Bool
        package let controlPlane: ControlPlane.DebugSnapshot?
        package let upstreams: [ProxyDebug.UpstreamSnapshot]
        package let processToolCatalogs: [ProcessToolCatalogRegistry.DebugSnapshot]
        package let recentTraffic: [ProxyDebug.TrafficEvent]
        package let sessions: [SessionRequestPipeline.DebugSnapshot]
        package let leases: [LeaseManager.DebugSnapshot]
        package let queuedRequestCount: Int
        package let refreshCodeIssues: RefreshCodeIssues.DebugSnapshot?

        package init(
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

    package struct SSEOpenResult {
        package let bufferedNotifications: [Data]

        package init(bufferedNotifications: [Data]) {
            self.bufferedNotifications = bufferedNotifications
        }
    }

    private let runtimeCoordinator: any RuntimeHTTPControlPort
    private let refreshCodeIssuesCoordinator: RefreshCodeIssues.Coordinator?
    private let refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState?

    package init(
        runtimeCoordinator: any RuntimeHTTPControlPort,
        refreshCodeIssuesCoordinator: RefreshCodeIssues.Coordinator? = nil,
        refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState? = nil
    ) {
        self.runtimeCoordinator = runtimeCoordinator
        self.refreshCodeIssuesCoordinator = refreshCodeIssuesCoordinator
        self.refreshCodeIssuesDebugState = refreshCodeIssuesDebugState
    }

    package func debugSnapshotData(includeSensitiveDebugPayloads: Bool = false) -> Data? {
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

    package func openSSE(sessionID: String, channel: Channel) -> HTTPControlService.SSEOpenResult {
        let session = runtimeCoordinator.session(id: sessionID)
        let hadClients = session.notificationHub.hasSseClients
        session.notificationHub.addSse(channel)
        runtimeCoordinator.markNotificationClientConnected(sessionID: sessionID)
        let bufferedNotifications = hadClients ? [] : session.router.drainBufferedNotifications()
        return HTTPControlService.SSEOpenResult(bufferedNotifications: bufferedNotifications)
    }

    package func closeSSE(sessionID: String, channel: Channel) {
        guard runtimeCoordinator.hasSession(id: sessionID) else { return }
        let session = runtimeCoordinator.session(id: sessionID)
        session.notificationHub.removeSse(channel)
    }

    package func deleteSession(id sessionID: String) {
        guard runtimeCoordinator.hasSession(id: sessionID) else { return }
        runtimeCoordinator.removeSession(id: sessionID)
    }

    package func hasSession(id sessionID: String) -> Bool {
        runtimeCoordinator.hasSession(id: sessionID)
    }

    package func negotiatedProtocolVersion(id sessionID: String) -> String? {
        runtimeCoordinator.negotiatedProtocolVersion(id: sessionID)
    }

    package func debugReset(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        promise.completeWithTask { [runtimeCoordinator, refreshCodeIssuesCoordinator, refreshCodeIssuesDebugState] in
            await refreshCodeIssuesCoordinator?.reset()
            refreshCodeIssuesDebugState?.reset()
            runtimeCoordinator.debugReset()
        }
        return promise.futureResult
    }
}
