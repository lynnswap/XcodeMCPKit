import Foundation
import ProxyCore
import ProxyMCP

enum MCPErrorResponder {
    static func errorResponseData(
        id: RPCID?,
        code: Int,
        message: String,
        data: JSONValue? = nil,
        forceBatchArray: Bool = false
    ) -> Data? {
        let errorObject = makeErrorObject(code: code, message: message, data: data)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id?.value.foundationObject ?? NSNull(),
            "error": errorObject,
        ]
        let payload: Any = forceBatchArray ? [response] : response
        guard JSONSerialization.isValidJSONObject(payload) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    static func errorResponseData(
        ids: [RPCID],
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
        let errorObject = makeErrorObject(code: code, message: message, data: data)
        let responses: [[String: Any]] = ids.map { id in
            [
                "jsonrpc": "2.0",
                "id": id.value.foundationObject,
                "error": errorObject,
            ]
        }
        guard JSONSerialization.isValidJSONObject(responses) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: responses, options: [])
    }

    static func requestMetadata(from data: Data) -> (ids: [RPCID], isBatch: Bool) {
        requestMetadata(fromParsed: try? JSONSerialization.jsonObject(with: data, options: []))
    }

    static func requestMetadata(fromParsed json: Any?) -> (ids: [RPCID], isBatch: Bool) {
        let metadata = JSONRPCMessageInspector.requestMetadata(fromParsed: json)
        return (metadata.ids, metadata.isBatch)
    }

    private static func makeErrorObject(
        code: Int,
        message: String,
        data: JSONValue?
    ) -> [String: Any] {
        var error: [String: Any] = [
            "code": code,
            "message": message,
        ]
        if let data {
            error["data"] = data.foundationObject
        }
        return error
    }
}
