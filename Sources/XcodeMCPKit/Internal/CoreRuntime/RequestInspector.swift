import Foundation

package struct RequestTransform {
    package let upstreamData: Data
    package let expectsResponse: Bool
    package let isBatch: Bool
    package let idKey: String?
    package let responseIDs: [JSONRPC.ID]
    package let responseMethodsByIDKey: [String: String]
    package let responseToolNamesByIDKey: [String: String]
    package let responseOriginalIDsByKey: [String: JSONRPC.ID]
    package let method: String?
    package let toolName: String?
    package let originalID: JSONRPC.ID?
    package let normalizationToolsListResponseIDKey: String?
    package let isCacheableToolsListRequest: Bool
    package let cacheableToolsListResponseIDKey: String?
}

package enum RequestInspector {
    package static func transform(
        _ data: Data,
        parsedJSON: Any? = nil,
        sessionID: String,
        mapID: (_ sessionID: String, _ originalID: JSONRPC.ID) throws -> Int64
    ) throws -> RequestTransform {
        let json = try parsedJSON ?? JSONSerialization.jsonObject(with: data, options: [])
        if var object = json as? [String: Any] {
            let kind = JSONRPC.Message.Inspector.kind(of: object)
            let method = JSONRPC.Message.Inspector.method(from: object)
            let toolName = toolName(from: object, method: method)
            // We intentionally treat tools/list as stable and cache it regardless of params.
            // Some clients attach pagination-like params even when they expect the full list.
            let isCacheableToolsListRequest: Bool = {
                guard case .request(let method, _) = kind else { return false }
                return method == "tools/list"
            }()
            if case .request(let method, let rpcID) = kind {
                let upstreamID = try mapID(sessionID, rpcID)
                object["id"] = upstreamID
                let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
                return RequestTransform(
                    upstreamData: upstream,
                    expectsResponse: true,
                    isBatch: false,
                    idKey: rpcID.key,
                    responseIDs: [rpcID],
                    responseMethodsByIDKey: [rpcID.key: method],
                    responseToolNamesByIDKey: toolName.map { [rpcID.key: $0] } ?? [:],
                    responseOriginalIDsByKey: [rpcID.key: rpcID],
                    method: method,
                    toolName: toolName,
                    originalID: rpcID,
                    normalizationToolsListResponseIDKey: isCacheableToolsListRequest ? rpcID.key : nil,
                    isCacheableToolsListRequest: isCacheableToolsListRequest,
                    cacheableToolsListResponseIDKey: isCacheableToolsListRequest ? rpcID.key : nil
                )
            }
            let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
            return RequestTransform(
                upstreamData: upstream,
                expectsResponse: false,
                isBatch: false,
                idKey: nil,
                responseIDs: [],
                responseMethodsByIDKey: [:],
                responseToolNamesByIDKey: [:],
                responseOriginalIDsByKey: [:],
                method: method,
                toolName: toolName,
                originalID: nil,
                normalizationToolsListResponseIDKey: nil,
                isCacheableToolsListRequest: isCacheableToolsListRequest,
                cacheableToolsListResponseIDKey: nil
            )
        }

        if let array = json as? [Any] {
            var transformed: [Any] = []
            var responseIDs: [JSONRPC.ID] = []
            var responseMethodsByIDKey: [String: String] = [:]
            var responseToolNamesByIDKey: [String: String] = [:]
            var responseOriginalIDsByKey: [String: JSONRPC.ID] = [:]
            responseIDs.reserveCapacity(array.count)
            for item in array {
                if var object = item as? [String: Any] {
                    if case .request(let method, let rpcID) =
                        JSONRPC.Message.Inspector.kind(of: object)
                    {
                        let upstreamID = try mapID(sessionID, rpcID)
                        object["id"] = upstreamID
                        responseIDs.append(rpcID)
                        responseOriginalIDsByKey[rpcID.key] = rpcID
                        responseMethodsByIDKey[rpcID.key] = method
                        if let toolName = toolName(from: object, method: method) {
                            responseToolNamesByIDKey[rpcID.key] = toolName
                        }
                    }
                    transformed.append(object)
                } else {
                    transformed.append(item)
                }
            }
            let normalizationToolsListResponseIDKey: String? = {
                for item in array {
                    guard let object = item as? [String: Any],
                        case .request("tools/list", let rpcID) =
                            JSONRPC.Message.Inspector.kind(of: object)
                    else {
                        continue
                    }
                    return rpcID.key
                }
                return nil
            }()
            let cacheableToolsListResponseIDKey: String? = {
                guard let normalizationToolsListResponseIDKey else {
                    return nil
                }
                for item in array {
                    guard let object = item as? [String: Any],
                        case .request(let method, _) =
                            JSONRPC.Message.Inspector.kind(of: object)
                    else {
                        continue
                    }
                    guard method == "tools/list" else {
                        return nil
                    }
                }
                return normalizationToolsListResponseIDKey
            }()
            let upstream = try JSONSerialization.data(withJSONObject: transformed, options: [])
            return RequestTransform(
                upstreamData: upstream,
                expectsResponse: !responseIDs.isEmpty,
                isBatch: true,
                idKey: nil,
                responseIDs: responseIDs,
                responseMethodsByIDKey: responseMethodsByIDKey,
                responseToolNamesByIDKey: responseToolNamesByIDKey,
                responseOriginalIDsByKey: responseOriginalIDsByKey,
                method: nil,
                toolName: nil,
                originalID: nil,
                normalizationToolsListResponseIDKey: normalizationToolsListResponseIDKey,
                isCacheableToolsListRequest: cacheableToolsListResponseIDKey != nil,
                cacheableToolsListResponseIDKey: cacheableToolsListResponseIDKey
            )
        }

        return RequestTransform(
            upstreamData: data,
            expectsResponse: false,
            isBatch: false,
            idKey: nil,
            responseIDs: [],
            responseMethodsByIDKey: [:],
            responseToolNamesByIDKey: [:],
            responseOriginalIDsByKey: [:],
            method: nil,
            toolName: nil,
            originalID: nil,
            normalizationToolsListResponseIDKey: nil,
            isCacheableToolsListRequest: false,
            cacheableToolsListResponseIDKey: nil
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
