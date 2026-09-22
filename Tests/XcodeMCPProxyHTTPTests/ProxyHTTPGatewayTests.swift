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

    @Test(arguments: [false, true])
    func startupFailurePreservesGroupCleanupFailure(cleanupFails: Bool) async throws {
        let recorded = GatewayCleanupRecorder()
        defer { recorded.finishCleanup() }
        let gateway = ProxyHTTPGateway(
            configuration: .init(listenHost: "127.0.0.1", listenPort: 0, maxBodyBytes: 1_048_576),
            runtime: GatewayTestRuntime(),
            logger: Logger(label: "ProxyHTTPGatewayTests"),
            bind: { _, _, _ in throw GatewayFailure.bind },
            shutdownGroup: { group in
                recorded.record(group: group)
                if cleanupFails { throw GatewayFailure.group }
                try await group.shutdownGracefully()
            }
        )

        let error = try await #require(throws: (any Error).self) { _ = try await gateway.start() }

        if cleanupFails {
            #expect((error as NSError).underlyingErrors.compactMap { $0 as? GatewayFailure } == [.bind, .group])
            #expect((error as NSError).localizedDescription.contains("event loop group"))
            let repeated = try await #require(throws: NSError.self) { try await gateway.shutdown() }
            #expect(repeated.underlyingErrors.compactMap { $0 as? GatewayFailure } == [.group])
        } else {
            #expect(error as? GatewayFailure == .bind)
            try await gateway.shutdown()
        }
        #expect(recorded.groupShutdownCount == 1)
    }

    @Test func shutdownAttemptsEveryResourceAndReportsAllFailures() async throws {
        let recorded = GatewayCleanupRecorder()
        defer { recorded.finishCleanup() }
        let gateway = ProxyHTTPGateway(
            configuration: .init(listenHost: "127.0.0.1", listenPort: 0, maxBodyBytes: 1_048_576),
            runtime: GatewayTestRuntime(),
            logger: Logger(label: "ProxyHTTPGatewayTests"),
            bind: { bootstrap, host, port in
                let listener = try await bootstrap.bind(host: host, port: port).get()
                let accepted = listener.eventLoop.makePromise(of: Channel.self)
                try await listener.pipeline.addHandlers(
                    RejectFirstClose(failure: .listener),
                    RecordAcceptedChannel(accepted: accepted)
                ).get()
                recorded.record(listener: listener, accepted: accepted.futureResult)
                return listener
            },
            shutdownGroup: { group in
                recorded.record(group: group)
                throw GatewayFailure.group
            }
        )
        let endpoint = try await gateway.start()
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { clientGroup.shutdownGracefully { _ in } }
        let client = try await ClientBootstrap(group: clientGroup)
            .connect(host: endpoint.host, port: endpoint.port).get()
        defer { client.close(promise: nil) }
        let acceptedFuture = try #require(recorded.accepted)
        let accepted = try await acceptedFuture.get()

        let error = try await #require(throws: NSError.self) { try await gateway.shutdown() }

        #expect(error.underlyingErrors.compactMap { $0 as? GatewayFailure } == [.listener, .accepted, .group])
        #expect(error.localizedDescription.contains("listener channel"))
        #expect(error.localizedDescription.contains("accepted channel"))
        #expect(error.localizedDescription.contains("event loop group"))
        #expect(error.localizedDescription.contains("release may be incomplete"))
        #expect(recorded.listener?.isActive == true)
        #expect(accepted.isActive)
        #expect(recorded.groupShutdownCount == 1)
        let repeated = try await #require(throws: NSError.self) { try await gateway.shutdown() }
        #expect(repeated.underlyingErrors.compactMap { $0 as? GatewayFailure } == [.listener, .accepted, .group])
        let waiter = try await #require(throws: NSError.self) { try await gateway.waitUntilShutdown() }
        #expect(waiter.underlyingErrors.compactMap { $0 as? GatewayFailure } == [.listener, .accepted, .group])
        #expect(recorded.groupShutdownCount == 1)
        // The injected failures leave real channels open; the fixture owns the final cleanup.
        try await recorded.listener?.close().get()
        try await accepted.close().get()
        try await client.closeFuture.get()
    }
}

private enum GatewayFailure: Error {
    case bind, listener, accepted, group
}

private final class GatewayCleanupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var group: EventLoopGroup?
    private var groupShutdowns = 0
    private var listeningChannel: Channel?
    private var acceptedFuture: EventLoopFuture<Channel>?

    var groupShutdownCount: Int { lock.withLock { groupShutdowns } }
    var listener: Channel? { lock.withLock { listeningChannel } }
    var accepted: EventLoopFuture<Channel>? { lock.withLock { acceptedFuture } }

    func record(group: EventLoopGroup) {
        lock.withLock {
            self.group = group
            groupShutdowns += 1
        }
    }

    func record(listener: Channel, accepted: EventLoopFuture<Channel>) {
        lock.withLock {
            listeningChannel = listener
            acceptedFuture = accepted
        }
    }

    func finishCleanup() {
        lock.withLock { group }?.shutdownGracefully { _ in }
    }
}

private final class RejectFirstClose: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = Never
    private let failure: GatewayFailure
    private var didReject = false

    init(failure: GatewayFailure) { self.failure = failure }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        if didReject {
            context.close(mode: mode, promise: promise)
        } else {
            didReject = true
            promise?.fail(failure)
        }
    }
}

private final class RecordAcceptedChannel: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Channel
    private let accepted: EventLoopPromise<Channel>

    init(accepted: EventLoopPromise<Channel>) { self.accepted = accepted }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channel = unwrapInboundIn(data)
        do {
            try channel.pipeline.syncOperations.addHandler(RejectFirstClose(failure: .accepted))
            context.fireChannelRead(data)
            accepted.succeed(channel)
        } catch {
            accepted.fail(error)
            channel.close(promise: nil)
        }
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
