import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import ProxySessionControlPlane
import ProxySessionUpstream
import ProxyCore
import ProxyMCP

package final class SessionContext: Sendable {
    package let id: String
    package let router: ProxyRouter
    package let notificationHub: NotificationHub
    package let serverRequestTracker: ServerRequestTracker

    package init(id: String, config: ProxyConfig) {
        self.id = id
        self.notificationHub = NotificationHub()
        self.serverRequestTracker = ServerRequestTracker(
            routeTimeout: makeRequestTimeout(config.requestTimeout) ?? .seconds(300)
        )
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

private final class DocumentationToolListUpdateWaiter: @unchecked Sendable {
    struct Result: Sendable {
        let update: DocumentationProvider.ToolListUpdate
        let timedOut: Bool
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var resolved = false

    func wait(
        for task: Task<DocumentationProvider.ToolListUpdate, Never>,
        timeout: TimeAmount
    ) async -> Result {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                setContinuation(continuation)
                addTask(Task {
                    let update = await task.value
                    self.resume(Result(update: update, timedOut: false))
                })
                addTask(Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout.nanoseconds))
                    guard Task.isCancelled == false else {
                        return
                    }
                    self.resume(Result(update: .unavailable, timedOut: true))
                })
            }
        } onCancel: {
            resume(Result(update: .unavailable, timedOut: true))
        }
    }

    private func setContinuation(
        _ continuation: CheckedContinuation<Result, Never>
    ) {
        lock.lock()
        if resolved {
            lock.unlock()
            continuation.resume(returning: Result(update: .unavailable, timedOut: true))
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func addTask(_ task: Task<Void, Never>) {
        lock.lock()
        if resolved {
            lock.unlock()
            task.cancel()
            return
        }
        tasks.append(task)
        lock.unlock()
    }

    private func resume(_ result: Result) {
        lock.lock()
        guard resolved == false else {
            lock.unlock()
            return
        }
        resolved = true
        let continuation = continuation
        self.continuation = nil
        let tasks = tasks
        self.tasks.removeAll()
        lock.unlock()

        for task in tasks {
            task.cancel()
        }
        continuation?.resume(returning: result)
    }
}

/// The single routing decision for a DocumentationSearch tools/call:
/// either the provider produced the response, or proxy-managed
/// DocumentationSearch is unavailable.
package enum DocumentationSearchOutcome: Sendable {
    case handled(Data)
    case unavailable(DocumentationProvider.UnavailableReason)
}

package enum ServerRequestResponseForwardingResult: Sendable, Equatable {
    case accepted
    case missingRoute
    case invalidResponse
    case upstreamUnavailable
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
        originalID: JSONRPC.ID,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer>
    func sharedToolsList(
        sessionID: String,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue
    func liveXcodeListWindowsResult(
        route: ControlPlane.Route,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue
    func callDocumentationSearch(
        requestData: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationSearchOutcome
    func hasDocumentationSearchService() -> Bool
    func chooseUpstreamIndex() -> Int?
    func enqueueOnUpstreamSlot<Output: Sendable>(
        leaseID: LeaseManager.ID,
        descriptor: SessionRequestPipeline.Descriptor,
        on eventLoop: EventLoop,
        preferredUpstreamIndex: Int?,
        starter: @escaping @Sendable (Int) -> EventLoopFuture<Output>
    ) -> EventLoopFuture<Output>
    func assignUpstreamID(sessionID: String, originalID: JSONRPC.ID, upstreamIndex: Int) -> Int64
    func removeUpstreamIDMapping(sessionID: String, requestIDKey: String, upstreamIndex: Int)
    func onRequestTimeout(sessionID: String, requestIDKey: String, upstreamIndex: Int)
    func onRequestSucceeded(sessionID: String, requestIDKey: String, upstreamIndex: Int)
    func sendUpstream(_ data: Data, upstreamIndex: Int, ensureRunning: Bool)
    func forwardServerRequestResponse(
        responseData: Data,
        sessionID: String,
        responseID: JSONRPC.ID,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ServerRequestResponseForwardingResult>
    func debugSnapshot() -> ProxyDebug.Snapshot
    func debugSnapshot(includeSensitiveDebugPayloads: Bool) -> ProxyDebug.Snapshot
    func createRequestLease(descriptor: SessionRequestPipeline.Descriptor) -> LeaseManager.ID
    func activateRequestLease(
        _ leaseID: LeaseManager.ID,
        requestIDKey: String?,
        upstreamIndex: Int?,
        timeout: TimeAmount?
    )
    func completeRequestLease(_ leaseID: LeaseManager.ID)
    func requeueRequestLease(_ leaseID: LeaseManager.ID)
    func failRequestLease(
        _ leaseID: LeaseManager.ID,
        terminalState: LeaseManager.State,
        reason: LeaseManager.ReleaseReason
    )
    func handleRequestLeaseTimeout(
        _ leaseID: LeaseManager.ID,
        sessionID: String,
        requestIDKeys: [String],
        upstreamIndex: Int
    )
    func abandonRequestLease(
        _ leaseID: LeaseManager.ID,
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

    package func hasDocumentationSearchService() -> Bool {
        false
    }

    func sendUpstream(_ data: Data, upstreamIndex: Int) {
        sendUpstream(data, upstreamIndex: upstreamIndex, ensureRunning: false)
    }

    package func forwardServerRequestResponse(
        responseData _: Data,
        sessionID _: String,
        responseID _: JSONRPC.ID,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ServerRequestResponseForwardingResult> {
        eventLoop.makeSucceededFuture(.missingRoute)
    }

    func enqueueOnUpstreamSlot<Output: Sendable>(
        leaseID: LeaseManager.ID,
        descriptor: SessionRequestPipeline.Descriptor,
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

    func debugSnapshot() -> ProxyDebug.Snapshot {
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
            let healthState: ProxySessionUpstream.Upstream.HealthState
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
    package let upstreamEventTasks = AsyncTaskSupervisor()
    package let runtimeTasks = AsyncTaskSupervisor()
    package let upstreamStderrLogLimiter = UpstreamStderrLogLimiter()
    package let primaryInitializeReadinessTokenBox =
        NIOLockedValueBox<UpstreamReadinessWaiterToken?>(nil)
    package let documentationPrewarmTaskBox =
        NIOLockedValueBox<Task<DocumentationProvider.ToolListUpdate, Never>?>(nil)
    package let toolCatalogSummaryLoggedBox = NIOLockedValueBox(false)
    package let debugRecorder: ProxyDebugRecorder
    package let leaseManager: LeaseManager
    package let eventLoop: EventLoop
    package let upstreamRouter: UpstreamRouter
    package let config: ProxyConfig
    package let logger: Logger = ProxyLogging.make("session")
    package let upstreams: [any UpstreamSlotControlling]
    package let initializeParamsOverride: ProxyConfig.File.InitializeHandshakeOverride?
    package let canonicalBrokerState: CanonicalBrokerState
    package let controlPlaneDebugMirror = ControlPlane.DebugMirror()

    package let upstreamHealthManager: UpstreamHealthManager
    package let upstreamSlotScheduler: UpstreamSlotScheduler
    package let upstreamReadinessGate: UpstreamReadinessGate
    package let upstreamReadinessCoordinator: UpstreamReadinessCoordinator
    package let clock: ClockClient
    package let nowUptimeNanoseconds: @Sendable () -> UInt64
    package let scheduleRuntimeTimeout:
        @Sendable (TimeAmount, @escaping @Sendable () -> Void) ->
            RuntimeScheduledTimeout
    package let controlPlaneCoordinator: ControlPlaneCoordinator
    package let documentationProviderManager: (any DocumentationProviderManaging)?
    package let documentationProviderRoutes: [DocumentationProviderRoute]
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
        let documentationServiceEnabled = Self.documentationProviderServiceIsConfigured(
            config: config
        )
        let documentationTargets =
            documentationServiceEnabled
            ? xcodeTargetDiscovery?.runningXcodeTargets() ?? []
            : []
        let upstreamPlan = Self.makeDefaultUpstreamPlan(
            config: config,
            sharedSessionID: config.upstreamSessionID,
            count: count,
            documentationTargets: documentationTargets
        )
        let clock = ClockClient.liveValue
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let documentationTransport = RuntimeDocumentationProviderTransport(
            runtimeBox: runtimeBox,
            fallback: SessionBackedDocumentationProviderTransport(
                sessionFactory: LiveDocumentationProviderSessionFactory(
                    baseEnvironment: ProcessInfo.processInfo.environment
                ),
                clock: clock
            ),
            clock: clock
        )
        let documentationProviderManager =
            documentationServiceEnabled
            ? xcodeTargetDiscovery.flatMap { discovery in
                Self.makeDefaultDocumentationProviderManager(
                    config: config,
                    discovery: discovery,
                    transport: documentationTransport
                )
            }
            : nil
        self.init(
            config: config,
            eventLoop: eventLoop,
            upstreams: upstreamPlan.upstreams,
            clock: clock,
            upstreamReadinessGate: upstreamReadinessGate,
            documentationProviderRoutes: upstreamPlan.documentationRoutes,
            documentationProviderManager: documentationProviderManager,
            prewarmDocumentationProviderOnStartup: documentationProviderManager != nil,
            startImmediately: startImmediately,
            runtimeBox: runtimeBox
        )
    }

    package static func makeDefaultDocumentationProviderManager(
        config: ProxyConfig,
        discovery: any XcodeTargetDiscovering,
        transport: any DocumentationProviderRouting
    ) -> (any DocumentationProviderManaging)? {
        guard documentationProviderServiceIsConfigured(config: config) else {
            return nil
        }
        let environment = ProcessInfo.processInfo.environment
        let pinnedProcessID = environment["MCP_XCODE_PID"].flatMap(pid_t.init)
        return DocumentationProviderManager(
            discovery: discovery,
            transport: transport,
            pinnedProcessID: pinnedProcessID,
            initializeParams: InitializeHandshakeJSON.resolved(
                initializeParamsOverride: config.initializeParamsOverride
            ),
            serviceRepairer: LiveDocumentationSearchServiceRepairer(),
            localSearchProvider: LiveDocumentationAssetSearchProvider()
        )
    }

    package static func documentationProviderServiceIsConfigured(
        config: ProxyConfig
    ) -> Bool {
        config.disabledToolNames.contains(DocumentationProvider.ToolCatalog.toolName) == false
            && XcrunArguments.isDefaultMCPBridgeInvocation(config: config)
    }

    package init(
        config: ProxyConfig,
        eventLoop: EventLoop,
        upstreams: [any UpstreamSlotControlling],
        clock: ClockClient = .liveValue,
        upstreamReadinessGate: UpstreamReadinessGate? = nil,
        nowUptimeNanoseconds: (@Sendable () -> UInt64)? = nil,
        scheduleRuntimeTimeout: (
            @Sendable (TimeAmount, @escaping @Sendable () -> Void) ->
                RuntimeScheduledTimeout
        )? = nil,
        documentationProviderRoutes: [DocumentationProviderRoute] = [],
        documentationProviderManager: (any DocumentationProviderManaging)? = nil,
        prewarmDocumentationProviderOnStartup: Bool = false,
        startImmediately: Bool = true,
        runtimeBox providedRuntimeBox: WeakRuntimeCoordinatorBox? = nil
    ) {
        precondition(!upstreams.isEmpty, "upstreams must not be empty")
        let runtimeBox = providedRuntimeBox ?? WeakRuntimeCoordinatorBox()
        let uptimeProvider = nowUptimeNanoseconds ?? clock.uptimeNanoseconds
        let runtimeClock = ClockClient(
            now: clock.now,
            uptimeNanoseconds: uptimeProvider,
            sleep: clock.sleep,
            sleepForTimeInterval: clock.sleepForTimeInterval
        )
        let timeoutScheduler =
            scheduleRuntimeTimeout
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
        self.documentationProviderRoutes = documentationProviderRoutes
        self.prewarmDocumentationProviderOnStartup = prewarmDocumentationProviderOnStartup
        let resolvedReadinessGate =
            upstreamReadinessGate
            ?? .alwaysReady(uptimeNanoseconds: runtimeClock.uptimeNanoseconds)
        self.upstreamReadinessGate = resolvedReadinessGate
        self.upstreamReadinessCoordinator = UpstreamReadinessCoordinator(
            gate: resolvedReadinessGate,
            logger: ProxyLogging.make("upstream.readiness")
        )
        self.upstreamSlotScheduler = UpstreamSlotScheduler(
            canUseUpstream: {
                [weak upstreamHealthManager = self.upstreamHealthManager] upstreamIndex in
                let nowUptimeNs = uptimeProvider()
                guard let upstreamHealthManager else {
                    return UpstreamHealthManager.UseEvaluation(isUsable: false, effects: [])
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
                ) ?? UpstreamHealthManager.SelectionResult(upstreamIndex: nil, effects: [])
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
                return Dictionary(
                    uniqueKeysWithValues: states.enumerated().map { index, state in
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
            controlPlaneDefaultTimeout: MCP.MethodDispatcher.timeoutForControlPlane(
                defaultSeconds: config.requestTimeout
            ),
            clock: runtimeClock
        )
        runtimeBox.value = self

        for (upstreamIndex, upstream) in upstreams.enumerated() {
            upstreamEventTasks.run { [weak self, upstream] in
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

    @discardableResult
    package func addRuntimeTask(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        runtimeTasks.run(operation)
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
        runtimeTasks.cancelAll()
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

        let runtimeDrain = runtimeTasks.beginShutdown()
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
                    _ = await documentationPrewarmTask.value
                }
            }
        }
        await upstreamEventTasks.shutdown()
        await runtimeDrain.wait()
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
            for: MCP.MethodDispatcher.timeoutForControlPlane(
                defaultSeconds: config.requestTimeout
            )
        )
        addRuntimeTask { [weak self] in
            guard let self,
                  let baseResult = await self.controlPlaneCoordinator.prewarmToolsCatalogIfNeeded(
                      deadlineUptimeNs: deadline
                  ) else {
                return
            }
            let finalResult = await self.startupPrewarmToolsListResultWithDocumentationOverlay(
                baseResult: baseResult,
                requestTimeout: self.timeAmount(until: deadline),
                metadata: ["origin": .string("prewarm")]
            )
            self.logToolCatalogSummaryIfNeeded(finalResult)
        }
    }

    package func prewarmDocumentationProvider() {
        guard let documentationProviderManager else { return }
        let timeoutSeconds =
            config.requestTimeout > 0
            ? min(config.requestTimeout, 30)
            : 30
        let timeout = MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: timeoutSeconds)
        let task = Task<DocumentationProvider.ToolListUpdate, Never> {
            [weak self, documentationProviderManager, logger] in
            guard !Task.isCancelled else { return .unavailable }
            logger.debug(
                "Prewarming documentation provider",
                metadata: [
                    "timeout_seconds": .string("\(timeoutSeconds)")
                ]
            )
            let update = await documentationProviderManager.startBackgroundDiscovery(
                requestTimeout: timeout
            )
            self?.recordDocumentationToolListUpdate(update)
            guard !Task.isCancelled else { return .unavailable }
            logger.debug("Documentation provider prewarm completed")
            return update
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

    private func applyHealthEffects(_ effects: [UpstreamHealthManager.Effect]) {
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

    private func startHealthProbes(_ probes: [UpstreamHealthManager.ProbeRequest]) {
        for probe in probes {
            probeUpstreamHealth(
                upstreamIndex: probe.upstreamIndex,
                probeGeneration: probe.probeGeneration
            )
        }
    }

    package func enqueueOnUpstreamSlot<Output: Sendable>(
        leaseID: LeaseManager.ID,
        descriptor: SessionRequestPipeline.Descriptor,
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
            return eventLoop.makeFailedFuture(UpstreamSlotScheduler.AcquisitionError.unavailable)
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
                promise.fail(UpstreamSlotScheduler.AcquisitionError.unavailable)
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
        originalID: JSONRPC.ID,
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
        originalID: JSONRPC.ID,
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
                negotiatedProtocolVersion: Self.supportedProtocolVersion(
                    fromInitializeResult: cachedResult
                ),
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
        originalID: JSONRPC.ID,
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
            ?? MCP.MethodDispatcher.timeoutForMethod(
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
        let finalResult = await toolsListResultWithDocumentationOverlay(
            baseResult: baseResult,
            requestTimeout: timeAmount(until: deadline),
            metadata: ["session": .string(sessionID)]
        )
        logToolCatalogSummaryIfNeeded(finalResult)
        return finalResult
    }

    package func liveXcodeListWindowsResult(
        route: ControlPlane.Route,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue {
        let timeout =
            requestTimeoutOverride
            ?? MCP.MethodDispatcher.timeoutForMethod(
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
            ?? MCP.MethodDispatcher.timeoutForMethod(
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

    package func hasDocumentationSearchService() -> Bool {
        documentationProviderManager != nil
    }

    private func logToolCatalogSummaryIfNeeded(_ result: JSONValue) {
        let shouldLog = toolCatalogSummaryLoggedBox.withLockedValue { logged in
            if logged {
                return false
            }
            logged = true
            return true
        }
        guard shouldLog else {
            return
        }

        logger.info("\(ToolCatalogStartupLogFormatter.summary(from: result))")
    }

    private func toolsListResultWithDocumentationOverlay(
        baseResult: JSONValue,
        requestTimeout: TimeAmount?,
        metadata: Logger.Metadata
    ) async -> JSONValue {
        guard let documentationProviderManager else {
            return baseResult
        }
        let update = await documentationToolListUpdateForPublicToolsList(
            manager: documentationProviderManager,
            requestTimeout: requestTimeout
        )
        return toolsListResultApplyingDocumentationUpdate(
            update,
            to: baseResult,
            metadata: metadata
        )
    }

    private func startupPrewarmToolsListResultWithDocumentationOverlay(
        baseResult: JSONValue,
        requestTimeout: TimeAmount?,
        metadata: Logger.Metadata
    ) async -> JSONValue {
        guard let documentationProviderManager else {
            return baseResult
        }
        let update: DocumentationProvider.ToolListUpdate
        if let prewarmResult = await consumeDocumentationPrewarmTaskUpdate(
            requestTimeout: requestTimeout
        ) {
            update = prewarmResult.update
        } else {
            update = await documentationProviderManager.startBackgroundDiscovery(
                requestTimeout: requestTimeout
            )
        }
        return toolsListResultApplyingDocumentationUpdate(
            update,
            to: baseResult,
            metadata: metadata
        )
    }

    private func toolsListResultApplyingDocumentationUpdate(
        _ update: DocumentationProvider.ToolListUpdate,
        to baseResult: JSONValue,
        metadata: Logger.Metadata
    ) -> JSONValue {
        recordDocumentationToolListUpdate(update)
        var logMetadata = metadata
        logMetadata["update"] = .string(update.debugLabel)
        logger.debug(
            "Applied documentation provider tools/list overlay",
            metadata: logMetadata
        )
        return DocumentationProvider.ToolCatalog.applying(update, to: baseResult)
    }

    private func documentationToolListUpdateForPublicToolsList(
        manager: any DocumentationProviderManaging,
        requestTimeout: TimeAmount?
    ) async -> DocumentationProvider.ToolListUpdate {
        if let prewarmResult = await consumeDocumentationPrewarmTaskUpdate(
            requestTimeout: requestTimeout
        ) {
            let prewarmUpdate = prewarmResult.update
            if case .available = prewarmUpdate {
                return prewarmUpdate
            }
            if prewarmResult.timedOut {
                return .unavailable
            }
        }
        return await documentationToolListUpdate(
            manager: manager,
            requestTimeout: requestTimeout
        )
    }

    private func consumeDocumentationPrewarmTaskUpdate(
        requestTimeout: TimeAmount?
    ) async -> DocumentationToolListUpdateWaiter.Result? {
        guard let documentationPrewarmTask = documentationPrewarmTaskBox.withLockedValue({ $0 }) else {
            return nil
        }
        let result = await documentationToolListUpdate(
            fromPrewarmTask: documentationPrewarmTask,
            requestTimeout: requestTimeout
        )
        if result.timedOut == false {
            documentationPrewarmTaskBox.withLockedValue { $0 = nil }
        }
        return result
    }

    private func documentationToolListUpdate(
        fromPrewarmTask task: Task<DocumentationProvider.ToolListUpdate, Never>,
        requestTimeout: TimeAmount?
    ) async -> DocumentationToolListUpdateWaiter.Result {
        guard requestTimeout?.nanoseconds != 0 else {
            return DocumentationToolListUpdateWaiter.Result(update: .unavailable, timedOut: true)
        }
        guard let requestTimeout, requestTimeout.nanoseconds > 0 else {
            return DocumentationToolListUpdateWaiter.Result(
                update: await task.value,
                timedOut: false
            )
        }
        let result = await DocumentationToolListUpdateWaiter().wait(
            for: task,
            timeout: requestTimeout
        )
        if result.timedOut {
            logger.debug(
                "documentation provider prewarm did not finish before tools/list timeout",
                metadata: [
                    "timeout_ns": .string("\(requestTimeout.nanoseconds)"),
                ]
            )
        }
        return result
    }

    private func recordDocumentationToolListUpdate(_ update: DocumentationProvider.ToolListUpdate) {
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
    ) async -> DocumentationProvider.ToolListUpdate {
        guard requestTimeout?.nanoseconds != 0 else {
            return .unavailable
        }
        guard let requestTimeout, requestTimeout.nanoseconds > 0 else {
            return await manager.toolListUpdate(requestTimeout: requestTimeout)
        }
        do {
            return try await withThrowingTaskGroup(of: DocumentationProvider.ToolListUpdate.self) {
                group in
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
        id: JSONRPC.ID,
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
        id: JSONRPC.ID,
        error: Error
    ) throws -> ByteBuffer {
        let mapped = ControlPlane.ErrorMapper.jsonRPCError(for: error)
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
        addRuntimeTask {
            await coordinator.cancelLoadsStartedBeforeGeneration(
                invalidatedGeneration,
                reason: reason
            )
        }
    }

}
