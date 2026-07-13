import Foundation
import XcodeMCPProxyRuntime

package struct XcodeMCPProxyProductMetadata: Equatable, Sendable {
    package let name: String
    package let version: String

    package init(name: String = "XcodeMCPProxyKit", version: String) {
        self.name = name
        self.version = version
    }

    package func versionLine(arguments: [String], defaultExecutableName: String) -> String {
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

extension XcodeMCPProxyServer {
    package enum LaunchAction: Sendable {
        case showHelp(String)
        case showVersion(String)
        case dryRun(String)
        case start(preparedConfiguration: PreparedConfiguration, forceRestart: Bool)
    }

    package struct LaunchResolutionError: Error, CustomStringConvertible, Equatable, Sendable {
        package enum Presentation: Equatable, Sendable {
            case conciseUsageHint
            case fullUsage
        }

        package let message: String
        package let presentation: Presentation

        package init(message: String, presentation: Presentation) {
            self.message = message
            self.presentation = presentation
        }

        package var description: String { message }
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

    package static var productMetadata: XcodeMCPProxyProductMetadata {
        XcodeMCPProxyProductMetadata(version: ProxyBuildInfo.version)
    }

    package static var serverUsage: String {
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

    package static func serverVersionLine(arguments: [String]) -> String {
        productMetadata.versionLine(
            arguments: arguments,
            defaultExecutableName: "xcode-mcp-proxy-server"
        )
    }

    package static func resolveLaunchAction(
        arguments: [String],
        environment: [String: String]
    ) throws -> LaunchAction {
        try resolveLaunchAction(
            arguments: arguments,
            environment: environment,
            loadFileConfiguration: {
                try ProxyConfig.File.Loader.loadStrict(configURL: $0)
            }
        )
    }

    static func resolveLaunchAction(
        arguments: [String],
        environment: [String: String],
        loadFileConfiguration: @Sendable (URL) throws ->
            ProxyConfig.File.LoadedConfiguration
    ) throws -> LaunchAction {
        var parsed = try parseLaunchOptions(arguments: arguments)
        let versionLine = serverVersionLine(arguments: arguments)

        if parsed.showHelp {
            return .showHelp(serverUsage)
        }
        if parsed.showVersion {
            return .showVersion(versionLine)
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

        let configuration = XcodeMCPProxyServerConfiguration(serverProxyConfig: proxyConfig)
        let resolved: ProxyConfig
        do {
            resolved = try ProxyConfig.resolving(
                configuration,
                loadFileConfiguration: loadFileConfiguration
            )
            try resolved.validateModernProtocolConfiguration()
        } catch {
            throw LaunchResolutionError(
                message: String(describing: error),
                presentation: .fullUsage
            )
        }
        let dryRun = parsed.dryRun || isTruthy(environment["DRY_RUN"])
        let dryRunCommandLine = resolvedDryRunCommandLine(options: parsed, configuration: configuration)

        if dryRun {
            return .dryRun(dryRunCommandLine)
        }
        return .start(
            preparedConfiguration: PreparedConfiguration(
                configuration: configuration,
                proxyConfig: resolved
            ),
            forceRestart: parsed.forceRestart
        )
    }

    package static let removedLazyInitializationMessage = CLIParser.removedLazyInitMessage
    package static let removedXcodePIDMessage = CLIParser.removedXcodePIDMessage

    package static func bootstrapLogging(environment: [String: String]) {
        ProxyLogging.bootstrap(environment: environment)
    }

    package static func parseLaunchOptions(arguments: [String]) throws -> ParsedLaunchOptions {
        let scan: ProxyCLIInvocationScanner.ServerScan
        do {
            scan = try ProxyCLIInvocationScanner.scanServer(arguments)
        } catch let error as ProxyCLIInvocationScanner.Error {
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
        configuration: XcodeMCPProxyServerConfiguration
    ) -> String {
        var parts = ["xcode-mcp-proxy-server"] + options.forwardedArguments
        if options.hasConfigFlag == false, let configURL = configuration.configurationFileURL {
            parts += ["--config", configURL.path]
        }
        if options.hasRefreshCodeIssuesModeFlag == false,
           configuration.featurePolicy.refreshCodeIssuesMode != .proxy {
            parts += [
                "--refresh-code-issues-mode",
                configuration.featurePolicy.refreshCodeIssuesMode.rawValue,
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
