import Foundation
import Testing

@testable import XcodeMCPProxyRuntime

@Suite
struct RefreshToolsListWireShapeTests {
    @Test func refreshToolsListWireShapeRemainsStable() throws {
        let responseObject: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 7,
            "result": [
                "tools": [
                    [
                        "name": "XcodeRefreshCodeIssuesInFile",
                        "description": "placeholder",
                    ],
                    [
                        "name": "RunAllTests",
                        "description": "kept",
                    ],
                ]
            ],
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseObject, options: [])

        let rewritten = RefreshCodeIssues.ToolsListRewriter.rewriteResponseDataIfNeeded(
            responseData,
            method: "tools/list",
            mode: .proxy,
            hiddenToolNames: ["RunAllTests"]
        )

        let rewrittenObject = try #require(
            JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        )
        let result = try #require(rewrittenObject["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])

        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "XcodeRefreshCodeIssuesInFile")
        #expect(
            tools[0]["description"] as? String
                == """
                Returns file-scoped diagnostics for a source file. By default, the proxy serves this via Xcode navigator issues to avoid switching Spaces. Use --refresh-code-issues-mode upstream to use Xcode's native live diagnostics path instead.
                """
        )
    }
}
