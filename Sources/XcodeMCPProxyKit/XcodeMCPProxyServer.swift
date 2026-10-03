import XcodeMCPProxyRuntimeContract
import XcodeMCPCore
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

        /// Automatically approve Xcode MCP connection dialogs for all agents,
        /// including agents connecting directly to Xcode outside this proxy.
        ///
        /// Preserves configured-agent identity matching and additionally accepts
        /// the English heading `Allow “…” to access Xcode?` with an `Allow` button
        /// for other agents. Requires macOS Accessibility permission for the host process.
        case automatic
    }

    /// Initialize handshake values sent from the proxy to native helpers.
    ///
    /// Properties left as `nil` use the built-in defaults.
    public struct InitializeHandshake: Equatable, Sendable {
        /// Upstream client information for the initialize handshake.
        public struct ClientInfo: Equatable, Sendable {
            /// Client name to advertise to the native helper.
            public var name: String?

            /// Client version to advertise to the native helper.
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

    /// Native helper application bundle. `nil` uses the installed helper.
    public var nativeHostBundleURL: URL?

    /// Xcode developer directory. `nil` uses the selected Xcode installation.
    public var developerDirectoryURL: URL?

    /// Maximum accepted HTTP request body size in bytes.
    public var maxBodyBytes: Int

    /// Request timeout. `nil` disables request timeouts.
    public var requestTimeout: Duration?

    /// Initialize handshake overrides. `nil` uses the built-in defaults.
    public var initializeHandshake: InitializeHandshake?

    /// Endpoint discovery policy.
    public var discovery: Discovery

    /// Permission dialog automation policy.
    public var approvalPolicy: ApprovalPolicy

    /// Whether to fetch native tool catalogs during startup.
    public var prewarmToolsList: Bool

    /// Creates a public proxy server configuration.
    ///
    /// - Parameters:
    ///   - bindAddress: HTTP bind address.
    ///   - nativeHostBundleURL: Native helper application bundle, or `nil` to use the installed helper.
    ///   - developerDirectoryURL: Xcode developer directory, or `nil` to use the selected installation.
    ///   - maxBodyBytes: Maximum accepted HTTP request body size.
    ///   - requestTimeout: Request timeout, or `nil` to disable it.
    ///   - discovery: Endpoint discovery policy.
    ///   - approvalPolicy: Permission dialog automation policy.
    ///   - prewarmToolsList: Whether to fetch native tool catalogs during startup.
    ///   - initializeHandshake: Explicit upstream initialize handshake override.
    public init(
        bindAddress: BindAddress = .localhost(),
        nativeHostBundleURL: URL? = nil,
        developerDirectoryURL: URL? = nil,
        maxBodyBytes: Int = 1_048_576,
        requestTimeout: Duration? = .seconds(300),
        initializeHandshake: InitializeHandshake? = nil,
        discovery: Discovery = .defaultLocation,
        approvalPolicy: ApprovalPolicy = .manual,
        prewarmToolsList: Bool = true
    ) {
        self.bindAddress = bindAddress
        self.nativeHostBundleURL = nativeHostBundleURL
        self.developerDirectoryURL = developerDirectoryURL
        self.maxBodyBytes = maxBodyBytes
        self.requestTimeout = requestTimeout
        self.initializeHandshake = initializeHandshake
        self.discovery = discovery
        self.approvalPolicy = approvalPolicy
        self.prewarmToolsList = prewarmToolsList
    }

    var listenHost: String { bindAddress.host }
    var listenPort: Int { bindAddress.port }
    var autoApproveXcodeDialog: Bool { approvalPolicy == .automatic }
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

    /// An operation failed and releasing its resources also failed.
    public struct CleanupError: Error, CustomStringConvertible, Sendable {
        /// The failure that caused cleanup to begin.
        public let operationError: any Error

        /// The failure encountered while releasing resources.
        public let cleanupError: any Error

        /// The bound endpoint, if startup reached the listening stage.
        ///
        /// The cleanup failure may mean that this endpoint or other HTTP
        /// resources have not been fully released.
        public let endpoint: Endpoint?

        /// Describes both failures and the potentially incomplete cleanup.
        public var description: String {
            "\(operationError); shutdown also failed: \(cleanupError). Resource release may be incomplete."
        }
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

    struct Dependencies: Sendable {
        var discoveryClient: DiscoveryClient
        var processID: @Sendable () -> Int
        var makeAutoApprover:
            @Sendable (XcodeMCPProxyServerConfiguration, any ProxyRuntimeServing) -> any ProxyServerPermissionDialogAutoApprover
        var makeRuntime: @Sendable (ProxyRuntimeConfiguration) throws -> any ProxyRuntimeServing
        var makeHTTPGateway:
            @Sendable (
                ProxyHTTPConfiguration,
                any ProxyRuntimeServing,
                Logger
            ) -> any ProxyHTTPGatewayServing

        init(
            discoveryClient: DiscoveryClient = .liveValue,
            processID: @escaping @Sendable () -> Int = {
                Int(ProcessInfo.processInfo.processIdentifier)
            },
            makeAutoApprover: @escaping @Sendable (
                XcodeMCPProxyServerConfiguration,
                any ProxyRuntimeServing
            ) -> any ProxyServerPermissionDialogAutoApprover,
            makeRuntime: @escaping @Sendable (ProxyRuntimeConfiguration) throws -> any ProxyRuntimeServing,
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
            self.processID = processID
            self.makeAutoApprover = makeAutoApprover
            self.makeRuntime = makeRuntime
            self.makeHTTPGateway = makeHTTPGateway
        }

        static var live: Self {
            return Self(
                makeAutoApprover: { config, runtime in
                    let additionalCandidates = PermissionDialogExecutableResolver.executableCandidates(
                        bundleURL: config.nativeHostBundleURL,
                        developerDirectoryURL: config.developerDirectoryURL
                    )
                    return XcodePermissionDialogAutomation.AutoApprover(
                        configuration: .init(
                            permissionDialogProcessIDs: {
                                runtime.inventorySnapshot().permissionDialogProcessIDs
                            },
                            agentPathCandidates: {
                                XcodePermissionDialogAutomation.AutoApprover
                                    .executablePathCandidates(additional: additionalCandidates)
                            },
                            assistantNameCandidates: {
                                Set(XcodeMCPProxyServer.permissionDialogAssistantNameCandidates(config: config))
                            },
                            agentProcessIDCandidates: {
                                XcodePermissionDialogAutomation.AutoApprover
                                    .descendantProcessIDCandidates()
                            },
                            agentScope: .allAgents
                        ),
                        logger: ProxyLogging.make("xcode.permission")
                    )
                },
                makeRuntime: { config in
                    let invocation = try NativeHostInvocation.resolve(
                        bundleURL: config.nativeHostBundleURL,
                        developerDirectoryURL: config.developerDirectoryURL
                    )
                    var resolved = config
                    resolved.nativeHostBundleURL = URL(fileURLWithPath: invocation.command)
                        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    return ProxyRuntime(configuration: resolved)
                }
            )
        }
    }

    let logger: Logger = ProxyLogging.make("server")
    let lifecycle: Lifecycle

    /// Creates a proxy server with live runtime dependencies.
    ///
    /// - Parameter configuration: Public HTTP, native helper, discovery, and
    ///   lifecycle settings.
    public init(
        configuration: XcodeMCPProxyServerConfiguration =
            XcodeMCPProxyServerConfiguration()
    ) {
        let dependencies = Dependencies.live
        self.lifecycle = Lifecycle(
            configuration: configuration,
            dependencies: dependencies,
            logger: logger
        )
    }

    init(
        configuration: XcodeMCPProxyServerConfiguration,
        dependencies: Dependencies
    ) {
        self.lifecycle = Lifecycle(
            configuration: configuration,
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
    /// Repeated calls return the result of the same shutdown attempt, including
    /// any resource-release failure.
    public func shutdown() async throws {
        try await lifecycle.shutdown()
    }

    static func listeningLogLine(displayHost: String, port: Int) -> String {
        "Xcode MCP proxy listening on http://\(displayHost):\(port) (version \(productMetadata.version))"
    }

    static func startupSummary(
        displayHost: String,
        port: Int,
        config: XcodeMCPProxyServerConfiguration,
        xcodeTargets: [ProxyRuntimeInventorySnapshot.XcodeTarget]
    ) -> String {
        var lines = [
            "\(productMetadata.name) \(productMetadata.version)",
            "",
            "Server",
            "  URL: http://\(displayHost):\(port)/mcp",
            "  Auto approve: \(config.autoApproveXcodeDialog ? "enabled" : "disabled")",
            "",
            "Xcode",
        ]
        appendGUIXcodeStatus(xcodeTargets, to: &lines)

        return lines.joined(separator: "\n")
    }

    private static func appendGUIXcodeStatus(
        _ xcodeTargets: [ProxyRuntimeInventorySnapshot.XcodeTarget],
        to lines: inout [String]
    ) {
        switch xcodeTargets.count {
        case 0:
            lines.append("  GUI: not detected")
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

    }

    private static func permissionDialogAssistantNameCandidates(config: XcodeMCPProxyServerConfiguration) -> [String] {
        var candidates = Set<String>(["XcodeMCPKit"])
        if let name = config.initializeHandshake?.clientInfo?.name, name.isEmpty == false {
            candidates.insert(name)
        }
        return Array(candidates)
    }
}

extension XcodeMCPProxyServerConfiguration {
    func runtimeConfiguration() throws -> ProxyRuntimeConfiguration {
        guard listenHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw XcodeMCPProxyServer.LifecycleError.invalidConfiguration("bindAddress.host must not be empty")
        }
        guard (0...65_535).contains(listenPort) else {
            throw XcodeMCPProxyServer.LifecycleError.invalidConfiguration("bindAddress.port must be in 0...65535")
        }
        guard maxBodyBytes > 0 else {
            throw XcodeMCPProxyServer.LifecycleError.invalidConfiguration("maxBodyBytes must be greater than zero")
        }
        let timeout: TimeInterval
        if let requestTimeout {
            let components = requestTimeout.components
            timeout = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
            guard timeout > 0 else {
                throw XcodeMCPProxyServer.LifecycleError.invalidConfiguration("requestTimeout must be positive; use nil to disable it")
            }
        } else {
            timeout = 0
        }
        let configuration = ProxyRuntimeConfiguration(
            nativeHostBundleURL: nativeHostBundleURL,
            developerDirectoryURL: developerDirectoryURL,
            maxMessageBytes: maxBodyBytes,
            requestTimeout: timeout,
            prewarmToolsList: prewarmToolsList,
            usesPermissionDialogAutomation: autoApproveXcodeDialog,
            initializeParamsOverride: initializeHandshake.map { handshake in
                .init(
                    protocolVersion: handshake.protocolVersion,
                    clientName: handshake.clientInfo?.name,
                    clientVersion: handshake.clientInfo?.version,
                    capabilities: handshake.capabilities?.mapValues(ProxyRuntimeConfiguration.JSONValue.init)
                )
            }
        )
        try configuration.validateModernProtocolConfiguration()
        return configuration
    }
}

private extension ProxyRuntimeConfiguration.JSONValue {
    init(_ value: MCPJSONValue) {
        switch value {
        case .object(let object): self = .object(object.mapValues(Self.init))
        case .array(let array): self = .array(array.map(Self.init))
        case .string(let string): self = .string(string)
        case .integer(let integer): self = .number(.integer(integer))
        case .double(let double): self = .number(.double(double))
        case .bool(let bool): self = .bool(bool)
        case .null: self = .null
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
