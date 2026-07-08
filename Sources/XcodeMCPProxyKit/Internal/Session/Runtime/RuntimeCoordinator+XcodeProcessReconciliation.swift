import Foundation
import NIO
import XcodeMCPKit

extension RuntimeCoordinator {
    func triggerXcodeProcessReconcile(reason: String) {
        guard processRoutingEnabled, let xcodeTargetDiscovery else {
            return
        }
        xcodeProcessReconcileScheduleState.withLockedValue { state in
            state.pendingReasons.append(reason)
        }
        startScheduledXcodeProcessReconcileWorkerIfNeeded(discovery: xcodeTargetDiscovery)
    }

    private func startScheduledXcodeProcessReconcileWorkerIfNeeded(
        discovery: any XcodeTargetDiscovering
    ) {
        let shouldStartWorker = xcodeProcessReconcileScheduleState.withLockedValue { state in
            guard state.workerRunning == false, state.pendingReasons.isEmpty == false else {
                return false
            }
            state.workerRunning = true
            return true
        }
        guard shouldStartWorker else { return }
        let accepted = addRuntimeTask { [weak self, discovery] in
            guard let self else { return }
            self.runScheduledXcodeProcessReconciles(discovery: discovery)
        }
        guard accepted == false else {
            return
        }
        xcodeProcessReconcileScheduleState.withLockedValue { state in
            state.workerRunning = false
            state.pendingReasons.removeAll()
        }
    }

    func startXcodeProcessReconciliationLoop() {
        guard processRoutingEnabled, xcodeTargetDiscovery != nil else {
            return
        }
        let generation = xcodeProcessReconciliationLoopState.withLockedValue { state -> UInt64? in
            guard state.isRunning == false else {
                return nil
            }
            state.generation &+= 1
            state.isRunning = true
            return state.generation
        }
        guard let generation else { return }
        let accepted = addRuntimeTask { [weak self, generation] in
            guard let self else { return }
            await self.runXcodeProcessReconciliationLoop(generation: generation)
        }
        if accepted == false {
            finishXcodeProcessReconciliationLoop(generation: generation)
        }
    }

    func restartXcodeProcessReconciliationLoopAfterRuntimeTaskReset() {
        guard processRoutingEnabled else {
            return
        }
        invalidateXcodeProcessReconciliationLoop()
        startXcodeProcessReconciliationLoop()
    }

    private func runXcodeProcessReconciliationLoop(generation: UInt64) async {
        defer {
            finishXcodeProcessReconciliationLoop(generation: generation)
        }
        while !Task.isCancelled, isCurrentXcodeProcessReconciliationLoop(generation: generation) {
            let hasPendingProcessToolsCatalogRefresh =
                processRouteReadinessStore.pendingCatalogRefreshIsEmpty() == false
            let isRecovering =
                activeInitializedHealthyishCount() == 0
                || anyActiveRecoveryInFlight()
                || hasPendingProcessToolsCatalogRefresh
            let interval: Duration = xcodeProcessRoutes.isEmpty
                || isRecovering
                ? .seconds(2)
                : .seconds(30)
            await clock.sleep(interval)
            guard !Task.isCancelled,
                  isCurrentXcodeProcessReconciliationLoop(generation: generation)
            else {
                return
            }
            triggerXcodeProcessReconcile(reason: "periodic_scan")
        }
    }

    private func invalidateXcodeProcessReconciliationLoop() {
        xcodeProcessReconciliationLoopState.withLockedValue { state in
            state.generation &+= 1
            state.isRunning = false
        }
    }

    private func isCurrentXcodeProcessReconciliationLoop(generation: UInt64) -> Bool {
        xcodeProcessReconciliationLoopState.withLockedValue { state in
            state.isRunning && state.generation == generation
        }
    }

    private func finishXcodeProcessReconciliationLoop(generation: UInt64) {
        xcodeProcessReconciliationLoopState.withLockedValue { state in
            guard state.generation == generation else {
                return
            }
            state.isRunning = false
        }
    }

