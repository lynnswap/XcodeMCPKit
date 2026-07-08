import XcodeMCPKit
import Foundation

struct ProcessRouteID: Hashable, Sendable {
    let processID: pid_t
    let instanceGeneration: UInt64
}

struct XcodeProcessRoute: Sendable, Equatable {
    let id: ProcessRouteID
    let target: XcodeProcessTarget
    let upstreamIndices: [Int]

    var primaryUpstreamIndex: Int? {
        upstreamIndices.first
    }

    init(
        id: ProcessRouteID,
        target: XcodeProcessTarget,
        upstreamIndices: [Int]
    ) {
        self.id = id
        self.target = target
        self.upstreamIndices = upstreamIndices
    }

    init(target: XcodeProcessTarget, upstreamIndices: [Int]) {
        self.id = ProcessRouteID(
            processID: target.processID,
            instanceGeneration: 0
        )
        self.target = target
        self.upstreamIndices = upstreamIndices
    }
}
