import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import XcodeMCPKit

final class SessionContext: Sendable {
    let id: String
    let router: JSONRPCResponseRouter
    let serverRequestTracker: ServerRequestTracker

    init(
        id: String,
        config: ProxyRuntimeConfiguration,
        notificationSink: (@Sendable (Data) -> Void)? = nil
    ) {
        self.id = id
        self.serverRequestTracker = ServerRequestTracker(
            routeTimeout: makeRequestTimeout(config.requestTimeout) ?? .seconds(300)
        )
        self.router = JSONRPCResponseRouter(
            requestTimeout: makeRequestTimeout(config.requestTimeout),
            hasActiveClients: {
                notificationSink != nil
            },
            sendNotification: { data in
                notificationSink?(data)
            },
            onNotificationBufferOverflow: { droppedNotificationCount in
                ProxyLogging.make("runtime.session").warning(
                    "Notification buffer overflow in a runtime without a notification sink",
                    metadata: [
                        "session": .string(id),
                        "dropped_notifications": .string("\(droppedNotificationCount)"),
                    ]
                )
            }
        )
    }
}

final class WeakRuntimeCoordinatorBox: @unchecked Sendable {
    weak var value: RuntimeCoordinator?

    init() {}
}

struct RuntimeCoordinatorTestHooks: Sendable {
    var upstreamEventHandled: (@Sendable (_ upstreamIndex: Int) -> Void)?
    var toolsListRefreshCompleted: (@Sendable (_ upstreamIndex: Int, _ succeeded: Bool) -> Void)?
    var toolsListPrewarmCompleted: (@Sendable () -> Void)?
    var upstreamInitialized: (@Sendable (_ upstreamIndex: Int) -> Void)?
    var processRouteCatalogCommitted:
        (@Sendable (_ processID: pid_t, _ upstreamIndex: Int) -> Void)?
    var xcodeProcessReconcileCompleted: (@Sendable (_ reason: String) -> Void)?
    var controlPlaneRPCWillEnqueue: (@Sendable () -> Void)?
    var upstreamRequestQueued:
        (
            @Sendable (
                _ leaseID: LeaseManager.ID,
                _ descriptor: SessionRequestPipeline.Descriptor,
                _ queuedRequestCount: Int
            ) -> Void
        )?
    var upstreamRequestWillStart:
        (
            @Sendable (
                _ leaseID: LeaseManager.ID,
                _ descriptor: SessionRequestPipeline.Descriptor
            ) -> Void
        )?
    var primaryInitializeFailureCleanupCompleted: (@Sendable (_ upstreamIndex: Int?) -> Void)?
    var ownerRouteProofsResolved: (@Sendable () -> Void)?

    init(
        upstreamEventHandled: (@Sendable (_ upstreamIndex: Int) -> Void)? = nil,
        toolsListRefreshCompleted: (@Sendable (_ upstreamIndex: Int, _ succeeded: Bool) -> Void)? = nil,
        toolsListPrewarmCompleted: (@Sendable () -> Void)? = nil,
        upstreamInitialized: (@Sendable (_ upstreamIndex: Int) -> Void)? = nil,
        processRouteCatalogCommitted:
            (@Sendable (_ processID: pid_t, _ upstreamIndex: Int) -> Void)? = nil,
        xcodeProcessReconcileCompleted: (@Sendable (_ reason: String) -> Void)? = nil,
        controlPlaneRPCWillEnqueue: (@Sendable () -> Void)? = nil,
        upstreamRequestQueued:
            (
                @Sendable (
                    _ leaseID: LeaseManager.ID,
                    _ descriptor: SessionRequestPipeline.Descriptor,
                    _ queuedRequestCount: Int
                ) -> Void
            )? = nil,
        upstreamRequestWillStart:
            (
                @Sendable (
                    _ leaseID: LeaseManager.ID,
                    _ descriptor: SessionRequestPipeline.Descriptor
                ) -> Void
            )? = nil,
        primaryInitializeFailureCleanupCompleted: (@Sendable (_ upstreamIndex: Int?) -> Void)? = nil,
        ownerRouteProofsResolved: (@Sendable () -> Void)? = nil,
    ) {
        self.upstreamEventHandled = upstreamEventHandled
        self.toolsListRefreshCompleted = toolsListRefreshCompleted
        self.toolsListPrewarmCompleted = toolsListPrewarmCompleted
        self.upstreamInitialized = upstreamInitialized
        self.processRouteCatalogCommitted = processRouteCatalogCommitted
        self.xcodeProcessReconcileCompleted = xcodeProcessReconcileCompleted
        self.controlPlaneRPCWillEnqueue = controlPlaneRPCWillEnqueue
        self.upstreamRequestQueued = upstreamRequestQueued
        self.upstreamRequestWillStart = upstreamRequestWillStart
        self.primaryInitializeFailureCleanupCompleted = primaryInitializeFailureCleanupCompleted
        self.ownerRouteProofsResolved = ownerRouteProofsResolved
    }
}