    private func runScheduledXcodeProcessReconciles(
        discovery: any XcodeTargetDiscovering
    ) {
        defer {
            finishScheduledXcodeProcessReconcileWorker(discovery: discovery)
        }
        while !Task.isCancelled {
            guard let reason = dequeueScheduledXcodeProcessReconcileReason() else {
                return
            }
            let targets = discovery.runningXcodeTargets()
            guard !Task.isCancelled else {
                return
            }
            reconcileXcodeProcessTargets(
                targets,
                reason: reason
            )
        }
    }

    private func dequeueScheduledXcodeProcessReconcileReason() -> String? {
        xcodeProcessReconcileScheduleState.withLockedValue { state in
            guard state.pendingReasons.isEmpty == false else {
                return nil
            }
            let reasons = state.pendingReasons
            state.pendingReasons.removeAll()
            return reasons.joined(separator: ",")
        }
    }

    private func finishScheduledXcodeProcessReconcileWorker(
        discovery: any XcodeTargetDiscovering
    ) {
        xcodeProcessReconcileScheduleState.withLockedValue { state in
            state.workerRunning = false
        }
        startScheduledXcodeProcessReconcileWorkerIfNeeded(discovery: discovery)
    }

    func reconcileXcodeProcessTargets(
        _ targets: [XcodeProcessTarget],
        reason: String
    ) {
        guard processRoutingEnabled else { return }
        let result = processRouteStore.reconcile(
            targets: targets,
            reason: reason,
            nowUptimeNs: nowUptimeNanoseconds(),
            makeRoute: { target in
                self.appendProcessBoundRoute(for: target)
            }
        )
        guard result.didChange else {
            retryPendingProcessRouteReadiness(reason: reason)
            return
        }

        for route in result.retiredRoutes {
            retireProcessBoundRoute(route, reason: reason)
        }

        if result.addedRoutes.isEmpty == false {
            for route in result.addedRoutes {
                processRouteReadinessStore.insertPendingCatalogRefresh(
                    processID: route.target.processID
                )
            }
            for route in result.addedRoutes {
                processRouteStore.removeUnavailableState(processID: route.target.processID)
            }
            for route in result.addedRoutes {
                observeXcodeProcessExit(route.target.processID)
            }
            invalidateControlPlane(
                reason: "xcode_process_added",
                clearInitialize: false,
                clearToolsCatalog: true
            )
            startInitializationForAddedProcessRoutes(result.addedRoutes)
            publishToolsListChangedNotification()
        }

        retryPendingProcessRouteReadiness(reason: reason)
    }

    private func appendProcessBoundRoute(
        for target: XcodeProcessTarget
    ) -> XcodeProcessRoute {
        let slots = dynamicUpstreamFactory?(target) ?? []
        let startIndex = upstreamsBox.withLockedValue { upstreams -> Int in
            let startIndex = upstreams.count
            upstreams.append(contentsOf: slots)
            return startIndex
        }
        guard slots.isEmpty == false else {
            logger.warning(
                "Discovered Xcode process without a dynamic upstream factory",
                metadata: [
                    "pid": .string("\(target.processID)"),
                    "app_path": .string(target.appPath),
                ]
            )
            return XcodeProcessRoute(target: target, upstreamIndices: [])
        }

        upstreamRouter.appendUpstreams(count: slots.count)
        upstreamHealthManager.appendUpstreams(count: slots.count)
        debugRecorder.appendUpstreams(count: slots.count)

        let upstreamIndices = Array(startIndex..<(startIndex + slots.count))
        for (offset, upstream) in slots.enumerated() {
            observeUpstreamEvents(upstream, upstreamIndex: startIndex + offset)
        }
        logger.info(
            "Added Xcode process route",
            metadata: [
                "pid": .string("\(target.processID)"),
                "app_path": .string(target.appPath),
                "xcode_version": .string(target.xcodeVersion),
                "upstreams": .string(upstreamIndices.map(String.init).joined(separator: ",")),
            ]
        )
        return XcodeProcessRoute(target: target, upstreamIndices: upstreamIndices)
    }

