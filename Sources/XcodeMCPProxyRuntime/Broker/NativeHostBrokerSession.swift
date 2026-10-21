import Foundation
import NIOConcurrencyHelpers
import XcodeMCPCore
import XcodeMCPProxyRuntimeContract

/// One Xcode installation's headless host or one running GUI Xcode process, with the
/// connection that owns its process.
final class NativeBrokerHost: Sendable {
    let identifier: String
    let index: Int
    let installation: XcodeHostInstallation
    let guiProcess: XcodeGUIProcess?
    let connection: NativeHostConnection
    /// Requests that wait in the broker for a session's turn on one of this host's models. Their
    /// limit is the host queue's, which they would otherwise be in.
    let waitingRequests = NativeBrokerByteBudget(limit: 32 * 1024 * 1024)

    init(identifier: String, index: Int, installation: XcodeHostInstallation, guiProcess: XcodeGUIProcess?,
         connection: NativeHostConnection) {
        self.identifier = identifier
        self.index = index
        self.installation = installation
        self.guiProcess = guiProcess
        self.connection = connection
    }

    var status: NativeHostConnection.Status { connection.status.withLockedValue { $0 } }
}

final class NativeBrokerSession: Sendable {
    struct State: Sendable {
        var hostRequests: [String: Int] = [:]
        var closed = false
        var operations: [UUID: NativeHostBrokerOperation] = [:]
        var workspaces: [String: NativeBrokerWorkspace] = [:]
        var deviceSessions: [String: NativeBrokerDeviceSession] = [:]
        var launchSessions: [String: NativeBrokerLaunchSession] = [:]
        /// Models used by this session's running requests, counted per request.
        var admittedWorkspaces: [NativeBrokerWorkspace.Scope: Int] = [:]
        /// The scheme, run destination, and test plan this session uses in each headless model,
        /// as the host last reported them.
        var selections: [NativeBrokerWorkspace.Scope: JSONValue] = [:]

        func retainsHost(_ identifier: String) -> Bool {
            workspaces.values.contains { $0.hostIdentifier == identifier }
                || deviceSessions.values.contains { $0.hostIdentifier == identifier }
                || launchSessions.values.contains { $0.hostIdentifier == identifier }
        }

        func usesHost(_ identifier: String) -> Bool {
            !closed && (retainsHost(identifier) || hostRequests[identifier] != nil)
        }
    }
    let identifier: ProxySessionID
    /// Identifies this session to headless hosts, which keep Xcode's per-conversation state.
    let conversationID = UUID().uuidString
    /// Orders this session's operations on each headless model.
    let selectionTurns = NativeBrokerTurns<NativeBrokerWorkspace.Scope>()
    let state: NIOLockedValueBox<State>

    /// Receives the host notifications meant for this session.
    let notify: @Sendable (Data) -> Void

    init(identifier: ProxySessionID, notify: @escaping @Sendable (Data) -> Void) {
        self.identifier = identifier
        self.notify = notify
        state = NIOLockedValueBox(State())
    }

    func releaseHost(_ identifier: String) {
        state.withLockedValue { state in
            let remaining = (state.hostRequests[identifier] ?? 0) - 1
            if remaining == 0 { state.hostRequests.removeValue(forKey: identifier) }
            else { state.hostRequests[identifier] = remaining }
        }
    }

    func releaseAdmission(of workspace: NativeBrokerWorkspace) {
        state.withLockedValue { state in
            guard let count = state.admittedWorkspaces[workspace.scope] else { return }
            state.admittedWorkspaces[workspace.scope] = count > 1 ? count - 1 : nil
        }
    }

    /// Stops admission, cancels the session's requests, and completes when their work has drained.
    func close() -> Task<Void, Never> {
        let operations = state.withLockedValue { state in
            state.closed = true
            let operations = Array(state.operations.values)
            state.operations.removeAll()
            state.workspaces.removeAll()
            state.deviceSessions.removeAll()
            state.launchSessions.removeAll()
            return operations
        }
        for operation in operations { operation.cancel() }
        return Task {
            for operation in operations { await operation.waitForWorkCompletion() }
        }
    }
}
