import Foundation
import Logging
import NIO
import NIOHTTP1
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
        package var makeAutoApprover: @Sendable () -> any ProxyServerPermissionDialogAutoApprover
        package var makeRuntimeCoordinator:
            @Sendable (_ config: ProxyConfig, _ eventLoop: EventLoop) -> any RuntimeCoordinating

        package init(
            discoveryClient: DiscoveryClient = .liveValue,
            executableLookupClient: ExecutableLookupClient = .liveValue,
            processID: @escaping @Sendable () -> Int = {
                Int(ProcessInfo.processInfo.processIdentifier)
            },
            makeAutoApprover: @escaping @Sendable () -> any ProxyServerPermissionDialogAutoApprover,
            makeRuntimeCoordinator: @escaping @Sendable (_ config: ProxyConfig, _ eventLoop: EventLoop) -> any RuntimeCoordinating
        ) {
            self.discoveryClient = discoveryClient
            self.executableLookupClient = executableLookupClient
            self.processID = processID
            self.makeAutoApprover = makeAutoApprover
            self.makeRuntimeCoordinator = makeRuntimeCoordinator
        }

        package static func live(config: ProxyConfig) -> Self {
            let executableLookupClient = ExecutableLookupClient.liveValue
            return Self(
                executableLookupClient: executableLookupClient,
                makeAutoApprover: {
                    let additionalCandidates = ProxyServer.additionalPermissionDialogExecutableCandidates(
                        config: config,
                        executableLookupClient: executableLookupClient
                    )
                    return XcodePermissionDialogAutoApprover(
                        dependencies: .live(
                            agentPathCandidates: {
                                XcodePermissionDialogAutoApprover.defaultAgentPathCandidates(
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
                    RuntimeCoordinator(config: config, eventLoop: eventLoop)
                }
            )
        }
    }

    private let config: ProxyConfig
    private let dependencies: Dependencies
    private let group: EventLoopGroup
    private let refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator
    private let refreshCodeIssuesTargetResolver: RefreshCodeIssuesTargetResolver
    private let refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState
    private var channels: [Channel] = []
    private let logger: Logger = ProxyLogging.make("server")
    private let runtimeLock = NSLock()
    private let runtimeHolder = RuntimeHolder()
    private let acceptedChannelTracker = ProxyAcceptedChannelTracker()
    private var isShuttingDown = false
    private var sessionManager: (any RuntimeCoordinating)?
    private var permissionDialogAutoApprover: (any ProxyServerPermissionDialogAutoApprover)?

    public convenience init(config: ProxyConfig) {
        self.init(config: config, dependencies: .live(config: config))
    }

    package init(config: ProxyConfig, dependencies: Dependencies) {
        self.config = config
        self.dependencies = dependencies
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.refreshCodeIssuesCoordinator = RefreshCodeIssuesCoordinator.makeDefault()
        self.refreshCodeIssuesTargetResolver = RefreshCodeIssuesTargetResolver()
        self.refreshCodeIssuesDebugState = RefreshCodeIssuesDebugState(
            defaultRequestTimeoutSeconds: config.requestTimeout
        )
    }

    public func run() async throws {
        _ = try startAndWriteDiscovery()
        try await wait()
    }

    public func startAndWriteDiscovery() throws -> (host: String, port: Int) {
        let channel = try start()
        let (host, port) = resolvedListenAddress(for: channel)
        let displayHost = config.listenHost == "localhost" ? "localhost" : host
        writeDiscovery(resolvedHost: host, port: port)
        logger.info("\(Self.listeningLogLine(displayHost: displayHost, port: port))")
        return (host, port)
    }

    public func wait() async throws {
        try await waitForHTTP()
    }

    public func start() throws -> Channel {
        let logger = self.logger
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .serverChannelInitializer { [acceptedChannelTracker] channel in
                channel.pipeline.addHandler(ProxyAcceptedChannelHandler(tracker: acceptedChannelTracker))
            }
            .childChannelInitializer {
                [runtimeHolder, config, refreshCodeIssuesCoordinator, refreshCodeIssuesTargetResolver, refreshCodeIssuesDebugState, logger] channel in
                runtimeHolder.sessionManager(on: channel.eventLoop).flatMap { sessionManager in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.pipeline.addHandler(
                            HTTPHandler(
                                config: config,
                                sessionManager: sessionManager,
                                refreshCodeIssuesCoordinator: refreshCodeIssuesCoordinator,
                                refreshCodeIssuesTargetResolver: refreshCodeIssuesTargetResolver,
                                refreshCodeIssuesDebugState: refreshCodeIssuesDebugState
                            )
                        )
                    }
                }.flatMapError { error in
                    if case RuntimeHolderError.shuttingDown = error {
                        channel.close(mode: .all, promise: nil)
                        return channel.eventLoop.makeSucceededFuture(())
                    }

                    logger.warning(
                        "Child channel initialization failed.",
                        metadata: [
                            "error": "\(error)"
                        ]
                    )
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let boundChannels = try bindChannels(using: bootstrap)
        guard installBoundChannelsAndPrepareRuntime(boundChannels) else {
            for channel in boundChannels {
                channel.close(promise: nil)
            }
            throw ProxyServerError.shutdownInProgress
        }
        guard let first = boundChannels.first else {
            throw ProxyServerError.failedToBind
        }
        return first
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

    private func bindChannels(using bootstrap: ServerBootstrap) throws -> [Channel] {
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
        guard let selection = firstXcrunToolSelection(from: upstreamArgs) else {
            return nil
        }
        return executableLookupClient.resolveXcrunToolPath(
            xcrunCommandPath,
            selection.toolName,
            selection.preToolArguments
        )
    }

    package static func firstXcrunToolSelection(from args: [String]) -> (toolName: String, preToolArguments: [String])? {
        let flagsWithValues: Set<String> = [
            "-sdk", "--sdk",
            "-toolchain", "--toolchain",
        ]

        var index = 0
        while index < args.count {
            let argument = args[index]
            if flagsWithValues.contains(argument) {
                index += 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            return (argument, Array(args.prefix(index)))
        }

        return nil
    }

    private static func permissionDialogAssistantNameCandidates(config: ProxyConfig) -> [String] {
        var candidates = Set<String>(["XcodeMCPKit"])
        let override = ProxyFileConfigLoader.loadInitializeParamsOverride(
            configPath: config.configPath,
            logger: ProxyLogging.make("config")
        )
        if case .object(let clientInfo)? = override?["clientInfo"],
           case .string(let name)? = clientInfo["name"],
           name.isEmpty == false {
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
            runtimeHolder.beginShutdown()
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

    private func installBoundChannelsAndPrepareRuntime(_ boundChannels: [Channel]) -> Bool {
        runtimeLock.withLock {
            guard isShuttingDown == false else {
                return false
            }

            channels = boundChannels

            if let sessionManager {
                runtimeHolder.activate(sessionManager)
                return true
            }

            if config.autoApproveXcodeDialog {
                let autoApprover = dependencies.makeAutoApprover()
                autoApprover.start()
                permissionDialogAutoApprover = autoApprover
            }

            let sessionManager = dependencies.makeRuntimeCoordinator(config, group.next())
            self.sessionManager = sessionManager
            runtimeHolder.activate(sessionManager)
            return true
        }
    }
}

private enum ProxyServerError: Error {
    case failedToBind
    case shutdownInProgress
}

private enum RuntimeHolderError: Error {
    case shuttingDown
}

private final class ProxyAcceptedChannelTracker: @unchecked Sendable {
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

private final class ProxyAcceptedChannelHandler: ChannelInboundHandler, @unchecked Sendable {
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

private final class RuntimeHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionManager: (any RuntimeCoordinating)?
    private var waiters: [EventLoopPromise<any RuntimeCoordinating>] = []
    private var isShuttingDown = false

    func sessionManager(on eventLoop: EventLoop) -> EventLoopFuture<any RuntimeCoordinating> {
        lock.withLock {
            if isShuttingDown {
                return eventLoop.makeFailedFuture(RuntimeHolderError.shuttingDown)
            }
            if let sessionManager {
                return eventLoop.makeSucceededFuture(sessionManager)
            }
            let promise = eventLoop.makePromise(of: (any RuntimeCoordinating).self)
            waiters.append(promise)
            return promise.futureResult
        }
    }

    func activate(_ sessionManager: any RuntimeCoordinating) {
        let waiters = lock.withLock { () -> [EventLoopPromise<any RuntimeCoordinating>] in
            guard isShuttingDown == false else {
                return []
            }
            self.sessionManager = sessionManager
            let waiters = self.waiters
            self.waiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.succeed(sessionManager)
        }
    }

    func beginShutdown() {
        let waiters = lock.withLock { () -> [EventLoopPromise<any RuntimeCoordinating>] in
            isShuttingDown = true
            sessionManager = nil
            let waiters = self.waiters
            self.waiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.fail(RuntimeHolderError.shuttingDown)
        }
    }
}

package protocol ProxyServerPermissionDialogAutoApprover: Sendable {
    func start()
    func stop()
}

extension XcodePermissionDialogAutoApprover: ProxyServerPermissionDialogAutoApprover {}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
