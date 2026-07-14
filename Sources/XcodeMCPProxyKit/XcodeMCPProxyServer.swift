import Foundation
import Logging
import XcodeMCPKit
import XcodeMCPPermissionAutomation
import XcodeMCPProxyHTTP
import XcodeMCPProxyRuntime

/// Public configuration for an embedded Xcode MCP proxy server.
///
/// This type is the stable server configuration surface for
/// `XcodeMCPProxyKit`. Lower-level parser, discovery, filesystem, and
/// session-routing types stay internal to the targets that own them.
public struct XcodeMCPProxyServerConfiguration: Equatable, Sendable {
    /// Address that the Streamable HTTP server binds.
    public struct BindAddress: Equatable, Sendable {
        /// Hostname or IP address for the server socket.
        public var host: String

        /// TCP port for the server socket.
        ///
        /// Use `0` to request an ephemeral port from the operating system.
        public var port: Int

        /// Creates a bind address.
        public init(host: String = "localhost", port: Int = 8765) {
            self.host = host
            self.port = port
        }

        /// Creates a loopback bind address.
        public static func localhost(port: Int = 8765) -> Self {
            Self(host: "localhost", port: port)
        }
    }

    /// Upstream `mcpbridge` process policy.
    public enum Upstream: Equatable, Sendable {
        /// Use Xcode's default `xcrun mcpbridge` invocation.
        case defaultMCPBridge(processesPerXcode: Int = 1, sessionID: String? = nil)

        /// Use an explicit upstream command and arguments.
        case custom(
            command: String,
            arguments: [String],
            processesPerXcode: Int = 1,
            sessionID: String? = nil
        )

        var invocation: MCPBridgeInvocation {
            switch self {
            case .defaultMCPBridge:
                return .defaultMCPBridge
            case .custom(let command, let arguments, _, _):
                return MCPBridgeInvocation(command: command, arguments: arguments)
            }
        }

        var command: String {
            invocation.command
        }

        var arguments: [String] {
            invocation.arguments
        }

        var processesPerXcode: Int {
            switch self {
            case .defaultMCPBridge(let count, _), .custom(_, _, let count, _):
                return count
            }
        }

        var sessionID: String? {
            switch self {
            case .defaultMCPBridge(_, let sessionID), .custom(_, _, _, let sessionID):
                return sessionID
            }
        }
    }

    /// Endpoint discovery file policy.
    public enum Discovery: Equatable, Sendable {
        /// Do not publish an endpoint discovery record.
        case disabled

        /// Publish to the platform default discovery location.
        case defaultLocation

        /// Publish to an explicit file URL.
        case file(URL)
    }

    /// Xcode permission dialog automation policy.
    public enum ApprovalPolicy: Equatable, Sendable {
        /// Do not automate the Xcode permission dialog.
        case manual

        /// Try to approve the Xcode permission dialog automatically.
        ///
        /// This requires macOS Accessibility permission for the host process.
        case automatic
    }

    /// How `XcodeRefreshCodeIssuesInFile` requests are served.
    public enum RefreshCodeIssuesMode: String, Equatable, Sendable {
        /// Serve refresh-code-issues requests through proxy diagnostics.
        case proxy

        /// Forward refresh-code-issues requests to the upstream Xcode MCP
        /// bridge.
        case upstream
    }

    /// Optional proxy features that affect tool behavior.
    public struct FeaturePolicy: Equatable, Sendable {
        /// Whether the proxy should prewarm the upstream tools list.
        public var prewarmToolsList: Bool

        /// Refresh-code-issues handling mode.
        public var refreshCodeIssuesMode: RefreshCodeIssuesMode

        /// Creates a feature policy.
        public init(
            prewarmToolsList: Bool = true,
            refreshCodeIssuesMode: RefreshCodeIssuesMode = .proxy
        ) {
            self.prewarmToolsList = prewarmToolsList
            self.refreshCodeIssuesMode = refreshCodeIssuesMode
        }

        /// Default feature policy.
        public static let `default` = Self()
    }

