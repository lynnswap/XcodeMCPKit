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
                  let url = URL(string: record.url) else {
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
               let url = URL(string: record.url) {
                return try validate(url, label: "proxy discovery endpoint")
            }
            return fallbackURL
        }
    }

    private static func validate(_ url: URL, label: String) throws -> URL {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw XcodeMCPError.invalidRequest("\(label) must be an http/https URL")
        }
        return url
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else { return nil }
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
            package var makeAdapter: (
                XcodeMCPProxyStdioAdapterConfiguration,
                FileHandle,
                FileHandle
            ) throws -> any LaunchAdapter
            package var input: FileHandle
            package var output: FileHandle

            package init(
                makeAdapter: @escaping (
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

        private enum Action {
            case showHelp(String)
            case showVersion(String)
            case start(XcodeMCPProxyStdioAdapterConfiguration)
        }

        private struct LaunchError: Error, CustomStringConvertible {
            enum Presentation {
                case plain
                case usage
                case serverOnlyFlagHint
            }

            let description: String
            let presentation: Presentation
        }

        private static let serverOnlyFlags: Set<String> = [
            "--config", "--auto-approve", "--listen", "--host", "--port",
            "--max-body-bytes", "--upstream-command", "--upstream-args",
            "--upstream-arg", "--upstream-processes", "--session-id",
            "--refresh-code-issues-mode",
        ]

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
                switch try parseAction(arguments: arguments, environment: environment) {
                case .showHelp(let usage):
                    stdout(usage)
                    return 0
                case .showVersion(let version):
                    stdout(version)
                    return 0
                case .start(let configuration):
                    let adapter = try dependencies.makeAdapter(
                        configuration,
                        dependencies.input,
                        dependencies.output
                    )
                    try await adapter.start()
                    await adapter.waitUntilStopped()
                    return 0
                }
            } catch let error as LaunchError {
                stderr(error.description)
                switch error.presentation {
                case .plain:
                    break
                case .usage:
                    stderr(Self.usage(environment: environment))
                case .serverOnlyFlagHint:
                    stderr("Run: xcode-mcp-proxy-server --help")
                }
                return 1
            } catch {
                stderr("error: \(error.localizedDescription)")
                return 1
            }
        }

        private func parseAction(
            arguments: [String],
            environment: [String: String]
        ) throws -> Action {
            let executable = executableName(arguments)
            let usage = Self.usage(environment: environment)
            let values = Array(arguments.dropFirst())
            if values.contains("-h") || values.contains("--help") {
                return .showHelp(usage)
            }
            if values.contains("--version") {
                return .showVersion(
                    XcodeMCPProxyServer.productMetadata.versionLine(
                        arguments: arguments,
                        defaultExecutableName: executable
                    )
                )
            }

            var endpoint: XcodeMCPProxyStdioAdapterConfiguration.Endpoint =
                .proxyDefault(environment: environment)
            var requestTimeout: Duration? = .seconds(300)
            var didReadURL = false
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--request-timeout":
                    guard index + 1 < arguments.count else {
                        throw LaunchError(
                            description: "--request-timeout requires seconds",
                            presentation: .usage
                        )
                    }
                    requestTimeout = try Self.requestTimeout(arguments[index + 1])
                    index += 2
                case "--url":
                    guard didReadURL == false else {
                        throw LaunchError(
                            description: "--url may only be specified once.",
                            presentation: .usage
                        )
                    }
                    guard index + 1 < arguments.count,
                          arguments[index + 1].hasPrefix("-") == false else {
                        throw LaunchError(
                            description: "--url requires a value (http/https URL).",
                            presentation: .usage
                        )
                    }
                    endpoint = .url(try Self.url(arguments[index + 1], label: "--url"))
                    didReadURL = true
                    index += 2
                case let value where value.hasPrefix("--url="):
                    guard didReadURL == false else {
                        throw LaunchError(
                            description: "--url may only be specified once.",
                            presentation: .usage
                        )
                    }
                    let raw = String(value.dropFirst("--url=".count))
                    guard raw.isEmpty == false else {
                        throw LaunchError(
                            description: "--url requires a value (http/https URL).",
                            presentation: .usage
                        )
                    }
                    endpoint = .url(try Self.url(raw, label: "--url"))
                    didReadURL = true
                    index += 1
                case "url", "--print-url":
                    throw LaunchError(
                        description: "url helper mode was removed; configure your HTTP client with a concrete URL.",
                        presentation: .plain
                    )
                case "--lazy-init":
                    throw LaunchError(
                        description: XcodeMCPProxyServer.removedLazyInitializationMessage,
                        presentation: .plain
                    )
                case "--xcode-pid":
                    throw LaunchError(
                        description: XcodeMCPProxyServer.removedXcodePIDMessage,
                        presentation: .plain
                    )
                case let flag where Self.serverOnlyFlags.contains(flag):
                    throw LaunchError(
                        description: "This option is only supported by xcode-mcp-proxy-server (proxy server).",
                        presentation: .serverOnlyFlagHint
                    )
                default:
                    throw LaunchError(
                        description: "Unknown argument: \(argument)",
                        presentation: .usage
                    )
                }
            }
            return .start(.init(endpoint: endpoint, requestTimeout: requestTimeout))
        }

        private static func requestTimeout(_ raw: String) throws -> Duration? {
            guard let seconds = Double(raw), seconds.isFinite, seconds >= 0 else {
                throw LaunchError(
                    description: "--request-timeout must be a finite number greater than or equal to zero",
                    presentation: .usage
                )
            }
            guard seconds > 0 else { return nil }
            let nanoseconds = (seconds * 1_000_000_000).rounded(.up)
            guard nanoseconds <= Double(Int64.max) else {
                throw LaunchError(
                    description: "--request-timeout is too large",
                    presentation: .usage
                )
            }
            return .nanoseconds(Int64(nanoseconds))
        }

        private static func url(_ raw: String, label: String) throws -> URL {
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                throw LaunchError(
                    description: "\(label) must be an http/https URL",
                    presentation: .usage
                )
            }
            return url
        }

        private static func usage(environment: [String: String]) -> String {
            let discoveryFile = Discovery.defaultFileURL(environment: environment)
            return """
                Usage:
                  xcode-mcp-proxy [options]

                Description:
                  STDIO compatibility adapter that forwards MCP traffic to a running xcode-mcp-proxy-server (Streamable HTTP).

                Options:
                  --request-timeout seconds  Request timeout (default: 300, 0 disables)
                  --url url                  Explicit upstream URL (default: env/discovery/http://localhost:8765/mcp)
                  --version                  Show version
                  -h, --help                 Show help

                Environment:
                  XCODE_MCP_PROXY_ENDPOINT   Upstream proxy URL (overrides discovery)

                Notes:
                  - Proxy server: xcode-mcp-proxy-server
                  - --config is only supported by xcode-mcp-proxy-server
                  - Discovery file: \(discoveryFile.path)
                """
        }

        private func executableName(_ arguments: [String]) -> String {
            guard let raw = arguments.first, raw.isEmpty == false else {
                return "xcode-mcp-proxy"
            }
            let name = URL(fileURLWithPath: raw).lastPathComponent
            return name.isEmpty ? "xcode-mcp-proxy" : name
        }
    }
}

extension XcodeMCPProxyStdioAdapter: XcodeMCPProxyStdioAdapter.LaunchAdapter {}