struct XcodeProcessReconcileScheduleState: Sendable {
    var workerRunning = false
    var pendingReasons: [String] = []
}

struct XcodeProcessStartupReconcileState: Sendable {
    var isReconciling = true
    var didObserveChange = false
}

struct DocumentationProviderDiscoveryState: Sendable {
    var generation: UInt64 = 0
    var task: Task<DocumentationProvider.ToolListUpdate, Never>?
    var retryTimeout: RuntimeScheduledTimeout?
    var isClosed = false
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
    func cancelForDeinit()
    func shutdown() async
}

protocol RuntimeSessionRegistryPort: Sendable {
    func session(id: String) -> SessionContext
    func hasSession(id: String) -> Bool
    func isSessionInitialized(id: String) -> Bool
    func negotiatedProtocolVersion(id: String) -> String?
    func removeSession(id: String)
    func isInitialized() -> Bool
}

protocol RuntimeToolsCatalogPort: Sendable {
    func cachedToolsListResult() -> JSONValue?
    func cachedToolsListResult(forUpstreamIndex upstreamIndex: Int) -> JSONValue?
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
        starter: @escaping @Sendable (UpstreamOperationLease) -> EventLoopFuture<Output>
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
        operationLease: UpstreamOperationLease
    )
    func abandonRequestLease(
        _ leaseID: LeaseManager.ID,
        sessionID: String,
        requestIDKeys: [String],
        operationLease: UpstreamOperationLease?
    )
}

protocol RuntimeClientLocalMCPResponderPort:
    RuntimeSessionRegistryPort,
    RuntimeInitializeToolsPort
{}

protocol RuntimeMCPForwardingPort:
    RuntimeSessionRegistryPort,
    RuntimeToolsCatalogPort,
    RuntimeInitializeToolsPort,
    RuntimeToolRoutingPort,
    RuntimeUpstreamForwardingPort,
    RuntimeRequestLeasePort,
    ProxyUpstreamRequestRuntimePort
{}

protocol RuntimeClientMCPRequestPort:
    RuntimeSessionRegistryPort,
    RuntimeClientLocalMCPResponderPort,
    RuntimeMCPForwardingPort
{}

protocol RuntimeCoordinating:
    RuntimeSessionLifecyclePort,
    RuntimeClientMCPRequestPort,
    RuntimeDebugSnapshotPort
{}

extension RuntimeSessionLifecyclePort {
    func start() {}
    func cancelForDeinit() {}
}

extension RuntimeSessionRegistryPort {
    func isSessionInitialized(id: String) -> Bool {
        negotiatedProtocolVersion(id: id) != nil
    }

    func negotiatedProtocolVersion(id _: String) -> String? {
        nil
    }

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
        starter: @escaping @Sendable (UpstreamOperationLease) -> EventLoopFuture<Output>
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
        starter: @escaping @Sendable (UpstreamOperationLease) -> EventLoopFuture<Output>
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
    static let documentationProviderDiscoveryRetryInterval: TimeAmount = .seconds(2)
    struct TestSnapshot: Sendable {
        struct Upstream: Sendable {
            let id: Int
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

        func upstream(id: Int) -> Upstream? {
            upstreams.first { $0.id == id }
        }
    }

