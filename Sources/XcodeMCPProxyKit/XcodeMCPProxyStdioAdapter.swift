import Foundation
import Logging

/// Inputs used to resolve the Streamable HTTP endpoint for the STDIO adapter.
public struct XcodeMCPProxyAdapterEndpointResolutionOptions: Equatable, Sendable {
    /// Optional explicit endpoint string, usually from `--url` or `--stdio`.
    public var explicitURL: String?

    /// Label used in validation errors for ``explicitURL``.
    public var explicitURLLabel: String

    /// Environment used for `XCODE_MCP_PROXY_ENDPOINT` and discovery path overrides.
    public var environment: [String: String]

    /// Optional discovery file URL. `nil` derives the file from the environment.
    public var discoveryFileURL: URL?

    /// Fallback endpoint when no explicit, environment, or discovery endpoint is available.
    public var fallbackURL: URL

    /// Creates endpoint resolution options.
    public init(
        explicitURL: String? = nil,
        explicitURLLabel: String = "explicit URL",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        discoveryFileURL: URL? = nil,
        fallbackURL: URL = XcodeMCPProxyAdapterEndpointResolver.defaultEndpointURL
    ) {
        self.explicitURL = explicitURL
        self.explicitURLLabel = explicitURLLabel
        self.environment = environment
        self.discoveryFileURL = discoveryFileURL
        self.fallbackURL = fallbackURL
    }
}

/// Resolved upstream endpoint for the STDIO compatibility adapter.
public struct XcodeMCPProxyAdapterEndpoint: Equatable, Sendable {
    /// Source that selected the endpoint.
    public enum Source: String, Equatable, Sendable {
        /// The endpoint was provided directly by the caller.
        case explicit

        /// The endpoint came from `XCODE_MCP_PROXY_ENDPOINT`.
        case environment

        /// The endpoint came from a proxy discovery file.
        case discovery

        /// The default endpoint was used.
        case fallback
    }

    /// Full Streamable HTTP MCP endpoint URL.
    public let url: URL

    /// How the endpoint was selected.
    public let source: Source

    /// Creates a resolved adapter endpoint.
    public init(url: URL, source: Source) {
        self.url = url
        self.source = source
    }
}

/// Resolves the Streamable HTTP endpoint used by the STDIO adapter.
public struct XcodeMCPProxyAdapterEndpointResolver: Sendable {
    /// Endpoint resolution errors.
    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        /// A configured endpoint was not an HTTP or HTTPS URL.
        case invalidURL(label: String)

