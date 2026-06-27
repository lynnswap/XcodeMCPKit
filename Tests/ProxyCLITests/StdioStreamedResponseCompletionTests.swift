import Foundation
import Testing
import XcodeMCPRuntime
@testable import XcodeMCPProxyKit

struct StdioStreamedResponseCompletionTests {
    @Test func completionTracksStringAndNumericIDsSeparately() async throws {
        let completion = StdioStreamedResponseCompletion(ids: [
            .number(.int(1)),
            .string("1"),
        ])

        let completedAfterNumeric = await completion.record(try responseData(id: 1))
        #expect(completedAfterNumeric == false)

        let completedAfterString = await completion.record(try responseData(id: "1"))
        #expect(completedAfterString == true)
    }
}

private func responseData(id: Any) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": [:] as [String: Any],
        ],
        options: []
    )
}
