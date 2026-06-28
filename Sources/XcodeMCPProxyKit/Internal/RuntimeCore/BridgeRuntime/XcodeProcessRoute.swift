import XcodeMCPCore
import Foundation

struct XcodeProcessRoute: Sendable, Equatable {
    let target: XcodeProcessTarget
    let upstreamIndices: [Int]

    var primaryUpstreamIndex: Int? {
        upstreamIndices.first
    }

    init(target: XcodeProcessTarget, upstreamIndices: [Int]) {
        self.target = target
        self.upstreamIndices = upstreamIndices
    }
}
