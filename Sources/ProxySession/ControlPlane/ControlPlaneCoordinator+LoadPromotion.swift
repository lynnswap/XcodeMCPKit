import Foundation
import NIO

extension ControlPlaneCoordinator {
    func replaceToolsCatalogRequestLoad(
        _ current: ToolsCatalogLoadState,
        requestTimeout: TimeAmount?
    ) -> UUID {
        var previous = current
        toolsCatalogLoad = nil
        let migratedWaiters = removeForegroundToolsCatalogWaiters(from: &previous)
        cancelToolsCatalogLoad(previous, error: CancellationError())
        let newLoadID = startToolsCatalogLoad(origin: .request, requestTimeout: requestTimeout)
        attachToolsCatalogWaiters(loadID: newLoadID, waiters: migratedWaiters)
        return newLoadID
    }

    func promotePrewarmToolsCatalogLoad(
        _ current: ToolsCatalogLoadState,
        requestTimeout: TimeAmount?
    ) -> UUID {
        var previous = current
        prewarmToolsCatalogLoad = nil
        let migratedWaiters = removeForegroundToolsCatalogWaiters(from: &previous)
        cancelToolsCatalogLoad(previous, error: CancellationError())
        let newLoadID = startToolsCatalogLoad(origin: .request, requestTimeout: requestTimeout)
        attachToolsCatalogWaiters(loadID: newLoadID, waiters: migratedWaiters)
        return newLoadID
    }

    func replaceWindowLoad(
        route: ControlPlaneRoute,
        current: WindowLoadState,
        requestTimeout: TimeAmount?
    ) -> UUID {
        let migratedWaiters = Array(current.waiters)
        windowLoads.removeValue(forKey: route)
        cancelWindowLoad(
            WindowLoadState(
                loadID: current.loadID,
                route: current.route,
                requestTimeout: current.requestTimeout,
                requestDeadlineUptimeNs: current.requestDeadlineUptimeNs,
                rpcHandle: current.rpcHandle,
                task: current.task,
                waiters: [:]
            ),
            error: CancellationError()
        )
        let newLoadID = startWindowLoad(route: route, requestTimeout: requestTimeout)
        attachWindowWaiters(route: route, loadID: newLoadID, waiters: migratedWaiters)
        return newLoadID
    }

    func removeForegroundToolsCatalogWaiters(
        from load: inout ToolsCatalogLoadState
    ) -> [(WaiterID, ToolsCatalogWaiterRecord)] {
        var migrated: [(WaiterID, ToolsCatalogWaiterRecord)] = []
        for (waiterID, waiter) in load.waiters where waiter.kind == .foreground {
            waiter.timeoutTask?.cancel()
            migrated.append((waiterID, waiter))
        }
        for (waiterID, _) in migrated {
            load.waiters.removeValue(forKey: waiterID)
        }
        load.foregroundWaiterCount = 0
        return migrated
    }

    func attachToolsCatalogWaiters(
        loadID: UUID,
        waiters: [(WaiterID, ToolsCatalogWaiterRecord)]
    ) {
        guard var load = currentToolsCatalogLoadState(loadID: loadID) else { return }
        for (waiterID, waiter) in waiters {
            if deadlineExceeded(waiter.deadlineUptimeNs) {
                waiter.continuation.resume(throwing: TimeoutError())
                continue
            }
            let timeoutTask = makeTimeoutTask(deadlineUptimeNs: waiter.deadlineUptimeNs) {
                await self.timeoutToolsCatalogWaiter(loadID: loadID, waiterID: waiterID)
            }
            load.waiters[waiterID] = ToolsCatalogWaiterRecord(
                continuation: waiter.continuation,
                kind: waiter.kind,
                deadlineUptimeNs: waiter.deadlineUptimeNs,
                timeoutTask: timeoutTask
            )
            if waiter.kind == .foreground {
                load.foregroundWaiterCount += 1
            }
        }
        setToolsCatalogLoadState(load)
        syncDebug()
    }

    func attachWindowWaiters(
        route: ControlPlaneRoute,
        loadID: UUID,
        waiters: [(WaiterID, WindowWaiterRecord)]
    ) {
        guard var load = windowLoads[route], load.loadID == loadID else { return }
        for (waiterID, waiter) in waiters {
            if deadlineExceeded(waiter.deadlineUptimeNs) {
                waiter.continuation.resume(throwing: TimeoutError())
                continue
            }
            let timeoutTask = makeTimeoutTask(deadlineUptimeNs: waiter.deadlineUptimeNs) {
                await self.timeoutWindowWaiter(route: route, loadID: loadID, waiterID: waiterID)
            }
            load.waiters[waiterID] = WindowWaiterRecord(
                continuation: waiter.continuation,
                deadlineUptimeNs: waiter.deadlineUptimeNs,
                timeoutTask: timeoutTask
            )
        }
        windowLoads[route] = load
        syncDebug()
    }

    func currentPhase() -> Phase {
        if initializeLoad != nil {
            return .loadingInitialize
        }
        if toolsCatalogLoad != nil || prewarmToolsCatalogLoad != nil {
            return .loadingToolsCatalog
        }
        if windowLoads.isEmpty == false {
            return .listingWindows
        }
        return .idle
    }

    func currentWaiterCounts() -> ControlPlaneWaiterCounts {
        let initializeCount = initializeLoad?.waiters.count ?? 0
        let toolsCount =
            (toolsCatalogLoad?.foregroundWaiterCount ?? 0)
            + (prewarmToolsCatalogLoad?.foregroundWaiterCount ?? 0)
        let windowsCount = windowLoads.values.reduce(into: 0) { partial, load in
            partial += load.waiters.count
        }
        return ControlPlaneWaiterCounts(
            initialize: initializeCount,
            toolsCatalog: toolsCount,
            windows: windowsCount
        )
    }

    func currentInFlightRequestLabels() -> [String] {
        var requests: [String] = []
        if initializeLoad != nil {
            requests.append("initialize")
        }
        if toolsCatalogLoad != nil || prewarmToolsCatalogLoad != nil {
            requests.append("tools/list")
        }
        let routes = windowLoads.keys.sorted { $0.debugLabel < $1.debugLabel }
        requests.append(
            contentsOf: routes.map { route in
                "tools/call:XcodeListWindows@\(route.debugLabel)"
            }
        )
        return requests
    }

    func syncDebug() {
        let brokerSnapshot = brokerState.snapshot()
        let snapshot = ProxyControlPlaneDebugSnapshot(
            phase: currentPhase().rawValue,
            canonicalInitializeSourceUpstream: brokerSnapshot.initializeSourceUpstream,
            canonicalToolsSourceUpstream: brokerSnapshot.toolsSourceUpstream,
            canonicalReady: brokerSnapshot.canonicalReady,
            upstreamHandshakeStates: upstreamHandshakeStates(),
            waiterCounts: currentWaiterCounts(),
            inFlightControlPlaneRequests: currentInFlightRequestLabels(),
            lastIncompatibility: brokerSnapshot.lastIncompatibility
        )
        debugMirror.overwrite(snapshot)
    }
}