    private func retireProcessBoundRoute(
        _ route: XcodeProcessRoute,
        reason: String
    ) {
        processRouteStore.removeUnavailableState(processID: route.target.processID)
        xcodeProcessEventMonitor.removeExitObserver(processID: route.target.processID)
        processRouteReadinessStore.removePendingCatalogRefresh(processID: route.target.processID)
        cancelScheduledProcessToolsCatalogRetry(processID: route.target.processID)
        removeXcodeWindowOwners(forProcessID: route.target.processID)
        resetProcessRouteActivation(
            processID: route.target.processID,
            reason: "route_retired_\(reason)"
        )

        let removalUpdate = applyToolCatalogSurfaceMutation {
            processToolSurfaceStore.removeProcess(
                processID: route.target.processID,
                exposedProcessIDs: processToolCatalogExposedProcessIDs()
            )
        }
        if removalUpdate?.isNoChange == true {
            applyToolCatalogSurfaceMutation {
                processToolSurfaceStore.recomputeSurface(
                    exposedProcessIDs: processToolCatalogExposedProcessIDs(),
                    publishesToolsListChanged: true
                )
            }
        }

        var resetInitialize = false
        for upstreamIndex in route.upstreamIndices {
            retireProcessBoundUpstream(
                upstreamIndex: upstreamIndex,
                reason: reason,
                resetInitialize: &resetInitialize
            )
        }

        invalidateControlPlane(
            reason: "xcode_process_removed",
            clearInitialize: resetInitialize,
            clearToolsCatalog: false
        )
        if resetInitialize {
            restartPrimaryInitializeAfterRetiringCachedProcessRoute()
        }
        failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
        logger.info(
            "Retired Xcode process route",
            metadata: [
                "pid": .string("\(route.target.processID)"),
                "app_path": .string(route.target.appPath),
                "xcode_version": .string(route.target.xcodeVersion),
                "reason": .string(reason),
            ]
        )
    }

    private func retireProcessBoundUpstream(
        upstreamIndex: Int,
        reason: String,
        resetInitialize: inout Bool
    ) {
        let globalInit = initializeManager.handleUpstreamExit(upstreamIndex: upstreamIndex)
        if globalInit?.primaryInitUpstreamIndex == upstreamIndex,
           let upstreamID = globalInit?.primaryInitUpstreamID {
            upstreamRouter.remove(upstreamIndex: upstreamIndex, upstreamID: upstreamID)
        }

        clearUpstreamState(upstreamIndex: upstreamIndex)
        upstreamRouter.reset(upstreamIndex: upstreamIndex)
        releaseLeases(
            leaseManager.abandonActiveLeases(
                upstreamIndex: upstreamIndex,
                reason: .upstreamExit
            )
        )
        let upstreamToStop = upstreamsBox.withLockedValue { upstreams in
            upstreamIndex >= 0 && upstreamIndex < upstreams.count ? upstreams[upstreamIndex] : nil
        }
        if let upstreamToStop {
            addRuntimeTask {
                await upstreamToStop.stop()
            }
        }

        if globalInit?.hadGlobalInit == true, anyActiveInitializedUpstream() == false {
            resetInitialize = true
            initializeManager.resetWarmSecondaryForRetry()
        }

        let retiredPrimaryInitialize =
            globalInit?.wasInFlight == true
            && globalInit?.primaryInitUpstreamIndex == upstreamIndex
        if retiredPrimaryInitialize,
           retryPrimaryInitializeOnAlternativeUpstream(
               failedUpstreamIndex: upstreamIndex,
               failedUpstreamID: nil,
               reason: "xcode_process_removed_\(reason)"
           ) {
            return
        }
    }

    private func restartPrimaryInitializeAfterRetiringCachedProcessRoute() {
        guard processRoutingEnabled, isInitialized() == false else {
            return
        }
        guard initializeManager.snapshot().initInFlight == false else {
            return
        }

        clearActiveWarmInitializesBeforePrimaryRestart()
        startEagerInitializePrimary(applyBackoff: true)
    }

