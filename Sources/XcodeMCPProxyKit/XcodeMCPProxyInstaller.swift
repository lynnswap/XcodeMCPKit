import Foundation
import ProxyCLICommon

/// Installer facade for Xcode MCP proxy executables.
public struct XcodeMCPProxyInstaller: Sendable {
    /// Top-level action for an installer invocation.
    public enum LaunchAction: Equatable, Sendable {
        /// Print usage and exit.
        case showHelp

        /// Print version information and exit.
        case showVersion

        /// Install proxy executables.
        case install
    }

    /// Normalized installer launch options.
    public struct LaunchOptions: Equatable, Sendable {
        /// Executable name resolved from argv.
        public let executableName: String

        /// Creates normalized installer launch options.
        public init(executableName: String) {
            self.executableName = executableName
        }
    }

    /// Resolved launch plan for `xcode-mcp-proxy-install`.
    public struct LaunchPlan: Equatable, Sendable {
        /// Top-level action to execute.
        public let action: LaunchAction

        /// Installer configuration. This is present for `.install` plans and
        /// absent for display-only plans.
        public let configuration: Configuration?

        /// Normalized launch options.
        public let options: LaunchOptions

        /// Usage text for help or validation failures.
        public let usage: String

        /// Version line for version display.
        public let versionLine: String

        /// Creates an installer launch plan.
        public init(
            action: LaunchAction,
            configuration: Configuration?,
            options: LaunchOptions,
            usage: String,
            versionLine: String
        ) {
            self.action = action
            self.configuration = configuration
            self.options = options
            self.usage = usage
            self.versionLine = versionLine
        }
    }

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

    /// CLI usage for `xcode-mcp-proxy-install`.
    public static var installUsage: String {
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
    public static func installVersionLine(arguments: [String]) -> String {
        XcodeMCPProxyServer.productMetadata.versionLine(
            arguments: arguments,
            defaultExecutableName: "xcode-mcp-proxy-install"
        )
    }

    /// Resolves argv and environment into an installer launch plan.
    public static func resolveLaunchPlan(
        arguments: [String],
        environment: [String: String]
    ) throws -> LaunchPlan {
        let scan = ProxyCLIInvocationScanner.scanInstall(arguments)
        let options = LaunchOptions(
            executableName: executableName(
                arguments: arguments,
                defaultExecutableName: "xcode-mcp-proxy-install"
            )
        )
        let versionLine = installVersionLine(arguments: arguments)

        if scan.showHelp {
            return LaunchPlan(
                action: .showHelp,
                configuration: nil,
                options: options,
                usage: installUsage,
                versionLine: versionLine
            )
        }
        if scan.showVersion {
            return LaunchPlan(
                action: .showVersion,
                configuration: nil,
                options: options,
                usage: installUsage,
                versionLine: versionLine
            )
        }

        return LaunchPlan(
            action: .install,
            configuration: try parseLaunchConfiguration(arguments, environment: environment),
            options: options,
            usage: installUsage,
            versionLine: versionLine
        )
    }

    package static func parseLaunchConfiguration(
        _ arguments: [String],
        environment: [String: String]
    ) throws -> Configuration {
        var configuration = Configuration(
            prefix: environment["PREFIX"],
            bindir: environment["BINDIR"],
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
                configuration.bindir = arguments[index + 1]
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

    private static func executableName(arguments: [String], defaultExecutableName: String) -> String {
        guard let rawExecutable = arguments.first, !rawExecutable.isEmpty else {
            return defaultExecutableName
        }

        let name = URL(fileURLWithPath: rawExecutable).lastPathComponent
        return name.isEmpty ? defaultExecutableName : name
    }
}

extension XcodeMCPProxyInstaller {
    package struct Launcher {
        package struct Dependencies {
            package var executableURL: () -> URL?
            package var install:
                (XcodeMCPProxyInstaller.Configuration, URL, (String) -> Void) throws -> Void

            package init(
                executableURL: @escaping () -> URL?,
                install: @escaping (
                    XcodeMCPProxyInstaller.Configuration,
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
                let plan = try XcodeMCPProxyInstaller.resolveLaunchPlan(
                    arguments: arguments,
                    environment: environment
                )

                switch plan.action {
                case .showHelp:
                    stdout(plan.usage)
                    return 0
                case .showVersion:
                    stdout(plan.versionLine)
                    return 0
                case .install:
                    guard let configuration = plan.configuration else {
                        throw XcodeMCPProxyInstaller.Error.message(
                            "installer launch plan is missing configuration"
                        )
                    }
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
