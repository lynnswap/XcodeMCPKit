import XcodeMCPCore
import XcodeMCPProcessRuntime
import Foundation

package struct XcodeProcessRoute: Sendable, Equatable {
    package let target: XcodeProcessTarget
    package let upstreamIndices: [Int]

    package var primaryUpstreamIndex: Int? {
        upstreamIndices.first
    }

    package init(target: XcodeProcessTarget, upstreamIndices: [Int]) {
        self.target = target
        self.upstreamIndices = upstreamIndices
    }
}
