import Foundation
import ProxyMCP

package enum ToolRoutingDecision: Sendable {
    case forward(preferredUpstreamIndex: Int?)
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
