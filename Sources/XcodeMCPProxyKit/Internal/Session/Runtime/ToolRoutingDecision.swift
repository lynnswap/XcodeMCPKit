import Foundation
import XcodeMCPCore
import XcodeMCPProcessRuntime
import XcodeMCPProxyRuntime

package enum ToolRoutingDecision: Sendable {
    case forward(preferredUpstreamIndex: Int?)
    case forwardAny(preferredUpstreamIndices: [Int])
    case localXcodeListWindows
    case reject(errors: [ToolRoutingError], forceBatchArray: Bool)
}

package struct ToolRoutingError: Sendable {
    package let id: JSONRPC.ID
    package let message: String

    package init(id: JSONRPC.ID, message: String) {
        self.id = id
        self.message = message
    }
}
