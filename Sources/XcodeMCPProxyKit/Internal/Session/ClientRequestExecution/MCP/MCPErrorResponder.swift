import Foundation
import XcodeMCPKit

enum MCPErrorResponder {
    static func errorResponseData(
        id: JSONRPC.ID?,
        code: Int,
        message: String,
        data: JSONValue? = nil
    ) -> Data? {
        try? JSONRPC.Wire.errorResponseData(
            id: id,
            code: code,
            message: message,
            data: data
        )
    }
}
