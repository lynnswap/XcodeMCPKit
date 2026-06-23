import Foundation
import NIO
import ProxySessionControlPlane
import ProxySessionUpstream
import ProxyCore
import ProxyMCP

extension RuntimeCoordinator {
    func startEagerInitializePrimary(applyBackoff: Bool = false) {
        guard let upstreamIndex = primaryInitializeUpstreamIndex() else {
            failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
            return
        }
        runWhenUpstreamReady(
            reason: "primary_initialize",
            applyBackoff: applyBackoff
        ) { [weak self, upstreamIndex] in
            guard let self else { return }
            self.startUpstreamSlot(upstreamIndex)
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
            guard let upstreamIndex = self.initializeManager.pendingPrimaryInitializeUpstreamIndex()
            else {
                return
            }
            self.startUpstreamSlot(upstreamIndex)
            self.sendPrimaryInitializeRequestIfStillPending()
        }
    }

    private func sendPrimaryInitializeRequestIfStillPending() {
        guard let upstreamIndex = initializeManager.pendingPrimaryInitializeUpstreamIndex() else {
            return
        }
        let upstreamID = upstreamRouter.assignInitialize(upstreamIndex: upstreamIndex)
        guard initializeManager.beginPrimaryInitializeSend(
            upstreamIndex: upstreamIndex,
            upstreamID: upstreamID
        ) else {
            upstreamRouter.remove(upstreamIndex: upstreamIndex, upstreamID: upstreamID)
            return
        }
        markUpstreamInitInFlight(upstreamIndex: upstreamIndex, upstreamID: upstreamID)

        let request = makeInternalInitializeRequest(id: upstreamID)
        if let data = try? JSONSerialization.data(withJSONObject: request, options: []) {
            sendUpstream(data, upstreamIndex: upstreamIndex, ensureRunning: true)
        } else {
            failInitPending(error: TimeoutError())
        }
    }

    func primaryInitializeUpstreamIndex(excluding excludedUpstreamIndices: Set<Int> = []) -> Int? {
        guard xcodeProcessRoutes.isEmpty == false else {
            return excludedUpstreamIndices.contains(0) ? nil : 0
        }

        let unavailable = unavailableXcodeProcessIDs()
        for route in xcodeProcessRoutes {
            guard let upstreamIndex = route.primaryUpstreamIndex,
                  excludedUpstreamIndices.contains(upstreamIndex) == false,
                  unavailable.contains(route.target.processID) == false
            else {
                continue
            }
            return upstreamIndex
        }
        return nil
    }

    func retryPrimaryInitializeOnAlternativeUpstream(
        failedUpstreamIndex: Int,
        failedUpstreamID: Int64?,
        reason: String
    ) -> Bool {
        guard xcodeProcessRoutes.isEmpty == false else {
            return false
        }
        markXcodeProcessRouteUnavailable(upstreamIndex: failedUpstreamIndex, reason: reason)
        guard let retryUpstreamIndex = primaryInitializeUpstreamIndex(
            excluding: [failedUpstreamIndex]
        ) else {
            return false
        }
        if let failedUpstreamID {
            upstreamRouter.remove(upstreamIndex: failedUpstreamIndex, upstreamID: failedUpstreamID)
        }
        clearUpstreamInitInFlight(upstreamIndex: failedUpstreamIndex)
        initializeManager.reopenPrimaryInitializeForRetry()
        guard initializeManager.preparePrimaryInitializeRetry(upstreamIndex: retryUpstreamIndex)
        else {
            return false
        }
        startPrimaryInitializeRequestWhenReady(applyBackoff: true)
        return true
    }

