import CryptoKit
import Foundation
import NIOConcurrencyHelpers

struct WindowEpoch: Sendable, Hashable {
    let rawValue: UInt64
}

struct WindowOwnershipIdentity: Sendable, Hashable {
    let processID: pid_t
    let rawTabIdentifier: String
    let proxyTabIdentifier: String
    let workspacePath: String

    init(processID: pid_t, rawTabIdentifier: String, workspacePath: String) {
        self.processID = processID
        self.rawTabIdentifier = rawTabIdentifier
        self.proxyTabIdentifier = Self.makeProxyTabIdentifier(
            processID: processID,
            rawTabIdentifier: rawTabIdentifier,
            workspacePath: workspacePath
        )
        self.workspacePath = workspacePath
    }

    static func makeProxyTabIdentifier(
        processID: pid_t,
        rawTabIdentifier: String,
        workspacePath: String
    ) -> String {
        let input = "\(processID)\u{0}\(rawTabIdentifier)\u{0}\(workspacePath)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let token = digest.map { byte -> String in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0\(hex)" : hex
        }.joined()
        return "\(WindowOwnershipSnapshot.proxyTabIdentifierPrefix)\(token)"
    }
}

struct WindowOwnershipSnapshot: Sendable {
    static let proxyTabIdentifierPrefix = "xcode-mcpkit:"

    let epoch: WindowEpoch
    let identities: [WindowOwnershipIdentity]

    func identity(forProxyTabIdentifier identifier: String) -> WindowOwnershipIdentity? {
        identities.first { $0.proxyTabIdentifier == identifier }
    }

    func identities(
        forRawTabIdentifier identifier: String,
        eligibleProcessIDs: Set<pid_t>
    ) -> [WindowOwnershipIdentity] {
        identities.filter {
            $0.rawTabIdentifier == identifier && eligibleProcessIDs.contains($0.processID)
        }
    }

    func identities(
        workspacePath: String,
        processID: pid_t
    ) -> [WindowOwnershipIdentity] {
        identities.filter {
            $0.workspacePath == workspacePath && $0.processID == processID
        }
    }

    func proxyTabIdentifier(
        processID: pid_t,
        rawTabIdentifier: String,
        workspacePath: String
    ) -> String {
        identities.first {
            $0.processID == processID
                && $0.rawTabIdentifier == rawTabIdentifier
                && $0.workspacePath == workspacePath
        }?.proxyTabIdentifier
            ?? WindowOwnershipIdentity.makeProxyTabIdentifier(
                processID: processID,
                rawTabIdentifier: rawTabIdentifier,
                workspacePath: workspacePath
            )
    }

    func tabOwnerCountsByProcessID() -> [pid_t: Int] {
        identities.reduce(into: [:]) { $0[$1.processID, default: 0] += 1 }
    }

    func workspaceOwnerCountsByProcessID() -> [pid_t: Int] {
        var paths: [pid_t: Set<String>] = [:]
        for identity in identities {
            paths[identity.processID, default: []].insert(identity.workspacePath)
        }
        return paths.mapValues(\.count)
    }
}

struct WindowTransition: Sendable {
    let epoch: WindowEpoch
    let didChange: Bool
}

final class WindowOwnershipAuthority: Sendable {
    private struct State: Sendable {
        var epoch = WindowEpoch(rawValue: 0)
        var identities: [WindowOwnershipIdentity] = []
    }

    private let state = NIOLockedValueBox(State())

    @discardableResult
    func record(
        processID: pid_t,
        entries: [XcodeListWindowsEntry]
    ) -> WindowTransition {
        state.withLockedValue { state in
            let replacement = entries.map {
                WindowOwnershipIdentity(
                    processID: processID,
                    rawTabIdentifier: $0.tabIdentifier,
                    workspacePath: $0.workspacePath
                )
            }
            let next = Self.normalized(
                state.identities.filter { $0.processID != processID } + replacement
            )
            guard next != state.identities else {
                return WindowTransition(epoch: state.epoch, didChange: false)
            }
            state.identities = next
            state.epoch = WindowEpoch(rawValue: state.epoch.rawValue &+ 1)
            return WindowTransition(epoch: state.epoch, didChange: true)
        }
    }

