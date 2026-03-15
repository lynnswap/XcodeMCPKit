import Foundation
import Testing

@testable import ProxyCore

@Suite
struct SSECodecTests {
    @Test func sseCodecEncodesSingleLineDataEvent() async throws {
        let json = #"{"jsonrpc":"2.0","method":"ping"}"#
        let data = Data(json.utf8)
        let encoded = SSECodec.encodeDataEvent(data)
        #expect(encoded == "data: \(json)\n\n")
    }

    @Test func sseCodecRoundTripsMultiLinePayload() async throws {
        let payload = "{\n\"a\": 1\n}"
        let data = Data(payload.utf8)
        let encoded = SSECodec.encodeDataEvent(data)
        #expect(encoded == "data: {\ndata: \"a\": 1\ndata: }\n\n")

        var decoder = SSEDecoder()
        var decodedEvents: [String] = []
        for line in (encoded ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
            if let event = decoder.feed(line: String(line)) {
                decodedEvents.append(String(decoding: event, as: UTF8.self))
            }
        }
        if let tail = decoder.flushIfNeeded() {
            decodedEvents.append(String(decoding: tail, as: UTF8.self))
        }

        #expect(decodedEvents == [payload])
    }

    @Test func sseDecoderIgnoresCommentsAndHandlesCRLF() async throws {
        var decoder = SSEDecoder()

        // Comment line should not produce an event.
        #expect(decoder.feed(line: ": ok") == nil)
        #expect(decoder.feed(line: "") == nil)

        // CR should be stripped from the line.
        let json = #"{"a":1}"#
        #expect(decoder.feed(line: "data: \(json)\r") == nil)
        let event = decoder.feed(line: "")
        #expect(event != nil)
        #expect(String(decoding: event ?? Data(), as: UTF8.self) == json)
    }
}
