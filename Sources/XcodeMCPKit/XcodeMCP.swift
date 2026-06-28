import Foundation

/// A high-level client for Xcode MCP.
///
/// `XcodeMCP` connects through the configured transport, performs the MCP
/// initialize handshake, and exposes the dynamic Xcode tool catalog through
/// ``listTools()`` and ``callTool(_:arguments:onProgress:)``. The default
/// transport starts a local `mcpbridge` process. Streamable HTTP transport can
/// connect to a running proxy endpoint.
///
/// The tool catalog is discovered at runtime. This package intentionally does
/// not promise tool-specific Swift methods or typed request/response models for
/// individual Xcode tools. Pass tool arguments as ``MCPJSONValue`` and inspect
/// the returned ``MCPToolResult`` for the final MCP response.
///
/// Server-to-client handlers such as roots, sampling, and elicitation are not
/// exposed by this v1 API. Progress notifications are delivered only through
/// the callback supplied to ``callTool(_:arguments:onProgress:)``; the streaming
/// transport itself is an implementation detail.
///
/// ```swift
/// import XcodeMCPKit
///
/// let xcode = try await XcodeMCP()
///
/// let tools = try await xcode.listTools()
/// guard tools.contains(where: { $0.name == "DocumentationSearch" }) else {
///     throw XcodeMCPError.invalidResponse("DocumentationSearch is unavailable")
/// }
///
/// _ = try await xcode.callTool(
///     "DocumentationSearch",
///     arguments: ["query": "NavigationStack"]
/// )
///
/// await xcode.close()
/// ```
public actor XcodeMCP {
    /// Settings used to connect to and initialize an MCP endpoint.
    ///
    /// The default configuration starts `xcrun mcpbridge` with the current
    /// process environment and a conservative per-request timeout. Use
    /// ``Transport/streamableHTTP(endpoint:)`` to connect to a proxy
    /// Streamable HTTP endpoint instead.
    public struct Configuration: Equatable, Sendable {
        /// Transport used to reach the Xcode MCP server.
        public enum Transport: Equatable, Sendable {
            /// Launch and talk to a local bridge process over stdio.
            case localBridge(Bridge)

            /// Connect to a concrete Streamable HTTP MCP endpoint.
            case streamableHTTP(endpoint: URL)

            /// Connect to the Streamable HTTP endpoint recorded in a proxy
            /// discovery file.
            case streamableHTTPDiscoveryFile(URL)

            /// Connect to the Streamable HTTP endpoint recorded in a proxy
            /// discovery file.
            ///
            /// The discovery file uses the same shape written by
            /// `xcode-mcp-proxy-server startAndWriteDiscovery()`.
            public static func streamableHTTP(discoveryFile: URL) -> Self {
                .streamableHTTPDiscoveryFile(discoveryFile)
            }

            /// Connect to the Streamable HTTP proxy endpoint discovered from
            /// the standard proxy discovery file location.
            ///
            /// The file path honors `XCODE_MCP_PROXY_DISCOVERY_FILE` first,
            /// then `XCODE_MCP_PROXY_CACHE_ROOT`, and otherwise uses the
            /// default user caches location used by `xcode-mcp-proxy-server`.
            ///
            /// - Parameter environment: Environment used to resolve proxy
            ///   discovery overrides.
            public static func streamableHTTPProxyDiscovery(
                environment: [String: String] = ProcessInfo.processInfo.environment
            ) -> Self {
                .streamableHTTP(discoveryFile: Discovery.defaultFileURL(environment: environment))
            }
        }

        /// Upstream bridge process policy.
        public enum Bridge: Equatable, Sendable {
            /// Use Xcode's default `xcrun mcpbridge` invocation.
            case defaultMCPBridge

            /// Use an explicit upstream bridge command.
            case custom(
                command: String,
                arguments: [String],
                environment: [String: String]
            )

            package var invocation: MCPBridgeInvocation {
                switch self {
                case .defaultMCPBridge:
                    return .defaultMCPBridge
                case .custom(let command, let arguments, _):
                    return MCPBridgeInvocation(command: command, arguments: arguments)
                }
            }

            package var command: String {
                invocation.command
            }

            package var arguments: [String] {
                invocation.arguments
            }

            package var environment: [String: String] {
                switch self {
                case .defaultMCPBridge:
                    return ProcessInfo.processInfo.environment
                case .custom(_, _, let environment):
                    return environment
                }
            }

            package var maxQueuedWriteBytes: Int {
                4 * 1024 * 1024
            }
        }

        /// Transport used to reach the Xcode MCP server.
        public var transport: Transport

        /// Bridge process policy.
        ///
        /// This compatibility property reads and writes the local bridge used
        /// by ``Transport/localBridge(_:)``. Setting it switches the
        /// configuration back to local process transport.
        public var bridge: Bridge {
            get {
                guard case .localBridge(let bridge) = transport else {
                    return .defaultMCPBridge
                }
                return bridge
            }
            set {
                transport = .localBridge(newValue)
            }
        }

        /// Client name sent in the MCP `initialize` request.
        public var clientName: String

        /// Client version sent in the MCP `initialize` request.
        public var clientVersion: String

        /// Additional MCP client capabilities sent during initialization.
        ///
        /// Values are encoded as raw MCP JSON. Capabilities that require
        /// server-to-client handlers, such as `roots`, `sampling`, and
        /// `elicitation`, are intentionally not exposed by this API.
        public var capabilities: [String: MCPJSONValue]

        /// Maximum duration to wait for each request.
        ///
        /// Set this to `nil` to disable client-side request timeouts.
        public var requestTimeout: Duration?

        /// Creates a local bridge configuration.
        ///
        /// - Parameters:
        ///   - bridge: Upstream bridge process policy.
        ///   - clientName: Client name sent in the MCP `initialize` request.
        ///   - clientVersion: Client version sent in the MCP `initialize`
        ///     request.
        ///   - capabilities: Additional MCP client capabilities encoded as raw
        ///     MCP JSON.
        ///   - requestTimeout: Maximum duration to wait for each request, or
        ///     `nil` to disable client-side request timeouts.
        public init(
            bridge: Bridge = .defaultMCPBridge,
            clientName: String = "XcodeMCPKit",
            clientVersion: String = "dev",
            capabilities: [String: MCPJSONValue] = [:],
            requestTimeout: Duration? = .seconds(60)
        ) {
            self.transport = .localBridge(bridge)
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.capabilities = capabilities
            self.requestTimeout = requestTimeout
        }

        /// Creates a configuration for the selected transport.
        ///
        /// - Parameters:
        ///   - transport: Transport used to reach the Xcode MCP server.
        ///   - clientName: Client name sent in the MCP `initialize` request.
        ///   - clientVersion: Client version sent in the MCP `initialize`
        ///     request.
        ///   - capabilities: Additional MCP client capabilities encoded as raw
        ///     MCP JSON.
        ///   - requestTimeout: Maximum duration to wait for each request, or
        ///     `nil` to disable client-side request timeouts.
        public init(
            transport: Transport,
            clientName: String = "XcodeMCPKit",
            clientVersion: String = "dev",
            capabilities: [String: MCPJSONValue] = [:],
            requestTimeout: Duration? = .seconds(60)
        ) {
            self.transport = transport
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.capabilities = capabilities
            self.requestTimeout = requestTimeout
        }
    }

    private let session: InitializedMCPClientSession

    /// Connects to the configured MCP transport and returns an initialized
    /// client.
    ///
    /// For local bridge transport the initializer launches the configured
    /// process. For Streamable HTTP transport it connects to the configured
    /// endpoint. In both cases it sends MCP `initialize`, then sends
    /// `notifications/initialized`. If initialization fails, the transport is
    /// closed before the error is rethrown.
    ///
    /// - Parameter config: Connection and initialization settings.
    public init(config: Configuration = Configuration()) async throws {
        try await self.init(
            config: config,
            streamableHTTPDiscoveryResolver: .liveValue
        )
    }

    package init(
        config: Configuration = Configuration(),
        streamableHTTPDiscoveryResolver: StreamableHTTPDiscoveryResolver
    ) async throws {
        do {
            let transport: any XcodeMCPTransport
            switch config.transport {
            case .localBridge(let bridge):
                transport = try await UpstreamProcessXcodeMCPTransport.start(
                    command: bridge.command,
                    arguments: bridge.arguments,
                    environment: bridge.environment,
                    maxQueuedWriteBytes: bridge.maxQueuedWriteBytes
                )
            case .streamableHTTP(let endpoint):
                transport = try await StreamableHTTPXcodeMCPTransport.start(
                    endpoint: endpoint,
                    requestTimeout: config.requestTimeout
                )
            case .streamableHTTPDiscoveryFile(let discoveryFile):
                transport = try await StreamableHTTPXcodeMCPTransport.start(
                    discoveryFile: discoveryFile,
                    requestTimeout: config.requestTimeout,
                    discoveryResolver: streamableHTTPDiscoveryResolver
                )
            }
            try await self.init(config: config, transport: transport)
        } catch {
            throw Self.publicError(from: error)
        }
    }

    package init(config: Configuration = Configuration(), transport: any XcodeMCPTransport) async throws {
        do {
            self.session = try await InitializedMCPClientSession(
                transport: transport,
                configuration: InitializedMCPClientSession.Configuration(
                    clientName: config.clientName,
                    clientVersion: config.clientVersion,
                    capabilities: config.capabilities.mapValues(\.jsonValue),
                    requestTimeout: config.requestTimeout
                )
            )
        } catch {
            throw Self.publicError(from: error)
        }
    }

    isolated deinit {
        let session = session
        Task {
            await session.close()
        }
    }

    /// Returns the currently available Xcode MCP tools.
    ///
    /// The returned catalog is dynamic and comes from the running Xcode MCP
    /// server. Use the tool `name` with ``callTool(_:arguments:onProgress:)``
    /// and treat `inputSchema` and `raw` as MCP JSON supplied by the server.
    public func listTools() async throws -> [MCPTool] {
        let result = try await request("tools/list")
        guard let tools = result.objectValue?["tools"]?.arrayValue else {
            throw XcodeMCPError.invalidResponse("tools/list result is missing tools")
        }
        return try tools.map { try MCPTool(json: $0) }
    }

    /// Calls an Xcode MCP tool and returns its final result.
    ///
    /// This method sends an MCP `tools/call` request using the supplied raw JSON
    /// arguments. It waits for the final `tools/call` response and returns it as
    /// ``MCPToolResult``. Incremental transport events are not exposed as a
    /// public stream; progress notifications are delivered through
    /// `onProgress` when the server emits them.
    ///
    /// - Parameters:
    ///   - name: Tool name from ``listTools()``.
    ///   - arguments: Tool arguments encoded as MCP JSON.
    ///   - onProgress: Optional callback for MCP progress notifications
    ///     associated with this call.
    /// - Returns: The final tool result, including content, structured content,
    ///   error status, and the raw MCP JSON response.
    public func callTool(
        _ name: String,
        arguments: [String: MCPJSONValue] = [:],
        onProgress: (@Sendable (MCPProgress) async -> Void)? = nil
    ) async throws -> MCPToolResult {
        guard name.isEmpty == false else {
            throw XcodeMCPError.invalidRequest("tool name must not be empty")
        }

        let params: [String: MCPJSONValue] = [
            "name": .string(name),
            "arguments": .object(arguments),
        ]
        let progressHandler: InitializedMCPClientSession.ProgressHandler?
        if let onProgress {
            progressHandler = { rawProgress in
                guard let progress = MCPProgress(json: MCPJSONValue(rawProgress)) else {
                    return
                }
                await onProgress(progress)
            }
        } else {
            progressHandler = nil
        }

        let result = try await request(
            "tools/call",
            params: .object(params),
            onProgress: progressHandler
        )
        return try MCPToolResult(json: result)
    }

    /// Sends an arbitrary MCP request and returns the raw result.
    ///
    /// Use this escape hatch for dynamic MCP methods that are not `tools/list`
    /// or `tools/call`. The client still owns JSON-RPC framing, request ids,
    /// transport session headers, timeouts, and response error mapping.
    ///
    /// This method intentionally returns ``MCPJSONValue`` instead of a
    /// tool-specific model so SDK consumers can call newly discovered MCP
    /// methods without this package adding typed wrappers.
    ///
    /// - Parameters:
    ///   - method: MCP method name to send.
    ///   - params: Optional raw MCP params.
    /// - Returns: The raw MCP result value, or ``MCPJSONValue/null`` when the
    ///   server response omits `result`.
    public func request(
        _ method: String,
        params: MCPJSONValue? = nil
    ) async throws -> MCPJSONValue {
        try await request(method, params: params, onProgress: nil)
    }

    /// Sends an arbitrary MCP notification.
    ///
    /// Use this escape hatch for dynamic MCP notifications. The client still
    /// owns JSON-RPC framing, transport session headers, and transport error
    /// mapping, but no response is expected from the server.
    ///
    /// - Parameters:
    ///   - method: MCP notification method name to send.
    ///   - params: Optional raw MCP params.
    public func notify(_ method: String, params: MCPJSONValue? = nil) async throws {
        do {
            try await session.notify(method, params: params?.jsonValue)
        } catch {
            throw Self.publicError(from: error)
        }
    }

    /// Closes the client and terminates the underlying transport.
    ///
    /// Closing is idempotent. Pending requests fail with ``XcodeMCPError/closed``,
    /// registered progress callbacks are discarded, and no further requests may
    /// be sent through this client.
    public func close() async {
        await session.close()
    }
}