    let sessionRegistry: SessionRegistry
    let initializeManager: InitializeManager
    let upstreamEventTasks = AsyncTaskSupervisor()
    let runtimeTasks = AsyncTaskSupervisor()
    let upstreamStderrLogLimiter = UpstreamStderrLogLimiter()
    let primaryInitializeReadinessTokenBox =
        NIOLockedValueBox<UpstreamReadinessWaiterToken?>(nil)
    let documentationProviderDiscoveryState =
        NIOLockedValueBox(DocumentationProviderDiscoveryState())
    let unboundToolCatalogSummaryLoggedBox = NIOLockedValueBox(false)
    let debugRecorder: ProxyDebugRecorder
    let leaseManager: LeaseManager
    let eventLoop: EventLoop
    let upstreamRouter: UpstreamRouter
    let config: ProxyRuntimeConfiguration
    let logger: Logger = ProxyLogging.make("session")
    let upstreamTopology: UpstreamTopologyAuthority
    var upstreams: [any UpstreamSlotControlling] {
        upstreamTopology.snapshot().slots
    }
    var upstreamSlotIDs: [UpstreamSlotID] {
        upstreamTopology.snapshot().slotIDs
    }
    let initializeParamsOverride: ProxyRuntimeConfiguration.InitializeHandshakeOverride?
    let canonicalHandshakeState: CanonicalHandshakeState
    let controlPlaneDebugMirror = ControlPlane.DebugMirror()
    let processControlPlane: ProcessControlPlaneAuthority

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
    let xcodeProcessReconcileScheduleState =
        NIOLockedValueBox(XcodeProcessReconcileScheduleState())
    let xcodeProcessEventMonitor: (any XcodeProcessEventMonitoring)?
    let xcodeTargetDiscovery: (any XcodeTargetDiscovering)?
    let dynamicUpstreamFactory: XcodeProcessUpstreamFactory?
    var xcodeProcessRoutes: [XcodeProcessRoute] {
        processControlPlane.activeRoutes()
    }
    let windowOwnershipAuthority = WindowOwnershipAuthority()
    let windowRoutingResolver = WindowRoutingResolver()
    let prewarmDocumentationProviderOnStartup: Bool
    let testHooks: RuntimeCoordinatorTestHooks
    private let lifecycleStartedBox = NIOLockedValueBox(false)

    /// Composition-root entry point: the Xcode-specific readiness gate and
    /// target discovery default to this module's live session-owned
    /// implementations.
    convenience init(
        config: ProxyRuntimeConfiguration,
        eventLoop: EventLoop,
        upstreamReadinessGate: UpstreamReadinessGate? = nil,
        xcodeTargetDiscovery: (any XcodeTargetDiscovering)? = nil,
        xcodeProcessEventMonitor: (any XcodeProcessEventMonitoring)? = nil,
        notificationSink: (@Sendable (_ sessionID: String, _ data: Data) -> Void)? = nil,
        sessionClosedSink: (@Sendable (_ sessionID: String) -> Void)? = nil,
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
            xcodeProcessEventMonitor: xcodeProcessEventMonitor,
            dynamicUpstreamFactory: { target in
                MCPBridgeRuntime.makeProcessBoundUpstreamSlots(
                    config: bridgeRuntimeConfig,
                    xcodeTarget: target
                )
            },
            documentationProviderManager: documentationProviderManager,
            prewarmDocumentationProviderOnStartup: documentationProviderManager != nil,
            notificationSink: notificationSink,
            sessionClosedSink: sessionClosedSink,
            startImmediately: startImmediately,
            runtimeBox: runtimeBox
        )
    }

    static func makeDefaultDocumentationProviderManager(
        config: ProxyRuntimeConfiguration,
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
        config: ProxyRuntimeConfiguration
    ) -> Bool {
        config.disabledToolNames.contains(DocumentationProvider.ToolCatalog.toolName) == false
            && MCPBridgeRuntime.supportsProcessBoundRouting(
                config: config.mcpBridgeRuntimeConfiguration
            )
    }