    private func clearActiveWarmInitializesBeforePrimaryRestart() {
        let activePrimaryUpstreamIndex = initializeManager.activePrimaryInitializeUpstreamIndex()
        let states = upstreamHealthManager.statesSnapshot()
        for upstreamIndex in activeProcessBoundUpstreamIndices().sorted() {
            guard upstreamIndex != activePrimaryUpstreamIndex,
                  upstreamIndex >= 0,
                  upstreamIndex < states.count else {
                continue
            }
            let state = states[upstreamIndex]
            guard state.initInFlight, state.isInitialized == false else {
                continue
            }
            clearUpstreamState(upstreamIndex: upstreamIndex)
        }
    }

    private func startInitializationForAddedProcessRoutes(_ routes: [XcodeProcessRoute]) {
        let routesWithUpstreams = routes.filter { $0.upstreamIndices.isEmpty == false }
        guard routesWithUpstreams.isEmpty == false else {
            return
        }
        guard isInitialized() else {
            startProcessRouteActivation(for: routesWithUpstreams[0])
            return
        }
        for route in routesWithUpstreams {
            startProcessRouteActivation(for: route)
        }
    }

    private func retryPendingProcessRouteReadiness(reason: String) {
        let activeRoutes = xcodeProcessRoutes
        let activeProcessIDs = Set(activeRoutes.map(\.target.processID))
        let unavailableProcessIDs = unavailableXcodeProcessIDs()
        let missingCatalogProcessIDs = Set(activeRoutes.compactMap { route -> pid_t? in
            guard unavailableProcessIDs.contains(route.target.processID) == false,
                  processToolSurfaceStore.catalog(forProcessID: route.target.processID) == nil
            else {
                return nil
            }
            return route.target.processID
        })
        let pendingProcessIDs = processRouteReadinessStore
            .pendingCatalogRefreshProcessIDsSnapshot()
            .union(missingCatalogProcessIDs)
            .filter { processID in
                activeProcessIDs.contains(processID)
                    && unavailableProcessIDs.contains(processID) == false
                    && processToolSurfaceStore.catalog(forProcessID: processID) == nil
            }
        processRouteReadinessStore.replacePendingCatalogRefreshes(pendingProcessIDs)
        guard pendingProcessIDs.isEmpty == false else {
            return
        }

        guard isInitialized() else {
            guard initializeManager.snapshot().initInFlight == false else {
                return
            }
            if let route = activeRoutes.first(where: {
                pendingProcessIDs.contains($0.target.processID)
            }) {
                startProcessRouteActivation(for: route)
            }
            return
        }

        for route in activeRoutes where pendingProcessIDs.contains(route.target.processID) {
            startProcessRouteActivation(for: route)
        }
        refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "pending_process_route_\(reason)",
            processIDs: pendingProcessIDs
        )
    }

    func refreshPendingProcessToolsCatalogAfterWarmInitialize(upstreamIndex: Int) {
        refreshPendingProcessToolsCatalogForReadyUpstream(
            upstreamIndex: upstreamIndex,
            reason: "warm_initialize_\(upstreamIndex)"
        )
    }

    func refreshPendingProcessToolsCatalogForReadyUpstream(upstreamIndex: Int, reason: String) {
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex) else {
            return
        }
        let shouldRefresh = processRouteReadinessStore.hasPendingCatalogRefresh(
            processID: route.target.processID
        )
        guard shouldRefresh else {
            return
        }
        refreshMissingProcessToolsCatalogsIfNeeded(
            reason: reason,
            processIDs: [route.target.processID]
        )
    }

    func publishToolsListChangedNotification() {
        let notification = JSONRPC.Wire.notificationObject(
            method: "notifications/tools/list_changed"
        )
        guard let data = try? JSONRPC.Wire.data(from: notification) else {
            return
        }

        var deliveredSessionIDs = Set<String>()
        let targets = sessionRegistry.activeNotificationTargets()
            + sessionRegistry.pendingNotificationClientTargets()
        for target in targets where deliveredSessionIDs.insert(target.id).inserted {
            target.router.handleIncoming(data)
        }
    }

    private func observeXcodeProcessExit(_ processID: pid_t) {
        xcodeProcessEventMonitor.observeExit(processID: processID) { [weak self] reason in
            self?.triggerXcodeProcessReconcile(reason: reason)
        }
    }
}
