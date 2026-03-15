import Testing

@testable import XcodeMCPProxy

@Suite
struct ProxyServerBuildInfoTests {
    @Test func proxyServerListeningLogLineIncludesURLAndVersion() throws {
        let line = ProxyServer.listeningLogLine(displayHost: "localhost", port: 8765)

        #expect(line.contains("http://localhost:8765"))
        #expect(line.contains("version \(ProxyBuildInfo.version)"))
    }
}