    @discardableResult
    func replace(
        _ entriesByProcessID: [pid_t: [XcodeListWindowsEntry]]
    ) -> WindowTransition {
        state.withLockedValue { state in
            let replacedProcessIDs = Set(entriesByProcessID.keys)
            var next = state.identities.filter {
                replacedProcessIDs.contains($0.processID) == false
            }
            for processID in entriesByProcessID.keys.sorted() {
                for entry in entriesByProcessID[processID] ?? [] {
                    next.append(
                        WindowOwnershipIdentity(
                            processID: processID,
                            rawTabIdentifier: entry.tabIdentifier,
                            workspacePath: entry.workspacePath
                        )
                    )
                }
            }
            next = Self.normalized(next)
            guard next != state.identities else {
                return WindowTransition(epoch: state.epoch, didChange: false)
            }
            state.identities = next
            state.epoch = WindowEpoch(rawValue: state.epoch.rawValue &+ 1)
            return WindowTransition(epoch: state.epoch, didChange: true)
        }
    }

    @discardableResult
    func remove(processID: pid_t) -> WindowTransition {
        state.withLockedValue { state in
            let next = state.identities.filter { $0.processID != processID }
            guard next != state.identities else {
                return WindowTransition(epoch: state.epoch, didChange: false)
            }
            state.identities = next
            state.epoch = WindowEpoch(rawValue: state.epoch.rawValue &+ 1)
            return WindowTransition(epoch: state.epoch, didChange: true)
        }
    }

    @discardableResult
    func removeAll() -> WindowTransition {
        state.withLockedValue { state in
            guard state.identities.isEmpty == false else {
                return WindowTransition(epoch: state.epoch, didChange: false)
            }
            state.identities.removeAll()
            state.epoch = WindowEpoch(rawValue: state.epoch.rawValue &+ 1)
            return WindowTransition(epoch: state.epoch, didChange: true)
        }
    }

    func snapshot() -> WindowOwnershipSnapshot {
        state.withLockedValue {
            WindowOwnershipSnapshot(epoch: $0.epoch, identities: $0.identities)
        }
    }

    func validate(_ epoch: WindowEpoch) -> Bool {
        state.withLockedValue { $0.epoch == epoch }
    }

    private static func normalized(
        _ identities: [WindowOwnershipIdentity]
    ) -> [WindowOwnershipIdentity] {
        Array(Set(identities)).sorted { lhs, rhs in
            if lhs.processID != rhs.processID { return lhs.processID < rhs.processID }
            if lhs.workspacePath != rhs.workspacePath {
                return lhs.workspacePath < rhs.workspacePath
            }
            if lhs.rawTabIdentifier != rhs.rawTabIdentifier {
                return lhs.rawTabIdentifier < rhs.rawTabIdentifier
            }
            return lhs.proxyTabIdentifier < rhs.proxyTabIdentifier
        }
    }
}

struct WindowOwnerQuery: Sendable {
    let tabIdentifier: String?
    let workspacePath: String?
}

struct WindowRouteProof: Sendable, Hashable {
    let windowEpoch: WindowEpoch
    let route: ProcessControlPlaneAuthority.RouteProof
}

enum WindowRouteResolution: Sendable {
    case resolved(processID: pid_t, ownerLabel: String, proof: WindowRouteProof)
    case unresolved
    case conflict(String)
}