        /// User-facing error description.
        public var description: String {
            switch self {
            case .invalidURL(let label):
                return "\(label) must be an http/https URL"
            }
        }
    }

    /// Environment variable used to override the adapter endpoint.
    public static let endpointEnvironmentVariable = "XCODE_MCP_PROXY_ENDPOINT"

    /// Default endpoint string used when no override or discovery file is available.
    public static let defaultEndpointURLString = "http://localhost:8765/mcp"

    /// Default endpoint URL used when no override or discovery file is available.
    public static let defaultEndpointURL = URL(string: defaultEndpointURLString)!

    var discoveryClient: DiscoveryClient

    /// Creates a live endpoint resolver.
    public init() {
        self.init(discoveryClient: .liveValue)
    }

    init(discoveryClient: DiscoveryClient) {
        self.discoveryClient = discoveryClient
    }

    /// Returns the discovery file URL used by the adapter for the environment.
    public static func discoveryFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        ProxyFilesystemLocations.discoveryFileURL(environment: environment)
    }

    /// Resolves the endpoint using explicit value, environment, discovery, then fallback.
    public func resolve(
        _ options: XcodeMCPProxyAdapterEndpointResolutionOptions =
            XcodeMCPProxyAdapterEndpointResolutionOptions()
    ) throws -> XcodeMCPProxyAdapterEndpoint {
        if let explicit = Self.nonEmpty(options.explicitURL) {
            return XcodeMCPProxyAdapterEndpoint(
                url: try Self.parseHTTPURL(explicit, label: options.explicitURLLabel),
                source: .explicit
            )
        }

        if let raw = Self.nonEmpty(
            options.environment[Self.endpointEnvironmentVariable]
        ) {
            return XcodeMCPProxyAdapterEndpoint(
                url: try Self.parseHTTPURL(raw, label: Self.endpointEnvironmentVariable),
                source: .environment
            )
        }

        let discoveryFileURL = options.discoveryFileURL
            ?? Self.discoveryFileURL(environment: options.environment)
        if let record = discoveryClient.read(discoveryFileURL),
            let resolved = try? Self.parseHTTPURL(record.url, label: "discovery")
        {
            return XcodeMCPProxyAdapterEndpoint(url: resolved, source: .discovery)
        }

        guard Self.isHTTPURL(options.fallbackURL) else {
            throw Error.invalidURL(label: "fallback")
        }
        return XcodeMCPProxyAdapterEndpoint(
            url: options.fallbackURL,
            source: .fallback
        )
    }

    private static func parseHTTPURL(_ value: String, label: String) throws -> URL {
        guard let url = URL(string: value), isHTTPURL(url) else {
            throw Error.invalidURL(label: label)
        }
        return url
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Configuration for a STDIO adapter instance.
public struct XcodeMCPProxyStdioAdapterConfiguration: Equatable, Sendable {
    /// Endpoint resolution options.
    public var endpoint: XcodeMCPProxyAdapterEndpointResolutionOptions

    /// HTTP request timeout used when forwarding STDIO messages.
    public var requestTimeout: TimeInterval

    /// Creates STDIO adapter configuration.
    public init(
        endpoint: XcodeMCPProxyAdapterEndpointResolutionOptions = .init(),
        requestTimeout: TimeInterval = 300
    ) {
        self.endpoint = endpoint
        self.requestTimeout = requestTimeout
    }
}

/// Facade for running the STDIO compatibility adapter against the proxy server.
public final class XcodeMCPProxyStdioAdapter: Sendable {
    /// Top-level action for an adapter launch invocation.
    public enum LaunchAction: Equatable, Sendable {
        /// Print usage and exit.
        case showHelp

        /// Print version information and exit.
        case showVersion

        /// Start the STDIO adapter.
        case start
    }

    /// Normalized STDIO adapter launch options.
    public struct LaunchOptions: Equatable, Sendable {
        /// Executable name resolved from argv.
        public let executableName: String

        /// HTTP request timeout used when forwarding STDIO messages.
        public let requestTimeout: TimeInterval

        /// Creates normalized adapter launch options.
        public init(executableName: String, requestTimeout: TimeInterval) {
            self.executableName = executableName
            self.requestTimeout = requestTimeout
        }
    }

    /// Resolved launch plan for `xcode-mcp-proxy`.
    public struct LaunchPlan: Equatable, Sendable {
        /// Top-level action to execute.
        public let action: LaunchAction

        /// Public adapter configuration. This is present for `.start` plans and
        /// absent for display-only plans.
        public let configuration: XcodeMCPProxyStdioAdapterConfiguration?

        /// Resolved upstream endpoint. This is present for `.start` plans.
        public let endpoint: XcodeMCPProxyAdapterEndpoint?

        /// Normalized launch options.
        public let options: LaunchOptions

        /// Usage text for help or validation failures.
        public let usage: String

        /// Version line for version display.
        public let versionLine: String

        /// Creates an adapter launch plan.
        public init(
            action: LaunchAction,
            configuration: XcodeMCPProxyStdioAdapterConfiguration?,
            endpoint: XcodeMCPProxyAdapterEndpoint?,
            options: LaunchOptions,
            usage: String,
            versionLine: String
        ) {
            self.action = action
            self.configuration = configuration
            self.endpoint = endpoint
            self.options = options
            self.usage = usage
            self.versionLine = versionLine
        }
    }

    /// Error raised while resolving adapter launch arguments.
    public struct LaunchResolutionError: Error, CustomStringConvertible, Equatable, Sendable {
        /// Preferred command-line presentation for the error.
        public enum Presentation: Equatable, Sendable {
            /// Print only the message.
            case plain

            /// Print the message followed by adapter usage.
            case fullUsage

            /// Print the message and a server help hint.
            case serverOnlyFlagHint
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

    /// Log callbacks used by the adapter launcher.
    package struct LogSink {
        package var error: (String) -> Void
        package var info: (String, Logger.Metadata) -> Void

        package init(
            error: @escaping (String) -> Void,
            info: @escaping (String, Logger.Metadata) -> Void
        ) {
            self.error = error
            self.info = info
        }
    }

    package struct ParsedLaunchOptions {
        var requestTimeout: TimeInterval
        var explicitURL: String?
        var explicitURLLabel: String

        init(
            requestTimeout: TimeInterval = 300,
            explicitURL: String? = nil,
            explicitURLLabel: String = "explicit URL"
        ) {
            self.requestTimeout = requestTimeout
            self.explicitURL = explicitURL
            self.explicitURLLabel = explicitURLLabel
        }
    }

    /// Resolved Streamable HTTP endpoint used by this adapter.
    public let endpoint: XcodeMCPProxyAdapterEndpoint

    private let adapter: StdioAdapter

    /// Creates an adapter by resolving the endpoint from configuration.
    public convenience init(
        configuration: XcodeMCPProxyStdioAdapterConfiguration =
            XcodeMCPProxyStdioAdapterConfiguration(),
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) throws {
        let endpoint = try XcodeMCPProxyAdapterEndpointResolver().resolve(configuration.endpoint)
        self.init(
            endpoint: endpoint,
            requestTimeout: configuration.requestTimeout,
            input: input,
            output: output
        )
    }

    /// Creates an adapter for an already resolved endpoint.
    public convenience init(
        endpoint: XcodeMCPProxyAdapterEndpoint,
        requestTimeout: TimeInterval = 300,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        self.init(
            endpoint: endpoint,
            requestTimeout: requestTimeout,
            input: input,
            output: output,
            shutdownPolicy: .live
        )
    }

    package init(
        endpoint: XcodeMCPProxyAdapterEndpoint,
        requestTimeout: TimeInterval,
        input: FileHandle,
        output: FileHandle,
        shutdownPolicy: StdioAdapterShutdownPolicy
    ) {
        self.endpoint = endpoint
        self.adapter = StdioAdapter(
            upstreamURL: endpoint.url,
            requestTimeout: requestTimeout,
            input: input,
            output: output,
            shutdownPolicy: shutdownPolicy
        )
    }

    /// Starts reading STDIO input and forwarding messages to the proxy endpoint.
    public func start() async {
        await adapter.start()
    }

    /// Waits until the adapter finishes.
    public func wait() async {
        await adapter.wait()
    }

    /// Stops the adapter.
    public func stop() async {
        await adapter.stop()
    }

    /// CLI usage for `xcode-mcp-proxy`.
    public static func adapterUsage(
        discoveryFileURL: URL = XcodeMCPProxyAdapterEndpointResolver.discoveryFileURL()
    ) -> String {
        """
        Usage:
          xcode-mcp-proxy [options]

        Description:
          STDIO compatibility adapter that forwards MCP traffic to a running xcode-mcp-proxy-server (Streamable HTTP).

        Options:
          --request-timeout seconds  Request timeout (default: 300, 0 disables)
          --url url                  Explicit upstream URL (default: env/discovery/http://localhost:8765/mcp)
          --version                  Show version
          -h, --help                 Show help

        Environment:
          XCODE_MCP_PROXY_ENDPOINT   Upstream proxy URL (overrides discovery)

        Notes:
          - Proxy server: xcode-mcp-proxy-server
          - --config is only supported by xcode-mcp-proxy-server
          - Discovery file: \(discoveryFileURL.path)
        """
    }

    /// Formats a CLI-compatible adapter version line.
    public static func adapterVersionLine(arguments: [String]) -> String {
        XcodeMCPProxyServer.productMetadata.versionLine(
            arguments: arguments,
            defaultExecutableName: "xcode-mcp-proxy"
        )
    }

    /// Rewrites the legacy `--url` spelling to the equivalent `--stdio` form.
    public static func rewriteURLFlagToStdio(_ arguments: [String]) throws -> [String] {
        var rewritten: [String] = []
        rewritten.reserveCapacity(arguments.count + 1)
        var didRewrite = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--url" {
                guard !didRewrite else {
                    throw LaunchResolutionError(
                        message: "--url may only be specified once.",
                        presentation: .fullUsage
                    )
                }
                guard index + 1 < arguments.count else {
                    throw LaunchResolutionError(
                        message: "--url requires a value (http/https URL).",
                        presentation: .fullUsage
                    )
                }
                let value = arguments[index + 1]
                guard !value.hasPrefix("-") else {
                    throw LaunchResolutionError(
                        message: "--url requires a value (http/https URL).",
                        presentation: .fullUsage
                    )
                }
                rewritten.append("--stdio")
                rewritten.append(value)
                didRewrite = true
                index += 2
                continue
            }

            if argument.hasPrefix("--url=") {
                guard !didRewrite else {
                    throw LaunchResolutionError(
                        message: "--url may only be specified once.",
                        presentation: .fullUsage
                    )
                }
                let value = String(argument.dropFirst("--url=".count))
                guard !value.isEmpty else {
                    throw LaunchResolutionError(
                        message: "--url requires a value (http/https URL).",
                        presentation: .fullUsage
                    )
                }
                rewritten.append("--stdio")
                rewritten.append(value)
                didRewrite = true
                index += 1
                continue
            }

            rewritten.append(argument)
            index += 1
        }

        return rewritten
    }

    /// Resolves argv and environment into an adapter launch plan.
    public static func resolveLaunchPlan(
        arguments: [String],
        environment: [String: String]
    ) throws -> LaunchPlan {
        let scan = ProxyCLIInvocationScanner.scanAdapter(arguments)
        let displayOptions = LaunchOptions(
            executableName: executableName(
                arguments: arguments,
                defaultExecutableName: "xcode-mcp-proxy"
            ),
            requestTimeout: 300
        )
        let versionLine = adapterVersionLine(arguments: arguments)

        if scan.showHelp {
            return LaunchPlan(
                action: .showHelp,
                configuration: nil,
                endpoint: nil,
                options: displayOptions,
                usage: adapterUsage(),
                versionLine: versionLine
            )
        }
        if scan.showVersion {
            return LaunchPlan(
                action: .showVersion,
                configuration: nil,
                endpoint: nil,
                options: displayOptions,
                usage: adapterUsage(),
                versionLine: versionLine
            )
        }

        if scan.usesRemovedURLHelper {
            throw LaunchResolutionError(
                message: "url helper mode was removed; configure your HTTP client with a concrete URL (default: http://localhost:8765/mcp).",
                presentation: .plain
            )
        }

        if let removedFlagMessage = scan.removedFlagMessage {
            throw LaunchResolutionError(message: removedFlagMessage, presentation: .plain)
        }

        if scan.serverOnlyFlag != nil {
            throw LaunchResolutionError(
                message: "This option is only supported by xcode-mcp-proxy-server (proxy server).",
                presentation: .serverOnlyFlagHint
            )
        }

        if scan.hasExplicitURL && scan.hasStdioFlag {
            throw LaunchResolutionError(
                message: "Use either --url or --stdio (not both).",
                presentation: .fullUsage
            )
        }

        let parsed = try parseLaunchOptions(arguments)
        let endpointConfiguration = XcodeMCPProxyAdapterEndpointResolutionOptions(
            explicitURL: parsed.explicitURL,
            explicitURLLabel: parsed.explicitURLLabel,
            environment: environment
        )
        let configuration = XcodeMCPProxyStdioAdapterConfiguration(
            endpoint: endpointConfiguration,
            requestTimeout: parsed.requestTimeout
        )
        let endpoint: XcodeMCPProxyAdapterEndpoint
        do {
            endpoint = try XcodeMCPProxyAdapterEndpointResolver().resolve(endpointConfiguration)
        } catch let error as XcodeMCPProxyAdapterEndpointResolver.Error {
            throw LaunchResolutionError(message: error.description, presentation: .fullUsage)
        }

        return LaunchPlan(
            action: .start,
            configuration: configuration,
            endpoint: endpoint,
            options: LaunchOptions(
                executableName: displayOptions.executableName,
                requestTimeout: parsed.requestTimeout
            ),
            usage: adapterUsage(),
            versionLine: versionLine
        )
    }

    package static func parseLaunchOptions(_ arguments: [String]) throws -> ParsedLaunchOptions {
        var options = ParsedLaunchOptions()
        var index = 1
        var didReadURLFlag = false

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--request-timeout":
                guard index + 1 < arguments.count else {
                    throw LaunchResolutionError(
                        message: "--request-timeout requires seconds",
                        presentation: .fullUsage
                    )
                }
                if let parsed = TimeInterval(arguments[index + 1]) {
                    options.requestTimeout = parsed
                }
                index += 2
            case "--url":
                guard didReadURLFlag == false else {
                    throw LaunchResolutionError(
                        message: "--url may only be specified once.",
                        presentation: .fullUsage
                    )
                }
                guard index + 1 < arguments.count else {
                    throw LaunchResolutionError(
                        message: "--url requires a value (http/https URL).",
                        presentation: .fullUsage
                    )
                }
                let value = arguments[index + 1]
                guard !value.hasPrefix("-") else {
                    throw LaunchResolutionError(
                        message: "--url requires a value (http/https URL).",
                        presentation: .fullUsage
                    )
                }
                options.explicitURL = value
                options.explicitURLLabel = "--url"
                didReadURLFlag = true
                index += 2
            case let value where value.hasPrefix("--url="):
                guard didReadURLFlag == false else {
                    throw LaunchResolutionError(
                        message: "--url may only be specified once.",
                        presentation: .fullUsage
                    )
                }
                let explicitURL = String(value.dropFirst("--url=".count))
                guard !explicitURL.isEmpty else {
                    throw LaunchResolutionError(
                        message: "--url requires a value (http/https URL).",
                        presentation: .fullUsage
                    )
                }
                options.explicitURL = explicitURL
                options.explicitURLLabel = "--url"
                didReadURLFlag = true
                index += 1
            case "--stdio":
                if index + 1 < arguments.count {
                    let value = arguments[index + 1]
                    if !value.hasPrefix("-") {
                        options.explicitURL = value
                        options.explicitURLLabel = "--stdio"
                        index += 2
                        continue
                    }
                }
                index += 1
            case "-h", "--help", "--version":
                index += 1
            default:
                throw LaunchResolutionError(
                    message: "Unknown argument: \(argument)",
                    presentation: .fullUsage
                )
            }
        }

        return options
    }

    private static func executableName(arguments: [String], defaultExecutableName: String) -> String {
        guard let rawExecutable = arguments.first, !rawExecutable.isEmpty else {
            return defaultExecutableName
        }

        let name = URL(fileURLWithPath: rawExecutable).lastPathComponent
        return name.isEmpty ? defaultExecutableName : name
    }
}

