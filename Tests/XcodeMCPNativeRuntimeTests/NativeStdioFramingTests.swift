import Foundation
import Testing
import XcodeMCPWire

@Suite
struct NativeStdioFramingTests {
    @Test func lengthDelimitedMalformedJSONWaitsForTheEntireBody() {
        let framer = StdioFramer(mode: .delimitedMessages)
        let malformed = Data(#"{"jsonrpc":"2.0" invalid}"#.utf8)
        let header = Data("Content-Length: \(malformed.count)\r\n\r\n".utf8)
        let prefix = framer.append(header + Data(malformed.dropLast()))
        #expect(prefix.messages.isEmpty)
        #expect(prefix.protocolViolation == nil)
        #expect(prefix.bufferedByteCount == header.count + malformed.count - 1)
        let valid = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let suffix = framer.append(Data(malformed.suffix(1)) + valid + Data([0x0A]))
        #expect(suffix.messages == [malformed, valid])
        #expect(suffix.protocolViolation == nil)
        #expect(suffix.bufferedByteCount == 0)
    }

    @Test func contentLengthBodyPreservesTheWholeFrameInsteadOfAnObjectPrefix() {
        let framer = StdioFramer(mode: .delimitedMessages)
        let malformed = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"} trailing"#.utf8)
        let header = Data("Content-Length: \(malformed.count)\r\n\r\n".utf8)
        let result = framer.append(header + malformed)
        #expect(result.messages == [malformed])
        #expect(result.protocolViolation == nil)
        #expect(result.bufferedByteCount == 0)
    }

    @Test(arguments: ["Content-Length: nope\r\n\r\n{}", "Content-Length: -1\r\n\r\nx", "Content-Length: \(Int.max)\r\n\r\n"])
    func malformedLengthHeadersRemainFramingErrors(raw: String) {
        let result = StdioFramer(mode: .delimitedMessages).append(Data(raw.utf8))
        #expect(result.messages.isEmpty)
        #expect(result.protocolViolation?.reason == .invalidContentLengthHeader)
    }

    @Test func nativeLinesRequireTheirDelimiterEvenWhenTheObjectIsComplete() throws {
        let framer = StdioFramer(mode: .delimitedMessages)
        let message = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let prefix = framer.append(message)
        #expect(prefix.messages.isEmpty)
        #expect(prefix.protocolViolation == nil)
        #expect(prefix.bufferedByteCount == message.count)
        let suffix = framer.append(Data([0x0D, 0x0A]))
        #expect(suffix.messages.count == 1)
        #expect(try nativeTestJSON(#require(suffix.messages.first)) == nativeTestJSON(message))
        #expect(suffix.protocolViolation == nil)
        #expect(suffix.bufferedByteCount == 0)
    }
}
