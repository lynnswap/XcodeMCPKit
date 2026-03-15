import Foundation
import Testing

@testable import ProxyCore

@Suite
struct StdioFramerTests {
    @Test func stdioFramerContentLength() async throws {
        let framer = StdioFramer()
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1}"
        let payload = "Content-Length: \(json.utf8.count)\r\n\r\n\(json)"
        let result = framer.append(Data(payload.utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.isEmpty)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerNDJSON() async throws {
        let framer = StdioFramer()
        let json1 = "{\"jsonrpc\":\"2.0\",\"id\":1}"
        let json2 = "{\"jsonrpc\":\"2.0\",\"id\":2}"
        let payload = "\(json1)\n\(json2)\n"
        let result = framer.append(Data(payload.utf8))
        #expect(result.messages.count == 2)
        #expect(result.recoveries.isEmpty)
        guard result.messages.count == 2 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json1)
        #expect(String(data: result.messages[1], encoding: .utf8) == json2)
    }

    @Test func stdioFramerRawJSON() async throws {
        let framer = StdioFramer()
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}"
        let result = framer.append(Data(json.utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.isEmpty)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerMultilineJSON() async throws {
        let framer = StdioFramer()
        let json = "{\n\"jsonrpc\":\"2.0\",\n\"id\":1,\n\"result\":{\"ok\":true}\n}"
        let result = framer.append(Data(json.utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.isEmpty)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerDropsLeadingNonJSONLineAndContinues() async throws {
        let framer = StdioFramer()
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1}"
        let payload = "some log line\n\(json)"
        let result = framer.append(Data(payload.utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.isEmpty)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerDoesNotStallOnContentLengthLookingLogLine() async throws {
        let framer = StdioFramer()
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1}"
        let payload = "Content-Length: 123\n\(json)"
        let result = framer.append(Data(payload.utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.isEmpty)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerKeepsWaitingForPartialContentLengthHeaderAcrossWrites() async throws {
        let framer = StdioFramer()
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1}"

        let header = "Content-Length: \(json.utf8.count)\r\n"
        let partsA = framer.append(Data(header.utf8))
        #expect(partsA.messages.isEmpty)
        #expect(partsA.recoveries.isEmpty)

        let rest = "\r\n\(json)"
        let partsB = framer.append(Data(rest.utf8))
        #expect(partsB.messages.count == 1)
        #expect(partsB.recoveries.isEmpty)
        guard partsB.messages.count == 1 else { return }
        #expect(String(data: partsB.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerRecoversFromBogusContentLengthBlock() async throws {
        let framer = StdioFramer()
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1}"
        let payload = "Content-Length: 123\n\nsome log line\n\(json)"
        let result = framer.append(Data(payload.utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.isEmpty)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerRecoversFromBogusContentLengthShorterThanJSON() async throws {
        let framer = StdioFramer()
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1}"
        let payload = "Content-Length: 5\r\n\r\n\(json)"
        let result = framer.append(Data(payload.utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.isEmpty)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerRecoversFromBogusContentLengthLongerThanJSON() async throws {
        let framer = StdioFramer()
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1}"
        let payload = "Content-Length: 123\n\n\(json)"
        let result = framer.append(Data(payload.utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.isEmpty)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerResyncsCorruptLeadingObjectToNextValidObject() async throws {
        let framer = StdioFramer()
        let corrupt = "{" + String(repeating: "x", count: 16 * 1024)
        let json = "{\"id\":2,\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true}}"

        let result = framer.append(Data((corrupt + "\n" + json).utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.count == 1)
        guard let recovery = result.recoveries.first else { return }
        #expect(recovery.kind == .resync)
        #expect(recovery.droppedPrefixBytes == corrupt.utf8.count + 1)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerResyncsCorruptLeadingObjectAndEmitsMultipleValidObjects() async throws {
        let framer = StdioFramer()
        let corrupt =
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"broken\":\""
            + String(repeating: "x", count: 16 * 1024)
        let json1 = "{\"id\":2,\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true}}"
        let json2 = "{\"id\":3,\"jsonrpc\":\"2.0\",\"result\":{\"ok\":false}}"

        let result = framer.append(Data((corrupt + "\n" + json1 + json2).utf8))
        #expect(result.messages.count == 2)
        #expect(result.recoveries.count == 1)
        guard result.messages.count == 2 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json1)
        #expect(String(data: result.messages[1], encoding: .utf8) == json2)
    }

    @Test func stdioFramerResyncsCorruptLeadingObjectToPrettyPrintedMethodFirstObject() async throws
    {
        let framer = StdioFramer()
        let corrupt = "{" + String(repeating: "x", count: 16 * 1024)
        let json = """
            {
              "method": "notifications/progress",
              "jsonrpc": "2.0",
              "params": {
                "value": true
              }
            }
            """

        let result = framer.append(Data((corrupt + "\n" + json).utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.count == 1)
        guard let recovery = result.recoveries.first else { return }
        #expect(recovery.kind == .resync)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerResyncsCorruptLeadingObjectToPrettyPrintedBatch() async throws {
        let framer = StdioFramer()
        let corrupt = "{" + String(repeating: "x", count: 16 * 1024)
        let json = """
            [
              {
                "method": "notifications/cancelled",
                "jsonrpc": "2.0"
              }
            ]
            """

        let result = framer.append(Data((corrupt + "\n" + json).utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.count == 1)
        guard let recovery = result.recoveries.first else { return }
        #expect(recovery.kind == .resync)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerResyncsCorruptLeadingArrayToNextBatch() async throws {
        let framer = StdioFramer()
        let corrupt = "[" + String(repeating: "x", count: 16 * 1024)
        let json = """
            [
              {
                "jsonrpc": "2.0",
                "id": 2
              },
              {
                "jsonrpc": "2.0",
                "method": "notifications/progress"
              }
            ]
            """

        let result = framer.append(Data((corrupt + "\n" + json).utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.count == 1)
        guard let recovery = result.recoveries.first else { return }
        #expect(recovery.kind == .resync)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerResyncsCorruptObjectToAdjacentRawJSONObject() async throws {
        let framer = StdioFramer()
        let corrupt =
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":tru}"
            + String(repeating: "x", count: 16 * 1024)
            + "}"
        let json = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":true}}"

        let result = framer.append(Data((corrupt + json).utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.count == 1)
        guard let recovery = result.recoveries.first else { return }
        #expect(recovery.kind == .resync)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerResyncsSmallInvalidObjectWithoutWaitingForThreshold() async throws {
        let framer = StdioFramer()
        let corrupt = "{\"result\":tru}"
        let json = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":true}}"

        let result = framer.append(Data((corrupt + json).utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.count == 1)
        guard let recovery = result.recoveries.first else { return }
        #expect(recovery.kind == .resync)
        #expect(recovery.droppedPrefixBytes == corrupt.utf8.count)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerResyncsSmallInvalidObjectAcrossNewlineDelimitedMessages() async throws {
        let framer = StdioFramer()
        let corrupt = "{\"result\":tru}\n"
        let json = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":true}}"

        let result = framer.append(Data((corrupt + json).utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.count == 1)
        guard let recovery = result.recoveries.first else { return }
        #expect(recovery.kind == .resync)
        #expect(recovery.droppedPrefixBytes == corrupt.utf8.count)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerDoesNotResyncNestedJSONInsideSmallMalformedObject() async throws {
        let framer = StdioFramer()
        let payload = """
            {
              "broken": tru,
              "result": {
                "jsonrpc": "2.0",
                "id": 2
              }
            }
            """

        let result = framer.append(Data(payload.utf8))
        #expect(result.messages.isEmpty)
        #expect(result.recoveries.isEmpty)
        #expect(result.bufferedByteCount == payload.utf8.count)
    }

    @Test func stdioFramerDoesNotResyncAdjacentNestedJSONObjectInsideSmallMalformedObject()
        async throws
    {
        let framer = StdioFramer()
        let payload = "{\"outer\":{\"broken\":true}{\"jsonrpc\":\"2.0\",\"id\":2}}"

        let result = framer.append(Data(payload.utf8))
        #expect(result.messages.isEmpty)
        #expect(result.recoveries.isEmpty)
        #expect(result.bufferedByteCount == payload.utf8.count)
    }

    @Test func stdioFramerDoesNotEarlyResyncWhenSmallMalformedObjectHasNoStructuralEnd()
        async throws
    {
        let framer = StdioFramer()
        let payload = """
            {
              "broken": tru,
              "result":
            {"jsonrpc":"2.0","id":2}
            """

        let result = framer.append(Data(payload.utf8))
        #expect(result.messages.isEmpty)
        #expect(result.recoveries.isEmpty)
        #expect(result.bufferedByteCount == payload.utf8.count)
    }

    @Test func stdioFramerResyncsCorruptBatchToAdjacentRawJSONObject() async throws {
        let framer = StdioFramer()
        let corrupt =
            "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":tru}]"
            + String(repeating: "x", count: 16 * 1024)
            + "]"
        let json = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":true}}"

        let result = framer.append(Data((corrupt + json).utf8))
        #expect(result.messages.count == 1)
        #expect(result.recoveries.count == 1)
        guard let recovery = result.recoveries.first else { return }
        #expect(recovery.kind == .resync)
        guard result.messages.count == 1 else { return }
        #expect(String(data: result.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerWaitsForIncompleteLargeBatchInsteadOfResyncingInnerObject() async throws {
        let framer = StdioFramer()
        let largeText = String(repeating: "x", count: 20 * 1024)
        let partial = """
            [
              {
                "jsonrpc": "2.0",
                "id": 1,
                "result": {
                  "text": "\(largeText)"
                }
              }
            """

        let resultA = framer.append(Data(partial.utf8))
        #expect(resultA.messages.isEmpty)
        #expect(resultA.recoveries.isEmpty)
        #expect(resultA.bufferedByteCount == partial.utf8.count)

        let completed = partial + "\n]"
        let resultB = framer.append(Data("\n]".utf8))
        #expect(resultB.messages.count == 1)
        #expect(resultB.recoveries.isEmpty)
        guard resultB.messages.count == 1 else { return }
        #expect(String(data: resultB.messages[0], encoding: .utf8) == completed)
    }

    @Test func stdioFramerDoesNotResyncPartialValidMessageBelowThreshold() async throws {
        let framer = StdioFramer()
        let partial =
            "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{\"value\":\""
            + String(repeating: "x", count: 1024)

        let result = framer.append(Data(partial.utf8))
        #expect(result.messages.isEmpty)
        #expect(result.recoveries.isEmpty)
        #expect(result.bufferedByteCount == partial.utf8.count)
    }

    @Test func stdioFramerKeepsLargeValidJSONAcrossMultipleAppendsWithoutResync() async throws {
        let framer = StdioFramer()
        let largeText = String(repeating: "x", count: 20 * 1024)
        let json = "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{\"text\":\"\(largeText)\"}}"

        let midpoint = json.index(json.startIndex, offsetBy: 12 * 1024)
        let partA = String(json[..<midpoint])
        let partB = String(json[midpoint...])

        let resultA = framer.append(Data(partA.utf8))
        #expect(resultA.messages.isEmpty)
        #expect(resultA.recoveries.isEmpty)

        let resultB = framer.append(Data(partB.utf8))
        #expect(resultB.messages.count == 1)
        #expect(resultB.recoveries.isEmpty)
        guard resultB.messages.count == 1 else { return }
        #expect(String(data: resultB.messages[0], encoding: .utf8) == json)
    }

    @Test func stdioFramerClearsBufferAtHardLimitWithoutCandidate() async throws {
        let framer = StdioFramer()
        let payload = "{" + String(repeating: "x", count: 4 * 1024 * 1024)

        let result = framer.append(Data(payload.utf8))
        #expect(result.messages.isEmpty)
        #expect(result.recoveries.count == 1)
        guard let recovery = result.recoveries.first else { return }
        #expect(recovery.kind == .fatalClear)
        #expect(recovery.candidateOffset == nil)
        #expect(result.bufferedByteCount == 0)
    }

    @Test func stdioFramerClearsBufferAtHardLimitAfterRejectingFalseCandidates() async throws {
        let framer = StdioFramer()
        let payload =
            "{" + String(repeating: "x", count: 2 * 1024 * 1024) + "{\"id\":"
            + String(repeating: "y", count: 2 * 1024 * 1024)

        let result = framer.append(Data(payload.utf8))
        #expect(result.messages.isEmpty)
        #expect(result.recoveries.count == 1)
        guard let recovery = result.recoveries.first else { return }
        #expect(recovery.kind == .fatalClear)
        #expect(result.bufferedByteCount == 0)
    }

    @Test func stdioFramerKeepsIncompleteLargeRawJSONBeyondHardLimit() async throws {
        let framer = StdioFramer()
        let largeText = String(repeating: "x", count: 4 * 1024 * 1024)
        let partial = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"text\":\"\(largeText)"

        let resultA = framer.append(Data(partial.utf8))
        #expect(resultA.messages.isEmpty)
        #expect(resultA.recoveries.isEmpty)
        #expect(resultA.bufferedByteCount == partial.utf8.count)

        let completed = partial + "\"}}"
        let resultB = framer.append(Data("\"}}".utf8))
        #expect(resultB.messages.count == 1)
        #expect(resultB.recoveries.isEmpty)
        guard resultB.messages.count == 1 else { return }
        #expect(String(data: resultB.messages[0], encoding: .utf8) == completed)
    }
}
