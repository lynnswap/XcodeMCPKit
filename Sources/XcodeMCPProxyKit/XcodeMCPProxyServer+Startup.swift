import XcodeMCPProxyRuntimeContract
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
            let httpGateway: any ProxyHTTPGatewayServing
            let runtime: any ProxyRuntimeServing
            let endpoint: Endpoint
            let autoApprover: (any ProxyServerPermissionDialogAutoApprover)?

            init(
                httpGateway: any ProxyHTTPGatewayServing,
                runtime: any ProxyRuntimeServing,
                endpoint: Endpoint,
                autoApprover: (any ProxyServerPermissionDialogAutoApprover)?
            ) {
                self.httpGateway = httpGateway
                self.runtime = runtime
                self.endpoint = endpoint
                self.autoApprover = autoApprover
            }

            func signalCancellation() {
                autoApprover?.cancel()
                httpGateway.cancelForDeinit()
                runtime.cancelForDeinit()
            }
        }

        private let configuration: XcodeMCPProxyServerConfiguration
        private let dependencies: Dependencies
        private let logger: Logger
        private var phase: Phase = .idle
        private var startupTask: Task<Resources, any Error>?
        private var shutdownTask: Task<Void, any Error>?
        private var resources: Resources?
        private var lastEndpoint: Endpoint?
        private var terminalHosts: [Status.Host] = []
        private var shutdownRequested = false

        init(
            configuration: XcodeMCPProxyServerConfiguration,
            dependencies: Dependencies,
            logger: Logger
        ) {
            self.configuration = configuration
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
            let runtimeConfiguration: ProxyRuntimeConfiguration
            do {
                runtimeConfiguration = try configuration.runtimeConfiguration()
            } catch {
                phase = .stopped
                throw error
            }

            let task = Task {
                try await Self.acquire(
                    configuration: configuration,
                    runtimeConfiguration: runtimeConfiguration,
                    dependencies: dependencies,
                    logger: logger
                )
            }
            startupTask = task

            let acquired: Resources
            do {
                acquired = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            } catch {
                phase = .stopped
                lastEndpoint = (error as? CleanupError)?.endpoint
                throw error
            }

            startupTask = nil
            if shutdownRequested {
                try await shutdown()
                throw LifecycleError.shutdownInProgress
            }

            resources = acquired
            lastEndpoint = acquired.endpoint

            acquired.autoApprover?.start()
            acquired.runtime.start()
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
                return Status(generatedAt: Date(), phase: publicPhase, endpoint: lastEndpoint, hosts: terminalHosts)
            }

            let runtimeSnapshot = resources.runtime.snapshot()
            return Status(
                generatedAt: runtimeSnapshot.generatedAt,
                phase: publicPhase,
                endpoint: resources.endpoint,
                hosts: runtimeSnapshot.hosts.map(Self.publicHost)
            )
        }

        func waitUntilShutdown() async throws {
            if let shutdownTask {
                try await shutdownTask.value
                return
            }
            switch phase {
            case .idle, .stopped:
                if let startupTask {
                    do {
                        _ = try await startupTask.value
                    } catch let error as CleanupError {
                        throw error
                    } catch {
                        // The startup error was reported by start(); its cleanup completed.
                    }
                }
                return
            case .starting:
                guard let startupTask else { return }
                let acquired = try await startupTask.value
                if let shutdownTask {
                    try await shutdownTask.value
                } else {
                    try await Self.waitForListenerClose(acquired)
                }
            case .running:
                guard let resources else { return }
                try await Self.waitForListenerClose(resources)
            case .stopping:
                return
            }
        }

        func shutdown() async throws {
            shutdownRequested = true

            if let shutdownTask {
                try await shutdownTask.value
                return
            }

            let startupTask = self.startupTask
            let resources = self.resources
            guard startupTask != nil || resources != nil else {
                phase = .stopped
                return
            }
            phase = .stopping
            startupTask?.cancel()
            let task = Task {
                defer {
                    self.startupTask = nil
                    self.resources = nil
                    phase = .stopped
                }
                let acquired: Resources
                if let startupTask {
                    do {
                        acquired = try await startupTask.value
                    } catch let error as CleanupError {
                        lastEndpoint = error.endpoint
                        throw error
                    } catch {
                        // Acquisition already completed its unwind successfully.
                        return
                    }
                } else if let resources {
                    acquired = resources
                } else {
                    return
                }
                lastEndpoint = acquired.endpoint
                // Read after release, so hosts that requests registered during shutdown are included.
                // Shutdown stops every host process.
                defer {
                    terminalHosts = acquired.runtime.snapshot().hosts.map { host in
                        Status.Host(identifier: host.identifier, developerDirectory: host.developerDirectory,
                                    kind: Self.publicKind(of: host), state: .stopped, activeRequestCount: 0)
                    }
                }
                try await Self.release(acquired)
            }
            shutdownTask = task
            try await task.value
        }

        private func logStartupSummary(for resources: Resources) {
            let displayHost =
                configuration.listenHost == "localhost"
                ? "localhost"
                : resources.endpoint.host
            let summary = XcodeMCPProxyServer.startupSummary(
                displayHost: displayHost,
                port: resources.endpoint.port
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
            runtimeConfiguration: ProxyRuntimeConfiguration,
            dependencies: Dependencies,
            logger: Logger
        ) async throws -> Resources {
            let runtime = try dependencies.makeRuntime(runtimeConfiguration)
            let httpGateway = dependencies.makeHTTPGateway(
                ProxyHTTPConfiguration(
                    listenHost: configuration.listenHost,
                    listenPort: configuration.listenPort,
                    maxBodyBytes: configuration.maxBodyBytes,
                    enablesDebugEndpoints: configuration.enablesDebugEndpoints
                ),
                runtime,
                logger
            )

            var endpoint: Endpoint?
            do {
                let resolvedEndpoint = try await httpGateway.start()
                let resolvedHost = resolvedEndpoint.host
                let resolvedPort = resolvedEndpoint.port
                let boundEndpoint = Endpoint(host: resolvedHost, port: resolvedPort)
                endpoint = boundEndpoint
                try writeDiscovery(
                    configuration.discovery,
                    resolvedHost: resolvedHost,
                    port: resolvedPort,
                    configuredHost: configuration.listenHost,
                    dependencies: dependencies
                )

                return Resources(
                    httpGateway: httpGateway,
                    runtime: runtime,
                    endpoint: boundEndpoint,
                    autoApprover: configuration.approvalPolicy == .automatic
                        ? dependencies.makeAutoApprover(configuration) : nil
                )
            } catch {
                let operationError = error
                var cleanupError: (any Error)?
                do {
                    try await httpGateway.shutdown()
                } catch {
                    cleanupError = error
                }
                await runtime.shutdown()
                if let cleanupError {
                    throw CleanupError(
                        operationError: operationError,
                        cleanupError: cleanupError,
                        endpoint: endpoint
                    )
                }
                throw operationError
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
            var firstError: (any Error)?

            do {
                try await resources.httpGateway.shutdown()
            } catch {
                firstError = error
            }

            await resources.autoApprover?.shutdown()
            await resources.runtime.shutdown()

            if let firstError {
                throw firstError
            }
        }

        private static func publicHost(_ host: ProxyRuntimeSnapshot.Host) -> Status.Host {
            let state: Status.Host.State = switch host.state {
            case .stopped: .stopped
            case .starting: .starting
            case .running: .running
            }
            return Status.Host(identifier: host.identifier, developerDirectory: host.developerDirectory,
                               kind: publicKind(of: host), state: state, activeRequestCount: host.activeRequestCount)
        }

        private static func publicKind(of host: ProxyRuntimeSnapshot.Host) -> Status.Host.Kind {
            host.guiProcessIdentifier.map { .gui(processIdentifier: $0) } ?? .headless
        }
    }
}
