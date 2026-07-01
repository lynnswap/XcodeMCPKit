import Foundation
import NIO
import XcodeMCPKit

extension RuntimeCoordinator {
    func triggerXcodeProcessReconcile(reason: String) {
        guard processRoutingEnabled, let xcodeTargetDiscovery else {
            return
        }
        addRuntimeTask { [weak self, xcodeTargetDiscovery] in
            guard let self else { return }
            self.reconcileXcodeProcessTargets(
                xcodeTargetDiscovery.runningXcodeTargets(),
                reason: reason
            )
        }
    }

    func startXcodeProcessReconciliationLoop() {
        guard processRoutingEnabled, let xcodeTargetDiscovery else {
            return
        }
        addRuntimeTask { [weak self, xcodeTargetDiscovery] in
            guard let self else { return }
            while !Task.isCancelled {
                let hasPendingProcessToolsCatalogRefresh =
                    self.pendingProcessToolsCatalogRefreshProcessIDs.withLockedValue {
                        $0.isEmpty == false
                    }
                let isRecovering =
                    self.activeInitializedHealthyishCount() == 0
                    || self.anyActiveRecoveryInFlight()
                    || hasPendingProcessToolsCatalogRefresh
                let interval: Duration = self.xcodeProcessRoutes.isEmpty
                    || isRecovering
                    ? .seconds(2)
                    : .seconds(30)
                await self.clock.sleep(interval)
                guard !Task.isCancelled else { return }
                self.reconcileXcodeProcessTargets(
                    xcodeTargetDiscovery.runningXcodeTargets(),
                    reason: "periodic_scan"
                )
            }
        }
    }

    func reconcileXcodeProcessTargets(
        _ targets: [XcodeProcessTarget],
        reason: String
    ) {
        guard processRoutingEnabled else { return }
        let result = xcodeProcessRegistry.reconcile(
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
            pendingProcessToolsCatalogRefreshProcessIDs.withLockedValue { processIDs in
                for route in result.addedRoutes {
                    processIDs.insert(route.target.processID)
                }
            }
            unavailableXcodeProcessRoutes.withLockedValue { unavailable in
                for route in result.addedRoutes {
                    unavailable.removeValue(forKey: route.target.processID)
                }
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
        }

        retryPendingProcessRouteReadiness(reason: reason)
        publishToolsListChangedNotification()
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
        _ = unavailableXcodeProcessRoutes.withLockedValue { state in
            state.removeValue(forKey: route.target.processID)
        }
        xcodeProcessEventMonitor.removeExitObserver(processID: route.target.processID)
        _ = pendingProcessToolsCatalogRefreshProcessIDs.withLockedValue {
            $0.remove(route.target.processID)
        }
        processToolCatalogRegistry.removeCatalog(forProcessID: route.target.processID)
        removeXcodeWindowOwners(forProcessID: route.target.processID)

        var resetInitialize = false
        for upstreamIndex in route.upstreamIndices {
            retireProcessBoundUpstream(
                upstreamIndex: upstreamIndex,
                reason: reason,
                resetInitialize: &resetInitialize
            )
        }

        resyncProcessToolsCatalogSurfaceAfterRemoving(
            upstreamIndex: route.primaryUpstreamIndex ?? -1,
            processID: route.target.processID
        )
        invalidateControlPlane(
            reason: "xcode_process_removed",
            clearInitialize: resetInitialize,
            clearToolsCatalog: true
        )
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

        if globalInit?.wasInFlight == true,
           retryPrimaryInitializeOnAlternativeUpstream(
               failedUpstreamIndex: upstreamIndex,
               failedUpstreamID: nil,
               reason: "xcode_process_removed_\(reason)"
           ) {
            return
        }
    }

    private func startInitializationForAddedProcessRoutes(_ routes: [XcodeProcessRoute]) {
        guard routes.contains(where: { $0.upstreamIndices.isEmpty == false }) else {
            return
        }
        if isInitialized() {
            for route in routes {
                for upstreamIndex in route.upstreamIndices {
                    startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
                }
            }
            return
        }
        startEagerInitializePrimary()
    }

    private func retryPendingProcessRouteReadiness(reason: String) {
        let activeRoutes = xcodeProcessRoutes
        let activeProcessIDs = Set(activeRoutes.map(\.target.processID))
        let pendingProcessIDs = pendingProcessToolsCatalogRefreshProcessIDs.withLockedValue {
            processIDs -> Set<pid_t> in
            processIDs = processIDs.filter { processID in
                activeProcessIDs.contains(processID)
                && processToolCatalogRegistry.catalog(forProcessID: processID) == nil
            }
            return processIDs
        }
        guard pendingProcessIDs.isEmpty == false else {
            return
        }

        for route in activeRoutes where pendingProcessIDs.contains(route.target.processID) {
            for upstreamIndex in route.upstreamIndices {
                startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
            }
        }
        refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "pending_process_route_\(reason)",
            processIDs: pendingProcessIDs
        )
    }

    func refreshPendingProcessToolsCatalogAfterWarmInitialize(upstreamIndex: Int) {
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex) else {
            return
        }
        let shouldRefresh = pendingProcessToolsCatalogRefreshProcessIDs.withLockedValue {
            $0.contains(route.target.processID)
        }
        guard shouldRefresh else {
            return
        }
        refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "warm_initialize_\(upstreamIndex)",
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
