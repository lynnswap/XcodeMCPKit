import Foundation
import Testing
import XcodeMCPWire

@Suite
struct NativeStdioFramingTests {
    @Test(arguments: ["C", "Content-", "Content-Lengt"], [1, 4096])
    func incompleteHeaderPrefixesBecomeLinesWhenTheDelimiterArrives(prefix: String, chunkSize: Int) {
        let framer = StdioFramer(mode: .delimitedMessages)
        let following = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let input = Data((prefix + "\n").utf8) + following + Data([0x0A])
        var messages: [Data] = []
        for offset in stride(from: 0, to: input.count, by: chunkSize) {
            let end = min(offset + chunkSize, input.count)
            let result = framer.append(input.subdata(in: offset..<end))
            #expect(result.protocolViolation == nil)
            messages.append(contentsOf: result.messages)
        }
        #expect(messages == [Data(prefix.utf8), following])
        #expect(framer.bufferedMessageByteCount == 0)
    }

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

    @Test func fragmentedLargeLineKeepsTheFollowingPartialLine() {
        let framer = StdioFramer(mode: .delimitedMessages)
        let message = Data((#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"text":""#
            + String(repeating: "a", count: 2 * 1024 * 1024)
            + #""}}"#).utf8)
        let following = Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8)
        let third = Data(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#.utf8)

        for offset in stride(from: 0, to: message.count, by: 64 * 1024) {
            let end = min(offset + 64 * 1024, message.count)
            let result = framer.append(message.subdata(in: offset..<end))
            #expect(result.messages.isEmpty)
            #expect(result.protocolViolation == nil)
            #expect(result.bufferedByteCount == end)
        }

        let split = following.count / 2
        let first = framer.append(Data([0x0A]) + following.prefix(split))
        #expect(first.messages == [message])
        #expect(first.protocolViolation == nil)
        #expect(first.bufferedByteCount == split)

        let rest = framer.append(following.suffix(from: split) + Data([0x0A]) + third + Data([0x0A]))
        #expect(rest.messages == [following, third])
        #expect(rest.protocolViolation == nil)
        #expect(rest.bufferedByteCount == 0)
    }

    @Test func fragmentedNativeLinesCanBeFollowedByLengthDelimitedFrames() {
        let framer = StdioFramer(mode: .delimitedMessages)
        let line = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let body = Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8)
        let following = Data(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#.utf8)
        let prefix = framer.append(Data(line.dropLast()))
        #expect(prefix.messages.isEmpty)
        #expect(prefix.protocolViolation == nil)

        let boundary = framer.append(Data(line.suffix(1)) + Data("\nContent-".utf8))
        #expect(boundary.messages == [line])
        #expect(boundary.protocolViolation == nil)
        #expect(boundary.bufferedByteCount == "Content-".utf8.count)

        let rest = framer.append(Data("Length: \(body.count)\r\n\r\n".utf8) + body + following + Data([0x0A]))
        #expect(rest.messages == [body, following])
        #expect(rest.protocolViolation == nil)
        #expect(rest.bufferedByteCount == 0)
    }

    @Test(arguments: [1, 64, 512], ["\n", "\r\n"])
    func contentLengthHeadersDoNotContributeToBufferedMessageBytes(chunkSize: Int, lineEnding: String) {
        let framer = StdioFramer(mode: .delimitedMessages)
        let prefix = #"{"text":""#
        let suffix = #""}"#
        let body = Data((prefix + String(repeating: "a", count: 256 - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
        let header = Data([
            "Content-Length: \(body.count)",
            "Content-Type: application/json",
            "X-Padding: " + String(repeating: "x", count: 200),
            "", "",
        ].joined(separator: lineEnding).utf8)
        let frame = header + body

        for offset in stride(from: 0, to: frame.count - 1, by: chunkSize) {
            let end = min(offset + chunkSize, frame.count - 1)
            let result = framer.append(frame.subdata(in: offset..<end))
            #expect(result.messages.isEmpty)
            #expect(result.protocolViolation == nil)
            #expect(result.bufferedByteCount == end)
            #expect(framer.bufferedMessageByteCount == max(0, end - header.count))
        }
        #expect(framer.bufferedMessageByteCount == body.count - 1)

        let completed = framer.append(Data(frame.suffix(1)))
        #expect(completed.messages == [body])
        #expect(completed.protocolViolation == nil)
        #expect(framer.bufferedMessageByteCount == 0)
    }

    @Test func linePayloadSizeCountsUTF8BytesUntilTheDelimiterArrives() {
        let framer = StdioFramer(mode: .delimitedMessages)
        let message = Data(#"{"text":"é😃"}"#.utf8)
        for offset in message.indices {
            let result = framer.append(Data([message[offset]]))
            #expect(result.messages.isEmpty)
            #expect(result.protocolViolation == nil)
            #expect(framer.bufferedMessageByteCount == offset + 1)
        }
        let completed = framer.append(Data([0x0A]))
        #expect(completed.messages == [message])
        #expect(completed.protocolViolation == nil)
        #expect(framer.bufferedMessageByteCount == 0)
    }

    @Test(arguments: [false, true])
    func headerSizeRemainsBoundedSeparatelyFromPayloadSize(completeHeader: Bool) {
        let framer = StdioFramer(mode: .delimitedMessages)
        var header = Data(("Content-Length: " + String(repeating: " ", count: 4 * 1024 * 1024) + "1").utf8)
        if completeHeader { header.append(Data("\r\n\r\n".utf8)) }
        let result = framer.append(header)
        #expect(result.messages.isEmpty)
        #expect(result.protocolViolation?.reason == .headerTooLarge)
        #expect(framer.bufferedMessageByteCount == 0)
    }
}
