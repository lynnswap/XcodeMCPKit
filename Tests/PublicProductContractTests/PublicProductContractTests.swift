// swift-format-ignore-file

import Darwin
import Foundation
import Testing
import XcodeMCPCoreTestSupport

@Suite
struct PublicProductContractTests {
    @Test func publicProductsCompileFromExternalSwiftPMTargets() async throws {
        // Avoid false 5s STDIO adapter timeouts while this test runs nested swift build processes.
        try await TestResourceGate.withProcessHeavyStdioAdapterAccess {
            try await runPublicProductsCompileFromExternalSwiftPMTargets()
        }
    }

    private func runPublicProductsCompileFromExternalSwiftPMTargets() async throws {
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

        for check in removedSurfaceChecks {
            let result = try runSwiftBuild(
                packageURL: fixture.url,
                logURL: fixture.url.appendingPathComponent("\(check.targetName)-swift-build.log"),
                targets: [check.targetName]
            )
            expectBuildFailed(
                result,
                targetName: check.targetName,
                expectedFragments: check.expectedFragments
            )
        }
    }

    private func makeFixturePackage(at packageURL: URL, repositoryRoot: URL) throws {
        let fixtureTargets = [
            "XcodeMCPKitClient",
            "XcodeMCPProxyKitClient",
            "XcodeMCPProxyKitOnlyClient",
            "XcodeMCPKitTestingClient",
        ] + lowLevelImportChecks.map(\.targetName)
            + removedSurfaceChecks.map(\.targetName)

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
        for check in removedSurfaceChecks {
            try check.source.write(
                to: packageURL.appendingPathComponent("Sources/\(check.targetName)/Contract.swift"),
                atomically: true,
                encoding: .utf8
            )
        }
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
                    name: "XcodeMCPProxyKitClientImportsTestSupport",
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
                .target(
                    name: "XcodeMCPKitClientUsesRemovedNotify",
                    dependencies: [
                        .product(name: "XcodeMCPKit", package: "XcodeMCPKit")
                    ],
                    swiftSettings: [
                        .swiftLanguageMode(.v6),
                        .defaultIsolation(nil),
                    ]
                ),
                .target(
                    name: "XcodeMCPKitClientUsesSnapshotInitializer",
                    dependencies: [
                        .product(name: "XcodeMCPKit", package: "XcodeMCPKit")
                    ],
                    swiftSettings: [
                        .swiftLanguageMode(.v6),
                        .defaultIsolation(nil),
                    ]
                ),
                .target(
                    name: "XcodeMCPProxyKitClientUsesRemovedAdapterEndpointFamily",
                    dependencies: [
                        .product(name: "XcodeMCPProxyKit", package: "XcodeMCPKit")
                    ],
                    swiftSettings: [
                        .swiftLanguageMode(.v6),
                        .defaultIsolation(nil),
                    ]
                ),
                .target(
                    name: "XcodeMCPProxyKitClientUsesRemovedAdapterLaunchPlanFamily",
                    dependencies: [
                        .product(name: "XcodeMCPProxyKit", package: "XcodeMCPKit")
                    ],
                    swiftSettings: [
                        .swiftLanguageMode(.v6),
                        .defaultIsolation(nil),
                    ]
                ),
                .target(
                    name: "XcodeMCPProxyKitClientUsesRemovedServerSurface",
                    dependencies: [
                        .product(name: "XcodeMCPProxyKit", package: "XcodeMCPKit")
                    ],
                    swiftSettings: [
                        .swiftLanguageMode(.v6),
                        .defaultIsolation(nil),
                    ]
                ),
                .target(
                    name: "XcodeMCPProxyKitClientUsesRemovedInstallerSurface",
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
        let outputFD = unsafe open(logURL.path, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard outputFD >= 0 else {
            throw POSIXCommandError(operation: "open \(logURL.path)", code: errno)
        }
        defer {
            close(outputFD)
        }

        let targetDescription = targets.joined(separator: ", ")
        let process = try SpawnedProcessGroup.spawn(
            executable: "/usr/bin/env",
            arguments: [
                "env",
                "swift",
                "build",
                "--package-path",
                packageURL.path,
            ] + targets.flatMap { ["--target", $0] } + [
                "-Xswiftc",
                "-strict-concurrency=minimal",
            ],
            outputFD: outputFD
        )
        let waitResult = process.wait(
            timeoutSeconds: timeoutSeconds,
            heartbeatInterval: 30
        ) { elapsedSeconds in
            print(
                "PublicProductContractTests: swift build still running after \(Int(elapsedSeconds))s "
                    + "for \(targetDescription); log: \(logURL.path)"
            )
            unsafe fflush(stdout)
        }

        return CommandResult(
            exitCode: waitResult.exitCode,
            output: (try? String(contentsOf: logURL, encoding: .utf8)) ?? "",
            timedOut: waitResult.timedOut,
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

}

private final class SpawnedProcessGroup: @unchecked Sendable {
    private let pid: pid_t
    private let exitSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var waitStatus: Int32?

    private init(pid: pid_t) {
        self.pid = pid
        DispatchQueue.global(qos: .utility).async {
            self.reap()
        }
    }

    static func spawn(
        executable: String,
        arguments: [String],
        outputFD: CInt
    ) throws -> SpawnedProcessGroup {
        let pid = try unsafe spawnPOSIX(executable: executable, arguments: arguments, outputFD: outputFD)
        return SpawnedProcessGroup(pid: pid)
    }

    @unsafe private static func spawnPOSIX(
        executable: String,
        arguments: [String],
        outputFD: CInt
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?

        try checkPOSIX(
            unsafe posix_spawn_file_actions_init(&fileActions),
            operation: "posix_spawn_file_actions_init"
        )
        defer {
            unsafe posix_spawn_file_actions_destroy(&fileActions)
        }

        try checkPOSIX(
            unsafe posix_spawn_file_actions_adddup2(&fileActions, outputFD, STDOUT_FILENO),
            operation: "posix_spawn_file_actions_adddup2 stdout"
        )
        try checkPOSIX(
            unsafe posix_spawn_file_actions_adddup2(&fileActions, outputFD, STDERR_FILENO),
            operation: "posix_spawn_file_actions_adddup2 stderr"
        )

        try checkPOSIX(unsafe posix_spawnattr_init(&attr), operation: "posix_spawnattr_init")
        defer {
            unsafe posix_spawnattr_destroy(&attr)
        }

        try checkPOSIX(
            unsafe posix_spawnattr_setpgroup(&attr, 0),
            operation: "posix_spawnattr_setpgroup"
        )
        try checkPOSIX(
            unsafe posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP)),
            operation: "posix_spawnattr_setflags"
        )

        var cArguments = unsafe [UnsafeMutablePointer<CChar>]()
        func freeCArguments() {
            var index = 0
            while index < (unsafe cArguments.count) {
                unsafe free(cArguments[index])
                index += 1
            }
        }

        for argument in arguments {
            guard let cArgument = unsafe strdup(argument) else {
                freeCArguments()
                throw POSIXCommandError(operation: "strdup argument", code: ENOMEM)
            }
            unsafe cArguments.append(cArgument)
        }
        defer {
            freeCArguments()
        }

        var argv = unsafe [UnsafeMutablePointer<CChar>?]()
        var argumentIndex = 0
        while argumentIndex < (unsafe cArguments.count) {
            unsafe argv.append(cArguments[argumentIndex])
            argumentIndex += 1
        }
        unsafe argv.append(nil)

        var pid: pid_t = 0
        let spawnResult = unsafe executable.withCString { executablePath in
            unsafe argv.withUnsafeMutableBufferPointer { argvBuffer in
                unsafe posix_spawnp(
                    &pid,
                    executablePath,
                    &fileActions,
                    &attr,
                    argvBuffer.baseAddress,
                    environ
                )
            }
        }
        try checkPOSIX(spawnResult, operation: "posix_spawnp \(executable)")
        return pid
    }

    func wait(
        timeoutSeconds: TimeInterval,
        heartbeatInterval: TimeInterval,
        onHeartbeat: (TimeInterval) -> Void
    ) -> (exitCode: Int32, timedOut: Bool) {
        let start = Date()
        let deadline = start.addingTimeInterval(timeoutSeconds)
        var nextHeartbeat = start.addingTimeInterval(heartbeatInterval)

        while true {
            let now = Date()
            let nextWakeUp = min(deadline, nextHeartbeat)
            let waitSeconds = max(0, nextWakeUp.timeIntervalSince(now))
            if exitSemaphore.wait(timeout: .now() + waitSeconds) == .success {
                return (Self.exitCode(from: currentWaitStatus()), false)
            }

            let elapsedSeconds = Date().timeIntervalSince(start)
            if elapsedSeconds >= timeoutSeconds {
                terminateProcessGroup()
                return (Self.exitCode(from: currentWaitStatus()), true)
            }

            if Date() >= nextHeartbeat {
                onHeartbeat(elapsedSeconds)
                repeat {
                    nextHeartbeat = nextHeartbeat.addingTimeInterval(heartbeatInterval)
                } while Date() >= nextHeartbeat
            }
        }
    }

    private func reap() {
        var status: Int32 = 0
        while true {
            let waitedPID = unsafe waitpid(pid, &status, 0)
            if waitedPID == pid {
                lock.lock()
                waitStatus = status
                lock.unlock()
                break
            }
            if waitedPID == -1, errno == EINTR {
                continue
            }
            break
        }
        exitSemaphore.signal()
    }

    private func terminateProcessGroup() {
        guard currentWaitStatus() == nil else {
            return
        }

        signalProcessGroup(SIGTERM)
        if exitSemaphore.wait(timeout: .now() + 5) == .success {
            return
        }

        signalProcessGroup(SIGKILL)
        _ = exitSemaphore.wait(timeout: .now() + 5)
    }

    private func signalProcessGroup(_ signal: Int32) {
        if kill(-pid, signal) == -1, errno != ESRCH {
            kill(pid, signal)
        }
    }

    private func currentWaitStatus() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return waitStatus
    }

    private static func exitCode(from waitStatus: Int32?) -> Int32 {
        guard let waitStatus else {
            return -1
        }
        let status = waitStatus & 0x7f
        if status == 0 {
            return (waitStatus >> 8) & 0xff
        }
        if status != 0x7f {
            return 128 + status
        }
        return -1
    }

    private static func checkPOSIX(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw POSIXCommandError(operation: operation, code: result)
        }
    }
}

