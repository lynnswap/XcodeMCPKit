import Foundation
import Logging
import NIO
import NIOHTTP1
import XcodeMCPKit

/// Embeddable Streamable HTTP proxy server for Xcode MCP.
///
/// `XcodeMCPProxyServer` is the library boundary used by the
/// `xcode-mcp-proxy-server` executable. Construct it with ``Configuration``,
/// call ``startAndWriteDiscovery()`` or ``start()``, then keep the process
/// alive with ``wait()`` until your application decides to call ``shutdown()``.
/// Both start methods return the resolved endpoint.
///
/// The server exposes the proxy lifecycle. CLI parsing, STDIO adapter behavior,
/// and internal session routing are intentionally handled outside this public
/// type.
public final class XcodeMCPProxyServer {
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
    }

    /// Public configuration for an embedded Xcode MCP proxy server.
    ///
    /// This type is the stable server configuration surface for
    /// `XcodeMCPProxyKit`. Lower-level parser, discovery, filesystem, and
    /// session-routing types stay internal to the targets that own
    /// them.
    public struct Configuration: Equatable, Sendable {
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

        /// Request and payload limits enforced by the proxy.
        public struct Limits: Equatable, Sendable {
            /// Maximum accepted HTTP request body size in bytes.
            public var maxBodyBytes: Int

            /// Request timeout in seconds.
            public var requestTimeout: TimeInterval

            /// Creates proxy request limits.
            public init(maxBodyBytes: Int = 1_048_576, requestTimeout: TimeInterval = 300) {
                self.maxBodyBytes = maxBodyBytes
                self.requestTimeout = requestTimeout
            }

            /// Default proxy limits.
            public static let `default` = Self()
        }

        /// Endpoint discovery file policy.
        public struct Discovery: Equatable, Sendable {
            /// Optional discovery file URL.
            ///
            /// `nil` uses the default discovery location.
            public var fileURL: URL?

            /// Creates a discovery policy.
            public init(fileURL: URL? = nil) {
                self.fileURL = fileURL
            }

            /// Uses the default discovery file location.
            public static let `default` = Self()
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
        /// ``configurationFilePath``. Properties left as `nil` keep the file
        /// value when present, otherwise the proxy's built-in default is used.
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
        public var bind: BindAddress

        /// Upstream bridge process policy.
        public var upstream: Upstream

        /// Request and payload limits.
        public var limits: Limits

        /// Optional TOML configuration path for initialize overrides and
        /// disabled tools.
        public var configurationFilePath: String?

        /// Explicit tool visibility policy.
        ///
        /// `nil` keeps disabled tools loaded from ``configurationFilePath``.
        /// A non-`nil` policy overrides the file's `[tools].disabled` list.
        public var toolPolicy: ToolPolicy?

        /// Explicit initialize handshake override.
        ///
        /// Non-`nil` fields override the matching file-backed
        /// `[upstream_handshake]` fields. Fields left `nil` keep the file
        /// value when present, otherwise the built-in default is used.
        public var initializeHandshake: InitializeHandshake?

        /// Endpoint discovery policy.
        public var discovery: Discovery

        /// Permission dialog automation policy.
        public var approval: ApprovalPolicy

        /// Optional proxy feature policy.
        public var features: FeaturePolicy

        /// Creates a public proxy server configuration.
        ///
        /// - Parameters:
        ///   - bind: HTTP bind address.
        ///   - upstream: Upstream bridge process policy.
        ///   - limits: Request and payload limits.
        ///   - configurationFilePath: Optional TOML configuration path.
        ///   - discovery: Endpoint discovery policy.
        ///   - approval: Permission dialog automation policy.
        ///   - features: Optional proxy feature policy.
        ///   - toolPolicy: Explicit tool visibility policy.
        ///   - initializeHandshake: Explicit upstream initialize handshake
        ///     override.
        public init(
            bind: BindAddress = .localhost(),
            upstream: Upstream = .defaultMCPBridge(),
            limits: Limits = .default,
            configurationFilePath: String? = nil,
            discovery: Discovery = .default,
            approval: ApprovalPolicy = .manual,
            features: FeaturePolicy = .default,
            toolPolicy: ToolPolicy? = nil,
            initializeHandshake: InitializeHandshake? = nil
        ) {
            self.bind = bind
            self.upstream = upstream
            self.limits = limits
            self.configurationFilePath = configurationFilePath
            self.toolPolicy = toolPolicy
            self.initializeHandshake = initializeHandshake
            self.discovery = discovery
            self.approval = approval
            self.features = features
        }

        init(serverProxyConfig proxyConfig: ProxyConfig) {
            self.init(
                bind: BindAddress(
                    host: proxyConfig.listenHost,
                    port: proxyConfig.listenPort
                ),
                upstream: .custom(
                    command: proxyConfig.upstreamCommand,
                    arguments: proxyConfig.upstreamArgs,
                    processesPerXcode: proxyConfig.upstreamProcessCount,
                    sessionID: proxyConfig.upstreamSessionID
                ),
                limits: Limits(
                    maxBodyBytes: proxyConfig.maxBodyBytes,
                    requestTimeout: proxyConfig.requestTimeout
                ),
                configurationFilePath: proxyConfig.configPath,
                discovery: Discovery(fileURL: proxyConfig.discoveryFileURL),
                approval: proxyConfig.autoApproveXcodeDialog ? .automatic : .manual,
                features: FeaturePolicy(
                    prewarmToolsList: proxyConfig.prewarmToolsList,
                    refreshCodeIssuesMode: RefreshCodeIssuesMode(proxyConfig.refreshCodeIssuesMode)
                )
            )
        }

        var listenHost: String { bind.host }
        var listenPort: Int { bind.port }
        var upstreamCommand: String { upstream.command }
        var upstreamArguments: [String] { upstream.arguments }
        var upstreamProcessCount: Int { upstream.processesPerXcode }
        var upstreamSessionID: String? { upstream.sessionID }
        var maxBodyBytes: Int { limits.maxBodyBytes }
        var requestTimeout: TimeInterval { limits.requestTimeout }
        var configPath: String? { configurationFilePath }
        var discoveryFileURL: URL? { discovery.fileURL }
        var prewarmToolsList: Bool { features.prewarmToolsList }
        var autoApproveXcodeDialog: Bool { approval == .automatic }
        var refreshCodeIssuesMode: RefreshCodeIssuesMode {
            features.refreshCodeIssuesMode
        }
    }

    struct Dependencies: Sendable {
        var discoveryClient: DiscoveryClient
        var executableLookupClient: ExecutableLookupClient
        var processID: @Sendable () -> Int
        var runningXcodeTargets: @Sendable () -> [XcodeProcessTarget]
        var makeAutoApprover: @Sendable () -> any ProxyServerPermissionDialogAutoApprover
        var makeRuntimeCoordinator:
            @Sendable (_ config: ProxyConfig, _ eventLoop: EventLoop) -> any RuntimeCoordinating

        init(
            discoveryClient: DiscoveryClient = .liveValue,
            executableLookupClient: ExecutableLookupClient = .liveValue,
            processID: @escaping @Sendable () -> Int = {
                Int(ProcessInfo.processInfo.processIdentifier)
            },
            runningXcodeTargets: @escaping @Sendable () -> [XcodeProcessTarget] = {
                []
            },
            makeAutoApprover: @escaping @Sendable () -> any ProxyServerPermissionDialogAutoApprover,
            makeRuntimeCoordinator: @escaping @Sendable (_ config: ProxyConfig, _ eventLoop: EventLoop) -> any RuntimeCoordinating
        ) {
            self.discoveryClient = discoveryClient
            self.executableLookupClient = executableLookupClient
            self.processID = processID
            self.runningXcodeTargets = runningXcodeTargets
            self.makeAutoApprover = makeAutoApprover
            self.makeRuntimeCoordinator = makeRuntimeCoordinator
        }

        static func live(config: ProxyConfig) -> Self {
            let executableLookupClient = ExecutableLookupClient.liveValue
            return Self(
                executableLookupClient: executableLookupClient,
                runningXcodeTargets: {
                    LiveXcodeTargetDiscovery().runningXcodeTargets()
                },
                makeAutoApprover: {
                    let additionalCandidates = XcodeMCPProxyServer.additionalPermissionDialogExecutableCandidates(
                        config: config,
                        executableLookupClient: executableLookupClient
                    )
                    return XcodePermissionDialog.AutoApprover(
                        dependencies: .live(
                            agentPathCandidates: {
                                XcodePermissionDialog.AutoApprover.defaultAgentPathCandidates(
                                    additionalExecutableCandidates: additionalCandidates
                                )
                            },
                            assistantNameCandidates: {
                                Set(XcodeMCPProxyServer.permissionDialogAssistantNameCandidates(config: config))
                            }
                        )
                    )
                },
                makeRuntimeCoordinator: { config, eventLoop in
                    RuntimeCoordinator(
                        config: config,
                        eventLoop: eventLoop,
                        upstreamReadinessGate: .liveDefault(config: config, clock: .liveValue),
                        xcodeTargetDiscovery: LiveXcodeTargetDiscovery(),
                        startImmediately: false
                    )
                }
            )
        }
    }

    let config: ProxyConfig
    let dependencies: Dependencies
    let group: EventLoopGroup
    let refreshCodeIssuesCoordinator: RefreshCodeIssues.Coordinator
    let refreshCodeIssuesTargetResolver: RefreshCodeIssues.TargetResolver
    let refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState
    private var channels: [Channel] = []
    let logger: Logger = ProxyLogging.make("server")
    let runtimeLock = NSLock()
    let acceptedChannelTracker = ProxyAcceptedChannelTracker()
    var isShuttingDown = false
    var sessionManager: (any RuntimeCoordinating)?
    var permissionDialogAutoApprover: (any ProxyServerPermissionDialogAutoApprover)?
    var hasStartedRuntimeOrChannels: Bool {
        sessionManager != nil || channels.isEmpty == false
    }

    /// Creates a proxy server with live runtime dependencies.
    ///
    /// - Parameter config: Public HTTP, upstream bridge, discovery, and
    ///   lifecycle settings.
    public convenience init(config: Configuration = Configuration()) {
        let proxyConfig = ProxyConfig(config)
        self.init(proxyConfig: proxyConfig, dependencies: .live(config: proxyConfig))
    }

    init(proxyConfig: ProxyConfig, dependencies: Dependencies) {
        self.config = proxyConfig
        self.dependencies = dependencies
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.refreshCodeIssuesCoordinator = RefreshCodeIssues.Coordinator.makeDefault()
        self.refreshCodeIssuesTargetResolver = RefreshCodeIssues.TargetResolver()
        self.refreshCodeIssuesDebugState = RefreshCodeIssues.DebugState(
            defaultRequestTimeoutSeconds: proxyConfig.requestTimeout
        )
    }

    /// Starts the server and writes endpoint discovery information.
    ///
    /// This is the usual entry point for embedded users. It binds HTTP
    /// channels, starts the proxy runtime, writes the discovery file configured
    /// by ``Configuration/discovery``, logs a startup summary, and returns the
    /// resolved endpoint.
    ///
    /// Each server instance can be started once. A second call to this method
    /// or to ``start()`` throws ``LifecycleError/alreadyStarted``.
    public func startAndWriteDiscovery() throws -> Endpoint {
        let channel = try startListening()
        let (host, port) = resolvedListenAddress(for: channel)
        let displayHost = config.listenHost == "localhost" ? "localhost" : host
        writeDiscovery(resolvedHost: host, port: port)
        let summary = Self.startupSummary(
            displayHost: displayHost,
            port: port,
            config: config,
            xcodeTargets: dependencies.runningXcodeTargets()
        )
        logger.info("\(summary)")
        return Endpoint(host: host, port: port)
    }

    /// Waits until the listening HTTP channels close.
    ///
    /// Call this after starting the server to keep an async task suspended for
    /// the server lifetime. Calling ``shutdown()`` closes the channels and lets
    /// this method return.
    public func wait() async throws {
        try await waitForHTTP()
    }

    /// Shuts down the proxy server and its runtime resources.
    ///
    /// Shutdown stops permission automation, closes listening and accepted
    /// channels, shuts down the runtime coordinator, and terminates the event
    /// loop group.
    public func shutdown() async throws {
        let shutdownContext = beginShutdown()
        shutdownContext.autoApprover?.stop()

        var shutdownError: (any Error)?
        do {
            try await closeChannels(shutdownContext.channels)
        } catch {
            shutdownError = error
        }

        await shutdownContext.sessionManager?.shutdown()
        do {
            try await shutdownEventLoopGroup()
        } catch {
            if shutdownError == nil {
                shutdownError = error
            }
        }

        if let shutdownError {
            throw shutdownError
        }
    }

    private func closeChannels(_ listenChannels: [Channel]) async throws {
        let listenCloseFutures = listenChannels.map(\.closeFuture)
        for channel in listenChannels {
            channel.close(mode: .all, promise: nil)
        }
        try await EventLoopFuture.andAllSucceed(listenCloseFutures, on: group.next()).get()

        while true {
            let childChannels = acceptedChannelTracker.snapshot()
            guard !childChannels.isEmpty else { break }

            let childCloseFutures = childChannels.map(\.closeFuture)
            for channel in childChannels {
                channel.close(mode: .all, promise: nil)
            }
            try await EventLoopFuture.andAllSucceed(childCloseFutures, on: group.next()).get()
        }
    }

    private func shutdownEventLoopGroup() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            group.shutdownGracefully { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func resolvedListenAddress(for channel: Channel) -> (String, Int) {
        if let address = channel.localAddress {
            let host = address.ipAddress ?? config.listenHost
            let port = address.port ?? config.listenPort
            return (host, port)
        }
        return (config.listenHost, config.listenPort)
    }

    func bindChannels(using bootstrap: ServerBootstrap) throws -> [Channel] {
        if config.listenHost != "localhost" {
            let channel = try bootstrap.bind(host: config.listenHost, port: config.listenPort).wait()
            return [channel]
        }

        var bound: [Channel] = []
        do {
            let v4Channel = try bootstrap.bind(host: "127.0.0.1", port: config.listenPort).wait()
            bound.append(v4Channel)
            let v4Port = v4Channel.localAddress?.port ?? config.listenPort
            guard v4Port > 0 else {
                return bound
            }
            do {
                let v6Channel = try bootstrap.bind(host: "::1", port: v4Port).wait()
                bound.append(v6Channel)
            } catch {
                logger.warning("Failed to bind IPv6 loopback; continuing with IPv4 only", metadata: ["error": "\(error)"])
            }
            return bound
        } catch {
            logger.warning("Failed to bind IPv4 loopback; attempting IPv6 only", metadata: ["error": "\(error)"])
            let v6Channel = try bootstrap.bind(host: "::1", port: config.listenPort).wait()
            return [v6Channel]
        }
    }

    private func waitForHTTP() async throws {
        let futures = runtimeLock.withLock { channels.map(\.closeFuture) }
        if futures.isEmpty {
            return
        }
        try await EventLoopFuture.andAllSucceed(futures, on: group.next()).get()
    }

    private func writeDiscovery(resolvedHost: String, port: Int) {
        guard let record = dependencies.discoveryClient.makeRecord(
            discoveryHost(resolvedHost),
            port,
            dependencies.processID(),
            "http"
        ) else {
            return
        }
        do {
            try dependencies.discoveryClient.write(record, config.discoveryFileURL)
        } catch {
            logger.warning(
                "Failed to write discovery file",
                metadata: [
                    "error": "\(error)",
                    "path": "\(config.discoveryFileURL?.path ?? dependencies.discoveryClient.defaultFileURL().path)",
                ]
            )
        }
    }

    private func discoveryHost(_ resolvedHost: String) -> String {
        switch config.listenHost {
        case "localhost", "0.0.0.0", "::":
            return "localhost"
        default:
            return resolvedHost
        }
    }

    static func listeningLogLine(displayHost: String, port: Int) -> String {
        "Xcode MCP proxy listening on http://\(displayHost):\(port) (version \(productMetadata.version))"
    }

    static func startupSummary(
        displayHost: String,
        port: Int,
        config: ProxyConfig,
        xcodeTargets: [XcodeProcessTarget]
    ) -> String {
        let upstreamsPerXcode = max(1, min(config.upstreamProcessCount, 10))
        let processRoutingActive =
            xcodeTargets.isEmpty == false
            && XcrunArguments.isDefaultMCPBridgeInvocation(config: config)
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
        if RuntimeCoordinator.documentationProviderServiceIsConfigured(config: config) {
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

    private func beginShutdown() -> (
        sessionManager: (any RuntimeCoordinating)?,
        autoApprover: (any ProxyServerPermissionDialogAutoApprover)?,
        channels: [Channel]
    ) {
        runtimeLock.withLock {
            let context = (
                sessionManager: sessionManager,
                autoApprover: permissionDialogAutoApprover,
                channels: channels
            )
            isShuttingDown = true
            sessionManager = nil
            permissionDialogAutoApprover = nil
            return context
        }
    }

    func setChannelsForStartedServer(_ startedChannels: [Channel]) {
        channels = startedChannels
    }
}

private extension ProxyConfig {
    init(_ config: XcodeMCPProxyServer.Configuration) {
        self.init(
            listenHost: config.listenHost,
            listenPort: config.listenPort,
            upstreamCommand: config.upstreamCommand,
            upstreamArgs: config.upstreamArguments,
            upstreamProcessCount: config.upstreamProcessCount,
            upstreamSessionID: config.upstreamSessionID,
            maxBodyBytes: config.maxBodyBytes,
            requestTimeout: config.requestTimeout,
            configPath: config.configPath,
            discoveryFileURL: config.discoveryFileURL,
            prewarmToolsList: config.prewarmToolsList,
            autoApproveXcodeDialog: config.autoApproveXcodeDialog,
            refreshCodeIssuesMode: ProxyConfig.RefreshCodeIssuesMode(config.refreshCodeIssuesMode),
            disabledToolNames: config.toolPolicy?.disabledToolNames,
            initializeParamsOverride: config.initializeHandshake.map {
                ProxyConfig.File.InitializeHandshakeOverride($0)
            }
        )
    }
}

private extension ProxyConfig.File.InitializeHandshakeOverride {
    init(_ handshake: XcodeMCPProxyServer.Configuration.InitializeHandshake) {
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
    init(_ mode: XcodeMCPProxyServer.Configuration.RefreshCodeIssuesMode) {
        switch mode {
        case .proxy:
            self = .proxy
        case .upstream:
            self = .upstream
        }
    }
}

private extension XcodeMCPProxyServer.Configuration.RefreshCodeIssuesMode {
    init(_ mode: ProxyConfig.RefreshCodeIssuesMode) {
        switch mode {
        case .proxy:
            self = .proxy
        case .upstream:
            self = .upstream
        }
    }
}

final class ProxyAcceptedChannelTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]

    func register(_ channel: Channel) {
        let id = ObjectIdentifier(channel)
        lock.withLock {
            channels[id] = channel
        }
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            _ = lock.withLock {
                channels.removeValue(forKey: id)
            }
        }
    }

    func snapshot() -> [Channel] {
        lock.withLock { Array(channels.values) }
    }
}

final class ProxyAcceptedChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Channel

    private let tracker: ProxyAcceptedChannelTracker

    init(tracker: ProxyAcceptedChannelTracker) {
        self.tracker = tracker
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channel = unwrapInboundIn(data)
        tracker.register(channel)
        context.fireChannelRead(data)
    }
}

protocol ProxyServerPermissionDialogAutoApprover: Sendable {
    func start()
    func stop()
}

extension XcodePermissionDialog.AutoApprover: ProxyServerPermissionDialogAutoApprover {}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
