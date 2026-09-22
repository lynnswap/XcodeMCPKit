import Foundation
import NIOCore
import XcodeMCPCore

package struct ProxySessionID: Hashable, Sendable {
    package let rawValue: String

    package init(rawValue: String) {
        precondition(rawValue.isEmpty == false, "proxy session ID must not be empty")
        self.rawValue = rawValue
    }
}

package enum ProxyRuntimeEvent: Sendable {
    case sessionOpened(sessionID: ProxySessionID)
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

        package init(id: Int, healthState: String, isInitialized: Bool, activeRequestCount: Int) {
            self.id = id
            self.healthState = healthState
            self.isInitialized = isInitialized
            self.activeRequestCount = activeRequestCount
        }
    }

    package let generatedAt: Date
    package let proxyInitialized: Bool
    package let catalogAvailable: Bool
    package let queuedRequestCount: Int
    package let upstreams: [Upstream]

    package init(generatedAt: Date, proxyInitialized: Bool, catalogAvailable: Bool,
                 queuedRequestCount: Int, upstreams: [Upstream]) {
        self.generatedAt = generatedAt
        self.proxyInitialized = proxyInitialized
        self.catalogAvailable = catalogAvailable
        self.queuedRequestCount = queuedRequestCount
        self.upstreams = upstreams
    }
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

    package init(xcodeTargets: [XcodeTarget], permissionDialogProcessIDs: [pid_t]) {
        self.xcodeTargets = xcodeTargets
        self.permissionDialogProcessIDs = permissionDialogProcessIDs
    }
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
    ) -> (any ProxyRuntimeRequestOperating)?
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

