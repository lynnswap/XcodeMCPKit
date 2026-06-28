import Darwin
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
        expectBuildSucceeded(result, context: "public product fixture build")

        for check in lowLevelImportChecks {
            let result = try runSwiftBuild(
                packageURL: fixture.url,
                logURL: fixture.url.appendingPathComponent("\(check.targetName)-swift-build.log"),
                targets: [check.targetName]
            )
            expectBuildFailedBecauseModuleIsUnavailable(
                result,
                targetName: check.targetName,
                moduleName: check.moduleName
            )
        }

        let leakedHelperResult = try runSwiftBuild(
            packageURL: fixture.url,
            logURL: fixture.url.appendingPathComponent("\(runtimeHelperLeakCheck.targetName)-swift-build.log"),
            targets: [runtimeHelperLeakCheck.targetName]
        )
        expectBuildFailed(
            leakedHelperResult,
            targetName: runtimeHelperLeakCheck.targetName,
            expectedFragments: runtimeHelperLeakCheck.expectedFragments
        )
    }

    private func makeFixturePackage(at packageURL: URL, repositoryRoot: URL) throws {
        let fixtureTargets = [
            "XcodeMCPKitClient",
            "XcodeMCPProxyKitClient",
            "XcodeMCPProxyKitOnlyClient",
            "XcodeMCPKitTestingClient",
        ] + lowLevelImportChecks.map(\.targetName) + [
            runtimeHelperLeakCheck.targetName
        ]

        for target in fixtureTargets {
            try FileManager.default.createDirectory(
                at: packageURL.appendingPathComponent("Sources/\(target)"),
                withIntermediateDirectories: true
            )
        }

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
        try xcodeMCPProxyKitOnlyClientSource
            .write(
                to: packageURL.appendingPathComponent("Sources/XcodeMCPProxyKitOnlyClient/Contract.swift"),
                atomically: true,
                encoding: .utf8
            )
        try xcodeMCPKitTestingClientSource
            .write(
                to: packageURL.appendingPathComponent("Sources/XcodeMCPKitTestingClient/Contract.swift"),
                atomically: true,
                encoding: .utf8
            )
        for check in lowLevelImportChecks {
            try lowLevelImportClientSource(moduleName: check.moduleName)
                .write(
                    to: packageURL.appendingPathComponent("Sources/\(check.targetName)/Contract.swift"),
                    atomically: true,
                    encoding: .utf8
                )
        }
        try runtimeHelperLeakClientSource
            .write(
                to: packageURL.appendingPathComponent("Sources/\(runtimeHelperLeakCheck.targetName)/Contract.swift"),
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
                        .product(name: "XcodeMCPKit", package: "XcodeMCPKit"),
                        .product(name: "XcodeMCPProxyKit", package: "XcodeMCPKit")
                    ],
                    swiftSettings: [
                        .swiftLanguageMode(.v6),
                        .defaultIsolation(nil),
                    ]
                ),
                .target(
                    name: "XcodeMCPProxyKitOnlyClient",
                    dependencies: [
                        .product(name: "XcodeMCPProxyKit", package: "XcodeMCPKit")
                    ],
                    swiftSettings: [
                        .swiftLanguageMode(.v6),
                        .defaultIsolation(nil),
                    ]
                ),
                .target(
                    name: "XcodeMCPKitClientImportsCore",
                    dependencies: [
                        .product(name: "XcodeMCPKit", package: "XcodeMCPKit")
                    ],
                    swiftSettings: [
                        .swiftLanguageMode(.v6),
                        .defaultIsolation(nil),
                    ]
                ),
                .target(
                    name: "XcodeMCPKitClientImportsProcessRuntime",
                    dependencies: [
                        .product(name: "XcodeMCPKit", package: "XcodeMCPKit")
                    ],
                    swiftSettings: [
                        .swiftLanguageMode(.v6),
                        .defaultIsolation(nil),
                    ]
                ),
                .target(
                    name: "XcodeMCPProxyKitClientImportsCore",
                    dependencies: [
                        .product(name: "XcodeMCPProxyKit", package: "XcodeMCPKit")
                    ],
                    swiftSettings: [
                        .swiftLanguageMode(.v6),
                        .defaultIsolation(nil),
                    ]
                ),
                .target(
                    name: "XcodeMCPProxyKitClientImportsProcessRuntime",
                    dependencies: [
                        .product(name: "XcodeMCPProxyKit", package: "XcodeMCPKit")
                    ],
                    swiftSettings: [
                        .swiftLanguageMode(.v6),
                        .defaultIsolation(nil),
                    ]
                ),
                .target(
                    name: "XcodeMCPKitClientUsesProtocolHelper",
                    dependencies: [
                        .product(name: "XcodeMCPKit", package: "XcodeMCPKit")
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

    private func runSwiftBuild(
        packageURL: URL,
        logURL: URL,
        targets: [String] = [
            "XcodeMCPKitClient",
            "XcodeMCPKitTestingClient",
            "XcodeMCPProxyKitClient",
            "XcodeMCPProxyKitOnlyClient",
        ],
        timeoutSeconds: TimeInterval = 180
    ) throws -> CommandResult {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: logURL)
        var outputClosed = false
        func closeOutput() {
            guard !outputClosed else {
                return
            }
            outputClosed = true
            try? output.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift",
            "build",
            "--package-path",
            packageURL.path,
        ] + targets.flatMap { ["--target", $0] } + [
            "-Xswiftc",
            "-strict-concurrency=minimal",
        ]
        process.standardOutput = output
        process.standardError = output

        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }

        try process.run()
        let timedOut = exitSemaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut
        if timedOut {
            terminate(process, exitSemaphore: exitSemaphore)
        }
        closeOutput()
        let exitCode: Int32 = process.isRunning ? -1 : process.terminationStatus

        return CommandResult(
            exitCode: exitCode,
            output: (try? String(contentsOf: logURL, encoding: .utf8)) ?? "",
            timedOut: timedOut,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func expectBuildSucceeded(_ result: CommandResult, context: String) {
        if result.timedOut {
            Issue.record(
                """
                \(context) timed out after \(Int(result.timeoutSeconds)) seconds:
                \(result.output)
                """
            )
            #expect(!result.timedOut)
            return
        }

        if result.exitCode != 0 {
            Issue.record("\(context) failed with exit code \(result.exitCode):\n\(result.output)")
        }
        #expect(result.exitCode == 0)
    }

    private func expectBuildFailedBecauseModuleIsUnavailable(
        _ result: CommandResult,
        targetName: String,
        moduleName: String
    ) {
        if result.timedOut {
            Issue.record(
                """
                \(targetName) timed out after \(Int(result.timeoutSeconds)) seconds:
                \(result.output)
                """
            )
            #expect(!result.timedOut)
            return
        }

        if result.exitCode == 0 {
            Issue.record("\(targetName) unexpectedly imported \(moduleName)")
        }
        #expect(result.exitCode != 0)

        let expectedFragments = [
            "no such module '\(moduleName)'",
            "no such module \"\(moduleName)\"",
            "no such module: \(moduleName)",
        ]
        let reportedMissingModule = expectedFragments.contains { result.output.contains($0) }
        if !reportedMissingModule {
            Issue.record(
                """
                \(targetName) failed for an unexpected reason while importing \(moduleName):
                \(result.output)
                """
            )
        }
        #expect(reportedMissingModule)
    }

    private func expectBuildFailed(
        _ result: CommandResult,
        targetName: String,
        expectedFragments: [String]
    ) {
        if result.timedOut {
            Issue.record(
                """
                \(targetName) timed out after \(Int(result.timeoutSeconds)) seconds:
                \(result.output)
                """
            )
            #expect(!result.timedOut)
            return
        }

        if result.exitCode == 0 {
            Issue.record("\(targetName) unexpectedly compiled")
        }
        #expect(result.exitCode != 0)

        let reportedExpectedFailure = expectedFragments.contains { result.output.contains($0) }
        if !reportedExpectedFailure {
            Issue.record(
                """
                \(targetName) failed for an unexpected reason:
                \(result.output)
                """
            )
        }
        #expect(reportedExpectedFailure)
    }

    private func terminate(_ process: Process, exitSemaphore: DispatchSemaphore) {
        guard process.isRunning else {
            return
        }

        process.terminate()
        if exitSemaphore.wait(timeout: .now() + 5) == .success {
            return
        }

        kill(process.processIdentifier, SIGKILL)
        _ = exitSemaphore.wait(timeout: .now() + 5)
    }
}

private let lowLevelImportChecks: [(targetName: String, moduleName: String)] = [
    ("XcodeMCPKitClientImportsCore", "XcodeMCPCore"),
    ("XcodeMCPKitClientImportsProcessRuntime", "XcodeMCPProcessRuntime"),
    ("XcodeMCPProxyKitClientImportsCore", "XcodeMCPCore"),
    ("XcodeMCPProxyKitClientImportsProcessRuntime", "XcodeMCPProcessRuntime"),
]

private let runtimeHelperLeakCheck = (
    targetName: "XcodeMCPKitClientUsesProtocolHelper",
    expectedFragments: [
        "cannot find 'MCP' in scope",
        "'MCP' is inaccessible",
        "inaccessible due to 'package' protection level",
    ]
)

private struct CommandResult {
    let exitCode: Int32
    let output: String
    let timedOut: Bool
    let timeoutSeconds: TimeInterval
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
        bridge: .defaultMCPBridge,
        clientName: "PublicContractClient",
        clientVersion: "1.0",
        capabilities: [
            "experimental": [
                "enabled": true,
            ]
        ],
        requestTimeout: .seconds(1)
    )
    let customBridgeConfig = XcodeMCP.Configuration(
        bridge: .custom(
            command: "/usr/bin/env",
            arguments: ["printf"],
            environment: ["PUBLIC_CONTRACT": "1"]
        )
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
    let proxyDiscoveryConfig = XcodeMCP.Configuration(
        transport: .streamableHTTPProxyDiscovery(
            environment: [
                "XCODE_MCP_PROXY_DISCOVERY_FILE": "/tmp/xcode-mcp/proxy-endpoint.json",
            ]
        )
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
        customBridgeConfig,
        httpConfig,
        discoveryConfig,
        proxyDiscoveryConfig,
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

private let xcodeMCPProxyKitOnlyClientSource = """
import XcodeMCPProxyKit

func compileOnlyProxyProductOnlySurface() {
    let config = XcodeMCPProxyServer.Configuration()
    let server = XcodeMCPProxyServer(config: config)
    let installer = XcodeMCPProxyInstaller()

    _ = (
        config,
        server,
        installer,
        XcodeMCPProxyInstaller.binaryNames
    )
}
"""

private let xcodeMCPProxyKitClientSource = """
import Foundation
import XcodeMCPKit
import XcodeMCPProxyKit

func compileOnlyProxyConfigurationSurface() {
    let config = XcodeMCPProxyServer.Configuration(
        bind: .init(host: "127.0.0.1", port: 0),
        upstream: .defaultMCPBridge(
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
        ),
        toolPolicy: .init(
            disabledToolNames: ["RunAllTests", "RunSomeTests"]
        ),
        initializeHandshake: .init(
            protocolVersion: "2025-06-18",
            clientInfo: .init(name: "EmbeddingClient", version: "1.0"),
            capabilities: [
                "roots": [
                    "listChanged": true,
                ],
                "experimental": [
                    "priority": 1,
                    "score": 0.5,
                    "metadata": .null,
                ],
            ]
        )
    )
    let customUpstreamConfig = XcodeMCPProxyServer.Configuration(
        upstream: .custom(
            command: "/usr/bin/env",
            arguments: ["printf"],
            processesPerXcode: 1,
            sessionID: "session-1"
        )
    )

    let typedToolPolicy = config.toolPolicy
    let typedHandshake = config.initializeHandshake
    let typedCapabilities: [String: MCPJSONValue]? = typedHandshake?.capabilities
    let metadataIsNull = typedCapabilities?["experimental"]?.objectValue?["metadata"]?.isNull
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

    _ = (
        config,
        customUpstreamConfig,
        typedToolPolicy,
        typedHandshake,
        typedCapabilities,
        metadataIsNull,
        upstreamMode,
        server,
        adapterConfig,
        endpoint,
        adapter,
        plan
    )
    _ = XcodeMCPProxyInstaller.binaryNames
}

func compileOnlyProxyLaunchSurface() async throws {
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
    let runnerStdout: @Sendable (String) -> Void = { _ in }
    let runnerStderr: @Sendable (String) -> Void = { _ in }
    let serverExitCode = await XcodeMCPProxyServer.run(
        arguments: [
            "xcode-mcp-proxy-server",
            "--version",
        ],
        environment: [:],
        stdout: runnerStdout,
        stderr: runnerStderr
    )
    let adapterExitCode = await XcodeMCPProxyStdioAdapter.run(
        arguments: [
            "xcode-mcp-proxy",
            "--version",
        ],
        environment: [:],
        stdout: runnerStdout,
        stderr: runnerStderr
    )
    let installerExitCode = XcodeMCPProxyInstaller.run(
        arguments: [
            "xcode-mcp-proxy-install",
            "--version",
        ],
        environment: [:],
        stdout: runnerStdout,
        stderr: runnerStderr
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
        installPlan.versionLine,
        serverExitCode,
        adapterExitCode,
        installerExitCode
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

private func lowLevelImportClientSource(moduleName: String) -> String {
    """
    import \(moduleName)

    func compileOnlyLowLevelModuleShouldNotBeVisible() {}
    """
}

private let runtimeHelperLeakClientSource = """
import XcodeMCPKit

func compileOnlyRuntimeProtocolHelperShouldNotBeVisible() {
    _ = MCP.ProtocolVersion.current
}
"""
