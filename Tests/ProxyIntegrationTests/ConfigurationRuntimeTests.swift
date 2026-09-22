import Foundation
import Testing
import XcodeMCPCore
import XcodeMCPProxyTestSupport
@testable import XcodeMCPProxyRuntime
@testable import XcodeMCPProxyKit
@testable import XcodeMCPProxyRuntimeTestSupport

@Suite(.serialized, .asyncTestCleanup)
struct ConfigurationRuntimeTests {
    @Test func sessionManagerUsesInitializeParamsOverrideFromConfigFile() async throws {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake]
            clientName = "custom-proxy"

            [upstream_handshake.capabilities]
            roots = true
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = try ProxyConfig.resolving(
            XcodeMCPProxyServerConfiguration(
                requestTimeout: .seconds(5),
                configurationFileURL: URL(fileURLWithPath: configPath),
                featurePolicy: .init(prewarmToolsList: false)
            )
        ).runtimeConfiguration(xcodeMode: .gui)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])

        #expect(params["protocolVersion"] as? String == "2025-06-18")
        #expect(clientInfo["name"] as? String == "custom-proxy")
        #expect(clientInfo["version"] as? String == InitializeHandshakeParams.defaultProxyClientVersion())
        #expect(capabilities["roots"] as? Bool == true)
    }

    @Test func sessionManagerAppliesPublicInitializeHandshakeOverrideAfterConfigFile()
        async throws
    {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake]
            protocolVersion = "2025-06-18"
            clientName = "file-proxy"
            clientVersion = "file-version"

            [upstream_handshake.capabilities]
            roots = true
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let publicConfiguration = XcodeMCPProxyServerConfiguration(
            configurationFileURL: URL(fileURLWithPath: configPath),
            initializeHandshake: .init(
                clientInfo: .init(name: "typed-proxy"),
                capabilities: [
                    "sampling": [
                        "enabled": true
                    ]
                ]
            ),
            featurePolicy: .init(prewarmToolsList: false)
        )
        let config = try ProxyConfig.resolving(publicConfiguration).runtimeConfiguration(
            xcodeMode: .gui
        )

        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        let sampling = try #require(capabilities["sampling"] as? [String: Any])

        #expect(params["protocolVersion"] as? String == "2025-06-18")
        #expect(clientInfo["name"] as? String == "typed-proxy")
        #expect(clientInfo["version"] as? String == "file-version")
        #expect(capabilities["roots"] == nil)
        #expect(sampling["enabled"] as? Bool == true)
    }

    @Test func sessionManagerAutoResolvesInitializeVersionFromConfiguredClientName() async throws {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake]
            clientName = "Claude"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = try ProxyConfig.resolving(
            XcodeMCPProxyServerConfiguration(
                requestTimeout: .seconds(5),
                configurationFileURL: URL(fileURLWithPath: configPath),
                featurePolicy: .init(prewarmToolsList: false)
            )
        ).runtimeConfiguration(xcodeMode: .gui)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])

        #expect(clientInfo["name"] as? String == "Claude")
        #expect(clientInfo["version"] as? String == InitializeHandshakeParams.defaultClientVersion(for: "Claude"))
    }

    @Test func strictConfigLoaderRejectsInvalidInitializeConfiguration() async throws {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake
            protocolVersion = "broken"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        #expect(throws: ProxyConfig.File.LoadError.self) {
            _ = try ProxyConfig.File.Loader.loadStrict(
                configURL: URL(fileURLWithPath: configPath)
            )
        }
    }

    @Test func sessionManagerUsesConfiguredInitializeParamsAfterEagerInitTimesOut()
        async throws
    {
        let configPath = try makeTempProxyConfigFile(
            """
            [upstream_handshake]
            clientName = "configured-proxy"
            """
        )
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let timeoutClock = TestClock()
        let initializeCleanupCompleted = TestSignal()
        let config = try ProxyConfig.resolving(
            XcodeMCPProxyServerConfiguration(
                requestTimeout: .milliseconds(100),
                configurationFileURL: URL(fileURLWithPath: configPath),
                featurePolicy: .init(prewarmToolsList: false)
            )
        ).runtimeConfiguration(xcodeMode: .gui)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            scheduleRuntimeTimeout: makeDeterministicRuntimeTimeoutScheduler(clock: timeoutClock),
            testHooks: RuntimeCoordinatorTestHooks(
                primaryInitializeFailureCleanupCompleted: { _ in
                    initializeCleanupCompleted.signal()
                }
            )
        )
        defer { manager.shutdownAndWait() }

        _ = try await sentValue(from: upstream, at: 0, timeout: .seconds(5))
        try await waitForSuspendedSleepers(on: timeoutClock)
        timeoutClock.advance(by: .milliseconds(100))
        try await initializeCleanupCompleted.wait(
            description: "waiting for eager initialize timeout cleanup"
        )
        #expect(manager.testStateSnapshot().initInFlight == false)

        _ = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2099-01-01",
                    "capabilities": [String: Any](),
                    "clientInfo": [
                        "name": "downstream-client",
                        "version": "9.9",
                    ],
                ],
            ],
            on: eventLoop
        )

        _ = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))
        let resent = try #require(await upstream.sentValue(at: 1))
        let object = try JSONSerialization.jsonObject(with: resent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])

        let snapshot = manager.testStateSnapshot()
        #expect(snapshot.hasInitResult == false)
        #expect(params["protocolVersion"] as? String == "2025-06-18")
        #expect(clientInfo["name"] as? String == "configured-proxy")
        #expect(clientInfo["version"] as? String == InitializeHandshakeParams.defaultProxyClientVersion())
    }

}

private func makeTempProxyConfigFile(_ contents: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("proxy-config.toml")
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL.path
}
