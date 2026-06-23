import Foundation
import Logging
import NIO
import NIOHTTP1
import ProxyBuildInfo
import ProxyCore
import ProxySession
import ProxyHTTPGateway
import ProxyXcodeFeatures
import ProxyXcodeSupport

public final class ProxyServer {
    package struct Dependencies: Sendable {
        package var discoveryClient: DiscoveryClient
        package var executableLookupClient: ExecutableLookupClient
        package var processID: @Sendable () -> Int
        package var runningXcodeTargets: @Sendable () -> [DocumentationProviderTarget]
        package var makeAutoApprover: @Sendable () -> any ProxyServerPermissionDialogAutoApprover
        package var makeRuntimeCoordinator:
            @Sendable (_ config: ProxyConfig, _ eventLoop: EventLoop) -> any RuntimeCoordinating

        package init(
            discoveryClient: DiscoveryClient = .liveValue,
            executableLookupClient: ExecutableLookupClient = .liveValue,
            processID: @escaping @Sendable () -> Int = {
                Int(ProcessInfo.processInfo.processIdentifier)
            },
            runningXcodeTargets: @escaping @Sendable () -> [DocumentationProviderTarget] = {
                []
            },
            makeAutoApprover: @escaping @Sendable () -> any ProxyServerPermissionDialogAutoApprover,
            makeRuntimeCoordinator: @escaping @Sendable (_ config: ProxyConfig, _ eventLoop: EventLoop) -> any RuntimeCoordinating
        ) {
            self.discoveryClient = discoveryClient
            self.executableLookupClient = executableLookupClient
            self.processID = processID
            self.runningXcodeTargets = runningXcodeTargets
            self.makeAutoApprover = makeAutoApprover
            self.makeRuntimeCoordinator = makeRuntimeCoordinator
        }

        package static func live(config: ProxyConfig) -> Self {
            let executableLookupClient = ExecutableLookupClient.liveValue
            return Self(
                executableLookupClient: executableLookupClient,
                runningXcodeTargets: {
                    LiveXcodeTargetDiscovery().runningXcodeTargets()
                },
                makeAutoApprover: {
                    let additionalCandidates = ProxyServer.additionalPermissionDialogExecutableCandidates(
                        config: config,
                        executableLookupClient: executableLookupClient
                    )
                    return XcodePermissionDialog.AutoApprover(
                        dependencies: .live(
                            agentPathCandidates: {
                                XcodePermissionDialog.AutoApprover.defaultAgentPathCandidates(
                                    additionalExecutableCandidates: additionalCandidates
                                )
                            },
                            assistantNameCandidates: {
                                Set(ProxyServer.permissionDialogAssistantNameCandidates(config: config))
                            }
                        )
                    )
                },
                makeRuntimeCoordinator: { config, eventLoop in
                    RuntimeCoordinator(
                        config: config,
                        eventLoop: eventLoop,
                        upstreamReadinessGate: .liveDefault(config: config, clock: .liveValue),
                        xcodeTargetDiscovery: LiveXcodeTargetDiscovery(),
                        startImmediately: false
                    )
                }
            )
        }
    }

    package let config: ProxyConfig
    package let dependencies: Dependencies
    package let group: EventLoopGroup
    package let refreshCodeIssuesCoordinator: RefreshCodeIssues.Coordinator
    package let refreshCodeIssuesTargetResolver: RefreshCodeIssues.TargetResolver
    package let refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState
    private var channels: [Channel] = []
    package let logger: Logger = ProxyLogging.make("server")
    package let runtimeLock = NSLock()
    package let acceptedChannelTracker = ProxyAcceptedChannelTracker()
    package var isShuttingDown = false
    package var sessionManager: (any RuntimeCoordinating)?
    package var permissionDialogAutoApprover: (any ProxyServerPermissionDialogAutoApprover)?

    public convenience init(config: ProxyConfig) {
        self.init(config: config, dependencies: .live(config: config))
    }

    package init(config: ProxyConfig, dependencies: Dependencies) {
        self.config = config
        self.dependencies = dependencies
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.refreshCodeIssuesCoordinator = RefreshCodeIssues.Coordinator.makeDefault()
        self.refreshCodeIssuesTargetResolver = RefreshCodeIssues.TargetResolver()
        self.refreshCodeIssuesDebugState = RefreshCodeIssues.DebugState(
            defaultRequestTimeoutSeconds: config.requestTimeout
        )
    }

    public func startAndWriteDiscovery() throws -> (host: String, port: Int) {
        let channel = try start()
        let (host, port) = resolvedListenAddress(for: channel)
        let displayHost = config.listenHost == "localhost" ? "localhost" : host
        writeDiscovery(resolvedHost: host, port: port)
        let summary = Self.startupSummary(
            displayHost: displayHost,
            port: port,
            config: config,
            xcodeTargets: dependencies.runningXcodeTargets()
        )
        logger.info("\(summary)")
        return (host, port)
    }

