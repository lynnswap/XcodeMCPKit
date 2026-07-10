import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPKit
@testable import XcodeMCPProxyKit
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
                makeAutoApprover: { _ in autoApprover },
                makeRuntimeCoordinator: { config, eventLoop in
                    RuntimeCoordinator(
                        config: config,
                        eventLoop: eventLoop,
                        upstreams: [upstream],
                        startImmediately: false
                    )
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
                makeAutoApprover: { _ in autoApprover },
                makeRuntimeCoordinator: { config, eventLoop in
                    RuntimeCoordinator(
                        config: config,
                        eventLoop: eventLoop,
                        upstreams: [upstream],
                        startImmediately: false
                    )
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
        #expect((await server.snapshot()).phase == .stopped)
    }

    @Test func unstartedServerDoesNotCreateEventLoopThreads() async throws {
        let groupCreationCount = NIOLockedValueBox(0)
        let server = XcodeMCPProxyServer(
            configuration: .init(discovery: .disabled),
            dependencies: .init(
                makeEventLoopGroup: {
                    groupCreationCount.withLockedValue { $0 += 1 }
                    return MultiThreadedEventLoopGroup(numberOfThreads: 1)
                },
                makeAutoApprover: { _ in RecordingAutoApprover() },
                makeRuntimeCoordinator: { _, _ in
                    fatalError("an unstarted server must not create a runtime")
                }
            )
        )

        #expect(groupCreationCount.withLockedValue { $0 } == 0)
        #expect((await server.snapshot()).phase == .idle)
        try await server.shutdown()
        #expect(groupCreationCount.withLockedValue { $0 } == 0)
    }

    @Test func startedServerDeinitSynchronouslyCancelsRuntimeRetainTasks() async throws {
        let runtimeReference = WeakRuntimeReference()
        let eventLoopGroup = NIOLockedValueBox<MultiThreadedEventLoopGroup?>(nil)
        let upstream = RecordingUpstreamSlot()
        var server: XcodeMCPProxyServer? = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                discovery: .disabled
            ),
            dependencies: .init(
                discoveryClient: .testValue,
                makeEventLoopGroup: {
                    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                    eventLoopGroup.withLockedValue { $0 = group }
                    return group
                },
                makeAutoApprover: { _ in RecordingAutoApprover() },
                makeRuntimeCoordinator: { config, eventLoop in
                    let runtime = RuntimeCoordinator(
                        config: config,
                        eventLoop: eventLoop,
                        upstreams: [upstream],
                        startImmediately: false
                    )
                    runtimeReference.value = runtime
                    return runtime
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

        // This test deliberately omits the server's explicit shutdown contract.
        // Deinit guarantees cancellation signaling, not synchronous runtime
        // destruction. The injected event-loop group remains test-owned.
        try await shutdown(try #require(eventLoopGroup.withLockedValue { $0 }))
    }

    @Test func explicitConfigurationReadFailurePrecedesResourceAcquisition() async throws {
        let groupCreationCount = NIOLockedValueBox(0)
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).toml")
        let server = XcodeMCPProxyServer(
            configuration: .init(
                configurationFileURL: missingURL,
                discovery: .disabled
            ),
            dependencies: .init(
                makeEventLoopGroup: {
                    groupCreationCount.withLockedValue { $0 += 1 }
                    return MultiThreadedEventLoopGroup(numberOfThreads: 1)
                },
                makeAutoApprover: { _ in RecordingAutoApprover() },
                makeRuntimeCoordinator: { _, _ in
                    fatalError("invalid configuration must not create a runtime")
                }
            )
        )

        await #expect(throws: ProxyConfig.File.LoadError.self) {
            _ = try await server.start()
        }
        #expect(groupCreationCount.withLockedValue { $0 } == 0)
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
                makeAutoApprover: { _ in RecordingAutoApprover() },
                makeRuntimeCoordinator: { config, eventLoop in
                    RuntimeCoordinator(
                        config: config,
                        eventLoop: eventLoop,
                        upstreams: [upstream],
                        startImmediately: false
                    )
                }
            )
        )

        _ = try await server.start()
        try await server.shutdown()
        #expect(readCount.withLockedValue { $0 } == 1)
    }

    @Test func zeroRequestTimeoutFailsBeforeResourceAcquisition() async throws {
        let groupCreationCount = NIOLockedValueBox(0)
        let server = XcodeMCPProxyServer(
            configuration: .init(
                requestTimeout: .zero,
                discovery: .disabled
            ),
            dependencies: .init(
                makeEventLoopGroup: {
                    groupCreationCount.withLockedValue { $0 += 1 }
                    return MultiThreadedEventLoopGroup(numberOfThreads: 1)
                },
                makeAutoApprover: { _ in RecordingAutoApprover() },
                makeRuntimeCoordinator: { _, _ in
                    fatalError("invalid configuration must not create a runtime")
                }
            )
        )

        await #expect(throws: XcodeMCPProxyServer.LifecycleError.self) {
            _ = try await server.start()
        }
        #expect(groupCreationCount.withLockedValue { $0 } == 0)
    }

    @Test func discoveryWriteFailureUnwindsListenerAndRuntime() async throws {
        let recordedPort = NIOLockedValueBox<Int?>(nil)
        let eventLoopGroup = NIOLockedValueBox<MultiThreadedEventLoopGroup?>(nil)
        let eventLoopShutdownCount = NIOLockedValueBox(0)
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
                makeEventLoopGroup: {
                    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                    eventLoopGroup.withLockedValue { $0 = group }
                    return group
                },
                shutdownEventLoopGroup: { group in
                    eventLoopShutdownCount.withLockedValue { $0 += 1 }
                    try await shutdown(group)
                },
                makeAutoApprover: { _ in RecordingAutoApprover() },
                makeRuntimeCoordinator: { config, eventLoop in
                    RuntimeCoordinator(
                        config: config,
                        eventLoop: eventLoop,
                        upstreams: [upstream],
                        startImmediately: false
                    )
                }
            )
        )

        await #expect(throws: DiscoveryWriteFailure.expected) {
            _ = try await server.start()
        }
        #expect(upstream.startCount == 0)
        #expect(upstream.stopCount == 1)
        _ = try #require(eventLoopGroup.withLockedValue { $0 })
        #expect(eventLoopShutdownCount.withLockedValue { $0 } == 1)
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
                makeAutoApprover: { _ in RecordingAutoApprover() },
                makeRuntimeCoordinator: { config, eventLoop in
                    RuntimeCoordinator(
                        config: config,
                        eventLoop: eventLoop,
                        upstreams: [upstream],
                        startImmediately: false
                    )
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
        #expect(labels == [
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
        let eventLoopGroup = NIOLockedValueBox<MultiThreadedEventLoopGroup?>(nil)
        let eventLoopShutdownCount = NIOLockedValueBox(0)
        let upstream = RecordingUpstreamSlot()
        let server = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                discovery: .disabled
            ),
            dependencies: .init(
                discoveryClient: .testValue,
                makeEventLoopGroup: {
                    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                    eventLoopGroup.withLockedValue { $0 = group }
                    return group
                },
                shutdownEventLoopGroup: { group in
                    eventLoopShutdownCount.withLockedValue { $0 += 1 }
                    try await shutdown(group)
                },
                makeAutoApprover: { _ in RecordingAutoApprover() },
                makeRuntimeCoordinator: { config, eventLoop in
                    RuntimeCoordinator(
                        config: config,
                        eventLoop: eventLoop,
                        upstreams: [upstream],
                        startImmediately: false
                    )
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
        _ = try #require(eventLoopGroup.withLockedValue { $0 })
        #expect(eventLoopShutdownCount.withLockedValue { $0 } == 1)
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

    var startCount: Int {
        startCountBox.withLockedValue { $0 }
    }

    func start() {
        startCountBox.withLockedValue { $0 += 1 }
    }

    func stop() {}
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
