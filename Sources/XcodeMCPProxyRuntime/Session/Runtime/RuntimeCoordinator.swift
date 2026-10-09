import XcodeMCPProxyRuntimeContract
import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import XcodeMCPCore

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
    var upstreamExitStateCleared: (@Sendable (_ upstreamIndex: Int) -> Void)?
    var toolsListRefreshCompleted: (@Sendable (_ upstreamIndex: Int, _ succeeded: Bool) -> Void)?
    var toolsListPrewarmCompleted: (@Sendable () -> Void)?
    var upstreamInitialized: (@Sendable (_ upstreamIndex: Int) -> Void)?
    var nativeToolsCatalogCommitted: (@Sendable (_ upstreamIndex: Int) -> Void)?
    var controlPlaneRPCWillEnqueue: (@Sendable () -> Void)?
    var controlPlaneRPCAssignedUpstreamID: (@Sendable () -> Void)?
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
    var healthProbeResponseWaiterWillRegister: (@Sendable () -> Void)?

    init(
        upstreamEventHandled: (@Sendable (_ upstreamIndex: Int) -> Void)? = nil,
        upstreamExitStateCleared: (@Sendable (_ upstreamIndex: Int) -> Void)? = nil,
        toolsListRefreshCompleted: (@Sendable (_ upstreamIndex: Int, _ succeeded: Bool) -> Void)? = nil,
        toolsListPrewarmCompleted: (@Sendable () -> Void)? = nil,
        upstreamInitialized: (@Sendable (_ upstreamIndex: Int) -> Void)? = nil,
        nativeToolsCatalogCommitted: (@Sendable (_ upstreamIndex: Int) -> Void)? = nil,
        controlPlaneRPCWillEnqueue: (@Sendable () -> Void)? = nil,
        controlPlaneRPCAssignedUpstreamID: (@Sendable () -> Void)? = nil,
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
        healthProbeResponseWaiterWillRegister: (@Sendable () -> Void)? = nil,
    ) {
        self.upstreamEventHandled = upstreamEventHandled
        self.upstreamExitStateCleared = upstreamExitStateCleared
        self.toolsListRefreshCompleted = toolsListRefreshCompleted
        self.toolsListPrewarmCompleted = toolsListPrewarmCompleted
        self.upstreamInitialized = upstreamInitialized
        self.nativeToolsCatalogCommitted = nativeToolsCatalogCommitted
        self.controlPlaneRPCWillEnqueue = controlPlaneRPCWillEnqueue
        self.controlPlaneRPCAssignedUpstreamID = controlPlaneRPCAssignedUpstreamID
        self.upstreamRequestQueued = upstreamRequestQueued
        self.upstreamRequestWillStart = upstreamRequestWillStart
        self.primaryInitializeFailureCleanupCompleted = primaryInitializeFailureCleanupCompleted
        self.healthProbeResponseWaiterWillRegister = healthProbeResponseWaiterWillRegister
    }
}

typealias NativeUpstreamFactory = @Sendable () -> any UpstreamSlotControlling

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
    func sessionStateAndTouch(id: String) -> ProxyRuntimeSessionState
    func beginClientRequest(id: String, createIfMissing: Bool) -> Bool
    func endClientRequest(id: String)
    func openClientEventStream(id: String) -> Bool
    func closeClientEventStream(id: String)
    func expireInactiveSessions(inactiveForNanoseconds: UInt64)
    func removeSession(id: String)
    func isInitialized() -> Bool
}

protocol RuntimeToolsCatalogPort: Sendable {
    func cachedToolsListResult() -> JSONValue?
    func cachedToolsListResult(forUpstreamIndex upstreamIndex: Int) -> JSONValue?
    func toolDefinition(named name: String, sourceProof: UpstreamTopologyProof) -> ToolDefinitionSnapshot?
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
        timeout: TimeAmount?,
        progressTokenMapping: ProgressTokenMapping?
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
        operationLease: UpstreamOperationLease?,
        after requestSendCompletion: UpstreamRequestSendCompletion?
    )
    func abandonRequestLease(
        _ leaseID: LeaseManager.ID,
        sessionID: String,
        requestIDKeys: [String],
        operationLease: UpstreamOperationLease?,
        after requestSendCompletion: UpstreamRequestSendCompletion?
    )
}

extension RuntimeRequestLeasePort {
    func handleRequestLeaseTimeout(
        _ leaseID: LeaseManager.ID,
        sessionID: String,
        requestIDKeys: [String],
        operationLease: UpstreamOperationLease?
    ) {
        handleRequestLeaseTimeout(
            leaseID,
            sessionID: sessionID,
            requestIDKeys: requestIDKeys,
            operationLease: operationLease,
            after: nil
        )
    }