    init(
        config: ProxyRuntimeConfiguration,
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
        xcodeProcessEventMonitor: (any XcodeProcessEventMonitoring)? = nil,
        dynamicUpstreamFactory: XcodeProcessUpstreamFactory? = nil,
        documentationProviderManager: (any DocumentationProviderManaging)? = nil,
        prewarmDocumentationProviderOnStartup: Bool = false,
        notificationSink: (@Sendable (_ sessionID: String, _ data: Data) -> Void)? = nil,
        sessionClosedSink: (@Sendable (_ sessionID: String) -> Void)? = nil,
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
        let upstreamTopology = UpstreamTopologyAuthority(upstreams)
        self.upstreamTopology = upstreamTopology
        self.clock = runtimeClock
        let handshakeState = CanonicalHandshakeState()
        self.canonicalHandshakeState = handshakeState
        self.initializeManager = InitializeManager(brokerState: handshakeState)
        self.sessionRegistry = SessionRegistry(
            configuration: config,
            notificationSink: notificationSink,
            sessionClosedSink: sessionClosedSink
        )
        let initialTopology = upstreamTopology.snapshot()
        let debugRecorder = ProxyDebugRecorder()
        debugRecorder.applyTopology(initialTopology)
        self.debugRecorder = debugRecorder
        self.leaseManager = LeaseManager()
        let upstreamRouter = UpstreamRouter(upstreamCount: upstreams.count)
        upstreamRouter.applyTopology(initialTopology)
        self.upstreamRouter = upstreamRouter
        let upstreamHealthManager = UpstreamHealthManager()
        upstreamHealthManager.applyTopology(initialTopology)
        self.upstreamHealthManager = upstreamHealthManager
        self.nowUptimeNanoseconds = uptimeProvider
        self.scheduleRuntimeTimeout = timeoutScheduler
        self.documentationProviderManager = documentationProviderManager
        self.processRoutingEnabled = resolvedProcessRoutingEnabled
        let processControlPlane = ProcessControlPlaneAuthority(
            initialRoutes: xcodeProcessRoutes,
            nowUptimeNs: uptimeProvider(),
            reason: "startup"
        )
        self.processControlPlane = processControlPlane
        self.xcodeTargetDiscovery = xcodeTargetDiscovery
        self.xcodeProcessEventMonitor = xcodeProcessEventMonitor
        self.dynamicUpstreamFactory = dynamicUpstreamFactory
        self.prewarmDocumentationProviderOnStartup = prewarmDocumentationProviderOnStartup
        self.testHooks = testHooks
        let resolvedReadinessGate =
            upstreamReadinessGate
            ?? .alwaysReady()
        self.upstreamReadinessGate = resolvedReadinessGate
        self.upstreamReadinessCoordinator = UpstreamReadinessCoordinator(
            gate: resolvedReadinessGate,
            logger: ProxyLogging.make("upstream.readiness")
        )
        let routableProcessBoundUpstreamIndices: @Sendable () -> Set<Int> = { [runtimeBox] in
            guard resolvedProcessRoutingEnabled else { return [] }
            guard let runtime = runtimeBox.value else {
                return Set(processControlPlane.activeRoutes().flatMap(\.upstreamIndices))
            }
            return runtime.routableProcessBoundUpstreamIndices()
        }
        let inactiveProcessBoundUpstreamIndices: @Sendable () -> Set<Int> = {
            guard resolvedProcessRoutingEnabled else { return [] }
            let active = routableProcessBoundUpstreamIndices()
            return Set(upstreamTopology.snapshot().slotIDs.map(\.rawValue)).subtracting(active)
        }
        self.upstreamSlotScheduler = UpstreamSlotScheduler(
            canUseUpstream: {
                [weak upstreamHealthManager] upstreamIndex in
                let nowUptimeNs = uptimeProvider()
                guard let upstreamHealthManager else {
                    return UpstreamHealthManager.UseEvaluation(proof: nil, effects: [])
                }
                if resolvedProcessRoutingEnabled,
                    routableProcessBoundUpstreamIndices().contains(upstreamIndex) == false
                {
                    return UpstreamHealthManager.UseEvaluation(proof: nil, effects: [])
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
                ) ?? UpstreamHealthManager.SelectionResult(proof: nil, effects: [])
            },
            operationLease: { [upstreamTopology] proof in
                upstreamTopology.operationLease(for: proof)
            },
            validateOperationLease: { [upstreamTopology] lease in
                upstreamTopology.validate(lease)
            },
            applyHealthEffects: { [runtimeBox] effects in
                runtimeBox.value?.applyHealthEffects(effects)
            },
            testHooks: UpstreamSlotSchedulerTestHooks(
                requestQueued: { leaseID, descriptor, queuedRequestCount in
                    testHooks.upstreamRequestQueued?(leaseID, descriptor, queuedRequestCount)
                },
                requestWillStart: { leaseID, descriptor in
                    testHooks.upstreamRequestWillStart?(leaseID, descriptor)
                }
            )
        )
        self.initializeParamsOverride = config.initializeParamsOverride
        self.controlPlaneCoordinator = ControlPlaneCoordinator(
            handshakeState: self.canonicalHandshakeState,
            cachedToolsCatalog: { [processControlPlane] in
                processControlPlane.canonicalToolsCatalogRaw()
            },
            canonicalToolsSource: { [processControlPlane] in
                processControlPlane.canonicalSourceUpstream()
            },
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
                let states = upstreamHealthManager.activeStatesSnapshot()
                return Dictionary(
                    uniqueKeysWithValues: states.map { id, state in
                        let summary: String
                        if state.initInFlight {
                            summary = "initializing"
                        } else if state.isInitialized {
                            summary = "initialized"
                        } else {
                            summary = "idle"
                        }
                        return ("\(id.rawValue)", summary)
                    })
            },
            logger: ProxyLogging.make("control-plane"),
            controlPlaneDefaultTimeout: MCP.MethodDispatcher.timeoutForControlPlane(
                defaultSeconds: config.requestTimeout
            ),
            clock: runtimeClock
        )
        runtimeBox.value = self