extension XcodeMCP {
    package func request(
        _ method: String,
        params: MCPJSONValue? = nil,
        onProgress: InitializedMCPClientSession.ProgressHandler?
    ) async throws -> MCPJSONValue {
        do {
            let result = try await session.request(
                method,
                params: params?.jsonValue,
                onProgress: onProgress
            )
            return MCPJSONValue(result)
        } catch {
            throw Self.publicError(from: error)
        }
    }
}

private extension XcodeMCP {
    static func publicError(from error: any Error) -> any Error {
        if let error = error as? XcodeMCPError {
            return error
        }
        if error is CancellationError {
            return error
        }
        guard let runtimeError = error as? MCPBridgeRuntimeError else {
            return XcodeMCPError.transportUnavailable(errorDescription(error))
        }
        switch runtimeError {
        case .closed:
            return XcodeMCPError.closed
        case .invalidRequest(let message):
            return XcodeMCPError.invalidRequest(message)
        case .invalidResponse(let message):
            return XcodeMCPError.invalidResponse(message)
        case .requestTimedOut(let method):
            return XcodeMCPError.requestTimedOut(method: method)
        case .serverError(let code, let message, let data):
            return XcodeMCPError.serverError(
                code: code,
                message: message,
                data: data.map(MCPJSONValue.init)
            )
        case .transportUnavailable(let reason):
            return XcodeMCPError.transportUnavailable(reason)
        }
    }

    static func errorDescription(_ error: any Error) -> String {
        let nsError = error as NSError
        if nsError.localizedDescription.isEmpty == false {
            return nsError.localizedDescription
        }
        return String(describing: error)
    }
}
