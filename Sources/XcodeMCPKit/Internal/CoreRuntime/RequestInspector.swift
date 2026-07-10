import Foundation

package struct RequestTransform {
    package let upstreamData: Data
    package let expectsResponse: Bool
    package let idKey: String?
    package let responseID: JSONRPC.ID?
    package let method: String?
    package let toolName: String?
    package let originalID: JSONRPC.ID?
    package let isCacheableToolsListRequest: Bool
}

package enum RequestInspector {
    package static func transform(
        _ data: Data,
        parsedJSON: Any? = nil,
        sessionID: String,
        mapID: (_ sessionID: String, _ originalID: JSONRPC.ID) throws -> Int64
    ) throws -> RequestTransform {
        let json = try parsedJSON ?? JSONSerialization.jsonObject(with: data, options: [])
        guard var object = json as? [String: Any] else {
            throw JSONRPC.Wire.DecodingFailure.messageWasNotObject
        }

        let kind = JSONRPC.Message.Inspector.kind(of: object)
        let method = JSONRPC.Message.Inspector.method(from: object)
        let toolName = toolName(from: object, method: method)
        if case .request(let method, let rpcID) = kind {
            let upstreamID = try mapID(sessionID, rpcID)
            object["id"] = upstreamID
            return RequestTransform(
                upstreamData: try JSONRPC.Wire.data(from: object),
                expectsResponse: true,
                idKey: rpcID.key,
                responseID: rpcID,
                method: method,
                toolName: toolName,
                originalID: rpcID,
                // tools/list is stable even when clients attach pagination-like params.
                isCacheableToolsListRequest: method == "tools/list"
            )
        }

        return RequestTransform(
            upstreamData: try JSONRPC.Wire.data(from: object),
            expectsResponse: false,
            idKey: nil,
            responseID: nil,
            method: method,
            toolName: toolName,
            originalID: nil,
            isCacheableToolsListRequest: false
        )
    }

    private static func toolName(from object: [String: Any], method: String?) -> String? {
        guard method == "tools/call",
            let params = object["params"] as? [String: Any],
            let toolName = params["name"] as? String
        else {
            return nil
        }
        return toolName
    }
}
