import Foundation
import XcodeMCPCore

package struct ServerSessionID: Hashable, Sendable {
    package let rawValue: String

    package init(rawValue: String) {
        precondition(rawValue.isEmpty == false, "server session ID must not be empty")
        self.rawValue = rawValue
    }
}

/// One JSON-RPC message from a client.
package struct ServerRuntimeRequest: Sendable {
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
package enum ServerRuntimeReply: Sendable {
    /// One JSON-RPC response object, carrying a result or an error.
    case response(Data)
    /// A client notification or response, which has no reply.
    case accepted
}

package struct ServerRuntimeSnapshot: Sendable {
    /// One owned headless host for an Xcode installation.
    package struct Host: Equatable, Sendable {
        package enum State: Equatable, Sendable {
            case stopped
            case starting
            case running
        }

        package let identifier: String
        package let developerDirectory: URL
        package let state: State
        package let activeRequestCount: Int

        package init(identifier: String, developerDirectory: URL,
                     state: State, activeRequestCount: Int) {
            self.identifier = identifier
            self.developerDirectory = developerDirectory
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

/// A client message that the runtime has received.
package protocol ServerRuntimeCall: Sendable {
    /// The message's reply, once the runtime has handled it.
    var reply: ServerRuntimeReply { get async }

    /// Cancels the request, which then replies without waiting for its host.
    func cancel()
}

/// The runtime side of one MCP session, which the HTTP gateway creates, uses, and ends.
package protocol ServerRuntimeSession: Sendable {
    /// Receives one client message. A session receives its messages in call order, so a
    /// cancellation finds every request received before it.
    func receive(_ message: ServerRuntimeRequest) -> any ServerRuntimeCall

    /// Ends the session: cancels its requests and releases what it references. Later calls do nothing.
    func close()
}

/// The runtime cannot open sessions while it stops or resets.
package struct ServerRuntimeUnavailable: Error {
    package init() {}
}

package protocol ServerRuntimeServing: Sendable {
    func start()
    func cancelForDeinit()
    func shutdown() async
    /// Opens a session. `notify` receives the host notifications meant for it, such as progress
    /// for its requests.
    func openSession(_ id: ServerSessionID, notify: @escaping @Sendable (Data) -> Void) throws -> any ServerRuntimeSession
    func snapshot() -> ServerRuntimeSnapshot
    func debugSnapshotData(includeSensitivePayloads: Bool) -> Data?
    func reset() async
}
