import Foundation
import NIO
import XcodeMCPCore

extension RuntimeCoordinator {
    struct InitializeResponseOwnership: Sendable {
        let initializeClaim: UpstreamHealthManager.InitializeClaim
    }

    struct CommittedUpstreamInitialization: Sendable {
        let canonicalCommit: CanonicalHandshakeState.InitializeCommit
        let healthTransition: UpstreamHealthManager.MarkInitializedTransition?
    }

    func startEagerInitializePrimary(applyBackoff: Bool = false) {
        guard let upstreamIndex = primaryInitializeUpstreamIndex() else {
            failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
            return
        }
        runWhenUpstreamReady(
            reason: "primary_initialize",
            applyBackoff: applyBackoff
        ) { [weak self, upstreamIndex, applyBackoff] in
            guard let self else { return }
            guard self.upstreamTopology.operationLease(for: UpstreamSlotID(rawValue: upstreamIndex)) != nil else {
                self.startEagerInitializePrimary(applyBackoff: applyBackoff)
                return
            }
            self.startEagerInitializePrimaryWhenReady(upstreamIndex: upstreamIndex)
        }
    }

    private func startEagerInitializePrimaryWhenReady(upstreamIndex: Int) {
        let decision = initializeManager.beginEagerInitializePrimary(upstreamIndex: upstreamIndex)
        let shouldSend = decision.shouldSendRequest
        let shouldScheduleTimeout = decision.shouldScheduleTimeout
        if shouldScheduleTimeout {
            scheduleInitTimeout()
        }
        guard shouldSend else { return }

        sendPrimaryInitializeRequestIfStillPending()
    }

    func startPrimaryInitializeRequestWhenReady(applyBackoff: Bool = false) {
        let token = upstreamReadinessGate.isEnabled ? UpstreamReadinessWaiterToken() : nil
        if let token {
            guard initializeManager.setPrimaryInitializeReadinessToken(token) else { return }
            replacePrimaryInitializeReadinessWaiter(with: token)
        }
        runWhenUpstreamReady(
            reason: "primary_initialize_request",
            applyBackoff: applyBackoff,
            token: token
        ) { [weak self, token] in
            guard let self else { return }
            if let token {
                self.clearPrimaryInitializeReadinessWaiter(token)
                guard !token.isCancelled else { return }
            }
            guard self.initializeManager.pendingPrimaryInitializeUpstreamIndex() != nil else {
                return
            }
            self.sendPrimaryInitializeRequestIfStillPending()
        }
    }

    private func sendPrimaryInitializeRequestIfStillPending() {
        guard let upstreamIndex = initializeManager.pendingPrimaryInitializeUpstreamIndex() else {
            return
        }
        guard let operationLease = upstreamTopology.operationLease(
            for: UpstreamSlotID(rawValue: upstreamIndex)
        ) else { return }
        if deferInitializeUntilUpstreamActivatable(
            operationLease,
            resume: { [weak self] in
                self?.sendPrimaryInitializeRequestIfStillPending()
            }
        ) {
            return
        }
        let proof = operationLease.proof
        guard let initializeClaim = upstreamHealthManager.claimWarmInitialize(
            topologyProof: proof
        ),
           let upstreamID = upstreamRouter.assignInitialize(proof: proof) else {
            return
        }
        guard initializeManager.beginPrimaryInitializeSend(
            upstreamIndex: upstreamIndex,
            upstreamID: upstreamID
        ) else {
            upstreamRouter.remove(proof: proof, upstreamID: upstreamID)
            clearUpstreamState(initializeClaim: initializeClaim)
            return
        }
        guard upstreamHealthManager.setWarmInitializeUpstreamID(
            upstreamID,
            for: initializeClaim
        ) else {
            _ = initializeManager.releasePrimaryInitialize(
                upstreamIndex: upstreamIndex,
                upstreamID: upstreamID
            )
            upstreamRouter.remove(proof: proof, upstreamID: upstreamID)
            return
        }

        let request = makeInternalInitializeRequest(id: upstreamID)
        if let data = try? JSONRPC.Wire.data(from: request) {
            guard upstreamHealthManager.beginInitializeSend(initializeClaim) else { return }
            _ = sendUpstream(
                data,
                operationLease: operationLease,
                ensureRunning: true,
                onRejected: { [weak self] in
                    self?.clearUpstreamState(initializeClaim: initializeClaim)
                }
            )
        } else {
            failInitPending(error: ControlPlane.Error.invalidResponse("invalid initialize response"))
        }
    }

