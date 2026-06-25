import Foundation
import ProxyInstallSupport

/// Installer facade for Xcode MCP proxy executables.
public struct XcodeMCPProxyInstaller: Sendable {
    /// Destination and mode settings for a source install.
    public struct Configuration: Equatable, Sendable {
        /// Install prefix used when ``bindir`` is not set.
        public var prefix: String?

        /// Explicit binary directory. This takes precedence over ``prefix``.
        public var bindir: String?

        /// Whether to only compute and print the install plan.
        public var dryRun: Bool

        /// Creates installer configuration.
        public init(prefix: String? = nil, bindir: String? = nil, dryRun: Bool = false) {
            self.prefix = prefix
            self.bindir = bindir
            self.dryRun = dryRun
        }
    }

    /// One proxy executable that will be copied by an install plan.
    public struct Binary: Equatable, Sendable {
        /// Executable file name.
        public let name: String

        /// Source executable path.
        public let sourceURL: URL

        /// Destination executable path.
        public let destinationURL: URL

        /// Creates a binary copy entry.
        public init(name: String, sourceURL: URL, destinationURL: URL) {
            self.name = name
            self.sourceURL = sourceURL
            self.destinationURL = destinationURL
        }
    }

    /// Fully resolved install plan.
    public struct InstallPlan: Equatable, Sendable {
        /// Directory where executables will be installed.
        public let binDirectory: URL

        /// Executables included in the install.
        public let binaries: [Binary]

        /// Whether the plan should be displayed without copying files.
        public let dryRun: Bool

        /// Creates an install plan.
        public init(binDirectory: URL, binaries: [Binary], dryRun: Bool) {
            self.binDirectory = binDirectory
            self.binaries = binaries
            self.dryRun = dryRun
        }

        /// Human-readable lines printed for a dry run.
        public var dryRunLines: [String] {
            var lines = ["Would create: \(binDirectory.path)"]
            lines.append(contentsOf: binaries.map { "Would install: \($0.destinationURL.path)" })
            return lines
        }
    }

    /// Errors raised while planning or executing an install.
    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        /// A user-facing install failure message.
        case message(String)

        /// User-facing error description.
        public var description: String {
            switch self {
            case .message(let text):
                return text
            }
        }
    }

    /// Executable product names installed by the source installer.
    public static let binaryNames = [
        "xcode-mcp-proxy",
        "xcode-mcp-proxy-server",
    ]

    /// Installer configuration.
    public var configuration: Configuration

    /// Creates an installer facade.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Resolves the file operations that would be performed for an install.
    ///
    /// - Parameter executableURL: Path to the running installer executable.
    /// - Returns: A plan containing source and destination executable paths.
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

    /// Builds release products when needed and installs the proxy executables.
    ///
    /// When ``Configuration/dryRun`` is true this method prints the dry-run plan
    /// and does not create directories or copy files.
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

    /// Resolves the destination binary directory.
    ///
    /// `bindir` takes precedence over `prefix`; otherwise this returns
    /// `~/.local/bin`.
    public static func resolveBinDirectory(prefix: String?, bindir: String?) -> URL {
        if let bindir {
            return URL(fileURLWithPath: expandPath(bindir), isDirectory: true)
        }

        let defaultPrefix = prefix ?? "\(NSHomeDirectory())/.local"
        let expandedPrefix = expandPath(defaultPrefix)
        return URL(fileURLWithPath: expandedPrefix, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    /// Expands a leading tilde in a filesystem path.
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
        do {
            try ProxyProductBuilder.buildReleaseProducts(products, in: directory)
        } catch let error as ProxyProductBuilder.Error {
            throw Error.message(error.description)
        }
    }
}