    /// Tool visibility policy applied by the proxy.
    public struct ToolPolicy: Equatable, Sendable {
        /// Tool names hidden from `tools/list` results and rejected for
        /// `tools/call` requests.
        ///
        /// Names are normalized when the server builds its runtime config:
        /// surrounding whitespace is trimmed and empty names are ignored.
        public var disabledToolNames: Set<String>

        /// Creates a tool policy.
        public init(disabledToolNames: Set<String> = []) {
            self.disabledToolNames = disabledToolNames
        }

        /// Default tool policy.
        public static let `default` = Self()
    }

    /// Initialize handshake overrides sent from the proxy to upstream
    /// `mcpbridge` processes.
    ///
    /// Non-`nil` properties override the matching values loaded from
    /// ``configurationFileURL``. Properties left as `nil` keep the file value
    /// when present, otherwise the proxy's built-in default is used.
    public struct InitializeHandshake: Equatable, Sendable {
        /// Upstream client information for the initialize handshake.
        public struct ClientInfo: Equatable, Sendable {
            /// Client name to advertise to the upstream MCP bridge.
            public var name: String?

            /// Client version to advertise to the upstream MCP bridge.
            public var version: String?

            /// Creates upstream client information.
            public init(name: String? = nil, version: String? = nil) {
                self.name = name
                self.version = version
            }
        }

        /// Protocol version to send in initialize params.
        public var protocolVersion: String?

        /// Client info to send in initialize params.
        public var clientInfo: ClientInfo?

        /// Capability object to send in initialize params.
        public var capabilities: [String: MCPJSONValue]?

        /// Creates initialize handshake overrides.
        public init(
            protocolVersion: String? = nil,
            clientInfo: ClientInfo? = nil,
            capabilities: [String: MCPJSONValue]? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.clientInfo = clientInfo
            self.capabilities = capabilities
        }
    }

    /// HTTP bind address.
    public var bindAddress: BindAddress

    /// Upstream bridge process policy.
    public var upstream: Upstream

    /// Maximum accepted HTTP request body size in bytes.
    public var maxBodyBytes: Int

    /// Request timeout. `nil` disables request timeouts.
    public var requestTimeout: Duration?

    /// Optional TOML configuration file for initialize overrides and disabled
    /// tools.
    public var configurationFileURL: URL?

    /// Explicit tool visibility policy.
    ///
    /// `nil` keeps disabled tools loaded from ``configurationFileURL``. A
    /// non-`nil` policy overrides the file's `[tools].disabled` list.
    public var toolPolicy: ToolPolicy?

    /// Explicit initialize handshake override.
    ///
    /// Non-`nil` fields override the matching file-backed
    /// `[upstream_handshake]` fields. Fields left `nil` keep the file value
    /// when present, otherwise the built-in default is used.
    public var initializeHandshake: InitializeHandshake?

    /// Endpoint discovery policy.
    public var discovery: Discovery

    /// Permission dialog automation policy.
    public var approvalPolicy: ApprovalPolicy

    /// Optional proxy feature policy.
    public var featurePolicy: FeaturePolicy

    /// Creates a public proxy server configuration.
    ///
    /// - Parameters:
    ///   - bindAddress: HTTP bind address.
    ///   - upstream: Upstream bridge process policy.
    ///   - maxBodyBytes: Maximum accepted HTTP request body size.
    ///   - requestTimeout: Request timeout, or `nil` to disable it.
    ///   - configurationFileURL: Optional TOML configuration file URL.
    ///   - discovery: Endpoint discovery policy.
    ///   - approvalPolicy: Permission dialog automation policy.
    ///   - featurePolicy: Optional proxy feature policy.
    ///   - toolPolicy: Explicit tool visibility policy.
    ///   - initializeHandshake: Explicit upstream initialize handshake override.
    public init(
        bindAddress: BindAddress = .localhost(),
        upstream: Upstream = .defaultMCPBridge(),
        maxBodyBytes: Int = 1_048_576,
        requestTimeout: Duration? = .seconds(300),
        configurationFileURL: URL? = nil,
        toolPolicy: ToolPolicy? = nil,
        initializeHandshake: InitializeHandshake? = nil,
        discovery: Discovery = .defaultLocation,
        approvalPolicy: ApprovalPolicy = .manual,
        featurePolicy: FeaturePolicy = .default
    ) {
        self.bindAddress = bindAddress
        self.upstream = upstream
        self.maxBodyBytes = maxBodyBytes
        self.requestTimeout = requestTimeout
        self.configurationFileURL = configurationFileURL
        self.toolPolicy = toolPolicy
        self.initializeHandshake = initializeHandshake
        self.discovery = discovery
        self.approvalPolicy = approvalPolicy
        self.featurePolicy = featurePolicy
    }

