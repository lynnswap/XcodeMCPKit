import XcodeMCPServerRuntimeContract
import XcodeMCPCore
import Foundation
import Logging
import XcodeMCPServerHTTP
import XcodeMCPServerRuntime
import XcodeMCPPermissionAutomation

/// Public configuration for an embedded Xcode MCP server.
///
/// This type is the stable server configuration surface for
/// `XcodeMCPServerKit`. Lower-level parser, discovery, filesystem, and
/// session-routing types stay internal to the targets that own them.
public struct XcodeMCPServerConfiguration: Equatable, Sendable {
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

    /// Xcode MCP connection dialog automation policy.
    public enum ApprovalPolicy: Equatable, Sendable {
        /// Leave Xcode permission dialogs for the user to approve.
        case manual

        /// Automatically approve Xcode MCP connection dialogs for all agents,
        /// including clients connecting to Xcode outside this server.
        ///
        /// Requires macOS Accessibility permission for the server process.
        case automatic
    }

    /// HTTP bind address.
    public var bindAddress: BindAddress

    /// Native helper application bundle. `nil` uses the installed helper.
    public var nativeHostBundleURL: URL?

    /// Preferred Xcode app or developer directory. Unavailable selections use discovery.
    public var developerDirectoryURL: URL?

    /// Whether to share compilation caches across worktrees using compiler prefix mapping.
    public var sharesCompilationCache: Bool

    /// Whether to automate GUI Xcode MCP connection dialogs. Defaults to manual approval.
    public var approvalPolicy: ApprovalPolicy

    /// Maximum accepted HTTP request body size in bytes.
    public var maxBodyBytes: Int

    /// Request timeout, or `nil` for none, the default. A client that gives up cancels its request
    /// or disconnects, which also ends the work. Starting a host stays bounded either way.
    public var requestTimeout: Duration?

    /// Endpoint discovery policy.
    public var discovery: Discovery

    /// Whether to fetch native tool catalogs during startup.
    public var prewarmToolsList: Bool

    /// Whether to serve `/debug/hosts` and `/debug/reset`. They are served only on a loopback
    /// listener. Defaults to `false`.
    public var enablesDebugEndpoints: Bool

    /// Creates a public server configuration.
    ///
    /// - Parameters:
    ///   - bindAddress: HTTP bind address.
    ///   - nativeHostBundleURL: Native helper application bundle, or `nil` to use the installed helper.
    ///   - developerDirectoryURL: Preferred Xcode app or developer directory.
    ///     Unavailable selections fall through to installed-Xcode discovery.
    ///   - sharesCompilationCache: Whether to share compilation caches across worktrees. Defaults to `false`.
    ///   - maxBodyBytes: Maximum accepted HTTP request body size.
    ///   - requestTimeout: Request timeout, or `nil` for none. Defaults to `nil`.
    ///   - discovery: Endpoint discovery policy.
    ///   - approvalPolicy: Xcode MCP connection dialog automation policy. Defaults to `.manual`.
    ///   - prewarmToolsList: Whether to fetch native tool catalogs during startup.
    ///   - enablesDebugEndpoints: Whether to serve the debug endpoints on a loopback listener. Defaults to `false`.
    public init(
        bindAddress: BindAddress = .localhost(),
        nativeHostBundleURL: URL? = nil,
        developerDirectoryURL: URL? = nil,
        sharesCompilationCache: Bool = false,
        maxBodyBytes: Int = 1_048_576,
        requestTimeout: Duration? = nil,
        discovery: Discovery = .defaultLocation,
        approvalPolicy: ApprovalPolicy = .manual,
        prewarmToolsList: Bool = true,
        enablesDebugEndpoints: Bool = false
    ) {
        self.bindAddress = bindAddress
        self.nativeHostBundleURL = nativeHostBundleURL
        self.developerDirectoryURL = developerDirectoryURL
        self.sharesCompilationCache = sharesCompilationCache
        self.approvalPolicy = approvalPolicy
        self.maxBodyBytes = maxBodyBytes
        self.requestTimeout = requestTimeout
        self.discovery = discovery
        self.prewarmToolsList = prewarmToolsList
        self.enablesDebugEndpoints = enablesDebugEndpoints
    }

    var listenHost: String { bindAddress.host }
    var listenPort: Int { bindAddress.port }
}

/// Embeddable Streamable HTTP server for Xcode MCP.
///
/// `XcodeMCPServer` is the library boundary used by the
/// `xcode-mcp-server` executable. Construct it with
/// ``XcodeMCPServerConfiguration``, call ``start()``, then keep the process
/// alive with ``waitUntilShutdown()`` until your
/// application decides to call ``shutdown()``. Start returns the resolved
/// endpoint.
///
/// The server exposes the server lifecycle. CLI parsing and internal session
/// routing are intentionally handled outside this public type.
public final class XcodeMCPServer: Sendable {
    /// A resolved Streamable HTTP server endpoint.
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

    /// Errors thrown while starting or stopping a server instance.
    public enum LifecycleError: Error, Equatable, Sendable {
        /// The configured listener could not bind to any requested address.
        case failedToBind

        /// The server instance has already been started.
        ///
        /// Create a new ``XcodeMCPServer`` instance after calling
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

        /// An owned headless host the server uses for an Xcode installation.
        public struct Host: Equatable, Sendable {
            /// What the host connects to.
            public enum Kind: Equatable, Sendable {
                /// A headless native host the server starts for an Xcode installation.
                case headless
                /// A legacy GUI host kind. The server creates only headless hosts.
                case gui(processIdentifier: Int32)
            }

