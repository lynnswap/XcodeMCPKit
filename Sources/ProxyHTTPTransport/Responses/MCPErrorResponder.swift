import Foundation
import ProxyCore

enum MCPErrorResponder {
    static func errorResponseData(
        id: RPCID?,
        code: Int,
        message: String,
        data: JSONValue? = nil
    ) -> Data? {
        let errorObject = makeErrorObject(code: code, message: message, data: data)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id?.value.foundationObject ?? NSNull(),
            "error": errorObject,
        ]
        guard JSONSerialization.isValidJSONObject(response) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: response, options: [])
    }

    static func errorResponseData(
        ids: [RPCID],
        code: Int,
        message: String,
        data: JSONValue? = nil,
        forceBatchArray: Bool = false
    ) -> Data? {
        if ids.isEmpty {
            return errorResponseData(id: nil, code: code, message: message, data: data)
        }
        if ids.count == 1, forceBatchArray == false {
            return errorResponseData(id: ids[0], code: code, message: message, data: data)
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
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return ([], false)
        }
        if let object = json as? [String: Any] {
            if let id = object["id"], let rpcID = RPCID(any: id) {
                return ([rpcID], false)
            }
            return ([], false)
        }
        if let array = json as? [Any] {
            let ids: [RPCID] = array.compactMap { item -> RPCID? in
                guard let object = item as? [String: Any],
                      let id = object["id"] else {
                    return nil
                }
                return RPCID(any: id)
            }
            return (ids, true)
        }
        return ([], false)
    }

    static func requestIDs(from data: Data) -> [RPCID] {
        requestMetadata(from: data).ids
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
