import Foundation
import NIO
import XcodeMCPKit

extension RuntimeCoordinator {
    struct InitializeResponseOwnership: Sendable {
        let initializeClaim: UpstreamHealthManager.InitializeClaim
    }

    enum CanonicalInitializeAuthorization: Sendable {
        case publish(
            result: JSONValue,
            lease: CanonicalHandshakeState.InitializePublicationLease
        )
        case join(CanonicalHandshakeState.InitializeJoinLease)
    }

    func startEagerInitializePrimary(applyBackoff: Bool = false) {
        guard let upstreamIndex = primaryInitializeUpstreamIndex() else {
            if startXcodeProcessDiscoveryWhenReadyForPrimaryInitialize(
                applyBackoff: applyBackoff
            ) {
                return
            }
            failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
            return
        }
        runWhenUpstreamReady(
            reason: "primary_initialize",
            applyBackoff: applyBackoff
        ) { [weak self, upstreamIndex, applyBackoff] in
            guard let self else { return }
            guard self.isActiveProcessBoundUpstream(upstreamIndex) else {
                self.startEagerInitializePrimary(applyBackoff: applyBackoff)
                return
            }
            self.startEagerInitializePrimaryWhenReady(upstreamIndex: upstreamIndex)
        }
    }

    @discardableResult
    private func startXcodeProcessDiscoveryWhenReadyForPrimaryInitialize(
        applyBackoff: Bool
    ) -> Bool {
        guard processRoutingEnabled,
              xcodeTargetDiscovery != nil,
              xcodeProcessRoutes.isEmpty,
              upstreamReadinessGate.isEnabled
        else {
            return false
        }
        runWhenUpstreamReady(
            reason: "primary_initialize_process_discovery",
            applyBackoff: applyBackoff
        ) { [weak self] in
            self?.triggerXcodeProcessReconcile(reason: "primary_initialize_readiness")
        }
        return true
    }