    init(serverProxyConfig proxyConfig: ProxyConfig) {
        self.init(
            bindAddress: BindAddress(
                host: proxyConfig.listenHost,
                port: proxyConfig.listenPort
            ),
            upstream: .custom(
                command: proxyConfig.upstreamCommand,
                arguments: proxyConfig.upstreamArgs,
                processesPerXcode: proxyConfig.upstreamProcessCount,
                sessionID: proxyConfig.upstreamSessionID
            ),
            maxBodyBytes: proxyConfig.maxBodyBytes,
            requestTimeout: proxyConfig.requestTimeout > 0
                ? .seconds(proxyConfig.requestTimeout)
                : nil,
            configurationFileURL: proxyConfig.configPath.map {
                URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
            },
            discovery: proxyConfig.discoveryFileURL.map(Discovery.file) ?? .defaultLocation,
            approvalPolicy: proxyConfig.autoApproveXcodeDialog ? .automatic : .manual,
            featurePolicy: FeaturePolicy(
                prewarmToolsList: proxyConfig.prewarmToolsList,
                refreshCodeIssuesMode: RefreshCodeIssuesMode(proxyConfig.refreshCodeIssuesMode)
            )
        )
    }

    var listenHost: String { bindAddress.host }
    var listenPort: Int { bindAddress.port }
    var upstreamCommand: String { upstream.command }
    var upstreamArguments: [String] { upstream.arguments }
    var upstreamProcessCount: Int { upstream.processesPerXcode }
    var upstreamSessionID: String? { upstream.sessionID }
    var configPath: String? { configurationFileURL?.path }
    var prewarmToolsList: Bool { featurePolicy.prewarmToolsList }
    var autoApproveXcodeDialog: Bool { approvalPolicy == .automatic }
    var refreshCodeIssuesMode: RefreshCodeIssuesMode {
        featurePolicy.refreshCodeIssuesMode
    }
}

/// Embeddable Streamable HTTP proxy server for Xcode MCP.
///
/// `XcodeMCPProxyServer` is the library boundary used by the
/// `xcode-mcp-proxy-server` executable. Construct it with
/// ``XcodeMCPProxyServerConfiguration``, call ``start()``, then keep the process
/// alive with ``waitUntilShutdown()`` until your
/// application decides to call ``shutdown()``. Start returns the resolved
/// endpoint.
///
/// The server exposes the proxy lifecycle. CLI parsing, STDIO adapter behavior,
/// and internal session routing are intentionally handled outside this public
/// type.
public final class XcodeMCPProxyServer: Sendable {
    /// A resolved Streamable HTTP proxy endpoint.
    public struct Endpoint: Equatable, Sendable {
        /// Hostname or IP address clients should connect to.
        public let host: String

        /// TCP port clients should connect to.
        public let port: Int

        /// Full MCP endpoint URL, including the `/mcp` path.
        public let url: URL

        /// Creates a resolved endpoint value.
        public init(host: String, port: Int) {
            self.host = host
            self.port = port
            self.url = Self.makeURL(host: host, port: port)
        }

        private static func makeURL(host: String, port: Int) -> URL {
            let urlHost = urlAuthorityHost(host)
            var components = URLComponents()
            components.scheme = "http"
            components.host = urlHost
            components.port = port
            components.path = "/mcp"
            if let url = components.url {
                return url
            }
            return URL(string: "http://\(urlHost):\(port)/mcp")!
        }

        private static func urlAuthorityHost(_ host: String) -> String {
            if host.contains(":"), !host.hasPrefix("[") {
                return "[\(host)]"
            }
            return host
        }
    }

    /// Errors thrown while starting or stopping a proxy server instance.
    public enum LifecycleError: Error, Equatable, Sendable {
        /// The configured listener could not bind to any requested address.
        case failedToBind