    public func wait() async throws {
        try await waitForHTTP()
    }

    public func shutdown() async throws {
        let shutdownContext = beginShutdown()
        shutdownContext.autoApprover?.stop()

        var shutdownError: (any Error)?
        do {
            try await closeChannels(shutdownContext.channels)
        } catch {
            shutdownError = error
        }

        await shutdownContext.sessionManager?.shutdown()
        do {
            try await shutdownEventLoopGroup()
        } catch {
            if shutdownError == nil {
                shutdownError = error
            }
        }

        if let shutdownError {
            throw shutdownError
        }
    }

    private func closeChannels(_ listenChannels: [Channel]) async throws {
        let listenCloseFutures = listenChannels.map(\.closeFuture)
        for channel in listenChannels {
            channel.close(mode: .all, promise: nil)
        }
        try await EventLoopFuture.andAllSucceed(listenCloseFutures, on: group.next()).get()

        while true {
            let childChannels = acceptedChannelTracker.snapshot()
            guard !childChannels.isEmpty else { break }

            let childCloseFutures = childChannels.map(\.closeFuture)
            for channel in childChannels {
                channel.close(mode: .all, promise: nil)
            }
            try await EventLoopFuture.andAllSucceed(childCloseFutures, on: group.next()).get()
        }
    }

