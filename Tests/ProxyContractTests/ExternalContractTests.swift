import Foundation
import Testing

import ProxyCore
import ProxyMCP
import ProxyXcodeFeatures
@testable import ProxyCLI
@testable import ProxyHTTPGateway

@Suite
struct ExternalContractTests {
    @Test func cliAdapterUsageRemainsStable() {
        let usage = XcodeMCPProxyCLICommand.usage(
            discoveryFileURL: URL(fileURLWithPath: "/tmp/xcode-mcp-contract/endpoint.json")
        )

        #expect(
            usage == """
            Usage:
              xcode-mcp-proxy [options]

            Description:
              STDIO compatibility adapter that forwards MCP traffic to a running xcode-mcp-proxy-server (Streamable HTTP).

            Options:
              --request-timeout seconds  Request timeout (default: 300, 0 disables)
              --url url                  Explicit upstream URL (default: env/discovery/http://localhost:8765/mcp)
              --version                  Show version
              -h, --help                 Show help

            Environment:
              XCODE_MCP_PROXY_ENDPOINT   Upstream proxy URL (overrides discovery)

            Notes:
              - Proxy server: xcode-mcp-proxy-server
              - --config is only supported by xcode-mcp-proxy-server
              - Discovery file: /tmp/xcode-mcp-contract/endpoint.json
            """
        )
    }

    @Test func cliServerUsageRemainsStable() {
        #expect(
            XcodeMCPProxyServerCommand.serverUsage() == """
            Usage:
              xcode-mcp-proxy-server [options]

            Options:
              --listen host:port
              --host host
              --port port
              --config path
              --auto-approve
              --upstream-processes n
              --refresh-code-issues-mode proxy|upstream
              --force-restart
              --dry-run
              --version
              -h, --help

            Notes:
              - Starts the Streamable HTTP proxy server (and spawns xcrun mcpbridge as upstream processes).
              - HTTP-capable clients should connect directly; xcode-mcp-proxy is the STDIO compatibility adapter.
              - Default listen: localhost:8765 (override via --listen / --host / --port or env LISTEN/HOST/PORT).
              - --auto-approve opt-in enables automatic approval of the Xcode permission dialog.
              - Initialize config path: --config or env MCP_XCODE_CONFIG
              - When the listen port is already in use, rerun with --force-restart to terminate an existing xcode-mcp-proxy-server.
            """
        )
    }

    @Test func discoveryRecordShapeRemainsStable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("endpoint.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let record = DiscoveryRecord(
            url: "http://127.0.0.1:8765/mcp",
            host: "127.0.0.1",
            port: 8765,
            pid: 4242,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        try Discovery.write(record: record, overrideURL: fileURL)

        let payload = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(
            payload == """
            {
              "host" : "127.0.0.1",
              "pid" : 4242,
              "port" : 8765,
              "updatedAt" : "1970-01-01T00:00:00Z",
              "url" : "http:\\/\\/127.0.0.1:8765\\/mcp"
            }
            """
        )
    }

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

        let rewritten = RefreshCodeIssuesToolsListRewriter.rewriteResponseDataIfNeeded(
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

    @Test func errorWireShapeRemainsStable() throws {
        let responseData = try #require(
            MCPErrorResponder.errorResponseData(
                id: RPCID(any: 9),
                code: -32001,
                message: "upstream unavailable",
                data: .object([
                    "reason": .string("disabled")
                ])
            )
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let error = try #require(object["error"] as? [String: Any])
        let data = try #require(error["data"] as? [String: Any])

        #expect(object["jsonrpc"] as? String == "2.0")
        #expect((object["id"] as? NSNumber)?.intValue == 9)
        #expect((error["code"] as? NSNumber)?.intValue == -32001)
        #expect(error["message"] as? String == "upstream unavailable")
        #expect(data["reason"] as? String == "disabled")
    }
}
