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

        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--config", configPath],
            environment: [:]
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

        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--config", configPath],
            environment: [:]
        )

        #expect(config.disabledToolNames == ["RunAllTests", "RunSomeTests"])
    }

    @Test func cliIgnoresInvalidDisabledToolNamesConfig() async throws {
        let configPath = try makeTempConfigFile(
            """
            [tools]
            disabled = 123
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy", "--config", configPath],
            environment: [:]
        )

        #expect(config.disabledToolNames.isEmpty)
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

        let config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 0,
            upstreamCommand: MCPBridgeInvocation.defaultMCPBridge.command,
            upstreamArgs: MCPBridgeInvocation.defaultMCPBridge.arguments,
            maxBodyBytes: 1_048_576,
            requestTimeout: 300,
            configPath: configPath,
            disabledToolNames: ["ExplicitTool"]
        )

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

        let config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 0,
            upstreamCommand: MCPBridgeInvocation.defaultMCPBridge.command,
            upstreamArgs: MCPBridgeInvocation.defaultMCPBridge.arguments,
            maxBodyBytes: 1_048_576,
            requestTimeout: 300,
            configPath: configPath
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

    @Test func cliParsesStdioUpstream() async throws {
        let config = try CLIParser.parse(
            args: [
                "xcode-mcp-proxy",
                "--stdio",
                "http://localhost:8765/mcp",
            ],
            environment: [:]
        )
        #expect(config.transport == .stdio)
        #expect(config.stdioUpstreamURL?.absoluteString == "http://localhost:8765/mcp")
        #expect(config.stdioUpstreamSource == .explicit)
    }

    @Test func cliDefaultsStdioUpstreamFallback() async throws {
        let tempURL = makeTempDiscoveryURL()
        let config = try CLIParser.parse(
            args: [
                "xcode-mcp-proxy",
                "--stdio",
            ],
            environment: [:],
            discoveryOverrideURL: tempURL
        )
        #expect(config.transport == .stdio)
        #expect(config.stdioUpstreamURL?.absoluteString == "http://localhost:8765/mcp")
        #expect(config.stdioUpstreamSource == .fallback)
    }

    @Test func cliDefaultsStdioUpstreamFromDiscovery() async throws {
        let tempURL = makeTempDiscoveryURL()
        let record = DiscoveryRecord(
            url: "http://localhost:5555/mcp",
            host: "localhost",
            port: 5555,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date()
        )
        try Discovery.write(record: record, overrideURL: tempURL)
        let config = try CLIParser.parse(
            args: [
                "xcode-mcp-proxy",
                "--stdio",
            ],
            environment: [:],
            discoveryOverrideURL: tempURL
        )
        #expect(config.transport == .stdio)
        #expect(config.stdioUpstreamURL?.absoluteString == "http://localhost:5555/mcp")
        #expect(config.stdioUpstreamSource == .discovery)
    }

    @Test func cliDefaultsStdioUpstreamFromExpandedIPv6Discovery() async throws {
        let tempURL = makeTempDiscoveryURL()
        let record = DiscoveryRecord(
            url: "http://[0:0:0:0:0:0:0:1]:5555/mcp",
            host: "0:0:0:0:0:0:0:1",
            port: 5555,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date()
        )
        try Discovery.write(record: record, overrideURL: tempURL)
        let config = try CLIParser.parse(
            args: [
                "xcode-mcp-proxy",
                "--stdio",
            ],
            environment: [:],
            discoveryOverrideURL: tempURL
        )
        #expect(config.transport == .stdio)
        #expect(config.stdioUpstreamURL?.absoluteString == "http://[0:0:0:0:0:0:0:1]:5555/mcp")
        #expect(config.stdioUpstreamSource == .discovery)
    }

    @Test func cliIgnoresNonLoopbackDiscoveryEndpoint() async throws {
        let tempURL = makeTempDiscoveryURL()
        let record = DiscoveryRecord(
            url: "http://example.com:5555/mcp",
            host: "example.com",
            port: 5555,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date()
        )
        try Discovery.write(record: record, overrideURL: tempURL)
        let config = try CLIParser.parse(
            args: [
                "xcode-mcp-proxy",
                "--stdio",
            ],
            environment: [:],
            discoveryOverrideURL: tempURL
        )
        #expect(config.transport == .stdio)
        #expect(config.stdioUpstreamURL?.absoluteString == "http://localhost:8765/mcp")
        #expect(config.stdioUpstreamSource == .fallback)
    }

    @Test func cliDefaultsStdioUpstreamFromEnvironment() async throws {
        let tempURL = makeTempDiscoveryURL()
        let config = try CLIParser.parse(
            args: [
                "xcode-mcp-proxy",
                "--stdio",
            ],
            environment: [
                "XCODE_MCP_PROXY_ENDPOINT": "http://localhost:9000/mcp"
            ],
            discoveryOverrideURL: tempURL
        )
        #expect(config.transport == .stdio)
        #expect(config.stdioUpstreamURL?.absoluteString == "http://localhost:9000/mcp")
        #expect(config.stdioUpstreamSource == .environment)
    }

    @Test func cliDefaultsToHTTP() async throws {
        let config = try CLIParser.parse(
            args: ["xcode-mcp-proxy"],
            environment: [:]
        )
        #expect(config.transport == .http)
        #expect(config.stdioUpstreamURL == nil)
        #expect(config.listenPort == 0)
    }

    @Test func adapterEndpointResolverUsesExplicitEnvironmentDiscoveryFallbackOrder() async throws {
        let tempURL = makeTempDiscoveryURL()
        let record = DiscoveryRecord(
            url: "http://localhost:5555/mcp",
            host: "localhost",
            port: 5555,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            updatedAt: Date()
        )
        try Discovery.write(record: record, overrideURL: tempURL)

        let resolver = XcodeMCPProxyAdapterEndpointResolver()
        let environment = [
            "XCODE_MCP_PROXY_ENDPOINT": "http://localhost:6666/mcp"
        ]

        let explicit = try resolver.resolve(
            .init(
                explicitURL: "http://localhost:7777/mcp",
                explicitURLLabel: "--url",
                environment: environment,
                discoveryFileURL: tempURL
            )
        )
        #expect(explicit.url.absoluteString == "http://localhost:7777/mcp")
        #expect(explicit.source == .explicit)

        let env = try resolver.resolve(
            .init(environment: environment, discoveryFileURL: tempURL)
        )
        #expect(env.url.absoluteString == "http://localhost:6666/mcp")
        #expect(env.source == .environment)

        let discovery = try resolver.resolve(
            .init(environment: [:], discoveryFileURL: tempURL)
        )
        #expect(discovery.url.absoluteString == "http://localhost:5555/mcp")
        #expect(discovery.source == .discovery)

        let fallback = try resolver.resolve(
            .init(environment: [:], discoveryFileURL: makeTempDiscoveryURL())
        )
        #expect(fallback.url.absoluteString == "http://localhost:8765/mcp")
        #expect(fallback.source == .fallback)
    }
}

private func makeTempConfigFile(_ contents: String) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("toml")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}
