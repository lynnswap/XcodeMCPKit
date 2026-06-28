import Foundation
import Testing
import XcodeMCPCore
import XcodeMCPProcessRuntime
@testable import XcodeMCPProxyKit

struct JSONRPCResponseCompletionTrackerTests {
    @Test func completionTracksStringAndNumericIDsSeparately() async throws {
        let completion = JSONRPC.ResponseCompletionTracker(ids: [
            .number(.int(1)),
            .string("1"),
        ])

        let completedAfterNumeric = await completion.record(try responseData(id: 1))
        #expect(completedAfterNumeric == false)

        let completedAfterString = await completion.record(try responseData(id: "1"))
        #expect(completedAfterString == true)
    }

    @Test func completionTracksBatchResponsesAndIgnoresNotifications() async throws {
        let completion = JSONRPC.ResponseCompletionTracker(ids: [
            .number(.int(1)),
            .number(.int(2)),
        ])

        let completedAfterNotification = await completion.record(
            try jsonData([
                "jsonrpc": "2.0",
                "method": "notifications/progress",
                "params": ["value": 1],
            ])
        )
        #expect(completedAfterNotification == false)

        let completedAfterBatch = await completion.record(
            try jsonData([
                [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "result": [:] as [String: Any],
                ],
                [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "error": [
                        "code": -32000,
                        "message": "failed",
                    ],
                ],
            ])
        )
        #expect(completedAfterBatch == true)
    }
}

private func responseData(id: Any) throws -> Data {
    try jsonData([
        "jsonrpc": "2.0",
        "id": id,
        "result": [:] as [String: Any],
    ])
}

private func jsonData(_ payload: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: payload, options: [])
}
