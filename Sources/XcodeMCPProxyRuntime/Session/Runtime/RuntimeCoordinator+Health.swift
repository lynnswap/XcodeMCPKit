import Foundation
import NIO
import NIOFoundationCompat
import XcodeMCPKit

extension RuntimeCoordinator {
    enum WarmInitializeMode: Sendable {
        case regular
        case processRouteActivation(ProcessControlPlaneAuthority.ActivationReservation)

        var readinessToken: UpstreamReadinessWaiterToken? {
            switch self {
            case .regular:
                return nil
            case .processRouteActivation(let reservation):
                return reservation.readinessToken
            }
        }
    }

    func markRequestSucceeded(_ operationLease: UpstreamOperationLease) {
        upstreamHealthManager.markRequestSucceeded(operationLease.proof)
    }

    func markUpstreamOverloaded(_ proof: UpstreamTopologyProof) {
        _ = upstreamHealthManager.markUpstreamOverloaded(proof)
    }

    func markRequestTimedOut(_ operationLease: UpstreamOperationLease) {
        markRequestTimedOut(operationLease.proof)
    }

    private func markRequestTimedOut(_ proof: UpstreamTopologyProof) {
        let nowUptimeNs = nowUptimeNanoseconds()
        guard let result = commitVerifiedHealthSupportMutation(
            proof: proof,
            mutation: {
                .some(upstreamHealthManager.markRequestTimedOut(
                    proof,
                    nowUptimeNs: nowUptimeNs
                ))
            }
        ) else { return }
        let timeoutCount = result.timeoutCount

        if result.shouldClearPins {
            logger.warning(
                "Upstream quarantined after repeated request timeouts",
                metadata: [
                    "upstream": .string("\(proof.slotID.rawValue)"),
                    "timeout_count": .string("\(timeoutCount)"),
                ]
            )
            failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
            schedulePendingInitializeQuarantineRecovery()
        }
    }

    func probeUpstreamHealth(_ probe: UpstreamHealthManager.ProbeRequest) {
        let upstreamIndex = probe.upstreamIndex
        guard let operationLease = upstreamTopology.operationLease(
            for: probe.topologyProof
        ) else {
            schedulePendingInitializeQuarantineRecovery()
            return
        }
        let internalSessionID = controlPlaneSessionID(for: "health_probe", route: nil)
        _ = session(id: internalSessionID)
        let probeSession = session(id: internalSessionID)
        let probeTimeout: TimeAmount = .seconds(2)
        let originalID = JSONRPC.ID(any: "__probe-\(upstreamIndex)-\(UUID().uuidString)")!
        let registration = probeSession.router.registerRequestPending(
            idKey: originalID.key,
            on: eventLoop,
            timeout: probeTimeout
        )
        guard let upstreamID = assignUpstreamID(
            sessionID: internalSessionID,
            originalID: originalID,
            operationLease: operationLease
        ) else {
            _ = probeSession.router.cancelPending(token: registration.token)
            finishHealthProbe(probe, success: false, reason: "assign_request_id_failed")
            return
        }

        let request = JSONRPC.Wire.requestObject(id: upstreamID, method: "tools/list")
        guard let requestData = try? JSONRPC.Wire.data(from: request) else {
            finishHealthProbe(
                probe,
                success: false,
                reason: "encode_request_failed"
            )
            return
        }

        guard sendUpstream(
            requestData,
            operationLease: operationLease,
            ensureRunning: false,
            admission: nil,
            onRejected: {
                _ = probeSession.router.cancelPending(token: registration.token)
            }
        ) else {
            finishHealthProbe(probe, success: false, reason: "send_rejected")
            return
        }

        addRuntimeTask { [weak self, probeSession, registration] in
            guard let self else { return }
            do {
                var buffer = try await withTaskCancellationHandler {
                    try await registration.future.get()
                } onCancel: {
                    _ = probeSession.router.cancelPending(token: registration.token)
                    self.upstreamRouter.remove(
                        proof: operationLease.proof,
                        upstreamID: upstreamID
                    )
                }
                guard let responseData = buffer.readData(length: buffer.readableBytes),
                    let object = try JSONSerialization.jsonObject(with: responseData, options: [])
                        as? [String: Any],
                    object["error"] == nil,
                    let resultValue = object["result"],
                    let result = JSONValue(any: resultValue),
                    self.isValidToolsListResult(result)
                else {
                    self.upstreamRouter.remove(
                        proof: operationLease.proof,
                        upstreamID: upstreamID
                    )
                    self.finishHealthProbe(
                        probe,
                        success: false,
                        reason: "invalid_response"
                    )
                    return
                }
                self.finishHealthProbe(
                    probe,
                    success: true,
                    reason: "ok"
                )
            } catch {
                if error is CancellationError {
                    self.upstreamRouter.remove(
                        proof: operationLease.proof,
                        upstreamID: upstreamID
                    )
                    self.finishHealthProbe(
                        probe,
                        success: false,
                        reason: "cancelled"
                    )
                    return
                }
                self.upstreamRouter.remove(
                    proof: operationLease.proof,
                    upstreamID: upstreamID
                )
                self.finishHealthProbe(
                    probe,
                    success: false,
                    reason: "timeout"
                )
            }
        }
    }

