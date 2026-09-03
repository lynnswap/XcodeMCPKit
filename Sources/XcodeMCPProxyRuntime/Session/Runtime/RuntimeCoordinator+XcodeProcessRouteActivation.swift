import Foundation
import Logging
import NIO
import XcodeMCPKit

extension RuntimeCoordinator {
    struct InitializeChannelReplacement: Sendable {
        let operationLease: UpstreamOperationLease

        var proof: UpstreamTopologyProof { operationLease.proof }
    }

    @discardableResult
    func applyCatalogCommit(
        _ commit: CatalogCommit
    ) -> [ControlPlane.RPCCancellationDelivery] {
        switch commit {
        case .accepted(_, let transition), .discarded(_, let transition):
            return applyProcessControlPlaneTransition(transition)
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
        guard initializeManager.snapshot().isShuttingDown == false else { return }
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
        var activation: (
            ProcessControlPlaneAuthority.ActivationReservation,
            ProcessControlPlaneTransition
        )?
        guard initializeManager.performIfRunning({
            activation = processControlPlane.reserveActivation(
                routeID: route.id,
                upstreamProof: upstreamProof,
                nowUptimeNs: nowUptimeNanoseconds(),
                readinessToken: readinessToken
            )
        }), let (reservation, transition) = activation else {
            return
        }
        applyProcessControlPlaneTransition(transition)
        startUpstreamWarmInitialize(
            upstreamIndex: upstreamIndex,
            mode: .processRouteActivation(reservation)
        )
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
        logger.debug(
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
        logger.debug(
            "route_activation_initialized",
            metadata: [
                "pid": .string("\(processID)"),
                "upstream": .string("\(upstreamIndex)"),
                "catalog_timeout_ms": .string(
                    processRouteActivationCatalogTimeoutMillisecondsDescription()
                ),
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
              let initialized = processControlPlane.markChannelInitialized(
                  routeID: route.id,
                  upstreamProof: upstreamProof
              ) else { return }
        logger.debug(
            "route_activation_initialized",
            metadata: [
                "pid": .string("\(route.target.processID)"),
                "upstream": .string("\(upstreamIndex)"),
                "catalog_timeout_ms": .string(
                    processRouteActivationCatalogTimeoutMillisecondsDescription()
                ),
            ]
        )
        for lease in initialized.activeCatalogLeases {
            scheduleProcessRouteActivationCatalogTimeout(
                lease: lease,
                initializeClaim: initializeClaim
            )
        }
        if let existingCatalog = processControlPlane.catalog(
            forProcessID: route.target.processID
        ) {
            guard let (lease, transition) = beginProcessCatalogAttemptIfRunning(
                routeID: route.id,
                preferredUpstreamProof: upstreamProof
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
        guard initialized.shouldStartCatalogLoad else { return }
        refreshProcessRouteToolsCatalog(
            route: route,
            upstreamProof: upstreamProof,
            reason: "route_activation_initialized_\(upstreamIndex)"
        )
    }

    func abandonProcessRouteActivation(processID: pid_t, reason: String) {
        applyProcessControlPlaneTransition(processControlPlane.abandon(processID: processID))
        logger.debug(
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
        logger.debug(
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
            logger.debug(
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
        logger.debug(
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
        var transition = ProcessControlPlaneTransition.none
        guard initializeManager.performIfRunning({
            transition = processControlPlane.attachRetryTimeout(timeout, to: lease)
        }) else {
            timeout.cancel()
            return
        }
        applyProcessControlPlaneTransition(transition)
    }

    func scheduleProcessRouteActivationCatalogTimeoutIfNeeded(
        lease: CatalogLease
    ) {
        guard let initializeClaim = upstreamHealthManager.currentCatalogActivationClaim(
            upstreamIndex: lease.upstreamIndex
        ), initializeClaim.topologyProof == lease.topologyProof else {
            return
        }
        scheduleProcessRouteActivationCatalogTimeout(
            lease: lease,
            initializeClaim: initializeClaim
        )
    }

    private func scheduleProcessRouteActivationCatalogTimeout(
        lease: CatalogLease,
        initializeClaim: UpstreamHealthManager.InitializeClaim
    ) {
        guard let timeoutAmount = processRouteActivationCatalogTimeoutAmount() else {
            return
        }
        var reservation: CatalogTimeoutReservation?
        guard initializeManager.performIfRunning({
            reservation = processControlPlane.reserveCatalogTimeout(for: lease)
        }), let reservation else {
            return
        }
        let timeout = scheduleRuntimeTimeout(timeoutAmount) { [weak self] in
            self?.handleProcessRouteActivationCatalogTimeout(
                reservation: reservation,
                initializeClaim: initializeClaim
            )
        }
        var transition = ProcessControlPlaneTransition.none
        guard initializeManager.performIfRunning({
            transition = processControlPlane.attachCatalogTimeout(
                timeout,
                to: reservation
            )
        }) else {
            timeout.cancel()
            return
        }
        applyProcessControlPlaneTransition(transition)
    }

    private func processRouteActivationCatalogTimeoutAmount() -> TimeAmount? {
        guard config.requestTimeout > 0 else { return nil }
        return MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: config.requestTimeout)
    }

    private func handleProcessRouteActivationCatalogTimeout(
        reservation: CatalogTimeoutReservation,
        initializeClaim: UpstreamHealthManager.InitializeClaim
    ) {
        let lease = reservation.lease
        guard let proof = initializeClaim.topologyProof,
              proof == lease.topologyProof,
              let route = xcodeProcessRoute(forUpstreamIndex: lease.upstreamIndex),
              route.id == lease.routeIdentity else { return }
        var timeout: ProcessControlPlaneAuthority.CatalogRequestTimeout?
        var didTimeoutCatalogRequest = false
        var validatedTopology = false
        guard initializeManager.performIfRunning({
            validatedTopology = upstreamTopology.withValidated(proof, {
                didTimeoutCatalogRequest = upstreamHealthManager.timeoutCatalogRequest(
                    initializeClaim,
                    commit: { _ in
                        timeout = processControlPlane.handleCatalogRequestTimeout(
                            reservation,
                            nowUptimeNs: nowUptimeNanoseconds()
                        )
                        return timeout != nil
                    }
                )
            }) != nil
        }),
            validatedTopology,
            didTimeoutCatalogRequest,
            let timeout
        else {
            return
        }
        let cancellationDeliveries = applyProcessControlPlaneTransition(timeout.transition)
        guard case .retryRequired(
            _,
            let retry,
            let retryLease,
            let catalogTimeoutCount
        ) = timeout else {
            return
        }

        logger.debug(
            "route_activation_timeout",
            metadata: [
                "pid": .string("\(lease.processID)"),
                "upstream": .string("\(lease.upstreamIndex)"),
                "attempt": .string("\(lease.attempt)"),
                "phase": .string("catalog"),
                "method": .string("tools/list"),
                "timeout_ms": .string(
                    processRouteActivationCatalogTimeoutMillisecondsDescription()
                ),
                "catalog_timeout_count": .string("\(catalogTimeoutCount)"),
                "retry_delay_ms": .string("\(retry.delayMilliseconds)"),
            ]
        )
        if processControlPlane.consumeToolsUnavailableWarningIfNeeded() {
            XcodeMCPToolsAvailabilityDiagnostic.logTimeout(
                logger: logger,
                processID: lease.processID,
                upstreamIndex: lease.upstreamIndex,
                retryDelayMilliseconds: retry.delayMilliseconds
            )
        }

        scheduleMissingProcessToolsCatalogRetry(
            processID: lease.processID,
            lease: retryLease,
            retry: retry,
            after: cancellationDeliveries,
            reason: "catalog_timeout"
        )
    }

    private func processRouteActivationCatalogTimeoutMillisecondsDescription() -> String {
        processRouteActivationCatalogTimeoutAmount().map {
            String($0.nanoseconds / 1_000_000)
        } ?? "disabled"
    }

    func handleProcessRouteActivationChannelTimeout(
        lease: ActivationLease,
        initializeClaim: UpstreamHealthManager.InitializeClaim
    ) {
        guard timeoutUpstreamInitialize(
            initializeClaim: initializeClaim,
            resetsProcessRouteActivation: false,
            replacesInitializedChannel: false
        ) else {
            return
        }
        guard let replacement = replaceOrRetireInitializeChannel(initializeClaim) else { return }
        let timeout = processControlPlane.handleChannelInitializeTimeout(lease)
        if let timeout,
           xcodeProcessRoutes.contains(where: { $0.id == timeout.activationLease.routeID }) {
            applyProcessControlPlaneTransition(timeout.transition)
            scheduleProcessRouteActivationRetryAfterChannelStop(
                processID: lease.processID,
                retry: timeout.retry,
                lease: timeout.activationLease,
                replacement: replacement,
                reason: "channel_initialize_timeout"
            )
            return
        }
        if let timeout {
            applyProcessControlPlaneTransition(timeout.transition)
        }
        guard let route = xcodeProcessRoute(forUpstreamIndex: initializeClaim.upstreamIndex) else {
            return
        }
        var fresh: (
            ActivationLease,
            ProcessControlPlaneAuthority.Retry,
            ProcessControlPlaneTransition
        )?
        guard initializeManager.performIfRunning({
            fresh = processControlPlane.prepareFreshActivationRetry(
                routeID: route.id,
                upstreamProof: replacement.proof,
                nowUptimeNs: nowUptimeNanoseconds()
            )
        }), let fresh else {
            return
        }
        applyProcessControlPlaneTransition(fresh.2)
        scheduleProcessRouteActivationRetryAfterChannelStop(
            processID: route.target.processID,
            retry: fresh.1,
            lease: fresh.0,
            replacement: replacement,
            reason: "channel_initialize_timeout"
        )
    }

    private func scheduleProcessRouteActivationRetryAfterChannelStop(
        processID: pid_t,
        retry: ProcessControlPlaneAuthority.Retry,
        lease: ActivationLease,
        replacement: InitializeChannelReplacement,
        reason: String
    ) {
        let scheduled = addRuntimeTask { [weak self, replacement] in
            guard let self,
                  await self.waitUntilUpstreamOperationActivatable(
                    replacement.operationLease
                  ),
                  self.initializeManager.snapshot().isShuttingDown == false
            else { return }
            self.scheduleProcessRouteActivationRetry(
                processID: processID,
                retry: retry,
                lease: lease,
                reason: reason
            )
        }
        if scheduled == false {
            applyProcessControlPlaneTransition(
                processControlPlane.resetAttempt(processID: processID)
            )
        }
    }

    @discardableResult
    func replaceOrRetireInitializeChannel(
        _ initializeClaim: UpstreamHealthManager.InitializeClaim
    ) -> InitializeChannelReplacement? {
        guard let proof = initializeClaim.topologyProof else { return nil }
        let requestsBridgePoolRecovery: Bool
        if initializeClaim.owner == .regular {
            requestsBridgePoolRecovery = true
        } else {
            requestsBridgePoolRecovery = false
        }
        return replaceOrRetireInitializeChannel(
            proof,
            expectedRouteID: nil,
            requestsBridgePoolRecovery: requestsBridgePoolRecovery
        )
    }

    @discardableResult
    func replaceOrRetireInitializeChannel(
        _ proof: UpstreamTopologyProof,
        expectedRouteID: ProcessRouteID?,
        requestsBridgePoolRecovery: Bool
    ) -> InitializeChannelReplacement? {
        var replacement: InitializeChannelReplacement?
        guard initializeManager.performIfRunning({
            replacement = replaceOrRetireInitializeChannelWhileRunning(
                proof,
                expectedRouteID: expectedRouteID,
                requestsBridgePoolRecovery: requestsBridgePoolRecovery
            )
        }) else {
            return nil
        }
        return replacement
    }

    private func replaceOrRetireInitializeChannelWhileRunning(
        _ proof: UpstreamTopologyProof,
        expectedRouteID: ProcessRouteID?,
        requestsBridgePoolRecovery: Bool
    ) -> InitializeChannelReplacement? {
        let upstreamIndex = proof.slotID.rawValue
        let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex)
        if let expectedRouteID, route?.id != expectedRouteID {
            return nil
        }
        let replacements: [any UpstreamSlotControlling]
        if let route {
            replacements = dynamicUpstreamFactory?(route.target) ?? []
        } else if processRoutingEnabled == false, let unboundUpstreamFactory {
            replacements = [unboundUpstreamFactory()]
        } else {
            replacements = []
        }
        if let replacement = replacements.first {
            let previousStopCompletion = AsyncTerminalSignal()
            if let transition = commitUpstreamTopologyMutation({
                upstreamTopology.replace(
                    proof,
                    with: replacement,
                    predecessorStopCompletion: previousStopCompletion
                )
            }),
                let previous = transition.replaced?.slot,
                let replacementLease = transition.snapshot.operationLease(proof.slotID) {
                observeUpstreamEvents(replacementLease)
                let replacementProof = replacementLease.proof
                let upstreamTopology = upstreamTopology
                let finishPreviousStop: @Sendable () -> Void = {
                    upstreamTopology.clearPredecessorStopCompletion(
                        previousStopCompletion,
                        for: replacementProof
                    )
                    previousStopCompletion.signal()
                }
                retireUpstreamSlot(previous, onStopped: finishPreviousStop)
                for unused in replacements.dropFirst() {
                    retireUpstreamSlot(unused)
                }
                if requestsBridgePoolRecovery {
                    addRuntimeTask { [weak self, replacementLease] in
                        guard let self,
                              await self.waitUntilUpstreamOperationActivatable(replacementLease),
                              self.initializeManager.snapshot().isShuttingDown == false
                        else { return }
                        if let route {
                            var transition = ProcessControlPlaneTransition.none
                            guard self.initializeManager.performIfRunning({
                                transition = self.processControlPlane.requestBridgePoolRecovery(
                                    routeID: route.id,
                                    upstreamID: replacementLease.proof.slotID
                                )
                            }) else { return }
                            self.applyProcessControlPlaneTransition(transition)
                        } else if self.processRoutingEnabled == false {
                            self.startUpstreamWarmInitialize(
                                upstreamIndex: replacementLease.upstreamIndex,
                                applyBackoff: true
                            )
                        }
                    }
                }
                return InitializeChannelReplacement(
                    operationLease: replacementLease
                )
            }
        }
        for unused in replacements {
            retireUpstreamSlot(unused)
        }
        guard let transition = commitUpstreamTopologyMutation({
            upstreamTopology.retire(proof)
        }) else { return nil }
        for retired in transition.retired {
            retireUpstreamSlot(retired.slot)
        }
        if let route {
            applyProcessControlPlaneTransition(processControlPlane.retireRoute(
                routeID: route.id,
                reason: "initialize_channel_replacement_unavailable",
                nowUptimeNs: nowUptimeNanoseconds()
            ))
            triggerXcodeProcessReconcile(reason: "initialize_channel_replacement_unavailable")
        }
        return nil
    }

}
