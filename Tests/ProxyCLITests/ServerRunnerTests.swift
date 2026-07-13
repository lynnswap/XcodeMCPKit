import Foundation
import Testing
@testable import XcodeMCPProxyKit
import XcodeMCPProxyRuntime

@Suite
struct ServerRunnerTests {
    @Test func serverLaunchPlanNormalizesServerArguments() throws {
        let action = try XcodeMCPProxyServer.resolveLaunchAction(
            arguments: [
                "xcode-mcp-proxy-server",
                "--listen",
                "127.0.0.1:9000",
                "--auto-approve",
                "--refresh-code-issues-mode",
                "upstream",
                "--force-restart",
            ],
            environment: [:]
        )

        let (config, forceRestart) = try startPayload(action)
        #expect(forceRestart == true)
        #expect(config.bindAddress.host == "127.0.0.1")
        #expect(config.bindAddress.port == 9000)
        #expect(config.approvalPolicy == .automatic)
        #expect(config.featurePolicy.refreshCodeIssuesMode == .upstream)
    }

    @Test func serverLaunchPlanNormalizesEnvironmentDefaults() throws {
        let configURL = try makeServerConfigFile()
        defer { try? FileManager.default.removeItem(at: configURL) }
        let action = try XcodeMCPProxyServer.resolveLaunchAction(
            arguments: ["xcode-mcp-proxy-server"],
            environment: [
                "HOST": "127.0.0.1",
                "PORT": "9999",
                "MCP_XCODE_CONFIG": configURL.path,
                "MCP_XCODE_REFRESH_CODE_ISSUES_MODE": "upstream",
            ]
        )

        let (config, _) = try startPayload(action)
        #expect(config.bindAddress.host == "127.0.0.1")
        #expect(config.bindAddress.port == 9999)
        #expect(config.configurationFileURL == configURL)
        #expect(config.featurePolicy.refreshCodeIssuesMode == .upstream)
    }

