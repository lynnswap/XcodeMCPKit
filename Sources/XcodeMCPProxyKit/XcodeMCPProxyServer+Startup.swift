import Foundation
import Logging
import NIO
import NIOHTTP1

extension XcodeMCPProxyServer {
    actor Lifecycle {
        private enum Phase {
            case idle
            case starting
            case running
            case stopping
            case stopped
        }

        private final class Resources: @unchecked Sendable {
            let config: ProxyConfig
            let group: EventLoopGroup
            let shutdownEventLoopGroup: @Sendable (EventLoopGroup) async throws -> Void
            let acceptedChannelTracker: ProxyAcceptedChannelTracker
            let listenChannels: [Channel]
            let runtime: any RuntimeCoordinating
            let autoApprover: (any ProxyServerPermissionDialogAutoApprover)?
            let endpoint: Endpoint

            init(
                config: ProxyConfig,
                group: EventLoopGroup,
                shutdownEventLoopGroup: @escaping @Sendable (EventLoopGroup) async throws -> Void,
                acceptedChannelTracker: ProxyAcceptedChannelTracker,
                listenChannels: [Channel],
                runtime: any RuntimeCoordinating,
                autoApprover: (any ProxyServerPermissionDialogAutoApprover)?,
                endpoint: Endpoint
            ) {
                self.config = config
                self.group = group
                self.shutdownEventLoopGroup = shutdownEventLoopGroup
                self.acceptedChannelTracker = acceptedChannelTracker
                self.listenChannels = listenChannels
                self.runtime = runtime
                self.autoApprover = autoApprover
                self.endpoint = endpoint
            }

            func signalCancellation() {
                autoApprover?.stop()
                runtime.cancelForDeinit()
                for channel in listenChannels {
                    channel.close(mode: .all, promise: nil)
                }
                for channel in acceptedChannelTracker.snapshot() {
                    channel.close(mode: .all, promise: nil)
                }
                group.shutdownGracefully { _ in }
            }
        }

        private let configuration: XcodeMCPProxyServerConfiguration
        private let preparedProxyConfig: ProxyConfig?
        private let dependencies: Dependencies
        private let logger: Logger
        private var phase: Phase = .idle
        private var startupTask: Task<Resources, any Error>?
        private var shutdownTask: Task<Void, any Error>?
        private var resources: Resources?
        private var lastEndpoint: Endpoint?
        private var terminalUpstreams: [Status.Upstream] = []
        private var shutdownRequested = false

        init(
            configuration: XcodeMCPProxyServerConfiguration,
            preparedProxyConfig: ProxyConfig?,
            dependencies: Dependencies,
            logger: Logger
        ) {
            self.configuration = configuration
            self.preparedProxyConfig = preparedProxyConfig
            self.dependencies = dependencies
            self.logger = logger
        }

        func start() async throws -> Endpoint {
            guard phase == .idle else {
                if phase == .stopping {
                    throw LifecycleError.shutdownInProgress
                }
                throw LifecycleError.alreadyStarted
            }

            phase = .starting
            // Explicit file IO and all public-value validation happen before
            // the event-loop factory can acquire a thread.
            let config: ProxyConfig
            do {
                if let preparedProxyConfig {
                    config = preparedProxyConfig
                } else {
                    config = try ProxyConfig.resolving(
                        configuration,
                        loadFileConfiguration: dependencies.loadFileConfiguration
                    )
                }
                try config.validateModernProtocolConfiguration()
            } catch {
                phase = .stopped
                throw error
            }

            let task = Task {
                try await Self.acquire(
                    configuration: configuration,
                    config: config,
                    dependencies: dependencies,
                    logger: logger
                )
            }
            startupTask = task

            let acquired: Resources
            do {
                acquired = try await task.value
            } catch {
                startupTask = nil
                phase = .stopped
                throw error
            }

            startupTask = nil
            if phase == .stopped {
                throw LifecycleError.shutdownInProgress
            }
            if resources == nil {
                resources = acquired
                lastEndpoint = acquired.endpoint
            }

            if shutdownRequested {
                try await finishShutdown(using: resources ?? acquired)
                throw LifecycleError.shutdownInProgress
            }

            acquired.autoApprover?.start()
            acquired.runtime.start()
            phase = .running
            return acquired.endpoint
        }

        func snapshot() -> Status {
            let publicPhase: Status.Phase
            switch phase {
            case .idle, .starting:
                publicPhase = .idle
            case .running:
                publicPhase = .running
            case .stopping:
                publicPhase = .stopping
            case .stopped:
                publicPhase = .stopped
            }

            guard let resources else {
                return Status(
                    generatedAt: Date(),
                    phase: publicPhase,
                    endpoint: lastEndpoint,
                    proxyInitialized: false,
                    catalogAvailable: false,
                    queuedRequestCount: 0,
                    upstreams: terminalUpstreams
                )
            }

            let debug = resources.runtime.debugSnapshot()
            let upstreams = debug.upstreams.map { upstream in
                Status.Upstream(
                    id: upstream.upstreamIndex,
                    health: Self.publicHealth(
                        debugHealth: upstream.healthState,
                        isInitialized: upstream.isInitialized
                    ),
                    isInitialized: upstream.isInitialized,
                    activeRequestCount: upstream.activeCorrelatedRequestCount
                )
            }
            return Status(
                generatedAt: debug.generatedAt,
                phase: publicPhase,
                endpoint: resources.endpoint,
                proxyInitialized: debug.proxyInitialized,
                catalogAvailable: debug.cachedToolsListAvailable,
                queuedRequestCount: debug.queuedRequestCount,
                upstreams: upstreams
            )
        }

        func waitUntilShutdown() async throws {
            switch phase {
            case .idle, .stopped:
                return
            case .starting:
                guard let startupTask else { return }
                let acquired = try await startupTask.value
                try await Self.waitForListenerClose(acquired)
            case .running:
                guard let resources else { return }
                try await Self.waitForListenerClose(resources)
            case .stopping:
                if let shutdownTask {
                    try await shutdownTask.value
                } else if let startupTask {
                    _ = try? await startupTask.value
                    if let shutdownTask {
                        try await shutdownTask.value
                    }
                }
            }
        }

        func shutdown() async throws {
            shutdownRequested = true

            if let shutdownTask {
                try await shutdownTask.value
                return
            }

            switch phase {
            case .idle:
                phase = .stopped
                return
            case .stopped:
                return
            case .starting:
                phase = .stopping
                guard let startupTask else {
                    phase = .stopped
                    return
                }
                do {
                    let acquired = try await startupTask.value
                    self.startupTask = nil
                    resources = acquired
                    lastEndpoint = acquired.endpoint
                    try await finishShutdown(using: acquired)
                } catch {
                    self.startupTask = nil
                    phase = .stopped
                    // Acquisition owns and completes its own unwind. A failed
                    // start leaves shutdown with nothing else to release.
                }
            case .running:
                guard let resources else {
                    phase = .stopped
                    return
                }
                try await finishShutdown(using: resources)
            case .stopping:
                if let shutdownTask {
                    try await shutdownTask.value
                }
            }
        }

        private func finishShutdown(using resources: Resources) async throws {
            if phase == .stopped {
                return
            }
            if let shutdownTask {
                try await shutdownTask.value
                return
            }
            phase = .stopping
            terminalUpstreams = Self.stoppedUpstreams(from: resources.runtime.debugSnapshot())
            let task = Task {
                try await Self.release(resources)
            }
            shutdownTask = task
            do {
                try await task.value
                self.resources = nil
                shutdownTask = nil
                phase = .stopped
            } catch {
                self.resources = nil
                shutdownTask = nil
                phase = .stopped
                throw error
            }
        }

        isolated deinit {
            startupTask?.cancel()
            shutdownTask?.cancel()
            resources?.signalCancellation()
        }

        private static func acquire(
            configuration: XcodeMCPProxyServerConfiguration,
            config: ProxyConfig,
            dependencies: Dependencies,
            logger: Logger
        ) async throws -> Resources {
            let group = dependencies.makeEventLoopGroup()
            let tracker = ProxyAcceptedChannelTracker()
            let refreshCoordinator = RefreshCodeIssues.Coordinator.makeDefault()
            let refreshTargetResolver = RefreshCodeIssues.TargetResolver()
            let refreshDebugState = RefreshCodeIssues.DebugState(
                defaultRequestTimeoutSeconds: config.requestTimeout
            )
            let runtime = dependencies.makeRuntimeCoordinator(config, group.next())
            let autoApprover = config.autoApproveXcodeDialog
                ? dependencies.makeAutoApprover(config)
                : nil
            var boundChannels: [Channel] = []

            do {
                let childInitializer = ProxyHTTPChildChannelInitializer(
                    config: config,
                    sessionManager: runtime,
                    refreshCodeIssuesCoordinator: refreshCoordinator,
                    refreshCodeIssuesTargetResolver: refreshTargetResolver,
                    refreshCodeIssuesDebugState: refreshDebugState,
                    logger: logger
                )
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

                boundChannels = try await bindChannels(
                    using: bootstrap,
                    host: config.listenHost,
                    port: config.listenPort,
                    logger: logger
                )
                guard let first = boundChannels.first else {
                    throw LifecycleError.failedToBind
                }

                let resolvedHost = first.localAddress?.ipAddress ?? config.listenHost
                let resolvedPort = first.localAddress?.port ?? config.listenPort
                let endpoint = Endpoint(host: resolvedHost, port: resolvedPort)
                try writeDiscovery(
                    configuration.discovery,
                    resolvedHost: resolvedHost,
                    port: resolvedPort,
                    configuredHost: config.listenHost,
                    dependencies: dependencies
                )

                let displayHost = config.listenHost == "localhost" ? "localhost" : resolvedHost
                let summary = XcodeMCPProxyServer.startupSummary(
                    displayHost: displayHost,
                    port: resolvedPort,
                    config: config,
                    xcodeTargets: dependencies.runningXcodeTargets()
                )
                logger.info("\(summary)")

                return Resources(
                    config: config,
                    group: group,
                    shutdownEventLoopGroup: dependencies.shutdownEventLoopGroup,
                    acceptedChannelTracker: tracker,
                    listenChannels: boundChannels,
                    runtime: runtime,
                    autoApprover: autoApprover,
                    endpoint: endpoint
                )
            } catch {
                autoApprover?.stop()
                for channel in boundChannels {
                    channel.close(mode: .all, promise: nil)
                }
                if boundChannels.isEmpty == false {
                    try? await EventLoopFuture.andAllSucceed(
                        boundChannels.map(\.closeFuture),
                        on: group.next()
                    ).get()
                }
                await runtime.shutdown()
                try? await dependencies.shutdownEventLoopGroup(group)
                throw error
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

        private static func writeDiscovery(
            _ policy: XcodeMCPProxyServerConfiguration.Discovery,
            resolvedHost: String,
            port: Int,
            configuredHost: String,
            dependencies: Dependencies
        ) throws {
            let overrideURL: URL?
            switch policy {
            case .disabled:
                return
            case .defaultLocation:
                overrideURL = nil
            case .file(let url):
                overrideURL = url
            }

            let discoveryHost: String
            switch configuredHost {
            case "localhost", "0.0.0.0", "::":
                discoveryHost = "localhost"
            default:
                discoveryHost = resolvedHost
            }
            guard let record = dependencies.discoveryClient.makeRecord(
                discoveryHost,
                port,
                dependencies.processID(),
                "http"
            ) else {
                throw LifecycleError.failedToCreateDiscoveryRecord
            }
            try dependencies.discoveryClient.write(record, overrideURL)
        }

        private static func waitForListenerClose(_ resources: Resources) async throws {
            try await EventLoopFuture.andAllSucceed(
                resources.listenChannels.map(\.closeFuture),
                on: resources.group.next()
            ).get()
        }

        private static func release(_ resources: Resources) async throws {
            resources.autoApprover?.stop()
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

            await resources.runtime.shutdown()
            do {
                try await resources.shutdownEventLoopGroup(resources.group)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }

            if let firstError {
                throw firstError
            }
        }

        private static func publicHealth(
            debugHealth: String,
            isInitialized: Bool
        ) -> Status.Upstream.Health {
            if debugHealth.hasPrefix("quarantined") {
                return .quarantined
            }
            if debugHealth == "degraded" {
                return .degraded
            }
            return isInitialized ? .healthy : .starting
        }

        private static func stoppedUpstreams(
            from debug: ProxyDebug.Snapshot
        ) -> [Status.Upstream] {
            debug.upstreams.map { upstream in
                Status.Upstream(
                    id: upstream.upstreamIndex,
                    health: .stopped,
                    isInitialized: upstream.isInitialized,
                    activeRequestCount: 0
                )
            }
        }
    }
}
