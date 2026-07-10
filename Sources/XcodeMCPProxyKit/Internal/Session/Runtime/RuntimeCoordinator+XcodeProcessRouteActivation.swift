import Foundation
import Logging
import NIO
import XcodeMCPKit

extension RuntimeCoordinator {
    func applyCatalogCommit(_ commit: CatalogCommit) {
        switch commit {
        case .accepted(_, let transition), .discarded(_, let transition):
            applyProcessControlPlaneTransition(transition)
        }
    }

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
        switch processControlPlane.attemptSnapshot(processID: route.target.processID)?.phase {
        case .pending, .attaching, .initialized, .loadingCatalog, .backoff:
            return true
        case .cataloged, .abandoned, nil:
            return false
        }
    }

    func beginProcessRouteActivationIfNeeded(
        mode: WarmInitializeMode,
        upstreamIndex: Int
    ) -> ProcessControlPlaneAuthority.ActivationStart? {
        guard case .processRouteActivation(let processID) = mode else {
            return nil
        }
        guard let route = processControlPlane.route(forProcessID: processID) else {
            return nil
        }
        let now = nowUptimeNanoseconds()
        guard let (start, transition) = processControlPlane.beginAttaching(
            routeID: route.id,
            upstreamIndex: upstreamIndex,
            nowUptimeNs: now
        ) else {
            return nil
        }
        applyProcessControlPlaneTransition(transition)
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
        return start
    }

    func handleProcessRouteActivationTimeout(
        processID: pid_t,
        upstreamIndex: Int,
        upstreamID: Int64,
        attempt: Int?
    ) {
        guard let attempt,
              let timeout = processControlPlane.handleActivationTimeout(
                  processID: processID,
                  upstreamIndex: upstreamIndex,
                  attemptID: attempt
              )
        else {
            return
        }

        applyProcessControlPlaneTransition(timeout.transition)
        logger.info(
            "route_activation_timeout",
            metadata: [
                "pid": .string("\(processID)"),
                "upstream": .string("\(upstreamIndex)"),
                "attempt": .string("\(attempt)"),
            ]
        )

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
            retry: timeout.retry,
            reason: "timeout"
        )
    }

    func markProcessRouteActivationInitialized(upstreamIndex: Int) {
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex) else {
            return
        }
        let processID = route.target.processID
        guard let initialized = processControlPlane.markInitialized(
            routeID: route.id,
            upstreamIndex: upstreamIndex
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
        if let existingCatalog = processControlPlane.catalog(forProcessID: processID) {
            applyCatalogCommit(processControlPlane.completeCatalog(
                .usable(existingCatalog.rawResult, source: existingCatalog.upstreamID),
                lease: initialized.lease,
                nowUptimeNanoseconds: nowUptimeNanoseconds()
            ))
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
        guard let lease = processControlPlane.currentCatalogLease(
            processID: target.processID,
            upstreamIndex: activationUpstreamIndex ?? upstreamIndex
        ), let catalog = processControlPlane.catalog(forProcessID: target.processID) else {
            return false
        }
        guard case .accepted(_, let transition) = processControlPlane.completeCatalog(
            .usable(catalog.rawResult, source: catalog.upstreamID),
            lease: lease,
            nowUptimeNanoseconds: nowUptimeNanoseconds()
        ) else { return false }
        applyProcessControlPlaneTransition(transition)
        markXcodeProcessRouteCatalogAvailable(upstreamIndex: upstreamIndex)
        logger.info(
            "route_activation_cataloged",
            metadata: [
                "pid": .string("\(target.processID)"),
                "upstream": .string("\(upstreamIndex)"),
                "duration_ms": .string(
                    "0"
                ),
            ]
        )
        return true
    }

    func processRouteActivationCatalogAttempt(
        processID: pid_t,
        upstreamIndex: Int
    ) -> Int? {
        guard let attempt = processControlPlane.attemptSnapshot(processID: processID),
              attempt.upstreamID.rawValue == upstreamIndex,
              [.attaching, .initialized, .loadingCatalog].contains(attempt.phase) else {
            return nil
        }
        return attempt.attemptID.rawValue
    }

    func finishProcessRouteActivationCatalogRequestAfterEmptyCatalog(
        processID: pid_t,
        upstreamIndex: Int,
        attempt: Int
    ) {
        guard processControlPlane.attemptSnapshot(processID: processID)?.attemptID.rawValue == attempt,
              let lease = processControlPlane.currentCatalogLease(
            processID: processID,
            upstreamIndex: upstreamIndex
        ) else { return }
        applyCatalogCommit(processControlPlane.completeCatalog(
            .unusable,
            lease: lease,
            nowUptimeNanoseconds: nowUptimeNanoseconds()
        ))
    }

    func abandonProcessRouteActivation(processID: pid_t, reason: String) {
        applyProcessControlPlaneTransition(processControlPlane.abandon(processID: processID))
        logger.info(
            "route_activation_abandoned",
            metadata: [
                "pid": .string("\(processID)"),
                "reason": .string(reason),
            ]
        )
    }

    func resetProcessRouteActivation(processID: pid_t, reason: String) {
        let transition = processControlPlane.resetAttempt(processID: processID)
        guard transition.effects.isEmpty == false else { return }
        applyProcessControlPlaneTransition(transition)
        logger.info(
            "route_activation_abandoned",
            metadata: [
                "pid": .string("\(processID)"),
                "reason": .string(reason),
            ]
        )
    }

    func resetProcessRouteActivationIfClearingPreCatalogUpstream(upstreamIndex: Int) {
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex),
              processControlPlane.catalog(forProcessID: route.target.processID) == nil
        else {
            return
        }
        switch processControlPlane.attemptSnapshot(processID: route.target.processID) {
        case let attempt? where attempt.phase == .attaching && attempt.upstreamID.rawValue == upstreamIndex:
            resetProcessRouteActivation(
                processID: route.target.processID,
                reason: "upstream_cleared_before_catalog"
            )
        case let attempt? where attempt.phase == .initialized && attempt.upstreamID.rawValue == upstreamIndex:
            resetProcessRouteActivation(
                processID: route.target.processID,
                reason: "upstream_cleared_before_catalog"
            )
        case _:
            return
        }
    }

    func clearsInitializedProcessRouteActivationBeforeCatalog(upstreamIndex: Int) -> Bool {
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex),
              processControlPlane.catalog(forProcessID: route.target.processID) == nil
        else {
            return false
        }
        guard let attempt = processControlPlane.attemptSnapshot(processID: route.target.processID),
              attempt.phase == .initialized else {
            return false
        }
        return attempt.upstreamID.rawValue == upstreamIndex
    }

    func resetAllProcessRouteActivations(reason: String) {
        let reset = processControlPlane.resetAllAttempts()
        applyProcessControlPlaneTransition(reset.transition)
        for processID in reset.processIDs {
            logger.info(
                "route_activation_abandoned",
                metadata: [
                    "pid": .string("\(processID)"),
                    "reason": .string(reason),
                ]
            )
        }
    }

    private func scheduleProcessRouteActivationRetry(
        processID: pid_t,
        retry: ProcessControlPlaneAuthority.Retry,
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
        let timeout = scheduleRuntimeTimeout(retry.delay) { [weak self] in
            guard let self else { return }
            guard self.processControlPlane.handleRetryFired(
                processID: processID,
                attemptID: retry.attempt
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
        if let lease = processControlPlane.currentCatalogLease(
            processID: processID,
            upstreamIndex: processControlPlane.attemptSnapshot(processID: processID)?.upstreamID.rawValue ?? -1
        ) {
            applyProcessControlPlaneTransition(
                processControlPlane.attach(.retryTimeout(timeout), to: lease)
            )
        } else {
            timeout.cancel()
        }
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
        guard processControlPlane.attemptSnapshot(processID: processID)?.attemptID.rawValue == attempt,
              let lease = processControlPlane.currentCatalogLease(
            processID: processID,
            upstreamIndex: upstreamIndex
        ) else {
            timeout.cancel()
            return
        }
        applyProcessControlPlaneTransition(
            processControlPlane.attach(.catalogTimeout(timeout), to: lease)
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
        guard let timeout = processControlPlane.handleCatalogTimeout(
            processID: processID,
            upstreamIndex: upstreamIndex,
            attemptID: attempt
        ) else {
            return
        }
        applyProcessControlPlaneTransition(timeout.transition)

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

        guard let topologyTransition = upstreamTopology.replace(
            UpstreamSlotID(rawValue: upstreamIndex),
            with: replacement
        ), let previous = topologyTransition.replaced?.slot else {
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
        publishUpstreamTopology(topologyTransition.snapshot)
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
