import Foundation
import Testing
import XcodeMCPCore
import XcodeMCPProcessRuntime
@testable import XcodeMCPProxyKit

struct JSONRPCRuntimeStdioContractTests {
    @Test func requestEnvelopeInspectsSingleRequestsAndNotifications() throws {
        let request = JSONRPC.Request.Envelope.inspect(
            try jsonData([
                "jsonrpc": "2.0",
                "id": 42,
                "method": "tools/list",
            ])
        )
        #expect(request.method == "tools/list")
        #expect(request.ids == [.number(.int(42))])
        #expect(request.isBatch == false)
        #expect(request.expectsResponse)

        let notification = JSONRPC.Request.Envelope.inspect(
            try jsonData([
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
            ])
        )
        #expect(notification.method == "notifications/initialized")
        #expect(notification.ids.isEmpty)
        #expect(notification.isBatch == false)
        #expect(notification.expectsResponse == false)
    }

    @Test func requestEnvelopeCollectsOnlyRequestIDsFromBatchInput() throws {
        let envelope = JSONRPC.Request.Envelope.inspect(
            try jsonData([
                [
                    "jsonrpc": "2.0",
                    "id": "a",
                    "method": "tools/list",
                ],
                [
                    "jsonrpc": "2.0",
                    "method": "notifications/initialized",
                ],
                [
                    "jsonrpc": "2.0",
                    "id": 7,
                    "method": "tools/call",
                ],
                "not an object",
            ])
        )

        #expect(envelope.method == nil)
        #expect(envelope.ids == [.string("a"), .number(.int(7))])
        #expect(envelope.isBatch)
        #expect(envelope.expectsResponse)
    }

    @Test func requestEnvelopeTreatsMalformedAndNonRequestPayloadsAsNotificationOnly() throws {
        let invalidJSON = JSONRPC.Request.Envelope.inspect(Data("{".utf8))
        #expect(invalidJSON.method == nil)
        #expect(invalidJSON.ids.isEmpty)
        #expect(invalidJSON.isBatch == false)
        #expect(invalidJSON.expectsResponse == false)

        let nonRequest = JSONRPC.Request.Envelope.inspect(try jsonData(["ok": true]))
        #expect(nonRequest.method == nil)
        #expect(nonRequest.ids.isEmpty)
        #expect(nonRequest.isBatch == false)
        #expect(nonRequest.expectsResponse == false)
    }

    @Test func wireBuildsStdioErrorPayloadsFromRawIDValues() throws {
        let singleData = try #require(
            try JSONRPC.Wire.errorResponseData(
                idValues: [.string("request-1")],
                code: -32000,
                message: "upstream unavailable"
            )
        )
        let single = try #require(
            JSONSerialization.jsonObject(with: singleData) as? [String: Any]
        )
        let singleError = try #require(single["error"] as? [String: Any])
        #expect(single["jsonrpc"] as? String == "2.0")
        #expect(single["id"] as? String == "request-1")
        #expect((singleError["code"] as? NSNumber)?.intValue == -32000)
        #expect(singleError["message"] as? String == "upstream unavailable")

        let batchData = try #require(
            try JSONRPC.Wire.errorResponseData(
                idValues: [.string("a"), .number(.int(7))],
                code: -32001,
                message: "upstream overloaded"
            )
        )
        let batch = try #require(
            JSONSerialization.jsonObject(with: batchData) as? [[String: Any]]
        )
        #expect(batch.count == 2)
        #expect(batch[0]["id"] as? String == "a")
        #expect((batch[1]["id"] as? NSNumber)?.intValue == 7)

        let notificationOnlyData = try JSONRPC.Wire.errorResponseData(
            idValues: [],
            code: -32000,
            message: "ignored"
        )
        #expect(notificationOnlyData == nil)
    }
}

private func jsonData(_ payload: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: payload, options: [])
}
