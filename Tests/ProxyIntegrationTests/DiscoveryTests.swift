import Foundation
import Testing
import XcodeMCPCore
@testable import XcodeMCPProxyKit


@Suite
struct DiscoveryTests {
    @Test func discoveryClientRejectsDeadPIDWithoutFilesystemOrKill() async throws {
        let record = DiscoveryRecord(
            url: "http://localhost:8888/mcp",
            host: "localhost",
            port: 8888,
            pid: 12345,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let client = DiscoveryClient.live(
            defaultFileURL: { URL(fileURLWithPath: "/unused/endpoint.json") },
            loadRecord: { _ in record },
            persistRecord: { _, _ in
                Issue.record("read should not persist discovery records")
            },
            createDirectory: { _ in
                Issue.record("read should not create directories")
            },
            isProcessAlive: { pid in
                #expect(pid == record.pid)
                return false
            },
            now: { Date(timeIntervalSince1970: 2) }
        )

        #expect(client.read(nil) == nil)
    }

    @Test func discoveryClientRejectsNonLoopbackURLWithoutFilesystemOrKill() async throws {
        let record = DiscoveryRecord(
            url: "http://example.com:8888/mcp",
            host: "example.com",
            port: 8888,
            pid: 12345,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let client = DiscoveryClient.live(
            defaultFileURL: { URL(fileURLWithPath: "/unused/endpoint.json") },
            loadRecord: { _ in record },
            persistRecord: { _, _ in
                Issue.record("read should not persist discovery records")
            },
            createDirectory: { _ in
                Issue.record("read should not create directories")
            },
            isProcessAlive: { pid in
                #expect(pid == record.pid)
                return true
            },
            now: { Date(timeIntervalSince1970: 2) }
        )

        #expect(client.read(nil) == nil)
    }
}
