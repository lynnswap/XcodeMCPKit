import Foundation
import Testing

@testable import ProxyHTTPTransport

struct HTTPLoggingFormatTests {
    @Test func mcpLogDetailsExtractsToolsCallNameAndParams() throws {
        let payload = """
        {
          "jsonrpc": "2.0",
          "id": 1,
          "method": "tools/call",
          "params": {
            "name": "XcodeListWindows",
            "arguments": {
              "includeMinimized": true
            }
          }
        }
        """.data(using: .utf8)!

        let details = HTTPHandler.mcpLogDetails(from: payload)

        #expect(details.invocation == "tools/call:XcodeListWindows")
        let paramsJSON = try #require(details.paramsJSON.data(using: .utf8))
        let paramsObject = try JSONSerialization.jsonObject(with: paramsJSON, options: []) as? [String: Any]
        let name = paramsObject?["name"] as? String
        let arguments = paramsObject?["arguments"] as? [String: Any]
        #expect(name == "XcodeListWindows")
        #expect(arguments?["includeMinimized"] as? Bool == true)
    }

    @Test func mcpLogDetailsHandlesBatchRequests() throws {
        let payload = """
        [
          {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"next"}},
          {"jsonrpc":"2.0","id":2,"method":"ping"}
        ]
        """.data(using: .utf8)!

        let details = HTTPHandler.mcpLogDetails(from: payload)

        #expect(details.invocation == "batch[2]")
        let paramsJSON = try #require(details.paramsJSON.data(using: .utf8))
        let paramsArray = try JSONSerialization.jsonObject(with: paramsJSON, options: []) as? [Any]
        #expect(paramsArray?.count == 2)
        let first = paramsArray?[0] as? [String: Any]
        #expect(first?["cursor"] as? String == "next")
        #expect(paramsArray?[1] is NSNull)
    }

    @Test func makeHTTPLogBlockUsesRequiredFourLineFormat() throws {
        let request = HTTPHandler.RequestLogContext(
            id: "request-1",
            method: "POST",
            path: "/mcp",
            remoteAddress: nil,
            mcpInvocation: "tools/list",
            requestParamsJSON: "{\"cursor\":\"next\"}"
        )

        let logBlock = HTTPResponseWriter.makeHTTPLogBlock(
            request: request,
            statusCode: 200,
            sessionID: "session-123",
            date: Date(timeIntervalSince1970: 1_714_469_200)
        )
        let lines = logBlock.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines.count == 4)
        #expect(lines[0].contains(" info session-123 200"))
        #expect(lines[0].contains("+") == false)
        #expect(lines[0].range(of: #"^\d{2}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} info session-123 200$"#, options: .regularExpression) != nil)
        #expect(lines[1] == "POST /mcp")
        #expect(lines[2] == "tools/list")
        #expect(lines[3] == "{\"cursor\":\"next\"}")
    }
}
