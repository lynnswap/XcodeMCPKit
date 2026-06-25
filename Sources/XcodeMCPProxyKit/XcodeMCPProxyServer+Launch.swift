import Foundation
import ProxyBuildInfo
import ProxyCLICommon
import ProxyCore

extension XcodeMCPProxyServer {
    /// Product metadata exposed by the server-side kit.
    public struct ProductMetadata: Equatable, Sendable {
        /// Product name shown in server startup summaries.
        public let name: String

        /// Resolved package version.
        public let version: String

        /// Creates product metadata.
        public init(name: String = "XcodeMCPKit", version: String) {
            self.name = name
            self.version = version
        }

        /// Formats a CLI-compatible version line.
        public func versionLine(arguments: [String], defaultExecutableName: String) -> String {
            "\(executableName(arguments: arguments, defaultExecutableName: defaultExecutableName)) \(version)"
        }

        private func executableName(arguments: [String], defaultExecutableName: String) -> String {
            guard let rawExecutable = arguments.first, !rawExecutable.isEmpty else {
                return defaultExecutableName
            }

            let name = URL(fileURLWithPath: rawExecutable).lastPathComponent
            return name.isEmpty ? defaultExecutableName : name
        }
    }

    /// Resolved top-level action for a server launch invocation.
    public enum LaunchAction: Equatable, Sendable {
        /// Print usage and exit.
        case showHelp

        /// Print version information and exit.
        case showVersion

        /// Print the resolved dry-run command and exit.
        case dryRun

        /// Start the proxy server.
        case start
    }

    /// Normalized server launch options.
    public struct LaunchOptions: Equatable, Sendable {
        /// Executable name resolved from argv.
        public let executableName: String

        /// Whether the invocation should dry-run instead of starting.
        public let dryRun: Bool

        /// Whether an existing proxy server should be terminated before start.
        public let forceRestart: Bool

        /// Creates normalized server launch options.
        public init(executableName: String, dryRun: Bool, forceRestart: Bool) {
            self.executableName = executableName
            self.dryRun = dryRun
            self.forceRestart = forceRestart
        }
    }

    /// Resolved launch plan for `xcode-mcp-proxy-server`.
    public struct LaunchPlan: Equatable, Sendable {
        /// Top-level action to execute.
        public let action: LaunchAction

        /// Public server configuration. This is present for `.start` and
        /// `.dryRun` plans and absent for display-only plans.
        public let configuration: Configuration?

        /// Normalized launch options.
        public let options: LaunchOptions

        /// Stable dry-run command line derived from the resolved plan.
        public let resolvedDryRunCommandLine: String?

        /// Usage text for help or validation failures.
        public let usage: String

        /// Version line for version display.
        public let versionLine: String

        /// Creates a launch plan.
        public init(
            action: LaunchAction,
            configuration: Configuration?,
            options: LaunchOptions,
            resolvedDryRunCommandLine: String?,
            usage: String,
            versionLine: String
        ) {
            self.action = action
            self.configuration = configuration
            self.options = options
            self.resolvedDryRunCommandLine = resolvedDryRunCommandLine
            self.usage = usage
            self.versionLine = versionLine
        }
    }

    /// Error raised while resolving server launch arguments.
    public struct LaunchResolutionError: Error, CustomStringConvertible, Equatable, Sendable {
        /// Preferred command-line presentation for the error.
        public enum Presentation: Equatable, Sendable {
            /// Print `error: <message>` and a short help hint.
            case conciseUsageHint

            /// Print `<message>` followed by full usage.
            case fullUsage
        }

        /// Human-readable error message.
        public let message: String

        /// Preferred command-line presentation.
        public let presentation: Presentation

        /// Creates a launch resolution error.
        public init(message: String, presentation: Presentation) {
            self.message = message
            self.presentation = presentation
        }

        /// User-facing error description.
        public var description: String { message }
    }

