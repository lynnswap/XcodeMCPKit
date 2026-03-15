import Foundation
import Testing

@testable import ProxyCore

@Suite
struct RequestInspectorTests {
    @Test func requestInspectorMapsSingleRequest() async throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/list",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var mapped: [String] = []
        let transform = try RequestInspector.transform(
            data,
            sessionID: "s1",
            mapID: { sessionID, originalID in
                mapped.append("\(sessionID):\(originalID.key)")
                return 42
            }
        )

        #expect(transform.expectsResponse == true)
        #expect(transform.isBatch == false)
        #expect(transform.idKey == "5")
        #expect(transform.method == "tools/list")
        #expect(mapped == ["s1:5"])

        let upstream =
            try JSONSerialization.jsonObject(with: transform.upstreamData, options: [])
            as? [String: Any]
        let id = (upstream?["id"] as? NSNumber)?.intValue
        #expect(id == 42)
    }

    @Test func requestInspectorHandlesNotification() async throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var mapped = false
        let transform = try RequestInspector.transform(
            data,
            sessionID: "s1",
            mapID: { _, _ in
                mapped = true
                return 1
            }
        )

        #expect(transform.expectsResponse == false)
        #expect(transform.isBatch == false)
        #expect(transform.idKey == nil)
        #expect(transform.method == "notifications/initialized")
        #expect(mapped == false)
    }

    @Test func requestInspectorMapsBatchRequests() async throws {
        let payload: [Any] = [
            ["jsonrpc": "2.0", "id": 1, "method": "tools/list"],
            ["jsonrpc": "2.0", "method": "ping"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var mappedCount = 0
        let transform = try RequestInspector.transform(
            data,
            sessionID: "s1",
            mapID: { _, _ in
                mappedCount += 1
                return 77
            }
        )

        #expect(transform.expectsResponse == true)
        #expect(transform.isBatch == true)
        #expect(transform.idKey == nil)

        let upstream =
            try JSONSerialization.jsonObject(with: transform.upstreamData, options: []) as? [Any]
        let first = upstream?.first as? [String: Any]
        let id = (first?["id"] as? NSNumber)?.intValue
        #expect(id == 77)
        #expect(mappedCount == 1)
    }

    @Test func requestInspectorRejectsScalarJSON() async throws {
        let data = Data("true".utf8)
        do {
            _ = try RequestInspector.transform(
                data,
                sessionID: "s1",
                mapID: { _, _ in 1 }
            )
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
    }
}
