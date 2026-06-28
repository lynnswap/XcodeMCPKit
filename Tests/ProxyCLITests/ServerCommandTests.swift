import Foundation
import Testing
@testable import XcodeMCPProxyKit

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
        let command = makeServerCommand(
            stdout: { output.append($0) },
            forceRestartExistingServer: { _, _, _ in
                Issue.record("forceRestartExistingServer should not be called for --version")
                return false
            },
            makeServer: { _ in
                Issue.record("makeServer should not be called for --version")
                return RecordingProxyServer()
            }
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
        let command = makeServerCommand(
            stdout: { output.append($0) },
            forceRestartExistingServer: { _, _, _ in
                Issue.record("forceRestartExistingServer should not be called for --version")
                return false
            },
            makeServer: { _ in
                Issue.record("makeServer should not be called for --version")
                return RecordingProxyServer()
            }
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
        let command = makeServerCommand(
            stdout: { output.append($0) },
            stderr: { errors.append($0) },
            makeServer: { _ in
                Issue.record("makeServer should not be called for --help")
                return RecordingProxyServer()
            }
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
        let command = makeServerCommand(
            stdout: { output.append($0) },
            stderr: { errors.append($0) },
            makeServer: { _ in
                Issue.record("makeServer should not be called for --help")
                return RecordingProxyServer()
            }
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
        let command = makeServerCommand(
            stdout: { output.append($0) },
            stderr: { output.append($0) }
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
        let command = makeServerCommand(
            stdout: { output.append($0) },
            stderr: { output.append($0) }
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
        let command = makeServerCommand(
            stdout: { output.append($0) },
            stderr: { output.append($0) }
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

    @Test func serverCommandInvokesForceRestartBeforeStartingInjectedServer() async throws {
        let restarted = CapturedLines()
        let fakeServer = RecordingProxyServer()
        let command = makeServerCommand(
            forceRestartExistingServer: { host, port, _ in
                restarted.append("\(host):\(port)")
                return true
            },
            makeServer: { config in
                fakeServer.record(config: config)
                return fakeServer
            }
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

    @Test func serverCommandEmitsLauncherForceRestartWarnings() async throws {
        let restarted = CapturedLines()
        let warnings = CapturedLines()
        let fakeServer = RecordingProxyServer()
        let command = makeServerCommand(
            stderr: { warnings.append($0) },
            forceRestartExistingServer: { host, port, emitWarning in
                restarted.append("\(host):\(port)")
                emitWarning("fake restart warning")
                return true
            },
            makeServer: { config in
                fakeServer.record(config: config)
                return fakeServer
            }
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
        let command = makeServerCommand(
            stderr: { errors.append($0) },
            makeServer: { _ in FailingProxyServer(error: AddressAlreadyInUseError()) },
            isAddressAlreadyInUse: { _ in true },
            detectExistingServerProcessIDs: { _, _ in [321] }
        )

        let exitCode = await command.run(
            args: [
                "xcode-mcp-proxy-server",
                "--listen", "127.0.0.1:9002",
            ],
            environment: [:]
        )

        #expect(exitCode == 1)
        let diagnostic = try #require(errors.snapshot().first)
        #expect(errors.snapshot().count == 1)
        #expect(diagnostic.contains("listen 127.0.0.1:9002"))
        #expect(diagnostic.contains("pid: 321"))
        #expect(diagnostic.contains("--force-restart"))
    }

    @Test func serverCommandDryRunPrintsResolvedCommandFromLaunchPlan() async throws {
        let output = CapturedLines()
        let command = makeServerCommand(
            stdout: { output.append($0) },
            stderr: { output.append($0) }
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
        let command = makeServerCommand(
            stdout: { output.append($0) },
            stderr: { output.append($0) }
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
        let command = makeServerCommand(
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
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
        let command = makeServerCommand(
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
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

private func makeServerCommand(
    stdout: @escaping (String) -> Void = { _ in },
    stderr: @escaping (String) -> Void = { _ in },
    forceRestartExistingServer: @escaping (_ host: String, _ port: Int, _ stderr: (String) -> Void) -> Bool = {
        _, _, _ in false
    },
    makeServer: @escaping (XcodeMCPProxyServer.Configuration) -> any XcodeMCPProxyServer.LaunchServer = { _ in
        RecordingProxyServer()
    },
    isAddressAlreadyInUse: @escaping (Swift.Error) -> Bool = { _ in false },
    detectExistingServerProcessIDs: @escaping (_ host: String, _ port: Int) -> [Int] = { _, _ in [] }
) -> XcodeMCPProxyServerCommand {
    let launcher = XcodeMCPProxyServer.Launcher(
        dependencies: .init(
            makeServer: makeServer,
            isAddressAlreadyInUse: isAddressAlreadyInUse,
            forceRestartExistingServer: forceRestartExistingServer,
            detectExistingServerProcessIDs: detectExistingServerProcessIDs
        )
    )
    return XcodeMCPProxyServerCommand(
        dependencies: .init(
            bootstrapLogging: { _ in },
            stdout: stdout,
            stderr: stderr,
            launcher: launcher
        )
    )
}

private struct AddressAlreadyInUseError: Error {}

private final class FailingProxyServer: XcodeMCPProxyServer.LaunchServer {
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

private final class RecordingProxyServer: XcodeMCPProxyServer.LaunchServer {
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
