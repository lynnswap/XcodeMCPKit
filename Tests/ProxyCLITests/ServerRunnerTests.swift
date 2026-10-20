import XcodeMCPCore
import Foundation
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyKit
@testable import XcodeMCPProxyRuntime

@Suite
struct ServerRunnerTests {
    @Test func serverLaunchPlanNormalizesServerArguments() throws {
        let action = try XcodeMCPProxyServer.resolveLaunchAction(
            arguments: [
                "xcode-mcp-proxy-server",
                "--listen",
                "127.0.0.1:9000",
                    "--force-restart",
            ],
            environment: [:]
        )

        let (config, forceRestart) = try startPayload(action)
        #expect(forceRestart == true)
        #expect(config.bindAddress.host == "127.0.0.1")
        #expect(config.bindAddress.port == 9000)
    }

    @Test func serverLaunchPlanNormalizesEnvironmentDefaults() throws {
        let action = try XcodeMCPProxyServer.resolveLaunchAction(
            arguments: ["xcode-mcp-proxy-server"],
            environment: [
                "HOST": "127.0.0.1",
                "PORT": "9999",
            ]
        )

        let (config, _) = try startPayload(action)
        #expect(config.bindAddress.host == "127.0.0.1")
        #expect(config.bindAddress.port == 9999)
    }

