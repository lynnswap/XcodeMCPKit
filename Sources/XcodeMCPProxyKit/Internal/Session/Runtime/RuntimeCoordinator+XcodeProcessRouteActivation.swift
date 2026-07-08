import Foundation
import Logging
import NIO
import XcodeMCPKit

extension RuntimeCoordinator {
    func startProcessRouteActivation(for route: XcodeProcessRoute) {
        guard unavailableXcodeProcessIDs().contains(route.target.processID) == false else {
            return
        }
        guard let upstreamIndex = route.primaryUpstreamIndex else {
            abandonProcessRouteActivation(
                processID: route.target.processID,
                reason: "missing_upstream"
            )
            return
        }
        xcodeProcessRouteActivationTracker.prepare(processID: route.target.processID)
        startUpstreamWarmInitialize(
            upstreamIndex: upstreamIndex,
            mode: .processRouteActivation(processID: route.target.processID)
        )
        guard isInitialized() else {
            return
        }
        for secondaryUpstreamIndex in route.upstreamIndices where secondaryUpstreamIndex != upstreamIndex {
            startUpstreamWarmInitialize(upstreamIndex: secondaryUpstreamIndex)
        }
    }

    func processRouteActivationOwnsPrimaryInitialize(upstreamIndex: Int) -> Bool {
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex),
              route.primaryUpstreamIndex == upstreamIndex
        else {
            return false
        }
        switch xcodeProcessRouteActivationTracker.phase(processID: route.target.processID) {
        case .pending, .attaching, .initialized:
            return true
        case .cataloged, .abandoned, nil:
            return false
        }
    }

    func beginProcessRouteActivationIfNeeded(
        mode: WarmInitializeMode,
        upstreamIndex: Int
    ) -> XcodeProcessRouteActivationTracker.Start? {
        guard case .processRouteActivation(let processID) = mode else {
            return nil
        }
        let now = nowUptimeNanoseconds()
        guard let start = xcodeProcessRouteActivationTracker.beginAttaching(
            processID: processID,
            upstreamIndex: upstreamIndex,
            nowUptimeNs: now
        ) else {
            return nil
        }
        let timeoutMs = upstreamInitTimeoutAmount(for: mode).map {
            $0.nanoseconds / 1_000_000
        }
        logger.info(
            "route_activation_started",
            metadata: [
                "pid": .string("\(processID)"),
                "upstream": .string("\(upstreamIndex)"),
                "attempt": .string("\(start.attempt)"),
                "timeout_ms": .string(timeoutMs.map(String.init) ?? "disabled"),
            ]
        )
        testHooks.processRouteActivationEvent?(processID, upstreamIndex, "started")
        return start
    }

    func handleProcessRouteActivationTimeout(
        processID: pid_t,
        upstreamIndex: Int,
        upstreamID: Int64,
        attempt: Int?
    ) {
        guard let attempt,
              let retry = xcodeProcessRouteActivationTracker.handleTimeout(
                  processID: processID,
                  upstreamIndex: upstreamIndex,
                  attempt: attempt
              )
        else {
            return
        }

        logger.info(
            "route_activation_timeout",
            metadata: [
                "pid": .string("\(processID)"),
                "upstream": .string("\(upstreamIndex)"),
                "attempt": .string("\(attempt)"),
            ]
        )
        testHooks.processRouteActivationEvent?(processID, upstreamIndex, "timeout")

        guard clearUpstreamState(upstreamIndex: upstreamIndex, expectedUpstreamID: upstreamID) else {
            resetProcessRouteActivation(
                processID: processID,
                reason: "stale_activation_timeout"
            )
            return
        }
        guard replaceProcessBoundUpstreamSlot(processID: processID, upstreamIndex: upstreamIndex) else {
            return
        }
        scheduleProcessRouteActivationRetry(
            processID: processID,
            retry: retry,
            reason: "timeout"
        )
    }

    func markProcessRouteActivationInitialized(upstreamIndex: Int) {
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex) else {
            return
        }
        let processID = route.target.processID
        guard let initialized = xcodeProcessRouteActivationTracker.markInitialized(
            processID: processID,
            upstreamIndex: upstreamIndex,
            nowUptimeNs: nowUptimeNanoseconds()
        ) else {
            return
        }
        logger.info(
            "route_activation_initialized",
            metadata: [
                "pid": .string("\(processID)"),
                "upstream": .string("\(upstreamIndex)"),
            ]
        )
        testHooks.processRouteActivationEvent?(processID, upstreamIndex, "initialized")
        if let existingCatalog = processToolCatalogRegistry.catalog(forProcessID: processID),
           markProcessRouteActivationCataloged(
               target: route.target,
               upstreamIndex: existingCatalog.upstreamIndex,
               activationUpstreamIndex: upstreamIndex,
               attempt: initialized.attempt
           ) {
            return
        }
        scheduleProcessRouteActivationCatalogTimeout(
            processID: processID,
            upstreamIndex: upstreamIndex,
            attempt: initialized.attempt
        )
    }

    func markProcessRouteActivationCataloged(
        target: XcodeProcessTarget,
        upstreamIndex: Int,
        activationUpstreamIndex: Int? = nil,
        attempt: Int? = nil
    ) -> Bool {
        let now = nowUptimeNanoseconds()
        guard let cataloged = xcodeProcessRouteActivationTracker.markCataloged(
            processID: target.processID,
            upstreamIndex: activationUpstreamIndex ?? upstreamIndex,
            catalogedUpstreamIndex: upstreamIndex,
            attempt: attempt,
            nowUptimeNs: now
        ) else {
            return false
        }
        markXcodeProcessRouteCatalogAvailable(upstreamIndex: upstreamIndex)
        logger.info(
            "route_activation_cataloged",
            metadata: [
                "pid": .string("\(target.processID)"),
                "upstream": .string("\(upstreamIndex)"),
                "duration_ms": .string(
                    "\(cataloged / 1_000_000)"
                ),
            ]
        )
        testHooks.processRouteActivationEvent?(target.processID, upstreamIndex, "cataloged")
        return true
    }

    func processRouteActivationCatalogAttempt(
        processID: pid_t,
        upstreamIndex: Int
    ) -> Int? {
        xcodeProcessRouteActivationTracker.catalogAttempt(
            processID: processID,
            upstreamIndex: upstreamIndex
        )
    }

    func refreshProcessRouteActivationCatalogWaitAfterEmptyCatalog(
        processID: pid_t,
        upstreamIndex: Int,
        attempt: Int
    ) {
        guard xcodeProcessRouteActivationTracker.finishCatalogWaitWithoutCatalog(
            processID: processID,
            upstreamIndex: upstreamIndex,
            attempt: attempt
        ) else {
            return
        }
        scheduleProcessRouteActivationCatalogTimeout(
            processID: processID,
            upstreamIndex: upstreamIndex,
            attempt: attempt
        )
    }

    func abandonProcessRouteActivation(processID: pid_t, reason: String) {
        xcodeProcessRouteActivationTracker.abandon(processID: processID, reason: reason)
        logger.info(
            "route_activation_abandoned",
            metadata: [
                "pid": .string("\(processID)"),
                "reason": .string(reason),
            ]
        )
        testHooks.processRouteActivationEvent?(processID, nil, "abandoned")
    }

    func resetProcessRouteActivation(processID: pid_t, reason: String) {
        guard xcodeProcessRouteActivationTracker.reset(processID: processID) else {
            return
        }
        logger.info(
            "route_activation_abandoned",
            metadata: [
                "pid": .string("\(processID)"),
                "reason": .string(reason),
            ]
        )
        testHooks.processRouteActivationEvent?(processID, nil, "abandoned")
    }

    func resetProcessRouteActivationIfClearingPreCatalogUpstream(upstreamIndex: Int) {
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex),
              processToolCatalogRegistry.catalog(forProcessID: route.target.processID) == nil
        else {
            return
        }
        switch xcodeProcessRouteActivationTracker.phase(processID: route.target.processID) {
        case .attaching(let activationUpstreamIndex, _, _)
            where activationUpstreamIndex == upstreamIndex:
            resetProcessRouteActivation(
                processID: route.target.processID,
                reason: "upstream_cleared_before_catalog"
            )
        case .initialized(let activationUpstreamIndex, _, _)
            where activationUpstreamIndex == upstreamIndex:
            resetProcessRouteActivation(
                processID: route.target.processID,
                reason: "upstream_cleared_before_catalog"
            )
        case .pending, .cataloged, .abandoned, .attaching, .initialized, nil:
            return
        }
    }

    func clearsInitializedProcessRouteActivationBeforeCatalog(upstreamIndex: Int) -> Bool {
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex),
              processToolCatalogRegistry.catalog(forProcessID: route.target.processID) == nil
        else {
            return false
        }
        guard case .initialized(let activationUpstreamIndex, _, _) =
            xcodeProcessRouteActivationTracker.phase(processID: route.target.processID)
        else {
            return false
        }
        return activationUpstreamIndex == upstreamIndex
    }

    func resetAllProcessRouteActivations(reason: String) {
        for processID in xcodeProcessRouteActivationTracker.resetAll() {
            logger.info(
                "route_activation_abandoned",
                metadata: [
                    "pid": .string("\(processID)"),
                    "reason": .string(reason),
                ]
            )
            testHooks.processRouteActivationEvent?(processID, nil, "abandoned")
        }
    }

    private func scheduleProcessRouteActivationRetry(
        processID: pid_t,
        retry: XcodeProcessRouteActivationTracker.Retry,
        reason: String
    ) {
        logger.info(
            "route_activation_retry_scheduled",
            metadata: [
                "pid": .string("\(processID)"),
                "delay_ms": .string("\(retry.delayMilliseconds)"),
                "attempt": .string("\(retry.attempt)"),
                "reason": .string(reason),
            ]
        )
        testHooks.processRouteActivationEvent?(processID, nil, "retry_scheduled")
        let timeout = scheduleRuntimeTimeout(retry.delay) { [weak self] in
            guard let self else { return }
            guard self.xcodeProcessRouteActivationTracker.handleRetryFired(
                processID: processID
            ) else {
                return
            }
            guard let route = self.xcodeProcessRoutes.first(where: {
                $0.target.processID == processID
            }) else {
                self.abandonProcessRouteActivation(
                    processID: processID,
                    reason: "retry_route_missing"
                )
                return
            }
            self.startProcessRouteActivation(for: route)
        }
        xcodeProcessRouteActivationTracker.storeRetry(
            processID: processID,
            timeout: timeout
        )
    }

    private func scheduleProcessRouteActivationCatalogTimeout(
        processID: pid_t,
        upstreamIndex: Int,
        attempt: Int
    ) {
        guard let timeoutAmount = processRouteActivationCatalogTimeoutAmount() else {
            return
        }
        let timeout = scheduleRuntimeTimeout(timeoutAmount) { [weak self] in
            self?.handleProcessRouteActivationCatalogTimeout(
                processID: processID,
                upstreamIndex: upstreamIndex,
                attempt: attempt
            )
        }
        xcodeProcessRouteActivationTracker.storeCatalogTimeout(
            processID: processID,
            upstreamIndex: upstreamIndex,
            attempt: attempt,
            timeout: timeout
        )
    }

    private func processRouteActivationCatalogTimeoutAmount() -> TimeAmount? {
        MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: config.requestTimeout)
    }

    private func handleProcessRouteActivationCatalogTimeout(
        processID: pid_t,
        upstreamIndex: Int,
        attempt: Int
    ) {
        guard let timeout = xcodeProcessRouteActivationTracker.handleCatalogTimeout(
            processID: processID,
            upstreamIndex: upstreamIndex,
            attempt: attempt
        ) else {
            return
        }
        timeout.rpcHandles.forEach { $0.cancel() }

        logger.info(
            "route_activation_timeout",
            metadata: [
                "pid": .string("\(processID)"),
                "upstream": .string("\(upstreamIndex)"),
                "attempt": .string("\(attempt)"),
                "phase": .string("catalog"),
                "retry_delay_ms": .string("\(timeout.retry.delayMilliseconds)"),
            ]
        )
        testHooks.processRouteActivationEvent?(processID, upstreamIndex, "timeout")

        clearUpstreamState(upstreamIndex: upstreamIndex)
        guard replaceProcessBoundUpstreamSlot(processID: processID, upstreamIndex: upstreamIndex) else {
            return
        }
        scheduleProcessRouteActivationRetry(
            processID: processID,
            retry: timeout.retry,
            reason: "catalog_timeout"
        )
    }

    @discardableResult
    private func replaceProcessBoundUpstreamSlot(
        processID: pid_t,
        upstreamIndex: Int
    ) -> Bool {
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex),
              route.target.processID == processID
        else {
            abandonProcessRouteActivation(
                processID: processID,
                reason: "replacement_route_unavailable"
            )
            return false
        }
        let replacements = dynamicUpstreamFactory?(route.target) ?? []
        guard let replacement = replacements.first else {
            abandonProcessRouteActivation(
                processID: processID,
                reason: "replacement_unavailable"
            )
            return false
        }

        let previous = upstreamsBox.withLockedValue { upstreams -> (any UpstreamSlotControlling)? in
            guard upstreamIndex >= 0, upstreamIndex < upstreams.count else {
                return nil
            }
            let previous = upstreams[upstreamIndex]
            upstreams[upstreamIndex] = replacement
            return previous
        }
        guard let previous else {
            for unusedReplacement in replacements {
                addRuntimeTask {
                    await unusedReplacement.stop()
                }
            }
            abandonProcessRouteActivation(
                processID: processID,
                reason: "replacement_slot_unavailable"
            )
            return false
        }
        observeUpstreamEvents(replacement, upstreamIndex: upstreamIndex)
        addRuntimeTask {
            await previous.stop()
        }
        for unusedReplacement in replacements.dropFirst() {
            addRuntimeTask {
                await unusedReplacement.stop()
            }
        }
        return true
    }
}