    func primaryInitializeUpstreamIndex(excluding excludedUpstreamIndices: Set<Int> = []) -> Int? {
        upstreamSlotIDs.map(\.rawValue).sorted().first { !excludedUpstreamIndices.contains($0) }
    }

    func currentPrimaryInitializeUpstreamIndex() -> Int {
        initializeManager.activePrimaryInitializeUpstreamIndex()
            ?? canonicalHandshakeState.initializeSourceUpstream()
            ?? primaryInitializeUpstreamIndex()
            ?? 0
    }

    func isCurrentPrimaryInitializeUpstream(_ upstreamIndex: Int) -> Bool {
        currentPrimaryInitializeUpstreamIndex() == upstreamIndex
    }

    private func primaryInitializeRetryUpstreamIndex(failedUpstreamIndex: Int) -> Int? {
        let excludedUpstreamIndices: Set<Int> = [failedUpstreamIndex]
        return primaryInitializeUpstreamIndex(excluding: excludedUpstreamIndices)
    }

    func retryPrimaryInitializeOnAlternativeUpstream(
        failedUpstreamIndex: Int,
        failedUpstreamID: Int64?,
        reason: String,
        matching expectedPhase: InitializeManager.PrimaryInitializePhase? = nil
    ) -> Bool {
        guard let retryUpstreamIndex = primaryInitializeRetryUpstreamIndex(
            failedUpstreamIndex: failedUpstreamIndex
        ) else {
            return false
        }
        if let failedUpstreamID {
            if let claim = upstreamHealthManager.currentInitializeClaim(
                upstreamIndex: failedUpstreamIndex,
                expectedUpstreamID: failedUpstreamID
            ) {
                _ = clearUpstreamState(
                    initializeClaim: claim,
                )
            }
        }
        guard initializeManager.preparePrimaryInitializeRetry(
            upstreamIndex: retryUpstreamIndex,
            matching: expectedPhase
        ) else {
            return false
        }
        startPrimaryInitializeRequestWhenReady(applyBackoff: true)
        return true
    }

