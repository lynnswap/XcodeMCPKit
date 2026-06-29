import Foundation
import Testing
@testable import XcodeMCPProxyKit

@Suite(.serialized)
struct ServerLauncherIntegrationTests {
    @Test func serverRunnerDryRunUsesEnvironmentDerivedDefaults() async throws {
        let output = CapturedLines()
        let errors = CapturedLines()

        let exitCode = await XcodeMCPProxyServer.run(
            arguments: ["xcode-mcp-proxy-server", "--dry-run"],
            environment: [
                "LISTEN": "127.0.0.1:7777",
                "MCP_XCODE_CONFIG": "/tmp/proxy-config.toml",
            ],
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )

        #expect(exitCode == 0)
        #expect(errors.snapshot().isEmpty)
        let line = try #require(output.snapshot().first)
        #expect(line == "xcode-mcp-proxy-server --listen 127.0.0.1:7777 --config /tmp/proxy-config.toml")
    }

    @Test func serverLauncherStartsInjectedProxyServer() async throws {
        let restarted = CapturedLines()
        let fakeServer = IntegrationRecordingProxyServer()
        let launcher = makeIntegrationServerLauncher(
            forceRestartExistingServer: { host, port, _ in
                restarted.append("\(host):\(port)")
                return true
            },
            makeServer: { config in
                fakeServer.record(config: config)
                return fakeServer
            }
        )

        let exitCode = await launcher.run(
            arguments: [
                "xcode-mcp-proxy-server",
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
        #expect(config.limits.requestTimeout == 12)
        #expect(fakeServer.startCount() == 1)
        #expect(fakeServer.waitCount() == 1)
    }
}

private func makeIntegrationServerLauncher(
    forceRestartExistingServer: @escaping (_ host: String, _ port: Int, _ stderr: (String) -> Void) -> Bool = {
        _, _, _ in false
    },
    makeServer: @escaping (XcodeMCPProxyServerConfiguration) -> any XcodeMCPProxyServer.LaunchServer = { _ in
        IntegrationRecordingProxyServer()
    }
) -> XcodeMCPProxyServer.Launcher {
    XcodeMCPProxyServer.Launcher(
        dependencies: .init(
            makeServer: makeServer,
            isAddressAlreadyInUse: { _ in false },
            forceRestartExistingServer: forceRestartExistingServer,
            detectExistingServerProcessIDs: { _, _ in [] }
        )
    )
}

private final class IntegrationRecordingProxyServer: XcodeMCPProxyServer.LaunchServer {
    private let lock = NSLock()
    private var config: XcodeMCPProxyServerConfiguration?
    private var started = 0
    private var waited = 0

    func record(config: XcodeMCPProxyServerConfiguration) {
        withLock {
            self.config = config
        }
    }

    func startAndWriteDiscovery() throws -> XcodeMCPProxyServer.Endpoint {
        withLock {
            started += 1
        }
        return XcodeMCPProxyServer.Endpoint(host: "127.0.0.1", port: 8766)
    }

    func wait() async throws {
        incrementWaitCount()
    }

    func recordedConfig() -> XcodeMCPProxyServerConfiguration? {
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