        /// The server instance has already been started.
        ///
        /// Create a new ``XcodeMCPProxyServer`` instance after calling
        /// ``shutdown()`` instead of starting the same instance again.
        case alreadyStarted

        /// The server is already shutting down.
        case shutdownInProgress

        /// A public configuration value is outside its supported domain.
        case invalidConfiguration(String)

        /// Discovery was enabled but a record could not be constructed.
        case failedToCreateDiscoveryRecord
    }

    /// A sanitized point-in-time view of server health.
    public struct Status: Equatable, Sendable {
        /// Server lifecycle phase.
        public enum Phase: Equatable, Sendable {
            case idle
            case running
            case stopping
            case stopped
        }

        /// Sanitized upstream health.
        public struct Upstream: Equatable, Sendable {
            /// Stable upstream slot identifier.
            public let id: Int

            /// Upstream process health.
            public enum Health: Equatable, Sendable {
                case starting
                case healthy
                case degraded
                case quarantined
                case stopped
            }

            /// Current upstream health.
            public let health: Health

            /// Whether the MCP initialize handshake completed.
            public let isInitialized: Bool

            /// Number of active requests assigned to this upstream.
            public let activeRequestCount: Int
        }

        /// Snapshot generation time.
        public let generatedAt: Date

        /// Lifecycle phase at snapshot time.
        public let phase: Phase

        /// Bound endpoint when the server is running or stopping.
        public let endpoint: Endpoint?

        /// Whether the proxy-level initialize handshake completed.
        public let proxyInitialized: Bool

        /// Whether a tool catalog is available.
        public let catalogAvailable: Bool

        /// Number of requests waiting for an upstream slot.
        public let queuedRequestCount: Int

        /// Sanitized upstream summaries.
        public let upstreams: [Upstream]

        init(
            generatedAt: Date,
            phase: Phase,
            endpoint: Endpoint?,
            proxyInitialized: Bool,
            catalogAvailable: Bool,
            queuedRequestCount: Int,
            upstreams: [Upstream]
        ) {
            self.generatedAt = generatedAt
            self.phase = phase
            self.endpoint = endpoint
            self.proxyInitialized = proxyInitialized
            self.catalogAvailable = catalogAvailable
            self.queuedRequestCount = queuedRequestCount
            self.upstreams = upstreams
        }
    }

    package struct PreparedConfiguration: Sendable {
        package let configuration: XcodeMCPProxyServerConfiguration
        let proxyConfig: ProxyConfig

        init(
            configuration: XcodeMCPProxyServerConfiguration,
            proxyConfig: ProxyConfig
        ) {
            self.configuration = configuration
            self.proxyConfig = proxyConfig
        }
    }

    struct Dependencies: Sendable {
        var discoveryClient: DiscoveryClient
        var executableLookupClient: ExecutableLookupClient
        var processID: @Sendable () -> Int
        var loadFileConfiguration:
            @Sendable (URL) throws -> ProxyConfig.File.LoadedConfiguration
        var makeAutoApprover:
            @Sendable (ProxyConfig, any ProxyRuntimeServing) -> any ProxyServerPermissionDialogAutoApprover
        var makeRuntime: @Sendable (ProxyRuntimeConfiguration) -> any ProxyRuntimeServing
        var makeHTTPGateway:
            @Sendable (
                ProxyHTTPConfiguration,
                any ProxyRuntimeServing,
                Logger
            ) -> any ProxyHTTPGatewayServing

