import Foundation
import Logging
import NIO
import Testing

@testable import XcodeMCPProxyHTTP
import XcodeMCPProxyRuntime

struct ProxyHTTPGatewayTests {
    @Test func shutdownClosesListenerAndReleasesPort() async throws {
        let gateway = ProxyHTTPGateway(
            configuration: ProxyHTTPConfiguration(
                listenHost: "127.0.0.1",
                listenPort: 0,
                maxBodyBytes: 1_048_576
            ),
            runtime: GatewayTestRuntime(),
            logger: Logger(label: "ProxyHTTPGatewayTests")
        )
        let endpoint = try await gateway.start()
        #expect(endpoint.port > 0)

        let listenerClosed = Task {
            try await gateway.waitUntilShutdown()
        }
        try await gateway.shutdown()
        try await listenerClosed.value

        let probeGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let rebound = try await ServerBootstrap(group: probeGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: endpoint.host, port: endpoint.port)
            .get()
        try await rebound.close().get()
        try await probeGroup.shutdownGracefully()
    }
}

private final class GatewayTestRuntime: ProxyRuntimeServing, Sendable {
    func start() {}
    func cancelForDeinit() {}
    func shutdown() async {}

    func subscribeToEvents(
        _ receive: @escaping @Sendable (ProxyRuntimeEvent) -> Void
    ) -> @Sendable () -> Void {
        {}
    }

    func beginRequest(
        _: ProxyRuntimeRequest,
        in _: ProxySessionID?
    ) -> (any ProxyRuntimeRequestOperating)? {
        fatalError("gateway lifecycle test does not admit requests")
    }

    func clientRequestFinished(_: ProxySessionID) {}

    func sessionState(_: ProxySessionID) -> ProxyRuntimeSessionState {
        .missing
    }

    func clientEventStreamOpened(_: ProxySessionID) -> Bool { false }

    func clientEventStreamClosed(_: ProxySessionID) {}

    func expireInactiveSessions(inactiveFor _: TimeAmount) {}

    func removeSession(_: ProxySessionID) {}

    func snapshot() -> ProxyRuntimeSnapshot {
        fatalError("gateway lifecycle test does not read runtime state")
    }

    func inventorySnapshot() -> ProxyRuntimeInventorySnapshot {
        fatalError("gateway lifecycle test does not read process inventory")
    }

    func debugSnapshotData(includeSensitivePayloads _: Bool) -> Data? {
        nil
    }

    func reset() async {}
}
