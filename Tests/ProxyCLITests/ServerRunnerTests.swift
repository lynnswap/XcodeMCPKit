import Foundation
import Testing
@testable import XcodeMCPProxyKit

@Suite
struct ServerRunnerTests {
    @Test func serverLaunchPlanNormalizesServerArguments() throws {
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
        #expect(config.bindAddress.host == "127.0.0.1")
        #expect(config.bindAddress.port == 9000)
        #expect(config.approvalPolicy == .automatic)
        #expect(config.featurePolicy.refreshCodeIssuesMode == .upstream)
        #expect(
            plan.resolvedDryRunCommandLine ==
                "xcode-mcp-proxy-server --listen 127.0.0.1:9000 --auto-approve --refresh-code-issues-mode upstream"
        )
    }

    @Test func serverLaunchPlanNormalizesEnvironmentDefaults() throws {
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
        #expect(config.bindAddress.host == "127.0.0.1")
        #expect(config.bindAddress.port == 9999)
        #expect(config.configurationFilePath == "/tmp/proxy-config.toml")
        #expect(config.featurePolicy.refreshCodeIssuesMode == .upstream)
        #expect(
            plan.resolvedDryRunCommandLine ==
                "xcode-mcp-proxy-server --listen 127.0.0.1:9999 --config /tmp/proxy-config.toml --refresh-code-issues-mode upstream"
        )
    }

    @Test func serverLaunchPlanLetsExplicitConfigOverrideEnvironment() throws {
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

    @Test func serverLaunchPlanIgnoresRemovedXcodePIDEnvironment() throws {
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
        #expect(config.bindAddress.host == "127.0.0.1")
        #expect(config.bindAddress.port == 9999)
    }

    @Test func serverRunnerPrintsVersionBeforeValidation() async throws {
        let result = await runServer(
            arguments: [
                "xcode-mcp-proxy-server",
                "--version",
                "--url", "http://localhost:8765/mcp",
            ]
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == ["xcode-mcp-proxy-server \(XcodeMCPProxyServer.productMetadata.version)"])
        #expect(result.stderr.isEmpty)
    }

    @Test func serverRunnerPrintsVersionWhenFlagAppearsAsConfigValue() async throws {
        let result = await runServer(arguments: ["xcode-mcp-proxy-server", "--config", "--version"])

        #expect(result.exitCode == 0)
        #expect(result.stdout == ["xcode-mcp-proxy-server \(XcodeMCPProxyServer.productMetadata.version)"])
        #expect(result.stderr.isEmpty)
    }

    @Test func serverRunnerHelpWinsOverVersion() async throws {
        let result = await runServer(arguments: ["xcode-mcp-proxy-server", "--version", "--help", "--url"])

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let line = try #require(result.stdout.first)
        #expect(line.contains("Usage:"))
    }

    @Test func serverRunnerHelpWinsOverVersionWhenRefreshModeValueIsMissing() async throws {
        let result = await runServer(
            arguments: [
                "xcode-mcp-proxy-server",
                "--version",
                "--refresh-code-issues-mode",
                "--help",
            ]
        )

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let line = try #require(result.stdout.first)
        #expect(line.contains("Usage:"))
    }

    @Test func serverRunnerRejectsRemovedLazyInitEnvironment() async throws {
        let result = await runServer(
            arguments: ["xcode-mcp-proxy-server", "--dry-run"],
            environment: ["LAZY_INIT": "true"]
        )

        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr == [
            "error: \(XcodeMCPProxyServer.removedLazyInitializationMessage)",
            "run with --help for usage",
        ])
    }

    @Test func serverRunnerRejectsRemovedLazyInitFlagBeforeDryRun() async throws {
        let result = await runServer(
            arguments: ["xcode-mcp-proxy-server", "--lazy-init", "--dry-run"]
        )

        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr == [
            "error: \(XcodeMCPProxyServer.removedLazyInitializationMessage)",
            "run with --help for usage",
        ])
    }

    @Test func serverRunnerRejectsRemovedXcodePIDFlagBeforeDryRun() async throws {
        let result = await runServer(
            arguments: ["xcode-mcp-proxy-server", "--xcode-pid", "1234", "--dry-run"]
        )

        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr == [
            "error: \(XcodeMCPProxyServer.removedXcodePIDMessage)",
            "run with --help for usage",
        ])
    }

    @Test func serverLauncherInvokesForceRestartBeforeStartingInjectedServer() async throws {
        let restarted = CapturedLines()
        let fakeServer = RecordingProxyServer()
        let launcher = makeServerLauncher(
            forceRestartExistingServer: { host, port, _ in
                restarted.append("\(host):\(port)")
                return true
            },
            makeServer: { config in
                fakeServer.record(config: config)
                return fakeServer
            }
        )

        let exitCode = await launcher.run(
            arguments: [
                "xcode-mcp-proxy-server",
                "--listen", "127.0.0.1:9000",
                "--force-restart",
            ],
            environment: [:],
            stdout: { _ in },
            stderr: { _ in }
        )

        #expect(exitCode == 0)
        #expect(restarted.snapshot() == ["127.0.0.1:9000"])
        let config = try #require(fakeServer.recordedConfig())
        #expect(config.bindAddress.host == "127.0.0.1")
        #expect(config.bindAddress.port == 9000)
        #expect(fakeServer.startCount() == 1)
        #expect(fakeServer.waitCount() == 1)
    }

    @Test func serverLauncherEmitsForceRestartWarnings() async throws {
        let restarted = CapturedLines()
        let warnings = CapturedLines()
        let fakeServer = RecordingProxyServer()
        let launcher = makeServerLauncher(
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

        let exitCode = await launcher.run(
            arguments: [
                "xcode-mcp-proxy-server",
                "--listen", "127.0.0.1:9001",
                "--force-restart",
            ],
            environment: [:],
            stdout: { _ in },
            stderr: { warnings.append($0) }
        )

        #expect(exitCode == 0)
        #expect(restarted.snapshot() == ["127.0.0.1:9001"])
        #expect(warnings.snapshot() == ["fake restart warning"])
        #expect(fakeServer.startCount() == 1)
    }

    @Test func serverLauncherReportsPortInUseThroughProxyKitDiagnostic() async throws {
        let errors = CapturedLines()
        let launcher = makeServerLauncher(
            makeServer: { _ in FailingProxyServer(error: AddressAlreadyInUseError()) },
            isAddressAlreadyInUse: { _ in true },
            detectExistingServerProcessIDs: { _, _ in [321] }
        )

        let exitCode = await launcher.run(
            arguments: [
                "xcode-mcp-proxy-server",
                "--listen", "127.0.0.1:9002",
            ],
            environment: [:],
            stdout: { _ in },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 1)
        let diagnostic = try #require(errors.snapshot().first)
        #expect(errors.snapshot().count == 1)
        #expect(diagnostic.contains("listen 127.0.0.1:9002"))
        #expect(diagnostic.contains("pid: 321"))
        #expect(diagnostic.contains("--force-restart"))
    }

    @Test func serverRunnerDryRunPrintsResolvedCommandFromLaunchPlan() async throws {
        let result = await runServer(
            arguments: ["xcode-mcp-proxy-server", "--dry-run"],
            environment: [
                "MCP_XCODE_CONFIG": "/tmp/proxy-config.toml",
                "HOST": "127.0.0.1",
                "PORT": "9999",
            ]
        )

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let line = try #require(result.stdout.first)
        #expect(line.contains("--listen 127.0.0.1:9999"))
        #expect(line.contains("--config /tmp/proxy-config.toml"))
        #expect(line.contains("--auto-approve") == false)
        #expect(line.contains("--lazy-init") == false)
    }

    @Test func serverRunnerDryRunPrintsAutoApproveWhenExplicitlyEnabled() async throws {
        let result = await runServer(
            arguments: ["xcode-mcp-proxy-server", "--auto-approve", "--dry-run"]
        )

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let line = try #require(result.stdout.first)
        #expect(line.contains("--auto-approve"))
    }

    @Test func serverRunnerTreatsHelpOnlyAsTopLevelFlag() async throws {
        let result = await runServer(
            arguments: [
                "xcode-mcp-proxy-server",
                "--upstream-arg", "--help",
                "--dry-run",
            ]
        )

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let line = try #require(result.stdout.first)
        #expect(line.contains("--upstream-arg --help"))
        #expect(line.contains("Usage:") == false)
    }

    @Test func serverRunnerPreservesExplicitHelpBeforeLaterParseErrors() async throws {
        let result = await runServer(
            arguments: [
                "xcode-mcp-proxy-server",
                "--help",
                "--url",
            ]
        )

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.first?.contains("Usage:") == true)
    }
}

