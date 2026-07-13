import Foundation
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyKit
import XcodeMCPProxyRuntime


@Suite
struct CLIParserTests {
    @Test func cliUsesCanonicalDefaultMCPBridgeInvocation() async throws {
        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy"],
            environment: [:]
        )

        #expect(config.upstreamCommand == MCPBridgeInvocation.defaultMCPBridge.command)
        #expect(config.upstreamArgs == MCPBridgeInvocation.defaultMCPBridge.arguments)
    }

    @Test func cliParsesListenAddress() async throws {
        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--listen", "0.0.0.0:9999"],
            environment: [:]
        )
        #expect(config.listenHost == "0.0.0.0")
        #expect(config.listenPort == 9999)
    }

    @Test func cliParsesHostAndPort() async throws {
        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--host", "localhost", "--port", "8080"],
            environment: [:]
        )
        #expect(config.listenHost == "localhost")
        #expect(config.listenPort == 8080)
    }

    @Test func cliAllowsListenPortZero() async throws {
        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--listen", "localhost:0"],
            environment: [:]
        )
        #expect(config.listenHost == "localhost")
        #expect(config.listenPort == 0)
    }

    @Test func cliTreatsOnlyZeroRequestTimeoutAsDisabled() throws {
        let disabled = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--request-timeout", "0"],
            environment: [:]
        )
        #expect(disabled.requestTimeout == 0)

        for invalid in ["-1", "nan", "inf", "-inf", "not-a-number"] {
            #expect(throws: CLIError.self) {
                _ = try CLIParser.parse(
                    args: ["xcode-mcp-proxy", "--request-timeout", invalid],
                    environment: [:]
                )
            }
        }
    }

    @Test func cliRejectsInvalidExplicitPortAndBodyLimit() throws {
        for invalidPort in ["-1", "65536", "not-a-port"] {
            #expect(throws: CLIError.self) {
                _ = try CLIParser.parse(
                    args: ["xcode-mcp-proxy", "--port", invalidPort],
                    environment: [:]
                )
            }
        }
        for invalidBodyLimit in ["0", "-1", "not-a-size"] {
            #expect(throws: CLIError.self) {
                _ = try CLIParser.parse(
                    args: ["xcode-mcp-proxy", "--max-body-bytes", invalidBodyLimit],
                    environment: [:]
                )
            }
        }
    }

    @Test func cliRejectsRemovedLazyInit() async throws {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(
                args: ["xcode-mcp-proxy", "--request-timeout", "12", "--lazy-init"],
                environment: [:]
            )
        }

        do {
            _ = try CLIParser.parse(
                args: ["xcode-mcp-proxy", "--request-timeout", "12", "--lazy-init"],
                environment: [:]
            )
            #expect(Bool(false))
        } catch let error as CLIError {
            #expect(error.description == CLIParser.removedLazyInitMessage)
        }
    }

    @Test func cliRejectsRemovedXcodePID() async throws {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(
                args: ["xcode-mcp-proxy", "--xcode-pid", "1234"],
                environment: [:]
            )
        }

        do {
            _ = try CLIParser.parse(
                args: ["xcode-mcp-proxy", "--xcode-pid", "1234"],
                environment: [:]
            )
            #expect(Bool(false))
        } catch let error as CLIError {
            #expect(error.description == CLIParser.removedXcodePIDMessage)
        }
    }

    @Test func cliParsesRefreshCodeIssuesMode() async throws {
        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--refresh-code-issues-mode", "upstream"],
            environment: [:]
        )

        #expect(config.refreshCodeIssuesMode == .upstream)
    }

    @Test func cliParsesAutoApproveFlag() async throws {
        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--auto-approve"],
            environment: [:]
        )

        #expect(config.autoApproveXcodeDialog == true)
    }

    @Test func cliParsesConfigPath() async throws {
        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--config", "/tmp/proxy-config.toml"],
            environment: [:]
        )

        #expect(config.configPath == "/tmp/proxy-config.toml")
    }

    @Test func cliLoadsDisabledToolNamesFromConfig() async throws {
        let configPath = try makeTempConfigFile(
            """
            [tools]
            disabled = ["RunAllTests", "RunSomeTests"]
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let parsed = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--config", configPath],
            environment: [:]
        )
        #expect(parsed.disabledToolNames.isEmpty)
        let config = try ProxyConfig.resolving(
            XcodeMCPProxyServerConfiguration(serverProxyConfig: parsed)
        )

        #expect(config.disabledToolNames == ["RunAllTests", "RunSomeTests"])
    }

    @Test func cliNormalizesDisabledToolNamesFromConfig() async throws {
        let configPath = try makeTempConfigFile(
            """
            [tools]
            disabled = [" RunAllTests ", "", "RunAllTests", "RunSomeTests "]
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let parsed = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--config", configPath],
            environment: [:]
        )
        let config = try ProxyConfig.resolving(
            XcodeMCPProxyServerConfiguration(serverProxyConfig: parsed)
        )

        #expect(config.disabledToolNames == ["RunAllTests", "RunSomeTests"])
    }

    @Test func strictServerConfigRejectsInvalidDisabledToolNames() async throws {
        let configPath = try makeTempConfigFile(
            """
            [tools]
            disabled = 123
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let parsed = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--config", configPath],
            environment: [:]
        )

        #expect(parsed.disabledToolNames.isEmpty)
        #expect(throws: ProxyConfig.File.LoadError.self) {
            _ = try ProxyConfig.resolving(
                XcodeMCPProxyServerConfiguration(serverProxyConfig: parsed)
            )
        }
    }

    @Test func configLoadsHandshakeOverrideWhenDisabledToolsAreExplicit() throws {
        let configPath = try makeTempConfigFile(
            """
            [tools]
            disabled = ["RunAllTests"]

            [upstream_handshake]
            clientName = "custom-client"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        var config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 0,
            upstreamCommand: MCPBridgeInvocation.defaultMCPBridge.command,
            upstreamArgs: MCPBridgeInvocation.defaultMCPBridge.arguments,
            maxBodyBytes: 1_048_576,
            requestTimeout: 300,
            configPath: configPath,
            disabledToolNames: ["ExplicitTool"]
        )
        let loaded = try ProxyConfig.File.Loader.loadStrict(
            configURL: URL(fileURLWithPath: configPath)
        )
        let explicitDisabledToolNames = config.disabledToolNames
        config.applyFileConfiguration(loaded)
        config.disabledToolNames = explicitDisabledToolNames

        #expect(config.disabledToolNames == ["ExplicitTool"])
        #expect(config.initializeParamsOverride?.clientName == "custom-client")
    }

    @Test func configRejectsLegacyHandshakeProtocolVersion() throws {
        let configPath = try makeTempConfigFile(
            """
            [upstream_handshake]
            protocolVersion = "2025-03-26"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        var config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 0,
            upstreamCommand: MCPBridgeInvocation.defaultMCPBridge.command,
            upstreamArgs: MCPBridgeInvocation.defaultMCPBridge.arguments,
            maxBodyBytes: 1_048_576,
            requestTimeout: 300,
            configPath: configPath
        )
        config.applyFileConfiguration(
            try ProxyConfig.File.Loader.loadStrict(
                configURL: URL(fileURLWithPath: configPath)
            )
        )

        #expect(config.initializeParamsOverride?.protocolVersion == "2025-03-26")
        do {
            try config.validateModernProtocolConfiguration()
            Issue.record("expected legacy protocolVersion to be rejected")
        } catch let error as ProxyConfig.ValidationError {
            #expect(error.description.contains("2025-06-18"))
            #expect(error.description.contains("2025-03-26"))
        }
    }

    @Test func cliParsesUpstreamProcesses() async throws {
        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--upstream-processes", "10"],
            environment: [:]
        )
        #expect(config.upstreamProcessCount == 10)
    }

    @Test func cliRejectsInvalidUpstreamProcesses() async throws {
        do {
            _ = try CLIParser.parse(
                args: ["xcode-mcp-proxy", "--upstream-processes", "0"],
                environment: [:]
            )
            #expect(Bool(false))
        } catch {}

        do {
            _ = try CLIParser.parse(
                args: ["xcode-mcp-proxy", "--upstream-processes", "11"],
                environment: [:]
            )
            #expect(Bool(false))
        } catch {}

        do {
            _ = try CLIParser.parse(
                args: ["xcode-mcp-proxy", "--upstream-processes", "abc"],
                environment: [:]
            )
            #expect(Bool(false))
        } catch {}
    }

    @Test func cliUsesEnvironmentOverrides() async throws {
        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy"],
            environment: [
                "MCP_XCODE_CONFIG": "/tmp/proxy-config.toml",
                "MCP_XCODE_SESSION_ID": "session-xyz",
                "MCP_XCODE_REFRESH_CODE_ISSUES_MODE": "upstream",
                "MCP_XCODE_AUTO_APPROVE": "1",
            ]
        )
        #expect(config.configPath == "/tmp/proxy-config.toml")
        #expect(config.upstreamSessionID == "session-xyz")
        #expect(config.refreshCodeIssuesMode == .upstream)
        #expect(config.autoApproveXcodeDialog == false)
    }

    @Test func cliIgnoresBlankRefreshCodeIssuesModeEnvironment() async throws {
        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy"],
            environment: [
                "MCP_XCODE_REFRESH_CODE_ISSUES_MODE": "   "
            ]
        )

        #expect(config.refreshCodeIssuesMode == .proxy)
    }

    @Test func cliIgnoresRemovedXcodePIDEnvironment() async throws {
        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy"],
            environment: [
                "XCODE_PID": "1234",
                "MCP_XCODE_PID": "5678",
                "MCP_XCODE_CONFIG": "/tmp/proxy-config.toml",
            ]
        )

        #expect(config.configPath == "/tmp/proxy-config.toml")
    }

    @Test func cliExplicitConfigOverridesEnvironment() async throws {
        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--config", "/tmp/explicit.toml"],
            environment: [
                "MCP_XCODE_CONFIG": "/tmp/environment.toml"
            ]
        )

        #expect(config.configPath == "/tmp/explicit.toml")
    }

    @Test func cliExplicitRefreshCodeIssuesModeOverridesEnvironment() async throws {
        let config = try CLIParser.parse(
            args: [
                "xcode-mcp-proxy",
                "--refresh-code-issues-mode",
                "proxy",
            ],
            environment: [
                "MCP_XCODE_REFRESH_CODE_ISSUES_MODE": "upstream"
            ]
        )

        #expect(config.refreshCodeIssuesMode == .proxy)
    }

    @Test func cliRejectsRemovedStdioMode() {
        #expect(throws: CLIError.self) {
            _ = try CLIParser.parse(
                args: ["xcode-mcp-proxy", "--stdio"],
                environment: [:]
            )
        }
    }
}

private func makeTempConfigFile(_ contents: String) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("toml")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}
