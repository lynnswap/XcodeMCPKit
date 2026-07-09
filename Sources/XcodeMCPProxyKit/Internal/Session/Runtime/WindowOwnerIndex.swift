import CryptoKit
import Foundation

struct WindowOwnerIndex: Sendable, Equatable {
    struct Identity: Sendable, Hashable {
        let processID: pid_t
        let rawTabIdentifier: String
        let proxyTabIdentifier: String
        let workspacePath: String

        init(processID: pid_t, rawTabIdentifier: String, workspacePath: String) {
            self.processID = processID
            self.rawTabIdentifier = rawTabIdentifier
            self.proxyTabIdentifier = Self.proxyTabIdentifier(
                processID: processID,
                rawTabIdentifier: rawTabIdentifier
            )
            self.workspacePath = workspacePath
        }

        private static func proxyTabIdentifier(
            processID: pid_t,
            rawTabIdentifier: String
        ) -> String {
            let input = "\(processID)\u{0}\(rawTabIdentifier)"
            let digest = SHA256.hash(data: Data(input.utf8))
            let token = digest.map { byte -> String in
                let hex = String(byte, radix: 16)
                return byte < 16 ? "0\(hex)" : hex
            }.joined()
            return "\(WindowOwnerIndex.proxyTabIdentifierPrefix)\(token)"
        }
    }

    enum ProcessOwnerLookup: Sendable, Equatable {
        case resolved(pid_t)
        case unresolved
        case conflicting(Set<pid_t>)
    }

    static let proxyTabIdentifierPrefix = "xcode-mcpkit:"

    private var identities: [Identity] = []

    var isEmpty: Bool {
        identities.isEmpty
    }

    mutating func removeAll() {
        identities.removeAll()
    }

    @discardableResult
    mutating func remove(processID: pid_t) -> Bool {
        let countBefore = identities.count
        identities.removeAll { $0.processID == processID }
        return identities.count != countBefore
    }

    @discardableResult
    mutating func record(processID: pid_t, entries: [XcodeListWindowsEntry]) -> Bool {
        let before = identities
        for entry in entries {
            let identity = Identity(
                processID: processID,
                rawTabIdentifier: entry.tabIdentifier,
                workspacePath: entry.workspacePath
            )
            if identities.contains(identity) == false {
                identities.append(identity)
            }
        }
        return identities != before
    }

    func owner(forWorkspacePath workspacePath: String) -> ProcessOwnerLookup {
        let processIDs = Set(
            identities
                .filter { $0.workspacePath == workspacePath }
                .map(\.processID)
        )
        switch processIDs.count {
        case 0:
            return .unresolved
        case 1:
            return .resolved(processIDs.first!)
        default:
            return .conflicting(processIDs)
        }
    }

    func identity(forProxyTabIdentifier tabIdentifier: String) -> Identity? {
        identities.first { $0.proxyTabIdentifier == tabIdentifier }
    }

    func identities(forRawTabIdentifier tabIdentifier: String) -> [Identity] {
        identities.filter { $0.rawTabIdentifier == tabIdentifier }
    }

    func identities(
        workspacePath: String,
        processID: pid_t
    ) -> [Identity] {
        identities.filter {
            $0.workspacePath == workspacePath && $0.processID == processID
        }
    }

    func proxyTabIdentifier(
        processID: pid_t,
        rawTabIdentifier: String,
        workspacePath: String
    ) -> String {
        identity(
            processID: processID,
            rawTabIdentifier: rawTabIdentifier,
            workspacePath: workspacePath
        )?.proxyTabIdentifier
            ?? Identity(
                processID: processID,
                rawTabIdentifier: rawTabIdentifier,
                workspacePath: workspacePath
            ).proxyTabIdentifier
    }

    func identity(
        processID: pid_t,
        rawTabIdentifier: String,
        workspacePath: String
    ) -> Identity? {
        identities.first {
            $0.processID == processID
                && $0.rawTabIdentifier == rawTabIdentifier
                && $0.workspacePath == workspacePath
        }
    }

    func tabOwnerCountsByProcessID() -> [pid_t: Int] {
        identities.reduce(into: [:]) { counts, identity in
            counts[identity.processID, default: 0] += 1
        }
    }

    func workspaceOwnerCountsByProcessID() -> [pid_t: Int] {
        var workspacePathsByProcessID: [pid_t: Set<String>] = [:]
        for identity in identities {
            workspacePathsByProcessID[identity.processID, default: []].insert(identity.workspacePath)
        }
        return workspacePathsByProcessID.mapValues(\.count)
    }
}
