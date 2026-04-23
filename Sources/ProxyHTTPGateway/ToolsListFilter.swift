import Foundation
import ProxyCore
import ProxyMCP

package enum ToolsListFilter {
    package static func rewriteResult(
        _ result: JSONValue,
        hiddenToolNames: Set<String> = []
    ) -> JSONValue {
        guard case .object(var resultObject) = result,
            case .array(let tools) = resultObject["tools"]
        else {
            return result
        }

        let filteredTools = tools.compactMap { toolValue -> JSONValue? in
            guard case .object(let toolObject) = toolValue,
                case .string(let name) = toolObject["name"]
            else {
                return toolValue
            }
            return hiddenToolNames.contains(name) ? nil : toolValue
        }
        resultObject["tools"] = .array(filteredTools)
        return .object(resultObject)
    }

    package static func rewriteResponseDataIfNeeded(
        _ responseData: Data,
        hiddenToolNames: Set<String> = []
    ) -> Data {
        guard hiddenToolNames.isEmpty == false,
            let object = try? JSONSerialization.jsonObject(with: responseData, options: [])
                as? [String: Any],
            let result = object["result"],
            let resultValue = JSONValue(any: result)
        else {
            return responseData
        }

        let rewrittenResult = rewriteResult(
            resultValue,
            hiddenToolNames: hiddenToolNames
        )
        var rewrittenObject = object
        rewrittenObject["result"] = rewrittenResult.foundationObject
        guard JSONSerialization.isValidJSONObject(rewrittenObject),
            let rewrittenData = try? JSONSerialization.data(withJSONObject: rewrittenObject, options: [])
        else {
            return responseData
        }
        return rewrittenData
    }
}