    @Test func serverLauncherPreservesInjectedNativeSelectionThroughChildConfiguration() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.cleanup() }
        let bundle = temporary.url.appendingPathComponent("Injected Native Host.app", isDirectory: true)
        let executable = bundle.appendingPathComponent("Contents/MacOS/xcode-mcp-native-host")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let developerDirectory = "/Applications/Injected Xcode.app/Contents/Developer"
        let fakeServer = RecordingProxyServer()
        let launcher = makeServerLauncher(makeServer: { configuration in
            fakeServer.record(config: configuration)
            return fakeServer
        })

        let exitCode = await launcher.run(
            arguments: ["xcode-mcp-proxy-server"],
            environment: [
                "DEVELOPER_DIR": developerDirectory,
                "XCODE_MCP_NATIVE_HOST_BUNDLE": bundle.path,
            ],
            stdout: { _ in }, stderr: { _ in }
        )
        #expect(exitCode == 0)
        let configuration = try #require(fakeServer.recordedConfig())
        let runtimeConfiguration = try configuration.runtimeConfiguration()
        let child = try NativeHostRuntime.makeDefaultUpstreamConfig(
            config: NativeHostRuntime.Configuration(
                nativeHostBundleURL: runtimeConfiguration.nativeHostBundleURL,
                developerDirectoryURL: runtimeConfiguration.developerDirectoryURL,
                sharesCompilationCache: runtimeConfiguration.sharesCompilationCache,
                maxBodyBytes: runtimeConfiguration.maxMessageBytes),
            baseEnvironment: [
                "DEVELOPER_DIR": "/Applications/Parent Xcode.app/Contents/Developer",
                "XCODE_MCP_NATIVE_HOST_BUNDLE": "/missing/Parent Native Host.app",
            ]
        )
        #expect(child.command == executable.resolvingSymlinksInPath().path)
        #expect(Array(child.args.prefix(2)) == ["--developer-dir", developerDirectory])
        #expect(child.environment["DEVELOPER_DIR"] == developerDirectory)
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
            #expect(throws: CLICommandError.self) {
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

    @Test func serverRunnerPrintsVersion() async throws {
        let result = await runServer(
            arguments: ["xcode-mcp-proxy-server", "--version"]
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == [XcodeMCPProxyServer.productMetadata.version])
        #expect(result.stderr.isEmpty)
    }

    @Test func serverRunnerDoesNotReinterpretAnOptionValueAsVersion() async throws {
        let result = await runServer(arguments: ["xcode-mcp-proxy-server", "--listen", "--version"])

        #expect(result.exitCode == 64)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.first?.contains("Missing value for '--listen <host:port>'") == true)
    }

    @Test func serverRunnerPrintsGeneratedHelp() async throws {
        let result = await runServer(arguments: ["xcode-mcp-proxy-server", "--help"])

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let line = try #require(result.stdout.first)
        #expect(line.contains("USAGE: xcode-mcp-proxy-server"))
    }

    @Test func serverRunnerRejectsUnsupportedOptionsThroughArgumentParser() async {
        for option in ["--lazy-init", "--xcode-pid", "--url", "--stdio"] {
            let result = await runServer(
                arguments: ["xcode-mcp-proxy-server", option]
            )

            #expect(result.exitCode == 64)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.first?.contains("Unknown option '\(option)'") == true)
        }
    }

    @Test func serverLauncherInvokesForceRestartBeforeStartingInjectedServer() async throws {
        let restarted = CapturedLines()
        let fakeServer = RecordingProxyServer()
        let launcher = makeServerLauncher(
            forceRestartExistingServer: { host, port, _ in
                restarted.append("\(host):\(port)")
                return true
            },
            makeServer: { configuration in
                fakeServer.record(config: configuration)
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

    @Test(arguments: [
        (["--host", " "], [String: String]()),
        (["--host", "\t\n"], [String: String]()),
        (["--listen", " :8765"], [String: String]()),
        (["--port", "65536"], [String: String]()),
        ([String](), ["PORT": "65536"]),
        ([String](), ["LISTEN": "localhost:65536"]),
    ])
    func invalidStartupConfigurationPreventsRestartSideEffects(
        input: (arguments: [String], environment: [String: String])
    ) async throws {
        let effects = CapturedLines()
        let errors = CapturedLines()
        let fakeServer = RecordingProxyServer()
        let launcher = makeServerLauncher(
            forceRestartExistingServer: { _, _, _ in effects.append("terminate"); return true },
            makeServer: { _ in effects.append("makeServer"); return fakeServer },
            detectExistingServerProcessIDs: { _, _ in effects.append("lookup"); return [123] }
        )
        let exitCode = await launcher.run(
            arguments: ["xcode-mcp-proxy-server"] + input.arguments + ["--force-restart"],
            environment: input.environment,
            stdout: { _ in }, stderr: { errors.append($0) }
        )
        #expect(exitCode != 0)
        #expect(errors.snapshot().count == 1)
        #expect(effects.snapshot().isEmpty)
        #expect(fakeServer.startCount() == 0)
        #expect(fakeServer.waitCount() == 0)
    }

    @Test(arguments: [
        ["--host", " "], ["--listen", " :8765"], ["--port", "65536"],
    ])
    func publicDryRunRejectsInvalidStartupConfiguration(arguments: [String]) async throws {
        let result = await runServer(arguments:
            ["xcode-mcp-proxy-server"] + arguments + ["--force-restart", "--dry-run"])
        #expect(result.exitCode != 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.count == 1)
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
            makeServer: { configuration in
                fakeServer.record(config: configuration)
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

    @Test func forceRestartLeavesNonProxyListenerRunningAndReportsPortInUse() async throws {
        let processControl = ProcessControlClient(
            runCommand: { path, arguments in
                switch (path, arguments) {
                case ("/usr/sbin/lsof", ["-nP", "-iTCP:9002", "-sTCP:LISTEN", "-Fpn"]):
                    return "p123\nn127.0.0.1:9002"
                case ("/bin/ps", ["-ww", "-p", "123", "-o", "command="]):
                    return "/usr/bin/python3 other-server.py"
                default:
                    Issue.record("unexpected process lookup: \(path) \(arguments)")
                    return nil
                }
            },
            sendSignal: { _, _ in
                Issue.record("non-proxy listener must not receive signals")
                return ProcessSignalResult(result: 0, errnoValue: 0)
            }
        )
        let controller = ExistingProxyServerProcessController.live(processControl: processControl)
        let errors = CapturedLines()
        let launcher = makeServerLauncher(
            forceRestartExistingServer: controller.terminateExistingServer,
            makeServer: { _ in FailingProxyServer(error: AddressAlreadyInUseError()) },
            isAddressAlreadyInUse: { _ in true },
            detectExistingServerProcessIDs: controller.detectExistingServerProcessIDs
        )

        let exitCode = await launcher.run(
            arguments: ["xcode-mcp-proxy-server", "--listen", "127.0.0.1:9002", "--force-restart"],
            environment: [:],
            stdout: { _ in },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 1)
        #expect(errors.snapshot().count == 1)
        let diagnostic = try #require(errors.snapshot().first)
        #expect(diagnostic.contains("listen 127.0.0.1:9002 is already in use"))
        #expect(!diagnostic.contains("Detected"))
    }

    @Test(arguments: [false, true])
    func serverLauncherPreservesWaitAndShutdownFailures(waitFails: Bool) async throws {
        let server = ShutdownFailingProxyServer(waitFails: waitFails)
        let errors = CapturedLines()
        let launcher = makeServerLauncher(makeServer: { _ in server })

        let exitCode = await launcher.run(
            arguments: ["xcode-mcp-proxy-server", "--listen", "127.0.0.1:9002"],
            environment: [:],
            stdout: { _ in },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 1)
        #expect(server.shutdownCount == 1)
        let diagnostic = try #require(errors.snapshot().first)
        #expect(errors.snapshot().count == 1)
        #expect(diagnostic.contains("gateway cleanup failed"))
        #expect(diagnostic.contains("listener wait failed") == waitFails)
    }

    @Test(.timeLimit(.minutes(1)))
    func aTerminationSignalShutsTheServerDown() async throws {
        let server = SignalStoppedProxyServer()
        let handlers = LockedBox<[@Sendable () -> Void]>([])
        let observing = LockedBox(false)
        let launcher = XcodeMCPProxyServer.Launcher(dependencies: .init(
            makeServer: { _ in server },
            isAddressAlreadyInUse: { _ in false },
            observeTerminationSignals: { handler in
                handlers.withValue { $0.append(handler) }
                observing.withValue { $0 = true }
                return { observing.withValue { $0 = false } }
            }
        ))

        let running = Task {
            await launcher.run(arguments: ["xcode-mcp-proxy-server", "--listen", "127.0.0.1:9003"],
                               environment: [:], stdout: { _ in }, stderr: { _ in })
        }
        while handlers.snapshot().isEmpty { await Task.yield() }
        handlers.snapshot().first?()

        #expect(await running.value == 0)
        #expect(server.shutdownCount >= 1)
        #expect(!observing.snapshot())
    }

    /// A failed cleanup still fails the run.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func aTerminationSignalDuringStartupShutsTheServerDown(cleanupFails: Bool) async throws {
        let server = StartBlockingProxyServer(cleanupFails: cleanupFails)
        let errors = CapturedLines()
        let handlers = LockedBox<[@Sendable () -> Void]>([])
        let launcher = XcodeMCPProxyServer.Launcher(dependencies: .init(
            makeServer: { _ in server },
            isAddressAlreadyInUse: { _ in false },
            observeTerminationSignals: { handler in
                handlers.withValue { $0.append(handler) }
                return {}
            }
        ))

        let running = Task {
            await launcher.run(arguments: ["xcode-mcp-proxy-server", "--listen", "127.0.0.1:9004"],
                               environment: [:], stdout: { _ in }, stderr: { errors.append($0) })
        }
        while handlers.snapshot().isEmpty || !server.isStarting { await Task.yield() }
        handlers.snapshot().first?()

        #expect(await running.value == (cleanupFails ? 1 : 0))
        #expect(server.shutdownCount >= 1)
        #expect(errors.snapshot().contains { $0.contains("gateway cleanup failed") } == cleanupFails)
    }

    @Test func startupCleanupFailureIsNotReplacedByPortInUseDiagnostic() async throws {
        let error = XcodeMCPProxyServer.CleanupError(
            operationError: AddressAlreadyInUseError(),
            cleanupError: LaunchCleanupFailure.expected,
            endpoint: nil
        )
        let errors = CapturedLines()
        let launcher = makeServerLauncher(
            makeServer: { _ in FailingProxyServer(error: error) },
            isAddressAlreadyInUse: { _ in true }
        )

        let exitCode = await launcher.run(
            arguments: ["xcode-mcp-proxy-server"],
            environment: [:],
            stdout: { _ in },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 1)
        let diagnostic = try #require(errors.snapshot().first)
        #expect(diagnostic.contains("AddressAlreadyInUseError"))
        #expect(diagnostic.contains("gateway cleanup failed"))
    }

    @Test func serverRunnerDryRunPrintsResolvedCommandFromLaunchPlan() async throws {
        let result = await runServer(
            arguments: ["xcode-mcp-proxy-server", "--dry-run"],
            environment: [
                "HOST": "127.0.0.1",
                "PORT": "9999",
            ]
        )

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let line = try #require(result.stdout.first)
        #expect(line.contains("--listen 127.0.0.1:9999"))
        #expect(line.contains("--auto-approve") == false)
        #expect(line.contains("--lazy-init") == false)
    }



    @Test func serverRunnerRejectsRemovedXcodeMode() async {
        let result = await runServer(arguments: ["xcode-mcp-proxy-server", "--xcode-mode", "headless", "--dry-run"])
        #expect(result.exitCode != 0)
        #expect(result.stderr.joined().contains("xcode-mode"))
    }

    @Test func serverLaunchPlanHonorsDryRunEnvironment() throws {
        for value in ["1", "true", "TRUE", "yes", "on", " ON "] {
            let action = try XcodeMCPProxyServer.resolveLaunchAction(
                arguments: ["xcode-mcp-proxy-server"],
                environment: ["DRY_RUN": value]
            )

            guard case .dryRun = action else {
                Issue.record("expected DRY_RUN=\(value) to select the dry-run action")
                continue
            }
        }
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
        #expect(result.stdout.first?.contains("USAGE:") == true)
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

/// These tests change the process-wide `SIGTERM` disposition, so they run one at a time.
@Suite(.serialized)
struct TerminationSignalTests {
    @Test(.timeLimit(.minutes(1)))
    func aDeliveredTerminationSignalReachesTheHandler() async throws {
        let calls = LockedBox(0)
        let stop = TerminationSignals.observe { calls.withValue { $0 += 1 } }
        defer { stop() }
        kill(getpid(), SIGTERM)
        while calls.snapshot() == 0 { await Task.yield() }
        #expect(calls.snapshot() == 1)
    }

    @Test func overlappingObserversKeepTheirDispositionsUntilTheLastStops() {
        var custom = sigaction()
        custom.__sigaction_u.__sa_handler = SIG_IGN
        custom.sa_flags = SA_RESTART | SA_NODEFER
        var original = sigaction()
        sigaction(SIGTERM, &custom, &original)
        defer { sigaction(SIGTERM, &original, nil) }

        let stopFirst = TerminationSignals.observe {}
        let stopSecond = TerminationSignals.observe {}
        stopFirst()
        var current = sigaction()
        sigaction(SIGTERM, nil, &current)
        #expect(current.sa_flags != custom.sa_flags)

        stopSecond()
        sigaction(SIGTERM, nil, &current)
        #expect(current.sa_flags == custom.sa_flags)
    }

    @Test func observingTerminationSignalsRestoresThePreviousDispositions() {
        var custom = sigaction()
        custom.__sigaction_u.__sa_handler = SIG_IGN
        custom.sa_flags = SA_RESTART | SA_NODEFER
        sigemptyset(&custom.sa_mask)
        sigaddset(&custom.sa_mask, SIGUSR1)
        var original = sigaction()
        sigaction(SIGTERM, &custom, &original)
        defer { sigaction(SIGTERM, &original, nil) }

        TerminationSignals.observe {}()

        var restored = sigaction()
        sigaction(SIGTERM, nil, &restored)
        #expect(restored.sa_flags == custom.sa_flags)
        #expect(restored.sa_mask == custom.sa_mask)
    }
}

private func makeServerLauncher(
    forceRestartExistingServer: @escaping (_ host: String, _ port: Int, _ stderr: (String) -> Void) -> Bool = {
        _, _, _ in false
    },
    makeServer:
        @escaping (XcodeMCPProxyServerConfiguration) ->
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
    guard case .start(let configuration, let forceRestart) = action else {
        throw UnexpectedServerLaunchAction()
    }
    return (configuration, forceRestart)
}

private struct UnexpectedServerLaunchAction: Error {}

private struct AddressAlreadyInUseError: Error {}

private enum LaunchCleanupFailure: Error, CustomStringConvertible {
    case expected
    var description: String { "gateway cleanup failed" }
}

private enum LaunchWaitFailure: Error, CustomStringConvertible {
    case expected
    var description: String { "listener wait failed" }
}

private final class ShutdownFailingProxyServer: XcodeMCPProxyServer.LaunchServer {
    private let waitFails: Bool
    private let shutdowns = LockedBox(0)

    init(waitFails: Bool) { self.waitFails = waitFails }
    var shutdownCount: Int { shutdowns.snapshot() }

    func start() async throws -> XcodeMCPProxyServer.Endpoint {
        .init(host: "127.0.0.1", port: 9002)
    }

    func waitUntilShutdown() async throws {
        if waitFails { throw LaunchWaitFailure.expected }
    }

    func shutdown() async throws {
        shutdowns.withValue { $0 += 1 }
        throw LaunchCleanupFailure.expected
    }
}

/// Starts only after it is shut down, which ends the start with an error.
private final class StartBlockingProxyServer: XcodeMCPProxyServer.LaunchServer {
    private let stops = AsyncStream<Void>.makeStream()
    private let state = LockedBox((starting: false, shutdowns: 0))
    private let cleanupFails: Bool

    init(cleanupFails: Bool) { self.cleanupFails = cleanupFails }

    var isStarting: Bool { state.snapshot().starting }
    var shutdownCount: Int { state.snapshot().shutdowns }

    func start() async throws -> XcodeMCPProxyServer.Endpoint {
        state.withValue { $0.starting = true }
        for await _ in stops.stream {}
        throw XcodeMCPProxyServer.LifecycleError.shutdownInProgress
    }

    func waitUntilShutdown() async throws {
        Issue.record("wait should not be called when start fails")
    }

    func shutdown() async throws {
        state.withValue { $0.shutdowns += 1 }
        stops.continuation.finish()
        if cleanupFails { throw LaunchCleanupFailure.expected }
    }
}

/// Waits until it is shut down.
private final class SignalStoppedProxyServer: XcodeMCPProxyServer.LaunchServer {
    private let stops = AsyncStream<Void>.makeStream()
    private let shutdowns = LockedBox(0)

    var shutdownCount: Int { shutdowns.snapshot() }

    func start() async throws -> XcodeMCPProxyServer.Endpoint {
        .init(host: "127.0.0.1", port: 9003)
    }

    func waitUntilShutdown() async throws {
        for await _ in stops.stream {}
    }

    func shutdown() async throws {
        shutdowns.withValue { $0 += 1 }
        stops.continuation.finish()
    }
}

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
