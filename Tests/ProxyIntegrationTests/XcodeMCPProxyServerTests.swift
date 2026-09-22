@testable import XcodeMCPCore
import Dispatch
import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPKit
@testable import XcodeMCPProxyHTTP
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

    @Test func existingServerControllerDetectsOnlyListeningProxyServerProcesses() throws {
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
            currentProcessID: { 999 },
            processControl: processControl
        )

        #expect(controller.detectExistingServerProcessIDs("localhost", 8765) == [456])
    }

    @Test(arguments: ["localhost", "my-mac.local"])
    func forceRestartTerminatesOnlyTheRequestedEndpointOwners(host: String) {
        let processes = RestartProcessFixture()
        let controller = ExistingProxyServerProcessController.live(
            clock: processes.clock,
            currentProcessID: { 999 },
            processControl: processes.client
        )
        var warnings: [String] = []

        #expect(controller.terminateExistingServer(host, 8765) { warnings.append($0) })

        #expect(processes.terminatedProcessIDs == (host == "localhost" ? [456, 567] : [456]))
        #expect(warnings.count == (host == "localhost" ? 2 : 1))
        #expect(warnings.contains { $0.contains("pid: 456") })
        #expect(processes.aliveProcessIDs == (host == "localhost" ? [123, 321, 789, 999] : [123, 321, 567, 789, 999]))
    }

    @Test func forceRestartRechecksLaterPIDAfterEarlierTermination() {
        let processes = RestartProcessFixture(reuseSecondPIDOnTermination: true)
        let controller = ExistingProxyServerProcessController.live(
            clock: processes.clock,
            currentProcessID: { 999 },
            processControl: processes.client
        )
        var warnings: [String] = []

        #expect(controller.terminateExistingServer("localhost", 8765) { warnings.append($0) })

        #expect(processes.terminatedProcessIDs == [456])
        #expect(processes.aliveProcessIDs == [123, 321, 567, 789, 999])
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("pid: 456") == true)
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

    @Test(arguments: [false, true])
    func automaticEnabledHeadlessHonorsApprovalPolicyAndUsesUnboundFeatures(
        autoApprove: Bool
    ) async throws {
        let availabilityQueries = NIOLockedValueBox(0)
        let autoApproverCreations = NIOLockedValueBox(0)
        let autoApprover = RecordingAutoApprover()
        let runtimeConfiguration = NIOLockedValueBox<ProxyRuntimeConfiguration?>(nil)
        let runtime = StartupInventoryRuntime()
        let server = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                discovery: .disabled,
                approvalPolicy: autoApprove ? .automatic : .manual,
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
                    return autoApprover
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
        #expect(captured.usesPermissionDialogAutomation == autoApprove)
        #expect(captured.refreshCodeIssuesMode == .upstream)
        #expect(ProxyRuntime.supportsProcessBoundRouting(configuration: captured) == false)
        #expect(ProxyRuntime.documentationSearchIsConfigured(configuration: captured) == false)
        #expect(autoApproverCreations.withLockedValue { $0 } == (autoApprove ? 1 : 0))
        #expect(autoApprover.startCount == (autoApprove ? 1 : 0))
        try await server.shutdown()
        #expect(autoApprover.cancelCount == (autoApprove ? 1 : 0))
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

    @Test(arguments: [false, true])
    func shutdownDuringStartupReportsCleanupFailure(discoveryFails: Bool) async throws {
        let gateway = ControlledShutdownGateway(holdStartup: true)
        let runtime = StartupInventoryRuntime()
        let autoApprover = RecordingAutoApprover()
        var discovery = DiscoveryClient.testValue
        if discoveryFails {
            discovery.write = { _, _ in throw DiscoveryWriteFailure.expected }
        }
        let server = XcodeMCPProxyServer(
            configuration: .init(approvalPolicy: .automatic),
            dependencies: .init(
                discoveryClient: discovery,
                makeAutoApprover: { _, _ in autoApprover },
                makeRuntime: { _ in runtime },
                makeHTTPGateway: { _, _, _ in gateway }
            )
        )
        let start = Task { try await server.start() }
        try await gateway.startBegan.wait(description: "waiting for gateway startup")
        let firstShutdown = Task { try await server.shutdown() }
        try await gateway.startCancelled.wait(description: "waiting for startup cancellation")
        let secondShutdown = Task { try await server.shutdown() }
        let waiter = Task { try await server.waitUntilShutdown() }
        gateway.allowStart.signal()
        try await gateway.shutdownBegan.wait(description: "waiting for gateway cleanup")
        gateway.allowShutdown.signal()

        let startError = await #expect(throws: (any Error).self) { _ = try await start.value }
        let firstError = await #expect(throws: (any Error).self) { try await firstShutdown.value }
        let secondError = await #expect(throws: (any Error).self) { try await secondShutdown.value }
        let waiterError = await #expect(throws: (any Error).self) { try await waiter.value }
        for error in [startError, firstError, secondError, waiterError] {
            if discoveryFails {
                let failure = try #require(error as? XcodeMCPProxyServer.CleanupError)
                #expect(failure.operationError as? DiscoveryWriteFailure == .expected)
                #expect(failure.cleanupError as? GatewayShutdownFailure == .expected)
                #expect(failure.endpoint == gateway.endpoint)
            } else {
                #expect(error as? GatewayShutdownFailure == .expected)
            }
        }
        let repeatedError = await #expect(throws: (any Error).self) { try await server.shutdown() }
        #expect(discoveryFails
            ? repeatedError is XcodeMCPProxyServer.CleanupError
            : repeatedError as? GatewayShutdownFailure == .expected)
        #expect(gateway.shutdownCount == 1)
        #expect(runtime.shutdownCount == 1)
        #expect(autoApprover.cancelCount == 1)
        let status = await server.snapshot()
        #expect(status.phase == .stopped)
        #expect(status.endpoint == gateway.endpoint)
    }

    @Test func startupFailurePreservesItsCleanupFailureAndBoundEndpoint() async throws {
        let gateway = ControlledShutdownGateway()
        gateway.allowShutdown.signal()
        let runtime = StartupInventoryRuntime()
        var discovery = DiscoveryClient.testValue
        discovery.write = { _, _ in throw DiscoveryWriteFailure.expected }
        let server = XcodeMCPProxyServer(
            configuration: .init(),
            dependencies: .init(
                discoveryClient: discovery,
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { _ in runtime },
                makeHTTPGateway: { _, _, _ in gateway }
            )
        )

        let error = try await #require(throws: XcodeMCPProxyServer.CleanupError.self) {
            _ = try await server.start()
        }

        #expect(error.operationError as? DiscoveryWriteFailure == .expected)
        #expect(error.cleanupError as? GatewayShutdownFailure == .expected)
        #expect(error.endpoint == gateway.endpoint)
        #expect((await server.snapshot()).endpoint == gateway.endpoint)
        await #expect(throws: XcodeMCPProxyServer.CleanupError.self) {
            try await server.waitUntilShutdown()
        }
        await #expect(throws: XcodeMCPProxyServer.CleanupError.self) {
            try await server.shutdown()
        }
        #expect(gateway.shutdownCount == 1)
        #expect(runtime.shutdownCount == 1)
    }

    @Test func gatewayAcquisitionFailurePreservesBothCausesThroughThePublicServer() async throws {
        let runtime = StartupInventoryRuntime()
        let groupShutdownCount = NIOLockedValueBox(0)
        let server = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                discovery: .disabled
            ),
            dependencies: .init(
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { _ in runtime },
                makeHTTPGateway: { configuration, runtime, logger in
                    ProxyHTTPGateway(
                        configuration: configuration,
                        runtime: runtime,
                        logger: logger,
                        bind: { _, _, _ in throw XcodeMCPProxyServer.LifecycleError.failedToBind },
                        shutdownGroup: { group in
                            groupShutdownCount.withLockedValue { $0 += 1 }
                            try await group.shutdownGracefully()
                            throw GatewayShutdownFailure.expected
                        }
                    )
                }
            )
        )

        let error = try await #require(throws: XcodeMCPProxyServer.CleanupError.self) {
            _ = try await server.start()
        }

        let operationErrors = (error.operationError as NSError).underlyingErrors
        #expect(operationErrors.contains { $0 as? XcodeMCPProxyServer.LifecycleError == .failedToBind })
        let cleanupErrors = (error.cleanupError as NSError).underlyingErrors
        #expect(cleanupErrors.contains { $0 as? GatewayShutdownFailure == .expected })
        #expect(error.endpoint == nil)
        await #expect(throws: XcodeMCPProxyServer.CleanupError.self) { try await server.shutdown() }
        #expect(groupShutdownCount.withLockedValue { $0 } == 1)
        #expect(runtime.shutdownCount == 1)
    }

    @Test func runningShutdownSharesReleaseFailureWithoutRepeatingCleanup() async throws {
        let gateway = ControlledShutdownGateway()
        let runtime = StartupInventoryRuntime()
        let server = XcodeMCPProxyServer(
            configuration: .init(discovery: .disabled),
            dependencies: .init(
                makeAutoApprover: { _, _ in RecordingAutoApprover() },
                makeRuntime: { _ in runtime },
                makeHTTPGateway: { _, _, _ in gateway }
            )
        )
        _ = try await server.start()
        let first = Task { try await server.shutdown() }
        try await gateway.shutdownBegan.wait(description: "waiting for gateway cleanup")
        let second = Task { try await server.shutdown() }
        gateway.allowShutdown.signal()

        await #expect(throws: GatewayShutdownFailure.expected) { try await first.value }
        await #expect(throws: GatewayShutdownFailure.expected) { try await second.value }
        await #expect(throws: GatewayShutdownFailure.expected) { try await server.shutdown() }
        await #expect(throws: GatewayShutdownFailure.expected) { try await server.waitUntilShutdown() }
        #expect(gateway.shutdownCount == 1)
        #expect(runtime.shutdownCount == 1)
        #expect((await server.snapshot()).phase == .stopped)
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

private enum GatewayShutdownFailure: Error {
    case expected
}

private final class ControlledShutdownGateway: ProxyHTTPGatewayServing, Sendable {
    let endpoint = XcodeMCPProxyServer.Endpoint(host: "127.0.0.1", port: 9876)
    let startBegan = TestSignal()
    let startCancelled = TestSignal()
    let allowStart = TestSignal()
    let shutdownBegan = TestSignal()
    let allowShutdown = TestSignal()
    private let holdStartup: Bool
    private let shutdowns = NIOLockedValueBox(0)

    init(holdStartup: Bool = false) {
        self.holdStartup = holdStartup
    }

    var shutdownCount: Int { shutdowns.withLockedValue { $0 } }

    func start() async throws -> ProxyHTTPEndpoint {
        startBegan.signal()
        if holdStartup {
            let completion = Task {
                try await allowStart.wait(timeout: .seconds(5), description: "releasing gateway startup")
            }
            try await withTaskCancellationHandler {
                try await completion.value
            } onCancel: {
                self.startCancelled.signal()
            }
        }
        return ProxyHTTPEndpoint(host: endpoint.host, port: endpoint.port)
    }

    func waitUntilShutdown() async throws {
        try await allowShutdown.wait(timeout: .seconds(5), description: "waiting for gateway shutdown")
    }

    func shutdown() async throws {
        shutdowns.withLockedValue { $0 += 1 }
        shutdownBegan.signal()
        let completion = Task {
            try await allowShutdown.wait(timeout: .seconds(5), description: "releasing gateway shutdown")
        }
        try await completion.value
        throw GatewayShutdownFailure.expected
    }

    func cancelForDeinit() {}
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
        var shutdownCount = 0
        var inventoryReadCount = 0
        var readInventoryBeforeStart = false
    }

    private let state = NIOLockedValueBox(State())

    var inventoryReadCount: Int {
        state.withLockedValue(\.inventoryReadCount)
    }

    var shutdownCount: Int { state.withLockedValue(\.shutdownCount) }

    var readInventoryBeforeStart: Bool {
        state.withLockedValue(\.readInventoryBeforeStart)
    }

    func start() {
        state.withLockedValue { $0.started = true }
    }

    func cancelForDeinit() {}

    func shutdown() async { state.withLockedValue { $0.shutdownCount += 1 } }

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

private final class RestartProcessFixture: Sendable {
    private struct ProcessInfo: Sendable {
        let host: String
        let port: Int
        let executable: String
    }

    private struct State {
        var aliveProcessIDs: Set<Int> = [123, 321, 456, 567, 789, 999]
        var terminatedProcessIDs: [Int] = []
        var now = Date(timeIntervalSince1970: 0)
        var secondPIDWasReused = false
    }

    private let state = NIOLockedValueBox(State())
    private let reuseSecondPIDOnTermination: Bool
    private let processes: [Int: ProcessInfo] = [
        123: .init(host: "127.0.0.1", port: 9000, executable: "xcode-mcp-proxy-server"),
        321: .init(host: "10.0.0.5", port: 8765, executable: "xcode-mcp-proxy-server"),
        456: .init(host: "127.0.0.1", port: 8765, executable: "xcode-mcp-proxy-server"),
        567: .init(host: "[::1]", port: 8765, executable: "xcode-mcp-proxy-server"),
        789: .init(host: "127.0.0.1", port: 8765, executable: "python3"),
        999: .init(host: "127.0.0.1", port: 8765, executable: "xcode-mcp-proxy-server"),
    ]

    init(reuseSecondPIDOnTermination: Bool = false) {
        self.reuseSecondPIDOnTermination = reuseSecondPIDOnTermination
    }

    var aliveProcessIDs: [Int] { state.withLockedValue { $0.aliveProcessIDs.sorted() } }
    var terminatedProcessIDs: [Int] { state.withLockedValue { $0.terminatedProcessIDs } }

    var clock: ClockClient {
        ClockClient(
            now: { self.state.withLockedValue { $0.now } },
            uptimeNanoseconds: { 0 },
            sleep: { _ in },
            sleepForTimeInterval: { interval in
                self.state.withLockedValue { $0.now.addTimeInterval(interval) }
            }
        )
    }

    var client: ProcessControlClient {
        ProcessControlClient(
            runCommand: { path, arguments in
                if path == "/usr/sbin/lsof" {
                    #expect(arguments == ["-nP", "-iTCP:8765", "-sTCP:LISTEN", "-Fpn"])
                    return self.aliveProcessIDs.compactMap { pid in
                        guard let process = self.processes[pid], process.port == 8765 else { return nil }
                        return "p\(pid)\nn\(process.host):\(process.port)"
                    }.joined(separator: "\n")
                }
                #expect(path == "/bin/ps")
                guard arguments.count == 5, let pid = Int(arguments[2]), let process = self.processes[pid] else {
                    Issue.record("unexpected process lookup: \(arguments)")
                    return nil
                }
                let executable = pid == 567 && self.state.withLockedValue({ $0.secondPIDWasReused })
                    ? "python3" : process.executable
                return "/tmp/\(executable) --listen \(process.host):\(process.port)"
            },
            sendSignal: { pid, signal in
                self.state.withLockedValue { state in
                    guard state.aliveProcessIDs.contains(pid) else {
                        return ProcessSignalResult(result: -1, errnoValue: ESRCH)
                    }
                    if signal != 0 {
                        #expect(signal == SIGTERM)
                        state.terminatedProcessIDs.append(pid)
                        state.aliveProcessIDs.remove(pid)
                        if pid == 456, self.reuseSecondPIDOnTermination {
                            state.secondPIDWasReused = true
                        }
                    }
                    return ProcessSignalResult(result: 0, errnoValue: 0)
                }
            },
            resolveHostAddress: { host, port in
                #expect(host == "my-mac.local")
                #expect(port == 8765)
                return "127.0.0.1"
            }
        )
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
