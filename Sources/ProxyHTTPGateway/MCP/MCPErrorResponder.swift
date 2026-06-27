import Foundation
import ProxyCore
import XcodeMCPRuntime

enum MCPErrorResponder {
    static func errorResponseData(
        id: JSONRPC.ID?,
        code: Int,
        message: String,
        data: JSONValue? = nil,
        forceBatchArray: Bool = false
    ) -> Data? {
        try? JSONRPC.Wire.errorResponseData(
            id: id,
            code: code,
            message: message,
            data: data,
            forceBatchArray: forceBatchArray
        )
    }

    static func errorResponseData(
        ids: [JSONRPC.ID],
        code: Int,
        message: String,
        data: JSONValue? = nil,
        forceBatchArray: Bool = false
    ) -> Data? {
        if ids.isEmpty {
            return errorResponseData(
                id: nil,
                code: code,
                message: message,
                data: data,
                forceBatchArray: forceBatchArray
            )
        }
        if ids.count == 1 {
            return errorResponseData(
                id: ids[0],
                code: code,
                message: message,
                data: data,
                forceBatchArray: forceBatchArray
            )
        }
        return try? JSONRPC.Wire.errorResponseData(
            ids: ids,
            code: code,
            message: message,
            data: data,
            forceBatchArray: forceBatchArray
        )
    }

    static func requestMetadata(from data: Data) -> (ids: [JSONRPC.ID], isBatch: Bool) {
        requestMetadata(fromParsed: try? JSONSerialization.jsonObject(with: data, options: []))
    }

    static func requestMetadata(fromParsed json: Any?) -> (ids: [JSONRPC.ID], isBatch: Bool) {
        let metadata = JSONRPC.Message.Inspector.requestMetadata(fromParsed: json)
        return (metadata.ids, metadata.isBatch)
    }
}