    func handleInitializeResponse(_ object: [String: Any], upstreamIndex: Int, upstreamID: Int64) {
        guard upstreamHealthManager.initializeAttemptMatches(
            upstreamIndex: upstreamIndex,
            expectedUpstreamID: upstreamID
        ) else {
            return
        }
        let isPrimaryInitialize = initializeManager.primaryInitializeMatches(
            upstreamIndex: upstreamIndex,
            upstreamID: upstreamID
        )
        let handlesPrimaryInitialize = isPrimaryInitialize
            || (
                upstreamIndex == 0
                    && initializeManager.activePrimaryInitializeUpstreamIndex() == nil
            )

        guard let resultValue = object["result"], let result = JSONValue(any: resultValue) else {
            if handlesPrimaryInitialize {
                let didRetry = retryPrimaryInitializeOnAlternativeUpstream(
                    failedUpstreamIndex: upstreamIndex,
                    failedUpstreamID: upstreamID,
                    reason: "primary_initialize_failed"
                )
                if didRetry {
                    return
                }
                if isPrimaryInitialize == false {
                    clearUpstreamState(
                        upstreamIndex: upstreamIndex,
                        expectedUpstreamID: upstreamID
                    )
                }
                if let errorObject = object["error"] as? [String: Any], !errorObject.isEmpty {
                    completeInitPendingWithError(errorObject)
                } else {
                    failInitPending(error: TimeoutError())
                }
            } else {
                clearUpstreamState(upstreamIndex: upstreamIndex, expectedUpstreamID: upstreamID)
                failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
            }
            return
        }

        guard let negotiatedProtocolVersion = Self.supportedProtocolVersion(
            fromInitializeResult: result
        ) else {
            handleUnsupportedInitializeProtocolVersion(result, upstreamIndex: upstreamIndex)
            return
        }

        if handlesPrimaryInitialize == false {
            if let canonicalInitialize = canonicalBrokerState.initializeResult(),
                !initializeResultsEquivalent(canonicalInitialize, result)
            {
                noteIncompatibleUpstream(
                    upstreamIndex: upstreamIndex,
                    kind: "initialize",
                    reason: "initialize.result mismatch"
                )
                failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
                return
            }
            sendInitializedNotificationIfNeeded(
                upstreamIndex: upstreamIndex,
                expectedUpstreamID: upstreamID
            ) { [weak self] in
                guard let self else { return }
                guard self.markUpstreamInitialized(
                    upstreamIndex: upstreamIndex,
                    expectedUpstreamID: upstreamID
                ) else {
                    return
                }
                self.upstreamSlotScheduler.wake()
            } onRejected: { [weak self] in
                self?.handleInitializedNotificationSendOverload(
                    upstreamIndex: upstreamIndex,
                    expectedUpstreamID: upstreamID
                )
            }
            return
        }

        let update = initializeManager.preparePrimaryInitializeSuccess()
        guard let update else { return }
        update.timeout?.cancel()

        sendInitializedNotificationIfNeeded(
            upstreamIndex: upstreamIndex,
            expectedUpstreamID: upstreamID
        ) { [weak self] in
            guard let self else { return }
            guard self.markUpstreamInitialized(
                upstreamIndex: upstreamIndex,
                expectedUpstreamID: upstreamID
            ) else {
                return
            }
            self.canonicalBrokerState.syncCanonicalInitialize(
                result,
                sourceUpstream: upstreamIndex
            )
            guard let pending = self.initializeManager.finishPrimaryInitializeSuccess() else { return }
            self.upstreamSlotScheduler.wake()
            if update.shouldWarmSecondary {
                self.initializeManager.markSecondaryWarmupStarted()
                self.warmUpSecondaryUpstreams()
            }
            self.refreshToolsListIfNeeded()
            self.completePendingInitializes(
                pending,
                result: result,
                negotiatedProtocolVersion: negotiatedProtocolVersion
            )
        } onRejected: { [weak self] in
            guard let self else { return }
            guard self.upstreamHealthManager.initializeAttemptMatches(
                upstreamIndex: upstreamIndex,
                expectedUpstreamID: upstreamID
            ) else {
                return
            }
            if upstreamIndex == 0,
                self.hasUsableInitializedSecondaryUpstreams(),
                let completion = self.initializeManager.finishPrimaryInitializeUsingCachedResult()
            {
                self.completePendingInitializes(
                    completion.pending,
                    result: completion.result,
                    negotiatedProtocolVersion: Self.supportedProtocolVersion(
                        fromInitializeResult: completion.result
                    )
                )
                self.eventLoop.execute { [weak self] in
                    self?.handleInitializedNotificationSendOverload(
                        upstreamIndex: upstreamIndex,
                        expectedUpstreamID: upstreamID,
                        treatsAsPrimary: true
                    )
                }
                return
            }
            self.initializeManager.reopenPrimaryInitializeForRetry()
            self.handleInitializedNotificationSendOverload(
                upstreamIndex: upstreamIndex,
                expectedUpstreamID: upstreamID,
                treatsAsPrimary: true
            )
        }
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
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalID.value.foundationObject,
            "result": result.foundationObject,
        ]
        guard JSONSerialization.isValidJSONObject(response),
            let data = try? JSONSerialization.data(withJSONObject: response, options: [])
        else {
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

    func handleUnsupportedInitializeProtocolVersion(_ result: JSONValue, upstreamIndex: Int) {
        let version = Self.protocolVersion(fromInitializeResult: result)
        let errorObject: [String: Any] = [
            "code": -32000,
            "message": "unsupported upstream protocol version",
            "data": [
                "protocolVersion": version as Any? ?? NSNull(),
                "supportedProtocolVersions": [MCP.ProtocolVersion.current],
            ],
        ]
        let activePrimaryUpstreamIndex = initializeManager.activePrimaryInitializeUpstreamIndex()
        let handlesPrimaryInitialize = activePrimaryUpstreamIndex == upstreamIndex
            || (upstreamIndex == 0 && activePrimaryUpstreamIndex == nil)
        if handlesPrimaryInitialize {
            let didRetry = retryPrimaryInitializeOnAlternativeUpstream(
                failedUpstreamIndex: upstreamIndex,
                failedUpstreamID: nil,
                reason: "unsupported_initialize_protocol"
            )
            if didRetry {
                return
            }
            if activePrimaryUpstreamIndex != upstreamIndex {
                clearUpstreamState(upstreamIndex: upstreamIndex)
            }
            completeInitPendingWithError(errorObject)
        } else {
            noteIncompatibleUpstream(
                upstreamIndex: upstreamIndex,
                kind: "initialize",
                reason: "unsupported protocol version"
            )
            failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
        }
    }

    func encodeInitializeErrorResponse(originalID: JSONRPC.ID, errorObject: [String: Any])
        -> ByteBuffer?
    {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalID.value.foundationObject,
            "error": errorObject,
        ]
        guard JSONSerialization.isValidJSONObject(response),
            let data = try? JSONSerialization.data(withJSONObject: response, options: [])
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
        if let upstreamIndex = result.upstreamIndex {
            if let upstreamID = result.upstreamID {
                upstreamRouter.remove(upstreamIndex: upstreamIndex, upstreamID: upstreamID)
            }
            clearUpstreamInitInFlight(upstreamIndex: upstreamIndex)
        }
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
    }

