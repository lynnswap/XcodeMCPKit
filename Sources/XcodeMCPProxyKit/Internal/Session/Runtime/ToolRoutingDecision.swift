import Foundation
import XcodeMCPCore
import XcodeMCPProcessRuntime

enum ToolRoutingDecision: Sendable {
    case forward(preferredUpstreamIndex: Int?)
    case forwardAny(preferredUpstreamIndices: [Int])
    case localXcodeListWindows
    case reject(errors: [ToolRoutingError], forceBatchArray: Bool)
}

struct ToolRoutingError: Sendable {
    let id: JSONRPC.ID
    let message: String

    init(id: JSONRPC.ID, message: String) {
        self.id = id
        self.message = message
    }
}
