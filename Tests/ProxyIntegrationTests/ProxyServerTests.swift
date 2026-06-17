import ProxyCore
import Foundation
import NIO
import NIOConcurrencyHelpers
import ProxySession
import Testing
import XcodeMCPTestSupport

@testable import XcodeMCPProxy

struct ProxyServerTests {
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

        let candidates = ProxyServer.additionalPermissionDialogExecutableCandidates(config: config)

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

        let candidates = ProxyServer.additionalPermissionDialogExecutableCandidates(config: config)

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

        let candidates = ProxyServer.additionalPermissionDialogExecutableCandidates(config: config)

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
        let server = ProxyServer(
            config: config,
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