    func finishHealthProbe(
        _ probe: UpstreamHealthManager.ProbeRequest,
        success: Bool,
        reason: String
    ) {
        let upstreamIndex = probe.upstreamIndex
        let nowUptimeNs = nowUptimeNanoseconds()
        let committed: Void? = commitVerifiedHealthSupportMutation(
            proof: probe.topologyProof,
            mutation: { () -> Void? in
                guard upstreamHealthManager.finishHealthProbe(
                    probe,
                    success: success,
                    nowUptimeNs: nowUptimeNs
                ) else { return nil }
                return ()
            }
        )
        guard committed != nil else {
            schedulePendingInitializeQuarantineRecovery()
            return
        }
        if success {
            upstreamSlotScheduler.wake()
            refreshPendingProcessToolsCatalogForReadyUpstream(
                upstreamIndex: upstreamIndex,
                reason: "health_probe_\(upstreamIndex)"
            )
        } else {
            failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
            schedulePendingInitializeQuarantineRecovery()
        }
        logger.debug(
            "Upstream health probe completed",
            metadata: [
                "upstream": .string("\(upstreamIndex)"),
                "success": .string(success ? "true" : "false"),
                "reason": .string(reason),
            ]
        )
    }

    func markToolsListRefreshSucceeded(
        _ proof: UpstreamTopologyProof,
        nowUptimeNs: UInt64
    ) {
        let upstreamIndex = proof.slotID.rawValue
        let committed: Void? = commitVerifiedHealthSupportMutation(
            proof: proof,
            mutation: { () -> Void? in
                guard upstreamHealthManager.markToolsListRefreshSucceeded(
                    proof,
                    nowUptimeNs: nowUptimeNs
                ) else { return nil }
                return ()
            }
        )
        guard committed != nil else { return }
        testHooks.toolsListRefreshCompleted?(upstreamIndex, true)
    }

    func markToolsListRefreshFailed(
        _ proof: UpstreamTopologyProof,
        nowUptimeNs: UInt64,
        reason: String
    )
    {
        let upstreamIndex = proof.slotID.rawValue
        guard let result = commitVerifiedHealthSupportMutation(
            proof: proof,
            mutation: {
                upstreamHealthManager.markToolsListRefreshFailed(
                    proof,
                    nowUptimeNs: nowUptimeNs
                )
            }
        ) else { return }
        let failures = result.failures
        let quarantineUntil = result.quarantineUntil

        logger.debug(
            "tools/list warmup failed (best-effort)",
            metadata: [
                "upstream": .string("\(upstreamIndex)"),
                "reason": .string(reason),
                "failures": .string("\(failures)"),
                "quarantine_until_uptime_ns": .string("\(quarantineUntil)"),
                "uptime_ns": .string("\(nowUptimeNs)"),
            ]
        )
        testHooks.toolsListRefreshCompleted?(upstreamIndex, false)
        schedulePendingInitializeQuarantineRecovery()
    }

