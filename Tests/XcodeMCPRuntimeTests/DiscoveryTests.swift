import Foundation
import Testing
import XcodeMCPCore
import XcodeMCPProcessRuntime
@testable import XcodeMCPProxyKit

private func makeTempDiscoveryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("endpoint.json")
}

private func cleanupTempDiscoveryURL(_ url: URL) {
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.removeItem(at: directory)
}

@Suite
struct DiscoveryTests {
    @Test func discoveryRoundTrip() async throws {
        let url = makeTempDiscoveryURL()
        defer { cleanupTempDiscoveryURL(url) }
        let record = DiscoveryRecord(
            url: "http://localhost:7777/mcp",
            host: "localhost",
            port: 7777,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date()
        )
        try Discovery.write(record: record, overrideURL: url)
        let loaded = Discovery.read(overrideURL: url)
        #expect(loaded?.url == record.url)
        #expect(loaded?.host == record.host)
        #expect(loaded?.port == record.port)
        #expect(loaded?.pid == record.pid)
    }

    @Test func discoveryRecordShapeRemainsStable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("endpoint.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let record = DiscoveryRecord(
            url: "http://127.0.0.1:8765/mcp",
            host: "127.0.0.1",
            port: 8765,
            pid: 4242,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        try Discovery.write(record: record, overrideURL: fileURL)

        let payload = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(
            payload == """
            {
              "host" : "127.0.0.1",
              "pid" : 4242,
              "port" : 8765,
              "updatedAt" : "1970-01-01T00:00:00Z",
              "url" : "http:\\/\\/127.0.0.1:8765\\/mcp"
            }
            """
        )
    }

    @Test func discoveryIgnoresInvalidJSON() async throws {
        let url = makeTempDiscoveryURL()
        defer { cleanupTempDiscoveryURL(url) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(Discovery.read(overrideURL: url) == nil)
    }

    @Test func discoveryRejectsDeadPID() async throws {
        let url = makeTempDiscoveryURL()
        defer { cleanupTempDiscoveryURL(url) }
        let record = DiscoveryRecord(
            url: "http://localhost:8888/mcp",
            host: "localhost",
            port: 8888,
            pid: 0,
            updatedAt: Date()
        )
        try Discovery.write(record: record, overrideURL: url)
        #expect(Discovery.read(overrideURL: url) == nil)
    }

    @Test func discoveryAllowsIPv4LoopbackRange() async throws {
        let url = makeTempDiscoveryURL()
        defer { cleanupTempDiscoveryURL(url) }
        let record = DiscoveryRecord(
            url: "http://127.42.1.9:8888/mcp",
            host: "127.42.1.9",
            port: 8888,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date()
        )
        try Discovery.write(record: record, overrideURL: url)
        #expect(Discovery.read(overrideURL: url)?.url == record.url)
    }

    @Test func discoveryAllowsIPv6LoopbackURL() async throws {
        let url = makeTempDiscoveryURL()
        defer { cleanupTempDiscoveryURL(url) }
        let record = DiscoveryRecord(
            url: "http://[::1]:8888/mcp",
            host: "::1",
            port: 8888,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date()
        )
        try Discovery.write(record: record, overrideURL: url)
        #expect(Discovery.read(overrideURL: url)?.url == record.url)
    }

    @Test func discoveryAllowsExpandedIPv6LoopbackURL() async throws {
        let url = makeTempDiscoveryURL()
        defer { cleanupTempDiscoveryURL(url) }
        let record = DiscoveryRecord(
            url: "http://[0:0:0:0:0:0:0:1]:8888/mcp",
            host: "0:0:0:0:0:0:0:1",
            port: 8888,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date()
        )
        try Discovery.write(record: record, overrideURL: url)
        #expect(Discovery.read(overrideURL: url)?.url == record.url)
    }

    @Test func discoveryRejectsNonLoopbackURL() async throws {
        let url = makeTempDiscoveryURL()
        defer { cleanupTempDiscoveryURL(url) }
        let record = DiscoveryRecord(
            url: "http://example.com:8888/mcp",
            host: "example.com",
            port: 8888,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date()
        )
        try Discovery.write(record: record, overrideURL: url)
        #expect(Discovery.read(overrideURL: url) == nil)
    }

    @Test func discoveryFormatsIPv6Host() async throws {
        let record = Discovery.makeRecord(host: "::1", port: 1234, pid: 1)
        #expect(record?.url == "http://[::1]:1234/mcp")
    }
}
