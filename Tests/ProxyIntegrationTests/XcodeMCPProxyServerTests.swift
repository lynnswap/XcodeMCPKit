import XcodeMCPProxyRuntimeContract
@testable import XcodeMCPCore
import Dispatch
import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPKit
@testable import XcodeMCPProxyHTTP
@testable import XcodeMCPProxyKit
@testable import XcodeMCPProxyRuntime
@testable import XcodeMCPProxyRuntimeTestSupport
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

        let runtime = StartupTestRuntime()
        let config = XcodeMCPProxyServerConfiguration(
            bindAddress: .init(host: "127.0.0.1", port: blockedPort),

            maxBodyBytes: 1_048_576,
            requestTimeout: .seconds(300)
        )
        let server = XcodeMCPProxyServer(
            configuration: config,
            dependencies: .init(
                discoveryClient: .testValue,
                makeRuntime: { _ in runtime }
            )
        )

        do {
            _ = try await server.start()
            Issue.record("expected bind failure")
        } catch {}

        #expect(runtime.startCount == 0)

        try? await server.shutdown()
        try? await blocker.close().get()
        try await shutdown(blockerGroup)
    }

    @Test func nativeStartupPreservesInstallationSelection() async throws {
        let runtimeConfiguration = NIOLockedValueBox<ProxyRuntimeConfiguration?>(nil)
        let runtime = StartupTestRuntime()
        let bundleURL = URL(fileURLWithPath: "/fixtures/XcodeMCPNativeHost.app")
        let developerURL = URL(fileURLWithPath: "/fixtures/Xcode.app/Contents/Developer")
        let server = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                nativeHostBundleURL: bundleURL,
                developerDirectoryURL: developerURL,
                discovery: .disabled
            ),
            dependencies: .init(
                discoveryClient: .testValue,
                makeRuntime: { config in
                    runtimeConfiguration.withLockedValue { $0 = config }
                    return runtime
                }
            )
        )
        _ = try await server.start()
        let captured = try #require(runtimeConfiguration.withLockedValue { $0 })
        #expect(captured.nativeHostBundleURL == bundleURL)
        #expect(captured.developerDirectoryURL == developerURL)
        try await server.shutdown()
    }

    @Test func unavailableNativeHelperFailsStartupBeforeBindingTheEndpoint() async throws {
        let missingBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-native-host-\(UUID().uuidString).app")
        let server = XcodeMCPProxyServer(configuration: .init(
            bindAddress: .localhost(port: 0), nativeHostBundleURL: missingBundle, discovery: .disabled
        ))
        await #expect(throws: MCPBridgeRuntimeError.self) { _ = try await server.start() }
        let snapshot = await server.snapshot()
        #expect(snapshot.phase == .stopped)
        #expect(snapshot.endpoint == nil)
        #expect(snapshot.hosts.isEmpty)
        try await server.shutdown()
    }

    @Test(arguments: [
        XcodeMCPProxyServerConfiguration.ApprovalPolicy.manual, .automatic,
    ])
    func automaticApprovalFollowsTheServerLifetime(
        policy: XcodeMCPProxyServerConfiguration.ApprovalPolicy
    ) async throws {
        let approver = RecordingPermissionDialogAutoApprover()
        let creations = NIOLockedValueBox(0)
        let server = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .localhost(port: 0), discovery: .disabled, approvalPolicy: policy
            ),
            dependencies: .init(
                discoveryClient: .testValue,
                makeRuntime: { _ in StartupTestRuntime() },
                makeAutoApprover: { _ in
                    creations.withLockedValue { $0 += 1 }
                    return approver
                }
            )
        )
        #expect(creations.withLockedValue { $0 } == 0)
        _ = try await server.start()
        let expected = policy == .automatic ? 1 : 0
        #expect(creations.withLockedValue { $0 } == expected)
        #expect(approver.counts.start == expected)
        try await server.shutdown()
        try await server.shutdown()
        #expect(approver.counts.shutdown == expected)
    }

    @Test func startRejectsRepeatedStartsOnSameServerInstance() async throws {
        let hosts = FakeHostSessionFactory()
        let config = XcodeMCPProxyServerConfiguration(
            bindAddress: .init(host: "127.0.0.1", port: 0),

            maxBodyBytes: 1_048_576,
            requestTimeout: .seconds(300)
        )
        let server = XcodeMCPProxyServer(
            configuration: config,
            dependencies: .init(
                discoveryClient: .testValue,
                makeRuntime: { config in
                    try makeServerTestRuntime(config: config, hosts: hosts)
                }
            )
        )

        let endpoint = try await server.start()
        #expect(endpoint.port > 0)

        await #expect(throws: XcodeMCPProxyServer.LifecycleError.alreadyStarted) {
            _ = try await server.start()
        }

        let waiter = Task {
            try await server.waitUntilShutdown()
        }
        try await server.shutdown()
        try await waiter.value
        try await server.shutdown()
        #expect((await server.snapshot()).phase == .stopped)
    }

    @Test func unstartedServerDoesNotCreateHTTPGateway() async throws {
        let gatewayCreationCount = NIOLockedValueBox(0)
        let server = XcodeMCPProxyServer(
            configuration: .init(discovery: .disabled),
            dependencies: .init(
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

    @Test func startedServerDeinitCancelsTheRuntimeHostProcess() async throws {
        let hosts = FakeHostSessionFactory()
        let approver = RecordingPermissionDialogAutoApprover()
        var server: XcodeMCPProxyServer? = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                discovery: .disabled,
                approvalPolicy: .automatic
            ),
            dependencies: .init(
                discoveryClient: .testValue,
                makeRuntime: { config in
                    try makeServerTestRuntime(config: config, hosts: hosts)
                },
                makeAutoApprover: { _ in approver }
            )
        )

        _ = try await server?.start()
        let host = try await waitWithTimeout("waiting for the default host to start", timeout: .seconds(5)) {
            try await hosts.started.nextValue(at: 0)
        }
        try await waitWithTimeout("waiting for the host handshake", timeout: .seconds(5)) {
            while host.requests("notifications/initialized").isEmpty { await Task.yield() }
        }
        server = nil

        try await host.cancelled.wait(description: "waiting for deinit to cancel the host process")
        #expect(approver.counts.cancel == 1)

        // This test deliberately omits the server's explicit shutdown contract.
        // Deinit guarantees cancellation signaling rather than awaiting teardown.
    }

    @Test func zeroRequestTimeoutFailsBeforeResourceAcquisition() async throws {
        let gatewayCreationCount = NIOLockedValueBox(0)
        let server = XcodeMCPProxyServer(
            configuration: .init(
                requestTimeout: .zero,
                discovery: .disabled
            ),
            dependencies: .init(
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
        let runtime = StartupTestRuntime()
        let server = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                discovery: .file(URL(fileURLWithPath: "/unused/discovery.json"))
            ),
            dependencies: .init(
                discoveryClient: discoveryClient,
                makeRuntime: { _ in runtime }
            )
        )

        await #expect(throws: DiscoveryWriteFailure.expected) {
            _ = try await server.start()
        }
        #expect(runtime.startCount == 0)
        #expect(runtime.shutdownCount == 1)
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
        let runtime = StartupTestRuntime()
        var discovery = DiscoveryClient.testValue
        if discoveryFails {
            discovery.write = { _, _ in throw DiscoveryWriteFailure.expected }
        }
        let server = XcodeMCPProxyServer(
            configuration: .init(),
            dependencies: .init(
                discoveryClient: discovery,
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
        let status = await server.snapshot()
        #expect(status.phase == .stopped)
        #expect(status.endpoint == gateway.endpoint)
    }

    @Test func startupFailurePreservesItsCleanupFailureAndBoundEndpoint() async throws {
        let gateway = ControlledShutdownGateway()
        gateway.allowShutdown.signal()
        let runtime = StartupTestRuntime()
        var discovery = DiscoveryClient.testValue
        discovery.write = { _, _ in throw DiscoveryWriteFailure.expected }
        let server = XcodeMCPProxyServer(
            configuration: .init(),
            dependencies: .init(
                discoveryClient: discovery,
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
        let runtime = StartupTestRuntime()
        let groupShutdownCount = NIOLockedValueBox(0)
        let server = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                discovery: .disabled
            ),
            dependencies: .init(
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
        let runtime = StartupTestRuntime()
        let server = XcodeMCPProxyServer(
            configuration: .init(discovery: .disabled),
            dependencies: .init(
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
        let hosts = FakeHostSessionFactory()
        let config = XcodeMCPProxyServerConfiguration(
            bindAddress: .init(host: "127.0.0.1", port: 0),

            maxBodyBytes: 1_048_576,
            requestTimeout: .seconds(300),
            prewarmToolsList: false
        )
        let server = XcodeMCPProxyServer(
            configuration: config,
            dependencies: .init(
                discoveryClient: .testValue,
                makeRuntime: { config in
                    try makeServerTestRuntime(config: config, hosts: hosts)
                }
            )
        )

        let endpoint = try await server.start()
        let status = try await waitUntilDefaultHostIsHealthy(server)
        #expect(status.phase == .running)
        #expect(status.endpoint == endpoint)
        let host = try #require(status.hosts.first)
        #expect(status.hosts.count == 1)
        #expect(host.identifier == "host-default")
        #expect(host.kind == .headless)
        #expect(host.activeRequestCount == 0)

        let labels = Set(Mirror(reflecting: status).children.compactMap(\.label))
        #expect(labels == ["phase", "endpoint", "hosts", "generatedAt"])

        try await server.shutdown()
    }

    @Test func concurrentShutdownCompletesAllOwnedResourcesExactlyOnce() async throws {
        let hosts = FakeHostSessionFactory()
        let server = XcodeMCPProxyServer(
            configuration: .init(
                bindAddress: .init(host: "127.0.0.1", port: 0),
                discovery: .disabled,
                prewarmToolsList: false
            ),
            dependencies: .init(
                discoveryClient: .testValue,
                makeRuntime: { config in
                    try makeServerTestRuntime(config: config, hosts: hosts)
                }
            )
        )

        let endpoint = try await server.start()
        _ = try await waitUntilDefaultHostIsHealthy(server)
        let host = try #require(hosts.sessions.withLockedValue { $0.first })
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let acceptedClient = try await ClientBootstrap(group: clientGroup)
            .connect(host: endpoint.host, port: endpoint.port)
            .get()

        async let firstShutdown: Void = server.shutdown()
        async let secondShutdown: Void = server.shutdown()
        try await firstShutdown
        try await secondShutdown
        try await acceptedClient.closeFuture.get()

        #expect(hosts.sessions.withLockedValue { $0.count } == 1)
        #expect(host.stopCount == 1)
        let status = await server.snapshot()
        #expect(status.phase == .stopped)
        #expect(status.hosts.map(\.state) == [.stopped])
        #expect(status.hosts.map(\.activeRequestCount) == [0])

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

private final class RecordingPermissionDialogAutoApprover: Sendable, ProxyServerPermissionDialogAutoApprover {
    private let state = NIOLockedValueBox((start: 0, cancel: 0, shutdown: 0))
    var counts: (start: Int, cancel: Int, shutdown: Int) { state.withLockedValue { $0 } }
    func start() { state.withLockedValue { $0.start += 1 } }
    func cancel() { state.withLockedValue { $0.cancel += 1 } }
    func shutdown() async { state.withLockedValue { $0.shutdown += 1 } }
}

private final class StartupTestRuntime: @unchecked Sendable, ProxyRuntimeServing {
    private struct State {
        var startCount = 0
        var shutdownCount = 0
    }

    private let state = NIOLockedValueBox(State())

    var startCount: Int { state.withLockedValue(\.startCount) }
    var shutdownCount: Int { state.withLockedValue(\.shutdownCount) }

    func start() {
        state.withLockedValue { $0.startCount += 1 }
    }

    func cancelForDeinit() {}

    func shutdown() async { state.withLockedValue { $0.shutdownCount += 1 } }

    func openSession(_: ProxySessionID,
                     notify _: @escaping @Sendable (Data) -> Void) throws -> any ProxyRuntimeSession {
        throw ProxyRuntimeUnavailable()
    }

    func snapshot() -> ProxyRuntimeSnapshot {
        ProxyRuntimeSnapshot(generatedAt: Date(), hosts: [])
    }

    func debugSnapshotData(includeSensitivePayloads: Bool) -> Data? {
        nil
    }

    func reset() async {}
}

/// The production runtime over scripted host processes.
private func makeServerTestRuntime(
    config: ProxyRuntimeConfiguration,
    hosts: FakeHostSessionFactory
) throws -> NativeHostBroker {
    let installation = XcodeHostInstallation(developerDirectory: URL(filePath: "/Fixture/Default.app"))
    return try NativeHostBroker(
        configuration: config,
        inventory: XcodeHostInventory(defaultInstallation: installation) { [installation] },
        sessionFactory: { _ in hosts }
    )
}

/// The runtime lists a host once it starts, which `start()` requests without waiting for it.
private func waitUntilDefaultHostIsHealthy(
    _ server: XcodeMCPProxyServer
) async throws -> XcodeMCPProxyServer.Status {
    try await waitWithTimeout("waiting for the default host to run", timeout: .seconds(5)) {
        while true {
            let status = await server.snapshot()
            if status.hosts.map(\.state) == [.running] { return status }
            await Task.yield()
        }
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