        init(
            discoveryClient: DiscoveryClient = .liveValue,
            executableLookupClient: ExecutableLookupClient = .liveValue,
            processID: @escaping @Sendable () -> Int = {
                Int(ProcessInfo.processInfo.processIdentifier)
            },
            loadFileConfiguration: @escaping @Sendable (URL) throws ->
                ProxyConfig.File.LoadedConfiguration = {
                    try ProxyConfig.File.Loader.loadStrict(configURL: $0)
                },
            makeAutoApprover: @escaping @Sendable (
                ProxyConfig,
                any ProxyRuntimeServing
            ) -> any ProxyServerPermissionDialogAutoApprover,
            makeRuntime: @escaping @Sendable (ProxyRuntimeConfiguration) -> any ProxyRuntimeServing,
            makeHTTPGateway: @escaping @Sendable (
                ProxyHTTPConfiguration,
                any ProxyRuntimeServing,
                Logger
            ) -> any ProxyHTTPGatewayServing = { configuration, runtime, logger in
                ProxyHTTPGateway(
                    configuration: configuration,
                    runtime: runtime,
                    logger: logger
                )
            }
        ) {
            self.discoveryClient = discoveryClient
            self.executableLookupClient = executableLookupClient
            self.processID = processID
            self.loadFileConfiguration = loadFileConfiguration
            self.makeAutoApprover = makeAutoApprover
            self.makeRuntime = makeRuntime
            self.makeHTTPGateway = makeHTTPGateway
        }

        static var live: Self {
            let executableLookupClient = ExecutableLookupClient.liveValue
            return Self(
                executableLookupClient: executableLookupClient,
                makeAutoApprover: { config, runtime in
                    let additionalCandidates = XcodeMCPProxyServer.additionalPermissionDialogExecutableCandidates(
                        config: config,
                        executableLookupClient: executableLookupClient
                    )
                    return XcodePermissionDialogAutomation.AutoApprover(
                        configuration: .init(
                            permissionDialogProcessIDs: {
                                runtime.inventorySnapshot().permissionDialogProcessIDs
                            },
                            agentPathCandidates: {
                                let processBoundCandidates = runtime.inventorySnapshot()
                                    .xcodeTargets.map(\.mcpBridgePath)
                                return XcodePermissionDialogAutomation.AutoApprover
                                    .executablePathCandidates(
                                    additional:
                                        additionalCandidates + processBoundCandidates
                                )
                            },
                            assistantNameCandidates: {
                                Set(XcodeMCPProxyServer.permissionDialogAssistantNameCandidates(config: config))
                            },
                            agentProcessIDCandidates: {
                                XcodePermissionDialogAutomation.AutoApprover
                                    .descendantProcessIDCandidates()
                            }
                        ),
                        logger: ProxyLogging.make("xcode.permission")
                    )
                },
                makeRuntime: { config in
                    ProxyRuntime(configuration: config)
                }
            )
        }

        static func live(config _: ProxyConfig) -> Self {
            .live
        }
    }

    let configuration: XcodeMCPProxyServerConfiguration
    let dependencies: Dependencies
    let logger: Logger = ProxyLogging.make("server")
    let lifecycle: Lifecycle

    /// Creates a proxy server with live runtime dependencies.
    ///
    /// - Parameter configuration: Public HTTP, upstream bridge, discovery, and
    ///   lifecycle settings.
    public init(
        configuration: XcodeMCPProxyServerConfiguration =
            XcodeMCPProxyServerConfiguration()
    ) {
        let dependencies = Dependencies.live
        self.configuration = configuration
        self.dependencies = dependencies
        self.lifecycle = Lifecycle(
            configuration: configuration,
            preparedProxyConfig: nil,
            dependencies: dependencies,
            logger: logger
        )
    }

    init(proxyConfig: ProxyConfig, dependencies: Dependencies) {
        let configuration = XcodeMCPProxyServerConfiguration(serverProxyConfig: proxyConfig)
        self.configuration = configuration
        self.dependencies = dependencies
        self.lifecycle = Lifecycle(
            configuration: configuration,
            preparedProxyConfig: proxyConfig,
            dependencies: dependencies,
            logger: logger
        )
    }

    init(
        configuration: XcodeMCPProxyServerConfiguration,
        dependencies: Dependencies
    ) {
        self.configuration = configuration
        self.dependencies = dependencies
        self.lifecycle = Lifecycle(
            configuration: configuration,
            preparedProxyConfig: nil,
            dependencies: dependencies,
            logger: logger
        )
    }

    init(
        preparedConfiguration: PreparedConfiguration,
        dependencies: Dependencies
    ) {
        self.configuration = preparedConfiguration.configuration
        self.dependencies = dependencies
        self.lifecycle = Lifecycle(
            configuration: preparedConfiguration.configuration,
            preparedProxyConfig: preparedConfiguration.proxyConfig,
            dependencies: dependencies,
            logger: logger
        )
    }

