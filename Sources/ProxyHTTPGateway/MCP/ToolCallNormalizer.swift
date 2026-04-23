import Foundation
import ProxyMCP
import ProxySession

package struct ToolCallNormalizer: Sendable {
    private static let structuredContentTools: Set<String> = [
        "DocumentationSearch"
    ]

    private let sessionManager: any RuntimeCoordinating

    package init(sessionManager: any RuntimeCoordinating) {
        self.sessionManager = sessionManager
    }

    package func normalizeResponseDataIfNeeded(
        method: String? = nil,
        toolName: String? = nil,
        responseMethodsByIDKey: [String: String] = [:],
        responseToolNamesByIDKey: [String: String] = [:],
        toolsCatalogOverride: JSONValue? = nil,
        upstreamData: Data
    ) -> Data {
        guard let payload = try? JSONSerialization.jsonObject(with: upstreamData, options: []) else {
            return upstreamData
        }

        if let object = payload as? [String: Any] {
            guard let rewritten = normalizeResponseObjectIfNeeded(
                object,
                method: method,
                explicitToolName: toolName,
                responseMethodsByIDKey: responseMethodsByIDKey,
                responseToolNamesByIDKey: responseToolNamesByIDKey,
                toolsCatalogOverride: toolsCatalogOverride
            ),
                JSONSerialization.isValidJSONObject(rewritten),
                let rewrittenData = try? JSONSerialization.data(withJSONObject: rewritten, options: [])
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
                let rewritten = normalizeResponseObjectIfNeeded(
                    object,
                    method: nil,
                    explicitToolName: nil,
                    responseMethodsByIDKey: responseMethodsByIDKey,
                    responseToolNamesByIDKey: responseToolNamesByIDKey,
                    toolsCatalogOverride: toolsCatalogOverride
                )
            else {
                return item
            }
            rewroteAny = true
            return rewritten
        }

        guard rewroteAny,
            JSONSerialization.isValidJSONObject(rewrittenArray),
            let rewrittenData = try? JSONSerialization.data(withJSONObject: rewrittenArray, options: [])
        else {
            return upstreamData
        }
        return rewrittenData
    }

    private func normalizeResponseObjectIfNeeded(
        _ object: [String: Any],
        method: String?,
        explicitToolName: String?,
        responseMethodsByIDKey: [String: String],
        responseToolNamesByIDKey: [String: String],
        toolsCatalogOverride: JSONValue?
    ) -> [String: Any]? {
        guard resolvedMethod(
            for: object,
            explicitMethod: method,
            responseMethodsByIDKey: responseMethodsByIDKey
        ) == "tools/call" else {
            return nil
        }

        let toolName = explicitToolName ?? resolvedToolName(
            for: object,
            responseToolNamesByIDKey: responseToolNamesByIDKey
        )
        guard let toolName, shouldNormalize(toolName: toolName, toolsCatalogOverride: toolsCatalogOverride)
        else {
            return nil
        }
        guard var result = object["result"] as? [String: Any] else {
            return nil
        }

        var changed = false
        if result["structuredContent"] == nil,
            let structuredContent = structuredToolContent(
                from: result,
                toolName: toolName,
                toolsCatalogOverride: toolsCatalogOverride
            )
        {
            result["structuredContent"] = structuredContent.foundationObject
            changed = true
        }
        if toolName == "GetBuildLog",
            let normalizedStructuredContent = normalizeGetBuildLogStructuredContentIfNeeded(
                from: result["structuredContent"]
            )
        {
            result["structuredContent"] = normalizedStructuredContent
            changed = true
        }

        guard changed else {
            return nil
        }

        var rewritten = object
        rewritten["result"] = result
        return rewritten
    }

    private func resolvedMethod(
        for object: [String: Any],
        explicitMethod: String?,
        responseMethodsByIDKey: [String: String]
    ) -> String? {
        if let explicitMethod {
            return explicitMethod
        }
        guard let responseIDValue = object["id"],
            let responseID = RPCID(any: responseIDValue)
        else {
            return nil
        }
        return responseMethodsByIDKey[responseID.key]
    }

    private func resolvedToolName(
        for object: [String: Any],
        responseToolNamesByIDKey: [String: String]
    ) -> String? {
        guard let responseIDValue = object["id"],
            let responseID = RPCID(any: responseIDValue)
        else {
            return nil
        }
        return responseToolNamesByIDKey[responseID.key]
    }

    private func shouldNormalize(toolName: String, toolsCatalogOverride: JSONValue?) -> Bool {
        if toolName == "GetBuildLog" {
            return true
        }
        if Self.structuredContentTools.contains(toolName) {
            return true
        }
        return toolOutputSchema(for: toolName, toolsCatalogOverride: toolsCatalogOverride) != nil
    }

    private func toolOutputSchema(for toolName: String, toolsCatalogOverride: JSONValue? = nil) -> JSONValue? {
        guard let toolsResult = toolsCatalogOverride ?? sessionManager.cachedToolsListResult(),
            case .object(let resultObject) = toolsResult,
            case .array(let tools) = resultObject["tools"]
        else {
            return nil
        }

        for toolValue in tools {
            guard case .object(let toolObject) = toolValue,
                case .string(let candidateName) = toolObject["name"],
                candidateName == toolName
            else {
                continue
            }
            return toolObject["outputSchema"]
        }
        return nil
    }

    private func structuredToolContent(
        from result: [String: Any],
        toolName: String,
        toolsCatalogOverride: JSONValue?
    ) -> JSONValue? {
        guard Self.structuredContentTools.contains(toolName)
            || toolOutputSchema(for: toolName, toolsCatalogOverride: toolsCatalogOverride) != nil
        else {
            return nil
        }
        guard let content = result["content"] as? [Any] else {
            return nil
        }

        for item in content {
            guard let object = item as? [String: Any],
                object["type"] as? String == "text",
                let text = object["text"] as? String,
                text.isEmpty == false,
                let data = text.data(using: .utf8),
                let any = try? JSONSerialization.jsonObject(with: data, options: []),
                let value = JSONValue(any: any)
            else {
                continue
            }
            return value
        }
        return nil
    }

    private func normalizeGetBuildLogStructuredContentIfNeeded(from value: Any?) -> [String: Any]? {
        guard var structuredContent = value as? [String: Any],
            let emittedIssues = structuredContent["emittedIssues"] as? [Any]
        else {
            return nil
        }

        var changed = false
        let normalizedIssues = emittedIssues.map { issue -> Any in
            guard var issueObject = issue as? [String: Any] else {
                return issue
            }
            let lineValue = issueObject["line"]
            if lineValue == nil || lineValue is NSNull {
                issueObject["line"] = 0
                changed = true
            }
            return issueObject
        }

        guard changed else {
            return nil
        }

        structuredContent["emittedIssues"] = normalizedIssues
        return structuredContent
    }
}
