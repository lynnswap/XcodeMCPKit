import Foundation
import XcodeMCPCore
import XcodeMCPProxyRuntimeContract

struct NativeBrokerWorkspace: Sendable, Equatable {
    let identifier: String
    let hostIdentifier: String
    let generation: UInt64
    let nativeIdentifier: String
    let gui: Bool
    let path: String?
    let name: String

    /// Identifies the native model a handle refers to, independent of the session that holds it.
    struct Scope: Hashable, Sendable {
        let hostIdentifier: String
        let generation: UInt64
        let nativeIdentifier: String
    }

    var scope: Scope { Scope(hostIdentifier: hostIdentifier, generation: generation, nativeIdentifier: nativeIdentifier) }

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
    let generation: UInt64
    let nativeIdentifier: String
    let workspace: NativeBrokerWorkspace?
}

struct NativeBrokerLaunchSession: Sendable, Equatable {
    let identifier: String
    let hostIdentifier: String
    let generation: UInt64
    let nativeIdentifier: String
    let workspace: NativeBrokerWorkspace?
}

extension NativeBrokerSession {
    func bindWorkspace(host: NativeBrokerHost, generation: UInt64, nativeIdentifier: String,
                       path: String?, name: String?) throws -> NativeBrokerWorkspace {
        try state.withLockedValue { state in
            guard !state.closed else { throw CancellationError() }
            // Validate while holding the registry lock so a replacement notification
            // cannot prune old references before a late response inserts another one.
            guard host.status.runningGeneration == generation else {
                throw NativeHostBrokerError("The Xcode connection changed before its reference could be registered; try again")
            }
            if let existing = state.workspaces.values.first(where: {
                $0.hostIdentifier == host.identifier && $0.generation == generation && $0.nativeIdentifier == nativeIdentifier
            }) { return existing }
            let workspace = NativeBrokerWorkspace(identifier: Self.reference(prefix: "w"),
                hostIdentifier: host.identifier, generation: generation, nativeIdentifier: nativeIdentifier,
                gui: host.guiProcess != nil, path: path,
                name: name ?? path.map { URL(filePath: $0).deletingPathExtension().lastPathComponent }
                    ?? nativeIdentifier)
            state.workspaces[workspace.identifier] = workspace
            return workspace
        }
    }

    func bindDeviceSession(host: NativeBrokerHost, generation: UInt64, nativeIdentifier: String,
                           workspace: NativeBrokerWorkspace?) throws -> NativeBrokerDeviceSession {
        try state.withLockedValue { state in
            guard !state.closed else { throw CancellationError() }
            guard host.status.runningGeneration == generation else {
                throw NativeHostBrokerError("The Xcode connection changed before its reference could be registered; try again")
            }
            if let existing = state.deviceSessions.values.first(where: {
                $0.hostIdentifier == host.identifier && $0.generation == generation && $0.nativeIdentifier == nativeIdentifier
            }) { return existing }
            let session = NativeBrokerDeviceSession(identifier: Self.reference(prefix: "d"),
                hostIdentifier: host.identifier, generation: generation, nativeIdentifier: nativeIdentifier,
                workspace: workspace)
            state.deviceSessions[session.identifier] = session
            return session
        }
    }

    func bindLaunchSession(host: NativeBrokerHost, generation: UInt64, nativeIdentifier: String,
                           workspace: NativeBrokerWorkspace?) throws -> NativeBrokerLaunchSession {
        try state.withLockedValue { state in
            guard !state.closed else { throw CancellationError() }
            guard host.status.runningGeneration == generation else {
                throw NativeHostBrokerError("The Xcode connection changed before its reference could be registered; try again")
            }
            if let existing = state.launchSessions.values.first(where: {
                $0.hostIdentifier == host.identifier && $0.generation == generation && $0.nativeIdentifier == nativeIdentifier
            }) { return existing }
            let launch = NativeBrokerLaunchSession(identifier: Self.reference(prefix: "r"),
                hostIdentifier: host.identifier, generation: generation, nativeIdentifier: nativeIdentifier,
                workspace: workspace)
            state.launchSessions[launch.identifier] = launch
            return launch
        }
    }

    /// Workspaces this session references through handles, device sessions, or launch sessions.
    func referencedWorkspaces() -> [NativeBrokerWorkspace] {
        state.withLockedValue { state in
            Array(state.workspaces.values) + state.deviceSessions.values.compactMap(\.workspace)
                + state.launchSessions.values.compactMap(\.workspace)
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
            guard !state.closed, host.status.runningGeneration == workspace.generation else { return }
            state.workspaces[workspace.identifier] = workspace
        }
    }

    /// Drops references created by a host process that has ended.
    @discardableResult
    func invalidateReferences(hostIdentifier: String, endedGeneration: UInt64) -> Bool {
        state.withLockedValue { state in
            func ended(_ host: String, _ generation: UInt64) -> Bool {
                host == hostIdentifier && generation <= endedGeneration
            }
            let previousCount = state.workspaces.count + state.deviceSessions.count + state.launchSessions.count
            state.workspaces = state.workspaces.filter { !ended($0.value.hostIdentifier, $0.value.generation) }
            state.deviceSessions = state.deviceSessions.filter { !ended($0.value.hostIdentifier, $0.value.generation) }
            state.launchSessions = state.launchSessions.filter { !ended($0.value.hostIdentifier, $0.value.generation) }
            return previousCount != state.workspaces.count + state.deviceSessions.count + state.launchSessions.count
        }
    }

    private static func reference(prefix: String) -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
