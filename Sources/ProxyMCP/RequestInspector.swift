import Foundation

package struct RequestTransform {
    package let upstreamData: Data
    package let expectsResponse: Bool
    package let isBatch: Bool
    package let idKey: String?
    package let responseIDs: [RPCID]
    package let responseMethodsByIDKey: [String: String]
    package let responseOriginalIDsByKey: [String: RPCID]
    package let method: String?
    package let originalID: RPCID?
    package let isCacheableToolsListRequest: Bool
    package let cacheableToolsListResponseIDKey: String?
}

package enum RequestInspector {
    package static func transform(
        _ data: Data,
        sessionID: String,
        mapID: (_ sessionID: String, _ originalID: RPCID) -> Int64
    ) throws -> RequestTransform {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        if var object = json as? [String: Any] {
            let method = object["method"] as? String
            // We intentionally treat tools/list as stable and cache it regardless of params.
            // Some clients attach pagination-like params even when they expect the full list.
            let isCacheableToolsListRequest = (method == "tools/list")
            if let id = object["id"], let rpcID = RPCID(any: id) {
                let upstreamID = mapID(sessionID, rpcID)
                object["id"] = upstreamID
                let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
                return RequestTransform(
                    upstreamData: upstream,
                    expectsResponse: true,
                    isBatch: false,
                    idKey: rpcID.key,
                    responseIDs: [rpcID],
                    responseMethodsByIDKey: method.map { [rpcID.key: $0] } ?? [:],
                    responseOriginalIDsByKey: [rpcID.key: rpcID],
                    method: method,
                    originalID: rpcID,
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
                responseOriginalIDsByKey: [:],
                method: method,
                originalID: nil,
                isCacheableToolsListRequest: isCacheableToolsListRequest,
                cacheableToolsListResponseIDKey: nil
            )
        }

        if let array = json as? [Any] {
            var transformed: [Any] = []
            var responseIDs: [RPCID] = []
            var responseMethodsByIDKey: [String: String] = [:]
            var responseOriginalIDsByKey: [String: RPCID] = [:]
            responseIDs.reserveCapacity(array.count)
            for item in array {
                if var object = item as? [String: Any] {
                    if let id = object["id"], let rpcID = RPCID(any: id) {
                        let upstreamID = mapID(sessionID, rpcID)
                        object["id"] = upstreamID
                        responseIDs.append(rpcID)
                        responseOriginalIDsByKey[rpcID.key] = rpcID
                        if let method = object["method"] as? String {
                            responseMethodsByIDKey[rpcID.key] = method
                        }
                    }
                    transformed.append(object)
                } else {
                    transformed.append(item)
                }
            }
            let cacheableToolsListResponseIDKey: String? = {
                guard array.count == 1,
                    let firstObject = array.first as? [String: Any],
                    firstObject["method"] as? String == "tools/list",
                    let firstID = firstObject["id"],
                    let rpcID = RPCID(any: firstID)
                else {
                    return nil
                }
                return rpcID.key
            }()
            let upstream = try JSONSerialization.data(withJSONObject: transformed, options: [])
            return RequestTransform(
                upstreamData: upstream,
                expectsResponse: !responseIDs.isEmpty,
                isBatch: true,
                idKey: nil,
                responseIDs: responseIDs,
                responseMethodsByIDKey: responseMethodsByIDKey,
                responseOriginalIDsByKey: responseOriginalIDsByKey,
                method: nil,
                originalID: nil,
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
            responseOriginalIDsByKey: [:],
            method: nil,
            originalID: nil,
            isCacheableToolsListRequest: false,
            cacheableToolsListResponseIDKey: nil
        )
    }
}
