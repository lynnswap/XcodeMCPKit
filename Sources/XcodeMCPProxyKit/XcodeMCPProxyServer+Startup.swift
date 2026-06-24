import Foundation
import NIO
import NIOHTTP1
import ProxySession

extension XcodeMCPProxyServer {
    /// Starts the proxy server without writing discovery information.
    ///
    /// Prefer ``startAndWriteDiscovery()`` when local clients or adapters need
    /// to discover the HTTP endpoint automatically.
    ///
    /// - Returns: The resolved endpoint.
    public func start() throws -> Endpoint {
        let channel = try startListening()
        let (host, port) = resolvedListenAddress(for: channel)
        return Endpoint(host: host, port: port)
    }

    package func startListening() throws -> NIO.Channel {
        try config.validateModernProtocolConfiguration()
        let preparedRuntime = try prepareRuntimeForStart()
        let sessionManager = preparedRuntime.sessionManager
        let childInitializer = ProxyHTTPChildChannelInitializer(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: refreshCodeIssuesCoordinator,
            refreshCodeIssuesTargetResolver: refreshCodeIssuesTargetResolver,
            refreshCodeIssuesDebugState: refreshCodeIssuesDebugState,
            logger: logger
        )
        var bootstrap = ServerBootstrap(group: group)
        bootstrap = bootstrap.serverChannelOption(ChannelOptions.backlog, value: 256)
        bootstrap = bootstrap.serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        bootstrap = bootstrap.serverChannelInitializer { [acceptedChannelTracker] channel -> EventLoopFuture<Void> in
            channel.pipeline.addHandler(ProxyAcceptedChannelHandler(tracker: acceptedChannelTracker))
        }
        bootstrap = bootstrap.childChannelInitializer { channel -> EventLoopFuture<Void> in
            childInitializer.initialize(channel)
        }
        bootstrap = bootstrap.childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let boundChannels: [Channel]
        do {
            boundChannels = try bindChannels(using: bootstrap)
        } catch {
            stopPreparedRuntimeAfterStartFailure(preparedRuntime)
            throw error
        }

        guard installBoundChannels(boundChannels, preparedRuntime: preparedRuntime) else {
            for channel in boundChannels {
                channel.close(promise: nil)
            }
            stopPreparedRuntimeAfterStartFailure(preparedRuntime)
            throw ProxyServerError.shutdownInProgress
        }
        guard let first = boundChannels.first else {
            stopPreparedRuntimeAfterStartFailure(preparedRuntime)
            throw ProxyServerError.failedToBind
        }
        preparedRuntime.startLifecycle()
        return first
    }

    private func prepareRuntimeForStart() throws -> ProxyServerPreparedRuntime {
        runtimeLock.lock()
        let existingSessionManager = isShuttingDown ? nil : sessionManager
        let wasShuttingDown = isShuttingDown
        runtimeLock.unlock()

        if let existing = existingSessionManager {
            return ProxyServerPreparedRuntime(
                sessionManager: existing,
                autoApprover: nil,
                ownsRuntime: false
            )
        }

        if wasShuttingDown {
            throw ProxyServerError.shutdownInProgress
        }

        let autoApprover: (any ProxyServerPermissionDialogAutoApprover)?
        if config.autoApproveXcodeDialog {
            autoApprover = dependencies.makeAutoApprover()
        } else {
            autoApprover = nil
        }

        let sessionManager = dependencies.makeRuntimeCoordinator(config, group.next())
        return ProxyServerPreparedRuntime(
            sessionManager: sessionManager,
            autoApprover: autoApprover,
            ownsRuntime: true
        )
    }

    private func installBoundChannels(
        _ boundChannels: [Channel],
        preparedRuntime: ProxyServerPreparedRuntime
    ) -> Bool {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        guard isShuttingDown == false else {
            return false
        }
        if sessionManager != nil, preparedRuntime.ownsRuntime {
            return false
        }

        setChannelsForStartedServer(boundChannels)
        if sessionManager == nil {
            sessionManager = preparedRuntime.sessionManager
        }
        if permissionDialogAutoApprover == nil {
            permissionDialogAutoApprover = preparedRuntime.autoApprover
        }
        return true
    }

    private func stopPreparedRuntimeAfterStartFailure(_ preparedRuntime: ProxyServerPreparedRuntime) {
        preparedRuntime.autoApprover?.stop()
        guard preparedRuntime.ownsRuntime else { return }
        let sessionManager = preparedRuntime.sessionManager
        Task {
            await sessionManager.shutdown()
        }
    }
}

private final class ProxyServerPreparedRuntime: @unchecked Sendable {
    let sessionManager: any RuntimeCoordinating
    let autoApprover: (any ProxyServerPermissionDialogAutoApprover)?
    let ownsRuntime: Bool

    init(
        sessionManager: any RuntimeCoordinating,
        autoApprover: (any ProxyServerPermissionDialogAutoApprover)?,
        ownsRuntime: Bool
    ) {
        self.sessionManager = sessionManager
        self.autoApprover = autoApprover
        self.ownsRuntime = ownsRuntime
    }

    func startLifecycle() {
        autoApprover?.start()
        guard ownsRuntime else { return }
        sessionManager.start()
    }
}