    private func shutdownEventLoopGroup() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            group.shutdownGracefully { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func resolvedListenAddress(for channel: Channel) -> (String, Int) {
        if let address = channel.localAddress {
            let host = address.ipAddress ?? config.listenHost
            let port = address.port ?? config.listenPort
            return (host, port)
        }
        return (config.listenHost, config.listenPort)
    }

    package func bindChannels(using bootstrap: ServerBootstrap) throws -> [Channel] {
        if config.listenHost != "localhost" {
            let channel = try bootstrap.bind(host: config.listenHost, port: config.listenPort).wait()
            return [channel]
        }

        var bound: [Channel] = []
        do {
            let v4Channel = try bootstrap.bind(host: "127.0.0.1", port: config.listenPort).wait()
            bound.append(v4Channel)
            let v4Port = v4Channel.localAddress?.port ?? config.listenPort
            guard v4Port > 0 else {
                return bound
            }
            do {
                let v6Channel = try bootstrap.bind(host: "::1", port: v4Port).wait()
                bound.append(v6Channel)
            } catch {
                logger.warning("Failed to bind IPv6 loopback; continuing with IPv4 only", metadata: ["error": "\(error)"])
            }
            return bound
        } catch {
            logger.warning("Failed to bind IPv4 loopback; attempting IPv6 only", metadata: ["error": "\(error)"])
            let v6Channel = try bootstrap.bind(host: "::1", port: config.listenPort).wait()
            return [v6Channel]
        }
    }

    private func waitForHTTP() async throws {
        let futures = runtimeLock.withLock { channels.map(\.closeFuture) }
        if futures.isEmpty {
            return
        }
        try await EventLoopFuture.andAllSucceed(futures, on: group.next()).get()
    }

    private func writeDiscovery(resolvedHost: String, port: Int) {
        guard let record = dependencies.discoveryClient.makeRecord(
            discoveryHost(resolvedHost),
            port,
            dependencies.processID(),
            "http"
        ) else {
            return
        }
        do {
            try dependencies.discoveryClient.write(record, config.discoveryFileURL)
        } catch {
            logger.warning(
                "Failed to write discovery file",
                metadata: [
                    "error": "\(error)",
                    "path": "\(config.discoveryFileURL?.path ?? dependencies.discoveryClient.defaultFileURL().path)",
                ]
            )
        }
    }

    private func discoveryHost(_ resolvedHost: String) -> String {
        switch config.listenHost {
        case "localhost", "0.0.0.0", "::":
            return "localhost"
        default:
            return resolvedHost
        }
    }

    package static func listeningLogLine(displayHost: String, port: Int) -> String {
        "Xcode MCP proxy listening on http://\(displayHost):\(port) (version \(ProxyBuildInfo.version))"
    }

    package static func startupSummary(
        displayHost: String,
        port: Int,
        config: ProxyConfig,
        xcodeTargets: [DocumentationProviderTarget]
    ) -> String {
        var lines = [
            "XcodeMCPKit \(ProxyBuildInfo.version)",
            "",
            "Server",
            "  URL: http://\(displayHost):\(port)/mcp",
            "  Upstream processes: \(config.upstreamProcessCount)",
            "  Auto approve: \(config.autoApproveXcodeDialog ? "enabled" : "disabled")",
            "",
            "Xcode",
        ]

        switch xcodeTargets.count {
        case 0:
            lines.append("  Status: not detected")
        case 1:
            if let target = xcodeTargets.first {
                lines.append("  App: \(target.appPath)")
                lines.append("  PID: \(target.processID)")
            }
        default:
            lines.append("  Detected: \(xcodeTargets.count)")
            lines.append("  Apps:")
            for target in xcodeTargets {
                lines.append("    - \(target.appPath) (PID: \(target.processID))")
            }
        }

        lines.append(
            "  DocumentationSearch: \(documentationSearchStartupStatus(config: config))"
        )
        return lines.joined(separator: "\n")
    }

    private static func documentationSearchStartupStatus(config: ProxyConfig) -> String {
        if RuntimeCoordinator.documentationProviderServiceIsConfigured(config: config) {
            return "pending"
        }
        return "disabled"
    }

    package static func additionalPermissionDialogExecutableCandidates(
        config: ProxyConfig,
        executableLookupClient: ExecutableLookupClient = .liveValue
    ) -> [String] {
        var candidates: [String] = []
        if let resolvedUpstreamCommand = executableLookupClient.resolveExecutablePath(config.upstreamCommand) {
            candidates.append(resolvedUpstreamCommand)
        }

        if let xcrunInvocation = xcrunInvocation(from: config, executableLookupClient: executableLookupClient) {
            candidates.append(xcrunInvocation.commandPath)
            if let toolResolution = resolvedXcrunTool(
                from: xcrunInvocation.arguments,
                xcrunCommandPath: xcrunInvocation.commandPath,
                executableLookupClient: executableLookupClient
            ) {
                candidates.append(toolResolution)
            }
        }

        return candidates
    }

    private static func xcrunInvocation(
        from config: ProxyConfig,
        executableLookupClient: ExecutableLookupClient
    ) -> (commandPath: String, arguments: [String])? {
        if let resolvedCommand = executableLookupClient.resolveExecutablePath(config.upstreamCommand),
           resolvedCommand.hasSuffix("/xcrun") {
            return (resolvedCommand, config.upstreamArgs)
        }

        guard let xcrunIndex = config.upstreamArgs.firstIndex(where: { argument in
            if argument == "xcrun" {
                return true
            }
            guard let resolved = executableLookupClient.resolveExecutablePath(argument) else {
                return false
            }
            return resolved.hasSuffix("/xcrun")
        }) else {
            return nil
        }

        let commandArgument = config.upstreamArgs[xcrunIndex]
        let resolvedCommand = executableLookupClient.resolveExecutablePath(commandArgument) ?? commandArgument
        let remainingArguments = Array(config.upstreamArgs.dropFirst(xcrunIndex + 1))
        return (resolvedCommand, remainingArguments)
    }

    private static func resolvedXcrunTool(
        from upstreamArgs: [String],
        xcrunCommandPath: String,
        executableLookupClient: ExecutableLookupClient
    ) -> String? {
        guard let selection = XcrunArguments.firstToolSelection(from: upstreamArgs) else {
            return nil
        }
        return executableLookupClient.resolveXcrunToolPath(
            xcrunCommandPath,
            selection.toolName,
            selection.preToolArguments
        )
    }

    private static func permissionDialogAssistantNameCandidates(config: ProxyConfig) -> [String] {
        var candidates = Set<String>(["XcodeMCPKit"])
        if let name = config.initializeParamsOverride?.clientName, name.isEmpty == false {
            candidates.insert(name)
        }
        return Array(candidates)
    }

    private func beginShutdown() -> (
        sessionManager: (any RuntimeCoordinating)?,
        autoApprover: (any ProxyServerPermissionDialogAutoApprover)?,
        channels: [Channel]
    ) {
        runtimeLock.withLock {
            let context = (
                sessionManager: sessionManager,
                autoApprover: permissionDialogAutoApprover,
                channels: channels
            )
            isShuttingDown = true
            sessionManager = nil
            permissionDialogAutoApprover = nil
            return context
        }
    }

    package func setChannelsForStartedServer(_ startedChannels: [Channel]) {
        channels = startedChannels
    }
}

package enum ProxyServerError: Error {
    case failedToBind
    case shutdownInProgress
}

package final class ProxyAcceptedChannelTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]

    func register(_ channel: Channel) {
        let id = ObjectIdentifier(channel)
        lock.withLock {
            channels[id] = channel
        }
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            _ = lock.withLock {
                channels.removeValue(forKey: id)
            }
        }
    }

    func snapshot() -> [Channel] {
        lock.withLock { Array(channels.values) }
    }
}

package final class ProxyAcceptedChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    package typealias InboundIn = Channel

    private let tracker: ProxyAcceptedChannelTracker

    init(tracker: ProxyAcceptedChannelTracker) {
        self.tracker = tracker
    }

    package func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channel = unwrapInboundIn(data)
        tracker.register(channel)
        context.fireChannelRead(data)
    }
}

package protocol ProxyServerPermissionDialogAutoApprover: Sendable {
    func start()
    func stop()
}

extension XcodePermissionDialog.AutoApprover: ProxyServerPermissionDialogAutoApprover {}

package extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
