import Foundation
import Logging
import NIO
import ProxyCore
import ProxyMCP

package actor ControlPlaneCoordinator {
    package typealias ToolsCatalogLoader =
        @Sendable (_ requestTimeout: TimeAmount?, _ rpcHandle: ControlPlaneRPCHandle) async throws
            -> CanonicalToolsCatalogLoadResult
    package typealias WindowsLoader =
        @Sendable (
            _ route: ControlPlaneRoute,
            _ requestTimeout: TimeAmount?,
            _ rpcHandle: ControlPlaneRPCHandle
        ) async throws -> JSONValue
    package typealias UpstreamHandshakeStatesProvider = @Sendable () -> [String: String]

    enum Phase: String, Sendable {
        case idle
        case loadingToolsCatalog = "loading_tools_catalog"
        case listingWindows = "listing_windows"
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
        let timeoutTask: Task<Void, Never>?
    }

    struct WindowWaiterRecord {
        let continuation: CheckedContinuation<JSONValue, Error>
        let deadlineUptimeNs: UInt64?
        let timeoutTask: Task<Void, Never>?
    }

    struct ToolsCatalogLoadState {
        let loadID: UUID
        let origin: ToolsCatalogLoadOrigin
        let requestTimeout: TimeAmount?
        let requestDeadlineUptimeNs: UInt64?
        let rpcHandle: ControlPlaneRPCHandle
        let task: Task<CanonicalToolsCatalogLoadResult, Error>
        let startGeneration: UInt64
        var waiters: [WaiterID: ToolsCatalogWaiterRecord] = [:]
        var foregroundWaiterCount = 0
    }

    struct WindowLoadState {
        let loadID: UUID
        let route: ControlPlaneRoute
        let requestTimeout: TimeAmount?
        let requestDeadlineUptimeNs: UInt64?
        let rpcHandle: ControlPlaneRPCHandle
        let task: Task<JSONValue, Error>
        let startGeneration: UInt64
        var waiters: [WaiterID: WindowWaiterRecord] = [:]
    }

    let brokerState: CanonicalBrokerState
    let debugMirror: ControlPlaneDebugMirror
    let toolsCatalogLoader: ToolsCatalogLoader
    let windowsLoader: WindowsLoader
    let upstreamHandshakeStates: UpstreamHandshakeStatesProvider
    let logger: Logger
    let controlPlaneDefaultTimeout: TimeAmount?
    let clock: ClockClient

    var toolsCatalogLoad: ToolsCatalogLoadState?
    var prewarmToolsCatalogLoad: ToolsCatalogLoadState?
    var windowLoads: [ControlPlaneRoute: WindowLoadState] = [:]

    package init(
        brokerState: CanonicalBrokerState,
        debugMirror: ControlPlaneDebugMirror,
        toolsCatalogLoader: @escaping ToolsCatalogLoader,
        windowsLoader: @escaping WindowsLoader,
        upstreamHandshakeStates: @escaping UpstreamHandshakeStatesProvider,
        logger: Logger,
        controlPlaneDefaultTimeout: TimeAmount?,
        clock: ClockClient = .liveValue
    ) {
        self.brokerState = brokerState
        self.debugMirror = debugMirror
        self.toolsCatalogLoader = toolsCatalogLoader
        self.windowsLoader = windowsLoader
        self.upstreamHandshakeStates = upstreamHandshakeStates
        self.logger = logger
        self.controlPlaneDefaultTimeout = controlPlaneDefaultTimeout
        self.clock = clock
    }

    package func toolsCatalog(deadlineUptimeNs: UInt64?) async throws -> JSONValue {
        cancelInvalidatedLoads()
        if let rawResult = brokerState.toolsCatalogRaw() {
            return rawResult
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

    package func listWindows(
        route: ControlPlaneRoute,
        deadlineUptimeNs: UInt64?
    ) async throws -> JSONValue {
        cancelInvalidatedLoads()
        let requestedTimeout = sharedRequestTimeout(for: deadlineUptimeNs)
        let requestedPromotionDeadlineUptimeNs = promotionDeadlineUptimeNs(
            forWaiterDeadlineUptimeNs: deadlineUptimeNs
        )
        let loadID = ensureWindowLoad(
            route: route,
            requestTimeout: requestedTimeout,
            requestedPromotionDeadlineUptimeNs: requestedPromotionDeadlineUptimeNs
        )
        let waiterID = WaiterID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerWindowWaiter(
                    route: route,
                    loadID: loadID,
                    waiterID: waiterID,
                    deadlineUptimeNs: deadlineUptimeNs,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelWindowWaiter(route: route, waiterID: waiterID)
            }
        }
    }

    package func prewarmToolsCatalogIfNeeded(deadlineUptimeNs: UInt64?) async {
        cancelInvalidatedLoads()
        guard
            brokerState.toolsCatalogRaw() == nil,
            toolsCatalogLoad == nil,
            prewarmToolsCatalogLoad == nil
        else {
            syncDebug()
            return
        }

        let loadID = startToolsCatalogLoad(
            origin: .prewarm,
            requestTimeout: sharedRequestTimeout(for: deadlineUptimeNs)
        )
        let waiterID = WaiterID()

        do {
            _ = try await withCheckedThrowingContinuation {
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
        }
    }

    package func invalidate(
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
        let activeWindows = Array(windowLoads.values)
        windowLoads.removeAll()
        for load in activeWindows {
            cancelWindowLoad(load, error: CancellationError())
        }

        if clearInitialize {
            brokerState.clearInitialize()
        }
        if clearToolsCatalog {
            brokerState.clearToolsCatalog()
        }
        syncDebug()
    }

    func startToolsCatalogLoad(
        origin: ToolsCatalogLoadOrigin,
        requestTimeout: TimeAmount?
    ) -> UUID {
        let loadID = UUID()
        let rpcHandle = ControlPlaneRPCHandle()
        let requestDeadlineUptimeNs = requestDeadline(for: requestTimeout)
        let task = Task.detached {
            try await self.toolsCatalogLoader(requestTimeout, rpcHandle)
        }
        let load = ToolsCatalogLoadState(
            loadID: loadID,
            origin: origin,
            requestTimeout: requestTimeout,
            requestDeadlineUptimeNs: requestDeadlineUptimeNs,
            rpcHandle: rpcHandle,
            task: task,
            startGeneration: brokerState.generation()
        )
        switch origin {
        case .request:
            toolsCatalogLoad = load
        case .prewarm:
            prewarmToolsCatalogLoad = load
        }
        Task { [loadID] in
            let result: Result<CanonicalToolsCatalogLoadResult, Error>
            do {
                result = .success(try await task.value)
            } catch {
                result = .failure(error)
            }
            self.completeToolsCatalogLoad(loadID: loadID, result: result)
        }
        syncDebug()
        return loadID
    }

    func startWindowLoad(
        route: ControlPlaneRoute,
        requestTimeout: TimeAmount?
    ) -> UUID {
        let loadID = UUID()
        let rpcHandle = ControlPlaneRPCHandle()
        let requestDeadlineUptimeNs = requestDeadline(for: requestTimeout)
        let task = Task.detached {
            try await self.windowsLoader(route, requestTimeout, rpcHandle)
        }
        windowLoads[route] = WindowLoadState(
            loadID: loadID,
            route: route,
            requestTimeout: requestTimeout,
            requestDeadlineUptimeNs: requestDeadlineUptimeNs,
            rpcHandle: rpcHandle,
            task: task,
            startGeneration: brokerState.generation()
        )
        Task { [route, loadID] in
            let result: Result<JSONValue, Error>
            do {
                result = .success(try await task.value)
            } catch {
                result = .failure(error)
            }
            self.completeWindowLoad(route: route, loadID: loadID, result: result)
        }
        syncDebug()
        return loadID
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

    func ensureWindowLoad(
        route: ControlPlaneRoute,
        requestTimeout: TimeAmount?,
        requestedPromotionDeadlineUptimeNs: UInt64?
    ) -> UUID {
        if let current = windowLoads[route] {
            if current.waiters.count <= 1 && shouldPromoteSharedLoad(
                currentRequestDeadlineUptimeNs: current.requestDeadlineUptimeNs,
                requestedRequestDeadlineUptimeNs: requestedPromotionDeadlineUptimeNs
            ) {
                return replaceWindowLoad(
                    route: route,
                    current: current,
                    requestTimeout: requestTimeout
                )
            }
            return current.loadID
        }
        return startWindowLoad(route: route, requestTimeout: requestTimeout)
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
            continuation.resume(throwing: TimeoutError())
            return
        }
        let timeoutTask = makeTimeoutTask(deadlineUptimeNs: deadlineUptimeNs) {
            await self.timeoutToolsCatalogWaiter(loadID: loadID, waiterID: waiterID)
        }
        load.waiters[waiterID] = ToolsCatalogWaiterRecord(
            continuation: continuation,
            kind: kind,
            deadlineUptimeNs: deadlineUptimeNs,
            timeoutTask: timeoutTask
        )
        if kind == .foreground {
            load.foregroundWaiterCount += 1
        }
        setToolsCatalogLoadState(load)
        syncDebug()
    }

    func registerWindowWaiter(
        route: ControlPlaneRoute,
        loadID: UUID,
        waiterID: WaiterID,
        deadlineUptimeNs: UInt64?,
        continuation: CheckedContinuation<JSONValue, Error>
    ) {
        guard var load = windowLoads[route], load.loadID == loadID else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if deadlineExceeded(deadlineUptimeNs) {
            continuation.resume(throwing: TimeoutError())
            return
        }
        let timeoutTask = makeTimeoutTask(deadlineUptimeNs: deadlineUptimeNs) {
            await self.timeoutWindowWaiter(route: route, loadID: loadID, waiterID: waiterID)
        }
        load.waiters[waiterID] = WindowWaiterRecord(
            continuation: continuation,
            deadlineUptimeNs: deadlineUptimeNs,
            timeoutTask: timeoutTask
        )
        windowLoads[route] = load
        syncDebug()
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
        waiter.continuation.resume(throwing: error)
        if shouldCancel {
            clearToolsCatalogLoadState(loadID: loadID)
            cancelToolsCatalogLoad(load, error: CancellationError())
        } else {
            setToolsCatalogLoadState(load)
        }
        syncDebug()
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

    func timeoutWindowWaiter(
        route: ControlPlaneRoute,
        loadID: UUID,
        waiterID: WaiterID
    ) {
        removeWindowWaiter(route: route, loadID: loadID, waiterID: waiterID, failingWith: TimeoutError())
    }

    func cancelWindowWaiter(
        route: ControlPlaneRoute,
        loadID: UUID,
        waiterID: WaiterID
    ) {
        removeWindowWaiter(
            route: route,
            loadID: loadID,
            waiterID: waiterID,
            failingWith: CancellationError()
        )
    }

    private func removeWindowWaiter(
        route: ControlPlaneRoute,
        loadID: UUID,
        waiterID: WaiterID,
        failingWith error: any Error
    ) {
        guard var load = windowLoads[route], load.loadID == loadID else { return }
        guard let waiter = load.waiters.removeValue(forKey: waiterID) else { return }
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(throwing: error)
        if load.waiters.isEmpty {
            windowLoads.removeValue(forKey: route)
            cancelWindowLoad(load, error: CancellationError())
        } else {
            windowLoads[route] = load
        }
        syncDebug()
    }

    func cancelWindowWaiter(
        route: ControlPlaneRoute,
        waiterID: WaiterID
    ) {
        guard let load = windowLoads[route], load.waiters[waiterID] != nil else { return }
        cancelWindowWaiter(route: route, loadID: load.loadID, waiterID: waiterID)
    }

    func completeToolsCatalogLoad(
        loadID: UUID,
        result: Result<CanonicalToolsCatalogLoadResult, Error>
    ) {
        guard let load = takeToolsCatalogLoadIfMatching(loadID: loadID) else { return }
        let completedUnderCurrentGeneration = brokerState.generation() == load.startGeneration
        if case .success(let loaded) = result, let sourceUpstream = loaded.sourceUpstream {
            brokerState.syncCanonicalToolsCatalog(
                loaded.rawResult,
                sourceUpstream: sourceUpstream,
                onlyIfGeneration: load.startGeneration
            )
        }
        let waiters = Array(load.waiters.values)
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            switch (result, completedUnderCurrentGeneration) {
            case (.success(let loaded), true):
                waiter.continuation.resume(returning: loaded.rawResult)
            case (.success, false):
                waiter.continuation.resume(throwing: CancellationError())
            case (.failure(let error), _):
                waiter.continuation.resume(throwing: error)
            }
        }
        syncDebug()
    }

    func completeWindowLoad(
        route: ControlPlaneRoute,
        loadID: UUID,
        result: Result<JSONValue, Error>
    ) {
        guard let load = windowLoads[route], load.loadID == loadID else { return }
        windowLoads.removeValue(forKey: route)
        let completedUnderCurrentGeneration = brokerState.generation() == load.startGeneration
        let waiters = Array(load.waiters.values)
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            switch (result, completedUnderCurrentGeneration) {
            case (.success(let loaded), true):
                waiter.continuation.resume(returning: loaded)
            case (.success, false):
                waiter.continuation.resume(throwing: CancellationError())
            case (.failure(let error), _):
                waiter.continuation.resume(throwing: error)
            }
        }
        syncDebug()
    }
}
