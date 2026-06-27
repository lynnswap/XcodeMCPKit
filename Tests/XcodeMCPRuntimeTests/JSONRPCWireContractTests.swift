import Foundation
import Testing
import XcodeMCPRuntime

@Suite
struct JSONRPCWireContractTests {
    @Test func requestAndResponseBuildersRemainStable() throws {
        let requestData = try JSONRPC.Wire.data(
            from: JSONRPC.Wire.requestObject(
                id: "request-1",
                method: "tools/call",
                params: .object([
                    "name": .string("DocumentationSearch"),
                    "arguments": .object([
                        "query": .string("SwiftUI"),
                        "limit": .number(.int(2)),
                        "exact": .bool(true),
                    ]),
                ])
            )
        )
        let request = try #require(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        let params = try #require(request["params"] as? [String: Any])
        let arguments = try #require(params["arguments"] as? [String: Any])

        #expect(request["jsonrpc"] as? String == "2.0")
        #expect(request["id"] as? String == "request-1")
        #expect(request["method"] as? String == "tools/call")
        #expect(arguments["query"] as? String == "SwiftUI")
        #expect((arguments["limit"] as? NSNumber)?.intValue == 2)
        #expect(arguments["exact"] as? Bool == true)

        let resultData = try JSONRPC.Wire.resultResponseData(
            id: try #require(JSONRPC.ID(any: NSNumber(value: 42))),
            result: .object(["ok": .bool(true)])
        )
        let resultObject = try #require(
            JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        )
        let result = try #require(resultObject["result"] as? [String: Any])

        #expect(resultObject["jsonrpc"] as? String == "2.0")
        #expect((resultObject["id"] as? NSNumber)?.intValue == 42)
        #expect(result["ok"] as? Bool == true)
    }

    @Test func batchErrorsAndResponseParsingRemainStable() throws {
        let stringID = try #require(JSONRPC.ID(any: "a"))
        let numberID = try #require(JSONRPC.ID(any: NSNumber(value: 7)))
        let batchData = try #require(
            try JSONRPC.Wire.errorResponseData(
                ids: [stringID, numberID],
                code: -32002,
                message: "upstream overloaded",
                forceBatchArray: true,
                includeNullIDWhenEmpty: false
            )
        )
        let batch = try #require(
            JSONSerialization.jsonObject(with: batchData) as? [[String: Any]]
        )
        let firstError = try #require(batch[0]["error"] as? [String: Any])
        let secondError = try #require(batch[1]["error"] as? [String: Any])

        #expect(batch.count == 2)
        #expect(batch[0]["jsonrpc"] as? String == "2.0")
        #expect(batch[0]["id"] as? String == "a")
        #expect((firstError["code"] as? NSNumber)?.intValue == -32002)
        #expect(firstError["message"] as? String == "upstream overloaded")
        #expect((batch[1]["id"] as? NSNumber)?.intValue == 7)
        #expect((secondError["code"] as? NSNumber)?.intValue == -32002)

        let rewrittenData = try JSONRPC.Wire.dataByReplacingID(
            in: batch[0],
            with: numberID
        )
        let rewritten = try #require(
            JSONSerialization.jsonObject(with: rewrittenData) as? [String: Any]
        )
        let parsedError = try #require(JSONRPC.Wire.errorPayload(inResponseObject: rewritten))

        #expect((rewritten["id"] as? NSNumber)?.intValue == 7)
        #expect(parsedError.code == -32002)
        #expect(parsedError.message == "upstream overloaded")
    }
}