    private func startEagerInitializePrimaryWhenReady(upstreamIndex: Int) {
        guard processRouteActivationOwnsPrimaryInitialize(
            upstreamIndex: upstreamIndex
        ) == false else { return }
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
        if processRouteActivationOwnsPrimaryInitialize(upstreamIndex: upstreamIndex) {
            _ = initializeManager.yieldPrimaryInitializeToRouteActivation(
                upstreamIndex: upstreamIndex
            )
            return
        }
        guard let initializeClaim = upstreamHealthManager.claimWarmInitialize(
            upstreamIndex: upstreamIndex
        ), let proof = initializeClaim.topologyProof,
           let operationLease = upstreamTopology.operationLease(for: proof),
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
            _ = initializeManager.yieldPrimaryInitializeToRouteActivation(
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
                admission: nil,
                onRejected: { [weak self] in
                    self?.clearUpstreamState(initializeClaim: initializeClaim)
                }
            )
        } else {
            failInitPending(error: TimeoutError())
        }
    }

    func primaryInitializeUpstreamIndex(excluding excludedUpstreamIndices: Set<Int> = []) -> Int? {
        guard processRoutingEnabled else {
            return excludedUpstreamIndices.contains(0) ? nil : 0
        }

        let unavailable = unavailableXcodeProcessIDs()
        for route in xcodeProcessRoutes {
            guard unavailable.contains(route.target.processID) == false else {
                continue
            }
            if let upstreamIndex = primaryInitializeCandidate(
                in: route,
                excluding: excludedUpstreamIndices
            ) {
                return upstreamIndex
            }
        }
        return nil
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

    private func primaryInitializeCandidate(
        in route: XcodeProcessRoute,
        excluding excludedUpstreamIndices: Set<Int>
    ) -> Int? {
        return route.upstreamIndices.first { upstreamIndex in
            guard excludedUpstreamIndices.contains(upstreamIndex) == false,
                  let state = upstreamHealthManager.state(
                      for: UpstreamSlotID(rawValue: upstreamIndex)
                  ) else { return false }
            guard state.initInFlight == false,
                  state.isInitialized == false else {
                return false
            }
            switch state.healthState {
            case .healthy, .degraded:
                return true
            case .quarantined:
                return false
            }
        }
    }

    private func primaryInitializeRetryUpstreamIndex(failedUpstreamIndex: Int) -> Int? {
        let excludedUpstreamIndices: Set<Int> = [failedUpstreamIndex]
        if let failedRoute = xcodeProcessRoute(forUpstreamIndex: failedUpstreamIndex),
           let siblingUpstreamIndex = primaryInitializeCandidate(
               in: failedRoute,
               excluding: excludedUpstreamIndices
           )
        {
            return siblingUpstreamIndex
        }
        return primaryInitializeUpstreamIndex(excluding: excludedUpstreamIndices)
    }

    func retryPrimaryInitializeOnAlternativeUpstream(
        failedUpstreamIndex: Int,
        failedUpstreamID: Int64?,
        reason: String
    ) -> Bool {
        guard processRoutingEnabled else {
            return false
        }
        guard let retryUpstreamIndex = primaryInitializeRetryUpstreamIndex(
            failedUpstreamIndex: failedUpstreamIndex
        ) else {
            markXcodeProcessRouteUnavailable(upstreamIndex: failedUpstreamIndex, reason: reason)
            return false
        }
        let failedProcessID = xcodeProcessRoute(forUpstreamIndex: failedUpstreamIndex)?.target.processID
        let retryProcessID = xcodeProcessRoute(forUpstreamIndex: retryUpstreamIndex)?.target.processID
        if failedProcessID == retryProcessID {
            markXcodeProcessRouteAvailable(upstreamIndex: retryUpstreamIndex)
        } else {
            markXcodeProcessRouteUnavailable(upstreamIndex: failedUpstreamIndex, reason: reason)
        }
        if let failedUpstreamID {
            if let claim = upstreamHealthManager.currentInitializeClaim(
                upstreamIndex: failedUpstreamIndex,
                expectedUpstreamID: failedUpstreamID
            ) {
                _ = clearUpstreamState(
                    initializeClaim: claim,
                    resetsProcessRouteActivation: false
                )
            }
        }
        initializeManager.reopenPrimaryInitializeForRetry()
        guard initializeManager.preparePrimaryInitializeRetry(upstreamIndex: retryUpstreamIndex)
        else {
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
            processRoutingEnabled
            && isPrimaryInitialize == false
            && activePrimaryInitializeUpstreamIndex == nil
            && canonicalHandshakeState.initializeResult() == nil
        let handlesPrimaryInitialize = isPrimaryInitialize
            || canPromoteWarmInitializeToPrimary
            || (
                !processRoutingEnabled
                    && isCurrentPrimaryInitializeUpstream(upstreamIndex)
                    && activePrimaryInitializeUpstreamIndex == nil
            )

        guard let resultValue = object["result"], let result = JSONValue(any: resultValue) else {
            _ = clearUpstreamState(
                initializeClaim: ownership.initializeClaim,
                resetsProcessRouteActivation: false
            )
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
                    failInitPending(error: TimeoutError())
                }
            } else {
                failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
            }
            return
        }

        guard let negotiatedProtocolVersion = Self.supportedProtocolVersion(
            fromInitializeResult: result
        ) else {
            handleUnsupportedInitializeProtocolVersion(
                result,
                upstreamIndex: upstreamIndex,
                upstreamID: upstreamID,
                ownership: ownership,
                handlesPrimaryInitialize: handlesPrimaryInitialize
            )
            return
        }

        guard let update = initializeManager.preparePrimaryInitializeSuccess(
            upstreamIndex: upstreamIndex,
            upstreamID: upstreamID,
            allowsPromotion: handlesPrimaryInitialize
        ) else {
            guard let joinLease = canonicalHandshakeState.prepareInitializeJoin(
                expectedResult: result
            ) else {
                if let canonicalInitialize = canonicalHandshakeState.initializeResult(),
                   !initializeResultsEquivalent(canonicalInitialize, result) {
                    _ = clearUpstreamState(
                        initializeClaim: ownership.initializeClaim,
                        resetsProcessRouteActivation: false
                    )
                    noteIncompatibleUpstream(
                        initializeClaim: ownership.initializeClaim,
                        kind: "initialize",
                        reason: "initialize.result mismatch"
                    )
                    failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
                } else {
                    rejectInitializeResponseOwnership(
                        ownership,
                        upstreamIndex: upstreamIndex,
                        expectedUpstreamID: upstreamID,
                        treatsAsPrimary: false
                    )
                }
                return
            }
            sendInitializedNotificationIfNeeded(
                upstreamIndex: upstreamIndex,
                expectedUpstreamID: upstreamID,
                initializeClaim: ownership.initializeClaim
            ) { [weak self] in
                guard let self else { return }
                guard self.markUpstreamInitialized(
                    upstreamIndex: upstreamIndex,
                    expectedUpstreamID: upstreamID,
                    ownership: ownership,
                    canonicalAuthorization: .join(joinLease)
                ) else {
                    self.recoverFromInitializedNotificationFailure(
                        upstreamIndex: upstreamIndex,
                        treatsAsPrimary: false
                    )
                    return
                }
                self.upstreamSlotScheduler.wake()
                self.refreshPendingProcessToolsCatalogAfterWarmInitialize(
                    upstreamIndex: upstreamIndex
                )
            } onRejected: { [weak self] in
                self?.rejectInitializeResponseOwnership(
                    ownership,
                    upstreamIndex: upstreamIndex,
                    expectedUpstreamID: upstreamID,
                    treatsAsPrimary: false
                )
            }
            return
        }

        sendInitializedNotificationIfNeeded(
            upstreamIndex: upstreamIndex,
            expectedUpstreamID: upstreamID,
            initializeClaim: ownership.initializeClaim
        ) { [weak self] in
            guard let self else { return }
            guard let completion = self.initializeManager.finishPrimaryInitializeSuccess(
                update.lease,
                commit: {
                    self.markUpstreamInitialized(
                        upstreamIndex: upstreamIndex,
                        expectedUpstreamID: upstreamID,
                        ownership: ownership,
                        canonicalAuthorization: .publish(
                            result: result,
                            lease: update.publicationLease
                        )
                    )
                }
            ) else {
                guard self.initializeManager.cancelPrimaryInitializeSuccess(
                    update.lease
                ) else { return }
                self.initializeManager.reopenPrimaryInitializeForRetry()
                self.rejectInitializeResponseOwnership(
                    ownership,
                    upstreamIndex: upstreamIndex,
                    expectedUpstreamID: upstreamID,
                    treatsAsPrimary: true
                )
                return
            }
            completion.timeout?.cancel()
            self.upstreamSlotScheduler.wake()
            if update.shouldWarmSecondary {
                self.initializeManager.markSecondaryWarmupStarted()
                self.warmUpSecondaryUpstreams(excluding: upstreamIndex)
            }
            self.refreshToolsListIfNeeded()
            self.completePendingInitializes(
                completion.pending,
                result: result,
                negotiatedProtocolVersion: negotiatedProtocolVersion
            )
        } onRejected: { [weak self] in
            guard let self else { return }
            if self.isCurrentPrimaryInitializeUpstream(upstreamIndex),
                self.hasUsableInitializedSecondaryUpstreams(excluding: upstreamIndex),
                let completion = self.initializeManager.finishPrimaryInitializeUsingCachedResult()
            {
                completion.timeout?.cancel()
                self.completePendingInitializes(
                    completion.pending,
                    result: completion.result,
                    negotiatedProtocolVersion: Self.supportedProtocolVersion(
                        fromInitializeResult: completion.result
                    )
                )
                self.rejectInitializeResponseOwnership(
                    ownership,
                    upstreamIndex: upstreamIndex,
                    expectedUpstreamID: upstreamID,
                    treatsAsPrimary: true
                )
                return
            }
            guard self.initializeManager.cancelPrimaryInitializeSuccess(
                update.lease
            ) else { return }
            self.initializeManager.reopenPrimaryInitializeForRetry()
            self.rejectInitializeResponseOwnership(
                ownership,
                upstreamIndex: upstreamIndex,
                expectedUpstreamID: upstreamID,
                treatsAsPrimary: true
            )
        }
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
                    negotiatedProtocolVersion: negotiatedProtocolVersion,
                    buffersUnmappedNotificationsUntilClientConnects: true
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
                    item.promise.fail(TimeoutError())
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
            resetsProcessRouteActivation: false
        )
        if handlesPrimaryInitialize {
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
            noteIncompatibleUpstream(
                initializeClaim: ownership.initializeClaim,
                kind: "initialize",
                reason: "unsupported protocol version"
            )
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
                    item.promise.fail(TimeoutError())
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

    func rejectInitializeResponseOwnership(
        _ ownership: InitializeResponseOwnership,
        upstreamIndex: Int,
        expectedUpstreamID: Int64,
        treatsAsPrimary: Bool
    ) {
        _ = expectedUpstreamID
        guard clearUpstreamState(
            initializeClaim: ownership.initializeClaim,
            resetsProcessRouteActivation: false
        ) else { return }
        recoverFromInitializedNotificationFailure(
            upstreamIndex: upstreamIndex,
            treatsAsPrimary: treatsAsPrimary
        )
    }

    func recoverFromInitializedNotificationFailure(
        upstreamIndex: Int,
        treatsAsPrimary: Bool
    ) {
        let handlesPrimaryInitialize = treatsAsPrimary || isCurrentPrimaryInitializeUpstream(upstreamIndex)
        let hasHealthySecondary = handlesPrimaryInitialize
            && hasUsableInitializedSecondaryUpstreams(excluding: upstreamIndex)
        if processControlPlane.canonicalSourceUpstream() == upstreamIndex && !hasHealthySecondary {
            invalidateControlPlane(
                reason: "initialized_notification_overload_\(upstreamIndex)",
                clearInitialize: false,
                clearToolsCatalog: true
            )
        }
        if handlesPrimaryInitialize {
            // A retry that still owns unresolved pending initializes gets a
            // fresh full timeout window, replacing the still-armed previous
            // timeout (never disarm first) so the pending promises stay
            // timeout-guarded at every instant. A retry with no waiters
            // drops the armed timeout instead of re-arming it.
            initializeManager.rearmInitTimeoutForRetry { makeInitTimeout() }?.cancel()
            if hasHealthySecondary {
                initializeManager.setWarmInitRecoveryIntent(.retryPrimaryWhenNoCachedInitialize)
                startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
            } else {
                resetSecondaryUpstreamsForPrimaryRetry(excluding: upstreamIndex)
                startPrimaryEagerRetry(failedPrimaryUpstreamIndex: upstreamIndex)
            }
        } else {
            startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
        }
        failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
    }

    func makeInitTimeout() -> RuntimeScheduledTimeout? {
        guard
            let timeoutAmount = MCP.MethodDispatcher.timeoutForInitialize(
                defaultSeconds: config.requestTimeout)
        else {
            return nil
        }
        return scheduleRuntimeTimeout(timeoutAmount) { [weak self] in
            guard let self else { return }
            self.failInitPending(error: TimeoutError())
        }
    }

    func scheduleInitTimeout() {
        guard let timeout = makeInitTimeout() else {
            return
        }
        let previous = initializeManager.replaceInitTimeout(timeout)
        previous?.cancel()
    }

    func failInitPending(error: Error) {
        let result = initializeManager.completePrimaryInitializeFailure()
        guard let result else { return }
        cancelPrimaryInitializeReadinessWaiter()
        result.timeout?.cancel()
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
                resetsProcessRouteActivation: false
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
        let context = sessionRegistry.removeSession(id: item.sessionID)
        context?.notificationHub.closeAll()
    }

    @discardableResult
    func clearUpstreamState(
        proof: UpstreamTopologyProof,
        expectedUpstreamID: Int64? = nil,
        resetsProcessRouteActivation: Bool = true
    ) -> Bool {
        guard let cleared = upstreamHealthManager.clearUpstreamState(
            proof,
            expectedUpstreamID: expectedUpstreamID
        ) else { return false }
        finishClearingUpstreamState(
            proof: proof,
            cleared: cleared,
            resetsProcessRouteActivation: resetsProcessRouteActivation
        )
        return true
    }

    @discardableResult
    func clearUpstreamState(
        initializeClaim: UpstreamHealthManager.InitializeClaim,
        resetsProcessRouteActivation: Bool = true,
        replacesInitializedChannel: Bool = true
    ) -> Bool {
        guard let proof = initializeClaim.topologyProof,
              let cleared = upstreamHealthManager.clearInitializeClaim(initializeClaim) else {
            return false
        }
        finishClearingUpstreamState(
            proof: proof,
            cleared: cleared,
            resetsProcessRouteActivation: resetsProcessRouteActivation
        )
        if replacesInitializedChannel,
           (cleared.didReceiveInitializeResponse || cleared.didSendInitialized) {
            replaceOrRetireInitializeChannel(initializeClaim)
        }
        return true
    }

    func finishClearingUpstreamState(
        proof: UpstreamTopologyProof,
        cleared: (
            timeout: RuntimeScheduledTimeout?,
            initUpstreamID: Int64?,
            didReceiveInitializeResponse: Bool,
            didSendInitialized: Bool
        ),
        resetsProcessRouteActivation: Bool
    ) {
        let upstreamIndex = proof.slotID.rawValue
        canonicalHandshakeState.invalidateInitializePublication(
            sourceUpstream: upstreamIndex
        )
        cleared.timeout?.cancel()
        if let initUpstreamID = cleared.initUpstreamID {
            upstreamRouter.remove(
                proof: proof,
                upstreamID: initUpstreamID
            )
        }
        if resetsProcessRouteActivation {
            resetProcessRouteActivationIfClearingPreCatalogUpstream(
                upstreamIndex: upstreamIndex
            )
        }
        debugRecorder.resetUpstream(upstreamIndex)
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex) else {
            removeXcodeWindowOwners(forUpstreamIndex: upstreamIndex)
            return
        }
        if let replacementUpstreamIndex = firstUsableInitializedUpstreamIndex(in: route),
           let replacementProof = upstreamHealthManager.topologyProof(
               for: replacementUpstreamIndex
           ),
           let transition = upstreamTopology.withValidated(replacementProof, {
               processControlPlane.rebindCatalogSource(
                    processID: route.target.processID,
                    from: proof,
                    to: replacementProof
                )
           }) {
            applyProcessControlPlaneTransition(transition)
            return
        }
        applyProcessControlPlaneTransition(
            processControlPlane.invalidateCatalogSource(
                processID: route.target.processID,
                source: proof
            )
        )
        removeXcodeWindowOwners(forUpstreamIndex: upstreamIndex)
    }

    @discardableResult
    func markUpstreamInitialized(
        upstreamIndex: Int,
        expectedUpstreamID: Int64,
        ownership: InitializeResponseOwnership,
        canonicalAuthorization: CanonicalInitializeAuthorization
    ) -> Bool {
        let initializeClaim = ownership.initializeClaim
        guard let proof = initializeClaim.topologyProof else { return false }
        var healthResult: UpstreamHealthManager.MarkInitializedTransition?
        guard upstreamTopology.withValidated(proof, {
            healthResult = upstreamHealthManager.markInitialized(
                initializeClaim,
                expectedUpstreamID: expectedUpstreamID,
                commit: {
                switch canonicalAuthorization {
                case .publish(let canonicalResult, let publicationLease):
                    return canonicalHandshakeState.publishCanonicalInitialize(
                        canonicalResult,
                        lease: publicationLease
                    ) != nil
                case .join(let joinLease):
                    return canonicalHandshakeState.validateInitializeJoin(joinLease)
                }
                }
            )
            return healthResult != nil
        }) == true, let result = healthResult else {
            if case .publish(_, let publicationLease) = canonicalAuthorization {
                canonicalHandshakeState.cancelInitializePublication(publicationLease)
            }
            clearUpstreamState(
                initializeClaim: initializeClaim,
                resetsProcessRouteActivation: false
            )
            return false
        }
        result.timeout?.cancel()
        markXcodeProcessRouteAvailable(upstreamIndex: upstreamIndex)
        if ownership.initializeClaim.owner == .processRouteActivation {
            finishProcessRouteActivationChannelInitialized(
                upstreamIndex: upstreamIndex,
                initializeClaim: initializeClaim
            )
        }
        testHooks.upstreamInitialized?(upstreamIndex)
        noteUpstreamInitializationSucceeded()
        return true
    }

    func warmUpSecondaryUpstreams(excluding primaryUpstreamIndex: Int? = nil) {
        let resolvedPrimaryUpstreamIndex = primaryUpstreamIndex ?? currentPrimaryInitializeUpstreamIndex()
        for upstreamIndex in secondaryUpstreamIndices(excluding: resolvedPrimaryUpstreamIndex) {
            startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
        }
    }

    func resetSecondaryUpstreamsForPrimaryRetry(excluding primaryUpstreamIndex: Int? = nil) {
        let resolvedPrimaryUpstreamIndex = primaryUpstreamIndex ?? currentPrimaryInitializeUpstreamIndex()
        for upstreamIndex in secondaryUpstreamIndices(excluding: resolvedPrimaryUpstreamIndex) {
            guard let proof = upstreamTopology.operationLease(
                for: UpstreamSlotID(rawValue: upstreamIndex)
            )?.proof else { continue }
            clearUpstreamState(proof: proof)
        }
    }

    func startPrimaryEagerRetry(failedPrimaryUpstreamIndex: Int? = nil) {
        let upstreamIndex = failedPrimaryUpstreamIndex ?? currentPrimaryInitializeUpstreamIndex()
        if let proof = upstreamTopology.operationLease(
            for: UpstreamSlotID(rawValue: upstreamIndex)
        )?.proof {
            clearUpstreamState(proof: proof)
        }
        initializeManager.resetWarmSecondaryForRetry()
        invalidateControlPlane(
            reason: "primary_eager_retry",
            clearInitialize: true,
            clearToolsCatalog: true
        )
        startEagerInitializePrimary(applyBackoff: true)
    }

    func hasUsableInitializedSecondaryUpstreams(excluding primaryUpstreamIndex: Int? = nil) -> Bool {
        let resolvedPrimaryUpstreamIndex = primaryUpstreamIndex ?? currentPrimaryInitializeUpstreamIndex()
        return secondaryUpstreamIndices(excluding: resolvedPrimaryUpstreamIndex).contains { upstreamIndex in
            guard let upstream = upstreamHealthManager.state(
                for: UpstreamSlotID(rawValue: upstreamIndex)
            ) else { return false }
            guard upstream.isInitialized else { return false }
            switch upstream.healthState {
            case .healthy, .degraded:
                return true
            case .quarantined:
                return false
            }
        }
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
