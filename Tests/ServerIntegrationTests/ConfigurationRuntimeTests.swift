import Foundation
import Testing
import XcodeMCPCore
import XcodeMCPServerRuntimeContract
import XcodeMCPServerTestSupport
@testable import XcodeMCPServerRuntime
@testable import XcodeMCPServerKit
@testable import XcodeMCPServerRuntimeTestSupport

@Suite(.serialized, .asyncTestCleanup)
struct ConfigurationRuntimeTests {
    /// Starts the default host and returns the `initialize` parameters it received.
    private func hostInitializeParameters(
        _ configuration: XcodeMCPServerConfiguration,
        beforeStart: (NativeHostBroker) async throws -> Void = { _ in }
    ) async throws -> [String: Any] {
        let factory = FakeHostSessionFactory()
        let installation = XcodeHostInstallation(developerDirectory: URL(filePath: "/Fixture/Default.app"))
        let broker = try NativeHostBroker(
            configuration: configuration.runtimeConfiguration(),
            inventory: XcodeHostInventory(defaultInstallation: installation) { [installation] },
            sessionFactory: { _ in factory })
        #expect(registerAsyncTestCleanup(description: "broker shutdown") { await broker.shutdown() })
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

    @Test func hostReceivesTheServerHandshakeRatherThanTheClientParameters() async throws {
        let params = try await hostInitializeParameters(XcodeMCPServerConfiguration(
            requestTimeout: .seconds(5), prewarmToolsList: false)) { broker in
            let request = try ServerRuntimeRequest(json: .object([
                "jsonrpc": .string("2.0"), "id": .number(.int(1)), "method": .string("initialize"),
                "params": .object([
                    "protocolVersion": .string("2099-01-01"),
                    "capabilities": .object(["roots": .object([:]), "sampling": .object([:])]),
                    "clientInfo": .object(["name": .string("downstream-client"), "version": .string("9.9")]),
                ]),
            ]))
            let session = try broker.openSession(ServerSessionID(rawValue: "downstream")) { _ in }
            _ = await session.receive(request).reply
            session.close()
        }
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        #expect(params["protocolVersion"] as? String == "2025-06-18")
        // Approval automation matches GUI Xcode connection dialogs by this name.
        #expect(clientInfo["name"] as? String == "XcodeMCPKit")
        // A shared host has no single client to answer its requests.
        #expect(capabilities.isEmpty)
    }
}
