import Foundation

/// Settings used to connect to and initialize an MCP endpoint.
///
/// The default configuration starts `xcrun mcpbridge` with the current process
/// environment and a conservative per-request timeout. Use
/// ``XcodeMCPConfiguration/Transport/streamableHTTP(endpoint:)`` to connect to
/// a proxy Streamable HTTP endpoint instead.
public struct XcodeMCPConfiguration: Equatable, Sendable {
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
    public struct Transport: Equatable, Sendable {
        package enum Storage: Equatable, Sendable {
            case localBridge(Bridge)
            case streamableHTTP(endpoint: URL)
            case streamableHTTPDiscoveryFile(URL)
        }

        package let storage: Storage

        package init(storage: Storage) {
            self.storage = storage
        }

        /// Launch and talk to a local bridge process over stdio.
        public static func localBridge(_ bridge: Bridge = .defaultMCPBridge) -> Self {
            Self(storage: .localBridge(bridge))
        }

        /// Connect to a concrete Streamable HTTP MCP endpoint.
        public static func streamableHTTP(endpoint: URL) -> Self {
            Self(storage: .streamableHTTP(endpoint: endpoint))
        }

        /// Connect to the Streamable HTTP endpoint recorded in a proxy
        /// discovery file.
        ///
        /// The discovery file uses the same shape written by a proxy server
        /// configured with discovery enabled.
        public static func streamableHTTP(discoveryFile: URL) -> Self {
            Self(storage: .streamableHTTPDiscoveryFile(discoveryFile))
        }

        /// Connect to the Streamable HTTP proxy endpoint discovered from the
        /// standard proxy discovery file location.
        ///
        /// The file path honors `XCODE_MCP_PROXY_DISCOVERY_FILE` first, then
        /// `XCODE_MCP_PROXY_CACHE_ROOT`, and otherwise uses the default user
        /// caches location used by `xcode-mcp-proxy-server`.
        ///
        /// - Parameter environment: Environment used to resolve proxy discovery
        ///   overrides.
        public static func streamableHTTPProxyDiscovery(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Self {
            .streamableHTTP(discoveryFile: Discovery.defaultFileURL(environment: environment))
        }
    }

    /// Transport used to reach the Xcode MCP server.
    public var transport: Transport

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

