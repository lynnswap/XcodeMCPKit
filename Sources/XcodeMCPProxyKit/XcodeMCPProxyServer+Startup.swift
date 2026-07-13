import Foundation
import Logging
import XcodeMCPProxyHTTP
import XcodeMCPProxyRuntime

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
            let httpGateway: any ProxyHTTPGatewayServing
            let runtime: any ProxyRuntimeServing
            let autoApprover: (any ProxyServerPermissionDialogAutoApprover)?
            let endpoint: Endpoint

            init(
                config: ProxyConfig,
                httpGateway: any ProxyHTTPGatewayServing,
                runtime: any ProxyRuntimeServing,
                autoApprover: (any ProxyServerPermissionDialogAutoApprover)?,
                endpoint: Endpoint
            ) {
                self.config = config
                self.httpGateway = httpGateway
                self.runtime = runtime
                self.autoApprover = autoApprover
                self.endpoint = endpoint
            }

            func signalCancellation() {
                autoApprover?.stop()
                httpGateway.cancelForDeinit()
                runtime.cancelForDeinit()
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

            acquired.runtime.start()
            acquired.autoApprover?.start()
            logStartupSummary(for: acquired)
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

            let runtimeSnapshot = resources.runtime.snapshot()
            let upstreams = runtimeSnapshot.upstreams.map { upstream in
                Status.Upstream(
                    id: upstream.id,
                    health: Self.publicHealth(
                        debugHealth: upstream.healthState,
                        isInitialized: upstream.isInitialized
                    ),
                    isInitialized: upstream.isInitialized,
                    activeRequestCount: upstream.activeRequestCount
                )
            }
            return Status(
                generatedAt: runtimeSnapshot.generatedAt,
                phase: publicPhase,
                endpoint: resources.endpoint,
                proxyInitialized: runtimeSnapshot.proxyInitialized,
                catalogAvailable: runtimeSnapshot.catalogAvailable,
                queuedRequestCount: runtimeSnapshot.queuedRequestCount,
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
            terminalUpstreams = Self.stoppedUpstreams(from: resources.runtime.snapshot())
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

        private func logStartupSummary(for resources: Resources) {
            let displayHost =
                resources.config.listenHost == "localhost"
                ? "localhost"
                : resources.endpoint.host
            let summary = XcodeMCPProxyServer.startupSummary(
                displayHost: displayHost,
                port: resources.endpoint.port,
                config: resources.config,
                xcodeTargets: resources.runtime.inventorySnapshot().xcodeTargets
            )
            logger.info("\(summary)")
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
            let runtime = dependencies.makeRuntime(config.runtimeConfiguration)
            let autoApprover = config.autoApproveXcodeDialog
                ? dependencies.makeAutoApprover(config, runtime)
                : nil
            let httpGateway = dependencies.makeHTTPGateway(
                ProxyHTTPConfiguration(
                    listenHost: config.listenHost,
                    listenPort: config.listenPort,
                    maxBodyBytes: config.maxBodyBytes
                ),
                runtime,
                logger
            )

            do {
                let resolvedEndpoint = try await httpGateway.start()
                let resolvedHost = resolvedEndpoint.host
                let resolvedPort = resolvedEndpoint.port
                let endpoint = Endpoint(host: resolvedHost, port: resolvedPort)
                try writeDiscovery(
                    configuration.discovery,
                    resolvedHost: resolvedHost,
                    port: resolvedPort,
                    configuredHost: config.listenHost,
                    dependencies: dependencies
                )

                return Resources(
                    config: config,
                    httpGateway: httpGateway,
                    runtime: runtime,
                    autoApprover: autoApprover,
                    endpoint: endpoint
                )
            } catch {
                autoApprover?.stop()
                try? await httpGateway.shutdown()
                await runtime.shutdown()
                throw error
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
            try await resources.httpGateway.waitUntilShutdown()
        }

        private static func release(_ resources: Resources) async throws {
            resources.autoApprover?.stop()
            var firstError: (any Error)?

            do {
                try await resources.httpGateway.shutdown()
            } catch {
                firstError = error
            }

            await resources.runtime.shutdown()

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
            from snapshot: ProxyRuntimeSnapshot
        ) -> [Status.Upstream] {
            snapshot.upstreams.map { upstream in
                Status.Upstream(
                    id: upstream.id,
                    health: .stopped,
                    isInitialized: upstream.isInitialized,
                    activeRequestCount: 0
                )
            }
        }
    }
}
