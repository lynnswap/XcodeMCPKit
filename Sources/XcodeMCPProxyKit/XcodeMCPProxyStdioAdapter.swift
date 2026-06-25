import Foundation
import ProxyCore
import ProxyStdioTransport

/// Resolved upstream endpoint for the STDIO compatibility adapter.
public struct XcodeMCPProxyAdapterEndpoint: Equatable, Sendable {
    /// Source that selected the endpoint.
    public enum Source: String, Equatable, Sendable {
        case explicit
        case environment
        case discovery
        case fallback
    }

    /// Full Streamable HTTP MCP endpoint URL.
    public let url: URL

    /// How the endpoint was selected.
    public let source: Source

    public init(url: URL, source: Source) {
        self.url = url
        self.source = source
    }
}

/// Resolves the Streamable HTTP endpoint used by the STDIO adapter.
public struct XcodeMCPProxyAdapterEndpointResolver: Sendable {
    public struct Configuration: Equatable, Sendable {
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

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case invalidURL(label: String)

        public var description: String {
            switch self {
            case .invalidURL(let label):
                return "\(label) must be an http/https URL"
            }
        }
    }

    public static let endpointEnvironmentVariable = "XCODE_MCP_PROXY_ENDPOINT"
    public static let defaultEndpointURLString = "http://localhost:8765/mcp"
    public static let defaultEndpointURL = URL(string: defaultEndpointURLString)!

    package var discoveryClient: DiscoveryClient

    public init() {
        self.init(discoveryClient: .liveValue)
    }

    package init(discoveryClient: DiscoveryClient) {
        self.discoveryClient = discoveryClient
    }

    public static func discoveryFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        ProxyFilesystemLocations.discoveryFileURL(environment: environment)
    }

    public func resolve(
        _ configuration: Configuration = Configuration()
    ) throws -> XcodeMCPProxyAdapterEndpoint {
        if let explicit = Self.nonEmpty(configuration.explicitURL) {
            return XcodeMCPProxyAdapterEndpoint(
                url: try Self.parseHTTPURL(explicit, label: configuration.explicitURLLabel),
                source: .explicit
            )
        }

        if let raw = Self.nonEmpty(
            configuration.environment[Self.endpointEnvironmentVariable]
        ) {
            return XcodeMCPProxyAdapterEndpoint(
                url: try Self.parseHTTPURL(raw, label: Self.endpointEnvironmentVariable),
                source: .environment
            )
        }

        let discoveryFileURL = configuration.discoveryFileURL
            ?? Self.discoveryFileURL(environment: configuration.environment)
        if let record = discoveryClient.read(discoveryFileURL),
            let resolved = try? Self.parseHTTPURL(record.url, label: "discovery")
        {
            return XcodeMCPProxyAdapterEndpoint(url: resolved, source: .discovery)
        }

        guard Self.isHTTPURL(configuration.fallbackURL) else {
            throw Error.invalidURL(label: "fallback")
        }
        return XcodeMCPProxyAdapterEndpoint(
            url: configuration.fallbackURL,
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

/// Facade for running the STDIO compatibility adapter against the proxy server.
public final class XcodeMCPProxyStdioAdapter: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var endpoint: XcodeMCPProxyAdapterEndpointResolver.Configuration
        public var requestTimeout: TimeInterval

        public init(
            endpoint: XcodeMCPProxyAdapterEndpointResolver.Configuration = .init(),
            requestTimeout: TimeInterval = 300
        ) {
            self.endpoint = endpoint
            self.requestTimeout = requestTimeout
        }
    }

    public let endpoint: XcodeMCPProxyAdapterEndpoint

    private let adapter: StdioAdapter

    public convenience init(
        configuration: Configuration = Configuration(),
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

    public func start() async {
        await adapter.start()
    }

    public func wait() async {
        await adapter.wait()
    }

    public func stop() async {
        await adapter.stop()
    }
}
