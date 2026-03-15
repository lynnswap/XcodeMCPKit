import Logging
import Testing

@testable import ProxyCore

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
}
