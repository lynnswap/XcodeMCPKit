import Foundation
import NIO
import ProxyFeatureXcode
import ProxyRuntime

package struct HTTPDebugSnapshot: Codable, Sendable {
    package let generatedAt: Date
    package let proxyInitialized: Bool
    package let cachedToolsListAvailable: Bool
    package let warmupInFlight: Bool
    package let upstreams: [ProxyUpstreamDebugSnapshot]
    package let recentTraffic: [ProxyDebugTrafficEvent]
    package let refreshCodeIssues: RefreshCodeIssuesDebugSnapshot?

    package init(
        base: ProxyDebugSnapshot,
        refreshCodeIssues: RefreshCodeIssuesDebugSnapshot?
    ) {
        self.generatedAt = base.generatedAt
        self.proxyInitialized = base.proxyInitialized
        self.cachedToolsListAvailable = base.cachedToolsListAvailable
        self.warmupInFlight = base.warmupInFlight
        self.upstreams = base.upstreams
        self.recentTraffic = base.recentTraffic
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
    private let refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState?

    package init(
        runtimeCoordinator: any RuntimeCoordinating,
        refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState? = nil
    ) {
        self.runtimeCoordinator = runtimeCoordinator
        self.refreshCodeIssuesDebugState = refreshCodeIssuesDebugState
    }

    package func debugSnapshotData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(
            HTTPDebugSnapshot(
                base: runtimeCoordinator.debugSnapshot(),
                refreshCodeIssues: refreshCodeIssuesDebugState?.snapshot()
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
}
