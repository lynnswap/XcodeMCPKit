import Foundation

package struct ProxyConfig: Sendable {
    package enum Transport: String, CaseIterable, Sendable {
        case http
        case stdio
    }

    package enum StdioUpstreamSource: String, Sendable {
        case explicit
        case environment
        case discovery
        case fallback
    }

    package enum RefreshCodeIssuesMode: String, Sendable {
        case proxy
        case upstream
    }

    package enum ValidationError: Error, CustomStringConvertible {
        case unsupportedProtocolVersion(String)

        package var description: String {
            switch self {
            case .unsupportedProtocolVersion(let protocolVersion):
                return "upstream_handshake.protocolVersion must be \(MCPProtocolVersion.current); \(protocolVersion) is not supported"
            }
        }
    }

    package enum File {}

    package var listenHost: String
    package var listenPort: Int
    package var upstreamCommand: String
    package var upstreamArgs: [String]
    package var upstreamProcessCount: Int
    package var upstreamSessionID: String?
    package var maxBodyBytes: Int
    package var requestTimeout: TimeInterval
    package var configPath: String?
    package var transport: ProxyConfig.Transport
    package var stdioUpstreamURL: URL?
    package var stdioUpstreamSource: ProxyConfig.StdioUpstreamSource?
    package var discoveryFileURL: URL?
    package var prewarmToolsList: Bool
    package var autoApproveXcodeDialog: Bool
    package var refreshCodeIssuesMode: ProxyConfig.RefreshCodeIssuesMode
    package var disabledToolNames: Set<String>
    package var initializeParamsOverride: ProxyConfig.File.InitializeHandshakeOverride?

    package init(
        listenHost: String,
        listenPort: Int,
        upstreamCommand: String,
        upstreamArgs: [String],
        upstreamProcessCount: Int = 1,
        upstreamSessionID: String? = nil,
        maxBodyBytes: Int,
        requestTimeout: TimeInterval,
        configPath: String? = nil,
        transport: ProxyConfig.Transport = .http,
        stdioUpstreamURL: URL? = nil,
        stdioUpstreamSource: ProxyConfig.StdioUpstreamSource? = nil,
        discoveryFileURL: URL? = nil,
        prewarmToolsList: Bool = true,
        autoApproveXcodeDialog: Bool = false,
        refreshCodeIssuesMode: ProxyConfig.RefreshCodeIssuesMode = .proxy,
        disabledToolNames: Set<String>? = nil
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.upstreamCommand = upstreamCommand
        self.upstreamArgs = upstreamArgs
        self.upstreamProcessCount = upstreamProcessCount
        self.upstreamSessionID = upstreamSessionID
        self.maxBodyBytes = maxBodyBytes
        self.requestTimeout = requestTimeout
        self.configPath = configPath
        self.transport = transport
        self.stdioUpstreamURL = stdioUpstreamURL
        self.stdioUpstreamSource = stdioUpstreamSource
        self.discoveryFileURL = discoveryFileURL
        self.prewarmToolsList = prewarmToolsList
        self.autoApproveXcodeDialog = autoApproveXcodeDialog
        self.refreshCodeIssuesMode = refreshCodeIssuesMode
        self.disabledToolNames = disabledToolNames ?? []
        if configPath != nil {
            loadFileConfig(preserveDisabledToolNames: disabledToolNames != nil)
        }
    }

    /// Reads the TOML file config (disabled tools, initialize-params
    /// override) from `configPath` and stores the decoded values. This is
    /// the only place the file is read; consumers use the stored values.
    package mutating func loadFileConfig() {
        loadFileConfig(preserveDisabledToolNames: false)
    }

    private mutating func loadFileConfig(preserveDisabledToolNames: Bool) {
        let logger = ProxyLogging.make("config")
        if preserveDisabledToolNames == false {
            disabledToolNames = ProxyConfig.File.Loader.loadDisabledToolNames(
                configPath: configPath,
                logger: logger
            )
        }
        initializeParamsOverride = ProxyConfig.File.Loader.loadInitializeParamsOverride(
            configPath: configPath,
            logger: logger
        )
    }

    package func validateModernProtocolConfiguration() throws {
        guard let protocolVersion = initializeParamsOverride?.protocolVersion else {
            return
        }
        guard MCPProtocolVersion.isSupported(protocolVersion) else {
            throw ValidationError.unsupportedProtocolVersion(protocolVersion)
        }
    }
}