    package struct ParsedLaunchOptions {
        var forwardedArguments: [String]
        var showHelp: Bool
        var showVersion: Bool
        var hasListenFlag: Bool
        var hasHostFlag: Bool
        var hasPortFlag: Bool
        var hasConfigFlag: Bool
        var hasAutoApproveFlag: Bool
        var hasRefreshCodeIssuesModeFlag: Bool
        var forceRestart: Bool
        var dryRun: Bool
    }

    /// Resolved XcodeMCPProxyKit product metadata.
    public static var productMetadata: ProductMetadata {
        ProductMetadata(version: ProxyBuildInfo.version)
    }

    /// CLI usage for `xcode-mcp-proxy-server`.
    public static var serverUsage: String {
        """
        Usage:
          xcode-mcp-proxy-server [options]

        Options:
          --listen host:port
          --host host
          --port port
          --config path
          --auto-approve
          --upstream-processes n
          --refresh-code-issues-mode proxy|upstream
          --force-restart
          --dry-run
          --version
          -h, --help

        Notes:
          - Starts the Streamable HTTP proxy server (and spawns xcrun mcpbridge as upstream processes).
          - HTTP-capable clients should connect directly; xcode-mcp-proxy is the STDIO compatibility adapter.
          - Default listen: localhost:8765 (override via --listen / --host / --port or env LISTEN/HOST/PORT).
          - --auto-approve opt-in enables automatic approval of the Xcode permission dialog.
          - Initialize config path: --config or env MCP_XCODE_CONFIG
          - When the listen port is already in use, rerun with --force-restart to terminate an existing xcode-mcp-proxy-server.
        """
    }

    /// Formats a CLI-compatible server version line.
    public static func serverVersionLine(arguments: [String]) -> String {
        productMetadata.versionLine(
            arguments: arguments,
            defaultExecutableName: "xcode-mcp-proxy-server"
        )
    }

    /// Resolves argv and environment into a server launch plan.
    public static func resolveLaunchPlan(
        arguments: [String],
        environment: [String: String]
    ) throws -> LaunchPlan {
        var parsed = try parseLaunchOptions(arguments: arguments)
        let versionLine = serverVersionLine(arguments: arguments)
        let displayOptions = LaunchOptions(
            executableName: executableName(
                arguments: arguments,
                defaultExecutableName: "xcode-mcp-proxy-server"
            ),
            dryRun: parsed.dryRun,
            forceRestart: parsed.forceRestart
        )

        if parsed.showHelp {
            return LaunchPlan(
                action: .showHelp,
                configuration: nil,
                options: displayOptions,
                resolvedDryRunCommandLine: nil,
                usage: serverUsage,
                versionLine: versionLine
            )
        }
        if parsed.showVersion {
            return LaunchPlan(
                action: .showVersion,
                configuration: nil,
                options: displayOptions,
                resolvedDryRunCommandLine: nil,
                usage: serverUsage,
                versionLine: versionLine
            )
        }

        try applyLaunchDefaults(from: environment, to: &parsed)

        let proxyArguments = ["xcode-mcp-proxy"] + parsed.forwardedArguments
        let proxyConfig: ProxyConfig
        do {
            proxyConfig = try CLIParser.parse(args: proxyArguments, environment: environment)
            try proxyConfig.validateModernProtocolConfiguration()
        } catch let error as CLIError {
            throw LaunchResolutionError(
                message: error.description,
                presentation: .fullUsage
            )
        } catch let error as ProxyConfig.ValidationError {
            throw LaunchResolutionError(
                message: error.description,
                presentation: .fullUsage
            )
        }

        let configuration = Configuration(serverProxyConfig: proxyConfig)
        let dryRun = parsed.dryRun || isTruthy(environment["DRY_RUN"])
        let options = LaunchOptions(
            executableName: displayOptions.executableName,
            dryRun: dryRun,
            forceRestart: parsed.forceRestart
        )
        let dryRunCommandLine = resolvedDryRunCommandLine(options: parsed, configuration: configuration)

        return LaunchPlan(
            action: dryRun ? .dryRun : .start,
            configuration: configuration,
            options: options,
            resolvedDryRunCommandLine: dryRunCommandLine,
            usage: serverUsage,
            versionLine: versionLine
        )
    }

