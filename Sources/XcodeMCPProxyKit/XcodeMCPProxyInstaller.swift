import Foundation

/// Destination and mode settings for a source install.
package struct XcodeMCPProxyInstallerConfiguration: Equatable, Sendable {
    /// Install prefix used when ``binaryDirectory`` is not set.
    package var prefix: String?

    /// Explicit binary directory. This takes precedence over ``prefix``.
    package var binaryDirectory: String?

    /// Whether to only compute and print the install plan.
    package var dryRun: Bool

    /// Creates installer configuration.
    package init(
        prefix: String? = nil,
        binaryDirectory: String? = nil,
        dryRun: Bool = false
    ) {
        self.prefix = prefix
        self.binaryDirectory = binaryDirectory
        self.dryRun = dryRun
    }
}

/// Installer facade for Xcode MCP proxy executables.
package struct XcodeMCPProxyInstaller: Sendable {
    /// Top-level action for an installer invocation.
    package enum LaunchAction: Equatable, Sendable {
        case showHelp(String)
        case showVersion(String)
        case install(XcodeMCPProxyInstallerConfiguration)
    }

    /// One proxy executable that will be copied by an install plan.
    package struct Binary: Equatable, Sendable {
        /// Executable file name.
        package let name: String

        /// Source executable path.
        package let sourceURL: URL

        /// Destination executable path.
        package let destinationURL: URL

        /// Creates a binary copy entry.
        package init(name: String, sourceURL: URL, destinationURL: URL) {
            self.name = name
            self.sourceURL = sourceURL
            self.destinationURL = destinationURL
        }
    }

    /// Fully resolved install plan.
    package struct InstallPlan: Equatable, Sendable {
        /// Directory where executables will be installed.
        package let binDirectory: URL

        /// Executables included in the install.
        package let binaries: [Binary]

        /// Whether the plan should be displayed without copying files.
        package let dryRun: Bool

        /// Creates an install plan.
        package init(binDirectory: URL, binaries: [Binary], dryRun: Bool) {
            self.binDirectory = binDirectory
            self.binaries = binaries
            self.dryRun = dryRun
        }

        /// Human-readable lines printed for a dry run.
        package var dryRunLines: [String] {
            var lines = ["Would create: \(binDirectory.path)"]
            lines.append(contentsOf: binaries.map { "Would install: \($0.destinationURL.path)" })
            return lines
        }
    }

    /// Errors raised while planning or executing an install.
    package enum Error: Swift.Error, CustomStringConvertible, Equatable {
        /// A user-facing install failure message.
        case message(String)

        /// User-facing error description.
        package var description: String {
            switch self {
            case .message(let text):
                return text
            }
        }
    }

    /// Executable product names installed by the source installer.
    package static let binaryNames = [
        "xcode-mcp-proxy",
        "xcode-mcp-proxy-server",
    ]

    /// Installer configuration.
    package var configuration: XcodeMCPProxyInstallerConfiguration

    /// Creates an installer facade.
    package init(
        configuration: XcodeMCPProxyInstallerConfiguration =
            XcodeMCPProxyInstallerConfiguration()
    ) {
        self.configuration = configuration
    }

    /// CLI usage for `xcode-mcp-proxy-install`.
    package static var installUsage: String {
        """
        Usage:
          xcode-mcp-proxy-install [--bindir path] [--prefix path] [--dry-run]

        Options:
          --bindir path   Install to this directory (overrides --prefix)
          --prefix path   Install to <prefix>/bin (default: ~/.local)
          --dry-run       Print actions without copying files
          --version       Show version
          -h, --help      Show this help

        Examples:
          swift run -c release xcode-mcp-proxy-install
          swift run -c release xcode-mcp-proxy-install --bindir "$HOME/bin"
        """
    }

    /// Formats a CLI-compatible installer version line.
    package static func installVersionLine(arguments: [String]) -> String {
        XcodeMCPProxyServer.productMetadata.versionLine(
            arguments: arguments,
            defaultExecutableName: "xcode-mcp-proxy-install"
        )
    }

    package static func resolveLaunchAction(
        arguments: [String],
        environment: [String: String]
    ) throws -> LaunchAction {
        let scan = ProxyCLIInvocationScanner.scanInstall(arguments)
        let versionLine = installVersionLine(arguments: arguments)

        if scan.showHelp {
            return .showHelp(installUsage)
        }
        if scan.showVersion {
            return .showVersion(versionLine)
        }

        return .install(
            try parseLaunchConfiguration(arguments, environment: environment)
        )
    }

    package static func parseLaunchConfiguration(
        _ arguments: [String],
        environment: [String: String]
    ) throws -> XcodeMCPProxyInstallerConfiguration {
        var configuration = XcodeMCPProxyInstallerConfiguration(
            prefix: environment["PREFIX"],
            binaryDirectory: environment["BINDIR"],
            dryRun: false
        )

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help", "--version":
                index += 1
            case "--prefix":
                guard index + 1 < arguments.count else {
                    throw Error.message("\(argument) requires a value")
                }
                configuration.prefix = arguments[index + 1]
                index += 2
            case "--bindir":
                guard index + 1 < arguments.count else {
                    throw Error.message("\(argument) requires a value")
                }
                configuration.binaryDirectory = arguments[index + 1]
                index += 2
            case "--dry-run":
                configuration.dryRun = true
                index += 1
            default:
                throw Error.message("unknown option: \(argument)")
            }
        }

        return configuration
    }

    /// Resolves the file operations that would be performed for an install.
    ///
    /// - Parameter executableURL: Path to the running installer executable.
    /// - Returns: A plan containing source and destination executable paths.
    package func plan(executableURL: URL) -> InstallPlan {
        let sourceDirectory = executableURL.deletingLastPathComponent()
        let binDirectory = Self.resolveBinDirectory(
            prefix: configuration.prefix,
            binaryDirectory: configuration.binaryDirectory
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
    /// When ``XcodeMCPProxyInstallerConfiguration/dryRun`` is true this method
    /// prints the dry-run plan and does not create directories or copy files.
    package func install(
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
    /// `binaryDirectory` takes precedence over `prefix`; otherwise this returns
    /// `~/.local/bin`.
    package static func resolveBinDirectory(prefix: String?, binaryDirectory: String?) -> URL {
        if let binaryDirectory {
            return URL(fileURLWithPath: expandPath(binaryDirectory), isDirectory: true)
        }

        let defaultPrefix = prefix ?? "\(NSHomeDirectory())/.local"
        let expandedPrefix = expandPath(defaultPrefix)
        return URL(fileURLWithPath: expandedPrefix, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    /// Expands a leading tilde in a filesystem path.
    package static func expandPath(_ path: String) -> String {
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

extension XcodeMCPProxyInstaller {
    package struct Launcher {
        package struct Dependencies {
            package var executableURL: () -> URL?
            package var install:
                (XcodeMCPProxyInstallerConfiguration, URL, (String) -> Void) throws -> Void

            package init(
                executableURL: @escaping () -> URL?,
                install: @escaping (
                    XcodeMCPProxyInstallerConfiguration,
                    URL,
                    (String) -> Void
                ) throws -> Void
            ) {
                self.executableURL = executableURL
                self.install = install
            }

            package static var live: Self {
                Self(
                    executableURL: { Bundle.main.executableURL },
                    install: { configuration, executableURL, stdout in
                        try XcodeMCPProxyInstaller(configuration: configuration).install(
                            executableURL: executableURL,
                            stdout: stdout
                        )
                    }
                )
            }
        }

        private let dependencies: Dependencies

        package init(dependencies: Dependencies = .live) {
            self.dependencies = dependencies
        }

        package func run(
            arguments: [String],
            environment: [String: String],
            stdout: (String) -> Void,
            stderr: (String) -> Void
        ) -> Int32 {
            do {
                let action = try XcodeMCPProxyInstaller.resolveLaunchAction(
                    arguments: arguments,
                    environment: environment
                )

                switch action {
                case .showHelp(let usage):
                    stdout(usage)
                    return 0
                case .showVersion(let versionLine):
                    stdout(versionLine)
                    return 0
                case .install(let configuration):
                    guard let executableURL = dependencies.executableURL() else {
                        throw XcodeMCPProxyInstaller.Error.message(
                            "failed to locate installer executable"
                        )
                    }
                    try dependencies.install(configuration, executableURL, stdout)
                    return 0
                }
            } catch let error as XcodeMCPProxyInstaller.Error {
                stderr("error: \(error.description)")
                stderr("run with --help for usage")
                return 1
            } catch {
                stderr("error: \(error)")
                return 1
            }
        }
    }
}
