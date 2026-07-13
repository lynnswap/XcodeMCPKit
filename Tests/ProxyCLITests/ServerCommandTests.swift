import Foundation
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyKit

@Suite
struct ServerCommandTests {
    @Test func serverCommandResolvesCanonicalDefaults() throws {
        let config = try resolvedProxyConfig()

        #expect(config.listenHost == "localhost")
        #expect(config.listenPort == 8765)
        #expect(config.upstreamCommand == MCPBridgeInvocation.defaultMCPBridge.command)
        #expect(config.upstreamArgs == MCPBridgeInvocation.defaultMCPBridge.arguments)
        #expect(config.upstreamProcessCount == 1)
        #expect(config.maxBodyBytes == 1_048_576)
        #expect(config.requestTimeout == 300)
        #expect(config.autoApproveXcodeDialog == false)
        #expect(config.refreshCodeIssuesMode == .proxy)
    }

    @Test func serverCommandMapsTypedOptionsToConfiguration() throws {
        let config = try resolvedProxyConfig(
            arguments: [
                "--listen", "0.0.0.0:9999",
                "--upstream-command", "/tmp/custom-bridge",
                "--upstream-args", "serve,--verbose",
                "--upstream-arg", "--trace",
                "--upstream-processes", "10",
                "--session-id", "session-123",
                "--max-body-bytes", "2048",
                "--request-timeout", "12.5",
                "--auto-approve",
                "--refresh-code-issues-mode", "upstream",
            ]
        )

        #expect(config.listenHost == "0.0.0.0")
        #expect(config.listenPort == 9999)
        #expect(config.upstreamCommand == "/tmp/custom-bridge")
        #expect(config.upstreamArgs == ["serve", "--verbose", "--trace"])
        #expect(config.upstreamProcessCount == 10)
        #expect(config.upstreamSessionID == "session-123")
        #expect(config.maxBodyBytes == 2048)
        #expect(config.requestTimeout == 12.5)
        #expect(config.autoApproveXcodeDialog)
        #expect(config.refreshCodeIssuesMode == .upstream)
    }

    @Test func serverCommandAllowsPortZeroAndZeroTimeout() throws {
        let config = try resolvedProxyConfig(
            arguments: [
                "--host", "localhost",
                "--port", "0",
                "--request-timeout", "0",
            ]
        )

        #expect(config.listenHost == "localhost")
        #expect(config.listenPort == 0)
        #expect(config.requestTimeout == 0)
    }

    @Test func serverCommandAcceptsDashPrefixedUpstreamArgumentList() throws {
        let config = try resolvedProxyConfig(
            arguments: ["--upstream-args", "--verbose,--trace"]
        )

        #expect(config.upstreamArgs == ["--verbose", "--trace"])
    }

