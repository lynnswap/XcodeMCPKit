import Foundation
import ProxyCore

package struct UpstreamSlotID: Sendable, Hashable, Comparable {
    package let rawValue: Int

    package init(rawValue: Int) {
        self.rawValue = rawValue
    }

    package static func < (lhs: UpstreamSlotID, rhs: UpstreamSlotID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package struct XcodeProcessID: Sendable, Hashable, Comparable {
    package let rawValue: pid_t

    package init(rawValue: pid_t) {
        self.rawValue = rawValue
    }

    package init(_ target: XcodeProcessTarget) {
        self.init(rawValue: target.processID)
    }

    package static func < (lhs: XcodeProcessID, rhs: XcodeProcessID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package struct XcodeVersionKey: Sendable, Hashable {
    package let xcodeVersion: String
    package let developerDir: String
    package let mcpbridgePath: String

    package init(
        xcodeVersion: String,
        developerDir: String,
        mcpbridgePath: String
    ) {
        self.xcodeVersion = xcodeVersion
        self.developerDir = developerDir
        self.mcpbridgePath = mcpbridgePath
    }

    package init(_ target: XcodeProcessTarget) {
        self.init(
            xcodeVersion: target.xcodeVersion,
            developerDir: target.developerDir,
            mcpbridgePath: target.mcpbridgePath
        )
    }
}

package enum UpstreamSelectionScope: Sendable, Hashable {
    case any
    case slots([UpstreamSlotID])
    case xcodeProcess(XcodeProcessID)
    case xcodeVersion(XcodeVersionKey)
}

package struct XcodeProcessBinding: Sendable, Equatable {
    package let processID: XcodeProcessID
    package let versionKey: XcodeVersionKey
    package let target: XcodeProcessTarget
    package let slotIDs: [UpstreamSlotID]

    package init(
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

    package init(target: XcodeProcessTarget, slotIDs: [UpstreamSlotID]) {
        self.init(
            processID: XcodeProcessID(target),
            versionKey: XcodeVersionKey(target),
            target: target,
            slotIDs: slotIDs
        )
    }
}

package struct UpstreamTopologySnapshot: Sendable, Equatable {
    package let slotIDs: [UpstreamSlotID]
    package let xcodeProcessBindings: [XcodeProcessBinding]

    package init(
        slotIDs: [UpstreamSlotID],
        xcodeProcessBindings: [XcodeProcessBinding] = []
    ) {
        self.slotIDs = slotIDs
        self.xcodeProcessBindings = xcodeProcessBindings
    }

    package init(
        slotCount: Int,
        xcodeProcessBindings: [XcodeProcessBinding] = []
    ) {
        self.init(
            slotIDs: (0..<max(0, slotCount)).map { UpstreamSlotID(rawValue: $0) },
            xcodeProcessBindings: xcodeProcessBindings
        )
    }

    package static let empty = UpstreamTopologySnapshot(slotIDs: [])

    package func xcodeProcessRoutes() -> [XcodeProcessRoute] {
        xcodeProcessBindings.map { binding in
            XcodeProcessRoute(
                target: binding.target,
                upstreamIndices: binding.slotIDs.map(\.rawValue)
            )
        }
    }

    package func slotIDs(matching scope: UpstreamSelectionScope) -> [UpstreamSlotID] {
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

    package func binding(forSlotID slotID: UpstreamSlotID) -> XcodeProcessBinding? {
        xcodeProcessBindings.first { binding in
            binding.slotIDs.contains(slotID)
        }
    }

    package func binding(forUpstreamIndex upstreamIndex: Int) -> XcodeProcessBinding? {
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
