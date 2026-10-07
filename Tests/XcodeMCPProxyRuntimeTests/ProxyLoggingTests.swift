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

    @Test(arguments: [
        (
            "[-[SimVolumeManager _diskUnmountApproval:diskDescription:]:365] DEBUG : VolumeManager: DiskArb is requesting approval to unmount a disk",
            Logger.Level.debug
        ),
        (
            "[-[SimServiceContext _onQueue_regenerateRuntimeDictionariesWithReason:]:1495] INFO  : Regenerating runtime dictionaries because of removing runtimes",
            .info
        ),
        (
            "[-[SimLaunchHostConnection _checkAndResyncIfNeeded]_block_invoke_2:316] NOTICE: Successful resync",
            .notice
        ),
        (
            "[-[SimLaunchHostConnection _connectToServiceName:]_block_invoke:242] ERROR : Lost connection to com.apple.CoreSimulator.SimLaunchHost-arm64 (interrupted)",
            .error
        ),
        ("[-[SimServiceContext reportError:]:1495] DEBUG : Context remains available", .debug),
        ("[NativeDiagnostic:42]  WaRnInG  : Retrying operation", .warning),
    ])
    func upstreamStderrUsesTheDeclaredDiagnosticLevel(
        input: (message: String, level: Logger.Level)
    ) async throws {
        #expect(UpstreamStderrLogFilter.level(for: input.message) == input.level)
    }

    @Test(arguments: [
        "Background DEBUG : No framed diagnostic level",
        "2026-10-05 23:53:55.622 xcode-mcp-native-host[43311:36380528] CoreSimulatorService connection interrupted. DEBUG logging is enabled.",
        " [NativeDiagnostic:42] DEBUG : Leading text precedes the frame",
        "[NativeDiagnostic:42] VERBOSE : Unknown severity",
        "[NativeDiagnostic:42] DEBUG without a severity separator",
        "[NativeDiagnostic:42 DEBUG : Incomplete frame",
        "[NativeDiagnostic:42] errorHandler: DEBUG appears in the message",
    ])
    func upstreamStderrWithoutARecognizedDiagnosticLevelRemainsAnError(message: String) async throws {
        #expect(UpstreamStderrLogFilter.level(for: message) == .error)
    }
}
