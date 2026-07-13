import Foundation
import XcodeMCPKit

struct ToolSurface: Sendable {
    struct RewriteResult: Sendable {
        let responseData: Data
        let cacheableToolsListResult: JSONValue?
    }

    private let refreshCodeIssuesMode: ProxyRuntimeConfiguration.RefreshCodeIssuesMode
    private let callNormalizer: ToolCallNormalizer
    private let hiddenToolNames: Set<String>

    init(config: ProxyRuntimeConfiguration, sessionManager: any RuntimeToolsCatalogPort) {
        self.refreshCodeIssuesMode = config.refreshCodeIssuesMode
        self.callNormalizer = ToolCallNormalizer(sessionManager: sessionManager)
        self.hiddenToolNames = config.disabledToolNames
    }

    func rewriteForwardedResponse(
        method: String?,
        toolName: String?,
        originalID: JSONRPC.ID?,
        cachesToolsListResult: Bool = false,
        upstreamIndex: Int? = nil,
        upstreamData: Data
    ) -> ToolSurface.RewriteResult {
        let resourcesData = rewriteUnsupportedResourcesListResponseIfNeeded(
            method: method,
            originalID: originalID,
            upstreamData: upstreamData
        )
        let toolsListData = rewriteToolsListResponseIfNeeded(resourcesData, method: method)
        let toolsListResult = method == "tools/list"
            ? extractToolsListResult(from: toolsListData)
            : nil
        let normalizedToolCallData = callNormalizer.normalizeResponseDataIfNeeded(
            method: method,
            toolName: toolName,
            toolsCatalogOverride: toolsListResult,
            upstreamIndex: upstreamIndex,
            upstreamData: toolsListData
        )
        let responseData = rewriteToolsListResponseIfNeeded(
            normalizedToolCallData,
            method: method,
            hiddenToolNames: hiddenToolNames
        )
        return ToolSurface.RewriteResult(
            responseData: responseData,
            cacheableToolsListResult: cachesToolsListResult ? toolsListResult : nil
        )
    }

    func shouldNotifyUpstreamSuccess(for responseData: Data) -> Bool {
        guard let object = try? JSONRPC.Wire.object(fromData: responseData) else {
            return false
        }
        return isUpstreamOverloadedErrorResponse(object) == false
    }

    private func rewriteUnsupportedResourcesListResponseIfNeeded(
        method: String?,
        originalID: JSONRPC.ID?,
        upstreamData: Data
    ) -> Data {
        guard let method, let originalID,
            let object = try? JSONRPC.Wire.object(fromData: upstreamData)
        else {
            return upstreamData
        }
        let rewritten = rewriteUnsupportedResourcesListResponseObjectIfNeeded(
            object,
            method: method,
            originalID: originalID
        )
        return (try? JSONRPC.Wire.data(from: rewritten)) ?? upstreamData
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
        if let result = object["result"] as? [String: Any], result[expectedKey] is [Any] {
            return object
        }
        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? (error["code"] as? Int)
            guard code == -32601 else { return object }
            return emptyResourcesListResponseObject(method: method, originalID: originalID)
        }
        if let result = object["result"],
            isNonStandardUnsupportedResourcesResult(result, method: method)
        {
            return emptyResourcesListResponseObject(method: method, originalID: originalID)
        }
        return object
    }

    private func emptyResourcesListResponseObject(
        method: String,
        originalID: JSONRPC.ID
    ) -> [String: Any] {
        let result: [String: Any] = method == "resources/list"
            ? ["resources": [Any]()]
            : ["resourceTemplates": [Any]()]
        return JSONRPC.Wire.resultResponseObject(
            id: originalID,
            result: JSONValue(any: result) ?? .object([:])
        )
    }

    private func isNonStandardUnsupportedResourcesResult(_ result: Any, method: String) -> Bool {
        guard let resultObject = result as? [String: Any],
            resultObject["isError"] as? Bool == true,
            let content = resultObject["content"] as? [Any],
            content.isEmpty == false
        else {
            return false
        }
        let methodToken = method.lowercased()
        return content.contains { item in
            guard let object = item as? [String: Any],
                let text = object["text"] as? String
            else {
                return false
            }
            let normalized = text.lowercased()
            return normalized.contains("unknown method") && normalized.contains(methodToken)
        }
    }

    private func extractToolsListResult(from responseData: Data) -> JSONValue? {
        guard let object = try? JSONRPC.Wire.object(fromData: responseData),
            let result = object["result"]
        else {
            return nil
        }
        return JSONValue(any: result)
    }

    private func rewriteToolsListResponseIfNeeded(
        _ responseData: Data,
        method: String?,
        hiddenToolNames: Set<String> = []
    ) -> Data {
        RefreshCodeIssues.ToolsListRewriter.rewriteResponseDataIfNeeded(
            responseData,
            method: method,
            mode: refreshCodeIssuesMode,
            hiddenToolNames: hiddenToolNames
        )
    }

    static func responseObject(
        from responseData: Data,
        matching responseIDKey: String
    ) -> [String: Any]? {
        guard let object = try? JSONRPC.Wire.object(fromData: responseData),
            JSONRPC.Message.Inspector.responseID(from: object)?.key == responseIDKey
        else {
            return nil
        }
        return object
    }

    private func isUpstreamOverloadedErrorResponse(_ object: [String: Any]) -> Bool {
        guard let error = object["error"] as? [String: Any] else { return false }
        let code = (error["code"] as? NSNumber)?.intValue ?? (error["code"] as? Int)
        return code == -32002 && error["message"] as? String == "upstream overloaded"
    }
}
