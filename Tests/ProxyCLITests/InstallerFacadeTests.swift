import Foundation
import Testing
@testable import XcodeMCPProxyKit

@Suite
struct InstallerFacadeTests {
    @Test func installerRunnerPrintsVersionBeforeValidation() throws {
        let result = runInstaller(
            arguments: ["xcode-mcp-proxy-install", "--version", "--unknown"]
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == ["xcode-mcp-proxy-install \(XcodeMCPProxyServer.productMetadata.version)"])
        #expect(result.stderr.isEmpty)
    }

    @Test func installerRunnerPrintsVersionWhenFlagAppearsAsBindirValue() throws {
        let result = runInstaller(
            arguments: ["xcode-mcp-proxy-install", "--bindir", "--version"]
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == ["xcode-mcp-proxy-install \(XcodeMCPProxyServer.productMetadata.version)"])
        #expect(result.stderr.isEmpty)
    }

    @Test func installerRunnerHelpWinsOverVersion() throws {
        let result = runInstaller(
            arguments: ["xcode-mcp-proxy-install", "--version", "--help"]
        )

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let line = try #require(result.stdout.first)
        #expect(line.contains("Usage:"))
    }

    @Test func installerLaunchPlanParsesOptionsAndPrefersBindir() throws {
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
        #expect(options.binaryDirectory == "/tmp/bin")
        #expect(options.dryRun == true)
        #expect(
            XcodeMCPProxyInstaller.resolveBinDirectory(
                prefix: options.prefix,
                binaryDirectory: options.binaryDirectory
            ).path == "/tmp/bin"
        )
    }

    @Test func installerFacadeExpandsHomeRelativePaths() throws {
        let home = NSHomeDirectory()
        let resolved = XcodeMCPProxyInstaller.resolveBinDirectory(
            prefix: "~/custom",
            binaryDirectory: nil
        )

        #expect(resolved.path == "\(home)/custom/bin")
    }

    @Test func installerFacadeFindsRepositoryRootFromBuildProducts() throws {
        let executableURL = URL(fileURLWithPath: "/tmp/repo/.build/debug/xcode-mcp-proxy-install")
        let root = XcodeMCPProxyInstaller.repositoryRoot(from: executableURL)

        #expect(root?.path == "/tmp/repo")
    }

    @Test func installerFacadeReportsMissingBinary() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let executableURL = tempDir.appendingPathComponent("xcode-mcp-proxy-install")

        #expect(throws: XcodeMCPProxyInstaller.Error.self) {
            try XcodeMCPProxyInstaller(
                configuration: .init(prefix: nil, binaryDirectory: tempDir.path, dryRun: false)
            ).install(
                executableURL: executableURL,
                fileManager: .default,
                buildProducts: { _, _ in },
                stdout: { _ in }
            )
        }
    }

    @Test func installerRunnerPrintsUsageForHelp() throws {
        let result = runInstaller(arguments: ["xcode-mcp-proxy-install", "--help"])

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.first?.contains("Usage:") == true)
    }

    @Test func installerRunnerTreatsHelpOnlyAsTopLevelFlag() throws {
        let result = runInstaller(
            arguments: [
                "xcode-mcp-proxy-install",
                "--bindir", "--help",
                "--dry-run",
            ]
        )

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.isEmpty == false)
        #expect(result.stdout.first?.contains("Usage:") == false)
    }

    @Test func installerRunnerPreservesExplicitHelpBeforeParseErrors() throws {
        let result = runInstaller(
            arguments: [
                "xcode-mcp-proxy-install",
                "--help",
                "--unknown",
            ]
        )

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.first?.contains("Usage:") == true)
    }

    @Test func installerPlanUsesBinaryListAndBindirPriority() throws {
        let executableURL = URL(fileURLWithPath: "/tmp/repo/.build/release/xcode-mcp-proxy-install")
        let installer = XcodeMCPProxyInstaller(
            configuration: .init(prefix: "/tmp/prefix", binaryDirectory: "/tmp/bin", dryRun: true)
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

private func runInstaller(
    arguments: [String],
    environment: [String: String] = [:]
) -> (exitCode: Int32, stdout: [String], stderr: [String]) {
    let output = CapturedLines()
    let errors = CapturedLines()
    let exitCode = XcodeMCPProxyInstaller.run(
        arguments: arguments,
        environment: environment,
        stdout: { output.append($0) },
        stderr: { errors.append($0) }
    )
    return (exitCode, output.snapshot(), errors.snapshot())
}