private struct POSIXCommandError: Error, CustomStringConvertible {
    let operation: String
    let code: Int32

    var description: String {
        "\(operation) failed: \(unsafe String(cString: strerror(code)))"
    }
}

private let lowLevelImportChecks: [(targetName: String, moduleName: String)] = [
    ("XcodeMCPProxyKitClientImportsTestSupport", "XcodeMCPProxyTestSupport"),
]

private let removedSurfaceChecks: [(
    targetName: String,
    source: String,
    expectedFragments: [String]
)] = [
    (
        "XcodeMCPKitClientUsesProtocolHelper",
        """
        import XcodeMCPKit

        func compileOnlyRuntimeProtocolHelperShouldNotBeVisible() {
            _ = MCP.ProtocolVersion.current
        }
        """,
        [
            "cannot find 'MCP' in scope",
            "'MCP' is inaccessible",
            "inaccessible due to 'package' protection level",
        ]
    ),
    (
        "XcodeMCPKitClientUsesRemovedNotify",
        """
        import XcodeMCPKit

        func compileOnlyRemovedNotify(client: XcodeMCP) async throws {
            try await client.notify("notifications/custom")
        }
        """,
        ["has no member 'notify'"]
    ),
    (
        "XcodeMCPKitClientUsesSnapshotInitializer",
        """
        import XcodeMCPKit

        func compileOnlySnapshotInitializerShouldNotBePublic() {
            _ = XcodeMCPConnectionSnapshot(
                sequence: 0,
                generation: 0,
                phase: .initializing
            )
        }
        """,
        [
            "initializer is inaccessible",
            "'XcodeMCPConnectionSnapshot' initializer is inaccessible",
        ]
    ),
    (
        "XcodeMCPProxyKitClientUsesRemovedAdapterEndpointFamily",
        """
        import Foundation
        import XcodeMCPProxyKit

        func compileOnlyRemovedAdapterEndpointFamily() throws {
            let options = XcodeMCPProxyAdapterEndpointResolutionOptions()
            let resolver = XcodeMCPProxyAdapterEndpointResolver()
            let endpoint = XcodeMCPProxyAdapterEndpoint(
                url: URL(string: "http://localhost:8765/mcp")!,
                source: .explicit
            )
            let source: XcodeMCPProxyAdapterEndpoint.Source = .fallback
            _ = (options, resolver, endpoint, source)
        }
        """,
        [
            "cannot find 'XcodeMCPProxyAdapterEndpointResolutionOptions' in scope",
            "cannot find 'XcodeMCPProxyAdapterEndpointResolver' in scope",
            "cannot find 'XcodeMCPProxyAdapterEndpoint' in scope",
        ]
    ),
    (
        "XcodeMCPProxyKitClientUsesRemovedAdapterLaunchPlanFamily",
        """
        import XcodeMCPProxyKit

        func compileOnlyRemovedAdapterLaunchPlanFamily() throws {
            _ = XcodeMCPProxyStdioAdapter.LaunchAction.start
            _ = XcodeMCPProxyStdioAdapter.LaunchOptions(
                executableName: "xcode-mcp-proxy",
                requestTimeout: 300
            )
            _ = try XcodeMCPProxyStdioAdapter.resolveLaunchPlan(
                arguments: ["xcode-mcp-proxy"],
                environment: [:]
            )
        }
        """,
        [
            "has no member 'LaunchAction'",
            "has no member 'LaunchOptions'",
            "has no member 'resolveLaunchPlan'",
            "type 'XcodeMCPProxyStdioAdapter' has no member",
        ]
    ),
    (
        "XcodeMCPProxyKitClientUsesRemovedServerSurface",
        """
        import XcodeMCPProxyKit

        func compileOnlyRemovedServerSurface(_ server: XcodeMCPProxyServer) async throws {
            _ = XcodeMCPProxyServer.productMetadata
            _ = try await server.startAndWriteDiscovery()
        }
        """,
        [
            "productMetadata' is inaccessible",
            "productMetadata is inaccessible",
            "has no member 'startAndWriteDiscovery'",
        ]
    ),
    (
        "XcodeMCPProxyKitClientUsesRemovedInstallerSurface",
        """
        import XcodeMCPProxyKit

        func compileOnlyRemovedInstallerSurface() {
            _ = XcodeMCPProxyInstaller()
            _ = XcodeMCPProxyInstallerConfiguration()
        }
        """,
        [
            "cannot find 'XcodeMCPProxyInstaller' in scope",
            "cannot find 'XcodeMCPProxyInstallerConfiguration' in scope",
        ]
    ),
]

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

    let config = XcodeMCPConfiguration(
        transport: .localBridge(),
        clientName: "PublicContractClient",
        clientVersion: "1.0",
        capabilities: [
            "experimental": [
                "enabled": true,
            ]
        ],
        requestTimeout: .seconds(1)
    )
    let customBridgeConfig = XcodeMCPConfiguration(
        transport: .localBridge(.custom(
            command: "/usr/bin/env",
            arguments: ["printf"],
            environment: ["PUBLIC_CONTRACT": "1"]
        ))
    )

    let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
    let httpConfig = XcodeMCPConfiguration(
        transport: .streamableHTTP(endpoint: endpoint),
        clientName: "PublicHTTPContractClient",
        clientVersion: "1.0",
        requestTimeout: .seconds(1)
    )
    let discoveryConfig = XcodeMCPConfiguration(
        transport: .streamableHTTP(discoveryFile: URL(fileURLWithPath: "/tmp/xcode-mcp/endpoint.json"))
    )
    let proxyDiscoveryConfig = XcodeMCPConfiguration(
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
    let limit = arguments["limit"]?.integerValue
    let integerLimit = arguments["limit"]?.integerValue
    let score = arguments["score"]?.doubleValue
    let optionalIsNull = metadata?["optional"]?.isNull
    let jsonFromObject = try MCPJSONValue(jsonObject: [
        "query": "NavigationStack",
        "limit": 3,
        "optional": NSNull(),
    ])
    let jsonFromEncodable = try MCPJSONValue(ContractPayload(
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
        .sessionRecoveryFailed("replacement initialize failed"),
    ]
    let localizedError: any LocalizedError = XcodeMCPError.sessionRecoveryFailed(
        "replacement initialize failed"
    )

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
        errors,
        localizedError.errorDescription,
        localizedError.recoverySuggestion
    )
}

