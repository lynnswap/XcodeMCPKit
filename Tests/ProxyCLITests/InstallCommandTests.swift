import Foundation
import Testing
import XcodeMCPProxyKit

@Suite
struct InstallCommandTests {
    @Test func installCommandPrintsVersionWithoutResolvingExecutableURL() throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyInstallCommand(
            dependencies: .init(
                stdout: { output.append($0) },
                stderr: { _ in },
                executableURL: {
                    Issue.record("executableURL should not be called for --version")
                    return nil
                },
                install: { _, _, _ in
                    Issue.record("install should not be called for --version")
                }
            )
        )

        let exitCode = command.run(
            args: ["xcode-mcp-proxy-install", "--version", "--unknown"],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(output.snapshot() == ["xcode-mcp-proxy-install \(XcodeMCPProxyServer.productMetadata.version)"])
    }

    @Test func installCommandPrintsVersionWhenFlagAppearsAsBindirValue() throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyInstallCommand(
            dependencies: .init(
                stdout: { output.append($0) },
                stderr: { _ in },
                executableURL: {
                    Issue.record("executableURL should not be called for --version")
                    return nil
                },
                install: { _, _, _ in
                    Issue.record("install should not be called for --version")
                }
            )
        )

        let exitCode = command.run(
            args: ["xcode-mcp-proxy-install", "--bindir", "--version"],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(output.snapshot() == ["xcode-mcp-proxy-install \(XcodeMCPProxyServer.productMetadata.version)"])
    }

    @Test func installCommandHelpWinsOverVersion() throws {
        let output = CapturedLines()
        let errors = CapturedLines()
        let command = XcodeMCPProxyInstallCommand(
            dependencies: .init(
                stdout: { output.append($0) },
                stderr: { errors.append($0) },
                executableURL: {
                    Issue.record("executableURL should not be called for --help")
                    return nil
                },
                install: { _, _, _ in
                    Issue.record("install should not be called for --help")
                }
            )
        )

        let exitCode = command.run(
            args: ["xcode-mcp-proxy-install", "--version", "--help"],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(errors.snapshot().isEmpty)
        let line = try #require(output.snapshot().first)
        #expect(line.contains("Usage:"))
    }

    @Test func installCommandParsesOptionsAndPrefersBindir() throws {
        let plan = try XcodeMCPProxyInstaller.resolveLaunchPlan(
            arguments: [
                "xcode-mcp-proxy-install",
                "--prefix", "/tmp/prefix",
                "--bindir", "/tmp/bin",
                "--dry-run",
            ],
            environment: [:]
        )
        let options = try #require(plan.configuration)

        #expect(options.prefix == "/tmp/prefix")
        #expect(options.bindir == "/tmp/bin")
        #expect(options.dryRun == true)
        #expect(
            XcodeMCPProxyInstaller.resolveBinDirectory(
                prefix: options.prefix,
                bindir: options.bindir
            ).path == "/tmp/bin"
        )
    }

    @Test func installCommandDelegatesLaunchToProxyKit() throws {
        let output = CapturedLines()
        let errors = CapturedLines()
        let received = LockedBox<(args: [String], environment: [String: String])?>(
            nil
        )
        let command = XcodeMCPProxyInstallCommand(
            dependencies: .init(
                stdout: { output.append($0) },
                stderr: { errors.append($0) },
                launch: { args, environment, stdout, _ in
                    received.withValue { value in
                        value = (args, environment)
                    }
                    stdout("delegated")
                    return 24
                }
            )
        )

        let exitCode = command.run(
            args: ["xcode-mcp-proxy-install", "--dry-run"],
            environment: ["BINDIR": "/tmp/bin"]
        )

        #expect(exitCode == 24)
        #expect(received.snapshot()?.args == ["xcode-mcp-proxy-install", "--dry-run"])
        #expect(received.snapshot()?.environment["BINDIR"] == "/tmp/bin")
        #expect(output.snapshot() == ["delegated"])
        #expect(errors.snapshot().isEmpty)
    }

