import Dispatch
import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPKit
@testable import XcodeMCPProxyKit
@testable import XcodeMCPProxyRuntime
import Testing
import XcodeMCPProxyTestSupport

struct XcodeMCPProxyServerTests {
    @Test func endpointURLBracketsIPv6LiteralHosts() {
        let endpoint = XcodeMCPProxyServer.Endpoint(host: "::1", port: 8765)

        #expect(endpoint.host == "::1")
        #expect(endpoint.port == 8765)
        #expect(endpoint.url.absoluteString == "http://[::1]:8765/mcp")
    }

    @Test func endpointURLPreservesNonIPv6Hosts() {
        let endpoint = XcodeMCPProxyServer.Endpoint(host: "127.0.0.1", port: 8765)

        #expect(endpoint.url.absoluteString == "http://127.0.0.1:8765/mcp")
    }

    @Test func firstXcrunToolSelectionTreatsLogAsFlagWithoutValue() {
        let selection = XcrunArguments.firstToolSelection(
            from: ["--sdk", "macosx", "--log", "mcpbridge", "--some-flag"]
        )

        #expect(selection?.toolName == "mcpbridge")
        #expect(selection?.preToolArguments == ["--sdk", "macosx", "--log"])
    }

    @Test func additionalPermissionDialogExecutableCandidatesKeepXcrunPathWhenToolResolutionFails() {
        let config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 0,
            upstreamCommand: "/usr/bin/xcrun",
            upstreamArgs: ["--foo"],
            maxBodyBytes: 1_048_576,
            requestTimeout: 300
        )

        let candidates = XcodeMCPProxyServer.additionalPermissionDialogExecutableCandidates(config: config)

