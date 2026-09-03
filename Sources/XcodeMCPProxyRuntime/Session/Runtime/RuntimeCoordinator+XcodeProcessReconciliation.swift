import Foundation
import NIO
import XcodeMCPKit

extension RuntimeCoordinator {
    private struct ProcessRouteReconcileCommit: Sendable {
        let transition: ProcessControlPlaneTransition
        let healthEffects: [UpstreamHealthManager.Effect]
    }

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
        defer { testHooks.xcodeProcessReconcileCompleted?(reason) }
        var commit: ProcessRouteReconcileCommit?
        guard initializeManager.performIfRunning({
            let existingRoutes = processControlPlane.activeRoutes()
            let observedRoutes = MCPBridgeRuntime.orderedXcodeTargets(targets).map { target in
                existingRoutes.first(where: {
                    $0.target == target && $0.upstreamIndices.isEmpty == false
                })
                    ?? appendProcessBoundRouteWhileRunning(for: target)
            }
            let nowUptimeNs = nowUptimeNanoseconds()
            let usability = evaluateProcessRouteUpstreamUsability(
                policy: .toolsCatalog,
                nowUptimeNs: nowUptimeNs
            )
            commit = ProcessRouteReconcileCommit(
                transition: processControlPlane.reconcileRoutes(
                    observedRoutes,
                    reason: reason,
                    nowUptimeNs: nowUptimeNs,
                    usability: usability.snapshot
                ),
                healthEffects: usability.effects
            )
        }), let commit else {
            return
        }
        applyProcessControlPlaneTransition(commit.transition)
        applyHealthEffects(commit.healthEffects)
        guard commit.transition.didChangeRoutes else {
            retryPendingProcessRouteReadiness(reason: reason)
            return
        }

        for route in commit.transition.retiredRoutes {
            retireProcessBoundRoute(route, reason: reason)
        }

        if commit.transition.addedRoutes.isEmpty == false {
            startInitializationForAddedProcessRoutes(commit.transition.addedRoutes)
        }