    func abandonRequestLease(
        _ leaseID: LeaseManager.ID,
        sessionID: String,
        requestIDKeys: [String],
        operationLease: UpstreamOperationLease?
    ) {
        abandonRequestLease(
            leaseID,
            sessionID: sessionID,
            requestIDKeys: requestIDKeys,
            operationLease: operationLease,
            after: nil
        )
    }
}

protocol RuntimeClientLocalMCPResponderPort:
    RuntimeSessionRegistryPort,
    RuntimeInitializeToolsPort
{}

protocol RuntimeMCPForwardingPort:
    RuntimeSessionRegistryPort,
    RuntimeToolsCatalogPort,
    RuntimeInitializeToolsPort,
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

    func sessionStateAndTouch(id: String) -> ProxyRuntimeSessionState {
        guard hasSession(id: id) else { return .missing }
        guard isSessionInitialized(id: id) else { return .uninitialized }
        return .initialized(protocolVersion: negotiatedProtocolVersion(id: id))
    }

    func beginClientRequest(id: String, createIfMissing: Bool) -> Bool {
        if createIfMissing {
            _ = session(id: id)
        }
        return hasSession(id: id)
    }

    func endClientRequest(id _: String) {}

    func openClientEventStream(id: String) -> Bool {
        hasSession(id: id)
    }

    func closeClientEventStream(id _: String) {}

    func expireInactiveSessions(inactiveForNanoseconds _: UInt64) {}

}

extension RuntimeToolsCatalogPort {
    func cachedToolsListResult(forUpstreamIndex _: Int) -> JSONValue? {
        nil
    }

