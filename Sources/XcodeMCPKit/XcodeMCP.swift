import XcodeMCPCore
import Foundation

/// Settings used to connect to and initialize an MCP endpoint.
///
/// The default configuration connects to the running XcodeMCPKit server, which
/// loads saved workspace models in its owned headless host. Use
/// ``XcodeMCPConfiguration/Transport/nativeHost(bundleURL:developerDirectoryURL:)``
/// for a standalone native host, or
/// ``XcodeMCPConfiguration/Transport/process(command:arguments:environment:)``
/// for another MCP process.
public struct XcodeMCPConfiguration: Equatable, Sendable {
    /// What the client connects to.
    public struct Transport: Equatable, Sendable {
        package enum Storage: Equatable, Sendable {
            case endpoint(URL)
            case discoveryFile(URL)
            case nativeHost(bundleURL: URL?, developerDirectoryURL: URL?)
            case process(command: String, arguments: [String], environment: [String: String])
        }

        package let storage: Storage

        /// The running server, found through its discovery file in the standard
        /// location.
        ///
        /// The file path honors `XCODE_MCP_PROXY_DISCOVERY_FILE` first, then
        /// `XCODE_MCP_PROXY_CACHE_ROOT`, and otherwise uses the default user
        /// caches location used by `xcode-mcp-proxy-server`.
        ///
        /// - Parameter environment: Environment used to resolve the discovery
        ///   file location.
        public static func server(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Self {
            .server(discoveryFile: Discovery.defaultFileURL(environment: environment))
        }

        /// The running server recorded in a discovery file.
        ///
        /// The file uses the shape written by a server configured with
        /// discovery enabled.
        public static func server(discoveryFile: URL) -> Self {
            Self(storage: .discoveryFile(discoveryFile))
        }

        /// A Streamable HTTP MCP endpoint.
        public static func server(at endpoint: URL) -> Self {
            Self(storage: .endpoint(endpoint))
        }

        /// A windowless native host that the client launches and owns.
        ///
        /// - Parameters:
        ///   - bundleURL: The helper application, or `nil` to find the installed one.
        ///   - developerDirectoryURL: The Xcode developer directory, or `nil` to
        ///     use Xcode discovery.
        public static func nativeHost(
            bundleURL: URL? = nil,
            developerDirectoryURL: URL? = nil
        ) -> Self {
            Self(storage: .nativeHost(
                bundleURL: bundleURL,
                developerDirectoryURL: developerDirectoryURL
            ))
        }

        /// An MCP process that the client launches and talks to over stdio.
        public static func process(
            command: String,
            arguments: [String] = [],
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Self {
            Self(storage: .process(
                command: command,
                arguments: arguments,
                environment: environment
            ))
        }
    }

    /// What the client connects to.
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

    /// Maximum duration to wait for each request. Defaults to 600 seconds.
    ///
    /// Set this to `nil` to disable client-side request timeouts.
    public var requestTimeout: Duration?

    /// Creates a configuration for the selected transport.
    ///
    /// - Parameters:
    ///   - transport: What the client connects to.
    ///   - clientName: Client name sent in the MCP `initialize` request.
    ///   - clientVersion: Client version sent in the MCP `initialize` request.
    ///   - capabilities: Additional MCP client capabilities encoded as raw MCP
    ///     JSON.
    ///   - requestTimeout: Maximum duration to wait for each request, or `nil`
    ///     to disable client-side request timeouts.
    public init(
        transport: Transport = .server(),
        clientName: String = "XcodeMCPKit",
        clientVersion: String = "dev",
        capabilities: [String: MCPJSONValue] = [:],
        requestTimeout: Duration? = .seconds(600)
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
/// ``listTools(timeout:)`` and ``callTool(_:arguments:timeout:onProgress:)``.
/// The default transport connects to the running server. Other transports
/// start an owned windowless host or another MCP process.
///
/// The tool catalog is discovered at runtime. This package intentionally does
/// not promise tool-specific Swift methods or typed request/response models for
/// individual Xcode tools. Pass tool arguments as ``MCPJSONValue`` and inspect
/// the returned ``MCPToolResult`` for the final MCP response.
///
/// Server-to-client handlers such as roots, sampling, and elicitation are not
/// exposed by this v1 API. Progress notifications are delivered only through
/// the callback supplied to ``callTool(_:arguments:timeout:onProgress:)``; the streaming
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
    /// For a process transport the initializer launches the process. For a
    /// server transport it connects to the endpoint. In both cases it sends
    /// MCP `initialize`, then sends
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
            case .nativeHost(let bundleURL, let developerDirectoryURL):
                recipe = MCPTransportRecipe {
                    let invocation = try NativeHostInvocation.resolve(
                        bundleURL: bundleURL,
                        developerDirectoryURL: developerDirectoryURL
                    )
                    return try await ProcessXcodeMCPTransport.start(
                        command: invocation.command,
                        arguments: invocation.arguments,
                        environment: ProcessInfo.processInfo.environment
                    )
                }
            case .process(let command, let arguments, let environment):
                recipe = MCPTransportRecipe {
                    try await ProcessXcodeMCPTransport.start(
                        command: command,
                        arguments: arguments,
                        environment: environment
                    )
                }
            case .endpoint(let endpoint):
                recipe = MCPTransportRecipe {
                    try await StreamableHTTPXcodeMCPTransport.start(
                        endpoint: endpoint,
                        requestTimeout: configuration.requestTimeout
                    )
                }
            case .discoveryFile(let discoveryFile):
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
    /// server. Use the tool `name` with
    /// ``callTool(_:arguments:timeout:onProgress:)`` and treat `inputSchema`
    /// and `raw` as MCP JSON supplied by the server.
    ///
    /// - Parameter timeout: The limit for loading every page of the catalog.
    public func listTools(
        timeout: XcodeMCPTimeout = .default
    ) async throws -> [MCPTool] {
        let deadline = try operationDeadline(timeout)
        do {
            return try await session.requestAllPages("tools/list", deadline: deadline) { page in
                guard let tools = MCPJSONValue(page)["tools"]?.arrayValue else {
                    throw XcodeMCPError.invalidResponse("tools/list result is missing tools")
                }
                return try tools.map { try MCPTool(json: $0) }
            }
        } catch {
            throw Self.publicError(from: error)
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
    ///   - name: Tool name from ``listTools(timeout:)``.
    ///   - arguments: Tool arguments encoded as MCP JSON.
    ///   - timeout: The limit for this call.
    ///   - onProgress: Optional callback for MCP progress notifications
    ///     associated with this call.
    /// - Returns: The final tool result, including content, structured content,
    ///   error status, and the raw MCP JSON response.
    public func callTool(
        _ name: String,
        arguments: [String: MCPJSONValue] = [:],
        timeout: XcodeMCPTimeout = .default,
        onProgress: (@Sendable (MCPProgress) async -> Void)? = nil
    ) async throws -> MCPToolResult {
        guard name.isEmpty == false else {
            throw XcodeMCPError.invalidRequest("tool name must not be empty")
        }
        let deadline = try operationDeadline(timeout)

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
            deadline: deadline,
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
    ///   - timeout: The limit for this request.
    /// - Returns: The raw MCP result value, or ``MCPJSONValue/null`` when the
    ///   server response omits `result`.
    public func request(
        _ method: String,
        params: MCPJSONValue? = nil,
        timeout: XcodeMCPTimeout = .default
    ) async throws -> MCPJSONValue {
        try await request(
            method,
            params: params,
            deadline: try operationDeadline(timeout),
            onProgress: nil
        )
    }

    /// The current connection snapshot.
    public var connectionState: XcodeMCPConnectionState {
        get async { await session.connectionState() }
    }

    /// A new stream of connection snapshots that starts with the current one
    /// and finishes after ``close()``. Each access returns an independent stream.
    public var connectionStates: AsyncStream<XcodeMCPConnectionState> {
        get async { await session.connectionStates() }
    }

    /// Explicitly creates and initializes a fresh transport connection.
    ///
    /// The connection attempt is bounded by ``XcodeMCPConfiguration/requestTimeout``
    /// (30 seconds when it is `nil`) and continues if this call is cancelled.
    ///
    /// - Parameter timeout: How long this call waits for the attempt.
    public func reconnect(timeout: XcodeMCPTimeout = .default) async throws {
        do {
            try await session.reconnect(deadline: try operationDeadline(timeout))
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
        deadline: Deadline?,
        onProgress: InitializedMCPClientSession.ProgressHandler?
    ) async throws -> MCPJSONValue {
        do {
            let result = try await session.request(
                method,
                params: params?.jsonValue,
                deadline: deadline,
                onProgress: onProgress
            )
            return MCPJSONValue(result)
        } catch {
            throw Self.publicError(from: error)
        }
    }
}

private extension XcodeMCP {
    func operationDeadline(_ timeout: XcodeMCPTimeout) throws -> Deadline? {
        switch timeout {
        case .default:
            return Deadline.fromNow(defaultRequestTimeout, clock: clock)
        case .unlimited:
            return nil
        case .after(let duration):
            guard duration > .zero else {
                throw XcodeMCPError.invalidRequest(
                    "timeout must be greater than zero; use .unlimited for no limit"
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
        guard let runtimeError = error as? MCPRuntimeError else {
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
