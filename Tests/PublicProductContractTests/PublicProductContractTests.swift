import Foundation
import Testing

@Suite
struct PublicProductContractTests {
    @Test func publicProductsCompileFromExternalSwiftPMTargets() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = try TemporaryDirectory()
        defer { fixture.cleanup() }

        try makeFixturePackage(at: fixture.url, repositoryRoot: repositoryRoot)

        let result = try runSwiftBuild(
            packageURL: fixture.url,
            logURL: fixture.url.appendingPathComponent("swift-build.log")
        )

        if result.exitCode != 0 {
            Issue.record("swift build failed with exit code \(result.exitCode):\n\(result.output)")
        }
        #expect(result.exitCode == 0)
    }

    private func makeFixturePackage(at packageURL: URL, repositoryRoot: URL) throws {
        try FileManager.default.createDirectory(
            at: packageURL.appendingPathComponent("Sources/XcodeMCPKitClient"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: packageURL.appendingPathComponent("Sources/XcodeMCPProxyKitClient"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: packageURL.appendingPathComponent("Sources/XcodeMCPKitTestingClient"),
            withIntermediateDirectories: true
        )

        try packageManifest(repositoryRoot: repositoryRoot)
            .write(
                to: packageURL.appendingPathComponent("Package.swift"),
                atomically: true,
                encoding: .utf8
            )
        try xcodeMCPKitClientSource
            .write(
                to: packageURL.appendingPathComponent("Sources/XcodeMCPKitClient/Contract.swift"),
                atomically: true,
                encoding: .utf8
            )
        try xcodeMCPProxyKitClientSource
            .write(
                to: packageURL.appendingPathComponent("Sources/XcodeMCPProxyKitClient/Contract.swift"),
                atomically: true,
                encoding: .utf8
            )
        try xcodeMCPKitTestingClientSource
            .write(
                to: packageURL.appendingPathComponent("Sources/XcodeMCPKitTestingClient/Contract.swift"),
                atomically: true,
                encoding: .utf8
            )
    }

    private func packageManifest(repositoryRoot: URL) -> String {
        """
        // swift-tools-version: 6.3
        import PackageDescription

        let package = Package(
            name: "PublicProductContractFixture",
            platforms: [
                .macOS("15.4")
            ],
            dependencies: [
                .package(name: "XcodeMCPKit", path: \(String(reflecting: repositoryRoot.path)))
            ],
            targets: [
                .target(
                    name: "XcodeMCPKitClient",
                    dependencies: [
                        .product(name: "XcodeMCPKit", package: "XcodeMCPKit")
                    ],
                    swiftSettings: [
                        .swiftLanguageMode(.v6),
                        .defaultIsolation(nil),
                    ]
                ),
                .target(
                    name: "XcodeMCPKitTestingClient",
                    dependencies: [
                        .product(name: "XcodeMCPKit", package: "XcodeMCPKit"),
                        .product(name: "XcodeMCPKitTesting", package: "XcodeMCPKit")
                    ],
                    swiftSettings: [
                        .swiftLanguageMode(.v6),
                        .defaultIsolation(nil),
                    ]
                ),
                .target(
                    name: "XcodeMCPProxyKitClient",
                    dependencies: [
                        .product(name: "XcodeMCPProxyKit", package: "XcodeMCPKit")
                    ],
                    swiftSettings: [
                        .swiftLanguageMode(.v6),
                        .defaultIsolation(nil),
                    ]
                ),
            ]
        )
        """
    }

    private func runSwiftBuild(packageURL: URL, logURL: URL) throws -> CommandResult {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: logURL)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift",
            "build",
            "--package-path",
            packageURL.path,
            "--target",
            "XcodeMCPKitClient",
            "--target",
            "XcodeMCPKitTestingClient",
            "--target",
            "XcodeMCPProxyKitClient",
            "-Xswiftc",
            "-strict-concurrency=minimal",
        ]
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            output: (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        )
    }
}

