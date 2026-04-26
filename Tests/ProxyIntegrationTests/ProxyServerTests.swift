import Foundation
import ProxyRuntime
import Testing

@testable import XcodeMCPProxy

struct ProxyServerTests {
    @Test func firstXcrunToolSelectionTreatsLogAsFlagWithoutValue() {
        let selection = ProxyServer.firstXcrunToolSelection(
            from: ["--sdk", "macosx", "--log", "mcpbridge", "--some-flag"]
        )

        #expect(selection?.toolName == "mcpbridge")
        #expect(selection?.preToolArguments == ["--sdk", "macosx", "--log"])
    }

    @Test func additionalPermissionDialogExecutableCandidatesKeepXcrunPathWhenToolResolutionFails() {
        let config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 0,
            upstreamCommand: "/usr/bin/xcrun",
            upstreamArgs: ["--foo"],
            maxBodyBytes: 1_048_576,
            requestTimeout: 300
        )

        let candidates = ProxyServer.additionalPermissionDialogExecutableCandidates(config: config)

        #expect(candidates.contains("/usr/bin/xcrun"))
    }

    @Test func additionalPermissionDialogExecutableCandidatesUseConfiguredXcrunCommand() throws {
        let fixture = try makeXcrunFixture()
        defer { fixture.cleanup() }

        let config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 0,
            upstreamCommand: fixture.wrapperPath,
            upstreamArgs: ["--sdk", "macosx", "mcpbridge"],
            maxBodyBytes: 1_048_576,
            requestTimeout: 300
        )

        let candidates = ProxyServer.additionalPermissionDialogExecutableCandidates(config: config)

        #expect(candidates.contains(fixture.wrapperPath))
        #expect(candidates.contains(fixture.toolPath))
    }

    @Test func additionalPermissionDialogExecutableCandidatesUseConfiguredXcrunFromUpstreamArgs() throws {
        let fixture = try makeXcrunFixture()
        defer { fixture.cleanup() }

        let config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 0,
            upstreamCommand: "/bin/echo",
            upstreamArgs: [fixture.wrapperPath, "--log", "mcpbridge"],
            maxBodyBytes: 1_048_576,
            requestTimeout: 300
        )

        let candidates = ProxyServer.additionalPermissionDialogExecutableCandidates(config: config)

        #expect(candidates.contains(fixture.wrapperPath))
        #expect(candidates.contains(fixture.toolPath))
    }

    @Test func makeXPCStatusSortsClientsAndAggregatesCorrelatedRequests() {
        let payload = ProxyServer.makeXPCStatus(
            endpointDisplay: "http://localhost:8765",
            reachable: true,
            version: "test-version",
            debugSnapshot: makeDebugSnapshot(
                upstreamHealth: "healthy",
                sessions: [
                    SessionDebugSnapshot(sessionID: "session-b", activeCorrelatedRequestCount: 2),
                    SessionDebugSnapshot(sessionID: "session-a", activeCorrelatedRequestCount: 2),
                    SessionDebugSnapshot(sessionID: "session-c", activeCorrelatedRequestCount: 5),
                ]
            )
        )

        #expect(payload.reachable)
        #expect(payload.version == "test-version")
        #expect(payload.xcodeHealth == "healthy")
        #expect(payload.activeClientCount == 3)
        #expect(payload.activeCorrelatedRequestCount == 9)
        #expect(payload.clients.map { $0.sessionID } == ["session-c", "session-a", "session-b"])
        #expect(payload.fetchError == nil)
    }

    @Test func makeXPCStatusMarksUnreachableProxyWithoutDebugSnapshot() {
        let payload = ProxyServer.makeXPCStatus(
            endpointDisplay: "http://localhost:8765",
            reachable: false,
            version: "test-version",
            debugSnapshot: nil
        )

        #expect(payload.reachable == false)
        #expect(payload.xcodeHealth == "Unknown")
        #expect(payload.activeClientCount == 0)
        #expect(payload.activeCorrelatedRequestCount == 0)
        #expect(payload.fetchError == "Proxy not reachable at http://localhost:8765.")
    }
}

private struct XcrunFixture {
    let wrapperPath: String
    let toolPath: String
    let directoryURL: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func makeXcrunFixture() throws -> XcrunFixture {
    let fileManager = FileManager.default
    let directoryURL = fileManager.temporaryDirectory
        .appendingPathComponent("xcode-mcp-proxy-xcrun-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let toolPath = directoryURL.appendingPathComponent("fake-mcpbridge").path
    let wrapperPath = directoryURL.appendingPathComponent("xcrun").path
    let script = """
    #!/bin/sh
    if [ "$1" = "--sdk" ]; then
      shift 2
    fi
    if [ "$1" = "--log" ]; then
      shift
    fi
    if [ "$1" = "--find" ] && [ "$2" = "mcpbridge" ]; then
      echo "\(toolPath)"
      exit 0
    fi
    exit 1
    """
    try script.write(to: URL(fileURLWithPath: wrapperPath), atomically: true, encoding: .utf8)
    try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: wrapperPath
    )

    return XcrunFixture(
        wrapperPath: wrapperPath,
        toolPath: toolPath,
        directoryURL: directoryURL
    )
}

private func makeDebugSnapshot(
    upstreamHealth: String,
    sessions: [SessionDebugSnapshot]
) -> ProxyDebugSnapshot {
    ProxyDebugSnapshot(
        generatedAt: Date(),
        proxyInitialized: true,
        cachedToolsListAvailable: false,
        warmupInFlight: false,
        upstreams: [
            ProxyUpstreamDebugSnapshot(
                upstreamIndex: 0,
                isInitialized: true,
                initInFlight: false,
                didSendInitialized: true,
                healthState: upstreamHealth,
                consecutiveRequestTimeouts: 0,
                consecutiveToolsListFailures: 0,
                lastToolsListSuccessUptimeNs: nil,
                recentStderr: [],
                lastDecodeError: nil,
                lastBridgeError: nil,
                protocolViolationCount: 0,
                lastProtocolViolationAt: nil,
                lastProtocolViolationReason: nil,
                lastProtocolViolationBufferedBytes: nil,
                lastProtocolViolationPreview: nil,
                lastProtocolViolationPreviewHex: nil,
                lastProtocolViolationLeadingByteHex: nil,
                bufferedStdoutBytes: 0,
                capacity: 1,
                requestPickCount: 0,
                activeCorrelatedRequestCount: sessions.reduce(into: 0) { partialResult, session in
                    partialResult += session.activeCorrelatedRequestCount
                },
                droppedUnmappedNotificationCount: 0,
                lateResponseDropCount: 0
            )
        ],
        recentTraffic: [],
        sessions: sessions,
        leases: [],
        queuedRequestCount: 0
    )
}
