import XcodeMCPProxyKit
import Foundation
import Testing

@Suite
struct CLICommandTests {
    @Test func cliCommandPrintsVersionWithoutCreatingLogSink() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                makeLogSink: {
                    Issue.record("makeLogSink should not be called for --version")
                    return XcodeMCPProxyCLICommand.LogSink(
                        error: { _ in },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { _, _, _, _ in
                    RecordingCLIAdapter()
                },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy", "--version", "--config", "/tmp/proxy-config.toml"],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(output.snapshot() == ["xcode-mcp-proxy \(XcodeMCPProxyServer.productMetadata.version)"])
    }

    @Test func cliCommandPrintsVersionWhenFlagAppearsAsURLValue() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                makeLogSink: {
                    Issue.record("makeLogSink should not be called for --version")
                    return XcodeMCPProxyCLICommand.LogSink(
                        error: { _ in },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { _, _, _, _ in
                    RecordingCLIAdapter()
                },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy", "--url", "--version"],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(output.snapshot() == ["xcode-mcp-proxy \(XcodeMCPProxyServer.productMetadata.version)"])
    }

    @Test func cliCommandHelpWinsOverVersion() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                makeLogSink: {
                    Issue.record("makeLogSink should not be called for --help")
                    return XcodeMCPProxyCLICommand.LogSink(
                        error: { _ in },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { _, _, _, _ in
                    RecordingCLIAdapter()
                },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy", "--version", "--help"],
            environment: [:]
        )

        #expect(exitCode == 0)
        let line = try #require(output.snapshot().first)
        #expect(line.contains("Usage:"))
    }

    @Test func cliCommandRewritesURLFlagToStdio() throws {
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

    @Test func cliCommandDelegatesLaunchToProxyKit() async throws {
        let output = CapturedLines()
        let received = LockedBox<(args: [String], environment: [String: String])?>(
            nil
        )
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                launch: { args, environment, stdout in
                    received.withValue { value in
                        value = (args, environment)
                    }
                    stdout("delegated")
                    return 42
                }
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy", "--version"],
            environment: ["XCODE_MCP_PROXY_ENDPOINT": "http://localhost:9001/mcp"]
        )

        #expect(exitCode == 42)
        #expect(received.snapshot()?.args == ["xcode-mcp-proxy", "--version"])
        #expect(
            received.snapshot()?.environment["XCODE_MCP_PROXY_ENDPOINT"]
                == "http://localhost:9001/mcp"
        )
        #expect(output.snapshot() == ["delegated"])
    }

    @Test func cliCommandRejectsURLAndStdioTogether() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { output.append($0) },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { _, _, _, _ in RecordingCLIAdapter() },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await command.run(
            args: [
                "xcode-mcp-proxy",
                "--url",
                "http://localhost:8765/mcp",
                "--stdio",
            ],
            environment: [:]
        )

        #expect(exitCode == 1)
        let lines = output.snapshot()
        #expect(lines.contains("Use either --url or --stdio (not both)."))
        #expect(lines.contains { $0.contains("Usage:") })
    }