private func runServer(
    arguments: [String],
    environment: [String: String] = [:]
) async -> (exitCode: Int32, stdout: [String], stderr: [String]) {
    let output = CapturedLines()
    let errors = CapturedLines()
    let exitCode = await XcodeMCPProxyServer.run(
        arguments: arguments,
        environment: environment,
        stdout: { output.append($0) },
        stderr: { errors.append($0) }
    )
    return (exitCode, output.snapshot(), errors.snapshot())
}

private func makeServerLauncher(
    forceRestartExistingServer: @escaping (_ host: String, _ port: Int, _ stderr: (String) -> Void) -> Bool = {
        _, _, _ in false
    },
    makeServer: @escaping (XcodeMCPProxyServerConfiguration) -> any XcodeMCPProxyServer.LaunchServer = { _ in
        RecordingProxyServer()
    },
    isAddressAlreadyInUse: @escaping (Swift.Error) -> Bool = { _ in false },
    detectExistingServerProcessIDs: @escaping (_ host: String, _ port: Int) -> [Int] = { _, _ in [] }
) -> XcodeMCPProxyServer.Launcher {
    XcodeMCPProxyServer.Launcher(
        dependencies: .init(
            makeServer: makeServer,
            isAddressAlreadyInUse: isAddressAlreadyInUse,
            forceRestartExistingServer: forceRestartExistingServer,
            detectExistingServerProcessIDs: detectExistingServerProcessIDs
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
        (config: Optional<XcodeMCPProxyServerConfiguration>.none, startCount: 0, waitCount: 0)
    )

    func record(config: XcodeMCPProxyServerConfiguration) {
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

    func recordedConfig() -> XcodeMCPProxyServerConfiguration? {
        state.snapshot().config
    }

    func startCount() -> Int {
        state.snapshot().startCount
    }

    func waitCount() -> Int {
        state.snapshot().waitCount
    }
}