    func schedulePendingInitializeQuarantineRecovery() {
        guard let preparation = initializeManager.preparePendingQuarantineRecovery(
            recovery: { upstreamHealthManager.earliestInitializedQuarantineRecovery() }
        ) else { return }
        preparation.replacedTimeout?.cancel()

        let nowUptimeNs = nowUptimeNanoseconds()
        let remaining = preparation.recovery.deadlineUptimeNs > nowUptimeNs
            ? preparation.recovery.deadlineUptimeNs - nowUptimeNs
            : 0
        let boundedRemaining = min(remaining, UInt64(Int64.max))
        let timeout = scheduleRuntimeTimeout(
            .nanoseconds(Int64(boundedRemaining))
        ) { [weak self] in
            self?.handlePendingInitializeQuarantineRecovery(preparation)
        }
        let attachment = initializeManager.attachPendingQuarantineRecoveryTimeout(
            timeout,
            lease: preparation.lease
        )
        attachment.replaced?.cancel()
        if attachment.accepted == false {
            timeout.cancel()
        }
    }

    private func handlePendingInitializeQuarantineRecovery(
        _ preparation: InitializeManager.PendingRecoveryPreparation
    ) {
        var probe: UpstreamHealthManager.ProbeRequest?
        let began: Bool? = initializeManager.withPendingQuarantineRecovery(
            preparation.lease
        ) {
            guard upstreamTopology.withValidated(
                preparation.recovery.topologyProof,
                {
                    probe = upstreamHealthManager.beginQuarantineRecovery(
                        preparation.recovery,
                        nowUptimeNs: nowUptimeNanoseconds()
                    )
                    return true
                }
            ) == true else { return false }
            return probe != nil
        }
        guard let began else { return }
        if began, let probe {
            probeUpstreamHealth(probe)
            schedulePendingInitializeQuarantineRecovery()
            return
        }
        schedulePendingInitializeQuarantineRecovery()
    }

    /// Commits a verified health transition and its initialize/catalog
    /// eligibility projection under the shared lock order:
    /// InitializeManager -> authoritative topology -> health -> canonical ->
    /// process control plane. Effects are applied only after all locks release.
    func commitVerifiedHealthSupportMutation<Result>(
        proof: UpstreamTopologyProof,
        detachedProof: UpstreamTopologyProof? = nil,
        mutation: () -> Result?
    ) -> Result? {
        var mutationResult: Result?
        var processEligibility: ProcessControlPlaneAuthority.SupportEligibilityResult?
        let eligibility = initializeManager.finishSupportEligibilityUpdate {
            var update: CanonicalHandshakeState.SupportEligibilityUpdate?
            guard upstreamTopology.withValidatedSnapshot(proof, { topologySnapshot in
                guard let result = mutation() else { return false }
                mutationResult = result
                update = commitSupportEligibilityAfterHealthMutation(
                    topologySnapshot: topologySnapshot,
                    detachedProof: detachedProof,
                    processEligibility: &processEligibility
                )
                return true
            }) == true else { return nil }
            return update
        }
        guard let eligibility, let mutationResult, let processEligibility else { return nil }
        applyProcessControlPlaneTransition(processEligibility.transition)
        for ineligibleProof in eligibility.update.newlyIneligibleProofs {
            removeXcodeWindowOwners(forUpstreamIndex: ineligibleProof.slotID.rawValue)
        }
        applySupportEligibilityCompletion(eligibility)
        return mutationResult
    }

    func isValidToolsListResult(_ value: JSONValue) -> Bool {
        guard case .object(let object) = value else { return false }
        guard let toolsValue = object["tools"] else { return false }
        if case .array = toolsValue {
            return true
        }
        return false
    }

    func recoveryAwareUsableInitializedUpstreamIndices(in route: XcodeProcessRoute) -> [Int] {
        processRouteExposure(policy: .toolsCatalog)
            .routes
            .first { $0.route.id == route.id }?
            .usableUpstreamIndices ?? []
    }

    func startUpstreamWarmInitialize(
        upstreamIndex: Int,
        applyBackoff: Bool = false,
        mode: WarmInitializeMode = .regular
    ) {
        guard isActiveProcessBoundUpstream(upstreamIndex) else { return }
        runWhenUpstreamReady(
            reason: "warm_initialize_\(upstreamIndex)",
            applyBackoff: applyBackoff,
            token: mode.readinessToken
        ) { [weak self, mode] in
            self?.startUpstreamWarmInitializeWhenReady(
                upstreamIndex: upstreamIndex,
                mode: mode
            )
        }
    }