    @Test func serverCommandRejectsInvalidValues() {
        let invalidInvocations = [
            ["--listen", "localhost"],
            ["--port", "-1"],
            ["--port", "65536"],
            ["--port", "not-a-port"],
            ["--max-body-bytes", "0"],
            ["--max-body-bytes", "-1"],
            ["--request-timeout", "-1"],
            ["--request-timeout", "nan"],
            ["--request-timeout", "inf"],
            ["--upstream-processes", "0"],
            ["--upstream-processes", "11"],
            ["--upstream-processes", "abc"],
        ]

        for arguments in invalidInvocations {
            #expect(throws: CLICommandError.self) {
                _ = try resolvedProxyConfig(arguments: arguments)
            }
        }
    }

    @Test func serverCommandRejectsConflictingAddressOptions() {
        #expect(throws: CLICommandError.self) {
            _ = try resolvedProxyConfig(
                arguments: [
                    "--listen", "localhost:8765",
                    "--port", "9000",
                ]
            )
        }
    }

    @Test func serverCommandResolvesEnvironmentWhenCLIOptionsAreAbsent() throws {
        let configURL = try makeTempConfigFile("")
        defer { try? FileManager.default.removeItem(at: configURL) }

        let config = try resolvedProxyConfig(
            environment: [
                "HOST": "127.0.0.1",
                "PORT": "9001",
                "MCP_XCODE_CONFIG": configURL.path,
                "MCP_XCODE_SESSION_ID": "session-env",
                "MCP_XCODE_REFRESH_CODE_ISSUES_MODE": "upstream",
                "MCP_XCODE_AUTO_APPROVE": "1",
            ]
        )

        #expect(config.listenHost == "127.0.0.1")
        #expect(config.listenPort == 9001)
        #expect(config.configPath == configURL.path)
        #expect(config.upstreamSessionID == "session-env")
        #expect(config.refreshCodeIssuesMode == .upstream)
        #expect(config.autoApproveXcodeDialog == false)
    }

    @Test func explicitCLIOptionsOverrideEnvironment() throws {
        let explicitConfigURL = try makeTempConfigFile("")
        let environmentConfigURL = try makeTempConfigFile("")
        defer {
            try? FileManager.default.removeItem(at: explicitConfigURL)
            try? FileManager.default.removeItem(at: environmentConfigURL)
        }

        let config = try resolvedProxyConfig(
            arguments: [
                "--listen", "127.0.0.1:9002",
                "--config", explicitConfigURL.path,
                "--session-id", "session-cli",
                "--refresh-code-issues-mode", "proxy",
            ],
            environment: [
                "LISTEN": "0.0.0.0:9003",
                "MCP_XCODE_CONFIG": environmentConfigURL.path,
                "MCP_XCODE_SESSION_ID": "session-env",
                "MCP_XCODE_REFRESH_CODE_ISSUES_MODE": "upstream",
            ]
        )

        #expect(config.listenHost == "127.0.0.1")
        #expect(config.listenPort == 9002)
        #expect(config.configPath == explicitConfigURL.path)
        #expect(config.upstreamSessionID == "session-cli")
        #expect(config.refreshCodeIssuesMode == .proxy)
    }

    @Test func serverCommandRejectsInvalidEnvironment() {
        #expect(throws: CLICommandError.self) {
            _ = try resolvedProxyConfig(environment: ["LISTEN": "localhost"])
        }
        #expect(throws: CLICommandError.self) {
            _ = try resolvedProxyConfig(environment: ["PORT": "65536"])
        }
        #expect(throws: CLICommandError.self) {
            _ = try resolvedProxyConfig(
                environment: ["MCP_XCODE_REFRESH_CODE_ISSUES_MODE": "invalid"]
            )
        }
    }

    @Test func serverCommandLoadsAndNormalizesFileConfiguration() throws {
        let configURL = try makeTempConfigFile(
            """
            [tools]
            disabled = [" RunAllTests ", "", "RunAllTests", "RunSomeTests "]

            [upstream_handshake]
            clientName = "custom-client"
            """
        )
        defer { try? FileManager.default.removeItem(at: configURL) }

        let config = try resolvedProxyConfig(
            arguments: ["--config", configURL.path]
        )

        #expect(config.disabledToolNames == ["RunAllTests", "RunSomeTests"])
        #expect(config.initializeParamsOverride?.clientName == "custom-client")
    }

    @Test func serverCommandRejectsInvalidFileConfiguration() throws {
        let invalidToolsURL = try makeTempConfigFile(
            """
            [tools]
            disabled = 123
            """
        )
        let legacyProtocolURL = try makeTempConfigFile(
            """
            [upstream_handshake]
            protocolVersion = "2025-03-26"
            """
        )
        defer {
            try? FileManager.default.removeItem(at: invalidToolsURL)
            try? FileManager.default.removeItem(at: legacyProtocolURL)
        }

        #expect(throws: CLICommandError.self) {
            _ = try resolvedProxyConfig(arguments: ["--config", invalidToolsURL.path])
        }
        #expect(throws: CLICommandError.self) {
            _ = try resolvedProxyConfig(arguments: ["--config", legacyProtocolURL.path])
        }
    }
}

private func resolvedProxyConfig(
    arguments: [String] = [],
    environment: [String: String] = [:]
) throws -> ProxyConfig {
    let action = try XcodeMCPProxyServer.resolveLaunchAction(
        arguments: ["xcode-mcp-proxy-server"] + arguments,
        environment: environment
    )
    guard case .start(let preparedConfiguration, _) = action else {
        throw UnexpectedServerCommandAction()
    }
    return preparedConfiguration.proxyConfig
}

private func makeTempConfigFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("toml")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private struct UnexpectedServerCommandAction: Error {}
