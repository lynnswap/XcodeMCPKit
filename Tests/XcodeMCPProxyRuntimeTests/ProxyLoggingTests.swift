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

    @Test func toolsAvailabilityDiagnosticExplainsAttachTimeout() {
        let expectedAction =
            "Check that \"Allow external agents to use Xcode tools\" is enabled in "
            + "Xcode > Settings > Intelligence. If Xcode shows a connection dialog, approve it."
        #expect(
            XcodeMCPToolsAvailabilityDiagnostic.action(
                forAttachProbeFailureReason: "timeout"
            ) == expectedAction
        )
        #expect(
            XcodeMCPToolsAvailabilityDiagnostic.action(
                forAttachProbeFailureReason: "invalid_response"
            ) == nil
        )
    }
}
