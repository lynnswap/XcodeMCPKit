import Foundation
import ProxyCore
import ProxyMCP
import ProxySession
import ProxyXcodeFeatures

package struct ToolSurface: Sendable {
    package struct RewriteResult: Sendable {
        package let responseData: Data
        package let cacheableToolsListResult: JSONValue?
    }

    private let refreshCodeIssuesMode: ProxyConfig.RefreshCodeIssuesMode
    private let callNormalizer: ToolCallNormalizer
    private let hiddenToolNames: Set<String>

    package init(
        config: ProxyConfig,
        sessionManager: any RuntimeCoordinating
    ) {
        self.refreshCodeIssuesMode = config.refreshCodeIssuesMode
        self.callNormalizer = ToolCallNormalizer(sessionManager: sessionManager)
        self.hiddenToolNames = config.disabledToolNames
    }

    package func rewriteForwardedResponse(
        method: String?,
        toolName: String?,
        originalID: JSONRPC.ID?,
        responseMethodsByIDKey: [String: String] = [:],
        responseToolNamesByIDKey: [String: String] = [:],
        responseOriginalIDsByKey: [String: JSONRPC.ID] = [:],
        normalizationToolsListResponseIDKey: String? = nil,
        cacheableToolsListResponseIDKey: String? = nil,
        upstreamData: Data
    ) -> ToolSurface.RewriteResult {
        let rewrittenResourcesData = rewriteUnsupportedResourcesListResponseIfNeeded(
            method: method,
            originalID: originalID,
            responseMethodsByIDKey: responseMethodsByIDKey,
            responseOriginalIDsByKey: responseOriginalIDsByKey,
            upstreamData: upstreamData
        )
        let cacheableToolsListData = rewriteToolsListResponseIfNeeded(
            rewrittenResourcesData,
            method: method,
            responseMethodsByIDKey: responseMethodsByIDKey
        )
        let normalizationToolsListResult = normalizationToolsListResponseIDKey.flatMap { responseIDKey in
            extractToolsListResult(
                from: cacheableToolsListData,
                matching: responseIDKey
            )
        }
        let cacheableToolsListResult = cacheableToolsListResponseIDKey.flatMap { _ in
            normalizationToolsListResult
        }
        let normalizedToolsCallData = callNormalizer.normalizeResponseDataIfNeeded(
            method: method,
            toolName: toolName,
            responseMethodsByIDKey: responseMethodsByIDKey,
            responseToolNamesByIDKey: responseToolNamesByIDKey,
            toolsCatalogOverride: normalizationToolsListResult,
            upstreamData: cacheableToolsListData
        )
        let responseData = rewriteToolsListResponseIfNeeded(
            normalizedToolsCallData,
            method: method,
            responseMethodsByIDKey: responseMethodsByIDKey,
            hiddenToolNames: hiddenToolNames
        )
        return ToolSurface.RewriteResult(
            responseData: responseData,
            cacheableToolsListResult: cacheableToolsListResult
        )
    }

    package func shouldNotifyUpstreamSuccess(for responseData: Data) -> Bool {
        guard let any = try? JSONSerialization.jsonObject(with: responseData, options: []) else {
            return true
        }

        if let object = any as? [String: Any] {
            return isUpstreamOverloadedErrorResponse(object) == false
        }

        if let array = any as? [Any] {
            let objects = array.compactMap { $0 as? [String: Any] }
            guard objects.isEmpty == false else {
                return true
            }
            return objects.allSatisfy(isUpstreamOverloadedErrorResponse) == false
        }

        return true
    }

    private func rewriteUnsupportedResourcesListResponseIfNeeded(
        method: String?,
        originalID: JSONRPC.ID?,
        responseMethodsByIDKey: [String: String],
        responseOriginalIDsByKey: [String: JSONRPC.ID],
        upstreamData: Data
    ) -> Data {
        guard let payload = try? JSONSerialization.jsonObject(with: upstreamData, options: []) else {
            return upstreamData
        }

        if let object = payload as? [String: Any] {
            let resolvedRequest: (method: String, originalID: JSONRPC.ID)? = {
                if let method, let originalID {
                    return (method, originalID)
                }
                guard let responseID = JSONRPC.Message.Inspector.responseID(from: object),
                    let method = responseMethodsByIDKey[responseID.key],
                    let originalID = responseOriginalIDsByKey[responseID.key]
                else {
                    return nil
                }
                return (method, originalID)
            }()
            guard let resolvedRequest else { return upstreamData }
            let rewrittenObject = rewriteUnsupportedResourcesListResponseObjectIfNeeded(
                object,
                method: resolvedRequest.method,
                originalID: resolvedRequest.originalID
            )
            guard JSONSerialization.isValidJSONObject(rewrittenObject),
                let rewrittenData = try? JSONSerialization.data(
                    withJSONObject: rewrittenObject,
                    options: []
                )
            else {
                return upstreamData
            }
            return rewrittenData
        }

        guard let array = payload as? [Any] else {
            return upstreamData
        }

        var rewroteAny = false
        let rewrittenArray = array.map { item -> Any in
            guard let object = item as? [String: Any],
                let responseID = JSONRPC.Message.Inspector.responseID(from: object),
                let method = responseMethodsByIDKey[responseID.key],
                let originalID = responseOriginalIDsByKey[responseID.key]
            else {
                return item
            }

            guard method == "resources/list" || method == "resources/templates/list" else {
                return item
            }

            rewroteAny = true
            return rewriteUnsupportedResourcesListResponseObjectIfNeeded(
                object,
                method: method,
                originalID: originalID
            )
        }
        guard rewroteAny,
            JSONSerialization.isValidJSONObject(rewrittenArray),
            let rewrittenData = try? JSONSerialization.data(
                withJSONObject: rewrittenArray,
                options: []
            )
        else {
            return upstreamData
        }
        return rewrittenData
    }

    private func rewriteUnsupportedResourcesListResponseObjectIfNeeded(
        _ object: [String: Any],
        method: String,
        originalID: JSONRPC.ID
    ) -> [String: Any] {
        guard method == "resources/list" || method == "resources/templates/list" else {
            return object
        }

        let expectedKey = method == "resources/list" ? "resources" : "resourceTemplates"
        let result = object["result"]

        if let resultObject = result as? [String: Any], resultObject[expectedKey] is [Any] {
            return object
        }

        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? (error["code"] as? Int)
            guard code == -32601 else {
                return object
            }
            return emptyResourcesListResponseObject(method: method, originalID: originalID)
        }

        if let result, isNonStandardUnsupportedResourcesResult(result, method: method) {
            return emptyResourcesListResponseObject(method: method, originalID: originalID)
        }

        return object
    }

    private func emptyResourcesListResponseObject(method: String, originalID: JSONRPC.ID) -> [String: Any] {
        let result: [String: Any] = method == "resources/list"
            ? ["resources": [Any]()]
            : ["resourceTemplates": [Any]()]
        return [
            "jsonrpc": "2.0",
            "id": originalID.value.foundationObject,
            "result": result,
        ]
    }

    private func isNonStandardUnsupportedResourcesResult(_ result: Any, method: String) -> Bool {
        guard let resultObject = result as? [String: Any] else {
            return false
        }
        guard let isError = resultObject["isError"] as? Bool, isError else {
            return false
        }
        guard let content = resultObject["content"] as? [Any], !content.isEmpty else {
            return false
        }

        let methodToken = method.lowercased()
        for item in content {
            guard let contentObject = item as? [String: Any],
                let text = contentObject["text"] as? String
            else {
                continue
            }
            let normalized = text.lowercased()
            if normalized.contains("unknown method"), normalized.contains(methodToken) {
                return true
            }
        }
        return false
    }

    private func extractToolsListResult(
        from responseData: Data,
        matching responseIDKey: String
    ) -> JSONValue? {
        guard let object = Self.responseObject(
            from: responseData,
            matching: responseIDKey
        ),
            let resultAny = object["result"]
        else {
            return nil
        }
        return JSONValue(any: resultAny)
    }

    private func rewriteToolsListResponseIfNeeded(
        _ responseData: Data,
        method: String? = nil,
        responseMethodsByIDKey: [String: String] = [:],
        hiddenToolNames: Set<String> = []
    ) -> Data {
        RefreshCodeIssues.ToolsListRewriter.rewriteResponseDataIfNeeded(
            responseData,
            method: method,
            responseMethodsByIDKey: responseMethodsByIDKey,
            mode: refreshCodeIssuesMode,
            hiddenToolNames: hiddenToolNames
        )
    }

    package static func responseObject(
        from responseData: Data,
        matching responseIDKey: String
    ) -> [String: Any]? {
        guard let payload = try? JSONSerialization.jsonObject(with: responseData, options: []) else {
            return nil
        }
        if let object = payload as? [String: Any] {
            guard let responseID = JSONRPC.Message.Inspector.responseID(from: object),
                responseID.key == responseIDKey
            else {
                return nil
            }
            return object
        }
        guard let array = payload as? [Any] else {
            return nil
        }
        for item in array {
            guard let object = item as? [String: Any],
                let responseID = JSONRPC.Message.Inspector.responseID(from: object),
                responseID.key == responseIDKey
            else {
                continue
            }
            return object
        }
        return nil
    }

    private func isUpstreamOverloadedErrorResponse(_ object: [String: Any]) -> Bool {
        guard let error = object["error"] as? [String: Any] else {
            return false
        }
        let code = (error["code"] as? NSNumber)?.intValue ?? (error["code"] as? Int)
        guard code == -32002 else {
            return false
        }
        return (error["message"] as? String) == "upstream overloaded"
    }
}
