import Foundation
import Testing
import ProxyCLICommon
import ProxyServerCLI
import XcodeMCPProxyKit

@Suite(.serialized)
struct ServerCommandIntegrationTests {
    @Test func serverCommandDryRunUsesEnvironmentDerivedDefaults() async throws {
        let output = CapturedLines()
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { output.append($0) },
                stderr: { output.append($0) },
                terminateExistingServer: { _, _ in false },
                makeServer: { _ in IntegrationRecordingProxyServer() },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
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
        let command = XcodeMCPProxyServerCommand(
            dependencies: .init(
                bootstrapLogging: { _ in },
                stdout: { _ in },
                stderr: { _ in },
                terminateExistingServer: { host, port in
                    restarted.append("\(host):\(port)")
                    return true
                },
                makeServer: { config in
                    fakeServer.record(config: config)
                    return fakeServer
                },
                isAddressAlreadyInUse: { _ in false },
                detectExistingProxyServerPIDs: { _, _ in [] }
            )
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
        #expect(config.listenHost == "127.0.0.1")
        #expect(config.listenPort == 8766)
        #expect(config.requestTimeout == 12)
        #expect(fakeServer.startCount() == 1)
        #expect(fakeServer.waitCount() == 1)
    }
}

private final class IntegrationRecordingProxyServer: ProxyServerCommandServer {
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
