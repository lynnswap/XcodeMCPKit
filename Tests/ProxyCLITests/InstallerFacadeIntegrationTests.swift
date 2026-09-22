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

    @Test func replacesExistingExecutablesAfterPreparingTheirPermissions() throws {
        let source = try TemporaryDirectory()
        defer { source.cleanup() }
        let destination = try TemporaryDirectory()
        defer { destination.cleanup() }
        try writeExecutables(in: source.url, output: "new", permissions: 0o444)
        try writeExecutables(in: destination.url, output: "old")

        try install(from: source.url, to: destination.url)

        for name in XcodeMCPProxyInstaller.binaryNames {
            let executable = destination.url.appendingPathComponent(name)
            #expect(try runExecutable(executable) == "new")
            #expect(try FileManager.default.attributesOfItem(atPath: executable.path)[.posixPermissions] as? Int == 0o755)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.url.path).sorted()
            == XcodeMCPProxyInstaller.binaryNames.sorted())
    }

    @Test(arguments: [false, true])
    func installingIntoTheSourceDirectoryPreservesExecutables(useDirectorySymlink: Bool) throws {
        let source = try TemporaryDirectory()
        defer { source.cleanup() }
        let aliases = try TemporaryDirectory()
        defer { aliases.cleanup() }
        try writeExecutables(in: source.url, output: "source")
        let destination = useDirectorySymlink ? aliases.url.appendingPathComponent("bin") : source.url
        if useDirectorySymlink {
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source.url)
        }

        try install(from: source.url, to: destination)

        for name in XcodeMCPProxyInstaller.binaryNames {
            #expect(try runExecutable(source.url.appendingPathComponent(name)) == "source")
        }
    }

    @Test func sourceAndDestinationFileAliasesPreserveTheOriginalFiles() throws {
        let source = try TemporaryDirectory()
        defer { source.cleanup() }
        let destination = try TemporaryDirectory()
        defer { destination.cleanup() }
        let originals = try TemporaryDirectory()
        defer { originals.cleanup() }
        try writeExecutables(in: originals.url, output: "original")
        for name in XcodeMCPProxyInstaller.binaryNames {
            let original = originals.url.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(
                at: source.url.appendingPathComponent(name),
                withDestinationURL: original
            )
            try FileManager.default.createSymbolicLink(
                at: destination.url.appendingPathComponent(name),
                withDestinationURL: original
            )
        }

        try install(from: source.url, to: destination.url)

        for name in XcodeMCPProxyInstaller.binaryNames {
            #expect(try runExecutable(originals.url.appendingPathComponent(name)) == "original")
            #expect(try runExecutable(destination.url.appendingPathComponent(name)) == "original")
            #expect(try FileManager.default.attributesOfItem(
                atPath: destination.url.appendingPathComponent(name).path
            )[.type] as? FileAttributeType == .typeRegular)
        }
    }

    @Test func stagingFailurePreservesBothInstalledExecutablesAndRemovesPartialCopies() throws {
        let source = try TemporaryDirectory()
        defer { source.cleanup() }
        let destination = try TemporaryDirectory()
        defer { destination.cleanup() }
        try writeExecutables(in: source.url, output: "new")
        try writeExecutables(in: destination.url, output: "old")
        let fileManager = FailingInstallFileManager(failCopyNamed: "xcode-mcp-proxy-server")

        let error = try #require(throws: XcodeMCPProxyInstaller.Error.self) {
            try install(from: source.url, to: destination.url, fileManager: fileManager)
        }

        #expect(error.description.contains("injected copy failure"))
        #expect(error.description.contains("Installed: none"))
        for name in XcodeMCPProxyInstaller.binaryNames {
            #expect(try runExecutable(destination.url.appendingPathComponent(name)) == "old")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.url.path).sorted()
            == XcodeMCPProxyInstaller.binaryNames.sorted())
    }

    @Test(arguments: [false, true])
    func replacementFailureReportsPartialInstallAndCleanupFailure(failCleanup: Bool) throws {
        let source = try TemporaryDirectory()
        defer { source.cleanup() }
        let destination = try TemporaryDirectory()
        defer { destination.cleanup() }
        try writeExecutables(in: source.url, output: "new")
        let proxy = destination.url.appendingPathComponent("xcode-mcp-proxy")
        let server = destination.url.appendingPathComponent("xcode-mcp-proxy-server")
        try Data("old".utf8).write(to: proxy)
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: false)
        let marker = server.appendingPathComponent("untouched")
        try Data("existing directory".utf8).write(to: marker)
        let output = CapturedLines()

        let error = try #require(throws: XcodeMCPProxyInstaller.Error.self) {
            try install(
                from: source.url,
                to: destination.url,
                fileManager: FailingInstallFileManager(failCleanup: failCleanup),
                stdout: { output.append($0) }
            )
        }

        #expect(error.description.contains("Failed to install xcode-mcp-proxy-server"))
        #expect(error.description.contains("Installed: \(proxy.path)\nNot installed: \(server.path)"))
        #expect(error.description.contains("injected cleanup failure") == failCleanup)
        #expect(try runExecutable(proxy) == "new")
        #expect(try String(contentsOf: marker, encoding: .utf8) == "existing directory")
        #expect(output.snapshot() == ["Installed xcode-mcp-proxy to \(proxy.path)"])
        let stagingDirectories = try FileManager.default.contentsOfDirectory(
            at: destination.url,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".xcode-mcp-install-") }
        #expect(stagingDirectories.count == (failCleanup ? 1 : 0))
        if let staging = stagingDirectories.first {
            #expect(error.description.contains(destination.url.appendingPathComponent(staging.lastPathComponent).path))
            #expect(try runExecutable(staging.appendingPathComponent("xcode-mcp-proxy-server")) == "new")
        }
    }

    @Test func cleanupFailureReportsThatBothExecutablesWereInstalled() throws {
        let source = try TemporaryDirectory()
        defer { source.cleanup() }
        let destination = try TemporaryDirectory()
        defer { destination.cleanup() }
        try writeExecutables(in: source.url, output: "new")

        let error = try #require(throws: XcodeMCPProxyInstaller.Error.self) {
            try install(
                from: source.url,
                to: destination.url,
                fileManager: FailingInstallFileManager(failCleanup: true)
            )
        }

        #expect(error.description.contains("injected cleanup failure"))
        #expect(error.description.contains("Not installed: none"))
        #expect(!error.description.contains("Failed to install"))
        for name in XcodeMCPProxyInstaller.binaryNames {
            #expect(try runExecutable(destination.url.appendingPathComponent(name)) == "new")
        }
    }
}