extension XcodeMCPProxyStdioAdapter {
    package protocol LaunchAdapter {
        func start() async
        func wait() async
    }

    package struct Launcher {
        package struct Dependencies {
            package var makeLogSink: () -> XcodeMCPProxyStdioAdapter.LogSink
            package var makeAdapter:
                (XcodeMCPProxyAdapterEndpoint, TimeInterval, FileHandle, FileHandle) -> any LaunchAdapter
            package var input: FileHandle
            package var output: FileHandle

            package init(
                makeLogSink: @escaping () -> XcodeMCPProxyStdioAdapter.LogSink,
                makeAdapter: @escaping (
                    XcodeMCPProxyAdapterEndpoint,
                    TimeInterval,
                    FileHandle,
                    FileHandle
                ) -> any LaunchAdapter,
                input: FileHandle,
                output: FileHandle
            ) {
                self.makeLogSink = makeLogSink
                self.makeAdapter = makeAdapter
                self.input = input
                self.output = output
            }

            package static var live: Self {
                Self(
                    makeLogSink: {
                        let logger = XcodeMCPProxyLogging.make("cli")
                        return XcodeMCPProxyStdioAdapter.LogSink(
                            error: { logger.error("\($0)") },
                            info: { message, metadata in
                                logger.info("\(message)", metadata: metadata)
                            }
                        )
                    },
                    makeAdapter: { endpoint, requestTimeout, input, output in
                        XcodeMCPProxyStdioAdapter(
                            endpoint: endpoint,
                            requestTimeout: requestTimeout,
                            input: input,
                            output: output
                        )
                    },
                    input: .standardInput,
                    output: .standardOutput
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
            stderr: ((String) -> Void)? = nil
        ) async -> Int32 {
            do {
                let plan = try XcodeMCPProxyStdioAdapter.resolveLaunchPlan(
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
                case .start:
                    return await startAdapter(from: plan, environment: environment, stderr: stderr)
                }
            } catch let error as XcodeMCPProxyStdioAdapter.LaunchResolutionError {
                let logSink = makeLogSink(stderr: stderr)
                switch error.presentation {
                case .plain:
                    logSink.error(error.description)
                case .fullUsage:
                    logSink.error(error.description)
                    logSink.error(XcodeMCPProxyStdioAdapter.adapterUsage())
                case .serverOnlyFlagHint:
                    logSink.error(error.description)
                    logSink.error("Run: xcode-mcp-proxy-server --help")
                }
                return 1
            } catch {
                makeLogSink(stderr: stderr).error("error: \(error)")
                return 1
            }
        }

        private func startAdapter(
            from plan: XcodeMCPProxyStdioAdapter.LaunchPlan,
            environment: [String: String],
            stderr: ((String) -> Void)?
        ) async -> Int32 {
            guard let endpoint = plan.endpoint else {
                makeLogSink(stderr: stderr).error("adapter launch plan is missing endpoint")
                return 1
            }

            let logSink = makeLogSink(stderr: stderr)
            logResolvedUpstream(endpoint: endpoint, environment: environment, logSink: logSink)

            let adapter = dependencies.makeAdapter(
                endpoint,
                plan.options.requestTimeout,
                dependencies.input,
                dependencies.output
            )
            await adapter.start()
            await adapter.wait()
            return 0
        }

        private func logResolvedUpstream(
            endpoint: XcodeMCPProxyAdapterEndpoint,
            environment: [String: String],
            logSink: XcodeMCPProxyStdioAdapter.LogSink
        ) {
            let url = endpoint.url.absoluteString
            switch endpoint.source {
            case .discovery:
                let discoveryPath = XcodeMCPProxyAdapterEndpointResolver.discoveryFileURL(
                    environment: environment
                ).path
                logSink.info(
                    "STDIO upstream resolved from discovery file",
                    [
                        "url": "\(url)",
                        "path": "\(discoveryPath)",
                    ]
                )
            case .fallback:
                logSink.info(
                    "STDIO upstream fell back to default",
                    ["url": "\(url)"]
                )
            case .environment:
                logSink.info(
                    "STDIO upstream resolved from XCODE_MCP_PROXY_ENDPOINT",
                    ["url": "\(url)"]
                )
            case .explicit:
                logSink.info(
                    "STDIO upstream resolved from CLI",
                    ["url": "\(url)"]
                )
            }
        }

        private func makeLogSink(stderr: ((String) -> Void)?) -> XcodeMCPProxyStdioAdapter.LogSink {
            let logSink = dependencies.makeLogSink()
            guard let stderr else {
                return logSink
            }
            return XcodeMCPProxyStdioAdapter.LogSink(
                error: stderr,
                info: logSink.info
            )
        }
    }
}

extension XcodeMCPProxyStdioAdapter: XcodeMCPProxyStdioAdapter.LaunchAdapter {}
