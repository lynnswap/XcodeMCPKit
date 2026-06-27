import Foundation
import XcodeMCPRuntime

extension RefreshCodeIssues {
    package enum ToolsListRewriter {
    package static func rewriteResult(
        _ result: JSONValue,
        mode: ProxyConfig.RefreshCodeIssuesMode,
        hiddenToolNames: Set<String> = []
    ) -> JSONValue {
        guard case .object(var resultObject) = result,
            case .array(let tools) = resultObject["tools"]
        else {
            return result
        }

        let rewrittenTools = tools.compactMap { toolValue -> JSONValue? in
            guard case .object(var toolObject) = toolValue else {
                return toolValue
            }
            guard case .string(let name) = toolObject["name"] else {
                return toolValue
            }
            guard hiddenToolNames.contains(name) == false else {
                return nil
            }
            guard name == RefreshCodeIssues.Request.toolName else {
                return toolValue
            }
            toolObject["description"] = .string(description(for: mode))
            return .object(toolObject)
        }
        resultObject["tools"] = .array(rewrittenTools)
        return .object(resultObject)
    }

    package static func rewriteResponseDataIfNeeded(
        _ responseData: Data,
        method: String? = nil,
        responseMethodsByIDKey: [String: String] = [:],
        mode: ProxyConfig.RefreshCodeIssuesMode,
        hiddenToolNames: Set<String> = []
    ) -> Data {
        guard let payload = try? JSONSerialization.jsonObject(with: responseData, options: []) else {
            return responseData
        }

        if let object = payload as? [String: Any] {
            guard responseMethod(for: object, explicitMethod: method, responseMethodsByIDKey: responseMethodsByIDKey) == "tools/list",
                let rewrittenObject = rewriteResponseObject(
                    object,
                    mode: mode,
                    hiddenToolNames: hiddenToolNames
                ),
                JSONSerialization.isValidJSONObject(rewrittenObject),
                let rewrittenData = try? JSONSerialization.data(
                    withJSONObject: rewrittenObject,
                    options: []
                )
            else {
                return responseData
            }
            return rewrittenData
        }

        guard let array = payload as? [Any] else {
            return responseData
        }

        var rewroteAny = false
        let rewrittenArray = array.map { item -> Any in
            guard let object = item as? [String: Any],
                responseMethod(
                    for: object,
                    explicitMethod: nil,
                    responseMethodsByIDKey: responseMethodsByIDKey
                ) == "tools/list",
                let rewrittenObject = rewriteResponseObject(
                    object,
                    mode: mode,
                    hiddenToolNames: hiddenToolNames
                )
            else {
                return item
            }
            rewroteAny = true
            return rewrittenObject
        }
        guard rewroteAny,
            JSONSerialization.isValidJSONObject(rewrittenArray),
            let rewrittenData = try? JSONSerialization.data(
                withJSONObject: rewrittenArray,
                options: []
            )
        else {
            return responseData
        }
        return rewrittenData
    }

    private static func responseMethod(
        for object: [String: Any],
        explicitMethod: String?,
        responseMethodsByIDKey: [String: String]
    ) -> String? {
        if let explicitMethod {
            return explicitMethod
        }
        guard let responseID = JSONRPC.Message.Inspector.responseID(from: object) else {
            return nil
        }
        return responseMethodsByIDKey[responseID.key]
    }

    private static func rewriteResponseObject(
        _ object: [String: Any],
        mode: ProxyConfig.RefreshCodeIssuesMode,
        hiddenToolNames: Set<String>
    ) -> [String: Any]? {
        guard let result = object["result"],
            let resultValue = JSONValue(any: result)
        else {
            return nil
        }

        let rewrittenResult = rewriteResult(
            resultValue,
            mode: mode,
            hiddenToolNames: hiddenToolNames
        )
        guard rewrittenResult.foundationObject as? [String: Any] != nil else {
            return nil
        }

        var rewrittenObject = object
        rewrittenObject["result"] = rewrittenResult.foundationObject
        return rewrittenObject
    }

    private static func description(for mode: ProxyConfig.RefreshCodeIssuesMode) -> String {
        switch mode {
        case .proxy:
            return """
            Returns file-scoped diagnostics for a source file. By default, the proxy serves this via Xcode navigator issues to avoid switching Spaces. Use --refresh-code-issues-mode upstream to use Xcode's native live diagnostics path instead.
            """
        case .upstream:
            return """
            Returns file-scoped diagnostics for a source file. This proxy is configured to pass through to Xcode's native live diagnostics path.
            """
        }
    }
    }
}