    @Test func installCommandExpandsHomeRelativePaths() throws {
        let home = NSHomeDirectory()
        let resolved = XcodeMCPProxyInstaller.resolveBinDirectory(
            prefix: "~/custom",
            bindir: nil
        )

        #expect(resolved.path == "\(home)/custom/bin")
    }

    @Test func installCommandFindsRepositoryRootFromBuildProducts() throws {
        let executableURL = URL(fileURLWithPath: "/tmp/repo/.build/debug/xcode-mcp-proxy-install")
        let root = XcodeMCPProxyInstaller.repositoryRoot(from: executableURL)

        #expect(root?.path == "/tmp/repo")
    }

    @Test func installCommandReportsMissingBinary() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let executableURL = tempDir.appendingPathComponent("xcode-mcp-proxy-install")

        #expect(throws: XcodeMCPProxyInstaller.Error.self) {
            try XcodeMCPProxyInstaller(
                configuration: .init(prefix: nil, bindir: tempDir.path, dryRun: false)
            ).install(
                executableURL: executableURL,
                fileManager: .default,
                buildProducts: { _, _ in },
                stdout: { _ in }
            )
        }
    }

    @Test func installCommandPrintsUsageForHelp() throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyInstallCommand(
            dependencies: .init(
                stdout: { output.append($0) },
                stderr: { _ in },
                executableURL: { nil },
                install: { _, _, _ in }
            )
        )

        let exitCode = command.run(
            args: ["xcode-mcp-proxy-install", "--help"],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(output.snapshot().first?.contains("Usage:") == true)
    }

    @Test func installCommandTreatsHelpOnlyAsTopLevelFlag() throws {
        let output = CapturedLines()
        let errors = CapturedLines()
        let command = XcodeMCPProxyInstallCommand(
            dependencies: .init(
                stdout: { output.append($0) },
                stderr: { errors.append($0) },
                executableURL: { URL(fileURLWithPath: "/tmp/xcode-mcp-proxy-install") },
                install: { configuration, executableURL, stdout in
                    try XcodeMCPProxyInstaller(configuration: configuration).install(
                        executableURL: executableURL,
                        fileManager: .default,
                        buildProducts: { _, _ in },
                        stdout: stdout
                    )
                }
            )
        )

        let exitCode = command.run(
            args: [
                "xcode-mcp-proxy-install",
                "--bindir", "--help",
                "--dry-run",
            ],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(errors.snapshot().isEmpty)
        #expect(output.snapshot().isEmpty == false)
        #expect(output.snapshot().first?.contains("Usage:") == false)
    }

    @Test func installCommandPreservesExplicitHelpBeforeParseErrors() throws {
        let output = CapturedLines()
        let errors = CapturedLines()
        let command = XcodeMCPProxyInstallCommand(
            dependencies: .init(
                stdout: { output.append($0) },
                stderr: { errors.append($0) },
                executableURL: { nil },
                install: { _, _, _ in }
            )
        )

        let exitCode = command.run(
            args: [
                "xcode-mcp-proxy-install",
                "--help",
                "--unknown",
            ],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(errors.snapshot().isEmpty)
        #expect(output.snapshot().first?.contains("Usage:") == true)
    }

    @Test func installerPlanUsesBinaryListAndBindirPriority() throws {
        let executableURL = URL(fileURLWithPath: "/tmp/repo/.build/release/xcode-mcp-proxy-install")
        let installer = XcodeMCPProxyInstaller(
            configuration: .init(prefix: "/tmp/prefix", bindir: "/tmp/bin", dryRun: true)
        )
        let plan = installer.plan(executableURL: executableURL)

        #expect(plan.binDirectory.path == "/tmp/bin")
        #expect(plan.dryRun)
        #expect(plan.binaries.map(\.name) == XcodeMCPProxyInstaller.binaryNames)
        #expect(plan.binaries.map(\.destinationURL.lastPathComponent) == [
            "xcode-mcp-proxy",
            "xcode-mcp-proxy-server",
        ])
    }
}
