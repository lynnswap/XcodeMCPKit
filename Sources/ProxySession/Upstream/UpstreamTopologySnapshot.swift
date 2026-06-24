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
    case xcodeProcess(XcodeProcessID)
    case xcodeVersion(XcodeVersionKey)
}

package struct XcodeProcessBinding: Sendable, Equatable {
    package let processID: XcodeProcessID
    package let versionKey: XcodeVersionKey
    package let target: XcodeProcessTarget
    package let slotIDs: [UpstreamSlotID]
    package let selectionScope: UpstreamSelectionScope

    package init(
        processID: XcodeProcessID,
        versionKey: XcodeVersionKey,
        target: XcodeProcessTarget,
        slotIDs: [UpstreamSlotID],
        selectionScope: UpstreamSelectionScope
    ) {
        self.processID = processID
        self.versionKey = versionKey
        self.target = target
        self.slotIDs = slotIDs
        self.selectionScope = selectionScope
    }

    package init(target: XcodeProcessTarget, slotIDs: [UpstreamSlotID]) {
        let processID = XcodeProcessID(target)
        self.init(
            processID: processID,
            versionKey: XcodeVersionKey(target),
            target: target,
            slotIDs: slotIDs,
            selectionScope: .xcodeProcess(processID)
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

    package func binding(forSlotID slotID: UpstreamSlotID) -> XcodeProcessBinding? {
        xcodeProcessBindings.first { binding in
            binding.slotIDs.contains(slotID)
        }
    }

    package func binding(forUpstreamIndex upstreamIndex: Int) -> XcodeProcessBinding? {
        binding(forSlotID: UpstreamSlotID(rawValue: upstreamIndex))
    }
}
