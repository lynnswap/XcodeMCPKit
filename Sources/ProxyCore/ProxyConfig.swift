import Foundation

public enum ProxyTransport: String, CaseIterable, Sendable {
    case http
    case stdio
}

public enum StdioUpstreamSource: String, Sendable {
    case explicit
    case environment
    case discovery
    case fallback
}

public enum RefreshCodeIssuesMode: String, Sendable {
    case proxy
    case upstream
}

public struct ProxyConfig: Sendable {
    public var listenHost: String
    public var listenPort: Int
    public var upstreamCommand: String
    public var upstreamArgs: [String]
    public var upstreamProcessCount: Int
    public var upstreamSessionID: String?
    public var maxBodyBytes: Int
    public var requestTimeout: TimeInterval
    public var configPath: String?
    public var transport: ProxyTransport
    public var stdioUpstreamURL: URL?
    public var stdioUpstreamSource: StdioUpstreamSource?
    public var discoveryFileURL: URL?
    public var prewarmToolsList: Bool
    public var autoApproveXcodeDialog: Bool
    public var refreshCodeIssuesMode: RefreshCodeIssuesMode
    public var disabledToolNames: Set<String>
    package var initializeParamsOverride: ProxyInitializeHandshakeOverride?

    public init(
        listenHost: String,
        listenPort: Int,
        upstreamCommand: String,
        upstreamArgs: [String],
        upstreamProcessCount: Int = 1,
        upstreamSessionID: String? = nil,
        maxBodyBytes: Int,
        requestTimeout: TimeInterval,
        configPath: String? = nil,
        transport: ProxyTransport = .http,
        stdioUpstreamURL: URL? = nil,
        stdioUpstreamSource: StdioUpstreamSource? = nil,
        discoveryFileURL: URL? = nil,
        prewarmToolsList: Bool = true,
        autoApproveXcodeDialog: Bool = false,
        refreshCodeIssuesMode: RefreshCodeIssuesMode = .proxy,
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
        if disabledToolNames == nil, configPath != nil {
            loadFileConfig()
        }
    }

    /// Reads the TOML file config (disabled tools, initialize-params
    /// override) from `configPath` and stores the decoded values. This is
    /// the only place the file is read; consumers use the stored values.
    public mutating func loadFileConfig() {
        let logger = ProxyLogging.make("config")
        disabledToolNames = ProxyFileConfigLoader.loadDisabledToolNames(
            configPath: configPath,
            logger: logger
        )
        initializeParamsOverride = ProxyFileConfigLoader.loadInitializeParamsOverride(
            configPath: configPath,
            logger: logger
        )
    }
}

public enum CLIError: Error, CustomStringConvertible {
    case message(String)

    public var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

public struct CLIParser {
    private static let defaultStdioUpstream = "http://localhost:8765/mcp"
    private static let stdioEndpointEnv = "XCODE_MCP_PROXY_ENDPOINT"
    private static let refreshCodeIssuesModeEnv = "MCP_XCODE_REFRESH_CODE_ISSUES_MODE"
    public static let configPathEnv = "MCP_XCODE_CONFIG"
    public static let removedLazyInitMessage =
        "The proxy always uses eager initialization; --lazy-init has been removed."
    public static let removedXcodePIDMessage =
        "Xcode PID support has been removed; --xcode-pid is no longer supported."

    public static func parse(args: [String], environment: [String: String]) throws -> ProxyConfig {
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
        var stdioUpstreamSource: StdioUpstreamSource?
        var autoApproveXcodeDialog = false
        var refreshCodeIssuesMode: RefreshCodeIssuesMode = .proxy
        var hasExplicitRefreshCodeIssuesMode = false

        var index = 1
        while index < args.count {
            let arg = args[index]
            guard let flag = ProxyCLIFlag(rawValue: arg) else {
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
                guard let parsed = RefreshCodeIssuesMode(rawValue: args[index + 1]) else {
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
            guard let parsed = RefreshCodeIssuesMode(rawValue: value) else {
                throw CLIError.message(
                    "\(refreshCodeIssuesModeEnv) must be proxy or upstream"
                )
            }
            refreshCodeIssuesMode = parsed
        }
        if configPath == nil, let value = nonEmpty(environment[configPathEnv]) {
            configPath = value
        }
        let transport: ProxyTransport = stdioUpstreamURL == nil ? .http : .stdio

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
    ) throws -> (url: URL, source: StdioUpstreamSource) {
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
