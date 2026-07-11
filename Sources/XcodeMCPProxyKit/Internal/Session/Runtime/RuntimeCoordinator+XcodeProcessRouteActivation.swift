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

    func commitProcessCatalog(
        _ outcome: CatalogOutcome,
        lease: CatalogLease,
        nowUptimeNanoseconds: UInt64
    ) -> CatalogCommit {
        let completionProof = outcome.sourceProof ?? lease.topologyProof
        guard let initializeClaim = upstreamHealthManager.currentCatalogActivationClaim(
            upstreamIndex: lease.upstreamIndex
        ), let activationProof = initializeClaim.topologyProof else {
            var catalogCommit: CatalogCommit?
            guard upstreamTopology.withValidated(completionProof, {
                catalogCommit = upstreamHealthManager.withUsableInitializedSource(
                    completionProof
                ) {
                    processControlPlane.completeCatalog(
                        outcome,
                        lease: lease,
                        nowUptimeNanoseconds: nowUptimeNanoseconds
                    )
                }
            }) != nil, let catalogCommit else {
                return .discarded(.upstreamReplaced, .none)
            }
            return catalogCommit
        }
        var catalogCommit: CatalogCommit?
        var activationCommit: UpstreamHealthManager.CatalogActivationCommit?
        guard upstreamTopology.withValidated([completionProof, activationProof], {
            activationCommit = upstreamHealthManager.commitCatalogActivation(
                initializeClaim,
                sourceProof: completionProof
            ) { _ in
                let result = processControlPlane.completeCatalog(
                    outcome,
                    lease: lease,
                    nowUptimeNanoseconds: nowUptimeNanoseconds
                )
                catalogCommit = result
                guard case .usable = outcome,
                      case .accepted = result else { return .keepWaiting }
                return .complete
            }
        }) != nil, let activationCommit else {
            return .discarded(.upstreamReplaced, .none)
        }
        switch activationCommit {
        case .notOwned:
            var fallbackCommit: CatalogCommit?
            guard upstreamTopology.withValidated(completionProof, {
                fallbackCommit = upstreamHealthManager.withUsableInitializedSource(
                    completionProof
                ) {
                    processControlPlane.completeCatalog(
                        outcome,
                        lease: lease,
                        nowUptimeNanoseconds: nowUptimeNanoseconds
                    )
                }
            }) != nil, let fallbackCommit else {
                return .discarded(.upstreamReplaced, .none)
            }
            return fallbackCommit
        case .kept:
            return preconditionedCatalogCommit(catalogCommit)
        case .completed(let timeout):
            timeout?.cancel()
            return preconditionedCatalogCommit(catalogCommit)
        }
    }

    private func preconditionedCatalogCommit(
        _ commit: CatalogCommit?
    ) -> CatalogCommit {
        guard let commit else {
            preconditionFailure("catalog activation commit did not execute")
        }
        return commit
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
        guard isActiveProcessBoundUpstream(upstreamIndex) else { return }
        guard let upstreamProof = upstreamTopology.operationLease(
            for: UpstreamSlotID(rawValue: upstreamIndex)
        )?.proof else { return }
        let readinessToken = UpstreamReadinessWaiterToken()
        guard let (reservation, transition) = processControlPlane.reserveActivation(
            routeID: route.id,
            upstreamProof: upstreamProof,
            nowUptimeNs: nowUptimeNanoseconds(),
            readinessToken: readinessToken
        ) else {
            return
        }
        applyProcessControlPlaneTransition(transition)
        startUpstreamWarmInitialize(
            upstreamIndex: upstreamIndex,
            mode: .processRouteActivation(reservation)
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
        guard case .processRouteActivation(let reservation) = mode else {
            return nil
        }
        let processID = reservation.processID
        let now = nowUptimeNanoseconds()
        guard upstreamIndex == reservation.upstreamIndex,
              let (start, transition) = processControlPlane.beginAttaching(
            reservation,
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

    func markProcessRouteActivationInitialized(proof: UpstreamTopologyProof) {
        let upstreamIndex = proof.slotID.rawValue
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex) else {
            return
        }
        let processID = route.target.processID
        guard let initialized = processControlPlane.markInitialized(
            routeID: route.id,
            upstreamProof: proof
        ) else {
            return
        }
        applyProcessControlPlaneTransition(initialized.transition)
        finishProcessRouteActivationInitialized(
            initialized,
            processID: processID,
            upstreamIndex: upstreamIndex
        )
    }

    func finishProcessRouteActivationInitialized(
        _ initialized: ProcessControlPlaneAuthority.InitializedAttempt,
        processID: pid_t,
        upstreamIndex: Int
    ) {
        logger.info(
            "route_activation_initialized",
            metadata: [
                "pid": .string("\(processID)"),
                "upstream": .string("\(upstreamIndex)"),
            ]
        )
        if let existingCatalog = processControlPlane.catalog(forProcessID: processID) {
            let commit = commitProcessCatalog(
                .usable(existingCatalog.rawResult, source: existingCatalog.upstreamProof),
                lease: initialized.lease,
                nowUptimeNanoseconds: nowUptimeNanoseconds()
            )
            applyCatalogCommit(commit)
            if case .accepted = commit {
                markXcodeProcessRouteCatalogAvailable(upstreamIndex: upstreamIndex)
            }
            return
        }
    }

    func finishProcessRouteActivationChannelInitialized(
        upstreamIndex: Int,
        initializeClaim: UpstreamHealthManager.InitializeClaim
    ) {
        guard let upstreamProof = initializeClaim.topologyProof,
              upstreamProof.slotID.rawValue == upstreamIndex,
              let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex),
              let attempt = processControlPlane.markChannelInitialized(
                  routeID: route.id,
                  upstreamProof: upstreamProof
              ) else { return }
        logger.info(
            "route_activation_initialized",
            metadata: [
                "pid": .string("\(route.target.processID)"),
                "upstream": .string("\(upstreamIndex)"),
            ]
        )
        if let existingCatalog = processControlPlane.catalog(
            forProcessID: route.target.processID
        ) {
            guard let (lease, transition) = processControlPlane.beginCatalogAttempt(
                routeID: route.id,
                preferredUpstreamProof: upstreamProof,
                nowUptimeNanoseconds: nowUptimeNanoseconds()
            ) else { return }
            applyProcessControlPlaneTransition(transition)
            let commit = commitProcessCatalog(
                .usable(existingCatalog.rawResult, source: existingCatalog.upstreamProof),
                lease: lease,
                nowUptimeNanoseconds: nowUptimeNanoseconds()
            )
            applyCatalogCommit(commit)
            if case .accepted = commit {
                markXcodeProcessRouteCatalogAvailable(upstreamIndex: upstreamIndex)
            }
            return
        }
        scheduleProcessRouteActivationCatalogTimeout(
            processID: route.target.processID,
            upstreamIndex: upstreamIndex,
            attempt: attempt,
            initializeClaim: initializeClaim
        )
        refreshPendingProcessToolsCatalogForReadyUpstream(
            upstreamIndex: upstreamIndex,
            reason: "route_activation_initialized_\(upstreamIndex)"
        )
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

    func scheduleProcessRouteActivationRetry(
        processID: pid_t,
        retry: ProcessControlPlaneAuthority.Retry,
        lease: ActivationLease,
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
            guard self.processControlPlane.handleActivationRetryFired(lease) else {
                return
            }
            guard let route = self.xcodeProcessRoutes.first(where: {
                $0.id == lease.routeID
            }) else {
                return
            }
            self.startProcessRouteActivation(for: route)
        }
        applyProcessControlPlaneTransition(
            processControlPlane.attachRetryTimeout(timeout, to: lease)
        )
    }

    private func scheduleProcessRouteActivationCatalogTimeout(
        processID: pid_t,
        upstreamIndex: Int,
        attempt: Int,
        initializeClaim: UpstreamHealthManager.InitializeClaim
    ) {
        guard let timeoutAmount = processRouteActivationCatalogTimeoutAmount() else {
            return
        }
        let timeout = scheduleRuntimeTimeout(timeoutAmount) { [weak self] in
            self?.handleProcessRouteActivationCatalogTimeout(
                processID: processID,
                upstreamIndex: upstreamIndex,
                attempt: attempt,
                initializeClaim: initializeClaim
            )
        }
        let attachment = upstreamHealthManager.replaceCatalogTimeout(
            timeout,
            for: initializeClaim
        )
        guard attachment.accepted else {
            timeout.cancel()
            return
        }
        attachment.replaced?.cancel()
    }

    private func processRouteActivationCatalogTimeoutAmount() -> TimeAmount? {
        MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: config.requestTimeout)
    }

    private func handleProcessRouteActivationCatalogTimeout(
        processID: pid_t,
        upstreamIndex: Int,
        attempt: Int,
        initializeClaim: UpstreamHealthManager.InitializeClaim
    ) {
        guard let proof = initializeClaim.topologyProof else { return }
        var cleared: (
            timeout: RuntimeScheduledTimeout?,
            initUpstreamID: Int64?,
            didReceiveInitializeResponse: Bool,
            didSendInitialized: Bool
        )?
        var processEligibility: ProcessControlPlaneAuthority.SupportEligibilityResult?
        let eligibility = initializeManager.finishSupportEligibilityUpdate {
            var update: CanonicalHandshakeState.SupportEligibilityUpdate?
            guard upstreamTopology.withValidatedSnapshot(proof, { topologySnapshot in
                cleared = upstreamHealthManager.timeoutCatalogActivation(
                    initializeClaim,
                    commit: { _ in true }
                )
                guard cleared != nil else { return false }
                update = commitSupportEligibilityAfterHealthMutation(
                    topologySnapshot: topologySnapshot,
                    detachedProof: proof,
                    catalogTimeoutProof: proof,
                    processEligibility: &processEligibility
                )
                return true
            }) == true else { return nil }
            return update
        }
        guard let eligibility, let cleared, let processEligibility else { return }
        let timeout = processEligibility.catalogTimeout
        if let timeout {
            applyProcessControlPlaneTransition(timeout.transition)
        }
        applyProcessControlPlaneTransition(processEligibility.transition)
        applySupportEligibilityCompletion(eligibility)
        finishClearingUpstreamState(
            proof: proof,
            cleared: cleared,
            resetsProcessRouteActivation: false
        )
        guard replaceOrRetireInitializeChannel(initializeClaim) else { return }
        guard let timeout else { return }

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

        scheduleProcessRouteActivationRetry(
            processID: timeout.activationLease.processID,
            retry: timeout.retry,
            lease: timeout.activationLease,
            reason: "catalog_timeout"
        )
    }

    func handleProcessRouteActivationChannelTimeout(
        lease: ActivationLease,
        initializeClaim: UpstreamHealthManager.InitializeClaim
    ) {
        guard clearUpstreamState(
            initializeClaim: initializeClaim,
            resetsProcessRouteActivation: false,
            replacesInitializedChannel: false
        ) else {
            return
        }
        guard replaceOrRetireInitializeChannel(initializeClaim) else { return }
        let timeout = processControlPlane.handleChannelInitializeTimeout(lease)
        if let timeout,
           xcodeProcessRoutes.contains(where: { $0.id == timeout.activationLease.routeID }) {
            applyProcessControlPlaneTransition(timeout.transition)
            scheduleProcessRouteActivationRetry(
                processID: lease.processID,
                retry: timeout.retry,
                lease: timeout.activationLease,
                reason: "channel_initialize_timeout"
            )
            return
        }
        if let timeout {
            applyProcessControlPlaneTransition(timeout.transition)
        }
        guard let route = xcodeProcessRoute(forUpstreamIndex: initializeClaim.upstreamIndex),
              let replacementProof = upstreamTopology.operationLease(
                for: UpstreamSlotID(rawValue: initializeClaim.upstreamIndex)
              )?.proof,
              let fresh = processControlPlane.prepareFreshActivationRetry(
                  routeID: route.id,
                  upstreamProof: replacementProof,
                  nowUptimeNs: nowUptimeNanoseconds()
              ) else { return }
        applyProcessControlPlaneTransition(fresh.2)
        scheduleProcessRouteActivationRetry(
            processID: route.target.processID,
            retry: fresh.1,
            lease: fresh.0,
            reason: "channel_initialize_timeout"
        )
    }

    @discardableResult
    func replaceOrRetireInitializeChannel(
        _ initializeClaim: UpstreamHealthManager.InitializeClaim
    ) -> Bool {
        guard let proof = initializeClaim.topologyProof else { return false }
        let upstreamIndex = proof.slotID.rawValue
        let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex)
        if let route {
            let replacements = dynamicUpstreamFactory?(route.target) ?? []
            if let replacement = replacements.first,
               let transition = upstreamTopology.replace(proof, with: replacement),
               let previous = transition.replaced?.slot,
               let replacementLease = transition.snapshot.operationLease(proof.slotID) {
                publishUpstreamTopology(transition.snapshot)
                observeUpstreamEvents(replacementLease)
                addRuntimeTask { await previous.stop() }
                for unused in replacements.dropFirst() {
                    addRuntimeTask { await unused.stop() }
                }
                return true
            }
            for unused in replacements {
                addRuntimeTask { await unused.stop() }
            }
        }
        guard let transition = upstreamTopology.retire(proof) else { return false }
        publishUpstreamTopology(transition.snapshot)
        for retired in transition.retired {
            addRuntimeTask { await retired.slot.stop() }
        }
        if let route {
            applyProcessControlPlaneTransition(processControlPlane.retireRoute(
                routeID: route.id,
                reason: "initialize_channel_replacement_unavailable",
                nowUptimeNs: nowUptimeNanoseconds()
            ))
            triggerXcodeProcessReconcile(reason: "initialize_channel_replacement_unavailable")
        }
        return false
    }

}
