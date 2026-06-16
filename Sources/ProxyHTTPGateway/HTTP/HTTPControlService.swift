import Foundation
import NIO
import ProxyXcodeFeatures
import ProxySession

package struct HTTPDebugSnapshot: Codable, Sendable {
    package let generatedAt: Date
    package let proxyInitialized: Bool
    package let cachedToolsListAvailable: Bool
    package let warmupInFlight: Bool
    package let controlPlane: ProxyControlPlaneDebugSnapshot?
    package let upstreams: [ProxyUpstreamDebugSnapshot]
    package let recentTraffic: [ProxyDebugTrafficEvent]
    package let sessions: [SessionDebugSnapshot]
    package let leases: [RequestLeaseDebugSnapshot]
    package let queuedRequestCount: Int
    package let refreshCodeIssues: RefreshCodeIssuesDebugSnapshot?

    package init(
        base: ProxyDebugSnapshot,
        refreshCodeIssues: RefreshCodeIssuesDebugSnapshot?
    ) {
        self.generatedAt = base.generatedAt
        self.proxyInitialized = base.proxyInitialized
        self.cachedToolsListAvailable = base.cachedToolsListAvailable
        self.warmupInFlight = base.warmupInFlight
        self.controlPlane = base.controlPlane
        self.upstreams = base.upstreams
        self.recentTraffic = base.recentTraffic
        self.sessions = base.sessions
        self.leases = base.leases
        self.queuedRequestCount = base.queuedRequestCount
        self.refreshCodeIssues = refreshCodeIssues
    }
}

package struct HTTPSSEOpenResult {
    package let bufferedNotifications: [Data]

    package init(bufferedNotifications: [Data]) {
        self.bufferedNotifications = bufferedNotifications
    }
}

package final class HTTPControlService: Sendable {
    private let runtimeCoordinator: any RuntimeCoordinating
    private let refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator?
    private let refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState?

    package init(
        runtimeCoordinator: any RuntimeCoordinating,
        refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator? = nil,
        refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState? = nil
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
            HTTPDebugSnapshot(
                base: runtimeCoordinator.debugSnapshot(
                    includeSensitiveDebugPayloads: includeSensitiveDebugPayloads
                ),
                refreshCodeIssues: includeSensitiveDebugPayloads
                    ? refreshCodeIssuesDebugState?.snapshot()
                    : nil
            )
        )
    }

    package func openSSE(sessionID: String, channel: Channel) -> HTTPSSEOpenResult {
        let session = runtimeCoordinator.session(id: sessionID)
        let hadClients = session.notificationHub.hasSseClients
        session.notificationHub.addSse(channel)
        let bufferedNotifications = hadClients ? [] : session.router.drainBufferedNotifications()
        return HTTPSSEOpenResult(bufferedNotifications: bufferedNotifications)
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