        #expect(candidates.contains("/usr/bin/xcrun"))
    }

    @Test func additionalPermissionDialogExecutableCandidatesUseConfiguredXcrunCommand() throws {
        let fixture = try makeXcrunFixture()
        defer { fixture.cleanup() }

        let config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 0,
            upstreamCommand: fixture.wrapperPath,
            upstreamArgs: ["--sdk", "macosx", "mcpbridge"],
            maxBodyBytes: 1_048_576,
            requestTimeout: 300
        )

        let candidates = XcodeMCPProxyServer.additionalPermissionDialogExecutableCandidates(config: config)

        #expect(candidates.contains(fixture.wrapperPath))
        #expect(candidates.contains(fixture.toolPath))
    }

    @Test func additionalPermissionDialogExecutableCandidatesUseConfiguredXcrunFromUpstreamArgs() throws {
        let fixture = try makeXcrunFixture()
        defer { fixture.cleanup() }

        let config = ProxyConfig(
            listenHost: "localhost",
            listenPort: 0,
            upstreamCommand: "/bin/echo",
            upstreamArgs: [fixture.wrapperPath, "--log", "mcpbridge"],
            maxBodyBytes: 1_048_576,
            requestTimeout: 300
        )

        let candidates = XcodeMCPProxyServer.additionalPermissionDialogExecutableCandidates(config: config)

        #expect(candidates.contains(fixture.wrapperPath))
        #expect(candidates.contains(fixture.toolPath))
    }

    @Test func executableLookupClientResolvesPathAndXcrunToolThroughInjectedClients() {
        let fileSystem = testDependency(of: FileSystemClient.self) {
            $0.isExecutableFile = { path in
                path == "/custom/bin/xcrun"
            }
        }
        let client = ExecutableLookupClient.live(
            environment: { ["PATH": "/usr/bin:/custom/bin"] },
            fileSystem: fileSystem,
            runCommand: { executablePath, arguments in
                #expect(executablePath == "/custom/bin/xcrun")
                #expect(arguments == ["--sdk", "macosx", "--find", "mcpbridge"])
                return "/custom/toolchain/mcpbridge\n"
            }
        )

        #expect(client.resolveExecutablePath("xcrun") == "/custom/bin/xcrun")
        #expect(
            client.resolveXcrunToolPath(
                "xcrun",
                "mcpbridge",
                ["--sdk", "macosx"]
            ) == "/custom/toolchain/mcpbridge"
        )
    }

    @Test func configurationMirrorsHTTPProxyConfigForCLIBoundary() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("xcode-mcp-proxy-config-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let configURL = directoryURL.appendingPathComponent("proxy.toml")
        try """
        [upstream_handshake]
        clientName = "XcodeMCPKit"

        [tools]
        disabled = []
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let discoveryURL = URL(fileURLWithPath: "/tmp/xcode-mcp-proxy-discovery.json")
        let proxyConfig = ProxyConfig(
            listenHost: "127.0.0.1",
            listenPort: 9876,
            upstreamCommand: "/usr/bin/xcrun",
            upstreamArgs: ["--sdk", "macosx", "mcpbridge"],
            upstreamProcessCount: 3,
            upstreamSessionID: "session-1",
            maxBodyBytes: 2048,
            requestTimeout: 12,
            configPath: configURL.path,
            discoveryFileURL: discoveryURL,
            prewarmToolsList: false,
            autoApproveXcodeDialog: true,
            refreshCodeIssuesMode: .upstream
        )

        let config = XcodeMCPProxyServerConfiguration(serverProxyConfig: proxyConfig)

        #expect(config.listenHost == "127.0.0.1")
        #expect(config.listenPort == 9876)
        #expect(config.upstreamCommand == "/usr/bin/xcrun")
        #expect(config.upstreamArguments == ["--sdk", "macosx", "mcpbridge"])
        #expect(config.upstreamProcessCount == 3)
        #expect(config.upstreamSessionID == "session-1")
        #expect(config.maxBodyBytes == 2048)
        #expect(config.requestTimeout == .seconds(12))
        #expect(config.configPath == configURL.path)
        #expect(config.discovery == .file(discoveryURL))
        #expect(config.prewarmToolsList == false)
        #expect(config.autoApproveXcodeDialog == true)
        #expect(config.refreshCodeIssuesMode == .upstream)
    }

    @Test func existingServerControllerDetectsOnlyProxyServerProcesses() throws {
        let record = DiscoveryRecord(
            url: "http://localhost:8765/mcp",
            host: "localhost",
            port: 8765,
            pid: 123,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let discoveryClient = DiscoveryClient.live(
            defaultFileURL: { URL(fileURLWithPath: "/unused/endpoint.json") },
            loadRecord: { _ in record },
            persistRecord: { _, _ in
                Issue.record("detect should not persist discovery records")
            },
            createDirectory: { _ in
                Issue.record("detect should not create directories")
            },
            isProcessAlive: { pid in
                #expect(pid == record.pid)
                return true
            },
            now: { Date(timeIntervalSince1970: 2) }
        )
        let processControl = ProcessControlClient(
            runCommand: { launchPath, arguments in
                switch (launchPath, arguments) {
                case ("/usr/sbin/lsof", ["-nP", "-iTCP:8765", "-sTCP:LISTEN", "-Fpn"]):
                    return """
                        p456
                        f9
                        n127.0.0.1:8765
                        p789
                        f9
                        n127.0.0.1:8765
                        """
                case ("/bin/ps", ["-ww", "-p", "123", "-o", "command="]):
                    return "/tmp/xcode-mcp-proxy-server --listen localhost:8765\n"
                case ("/bin/ps", ["-ww", "-p", "456", "-o", "command="]):
                    return "/usr/local/bin/xcode-mcp-proxy-server --listen localhost:8765\n"
                case ("/bin/ps", ["-ww", "-p", "789", "-o", "command="]):
                    return "/usr/bin/python3 other-server.py\n"
                default:
                    Issue.record("unexpected process command: \(launchPath) \(arguments)")
                    return nil
                }
            },
            sendSignal: { _, _ in
                Issue.record("detect should not send signals")
                return ProcessSignalResult(result: -1, errnoValue: ESRCH)
            }
        )
        let controller = ExistingProxyServerProcessController.live(
            discoveryClient: discoveryClient,
            currentProcessID: { 999 },
            processControl: processControl
        )

        #expect(controller.detectExistingServerProcessIDs("localhost", 8765) == [123, 456])
    }

    @Test func portInUseDiagnosticFormatsMessage() throws {
        let message = XcodeMCPProxyServer.PortInUseError(
            host: "::1",
            port: 8765,
            processIdentifiers: [111, 222]
        )
        .description

        #expect(message.contains("listen [::1]:8765"))
        #expect(message.contains("pids: 111, 222"))
        #expect(message.contains("--force-restart"))
    }

    @Test func startDoesNotLaunchRuntimeLifecycleWhenBindFails() async throws {
        let blockerGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let blocker = try await ServerBootstrap(group: blockerGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let blockedPort = try #require(blocker.localAddress?.port)

        let autoApprover = RecordingAutoApprover()
        let upstream = RecordingUpstreamSlot()
        let config = ProxyConfig(
            listenHost: "127.0.0.1",
            listenPort: blockedPort,
            upstreamCommand: MCPBridgeInvocation.defaultMCPBridge.command,
            upstreamArgs: MCPBridgeInvocation.defaultMCPBridge.arguments,
            maxBodyBytes: 1_048_576,
            requestTimeout: 300,
            autoApproveXcodeDialog: true
        )
        let server = XcodeMCPProxyServer(
            proxyConfig: config,
            dependencies: .init(
                discoveryClient: .testValue,
                makeAutoApprover: { _, _ in autoApprover },
                makeRuntime: { config in
                    makeServerTestRuntime(config: config, upstream: upstream)
                }
            )
        )

        do {
            _ = try await server.start()
            Issue.record("expected bind failure")
        } catch {}

        #expect(autoApprover.startCount == 0)
        #expect(upstream.startCount == 0)

        try? await server.shutdown()
        try? await blocker.close().get()
        try await shutdown(blockerGroup)
    }

    @Test func startupSummaryReadsInventoryAfterRuntimeStarts() async throws {
        let runtime = StartupInventoryRuntime()
        let server = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                discovery: .disabled
            ),
            dependencies: .init(
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { _ in runtime }
            )
        )

        _ = try await server.start()
        #expect(runtime.inventoryReadCount > 0)
        #expect(runtime.readInventoryBeforeStart == false)
        try await server.shutdown()
    }

    @Test func automaticEnabledHeadlessSkipsGUIAutomationAndUsesUnboundFeatures() async throws {
        let availabilityQueries = NIOLockedValueBox(0)
        let autoApproverCreations = NIOLockedValueBox(0)
        let runtimeConfiguration = NIOLockedValueBox<ProxyRuntimeConfiguration?>(nil)
        let runtime = StartupInventoryRuntime()
        let server = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                discovery: .disabled,
                approvalPolicy: .automatic,
                featurePolicy: .init(refreshCodeIssuesMode: .proxy)
            ),
            dependencies: .init(
                discoveryClient: .testValue,
                headlessMCPAvailability: {
                    availabilityQueries.withLockedValue { $0 += 1 }
                    return .enabled
                },
                makeAutoApprover: { _, _ in
                    autoApproverCreations.withLockedValue { $0 += 1 }
                    return RecordingAutoApprover()
                },
                makeRuntime: { config in
                    runtimeConfiguration.withLockedValue { $0 = config }
                    return runtime
                }
            )
        )

        _ = try await server.start()
        let captured = try #require(runtimeConfiguration.withLockedValue { $0 })
        #expect(availabilityQueries.withLockedValue { $0 } == 1)
        #expect(captured.xcodeMode == .headless)
        #expect(captured.usesPermissionDialogAutomation == false)
        #expect(captured.refreshCodeIssuesMode == .upstream)
        #expect(ProxyRuntime.supportsProcessBoundRouting(configuration: captured) == false)
        #expect(ProxyRuntime.documentationSearchIsConfigured(configuration: captured) == false)
        #expect(autoApproverCreations.withLockedValue { $0 } == 0)
        try await server.shutdown()
    }

    @Test func explicitGUIPreservesLegacyRoutingWithoutStatusQuery() async throws {
        let availabilityQueries = NIOLockedValueBox(0)
        let runtimeConfiguration = NIOLockedValueBox<ProxyRuntimeConfiguration?>(nil)
        let runtime = StartupInventoryRuntime()
        let server = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                discovery: .disabled,
                xcodeMode: .gui
            ),
            dependencies: .init(
                discoveryClient: .testValue,
                headlessMCPAvailability: {
                    availabilityQueries.withLockedValue { $0 += 1 }
                    return .enabled
                },
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { config in
                    runtimeConfiguration.withLockedValue { $0 = config }
                    return runtime
                }
            )
        )

        _ = try await server.start()
        let captured = try #require(runtimeConfiguration.withLockedValue { $0 })
        #expect(availabilityQueries.withLockedValue { $0 } == 0)
        #expect(captured.xcodeMode == .gui)
        #expect(ProxyRuntime.supportsProcessBoundRouting(configuration: captured))
        try await server.shutdown()
    }

    @Test func customAutomaticUpstreamPreservesUnboundModeWithoutStatusQuery() async throws {
        let availabilityQueries = NIOLockedValueBox(0)
        let runtimeConfiguration = NIOLockedValueBox<ProxyRuntimeConfiguration?>(nil)
        let runtime = StartupInventoryRuntime()
        let server = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                upstream: .custom(command: "/bin/echo", arguments: []),
                discovery: .disabled
            ),
            dependencies: .init(
                discoveryClient: .testValue,
                headlessMCPAvailability: {
                    availabilityQueries.withLockedValue { $0 += 1 }
                    return .enabled
                },
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { config in
                    runtimeConfiguration.withLockedValue { $0 = config }
                    return runtime
                }
            )
        )

        _ = try await server.start()
        let captured = try #require(runtimeConfiguration.withLockedValue { $0 })
        #expect(availabilityQueries.withLockedValue { $0 } == 0)
        #expect(captured.xcodeMode == .custom)
        #expect(ProxyRuntime.supportsProcessBoundRouting(configuration: captured) == false)
        try await server.shutdown()
    }

    @Test func explicitHeadlessDisabledFailsBeforeRuntimeAcquisition() async {
        let runtimeCreations = NIOLockedValueBox(0)
        let server = XcodeMCPProxyServer(
            configuration: .init(
                discovery: .disabled,
                xcodeMode: .headless
            ),
            dependencies: .init(
                discoveryClient: .testValue,
                headlessMCPAvailability: { .disabled },
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { _ in
                    runtimeCreations.withLockedValue { $0 += 1 }
                    return StartupInventoryRuntime()
                }
            )
        )

        await #expect(throws: XcodeMCPProxyServer.LifecycleError.self) {
            _ = try await server.start()
        }
        #expect(runtimeCreations.withLockedValue { $0 } == 0)
    }

    @Test func explicitModeRejectsCustomUpstreamBeforeRuntimeAcquisition() async {
        let runtimeCreations = NIOLockedValueBox(0)
        let server = XcodeMCPProxyServer(
            configuration: .init(
                upstream: .custom(command: "/bin/echo", arguments: []),
                discovery: .disabled,
                xcodeMode: .gui
            ),
            dependencies: .init(
                discoveryClient: .testValue,
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { _ in
                    runtimeCreations.withLockedValue { $0 += 1 }
                    return StartupInventoryRuntime()
                }
            )
        )

        await #expect(throws: XcodeMCPProxyServer.LifecycleError.self) {
            _ = try await server.start()
        }
        #expect(runtimeCreations.withLockedValue { $0 } == 0)
    }

    @Test func cancellingStartCancelsAndAwaitsHeadlessStatusResolution() async throws {
        let availability = CancellationControlledHeadlessAvailability()
        let runtimeCreations = NIOLockedValueBox(0)
        let server = XcodeMCPProxyServer(
            configuration: .init(discovery: .disabled),
            dependencies: .init(
                discoveryClient: .testValue,
                headlessMCPAvailability: {
                    try await availability.resolve()
                },
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { _ in
                    runtimeCreations.withLockedValue { $0 += 1 }
                    return StartupInventoryRuntime()
                }
            )
        )
        let startTask = Task {
            try await server.start()
        }

        try await availability.started.wait(description: "waiting for headless status resolution")
        startTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await startTask.value
        }
        try await availability.completed.wait(
            description: "waiting for cancelled headless status unwind"
        )
        #expect(availability.wasCancelled)
        #expect(runtimeCreations.withLockedValue { $0 } == 0)
        #expect((await server.snapshot()).phase == .stopped)
    }

    @Test func shutdownWhileStartingCancelsAndAwaitsHeadlessStatusResolution() async throws {
        let availability = CancellationControlledHeadlessAvailability()
        let runtimeCreations = NIOLockedValueBox(0)
        let server = XcodeMCPProxyServer(
            configuration: .init(discovery: .disabled),
            dependencies: .init(
                discoveryClient: .testValue,
                headlessMCPAvailability: {
                    try await availability.resolve()
                },
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { _ in
                    runtimeCreations.withLockedValue { $0 += 1 }
                    return StartupInventoryRuntime()
                }
            )
        )
        let startTask = Task {
            try await server.start()
        }

        try await availability.started.wait(description: "waiting for headless status resolution")
        try await server.shutdown()

        await #expect(throws: CancellationError.self) {
            _ = try await startTask.value
        }
        try await availability.completed.wait(
            description: "waiting for shutdown status unwind"
        )
        #expect(availability.wasCancelled)
        #expect(runtimeCreations.withLockedValue { $0 } == 0)
        #expect((await server.snapshot()).phase == .stopped)
    }

    @Test func startRejectsRepeatedStartsOnSameServerInstance() async throws {
        let autoApprover = RecordingAutoApprover()
        let upstream = RecordingUpstreamSlot()
        let config = ProxyConfig(
            listenHost: "127.0.0.1",
            listenPort: 0,
            upstreamCommand: MCPBridgeInvocation.defaultMCPBridge.command,
            upstreamArgs: MCPBridgeInvocation.defaultMCPBridge.arguments,
            maxBodyBytes: 1_048_576,
            requestTimeout: 300,
            autoApproveXcodeDialog: true
        )
        let server = XcodeMCPProxyServer(
            proxyConfig: config,
            dependencies: .init(
                discoveryClient: .testValue,
                makeAutoApprover: { _, _ in autoApprover },
                makeRuntime: { config in
                    makeServerTestRuntime(config: config, upstream: upstream)
                }
            )
        )

        let endpoint = try await server.start()
        #expect(endpoint.port > 0)

        await #expect(throws: XcodeMCPProxyServer.LifecycleError.alreadyStarted) {
            _ = try await server.start()
        }
        #expect(autoApprover.startCount == 1)

        let waiter = Task {
            try await server.waitUntilShutdown()
        }
        try await server.shutdown()
        try await waiter.value
        try await server.shutdown()
        #expect(autoApprover.cancelCount == 1)
        #expect((await server.snapshot()).phase == .stopped)
    }

    @Test func shutdownDoesNotWaitForCancelledAutoApproverWork() async throws {
        let autoApprover = BlockingAutoApprover()
        let upstream = RecordingUpstreamSlot()
        let config = ProxyConfig(
            listenHost: "127.0.0.1",
            listenPort: 0,
            upstreamCommand: MCPBridgeInvocation.defaultMCPBridge.command,
            upstreamArgs: MCPBridgeInvocation.defaultMCPBridge.arguments,
            maxBodyBytes: 1_048_576,
            requestTimeout: 300,
            autoApproveXcodeDialog: true
        )
        let server = XcodeMCPProxyServer(
            proxyConfig: config,
            dependencies: .init(
                discoveryClient: .testValue,
                makeAutoApprover: { _, _ in autoApprover },
                makeRuntime: { config in
                    makeServerTestRuntime(config: config, upstream: upstream)
                }
            )
        )

        _ = try await server.start()
        try await autoApprover.waitUntilWorkStarts()

        try await server.shutdown()

        #expect(autoApprover.cancelCount == 1)
        #expect(autoApprover.isWorkFinished == false)
        await autoApprover.releaseWork()
    }

    @Test func unstartedServerDoesNotCreateHTTPGateway() async throws {
        let gatewayCreationCount = NIOLockedValueBox(0)
        let server = XcodeMCPProxyServer(
            configuration: .init(discovery: .disabled),
            dependencies: .init(
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { _ in
                    fatalError("an unstarted server must not create a runtime")
                },
                makeHTTPGateway: { _, _, _ in
                    gatewayCreationCount.withLockedValue { $0 += 1 }
                    fatalError("an unstarted server must not create an HTTP gateway")
                }
            )
        )

        #expect(gatewayCreationCount.withLockedValue { $0 } == 0)
        #expect((await server.snapshot()).phase == .idle)
        try await server.shutdown()
        #expect(gatewayCreationCount.withLockedValue { $0 } == 0)
    }

    @Test func startedServerDeinitSynchronouslyCancelsRuntimeRetainTasks() async throws {
        let runtimeReference = WeakRuntimeReference()
        let upstream = RecordingUpstreamSlot()
        let autoApprover = RecordingAutoApprover()
        var server: XcodeMCPProxyServer? = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                discovery: .disabled,
                approvalPolicy: .automatic
            ),
            dependencies: .init(
                discoveryClient: .testValue,
                makeAutoApprover: { _, _ in autoApprover },
                makeRuntime: { config in
                    makeServerTestRuntime(
                        config: config,
                        upstream: upstream,
                        runtimeReference: runtimeReference
                    )
                }
            )
        )

        _ = try await server?.start()
        #expect(runtimeReference.value != nil)
        let runtimeTaskDrains = try #require(
            runtimeReference.runtimeTaskDrains()
        )
        server = nil

        try await waitWithTimeout(
            "waiting for deinit-cancelled runtime tasks",
            timeout: .seconds(2)
        ) {
            await runtimeTaskDrains.wait()
        }
        #expect(autoApprover.cancelCount == 1)

        // This test deliberately omits the server's explicit shutdown contract.
        // Deinit guarantees cancellation signaling rather than awaiting teardown.
    }

    @Test func explicitConfigurationReadFailurePrecedesResourceAcquisition() async throws {
        let gatewayCreationCount = NIOLockedValueBox(0)
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).toml")
        let server = XcodeMCPProxyServer(
            configuration: .init(
                configurationFileURL: missingURL,
                discovery: .disabled
            ),
            dependencies: .init(
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { _ in
                    fatalError("invalid configuration must not create a runtime")
                },
                makeHTTPGateway: { _, _, _ in
                    gatewayCreationCount.withLockedValue { $0 += 1 }
                    fatalError("invalid configuration must not create an HTTP gateway")
                }
            )
        )

        await #expect(throws: ProxyConfig.File.LoadError.self) {
            _ = try await server.start()
        }
        #expect(gatewayCreationCount.withLockedValue { $0 } == 0)
        #expect((await server.snapshot()).phase == .stopped)
        await #expect(throws: XcodeMCPProxyServer.LifecycleError.alreadyStarted) {
            _ = try await server.start()
        }
    }

    @Test func cliPreparedConfigurationIsReusedWithoutASecondFileRead() async throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("single-read-\(UUID().uuidString).toml")
        try "".write(to: configURL, atomically: true, encoding: .utf8)
        let readCount = NIOLockedValueBox(0)
        let action = try XcodeMCPProxyServer.resolveLaunchAction(
            arguments: [
                "xcode-mcp-proxy-server",
                "--listen", "127.0.0.1:0",
                "--config", configURL.path,
            ],
            environment: [:],
            loadFileConfiguration: { url in
                readCount.withLockedValue { $0 += 1 }
                return try ProxyConfig.File.Loader.loadStrict(configURL: url)
            }
        )
        guard case .start(let preparedConfiguration, _) = action else {
            Issue.record("expected start action")
            return
        }
        try FileManager.default.removeItem(at: configURL)

        let upstream = RecordingUpstreamSlot()
        let server = XcodeMCPProxyServer(
            preparedConfiguration: preparedConfiguration,
            dependencies: .init(
                discoveryClient: .testValue,
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { config in
                    makeServerTestRuntime(config: config, upstream: upstream)
                }
            )
        )

        _ = try await server.start()
        try await server.shutdown()
        #expect(readCount.withLockedValue { $0 } == 1)
    }

    @Test func zeroRequestTimeoutFailsBeforeResourceAcquisition() async throws {
        let gatewayCreationCount = NIOLockedValueBox(0)
        let server = XcodeMCPProxyServer(
            configuration: .init(
                requestTimeout: .zero,
                discovery: .disabled
            ),
            dependencies: .init(
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { _ in
                    fatalError("invalid configuration must not create a runtime")
                },
                makeHTTPGateway: { _, _, _ in
                    gatewayCreationCount.withLockedValue { $0 += 1 }
                    fatalError("invalid configuration must not create an HTTP gateway")
                }
            )
        )

        await #expect(throws: XcodeMCPProxyServer.LifecycleError.self) {
            _ = try await server.start()
        }
        #expect(gatewayCreationCount.withLockedValue { $0 } == 0)
    }

    @Test func discoveryWriteFailureUnwindsListenerAndRuntime() async throws {
        let recordedPort = NIOLockedValueBox<Int?>(nil)
        var discoveryClient = DiscoveryClient.testValue
        discoveryClient.write = { record, _ in
            recordedPort.withLockedValue { $0 = record.port }
            throw DiscoveryWriteFailure.expected
        }
        let upstream = RecordingUpstreamSlot()
        let server = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                discovery: .file(URL(fileURLWithPath: "/unused/discovery.json"))
            ),
            dependencies: .init(
                discoveryClient: discoveryClient,
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { config in
                    makeServerTestRuntime(config: config, upstream: upstream)
                }
            )
        )

        await #expect(throws: DiscoveryWriteFailure.expected) {
            _ = try await server.start()
        }
        #expect(upstream.startCount == 0)
        #expect(upstream.stopCount == 1)
        #expect((await server.snapshot()).phase == .stopped)

        let port = try #require(recordedPort.withLockedValue { $0 })
        let probeGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let probe = try await ServerBootstrap(group: probeGroup)
            .bind(host: "127.0.0.1", port: port)
            .get()
        try await probe.close().get()
        try await shutdown(probeGroup)
    }

    @Test func statusSnapshotExposesOnlySanitizedContractFields() async throws {
        let upstream = RecordingUpstreamSlot()
        let config = ProxyConfig(
            listenHost: "127.0.0.1",
            listenPort: 0,
            upstreamCommand: MCPBridgeInvocation.defaultMCPBridge.command,
            upstreamArgs: MCPBridgeInvocation.defaultMCPBridge.arguments,
            maxBodyBytes: 1_048_576,
            requestTimeout: 300
        )
        let server = XcodeMCPProxyServer(
            proxyConfig: config,
            dependencies: .init(
                discoveryClient: .testValue,
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { config in
                    makeServerTestRuntime(config: config, upstream: upstream)
                }
            )
        )

        let endpoint = try await server.start()
        let status = await server.snapshot()
        #expect(status.phase == .running)
        #expect(status.endpoint == endpoint)
        #expect(status.queuedRequestCount == 0)
        #expect(status.upstreams.map(\.id) == [0])
        #expect(status.upstreams.allSatisfy { $0.activeRequestCount == 0 })

        let labels = Set(Mirror(reflecting: status).children.compactMap(\.label))
        #expect(
            labels == [
                "phase",
                "endpoint",
                "proxyInitialized",
                "catalogAvailable",
                "queuedRequestCount",
                "upstreams",
                "generatedAt",
            ])

        try await server.shutdown()
    }

    @Test func concurrentShutdownCompletesAllOwnedResourcesExactlyOnce() async throws {
        let upstream = RecordingUpstreamSlot()
        let server = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                discovery: .disabled
            ),
            dependencies: .init(
                discoveryClient: .testValue,
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { config in
                    makeServerTestRuntime(config: config, upstream: upstream)
                }
            )
        )

        let endpoint = try await server.start()
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let acceptedClient = try await ClientBootstrap(group: clientGroup)
            .connect(host: endpoint.host, port: endpoint.port)
            .get()

        async let firstShutdown: Void = server.shutdown()
        async let secondShutdown: Void = server.shutdown()
        try await firstShutdown
        try await secondShutdown
        try await acceptedClient.closeFuture.get()

        #expect(upstream.stopCount == 1)
        let status = await server.snapshot()
        #expect(status.phase == .stopped)
        #expect(status.upstreams.map(\.health) == [.stopped])
        #expect(status.upstreams.map(\.activeRequestCount) == [0])

        let probeGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let rebound = try await ServerBootstrap(group: probeGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: endpoint.port)
            .get()
        try await rebound.close().get()
        try await shutdown(probeGroup)
        try await shutdown(clientGroup)
    }
}

private enum DiscoveryWriteFailure: Error {
    case expected
}

private final class RecordingAutoApprover: @unchecked Sendable, ProxyServerPermissionDialogAutoApprover {
    private let startCountBox = NIOLockedValueBox(0)
    private let cancelCountBox = NIOLockedValueBox(0)

    var startCount: Int {
        startCountBox.withLockedValue { $0 }
    }

    var cancelCount: Int {
        cancelCountBox.withLockedValue { $0 }
    }

    func start() {
        startCountBox.withLockedValue { $0 += 1 }
    }

    func cancel() {
        cancelCountBox.withLockedValue { $0 += 1 }
    }
}

private final class BlockingAutoApprover: @unchecked Sendable,
    ProxyServerPermissionDialogAutoApprover
{
    private let started = TestSignal()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let taskBox = NIOLockedValueBox<Task<Void, Never>?>(nil)
    private let cancelCountBox = NIOLockedValueBox(0)
    private let isWorkFinishedBox = NIOLockedValueBox(false)

    var cancelCount: Int {
        cancelCountBox.withLockedValue { $0 }
    }

    var isWorkFinished: Bool {
        isWorkFinishedBox.withLockedValue { $0 }
    }

    func start() {
        let started = started
        let releaseSemaphore = releaseSemaphore
        let isWorkFinishedBox = isWorkFinishedBox
        let task = Task.detached {
            started.signal()
            Self.waitForSynchronousWorkRelease(releaseSemaphore)
            isWorkFinishedBox.withLockedValue { $0 = true }
        }
        taskBox.withLockedValue { $0 = task }
    }

    func cancel() {
        cancelCountBox.withLockedValue { $0 += 1 }
        taskBox.withLockedValue { $0 }?.cancel()
    }

    func waitUntilWorkStarts() async throws {
        try await started.wait(description: "waiting for blocking auto-approver work")
    }

    func releaseWork() async {
        releaseSemaphore.signal()
        await taskBox.withLockedValue { $0 }?.value
    }

    private static func waitForSynchronousWorkRelease(
        _ semaphore: DispatchSemaphore
    ) {
        semaphore.wait()
    }
}

private final class CancellationControlledHeadlessAvailability: @unchecked Sendable {
    let started = TestSignal()
    let completed = TestSignal()

    private let release = TestSignal()
    private let cancelled = NIOLockedValueBox(false)

    var wasCancelled: Bool {
        cancelled.withLockedValue { $0 }
    }

    func resolve() async throws -> XcodeMCPServerAvailability {
        started.signal()
        defer { completed.signal() }
        do {
            try await release.waitUntilSignaled()
            return .enabled
        } catch is CancellationError {
            cancelled.withLockedValue { $0 = true }
            throw CancellationError()
        }
    }
}

private final class StartupInventoryRuntime: @unchecked Sendable, ProxyRuntimeServing {
    private struct State {
        var started = false
        var inventoryReadCount = 0
        var readInventoryBeforeStart = false
    }

    private let state = NIOLockedValueBox(State())

    var inventoryReadCount: Int {
        state.withLockedValue(\.inventoryReadCount)
    }

    var readInventoryBeforeStart: Bool {
        state.withLockedValue(\.readInventoryBeforeStart)
    }

    func start() {
        state.withLockedValue { $0.started = true }
    }

    func cancelForDeinit() {}

    func shutdown() async {}

    func subscribeToEvents(
        _ receive: @escaping @Sendable (ProxyRuntimeEvent) -> Void
    ) -> @Sendable () -> Void {
        {}
    }

    func beginRequest(
        _ message: ProxyRuntimeRequest,
        in sessionID: ProxySessionID?
    ) -> (any ProxyRuntimeRequestOperating)? {
        fatalError("startup lifecycle test does not admit requests")
    }

    func clientRequestFinished(_: ProxySessionID) {}

    func sessionState(_ id: ProxySessionID) -> ProxyRuntimeSessionState {
        .missing
    }

    func clientEventStreamOpened(_: ProxySessionID) -> Bool { false }

    func clientEventStreamClosed(_: ProxySessionID) {}

    func expireInactiveSessions(inactiveFor _: TimeAmount) {}

    func removeSession(_ id: ProxySessionID) {}

    func snapshot() -> ProxyRuntimeSnapshot {
        ProxyRuntimeSnapshot(
            generatedAt: Date(),
            proxyInitialized: false,
            catalogAvailable: false,
            queuedRequestCount: 0,
            upstreams: []
        )
    }

    func inventorySnapshot() -> ProxyRuntimeInventorySnapshot {
        state.withLockedValue { state in
            state.inventoryReadCount += 1
            state.readInventoryBeforeStart = state.readInventoryBeforeStart || state.started == false
        }
        return ProxyRuntimeInventorySnapshot(
            xcodeTargets: [
                ProxyRuntimeInventorySnapshot.XcodeTarget(
                    processID: 42,
                    appPath: "/Applications/Xcode.app",
                    mcpBridgePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge"
                )
            ],
            permissionDialogProcessIDs: [42]
        )
    }

    func debugSnapshotData(includeSensitivePayloads: Bool) -> Data? {
        nil
    }

    func reset() async {}
}

private final class WeakRuntimeReference: @unchecked Sendable {
    struct TaskDrains: Sendable {
        let runtime: AsyncTaskSupervisor.Drain
        let upstreamEvents: AsyncTaskSupervisor.Drain

        func wait() async {
            await upstreamEvents.wait()
            await runtime.wait()
        }
    }

    private let lock = NSLock()
    private weak var storage: RuntimeCoordinator?

    var value: RuntimeCoordinator? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    func runtimeTaskDrains() -> TaskDrains? {
        lock.lock()
        defer { lock.unlock() }
        guard let runtime = storage else {
            return nil
        }
        return TaskDrains(
            runtime: runtime.runtimeTasks.drainCurrentTasks(),
            upstreamEvents: runtime.upstreamEventTasks.drainCurrentTasks()
        )
    }
}

private func makeServerTestRuntime(
    config: ProxyRuntimeConfiguration,
    upstream: any UpstreamSlotControlling,
    runtimeReference: WeakRuntimeReference? = nil
) -> ProxyRuntime {
    ProxyRuntime.testing(configuration: config) {
        eventLoop,
        notificationSink,
        sessionClosedSink in
        let coordinator = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            notificationSink: notificationSink,
            sessionClosedSink: sessionClosedSink,
            startImmediately: false
        )
        runtimeReference?.value = coordinator
        return coordinator
    }
}

private final class RecordingUpstreamSlot: @unchecked Sendable, UpstreamSlotControlling {
    private let startCountBox = NIOLockedValueBox(0)
    private let stopCountBox = NIOLockedValueBox(0)
    private let eventStream: AsyncStream<Upstream.Event>

    var startCount: Int {
        startCountBox.withLockedValue { $0 }
    }

    var stopCount: Int {
        stopCountBox.withLockedValue { $0 }
    }

    var events: AsyncStream<Upstream.Event> {
        eventStream
    }

    init() {
        eventStream = AsyncStream { _ in }
    }

    func start() async {
        startCountBox.withLockedValue { $0 += 1 }
    }

    func stop() async {
        stopCountBox.withLockedValue { $0 += 1 }
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        _ = data
        return .accepted
    }
}

private struct XcrunFixture {
    let wrapperPath: String
    let toolPath: String
    let directoryURL: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func makeXcrunFixture() throws -> XcrunFixture {
    let fileManager = FileManager.default
    let directoryURL = fileManager.temporaryDirectory
        .appendingPathComponent("xcode-mcp-proxy-xcrun-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let toolPath = directoryURL.appendingPathComponent("fake-mcpbridge").path
    let wrapperPath = directoryURL.appendingPathComponent("xcrun").path
    let script = """
        #!/bin/sh
        if [ "$1" = "--sdk" ]; then
          shift 2
        fi
        if [ "$1" = "--log" ]; then
          shift
        fi
        if [ "$1" = "--find" ] && [ "$2" = "mcpbridge" ]; then
          echo "\(toolPath)"
          exit 0
        fi
        exit 1
        """
    try script.write(to: URL(fileURLWithPath: wrapperPath), atomically: true, encoding: .utf8)
    try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: wrapperPath
    )

    return XcrunFixture(
        wrapperPath: wrapperPath,
        toolPath: toolPath,
        directoryURL: directoryURL
    )
}
