import Foundation
import XcodeMCPCore
import XcodeMCPProxyRuntimeContract

struct NativeBrokerWorkspace: Sendable, Equatable {
    let identifier: String
    let hostIdentifier: String
    let source: ProxyRuntimeUpstreamSource
    let nativeIdentifier: String
    let gui: Bool
    let path: String?
    let name: String

    /// Identifies the native model a handle refers to, independent of the session that holds it.
    struct Scope: Hashable, Sendable {
        let hostIdentifier: String
        let source: ProxyRuntimeUpstreamSource
        let nativeIdentifier: String
    }

    var scope: Scope { Scope(hostIdentifier: hostIdentifier, source: source, nativeIdentifier: nativeIdentifier) }

    func hasSameNativeScope(as other: Self) -> Bool { scope == other.scope }

    var descriptor: JSONValue {
        var fields: [String: JSONValue] = [
            "workspaceIdentifier": .string(identifier),
            "name": .string(name),
            "kind": .string(gui ? "gui" : "headless"),
        ]
        if let path { fields["path"] = .string(path) }
        return .object(fields)
    }
}

struct NativeBrokerWorkspaceEntry: Sendable {
    let nativeIdentifier: String
    let path: String
}

struct NativeBrokerDeviceSession: Sendable, Equatable {
    let identifier: String
    let hostIdentifier: String
    let source: ProxyRuntimeUpstreamSource
    let nativeIdentifier: String
    let workspace: NativeBrokerWorkspace?
}

struct NativeBrokerLaunchSession: Sendable, Equatable {
    let identifier: String
    let hostIdentifier: String
    let source: ProxyRuntimeUpstreamSource
    let nativeIdentifier: String
    let workspace: NativeBrokerWorkspace?
}

extension NativeBrokerSession {
    /// Returns the session's handle for a native workspace and whether this call created it.
    func bindWorkspace(host: NativeBrokerHost, source: ProxyRuntimeUpstreamSource, nativeIdentifier: String,
                       path: String?, name: String?) throws -> (workspace: NativeBrokerWorkspace, created: Bool) {
        try state.withLockedValue { state in
            guard !state.closed else { throw CancellationError() }
            // Validate while holding the registry lock so a replacement notification
            // cannot prune old references before a late response inserts another one.
            guard host.snapshot?.upstreamSource == source else {
                throw NativeHostBrokerError("The Xcode connection changed before its reference could be registered; try again")
            }
            if let existing = state.workspaces.values.first(where: {
                $0.hostIdentifier == host.identifier && $0.source == source && $0.nativeIdentifier == nativeIdentifier
            }) { return (existing, false) }
            let workspace = NativeBrokerWorkspace(identifier: Self.reference(prefix: "w"),
                hostIdentifier: host.identifier, source: source, nativeIdentifier: nativeIdentifier,
                gui: host.guiProcess != nil, path: path,
                name: name ?? path.map { URL(filePath: $0).deletingPathExtension().lastPathComponent }
                    ?? nativeIdentifier)
            state.workspaces[workspace.identifier] = workspace
            return (workspace, true)
        }
    }

    func bindDeviceSession(host: NativeBrokerHost, source: ProxyRuntimeUpstreamSource, nativeIdentifier: String,
                           workspace: NativeBrokerWorkspace?) throws -> NativeBrokerDeviceSession {
        try state.withLockedValue { state in
            guard !state.closed else { throw CancellationError() }
            guard host.snapshot?.upstreamSource == source else {
                throw NativeHostBrokerError("The Xcode connection changed before its reference could be registered; try again")
            }
            if let existing = state.deviceSessions.values.first(where: {
                $0.hostIdentifier == host.identifier && $0.source == source && $0.nativeIdentifier == nativeIdentifier
            }) { return existing }
            let session = NativeBrokerDeviceSession(identifier: Self.reference(prefix: "d"),
                hostIdentifier: host.identifier, source: source, nativeIdentifier: nativeIdentifier,
                workspace: workspace)
            state.deviceSessions[session.identifier] = session
            return session
        }
    }

    func bindLaunchSession(host: NativeBrokerHost, source: ProxyRuntimeUpstreamSource, nativeIdentifier: String,
                           workspace: NativeBrokerWorkspace?) throws -> NativeBrokerLaunchSession {
        try state.withLockedValue { state in
            guard !state.closed else { throw CancellationError() }
            guard host.snapshot?.upstreamSource == source else {
                throw NativeHostBrokerError("The Xcode connection changed before its reference could be registered; try again")
            }
            if let existing = state.launchSessions.values.first(where: {
                $0.hostIdentifier == host.identifier && $0.source == source && $0.nativeIdentifier == nativeIdentifier
            }) { return existing }
            let launch = NativeBrokerLaunchSession(identifier: Self.reference(prefix: "r"),
                hostIdentifier: host.identifier, source: source, nativeIdentifier: nativeIdentifier,
                workspace: workspace)
            state.launchSessions[launch.identifier] = launch
            return launch
        }
    }

    func retainsNativeWorkspace(_ workspace: NativeBrokerWorkspace) -> Bool {
        state.withLockedValue { state in
            !state.closed && (state.workspaces.values.contains { $0.hasSameNativeScope(as: workspace) }
                || state.deviceSessions.values.contains { $0.workspace?.hasSameNativeScope(as: workspace) == true }
                || state.launchSessions.values.contains { $0.workspace?.hasSameNativeScope(as: workspace) == true })
        }
    }

    /// Restores a handle whose native close failed while the session and its host connection remain.
    func restoreWorkspace(_ workspace: NativeBrokerWorkspace, host: NativeBrokerHost) {
        state.withLockedValue { state in
            // Checked under the session lock, as in `bindWorkspace`, so a concurrent invalidation cannot be undone.
            guard !state.closed, host.snapshot?.upstreamSource == workspace.source else { return }
            state.workspaces[workspace.identifier] = workspace
        }
    }

    @discardableResult
    func invalidateReferences(hostIdentifier: String, supersededBy source: ProxyRuntimeUpstreamSource?) -> Bool {
        state.withLockedValue { state in
            func obsolete(host: String, previous: ProxyRuntimeUpstreamSource) -> Bool {
                guard host == hostIdentifier else { return false }
                guard let source else { return true }
                return previous.slotID == source.slotID && previous.generation < source.generation
            }
            let previousCount = state.workspaces.count + state.deviceSessions.count + state.launchSessions.count
            state.workspaces = state.workspaces.filter { !obsolete(host: $0.value.hostIdentifier, previous: $0.value.source) }
            state.deviceSessions = state.deviceSessions.filter { !obsolete(host: $0.value.hostIdentifier, previous: $0.value.source) }
            state.launchSessions = state.launchSessions.filter { !obsolete(host: $0.value.hostIdentifier, previous: $0.value.source) }
            return previousCount != state.workspaces.count + state.deviceSessions.count + state.launchSessions.count
        }
    }

    private static func reference(prefix: String) -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
