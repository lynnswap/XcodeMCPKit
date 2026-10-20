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
    package let decodedJSON: JSONValue?
    package var deadline: Date?
    package var headerSessionExists: Bool
    package let prefersEventStream: Bool

    package init(
        data: Data,
        headerSessionExists: Bool,
        prefersEventStream: Bool
    ) {
        self.data = data
        self.decodedJSON = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.init(any:))
        self.headerSessionExists = headerSessionExists
        self.prefersEventStream = prefersEventStream
    }

    package init(json: JSONValue, headerSessionExists: Bool, prefersEventStream: Bool) throws {
        self.data = try JSONSerialization.data(withJSONObject: json.foundationObject)
        self.decodedJSON = json
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
    case clientNotification
    case requestDeadline
}

package enum ProxyRuntimeSessionState: Sendable, Equatable {
    case missing
    case uninitialized
    case initialized(protocolVersion: String?)
}

package struct ProxyRuntimeSnapshot: Sendable {
    /// One Xcode host: a headless host for an installation, or a bridge to a running Xcode app.
    package struct Host: Equatable, Sendable {
        package enum State: Equatable, Sendable {
            case stopped
            case starting
            case running
        }

        package let identifier: String
        package let developerDirectory: URL
        /// The running Xcode app a GUI bridge connects to; `nil` for a headless host.
        package let guiProcessIdentifier: Int32?
        package let state: State
        package let activeRequestCount: Int

        package init(identifier: String, developerDirectory: URL, guiProcessIdentifier: Int32?,
                     state: State, activeRequestCount: Int) {
            self.identifier = identifier
            self.developerDirectory = developerDirectory
            self.guiProcessIdentifier = guiProcessIdentifier
            self.state = state
            self.activeRequestCount = activeRequestCount
        }
    }

    package let generatedAt: Date
    package let hosts: [Host]

    package init(generatedAt: Date, hosts: [Host]) {
        self.generatedAt = generatedAt
        self.hosts = hosts
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
    func debugSnapshotData(includeSensitivePayloads: Bool) -> Data?
    func reset() async
}
