@testable import XcodeMCPProxyKit
import Foundation
import Testing

@Suite
struct StdioAdapterRunnerTests {
    @Test func adapterRunnerPrintsVersion() async {
        let result = await runAdapter(arguments: ["xcode-mcp-proxy", "--version"])

        #expect(result.exitCode == 0)
        #expect(result.stdout == [XcodeMCPProxyServer.productMetadata.version])
        #expect(result.stderr.isEmpty)
    }

    @Test func adapterRunnerPrintsGeneratedHelp() async {
        let result = await runAdapter(arguments: ["xcode-mcp-proxy", "--help"])

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.first?.contains("USAGE: xcode-mcp-proxy") == true)
    }

    @Test func adapterRunnerRejectsUnsupportedOptionsThroughArgumentParser() async {
        let invocations = [
            ["xcode-mcp-proxy", "--stdio"],
            ["xcode-mcp-proxy", "--lazy-init"],
            ["xcode-mcp-proxy", "--xcode-pid", "1234"],
            ["xcode-mcp-proxy", "--listen", "127.0.0.1:9000"],
            ["xcode-mcp-proxy", "--config", "/tmp/proxy-config.toml"],
            ["xcode-mcp-proxy", "--auto-approve"],
        ]

        for arguments in invocations {
            let result = await runAdapter(arguments: arguments)
            #expect(result.exitCode == 64)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.first?.contains("Unknown option") == true)
        }
    }

    @Test func adapterLauncherStartsInjectedAdapterWithDurationConfiguration() async throws {
        let createdAdapter = RecordingLaunchAdapter()
        let captured = LockedBox<XcodeMCPProxyStdioAdapterConfiguration?>(nil)
        let launcher = XcodeMCPProxyStdioAdapter.Launcher(
            dependencies: .init(
                makeAdapter: { configuration, _, _ in
                    captured.withValue { $0 = configuration }
                    return createdAdapter
                },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await launcher.run(
            arguments: [
                "xcode-mcp-proxy",
                "--url", "http://localhost:9001/mcp",
                "--request-timeout", "12.5",
            ],
            environment: [:],
            stdout: { _ in },
            stderr: { _ in }
        )

        #expect(exitCode == 0)
        #expect(captured.snapshot()?.endpoint == .url(URL(string: "http://localhost:9001/mcp")!))
        #expect(captured.snapshot()?.requestTimeout == .milliseconds(12_500))
        #expect(await createdAdapter.startCount() == 1)
        #expect(await createdAdapter.waitCount() == 1)
    }

    @Test func adapterRunnerMapsZeroTimeoutToDisabled() async {
        let createdAdapter = RecordingLaunchAdapter()
        let captured = LockedBox<XcodeMCPProxyStdioAdapterConfiguration?>(nil)
        let launcher = XcodeMCPProxyStdioAdapter.Launcher(
            dependencies: .init(
                makeAdapter: { configuration, _, _ in
                    captured.withValue { $0 = configuration }
                    return createdAdapter
                },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await launcher.run(
            arguments: ["xcode-mcp-proxy", "--request-timeout", "0"],
            environment: [:],
            stdout: { _ in },
            stderr: { _ in }
        )

        #expect(exitCode == 0)
        #expect(captured.snapshot()?.requestTimeout == nil)
    }

    @Test func adapterRunnerRejectsInvalidTimeouts() async {
        for value in ["-1", "nan", "inf", "not-a-number"] {
            let result = await runAdapter(
                arguments: ["xcode-mcp-proxy", "--request-timeout", value]
            )
            #expect(result.exitCode == 64)
            #expect(result.stdout.isEmpty)
            #expect(
                result.stderr.first?.contains(
                    "--request-timeout must be a finite number greater than or equal to zero"
                ) == true
            )
        }
    }

    @Test func adapterRunnerPrintsUsageForHelp() async {
        let result = await runAdapter(arguments: ["xcode-mcp-proxy", "--help"])

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.first?.contains("--url <url>") == true)
        #expect(result.stdout.first?.contains("--stdio") == false)
    }
}

private func runAdapter(
    arguments: [String],
    environment: [String: String] = [:]
) async -> (exitCode: Int32, stdout: [String], stderr: [String]) {
    let output = CapturedLines()
    let errors = CapturedLines()
    let exitCode = await XcodeMCPProxyStdioAdapter.run(
        arguments: arguments,
        environment: environment,
        stdout: { output.append($0) },
        stderr: { errors.append($0) }
    )
    return (exitCode, output.snapshot(), errors.snapshot())
}

private actor RecordingLaunchAdapter: XcodeMCPProxyStdioAdapter.LaunchAdapter {
    private var started = 0
    private var waited = 0

    func start() async throws {
        started += 1
    }

    func waitUntilStopped() async {
        waited += 1
    }

    func startCount() -> Int { started }
    func waitCount() -> Int { waited }
}
