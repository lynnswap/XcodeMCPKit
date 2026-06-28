@testable import XcodeMCPProxyKit
import Foundation
import Testing

@Suite
struct StdioAdapterRunnerTests {
    @Test func adapterRunnerPrintsVersionBeforeValidation() async throws {
        let result = await runAdapter(
            arguments: ["xcode-mcp-proxy", "--version", "--config", "/tmp/proxy-config.toml"]
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == ["xcode-mcp-proxy \(XcodeMCPProxyServer.productMetadata.version)"])
        #expect(result.stderr.isEmpty)
    }

    @Test func adapterRunnerPrintsVersionWhenFlagAppearsAsURLValue() async throws {
        let result = await runAdapter(arguments: ["xcode-mcp-proxy", "--url", "--version"])

        #expect(result.exitCode == 0)
        #expect(result.stdout == ["xcode-mcp-proxy \(XcodeMCPProxyServer.productMetadata.version)"])
        #expect(result.stderr.isEmpty)
    }

    @Test func adapterRunnerHelpWinsOverVersion() async throws {
        let result = await runAdapter(arguments: ["xcode-mcp-proxy", "--version", "--help"])

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let line = try #require(result.stdout.first)
        #expect(line.contains("Usage:"))
    }

    @Test func adapterRunnerRewritesURLFlagToStdio() throws {
        let rewritten = try XcodeMCPProxyStdioAdapter.rewriteURLFlagToStdio([
            "xcode-mcp-proxy",
            "--url",
            "http://localhost:8765/mcp",
        ])

        #expect(rewritten == [
            "xcode-mcp-proxy",
            "--stdio",
            "http://localhost:8765/mcp",
        ])
    }

    @Test func adapterRunnerRejectsURLAndStdioTogether() async throws {
        let result = await runAdapter(
            arguments: [
                "xcode-mcp-proxy",
                "--url",
                "http://localhost:8765/mcp",
                "--stdio",
            ]
        )

        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("Use either --url or --stdio (not both)."))
        #expect(result.stderr.contains { $0.contains("Usage:") })
    }

    @Test func adapterRunnerRejectsServerOnlyFlags() async throws {
        let invocations = [
            ["xcode-mcp-proxy", "--listen", "127.0.0.1:9000"],
            ["xcode-mcp-proxy", "--config", "/tmp/proxy-config.toml"],
            ["xcode-mcp-proxy", "--auto-approve"],
        ]

        for arguments in invocations {
            let result = await runAdapter(arguments: arguments)

            #expect(result.exitCode == 1)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr == [
                "This option is only supported by xcode-mcp-proxy-server (proxy server).",
                "Run: xcode-mcp-proxy-server --help",
            ])
        }
    }

    @Test func adapterRunnerRejectsRemovedFlags() async throws {
        let lazyInit = await runAdapter(arguments: ["xcode-mcp-proxy", "--lazy-init"])
        #expect(lazyInit.exitCode == 1)
        #expect(lazyInit.stdout.isEmpty)
        #expect(lazyInit.stderr == [XcodeMCPProxyServer.removedLazyInitializationMessage])

        let xcodePID = await runAdapter(arguments: ["xcode-mcp-proxy", "--xcode-pid", "1234"])
        #expect(xcodePID.exitCode == 1)
        #expect(xcodePID.stdout.isEmpty)
        #expect(xcodePID.stderr == [XcodeMCPProxyServer.removedXcodePIDMessage])
    }

    @Test func adapterLauncherStartsInjectedAdapterFromResolvedEnvironmentURL() async throws {
        let createdAdapter = RecordingLaunchAdapter()
        let captured = LockedBox<(url: URL?, timeout: TimeInterval?)>((nil, nil))
        let launcher = XcodeMCPProxyStdioAdapter.Launcher(
            dependencies: .init(
                makeLogSink: {
                    XcodeMCPProxyStdioAdapter.LogSink(
                        error: { _ in },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { endpoint, timeout, _, _ in
                    captured.withValue { value in
                        value = (endpoint.url, timeout)
                    }
                    return createdAdapter
                },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await launcher.run(
            arguments: ["xcode-mcp-proxy", "--request-timeout", "12"],
            environment: [
                "XCODE_MCP_PROXY_ENDPOINT": "http://localhost:9001/mcp"
            ],
            stdout: { _ in }
        )

        #expect(exitCode == 0)
        let values = captured.snapshot()
        #expect(values.url?.absoluteString == "http://localhost:9001/mcp")
        #expect(values.timeout == 12)
        #expect(await createdAdapter.startCount() == 1)
        #expect(await createdAdapter.waitCount() == 1)
    }

    @Test func adapterRunnerPrintsUsageForHelp() async throws {
        let result = await runAdapter(arguments: ["xcode-mcp-proxy", "--help"])

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.first?.contains("Usage:") == true)
    }

    @Test func adapterLaunchPlanTreatsHelpOnlyAsTopLevelFlag() throws {
        let plan = try XcodeMCPProxyStdioAdapter.resolveLaunchPlan(
            arguments: [
                "xcode-mcp-proxy",
                "--request-timeout", "--help",
            ],
            environment: [:]
        )

        #expect(plan.action == .start)
        #expect(plan.options.requestTimeout == 300)
    }

    @Test func adapterLaunchPlanRejectsServerOnlyFlagsAfterMalformedTimeoutValue() throws {
        do {
            _ = try XcodeMCPProxyStdioAdapter.resolveLaunchPlan(
                arguments: [
                    "xcode-mcp-proxy",
                    "--request-timeout", "--listen",
                    "127.0.0.1:9000",
                ],
                environment: [:]
            )
            Issue.record("expected server-only flag to be rejected")
        } catch let error as XcodeMCPProxyStdioAdapter.LaunchResolutionError {
            #expect(
                error.description
                    == "This option is only supported by xcode-mcp-proxy-server (proxy server)."
            )
            #expect(error.presentation == .serverOnlyFlagHint)
        }
    }

    @Test func adapterLaunchPlanRejectsRemovedURLHelperAfterMalformedTimeoutValue() throws {
        do {
            _ = try XcodeMCPProxyStdioAdapter.resolveLaunchPlan(
                arguments: [
                    "xcode-mcp-proxy",
                    "--request-timeout", "--print-url",
                ],
                environment: [:]
            )
            Issue.record("expected removed URL helper to be rejected")
        } catch let error as XcodeMCPProxyStdioAdapter.LaunchResolutionError {
            #expect(error.description.contains("url helper mode was removed"))
            #expect(error.presentation == .plain)
        }
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

    func start() async {
        started += 1
    }

    func wait() async {
        waited += 1
    }

    func startCount() -> Int {
        started
    }

    func waitCount() -> Int {
        waited
    }
}
