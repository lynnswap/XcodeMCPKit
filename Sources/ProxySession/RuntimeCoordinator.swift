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

package protocol RuntimeCoordinating: Sendable {
    func session(id: String) -> SessionContext
    func hasSession(id: String) -> Bool
    func removeSession(id: String)
    func debugReset()
    func shutdown()
    func isInitialized() -> Bool
    func cachedToolsListResult() -> JSONValue?
    func setCachedToolsListResult(_ result: JSONValue)
    func refreshToolsListIfNeeded()
    func registerInitialize(
        sessionID: String,
        originalID: RPCID,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer>
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
}

extension RuntimeCoordinator {
    package var initializeGate: InitializeManager { initializeManager }
    package var upstreamSelectionPolicy: UpstreamHealthManager { upstreamHealthManager }
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
            let pinnedUpstreamIndex: Int?
            let initializeUpstreamIndex: Int?
            let preferInitializeUpstreamOnNextPin: Bool
            let didReceiveInitializeUpstreamMessage: Bool
        }

        let hasInitResult: Bool
        let initInFlight: Bool
        let didWarmSecondary: Bool
        let shouldRetryEagerInitializePrimaryAfterWarmInitFailure: Bool
        let upstreams: [Upstream]
    }

    package let sessionRegistry: SessionRegistry
    package let initializeManager = InitializeManager()
    package let upstreamTaskBox = NIOLockedValueBox<[Task<Void, Never>]>([])
    package let debugRecorder: ProxyDebugRecorder
    package let leaseManager: LeaseManager
    package let eventLoop: EventLoop
    package let upstreamRouter: UpstreamRouter
    package let config: ProxyConfig
    package let logger: Logger = ProxyLogging.make("session")
    package let upstreams: [any UpstreamSlotControlling]
    package let toolsListCache = ToolsListCache()
    package let initializeParamsOverride: [String: JSONValue]?

    package let upstreamHealthManager: UpstreamHealthManager
    package let upstreamSlotScheduler: UpstreamSlotScheduler
    package let nowUptimeNanoseconds: @Sendable () -> UInt64
    package let scheduleRuntimeTimeout: @Sendable (TimeAmount, @escaping @Sendable () -> Void) ->
        RuntimeScheduledTimeout

    package convenience init(config: ProxyConfig, eventLoop: EventLoop) {
        let count = max(1, min(config.upstreamProcessCount, 10))
        let upstreams = Self.makeDefaultUpstreams(
            config: config, sharedSessionID: config.upstreamSessionID, count: count)
        self.init(config: config, eventLoop: eventLoop, upstreams: upstreams)
    }

    package init(
        config: ProxyConfig,
        eventLoop: EventLoop,
        upstreams: [any UpstreamSlotControlling],
        nowUptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        scheduleRuntimeTimeout: (@Sendable (TimeAmount, @escaping @Sendable () -> Void) ->
            RuntimeScheduledTimeout)? = nil
    ) {
        precondition(!upstreams.isEmpty, "upstreams must not be empty")
        let schedulerProbeStarter = NIOLockedValueBox<(@Sendable ([HealthProbeRequest]) -> Void)?>(nil)
        let uptimeProvider = nowUptimeNanoseconds
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
        self.sessionRegistry = SessionRegistry(config: config)
        self.debugRecorder = ProxyDebugRecorder(upstreamCount: upstreams.count)
        self.leaseManager = LeaseManager()
        self.upstreamRouter = UpstreamRouter(upstreamCount: upstreams.count)
        self.upstreamHealthManager = UpstreamHealthManager(upstreamCount: upstreams.count)
        self.nowUptimeNanoseconds = nowUptimeNanoseconds
        self.scheduleRuntimeTimeout = timeoutScheduler
        self.upstreamSlotScheduler = UpstreamSlotScheduler(
            upstreamCount: upstreams.count,
            defaultCapacity: 1,
            canUseUpstream: { [weak upstreamHealthManager = self.upstreamHealthManager] upstreamIndex in
                let nowUptimeNs = uptimeProvider()
                guard let upstreamHealthManager else { return false }
                let evaluation = upstreamHealthManager.evaluateUsableInitialized(
                    index: upstreamIndex,
                    nowUptimeNs: nowUptimeNs
                )
                let probesToStart = evaluation.1
                if probesToStart.isEmpty == false {
                    let startProbes = schedulerProbeStarter.withLockedValue { $0 }
                    startProbes?(probesToStart)
                }
                return evaluation.0
            },
            selectUpstream: { [weak upstreamHealthManager = self.upstreamHealthManager] occupied in
                let nowUptimeNs = uptimeProvider()
                let chooseResult = upstreamHealthManager?.chooseBestInitializedUpstream(
                    nowUptimeNs: nowUptimeNs,
                    occupiedUpstreams: occupied
                )
                let probesToStart = chooseResult?.1 ?? []
                if probesToStart.isEmpty == false {
                    let startProbes = schedulerProbeStarter.withLockedValue { $0 }
                    startProbes?(probesToStart)
                }
                return chooseResult?.0
            }
        )
        self.initializeParamsOverride = ProxyFileConfigLoader.loadInitializeParamsOverride(
            configPath: config.configPath,
            logger: ProxyLogging.make("config")
        )
        schedulerProbeStarter.withLockedValue { startProbes in
            startProbes = { [weak self] probes in
                self?.startHealthProbes(probes)
            }
        }

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
            Task {
                await upstream.start()
            }
        }
        upstreamTaskBox.withLockedValue { taskBox in
            taskBox = tasks
        }

        startEagerInitializePrimary()
    }

    package func session(id: String) -> SessionContext {
        sessionRegistry.session(id: id)
    }

    package func hasSession(id: String) -> Bool {
        sessionRegistry.hasSession(id: id)
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

        toolsListCache.reset()
        upstreamRouter.resetAll()
        _ = leaseManager.resetAll(reason: .clientDisconnected)
        upstreamSlotScheduler.reset()
        debugRecorder.resetAll()
    }

    package func shutdown() {
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

        let tasks = upstreamTaskBox.withLockedValue { taskBox -> [Task<Void, Never>] in
            let current = taskBox
            taskBox = []
            return current
        }
        for task in tasks {
            task.cancel()
        }
        for upstream in upstreams {
            Task {
                await upstream.stop()
            }
        }
    }

    package func isInitialized() -> Bool {
        initializeManager.isInitialized()
    }

    package func cachedToolsListResult() -> JSONValue? {
        toolsListCache.cachedResult()
    }

    package func setCachedToolsListResult(_ result: JSONValue) {
        guard isValidToolsListResult(result) else { return }
        toolsListCache.setCachedResult(result)
    }

    package func refreshToolsListIfNeeded() {
        let shouldStart = toolsListCache.beginWarmupIfNeeded(
            isEnabled: config.prewarmToolsList,
            isInitialized: isInitialized()
        )
        guard shouldStart else { return }

        Task { [weak self] in
            guard let self else { return }
            await self.refreshToolsList()
        }
    }

    package func chooseUpstreamIndex() -> Int? {
        let nowUptimeNs = nowUptimeNanoseconds()
        let occupiedUpstreams = upstreamSlotScheduler.occupiedUpstreamIndices()

        let chooseResult = upstreamHealthManager.chooseBestInitializedUpstream(
            nowUptimeNs: nowUptimeNs,
            occupiedUpstreams: occupiedUpstreams
        )
        let chosen = chooseResult.0
        startHealthProbes(chooseResult.1)

        guard let chosen else {
            return nil
        }

        return chosen
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
            initializeManager.consumeRetryAfterWarmInitFailureRegardlessOfCachedInit()
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

    func chooseUpstreamIndex(sessionID _: String, shouldPin _: Bool) -> Int? {
        chooseUpstreamIndex()
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
            let upstreamID = upstreamRouter.assignInitialize(upstreamIndex: 0)
            initializeManager.setPrimaryInitUpstreamID(upstreamID)
            markUpstreamInitInFlight(upstreamIndex: 0, upstreamID: upstreamID)
            let initRequest = makeInternalInitializeRequest(id: upstreamID)
            if let data = try? JSONSerialization.data(withJSONObject: initRequest, options: []) {
                sendUpstream(data, upstreamIndex: 0, ensureRunning: true)
            } else {
                failInitPending(error: TimeoutError())
            }
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

}
