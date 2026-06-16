import Foundation
import Logging
import NIO
import NIOFoundationCompat
import NIOConcurrencyHelpers
import ProxyCore
import ProxyMCP

package final class SessionContext: Sendable {
    package let id: String
    package let router: ProxyRouter
    package let notificationHub: NotificationHub

    package init(id: String, config: ProxyConfig) {
        self.id = id
        self.notificationHub = NotificationHub()
        self.router = ProxyRouter(
            requestTimeout: makeRequestTimeout(config.requestTimeout),
            hasActiveClients: { [weak notificationHub] in
                notificationHub?.hasClients ?? false
            },
            sendNotification: { [weak notificationHub] data in
                notificationHub?.broadcast(data)
            }
        )
    }
}

package final class WeakRuntimeCoordinatorBox: @unchecked Sendable {
    weak var value: RuntimeCoordinator?

    package init() {}
}

/// The single routing decision for a DocumentationSearch tools/call:
/// either the provider produced the response, or proxy-managed
/// DocumentationSearch is unavailable.
package enum DocumentationSearchOutcome: Sendable {
    case handled(Data)
    case unavailable(DocumentationProviderUnavailableReason)
}

package protocol RuntimeCoordinating: Sendable {
    func start()
    func session(id: String) -> SessionContext
    func hasSession(id: String) -> Bool
    func negotiatedProtocolVersion(id: String) -> String?
    func markNotificationClientConnected(sessionID: String)
    func removeSession(id: String)
    func debugReset()
    func shutdown() async
    func isInitialized() -> Bool
    func cachedToolsListResult() -> JSONValue?
    func setCachedToolsListResult(_ result: JSONValue, sourceUpstream: Int)
    func registerInitialize(
        sessionID: String,
        originalID: RPCID,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer>
    func sharedToolsList(
        sessionID: String,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue
    func liveXcodeListWindowsResult(
        route: ControlPlaneRoute,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue
    func callDocumentationSearch(
        requestData: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationSearchOutcome
    func hasDocumentationProvider() -> Bool
    func chooseUpstreamIndex() -> Int?
    func enqueueOnUpstreamSlot<Output: Sendable>(
        leaseID: RequestLeaseID,
        descriptor: SessionPipelineRequestDescriptor,
        on eventLoop: EventLoop,
        preferredUpstreamIndex: Int?,
        starter: @escaping @Sendable (Int) -> EventLoopFuture<Output>
    ) -> EventLoopFuture<Output>
    func assignUpstreamID(sessionID: String, originalID: RPCID, upstreamIndex: Int) -> Int64
    func removeUpstreamIDMapping(sessionID: String, requestIDKey: String, upstreamIndex: Int)
    func onRequestTimeout(sessionID: String, requestIDKey: String, upstreamIndex: Int)
    func onRequestSucceeded(sessionID: String, requestIDKey: String, upstreamIndex: Int)
    func sendUpstream(_ data: Data, upstreamIndex: Int, ensureRunning: Bool)
    func debugSnapshot() -> ProxyDebugSnapshot
    func debugSnapshot(includeSensitiveDebugPayloads: Bool) -> ProxyDebugSnapshot
    func createRequestLease(descriptor: SessionPipelineRequestDescriptor) -> RequestLeaseID
    func activateRequestLease(
        _ leaseID: RequestLeaseID,
        requestIDKey: String?,
        upstreamIndex: Int?,
        timeout: TimeAmount?
    )
    func completeRequestLease(_ leaseID: RequestLeaseID)
    func requeueRequestLease(_ leaseID: RequestLeaseID)
    func failRequestLease(
        _ leaseID: RequestLeaseID,
        terminalState: RequestLeaseState,
        reason: RequestLeaseReleaseReason
    )
    func handleRequestLeaseTimeout(
        _ leaseID: RequestLeaseID,
        sessionID: String,
        requestIDKeys: [String],
        upstreamIndex: Int
    )
    func abandonRequestLease(
        _ leaseID: RequestLeaseID,
        sessionID: String,
        requestIDKeys: [String],
        upstreamIndex: Int?
    )
}

extension RuntimeCoordinating {
    package func start() {}

    package func negotiatedProtocolVersion(id _: String) -> String? {
        nil
    }

    package func markNotificationClientConnected(sessionID _: String) {}

    package func hasDocumentationProvider() -> Bool {
        false
    }

    func sendUpstream(_ data: Data, upstreamIndex: Int) {
        sendUpstream(data, upstreamIndex: upstreamIndex, ensureRunning: false)
    }

    func enqueueOnUpstreamSlot<Output: Sendable>(
        leaseID: RequestLeaseID,
        descriptor: SessionPipelineRequestDescriptor,
        on eventLoop: EventLoop,
        starter: @escaping @Sendable (Int) -> EventLoopFuture<Output>
    ) -> EventLoopFuture<Output> {
        enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop,
            preferredUpstreamIndex: nil,
            starter: starter
        )
    }

    func debugSnapshot() -> ProxyDebugSnapshot {
        debugSnapshot(includeSensitiveDebugPayloads: false)
    }

    package func callDocumentationSearch(
        requestData _: Data,
        requestTimeoutOverride _: TimeAmount?
    ) async throws -> DocumentationSearchOutcome {
        .unavailable(.noAvailableProvider)
    }
}

package final class RuntimeCoordinator: Sendable, RuntimeCoordinating {
    static let redactedDebugText = "<redacted>"

    struct TestSnapshot: Sendable {
        struct Upstream: Sendable {
            let isInitialized: Bool
            let initInFlight: Bool
            let healthState: UpstreamHealthState
        }

        struct Session: Sendable {
            let generation: UInt64
        }

        let hasInitResult: Bool
        let initInFlight: Bool
        let didWarmSecondary: Bool
        let shouldRetryEagerInitializePrimaryAfterWarmInitFailure: Bool
        let upstreams: [Upstream]
    }

    package let sessionRegistry: SessionRegistry
    package let initializeManager: InitializeManager
    package let upstreamTaskBox = NIOLockedValueBox<[Task<Void, Never>]>([])
    package let upstreamStderrLogLimiter = UpstreamStderrLogLimiter()
    package let primaryInitializeReadinessTokenBox =
        NIOLockedValueBox<UpstreamReadinessWaiterToken?>(nil)
    package let documentationPrewarmTaskBox = NIOLockedValueBox<Task<Void, Never>?>(nil)
    package let debugRecorder: ProxyDebugRecorder
    package let leaseManager: LeaseManager
    package let eventLoop: EventLoop
    package let upstreamRouter: UpstreamRouter
    package let config: ProxyConfig
    package let logger: Logger = ProxyLogging.make("session")
    package let upstreams: [any UpstreamSlotControlling]
    package let initializeParamsOverride: ProxyInitializeHandshakeOverride?
    package let canonicalBrokerState: CanonicalBrokerState
    package let controlPlaneDebugMirror = ControlPlaneDebugMirror()

    package let upstreamHealthManager: UpstreamHealthManager
    package let upstreamSlotScheduler: UpstreamSlotScheduler
    package let upstreamReadinessGate: UpstreamReadinessGate
    package let upstreamReadinessCoordinator: UpstreamReadinessCoordinator
    package let clock: ClockClient
    package let nowUptimeNanoseconds: @Sendable () -> UInt64
    package let scheduleRuntimeTimeout: @Sendable (TimeAmount, @escaping @Sendable () -> Void) ->
        RuntimeScheduledTimeout
    package let controlPlaneCoordinator: ControlPlaneCoordinator
    package let documentationProviderManager: (any DocumentationProviderManaging)?
    package let prewarmDocumentationProviderOnStartup: Bool
    private let lifecycleStartedBox = NIOLockedValueBox(false)

    /// Composition-root entry point: the Xcode-specific readiness gate and
    /// target discovery are injected because their live implementations
    /// live above this module (ProxyXcodeSupport).
    package convenience init(
        config: ProxyConfig,
        eventLoop: EventLoop,
        upstreamReadinessGate: UpstreamReadinessGate? = nil,
        xcodeTargetDiscovery: (any XcodeTargetDiscovering)? = nil,
        startImmediately: Bool = true
    ) {
        let count = max(1, min(config.upstreamProcessCount, 10))
        let upstreams = Self.makeDefaultUpstreams(
            config: config, sharedSessionID: config.upstreamSessionID, count: count)
        let clock = ClockClient.liveValue
        let documentationProviderManager = xcodeTargetDiscovery.flatMap { discovery in
            Self.makeDefaultDocumentationProviderManager(config: config, discovery: discovery)
        }
        self.init(
            config: config,
            eventLoop: eventLoop,
            upstreams: upstreams,
            clock: clock,
            upstreamReadinessGate: upstreamReadinessGate,
            documentationProviderManager: documentationProviderManager,
            prewarmDocumentationProviderOnStartup: documentationProviderManager != nil,
            startImmediately: startImmediately
        )
    }

    package static func makeDefaultDocumentationProviderManager(
        config: ProxyConfig,
        discovery: any XcodeTargetDiscovering
    ) -> (any DocumentationProviderManaging)? {
        guard config.disabledToolNames.contains(DocumentationToolCatalog.toolName) == false else {
            return nil
        }
        guard XcrunArguments.isDefaultMCPBridgeInvocation(config: config) else {
            return nil
        }
        let environment = ProcessInfo.processInfo.environment
        let pinnedProcessID = environment["MCP_XCODE_PID"].flatMap(pid_t.init)
        return DocumentationProviderManager(
            discovery: discovery,
            sessionFactory: LiveDocumentationProviderSessionFactory(baseEnvironment: environment),
            pinnedProcessID: pinnedProcessID,
            initializeParams: InitializeHandshakeJSON.resolved(
                initializeParamsOverride: config.initializeParamsOverride
            )
        )
    }

    package init(
        config: ProxyConfig,
        eventLoop: EventLoop,
        upstreams: [any UpstreamSlotControlling],
        clock: ClockClient = .liveValue,
        upstreamReadinessGate: UpstreamReadinessGate? = nil,
        nowUptimeNanoseconds: (@Sendable () -> UInt64)? = nil,
        scheduleRuntimeTimeout: (@Sendable (TimeAmount, @escaping @Sendable () -> Void) ->
            RuntimeScheduledTimeout)? = nil,
        documentationProviderManager: (any DocumentationProviderManaging)? = nil,
        prewarmDocumentationProviderOnStartup: Bool = false,
        startImmediately: Bool = true
    ) {
        precondition(!upstreams.isEmpty, "upstreams must not be empty")
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let uptimeProvider = nowUptimeNanoseconds ?? clock.uptimeNanoseconds
        let runtimeClock = ClockClient(
            now: clock.now,
            uptimeNanoseconds: uptimeProvider,
            sleep: clock.sleep,
            sleepForTimeInterval: clock.sleepForTimeInterval
        )
        let timeoutScheduler = scheduleRuntimeTimeout
            ?? { delay, operation in
                RuntimeScheduledTimeout.schedule(
                    on: eventLoop,
                    in: delay,
                    operation: operation
                )
            }
        self.config = config
        self.eventLoop = eventLoop
        self.upstreams = upstreams
        self.clock = runtimeClock
        let brokerState = CanonicalBrokerState()
        self.canonicalBrokerState = brokerState
        self.initializeManager = InitializeManager(brokerState: brokerState)
        self.sessionRegistry = SessionRegistry(config: config)
        self.debugRecorder = ProxyDebugRecorder(upstreamCount: upstreams.count)
        self.leaseManager = LeaseManager()
        self.upstreamRouter = UpstreamRouter(upstreamCount: upstreams.count)
        self.upstreamHealthManager = UpstreamHealthManager(upstreamCount: upstreams.count)
        self.nowUptimeNanoseconds = uptimeProvider
        self.scheduleRuntimeTimeout = timeoutScheduler
        self.documentationProviderManager = documentationProviderManager
        self.prewarmDocumentationProviderOnStartup = prewarmDocumentationProviderOnStartup
        let resolvedReadinessGate = upstreamReadinessGate
            ?? .alwaysReady(uptimeNanoseconds: runtimeClock.uptimeNanoseconds)
        self.upstreamReadinessGate = resolvedReadinessGate
        self.upstreamReadinessCoordinator = UpstreamReadinessCoordinator(
            gate: resolvedReadinessGate,
            logger: ProxyLogging.make("upstream.readiness")
        )
        self.upstreamSlotScheduler = UpstreamSlotScheduler(
            canUseUpstream: { [weak upstreamHealthManager = self.upstreamHealthManager] upstreamIndex in
                let nowUptimeNs = uptimeProvider()
                guard let upstreamHealthManager else {
                    return UpstreamUseEvaluation(isUsable: false, effects: [])
                }
                return upstreamHealthManager.evaluateUsableInitialized(
                    index: upstreamIndex,
                    nowUptimeNs: nowUptimeNs
                )
            },
            selectUpstream: { [weak upstreamHealthManager = self.upstreamHealthManager] occupied in
                let nowUptimeNs = uptimeProvider()
                return upstreamHealthManager?.chooseBestInitializedUpstream(
                    nowUptimeNs: nowUptimeNs,
                    occupiedUpstreams: occupied
                ) ?? UpstreamSelectionResult(upstreamIndex: nil, effects: [])
            },
            applyHealthEffects: { [runtimeBox] effects in
                runtimeBox.value?.applyHealthEffects(effects)
            }
        )
        self.initializeParamsOverride = config.initializeParamsOverride
        self.controlPlaneCoordinator = ControlPlaneCoordinator(
            brokerState: self.canonicalBrokerState,
            debugMirror: self.controlPlaneDebugMirror,
            toolsCatalogLoader: { [runtimeBox] requestTimeout, rpcHandle in
                guard let runtime = runtimeBox.value else {
                    throw CancellationError()
                }
                return try await runtime.loadCanonicalToolsCatalog(
                    requestTimeout: requestTimeout,
                    rpcHandle: rpcHandle
                )
            },
            windowsLoader: { [runtimeBox] route, requestTimeout, rpcHandle in
                guard let runtime = runtimeBox.value else {
                    throw CancellationError()
                }
                return try await runtime.loadLiveXcodeListWindows(
                    route: route,
                    requestTimeout: requestTimeout,
                    rpcHandle: rpcHandle
                )
            },
            upstreamHandshakeStates: { [weak upstreamHealthManager = self.upstreamHealthManager] in
                guard let upstreamHealthManager else { return [:] }
                let states = upstreamHealthManager.statesSnapshot()
                return Dictionary(uniqueKeysWithValues: states.enumerated().map { index, state in
                    let summary: String
                    if state.initInFlight {
                        summary = "initializing"
                    } else if state.isInitialized {
                        summary = "initialized"
                    } else {
                        summary = "idle"
                    }
                    return ("\(index)", summary)
                })
            },
            logger: ProxyLogging.make("control-plane"),
            controlPlaneDefaultTimeout: MCPMethodDispatcher.timeoutForControlPlane(
                defaultSeconds: config.requestTimeout
            ),
            clock: runtimeClock
        )
        runtimeBox.value = self

        var tasks: [Task<Void, Never>] = []
        tasks.reserveCapacity(upstreams.count)
        for (upstreamIndex, upstream) in upstreams.enumerated() {
            let task = Task { [weak self] in
                guard let self else { return }
                for await event in upstream.events {
                    switch event {
                    case .message(let data):
                        self.routeUpstreamMessage(data, upstreamIndex: upstreamIndex)
                    case .stderr(let message):
                        self.handleUpstreamStderr(message, upstreamIndex: upstreamIndex)
                    case .stdoutProtocolViolation(let protocolViolation):
                        self.handleUpstreamProtocolViolation(
                            protocolViolation,
                            upstreamIndex: upstreamIndex
                        )
                    case .stdoutBufferSize(let size):
                        self.handleBufferedStdoutBytes(size, upstreamIndex: upstreamIndex)
                    case .exit(let status):
                        self.handleUpstreamExit(status, upstreamIndex: upstreamIndex)
                    }
                }
            }
            tasks.append(task)
        }
        upstreamTaskBox.withLockedValue { taskBox in
            taskBox = tasks
        }

        if startImmediately {
            start()
        }
    }

    package func start() {
        let shouldStart = lifecycleStartedBox.withLockedValue { started in
            guard started == false else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        startEagerInitializePrimary()
        if prewarmDocumentationProviderOnStartup {
            prewarmDocumentationProvider()
        }
    }

    package func session(id: String) -> SessionContext {
        sessionRegistry.session(id: id)
    }

    package func hasSession(id: String) -> Bool {
        sessionRegistry.hasSession(id: id)
    }

    package func negotiatedProtocolVersion(id: String) -> String? {
        sessionRegistry.negotiatedProtocolVersion(id: id)
    }

    package func removeSession(id: String) {
        let context = sessionRegistry.removeSession(id: id)
        context?.notificationHub.closeAll()
    }

    package func debugReset() {
        let initializeReset = initializeManager.resetForDebug()
        initializeReset.timeout?.cancel()
        for pending in initializeReset.pending {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }

        let initTimeouts = upstreamHealthManager.resetForDebug()
        for timeout in initTimeouts {
            timeout?.cancel()
        }

        let sessions = sessionRegistry.removeAllSessions()
        for session in sessions {
            session.notificationHub.closeAll()
        }

        upstreamRouter.resetAll()
        _ = leaseManager.resetAll(reason: .clientDisconnected)
        upstreamSlotScheduler.reset()
        resetUpstreamReadinessWaiters()
        cancelPrimaryInitializeReadinessWaiter()
        debugRecorder.resetAll()
        upstreamStderrLogLimiter.reset()
        invalidateControlPlane(
            reason: "debug_reset",
            clearInitialize: true,
            clearToolsCatalog: true
        )
        canonicalBrokerState.reset()
    }

    package func shutdown() async {
        let shutdownState = initializeManager.beginShutdown()
        let pendingInitializes = shutdownState.pending
        for pending in pendingInitializes {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }
        shutdownState.timeout?.cancel()

        let upstreamTimeouts = upstreamHealthManager.clearInitTimeoutsForShutdown()
        for timeout in upstreamTimeouts {
            timeout?.cancel()
        }
        let documentationPrewarmTask = documentationPrewarmTaskBox.withLockedValue { taskBox in
            let task = taskBox
            taskBox = nil
            return task
        }
        documentationPrewarmTask?.cancel()
        upstreamReadinessCoordinator.shutdown()

        canonicalBrokerState.reset()
        await controlPlaneCoordinator.invalidate(
            reason: "shutdown",
            clearInitialize: true,
            clearToolsCatalog: true
        )

        let tasks = upstreamTaskBox.withLockedValue { taskBox -> [Task<Void, Never>] in
            let current = taskBox
            taskBox = []
            return current
        }
        for task in tasks {
            task.cancel()
        }
        await withTaskGroup(of: Void.self) { group in
            for upstream in upstreams {
                group.addTask {
                    await upstream.stop()
                }
            }
            if let documentationProviderManager {
                group.addTask {
                    await documentationProviderManager.shutdown()
                }
            }
            if let documentationPrewarmTask {
                group.addTask {
                    await documentationPrewarmTask.value
                }
            }
        }
        for task in tasks {
            await task.value
        }
    }

    package func isInitialized() -> Bool {
        initializeManager.isInitialized()
    }

    package func cachedToolsListResult() -> JSONValue? {
        canonicalBrokerState.toolsCatalogRaw()
    }

    package func setCachedToolsListResult(_ result: JSONValue, sourceUpstream: Int) {
        guard isValidToolsListResult(result) else { return }
        canonicalBrokerState.syncCanonicalToolsCatalog(
            result,
            sourceUpstream: sourceUpstream
        )
    }

    package func refreshToolsListIfNeeded() {
        guard config.prewarmToolsList, isInitialized() else { return }
        let deadline = timeoutDeadline(
            for: MCPMethodDispatcher.timeoutForControlPlane(
                defaultSeconds: config.requestTimeout
            )
        )
        Task { [weak self] in
            await self?.controlPlaneCoordinator.prewarmToolsCatalogIfNeeded(
                deadlineUptimeNs: deadline
            )
        }
    }

    package func prewarmDocumentationProvider() {
        guard let documentationProviderManager else { return }
        let timeoutSeconds = config.requestTimeout > 0
            ? min(config.requestTimeout, 30)
            : 30
        let timeout = MCPMethodDispatcher.timeoutForControlPlane(defaultSeconds: timeoutSeconds)
        let task = Task { [weak self, documentationProviderManager, logger] in
            guard !Task.isCancelled else { return }
            logger.debug(
                "Prewarming documentation provider",
                metadata: [
                    "timeout_seconds": .string("\(timeoutSeconds)"),
                ]
            )
            let update = await documentationProviderManager.prewarm(requestTimeout: timeout)
            self?.recordDocumentationToolListUpdate(update)
            guard !Task.isCancelled else { return }
            logger.debug("Documentation provider prewarm completed")
        }
        let previous = documentationPrewarmTaskBox.withLockedValue { taskBox in
            let previous = taskBox
            taskBox = task
            return previous
        }
        previous?.cancel()
    }

    package func chooseUpstreamIndex() -> Int? {
        let nowUptimeNs = nowUptimeNanoseconds()
        let occupiedUpstreams = upstreamSlotScheduler.occupiedUpstreamIndices()

        let chooseResult = upstreamHealthManager.chooseBestInitializedUpstream(
            nowUptimeNs: nowUptimeNs,
            occupiedUpstreams: occupiedUpstreams
        )
        applyHealthEffects(chooseResult.effects)
        let chosen = chooseResult.upstreamIndex

        guard let chosen else {
            return nil
        }

        return chosen
    }

    private func applyHealthEffects(_ effects: [UpstreamHealthEffect]) {
        for effect in effects {
            switch effect {
            case .cancelInitTimeout(let timeout):
                timeout.cancel()
            case .startHealthProbe(let probe):
                probeUpstreamHealth(
                    upstreamIndex: probe.upstreamIndex,
                    probeGeneration: probe.probeGeneration
                )
            case .clearPins:
                break
            case .failQueuedIfNoRecovery:
                failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
            }
        }
    }

    private func startHealthProbes(_ probes: [HealthProbeRequest]) {
        for probe in probes {
            probeUpstreamHealth(
                upstreamIndex: probe.upstreamIndex,
                probeGeneration: probe.probeGeneration
            )
        }
    }

    package func enqueueOnUpstreamSlot<Output: Sendable>(
        leaseID: RequestLeaseID,
        descriptor: SessionPipelineRequestDescriptor,
        on eventLoop: EventLoop,
        preferredUpstreamIndex: Int? = nil,
        starter: @escaping @Sendable (Int) -> EventLoopFuture<Output>
    ) -> EventLoopFuture<Output> {
        let hasHealthyUpstream = upstreamHealthManager.initializedHealthyishCount() > 0
        var recoveryInFlight = upstreamHealthManager.anyRecoveryInFlight()
        if hasHealthyUpstream == false, recoveryInFlight == false,
            initializeManager.consumeWarmInitRecoveryIntent(policy: .regardlessOfCachedInitialize)
        {
            startPrimaryEagerRetry()
            recoveryInFlight = upstreamHealthManager.anyRecoveryInFlight()
        }
        guard hasHealthyUpstream || recoveryInFlight else {
            _ = chooseUpstreamIndex()
            return eventLoop.makeFailedFuture(UpstreamSlotAcquisitionError.unavailable)
        }
        let promise = eventLoop.makePromise(of: Output.self)
        upstreamSlotScheduler.enqueueRequest(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop,
            preferredUpstreamIndex: preferredUpstreamIndex,
            starter: { upstreamIndex in
                starter(upstreamIndex).cascade(to: promise)
            },
            failUnavailable: {
                promise.fail(UpstreamSlotAcquisitionError.unavailable)
            },
            failCancelled: {
                promise.fail(CancellationError())
            }
        )
        return promise.futureResult
    }

    func sessionStillMatchesPendingInitialize(
        sessionID: String,
        sessionGeneration: UInt64
    ) -> Bool {
        sessionRegistry.sessionStillMatchesPendingInitialize(
            sessionID: sessionID,
            sessionGeneration: sessionGeneration
        )
    }

    package func registerInitialize(
        sessionID: String,
        originalID: RPCID,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        registerInitializeWaiter(
            sessionID: sessionID,
            originalID: originalID,
            requestObject: requestObject,
            on: eventLoop
        )
    }

    func registerInitializeWaiter(
        sessionID: String,
        originalID: RPCID,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        _ = session(id: sessionID)
        let sessionGeneration = sessionRegistry.generation(of: sessionID) ?? 0
        let decision = initializeManager.registerInitialize(
            sessionID: sessionID,
            sessionGeneration: sessionGeneration,
            originalID: originalID,
            on: eventLoop
        )
        let cachedResult = decision.cachedResult
        let shuttingDown = decision.isShuttingDown
        let pendingPromise = decision.promise
        let shouldSend = decision.shouldSendRequest
        let shouldScheduleTimeout = decision.shouldScheduleTimeout

        if shouldScheduleTimeout {
            scheduleInitTimeout()
        }

        if let cachedResult {
            _ = session(id: sessionID)
            sessionRegistry.markInitialized(
                id: sessionID,
                negotiatedProtocolVersion: Self.protocolVersion(fromInitializeResult: cachedResult),
                buffersUnmappedNotificationsUntilClientConnects: true
            )
            if let buffer = encodeInitializeResponse(originalID: originalID, result: cachedResult) {
                return eventLoop.makeSucceededFuture(buffer)
            }
            return eventLoop.makeFailedFuture(TimeoutError())
        }

        if shuttingDown {
            return eventLoop.makeFailedFuture(TimeoutError())
        }

        if pendingPromise != nil {
            _ = session(id: sessionID)
        }

        if shouldSend {
            startPrimaryInitializeRequestWhenReady()
        }

        guard let promise = pendingPromise else {
            return eventLoop.makeFailedFuture(TimeoutError())
        }
        return promise.futureResult
    }

    package func registerInitialize(
        originalID: RPCID,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        registerInitialize(
            sessionID: "__initialize_pending__:\(originalID.key)",
            originalID: originalID,
            requestObject: requestObject,
            on: eventLoop
        )
    }

    package func markNotificationClientConnected(sessionID: String) {
        sessionRegistry.markNotificationClientConnected(id: sessionID)
    }

    package func sharedToolsList(
        sessionID: String,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue {
        _ = session(id: sessionID)
        let timeout =
            requestTimeoutOverride
            ?? MCPMethodDispatcher.timeoutForMethod(
                "tools/list",
                defaultSeconds: config.requestTimeout
            )
        let deadline = timeoutDeadline(for: timeout)
        logger.debug(
            "Loading shared tools/list",
            metadata: [
                "session": .string(sessionID),
                "timeout_ns": .string("\(timeout?.nanoseconds ?? -1)"),
            ]
        )
        let baseResult = try await awaitControlPlaneOperation {
            try await self.controlPlaneCoordinator.toolsCatalog(
                deadlineUptimeNs: deadline
            )
        }
        logger.debug(
            "Loaded base tools/list",
            metadata: [
                "session": .string(sessionID),
                "has_documentation_provider": .string("\(documentationProviderManager != nil)"),
            ]
        )
        guard let documentationProviderManager else {
            return baseResult
        }
        let update = await documentationToolListUpdate(
            manager: documentationProviderManager,
            requestTimeout: timeAmount(until: deadline)
        )
        recordDocumentationToolListUpdate(update)
        logger.debug(
            "Applied documentation provider tools/list overlay",
            metadata: [
                "session": .string(sessionID),
                "update": .string(update.debugLabel),
            ]
        )
        return DocumentationToolCatalog.applying(update, to: baseResult)
    }

    package func liveXcodeListWindowsResult(
        route: ControlPlaneRoute,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue {
        let timeout =
            requestTimeoutOverride
            ?? MCPMethodDispatcher.timeoutForMethod(
                "tools/call",
                defaultSeconds: config.requestTimeout
            )
        let deadline = timeoutDeadline(for: timeout)
        return try await awaitControlPlaneOperation {
            try await self.controlPlaneCoordinator.listWindows(
                route: route,
                deadlineUptimeNs: deadline
            )
        }
    }

    package func callDocumentationSearch(
        requestData: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationSearchOutcome {
        guard let documentationProviderManager else {
            return .unavailable(.noAvailableProvider)
        }
        let timeout =
            requestTimeoutOverride
            ?? MCPMethodDispatcher.timeoutForMethod(
                "tools/call",
                defaultSeconds: config.requestTimeout
            )
        switch try await documentationProviderManager.callDocumentationSearch(
            requestData: requestData,
            requestTimeoutOverride: timeout
        ) {
        case .handled(let data, let invalidatedProvider):
            if invalidatedProvider {
                recordDocumentationProviderInvalidated(reason: "documentation_provider_recovered")
            }
            return .handled(data)
        case .unavailable(let reason):
            recordDocumentationProviderUnavailable(reason: "documentation_provider_unavailable")
            return .unavailable(reason)
        case .failed(let error, let invalidatedProvider):
            if invalidatedProvider {
                recordDocumentationProviderInvalidated(reason: "documentation_provider_invalidated")
            }
            throw error
        }
    }

    package func hasDocumentationProvider() -> Bool {
        documentationProviderManager != nil
    }

    private func recordDocumentationToolListUpdate(_ update: DocumentationToolListUpdate) {
        logger.debug(
            "Documentation provider tools/list update observed",
            metadata: ["update": .string(update.debugLabel)]
        )
    }

    private func recordDocumentationProviderUnavailable(reason: String) {
        logger.debug(
            "Documentation provider unavailable",
            metadata: ["reason": .string(reason)]
        )
    }

    private func recordDocumentationProviderInvalidated(reason: String) {
        logger.debug(
            "Documentation provider invalidated",
            metadata: ["reason": .string(reason)]
        )
    }

    private func documentationToolListUpdate(
        manager: any DocumentationProviderManaging,
        requestTimeout: TimeAmount?
    ) async -> DocumentationToolListUpdate {
        guard requestTimeout?.nanoseconds != 0 else {
            return .unavailable
        }
        guard let requestTimeout, requestTimeout.nanoseconds > 0 else {
            return await manager.toolListUpdate(requestTimeout: requestTimeout)
        }
        do {
            return try await withThrowingTaskGroup(of: DocumentationToolListUpdate.self) { group in
                group.addTask {
                    await manager.toolListUpdate(requestTimeout: requestTimeout)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(requestTimeout.nanoseconds))
                    throw TimeoutError()
                }
                guard let update = try await group.next() else {
                    throw TimeoutError()
                }
                group.cancelAll()
                return update
            }
        } catch {
            logger.debug(
                "documentation provider tools/list update failed",
                metadata: [
                    "error": .string(String(describing: error)),
                    "timeout_ns": .string("\(requestTimeout.nanoseconds)"),
                ]
            )
            return .unavailable
        }
    }

    func encodeJSONRPCResultBuffer(
        id: RPCID,
        result: JSONValue
    ) throws -> ByteBuffer {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.value.foundationObject,
            "result": result.foundationObject,
        ]
        guard JSONSerialization.isValidJSONObject(response) else {
            throw TimeoutError()
        }
        let data = try JSONSerialization.data(withJSONObject: response, options: [])
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    func encodeControlPlaneErrorBuffer(
        id: RPCID,
        error: Error
    ) throws -> ByteBuffer {
        let mapped = ControlPlaneErrorMapper.jsonRPCError(for: error)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.value.foundationObject,
            "error": [
                "code": mapped.code,
                "message": mapped.message,
            ],
        ]
        guard JSONSerialization.isValidJSONObject(response) else {
            throw TimeoutError()
        }
        let data = try JSONSerialization.data(withJSONObject: response, options: [])
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    func eventLoopFuture<T: Sendable>(
        on eventLoop: EventLoop,
        operation: @escaping @Sendable () async throws -> T
    ) -> EventLoopFuture<T> {
        let promise = eventLoop.makePromise(of: T.self)
        promise.completeWithTask {
            try await operation()
        }
        return promise.futureResult
    }

    func timeoutDeadline(for timeout: TimeAmount?) -> UInt64? {
        Self.timeoutDeadline(for: timeout, nowUptimeNanoseconds: nowUptimeNanoseconds)
    }

    static func timeoutDeadline(for timeout: TimeAmount?) -> UInt64? {
        timeoutDeadline(for: timeout, nowUptimeNanoseconds: ClockClient.liveValue.uptimeNanoseconds)
    }

    private static func timeoutDeadline(
        for timeout: TimeAmount?,
        nowUptimeNanoseconds: @Sendable () -> UInt64
    ) -> UInt64? {
        guard let timeout, timeout.nanoseconds > 0 else {
            return nil
        }
        return nowUptimeNanoseconds() &+ UInt64(timeout.nanoseconds)
    }

    func awaitControlPlaneOperation<Output: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        let task = Task {
            try await operation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func invalidateControlPlane(
        reason: String,
        clearInitialize: Bool,
        clearToolsCatalog: Bool
    ) {
        // The synchronous cache clear bumps the broker generation, which is
        // what keeps stale fast paths from serving or re-populating the
        // cache. The delayed actor cleanup must only cancel loads that
        // started before this generation, because fresh requests may already
        // have started by the time the actor receives the cleanup message.
        if clearInitialize {
            canonicalBrokerState.clearInitialize()
        }
        if clearToolsCatalog {
            canonicalBrokerState.clearToolsCatalog()
        }
        let invalidatedGeneration = canonicalBrokerState.generation()
        let coordinator = controlPlaneCoordinator
        Task {
            await coordinator.cancelLoadsStartedBeforeGeneration(
                invalidatedGeneration,
                reason: reason
            )
        }
    }

}
