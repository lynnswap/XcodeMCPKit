import Foundation
import Testing
@testable import XcodeMCPServerKit

@Suite(.serialized)
struct ServerLauncherIntegrationTests {
    @Test func serverRunnerDryRunUsesEnvironmentDerivedDefaults() async throws {
        let output = CapturedLines()
        let errors = CapturedLines()
        let exitCode = await XcodeMCPServer.run(
            arguments: ["xcode-mcp-server", "--dry-run"],
            environment: [
                "LISTEN": "127.0.0.1:7777",
            ],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 0)
        #expect(errors.snapshot().isEmpty)
        let line = try #require(output.snapshot().first)
        #expect(
            line ==
                "xcode-mcp-server --listen 127.0.0.1:7777"
        )
    }

    @Test func serverLauncherStartsInjectedServer() async throws {
        let restarted = CapturedLines()
        let fakeServer = IntegrationRecordingServer()
        let launcher = makeIntegrationServerLauncher(
            forceRestartExistingServer: { host, port, _ in
                restarted.append("\(host):\(port)")
                return true
            },
            makeServer: { configuration in
                fakeServer.record(config: configuration)
                return fakeServer
            }
        )

        let exitCode = await launcher.run(
            arguments: [
                "xcode-mcp-server",
                "--listen", "127.0.0.1:8766",
                "--request-timeout", "12",
                "--force-restart",
            ],
            environment: [:],
            stdout: { _ in },
            stderr: { _ in }
        )

        #expect(exitCode == 0)
        #expect(restarted.snapshot() == ["127.0.0.1:8766"])
        let config = try #require(fakeServer.recordedConfig())
        #expect(config.bindAddress.host == "127.0.0.1")
        #expect(config.bindAddress.port == 8766)
        #expect(config.requestTimeout == .seconds(12))
        #expect(fakeServer.startCount() == 1)
        #expect(fakeServer.waitCount() == 1)
    }
}

private func makeIntegrationServerLauncher(
    forceRestartExistingServer: @escaping (_ host: String, _ port: Int, _ stderr: (String) -> Void) -> Bool = {
        _, _, _ in false
    },
    makeServer: @escaping (XcodeMCPServerConfiguration) ->
        any XcodeMCPServer.LaunchServer = { _ in
        IntegrationRecordingServer()
    }
) -> XcodeMCPServer.Launcher {
    XcodeMCPServer.Launcher(
        dependencies: .init(
            makeServer: makeServer,
            isAddressAlreadyInUse: { _ in false },
            forceRestartExistingServer: forceRestartExistingServer,
            detectExistingServerProcessIDs: { _, _ in [] }
        )
    )
}

private final class IntegrationRecordingServer: @unchecked Sendable, XcodeMCPServer.LaunchServer {
    private let lock = NSLock()
    private var config: XcodeMCPServerConfiguration?
    private var started = 0
    private var waited = 0

    func record(config: XcodeMCPServerConfiguration) {
        withLock {
            self.config = config
        }
    }

    func start() async throws -> XcodeMCPServer.Endpoint {
        withLock {
            started += 1
        }
        return XcodeMCPServer.Endpoint(host: "127.0.0.1", port: 8766)
    }

    func waitUntilShutdown() async throws {
        incrementWaitCount()
    }

    func shutdown() async throws {}

    func recordedConfig() -> XcodeMCPServerConfiguration? {
        withLock { config }
    }

    func startCount() -> Int {
        withLock { started }
    }

    func waitCount() -> Int {
        withLock { waited }
    }

    private func incrementWaitCount() {
        withLock {
            waited += 1
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