    func handleInitializeResponse(_ object: [String: Any], upstreamIndex: Int, upstreamID: Int64) {
        guard upstreamHealthManager.currentInitializeClaim(
            upstreamIndex: upstreamIndex,
            expectedUpstreamID: upstreamID
        ) != nil else {
            return
        }
        if initializeManager.consumeCancelledPrimaryInitializeAttempt(
            upstreamIndex: upstreamIndex,
            upstreamID: upstreamID
        ) {
            if let claim = upstreamHealthManager.currentInitializeClaim(
                upstreamIndex: upstreamIndex,
                expectedUpstreamID: upstreamID
            ) {
                clearUpstreamState(initializeClaim: claim)
            }
            return
        }
        guard let ownership = takeInitializeResponseOwnership(
            upstreamIndex: upstreamIndex,
            upstreamID: upstreamID
        ) else { return }
        let isPrimaryInitialize = initializeManager.primaryInitializeMatches(
            upstreamIndex: upstreamIndex,
            upstreamID: upstreamID
        )
        let activePrimaryInitializeUpstreamIndex =
            initializeManager.activePrimaryInitializeUpstreamIndex()
        let canPromoteWarmInitializeToPrimary =
            isPrimaryInitialize == false
            && activePrimaryInitializeUpstreamIndex == nil
            && canonicalHandshakeState.initializeResult() == nil
        let handlesPrimaryInitialize = isPrimaryInitialize
            || canPromoteWarmInitializeToPrimary

        guard let resultValue = object["result"], let result = JSONValue(any: resultValue) else {
            guard clearUpstreamState(
                initializeClaim: ownership.initializeClaim,
            ) else { return }
            if completePendingInitializesUsingCachedResultIfAvailable() {
                retryInitializeAfterTerminalFailure(
                    ownership: ownership,
                    upstreamIndex: upstreamIndex
                )
                return
            }
            let anotherRouteCanPublish = canonicalHandshakeState.hasInitializeParticipants()
                || hasOtherInitializeRouteInFlight(excluding: upstreamIndex)
            if anotherRouteCanPublish {
                if handlesPrimaryInitialize {
                    _ = initializeManager.releasePrimaryInitialize(
                        upstreamIndex: upstreamIndex,
                        upstreamID: upstreamID
                    )
                }
                retryInitializeAfterTerminalFailure(
                    ownership: ownership,
                    upstreamIndex: upstreamIndex
                )
                failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
                return
            }
            if handlesPrimaryInitialize {
                let didRetry = retryPrimaryInitializeOnAlternativeUpstream(
                    failedUpstreamIndex: upstreamIndex,
                    failedUpstreamID: upstreamID,
                    reason: "primary_initialize_failed"
                )
                if didRetry {
                    return
                }
                if let errorObject = object["error"] as? [String: Any], !errorObject.isEmpty {
                    completeInitPendingWithError(errorObject)
                } else {
                    failInitPending(error: ControlPlane.Error.invalidResponse("invalid initialize response"))
                }
            } else {
                retryInitializeAfterTerminalFailure(
                    ownership: ownership,
                    upstreamIndex: upstreamIndex
                )
                failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
            }
            return
        }

        guard Self.supportedProtocolVersion(
            fromInitializeResult: result
        ) != nil else {
            handleUnsupportedInitializeProtocolVersion(
                result,
                upstreamIndex: upstreamIndex,
                upstreamID: upstreamID,
                ownership: ownership,
                handlesPrimaryInitialize: handlesPrimaryInitialize
            )
            return
        }

        guard let sourceProof = ownership.initializeClaim.topologyProof else {
            _ = clearUpstreamState(
                initializeClaim: ownership.initializeClaim,
            )
            return
        }
        let participantLease: CanonicalHandshakeState.InitializeParticipantLease
        switch canonicalHandshakeState.offerInitializeResult(
            result,
            sourceProof: sourceProof
        ) {
        case .accepted(let lease):
            participantLease = lease
        case .incompatible(let incompatibility):
            handleInitializeIncompatibility(
                incompatibility,
                ownership: ownership,
                upstreamIndex: upstreamIndex,
                expectedUpstreamID: upstreamID
            )
            return
        }

        sendInitializedNotificationIfNeeded(
            upstreamIndex: upstreamIndex,
            expectedUpstreamID: upstreamID,
            initializeClaim: ownership.initializeClaim
        ) { [weak self] in
            guard let self else { return }
            var upstreamCommit: CommittedUpstreamInitialization?
            let transaction = self.initializeManager.finishInitializeParticipant {
                let committed = self.commitUpstreamInitialized(
                    upstreamIndex: upstreamIndex,
                    expectedUpstreamID: upstreamID,
                    ownership: ownership,
                    participantLease: participantLease
                )
                upstreamCommit = committed
                return committed.canonicalCommit
            }
            if let upstreamCommit {
                self.finishUpstreamInitialized(
                    upstreamIndex: upstreamIndex,
                    ownership: ownership,
                    committed: upstreamCommit
                )
            }
            switch transaction.commit {
            case .published:
                guard let completion = transaction.publication else { return }
                self.applyInitializePublication(
                    completion,
                    upstreamIndex: upstreamIndex
                )
            case .joined:
                self.upstreamSlotScheduler.wake()
            case .incompatible(let incompatibility):
                self.handleInitializeIncompatibility(
                    incompatibility,
                    ownership: ownership,
                    upstreamIndex: upstreamIndex,
                    expectedUpstreamID: upstreamID
                )
            case .stale:
                self.handleInitializeParticipantFailure(
                    participantLease,
                    ownership: ownership,
                    upstreamIndex: upstreamIndex,
                    expectedUpstreamID: upstreamID,
                    treatsAsPrimary: handlesPrimaryInitialize
                )
            }
        } onRejected: { [weak self] in
            guard let self else { return }
            self.handleInitializeParticipantFailure(
                participantLease,
                ownership: ownership,
                upstreamIndex: upstreamIndex,
                expectedUpstreamID: upstreamID,
                treatsAsPrimary: handlesPrimaryInitialize
            )
        }
    }

    func applyInitializePublication(
        _ completion: InitializeManager.SuccessCompletion,
        upstreamIndex: Int
    ) {
        completion.timeout?.cancel()
        completion.recoveryTimeout?.cancel()
        upstreamSlotScheduler.wake()
        if completion.shouldWarmSecondary {
            warmUpSecondaryUpstreams(excluding: upstreamIndex)
        }
        refreshToolsListIfNeeded()
        completePendingInitializes(
            completion.pending,
            result: completion.result,
            negotiatedProtocolVersion: Self.supportedProtocolVersion(
                fromInitializeResult: completion.result
            )
        )
    }