struct WindowRoutingResolver {
    func resolve(
        _ query: WindowOwnerQuery,
        owners: WindowOwnershipSnapshot,
        routes: ProcessControlPlaneAuthority.RoutingSnapshot
    ) -> WindowRouteResolution {
        let eligibleProcessIDs = routes.processIDs
        let workspacePath = query.workspacePath.flatMap { $0.isEmpty ? nil : $0 }
        let tabIdentifier = query.tabIdentifier.flatMap { $0.isEmpty ? nil : $0 }

        func proof(processID: pid_t) -> WindowRouteProof? {
            guard let route = routes.routes.first(where: {
                $0.route.target.processID == processID
            }) else { return nil }
            return WindowRouteProof(
                windowEpoch: owners.epoch,
                route: .init(
                    exposureEpoch: routes.exposureEpoch,
                    routeID: route.route.id
                )
            )
        }

        func resolved(
            identity: WindowOwnershipIdentity,
            label: String
        ) -> WindowRouteResolution {
            guard eligibleProcessIDs.contains(identity.processID),
                  let routeProof = proof(processID: identity.processID) else {
                return .conflict("stale or unavailable XcodeMCPKit tabIdentifier '\(label)'")
            }
            return .resolved(
                processID: identity.processID,
                ownerLabel: label,
                proof: routeProof
            )
        }

        if let tabIdentifier,
           tabIdentifier.hasPrefix(WindowOwnershipSnapshot.proxyTabIdentifierPrefix) {
            guard let identity = owners.identity(forProxyTabIdentifier: tabIdentifier) else {
                return .conflict(
                    "stale or unknown XcodeMCPKit tabIdentifier '\(tabIdentifier)'"
                )
            }
            if let workspacePath, identity.workspacePath != workspacePath {
                return .conflict(
                    "tabIdentifier '\(tabIdentifier)' does not belong to workspacePath"
                        + " '\(workspacePath)'"
                )
            }
            return resolved(identity: identity, label: identity.proxyTabIdentifier)
        }

        if let workspacePath {
            let workspaceIdentities = owners.identities.filter {
                $0.workspacePath == workspacePath && eligibleProcessIDs.contains($0.processID)
            }
            let processIDs = Set(workspaceIdentities.map(\.processID))
            switch processIDs.count {
            case 0:
                if let tabIdentifier,
                   owners.identity(forProxyTabIdentifier: tabIdentifier) != nil {
                    return .conflict(
                        "tabIdentifier '\(tabIdentifier)' does not belong to workspacePath"
                            + " '\(workspacePath)'"
                    )
                }
                return .unresolved
            case 1:
                let processID = processIDs.first!
                if let tabIdentifier {
                    let rawIdentities = owners.identities(
                        forRawTabIdentifier: tabIdentifier,
                        eligibleProcessIDs: eligibleProcessIDs
                    )
                    if rawIdentities.isEmpty == false,
                       rawIdentities.contains(where: {
                           $0.processID == processID && $0.workspacePath == workspacePath
                       }) == false {
                        return .conflict(
                            "tabIdentifier '\(tabIdentifier)' does not belong to workspacePath"
                                + " '\(workspacePath)'"
                        )
                    }
                }
                guard let routeProof = proof(processID: processID) else { return .unresolved }
                return .resolved(
                    processID: processID,
                    ownerLabel: workspacePath,
                    proof: routeProof
                )
            default:
                let candidates = processIDs.map(String.init).sorted().joined(separator: ",")
                return .conflict(
                    "conflicting Xcode window owners for workspacePath '\(workspacePath)'"
                        + " (processes: \(candidates))"
                )
            }
        }

        guard let tabIdentifier else { return .unresolved }
        let rawIdentities = owners.identities(
            forRawTabIdentifier: tabIdentifier,
            eligibleProcessIDs: eligibleProcessIDs
        )
        switch rawIdentities.count {
        case 0:
            return .unresolved
        case 1:
            return resolved(identity: rawIdentities[0], label: tabIdentifier)
        default:
            let candidates = Set(rawIdentities.map(\.processID))
                .map(String.init).sorted().joined(separator: ",")
            return .conflict(
                "ambiguous raw Xcode tabIdentifier '\(tabIdentifier)'"
                    + " (processes: \(candidates))"
            )
        }
    }
}