package enum CLIError: Error, CustomStringConvertible {
    case message(String)

    package var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

package struct CLIParser {
    private static let defaultStdioUpstream = "http://localhost:8765/mcp"
    private static let stdioEndpointEnv = "XCODE_MCP_PROXY_ENDPOINT"
    private static let refreshCodeIssuesModeEnv = "MCP_XCODE_REFRESH_CODE_ISSUES_MODE"
    package static let configPathEnv = "MCP_XCODE_CONFIG"
    package static let removedLazyInitMessage =
        "The proxy always uses eager initialization; --lazy-init has been removed."
    package static let removedXcodePIDMessage =
        "Xcode PID support has been removed; --xcode-pid is no longer supported."

    package static func parse(args: [String], environment: [String: String]) throws -> ProxyConfig {
        return try parse(
            args: args,
            environment: environment,
            discoveryOverrideURL: ProxyFilesystemLocations.discoveryFileURL(environment: environment),
            discoveryClient: .liveValue
        )
    }

    package static func parse(
        args: [String],
        environment: [String: String],
        discoveryOverrideURL: URL?,
        discoveryClient: DiscoveryClient = .liveValue
    ) throws -> ProxyConfig {
        var listenHost = "localhost"
        var listenPort = 0
        var upstreamCommand = "xcrun"
        var upstreamArgs = ["mcpbridge"]
        var upstreamProcessCount = 1
        var upstreamSessionID: String?
        var maxBodyBytes = 1_048_576
        var requestTimeout: TimeInterval = 300
        var configPath: String?
        var stdioUpstreamURL: URL?
        var stdioUpstreamSource: ProxyConfig.StdioUpstreamSource?
        var autoApproveXcodeDialog = false
        var refreshCodeIssuesMode: ProxyConfig.RefreshCodeIssuesMode = .proxy
        var hasExplicitRefreshCodeIssuesMode = false

        var index = 1
        while index < args.count {
            let arg = args[index]
            guard let flag = CLI.Flag(rawValue: arg) else {
                throw CLIError.message("Unknown argument: \(arg)")
            }
            switch flag {
            case .listen:
                guard index + 1 < args.count else {
                    throw CLIError.message("--listen requires host:port")
                }
                let value = args[index + 1]
                if value.contains(":") {
                    let parsed = try parseListen(value)
                    listenHost = parsed.host
                    listenPort = parsed.port
                } else if let port = Int(value) {
                    listenPort = port
                } else {
                    listenHost = value
                }
                index += 2
            case .host:
                guard index + 1 < args.count else {
                    throw CLIError.message("--host requires a value")
                }
                listenHost = args[index + 1]
                index += 2
            case .port:
                guard index + 1 < args.count else {
                    throw CLIError.message("--port requires a value")
                }
                listenPort = Int(args[index + 1]) ?? listenPort
                index += 2
            case .upstreamCommand:
                guard index + 1 < args.count else {
                    throw CLIError.message("--upstream-command requires a value")
                }
                upstreamCommand = args[index + 1]
                index += 2
            case .upstreamArgs:
                guard index + 1 < args.count else {
                    throw CLIError.message("--upstream-args requires a value")
                }
                let value = args[index + 1]
                let parts = value.split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
                upstreamArgs = parts.isEmpty ? [] : parts
                index += 2
            case .upstreamArg:
                guard index + 1 < args.count else {
                    throw CLIError.message("--upstream-arg requires a value")
                }
                upstreamArgs.append(args[index + 1])
                index += 2
            case .upstreamProcesses:
                guard index + 1 < args.count else {
                    throw CLIError.message("--upstream-processes requires a value")
                }
                guard let parsed = Int(args[index + 1]), (1...10).contains(parsed) else {
                    throw CLIError.message("--upstream-processes must be an integer in 1..10")
                }
                upstreamProcessCount = parsed
                index += 2
            case .xcodePID:
                throw CLIError.message(Self.removedXcodePIDMessage)
            case .sessionID:
                guard index + 1 < args.count else {
                    throw CLIError.message("--session-id requires a value")
                }
                upstreamSessionID = args[index + 1]
                index += 2
            case .maxBodyBytes:
                guard index + 1 < args.count else {
                    throw CLIError.message("--max-body-bytes requires a value")
                }
                maxBodyBytes = Int(args[index + 1]) ?? maxBodyBytes
                index += 2
            case .requestTimeout:
                guard index + 1 < args.count else {
                    throw CLIError.message("--request-timeout requires seconds")
                }
                requestTimeout = TimeInterval(args[index + 1]) ?? requestTimeout
                index += 2
            case .config:
                guard index + 1 < args.count else {
                    throw CLIError.message("--config requires a value")
                }
                configPath = args[index + 1]
                index += 2
            case .autoApprove:
                autoApproveXcodeDialog = true
                index += 1
            case .refreshCodeIssuesMode:
                guard index + 1 < args.count else {
                    throw CLIError.message("--refresh-code-issues-mode requires proxy|upstream")
                }
                guard let parsed = ProxyConfig.RefreshCodeIssuesMode(rawValue: args[index + 1]) else {
                    throw CLIError.message("--refresh-code-issues-mode must be proxy or upstream")
                }
                refreshCodeIssuesMode = parsed
                hasExplicitRefreshCodeIssuesMode = true
                index += 2
            case .lazyInit:
                throw CLIError.message(Self.removedLazyInitMessage)
            case .stdio:
                if index + 1 < args.count {
                    let candidate = args[index + 1]
                    if !candidate.hasPrefix("-") {
                        stdioUpstreamURL = try parseHTTPURL(candidate, label: "--stdio")
                        stdioUpstreamSource = .explicit
                        index += 2
                        break
                    }
                }
                let resolved = try resolveDefaultStdioUpstream(
                    environment: environment,
                    discoveryOverrideURL: discoveryOverrideURL,
                    discoveryClient: discoveryClient
                )
                stdioUpstreamURL = resolved.url
                stdioUpstreamSource = resolved.source
                index += 1
            case .helpShort, .help, .version, .url, .printURL, .dryRun, .forceRestart,
                 .prefix, .bindir:
                throw CLIError.message("Unknown argument: \(arg)")
            }
        }

        if upstreamSessionID == nil, let value = environment["MCP_XCODE_SESSION_ID"], !value.isEmpty {
            upstreamSessionID = value
        }
        if let value = nonEmpty(environment[refreshCodeIssuesModeEnv]),
            hasExplicitRefreshCodeIssuesMode == false
        {
            guard let parsed = ProxyConfig.RefreshCodeIssuesMode(rawValue: value) else {
                throw CLIError.message(
                    "\(refreshCodeIssuesModeEnv) must be proxy or upstream"
                )
            }
            refreshCodeIssuesMode = parsed
        }
        if configPath == nil, let value = nonEmpty(environment[configPathEnv]) {
            configPath = value
        }
        let transport: ProxyConfig.Transport = stdioUpstreamURL == nil ? .http : .stdio

        return ProxyConfig(
            listenHost: listenHost,
            listenPort: listenPort,
            upstreamCommand: upstreamCommand,
            upstreamArgs: upstreamArgs,
            upstreamProcessCount: upstreamProcessCount,
            upstreamSessionID: upstreamSessionID,
            maxBodyBytes: maxBodyBytes,
            requestTimeout: requestTimeout,
            configPath: configPath,
            transport: transport,
            stdioUpstreamURL: stdioUpstreamURL,
            stdioUpstreamSource: stdioUpstreamSource,
            discoveryFileURL: discoveryOverrideURL,
            autoApproveXcodeDialog: autoApproveXcodeDialog,
            refreshCodeIssuesMode: refreshCodeIssuesMode
        )
    }

    private static func parseListen(_ value: String) throws -> (host: String, port: Int) {
        guard let colonIndex = value.lastIndex(of: ":") else {
            throw CLIError.message("--listen expects host:port (got \(value))")
        }
        let hostPart = String(value[..<colonIndex])
        let portPart = String(value[value.index(after: colonIndex)...])
        guard let port = Int(portPart), port >= 0 else {
            throw CLIError.message("--listen expects host:port (got \(value))")
        }
        let host = hostPart.isEmpty ? "localhost" : hostPart
        return (host, port)
    }

    private static func parseHTTPURL(_ value: String, label: String) throws -> URL {
        guard let url = URL(string: value),
              let scheme = url.scheme,
              scheme == "http" || scheme == "https" else {
            throw CLIError.message("\(label) must be an http/https URL")
        }
        return url
    }

    private static func resolveDefaultStdioUpstream(
        environment: [String: String],
        discoveryOverrideURL: URL? = nil,
        discoveryClient: DiscoveryClient
    ) throws -> (url: URL, source: ProxyConfig.StdioUpstreamSource) {
        if let raw = nonEmpty(environment[Self.stdioEndpointEnv]) {
            return (try parseHTTPURL(raw, label: Self.stdioEndpointEnv), .environment)
        }
        if let record = discoveryClient.read(discoveryOverrideURL),
           let resolved = try? parseHTTPURL(record.url, label: "discovery") {
            return (resolved, .discovery)
        }
        guard let defaultURL = URL(string: Self.defaultStdioUpstream) else {
            throw CLIError.message("Default stdio upstream URL is invalid")
        }
        return (defaultURL, .fallback)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
