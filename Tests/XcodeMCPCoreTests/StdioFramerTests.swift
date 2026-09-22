import Foundation
import Testing
import XcodeMCPCore

@Suite
struct StdioFramerTests {
    @Test func stdioFramerEmitsJSONObject() {
        let framer = StdioFramer()
        let json = #"{"jsonrpc":"2.0","id":1}"#

        let result = framer.append(Data(json.utf8))

        #expect(result.messages.count == 1)
        #expect(result.protocolViolation == nil)
        #expect(result.bufferedByteCount == 0)
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerEmitsMultipleMessagesSeparatedByNewlines() {
        let framer = StdioFramer()
        let json1 = #"{"jsonrpc":"2.0","id":1}"#
        let json2 = #"{"jsonrpc":"2.0","id":2}"#

        let result = framer.append(Data("\(json1)\n\(json2)\n".utf8))

        #expect(result.messages.count == 2)
        #expect(result.protocolViolation == nil)
        #expect(String(data: result.messages[0], encoding: .utf8) == json1)
        #expect(String(data: result.messages[1], encoding: .utf8) == json2)
    }

    @Test func stdioFramerEmitsTopLevelJSONArrayForBoundaryValidation() {
        let framer = StdioFramer()
        let json = #"[{"jsonrpc":"2.0","id":1},{"jsonrpc":"2.0","method":"notifications/progress"}]"#

        let result = framer.append(Data(json.utf8))

        #expect(result.messages.count == 1)
        #expect(result.protocolViolation == nil)
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerEmitsContentLengthFrame() {
        let framer = StdioFramer()
        let json = #"{"jsonrpc":"2.0","id":1}"#
        let payload = "Content-Length: \(json.utf8.count)\r\n\r\n\(json)"

        let result = framer.append(Data(payload.utf8))

        #expect(result.messages.count == 1)
        #expect(result.protocolViolation == nil)
        #expect(result.bufferedByteCount == 0)
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerBuffersPartialContentLengthFrameAcrossAppends() {
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

    @Test func stdioFramerBuffersIncompleteJSONWithoutDroppingBytes() {
        let framer = StdioFramer()
        let partial = #"{"jsonrpc":"2.0","id":1,"result":{"value":"abc"#

        let result = framer.append(Data(partial.utf8))

        #expect(result.messages.isEmpty)
        #expect(result.protocolViolation == nil)
        #expect(result.bufferedByteCount == partial.utf8.count)
    }

    @Test func stdioFramerEmitsLargeMessageSplitAcrossAppends() {
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

    @Test func stdioFramerTreatsInvalidContentLengthHeaderAsProtocolViolation() {
        let framer = StdioFramer()
        let payload = "Content-Length: abc\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1}"

        let result = framer.append(Data(payload.utf8))

        #expect(result.messages.isEmpty)
        #expect(result.bufferedByteCount == payload.utf8.count)
        #expect(result.protocolViolation?.reason == .invalidContentLengthHeader)
    }

    @Test func stdioFramerTreatsInvalidContentLengthBodyAsProtocolViolation() {
        let framer = StdioFramer()
        let payload = "Content-Length: 5\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1}"

        let result = framer.append(Data(payload.utf8))

        #expect(result.messages.isEmpty)
        #expect(result.bufferedByteCount == payload.utf8.count)
        #expect(result.protocolViolation?.reason == .invalidJSON)
    }

    @Test func stdioFramerTreatsLeadingLogLineAsProtocolViolation() {
        let framer = StdioFramer()
        let payload = "some log line\n{\"jsonrpc\":\"2.0\",\"id\":1}"

        let result = framer.append(Data(payload.utf8))

        #expect(result.messages.isEmpty)
        #expect(result.bufferedByteCount == payload.utf8.count)
        #expect(result.protocolViolation?.reason == .unexpectedLeadingByte)
    }

    @Test func stdioFramerTreatsMalformedJSONFollowedByValidJSONAsProtocolViolation() {
        let framer = StdioFramer()
        let payload = #"{"jsonrpc":"2.0","id":1,"result":tru}{"jsonrpc":"2.0","id":2}"#

        let result = framer.append(Data(payload.utf8))

        #expect(result.messages.isEmpty)
        #expect(result.bufferedByteCount == payload.utf8.count)
        #expect(result.protocolViolation?.reason == .invalidJSON)
    }

    @Test(arguments: [false, true])
    func stdioFramerAcceptsLargeMessagesRegardlessOfChunking(contentLength: Bool) {
        let text = String(repeating: "x", count: 5 * 1024 * 1024)
        let message = Data(#"{"jsonrpc":"2.0","id":1,"result":{"text":"\#(text)"}}"#.utf8)
        let header = contentLength ? Data("Content-Length: \(message.count)\r\n\r\n".utf8) : Data()
        let wire = header + message

        let whole = StdioFramer().append(wire)
        #expect(whole.messages == [message])
        #expect(whole.protocolViolation == nil)

        let framer = StdioFramer()
        let split = 4 * 1024 * 1024 + 1
        let prefix = framer.append(Data(wire.prefix(split)))
        #expect(prefix.messages.isEmpty)
        #expect(prefix.protocolViolation == nil)
        let suffix = framer.append(Data(wire.dropFirst(split)))
        #expect(suffix.messages == whole.messages)
        #expect(suffix.protocolViolation == nil)
        #expect(suffix.bufferedByteCount == 0)
    }

    @Test func stdioFramerRejectsUnrepresentableContentLengthWithoutOverflow() {
        let result = StdioFramer().append(Data("Content-Length: \(Int.max)\r\n\r\n".utf8))
        #expect(result.messages.isEmpty)
        #expect(result.protocolViolation?.reason == .invalidContentLengthHeader)
    }

    @Test(arguments: [false, true])
    func stdioFramerBoundsHeadersIndependentlyOfBodySize(delimited: Bool) {
        let header = "Content-Length:" + String(repeating: " ", count: 4 * 1024 * 1024)
            + (delimited ? "1\r\n\r\n{}" : "")
        let result = StdioFramer().append(Data(header.utf8))
        #expect(result.messages.isEmpty)
        #expect(result.protocolViolation?.reason == .headerTooLarge)
    }

    @Test func stdioFramerReassemblesLargeBodyFromPipeSizedChunks() {
        let message = Data(("{\"text\":\"" + String(repeating: "x", count: 16 * 1024 * 1024) + "\"}").utf8)
        let framer = StdioFramer()
        var messages: [Data] = []
        for offset in stride(from: 0, to: message.count, by: 64 * 1024) {
            let end = min(offset + 64 * 1024, message.count)
            let result = framer.append(message.subdata(in: offset..<end))
            #expect(result.protocolViolation == nil)
            messages.append(contentsOf: result.messages)
        }
        #expect(messages == [message])
    }

    @Test func stdioFramerPreservesEscapesAndNestedValuesAcrossEveryByteBoundary() {
        let first = Data(#"{"text":"quote\" slash\\ unicode\u007D braces{}[]","values":[true,null,-1.25e+2,{"key":"値"}]}"#.utf8)
        let second = Data(#"[{"second":false}]"#.utf8)
        let framer = StdioFramer()
        var messages: [Data] = []
        for byte in first + Data("\n".utf8) + second {
            let result = framer.append(Data([byte]))
            #expect(result.protocolViolation == nil)
            messages.append(contentsOf: result.messages)
        }
        #expect(messages == [first, second])
    }

    @Test(arguments: [#"{"result":truX"#, #"{"key" nope"#, "[01", "[1.e", "[1e+]", "[falseX"])
    func stdioFramerRejectsInvalidPrefixesWithoutWaitingForClosure(prefix: String) {
        let result = StdioFramer().append(Data(prefix.utf8))
        #expect(result.messages.isEmpty)
        #expect(result.protocolViolation?.reason == .invalidJSON)
    }

    @Test(arguments: [#"{"result":{},}"#, "[1,]"], [false, true])
    func stdioFramerRejectsTrailingCommas(json: String, contentLength: Bool) {
        let header = contentLength ? "Content-Length: \(json.utf8.count)\r\n\r\n" : ""
        let result = StdioFramer().append(Data((header + json).utf8))
        #expect(result.messages.isEmpty)
        #expect(result.protocolViolation?.reason == .invalidJSON)
    }

    @Test func stdioFramerDiscardsWhitespaceBetweenMessages() {
        let framer = StdioFramer()
        for _ in 0..<5 {
            let result = framer.append(Data(repeating: 0x20, count: 1024 * 1024))
            #expect(result.messages.isEmpty)
            #expect(result.protocolViolation == nil)
            #expect(result.bufferedByteCount == 0)
        }
        let message = Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)
        #expect(framer.append(message).messages == [message])
    }

    @Test func stdioFramerTreatsContentLengthLookingLogLineAsProtocolViolation() {
        let framer = StdioFramer()
        let payload = "Content-Length: 123\n{\"jsonrpc\":\"2.0\",\"id\":1}"

        let result = framer.append(Data(payload.utf8))

        #expect(result.messages.isEmpty)
        #expect(result.bufferedByteCount == payload.utf8.count)
        #expect(result.protocolViolation?.reason == .invalidContentLengthHeader)
    }
}
