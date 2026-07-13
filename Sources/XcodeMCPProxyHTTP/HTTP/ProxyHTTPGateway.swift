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
            case stopped
        }

        private let configuration: ProxyHTTPConfiguration
        private let runtime: any ProxyRuntimeServing
        private let logger: Logger
        private let cancellationAuthority: CancellationAuthority
        private var phase: Phase = .idle
        private var resources: Resources?

        init(
            configuration: ProxyHTTPConfiguration,
            runtime: any ProxyRuntimeServing,
            logger: Logger,
            cancellationAuthority: CancellationAuthority
        ) {
            self.configuration = configuration
            self.runtime = runtime
            self.logger = logger
            self.cancellationAuthority = cancellationAuthority
        }

        func start() async throws -> ProxyHTTPEndpoint {
            precondition(phase == .idle, "HTTP gateway may only be started once")

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
                    logger: logger
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
                for channel in boundChannels {
                    channel.close(mode: .all, promise: nil)
                }
                if boundChannels.isEmpty == false {
                    try? await EventLoopFuture.andAllSucceed(
                        boundChannels.map(\.closeFuture),
                        on: group.next()
                    ).get()
                }
                await childInitializer.shutdown()
                try? await group.shutdownGracefully()
                phase = .stopped
                throw error
            }
        }

        func waitUntilShutdown() async throws {
            guard let resources else { return }
            try await EventLoopFuture.andAllSucceed(
                resources.listenChannels.map(\.closeFuture),
                on: resources.group.next()
            ).get()
        }

        func shutdown() async throws {
            guard phase == .running, let resources else { return }
            phase = .stopped
            var firstError: (any Error)?

            do {
                for channel in resources.listenChannels {
                    channel.close(mode: .all, promise: nil)
                }
                try await EventLoopFuture.andAllSucceed(
                    resources.listenChannels.map(\.closeFuture),
                    on: resources.group.next()
                ).get()

                while true {
                    let accepted = resources.acceptedChannelTracker.snapshot()
                    guard accepted.isEmpty == false else { break }
                    for channel in accepted {
                        channel.close(mode: .all, promise: nil)
                    }
                    try await EventLoopFuture.andAllSucceed(
                        accepted.map(\.closeFuture),
                        on: resources.group.next()
                    ).get()
                }
            } catch {
                firstError = error
            }

            await resources.childInitializer.shutdown()
            do {
                try await resources.group.shutdownGracefully()
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }

            cancellationAuthority.clear()
            self.resources = nil
            if let firstError {
                throw firstError
            }
        }

        private static func bindChannels(
            using bootstrap: ServerBootstrap,
            host: String,
            port: Int,
            logger: Logger
        ) async throws -> [Channel] {
            if host != "localhost" {
                return [try await bootstrap.bind(host: host, port: port).get()]
            }

            do {
                let v4 = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
                let v4Port = v4.localAddress?.port ?? port
                guard v4Port > 0 else { return [v4] }
                do {
                    let v6 = try await bootstrap.bind(host: "::1", port: v4Port).get()
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
                return [try await bootstrap.bind(host: "::1", port: port).get()]
            }
        }
    }

    private let lifecycle: Lifecycle
    private let cancellationAuthority: CancellationAuthority

    package init(
        configuration: ProxyHTTPConfiguration,
        runtime: any ProxyRuntimeServing,
        logger: Logger
    ) {
        let cancellationAuthority = CancellationAuthority()
        self.cancellationAuthority = cancellationAuthority
        self.lifecycle = Lifecycle(
            configuration: configuration,
            runtime: runtime,
            logger: logger,
            cancellationAuthority: cancellationAuthority
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