private struct CommandResult {
    let exitCode: Int32
    let output: String
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        self.url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

private let xcodeMCPKitClientSource = """
import Foundation
import XcodeMCPKit

private struct ContractPayload: Encodable {
    var query: String
    var limit: Int
}

func compileOnlyClientDomainSurface() throws {
    let arguments: [String: MCPJSONValue] = [
        "query": "SwiftData",
        "includeBeta": true,
        "limit": 5,
        "score": 0.75,
        "tags": ["swift", "xcode"],
        "metadata": [
            "source": "contract-test",
            "optional": .null,
        ],
    ]

    let config = XcodeMCP.Configuration(
        bridge: .custom(
            command: "/usr/bin/xcrun",
            arguments: ["mcpbridge"],
            environment: ["PUBLIC_CONTRACT": "1"]
        ),
        clientName: "PublicContractClient",
        clientVersion: "1.0",
        capabilities: [
            "experimental": [
                "enabled": true,
            ]
        ],
        requestTimeout: .seconds(1)
    )

    let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
    let httpConfig = XcodeMCP.Configuration(
        transport: .streamableHTTP(endpoint: endpoint),
        clientName: "PublicHTTPContractClient",
        clientVersion: "1.0",
        requestTimeout: .seconds(1)
    )
    let discoveryConfig = XcodeMCP.Configuration(
        transport: .streamableHTTP(discoveryFile: URL(fileURLWithPath: "/tmp/xcode-mcp/endpoint.json"))
    )

    let metadata = arguments["metadata"]?.objectValue
    let tags = arguments["tags"]?.arrayValue?.compactMap { $0.stringValue }
    let query = arguments["query"]?.stringValue
    let includeBeta = arguments["includeBeta"]?.boolValue
    let limit = arguments["limit"]?.intValue
    let integerLimit = arguments["limit"]?.integerValue
    let score = arguments["score"]?.doubleValue
    let optionalIsNull = metadata?["optional"]?.isNull
    let jsonFromObject = try MCPJSONValue(jsonObject: [
        "query": "NavigationStack",
        "limit": 3,
        "optional": NSNull(),
    ])
    let jsonFromEncodable = try MCPJSONValue(encoding: ContractPayload(
        query: "Observation",
        limit: 2
    ))
    let foundationObject = jsonFromObject.jsonObject

    let tool = MCPTool(
        name: "DocumentationSearch",
        description: "Search Apple documentation",
        inputSchema: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                ],
            ],
        ]
    )

    let text = MCPContent.text(
        "Result text",
        raw: [
            "type": "text",
            "text": "Result text",
        ]
    )
    let image = MCPContent.image(
        data: "AAAA",
        mimeType: "image/png",
        raw: [
            "type": "image",
            "data": "AAAA",
            "mimeType": "image/png",
        ]
    )
    let resource = MCPContent.resource(
        uri: "file:///tmp/result.txt",
        text: "Result body",
        mimeType: "text/plain",
        raw: [
            "type": "resource",
            "uri": "file:///tmp/result.txt",
            "text": "Result body",
            "mimeType": "text/plain",
        ]
    )
    let result = MCPToolResult(
        content: [text, image, resource, .raw(["type": "custom"])],
        structuredContent: [
            "matches": 1,
            "tool": "DocumentationSearch",
        ],
        isError: false
    )
    let progress = MCPProgress(
        progressToken: "token-1",
        progress: 0.5,
        total: 1.0,
        message: "Halfway"
    )
    let errors: [XcodeMCPError] = [
        .closed,
        .invalidRequest("missing tool name"),
        .invalidResponse("missing result"),
        .requestTimedOut(method: "tools/list"),
        .serverError(code: -32000, message: "upstream unavailable", data: ["reason": "disabled"]),
        .transportUnavailable("mcpbridge closed"),
    ]

    _ = (
        arguments,
        config,
        httpConfig,
        discoveryConfig,
        tags,
        query,
        includeBeta,
        limit,
        integerLimit,
        score,
        optionalIsNull,
        jsonFromObject,
        jsonFromEncodable,
        foundationObject,
        tool,
        result,
        progress,
        errors
    )
}

func compileOnlyClientLifecycleSurface(config: XcodeMCP.Configuration) async throws {
    let client = try await XcodeMCP(config: config)
    _ = try await client.listTools()
    _ = try await client.callTool(
        "DocumentationSearch",
        arguments: [
            "query": "NavigationStack",
        ]
    ) { progress in
        _ = progress.message
    }
    _ = try await client.request(
        "workspace/symbols",
        params: [
            "query": "NavigationStack",
        ]
    )
    try await client.notify(
        "notifications/custom",
        params: [
            "enabled": true,
        ]
    )
    await client.close()
}
"""

private let xcodeMCPKitTestingClientSource = """
import XcodeMCPKit
import XcodeMCPKitTesting

func compileOnlyTestingRuntimeSurface() async throws {
    let runtime = XcodeMCPTestRuntime()
    await runtime.setTools([
        MCPTool(
            name: "DocumentationSearch",
            description: "Search docs",
            inputSchema: [
                "type": "object",
            ]
        )
    ])
    await runtime.setProgressUpdates(
        [
            .init(progress: 0.5, total: 1, message: "Halfway"),
        ],
        forToolNamed: "DocumentationSearch"
    )
    await runtime.setToolResult(
        MCPToolResult(
            content: [
                .text(
                    "Result text",
                    raw: [
                        "type": "text",
                        "text": "Result text",
                    ]
                )
            ],
            structuredContent: [
                "matches": 1,
            ]
        ),
        forToolNamed: "DocumentationSearch"
    )

    let client = try await runtime.makeClient()
    _ = try await client.listTools()
    _ = try await client.callTool(
        "DocumentationSearch",
        arguments: [
            "query": "NavigationStack",
        ]
    ) { progress in
        _ = progress.message
    }
    let messages = await runtime.recordedMessages()
    await client.close()

    _ = messages
}
"""

private let xcodeMCPProxyKitClientSource = """
import Foundation
import XcodeMCPProxyKit

func compileOnlyProxyConfigurationSurface() {
    let config = XcodeMCPProxyServer.Configuration(
        bind: .init(host: "127.0.0.1", port: 0),
        upstream: .custom(
            command: "/usr/bin/xcrun",
            arguments: ["mcpbridge"],
            processesPerXcode: 1,
            sessionID: "session-1"
        ),
        limits: .init(maxBodyBytes: 1_048_576, requestTimeout: 120),
        configurationFilePath: "/tmp/xcode-mcp-config.toml",
        discovery: .init(fileURL: URL(fileURLWithPath: "/tmp/xcode-mcp-discovery.json")),
        approval: .manual,
        features: .init(
            prewarmToolsList: false,
            refreshCodeIssuesMode: .proxy
        )
    )

    let upstreamMode = XcodeMCPProxyServer.Configuration.RefreshCodeIssuesMode.upstream
    let server = XcodeMCPProxyServer(config: config)
    let endpointConfig = XcodeMCPProxyAdapterEndpointResolver.Configuration(
        explicitURL: "http://localhost:8765/mcp",
        environment: [:]
    )
    let endpoint = try? XcodeMCPProxyAdapterEndpointResolver().resolve(endpointConfig)
    let adapterConfig = XcodeMCPProxyStdioAdapter.Configuration(
        endpoint: endpointConfig,
        requestTimeout: 30
    )
    let installer = XcodeMCPProxyInstaller(
        configuration: .init(prefix: "/tmp/xcode-mcp", bindir: nil, dryRun: true)
    )
    let plan = installer.plan(
        executableURL: URL(fileURLWithPath: "/tmp/repo/.build/release/xcode-mcp-proxy-install")
    )
    let adapter = endpoint.map {
        XcodeMCPProxyStdioAdapter(endpoint: $0, requestTimeout: 30)
    }

    _ = (config, upstreamMode, server, adapterConfig, endpoint, adapter, plan)
    _ = XcodeMCPProxyInstaller.binaryNames
}

func compileOnlyProxyLaunchSurface() throws {
    let plan = try XcodeMCPProxyServer.resolveLaunchPlan(
        arguments: [
            "xcode-mcp-proxy-server",
            "--listen", "127.0.0.1:0",
            "--dry-run",
        ],
        environment: [
            "MCP_XCODE_REFRESH_CODE_ISSUES_MODE": "upstream",
        ]
    )
    let metadata = XcodeMCPProxyServer.productMetadata
    let versionLine = metadata.versionLine(
        arguments: ["/usr/local/bin/xcode-mcp-proxy-server"],
        defaultExecutableName: "xcode-mcp-proxy-server"
    )
    let portError = XcodeMCPProxyServer.PortInUseError(
        host: "localhost",
        port: 8765,
        processIdentifiers: [123]
    )
    let adapterPlan = try XcodeMCPProxyStdioAdapter.resolveLaunchPlan(
        arguments: [
            "xcode-mcp-proxy",
            "--url", "http://localhost:8765/mcp",
            "--request-timeout", "12",
        ],
        environment: [:]
    )
    let rewrittenAdapterArgs = try XcodeMCPProxyStdioAdapter.rewriteURLFlagToStdio([
        "xcode-mcp-proxy",
        "--url=http://localhost:8765/mcp",
    ])
    let installPlan = try XcodeMCPProxyInstaller.resolveLaunchPlan(
        arguments: [
            "xcode-mcp-proxy-install",
            "--prefix", "/tmp/xcode-mcp",
            "--dry-run",
        ],
        environment: [:]
    )

    _ = (
        plan.action,
        plan.configuration,
        plan.options.dryRun,
        plan.options.forceRestart,
        plan.resolvedDryRunCommandLine,
        plan.usage,
        plan.versionLine,
        metadata.name,
        metadata.version,
        versionLine,
        portError.description,
        adapterPlan.action,
        adapterPlan.configuration,
        adapterPlan.endpoint,
        adapterPlan.options.requestTimeout,
        adapterPlan.usage,
        adapterPlan.versionLine,
        rewrittenAdapterArgs,
        installPlan.action,
        installPlan.configuration,
        installPlan.options.executableName,
        installPlan.usage,
        installPlan.versionLine
    )
}

func compileOnlyProxyLifecycleSurface(server: XcodeMCPProxyServer) async throws {
    let address = try server.start()
    let discoveryAddress = try server.startAndWriteDiscovery()
    try await server.wait()
    try await server.shutdown()

    _ = (address.host, address.port, discoveryAddress.host, discoveryAddress.port)
    _ = (address.url, discoveryAddress.url)
}
"""