        for entry in upstreamTopology.snapshot().entries {
            observeUpstreamEvents(entry.operationLease)
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
            let preexistingRouteIDs = xcodeProcessRoutes.map(\.id)
            if let xcodeProcessEventMonitor {
                let startupReconcileState = NIOLockedValueBox(
                    XcodeProcessStartupReconcileState()
                )
                xcodeProcessEventMonitor.setChangeHandler { [weak self] reason in
                    guard let self else { return }
                    let shouldSchedule = startupReconcileState.withLockedValue { state in
                        if state.isReconciling {
                            state.didObserveChange = true
                            return false
                        }
                        return true
                    }
                    guard shouldSchedule else { return }
                    self.handleXcodeProcessInventoryChange(reason: reason)
                }
                if let xcodeTargetDiscovery {
                    reconcileStartupXcodeProcessSnapshotUntilCurrent(
                        discovery: xcodeTargetDiscovery,
                        state: startupReconcileState
                    )
                } else {
                    startupReconcileState.withLockedValue { state in
                        state.isReconciling = false
                    }
                }
            } else {
                triggerXcodeProcessReconcile(reason: "startup")
            }
            let preexistingRoutes = xcodeProcessRoutes.filter {
                preexistingRouteIDs.contains($0.id)
            }
            startProcessRouteAttachments(preexistingRoutes)
            for route in preexistingRoutes {
                startProcessRouteActivation(for: route)
            }
        } else if config.usesPermissionDialogAutomation {
            xcodeProcessEventMonitor?.start()
        }
        startEagerInitializePrimary()
        if prewarmDocumentationProviderOnStartup {
            prewarmDocumentationProvider()
        }
    }

    private func reconcileStartupXcodeProcessSnapshotUntilCurrent(
        discovery: any XcodeTargetDiscovering,
        state startupState: NIOLockedValueBox<XcodeProcessStartupReconcileState>
    ) {
        while true {
            reconcileXcodeProcessTargets(
                discovery.runningXcodeTargets(),
                reason: "startup_snapshot"
            )
            let isCurrent = startupState.withLockedValue { state in
                if state.didObserveChange {
                    state.didObserveChange = false
                    return false
                }
                state.isReconciling = false
                return true
            }
            if isCurrent {
                return
            }
        }
    }

    private func handleXcodeProcessInventoryChange(reason: String) {
        triggerXcodeProcessReconcile(reason: reason)
        if prewarmDocumentationProviderOnStartup {
            prewarmDocumentationProvider()
        }
    }

    func observeUpstreamEvents(_ operationLease: UpstreamOperationLease) {
        let upstreamIndex = operationLease.upstreamIndex
        upstreamEventTasks.run { [weak self, operationLease] in
            guard let self else { return }
            for await event in operationLease.slot.events {
                guard self.upstreamTopology.validate(operationLease) else { return }
                switch event {
                case .message(let data):
                    self.routeUpstreamMessage(
                        data,
                        upstreamIndex: upstreamIndex,
                        proof: operationLease.proof
                    )
                case .stderr(let message):
                    self.handleUpstreamStderr(message, upstreamIndex: upstreamIndex)
                case .stdoutProtocolViolation(let protocolViolation):
                    self.handleUpstreamProtocolViolation(
                        protocolViolation,
                        upstreamIndex: upstreamIndex,
                        proof: operationLease.proof
                    )
                case .stdoutBufferSize(let size):
                    self.handleBufferedStdoutBytes(size, upstreamIndex: upstreamIndex)
                case .exit(let status):
                    self.handleUpstreamExit(
                        status,
                        upstreamIndex: upstreamIndex,
                        proof: operationLease.proof
                    )
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

    func isSessionInitialized(id: String) -> Bool {
        sessionRegistry.isInitialized(id: id)
    }

    func negotiatedProtocolVersion(id: String) -> String? {
        sessionRegistry.negotiatedProtocolVersion(id: id)
    }

    func removeSession(id: String) {
        _ = sessionRegistry.removeSession(id: id)
        let pendingInitializes = initializeManager.removePendingInitializes(sessionID: id)
        pendingInitializes.timeout?.cancel()
        pendingInitializes.recoveryTimeout?.cancel()
        if let upstreamIndex = pendingInitializes.cancelledPrimaryUpstreamIndex {
            if let upstreamID = pendingInitializes.cancelledPrimaryUpstreamID {
                if let claim = upstreamHealthManager.currentInitializeClaim(
                    upstreamIndex: upstreamIndex,
                    expectedUpstreamID: upstreamID
                ) {
                    clearUpstreamState(initializeClaim: claim)
                }
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
        initializeReset.recoveryTimeout?.cancel()
        for pending in initializeReset.pending {
            pending.eventLoop.execute {
                pending.promise.fail(CancellationError())
            }
        }

        let initTimeouts = upstreamHealthManager.resetForDebug()
        for timeout in initTimeouts {
            timeout?.cancel()
        }

        _ = sessionRegistry.removeAllSessions()

        upstreamRouter.resetAll()
        _ = leaseManager.resetAll(reason: .clientDisconnected)
        upstreamSlotScheduler.reset()
        runtimeTasks.cancelAll()
        resetUpstreamReadinessWaiters()
        cancelPrimaryInitializeReadinessWaiter()
        debugRecorder.resetAll()
        upstreamStderrLogLimiter.reset()
        resetAllProcessRouteActivations(reason: "debug_reset")
        cancelDocumentationProviderDiscovery()
        clearXcodeWindowOwners()
        applyProcessControlPlaneTransition(processControlPlane.reset())
        retryPendingProcessRouteReadiness(reason: "debug_reset")
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
        shutdownState.recoveryTimeout?.cancel()

        let upstreamTimeouts = upstreamHealthManager.clearInitTimeoutsForShutdown()
        for timeout in upstreamTimeouts {
            timeout?.cancel()
        }
        let documentationPrewarmTask = stopDocumentationProviderDiscovery()
        upstreamReadinessCoordinator.shutdown()
        xcodeProcessEventMonitor?.stop()
        resetAllProcessRouteActivations(reason: "shutdown")
        applyProcessControlPlaneTransition(processControlPlane.detachAllCooldownTimeouts())

        let runtimeDrain = runtimeTasks.beginShutdown()
        applyProcessControlPlaneTransition(processControlPlane.invalidateCatalog(.reset))
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

    func cancelForDeinit() {
        let shutdownState = initializeManager.beginShutdown()
        shutdownState.timeout?.cancel()
        shutdownState.recoveryTimeout?.cancel()
        for timeout in upstreamHealthManager.clearInitTimeoutsForShutdown() {
            timeout?.cancel()
        }
        _ = stopDocumentationProviderDiscovery()
        upstreamReadinessCoordinator.shutdown()
        xcodeProcessEventMonitor?.stop()
        resetAllProcessRouteActivations(reason: "deinit")
        applyProcessControlPlaneTransition(processControlPlane.detachAllCooldownTimeouts())
        applyProcessControlPlaneTransition(processControlPlane.invalidateCatalog(.reset))
        _ = runtimeTasks.beginShutdown()
        _ = upstreamEventTasks.beginShutdown()
    }

    func isInitialized() -> Bool {
        initializeManager.isInitialized()
    }

    func cachedToolsListResult() -> JSONValue? {
        processControlPlane.canonicalToolsCatalogRaw()
    }

    func cachedToolsListResult(forUpstreamIndex upstreamIndex: Int) -> JSONValue? {
        processControlPlane.catalog(forUpstreamIndex: upstreamIndex)?.rawResult
            ?? processControlPlane.canonicalToolsCatalogRaw()
    }

    func applyProcessControlPlaneTransition(_ transition: ProcessControlPlaneTransition) {
        for effect in transition.effects {
            switch effect {
            case .cancelTimeout(let timeout):
                timeout.cancel()
            case .cancelRPC(let handle):
                handle.cancel()
            case .cancelReadinessWaiter(let token):
                cancelUpstreamReadinessWaiter(token)
            case .restoreBridgePool(let recovery):
                restoreProcessBridgePool(recovery)
            }
        }
        if transition.publishesToolsListChanged {
            publishToolsListChangedNotification()
        }
    }

    func publishUpstreamTopology(_ snapshot: UpstreamTopologyAuthority.Snapshot) {
        upstreamRouter.applyTopology(snapshot)
        upstreamHealthManager.applyTopology(snapshot)
        debugRecorder.applyTopology(snapshot)
    }

    func upstreamSlotContext(
        _ upstreamIndex: Int
    ) -> (slot: any UpstreamSlotControlling, proof: UpstreamTopologyProof)? {
        let snapshot = upstreamTopology.snapshot()
        let id = UpstreamSlotID(rawValue: upstreamIndex)
        guard let slot = snapshot.slot(id), let proof = snapshot.proof(id) else { return nil }
        return (slot, proof)
    }

    func processToolCatalogExposedProcessIDs() -> Set<pid_t> {
        catalogExposedUsableProcessIDs()
    }

    func refreshToolsListIfNeeded() {
        guard config.prewarmToolsList, isInitialized() else { return }
        let deadline = timeoutDeadline(
            for: MCP.MethodDispatcher.timeoutForControlPlane(
                defaultSeconds: config.requestTimeout
            )
        )
        addRuntimeTask { [weak self] in
            guard let self else { return }
            defer { self.testHooks.toolsListPrewarmCompleted?() }
            guard
                let baseResult = await self.controlPlaneCoordinator.prewarmToolsCatalogIfNeeded(
                    deadlineUptimeNs: deadline
                )
            else {
                return
            }
            let finalResult = await self.startupPrewarmToolsListResultWithDocumentationOverlay(
                baseResult: baseResult,
                requestTimeout: self.timeAmount(until: deadline),
                metadata: ["origin": .string("prewarm")]
            )
            self.logUnboundToolCatalogSummaryIfNeeded(finalResult)
        }
    }

    func prewarmDocumentationProvider() {
        guard let documentationProviderManager else { return }
        let initializedUpstreamIndices = Set(
            upstreamHealthManager.activeStatesSnapshot().compactMap { id, state in
                state.isInitialized ? id.rawValue : nil
            }
        )
        guard
            processRoutingEnabled == false
                || xcodeProcessRoutes.contains(where: {
                    $0.upstreamIndices.contains(where: initializedUpstreamIndices.contains)
                })
        else {
            cancelDocumentationProviderDiscovery()
            return
        }
        let timeoutSeconds =
            config.requestTimeout > 0
            ? min(config.requestTimeout, 30)
            : 30
        let timeout = MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: timeoutSeconds)
        startDocumentationProviderDiscovery(
            manager: documentationProviderManager,
            requestTimeout: timeout,
            timeoutSeconds: timeoutSeconds,
            expectedGeneration: nil
        )
    }

    private func startDocumentationProviderDiscovery(
        manager: any DocumentationProviderManaging,
        requestTimeout: TimeAmount?,
        timeoutSeconds: TimeInterval,
        expectedGeneration: UInt64?
    ) {
        let previous = documentationProviderDiscoveryState.withLockedValue {
            state -> (
                task: Task<DocumentationProvider.ToolListUpdate, Never>?,
                retryTimeout: RuntimeScheduledTimeout?
            )? in
            guard state.isClosed == false else { return nil }
            if let expectedGeneration {
                guard state.generation == expectedGeneration else { return nil }
            }

            let previous = (task: state.task, retryTimeout: state.retryTimeout)
            state.generation &+= 1
            let generation = state.generation
            state.retryTimeout = nil
            state.task = Task<DocumentationProvider.ToolListUpdate, Never> {
                [weak self, manager, logger] in
                guard !Task.isCancelled else { return .unavailable }
                logger.debug(
                    "Prewarming documentation provider",
                    metadata: [
                        "timeout_seconds": .string("\(timeoutSeconds)")
                    ]
                )
                let update = await manager.startBackgroundDiscovery(
                    requestTimeout: requestTimeout
                )
                guard !Task.isCancelled else { return .unavailable }
                self?.completeDocumentationProviderDiscovery(
                    generation: generation,
                    update: update
                )
                logger.debug("Documentation provider prewarm completed")
                return update
            }
            return previous
        }
        guard let previous else { return }
        previous.task?.cancel()
        previous.retryTimeout?.cancel()
    }

    private func completeDocumentationProviderDiscovery(
        generation: UInt64,
        update: DocumentationProvider.ToolListUpdate
    ) {
        let accepted = documentationProviderDiscoveryState.withLockedValue { state in
            guard state.isClosed == false,
                state.generation == generation
            else {
                return false
            }
            state.task = nil
            return true
        }
        guard accepted else { return }
        recordDocumentationToolListUpdate(update)
        guard case .available = update else {
            scheduleDocumentationProviderDiscoveryRetry(generation: generation)
            return
        }
    }

    private func scheduleDocumentationProviderDiscoveryRetry(generation: UInt64) {
        let timeout = scheduleRuntimeTimeout(
            Self.documentationProviderDiscoveryRetryInterval
        ) { [weak self] in
            self?.retryDocumentationProviderDiscovery(generation: generation)
        }
        let shouldKeep = documentationProviderDiscoveryState.withLockedValue { state in
            guard state.isClosed == false,
                state.generation == generation,
                state.task == nil,
                state.retryTimeout == nil
            else {
                return false
            }
            state.retryTimeout = timeout
            return true
        }
        if shouldKeep == false {
            timeout.cancel()
        }
    }

    private func retryDocumentationProviderDiscovery(generation: UInt64) {
        guard let documentationProviderManager else { return }
        let timeoutSeconds =
            config.requestTimeout > 0
            ? min(config.requestTimeout, 30)
            : 30
        startDocumentationProviderDiscovery(
            manager: documentationProviderManager,
            requestTimeout: MCP.MethodDispatcher.timeoutForControlPlane(
                defaultSeconds: timeoutSeconds
            ),
            timeoutSeconds: timeoutSeconds,
            expectedGeneration: generation
        )
    }

    private func cancelDocumentationProviderDiscovery() {
        let pending = documentationProviderDiscoveryState.withLockedValue { state in
            state.generation &+= 1
            let pending = (task: state.task, retryTimeout: state.retryTimeout)
            state.task = nil
            state.retryTimeout = nil
            return pending
        }
        pending.task?.cancel()
        pending.retryTimeout?.cancel()
    }

    private func stopDocumentationProviderDiscovery()
        -> Task<DocumentationProvider.ToolListUpdate, Never>?
    {
        let pending = documentationProviderDiscoveryState.withLockedValue { state in
            state.isClosed = true
            state.generation &+= 1
            let pending = (task: state.task, retryTimeout: state.retryTimeout)
            state.task = nil
            state.retryTimeout = nil
            return pending
        }
        pending.task?.cancel()
        pending.retryTimeout?.cancel()
        return pending.task
    }

    func chooseUpstreamOperationLease() -> UpstreamOperationLease? {
        let nowUptimeNs = nowUptimeNanoseconds()
        let occupiedUpstreams = upstreamSlotScheduler.occupiedUpstreamIndices()
            .union(inactiveProcessBoundUpstreamIndices())

        let chooseResult = upstreamHealthManager.chooseBestInitializedUpstream(
            nowUptimeNs: nowUptimeNs,
            occupiedUpstreams: occupiedUpstreams
        )
        applyHealthEffects(chooseResult.effects)
        guard let proof = chooseResult.proof else { return nil }
        return upstreamTopology.operationLease(for: proof)
    }

    func chooseUpstreamIndex() -> Int? {
        chooseUpstreamOperationLease()?.upstreamIndex
    }

    func applyHealthEffects(_ effects: [UpstreamHealthManager.Effect]) {
        for effect in effects {
            switch effect {
            case .cancelInitTimeout(let timeout):
                timeout.cancel()
            case .startHealthProbe(let probe):
                probeUpstreamHealth(probe)
            case .clearPins:
                break
            case .failQueuedIfNoRecovery:
                failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
            }
        }
    }

    private func startHealthProbes(_ probes: [UpstreamHealthManager.ProbeRequest]) {
        for probe in probes {
            probeUpstreamHealth(probe)
        }
    }

    func enqueueOnUpstreamSlot<Output: Sendable>(
        leaseID: LeaseManager.ID,
        descriptor: SessionRequestPipeline.Descriptor,
        on eventLoop: EventLoop,
        preferredUpstreamIndex: Int? = nil,
        starter: @escaping @Sendable (UpstreamOperationLease) -> EventLoopFuture<Output>
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
        starter: @escaping @Sendable (UpstreamOperationLease) -> EventLoopFuture<Output>
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
            starter: { operationLease in
                starter(operationLease).cascade(to: promise)
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
        let canRecoverQuarantinedInitialize =
            upstreamHealthManager.earliestInitializedQuarantineRecovery() != nil
        guard
            primaryUpstreamIndex != nil
                || initializeManager.isInitialized()
                || processRoutingEnabled
                || canRecoverQuarantinedInitialize
        else {
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
                )
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
            schedulePendingInitializeQuarantineRecovery()
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
        logUnboundToolCatalogSummaryIfNeeded(finalResult)
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
                if processRoutingEnabled {
                    return rewriteXcodeListWindowsResultForClients(
                        result,
                        upstreamIndex: upstreamIndex
                    )
                }
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

    private func logUnboundToolCatalogSummaryIfNeeded(_ result: JSONValue) {
        guard processRoutingEnabled == false else { return }
        let shouldLog = unboundToolCatalogSummaryLoggedBox.withLockedValue { logged in
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
            from: result
        )
        logger.info("\(summary)")
    }

    private func toolsListResultWithDocumentationOverlay(
        baseResult: JSONValue,
        requestTimeout _: TimeAmount?,
        metadata: Logger.Metadata
    ) async -> JSONValue {
        toolsListResultWithConfiguredOverlay(
            baseResult: baseResult,
            metadata: metadata
        )
    }

    private func startupPrewarmToolsListResultWithDocumentationOverlay(
        baseResult: JSONValue,
        requestTimeout _: TimeAmount?,
        metadata: Logger.Metadata
    ) async -> JSONValue {
        toolsListResultWithConfiguredOverlay(
            baseResult: baseResult,
            metadata: metadata
        )
    }

    func toolsListResultWithConfiguredOverlay(
        baseResult: JSONValue,
        metadata: Logger.Metadata
    ) -> JSONValue {
        guard documentationProviderManager != nil else {
            return baseResult
        }
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

    func invalidateToolsCatalog(reason: String) {
        applyProcessControlPlaneTransition(processControlPlane.invalidateCatalog(.reset))
        logger.debug("control_plane_invalidated", metadata: ["reason": .string(reason)])
    }

}