    /// Starts the server and publishes discovery according to the configured policy.
    public func start() async throws -> Endpoint {
        try await lifecycle.start()
    }

    /// Returns a sanitized server status snapshot.
    public func snapshot() async -> Status {
        await lifecycle.snapshot()
    }

    /// Waits until all listening HTTP channels close.
    public func waitUntilShutdown() async throws {
        try await lifecycle.waitUntilShutdown()
    }

    /// Shuts down the proxy server and its runtime resources.
    ///
    /// Shutdown stops permission automation, closes listening and accepted
    /// channels, shuts down the runtime coordinator, and terminates the event
    /// loop group.
    public func shutdown() async throws {
        try await lifecycle.shutdown()
    }

    static func listeningLogLine(displayHost: String, port: Int) -> String {
        "Xcode MCP proxy listening on http://\(displayHost):\(port) (version \(productMetadata.version))"
    }

    static func startupSummary(
        displayHost: String,
        port: Int,
        config: ProxyConfig,
        xcodeTargets: [ProxyRuntimeInventorySnapshot.XcodeTarget]
    ) -> String {
        let upstreamsPerXcode = max(1, min(config.upstreamProcessCount, 10))
        let processRoutingActive =
            xcodeTargets.isEmpty == false
            && ProxyRuntime.supportsProcessBoundRouting(
                configuration: config.runtimeConfiguration
            )
        let upstreamProcessCount =
            processRoutingActive
            ? upstreamsPerXcode * xcodeTargets.count
            : upstreamsPerXcode
        var lines = [
            "\(productMetadata.name) \(productMetadata.version)",
            "",
            "Server",
            "  URL: http://\(displayHost):\(port)/mcp",
            "  Upstream processes: \(upstreamProcessCount)",
            "  Auto approve: \(config.autoApproveXcodeDialog ? "enabled" : "disabled")",
            "",
            "Xcode",
        ]
        if processRoutingActive {
            lines.insert(
                "  Upstream processes per Xcode: \(upstreamsPerXcode)",
                at: 5
            )
        }

        switch xcodeTargets.count {
        case 0:
            lines.append("  Status: not detected")
        case 1:
            if let target = xcodeTargets.first {
                lines.append("  App: \(target.appPath)")
                lines.append("  PID: \(target.processID)")
            }
        default:
            lines.append("  Detected: \(xcodeTargets.count)")
            lines.append("  Apps:")
            for target in xcodeTargets {
                lines.append("    - \(target.appPath) (PID: \(target.processID))")
            }
        }

        lines.append(
            "  DocumentationSearch: \(documentationSearchStartupStatus(config: config))"
        )
        return lines.joined(separator: "\n")
    }

    private static func documentationSearchStartupStatus(config: ProxyConfig) -> String {
        if ProxyRuntime.documentationSearchIsConfigured(
            configuration: config.runtimeConfiguration
        ) {
            return "pending"
        }
        return "disabled"
    }

    static func additionalPermissionDialogExecutableCandidates(
        config: ProxyConfig,
        executableLookupClient: ExecutableLookupClient = .liveValue
    ) -> [String] {
        PermissionDialogExecutableResolver.additionalExecutableCandidates(
            config: config,
            executableLookupClient: executableLookupClient
        )
    }

    private static func permissionDialogAssistantNameCandidates(config: ProxyConfig) -> [String] {
        var candidates = Set<String>(["XcodeMCPKit"])
        if let name = config.initializeParamsOverride?.clientName, name.isEmpty == false {
            candidates.insert(name)
        }
        return Array(candidates)
    }

}