    @Test func cliCommandRejectsServerOnlyFlags() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { output.append($0) },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { _, _, _, _ in RecordingCLIAdapter() },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy", "--listen", "127.0.0.1:9000"],
            environment: [:]
        )

        #expect(exitCode == 1)
        #expect(output.snapshot() == [
            "This option is only supported by xcode-mcp-proxy-server (proxy server).",
            "Run: xcode-mcp-proxy-server --help",
        ])
    }

    @Test func cliCommandRejectsConfigFlag() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { output.append($0) },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { _, _, _, _ in RecordingCLIAdapter() },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy", "--config", "/tmp/proxy-config.toml"],
            environment: [:]
        )

        #expect(exitCode == 1)
        #expect(output.snapshot() == [
            "This option is only supported by xcode-mcp-proxy-server (proxy server).",
            "Run: xcode-mcp-proxy-server --help",
        ])
    }

    @Test func cliCommandRejectsAutoApproveFlag() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { output.append($0) },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { _, _, _, _ in RecordingCLIAdapter() },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy", "--auto-approve"],
            environment: [:]
        )

        #expect(exitCode == 1)
        #expect(output.snapshot() == [
            "This option is only supported by xcode-mcp-proxy-server (proxy server).",
            "Run: xcode-mcp-proxy-server --help",
        ])
    }

    @Test func cliCommandRejectsRemovedLazyInitFlag() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { output.append($0) },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { _, _, _, _ in RecordingCLIAdapter() },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy", "--lazy-init"],
            environment: [:]
        )

        #expect(exitCode == 1)
        #expect(output.snapshot() == [CLIParser.removedLazyInitMessage])
    }

    @Test func cliCommandRejectsRemovedXcodePIDFlag() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { output.append($0) },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { _, _, _, _ in RecordingCLIAdapter() },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy", "--xcode-pid", "1234"],
            environment: [:]
        )

        #expect(exitCode == 1)
        #expect(output.snapshot() == [CLIParser.removedXcodePIDMessage])
    }

    @Test func cliCommandBuildsAdapterFromResolvedEnvironmentURL() async throws {
        let createdAdapter = RecordingCLIAdapter()
        let captured = LockedBox<(url: URL?, timeout: TimeInterval?)>((nil, nil))
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
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

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy", "--request-timeout", "12"],
            environment: [
                "XCODE_MCP_PROXY_ENDPOINT": "http://localhost:9001/mcp"
            ]
        )

        #expect(exitCode == 0)
        let values = captured.snapshot()
        #expect(values.url?.absoluteString == "http://localhost:9001/mcp")
        #expect(values.timeout == 12)
        #expect(await createdAdapter.startCount() == 1)
        #expect(await createdAdapter.waitCount() == 1)
    }

    @Test func cliCommandPrintsUsageForHelp() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { _ in },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { _, _, _, _ in RecordingCLIAdapter() },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy", "--help"],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(output.snapshot().first?.contains("Usage:") == true)
    }

    @Test func cliCommandCreatesLiveLogSinkAfterBootstrapping() async throws {
        let order = LockedBox<[String]>([])
        let output = CapturedLines()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in
                    order.withValue { $0.append("bootstrap") }
                },
                stdout: { _ in },
                makeLogSink: {
                    order.withValue { $0.append("makeLogSink") }
                    return XcodeMCPProxyCLICommand.LogSink(
                        error: { output.append($0) },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { _, _, _, _ in RecordingCLIAdapter() },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy", "--print-url"],
            environment: [:]
        )

        #expect(exitCode == 1)
        #expect(order.snapshot() == ["bootstrap", "makeLogSink"])
        #expect(output.snapshot().first?.contains("url helper mode was removed") == true)
    }

    @Test func cliCommandTreatsHelpOnlyAsTopLevelFlag() async throws {
        let usage = CapturedLines()
        let errors = CapturedLines()
        let createdAdapter = RecordingCLIAdapter()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { usage.append($0) },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { errors.append($0) },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { _, _, _, _ in createdAdapter },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await command.run(
            args: [
                "xcode-mcp-proxy",
                "--request-timeout", "--help",
            ],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(usage.snapshot().isEmpty)
        #expect(errors.snapshot().isEmpty)
        #expect(await createdAdapter.startCount() == 1)
        #expect(await createdAdapter.waitCount() == 1)
    }

    @Test func cliCommandStillRejectsServerOnlyFlagsAfterMalformedTimeoutValue() async throws {
        let usage = CapturedLines()
        let errors = CapturedLines()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { usage.append($0) },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { errors.append($0) },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { _, _, _, _ in RecordingCLIAdapter() },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await command.run(
            args: [
                "xcode-mcp-proxy",
                "--request-timeout", "--listen",
                "127.0.0.1:9000",
            ],
            environment: [:]
        )

        #expect(exitCode == 1)
        #expect(usage.snapshot().isEmpty)
        #expect(errors.snapshot() == [
            "This option is only supported by xcode-mcp-proxy-server (proxy server).",
            "Run: xcode-mcp-proxy-server --help",
        ])
    }

    @Test func cliCommandStillRejectsRemovedURLHelperAfterMalformedTimeoutValue() async throws {
        let usage = CapturedLines()
        let errors = CapturedLines()
        let command = XcodeMCPProxyCLICommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { usage.append($0) },
                makeLogSink: {
                    XcodeMCPProxyCLICommand.LogSink(
                        error: { errors.append($0) },
                        info: { _, _ in }
                    )
                },
                makeAdapter: { _, _, _, _ in RecordingCLIAdapter() },
                input: .standardInput,
                output: .standardOutput
            )
        )

        let exitCode = await command.run(
            args: [
                "xcode-mcp-proxy",
                "--request-timeout", "--print-url",
            ],
            environment: [:]
        )

        #expect(exitCode == 1)
        #expect(usage.snapshot().isEmpty)
        #expect(
            errors.snapshot().first?.contains("url helper mode was removed") == true
        )
    }
}

private actor RecordingCLIAdapter: CLICommandAdapter {
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