    @Test func serverLaunchPlanLetsExplicitConfigOverrideEnvironment() throws {
        let explicitConfigURL = try makeServerConfigFile()
        defer { try? FileManager.default.removeItem(at: explicitConfigURL) }
        let action = try XcodeMCPProxyServer.resolveLaunchAction(
            arguments: [
                "xcode-mcp-proxy-server",
                "--config", explicitConfigURL.path,
                "--dry-run",
            ],
            environment: [
                "MCP_XCODE_CONFIG": "/tmp/environment.toml",
            ]
        )

        guard case .dryRun(let commandLine) = action else {
            Issue.record("expected dry-run action")
            return
        }
        #expect(
            commandLine ==
                "xcode-mcp-proxy-server --config \(explicitConfigURL.path) --listen localhost:8765"
        )
    }

    @Test func serverLaunchPlanIgnoresRemovedXcodePIDEnvironment() throws {
        let action = try XcodeMCPProxyServer.resolveLaunchAction(
            arguments: ["xcode-mcp-proxy-server"],
            environment: [
                "HOST": "127.0.0.1",
                "PORT": "9999",
                "XCODE_PID": "1234",
                "MCP_XCODE_PID": "5678",
            ]
        )

        let (config, _) = try startPayload(action)
        #expect(config.bindAddress.host == "127.0.0.1")
        #expect(config.bindAddress.port == 9999)
    }

    @Test func serverLaunchNormalizesOnlyZeroTimeoutToNil() throws {
        let disabled = try XcodeMCPProxyServer.resolveLaunchAction(
            arguments: [
                "xcode-mcp-proxy-server",
                "--request-timeout", "0",
            ],
            environment: [:]
        )
        let (configuration, _) = try startPayload(disabled)
        #expect(configuration.requestTimeout == nil)

        for invalid in ["-1", "nan", "inf", "not-a-number"] {
            #expect(throws: XcodeMCPProxyServer.LaunchResolutionError.self) {
                _ = try XcodeMCPProxyServer.resolveLaunchAction(
                    arguments: [
                        "xcode-mcp-proxy-server",
                        "--request-timeout", invalid,
                    ],
                    environment: [:]
                )
            }
        }
    }

    @Test func serverLaunchReadsExplicitConfigurationExactlyOnce() throws {
        let configURL = try makeServerConfigFile()
        defer { try? FileManager.default.removeItem(at: configURL) }
        let readCount = LockedBox(0)

        _ = try XcodeMCPProxyServer.resolveLaunchAction(
            arguments: [
                "xcode-mcp-proxy-server",
                "--config", configURL.path,
            ],
            environment: [:],
            loadFileConfiguration: { url in
                #expect(url == configURL)
                readCount.withValue { $0 += 1 }
                return try ProxyConfig.File.Loader.loadStrict(configURL: url)
            }
        )

        #expect(readCount.snapshot() == 1)
    }

    @Test func serverLaunchExpandsTildeConfigPathBeforeLoading() throws {
        let relativePath = "~/.config/xcode-mcp/proxy.toml"
        let expectedURL = URL(
            fileURLWithPath: NSString(string: relativePath).expandingTildeInPath
        )

        _ = try XcodeMCPProxyServer.resolveLaunchAction(
            arguments: [
                "xcode-mcp-proxy-server",
                "--config", relativePath,
            ],
            environment: [:],
            loadFileConfiguration: { url in
                #expect(url == expectedURL)
                return ProxyConfig.File.LoadedConfiguration(
                    disabledToolNames: [],
                    initializeParamsOverride: nil
                )
            }
        )
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
            makeServer: { preparedConfiguration in
                fakeServer.record(config: preparedConfiguration.configuration)
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
            makeServer: { preparedConfiguration in
                fakeServer.record(config: preparedConfiguration.configuration)
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
        let configURL = try makeServerConfigFile()
        defer { try? FileManager.default.removeItem(at: configURL) }
        let result = await runServer(
            arguments: ["xcode-mcp-proxy-server", "--dry-run"],
            environment: [
                "MCP_XCODE_CONFIG": configURL.path,
                "HOST": "127.0.0.1",
                "PORT": "9999",
            ]
        )

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let line = try #require(result.stdout.first)
        #expect(line.contains("--listen 127.0.0.1:9999"))
        #expect(line.contains("--config \(configURL.path)"))
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
    makeServer: @escaping (XcodeMCPProxyServer.PreparedConfiguration) ->
        any XcodeMCPProxyServer.LaunchServer = { _ in
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

private func startPayload(
    _ action: XcodeMCPProxyServer.LaunchAction
) throws -> (XcodeMCPProxyServerConfiguration, Bool) {
    guard case .start(let preparedConfiguration, let forceRestart) = action else {
        throw UnexpectedServerLaunchAction()
    }
    return (preparedConfiguration.configuration, forceRestart)
}

private func makeServerConfigFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("server-config-\(UUID().uuidString).toml")
    try "".write(to: url, atomically: true, encoding: .utf8)
    return url
}

private struct UnexpectedServerLaunchAction: Error {}

private struct AddressAlreadyInUseError: Error {}

private final class FailingProxyServer: XcodeMCPProxyServer.LaunchServer {
    private let error: any Error

    init(error: any Error) {
        self.error = error
    }

    func start() async throws -> XcodeMCPProxyServer.Endpoint {
        throw error
    }

    func waitUntilShutdown() async throws {
        Issue.record("wait should not be called when start fails")
    }

    func shutdown() async throws {}
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

    func start() async throws -> XcodeMCPProxyServer.Endpoint {
        state.withValue { value in
            value.startCount += 1
        }
        return XcodeMCPProxyServer.Endpoint(host: "127.0.0.1", port: 8765)
    }

    func waitUntilShutdown() async throws {
        state.withValue { value in
            value.waitCount += 1
        }
    }

    func shutdown() async throws {}

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
