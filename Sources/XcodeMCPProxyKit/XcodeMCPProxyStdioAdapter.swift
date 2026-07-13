import Foundation
import XcodeMCPKit

/// Configuration for a Streamable HTTP to STDIO MCP adapter.
public struct XcodeMCPProxyStdioAdapterConfiguration: Equatable, Sendable {
    /// Policy used to select the Streamable HTTP proxy endpoint.
    public enum Endpoint: Equatable, Sendable {
        /// Connect to one concrete endpoint.
        case url(URL)

        /// Read the endpoint hint from one discovery file.
        case discoveryFile(URL)

        /// Resolve `XCODE_MCP_PROXY_ENDPOINT`, then proxy discovery, then the
        /// standard localhost endpoint using the supplied environment.
        case proxyDefault(environment: [String: String])
    }

    /// Endpoint policy used when the adapter starts forwarding messages.
    public var endpoint: Endpoint

    /// Maximum duration for one logical request, or `nil` to disable the
    /// client-side timeout.
    public var requestTimeout: Duration?

    /// Creates an adapter configuration.
    public init(
        endpoint: Endpoint = .proxyDefault(
            environment: ProcessInfo.processInfo.environment
        ),
        requestTimeout: Duration? = .seconds(300)
    ) {
        self.endpoint = endpoint
        self.requestTimeout = requestTimeout
    }
}

/// A one-shot STDIO adapter for a running Xcode MCP Streamable HTTP proxy.
///
/// Create and start one instance, wait for EOF or call ``stop()``, then discard
/// it. ``stop()`` is idempotent and returns only after owned reads, requests,
/// recovery work, event delivery, and transport shutdown have completed.
public final class XcodeMCPProxyStdioAdapter: Sendable {
    private let adapter: StdioAdapter

    /// Creates an adapter without acquiring network resources.
    ///
    /// Invalid endpoints and non-positive timeouts are rejected before an
    /// internal session is created. `nil` is the only disabled timeout value.
    public convenience init(
        configuration: XcodeMCPProxyStdioAdapterConfiguration = .init(),
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) throws {
        try self.init(
            configuration: configuration,
            input: input,
            output: output,
            shutdownPolicy: .live
        )
    }

    package init(
        configuration: XcodeMCPProxyStdioAdapterConfiguration,
        input: FileHandle,
        output: FileHandle,
        shutdownPolicy: StdioAdapterShutdownPolicy
    ) throws {
        if let timeout = configuration.requestTimeout, timeout <= .zero {
            throw XcodeMCPError.invalidRequest(
                "requestTimeout must be greater than zero; use nil to disable timeouts"
            )
        }
        let endpoint = try AdapterEndpointResolver.resolve(configuration.endpoint)
        self.adapter = StdioAdapter(
            upstreamURL: endpoint,
            requestTimeout: configuration.requestTimeout,
            input: input,
            output: output,
            shutdownPolicy: shutdownPolicy
        )
    }

    /// Starts input admission exactly once.
    ///
    /// Calling this method again, including after ``stop()``, throws.
    public func start() async throws {
        try await adapter.start()
    }

    /// Returns the current atomic proxy connection snapshot.
    public func connectionState() async -> XcodeMCPConnectionSnapshot {
        await adapter.connectionState()
    }

    /// Waits until EOF-driven or explicit shutdown has completed.
    public func waitUntilStopped() async {
        await adapter.waitUntilStopped()
    }

    /// Stops the adapter and awaits complete resource teardown.
    public func stop() async {
        await adapter.stop()
    }
}

private enum AdapterEndpointResolver {
    private static let endpointEnvironmentVariable = "XCODE_MCP_PROXY_ENDPOINT"
    private static let fallbackURL = URL(string: "http://localhost:8765/mcp")!