extension ProxyConfig {
    static func resolving(
        _ config: XcodeMCPProxyServerConfiguration,
        loadFileConfiguration: @Sendable (URL) throws -> ProxyConfig.File.LoadedConfiguration = {
            try ProxyConfig.File.Loader.loadStrict(configURL: $0)
        }
    ) throws -> Self {
        let host = config.listenHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.isEmpty == false else {
            throw XcodeMCPProxyServer.LifecycleError.invalidConfiguration(
                "bindAddress.host must not be empty"
            )
        }
        guard (0...65_535).contains(config.listenPort) else {
            throw XcodeMCPProxyServer.LifecycleError.invalidConfiguration(
                "bindAddress.port must be in 0...65535"
            )
        }
        guard (1...10).contains(config.upstreamProcessCount) else {
            throw XcodeMCPProxyServer.LifecycleError.invalidConfiguration(
                "upstream processesPerXcode must be in 1...10"
            )
        }
        guard config.maxBodyBytes > 0 else {
            throw XcodeMCPProxyServer.LifecycleError.invalidConfiguration(
                "maxBodyBytes must be greater than zero"
            )
        }

        let requestTimeout: TimeInterval
        if let duration = config.requestTimeout {
            let components = duration.components
            requestTimeout = Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
            guard requestTimeout.isFinite, requestTimeout > 0 else {
                throw XcodeMCPProxyServer.LifecycleError.invalidConfiguration(
                    "requestTimeout must be positive; use nil to disable it"
                )
            }
        } else {
            requestTimeout = 0
        }

        let loaded: ProxyConfig.File.LoadedConfiguration?
        if let configURL = config.configurationFileURL {
            loaded = try loadFileConfiguration(configURL)
        } else {
            loaded = nil
        }

        var resolved = Self(
            listenHost: config.listenHost,
            listenPort: config.listenPort,
            upstreamCommand: config.upstreamCommand,
            upstreamArgs: config.upstreamArguments,
            upstreamProcessCount: config.upstreamProcessCount,
            upstreamSessionID: config.upstreamSessionID,
            maxBodyBytes: config.maxBodyBytes,
            requestTimeout: requestTimeout,
            configPath: config.configPath,
            discoveryFileURL: {
                if case .file(let url) = config.discovery { return url }
                return nil
            }(),
            prewarmToolsList: config.prewarmToolsList,
            autoApproveXcodeDialog: config.autoApproveXcodeDialog,
            refreshCodeIssuesMode: ProxyConfig.RefreshCodeIssuesMode(config.refreshCodeIssuesMode),
            disabledToolNames: config.toolPolicy?.disabledToolNames
                ?? loaded?.disabledToolNames,
            initializeParamsOverride: loaded?.initializeParamsOverride
        )
        if let initializeHandshake = config.initializeHandshake {
            resolved.applyInitializeParamsOverride(
                ProxyConfig.File.InitializeHandshakeOverride(initializeHandshake)
            )
        }
        return resolved
    }
}

private extension ProxyConfig.File.InitializeHandshakeOverride {
    init(_ handshake: XcodeMCPProxyServerConfiguration.InitializeHandshake) {
        self.init(
            protocolVersion: handshake.protocolVersion,
            clientName: handshake.clientInfo?.name,
            clientVersion: handshake.clientInfo?.version,
            capabilities: handshake.capabilities?.mapValues(ProxyConfig.File.Value.init)
        )
    }
}

private extension ProxyConfig.File.Value {
    init(_ value: MCPJSONValue) {
        switch value {
        case .object(let object):
            self = .object(object.mapValues(ProxyConfig.File.Value.init))
        case .array(let array):
            self = .array(array.map(ProxyConfig.File.Value.init))
        case .string(let string):
            self = .string(string)
        case .integer(let integer):
            self = .number(.int(integer))
        case .double(let double):
            self = .number(.double(double))
        case .bool(let bool):
            self = .bool(bool)
        case .null:
            self = .null
        }
    }
}

private extension ProxyConfig.RefreshCodeIssuesMode {
    init(_ mode: XcodeMCPProxyServerConfiguration.RefreshCodeIssuesMode) {
        switch mode {
        case .proxy:
            self = .proxy
        case .upstream:
            self = .upstream
        }
    }
}

private extension XcodeMCPProxyServerConfiguration.RefreshCodeIssuesMode {
    init(_ mode: ProxyConfig.RefreshCodeIssuesMode) {
        switch mode {
        case .proxy:
            self = .proxy
        case .upstream:
            self = .upstream
        }
    }
}

protocol ProxyServerPermissionDialogAutoApprover: Sendable {
    func start()
    func cancel()
}

extension XcodePermissionDialogAutomation.AutoApprover:
    ProxyServerPermissionDialogAutoApprover {}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
