import Foundation
import Logging
import NIO
import XcodeMCPCore

actor ControlPlaneCoordinator {
    typealias ToolsCatalogLoader =
        @Sendable (_ requestTimeout: TimeAmount?, _ rpcHandle: ControlPlane.RPCHandle,
                   _ onFreshProvider: @escaping @Sendable (UpstreamTopologyProof) async -> Void) async throws
            -> CanonicalToolsCatalogLoadResult
    typealias UpstreamHandshakeStatesProvider = @Sendable () -> [String: String]
    typealias CachedToolsCatalogProvider = @Sendable () -> JSONValue?
    typealias CanonicalToolsSourceProvider = @Sendable () -> Int?
    typealias RefreshedToolsCatalogProvider = @Sendable (Set<UpstreamTopologyProof>) -> JSONValue?

    struct Drain: Sendable {
        private let completionTasks: [Task<Void, Never>]

        init(completionTasks: [Task<Void, Never>]) {
            self.completionTasks = completionTasks
        }

        func wait() async {
            for task in completionTasks {
                await task.value
            }
        }
    }

    enum Phase: String, Sendable {
        case idle
        case loadingToolsCatalog = "loading_tools_catalog"
    }

    enum ToolsCatalogLoadOrigin: Sendable {
        case request
        case prewarm
    }

    enum ToolsCatalogWaiterKind {
        case foreground
        case prewarmObserver
    }

    typealias WaiterID = UUID

    struct ToolsCatalogWaiterRecord {
        let continuation: CheckedContinuation<JSONValue, Error>
        let kind: ToolsCatalogWaiterKind
        let deadlineUptimeNs: UInt64?
        let partialPublicationUptimeNs: UInt64?
        var timeoutTask: Task<Void, Never>?
    }

    struct ToolsCatalogLoadState {
        let loadID: UUID
        let origin: ToolsCatalogLoadOrigin
        let requestTimeout: TimeAmount?
        let requestDeadlineUptimeNs: UInt64?
        let rpcHandle: ControlPlane.RPCHandle
        let task: Task<CanonicalToolsCatalogLoadResult, Error>
        var waiters: [WaiterID: ToolsCatalogWaiterRecord] = [:]
        var foregroundWaiterCount = 0
        var freshSources: Set<UpstreamTopologyProof> = []
        var hasPublishedPartialResult = false
    }

    let handshakeState: CanonicalHandshakeState
    let cachedToolsCatalog: CachedToolsCatalogProvider
    let refreshedToolsCatalog: RefreshedToolsCatalogProvider
    let canonicalToolsSource: CanonicalToolsSourceProvider
    let debugMirror: ControlPlane.DebugMirror
    let toolsCatalogLoader: ToolsCatalogLoader
    let upstreamHandshakeStates: UpstreamHandshakeStatesProvider
    let logger: Logger
    let controlPlaneDefaultTimeout: TimeAmount?
    let clock: ClockClient

    var toolsCatalogLoad: ToolsCatalogLoadState?
    var prewarmToolsCatalogLoad: ToolsCatalogLoadState?
    var completionTasks: [UUID: Task<Void, Never>] = [:]
    var acceptsNewLoads = true

    init(
        handshakeState: CanonicalHandshakeState,
        cachedToolsCatalog: @escaping CachedToolsCatalogProvider,
        refreshedToolsCatalog: @escaping RefreshedToolsCatalogProvider,
        canonicalToolsSource: @escaping CanonicalToolsSourceProvider,
        debugMirror: ControlPlane.DebugMirror,
        toolsCatalogLoader: @escaping ToolsCatalogLoader,
        upstreamHandshakeStates: @escaping UpstreamHandshakeStatesProvider,
        logger: Logger,
        controlPlaneDefaultTimeout: TimeAmount?,
        clock: ClockClient = .liveValue
    ) {
        self.handshakeState = handshakeState
        self.cachedToolsCatalog = cachedToolsCatalog
        self.refreshedToolsCatalog = refreshedToolsCatalog
        self.canonicalToolsSource = canonicalToolsSource
        self.debugMirror = debugMirror
        self.toolsCatalogLoader = toolsCatalogLoader
        self.upstreamHandshakeStates = upstreamHandshakeStates
        self.logger = logger
        self.controlPlaneDefaultTimeout = controlPlaneDefaultTimeout
        self.clock = clock
    }

    func toolsCatalog(deadlineUptimeNs: UInt64?) async throws -> JSONValue {
        guard acceptsNewLoads else {
            throw CancellationError()
        }
        guard deadlineExceeded(deadlineUptimeNs) == false else {
            throw TimeoutError()
        }

        let requestedTimeout = sharedRequestTimeout(for: deadlineUptimeNs)
        let requestedPromotionDeadlineUptimeNs = promotionDeadlineUptimeNs(
            forWaiterDeadlineUptimeNs: deadlineUptimeNs
        )
        let loadID = ensureToolsCatalogForegroundLoad(
            requestTimeout: requestedTimeout,
            requestedPromotionDeadlineUptimeNs: requestedPromotionDeadlineUptimeNs
        )
        let waiterID = WaiterID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerToolsCatalogWaiter(
                    loadID: loadID,
                    waiterID: waiterID,
                    deadlineUptimeNs: deadlineUptimeNs,
                    kind: .foreground,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelToolsCatalogWaiter(waiterID: waiterID)
            }
        }
    }

    func prewarmToolsCatalogIfNeeded(deadlineUptimeNs: UInt64?) async -> JSONValue? {
        guard acceptsNewLoads else {
            return nil
        }
        if let rawResult = cachedToolsCatalog() {
            syncDebug()
            return rawResult
        }
        guard deadlineExceeded(deadlineUptimeNs) == false else {
            return nil
        }
        guard
            toolsCatalogLoad == nil,
            prewarmToolsCatalogLoad == nil
        else {
            syncDebug()
            return nil
        }

        let loadID = startToolsCatalogLoad(
            origin: .prewarm,
            requestTimeout: sharedRequestTimeout(for: deadlineUptimeNs)
        )
        let waiterID = WaiterID()

        do {
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<JSONValue, Error>) in
                registerToolsCatalogWaiter(
                    loadID: loadID,
                    waiterID: waiterID,
                    deadlineUptimeNs: deadlineUptimeNs,
                    kind: .prewarmObserver,
                    continuation: continuation
                )
            }
        } catch {
            logger.debug(
                "tools catalog prewarm failed",
                metadata: ["error": .string(String(describing: error))]
            )
            return nil
        }
    }

    func invalidate(
        reason _: String,
        clearInitialize: Bool = false,
        clearToolsCatalog: Bool = true
    ) {
        if let load = toolsCatalogLoad {
            toolsCatalogLoad = nil
            cancelToolsCatalogLoad(load, error: CancellationError())
        }
        if let load = prewarmToolsCatalogLoad {
            prewarmToolsCatalogLoad = nil
            cancelToolsCatalogLoad(load, error: CancellationError())
        }

        if clearInitialize { handshakeState.clearInitialize() }
        _ = clearToolsCatalog
        syncDebug()
    }

    func beginShutdown(
        reason: String,
        clearInitialize: Bool = false,
        clearToolsCatalog: Bool = true
    ) -> Drain {
        acceptsNewLoads = false
        invalidate(
            reason: reason,
            clearInitialize: clearInitialize,
            clearToolsCatalog: clearToolsCatalog
        )
        return Drain(completionTasks: Array(completionTasks.values))
    }

    func startToolsCatalogLoad(
        origin: ToolsCatalogLoadOrigin,
        requestTimeout: TimeAmount?
    ) -> UUID {
        let loadID = UUID()
        let rpcHandle = ControlPlane.RPCHandle()
        let requestDeadlineUptimeNs = requestDeadline(for: requestTimeout)
        let task = Task.detached {
            try await self.toolsCatalogLoader(requestTimeout, rpcHandle) { source in
                await self.noteFreshToolsCatalogProvider(source, loadID: loadID)
            }
        }
        let load = ToolsCatalogLoadState(
            loadID: loadID,
            origin: origin,
            requestTimeout: requestTimeout,
            requestDeadlineUptimeNs: requestDeadlineUptimeNs,
            rpcHandle: rpcHandle,
            task: task
        )
        switch origin {
        case .request:
            toolsCatalogLoad = load
        case .prewarm:
            prewarmToolsCatalogLoad = load
        }
        let completionTask = Task { [loadID] in
            let result: Result<CanonicalToolsCatalogLoadResult, Error>
            do {
                result = .success(try await task.value)
            } catch {
                result = .failure(error)
            }
            self.completeToolsCatalogLoad(loadID: loadID, result: result)
            self.finishCompletionTask(loadID: loadID)
        }
        completionTasks[loadID] = completionTask
        syncDebug()
        return loadID
    }

    func finishCompletionTask(loadID: UUID) {
        completionTasks.removeValue(forKey: loadID)
    }

    func ensureToolsCatalogForegroundLoad(
        requestTimeout: TimeAmount?,
        requestedPromotionDeadlineUptimeNs: UInt64?
    ) -> UUID {
        if let current = toolsCatalogLoad {
            if current.foregroundWaiterCount <= 1 && shouldPromoteSharedLoad(
                currentRequestDeadlineUptimeNs: current.requestDeadlineUptimeNs,
                requestedRequestDeadlineUptimeNs: requestedPromotionDeadlineUptimeNs
            ) {
                return replaceToolsCatalogRequestLoad(current, requestTimeout: requestTimeout)
            }
            return current.loadID
        }
        if let current = prewarmToolsCatalogLoad {
            if current.foregroundWaiterCount <= 1 && shouldPromoteSharedLoad(
                currentRequestDeadlineUptimeNs: current.requestDeadlineUptimeNs,
                requestedRequestDeadlineUptimeNs: requestedPromotionDeadlineUptimeNs
            ) {
                return promotePrewarmToolsCatalogLoad(current, requestTimeout: requestTimeout)
            }
            return current.loadID
        }
        return startToolsCatalogLoad(origin: .request, requestTimeout: requestTimeout)
    }

    func registerToolsCatalogWaiter(
        loadID: UUID,
        waiterID: WaiterID,
        deadlineUptimeNs: UInt64?,
        kind: ToolsCatalogWaiterKind,
        continuation: CheckedContinuation<JSONValue, Error>
    ) {
        guard var load = currentToolsCatalogLoadState(loadID: loadID) else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if deadlineExceeded(deadlineUptimeNs) {
            if load.waiters.isEmpty {
                clearToolsCatalogLoadState(loadID: loadID)
                cancelToolsCatalogLoad(load, error: TimeoutError())
                syncDebug()
            }
            continuation.resume(throwing: TimeoutError())
            return
        }
        let publicationTime = kind == .foreground ? partialToolsCatalogPublicationTime(deadlineUptimeNs) : nil
        let timeoutTask = makeTimeoutTask(deadlineUptimeNs: publicationTime ?? deadlineUptimeNs) {
            await self.toolsCatalogWaiterPhaseReached(loadID: loadID, waiterID: waiterID)
        }
        load.waiters[waiterID] = ToolsCatalogWaiterRecord(
            continuation: continuation,
            kind: kind,
            deadlineUptimeNs: deadlineUptimeNs,
            partialPublicationUptimeNs: publicationTime,
            timeoutTask: timeoutTask
        )
        if kind == .foreground {
            load.foregroundWaiterCount += 1
        }
        setToolsCatalogLoadState(load)
        syncDebug()
    }

    func noteFreshToolsCatalogProvider(_ source: UpstreamTopologyProof, loadID: UUID) {
        guard var load = currentToolsCatalogLoadState(loadID: loadID) else { return }
        load.freshSources.insert(source)
        setToolsCatalogLoadState(load)
        for waiterID in load.waiters.keys {
            _ = publishPartialToolsCatalogIfReady(loadID: loadID, waiterID: waiterID)
        }
    }

    @discardableResult
    private func publishPartialToolsCatalogIfReady(loadID: UUID, waiterID: WaiterID) -> Bool {
        guard var load = currentToolsCatalogLoadState(loadID: loadID),
              let waiter = load.waiters[waiterID],
              let publicationTime = waiter.partialPublicationUptimeNs,
              clock.uptimeNanoseconds() >= publicationTime,
              deadlineExceeded(waiter.deadlineUptimeNs) == false,
              let result = refreshedToolsCatalog(load.freshSources) else { return false }
        load.waiters.removeValue(forKey: waiterID)
        load.foregroundWaiterCount = max(0, load.foregroundWaiterCount - 1)
        load.hasPublishedPartialResult = true
        waiter.timeoutTask?.cancel()
        // A successful partial response leaves the bounded read running so later
        // provider commits can publish their catalog changes.
        setToolsCatalogLoadState(load)
        syncDebug()
        waiter.continuation.resume(returning: result)
        return true
    }

    func toolsCatalogWaiterPhaseReached(loadID: UUID, waiterID: WaiterID) {
        if publishPartialToolsCatalogIfReady(loadID: loadID, waiterID: waiterID) { return }
        guard var load = currentToolsCatalogLoadState(loadID: loadID),
              var waiter = load.waiters[waiterID] else { return }
        if deadlineExceeded(waiter.deadlineUptimeNs) {
            timeoutToolsCatalogWaiter(loadID: loadID, waiterID: waiterID)
            return
        }
        waiter.timeoutTask = makeTimeoutTask(deadlineUptimeNs: waiter.deadlineUptimeNs) {
            await self.timeoutToolsCatalogWaiter(loadID: loadID, waiterID: waiterID)
        }
        load.waiters[waiterID] = waiter
        setToolsCatalogLoadState(load)
    }

    func timeoutToolsCatalogWaiter(loadID: UUID, waiterID: WaiterID) {
        removeToolsCatalogWaiter(loadID: loadID, waiterID: waiterID, failingWith: TimeoutError())
    }

    func cancelToolsCatalogWaiter(loadID: UUID, waiterID: WaiterID) {
        removeToolsCatalogWaiter(loadID: loadID, waiterID: waiterID, failingWith: CancellationError())
    }

    private func removeToolsCatalogWaiter(
        loadID: UUID,
        waiterID: WaiterID,
        failingWith error: any Error
    ) {
        guard var load = currentToolsCatalogLoadState(loadID: loadID) else { return }
        guard let waiter = load.waiters.removeValue(forKey: waiterID) else { return }
        waiter.timeoutTask?.cancel()
        if waiter.kind == .foreground {
            load.foregroundWaiterCount = max(0, load.foregroundWaiterCount - 1)
        }
        let shouldCancel = shouldCancelToolsCatalogLoadAfterWaiterRemoval(load)
        if shouldCancel {
            clearToolsCatalogLoadState(loadID: loadID)
            cancelToolsCatalogLoad(load, error: CancellationError())
        } else {
            setToolsCatalogLoadState(load)
        }
        syncDebug()
        waiter.continuation.resume(throwing: error)
    }

    func cancelToolsCatalogWaiter(waiterID: WaiterID) {
        if let load = toolsCatalogLoad, load.waiters[waiterID] != nil {
            cancelToolsCatalogWaiter(loadID: load.loadID, waiterID: waiterID)
            return
        }
        if let load = prewarmToolsCatalogLoad, load.waiters[waiterID] != nil {
            cancelToolsCatalogWaiter(loadID: load.loadID, waiterID: waiterID)
        }
    }

    func completeToolsCatalogLoad(
        loadID: UUID,
        result: Result<CanonicalToolsCatalogLoadResult, Error>
    ) {
        guard let load = takeToolsCatalogLoadIfMatching(loadID: loadID) else { return }
        let waiters = Array(load.waiters.values)
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
        }
        syncDebug()
        for waiter in waiters {
            if deadlineExceeded(waiter.deadlineUptimeNs) {
                waiter.continuation.resume(throwing: TimeoutError())
                continue
            }
            switch result {
            case .success(let loaded):
                waiter.continuation.resume(returning: loaded.rawResult)
            case .failure(let error):
                waiter.continuation.resume(throwing: error)
            }
        }
    }

}