    func toolDefinition(named name: String, sourceProof: UpstreamTopologyProof) -> ToolDefinitionSnapshot? {
        ToolCatalogCodec.toolsByName(in: cachedToolsListResult(forUpstreamIndex: sourceProof.slotID.rawValue))[name]
            .map { ToolDefinitionSnapshot(sourceProof: sourceProof, descriptor: $0) }
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
    struct TestSnapshot: Sendable {
        struct Upstream: Sendable {
            let id: Int
            let isInitialized: Bool
            let initInFlight: Bool
            let healthState: XcodeMCPCore.Upstream.HealthState
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
    let catalogChangedSink: (@Sendable () -> Void)?
    let initializeManager: InitializeManager
    let upstreamEventTasks = AsyncTaskSupervisor()
    let upstreamRetirementTasks = AsyncTaskSupervisor()
    let runtimeTasks = AsyncTaskSupervisor()
    let upstreamTopologyCommitLock = NIOLock()
    let upstreamStderrLogLimiter = UpstreamStderrLogLimiter()
    let primaryInitializeReadinessTokenBox =
        NIOLockedValueBox<UpstreamReadinessWaiterToken?>(nil)
    let nativeToolCatalogSummaryLoggedBox = NIOLockedValueBox(false)
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
    let toolsCatalog = ToolsCatalogAuthority()

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
    let nativeUpstreamFactory: NativeUpstreamFactory?
    let testHooks: RuntimeCoordinatorTestHooks
    private let lifecycleStartedBox = NIOLockedValueBox(false)

    /// Creates the native headless host owned by this runtime.
    convenience init(
        config: ProxyRuntimeConfiguration,
        eventLoop: EventLoop,
        upstreamReadinessGate: UpstreamReadinessGate? = nil,
        notificationSink: (@Sendable (_ sessionID: String, _ data: Data) -> Void)? = nil,
        sessionClosedSink: (@Sendable (_ sessionID: String) -> Void)? = nil,
        catalogChangedSink: (@Sendable () -> Void)? = nil,
        startImmediately: Bool = true
    ) {
        let bridgeRuntimeConfig = config.nativeHostRuntimeConfiguration
        let nativeUpstreamFactory: NativeUpstreamFactory = {
            NativeHostRuntime.makeUpstreamSlot(config: bridgeRuntimeConfig)
        }
        self.init(
            config: config,
            eventLoop: eventLoop,
            upstreams: [nativeUpstreamFactory()],
            upstreamReadinessGate: upstreamReadinessGate,
            nativeUpstreamFactory: nativeUpstreamFactory,
            notificationSink: notificationSink,
            sessionClosedSink: sessionClosedSink,
            catalogChangedSink: catalogChangedSink,
            startImmediately: startImmediately
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
        nativeUpstreamFactory: NativeUpstreamFactory? = nil,
        notificationSink: (@Sendable (_ sessionID: String, _ data: Data) -> Void)? = nil,
        sessionClosedSink: (@Sendable (_ sessionID: String) -> Void)? = nil,
        catalogChangedSink: (@Sendable () -> Void)? = nil,
        testHooks: RuntimeCoordinatorTestHooks = RuntimeCoordinatorTestHooks(),
        startImmediately: Bool = true,
        runtimeBox providedRuntimeBox: WeakRuntimeCoordinatorBox? = nil
    ) {
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
        self.catalogChangedSink = catalogChangedSink
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
            sessionClosedSink: sessionClosedSink,
            nowUptimeNanoseconds: uptimeProvider
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
        self.nativeUpstreamFactory = nativeUpstreamFactory
        self.testHooks = testHooks
        let resolvedReadinessGate =
            upstreamReadinessGate
            ?? .alwaysReady()
        self.upstreamReadinessGate = resolvedReadinessGate
        self.upstreamReadinessCoordinator = UpstreamReadinessCoordinator(
            gate: resolvedReadinessGate,
            logger: ProxyLogging.make("upstream.readiness")
        )
        self.upstreamSlotScheduler = UpstreamSlotScheduler(
            isLeaseLive: { [leaseManager] in leaseManager.isLive($0) },
            canUseUpstream: {
                [weak upstreamHealthManager] upstreamIndex in
                let nowUptimeNs = uptimeProvider()
                guard let upstreamHealthManager else {
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
                    occupiedUpstreams: occupied
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
        let toolsCatalog = self.toolsCatalog
        self.controlPlaneCoordinator = ControlPlaneCoordinator(
            handshakeState: self.canonicalHandshakeState,
            cachedToolsCatalog: { [toolsCatalog] in
                toolsCatalog.canonicalToolsCatalogRaw()
            },
            canonicalToolsSource: { [toolsCatalog] in
                toolsCatalog.canonicalSourceUpstream()
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
            upstreamHandshakeStates: { [weak upstreamHealthManager = self.upstreamHealthManager] in
                guard let upstreamHealthManager else { return [:] }
                let states = upstreamHealthManager.activeStatesSnapshot()
                return Dictionary(
                    uniqueKeysWithValues: states.map { id, state in
                        let summary: String
                        if state.initInFlight {
                            summary = "initializing"
                        } else if state.initPhase.isInitialized {
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
        startEagerInitializePrimary()
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
                    self.handleUpstreamStderr(
                        message,
                        upstreamIndex: upstreamIndex,
                        proof: operationLease.proof
                    )
                case .stdoutProtocolViolation(let protocolViolation):
                    self.handleUpstreamProtocolViolation(
                        protocolViolation,
                        upstreamIndex: upstreamIndex,
                        proof: operationLease.proof
                    )
                case .stdoutBufferSize(let size):
                    self.handleBufferedStdoutBytes(size, upstreamIndex: upstreamIndex)
                case .stdoutClosed:
                    self.handleUpstreamStdoutClosed(
                        upstreamIndex: upstreamIndex,
                        proof: operationLease.proof
                    )

                case .exit(let status):
                    self.handleUpstreamExit(
                        status,
                        upstreamIndex: upstreamIndex,
                        proof: operationLease.proof
                    )

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

    func sessionStateAndTouch(id: String) -> ProxyRuntimeSessionState {
        sessionRegistry.sessionStateAndTouch(id: id)
    }

    func beginClientRequest(id: String, createIfMissing: Bool) -> Bool {
        sessionRegistry.beginClientRequest(id: id, createIfMissing: createIfMissing)
    }

    func endClientRequest(id: String) {
        sessionRegistry.endClientRequest(id: id)
    }

    func openClientEventStream(id: String) -> Bool {
        sessionRegistry.openEventStream(id: id)
    }

    func closeClientEventStream(id: String) {
        sessionRegistry.closeEventStream(id: id)
    }

    func expireInactiveSessions(inactiveForNanoseconds: UInt64) {
        let removedSessionIDs = sessionRegistry.removeInactiveSessions(
            inactiveForNanoseconds: inactiveForNanoseconds
        )
        for sessionID in removedSessionIDs {
            cleanupRemovedSession(id: sessionID)
        }
    }

    func removeSession(id: String) {
        _ = sessionRegistry.removeSession(id: id)
        cleanupRemovedSession(id: id)
    }

    private func cleanupRemovedSession(id: String) {
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
        applyCatalogTransition(toolsCatalog.invalidate())
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
        upstreamReadinessCoordinator.shutdown()

        let runtimeDrain = runtimeTasks.beginShutdown()
        let controlPlaneDrain = await controlPlaneCoordinator.beginShutdown(
            reason: "shutdown",
            clearInitialize: true,
            clearToolsCatalog: true
        )
        applyCatalogTransition(toolsCatalog.invalidate())

        let shutdownTopology = commitUpstreamTopologyMutation {
            upstreamTopology.retireAll()
        }
        await withTaskGroup(of: Void.self) { group in
            for entry in shutdownTopology.retired {
                group.addTask {
                    await entry.slot.stop()
                }
            }
        }
        await upstreamEventTasks.shutdown()
        await controlPlaneDrain.wait()
        await runtimeDrain.wait()
        await upstreamRetirementTasks.shutdown()
    }

    func cancelForDeinit() {
        let shutdownState = initializeManager.beginShutdown()
        shutdownState.timeout?.cancel()
        shutdownState.recoveryTimeout?.cancel()
        for timeout in upstreamHealthManager.clearInitTimeoutsForShutdown() {
            timeout?.cancel()
        }
        upstreamReadinessCoordinator.shutdown()
        applyCatalogTransition(toolsCatalog.invalidate())
        _ = runtimeTasks.beginShutdown()
        _ = upstreamEventTasks.beginShutdown()
        _ = upstreamRetirementTasks.beginShutdown()
    }

    func isInitialized() -> Bool {
        initializeManager.isInitialized()
    }

    func cachedToolsListResult() -> JSONValue? {
        toolsCatalog.canonicalToolsCatalogRaw()
    }

    func cachedToolsListResult(forUpstreamIndex upstreamIndex: Int) -> JSONValue? {
        toolsCatalog.providerCatalog(forUpstreamIndex: upstreamIndex)?.rawResult
    }

    func toolDefinition(named name: String, sourceProof: UpstreamTopologyProof) -> ToolDefinitionSnapshot? {
        toolsCatalog.providerCatalog(for: sourceProof)?.definition(named: name)
    }

    func applyCatalogTransition(_ transition: CatalogTransition) {
        for handle in transition.cancelledRPCs { handle.cancel() }
        if transition.publishesToolsListChanged {
            publishToolsListChangedNotification()
        }
    }

    func publishToolsListChangedNotification() {
        catalogChangedSink?()
        let notification = JSONRPC.Wire.notificationObject(method: "notifications/tools/list_changed")
        guard let data = try? JSONRPC.Wire.data(from: notification) else { return }
        for target in sessionRegistry.initializedNotificationTargets() {
            target.router.handleIncoming(data)
        }
    }

    func publishUpstreamTopology(_ snapshot: UpstreamTopologyAuthority.Snapshot) {
        upstreamRouter.applyTopology(snapshot)
        upstreamHealthManager.applyTopology(snapshot)
        debugRecorder.applyTopology(snapshot)
    }

    func commitUpstreamTopologyMutation(
        _ mutation: () -> UpstreamTopologyAuthority.Transition
    ) -> UpstreamTopologyAuthority.Transition {
        upstreamTopologyCommitLock.withLock {
            let transition = mutation()
            publishUpstreamTopology(transition.snapshot)
            return transition
        }
    }

    func commitUpstreamTopologyMutation(
        _ mutation: () -> UpstreamTopologyAuthority.Transition?
    ) -> UpstreamTopologyAuthority.Transition? {
        upstreamTopologyCommitLock.withLock {
            guard let transition = mutation() else { return nil }
            publishUpstreamTopology(transition.snapshot)
            return transition
        }
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
            self.logNativeToolCatalogSummaryIfNeeded(baseResult)
        }
    }

    func chooseUpstreamOperationLease() -> UpstreamOperationLease? {
        let nowUptimeNs = nowUptimeNanoseconds()

        let chooseResult = upstreamHealthManager.chooseBestInitializedUpstream(
            nowUptimeNs: nowUptimeNs,
            occupiedUpstreams: []
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
        let primaryUpstreamIndex = activePrimaryUpstreamIndex ?? primaryInitializeUpstreamIndex()
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
            return eventLoop.makeFailedFuture(ControlPlane.Error.invalidResponse("invalid initialize response"))
        }

        if shuttingDown {
            return eventLoop.makeFailedFuture(UpstreamSlotScheduler.AcquisitionError.unavailable)
        }

        if pendingPromise != nil {
            _ = session(id: sessionID)
            schedulePendingInitializeQuarantineRecovery()
        }

        if shouldSend {
            startPrimaryInitializeRequestWhenReady()
        }

        guard let promise = pendingPromise else {
            return eventLoop.makeFailedFuture(UpstreamSlotScheduler.AcquisitionError.unavailable)
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
        logNativeToolCatalogSummaryIfNeeded(baseResult)
        return baseResult
    }

    private func logNativeToolCatalogSummaryIfNeeded(_ result: JSONValue) {
        let shouldLog = nativeToolCatalogSummaryLoggedBox.withLockedValue { logged in
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
        applyCatalogTransition(toolsCatalog.invalidate())
        logger.debug("control_plane_invalidated", metadata: ["reason": .string(reason)])
    }

}