    private func startUpstreamWarmInitializeWhenReady(
        upstreamIndex: Int,
        mode: WarmInitializeMode
    ) {
        guard isActiveProcessBoundUpstream(upstreamIndex) else { return }
        let activationStart = beginProcessRouteActivationIfNeeded(
            mode: mode,
            upstreamIndex: upstreamIndex
        )
        if case .processRouteActivation = mode, activationStart == nil {
            return
        }
        if let activationStart,
           processControlPlane.validate(activationStart) == false {
            applyProcessControlPlaneTransition(
                processControlPlane.cancelActivation(activationStart)
            )
            return
        }
        guard let initializeClaim = upstreamHealthManager.claimWarmInitialize(
            upstreamIndex: upstreamIndex,
            owner: activationStart == nil ? .regular : .processRouteActivation
        ) else {
            if let activationStart {
                applyProcessControlPlaneTransition(
                    processControlPlane.cancelActivation(activationStart)
                )
            }
            return
        }
        guard let proof = initializeClaim.topologyProof,
              let operationLease = upstreamTopology.operationLease(for: proof),
              let upstreamID = upstreamRouter.assignInitialize(proof: proof) else {
            clearUpstreamState(initializeClaim: initializeClaim)
            return
        }
        guard upstreamHealthManager.setWarmInitializeUpstreamID(
            upstreamID,
            for: initializeClaim
        ) else {
            upstreamRouter.remove(proof: proof, upstreamID: upstreamID)
            if let activationStart {
                applyProcessControlPlaneTransition(
                    processControlPlane.cancelActivation(activationStart)
                )
            }
            return
        }
        guard upstreamHealthManager.validate(initializeClaim) else { return }
        scheduleUpstreamInitTimeout(
            mode: mode,
            activationStart: activationStart,
            initializeClaim: initializeClaim
        )

        let request = makeInternalInitializeRequest(id: upstreamID)
        if let data = try? JSONRPC.Wire.data(from: request) {
            guard upstreamHealthManager.beginInitializeSend(initializeClaim) else { return }
            _ = sendUpstream(
                data,
                operationLease: operationLease,
                ensureRunning: true,
                admission: nil,
                onRejected: { [weak self] in
                    self?.clearUpstreamState(initializeClaim: initializeClaim)
                }
            )
        } else {
            clearUpstreamState(initializeClaim: initializeClaim)
        }
    }

    func scheduleUpstreamInitTimeout(
        mode: WarmInitializeMode = .regular,
        activationStart: ProcessControlPlaneAuthority.ActivationStart? = nil,
        initializeClaim: UpstreamHealthManager.InitializeClaim
    ) {
        guard
            let timeoutAmount = upstreamInitTimeoutAmount(for: mode)
        else {
            return
        }
        let timeout = scheduleRuntimeTimeout(timeoutAmount) { [weak self, mode] in
            guard let self else { return }
            switch mode {
            case .regular:
                self.handleUpstreamInitTimeout(initializeClaim: initializeClaim)
            case .processRouteActivation:
                guard let activationStart else { return }
                self.handleProcessRouteActivationChannelTimeout(
                    lease: activationStart.lease,
                    initializeClaim: initializeClaim
                )
            }
        }
        if case .processRouteActivation = mode {
            guard activationStart != nil else {
                timeout.cancel()
                return
            }
        }
        let attachment = upstreamHealthManager.replaceInitTimeout(
            timeout,
            for: initializeClaim
        )
        guard attachment.accepted else {
            timeout.cancel()
            return
        }
        attachment.replaced?.cancel()
    }

    func upstreamInitTimeoutAmount(for mode: WarmInitializeMode) -> TimeAmount? {
        switch mode {
        case .regular:
            return MCP.MethodDispatcher.timeoutForInitialize(defaultSeconds: config.requestTimeout)
        case .processRouteActivation:
            guard config.usesPermissionDialogAutomation else {
                return MCP.MethodDispatcher.timeoutForInitialize(defaultSeconds: config.requestTimeout)
            }
            return .seconds(3)
        }
    }

    func handleUpstreamInitTimeout(
        initializeClaim: UpstreamHealthManager.InitializeClaim
    ) {
        guard clearUpstreamState(initializeClaim: initializeClaim) else { return }
        let upstreamIndex = initializeClaim.upstreamIndex

        if isCurrentPrimaryInitializeUpstream(upstreamIndex) {
            let shouldRetryEagerInit = initializeManager.consumeWarmInitRecoveryIntent(
                policy: .onlyWithoutCachedInitialize
            )
            if shouldRetryEagerInit {
                startEagerInitializePrimary(applyBackoff: true)
            }
        }
        failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
    }
}