private func install(
    from source: URL,
    to destination: URL,
    fileManager: FileManager = .default,
    stdout: (String) -> Void = { _ in }
) throws {
    try XcodeMCPProxyInstaller(configuration: .init(binaryDirectory: destination.path)).install(
        executableURL: source.appendingPathComponent("xcode-mcp-proxy-install"),
        fileManager: fileManager,
        buildProducts: { _, _ in },
        stdout: stdout
    )
}

private func writeExecutables(in directory: URL, output: String, permissions: Int = 0o755) throws {
    for name in XcodeMCPProxyInstaller.binaryNames {
        let executable = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nprintf '%s' '\(output)'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: executable.path)
    }
}

private func runExecutable(_ executable: URL) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return String(decoding: output, as: UTF8.self)
}

private final class FailingInstallFileManager: FileManager, @unchecked Sendable {
    let failCopyNamed: String?
    let failCleanup: Bool

    init(failCopyNamed: String? = nil, failCleanup: Bool = false) {
        self.failCopyNamed = failCopyNamed
        self.failCleanup = failCleanup
        super.init()
    }

    override func copyItem(at source: URL, to destination: URL) throws {
        if source.lastPathComponent == failCopyNamed {
            try Data("partial copy".utf8).write(to: destination)
            throw XcodeMCPProxyInstaller.Error.message("injected copy failure")
        }
        try super.copyItem(at: source, to: destination)
    }

    override func removeItem(at url: URL) throws {
        if failCleanup, url.lastPathComponent.hasPrefix(".xcode-mcp-install-") {
            throw XcodeMCPProxyInstaller.Error.message("injected cleanup failure")
        }
        try super.removeItem(at: url)
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
