import Foundation
import Testing
import XcodeMCPKit

@testable import XcodeMCPProxyKit

@Suite
struct MCPErrorResponderTests {
    @Test func errorWireShapeRemainsStable() throws {
        let responseData = try #require(
            MCPErrorResponder.errorResponseData(
                id: JSONRPC.ID(any: 9),
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