    package static let removedLazyInitializationMessage = CLIParser.removedLazyInitMessage
    package static let removedXcodePIDMessage = CLIParser.removedXcodePIDMessage

    package static func bootstrapLogging(environment: [String: String]) {
        ProxyLogging.bootstrap(environment: environment)
    }

    package static func parseLaunchOptions(arguments: [String]) throws -> ParsedLaunchOptions {
        let scan: CLI.InvocationScanner.ServerScan
        do {
            scan = try CLI.InvocationScanner.scanServer(arguments)
        } catch let error as CLIError {
            throw LaunchResolutionError(
                message: error.description,
                presentation: .conciseUsageHint
            )
        }

        return ParsedLaunchOptions(
            forwardedArguments: scan.forwardedArgs,
            showHelp: scan.showHelp,
            showVersion: scan.showVersion,
            hasListenFlag: scan.hasListenFlag,
            hasHostFlag: scan.hasHostFlag,
            hasPortFlag: scan.hasPortFlag,
            hasConfigFlag: scan.hasConfigFlag,
            hasAutoApproveFlag: scan.hasAutoApproveFlag,
            hasRefreshCodeIssuesModeFlag: scan.hasRefreshCodeIssuesModeFlag,
            forceRestart: scan.forceRestart,
            dryRun: scan.dryRun
        )
    }

    package static func applyLaunchDefaults(
        from environment: [String: String],
        to options: inout ParsedLaunchOptions
    ) throws {
        if !options.hasListenFlag && !options.hasHostFlag && !options.hasPortFlag {
            if let listen = nonEmpty(environment["LISTEN"]) {
                options.forwardedArguments += ["--listen", listen]
            } else {
                let envHost = nonEmpty(environment["HOST"])
                let envPort = nonEmpty(environment["PORT"])
                if envHost != nil || envPort != nil {
                    let host = envHost ?? "localhost"
                    let port = envPort ?? "8765"
                    options.forwardedArguments += ["--listen", "\(host):\(port)"]
                } else {
                    options.forwardedArguments += ["--listen", "localhost:8765"]
                }
            }
        }

        if !options.hasListenFlag, options.hasHostFlag, !options.hasPortFlag {
            options.forwardedArguments += ["--port", "8765"]
        }

        if isTruthy(environment["LAZY_INIT"]) {
            throw LaunchResolutionError(
                message: CLIParser.removedLazyInitMessage,
                presentation: .conciseUsageHint
            )
        }
    }

    package static func resolvedDryRunCommandLine(
        options: ParsedLaunchOptions,
        configuration: Configuration
    ) -> String {
        var parts = ["xcode-mcp-proxy-server"] + options.forwardedArguments
        if options.hasConfigFlag == false, let configPath = configuration.configurationFilePath {
            parts += ["--config", configPath]
        }
        if options.hasRefreshCodeIssuesModeFlag == false,
           configuration.features.refreshCodeIssuesMode != .proxy {
            parts += [
                "--refresh-code-issues-mode",
                configuration.features.refreshCodeIssuesMode.rawValue,
            ]
        }
        return parts.joined(separator: " ")
    }

    package static func nonEmpty(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    package static func isTruthy(_ value: String?) -> Bool {
        guard let raw = nonEmpty(value) else { return false }
        return ["1", "true", "yes", "on"].contains(raw.lowercased())
    }

    private static func executableName(arguments: [String], defaultExecutableName: String) -> String {
        guard let rawExecutable = arguments.first, !rawExecutable.isEmpty else {
            return defaultExecutableName
        }

        let name = URL(fileURLWithPath: rawExecutable).lastPathComponent
        return name.isEmpty ? defaultExecutableName : name
    }
}