func compileOnlyClientLifecycleSurface(config: XcodeMCPConfiguration) async throws {
    let client = try await XcodeMCP(configuration: config)
    _ = await client.connectionState()
    _ = await client.connectionStates()
    _ = try await client.listTools(
        options: .init(timeout: .after(.seconds(30)))
    )
    _ = try await client.callTool(
        "DocumentationSearch",
        arguments: [
            "query": "NavigationStack",
        ],
        options: .init(replayPolicy: .onceWhenRejectedBeforeProcessing)
    ) { progress in
        _ = progress.message
    }
    _ = try await client.request(
        "workspace/symbols",
        params: [
            "query": "NavigationStack",
        ]
    )
    try await client.reconnect(options: .init(timeout: .disabled))
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
    let toolCalls = await runtime.recordedToolCalls()
    await client.close()

    _ = toolCalls
}
"""

private let xcodeMCPProxyKitOnlyClientSource = """
import XcodeMCPProxyKit

func compileOnlyProxyProductOnlySurface() {
    let config = XcodeMCPProxyServerConfiguration()
    let server = XcodeMCPProxyServer(configuration: config)

    _ = (
        config,
        server
    )
}
"""

private let xcodeMCPProxyKitClientSource = """
import Foundation
import XcodeMCPKit
import XcodeMCPProxyKit

