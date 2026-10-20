import Foundation
import Testing
import XcodeMCPCore
import XcodeMCPProxyRuntimeContract
import XcodeMCPProxyTestSupport
@testable import XcodeMCPProxyRuntime
@testable import XcodeMCPProxyKit
@testable import XcodeMCPProxyRuntimeTestSupport

@Suite(.serialized, .asyncTestCleanup)
struct ConfigurationRuntimeTests {
    /// Starts the default host and returns the `initialize` parameters it received.
    private func hostInitializeParameters(
        _ configuration: XcodeMCPProxyServerConfiguration,
        beforeStart: (NativeHostBroker) async throws -> Void = { _ in }
    ) async throws -> [String: Any] {
        let factory = FakeHostSessionFactory()
        let installation = XcodeHostInstallation(developerDirectory: URL(filePath: "/Fixture/Default.app"))
        let broker = try NativeHostBroker(
            configuration: configuration.runtimeConfiguration(),
            inventory: XcodeHostInventory(defaultInstallation: installation) { [installation] },
            sessionFactory: { _ in factory })
        #expect(registerAsyncTestCleanup(description: "broker shutdown") { await broker.shutdown() })
        // The broker requires its one event subscriber, which HTTP provides in production,
        // before a session opens.
        let unsubscribe = broker.subscribeToEvents { _ in }
        defer { unsubscribe() }
        try await beforeStart(broker)
        broker.start()
        let host = try await waitWithTimeout("host started", timeout: .seconds(5)) {
            try await factory.started.nextValue(at: 0)
        }
        try await waitWithTimeout("host initialized", timeout: .seconds(5)) {
            while host.requests("initialize").isEmpty { await Task.yield() }
        }
        let request = try #require(host.requests("initialize").first)
        let params = try #require(request["params"])
        return try #require(params.foundationObject as? [String: Any])
    }

    @Test func hostReceivesTheTypedInitializeHandshake() async throws {
        let params = try await hostInitializeParameters(XcodeMCPProxyServerConfiguration(
            requestTimeout: .seconds(5),
            initializeHandshake: .init(clientInfo: .init(name: "custom-proxy"),
                                       capabilities: ["roots": true, "sampling": [:], "elicitation": [:], "experimental": [:]]),
            prewarmToolsList: false))
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        #expect(params["protocolVersion"] as? String == "2025-06-18")
        #expect(clientInfo["name"] as? String == "custom-proxy")
        #expect(clientInfo["version"] as? String == InitializeHandshakeParams.defaultProxyClientVersion())
        // A shared host has no single client to answer its requests.
        #expect(capabilities.keys.sorted() == ["experimental"])
    }

    @Test func hostReceivesTypedHandshakeValuesUnchanged() async throws {
        let params = try await hostInitializeParameters(XcodeMCPProxyServerConfiguration(
            initializeHandshake: .init(
                protocolVersion: "2025-06-18",
                clientInfo: .init(name: "EmbeddingClient", version: "1.2.3"),
                capabilities: ["experimental": [
                    "enabled": true, "limit": 3, "score": 0.5, "tags": ["swift", "xcode"], "optional": .null,
                ]]),
            prewarmToolsList: false))
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

    @Test func hostHandshakeResolvesTheVersionForAConfiguredClientName() async throws {
        let params = try await hostInitializeParameters(XcodeMCPProxyServerConfiguration(
            requestTimeout: .seconds(5), initializeHandshake: .init(clientInfo: .init(name: "Claude")),
            prewarmToolsList: false))
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        #expect(clientInfo["name"] as? String == "Claude")
        #expect(clientInfo["version"] as? String == InitializeHandshakeParams.defaultClientVersion(for: "Claude"))
    }

    @Test func clientInitializeParametersDoNotReachTheHost() async throws {
        let params = try await hostInitializeParameters(XcodeMCPProxyServerConfiguration(
            requestTimeout: .seconds(5), initializeHandshake: .init(clientInfo: .init(name: "configured-proxy")),
            prewarmToolsList: false)) { broker in
            let request = try ProxyRuntimeRequest(json: .object([
                "jsonrpc": .string("2.0"), "id": .number(.int(1)), "method": .string("initialize"),
                "params": .object([
                    "protocolVersion": .string("2099-01-01"), "capabilities": .object([:]),
                    "clientInfo": .object(["name": .string("downstream-client"), "version": .string("9.9")]),
                ]),
            ]), headerSessionExists: false, prefersEventStream: false)
            let session = ProxySessionID(rawValue: "downstream")
            let operation = try #require(broker.beginRequest(request, in: session))
            _ = try await withCheckedThrowingContinuation { continuation in
                operation.whenComplete { continuation.resume(with: $0) }
            }
            broker.clientRequestFinished(session)
        }
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        #expect(params["protocolVersion"] as? String == "2025-06-18")
        #expect(clientInfo["name"] as? String == "configured-proxy")
        #expect(clientInfo["version"] as? String == InitializeHandshakeParams.defaultProxyClientVersion())
    }
}
