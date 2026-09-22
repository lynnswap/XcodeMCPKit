import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import XcodeMCPProxyRuntime

package struct ProxyHTTPEndpoint: Equatable, Sendable {
    package let host: String
    package let port: Int
}

package protocol ProxyHTTPGatewayServing: Sendable {
    func start() async throws -> ProxyHTTPEndpoint
    func waitUntilShutdown() async throws
    func shutdown() async throws
    func cancelForDeinit()
}

package final class ProxyHTTPGateway: ProxyHTTPGatewayServing, Sendable {
    private final class Resources: @unchecked Sendable {
        let group: EventLoopGroup
        let acceptedChannelTracker: ProxyAcceptedChannelTracker
        let listenChannels: [Channel]
        let childInitializer: ProxyHTTPChildChannelInitializer

        init(
            group: EventLoopGroup,
            acceptedChannelTracker: ProxyAcceptedChannelTracker,
            listenChannels: [Channel],
            childInitializer: ProxyHTTPChildChannelInitializer
        ) {
            self.group = group
            self.acceptedChannelTracker = acceptedChannelTracker
            self.listenChannels = listenChannels
            self.childInitializer = childInitializer
        }

        func signalCancellation() {
            childInitializer.cancel()
            for channel in listenChannels {
                channel.close(mode: .all, promise: nil)
            }
            for channel in acceptedChannelTracker.snapshot() {
                channel.close(mode: .all, promise: nil)
            }
            group.shutdownGracefully { _ in }
        }
    }

    private final class CancellationAuthority: Sendable {
        private let resources = NIOLockedValueBox<Resources?>(nil)

        func install(_ resources: Resources) {
            self.resources.withLockedValue { $0 = resources }
        }

        func clear() {
            resources.withLockedValue { $0 = nil }
        }

        func cancel() {
            resources.withLockedValue { $0 }?.signalCancellation()
        }
    }

    private actor Lifecycle {
        private enum Phase {
            case idle
            case running
            case stopping(Task<Void, any Error>)
            case stopped((any Error)?)
        }

        private let configuration: ProxyHTTPConfiguration
        private let runtime: any ProxyRuntimeServing
        private let logger: Logger
        private let cancellationAuthority: CancellationAuthority
        private let bind: @Sendable (ServerBootstrap, String, Int) async throws -> Channel
        private let shutdownGroup: @Sendable (EventLoopGroup) async throws -> Void
        private var phase: Phase = .idle
        private var resources: Resources?

        init(
            configuration: ProxyHTTPConfiguration,
            runtime: any ProxyRuntimeServing,
            logger: Logger,
            cancellationAuthority: CancellationAuthority,
            bind: @escaping @Sendable (ServerBootstrap, String, Int) async throws -> Channel,
            shutdownGroup: @escaping @Sendable (EventLoopGroup) async throws -> Void
        ) {
            self.configuration = configuration
            self.runtime = runtime
            self.logger = logger
            self.cancellationAuthority = cancellationAuthority
            self.bind = bind
            self.shutdownGroup = shutdownGroup
        }

        func start() async throws -> ProxyHTTPEndpoint {
            guard case .idle = phase else {
                preconditionFailure("HTTP gateway may only be started once")
            }

            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let tracker = ProxyAcceptedChannelTracker()
            let childInitializer = ProxyHTTPChildChannelInitializer(
                config: configuration,
                runtime: runtime,
                logger: logger
            )
            var boundChannels: [Channel] = []

            do {
                var bootstrap = ServerBootstrap(group: group)
                bootstrap = bootstrap.serverChannelOption(ChannelOptions.backlog, value: 256)
                bootstrap = bootstrap.serverChannelOption(
                    ChannelOptions.socketOption(.so_reuseaddr),
                    value: 1
                )
                bootstrap = bootstrap.serverChannelInitializer { channel in
                    channel.pipeline.addHandler(ProxyAcceptedChannelHandler(tracker: tracker))
                }
                bootstrap = bootstrap.childChannelInitializer { channel in
                    childInitializer.initialize(channel)
                }
                bootstrap = bootstrap.childChannelOption(
                    ChannelOptions.socketOption(.so_reuseaddr),
                    value: 1
                )

                boundChannels = try await Self.bindChannels(
                    using: bootstrap,
                    host: configuration.listenHost,
                    port: configuration.listenPort,
                    logger: logger,
                    bind: bind
                )
                guard let first = boundChannels.first else {
                    preconditionFailure("HTTP binding completed without a listening channel")
                }

                let resources = Resources(
                    group: group,
                    acceptedChannelTracker: tracker,
                    listenChannels: boundChannels,
                    childInitializer: childInitializer
                )
                self.resources = resources
                cancellationAuthority.install(resources)
                phase = .running
                return ProxyHTTPEndpoint(
                    host: first.localAddress?.ipAddress ?? configuration.listenHost,
                    port: first.localAddress?.port ?? configuration.listenPort
                )
            } catch {
                let operationError = error
                let failures = await release(
                    Resources(
                        group: group,
                        acceptedChannelTracker: tracker,
                        listenChannels: boundChannels,
                        childInitializer: childInitializer
                    )
                )
                phase = .stopped(Self.cleanupError(failures))
                if let failure = Self.cleanupError(failures, operationError: operationError) {
                    throw failure
                }
                throw operationError
            }
        }

        func waitUntilShutdown() async throws {
            if case .stopping(let task) = phase {
                try await task.value
                return
            }
            if case .stopped(let error) = phase {
                if let error { throw error }
                return
            }
            guard let resources else { return }
            try await EventLoopFuture.andAllSucceed(
                resources.listenChannels.map(\.closeFuture),
                on: resources.group.next()
            ).get()
        }

        func shutdown() async throws {
            if case .stopping(let task) = phase {
                try await task.value
                return
            }
            if case .stopped(let error) = phase {
                if let error { throw error }
                return
            }
            guard case .running = phase, let resources else { return }
            let task = Task {
                let error = Self.cleanupError(await release(resources))
                cancellationAuthority.clear()
                self.resources = nil
                phase = .stopped(error)
                if let error { throw error }
            }
            phase = .stopping(task)
            try await task.value
        }

        private func release(_ resources: Resources) async -> [(String, any Error)] {
            var failures = await Self.closeChannels(resources.listenChannels, role: "listener")
            failures += await Self.closeChannels(
                resources.acceptedChannelTracker.snapshot(),
                role: "accepted"
            )

            await resources.childInitializer.shutdown()
            do {
                try await shutdownGroup(resources.group)
            } catch {
                failures.append(("event loop group", error))
            }
            return failures
        }

        private static func closeChannels(_ channels: [Channel], role: String) async -> [(String, any Error)] {
            // closeFuture only signals closure; the close operation's future carries errors.
            let closing = channels.map { channel in
                let operation = channel.close(mode: .all).flatMapError { error in
                    if case ChannelError.alreadyClosed = error {
                        return channel.closeFuture
                    }
                    return channel.eventLoop.makeFailedFuture(error)
                }
                return (channel, operation)
            }
            var failures: [(String, any Error)] = []
            for (channel, operation) in closing {
                do {
                    try await operation.get()
                    try await channel.closeFuture.get()
                } catch {
                    let address = channel.localAddress.map(String.init(describing:)) ?? "unknown address"
                    failures.append(("\(role) channel \(address)", error))
                }
            }
            return failures
        }

        private static func cleanupError(
            _ failures: [(String, any Error)],
            operationError: (any Error)? = nil
        ) -> NSError? {
            guard !failures.isEmpty else { return nil }
            var causes: [any Error] = []
            var details: [String] = []
            if let operationError {
                causes.append(operationError)
                details.append("HTTP gateway startup failed: \(operationError)")
            }
            for (resource, error) in failures {
                causes.append(error)
                details.append("Failed to release \(resource): \(error)")
            }
            details.append("HTTP resource release may be incomplete.")
            return NSError(
                domain: "XcodeMCPProxyHTTP.Cleanup",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: details.joined(separator: "\n"),
                    NSMultipleUnderlyingErrorsKey: causes,
                ]
            )
        }

        private static func bindChannels(
            using bootstrap: ServerBootstrap,
            host: String,
            port: Int,
            logger: Logger,
            bind: @Sendable (ServerBootstrap, String, Int) async throws -> Channel
        ) async throws -> [Channel] {
            if host != "localhost" {
                return [try await bind(bootstrap, host, port)]
            }

            do {
                let v4 = try await bind(bootstrap, "127.0.0.1", port)
                let v4Port = v4.localAddress?.port ?? port
                guard v4Port > 0 else { return [v4] }
                do {
                    let v6 = try await bind(bootstrap, "::1", v4Port)
                    return [v4, v6]
                } catch {
                    logger.warning(
                        "Failed to bind IPv6 loopback; continuing with IPv4 only",
                        metadata: ["error": "\(error)"]
                    )
                    return [v4]
                }
            } catch {
                logger.warning(
                    "Failed to bind IPv4 loopback; attempting IPv6 only",
                    metadata: ["error": "\(error)"]
                )
                return [try await bind(bootstrap, "::1", port)]
            }
        }
    }

    private let lifecycle: Lifecycle
    private let cancellationAuthority: CancellationAuthority

    package init(
        configuration: ProxyHTTPConfiguration,
        runtime: any ProxyRuntimeServing,
        logger: Logger,
        bind: @escaping @Sendable (ServerBootstrap, String, Int) async throws -> Channel = {
            try await $0.bind(host: $1, port: $2).get()
        },
        shutdownGroup: @escaping @Sendable (EventLoopGroup) async throws -> Void = {
            try await $0.shutdownGracefully()
        }
    ) {
        let cancellationAuthority = CancellationAuthority()
        self.cancellationAuthority = cancellationAuthority
        self.lifecycle = Lifecycle(
            configuration: configuration,
            runtime: runtime,
            logger: logger,
            cancellationAuthority: cancellationAuthority,
            bind: bind,
            shutdownGroup: shutdownGroup
        )
    }

    deinit {
        cancellationAuthority.cancel()
    }

    package func start() async throws -> ProxyHTTPEndpoint {
        try await lifecycle.start()
    }

    package func waitUntilShutdown() async throws {
        try await lifecycle.waitUntilShutdown()
    }

    package func shutdown() async throws {
        try await lifecycle.shutdown()
    }

    package func cancelForDeinit() {
        cancellationAuthority.cancel()
    }
}

private final class ProxyAcceptedChannelTracker: @unchecked Sendable {
    private let channels = NIOLockedValueBox<[ObjectIdentifier: Channel]>([:])

    func register(_ channel: Channel) {
        let id = ObjectIdentifier(channel)
        channels.withLockedValue { $0[id] = channel }
        channel.closeFuture.whenComplete { [weak self] _ in
            _ = self?.channels.withLockedValue { $0.removeValue(forKey: id) }
        }
    }

    func snapshot() -> [Channel] {
        channels.withLockedValue { Array($0.values) }
    }
}

private final class ProxyAcceptedChannelHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Channel

    private let tracker: ProxyAcceptedChannelTracker

    init(tracker: ProxyAcceptedChannelTracker) {
        self.tracker = tracker
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channel = unwrapInboundIn(data)
        tracker.register(channel)
        context.fireChannelRead(data)
    }
}
