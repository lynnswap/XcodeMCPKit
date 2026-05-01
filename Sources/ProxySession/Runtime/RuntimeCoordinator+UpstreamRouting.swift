import Foundation
import Logging
import NIO
import ProxyCore
import ProxyMCP

extension RuntimeCoordinator {
    func failQueuedRequestsIfNoHealthyOrRecoveringUpstream() {
        guard upstreamHealthManager.initializedHealthyishCount() == 0 else { return }
        guard upstreamHealthManager.anyRecoveryInFlight() == false else { return }
        if initializeManager.consumeRetryAfterWarmInitFailureRegardlessOfCachedInit() {
            startPrimaryEagerRetry()
            if upstreamHealthManager.anyRecoveryInFlight() {
                return
            }
        }
        upstreamSlotScheduler.failQueuedRequests()
    }

    func routeUpstreamMessage(_ data: Data, upstreamIndex: Int) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            routeUnmappedUpstreamMessage(data, upstreamIndex: upstreamIndex)
            return
        }

        if var object = json as? [String: Any],
            let upstreamID = upstreamID(from: object["id"])
        {
            if let mapping = upstreamRouter.consume(
                upstreamIndex: upstreamIndex,
                upstreamID: upstreamID
            ) {
                if mapping.isInitialize {
                    handleInitializeResponse(object, upstreamIndex: upstreamIndex)
                    return
                }
                if let sessionID = mapping.sessionID, let originalID = mapping.originalID {
                    object["id"] = originalID.value.foundationObject
                    if let rewritten = try? JSONSerialization.data(withJSONObject: object, options: [])
                    {
                        recordTraffic(
                            upstreamIndex: upstreamIndex,
                            direction: "inbound",
                            data: rewritten
                        )
                        let target = session(id: sessionID)
                        target.router.handleIncoming(rewritten)
                        return
                    }
                }
            } else if upstreamRouter.consumeReleasedResponseMarker(
                upstreamIndex: upstreamIndex,
                upstreamID: upstreamID
            ) {
                logger.debug(
                    "Dropping late upstream response",
                    metadata: [
                        "upstream": .string("\(upstreamIndex)"),
                        "upstream_id": .string("\(upstreamID)"),
                    ]
                )
                debugRecorder.recordLateResponse(upstreamIndex: upstreamIndex)
                return
            }
        }

        if let array = json as? [Any] {
            var sessionID: String?
            var rewrittenAny = false
            var droppedLateResponse = false
            var transformed: [Any] = []
            for item in array {
                guard var object = item as? [String: Any] else {
                    transformed.append(item)
                    continue
                }
                guard let upstreamID = upstreamID(from: object["id"]) else {
                    transformed.append(item)
                    continue
                }
                guard let mapping = upstreamRouter.consume(
                    upstreamIndex: upstreamIndex,
                    upstreamID: upstreamID
                ) else {
                    if upstreamRouter.consumeReleasedResponseMarker(
                        upstreamIndex: upstreamIndex,
                        upstreamID: upstreamID
                    ) {
                        droppedLateResponse = true
                        debugRecorder.recordLateResponse(upstreamIndex: upstreamIndex)
                        continue
                    }
                    transformed.append(item)
                    continue
                }
                if mapping.isInitialize {
                    handleInitializeResponse(object, upstreamIndex: upstreamIndex)
                    continue
                }
                guard let originalID = mapping.originalID else {
                    transformed.append(item)
                    continue
                }
                object["id"] = originalID.value.foundationObject
                sessionID = sessionID ?? mapping.sessionID
                rewrittenAny = true
                transformed.append(object)
            }
            if rewrittenAny, let sessionID,
                let rewritten = try? JSONSerialization.data(
                    withJSONObject: transformed, options: [])
            {
                recordTraffic(
                    upstreamIndex: upstreamIndex,
                    direction: "inbound",
                    data: rewritten
                )
                let target = session(id: sessionID)
                target.router.handleIncoming(rewritten)
                return
            }
            if droppedLateResponse, transformed.isEmpty {
                logger.debug(
                    "Dropping late upstream batch response",
                    metadata: [
                        "upstream": .string("\(upstreamIndex)"),
                    ]
                )
                return
            }
            if droppedLateResponse,
                let rewritten = try? JSONSerialization.data(withJSONObject: transformed, options: [])
            {
                routeUnmappedUpstreamMessage(rewritten, upstreamIndex: upstreamIndex)
                return
            }
        }

        routeUnmappedUpstreamMessage(data, upstreamIndex: upstreamIndex)
    }

    func handleUpstreamExit(_ status: Int32, upstreamIndex: Int) {
        let globalInit = initializeManager.handleUpstreamExit(upstreamIndex: upstreamIndex)
        guard let globalInit else { return }

        if upstreamIndex == 0 && globalInit.wasInFlight {
            globalInit.timeout?.cancel()
            if let upstreamID = globalInit.primaryInitUpstreamID {
                upstreamRouter.remove(upstreamIndex: 0, upstreamID: upstreamID)
            }
            for item in globalInit.pending {
                item.eventLoop.execute {
                    item.promise.fail(TimeoutError())
                }
            }
        }

        clearUpstreamState(upstreamIndex: upstreamIndex)
        upstreamRouter.reset(upstreamIndex: upstreamIndex)
        releaseLeases(
            leaseManager.abandonActiveLeases(
                upstreamIndex: upstreamIndex,
                reason: .upstreamExit
            )
        )

        let shouldResetGlobalInit: Bool
        if globalInit.hadGlobalInit {
            shouldResetGlobalInit = !upstreamHealthManager.anyInitialized()
        } else {
            shouldResetGlobalInit = false
        }
        let shouldClearToolsCatalog =
            canonicalBrokerState.toolsSourceUpstream() == upstreamIndex
            && !upstreamHealthManager.anyInitialized()
        if shouldResetGlobalInit || shouldClearToolsCatalog {
            if shouldResetGlobalInit {
                initializeManager.resetCachedInitializeResult()
            }
            invalidateControlPlaneSynchronously(
                reason: "upstream_exit_\(upstreamIndex)",
                clearInitialize: shouldResetGlobalInit,
                clearToolsCatalog: shouldClearToolsCatalog
            )
        }

        if upstreamIndex == 0 {
            if shouldResetGlobalInit || !globalInit.hadGlobalInit {
                startEagerInitializePrimary(applyBackoff: true)
            } else {
                startUpstreamWarmInitialize(upstreamIndex: 0, applyBackoff: true)
            }
        } else if globalInit.hadGlobalInit {
            if shouldResetGlobalInit {
                let primaryInitInFlight = upstreamHealthManager.primaryInitInFlight()
                if primaryInitInFlight {
                    initializeManager
                        .setShouldRetryEagerInitializePrimaryAfterWarmInitFailure(true)
                } else {
                    initializeManager
                        .setShouldRetryEagerInitializePrimaryAfterWarmInitFailure(false)
                    startEagerInitializePrimary(applyBackoff: true)
                }
            }
            startUpstreamWarmInitialize(upstreamIndex: upstreamIndex, applyBackoff: true)
        }
    }

    package func assignUpstreamID(sessionID: String, originalID: RPCID, upstreamIndex: Int) -> Int64 {
        upstreamRouter.assign(
            upstreamIndex: upstreamIndex, sessionID: sessionID, originalID: originalID,
            isInitialize: false)
    }

    package func removeUpstreamIDMapping(sessionID: String, requestIDKey: String, upstreamIndex: Int) {
        _ = upstreamRouter.remove(
            upstreamIndex: upstreamIndex,
            sessionID: sessionID,
            requestIDKey: requestIDKey
        )
    }

    package func onRequestTimeout(sessionID: String, requestIDKey: String, upstreamIndex: Int) {
        removeUpstreamIDMapping(
            sessionID: sessionID, requestIDKey: requestIDKey, upstreamIndex: upstreamIndex)
        markRequestTimedOut(upstreamIndex: upstreamIndex)
    }

    package func onRequestSucceeded(sessionID: String, requestIDKey: String, upstreamIndex: Int) {
        _ = sessionID
        _ = requestIDKey
        markRequestSucceeded(upstreamIndex: upstreamIndex)
    }

    package func sendUpstream(_ data: Data, upstreamIndex: Int, ensureRunning: Bool = false) {
        guard upstreamIndex >= 0, upstreamIndex < upstreams.count else {
            return
        }
        Task {
            if ensureRunning {
                await upstreams[upstreamIndex].start()
            }
            let result = await upstreams[upstreamIndex].send(data)
            if result == .accepted {
                self.recordTraffic(
                    upstreamIndex: upstreamIndex,
                    direction: "outbound",
                    data: data
                )
                return
            }
            self.markUpstreamOverloaded(upstreamIndex: upstreamIndex)
            self.handleOverloadedUpstreamSend(
                originalRequestData: data,
                upstreamIndex: upstreamIndex
            )
        }
    }

    package func debugSnapshot() -> ProxyDebugSnapshot {
        debugSnapshot(includeSensitiveDebugPayloads: false)
    }

    package func debugSnapshot(includeSensitiveDebugPayloads: Bool) -> ProxyDebugSnapshot {
        let initSnapshot = initializeManager.snapshot()
        let brokerSnapshot = canonicalBrokerState.snapshot()
        let controlPlaneSnapshot = controlPlaneDebugMirror.snapshot()
        let upstreamStates = upstreamHealthManager.statesSnapshot()
        let leaseSnapshots = leaseManager.debugSnapshots()
        let sessionSnapshots = leaseManager.sessionDebugSnapshots(
            allSessionIDs: sessionRegistry.sessionIDs()
        )
        let schedulerSnapshot = upstreamSlotScheduler.debugSnapshot()

        return debugRecorder.snapshot(
            proxyInitialized: initSnapshot.hasInitResult && !initSnapshot.isShuttingDown,
            cachedToolsListAvailable: brokerSnapshot.toolsCatalogRaw != nil,
            controlPlane: controlPlaneSnapshot,
            upstreamStates: upstreamStates,
            sessionSnapshots: sessionSnapshots,
            leaseSnapshots: leaseSnapshots,
            queuedRequestCount: schedulerSnapshot.queuedRequestCount,
            redactedText: Self.redactedDebugText,
            includeSensitiveDebugPayloads: includeSensitiveDebugPayloads,
            healthFormatter: upstreamHealthManager.debugHealthStateString
        )
    }

    package func createRequestLease(
        descriptor: SessionPipelineRequestDescriptor
    ) -> RequestLeaseID {
        leaseManager.createLease(descriptor: descriptor)
    }

    package func activateRequestLease(
        _ leaseID: RequestLeaseID,
        requestIDKey: String?,
        upstreamIndex: Int?,
        timeout: TimeAmount?
    ) {
        let timeoutAt = timeout.map {
            Date().addingTimeInterval(Double($0.nanoseconds) / 1_000_000_000)
        }
        leaseManager.activateLease(
            leaseID,
            requestIDKey: requestIDKey,
            upstreamIndex: upstreamIndex,
            timeoutAt: timeoutAt
        )
    }

    package func completeRequestLease(_ leaseID: RequestLeaseID) {
        releaseLeases([leaseManager.completeLease(leaseID)].compactMap { $0 })
    }

    package func requeueRequestLease(_ leaseID: RequestLeaseID) {
        releaseLeases([leaseManager.requeueLease(leaseID)].compactMap { $0 })
    }

    package func failRequestLease(
        _ leaseID: RequestLeaseID,
        terminalState: RequestLeaseState,
        reason: RequestLeaseReleaseReason
    ) {
        releaseLeases(
            [leaseManager.failLease(leaseID, terminalState: terminalState, reason: reason)]
                .compactMap { $0 }
        )
    }

    package func handleRequestLeaseTimeout(
        _ leaseID: RequestLeaseID,
        sessionID: String,
        requestIDKeys: [String],
        upstreamIndex: Int
    ) {
        if let first = requestIDKeys.first {
            onRequestTimeout(
                sessionID: sessionID,
                requestIDKey: first,
                upstreamIndex: upstreamIndex
            )
            for requestIDKey in requestIDKeys.dropFirst() {
                removeUpstreamIDMapping(
                    sessionID: sessionID,
                    requestIDKey: requestIDKey,
                    upstreamIndex: upstreamIndex
                )
            }
        }
        releaseLeases([leaseManager.timeoutLease(leaseID)].compactMap { $0 })
    }

    package func abandonRequestLease(
        _ leaseID: RequestLeaseID,
        sessionID: String,
        requestIDKeys: [String],
        upstreamIndex: Int?
    ) {
        if let upstreamIndex {
            for requestIDKey in requestIDKeys {
                removeUpstreamIDMapping(
                    sessionID: sessionID,
                    requestIDKey: requestIDKey,
                    upstreamIndex: upstreamIndex
                )
            }
        }
        upstreamSlotScheduler.cancelQueuedRequest(leaseID: leaseID)
        releaseLeases(
            [leaseManager.failLease(
                leaseID,
                terminalState: .abandoned,
                reason: .clientDisconnected
            )].compactMap { $0 }
        )
    }

    func testStateSnapshot() -> TestSnapshot {
        let initSnapshot = initializeManager.snapshot()
        let upstreams = upstreamHealthManager.statesSnapshot().map { upstream in
                TestSnapshot.Upstream(
                    isInitialized: upstream.isInitialized,
                    initInFlight: upstream.initInFlight,
                    healthState: upstream.healthState
                )
        }
        return TestSnapshot(
            hasInitResult: initSnapshot.hasInitResult,
            initInFlight: initSnapshot.initInFlight,
            didWarmSecondary: initSnapshot.didWarmSecondary,
            shouldRetryEagerInitializePrimaryAfterWarmInitFailure: initSnapshot
                .shouldRetryEagerInitializePrimaryAfterWarmInitFailure,
            upstreams: upstreams
        )
    }

    func testSessionSnapshot(id: String) -> TestSnapshot.Session? {
        sessionRegistry.testSnapshot(id: id)
    }

    func testSetInitializeRoutingState(
        sessionID _: String,
        upstreamIndex _: Int,
        preferOnNextPin _: Bool,
        didReceiveInitializeUpstreamMessage _: Bool = false
    ) {}

    func handleOverloadedUpstreamSend(
        originalRequestData: Data,
        upstreamIndex: Int
    ) {
        guard let any = try? JSONSerialization.jsonObject(with: originalRequestData, options: [])
        else {
            return
        }

        let overloadError: [String: Any] = [
            "code": -32002,
            "message": "upstream overloaded",
        ]

        let responseAny: Any? = {
            if let object = any as? [String: Any] {
                guard let id = object["id"], !(id is NSNull) else { return nil }
                return [
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": overloadError,
                ]
            }
            if let array = any as? [Any] {
                let objects = array.compactMap { item -> [String: Any]? in
                    guard let object = item as? [String: Any],
                        let id = object["id"],
                        !(id is NSNull)
                    else {
                        return nil
                    }
                    return [
                        "jsonrpc": "2.0",
                        "id": id,
                        "error": overloadError,
                    ]
                }
                if objects.isEmpty {
                    return nil
                }
                return objects
            }
            return nil
        }()

        guard let responseAny,
            JSONSerialization.isValidJSONObject(responseAny),
            let data = try? JSONSerialization.data(withJSONObject: responseAny, options: [])
        else {
            return
        }

        routeUpstreamMessage(data, upstreamIndex: upstreamIndex)
    }

    func upstreamID(from value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String, let number = Int64(string) {
            return number
        }
        return nil
    }

    func isServerInitiatedMessage(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return object["method"] is String
        }
        if let array = value as? [Any] {
            return array.contains { item in
                guard let object = item as? [String: Any] else { return false }
                return object["method"] is String
            }
        }
        return false
    }

    func routeUnmappedUpstreamMessage(_ data: Data, upstreamIndex: Int) {
        recordTraffic(
            upstreamIndex: upstreamIndex,
            direction: "inbound_unmapped",
            data: data
        )
        guard let any = try? JSONSerialization.jsonObject(with: data, options: []) else {
            logger.debug(
                "Dropping unmapped upstream message (invalid JSON)",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "bytes": .string("\(data.count)"),
                ]
            )
            return
        }

        let serverInitiatedPayloads: [Data] = {
            if let object = any as? [String: Any] {
                guard object["method"] is String else { return [] }
                return [data]
            }
            if let array = any as? [Any] {
                var payloads: [Data] = []
                payloads.reserveCapacity(array.count)
                for item in array {
                    guard let object = item as? [String: Any],
                        object["method"] is String,
                        JSONSerialization.isValidJSONObject(object),
                        let encoded = try? JSONSerialization.data(
                            withJSONObject: object, options: [])
                    else {
                        continue
                    }
                    payloads.append(encoded)
                }
                return payloads
            }
            return []
        }()

        guard !serverInitiatedPayloads.isEmpty else {
            logger.debug(
                "Dropping unmapped upstream response",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "bytes": .string("\(data.count)"),
                ]
            )
            return
        }

        var routedTargets: [SessionContext] = []
        var routedSessionIDs = Set<String>()

        if upstreamIndex == 0 {
            for pending in initializeManager.pendingInitializes() {
                guard sessionStillMatchesPendingInitialize(
                    sessionID: pending.sessionID,
                    sessionGeneration: pending.sessionGeneration
                ),
                    let target = sessionRegistry.contextIfPresent(id: pending.sessionID),
                    routedSessionIDs.insert(target.id).inserted
                else {
                    continue
                }
                routedTargets.append(target)
            }
        }

        for target in sessionRegistry.activeNotificationTargets() {
            guard routedSessionIDs.insert(target.id).inserted else {
                continue
            }
            routedTargets.append(target)
        }

        if !routedTargets.isEmpty {
            for payload in serverInitiatedPayloads {
                for session in routedTargets {
                    session.router.handleIncoming(payload)
                }
            }
            return
        }

        logger.debug(
            "Dropping unmapped upstream message (no routed target sessions)",
            metadata: [
                "upstream": .string("\(upstreamIndex)"),
                "bytes": .string("\(data.count)"),
            ]
        )
        debugRecorder.recordDroppedUnmappedNotification(upstreamIndex: upstreamIndex)
    }

    func handleUpstreamStderr(_ message: String, upstreamIndex: Int) {
        debugRecorder.recordStderr(message, upstreamIndex: upstreamIndex)
        let classification = UpstreamStderrClassifier.classify(message)
        let decision = upstreamStderrLogLimiter.decision(
            upstreamIndex: upstreamIndex,
            message: message,
            classification: classification,
            nowUptimeNs: nowUptimeNanoseconds()
        )
        guard decision.shouldLog else { return }

        var metadata: [String: Logger.MetadataValue] = [
            "upstream": .string("\(upstreamIndex)")
        ]
        if decision.suppressedDuplicateCount > 0 {
            metadata["suppressed_duplicates"] = .string("\(decision.suppressedDuplicateCount)")
        }

        switch classification {
        case .xcodeUnavailable:
            logger.info(
                "mcpbridge reported that no Xcode process is running; waiting for Xcode before restarting",
                metadata: metadata
            )
        case .unknown:
            metadata["message"] = .string(message)
            logger.error(
                "Upstream stderr",
                metadata: metadata
            )
        }
    }

    func handleUpstreamProtocolViolation(
        _ protocolViolation: StdioFramerProtocolViolation,
        upstreamIndex: Int
    ) {
        debugRecorder.recordProtocolViolation(protocolViolation, upstreamIndex: upstreamIndex)
        let nowUptimeNs = nowUptimeNanoseconds()
        let initSnapshot = initializeManager.snapshot()
        let transition = upstreamHealthManager.markProtocolViolation(
            upstreamIndex: upstreamIndex,
            nowUptimeNs: nowUptimeNs
        )
        transition?.cancelledInitTimeout?.cancel()
        if upstreamIndex == 0, initSnapshot.initInFlight {
            failInitPending(error: TimeoutError())
        }
        upstreamRouter.reset(upstreamIndex: upstreamIndex)
        releaseLeases(
            leaseManager.abandonActiveLeases(
                upstreamIndex: upstreamIndex,
                reason: .stdoutProtocolViolation
            )
        )
        failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
        if let quarantineUntil = transition?.quarantineUntil {
            logger.warning(
                "Upstream quarantined after stdout protocol violation",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "quarantine_until_uptime_ns": .string("\(quarantineUntil)"),
                    "uptime_ns": .string("\(nowUptimeNs)"),
                ]
            )
        }
        let clearInitialize = upstreamIndex == 0 && initSnapshot.hasInitResult == false
        let clearToolsCatalog =
            canonicalBrokerState.toolsSourceUpstream() == upstreamIndex
            && !upstreamHealthManager.anyInitialized()
        if clearInitialize || clearToolsCatalog {
            invalidateControlPlaneSynchronously(
                reason: "protocol_violation_\(upstreamIndex)",
                clearInitialize: clearInitialize,
                clearToolsCatalog: clearToolsCatalog
            )
        }

        if upstreamIndex == 0 {
            if initSnapshot.hasInitResult {
                startUpstreamWarmInitialize(upstreamIndex: upstreamIndex, applyBackoff: true)
            } else {
                startEagerInitializePrimary(applyBackoff: true)
            }
        } else if initSnapshot.hasInitResult {
            startUpstreamWarmInitialize(upstreamIndex: upstreamIndex, applyBackoff: true)
        }
    }

    func handleBufferedStdoutBytes(_ size: Int, upstreamIndex: Int) {
        debugRecorder.recordBufferedStdoutBytes(size, upstreamIndex: upstreamIndex)
    }

    func recordTraffic(
        upstreamIndex: Int,
        direction: String,
        data: Data
    ) {
        debugRecorder.recordTraffic(
            upstreamIndex: upstreamIndex,
            direction: direction,
            data: data,
            redactedText: Self.redactedDebugText
        )
    }

    private func releaseLeases(_ actions: [RequestLeaseReleaseAction]) {
        for action in actions {
            if let upstreamIndex = action.upstreamIndex {
                upstreamSlotScheduler.releaseUpstreamSlot(
                    upstreamIndex: upstreamIndex,
                    leaseID: action.leaseID
                )
            }
        }
    }
}
