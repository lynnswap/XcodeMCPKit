import Darwin
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
            buildProducts: { _, _, _ in },
            stdout: { output.append($0) }
        )

        let expectedProxy = bindir.appendingPathComponent("xcode-mcp-proxy").path
        let expectedServer = bindir.appendingPathComponent("xcode-mcp-proxy-server").path
        #expect(output.snapshot() == [
            "Would create: \(bindir.path)",
            "Would install: \(expectedProxy)",
            "Would install: \(expectedServer)",
            "Would install: \(bindir.appendingPathComponent(XcodeMCPProxyInstaller.nativeHostBundleName).path)",
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
        try writeNativeHostFixture(in: sourceDir.url, output: "native")

        let output = CapturedLines()
        let buildCalls = Counter()
        try XcodeMCPProxyInstaller(
            configuration: .init(prefix: nil, binaryDirectory: installDir.url.path, dryRun: false)
        ).install(
            executableURL: installerURL,
            fileManager: .default,
            buildProducts: { _, _, _ in
                buildCalls.increment()
            },
            verifyNativeHostBundle: verifyNativeHostFixture,
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
        #expect(output.snapshot().count == 3)
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
            == (XcodeMCPProxyInstaller.binaryNames + [XcodeMCPProxyInstaller.nativeHostBundleName]).sorted())
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
        try writeNativeHostFixture(in: source.url, output: "original")
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
            == (XcodeMCPProxyInstaller.binaryNames + [XcodeMCPProxyInstaller.nativeHostBundleName]).sorted())
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
        #expect(error.description.contains("Installed: \(proxy.path)\nNot installed: \(server.path), \(destination.url.appendingPathComponent(XcodeMCPProxyInstaller.nativeHostBundleName).path)"))
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

    @Test func sourceBuildProducesTheNativeBundleInDestinationStaging() throws {
        let repository = try TemporaryDirectory()
        defer { repository.cleanup() }
        let destination = try TemporaryDirectory()
        defer { destination.cleanup() }
        try Data("package fixture".utf8).write(to: repository.url.appendingPathComponent("Package.swift"))
        let products = repository.url.appendingPathComponent(".build/release")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        try writeExecutables(in: products, output: "source")
        var buildCalled = false
        try XcodeMCPProxyInstaller(configuration: .init(binaryDirectory: destination.url.path)).install(
            executableURL: products.appendingPathComponent("xcode-mcp-proxy-install"),
            buildProducts: { names, root, nativeBundle in
                buildCalled = true
                #expect(names == XcodeMCPProxyInstaller.binaryNames)
                #expect(root == repository.url)
                #expect(nativeBundle.deletingLastPathComponent().lastPathComponent.hasPrefix(".xcode-mcp-install-"))
                try writeNativeHostFixture(in: nativeBundle.deletingLastPathComponent(), output: "built native helper")
            },
            verifyNativeHostBundle: verifyNativeHostFixture,
            stdout: { _ in }
        )
        #expect(buildCalled)
        #expect(try nativeFixtureContent(in: products) == "source")
        #expect(try nativeFixtureContent(in: destination.url) == "built native helper")
    }

    @Test func missingNativeBundlePreservesAllInstalledProducts() throws {
        let source = try TemporaryDirectory()
        defer { source.cleanup() }
        let destination = try TemporaryDirectory()
        defer { destination.cleanup() }
        try writeExecutables(in: source.url, output: "new")
        try writeExecutables(in: destination.url, output: "old")
        try FileManager.default.removeItem(at: source.url.appendingPathComponent(XcodeMCPProxyInstaller.nativeHostBundleName))
        let failure = try #require(throws: XcodeMCPProxyInstaller.Error.self) {
            try install(from: source.url, to: destination.url)
        }
        #expect(failure.description.contains("Installed: none"))
        for name in XcodeMCPProxyInstaller.binaryNames {
            #expect(try runExecutable(destination.url.appendingPathComponent(name)) == "old")
        }
        #expect(try nativeFixtureContent(in: destination.url) == "old")
    }

    @Test func replacesNativeBundleWithoutRetainingObsoleteFiles() throws {
        let source = try TemporaryDirectory()
        defer { source.cleanup() }
        let destination = try TemporaryDirectory()
        defer { destination.cleanup() }
        try writeExecutables(in: source.url, output: "new")
        try writeExecutables(in: destination.url, output: "old")
        let obsolete = destination.url.appendingPathComponent(XcodeMCPProxyInstaller.nativeHostBundleName)
            .appendingPathComponent("obsolete")
        try Data("old contents".utf8).write(to: obsolete)
        try install(from: source.url, to: destination.url)
        #expect(try nativeFixtureContent(in: destination.url) == "new")
        #expect(!FileManager.default.fileExists(atPath: obsolete.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.url.path).sorted()
            == (XcodeMCPProxyInstaller.binaryNames + [XcodeMCPProxyInstaller.nativeHostBundleName]).sorted())
    }

    @Test func nativeSwapFailurePreservesTheOldBundleAndReportsInstalledExecutables() throws {
        let source = try TemporaryDirectory()
        defer { source.cleanup() }
        let destination = try TemporaryDirectory()
        defer { destination.cleanup() }
        try writeExecutables(in: source.url, output: "new")
        try writeExecutables(in: destination.url, output: "old")
        let failure = try #require(throws: XcodeMCPProxyInstaller.Error.self) {
            try XcodeMCPProxyInstaller(configuration: .init(binaryDirectory: destination.url.path)).install(
                executableURL: source.url.appendingPathComponent("xcode-mcp-proxy-install"),
                buildProducts: { _, _, _ in },
                verifyNativeHostBundle: verifyNativeHostFixture,
                replaceNativeHostBundle: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) },
                stdout: { _ in }
            )
        }
        #expect(failure.description.contains("Failed to install XcodeMCPNativeHost.app"))
        #expect(failure.description.contains("Not installed: \(destination.url.appendingPathComponent(XcodeMCPProxyInstaller.nativeHostBundleName).path)"))
        #expect(try nativeFixtureContent(in: destination.url) == "old")
        for name in XcodeMCPProxyInstaller.binaryNames {
            #expect(try runExecutable(destination.url.appendingPathComponent(name)) == "new")
        }
    }

    @Test func nativeSignatureFailureDoesNotReplaceInstalledProducts() throws {
        let source = try TemporaryDirectory()
        defer { source.cleanup() }
        let destination = try TemporaryDirectory()
        defer { destination.cleanup() }
        try writeExecutables(in: source.url, output: "new")
        try writeExecutables(in: destination.url, output: "old")
        let failure = try #require(throws: XcodeMCPProxyInstaller.Error.self) {
            try XcodeMCPProxyInstaller(configuration: .init(binaryDirectory: destination.url.path)).install(
                executableURL: source.url.appendingPathComponent("xcode-mcp-proxy-install"),
                buildProducts: { _, _, _ in },
                verifyNativeHostBundle: { _ in throw XcodeMCPProxyInstaller.Error.message("injected signature failure") },
                stdout: { _ in }
            )
        }
        #expect(failure.description.contains("injected signature failure"))
        #expect(failure.description.contains("Installed: none"))
        #expect(try nativeFixtureContent(in: destination.url) == "old")
        for name in XcodeMCPProxyInstaller.binaryNames {
            #expect(try runExecutable(destination.url.appendingPathComponent(name)) == "old")
        }
    }

    @Test func oldNativeBundleCleanupFailureReportsTheCompletedInstallAndItsRemainingDirectory() throws {
        let source = try TemporaryDirectory()
        defer { source.cleanup() }
        let destination = try TemporaryDirectory()
        defer { destination.cleanup() }
        try writeExecutables(in: source.url, output: "new")
        try writeExecutables(in: destination.url, output: "old")
        let failure = try #require(throws: XcodeMCPProxyInstaller.Error.self) {
            try install(from: source.url, to: destination.url,
                        fileManager: FailingInstallFileManager(failCleanup: true))
        }
        #expect(failure.description.contains("Not installed: none"))
        #expect(try nativeFixtureContent(in: destination.url) == "new")
        let staging = try #require(FileManager.default.contentsOfDirectory(at: destination.url, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".xcode-mcp-install-") })
        #expect(failure.description.contains(destination.url.appendingPathComponent(staging.lastPathComponent).path))
        #expect(try nativeFixtureContent(in: staging) == "old")
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
        buildProducts: { _, _, _ in },
        verifyNativeHostBundle: verifyNativeHostFixture,
        stdout: stdout
    )
}

