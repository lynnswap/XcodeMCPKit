import ProxyCore
import Foundation
import Testing
import XcodeMCPProxy
import ProxyCLI

@Suite
struct ServerCommandTests {
    @Test func serverCommandParsesForceRestartAndDryRun() throws {
        let options = try XcodeMCPProxyServerCommand.parseOptions(args: [
            "xcode-mcp-proxy-server",
            "--listen",
            "127.0.0.1:9000",
            "--auto-approve",
            "--refresh-code-issues-mode",
            "upstream",
            "--force-restart",
            "--dry-run",
        ])

        #expect(options.forwardedArgs == [
            "--listen", "127.0.0.1:9000",
            "--auto-approve",
            "--refresh-code-issues-mode", "upstream",
        ])
        #expect(options.showHelp == false)
        #expect(options.showVersion == false)
        #expect(options.hasListenFlag == true)
        #expect(options.hasAutoApproveFlag == true)
        #expect(options.hasRefreshCodeIssuesModeFlag == true)
        #expect(options.forceRestart == true)
        #expect(options.dryRun == true)
    }

    @Test func serverCommandPrintsVersionBeforeValidation() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                stderr: { _ in },
                terminateExistingServer: { _, _ in
                    Issue.record("terminateExistingServer should not be called for --version")
                    return false
                },
                makeServer: { _ in
                    Issue.record("makeServer should not be called for --version")
                    return RecordingProxyServer()
                },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy-server", "--version", "--url", "http://localhost:8765/mcp"],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(output.snapshot() == ["xcode-mcp-proxy-server \(ProxyBuildInfo.version)"])
    }

    @Test func serverCommandPrintsVersionWhenFlagAppearsAsConfigValue() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                stderr: { _ in },
                terminateExistingServer: { _, _ in
                    Issue.record("terminateExistingServer should not be called for --version")
                    return false
                },
                makeServer: { _ in
                    Issue.record("makeServer should not be called for --version")
                    return RecordingProxyServer()
                },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy-server", "--config", "--version"],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(output.snapshot() == ["xcode-mcp-proxy-server \(ProxyBuildInfo.version)"])
    }

    @Test func serverCommandHelpWinsOverVersion() async throws {
        let output = CapturedLines()
        let errors = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                stderr: { errors.append($0) },
                terminateExistingServer: { _, _ in false },
                makeServer: { _ in
                    Issue.record("makeServer should not be called for --help")
                    return RecordingProxyServer()
                },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy-server", "--version", "--help", "--url"],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(errors.snapshot().isEmpty)
        let line = try #require(output.snapshot().first)
        #expect(line.contains("Usage:"))
    }

    @Test func serverCommandHelpWinsOverVersionWhenRefreshModeValueIsMissing() async throws {
        let output = CapturedLines()
        let errors = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                stderr: { errors.append($0) },
                terminateExistingServer: { _, _ in false },
                makeServer: { _ in
                    Issue.record("makeServer should not be called for --help")
                    return RecordingProxyServer()
                },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: [
                "xcode-mcp-proxy-server",
                "--version",
                "--refresh-code-issues-mode",
                "--help",
            ],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(errors.snapshot().isEmpty)
        let line = try #require(output.snapshot().first)
        #expect(line.contains("Usage:"))
    }

    @Test func serverCommandAppliesEnvironmentDefaultsWithoutXcodePID() throws {
        var options = XcodeMCPProxyServerCommand.Options(
            forwardedArgs: [],
            showHelp: false,
            showVersion: false,
            hasListenFlag: false,
            hasHostFlag: false,
            hasPortFlag: false,
            hasConfigFlag: false,
            hasAutoApproveFlag: false,
            hasRefreshCodeIssuesModeFlag: false,
            forceRestart: false,
            dryRun: false
        )

        try XcodeMCPProxyServerCommand.applyDefaults(
            from: [
                "HOST": "127.0.0.1",
                "PORT": "9999",
                "MCP_XCODE_CONFIG": "/tmp/proxy-config.toml",
                "MCP_XCODE_REFRESH_CODE_ISSUES_MODE": "upstream",
            ],
            to: &options
        )

        #expect(options.forwardedArgs == [
            "--listen", "127.0.0.1:9999",
        ])
    }

    @Test func serverCommandExplicitConfigOverridesEnvironment() throws {
        var options = XcodeMCPProxyServerCommand.Options(
            forwardedArgs: ["--config", "/tmp/explicit.toml"],
            showHelp: false,
            showVersion: false,
            hasListenFlag: false,
            hasHostFlag: false,
            hasPortFlag: false,
            hasConfigFlag: true,
            hasAutoApproveFlag: false,
            hasRefreshCodeIssuesModeFlag: false,
            forceRestart: false,
            dryRun: false
        )

        try XcodeMCPProxyServerCommand.applyDefaults(
            from: [
                "MCP_XCODE_CONFIG": "/tmp/environment.toml",
            ],
            to: &options
        )

        #expect(options.forwardedArgs == [
            "--config", "/tmp/explicit.toml",
            "--listen", "localhost:8765",
        ])
    }

    @Test func serverCommandIgnoresRemovedXcodePIDEnvironment() throws {
        var options = XcodeMCPProxyServerCommand.Options(
            forwardedArgs: [],
            showHelp: false,
            showVersion: false,
            hasListenFlag: false,
            hasHostFlag: false,
            hasPortFlag: false,
            hasConfigFlag: false,
            hasAutoApproveFlag: false,
            hasRefreshCodeIssuesModeFlag: false,
            forceRestart: false,
            dryRun: false
        )

        try XcodeMCPProxyServerCommand.applyDefaults(
            from: [
                "HOST": "127.0.0.1",
                "PORT": "9999",
                "XCODE_PID": "1234",
                "MCP_XCODE_PID": "5678",
            ],
            to: &options
        )

        #expect(options.forwardedArgs == [
            "--listen", "127.0.0.1:9999",
        ])
    }

    @Test func serverCommandRejectsRemovedLazyInitEnvironment() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                stderr: { output.append($0) },
                terminateExistingServer: { _, _ in false },
                makeServer: { _ in RecordingProxyServer() },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy-server", "--dry-run"],
            environment: ["LAZY_INIT": "true"]
        )

        #expect(exitCode == 1)
        #expect(output.snapshot() == [
            "error: \(CLIParser.removedLazyInitMessage)",
            "run with --help for usage",
        ])
    }

    @Test func serverCommandRejectsRemovedLazyInitFlagBeforeDryRun() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                stderr: { output.append($0) },
                terminateExistingServer: { _, _ in false },
                makeServer: { _ in RecordingProxyServer() },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy-server", "--lazy-init", "--dry-run"],
            environment: [:]
        )

        #expect(exitCode == 1)
        #expect(output.snapshot() == [
            "error: \(CLIParser.removedLazyInitMessage)",
            "run with --help for usage",
        ])
    }

    @Test func serverCommandRejectsRemovedXcodePIDFlagBeforeDryRun() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                stderr: { output.append($0) },
                terminateExistingServer: { _, _ in false },
                makeServer: { _ in RecordingProxyServer() },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy-server", "--xcode-pid", "1234", "--dry-run"],
            environment: [:]
        )

        #expect(exitCode == 1)
        #expect(output.snapshot() == [
            "error: \(CLIParser.removedXcodePIDMessage)",
            "run with --help for usage",
        ])
    }

    @Test func serverCommandFormatsPortInUseMessage() throws {
        let message = XcodeMCPProxyServerCommand.portInUseMessage(
            host: "::1",
            port: 8765,
            pids: [111, 222]
        )

        #expect(message.contains("listen [::1]:8765"))
        #expect(message.contains("pids: 111, 222"))
        #expect(message.contains("--force-restart"))
    }

    @Test func serverCommandHostMatchingHandlesLoopbackAndWildcard() throws {
        #expect(
            XcodeMCPProxyServerCommand.hostMatches(
                requestedHost: "localhost",
                actualHost: "127.0.0.1"
            )
        )
        #expect(
            XcodeMCPProxyServerCommand.hostMatches(
                requestedHost: "::",
                actualHost: "127.0.0.1"
            )
        )
        #expect(
            XcodeMCPProxyServerCommand.hostMatches(
                requestedHost: "127.0.0.1",
                actualHost: "::1"
            ) == false
        )
    }

    @Test func serverCommandExtractsListeningPIDsFromLsofFieldOutputForLocalhost() throws {
        let output = """
        p51731
        f9
        n127.0.0.1:8765
        f13
        n[::1]:8765
        p60000
        f8
        n10.0.0.5:8765
        """

        #expect(
            XcodeMCPProxyServerCommand.listeningPIDs(fromLsofOutput: output, matchingHost: "localhost")
                == [51731]
        )
    }

    @Test func serverCommandExtractsListeningPIDsFromLsofFieldOutputSkipsNonMatchingHosts() throws {
        let output = """
        p51731
        f9
        n[::1]:8765
        p60000
        f8
        n10.0.0.5:8765
        """

        #expect(
            XcodeMCPProxyServerCommand.listeningPIDs(fromLsofOutput: output, matchingHost: "127.0.0.1")
                .isEmpty
        )
    }

    @Test func serverCommandExtractsListeningPIDsFromLegacyTCPNames() throws {
        let output = """
        p111
        f9
        nTCP 127.0.0.1:8765 (LISTEN)
        p222
        f13
        nTCP [::1]:8765 (LISTEN)
        p333
        f8
        nTCP 10.0.0.5:8765 (LISTEN)
        """

        #expect(
            XcodeMCPProxyServerCommand.listeningPIDs(fromLsofOutput: output, matchingHost: "localhost")
                == [111, 222]
        )
    }

    @Test func serverCommandInvokesForceRestartBeforeStartingInjectedServer() async throws {
        let restarted = CapturedLines()
        let fakeServer = RecordingProxyServer()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                stderr: { _ in },
                terminateExistingServer: { host, port in
                    restarted.append("\(host):\(port)")
                    return true
                },
                makeServer: { config in
                    fakeServer.record(config: config)
                    return fakeServer
                },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: [
                "xcode-mcp-proxy-server",
                "--listen", "127.0.0.1:9000",
                "--force-restart",
            ],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(restarted.snapshot() == ["127.0.0.1:9000"])
        let config = try #require(fakeServer.recordedConfig())
        #expect(config.listenHost == "127.0.0.1")
        #expect(config.listenPort == 9000)
        #expect(fakeServer.startCount() == 1)
        #expect(fakeServer.waitCount() == 1)
    }

    @Test func serverCommandUsesExistingProxyServerClientForForceRestart() async throws {
        let restarted = CapturedLines()
        let warnings = CapturedLines()
        let fakeServer = RecordingProxyServer()
        let existingServerClient = testDependency(of: ExistingProxyServerClient.self) {
            $0.terminateExistingServer = { host, port, emitWarning in
                restarted.append("\(host):\(port)")
                emitWarning("fake restart warning")
                return true
            }
        }
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                stderr: { warnings.append($0) },
                makeServer: { config in
                    fakeServer.record(config: config)
                    return fakeServer
                },
                isAddressAlreadyInUse: { _ in false },
                existingProxyServerClient: existingServerClient
            )
        )

        let exitCode = await command.run(
            args: [
                "xcode-mcp-proxy-server",
                "--listen", "127.0.0.1:9001",
                "--force-restart",
            ],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(restarted.snapshot() == ["127.0.0.1:9001"])
        #expect(warnings.snapshot() == ["fake restart warning"])
        #expect(fakeServer.startCount() == 1)
    }

    @Test func serverCommandDryRunPrintsResolvedCommand() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                stderr: { output.append($0) },
                terminateExistingServer: { _, _ in false },
                makeServer: { _ in RecordingProxyServer() },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy-server", "--dry-run"],
            environment: [
                "MCP_XCODE_CONFIG": "/tmp/proxy-config.toml",
                "HOST": "127.0.0.1",
                "PORT": "9999",
            ]
        )

        #expect(exitCode == 0)
        let line = try #require(output.snapshot().first)
        #expect(line.contains("--listen 127.0.0.1:9999"))
        #expect(line.contains("--config /tmp/proxy-config.toml"))
        #expect(line.contains("--auto-approve") == false)
        #expect(line.contains("--lazy-init") == false)
    }

    @Test func serverCommandDryRunPrintsAutoApproveWhenExplicitlyEnabled() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                stderr: { output.append($0) },
                terminateExistingServer: { _, _ in false },
                makeServer: { _ in RecordingProxyServer() },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy-server", "--auto-approve", "--dry-run"],
            environment: [:]
        )

        #expect(exitCode == 0)
        let line = try #require(output.snapshot().first)
        #expect(line.contains("--auto-approve"))
    }

    @Test func serverCommandTreatsHelpOnlyAsTopLevelFlag() async throws {
        let output = CapturedLines()
        let errors = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                stderr: { errors.append($0) },
                terminateExistingServer: { _, _ in false },
                makeServer: { _ in RecordingProxyServer() },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: [
                "xcode-mcp-proxy-server",
                "--upstream-arg", "--help",
                "--dry-run",
            ],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(errors.snapshot().isEmpty)
        let line = try #require(output.snapshot().first)
        #expect(line.contains("--upstream-arg --help"))
        #expect(line.contains("Usage:") == false)
    }

    @Test func serverCommandPreservesExplicitHelpBeforeLaterParseErrors() async throws {
        let output = CapturedLines()
        let errors = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                stderr: { errors.append($0) },
                terminateExistingServer: { _, _ in false },
                makeServer: { _ in RecordingProxyServer() },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
        )

        let exitCode = await command.run(
            args: [
                "xcode-mcp-proxy-server",
                "--help",
                "--url",
            ],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(errors.snapshot().isEmpty)
        #expect(output.snapshot().first?.contains("Usage:") == true)
    }
}

private final class RecordingProxyServer: ProxyServerCommandServer {
    private let state = LockedBox(
        (config: Optional<ProxyConfig>.none, startCount: 0, waitCount: 0)
    )

    func record(config: ProxyConfig) {
        state.withValue { value in
            value.config = config
        }
    }

    func startAndWriteDiscovery() throws -> (host: String, port: Int) {
        state.withValue { value in
            value.startCount += 1
        }
        return ("127.0.0.1", 8765)
    }

    func wait() async throws {
        state.withValue { value in
            value.waitCount += 1
        }
    }

    func recordedConfig() -> ProxyConfig? {
        state.snapshot().config
    }

    func startCount() -> Int {
        state.snapshot().startCount
    }

    func waitCount() -> Int {
        state.snapshot().waitCount
    }
}
