import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import XcodeMCPKit

final class SessionContext: Sendable {
    let id: String
    let router: JSONRPCResponseRouter
    let notificationHub: NotificationHub
    let serverRequestTracker: ServerRequestTracker

    init(id: String, config: ProxyConfig) {
        self.id = id
        self.notificationHub = NotificationHub()
        self.serverRequestTracker = ServerRequestTracker(
            routeTimeout: makeRequestTimeout(config.requestTimeout) ?? .seconds(300)
        )
        self.router = JSONRPCResponseRouter(
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

final class WeakRuntimeCoordinatorBox: @unchecked Sendable {
    weak var value: RuntimeCoordinator?

    init() {}
}

struct RuntimeCoordinatorTestHooks: Sendable {
    var initializedNotificationStaleIgnored: (@Sendable (_ upstreamIndex: Int) -> Void)?
    var upstreamEventHandled: (@Sendable (_ upstreamIndex: Int) -> Void)?
    var toolsListRefreshCompleted: (@Sendable (_ upstreamIndex: Int, _ succeeded: Bool) -> Void)?
    var processToolsCatalogLoadedBeforeRecord:
        (@Sendable (_ target: XcodeProcessTarget, _ upstreamIndex: Int) async -> Void)?
    var upstreamInitialized: (@Sendable (_ upstreamIndex: Int) -> Void)?
    var upstreamRequestQueued:
        (@Sendable (
            _ leaseID: LeaseManager.ID,
            _ descriptor: SessionRequestPipeline.Descriptor,
            _ queuedRequestCount: Int
        ) -> Void)?
    var primaryInitializeFailureCleanupCompleted: (@Sendable (_ upstreamIndex: Int?) -> Void)?
    var processRouteActivationEvent:
        (@Sendable (_ processID: pid_t, _ upstreamIndex: Int?, _ event: String) -> Void)?

    init(
        initializedNotificationStaleIgnored: (@Sendable (_ upstreamIndex: Int) -> Void)? = nil,
        upstreamEventHandled: (@Sendable (_ upstreamIndex: Int) -> Void)? = nil,
        toolsListRefreshCompleted: (@Sendable (_ upstreamIndex: Int, _ succeeded: Bool) -> Void)? = nil,
        processToolsCatalogLoadedBeforeRecord:
            (@Sendable (_ target: XcodeProcessTarget, _ upstreamIndex: Int) async -> Void)? = nil,
        upstreamInitialized: (@Sendable (_ upstreamIndex: Int) -> Void)? = nil,
        upstreamRequestQueued:
            (@Sendable (
                _ leaseID: LeaseManager.ID,
                _ descriptor: SessionRequestPipeline.Descriptor,
                _ queuedRequestCount: Int
            ) -> Void)? = nil,
        primaryInitializeFailureCleanupCompleted: (@Sendable (_ upstreamIndex: Int?) -> Void)? = nil,
        processRouteActivationEvent:
            (@Sendable (_ processID: pid_t, _ upstreamIndex: Int?, _ event: String) -> Void)? = nil
    ) {
        self.initializedNotificationStaleIgnored = initializedNotificationStaleIgnored
        self.upstreamEventHandled = upstreamEventHandled
        self.toolsListRefreshCompleted = toolsListRefreshCompleted
        self.processToolsCatalogLoadedBeforeRecord = processToolsCatalogLoadedBeforeRecord
        self.upstreamInitialized = upstreamInitialized
        self.upstreamRequestQueued = upstreamRequestQueued
        self.primaryInitializeFailureCleanupCompleted = primaryInitializeFailureCleanupCompleted
        self.processRouteActivationEvent = processRouteActivationEvent
    }
}

struct XcodeProcessReconcileScheduleState: Sendable {
    var workerRunning = false
    var pendingReasons: [String] = []
}

struct XcodeProcessReconciliationLoopState: Sendable {
    var generation: UInt64 = 0
    var isRunning = false
}

struct ScheduledProcessToolsCatalogRetry: Sendable {
    let generation: UInt64
    let timeout: RuntimeScheduledTimeout
}

typealias XcodeProcessUpstreamFactory =
    @Sendable (_ target: XcodeProcessTarget) -> [any UpstreamSlotControlling]

/// The single routing decision for a DocumentationSearch tools/call:
/// either the provider produced the response, or proxy-managed
/// DocumentationSearch is unavailable.
enum DocumentationSearchOutcome: Sendable {
    case handled(Data)
    case unavailable(DocumentationProvider.UnavailableReason)
}

enum ServerRequestResponseForwardingResult: Sendable, Equatable {
    case accepted
    case missingRoute
    case invalidResponse
    case upstreamUnavailable
}

protocol RuntimeSessionLifecyclePort: Sendable {
    func start()
    func debugReset()
    func shutdown() async
}

protocol RuntimeSessionRegistryPort: Sendable {
    func session(id: String) -> SessionContext
    func hasSession(id: String) -> Bool
    func negotiatedProtocolVersion(id: String) -> String?
    func markNotificationClientConnected(sessionID: String)
    func removeSession(id: String)
    func isInitialized() -> Bool
}

protocol RuntimeToolsCatalogPort: Sendable {
    func cachedToolsListResult() -> JSONValue?
    func cachedToolsListResult(forUpstreamIndex upstreamIndex: Int) -> JSONValue?
    func setCachedToolsListResult(_ result: JSONValue, sourceUpstream: Int)
}

protocol RuntimeInitializeToolsPort: Sendable {
    func session(id: String) -> SessionContext
    func isInitialized() -> Bool
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
}

protocol RuntimeToolRoutingPort: Sendable {
    func toolRoutingDecision(
        for requestJSON: Any,
        requestTimeoutOverride: TimeAmount?
    ) async -> ToolRoutingDecision
    func immediateToolRoutingDecision(for requestJSON: Any) -> ToolRoutingDecision?
    func preferredUpstreamIndex(for requestJSON: Any) -> Int?
    func primaryUpstreamIndex(forXcodeProcessID processID: pid_t) -> Int?
    func liveXcodeListWindowsResult(
        route: ControlPlane.Route,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue
}

protocol RuntimeUpstreamForwardingPort: Sendable {
    func session(id: String) -> SessionContext
    func enqueueOnUpstreamSlot<Output: Sendable>(
        leaseID: LeaseManager.ID,
        descriptor: SessionRequestPipeline.Descriptor,
        on eventLoop: EventLoop,
        preferredUpstreamIndices: [Int]?,
        starter: @escaping @Sendable (Int) -> EventLoopFuture<Output>
    ) -> EventLoopFuture<Output>
    func forwardServerRequestResponse(
        responseData: Data,
        sessionID: String,
        responseID: JSONRPC.ID,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ServerRequestResponseForwardingResult>
}

protocol RuntimeDebugSnapshotPort: Sendable {
    func debugSnapshot() -> ProxyDebug.Snapshot
    func debugSnapshot(includeSensitiveDebugPayloads: Bool) -> ProxyDebug.Snapshot
}

protocol RuntimeRequestLeasePort: Sendable {
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

protocol RuntimeHTTPControlPort:
    RuntimeSessionLifecyclePort,
    RuntimeSessionRegistryPort,
    RuntimeDebugSnapshotPort {}

protocol RuntimeClientLocalMCPResponderPort:
    RuntimeSessionRegistryPort,
    RuntimeInitializeToolsPort {}

protocol RuntimeMCPForwardingPort:
    RuntimeSessionRegistryPort,
    RuntimeToolsCatalogPort,
    RuntimeInitializeToolsPort,
    RuntimeToolRoutingPort,
    RuntimeUpstreamForwardingPort,
    RuntimeRequestLeasePort,
    ProxyUpstreamRequestRuntimePort {}

protocol RuntimeClientMCPRequestPort:
    RuntimeSessionRegistryPort,
    RuntimeClientLocalMCPResponderPort,
    RuntimeMCPForwardingPort {}

protocol RuntimeHTTPGatewayPort:
    RuntimeHTTPControlPort,
    RuntimeClientMCPRequestPort {}

protocol RuntimeCoordinating:
    RuntimeHTTPGatewayPort {}

extension RuntimeSessionLifecyclePort {
    func start() {}
}

extension RuntimeSessionRegistryPort {
    func negotiatedProtocolVersion(id _: String) -> String? {
        nil
    }

    func markNotificationClientConnected(sessionID _: String) {}
}

extension RuntimeToolsCatalogPort {
    func cachedToolsListResult(forUpstreamIndex _: Int) -> JSONValue? {
        cachedToolsListResult()
    }
}

extension RuntimeInitializeToolsPort {
    func hasDocumentationSearchService() -> Bool {
        false
    }

    func callDocumentationSearch(
        requestData _: Data,
        requestTimeoutOverride _: TimeAmount?
    ) async throws -> DocumentationSearchOutcome {
        .unavailable(.noAvailableProvider)
    }
}

extension RuntimeToolRoutingPort {
    func toolRoutingDecision(
        for requestJSON: Any,
        requestTimeoutOverride _: TimeAmount?
    ) async -> ToolRoutingDecision {
        .forward(preferredUpstreamIndex: preferredUpstreamIndex(for: requestJSON))
    }

    func immediateToolRoutingDecision(for _: Any) -> ToolRoutingDecision? {
        nil
    }

    func preferredUpstreamIndex(for _: Any) -> Int? {
        nil
    }

    func primaryUpstreamIndex(forXcodeProcessID _: pid_t) -> Int? {
        nil
    }
}

extension RuntimeUpstreamForwardingPort {
    func forwardServerRequestResponse(
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
            preferredUpstreamIndices: nil,
            starter: starter
        )
    }

    func enqueueOnUpstreamSlot<Output: Sendable>(
        leaseID: LeaseManager.ID,
        descriptor: SessionRequestPipeline.Descriptor,
        on eventLoop: EventLoop,
        preferredUpstreamIndex: Int?,
        starter: @escaping @Sendable (Int) -> EventLoopFuture<Output>
    ) -> EventLoopFuture<Output> {
        enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop,
            preferredUpstreamIndices: preferredUpstreamIndex.map { [$0] },
            starter: starter
        )
    }
}

extension RuntimeDebugSnapshotPort {
    func debugSnapshot() -> ProxyDebug.Snapshot {
        debugSnapshot(includeSensitiveDebugPayloads: false)
    }
}

final class RuntimeCoordinator: Sendable, RuntimeCoordinating {
    static let redactedDebugText = "<redacted>"
    static let documentationProviderDiscoveryPollInterval: Duration = .seconds(2)

    struct TestSnapshot: Sendable {
        struct Upstream: Sendable {
            let isInitialized: Bool
            let initInFlight: Bool
            let healthState: XcodeMCPKit.Upstream.HealthState
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

    let sessionRegistry: SessionRegistry
    let initializeManager: InitializeManager
    let upstreamEventTasks = AsyncTaskSupervisor()
    let runtimeTasks = AsyncTaskSupervisor()
    let xcodeProcessReconciliationLoopState =
        NIOLockedValueBox(XcodeProcessReconciliationLoopState())
    let upstreamStderrLogLimiter = UpstreamStderrLogLimiter()
    let primaryInitializeReadinessTokenBox =
        NIOLockedValueBox<UpstreamReadinessWaiterToken?>(nil)
    let documentationPrewarmTaskBox =
        NIOLockedValueBox<Task<DocumentationProvider.ToolListUpdate, Never>?>(nil)
    let toolCatalogSummaryLoggedBox = NIOLockedValueBox(false)
    let debugRecorder: ProxyDebugRecorder
    let leaseManager: LeaseManager
    let eventLoop: EventLoop
    let upstreamRouter: UpstreamRouter
    let config: ProxyConfig
    let logger: Logger = ProxyLogging.make("session")
    let upstreamsBox: NIOLockedValueBox<[any UpstreamSlotControlling]>
    var upstreams: [any UpstreamSlotControlling] {
        upstreamsBox.withLockedValue { $0 }
    }
    let initializeParamsOverride: ProxyConfig.File.InitializeHandshakeOverride?
    let canonicalBrokerState: CanonicalBrokerState
    let controlPlaneDebugMirror = ControlPlane.DebugMirror()
    let processToolCatalogRegistry = ProcessToolCatalogRegistry()

    let upstreamHealthManager: UpstreamHealthManager
    let upstreamSlotScheduler: UpstreamSlotScheduler
    let upstreamReadinessGate: UpstreamReadinessGate
    let upstreamReadinessCoordinator: UpstreamReadinessCoordinator
    let clock: ClockClient
    let nowUptimeNanoseconds: @Sendable () -> UInt64
    let scheduleRuntimeTimeout:
        @Sendable (TimeAmount, @escaping @Sendable () -> Void) ->
            RuntimeScheduledTimeout
    let controlPlaneCoordinator: ControlPlaneCoordinator
    let documentationProviderManager: (any DocumentationProviderManaging)?
    let processRoutingEnabled: Bool
    let xcodeProcessRegistry: XcodeProcessRegistry
    let xcodeProcessReconcileScheduleState =
        NIOLockedValueBox(XcodeProcessReconcileScheduleState())
    let xcodeProcessEventMonitor = XcodeProcessEventMonitor()
    let xcodeTargetDiscovery: (any XcodeTargetDiscovering)?
    let dynamicUpstreamFactory: XcodeProcessUpstreamFactory?
    var xcodeProcessRoutes: [XcodeProcessRoute] {
        xcodeProcessRegistry.activeRoutes()
    }
    let tabOwnerProcessIDs = NIOLockedValueBox<[String: pid_t]>([:])
    let workspaceOwnerProcessIDs = NIOLockedValueBox<[String: pid_t]>([:])
    let availableToolsCatalogRefreshKeys = NIOLockedValueBox<Set<String>>([])
    let scheduledProcessToolsCatalogRetries =
        NIOLockedValueBox<[pid_t: ScheduledProcessToolsCatalogRetry]>([:])
    let pendingProcessToolsCatalogRefreshProcessIDs = NIOLockedValueBox<Set<pid_t>>([])
    let xcodeProcessRouteActivationTracker = XcodeProcessRouteActivationTracker()
    let unavailableXcodeProcessRoutes =
        NIOLockedValueBox<[pid_t: XcodeProcessRouteUnavailableRecord]>([:])
    let prewarmDocumentationProviderOnStartup: Bool
    let testHooks: RuntimeCoordinatorTestHooks
    private let lifecycleStartedBox = NIOLockedValueBox(false)

    /// Composition-root entry point: the Xcode-specific readiness gate and
    /// target discovery default to this module's live session-owned
    /// implementations.
    convenience init(
        config: ProxyConfig,
        eventLoop: EventLoop,
        upstreamReadinessGate: UpstreamReadinessGate? = nil,
        xcodeTargetDiscovery: (any XcodeTargetDiscovering)? = nil,
        startImmediately: Bool = true
    ) {
        let bridgeRuntimeConfig = config.mcpBridgeRuntimeConfiguration
        let xcodeProcessRoutingSupported = MCPBridgeRuntime.supportsProcessBoundRouting(
            config: bridgeRuntimeConfig
        )
        let xcodeProcessRoutingEnabled = xcodeProcessRoutingSupported && xcodeTargetDiscovery != nil
        let documentationServiceEnabled = Self.documentationProviderServiceIsConfigured(
            config: config
        )
        let xcodeTargets =
            xcodeProcessRoutingEnabled
            ? xcodeTargetDiscovery?.runningXcodeTargets() ?? []
            : []
        let upstreamPlan = MCPBridgeRuntime.makeUpstreamPlan(
            config: bridgeRuntimeConfig,
            xcodeTargets: xcodeTargets,
            processBoundRoutingEnabled: xcodeProcessRoutingEnabled
        )
        let clock = ClockClient.liveValue
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let documentationTransport = RuntimeDocumentationProviderTransport(
            runtimeBox: runtimeBox,
            fallback: SessionBackedDocumentationProviderTransport(
                sessionFactory: LiveDocumentationProviderSessionFactory(
                    config: config,
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
                    discovery: RuntimeDocumentationTargetDiscovery(
                        base: discovery,
                        runtimeBox: runtimeBox
                    ),
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
            xcodeProcessRoutes: upstreamPlan.xcodeProcessRoutes,
            processRoutingEnabled: xcodeProcessRoutingEnabled,
            xcodeTargetDiscovery: xcodeTargetDiscovery,
            dynamicUpstreamFactory: { target in
                MCPBridgeRuntime.makeProcessBoundUpstreamSlots(
                    config: bridgeRuntimeConfig,
                    xcodeTarget: target
                )
            },
            documentationProviderManager: documentationProviderManager,
            prewarmDocumentationProviderOnStartup: documentationProviderManager != nil,
            startImmediately: startImmediately,
            runtimeBox: runtimeBox
        )
    }

    static func makeDefaultDocumentationProviderManager(
        config: ProxyConfig,
        discovery: any XcodeTargetDiscovering,
        transport: any DocumentationProviderRouting
    ) -> (any DocumentationProviderManaging)? {
        guard documentationProviderServiceIsConfigured(config: config) else {
            return nil
        }
        return DocumentationProviderManager(
            discovery: discovery,
            transport: transport,
            initializeParams: InitializeHandshakeJSON.resolved(
                initializeParamsOverride: config.initializeParamsOverride
            ),
            serviceRepairer: LiveDocumentationSearchServiceRepairer(),
            localSearchProvider: DocumentationSearchActionProvider(),
            documentationSearchActionPolicy: .preferWhenMultipleRunningAndDefaultXcodeIsOlder
        )
    }

    static func documentationProviderServiceIsConfigured(
        config: ProxyConfig
    ) -> Bool {
        config.disabledToolNames.contains(DocumentationProvider.ToolCatalog.toolName) == false
            && MCPBridgeRuntime.supportsProcessBoundRouting(
                config: config.mcpBridgeRuntimeConfiguration
            )
    }

    init(
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
        xcodeProcessRoutes: [XcodeProcessRoute] = [],
        processRoutingEnabled: Bool? = nil,
        xcodeTargetDiscovery: (any XcodeTargetDiscovering)? = nil,
        dynamicUpstreamFactory: XcodeProcessUpstreamFactory? = nil,
        documentationProviderManager: (any DocumentationProviderManaging)? = nil,
        prewarmDocumentationProviderOnStartup: Bool = false,
        testHooks: RuntimeCoordinatorTestHooks = RuntimeCoordinatorTestHooks(),
        startImmediately: Bool = true,
        runtimeBox providedRuntimeBox: WeakRuntimeCoordinatorBox? = nil
    ) {
        let resolvedProcessRoutingEnabled =
            processRoutingEnabled ?? (xcodeProcessRoutes.isEmpty == false)
        precondition(
            !upstreams.isEmpty || resolvedProcessRoutingEnabled,
            "upstreams must not be empty outside process-bound routing mode"
        )
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
        let upstreamStore = NIOLockedValueBox(upstreams)
        self.upstreamsBox = upstreamStore
        self.clock = runtimeClock
        let brokerState = CanonicalBrokerState()
        self.canonicalBrokerState = brokerState
        self.initializeManager = InitializeManager(brokerState: brokerState)
        self.sessionRegistry = SessionRegistry(configuration: config)
        self.debugRecorder = ProxyDebugRecorder(upstreamCount: upstreams.count)
        self.leaseManager = LeaseManager()
        self.upstreamRouter = UpstreamRouter(upstreamCount: upstreams.count)
        let upstreamHealthManager = UpstreamHealthManager(upstreamCount: upstreams.count)
        self.upstreamHealthManager = upstreamHealthManager
        self.nowUptimeNanoseconds = uptimeProvider
        self.scheduleRuntimeTimeout = timeoutScheduler
        self.documentationProviderManager = documentationProviderManager
        self.processRoutingEnabled = resolvedProcessRoutingEnabled
        let xcodeProcessRegistry = XcodeProcessRegistry(
            initialRoutes: xcodeProcessRoutes,
            nowUptimeNs: uptimeProvider(),
            reason: "startup"
        )
        self.xcodeProcessRegistry = xcodeProcessRegistry
        self.xcodeTargetDiscovery = xcodeTargetDiscovery
        self.dynamicUpstreamFactory = dynamicUpstreamFactory
        self.prewarmDocumentationProviderOnStartup = prewarmDocumentationProviderOnStartup
        self.testHooks = testHooks
        let resolvedReadinessGate =
            upstreamReadinessGate
            ?? .alwaysReady(uptimeNanoseconds: runtimeClock.uptimeNanoseconds)
        self.upstreamReadinessGate = resolvedReadinessGate
        self.upstreamReadinessCoordinator = UpstreamReadinessCoordinator(
            gate: resolvedReadinessGate,
            logger: ProxyLogging.make("upstream.readiness")
        )
        let routableProcessBoundUpstreamIndices: @Sendable () -> Set<Int> = { [runtimeBox] in
            guard resolvedProcessRoutingEnabled else { return [] }
            guard let runtime = runtimeBox.value else {
                return Set(xcodeProcessRegistry.activeRoutes().flatMap(\.upstreamIndices))
            }
            return runtime.routableProcessBoundUpstreamIndices()
        }
        let inactiveProcessBoundUpstreamIndices: @Sendable () -> Set<Int> = {
            guard resolvedProcessRoutingEnabled else { return [] }
            let active = routableProcessBoundUpstreamIndices()
            let upstreamCount = upstreamStore.withLockedValue { $0.count }
            return Set(0..<upstreamCount).subtracting(active)
        }
        self.upstreamSlotScheduler = UpstreamSlotScheduler(
            canUseUpstream: {
                [weak upstreamHealthManager] upstreamIndex in
                let nowUptimeNs = uptimeProvider()
                guard let upstreamHealthManager else {
                    return UpstreamHealthManager.UseEvaluation(isUsable: false, effects: [])
                }
                if resolvedProcessRoutingEnabled,
                   routableProcessBoundUpstreamIndices().contains(upstreamIndex) == false {
                    return UpstreamHealthManager.UseEvaluation(isUsable: false, effects: [])
                }
                return upstreamHealthManager.evaluateUsableInitialized(
                    index: upstreamIndex,
                    nowUptimeNs: nowUptimeNs
                )
            },
            selectUpstream: { [weak upstreamHealthManager] occupied in
                let nowUptimeNs = uptimeProvider()
                return upstreamHealthManager?.chooseBestInitializedUpstream(
                    nowUptimeNs: nowUptimeNs,
                    occupiedUpstreams: occupied.union(inactiveProcessBoundUpstreamIndices())
                ) ?? UpstreamHealthManager.SelectionResult(upstreamIndex: nil, effects: [])
            },
            applyHealthEffects: { [runtimeBox] effects in
                runtimeBox.value?.applyHealthEffects(effects)
            },
            testHooks: UpstreamSlotSchedulerTestHooks(
                requestQueued: { leaseID, descriptor, queuedRequestCount in
                    testHooks.upstreamRequestQueued?(leaseID, descriptor, queuedRequestCount)
                }
            )
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
            observeUpstreamEvents(upstream, upstreamIndex: upstreamIndex)
        }

        if startImmediately {
            start()
        }
    }

    func start() {
        let shouldStart = lifecycleStartedBox.withLockedValue { started in
            guard started == false else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        if processRoutingEnabled {
            xcodeProcessEventMonitor.startWorkspaceNotifications { [weak self] reason in
                self?.triggerXcodeProcessReconcile(reason: reason)
            }
            for route in xcodeProcessRoutes {
                xcodeProcessEventMonitor.observeExit(processID: route.target.processID) {
                    [weak self] reason in
                    self?.triggerXcodeProcessReconcile(reason: reason)
                }
            }
            triggerXcodeProcessReconcile(reason: "startup")
            startXcodeProcessReconciliationLoop()
        }
        startEagerInitializePrimary()
        if prewarmDocumentationProviderOnStartup {
            prewarmDocumentationProvider()
        }
    }

    func observeUpstreamEvents(
        _ upstream: any UpstreamSlotControlling,
        upstreamIndex: Int
    ) {
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
                    if self.processRoutingEnabled {
                        self.triggerXcodeProcessReconcile(reason: "upstream_exit_\(status)")
                    }
                }
                self.testHooks.upstreamEventHandled?(upstreamIndex)
            }
        }
    }

    @discardableResult
    func addRuntimeTask(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        runtimeTasks.run(operation)
    }

    func session(id: String) -> SessionContext {
        sessionRegistry.session(id: id)
    }

    func hasSession(id: String) -> Bool {
        sessionRegistry.hasSession(id: id)
    }

    func negotiatedProtocolVersion(id: String) -> String? {
        sessionRegistry.negotiatedProtocolVersion(id: id)
    }

    func removeSession(id: String) {
        let context = sessionRegistry.removeSession(id: id)
        context?.notificationHub.closeAll()
        let pendingInitializes = initializeManager.removePendingInitializes(sessionID: id)
        pendingInitializes.timeout?.cancel()
        if let upstreamIndex = pendingInitializes.cancelledPrimaryUpstreamIndex {
            if let upstreamID = pendingInitializes.cancelledPrimaryUpstreamID {
                clearUpstreamState(upstreamIndex: upstreamIndex, expectedUpstreamID: upstreamID)
            }
            if let readinessToken = pendingInitializes.cancelledPrimaryReadinessToken {
                cancelPrimaryInitializeReadinessWaiter(readinessToken)
            }
        }
        for pending in pendingInitializes.pending {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }
    }

    func debugReset() {
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
        resetAllProcessRouteActivations(reason: "debug_reset")
        unavailableXcodeProcessRoutes.withLockedValue { $0.removeAll() }
        cancelAllScheduledProcessToolsCatalogRetries()
        pendingProcessToolsCatalogRefreshProcessIDs.withLockedValue { $0.removeAll() }
        clearXcodeWindowOwners()
        invalidateControlPlane(
            reason: "debug_reset",
            clearInitialize: true,
            clearToolsCatalog: true
        )
        canonicalBrokerState.reset()
        processToolCatalogRegistry.reset()
        restartXcodeProcessReconciliationLoopAfterRuntimeTaskReset()
    }

    func shutdown() async {
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
        resetAllProcessRouteActivations(reason: "shutdown")
        xcodeProcessEventMonitor.stop()
        cancelAllScheduledProcessToolsCatalogRetries()
        pendingProcessToolsCatalogRefreshProcessIDs.withLockedValue { $0.removeAll() }

        let runtimeDrain = runtimeTasks.beginShutdown()
        canonicalBrokerState.reset()
        processToolCatalogRegistry.reset()
        let controlPlaneDrain = await controlPlaneCoordinator.beginShutdown(
            reason: "shutdown",
            clearInitialize: true,
            clearToolsCatalog: true
        )

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
        await controlPlaneDrain.wait()
        await runtimeDrain.wait()
    }

    func isInitialized() -> Bool {
        initializeManager.isInitialized()
    }

    func cachedToolsListResult() -> JSONValue? {
        canonicalBrokerState.toolsCatalogRaw()
    }

    func cachedToolsListResult(forUpstreamIndex upstreamIndex: Int) -> JSONValue? {
        processToolCatalogRegistry.toolsListResult(forUpstreamIndex: upstreamIndex)
            ?? canonicalBrokerState.toolsCatalogRaw()
    }

    func setCachedToolsListResult(_ result: JSONValue, sourceUpstream: Int) {
        guard isValidToolsListResult(result) else { return }
        canonicalBrokerState.syncCanonicalToolsCatalog(
            result,
            sourceUpstream: sourceUpstream
        )
    }

    @discardableResult
    func applyToolCatalogSurfaceUpdate(
        _ update: ProcessToolCatalogRegistry.SurfaceUpdate,
        onlyIfGeneration expectedGeneration: UInt64? = nil
    ) -> Bool {
        if let expectedGeneration,
           canonicalBrokerState.generation() != expectedGeneration {
            return false
        }
        let applied: Bool
        switch update.canonicalAction {
        case .noChange:
            applied = true
            break
        case .syncCanonical(let rawResult, let sourceUpstream):
            applied = canonicalBrokerState.syncCanonicalToolsCatalog(
                rawResult,
                sourceUpstream: sourceUpstream,
                onlyIfGeneration: expectedGeneration
            )
        case .clearCanonical:
            applied = canonicalBrokerState.clearToolsCatalog(
                onlyIfGeneration: expectedGeneration
            )
        }
        if applied, update.publishesToolsListChanged {
            publishToolsListChangedNotification()
        }
        return applied
    }

    func cancelScheduledProcessToolsCatalogRetry(
        processID: pid_t,
        generation expectedGeneration: UInt64? = nil
    ) {
        let retry: ScheduledProcessToolsCatalogRetry? =
            scheduledProcessToolsCatalogRetries.withLockedValue { retries in
                guard let retry = retries[processID] else {
                    return nil
                }
                if let expectedGeneration, retry.generation != expectedGeneration {
                    return nil
                }
                retries.removeValue(forKey: processID)
                return retry
            }
        retry?.timeout.cancel()
    }

    func cancelAllScheduledProcessToolsCatalogRetries() {
        let retries = scheduledProcessToolsCatalogRetries.withLockedValue { retries in
            let retriesToCancel = Array(retries.values)
            retries.removeAll()
            return retriesToCancel
        }
        for retry in retries {
            retry.timeout.cancel()
        }
    }

    func processToolCatalogExposedProcessIDs() -> Set<pid_t> {
        catalogExposedUsableProcessIDs()
    }

    func processToolCatalogRegistryHasCompleteConfiguredCatalog() -> Bool {
        let configuredProcessIDs = catalogEligibleConfiguredProcessIDs()
        guard configuredProcessIDs.isEmpty == false else {
            return false
        }
        return processToolCatalogRegistry.processIDsWithCatalog() == configuredProcessIDs
    }

    func refreshToolsListIfNeeded() {
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

    func prewarmDocumentationProvider() {
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
            self?.scheduleDocumentationProviderDiscoveryPollIfNeeded(after: update)
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

    private func scheduleDocumentationProviderDiscoveryPollIfNeeded(
        after update: DocumentationProvider.ToolListUpdate
    ) {
        guard documentationProviderManager != nil else { return }
        guard case .available = update else {
            addRuntimeTask { [weak self] in
                guard let self else { return }
                await self.clock.sleep(Self.documentationProviderDiscoveryPollInterval)
                guard !Task.isCancelled else { return }
                self.prewarmDocumentationProvider()
            }
            return
        }
    }

    func chooseUpstreamIndex() -> Int? {
        let nowUptimeNs = nowUptimeNanoseconds()
        let occupiedUpstreams = upstreamSlotScheduler.occupiedUpstreamIndices()
            .union(inactiveProcessBoundUpstreamIndices())

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

    func applyHealthEffects(_ effects: [UpstreamHealthManager.Effect]) {
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

    func enqueueOnUpstreamSlot<Output: Sendable>(
        leaseID: LeaseManager.ID,
        descriptor: SessionRequestPipeline.Descriptor,
        on eventLoop: EventLoop,
        preferredUpstreamIndex: Int? = nil,
        starter: @escaping @Sendable (Int) -> EventLoopFuture<Output>
    ) -> EventLoopFuture<Output> {
        enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop,
            preferredUpstreamIndices: preferredUpstreamIndex.map { [$0] },
            starter: starter
        )
    }

    func enqueueOnUpstreamSlot<Output: Sendable>(
        leaseID: LeaseManager.ID,
        descriptor: SessionRequestPipeline.Descriptor,
        on eventLoop: EventLoop,
        preferredUpstreamIndices: [Int]?,
        starter: @escaping @Sendable (Int) -> EventLoopFuture<Output>
    ) -> EventLoopFuture<Output> {
        let hasHealthyUpstream = activeInitializedHealthyishCount() > 0
        var recoveryInFlight = anyActiveRecoveryInFlight()
        if hasHealthyUpstream == false, recoveryInFlight == false,
            initializeManager.consumeWarmInitRecoveryIntent(policy: .regardlessOfCachedInitialize)
        {
            startPrimaryEagerRetry()
            recoveryInFlight = anyActiveRecoveryInFlight()
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
            preferredUpstreamIndices: preferredUpstreamIndices ?? [],
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

    func registerInitialize(
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
        let activePrimaryUpstreamIndex = initializeManager.activePrimaryInitializeUpstreamIndex()
        let candidatePrimaryUpstreamIndex = activePrimaryUpstreamIndex ?? primaryInitializeUpstreamIndex()
        let primaryUpstreamIndex: Int?
        if activePrimaryUpstreamIndex == nil,
           let candidatePrimaryUpstreamIndex,
           processRouteActivationOwnsPrimaryInitialize(upstreamIndex: candidatePrimaryUpstreamIndex)
        {
            primaryUpstreamIndex = nil
        } else {
            primaryUpstreamIndex = candidatePrimaryUpstreamIndex
        }
        guard primaryUpstreamIndex != nil || initializeManager.isInitialized() || processRoutingEnabled else {
            return eventLoop.makeFailedFuture(UpstreamSlotScheduler.AcquisitionError.unavailable)
        }

        let decision = initializeManager.registerInitialize(
            sessionID: sessionID,
            sessionGeneration: sessionGeneration,
            originalID: originalID,
            primaryUpstreamIndex: primaryUpstreamIndex,
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

    func registerInitialize(
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

    func markNotificationClientConnected(sessionID: String) {
        sessionRegistry.markNotificationClientConnected(id: sessionID)
    }

    func sharedToolsList(
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

    func liveXcodeListWindowsResult(
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
        switch route {
        case .anyHealthy where processRoutingEnabled:
            return try await liveXcodeListWindowsAcrossProcessRoutes(
                deadlineUptimeNs: deadline,
                routeScope: .catalogSurface
            )
        default:
            let result = try await awaitControlPlaneOperation {
                try await self.controlPlaneCoordinator.listWindows(
                    route: route,
                    deadlineUptimeNs: deadline
                )
            }
            if case .pinnedUpstream(let upstreamIndex) = route {
                recordXcodeWindowOwners(from: result, upstreamIndex: upstreamIndex)
            }
            return result
        }
    }

    func callDocumentationSearch(
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

    func hasDocumentationSearchService() -> Bool {
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

        let summary = ToolCatalogStartupLogFormatter.summary(
            from: result,
            process: toolCatalogSourceProcess(),
            exposurePolicy: processRoutingEnabled
                ? "available_route_catalog_surface"
                : nil
        )
        logger.info("\(summary)")
    }

    private func toolCatalogSourceProcess() -> ToolCatalogStartupLogFormatter.Process? {
        guard let upstreamIndex = canonicalBrokerState.toolsSourceUpstream(),
              let route = xcodeProcessRoutes.first(where: {
                  $0.upstreamIndices.contains(upstreamIndex)
              })
        else {
            return nil
        }
        return ToolCatalogStartupLogFormatter.Process(
            appPath: route.target.appPath,
            processID: route.target.processID
        )
    }

    private func toolsListResultWithDocumentationOverlay(
        baseResult: JSONValue,
        requestTimeout _: TimeAmount?,
        metadata: Logger.Metadata
    ) async -> JSONValue {
        guard documentationProviderManager != nil else {
            return baseResult
        }
        return toolsListResultExposingProxyOwnedDocumentationSearch(
            baseResult: baseResult,
            metadata: metadata
        )
    }

    private func startupPrewarmToolsListResultWithDocumentationOverlay(
        baseResult: JSONValue,
        requestTimeout _: TimeAmount?,
        metadata: Logger.Metadata
    ) async -> JSONValue {
        guard documentationProviderManager != nil else {
            return baseResult
        }
        return toolsListResultExposingProxyOwnedDocumentationSearch(
            baseResult: baseResult,
            metadata: metadata
        )
    }

    private func toolsListResultExposingProxyOwnedDocumentationSearch(
        baseResult: JSONValue,
        metadata: Logger.Metadata
    ) -> JSONValue {
        logger.debug(
            "Applied proxy-owned DocumentationSearch tools/list overlay",
            metadata: metadata
        )
        return DocumentationProvider.ToolCatalog.exposingProxyOwnedSearch(in: baseResult)
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

    func encodeJSONRPCResultBuffer(
        id: JSONRPC.ID,
        result: JSONValue
    ) throws -> ByteBuffer {
        let data = try JSONRPC.Wire.resultResponseData(id: id, result: result)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    func encodeControlPlaneErrorBuffer(
        id: JSONRPC.ID,
        error: Error
    ) throws -> ByteBuffer {
        let mapped = ControlPlane.ErrorMapper.jsonRPCError(for: error)
        let data = try JSONRPC.Wire.errorResponseData(
            id: id,
            code: mapped.code,
            message: mapped.message
        )
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
