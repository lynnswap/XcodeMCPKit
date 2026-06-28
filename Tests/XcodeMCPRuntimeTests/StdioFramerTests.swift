import Foundation
import Testing
import XcodeMCPCore
import XcodeMCPProcessRuntime
import XcodeMCPProxyRuntime

@Suite
struct StdioFramerTests {
    @Test func stdioFramerEmitsJSONObject() async throws {
        let framer = StdioFramer()
        let json = #"{"jsonrpc":"2.0","id":1}"#

        let result = framer.append(Data(json.utf8))

        #expect(result.messages.count == 1)
        #expect(result.protocolViolation == nil)
        #expect(result.bufferedByteCount == 0)
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerEmitsMultipleMessagesSeparatedByNewlines() async throws {
        let framer = StdioFramer()
        let json1 = #"{"jsonrpc":"2.0","id":1}"#
        let json2 = #"{"jsonrpc":"2.0","id":2}"#

        let result = framer.append(Data("\(json1)\n\(json2)\n".utf8))

        #expect(result.messages.count == 2)
        #expect(result.protocolViolation == nil)
        #expect(String(data: result.messages[0], encoding: .utf8) == json1)
        #expect(String(data: result.messages[1], encoding: .utf8) == json2)
    }

    @Test func stdioFramerEmitsBatchArray() async throws {
        let framer = StdioFramer()
        let json = #"[{"jsonrpc":"2.0","id":1},{"jsonrpc":"2.0","method":"notifications/progress"}]"#

        let result = framer.append(Data(json.utf8))

        #expect(result.messages.count == 1)
        #expect(result.protocolViolation == nil)
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerEmitsContentLengthFrame() async throws {
        let framer = StdioFramer()
        let json = #"{"jsonrpc":"2.0","id":1}"#
        let payload = "Content-Length: \(json.utf8.count)\r\n\r\n\(json)"

        let result = framer.append(Data(payload.utf8))

        #expect(result.messages.count == 1)
        #expect(result.protocolViolation == nil)
        #expect(result.bufferedByteCount == 0)
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerBuffersPartialContentLengthFrameAcrossAppends() async throws {
        let framer = StdioFramer()
        let json = #"{"jsonrpc":"2.0","id":1}"#
        let header = "Content-Length: \(json.utf8.count)\r\n"

        let resultA = framer.append(Data(header.utf8))
        #expect(resultA.messages.isEmpty)
        #expect(resultA.protocolViolation == nil)
        #expect(resultA.bufferedByteCount == header.utf8.count)

        let resultB = framer.append(Data("\r\n\(json)".utf8))
        #expect(resultB.messages.count == 1)
        #expect(resultB.protocolViolation == nil)
        #expect(resultB.bufferedByteCount == 0)
        #expect(String(data: resultB.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerBuffersIncompleteJSONWithoutDroppingBytes() async throws {
        let framer = StdioFramer()
        let partial = #"{"jsonrpc":"2.0","id":1,"result":{"value":"abc"#

        let result = framer.append(Data(partial.utf8))

        #expect(result.messages.isEmpty)
        #expect(result.protocolViolation == nil)
        #expect(result.bufferedByteCount == partial.utf8.count)
    }

    @Test func stdioFramerEmitsLargeMessageSplitAcrossAppends() async throws {
        let framer = StdioFramer()
        let text = String(repeating: "x", count: 128 * 1024)
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"text":"\#(text)"}}"#
        let split = json.index(json.startIndex, offsetBy: 32 * 1024)

        let resultA = framer.append(Data(json[..<split].utf8))
        #expect(resultA.messages.isEmpty)
        #expect(resultA.protocolViolation == nil)
        #expect(resultA.bufferedByteCount == json[..<split].utf8.count)

        let resultB = framer.append(Data(json[split...].utf8))
        #expect(resultB.messages.count == 1)
        #expect(resultB.protocolViolation == nil)
        #expect(resultB.bufferedByteCount == 0)
        #expect(String(data: resultB.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerTreatsInvalidContentLengthHeaderAsProtocolViolation() async throws {
        let framer = StdioFramer()
        let payload = "Content-Length: abc\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1}"

        let result = framer.append(Data(payload.utf8))

        #expect(result.messages.isEmpty)
        #expect(result.bufferedByteCount == payload.utf8.count)
        #expect(result.protocolViolation?.reason == .invalidContentLengthHeader)
    }

    @Test func stdioFramerTreatsInvalidContentLengthBodyAsProtocolViolation() async throws {
        let framer = StdioFramer()
        let payload = "Content-Length: 5\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1}"

        let result = framer.append(Data(payload.utf8))

        #expect(result.messages.isEmpty)
        #expect(result.bufferedByteCount == payload.utf8.count)
        #expect(result.protocolViolation?.reason == .invalidJSON)
    }

    @Test func stdioFramerTreatsLeadingLogLineAsProtocolViolation() async throws {
        let framer = StdioFramer()
        let payload = "some log line\n{\"jsonrpc\":\"2.0\",\"id\":1}"

        let result = framer.append(Data(payload.utf8))

        #expect(result.messages.isEmpty)
        #expect(result.bufferedByteCount == payload.utf8.count)
        #expect(result.protocolViolation?.reason == .unexpectedLeadingByte)
    }

    @Test func stdioFramerTreatsMalformedJSONFollowedByValidJSONAsProtocolViolation() async throws {
        let framer = StdioFramer()
        let payload = #"{"jsonrpc":"2.0","id":1,"result":tru}{"jsonrpc":"2.0","id":2}"#

        let result = framer.append(Data(payload.utf8))

        #expect(result.messages.isEmpty)
        #expect(result.bufferedByteCount == payload.utf8.count)
        #expect(result.protocolViolation?.reason == .invalidJSON)
    }

    @Test func stdioFramerFailsOversizedIncompleteJSONAtHardLimit() async throws {
        let framer = StdioFramer()
        let text = String(repeating: "x", count: 4 * 1024 * 1024)
        let payload = #"{"jsonrpc":"2.0","id":1,"result":{"text":"\#(text)"#

        let result = framer.append(Data(payload.utf8))

        #expect(result.messages.isEmpty)
        #expect(result.bufferedByteCount == payload.utf8.count)
        #expect(result.protocolViolation?.reason == .bufferLimitExceeded)
    }

    @Test func stdioFramerTreatsContentLengthLookingLogLineAsProtocolViolation() async throws {
        let framer = StdioFramer()
        let payload = "Content-Length: 123\n{\"jsonrpc\":\"2.0\",\"id\":1}"

        let result = framer.append(Data(payload.utf8))

        #expect(result.messages.isEmpty)
        #expect(result.bufferedByteCount == payload.utf8.count)
        #expect(result.protocolViolation?.reason == .invalidContentLengthHeader)
    }
}