        retryPendingProcessRouteReadiness(reason: reason)
    }

    private func appendProcessBoundRouteWhileRunning(
        for target: XcodeProcessTarget
    ) -> XcodeProcessRoute {
        let slots = dynamicUpstreamFactory?(target) ?? []
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

        let transition = commitUpstreamTopologyMutation {
            upstreamTopology.append(slots)
        }
        let upstreamIndices = transition.addedIDs.map(\.rawValue)
        for id in transition.addedIDs {
            guard let operationLease = transition.snapshot.operationLease(id) else { continue }
            observeUpstreamEvents(operationLease)
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
        removeXcodeWindowOwners(forProcessID: route.target.processID)

        let hadGlobalInitialize = isInitialized()
        for upstreamIndex in route.upstreamIndices {
            guard let operationLease = upstreamTopology.operationLease(
                for: UpstreamSlotID(rawValue: upstreamIndex)
            ) else { continue }
            retireProcessBoundUpstream(
                operationLease: operationLease,
                reason: reason
            )
        }
        testHooks.processRouteRetirementWillDetach?()
        let topologyTransition = commitUpstreamTopologyMutation {
            upstreamTopology.retire(
                Set(route.upstreamIndices.map(UpstreamSlotID.init(rawValue:)))
            )
        }
        for retired in topologyTransition.retired {
            retireUpstreamSlot(retired.slot)
        }

        let resetInitialize = hadGlobalInitialize
            && canonicalHandshakeState.initializeResult() == nil
            && canonicalHandshakeState.hasInitializeParticipants() == false
            && anyActiveRecoveryInFlight() == false
        if resetInitialize {
            initializeManager.resetWarmSecondaryForRetry()
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
        operationLease: UpstreamOperationLease,
        reason: String
    ) {
        let upstreamIndex = operationLease.upstreamIndex
        let globalInit = initializeManager.handleUpstreamExit(upstreamIndex: upstreamIndex)
        if globalInit?.primaryInitUpstreamIndex == upstreamIndex,
           let upstreamID = globalInit?.primaryInitUpstreamID {
            upstreamRouter.remove(proof: operationLease.proof, upstreamID: upstreamID)
        }

        clearUpstreamState(proof: operationLease.proof)
        upstreamRouter.reset(proof: operationLease.proof)
        releaseLeases(
            leaseManager.abandonActiveLeases(
                upstreamIndex: upstreamIndex,
                reason: .upstreamExit
            )
        )
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

        startEagerInitializePrimary(applyBackoff: true)
    }

    private func startInitializationForAddedProcessRoutes(_ routes: [XcodeProcessRoute]) {
        let routesWithUpstreams = routes.filter { $0.upstreamIndices.isEmpty == false }
        guard routesWithUpstreams.isEmpty == false else {
            return
        }
        startProcessRouteAttachments(routesWithUpstreams)
        for route in routesWithUpstreams {
            startProcessRouteActivation(for: route)
        }
    }

    func startProcessRouteAttachments(_ routes: [XcodeProcessRoute]) {
        // Route membership starts one bridge per Xcode independently. Each
        // route then owns its own protocol activation; only the compatible
        // canonical result publication is globally arbitrated.
        for route in routes {
            guard let upstreamIndex = route.primaryUpstreamIndex else { continue }
            runWhenUpstreamReady(
                reason: "xcode_process_attach_\(route.target.processID)"
            ) { [weak self, route, upstreamIndex] in
                guard let self,
                      self.unavailableXcodeProcessIDs().contains(
                          route.target.processID
                      ) == false,
                      self.xcodeProcessRoutes.contains(where: {
                          $0.id == route.id && $0.primaryUpstreamIndex == upstreamIndex
                      })
                else {
                    return
                }
                self.startUpstreamSlot(upstreamIndex)
            }
        }
    }

    func retryPendingProcessRouteReadiness(reason: String) {
        let activeRoutes = xcodeProcessRoutes
        let activeProcessIDs = Set(activeRoutes.map(\.target.processID))
        let unavailableProcessIDs = unavailableXcodeProcessIDs()
        let missingCatalogProcessIDs = Set(activeRoutes.compactMap { route -> pid_t? in
            guard unavailableProcessIDs.contains(route.target.processID) == false,
                  processControlPlane.catalog(forProcessID: route.target.processID) == nil
            else {
                return nil
            }
            return route.target.processID
        })
        let pendingProcessIDs = processControlPlane
            .pendingCatalogProcessIDs(nowUptimeNs: nowUptimeNanoseconds())
            .union(missingCatalogProcessIDs)
            .filter { processID in
                activeProcessIDs.contains(processID)
                    && unavailableProcessIDs.contains(processID) == false
                    && processControlPlane.catalog(forProcessID: processID) == nil
            }
        guard pendingProcessIDs.isEmpty == false else {
            return
        }

        for route in activeRoutes where pendingProcessIDs.contains(route.target.processID) {
            startProcessRouteActivation(for: route)
        }
        guard isInitialized() else { return }
        for route in activeRoutes where pendingProcessIDs.contains(route.target.processID) {
            var transition = ProcessControlPlaneTransition.none
            guard initializeManager.performIfRunning({
                transition = processControlPlane.beginBridgePoolRecovery(routeID: route.id)
            }) else { return }
            applyProcessControlPlaneTransition(transition)
        }
        refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "pending_process_route_\(reason)",
            processIDs: pendingProcessIDs
        )
    }

    func restoreProcessBridgePool(_ recovery: ProcessBridgePoolRecovery) {
        guard initializeManager.snapshot().isShuttingDown == false else { return }
        guard let route = xcodeProcessRoutes.first(where: { $0.id == recovery.routeID }) else {
            return
        }
        guard route.upstreamIndices.contains(recovery.upstreamID.rawValue),
              let proof = upstreamTopology.operationLease(for: recovery.upstreamID)?.proof,
              let health = upstreamHealthManager.state(for: recovery.upstreamID) else {
            scheduleProcessBridgeRecoveryRetry(
                recovery,
                reason: "slot_missing"
            )
            return
        }
        if health.initPhase.isUsableInitialized {
            applyProcessControlPlaneTransition(
                processControlPlane.completeBridgeRecovery(recovery)
            )
            return
        }
        guard
              health.isInitialized == false,
              health.initInFlight == false else {
            scheduleProcessBridgeRecoveryRetry(
                recovery,
                reason: "slot_not_ready"
            )
            return
        }
        let resolvedRecovery = ProcessBridgeRecovery(
            reservation: recovery,
            topologyProof: proof
        )
        logger.debug(
            "bridge_pool_recovery_started",
            metadata: [
                "pid": .string("\(route.target.processID)"),
                "upstream": .string("\(recovery.upstreamID.rawValue)"),
            ]
        )
        startUpstreamWarmInitialize(
            upstreamIndex: recovery.upstreamID.rawValue,
            applyBackoff: false,
            mode: .processBridgeRecovery(resolvedRecovery)
        )
    }

    func scheduleProcessBridgeRecoveryRetry(
        _ recovery: ProcessBridgePoolRecovery,
        reason: String
    ) {
        var retry: ProcessBridgeRecoveryRetry?
        guard initializeManager.performIfRunning({
            retry = processControlPlane.prepareBridgeRecoveryRetry(
                recovery,
                failure: reason == "attach_probe_timeout" ? .toolsListTimeout : .other
            )
        }), let retry else {
            return
        }
        schedulePreparedProcessBridgeRecoveryRetry(retry, reason: reason)
    }

    func schedulePreparedProcessBridgeRecoveryRetry(
        _ retry: ProcessBridgeRecoveryRetry,
        reason: String
    ) {
        logger.debug(
            "bridge_pool_recovery_retry_scheduled",
            metadata: [
                "pid": .string("\(retry.reservation.routeID.processID)"),
                "upstream": .string("\(retry.reservation.upstreamID.rawValue)"),
                "reason": .string(reason),
                "delay_ms": .string("\(retry.delay.nanoseconds / 1_000_000)"),
                "consecutive_failures": .string("\(retry.consecutiveFailureCount)"),
            ]
        )
        if retry.failure == .toolsListTimeout,
           processControlPlane.consumeToolsUnavailableWarningIfNeeded() {
            XcodeMCPToolsAvailabilityDiagnostic.logTimeout(
                logger: logger,
                processID: retry.reservation.routeID.processID,
                upstreamIndex: retry.reservation.upstreamID.rawValue,
                retryDelayMilliseconds: retry.delay.nanoseconds / 1_000_000
            )
        }
        let timeout = scheduleRuntimeTimeout(retry.delay) { [weak self] in
            guard let self else { return }
            self.applyProcessControlPlaneTransition(
                self.processControlPlane.handleBridgeRecoveryRetryFired(
                    retry.reservation
                )
            )
        }
        var transition = ProcessControlPlaneTransition.none
        guard initializeManager.performIfRunning({
            transition = processControlPlane.attachBridgeRecoveryRetryTimeout(
                timeout,
                to: retry.reservation
            )
        }) else {
            timeout.cancel()
            return
        }
        applyProcessControlPlaneTransition(transition)
    }

    func replaceProcessBridgeRecoveryChannelAndScheduleRetry(
        _ recovery: ProcessBridgeRecovery,
        reason: String
    ) {
        let replacement = replaceOrRetireInitializeChannel(
            recovery.topologyProof,
            expectedRouteID: recovery.routeID,
            requestsBridgePoolRecovery: false
        )
        var retry: ProcessBridgeRecoveryRetry?
        guard initializeManager.performIfRunning({
            retry = processControlPlane.prepareBridgeRecoveryRetry(
                recovery.reservation,
                failure: reason == "attach_probe_timeout" ? .toolsListTimeout : .other
            )
        }), let retry else { return }
        guard let replacement else {
            schedulePreparedProcessBridgeRecoveryRetry(retry, reason: reason)
            return
        }
        addRuntimeTask { [weak self, replacement] in
            guard let self,
                  await self.waitUntilUpstreamOperationActivatable(
                    replacement.operationLease
                  ),
                  self.initializeManager.snapshot().isShuttingDown == false
            else { return }
            self.schedulePreparedProcessBridgeRecoveryRetry(retry, reason: reason)
        }
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
        let shouldRefresh = processControlPlane.pendingCatalogProcessIDs(
            nowUptimeNs: nowUptimeNanoseconds()
        ).contains(route.target.processID)
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
        let targets = sessionRegistry.initializedNotificationTargets()
        for target in targets where deliveredSessionIDs.insert(target.id).inserted {
            target.router.handleIncoming(data)
        }
    }

}
