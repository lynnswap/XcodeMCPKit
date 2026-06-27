import Foundation
import Testing
import XcodeMCPProxyKit

@Suite(.serialized)
struct ServerCommandIntegrationTests {
    @Test func serverCommandDryRunUsesEnvironmentDerivedDefaults() async throws {
        let output = CapturedLines()
        let command = makeIntegrationServerCommand(
            stdout: { output.append($0) },
            stderr: { output.append($0) }
        )

        let exitCode = await command.run(
            args: ["xcode-mcp-proxy-server", "--dry-run"],
            environment: [
                "LISTEN": "127.0.0.1:7777",
                "MCP_XCODE_CONFIG": "/tmp/proxy-config.toml",
            ]
        )

        #expect(exitCode == 0)
        let line = try #require(output.snapshot().first)
        #expect(line == "xcode-mcp-proxy-server --listen 127.0.0.1:7777 --config /tmp/proxy-config.toml")
    }

    @Test func serverCommandStartsInjectedProxyServer() async throws {
        let restarted = CapturedLines()
        let fakeServer = IntegrationRecordingProxyServer()
        let command = makeIntegrationServerCommand(
            forceRestartExistingServer: { host, port, _ in
                restarted.append("\(host):\(port)")
                return true
            },
            makeServer: { config in
                fakeServer.record(config: config)
                return fakeServer
            }
        )

        let exitCode = await command.run(
            args: [
                "xcode-mcp-proxy-server",
                "--listen", "127.0.0.1:8766",
                "--request-timeout", "12",
                "--force-restart",
            ],
            environment: [:]
        )

        #expect(exitCode == 0)
        #expect(restarted.snapshot() == ["127.0.0.1:8766"])
        let config = try #require(fakeServer.recordedConfig())
        #expect(config.bind.host == "127.0.0.1")
        #expect(config.bind.port == 8766)
        #expect(config.limits.requestTimeout == 12)
        #expect(fakeServer.startCount() == 1)
        #expect(fakeServer.waitCount() == 1)
    }
}

private func makeIntegrationServerCommand(
    stdout: @escaping (String) -> Void = { _ in },
    stderr: @escaping (String) -> Void = { _ in },
    forceRestartExistingServer: @escaping (_ host: String, _ port: Int, _ stderr: (String) -> Void) -> Bool = {
        _, _, _ in false
    },
    makeServer: @escaping (XcodeMCPProxyServer.Configuration) -> any XcodeMCPProxyServer.LaunchServer = { _ in
        IntegrationRecordingProxyServer()
    }
) -> XcodeMCPProxyServerCommand {
    let launcher = XcodeMCPProxyServer.Launcher(
        dependencies: .init(
            makeServer: makeServer,
            isAddressAlreadyInUse: { _ in false },
            forceRestartExistingServer: forceRestartExistingServer,
            detectExistingServerProcessIDs: { _, _ in [] }
        )
    )
    return XcodeMCPProxyServerCommand(
        dependencies: .init(
            bootstrapLogging: { _ in },
            stdout: stdout,
            stderr: stderr,
            launcher: launcher
        )
    )
}

private final class IntegrationRecordingProxyServer: XcodeMCPProxyServer.LaunchServer {
    private let lock = NSLock()
    private var config: XcodeMCPProxyServer.Configuration?
    private var started = 0
    private var waited = 0

    func record(config: XcodeMCPProxyServer.Configuration) {
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

    func recordedConfig() -> XcodeMCPProxyServer.Configuration? {
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
