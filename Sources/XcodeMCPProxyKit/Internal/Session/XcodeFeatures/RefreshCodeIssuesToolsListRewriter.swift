import Foundation
import XcodeMCPKit

extension RefreshCodeIssues {
    enum ToolsListRewriter {
    static func rewriteResult(
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

    static func rewriteResponseDataIfNeeded(
        _ responseData: Data,
        method: String? = nil,
        mode: ProxyConfig.RefreshCodeIssuesMode,
        hiddenToolNames: Set<String> = []
    ) -> Data {
        guard method == "tools/list",
            let object = try? JSONRPC.Wire.object(fromData: responseData),
            let rewrittenObject = rewriteResponseObject(
                object,
                mode: mode,
                hiddenToolNames: hiddenToolNames
            ),
            let rewrittenData = try? JSONRPC.Wire.data(from: rewrittenObject)
        else {
            return responseData
        }
        return rewrittenData
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
