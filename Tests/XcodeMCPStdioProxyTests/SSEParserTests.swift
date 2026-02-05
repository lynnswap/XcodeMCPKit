import Foundation
import Testing
@testable import XcodeMCPStdioProxy

@Test func sseParserExtractsDataEvents() async throws {
    let parser = SSEParser()
    let input = """
event: message
data: {\"jsonrpc\":\"2.0\",\"method\":\"ping\"}

data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}


""".data(using: .utf8)!

    let outputs = parser.append(input)
    #expect(outputs.count == 2)

    let first = String(data: outputs[0], encoding: .utf8)
    let second = String(data: outputs[1], encoding: .utf8)
    #expect(first?.contains("\"method\":\"ping\"") == true)
    #expect(second?.contains("\"method\":\"notifications/initialized\"") == true)
}