    func takeInitializeResponseOwnership(
        upstreamIndex: Int,
        upstreamID: Int64
    ) -> InitializeResponseOwnership? {
        guard let initializeClaim = upstreamHealthManager.currentInitializeClaim(
            upstreamIndex: upstreamIndex,
            expectedUpstreamID: upstreamID
        ), let topologyProof = initializeClaim.topologyProof,
        topologyProof.slotID.rawValue == upstreamIndex else { return nil }
        guard upstreamTopology.withValidated(topologyProof, {
            upstreamHealthManager.transferInitializeResponse(
                initializeClaim,
                expectedUpstreamID: upstreamID
            )
        }) == true else { return nil }
        return InitializeResponseOwnership(initializeClaim: initializeClaim)
    }

    func completePendingInitializes(
        _ pending: [InitializeManager.PendingInitialize],
        result: JSONValue,
        negotiatedProtocolVersion: String?
    ) {
        for item in pending {
            if sessionRegistry.sessionStillMatchesPendingInitialize(
                sessionID: item.sessionID,
                sessionGeneration: item.sessionGeneration
            ) {
                sessionRegistry.markInitialized(
                    id: item.sessionID,
                    negotiatedProtocolVersion: negotiatedProtocolVersion
                )
            }
            if let buffer = encodeInitializeResponse(
                originalID: item.originalID,
                result: result
            ) {
                item.eventLoop.execute {
                    item.promise.succeed(buffer)
                }
            } else {
                item.eventLoop.execute {
                    item.promise.fail(ControlPlane.Error.invalidResponse("invalid initialize response"))
                }
            }
        }
    }