            /// Whether the host's process is running.
            public enum State: Equatable, Sendable {
                /// No process is running. The next request for this host starts one.
                case stopped
                /// The process is starting and does not serve requests yet.
                case starting
                /// The process serves requests.
                case running
            }

            /// The `hostIdentifier` that `XcodeMCPKitListHosts` returns for this host.
            public let identifier: String

            /// Developer directory of the host's Xcode installation.
            public let developerDirectory: URL

            /// What the host connects to.
            public let kind: Kind

            /// Whether the host's process is running.
            public let state: State

            /// Number of requests the host is processing.
            public let activeRequestCount: Int
        }

        /// Snapshot generation time.
        public let generatedAt: Date

        /// Lifecycle phase at snapshot time.
        public let phase: Phase

        /// Bound endpoint when the server is running or stopping.
        public let endpoint: Endpoint?

        /// Hosts the server has registered, ordered by registration.
        public let hosts: [Host]

        init(generatedAt: Date, phase: Phase, endpoint: Endpoint?, hosts: [Host]) {
            self.generatedAt = generatedAt
            self.phase = phase
            self.endpoint = endpoint
            self.hosts = hosts
        }
    }

    struct Dependencies: Sendable {
        var discoveryClient: DiscoveryClient
        var processID: @Sendable () -> Int
        var makeRuntime: @Sendable (ServerRuntimeConfiguration) throws -> any ServerRuntimeServing
        var makeAutoApprover: @Sendable () -> any ServerPermissionDialogAutoApprover
        var makeHTTPGateway:
            @Sendable (
                ServerHTTPConfiguration,
                any ServerRuntimeServing,
                Logger
            ) -> any ServerHTTPGatewayServing

        init(
            discoveryClient: DiscoveryClient = .liveValue,
            processID: @escaping @Sendable () -> Int = {
                Int(ProcessInfo.processInfo.processIdentifier)
            },
            makeRuntime: @escaping @Sendable (ServerRuntimeConfiguration) throws -> any ServerRuntimeServing,
            makeAutoApprover: @escaping @Sendable () -> any ServerPermissionDialogAutoApprover = {
                XcodePermissionDialogAutomation.AutoApprover.liveForAllAgents()
            },
            makeHTTPGateway: @escaping @Sendable (
                ServerHTTPConfiguration,
                any ServerRuntimeServing,
                Logger
            ) -> any ServerHTTPGatewayServing = { configuration, runtime, logger in
                ServerHTTPGateway(
                    configuration: configuration,
                    runtime: runtime,
                    logger: logger
                )
            }
        ) {
            self.discoveryClient = discoveryClient
            self.processID = processID
            self.makeRuntime = makeRuntime
            self.makeAutoApprover = makeAutoApprover
            self.makeHTTPGateway = makeHTTPGateway
        }

        static var live: Self {
            return Self(
                makeRuntime: { config in
                    let invocation = try NativeHostInvocation.resolve(
                        bundleURL: config.nativeHostBundleURL,
                        developerDirectoryURL: config.developerDirectoryURL,
                        sharesCompilationCache: config.sharesCompilationCache
                    )
                    var resolved = config
                    resolved.nativeHostBundleURL = URL(fileURLWithPath: invocation.command)
                        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    return try NativeHostBroker(configuration: resolved)
                }
            )
        }
    }

    let logger: Logger = ServerLogging.make("server")
    let lifecycle: Lifecycle

    /// Creates a server with live runtime dependencies.
    ///
    /// - Parameter configuration: Public HTTP, native helper, discovery, and
    ///   lifecycle settings.
    public init(
        configuration: XcodeMCPServerConfiguration =
            XcodeMCPServerConfiguration()
    ) {
        let dependencies = Dependencies.live
        self.lifecycle = Lifecycle(
            configuration: configuration,
            dependencies: dependencies,
            logger: logger
        )
    }

    init(
        configuration: XcodeMCPServerConfiguration,
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

    /// Shuts down the server and its runtime resources.
    ///
    /// Shutdown closes listening and accepted channels, shuts down the
    /// native host, and terminates the event
    /// loop group.
    /// Repeated calls return the result of the same shutdown attempt, including
    /// any resource-release failure.
    public func shutdown() async throws {
        try await lifecycle.shutdown()
    }

    static func startupSummary(displayHost: String, port: Int) -> String {
        [
            "\(productMetadata.name) \(productMetadata.version)",
            "",
            "Server",
            "  URL: http://\(displayHost):\(port)/mcp",
            "  Xcode mode: headless (saved project files)",
        ].joined(separator: "\n")
    }

}

extension XcodeMCPServerConfiguration {
    func runtimeConfiguration() throws -> ServerRuntimeConfiguration {
        guard listenHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw XcodeMCPServer.LifecycleError.invalidConfiguration("bindAddress.host must not be empty")
        }
        guard (0...65_535).contains(listenPort) else {
            throw XcodeMCPServer.LifecycleError.invalidConfiguration("bindAddress.port must be in 0...65535")
        }
        guard maxBodyBytes > 0 else {
            throw XcodeMCPServer.LifecycleError.invalidConfiguration("maxBodyBytes must be greater than zero")
        }
        if let requestTimeout, requestTimeout <= .zero {
            throw XcodeMCPServer.LifecycleError.invalidConfiguration("requestTimeout must be positive; use nil to disable it")
        }
        return ServerRuntimeConfiguration(
            nativeHostBundleURL: nativeHostBundleURL,
            developerDirectoryURL: developerDirectoryURL,
            sharesCompilationCache: sharesCompilationCache,
            maxMessageBytes: maxBodyBytes,
            requestTimeout: requestTimeout,
            prewarmToolsList: prewarmToolsList
        )
    }
}
