import Logging
import Testing

@testable import XcodeMCPProxyRuntime

@Suite
struct ProxyLoggingTests {
    @Test func logLevelParserTrimsAndMatches() async throws {
        let level = LogLevelParser.parse("  WARN ")
        #expect(level == .warning)
    }

    @Test func logLevelParserRejectsUnknownValues() async throws {
        let level = LogLevelParser.parse("nope")
        #expect(level == nil)
    }

    @Test func logLevelParserResolvesEnvironmentPriority() async throws {
        let level = LogLevelParser.resolve(
            from: [
                "LOG_LEVEL": "debug",
                "MCP_LOG_LEVEL": "error",
            ]
        )
        #expect(level == .error)
    }

    @Test func toolsAvailabilityDiagnosticExplainsTimeoutAndRetry() {
        #expect(
            XcodeMCPToolsAvailabilityDiagnostic.timeoutSummary == """
                Xcode tools are unavailable

                  The proxy timed out waiting for tools/list.
                  Recovery:
                    1. Open a project in Xcode.
                    2. Check that "Allow external agents to use Xcode tools" is enabled in
                       Xcode > Settings > Intelligence.
                    3. If Xcode shows a connection dialog, approve it.
                  The proxy will retry automatically.
                """
        )
    }
}