private func writeExecutables(in directory: URL, output: String, permissions: Int = 0o755) throws {
    try writeNativeHostFixture(in: directory, output: output)
    for name in XcodeMCPProxyInstaller.binaryNames {
        let executable = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nprintf '%s' '\(output)'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: executable.path)
    }
}

private func writeNativeHostFixture(in directory: URL, output: String) throws {
    let bundle = directory.appendingPathComponent(XcodeMCPProxyInstaller.nativeHostBundleName)
    let macOS = bundle.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try Data(output.utf8).write(to: macOS.appendingPathComponent("xcode-mcp-native-host"))
    try Data("native bundle fixture".utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    let signature = bundle.appendingPathComponent("Contents/_CodeSignature")
    try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: true)
    try Data("signature fixture".utf8).write(to: signature.appendingPathComponent("CodeResources"))
}

private func nativeFixtureContent(in directory: URL) throws -> String {
    try String(contentsOf: directory.appendingPathComponent(XcodeMCPProxyInstaller.nativeHostBundleName)
        .appendingPathComponent("Contents/MacOS/xcode-mcp-native-host"), encoding: .utf8)
}

private func verifyNativeHostFixture(_ bundle: URL) throws {
    _ = try Data(contentsOf: bundle.appendingPathComponent("Contents/MacOS/xcode-mcp-native-host"))
    _ = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
    _ = try Data(contentsOf: bundle.appendingPathComponent("Contents/_CodeSignature/CodeResources"))
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
