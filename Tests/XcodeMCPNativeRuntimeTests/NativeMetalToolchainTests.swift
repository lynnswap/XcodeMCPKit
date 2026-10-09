import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

struct NativeMetalToolchainTests {
    @Test func discoversDownloadedToolchainFromCompiler() throws {
        let fixture = try MetalFixture(identifier: "com.apple.dt.toolchain.Metal.test")
        defer { fixture.remove() }

        let toolchain = try #require(try NativeMetalToolchain.installed(at: fixture.compiler))

        #expect(toolchain.directory == fixture.directory)
        #expect(toolchain.identifier == "com.apple.dt.toolchain.Metal.test")
    }

    @Test func defaultToolchainDoesNotEnableDownloadableProvider() throws {
        let fixture = try MetalFixture(identifier: "com.apple.dt.toolchain.XcodeDefault")
        defer { fixture.remove() }

        #expect(try NativeMetalToolchain.installed(at: fixture.compiler) == nil)
    }

    @Test func compilerOutsideToolchainDoesNotEnableDownloadableProvider() throws {
        #expect(try NativeMetalToolchain.installed(at: URL(fileURLWithPath: "/usr/bin/metal")) == nil)
    }

    @Test func malformedInstalledMetadataIsReported() throws {
        let fixture = try MetalFixture(identifier: "com.apple.dt.toolchain.Metal.test")
        defer { fixture.remove() }
        try Data("invalid plist".utf8).write(to: fixture.directory.appendingPathComponent("ToolchainInfo.plist"))

        #expect(throws: DecodingError.self) {
            try NativeMetalToolchain.installed(at: fixture.compiler)
        }
    }

    @Test func suppliesContainingDirectoryAndIdentifierWithoutPersistingSettings() throws {
        let fixture = try MetalFixture(identifier: "com.apple.dt.toolchain.Metal.test")
        defer { fixture.remove() }
        let toolchain = try #require(try NativeMetalToolchain.installed(at: fixture.compiler))
        let defaults = ArgumentDefaults()
        defaults.setVolatileDomain(["unrelated": "preserved"], forName: UserDefaults.argumentDomain)

        toolchain.configure(defaults: defaults)

        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        #expect(arguments[NativeMetalToolchain.searchPathsKey] as? String == fixture.root.path)
        #expect(arguments[NativeMetalToolchain.identifiersKey] as? String == toolchain.identifier)
        #expect(arguments[NativeMetalToolchain.needsDownloadableKey] as? Bool == true)
        #expect(arguments["unrelated"] as? String == "preserved")
        #expect(defaults.persistentWrites == 0)
    }
}

private struct MetalFixture {
    let root: URL
    let directory: URL
    let compiler: URL

    init(identifier: String) throws {
        root = URL.temporaryDirectory.appendingPathComponent("native-metal-\(UUID())", isDirectory: true)
        directory = root.appendingPathComponent("Downloaded.xctoolchain", isDirectory: true)
        compiler = directory.appendingPathComponent("usr/bin/metal")
        try FileManager.default.createDirectory(at: compiler.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["Identifier": identifier], format: .binary, options: 0)
            .write(to: directory.appendingPathComponent("ToolchainInfo.plist"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

// Keep NSArgumentDomain tests independent of the process-wide Foundation domain.
private final class ArgumentDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var arguments: [String: Any] = [:]
    private var writeCount = 0

    var persistentWrites: Int { lock.withLock { writeCount } }

    override func volatileDomain(forName domainName: String) -> [String: Any] {
        lock.withLock { arguments }
    }

    override func setVolatileDomain(_ domain: [String: Any], forName domainName: String) {
        lock.withLock { arguments = domain }
    }

    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        lock.withLock { writeCount += 1 }
    }
}
