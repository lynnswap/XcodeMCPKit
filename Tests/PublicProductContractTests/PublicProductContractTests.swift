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

func compileOnlyClientDomainSurface() {
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
        command: "/usr/bin/xcrun",
        arguments: ["mcpbridge"],
        environment: ["PUBLIC_CONTRACT": "1"],
        clientName: "PublicContractClient",
        clientVersion: "1.0",
        capabilities: [
            "experimental": [
                "enabled": true,
            ]
        ],
        requestTimeout: .seconds(1),
        maxQueuedWriteBytes: 65_536
    )

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

    _ = (arguments, config, tool, result, progress, errors)
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
    await client.close()
}
"""

private let xcodeMCPProxyKitClientSource = """
import Foundation
import XcodeMCPProxyKit

func compileOnlyProxyConfigurationSurface() {
    let config = XcodeMCPProxyServer.Configuration(
        listenHost: "127.0.0.1",
        listenPort: 0,
        upstreamCommand: "/usr/bin/xcrun",
        upstreamArguments: ["mcpbridge"],
        upstreamProcessCount: 1,
        upstreamSessionID: "session-1",
        maxBodyBytes: 1_048_576,
        requestTimeout: 120,
        configPath: "/tmp/xcode-mcp-config.toml",
        discoveryFileURL: URL(fileURLWithPath: "/tmp/xcode-mcp-discovery.json"),
        prewarmToolsList: false,
        autoApproveXcodeDialog: false,
        refreshCodeIssuesMode: .proxy
    )

    let upstreamMode = XcodeMCPProxyServer.Configuration.RefreshCodeIssuesMode.upstream
    let server = XcodeMCPProxyServer(config: config)

    _ = (config, upstreamMode, server)
}

func compileOnlyProxyLifecycleSurface(server: XcodeMCPProxyServer) async throws {
    let address = try server.start()
    let discoveryAddress = try server.startAndWriteDiscovery()
    try await server.wait()
    try await server.shutdown()

    _ = (address.host, address.port, discoveryAddress.host, discoveryAddress.port)
}
"""
