import Foundation
import XcodeMCPCore

struct NativeBrokerWorkspace: Sendable, Equatable {
    let identifier: String
    let hostIdentifier: String
    let nativeIdentifier: String
    let gui: Bool
    let path: String?
    let name: String

    func hasSameNativeScope(as other: Self) -> Bool {
        hostIdentifier == other.hostIdentifier && nativeIdentifier == other.nativeIdentifier
    }

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
    let nativeIdentifier: String
    let workspace: NativeBrokerWorkspace?
}

struct NativeBrokerLaunchSession: Sendable, Equatable {
    let identifier: String
    let hostIdentifier: String
    let nativeIdentifier: String
    let workspace: NativeBrokerWorkspace?
}

extension NativeBrokerSession {
    func bindWorkspace(host: NativeBrokerHost, nativeIdentifier: String,
                       path: String?, name: String?) throws -> NativeBrokerWorkspace {
        try state.withLockedValue { state in
            guard !state.closed else { throw CancellationError() }
            if let existing = state.workspaces.values.first(where: {
                $0.hostIdentifier == host.identifier && $0.nativeIdentifier == nativeIdentifier
            }) { return existing }
            let workspace = NativeBrokerWorkspace(identifier: Self.reference(prefix: "w"),
                hostIdentifier: host.identifier, nativeIdentifier: nativeIdentifier,
                gui: host.guiProcess != nil, path: path,
                name: name ?? path.map { URL(filePath: $0).deletingPathExtension().lastPathComponent }
                    ?? nativeIdentifier)
            state.workspaces[workspace.identifier] = workspace
            return workspace
        }
    }

    func bindDeviceSession(host: NativeBrokerHost, nativeIdentifier: String,
                           workspace: NativeBrokerWorkspace?) throws -> NativeBrokerDeviceSession {
        try state.withLockedValue { state in
            guard !state.closed else { throw CancellationError() }
            if let existing = state.deviceSessions.values.first(where: {
                $0.hostIdentifier == host.identifier && $0.nativeIdentifier == nativeIdentifier
            }) { return existing }
            let session = NativeBrokerDeviceSession(identifier: Self.reference(prefix: "d"),
                hostIdentifier: host.identifier, nativeIdentifier: nativeIdentifier,
                workspace: workspace)
            state.deviceSessions[session.identifier] = session
            return session
        }
    }

    func bindLaunchSession(host: NativeBrokerHost, nativeIdentifier: String,
                           workspace: NativeBrokerWorkspace?) throws -> NativeBrokerLaunchSession {
        try state.withLockedValue { state in
            guard !state.closed else { throw CancellationError() }
            if let existing = state.launchSessions.values.first(where: {
                $0.hostIdentifier == host.identifier && $0.nativeIdentifier == nativeIdentifier
            }) { return existing }
            let launch = NativeBrokerLaunchSession(identifier: Self.reference(prefix: "r"),
                hostIdentifier: host.identifier, nativeIdentifier: nativeIdentifier,
                workspace: workspace)
            state.launchSessions[launch.identifier] = launch
            return launch
        }
    }

    private static func reference(prefix: String) -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