    /// Creates a configuration for the selected transport.
    ///
    /// - Parameters:
    ///   - transport: Transport used to reach the Xcode MCP server.
    ///   - clientName: Client name sent in the MCP `initialize` request.
    ///   - clientVersion: Client version sent in the MCP `initialize` request.
    ///   - capabilities: Additional MCP client capabilities encoded as raw MCP
    ///     JSON.
    ///   - requestTimeout: Maximum duration to wait for each request, or `nil`
    ///     to disable client-side request timeouts.
    public init(
        transport: Transport = .localBridge(),
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
    private let session: InitializedMCPClientSession
    private let defaultRequestTimeout: Duration?
    private let clock: ClockClient

    /// Connects to the configured MCP transport and returns an initialized
    /// client.
    ///
    /// For local bridge transport the initializer launches the configured
    /// process. For Streamable HTTP transport it connects to the configured
    /// endpoint. In both cases it sends MCP `initialize`, then sends
    /// `notifications/initialized`. If initialization fails, the transport is
    /// closed before the error is rethrown.
    ///
    /// - Parameter configuration: Connection and initialization settings.
    public init(configuration: XcodeMCPConfiguration = XcodeMCPConfiguration()) async throws {
        try await self.init(
            configuration: configuration,
            streamableHTTPDiscoveryResolver: .liveValue
        )
    }

    package init(
        configuration: XcodeMCPConfiguration = XcodeMCPConfiguration(),
        streamableHTTPDiscoveryResolver: StreamableHTTPDiscoveryResolver
    ) async throws {
        do {
            let recipe: MCPTransportRecipe
            switch configuration.transport.storage {
            case .localBridge(let bridge):
                recipe = MCPTransportRecipe {
                    try await UpstreamProcessXcodeMCPTransport.start(
                        command: bridge.command,
                        arguments: bridge.arguments,
                        environment: bridge.environment,
                        maxQueuedWriteBytes: bridge.maxQueuedWriteBytes
                    )
                }
            case .streamableHTTP(let endpoint):
                recipe = MCPTransportRecipe {
                    try await StreamableHTTPXcodeMCPTransport.start(
                        endpoint: endpoint,
                        requestTimeout: configuration.requestTimeout
                    )
                }
            case .streamableHTTPDiscoveryFile(let discoveryFile):
                recipe = MCPTransportRecipe {
                    try await StreamableHTTPXcodeMCPTransport.start(
                        discoveryFile: discoveryFile,
                        requestTimeout: configuration.requestTimeout,
                        discoveryResolver: streamableHTTPDiscoveryResolver
                    )
                }
            }
            try await self.init(configuration: configuration, recipe: recipe)
        } catch {
            throw Self.publicError(from: error)
        }
    }

    package init(
        configuration: XcodeMCPConfiguration = XcodeMCPConfiguration(),
        transport: any XcodeMCPTransport
    ) async throws {
        try await self.init(
            configuration: configuration,
            recipe: MCPTransportRecipe { transport }
        )
    }

    package init(
        configuration: XcodeMCPConfiguration = XcodeMCPConfiguration(),
        recipe: MCPTransportRecipe
    ) async throws {
        do {
            if let timeout = configuration.requestTimeout, timeout <= .zero {
                throw XcodeMCPError.invalidRequest(
                    "requestTimeout must be greater than zero; use nil to disable timeouts"
                )
            }
            let sessionConfiguration = InitializedMCPClientSession.Configuration(
                clientName: configuration.clientName,
                clientVersion: configuration.clientVersion,
                capabilities: configuration.capabilities.mapValues(\.jsonValue),
                requestTimeout: configuration.requestTimeout
            )
            let authority = try await MCPClientSessionAuthority.startManaged(
                recipe: recipe,
                initialize: MCPManagedInitializeContext(
                    clientName: configuration.clientName,
                    clientVersion: configuration.clientVersion,
                    capabilities: sessionConfiguration.capabilities
                ),
                defaultTimeout: configuration.requestTimeout,
                clock: sessionConfiguration.clock
            )
            let session = InitializedMCPClientSession(
                authority: authority,
                configuration: sessionConfiguration
            )
            await session.start()
            self.session = session
            self.defaultRequestTimeout = configuration.requestTimeout
            self.clock = sessionConfiguration.clock
        } catch {
            throw Self.publicError(from: error)
        }
    }

    /// Returns the currently available Xcode MCP tools.
    ///
    /// The returned catalog is dynamic and comes from the running Xcode MCP
    /// server. Use the tool `name` with ``callTool(_:arguments:onProgress:)``
    /// and treat `inputSchema` and `raw` as MCP JSON supplied by the server.
    public func listTools(
        options: XcodeMCPRequestOptions = .init()
    ) async throws -> [MCPTool] {
        let deadline = try operationDeadline(options.timeout)
        var expectedGeneration = await session.connectionState().generation
        var restartedAfterGenerationChange = false
        var replayAvailable = options.replayPolicy == .onceWhenRejectedBeforeProcessing
        var cursor: String?
        var seenCursors: Set<String> = []
        var tools: [MCPTool] = []

        while true {
            let params = cursor.map { MCPJSONValue.object(["cursor": .string($0)]) }
            var pageOptions = options
            pageOptions.replayPolicy = replayAvailable
                ? .onceWhenRejectedBeforeProcessing
                : .never
            let result = try await request(
                "tools/list",
                params: params,
                options: pageOptions,
                resolvedDeadline: deadline,
                onProgress: nil
            )
            let generation = await session.connectionState().generation
            if generation != expectedGeneration {
                guard restartedAfterGenerationChange == false else {
                    throw XcodeMCPError.sessionRecoveryFailed(
                        "connection changed more than once while loading the tool catalog"
                    )
                }
                restartedAfterGenerationChange = true
                replayAvailable = false
                expectedGeneration = generation
                cursor = nil
                seenCursors.removeAll()
                tools.removeAll()
                continue
            }
            guard let page = result["tools"]?.arrayValue else {
                throw XcodeMCPError.invalidResponse("tools/list result is missing tools")
            }
            tools.append(contentsOf: try page.map { try MCPTool(json: $0) })
            guard let nextCursor = result["nextCursor"]?.stringValue,
                  nextCursor.isEmpty == false else {
                return tools
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw XcodeMCPError.invalidResponse("tools/list returned a cursor cycle")
            }
            cursor = nextCursor
        }
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
        options: XcodeMCPRequestOptions = .init(),
        onProgress: (@Sendable (MCPProgress) async -> Void)? = nil
    ) async throws -> MCPToolResult {
        guard name.isEmpty == false else {
            throw XcodeMCPError.invalidRequest("tool name must not be empty")
        }
        let resolvedDeadline = try operationDeadline(options.timeout)

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
            options: options,
            resolvedDeadline: resolvedDeadline,
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
        params: MCPJSONValue? = nil,
        options: XcodeMCPRequestOptions = .init()
    ) async throws -> MCPJSONValue {
        try await request(
            method,
            params: params,
            options: options,
            resolvedDeadline: try operationDeadline(options.timeout),
            onProgress: nil
        )
    }

    /// Returns the current atomic connection snapshot.
    public func connectionState() async -> XcodeMCPConnectionSnapshot {
        await session.connectionState()
    }

    /// Returns an independent state stream whose first element is the current
    /// snapshot. The stream finishes after ``close()``.
    public func connectionStates() async -> AsyncStream<XcodeMCPConnectionSnapshot> {
        await session.connectionStates()
    }

    /// Explicitly creates and initializes a fresh transport connection.
    public func reconnect(options: XcodeMCPRequestOptions = .init()) async throws {
        do {
            try await session.reconnect(deadline: try operationDeadline(options.timeout))
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
        options: XcodeMCPRequestOptions = .init(),
        resolvedDeadline: Deadline?,
        onProgress: InitializedMCPClientSession.ProgressHandler?
    ) async throws -> MCPJSONValue {
        do {
            let result = try await session.request(
                method,
                params: params?.jsonValue,
                deadline: resolvedDeadline,
                replayPolicy: options.replayPolicy == .never
                    ? .never
                    : .onceWhenRejectedBeforeProcessing,
                onProgress: onProgress
            )
            return MCPJSONValue(result)
        } catch {
            throw Self.publicError(from: error)
        }
    }
}

private extension XcodeMCP {
    func operationDeadline(_ timeout: XcodeMCPRequestOptions.Timeout) throws -> Deadline? {
        switch timeout {
        case .configurationDefault:
            return Deadline.fromNow(defaultRequestTimeout, clock: clock)
        case .disabled:
            return nil
        case .after(let duration):
            guard duration > .zero else {
                throw XcodeMCPError.invalidRequest(
                    "request timeout must be greater than zero; use .disabled to disable it"
                )
            }
            return Deadline.fromNow(duration, clock: clock)
        }
    }

    static func publicError(from error: any Error) -> any Error {
        if let error = error as? XcodeMCPError {
            return error
        }
        if let failure = error as? MCPClientSessionFailure,
           case .sessionRecoveryFailed(let reason) = failure {
            return XcodeMCPError.sessionRecoveryFailed(reason)
        }
        if error is CancellationError {
            return error
        }
        guard let runtimeError = error as? MCPBridgeRuntimeError else {
            if let failure = error as? MCPTransportFailure {
                switch failure {
                case .sessionExpired(let sessionID, _):
                    return XcodeMCPError.sessionRecoveryFailed(
                        "session \(sessionID) expired and could not be replaced"
                    )
                case .deliveryUnknown(let reason), .unavailable(let reason):
                    return XcodeMCPError.transportUnavailable(reason)
                }
            }
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
        case .httpStatus(let code, let body):
            let suffix = body.isEmpty ? "" : ": \(body)"
            return XcodeMCPError.transportUnavailable(
                "Streamable HTTP request failed with status \(code)\(suffix)"
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