func compileOnlyProxyConfigurationSurface() {
    let config = XcodeMCPProxyServerConfiguration(
        bindAddress: .init(host: "127.0.0.1", port: 0),
        upstream: .defaultMCPBridge(
            processesPerXcode: 1,
            sessionID: "session-1"
        ),
        maxBodyBytes: 1_048_576,
        requestTimeout: .seconds(120),
        configurationFileURL: URL(fileURLWithPath: "/tmp/xcode-mcp-config.toml"),
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
        ),
        discovery: .file(URL(fileURLWithPath: "/tmp/xcode-mcp-discovery.json")),
        approvalPolicy: .manual,
        featurePolicy: .init(
            prewarmToolsList: false,
            refreshCodeIssuesMode: .proxy
        )
    )
    let customUpstreamConfig = XcodeMCPProxyServerConfiguration(
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
    let upstreamMode = XcodeMCPProxyServerConfiguration.RefreshCodeIssuesMode.upstream
    let server = XcodeMCPProxyServer(configuration: config)
    let adapterConfig = XcodeMCPProxyStdioAdapterConfiguration(
        endpoint: .url(URL(string: "http://localhost:8765/mcp")!),
        requestTimeout: .seconds(30)
    )
    let adapter = try? XcodeMCPProxyStdioAdapter(configuration: adapterConfig)

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
        adapter
    )
}

func compileOnlyProxyLaunchSurface() async throws {
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
    _ = (
        serverExitCode,
        adapterExitCode
    )
}

func compileOnlyAdapterLifecycleSurface(
    adapter: XcodeMCPProxyStdioAdapter
) async throws {
    try await adapter.start()
    _ = await adapter.connectionState()
    await adapter.stop()
    await adapter.waitUntilStopped()
}

func compileOnlyProxyLifecycleSurface(server: XcodeMCPProxyServer) async throws {
    let address = try await server.start()
    let status = await server.snapshot()
    try await server.waitUntilShutdown()
    try await server.shutdown()

    _ = (address.host, address.port, address.url)
    _ = (
        status.phase,
        status.endpoint,
        status.proxyInitialized,
        status.catalogAvailable,
        status.queuedRequestCount,
        status.upstreams,
        status.generatedAt
    )
}
"""

private func lowLevelImportClientSource(moduleName: String) -> String {
    """
    import \(moduleName)

    func compileOnlyLowLevelModuleShouldNotBeVisible() {}
    """
}
