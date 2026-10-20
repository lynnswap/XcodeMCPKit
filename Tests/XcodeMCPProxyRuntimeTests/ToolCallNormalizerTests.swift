import Foundation
import Testing
import XcodeMCPCore
@testable import XcodeMCPProxyRuntime

struct ToolCallNormalizerTests {
    private func normalize(_ result: [String: Any], toolName: String, catalog: JSONValue? = nil) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": result])
        let normalized = ToolCallNormalizer().normalizeResponseDataIfNeeded(
            method: "tools/call", toolName: toolName, toolsCatalogOverride: catalog, upstreamData: data)
        let object = try #require(JSONSerialization.jsonObject(with: normalized) as? [String: Any])
        return try #require(object["result"] as? [String: Any])
    }

    @Test func structuredContentIsDecodedFromTextJSON() throws {
        let result = try normalize(["content": [["type": "text", "text": "{\"answer\":\"ok\"}"]]],
                                   toolName: "DocumentationSearch")
        #expect((result["structuredContent"] as? [String: Any])?["answer"] as? String == "ok")
    }

    @Test func nonTextContentIsNotDecoded() throws {
        let result = try normalize(["content": [["type": "image", "text": "{\"answer\":\"bad\"}"]]],
                                   toolName: "DocumentationSearch")
        #expect(result["structuredContent"] == nil)
    }

    @Test func buildLogIssuesWithoutALineReportLineZero() throws {
        let result = try normalize(["structuredContent": ["emittedIssues": [
            ["message": "missing line"], ["message": "null line", "line": NSNull()],
        ]]], toolName: "GetBuildLog")
        let issues = try #require((result["structuredContent"] as? [String: Any])?["emittedIssues"] as? [[String: Any]])
        #expect(issues.map { ($0["line"] as? NSNumber)?.intValue } == [0, 0])
    }

    @Test func outputSchemaInTheHostCatalogEnablesDecoding() throws {
        let content: [String: Any] = ["content": [["type": "text", "text": "{\"answer\":\"source\"}"]]]
        #expect(try normalize(content, toolName: "NewStructuredTool")["structuredContent"] == nil)
        let catalog = try #require(JSONValue(any: ["tools": [["name": "NewStructuredTool", "outputSchema": ["type": "object"]]]]))
        let result = try normalize(content, toolName: "NewStructuredTool", catalog: catalog)
        #expect((result["structuredContent"] as? [String: Any])?["answer"] as? String == "source")
    }
}