    func encodeInitializeResponse(originalID: JSONRPC.ID, result: JSONValue) -> ByteBuffer? {
        guard let data = try? JSONRPC.Wire.resultResponseData(id: originalID, result: result) else {
            return nil
        }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    static func protocolVersion(fromInitializeResult result: JSONValue) -> String? {
        guard case .object(let object) = result,
              case .string(let version)? = object["protocolVersion"]
        else {
            return nil
        }
        return version
    }

    static func supportedProtocolVersion(fromInitializeResult result: JSONValue) -> String? {
        guard let version = protocolVersion(fromInitializeResult: result),
            MCP.ProtocolVersion.isSupported(version)
        else {
            return nil
        }
        return version
    }

    func handleUnsupportedInitializeProtocolVersion(
        _ result: JSONValue,
        upstreamIndex: Int,
        upstreamID: Int64,
        ownership: InitializeResponseOwnership,
        handlesPrimaryInitialize: Bool
    ) {
        let version = Self.protocolVersion(fromInitializeResult: result)
        let errorObject: [String: Any] = [
            "code": -32000,
            "message": "unsupported upstream protocol version",
            "data": [
                "protocolVersion": version as Any? ?? NSNull(),
                "supportedProtocolVersions": [MCP.ProtocolVersion.current],
            ],
        ]
        _ = clearUpstreamState(
            initializeClaim: ownership.initializeClaim,
            replacesInitializedChannel: false
        )
        noteIncompatibleUpstream(
            initializeClaim: ownership.initializeClaim,
            kind: "initialize",
            reason: "unsupported protocol version"
        )
        if handlesPrimaryInitialize {
            _ = initializeManager.releasePrimaryInitialize(
                upstreamIndex: upstreamIndex,
                upstreamID: upstreamID
            )
            if completePendingInitializesUsingCachedResultIfAvailable() {
                return
            }
            if canonicalHandshakeState.hasInitializeParticipants()
                || hasOtherInitializeRouteInFlight(excluding: upstreamIndex) {
                failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
                return
            }
            let didRetry = retryPrimaryInitializeOnAlternativeUpstream(
                failedUpstreamIndex: upstreamIndex,
                failedUpstreamID: nil,
                reason: "unsupported_initialize_protocol"
            )
            if didRetry {
                return
            }
            completeInitPendingWithError(errorObject)
        } else {
            failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
        }
    }

    func encodeInitializeErrorResponse(originalID: JSONRPC.ID, errorObject: [String: Any])
        -> ByteBuffer?
    {
        guard let error = JSONRPC.Wire.errorPayload(
            inResponseObject: ["error": errorObject]
        ),
            let data = try? JSONRPC.Wire.errorResponseData(
                id: originalID,
                code: error.code,
                message: error.message,
                data: error.data
            )
        else {
            return nil
        }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    func completeInitPendingWithError(_ errorObject: [String: Any]) {
        let result = initializeManager.completePrimaryInitializeFailure()
        guard let result else { return }
        cancelPrimaryInitializeReadinessWaiter()
        result.timeout?.cancel()
        result.recoveryTimeout?.cancel()
        clearFailedPrimaryInitializeChannel(result)
        for item in result.pending {
            removePendingInitializeSessionIfCurrent(item)
            if let buffer = encodeInitializeErrorResponse(
                originalID: item.originalID, errorObject: errorObject)
            {
                item.eventLoop.execute {
                    item.promise.succeed(buffer)
                }
            } else {
                item.eventLoop.execute {
                    item.promise.fail(ControlPlane.Error.invalidResponse("invalid initialize response"))
                }
            }
        }

        if result.shouldRetryEagerInitialize {
            startEagerInitializePrimary(applyBackoff: true)
        }
        failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
        testHooks.primaryInitializeFailureCleanupCompleted?(result.upstreamIndex)
    }

    func sendInitializedNotificationIfNeeded(
        upstreamIndex: Int,
        expectedUpstreamID: Int64,
        initializeClaim: UpstreamHealthManager.InitializeClaim,
        onAccepted: @escaping @Sendable () -> Void = {},
        onRejected: @escaping @Sendable () -> Void = {}
    ) {
        let shouldSend = upstreamHealthManager.shouldSendInitializedNotification(
            initializeClaim
        )
        guard shouldSend else {
            guard upstreamHealthManager.validate(initializeClaim) else {
                onRejected()
                return
            }
            onAccepted()
            return
        }

        let notification = JSONRPC.Wire.notificationObject(method: "notifications/initialized")
        guard let data = try? JSONRPC.Wire.data(from: notification) else {
            onRejected()
            return
        }

        guard let proof = initializeClaim.topologyProof,
              let operationLease = upstreamTopology.operationLease(for: proof) else {
            onRejected()
            return
        }
        addRuntimeTask { [weak self, operationLease] in
            guard let self,
                  self.upstreamHealthManager.validate(initializeClaim),
                  self.upstreamTopology.validate(operationLease) else {
                onRejected()
                return
            }
            let result = await operationLease.slot.send(data)
            if result == .accepted {
                guard self.upstreamTopology.withValidated(operationLease.proof, {
                    self.upstreamHealthManager.markInitializedNotificationSent(
                        initializeClaim,
                        expectedUpstreamID: expectedUpstreamID
                    )
                }) == true else {
                    onRejected()
                    return
                }
                self.recordTraffic(
                    upstreamIndex: upstreamIndex,
                    direction: "outbound",
                    data: data
                )
                onAccepted()
                return
            }
            onRejected()
        }
    }

    func handleInitializeParticipantFailure(
        _ participantLease: CanonicalHandshakeState.InitializeParticipantLease,
        ownership: InitializeResponseOwnership,
        upstreamIndex: Int,
        expectedUpstreamID: Int64,
        treatsAsPrimary: Bool
    ) {
        canonicalHandshakeState.cancelInitializeParticipant(participantLease)
        let cleared = clearUpstreamState(
            initializeClaim: ownership.initializeClaim,
        )
        guard cleared else { return }

        if completePendingInitializesUsingCachedResultIfAvailable() {
            retryInitializeAfterTerminalFailure(
                ownership: ownership,
                upstreamIndex: upstreamIndex
            )
            return
        }
        if treatsAsPrimary {
            initializeManager.rearmInitTimeoutForRetry { makeInitTimeout(id: $0) }?.cancel()
            _ = initializeManager.releasePrimaryInitialize(
                upstreamIndex: upstreamIndex,
                upstreamID: expectedUpstreamID
            )
        }
        retryInitializeAfterTerminalFailure(
            ownership: ownership,
            upstreamIndex: upstreamIndex
        )
        failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
    }

    func handleInitializeIncompatibility(
        _ incompatibility: CanonicalHandshakeState.Incompatibility,
        ownership: InitializeResponseOwnership,
        upstreamIndex: Int,
        expectedUpstreamID: Int64
    ) {
        _ = clearUpstreamState(
            initializeClaim: ownership.initializeClaim,
            replacesInitializedChannel: false
        )
        noteIncompatibleUpstream(
            initializeClaim: ownership.initializeClaim,
            kind: incompatibility.kind,
            reason: incompatibility.reason
        )
        _ = initializeManager.releasePrimaryInitialize(
            upstreamIndex: upstreamIndex,
            upstreamID: expectedUpstreamID
        )
        _ = completePendingInitializesUsingCachedResultIfAvailable()
        failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
    }

    @discardableResult
    func completePendingInitializesUsingCachedResultIfAvailable() -> Bool {
        guard let completion = initializeManager.finishPrimaryInitializeUsingCachedResult()
        else { return false }
        completion.timeout?.cancel()
        completion.recoveryTimeout?.cancel()
        completePendingInitializes(
            completion.pending,
            result: completion.result,
            negotiatedProtocolVersion: Self.supportedProtocolVersion(
                fromInitializeResult: completion.result
            )
        )
        return true
    }

    private func retryInitializeAfterTerminalFailure(
        ownership: InitializeResponseOwnership,
        upstreamIndex: Int,
        reason: String = "initialize_response_failed"
    ) {
        startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
    }

    private func hasOtherInitializeRouteInFlight(excluding upstreamIndex: Int) -> Bool {
        upstreamSlotIDs.map(\.rawValue).contains { candidate in
            guard candidate != upstreamIndex else { return false }
            return upstreamHealthManager.state(
                for: UpstreamSlotID(rawValue: candidate)
            )?.initInFlight == true
        }
    }

    func makeInitTimeout(id: UUID) -> RuntimeScheduledTimeout? {
        guard
            let timeoutAmount = MCP.MethodDispatcher.timeoutForInitialize(
                defaultSeconds: config.requestTimeout)
        else {
            return nil
        }
        return scheduleRuntimeTimeout(timeoutAmount) { [weak self] in
            guard let self else { return }
            self.failInitPending(error: TimeoutError(), timeoutID: id)
        }
    }

    func scheduleInitTimeout() {
        initializeManager.replaceInitTimeout { makeInitTimeout(id: $0) }?.cancel()
    }

    func failInitPending(error: Error, timeoutID: UUID? = nil) {
        let result = initializeManager.completePrimaryInitializeFailure(timeoutID: timeoutID)
        guard let result else { return }
        cancelPrimaryInitializeReadinessWaiter()
        result.timeout?.cancel()
        result.recoveryTimeout?.cancel()
        clearFailedPrimaryInitializeChannel(result)
        for item in result.pending {
            removePendingInitializeSessionIfCurrent(item)
            item.eventLoop.execute {
                item.promise.fail(error)
            }
        }

        if result.shouldRetryEagerInitialize {
            startEagerInitializePrimary(applyBackoff: true)
        }
        failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
        testHooks.primaryInitializeFailureCleanupCompleted?(result.upstreamIndex)
    }

    private func clearFailedPrimaryInitializeChannel(
        _ result: InitializeManager.FailureResult
    ) {
        guard let upstreamIndex = result.upstreamIndex,
              let upstreamID = result.upstreamID else { return }
        if let claim = upstreamHealthManager.currentInitializeClaim(
            upstreamIndex: upstreamIndex,
            expectedUpstreamID: upstreamID
        ) {
            _ = clearUpstreamState(
                initializeClaim: claim,
            )
        }
    }

    func removePendingInitializeSessionIfCurrent(
        _ item: InitializeManager.PendingInitialize
    ) {
        guard sessionRegistry.sessionStillMatchesPendingInitialize(
            sessionID: item.sessionID,
            sessionGeneration: item.sessionGeneration
        ) else {
            return
        }
        _ = sessionRegistry.removeSession(id: item.sessionID)
    }

    @discardableResult
    func clearUpstreamState(
        proof: UpstreamTopologyProof,
        expectedUpstreamID: Int64? = nil,
    ) -> Bool {
        clearUpstreamStateReturningDetachedState(
            proof: proof,
            expectedUpstreamID: expectedUpstreamID,
        ) != nil
    }

    func clearUpstreamStateReturningDetachedState(
        proof: UpstreamTopologyProof,
        expectedUpstreamID: Int64? = nil,
    ) -> UpstreamHealthManager.ClearedUpstreamState? {
        var cleared: UpstreamHealthManager.ClearedUpstreamState?
        var catalogTransitions: [CatalogTransition] = []
        let eligibility = initializeManager.finishSupportEligibilityUpdate {
            var update: CanonicalHandshakeState.SupportEligibilityUpdate?
            guard upstreamTopology.withValidatedSnapshot(proof, { topologySnapshot in
                guard let result = upstreamHealthManager.clearUpstreamState(
                    proof,
                    expectedUpstreamID: expectedUpstreamID
                ) else { return false }
                cleared = result
                update = commitSupportEligibilityAfterHealthMutation(
                    topologySnapshot: topologySnapshot,
                    detachedProof: proof,
                    catalogTransitions: &catalogTransitions
                )
                return true
            }) == true else { return nil }
            return update
        }
        guard let cleared, let eligibility else { return nil }
        catalogTransitions.forEach(applyCatalogTransition)
        applySupportEligibilityCompletion(eligibility)
        finishClearingUpstreamState(
            proof: proof,
            cleared: cleared,
        )
        return cleared
    }

    @discardableResult
    func clearUpstreamState(
        initializeClaim: UpstreamHealthManager.InitializeClaim,
        replacesInitializedChannel: Bool = true
    ) -> Bool {
        clearUpstreamState(
            initializeClaim: initializeClaim,
            replacesInitializedChannel: replacesInitializedChannel,
            clearClaim: upstreamHealthManager.clearInitializeClaim
        )
    }

    @discardableResult
    func timeoutUpstreamInitialize(
        initializeClaim: UpstreamHealthManager.InitializeClaim,
        replacesInitializedChannel: Bool = true
    ) -> Bool {
        clearUpstreamState(
            initializeClaim: initializeClaim,
            replacesInitializedChannel: replacesInitializedChannel,
            clearClaim: upstreamHealthManager.timeoutInitializeClaim
        )
    }

    private func clearUpstreamState(
        initializeClaim: UpstreamHealthManager.InitializeClaim,
        replacesInitializedChannel: Bool,
        clearClaim: (UpstreamHealthManager.InitializeClaim)
            -> UpstreamHealthManager.ClearedUpstreamState?
    ) -> Bool {
        guard let proof = initializeClaim.topologyProof else { return false }
        var cleared: UpstreamHealthManager.ClearedUpstreamState?
        var catalogTransitions: [CatalogTransition] = []
        let eligibility = initializeManager.finishSupportEligibilityUpdate {
            var update: CanonicalHandshakeState.SupportEligibilityUpdate?
            guard upstreamTopology.withValidatedSnapshot(proof, { topologySnapshot in
                guard let result = clearClaim(initializeClaim) else { return false }
                cleared = result
                update = commitSupportEligibilityAfterHealthMutation(
                    topologySnapshot: topologySnapshot,
                    detachedProof: proof,
                    catalogTransitions: &catalogTransitions
                )
                return true
            }) == true else { return nil }
            return update
        }
        guard let cleared, let eligibility else { return false }
        catalogTransitions.forEach(applyCatalogTransition)
        applySupportEligibilityCompletion(eligibility)
        finishClearingUpstreamState(
            proof: proof,
            cleared: cleared,
        )
        if replacesInitializedChannel,
           (cleared.didReceiveInitializeResponse || cleared.didSendInitialized) {
            replaceOrRetireInitializeChannel(initializeClaim)
        }
        return true
    }

    func finishClearingUpstreamState(
        proof: UpstreamTopologyProof,
        cleared: UpstreamHealthManager.ClearedUpstreamState,
    ) {
        let upstreamIndex = proof.slotID.rawValue
        cleared.timeout?.cancel()
        if let initUpstreamID = cleared.initUpstreamID {
            upstreamRouter.remove(
                proof: proof,
                upstreamID: initUpstreamID
            )
        }
        debugRecorder.resetUpstream(upstreamIndex)
    }

    func commitSupportEligibilityAfterHealthMutation(
        topologySnapshot: UpstreamTopologyAuthority.Snapshot,
        detachedProof: UpstreamTopologyProof?,
        catalogTransitions: inout [CatalogTransition]
    ) -> CanonicalHandshakeState.SupportEligibilityUpdate {
        let authoritativeProofs = Set(topologySnapshot.entries.map { $0.operationLease.proof })
        return upstreamHealthManager.withUsableInitializedTopologyProofs(
            retaining: authoritativeProofs
        ) { healthUsableProofs in
            let update: CanonicalHandshakeState.SupportEligibilityUpdate
            if let detachedProof {
                update = canonicalHandshakeState.removeInitializeParticipantAndSupporter(
                    sourceProof: detachedProof,
                    retaining: healthUsableProofs
                )
            } else {
                update = canonicalHandshakeState.updateSupportEligibility(
                    retaining: healthUsableProofs
                )
            }
            catalogTransitions = update.newlyIneligibleProofs.map { toolsCatalog.invalidate(sourceProof: $0) }
            if let detachedProof, !update.newlyIneligibleProofs.contains(detachedProof) {
                catalogTransitions.append(toolsCatalog.invalidate(sourceProof: detachedProof))
            }
            return update
        }
    }

    func applySupportEligibilityCompletion(
        _ completion: InitializeManager.SupportEligibilityCompletion
    ) {
        if let publication = completion.publication {
            publication.timeout?.cancel()
            publication.recoveryTimeout?.cancel()
            upstreamSlotScheduler.wake()
            completePendingInitializes(
                publication.pending,
                result: publication.result,
                negotiatedProtocolVersion: Self.supportedProtocolVersion(
                    fromInitializeResult: publication.result
                )
            )
        }
        guard completion.update.newlyEligibleProofs.isEmpty == false else { return }
        upstreamSlotScheduler.wake()
        refreshToolsListIfNeeded()
    }

    func commitUpstreamInitialized(
        upstreamIndex: Int,
        expectedUpstreamID: Int64,
        ownership: InitializeResponseOwnership,
        participantLease: CanonicalHandshakeState.InitializeParticipantLease
    ) -> CommittedUpstreamInitialization {
        let initializeClaim = ownership.initializeClaim
        guard let proof = initializeClaim.topologyProof,
              proof == participantLease.topologyProof else {
            canonicalHandshakeState.cancelInitializeParticipant(participantLease)
            return CommittedUpstreamInitialization(
                canonicalCommit: .stale,
                healthTransition: nil
            )
        }
        var healthResult: UpstreamHealthManager.MarkInitializedTransition?
        var initializeCommit: CanonicalHandshakeState.InitializeCommit = .stale
        guard upstreamTopology.withValidated(proof, {
            healthResult = upstreamHealthManager.markInitialized(
                initializeClaim,
                expectedUpstreamID: expectedUpstreamID,
                commit: {
                    initializeCommit = canonicalHandshakeState
                        .commitInitializeParticipant(participantLease)
                    return initializeCommit.isAccepted
                }
            )
            return healthResult != nil
        }) == true, let result = healthResult else {
            canonicalHandshakeState.cancelInitializeParticipant(participantLease)
            return CommittedUpstreamInitialization(
                canonicalCommit: initializeCommit,
                healthTransition: nil
            )
        }
        return CommittedUpstreamInitialization(
            canonicalCommit: initializeCommit,
            healthTransition: result
        )
    }

    func finishUpstreamInitialized(
        upstreamIndex: Int,
        ownership: InitializeResponseOwnership,
        committed: CommittedUpstreamInitialization
    ) {
        guard committed.canonicalCommit.isAccepted,
              let healthTransition = committed.healthTransition else { return }
        healthTransition.timeout?.cancel()
        testHooks.upstreamInitialized?(upstreamIndex)
        noteUpstreamInitializationSucceeded()
        catalogChangedSink?()
    }

    func warmUpSecondaryUpstreams(excluding primaryUpstreamIndex: Int? = nil) {
        let resolvedPrimaryUpstreamIndex = primaryUpstreamIndex ?? currentPrimaryInitializeUpstreamIndex()
        for upstreamIndex in upstreamSlotIDs.map(\.rawValue) where upstreamIndex != resolvedPrimaryUpstreamIndex {
            startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
        }
    }

    func startPrimaryEagerRetry() {
        startEagerInitializePrimary(applyBackoff: true)
    }

    func makeInternalInitializeRequest(id: Int64) -> [String: Any] {
        JSONRPC.Wire.requestObject(
            id: id,
            method: "initialize",
            params: .object(
                InitializeHandshakeJSON.resolved(
                    initializeParamsOverride: initializeParamsOverride
                )
            )
        )
    }
}