    func sendInitializedNotificationIfNeeded(
        upstreamIndex: Int,
        expectedUpstreamID: Int64,
        onAccepted: @escaping @Sendable () -> Void = {},
        onRejected: @escaping @Sendable () -> Void = {}
    ) {
        let shouldSend = upstreamHealthManager.shouldSendInitializedNotification(
            upstreamIndex: upstreamIndex
        )
        guard shouldSend else {
            guard upstreamHealthManager.initializeAttemptMatches(
                upstreamIndex: upstreamIndex,
                expectedUpstreamID: expectedUpstreamID
            ) else {
                return
            }
            onAccepted()
            return
        }

        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: notification, options: []) else {
            guard upstreamHealthManager.initializeAttemptMatches(
                upstreamIndex: upstreamIndex,
                expectedUpstreamID: expectedUpstreamID
            ) else {
                return
            }
            onAccepted()
            return
        }

        addRuntimeTask { [weak self] in
            guard let self else { return }
            let result = await self.upstreams[upstreamIndex].send(data)
            if result == .accepted {
                guard self.upstreamHealthManager.markInitializedNotificationSent(
                    upstreamIndex: upstreamIndex,
                    expectedUpstreamID: expectedUpstreamID
                ) else {
                    self.testHooks.initializedNotificationStaleIgnored?(upstreamIndex)
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

    func handleInitializedNotificationSendOverload(
        upstreamIndex: Int,
        expectedUpstreamID: Int64,
        treatsAsPrimary: Bool = false
    ) {
        guard clearUpstreamState(
            upstreamIndex: upstreamIndex,
            expectedUpstreamID: expectedUpstreamID
        ) else {
            return
        }
        let handlesPrimaryInitialize = treatsAsPrimary || upstreamIndex == 0
        let hasHealthySecondary = handlesPrimaryInitialize
            && hasUsableInitializedSecondaryUpstreams()
        if canonicalBrokerState.toolsSourceUpstream() == upstreamIndex && !hasHealthySecondary {
            invalidateControlPlane(
                reason: "initialized_notification_overload_\(upstreamIndex)",
                clearInitialize: false,
                clearToolsCatalog: true
            )
        }
        if handlesPrimaryInitialize {
            if hasUsableInitializedSecondaryUpstreams() {
                initializeManager.setWarmInitRecoveryIntent(.retryPrimaryWhenNoCachedInitialize)
                startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
            } else {
                resetSecondaryUpstreamsForPrimaryRetry()
                startPrimaryEagerRetry(failedPrimaryUpstreamIndex: upstreamIndex)
            }
        } else {
            startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
        }
        failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
    }

    func scheduleInitTimeout() {
        guard
            let timeoutAmount = MCP.MethodDispatcher.timeoutForInitialize(
                defaultSeconds: config.requestTimeout)
        else {
            return
        }
        let timeout = scheduleRuntimeTimeout(timeoutAmount) { [weak self] in
            guard let self else { return }
            self.failInitPending(error: TimeoutError())
        }
        let previous = initializeManager.replaceInitTimeout(timeout)
        previous?.cancel()
    }

    func failInitPending(error: Error) {
        let result = initializeManager.completePrimaryInitializeFailure()
        guard let result else { return }
        cancelPrimaryInitializeReadinessWaiter()
        result.timeout?.cancel()
        if let upstreamIndex = result.upstreamIndex {
            if let upstreamID = result.upstreamID {
                upstreamRouter.remove(upstreamIndex: upstreamIndex, upstreamID: upstreamID)
            }
            clearUpstreamInitInFlight(upstreamIndex: upstreamIndex)
        }
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

    func markUpstreamInitInFlight(upstreamIndex: Int, upstreamID: Int64) {
        upstreamHealthManager.markInitInFlight(upstreamIndex: upstreamIndex, upstreamID: upstreamID)
    }

    func clearUpstreamInitInFlight(upstreamIndex: Int) {
        upstreamHealthManager.clearInitInFlight(upstreamIndex: upstreamIndex)
    }

    @discardableResult
    func clearUpstreamState(upstreamIndex: Int, expectedUpstreamID: Int64? = nil) -> Bool {
        guard let cleared = upstreamHealthManager.clearUpstreamState(
            upstreamIndex: upstreamIndex,
            expectedUpstreamID: expectedUpstreamID
        ) else {
            return false
        }
        cleared.timeout?.cancel()
        if let initUpstreamID = cleared.initUpstreamID {
            upstreamRouter.remove(
                upstreamIndex: upstreamIndex,
                upstreamID: initUpstreamID
            )
        }
        debugRecorder.resetUpstream(upstreamIndex)
        if let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex),
           let replacementUpstreamIndex = firstUsableInitializedUpstreamIndex(in: route)
        {
            processToolCatalogRegistry.removeUpstreamMapping(
                forUpstreamIndex: upstreamIndex,
                replacementUpstreamIndex: replacementUpstreamIndex
            )
            resyncProcessToolsCatalogSurfaceAfterRemoving(upstreamIndex: upstreamIndex)
        } else {
            processToolCatalogRegistry.removeCatalog(forUpstreamIndex: upstreamIndex)
            resyncProcessToolsCatalogSurfaceAfterRemoving(upstreamIndex: upstreamIndex)
            removeXcodeWindowOwners(forUpstreamIndex: upstreamIndex)
        }
        return true
    }

    @discardableResult
    func markUpstreamInitialized(upstreamIndex: Int, expectedUpstreamID: Int64) -> Bool {
        guard let result = upstreamHealthManager.markInitialized(
            upstreamIndex: upstreamIndex,
            expectedUpstreamID: expectedUpstreamID
        ) else {
            return false
        }
        result.timeout?.cancel()
        noteUpstreamInitializationSucceeded()
        return true
    }

    func markUpstreamInitialized(upstreamIndex: Int) {
        guard let result = upstreamHealthManager.markInitialized(upstreamIndex: upstreamIndex) else {
            return
        }
        result.timeout?.cancel()
        noteUpstreamInitializationSucceeded()
    }

    func warmUpSecondaryUpstreams() {
        guard upstreams.count > 1 else { return }
        for upstreamIndex in 1..<upstreams.count {
            startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
        }
    }

    func resetSecondaryUpstreamsForPrimaryRetry() {
        guard upstreams.count > 1 else { return }
        for upstreamIndex in 1..<upstreams.count {
            clearUpstreamState(upstreamIndex: upstreamIndex)
        }
    }

    func startPrimaryEagerRetry(failedPrimaryUpstreamIndex: Int = 0) {
        clearUpstreamState(upstreamIndex: failedPrimaryUpstreamIndex)
        initializeManager.resetWarmSecondaryForRetry()
        invalidateControlPlane(
            reason: "primary_eager_retry",
            clearInitialize: true,
            clearToolsCatalog: true
        )
        startEagerInitializePrimary(applyBackoff: true)
    }

    func hasUsableInitializedSecondaryUpstreams() -> Bool {
        upstreamHealthManager.statesSnapshot().dropFirst().contains { upstream in
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
        let mergedParams = InitializeHandshakeJSON.resolved(
            initializeParamsOverride: initializeParamsOverride
        ).mapValues(\.foundationObject)

        return [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": mergedParams,
        ]
    }
}
