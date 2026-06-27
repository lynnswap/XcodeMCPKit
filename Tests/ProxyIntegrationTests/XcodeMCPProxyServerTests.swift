import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPRuntime
import Testing
import XcodeMCPTestSupport

@testable import XcodeMCPProxyKit

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

        let config = XcodeMCPProxyServer.Configuration(serverProxyConfig: proxyConfig)

        #expect(config.listenHost == "127.0.0.1")
        #expect(config.listenPort == 9876)
        #expect(config.upstreamCommand == "/usr/bin/xcrun")
        #expect(config.upstreamArguments == ["--sdk", "macosx", "mcpbridge"])
        #expect(config.upstreamProcessCount == 3)
        #expect(config.upstreamSessionID == "session-1")
        #expect(config.maxBodyBytes == 2048)
        #expect(config.requestTimeout == 12)
        #expect(config.configPath == configURL.path)
        #expect(config.discoveryFileURL == discoveryURL)
        #expect(config.prewarmToolsList == false)
        #expect(config.autoApproveXcodeDialog == true)
        #expect(config.refreshCodeIssuesMode == .upstream)
    }

    @Test func existingServerControllerHostMatchingHandlesLoopbackAndWildcard() throws {
        #expect(
            ExistingProxyServerProcessController.hostMatches(
                requestedHost: "localhost",
                actualHost: "127.0.0.1"
            )
        )
        #expect(
            ExistingProxyServerProcessController.hostMatches(
                requestedHost: "::",
                actualHost: "127.0.0.1"
            )
        )
        #expect(
            ExistingProxyServerProcessController.hostMatches(
                requestedHost: "127.0.0.1",
                actualHost: "::1"
            ) == false
        )
    }

    @Test func existingServerControllerExtractsListeningPIDsFromLsofFieldOutputForLocalhost() throws {
        let output = """
        p51731
        f9
        n127.0.0.1:8765
        f13
        n[::1]:8765
        p60000
        f8
        n10.0.0.5:8765
        """

        #expect(
            ExistingProxyServerProcessController.listeningProcessIDs(
                fromLsofOutput: output,
                matchingHost: "localhost"
            ) == [51731]
        )
    }

    @Test func existingServerControllerExtractsListeningPIDsFromLsofFieldOutputSkipsNonMatchingHosts() throws {
        let output = """
        p51731
        f9
        n[::1]:8765
        p60000
        f8
        n10.0.0.5:8765
        """

        #expect(
            ExistingProxyServerProcessController.listeningProcessIDs(
                fromLsofOutput: output,
                matchingHost: "127.0.0.1"
            )
            .isEmpty
        )
    }

    @Test func existingServerControllerExtractsListeningPIDsFromLegacyTCPNames() throws {
        let output = """
        p111
        f9
        nTCP 127.0.0.1:8765 (LISTEN)
        p222
        f13
        nTCP [::1]:8765 (LISTEN)
        p333
        f8
        nTCP 10.0.0.5:8765 (LISTEN)
        """

        #expect(
            ExistingProxyServerProcessController.listeningProcessIDs(
                fromLsofOutput: output,
                matchingHost: "localhost"
            ) == [111, 222]
        )
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
            upstreamCommand: "xcrun",
            upstreamArgs: ["mcpbridge"],
            maxBodyBytes: 1_048_576,
            requestTimeout: 300,
            autoApproveXcodeDialog: true
        )
        let server = XcodeMCPProxyServer(
            proxyConfig: config,
            dependencies: .init(
                makeAutoApprover: { autoApprover },
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
            _ = try server.start()
            Issue.record("expected bind failure")
        } catch {}

        #expect(autoApprover.startCount == 0)
        #expect(upstream.startCount == 0)

        try? await server.shutdown()
        try? await blocker.close().get()
        await shutdown(blockerGroup)
    }

    @Test func startRejectsRepeatedStartsOnSameServerInstance() async throws {
        let autoApprover = RecordingAutoApprover()
        let upstream = RecordingUpstreamSlot()
        let config = ProxyConfig(
            listenHost: "127.0.0.1",
            listenPort: 0,
            upstreamCommand: "xcrun",
            upstreamArgs: ["mcpbridge"],
            maxBodyBytes: 1_048_576,
            requestTimeout: 300,
            autoApproveXcodeDialog: true
        )
        let server = XcodeMCPProxyServer(
            proxyConfig: config,
            dependencies: .init(
                makeAutoApprover: { autoApprover },
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

        let endpoint = try server.start()
        #expect(endpoint.port > 0)

        #expect(throws: XcodeMCPProxyServer.LifecycleError.alreadyStarted) {
            _ = try server.start()
        }
        #expect(throws: XcodeMCPProxyServer.LifecycleError.alreadyStarted) {
            _ = try server.startAndWriteDiscovery()
        }
        #expect(autoApprover.startCount == 1)

        try await server.shutdown()
    }
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

private final class RecordingUpstreamSlot: @unchecked Sendable, UpstreamSlotControlling {
    private let startCountBox = NIOLockedValueBox(0)
    private let eventStream: AsyncStream<Upstream.Event>

    var startCount: Int {
        startCountBox.withLockedValue { $0 }
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

    func stop() async {}

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
