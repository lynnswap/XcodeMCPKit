import Foundation

struct NativeMetalToolchain: Equatable {
    static let searchPathsKey = "IDEDownloadableMetalToolchainSearchPathsOverride"
    static let identifiersKey = "IDEDownloadableMetalToolchainIdentifiersOverride"
    static let needsDownloadableKey = "IDEMetalToolchainAlwaysNeedsDownloadable"

    let directory: URL
    let identifier: String

    static func configure(
        for installation: NativeXcodeInstallation,
        defaults: UserDefaults = .standard
    ) throws -> Self? {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "metal"]
        var environment = ProcessInfo.processInfo.environment
        environment["DEVELOPER_DIR"] = installation.developerDirectory.path
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NativeRuntimeError.unavailable(
                "xcrun could not locate Metal (exit \(process.terminationStatus)): "
                    + String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let compiler = URL(fileURLWithPath:
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        guard let toolchain = try installed(at: compiler) else { return nil }
        toolchain.configure(defaults: defaults)
        return toolchain
    }

    static func installed(at compiler: URL) throws -> Self? {
        var directory = compiler.standardizedFileURL.deletingLastPathComponent()
        while directory.pathExtension != "xctoolchain" {
            guard directory.path != "/" else { return nil }
            directory.deleteLastPathComponent()
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("ToolchainInfo.plist"))
        let info = try PropertyListDecoder().decode(ToolchainInfo.self, from: data)
        guard info.identifier.hasPrefix("com.apple.dt.toolchain.Metal.") else { return nil }
        return Self(directory: directory, identifier: info.identifier)
    }

    func configure(defaults: UserDefaults) {
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        // Swift Build scans directories containing .xctoolchain bundles.
        domain[Self.searchPathsKey] = directory.deletingLastPathComponent().path
        domain[Self.identifiersKey] = identifier
        // The GUI normally enables this provider when it observes Metal sources.
        domain[Self.needsDownloadableKey] = true
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    private struct ToolchainInfo: Decodable {
        let identifier: String

        enum CodingKeys: String, CodingKey {
            case identifier = "Identifier"
        }
    }
}
