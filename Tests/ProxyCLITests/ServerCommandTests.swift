import Foundation
import Testing
import ProxyServerCLI
import XcodeMCPProxyKit

@Suite
struct ServerCommandTests {
    @Test func proxyKitLaunchPlanNormalizesServerArguments() throws {
        let plan = try XcodeMCPProxyServer.resolveLaunchPlan(
            arguments: [
                "xcode-mcp-proxy-server",
                "--listen",
                "127.0.0.1:9000",
                "--auto-approve",
                "--refresh-code-issues-mode",
                "upstream",
                "--force-restart",
                "--dry-run",
            ],
            environment: [:]
        )

        let config = try #require(plan.configuration)
        #expect(plan.action == .dryRun)
        #expect(plan.options.forceRestart == true)
        #expect(plan.options.dryRun == true)
        #expect(config.bind.host == "127.0.0.1")
        #expect(config.bind.port == 9000)
        #expect(config.approval == .automatic)
        #expect(config.features.refreshCodeIssuesMode == .upstream)
        #expect(
            plan.resolvedDryRunCommandLine ==
                "xcode-mcp-proxy-server --listen 127.0.0.1:9000 --auto-approve --refresh-code-issues-mode upstream"
        )
    }

    @Test func proxyKitLaunchPlanNormalizesEnvironmentDefaults() throws {
        let plan = try XcodeMCPProxyServer.resolveLaunchPlan(
            arguments: ["xcode-mcp-proxy-server"],
            environment: [
                "HOST": "127.0.0.1",
                "PORT": "9999",
                "MCP_XCODE_CONFIG": "/tmp/proxy-config.toml",
                "MCP_XCODE_REFRESH_CODE_ISSUES_MODE": "upstream",
            ]
        )

        let config = try #require(plan.configuration)
        #expect(plan.action == .start)
        #expect(config.bind.host == "127.0.0.1")
        #expect(config.bind.port == 9999)
        #expect(config.configurationFilePath == "/tmp/proxy-config.toml")
        #expect(config.features.refreshCodeIssuesMode == .upstream)
        #expect(
            plan.resolvedDryRunCommandLine ==
                "xcode-mcp-proxy-server --listen 127.0.0.1:9999 --config /tmp/proxy-config.toml --refresh-code-issues-mode upstream"
        )
    }

    @Test func proxyKitLaunchPlanLetsExplicitConfigOverrideEnvironment() throws {
        let plan = try XcodeMCPProxyServer.resolveLaunchPlan(
            arguments: [
                "xcode-mcp-proxy-server",
                "--config", "/tmp/explicit.toml",
                "--dry-run",
            ],
            environment: [
                "MCP_XCODE_CONFIG": "/tmp/environment.toml",
            ]
        )

        let config = try #require(plan.configuration)
        #expect(config.configurationFilePath == "/tmp/explicit.toml")
        #expect(
            plan.resolvedDryRunCommandLine ==
                "xcode-mcp-proxy-server --config /tmp/explicit.toml --listen localhost:8765"
        )
    }

    @Test func proxyKitLaunchPlanIgnoresRemovedXcodePIDEnvironment() throws {
        let plan = try XcodeMCPProxyServer.resolveLaunchPlan(
            arguments: ["xcode-mcp-proxy-server"],
            environment: [
                "HOST": "127.0.0.1",
                "PORT": "9999",
                "XCODE_PID": "1234",
                "MCP_XCODE_PID": "5678",
            ]
        )

        let config = try #require(plan.configuration)
        #expect(config.bind.host == "127.0.0.1")
        #expect(config.bind.port == 9999)
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
        #expect(output.snapshot() == ["xcode-mcp-proxy-server \(XcodeMCPProxyServer.productMetadata.version)"])
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
        #expect(output.snapshot() == ["xcode-mcp-proxy-server \(XcodeMCPProxyServer.productMetadata.version)"])
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
            "error: \(XcodeMCPProxyServer.removedLazyInitializationMessage)",
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
            "error: \(XcodeMCPProxyServer.removedLazyInitializationMessage)",
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
            "error: \(XcodeMCPProxyServer.removedXcodePIDMessage)",
            "run with --help for usage",
        ])
    }

    @Test func proxyKitPortInUseDiagnosticFormatsMessage() throws {
        let message = XcodeMCPProxyServer.PortInUseError(
            host: "::1",
            port: 8765,
            processIdentifiers: [111, 222]
        )
        .description

        #expect(message.contains("listen [::1]:8765"))
        #expect(message.contains("pids: 111, 222"))
        #expect(message.contains("--force-restart"))
    }

    @Test func proxyKitExistingServerControllerHostMatchingHandlesLoopbackAndWildcard() throws {
        #expect(
            XcodeMCPProxyServer.ExistingServerController.hostMatches(
                requestedHost: "localhost",
                actualHost: "127.0.0.1"
            )
        )
        #expect(
            XcodeMCPProxyServer.ExistingServerController.hostMatches(
                requestedHost: "::",
                actualHost: "127.0.0.1"
            )
        )
        #expect(
            XcodeMCPProxyServer.ExistingServerController.hostMatches(
                requestedHost: "127.0.0.1",
                actualHost: "::1"
            ) == false
        )
    }

    @Test func proxyKitExistingServerControllerExtractsListeningPIDsFromLsofFieldOutputForLocalhost() throws {
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
            XcodeMCPProxyServer.ExistingServerController.listeningProcessIDs(
                fromLsofOutput: output,
                matchingHost: "localhost"
            ) == [51731]
        )
    }

    @Test func proxyKitExistingServerControllerExtractsListeningPIDsFromLsofFieldOutputSkipsNonMatchingHosts() throws {
        let output = """
        p51731
        f9
        n[::1]:8765
        p60000
        f8
        n10.0.0.5:8765
        """

        #expect(
            XcodeMCPProxyServer.ExistingServerController.listeningProcessIDs(
                fromLsofOutput: output,
                matchingHost: "127.0.0.1"
            )
            .isEmpty
        )
    }

    @Test func proxyKitExistingServerControllerExtractsListeningPIDsFromLegacyTCPNames() throws {
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
            XcodeMCPProxyServer.ExistingServerController.listeningProcessIDs(
                fromLsofOutput: output,
                matchingHost: "localhost"
            ) == [111, 222]
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
        #expect(config.bind.host == "127.0.0.1")
        #expect(config.bind.port == 9000)
        #expect(fakeServer.startCount() == 1)
        #expect(fakeServer.waitCount() == 1)
    }

    @Test func serverCommandUsesExistingServerControllerForForceRestart() async throws {
        let restarted = CapturedLines()
        let warnings = CapturedLines()
        let fakeServer = RecordingProxyServer()
        var existingServerController = XcodeMCPProxyServer.ExistingServerController.testValue
        existingServerController.terminateExistingServer = { host, port, emitWarning in
            restarted.append("\(host):\(port)")
            emitWarning("fake restart warning")
            return true
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
                existingServerController: existingServerController
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

    @Test func serverCommandReportsPortInUseThroughProxyKitDiagnostic() async throws {
        let errors = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                stderr: { errors.append($0) },
                terminateExistingServer: { _, _ in false },
                makeServer: { _ in FailingProxyServer(error: AddressAlreadyInUseError()) },
                isAddressAlreadyInUse: { _ in true },
                detectExistingProxyServerPIDs: { _, _ in [321] }
            )
        )

        let exitCode = await command.run(
            args: [
                "xcode-mcp-proxy-server",
                "--listen", "127.0.0.1:9002",
            ],
            environment: [:]
        )

        #expect(exitCode == 1)
        #expect(errors.snapshot() == [
            XcodeMCPProxyServer.PortInUseError(
                host: "127.0.0.1",
                port: 9002,
                processIdentifiers: [321]
            )
            .description,
        ])
    }

    @Test func serverCommandDryRunPrintsResolvedCommandFromLaunchPlan() async throws {
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

private struct AddressAlreadyInUseError: Error {}

private final class FailingProxyServer: ProxyServerCommandServer {
    private let error: any Error

    init(error: any Error) {
        self.error = error
    }

    func startAndWriteDiscovery() throws -> XcodeMCPProxyServer.Endpoint {
        throw error
    }

    func wait() async throws {
        Issue.record("wait should not be called when start fails")
    }
}

private final class RecordingProxyServer: ProxyServerCommandServer {
    private let state = LockedBox(
        (config: Optional<XcodeMCPProxyServer.Configuration>.none, startCount: 0, waitCount: 0)
    )

    func record(config: XcodeMCPProxyServer.Configuration) {
        state.withValue { value in
            value.config = config
        }
    }

    func startAndWriteDiscovery() throws -> XcodeMCPProxyServer.Endpoint {
        state.withValue { value in
            value.startCount += 1
        }
        return XcodeMCPProxyServer.Endpoint(host: "127.0.0.1", port: 8765)
    }

    func wait() async throws {
        state.withValue { value in
            value.waitCount += 1
        }
    }

    func recordedConfig() -> XcodeMCPProxyServer.Configuration? {
        state.snapshot().config
    }

    func startCount() -> Int {
        state.snapshot().startCount
    }

    func waitCount() -> Int {
        state.snapshot().waitCount
    }
}
