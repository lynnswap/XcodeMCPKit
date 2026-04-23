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
        package var makeAutoApprover: @Sendable () -> any ProxyServerPermissionDialogAutoApprover
        package var makeRuntimeCoordinator:
            @Sendable (_ config: ProxyConfig, _ eventLoop: EventLoop) -> any RuntimeCoordinating

        package init(
            makeAutoApprover: @escaping @Sendable () -> any ProxyServerPermissionDialogAutoApprover,
            makeRuntimeCoordinator: @escaping @Sendable (_ config: ProxyConfig, _ eventLoop: EventLoop) -> any RuntimeCoordinating
        ) {
            self.makeAutoApprover = makeAutoApprover
            self.makeRuntimeCoordinator = makeRuntimeCoordinator
        }

        package static func live(config: ProxyConfig) -> Self {
            return Self(
                makeAutoApprover: {
                    let additionalCandidates = ProxyServer.additionalPermissionDialogExecutableCandidates(config: config)
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
        self.refreshCodeIssuesCoordinator = RefreshCodeIssuesCoordinator.makeDefault(
            requestTimeout: config.requestTimeout
        )
        self.refreshCodeIssuesTargetResolver = RefreshCodeIssuesTargetResolver()
        self.refreshCodeIssuesDebugState = RefreshCodeIssuesDebugState(
            maxPendingPerKey: refreshCodeIssuesCoordinator.maxPendingPerKey,
            maxPendingTotal: refreshCodeIssuesCoordinator.maxPendingTotal,
            queueWaitTimeoutSeconds: refreshCodeIssuesCoordinator.queueWaitTimeoutSeconds
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

    public func shutdownGracefully() -> EventLoopFuture<Void> {
        let promise = group.next().makePromise(of: Void.self)
        let shutdownContext = beginShutdown()
        shutdownContext.autoApprover?.stop()
        shutdownContext.sessionManager?.shutdown()
        for channel in shutdownContext.channels {
            channel.close(promise: nil)
        }
        group.shutdownGracefully { error in
            if let error {
                promise.fail(error)
            } else {
                promise.succeed(())
            }
        }
        return promise.futureResult
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
        guard let record = Discovery.makeRecord(
            host: discoveryHost(resolvedHost),
            port: port,
            pid: Int(ProcessInfo.processInfo.processIdentifier)
        ) else {
            return
        }
        do {
            try Discovery.write(record: record, overrideURL: config.discoveryFileURL)
        } catch {
            logger.warning(
                "Failed to write discovery file",
                metadata: [
                    "error": "\(error)",
                    "path": "\(config.discoveryFileURL?.path ?? Discovery.defaultFileURL.path)",
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

    package static func additionalPermissionDialogExecutableCandidates(config: ProxyConfig) -> [String] {
        var candidates: [String] = []
        if let resolvedUpstreamCommand = resolvedExecutablePath(for: config.upstreamCommand) {
            candidates.append(resolvedUpstreamCommand)
        }

        if let xcrunInvocation = xcrunInvocation(from: config) {
            candidates.append(xcrunInvocation.commandPath)
            if let toolResolution = resolvedXcrunTool(
                from: xcrunInvocation.arguments,
                xcrunCommandPath: xcrunInvocation.commandPath
            ) {
                candidates.append(toolResolution)
            }
        }

        return candidates
    }

    private static func xcrunInvocation(from config: ProxyConfig) -> (commandPath: String, arguments: [String])? {
        if let resolvedCommand = resolvedExecutablePath(for: config.upstreamCommand),
           resolvedCommand.hasSuffix("/xcrun") {
            return (resolvedCommand, config.upstreamArgs)
        }

        guard let xcrunIndex = config.upstreamArgs.firstIndex(where: { argument in
            if argument == "xcrun" {
                return true
            }
            guard let resolved = resolvedExecutablePath(for: argument) else {
                return false
            }
            return resolved.hasSuffix("/xcrun")
        }) else {
            return nil
        }

        let commandArgument = config.upstreamArgs[xcrunIndex]
        let resolvedCommand = resolvedExecutablePath(for: commandArgument) ?? commandArgument
        let remainingArguments = Array(config.upstreamArgs.dropFirst(xcrunIndex + 1))
        return (resolvedCommand, remainingArguments)
    }

    private static func resolvedXcrunTool(
        from upstreamArgs: [String],
        xcrunCommandPath: String
    ) -> String? {
        guard let selection = firstXcrunToolSelection(from: upstreamArgs) else {
            return nil
        }
        return resolvedXcrunToolPath(
            xcrunCommandPath: xcrunCommandPath,
            toolName: selection.toolName,
            preToolArguments: selection.preToolArguments
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

    private static func resolvedExecutablePath(for command: String) -> String? {
        guard command.isEmpty == false else {
            return nil
        }

        if command.contains("/") {
            return URL(fileURLWithPath: command).standardizedFileURL.path
        }

        let pathValue =
            ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        for directory in pathValue.split(separator: ":").map(String.init) where directory.isEmpty == false {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func resolvedXcrunToolPath(
        xcrunCommandPath: String,
        toolName: String,
        preToolArguments: [String]
    ) -> String? {
        let executablePath: String
        if xcrunCommandPath.contains("/") {
            executablePath = URL(fileURLWithPath: xcrunCommandPath).standardizedFileURL.path
        } else if let resolvedCommandPath = resolvedExecutablePath(for: xcrunCommandPath) {
            executablePath = resolvedCommandPath
        } else {
            executablePath = "/usr/bin/xcrun"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = preToolArguments + ["--find", toolName]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              output.isEmpty == false else {
            return nil
        }
        return output
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
