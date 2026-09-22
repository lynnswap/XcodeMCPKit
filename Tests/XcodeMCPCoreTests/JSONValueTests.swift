import Foundation
import Testing
import XcodeMCPCore

@Suite
struct JSONValueTests {
    @Test func rpcIDFromString() async throws {
        let rpcID = JSONRPC.ID(any: "abc")
        #expect(rpcID?.key == "s:abc")
        #expect(rpcID?.value.foundationObject as? String == "abc")
    }

    @Test func rpcIDFromNumber() async throws {
        let rpcID = JSONRPC.ID(any: NSNumber(value: 42))
        #expect(rpcID?.key == "42")
        #expect((rpcID?.value.foundationObject as? NSNumber)?.intValue == 42)
    }

    @Test func requestIDKeysPreserveScalarTypeWithoutChangingWireValues() throws {
        let number = try #require(JSONRPC.ID(any: NSNumber(value: 1)))
        let string = try #require(JSONRPC.ID(any: "1"))
        let prefixed = try #require(JSONRPC.ID(any: "s:1"))

        #expect(Set([number.key, string.key, prefixed.key]).count == 3)
        #expect(number.value == .number(.int(1)))
        #expect(string.value == .string("1"))
        #expect(prefixed.value == .string("s:1"))
    }

    @Test func jsonValueRoundTrip() async throws {
        let input: [String: Any] = [
            "name": "x",
            "count": 2,
            "ok": true,
            "items": [1, 2],
        ]
        let jsonValue = JSONValue(any: input)
        #expect(jsonValue != nil)
        guard let jsonValue else { return }
        let object = jsonValue.foundationObject as? [String: Any]
        #expect(object?["name"] as? String == "x")
        #expect((object?["count"] as? NSNumber)?.intValue == 2)
        #expect(object?["ok"] as? Bool == true)
        #expect((object?["items"] as? [Any])?.count == 2)
    }
}
