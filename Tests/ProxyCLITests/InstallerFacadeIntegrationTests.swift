import Foundation
import Testing
@testable import XcodeMCPProxyKit

@Suite(.serialized)
struct InstallerFacadeIntegrationTests {
    @Test func installerFacadeDryRunPrintsInstallPlan() throws {
        let tempDir = try TemporaryDirectory()
        defer { tempDir.cleanup() }

        let output = CapturedLines()
        let bindir = tempDir.url.appendingPathComponent("bin", isDirectory: true)
        try XcodeMCPProxyInstaller(
            configuration: .init(prefix: nil, binaryDirectory: bindir.path, dryRun: true)
        ).install(
            executableURL: tempDir.url.appendingPathComponent("xcode-mcp-proxy-install"),
            fileManager: .default,
            buildProducts: { _, _ in },
            stdout: { output.append($0) }
        )

        let expectedProxy = bindir.appendingPathComponent("xcode-mcp-proxy").path
        let expectedServer = bindir.appendingPathComponent("xcode-mcp-proxy-server").path
        #expect(output.snapshot() == [
            "Would create: \(bindir.path)",
            "Would install: \(expectedProxy)",
            "Would install: \(expectedServer)",
        ])
    }

    @Test func installerFacadeCopiesFakeBinariesIntoBindir() throws {
        let sourceDir = try TemporaryDirectory()
        defer { sourceDir.cleanup() }
        let installDir = try TemporaryDirectory()
        defer { installDir.cleanup() }

        let installerURL = sourceDir.url.appendingPathComponent("xcode-mcp-proxy-install")
        let proxyURL = sourceDir.url.appendingPathComponent("xcode-mcp-proxy")
        let serverURL = sourceDir.url.appendingPathComponent("xcode-mcp-proxy-server")
        try Data("installer".utf8).write(to: installerURL)
        try Data("proxy".utf8).write(to: proxyURL)
        try Data("server".utf8).write(to: serverURL)

        let output = CapturedLines()
        let buildCalls = Counter()
        try XcodeMCPProxyInstaller(
            configuration: .init(prefix: nil, binaryDirectory: installDir.url.path, dryRun: false)
        ).install(
            executableURL: installerURL,
            fileManager: .default,
            buildProducts: { _, _ in
                buildCalls.increment()
            },
            stdout: { output.append($0) }
        )

        #expect(buildCalls.value == 0)
        #expect(
            try String(
                contentsOf: installDir.url.appendingPathComponent("xcode-mcp-proxy"),
                encoding: .utf8
            ) == "proxy"
        )
        #expect(
            try String(
                contentsOf: installDir.url.appendingPathComponent("xcode-mcp-proxy-server"),
                encoding: .utf8
            ) == "server"
        )
        #expect(output.snapshot().count == 2)
    }
}

private final class Counter {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