    static func resolve(
        _ endpoint: XcodeMCPProxyStdioAdapterConfiguration.Endpoint
    ) throws -> URL {
        switch endpoint {
        case .url(let url):
            return try validate(url, label: "endpoint")
        case .discoveryFile(let fileURL):
            guard let record = Discovery.read(overrideURL: fileURL),
                let url = URL(string: record.url)
            else {
                throw XcodeMCPError.transportUnavailable(
                    "Proxy discovery file is missing or invalid: \(fileURL.path)"
                )
            }
            return try validate(url, label: "proxy discovery endpoint")
        case .proxyDefault(let environment):
            if let raw = nonEmpty(environment[endpointEnvironmentVariable]) {
                guard let url = URL(string: raw) else {
                    throw XcodeMCPError.invalidRequest(
                        "\(endpointEnvironmentVariable) must be an http/https URL"
                    )
                }
                return try validate(url, label: endpointEnvironmentVariable)
            }
            let discoveryFile = Discovery.defaultFileURL(environment: environment)
            if let record = Discovery.read(overrideURL: discoveryFile),
                let url = URL(string: record.url)
            {
                return try validate(url, label: "proxy discovery endpoint")
            }
            return fallbackURL
        }
    }

    private static func validate(_ url: URL, label: String) throws -> URL {
        guard let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw XcodeMCPError.invalidRequest("\(label) must be an http/https URL")
        }
        return url
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            value.isEmpty == false
        else { return nil }
        return value
    }
}

extension XcodeMCPProxyStdioAdapter {
    package protocol LaunchAdapter {
        func start() async throws
        func waitUntilStopped() async
    }

    package struct Launcher {
        package struct Dependencies {
            package var makeAdapter:
                (
                    XcodeMCPProxyStdioAdapterConfiguration,
                    FileHandle,
                    FileHandle
                ) throws -> any LaunchAdapter
            package var input: FileHandle
            package var output: FileHandle

            package init(
                makeAdapter:
                    @escaping (
                        XcodeMCPProxyStdioAdapterConfiguration,
                        FileHandle,
                        FileHandle
                    ) throws -> any LaunchAdapter,
                input: FileHandle,
                output: FileHandle
            ) {
                self.makeAdapter = makeAdapter
                self.input = input
                self.output = output
            }

            package static var live: Self {
                Self(
                    makeAdapter: { configuration, input, output in
                        try XcodeMCPProxyStdioAdapter(
                            configuration: configuration,
                            input: input,
                            output: output
                        )
                    },
                    input: .standardInput,
                    output: .standardOutput
                )
            }
        }

        private let dependencies: Dependencies

        package init(dependencies: Dependencies = .live) {
            self.dependencies = dependencies
        }

        package func run(
            arguments: [String],
            environment: [String: String],
            stdout: @escaping @Sendable (String) -> Void,
            stderr: @escaping @Sendable (String) -> Void
        ) async -> Int32 {
            do {
                let command: ProxyAdapterCommand
                switch try CLICommandParser.parse(ProxyAdapterCommand.self, arguments: arguments) {
                case .cleanExit(let message):
                    stdout(message)
                    return 0
                case .command(let parsedCommand):
                    command = parsedCommand
                }

                let configuration = XcodeMCPProxyStdioAdapterConfiguration(
                    endpoint: command.url.map { .url($0.url) }
                        ?? .proxyDefault(environment: environment),
                    requestTimeout: command.requestTimeout.map { $0.duration }
                        ?? .seconds(300)
                )
                let adapter = try dependencies.makeAdapter(
                    configuration,
                    dependencies.input,
                    dependencies.output
                )
                try await adapter.start()
                await adapter.waitUntilStopped()
                return 0
            } catch let error as CLICommandError {
                stderr(error.description)
                return error.exitCode
            } catch {
                stderr("error: \(error.localizedDescription)")
                return 1
            }
        }
    }
}

extension XcodeMCPProxyStdioAdapter: XcodeMCPProxyStdioAdapter.LaunchAdapter {}
