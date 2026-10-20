import Foundation
import XcodeMCPCore

package struct ProxySessionID: Hashable, Sendable {
    package let rawValue: String

    package init(rawValue: String) {
        precondition(rawValue.isEmpty == false, "proxy session ID must not be empty")
        self.rawValue = rawValue
    }
}

/// One JSON-RPC message from a client.
package struct ProxyRuntimeRequest: Sendable {
    package let data: Data
    package let decodedJSON: JSONValue?

    package init(data: Data) {
        self.data = data
        self.decodedJSON = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.init(any:))
    }

    package init(json: JSONValue) throws {
        self.data = try JSONSerialization.data(withJSONObject: json.foundationObject)
        self.decodedJSON = json
    }
}

/// The runtime's answer to a client message. HTTP chooses the status and headers.
package enum ProxyRuntimeReply: Sendable {
    /// One JSON-RPC response object, carrying a result or an error.
    case response(Data)
    /// A client notification or response, which has no reply.
    case accepted
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

/// The runtime side of one MCP session, which the HTTP gateway creates, uses, and ends.
package protocol ProxyRuntimeSession: Sendable {
    /// Handles one client message and returns its reply. Cancelling the calling task cancels the
    /// request, which then replies without waiting for its host.
    func handle(_ message: ProxyRuntimeRequest) async -> ProxyRuntimeReply

    /// Ends the session: cancels its requests and releases what it references. Later calls do nothing.
    func close()
}

/// The runtime cannot open sessions while it stops or resets.
package struct ProxyRuntimeUnavailable: Error {
    package init() {}
}

package protocol ProxyRuntimeServing: Sendable {
    func start()
    func cancelForDeinit()
    func shutdown() async
    /// Opens a session. `notify` receives the host notifications meant for it, such as progress
    /// for its requests.
    func openSession(_ id: ProxySessionID, notify: @escaping @Sendable (Data) -> Void) throws -> any ProxyRuntimeSession
    func snapshot() -> ProxyRuntimeSnapshot
    func debugSnapshotData(includeSensitivePayloads: Bool) -> Data?
    func reset() async
}
