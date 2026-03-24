import Foundation
import ProxyCore

package enum RefreshCodeIssuesToolsListRewriter {
    package static func rewriteResult(
        _ result: JSONValue,
        mode: RefreshCodeIssuesMode
    ) -> JSONValue {
        guard case .object(var resultObject) = result,
            case .array(let tools) = resultObject["tools"]
        else {
            return result
        }

        let rewrittenTools = tools.map { toolValue in
            guard case .object(var toolObject) = toolValue,
                case .string(let name) = toolObject["name"],
                name == RefreshCodeIssuesRequest.toolName
            else {
                return toolValue
            }
            toolObject["description"] = .string(description(for: mode))
            if mode == .proxy {
                toolObject["outputSchema"] = proxyOutputSchema
            }
            return .object(toolObject)
        }
        resultObject["tools"] = .array(rewrittenTools)
        return .object(resultObject)
    }

    package static func rewriteResponseDataIfNeeded(
        _ responseData: Data,
        mode: RefreshCodeIssuesMode
    ) -> Data {
        guard
            let object = try? JSONSerialization.jsonObject(with: responseData, options: [])
                as? [String: Any],
            let result = object["result"],
            let resultValue = JSONValue(any: result)
        else {
            return responseData
        }

        let rewrittenResult = rewriteResult(resultValue, mode: mode)
        guard rewrittenResult.foundationObject as? [String: Any] != nil else {
            return responseData
        }

        var rewrittenObject = object
        rewrittenObject["result"] = rewrittenResult.foundationObject
        guard JSONSerialization.isValidJSONObject(rewrittenObject),
            let rewrittenData = try? JSONSerialization.data(withJSONObject: rewrittenObject, options: [])
        else {
            return responseData
        }
        return rewrittenData
    }

    private static func description(for mode: RefreshCodeIssuesMode) -> String {
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

    private static let proxyOutputSchema: JSONValue = .object([
        "type": .string("object"),
        "required": .array([
            .string("issues"),
            .string("truncated"),
            .string("totalFound"),
        ]),
        "properties": .object([
            "message": .object([
                "type": .string("string"),
                "description": .string("Optional message with additional information about the search results"),
            ]),
            "truncated": .object([
                "type": .string("boolean"),
                "description": .string("Whether results were truncated due to exceeding 100 issues"),
            ]),
            "totalFound": .object([
                "type": .string("integer"),
                "description": .string("Total number of issues before truncation"),
            ]),
            "issues": .object([
                "type": .string("array"),
                "description": .string("The list of current issues matching the input filters"),
                "items": .object([
                    "type": .string("object"),
                    "required": .array([
                        .string("message"),
                        .string("severity"),
                    ]),
                    "properties": .object([
                        "severity": .object([
                            "type": .string("string"),
                            "description": .string("The severity of issue (error, warning, remark)"),
                        ]),
                        "line": .object([
                            "type": .string("integer"),
                            "description": .string("The line number where the issue was detected, if known"),
                        ]),
                        "vitality": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("fresh"),
                                .string("stale"),
                            ]),
                            "description": .string("Whether an issue from a previous build is known to still be relevant or whether something might have changed since it was emitted (for example if the source file has been edited and it isn't yet known whether that edit fixes the issue). Possible values: (fresh, stale)"),
                        ]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("The file path where the issue was detected, if any"),
                        ]),
                        "message": .object([
                            "type": .string("string"),
                            "description": .string("The message describing the issue"),
                        ]),
                        "category": .object([
                            "type": .string("string"),
                            "description": .string("The category of the issue, if known"),
                        ]),
                    ]),
                ]),
            ]),
        ]),
    ])
}
