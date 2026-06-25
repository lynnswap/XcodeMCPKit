import Foundation

/// Installer facade for Xcode MCP proxy executables.
public struct XcodeMCPProxyInstaller: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var prefix: String?
        public var bindir: String?
        public var dryRun: Bool

        public init(prefix: String? = nil, bindir: String? = nil, dryRun: Bool = false) {
            self.prefix = prefix
            self.bindir = bindir
            self.dryRun = dryRun
        }
    }

    public struct Binary: Equatable, Sendable {
        public let name: String
        public let sourceURL: URL
        public let destinationURL: URL

        public init(name: String, sourceURL: URL, destinationURL: URL) {
            self.name = name
            self.sourceURL = sourceURL
            self.destinationURL = destinationURL
        }
    }

    public struct InstallPlan: Equatable, Sendable {
        public let binDirectory: URL
        public let binaries: [Binary]
        public let dryRun: Bool

        public init(binDirectory: URL, binaries: [Binary], dryRun: Bool) {
            self.binDirectory = binDirectory
            self.binaries = binaries
            self.dryRun = dryRun
        }

        public var dryRunLines: [String] {
            var lines = ["Would create: \(binDirectory.path)"]
            lines.append(contentsOf: binaries.map { "Would install: \($0.destinationURL.path)" })
            return lines
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case message(String)

        public var description: String {
            switch self {
            case .message(let text):
                return text
            }
        }
    }

    public static let binaryNames = [
        "xcode-mcp-proxy",
        "xcode-mcp-proxy-server",
    ]

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func plan(executableURL: URL) -> InstallPlan {
        let sourceDirectory = executableURL.deletingLastPathComponent()
        let binDirectory = Self.resolveBinDirectory(
            prefix: configuration.prefix,
            bindir: configuration.bindir
        )
        let binaries = Self.binaryNames.map { name in
            Binary(
                name: name,
                sourceURL: sourceDirectory.appendingPathComponent(name),
                destinationURL: binDirectory.appendingPathComponent(name)
            )
        }
        return InstallPlan(
            binDirectory: binDirectory,
            binaries: binaries,
            dryRun: configuration.dryRun
        )
    }

    public func install(
        executableURL: URL,
        stdout: (String) -> Void = { print($0) }
    ) throws {
        try install(
            executableURL: executableURL,
            fileManager: .default,
            buildProducts: Self.buildProducts,
            stdout: stdout
        )
    }

    package func install(
        executableURL: URL,
        fileManager: FileManager = .default,
        buildProducts: ([String], URL) throws -> Void,
        stdout: (String) -> Void
    ) throws {
        let plan = plan(executableURL: executableURL)
        if plan.dryRun {
            for line in plan.dryRunLines {
                stdout(line)
            }
            return
        }

        try fileManager.createDirectory(
            at: plan.binDirectory,
            withIntermediateDirectories: true
        )
        if let repoRoot = Self.repositoryRoot(from: executableURL),
            fileManager.fileExists(atPath: repoRoot.appendingPathComponent("Package.swift").path)
        {
            try buildProducts(Self.binaryNames, repoRoot)
        }

        for binary in plan.binaries {
            guard fileManager.fileExists(atPath: binary.sourceURL.path) else {
                throw Error.message(
                    "\(binary.name) not found next to installer (run with `swift run -c release` from the repo root)"
                )
            }

            if fileManager.fileExists(atPath: binary.destinationURL.path) {
                try fileManager.removeItem(at: binary.destinationURL)
            }
            try fileManager.copyItem(at: binary.sourceURL, to: binary.destinationURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: binary.destinationURL.path
            )
            stdout("Installed \(binary.name) to \(binary.destinationURL.path)")
        }
    }

    public static func resolveBinDirectory(prefix: String?, bindir: String?) -> URL {
        if let bindir {
            return URL(fileURLWithPath: expandPath(bindir), isDirectory: true)
        }

        let defaultPrefix = prefix ?? "\(NSHomeDirectory())/.local"
        let expandedPrefix = expandPath(defaultPrefix)
        return URL(fileURLWithPath: expandedPrefix, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    public static func expandPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return path
    }

    package static func repositoryRoot(from executableURL: URL) -> URL? {
        var current = executableURL
        while current.path != "/" {
            if current.lastPathComponent == ".build" {
                return current.deletingLastPathComponent()
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    package static func buildProducts(_ products: [String], in directory: URL) throws {
        for product in products {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["swift", "build", "-c", "release", "--product", product]
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw Error.message("swift build failed; run from the repo root and try again")
            }
        }
    }
}
