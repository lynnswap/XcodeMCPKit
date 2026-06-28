import XcodeMCPCore
import Foundation

struct UpstreamSlotID: Sendable, Hashable, Comparable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static func < (lhs: UpstreamSlotID, rhs: UpstreamSlotID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct XcodeProcessID: Sendable, Hashable, Comparable {
    let rawValue: pid_t

    init(rawValue: pid_t) {
        self.rawValue = rawValue
    }

    init(_ target: XcodeProcessTarget) {
        self.init(rawValue: target.processID)
    }

    static func < (lhs: XcodeProcessID, rhs: XcodeProcessID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct XcodeVersionKey: Sendable, Hashable {
    let xcodeVersion: String
    let developerDir: String
    let mcpbridgePath: String

    init(
        xcodeVersion: String,
        developerDir: String,
        mcpbridgePath: String
    ) {
        self.xcodeVersion = xcodeVersion
        self.developerDir = developerDir
        self.mcpbridgePath = mcpbridgePath
    }

    init(_ target: XcodeProcessTarget) {
        self.init(
            xcodeVersion: target.xcodeVersion,
            developerDir: target.developerDir,
            mcpbridgePath: target.mcpbridgePath
        )
    }
}

enum UpstreamSelectionScope: Sendable, Hashable {
    case any
    case slots([UpstreamSlotID])
    case xcodeProcess(XcodeProcessID)
    case xcodeVersion(XcodeVersionKey)
}

struct XcodeProcessBinding: Sendable, Equatable {
    let processID: XcodeProcessID
    let versionKey: XcodeVersionKey
    let target: XcodeProcessTarget
    let slotIDs: [UpstreamSlotID]

    init(
        processID: XcodeProcessID,
        versionKey: XcodeVersionKey,
        target: XcodeProcessTarget,
        slotIDs: [UpstreamSlotID]
    ) {
        self.processID = processID
        self.versionKey = versionKey
        self.target = target
        self.slotIDs = slotIDs
    }

    init(target: XcodeProcessTarget, slotIDs: [UpstreamSlotID]) {
        self.init(
            processID: XcodeProcessID(target),
            versionKey: XcodeVersionKey(target),
            target: target,
            slotIDs: slotIDs
        )
    }
}

struct UpstreamTopologySnapshot: Sendable, Equatable {
    let slotIDs: [UpstreamSlotID]
    let xcodeProcessBindings: [XcodeProcessBinding]

    init(
        slotIDs: [UpstreamSlotID],
        xcodeProcessBindings: [XcodeProcessBinding] = []
    ) {
        self.slotIDs = slotIDs
        self.xcodeProcessBindings = xcodeProcessBindings
    }

    init(
        slotCount: Int,
        xcodeProcessBindings: [XcodeProcessBinding] = []
    ) {
        self.init(
            slotIDs: (0..<max(0, slotCount)).map { UpstreamSlotID(rawValue: $0) },
            xcodeProcessBindings: xcodeProcessBindings
        )
    }

    static let empty = UpstreamTopologySnapshot(slotIDs: [])

    func xcodeProcessRoutes() -> [XcodeProcessRoute] {
        xcodeProcessBindings.map { binding in
            XcodeProcessRoute(
                target: binding.target,
                upstreamIndices: binding.slotIDs.map(\.rawValue)
            )
        }
    }

    func slotIDs(matching scope: UpstreamSelectionScope) -> [UpstreamSlotID] {
        switch scope {
        case .any:
            return slotIDs
        case .slots(let requestedSlotIDs):
            return validUniqueSlotIDs(requestedSlotIDs)
        case .xcodeProcess(let processID):
            guard let binding = xcodeProcessBindings.first(where: { binding in
                binding.processID == processID
            }) else {
                return []
            }
            return topologyOrderedSlotIDs(containedIn: binding.slotIDs)
        case .xcodeVersion(let versionKey):
            let matchingSlotIDs = xcodeProcessBindings.flatMap { binding -> [UpstreamSlotID] in
                binding.versionKey == versionKey ? binding.slotIDs : []
            }
            return topologyOrderedSlotIDs(containedIn: matchingSlotIDs)
        }
    }

    func binding(forSlotID slotID: UpstreamSlotID) -> XcodeProcessBinding? {
        xcodeProcessBindings.first { binding in
            binding.slotIDs.contains(slotID)
        }
    }

    func binding(forUpstreamIndex upstreamIndex: Int) -> XcodeProcessBinding? {
        binding(forSlotID: UpstreamSlotID(rawValue: upstreamIndex))
    }

    private func validUniqueSlotIDs(_ requestedSlotIDs: [UpstreamSlotID]) -> [UpstreamSlotID] {
        let knownSlotIDs = Set(slotIDs)
        var seenSlotIDs = Set<UpstreamSlotID>()
        return requestedSlotIDs.filter { slotID in
            guard knownSlotIDs.contains(slotID),
                  seenSlotIDs.contains(slotID) == false else {
                return false
            }
            seenSlotIDs.insert(slotID)
            return true
        }
    }

    private func topologyOrderedSlotIDs(containedIn candidateSlotIDs: [UpstreamSlotID])
        -> [UpstreamSlotID]
    {
        let candidates = Set(candidateSlotIDs)
        return slotIDs.filter { candidates.contains($0) }
    }
}
