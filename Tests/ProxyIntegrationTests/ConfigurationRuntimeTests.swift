import Foundation
import Testing
import XcodeMCPCore
import XcodeMCPProxyTestSupport
@testable import XcodeMCPProxyRuntime
@testable import XcodeMCPProxyKit
@testable import XcodeMCPProxyRuntimeTestSupport

@Suite(.serialized, .asyncTestCleanup)
struct ConfigurationRuntimeTests {
    @Test func sessionManagerUsesTypedInitializeHandshake() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = try XcodeMCPProxyServerConfiguration(
            requestTimeout: .seconds(5),
            initializeHandshake: .init(clientInfo: .init(name: "custom-proxy"), capabilities: ["roots": true]),
            prewarmToolsList: false
        ).runtimeConfiguration()
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

    @Test func sessionManagerPreservesTypedHandshakeValues() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let upstream = TestUpstreamClient()
        let config = try XcodeMCPProxyServerConfiguration(
            initializeHandshake: .init(
                protocolVersion: "2025-06-18",
                clientInfo: .init(name: "EmbeddingClient", version: "1.2.3"),
                capabilities: ["experimental": [
                    "enabled": true,
                    "limit": 3,
                    "score": 0.5,
                    "tags": ["swift", "xcode"],
                    "optional": .null,
                ]]
            ),
            prewarmToolsList: false
        ).runtimeConfiguration()
        let manager = RuntimeCoordinator(config: config, eventLoop: group.next(), upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let request = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let params = try #require(request["params"] as? [String: Any])
        let client = try #require(params["clientInfo"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        let experimental = try #require(capabilities["experimental"] as? [String: Any])
        #expect(client["name"] as? String == "EmbeddingClient")
        #expect(client["version"] as? String == "1.2.3")
        #expect(experimental["enabled"] as? Bool == true)
        #expect(experimental["limit"] as? Int == 3)
        #expect(experimental["score"] as? Double == 0.5)
        #expect(experimental["tags"] as? [String] == ["swift", "xcode"])
        #expect(experimental["optional"] is NSNull)
    }

    @Test func sessionManagerAutoResolvesInitializeVersionFromConfiguredClientName() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = try XcodeMCPProxyServerConfiguration(
            requestTimeout: .seconds(5),
            initializeHandshake: .init(clientInfo: .init(name: "Claude")),
            prewarmToolsList: false
        ).runtimeConfiguration()
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let object = try JSONSerialization.jsonObject(with: sent, options: []) as? [String: Any]
        let params = try #require(object?["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])

        #expect(clientInfo["name"] as? String == "Claude")
        #expect(clientInfo["version"] as? String == InitializeHandshakeParams.defaultClientVersion(for: "Claude"))
    }

    @Test func sessionManagerUsesConfiguredInitializeParamsAfterEagerInitTimesOut()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let timeoutClock = TestClock()
        let initializeCleanupCompleted = TestSignal()
        let config = try XcodeMCPProxyServerConfiguration(
            requestTimeout: .milliseconds(100),
            initializeHandshake: .init(clientInfo: .init(name: "configured-proxy")),
            prewarmToolsList: false
        ).runtimeConfiguration()
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
