import Foundation
import Testing
import XcodeMCPKit

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

    @Test func errorResponseAndParsingRemainStable() throws {
        let numberID = try #require(JSONRPC.ID(any: NSNumber(value: 7)))
        let errorData = try JSONRPC.Wire.errorResponseData(
            id: numberID,
            code: -32002,
            message: "upstream overloaded"
        )
        let response = try #require(
            JSONSerialization.jsonObject(with: errorData) as? [String: Any]
        )
        let error = try #require(response["error"] as? [String: Any])

        #expect(response["jsonrpc"] as? String == "2.0")
        #expect((response["id"] as? NSNumber)?.intValue == 7)
        #expect((error["code"] as? NSNumber)?.intValue == -32002)
        #expect(error["message"] as? String == "upstream overloaded")

        let rewrittenData = try JSONRPC.Wire.dataByReplacingID(
            in: response,
            with: numberID
        )
        let rewritten = try #require(
            JSONSerialization.jsonObject(with: rewrittenData) as? [String: Any]
        )
        let parsedError = try #require(JSONRPC.Wire.errorPayload(inResponseObject: rewritten))

        #expect((rewritten["id"] as? NSNumber)?.intValue == 7)
        #expect(parsedError.code == -32002)
        #expect(parsedError.message == "upstream overloaded")

        let invalidRequestData = try JSONRPC.Wire.errorResponseData(
            id: nil,
            code: -32600,
            message: "invalid request"
        )
        let invalidRequest = try #require(
            JSONSerialization.jsonObject(with: invalidRequestData) as? [String: Any]
        )
        let invalidRequestError = try #require(invalidRequest["error"] as? [String: Any])
        #expect(invalidRequest["id"] is NSNull)
        #expect((invalidRequestError["code"] as? NSNumber)?.intValue == -32600)
        #expect(invalidRequestError["message"] as? String == "invalid request")
    }
}
