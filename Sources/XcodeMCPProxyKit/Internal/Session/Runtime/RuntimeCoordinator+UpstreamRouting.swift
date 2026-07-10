import Foundation
import Logging
import NIO
import XcodeMCPKit

extension RuntimeCoordinator {
    func failQueuedRequestsIfNoHealthyOrRecoveringUpstream() {
        guard activeInitializedHealthyishCount() == 0 else { return }
        guard anyActiveRecoveryInFlight() == false else { return }
        if initializeManager.consumeWarmInitRecoveryIntent(policy: .regardlessOfCachedInitialize) {
            startPrimaryEagerRetry()
            if anyActiveRecoveryInFlight() {
                return
            }
        }
        upstreamSlotScheduler.failQueuedRequests()
    }

    private enum MappedResponseRoutingOutcome {
        case routed(sessionID: String, object: [String: Any])
        case handled
        case late
        case unmappedResponse
        case notResponse
    }

    private struct ServerInitiatedPayload {
        let data: Data
        let object: [String: Any]
        let expectsResponse: Bool

        func routedData(
            for session: SessionContext,
            upstreamIndex: Int
        ) -> Data? {
            guard case .request(_, let upstreamID) =
                JSONRPC.Message.Inspector.kind(of: object)
            else {
                return data
            }
            let clientID = session.serverRequestTracker.record(
                upstreamID: upstreamID,
                upstreamIndex: upstreamIndex
            )
            return try? JSONRPC.Wire.dataByReplacingID(in: object, with: clientID)
        }
    }

    func routeUpstreamMessage(
        _ data: Data,
        upstreamIndex: Int,
        proof suppliedProof: UpstreamTopologyProof? = nil
    ) {
        let slotID = UpstreamSlotID(rawValue: upstreamIndex)
        guard let proof = suppliedProof ?? upstreamTopology.snapshot().proof(slotID),
              proof.slotID == slotID,
              upstreamTopology.validate(proof) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            guard upstreamTopology.validate(proof) else { return }
            routeUnmappedUpstreamMessage(data, upstreamIndex: upstreamIndex)
            return
        }

        if let object = json as? [String: Any] {
            switch mappedResponseRoutingOutcome(
                object,
                upstreamIndex: upstreamIndex,
                proof: proof
            ) {
            case .routed(let sessionID, let object):
                if deliverClientResponseObjects([object], sessionID: sessionID, upstreamIndex: upstreamIndex) {
                    return
                }
            case .handled, .late:
                return
            case .unmappedResponse, .notResponse:
                break
            }
            guard upstreamTopology.validate(proof) else { return }
            routeUnmappedUpstreamMessage(data, upstreamIndex: upstreamIndex)
            return
        }

        if let array = json as? [Any] {
            routeUpstreamBatch(
                array,
                originalData: data,
                upstreamIndex: upstreamIndex,
                proof: proof
            )
            return
        }

        routeUnmappedUpstreamMessage(data, upstreamIndex: upstreamIndex)
    }

    private func routeUpstreamBatch(
        _ array: [Any],
        originalData: Data,
        upstreamIndex: Int,
        proof: UpstreamTopologyProof
    ) {
        var responseObjectsBySessionID: [String: [Any]] = [:]
        var mappedSessionIDs = Set<String>()
        var serverInitiatedPayloads: [ServerInitiatedPayload] = []
        var unmappedItems: [Any] = []
        var droppedLateResponse = false

        for item in array {
            guard let object = item as? [String: Any] else {
                unmappedItems.append(item)
                continue
            }

            switch mappedResponseRoutingOutcome(
                object,
                upstreamIndex: upstreamIndex,
                proof: proof
            ) {
            case .routed(let sessionID, let object):
                responseObjectsBySessionID[sessionID, default: []].append(object)
                mappedSessionIDs.insert(sessionID)
            case .handled:
                continue
            case .late:
                droppedLateResponse = true
            case .unmappedResponse:
                unmappedItems.append(item)
            case .notResponse:
                if let payload = serverInitiatedPayload(from: object) {
                    serverInitiatedPayloads.append(payload)
                } else {
                    unmappedItems.append(item)
                }
            }
        }

        let owningTargetOverride: SessionContext? = {
            guard mappedSessionIDs.count == 1,
                let sessionID = mappedSessionIDs.first
            else {
                return nil
            }
            return sessionRegistry.contextIfPresent(id: sessionID)
        }()
        let routedServerInitiated = routeServerInitiatedPayloads(
            serverInitiatedPayloads,
            upstreamIndex: upstreamIndex,
            sourceByteCount: originalData.count,
            owningTargetOverride: owningTargetOverride
        )
        let routedClientResponses = routeClientResponses(
            responseObjectsBySessionID,
            upstreamIndex: upstreamIndex
        )

        if unmappedItems.isEmpty {
            if droppedLateResponse && !routedClientResponses && !routedServerInitiated {
                logger.debug(
                    "Dropping late upstream batch response",
                    metadata: [
                        "upstream": .string("\(upstreamIndex)"),
                    ]
                )
            }
            return
        }

        if routedClientResponses || routedServerInitiated || droppedLateResponse {
            routeUnmappedBatchItems(unmappedItems, upstreamIndex: upstreamIndex)
            return
        }

        routeUnmappedUpstreamMessage(originalData, upstreamIndex: upstreamIndex)
    }

    private func mappedResponseRoutingOutcome(
        _ object: [String: Any],
        upstreamIndex: Int,
        proof: UpstreamTopologyProof
    ) -> MappedResponseRoutingOutcome {
        guard let responseID = JSONRPC.Message.Inspector.responseCorrelationID(from: object),
            let upstreamID = upstreamID(from: responseID)
        else {
            return .notResponse
        }

        guard let mapping = upstreamRouter.consume(
            proof: proof,
            upstreamID: upstreamID
        ) else {
            if upstreamRouter.consumeReleasedResponseMarker(
                proof: proof,
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
                return .late
            }
            guard upstreamTopology.validate(proof) else { return .late }
            return .unmappedResponse
        }

        if mapping.isInitialize {
            handleInitializeResponse(object, upstreamIndex: upstreamIndex, upstreamID: upstreamID)
            return .handled
        }

        guard let sessionID = mapping.sessionID,
            let originalID = mapping.originalID
        else {
            return .handled
        }
        return .routed(
            sessionID: sessionID,
            object: clientResponseObject(from: object, originalID: originalID)
        )
    }

    private func clientResponseObject(
        from object: [String: Any],
        originalID: JSONRPC.ID
    ) -> [String: Any] {
        if case .malformed = JSONRPC.Message.Inspector.kind(of: object) {
            return JSONRPC.Wire.errorResponseObject(
                id: originalID,
                code: -32000,
                message: "invalid upstream response"
            )
        }
        return JSONRPC.Wire.objectByReplacingID(in: object, with: originalID)
    }

    private func routeClientResponses(
        _ responseObjectsBySessionID: [String: [Any]],
        upstreamIndex: Int
    ) -> Bool {
        var routedAny = false
        for (sessionID, objects) in responseObjectsBySessionID {
            if deliverClientResponseObjects(
                objects,
                sessionID: sessionID,
                upstreamIndex: upstreamIndex
            ) {
                routedAny = true
            }
        }
        return routedAny
    }

    private func deliverClientResponseObjects(
        _ objects: [Any],
        sessionID: String,
        upstreamIndex: Int
    ) -> Bool {
        guard !objects.isEmpty else {
            return false
        }
        let payload: Any = objects.count == 1 ? objects[0] : objects
        guard let data = try? JSONRPC.Wire.data(from: payload) else {
            return false
        }
        recordTraffic(
            upstreamIndex: upstreamIndex,
            direction: "inbound",
            data: data
        )
        let target = session(id: sessionID)
        target.router.handleIncoming(data)
        return true
    }

    /// The staleness rule for the canonical tools catalog: it must not
    /// survive losing the upstream it came from unless another initialized
    /// upstream can still vouch for an equivalent catalog.
    func toolsCatalogLostItsSource(_ upstreamIndex: Int) -> Bool {
        processControlPlane.canonicalSourceUpstream() == upstreamIndex
            && !anyActiveInitializedUpstream()
    }

    func handleUpstreamExit(
        _ status: Int32,
        upstreamIndex: Int,
        proof suppliedProof: UpstreamTopologyProof? = nil
    ) {
        let slotID = UpstreamSlotID(rawValue: upstreamIndex)
        guard let proof = suppliedProof ?? upstreamTopology.snapshot().proof(slotID),
              proof.slotID == slotID,
              upstreamTopology.validate(proof) else { return }
        guard clearUpstreamState(proof: proof) else { return }
        let globalInit = initializeManager.handleUpstreamExit(upstreamIndex: upstreamIndex)
        guard let globalInit else { return }
        let suppressProcessRouteWarmRestart =
            clearsInitializedProcessRouteActivationBeforeCatalog(upstreamIndex: upstreamIndex)

        let exitedActivePrimaryInitialize =
            globalInit.primaryInitUpstreamIndex == upstreamIndex && globalInit.wasInFlight
        if exitedActivePrimaryInitialize {
            if let upstreamID = globalInit.primaryInitUpstreamID {
                upstreamRouter.remove(upstreamIndex: upstreamIndex, upstreamID: upstreamID)
            }
        }
        if xcodeProcessRouteHasUsableInitializedUpstream(containing: upstreamIndex) == false {
            markXcodeProcessRouteUnavailable(
                upstreamIndex: upstreamIndex,
                reason: "upstream_exit_\(status)"
            )
        }
        upstreamRouter.reset(proof: proof)
        releaseLeases(
            leaseManager.abandonActiveLeases(
                upstreamIndex: upstreamIndex,
                reason: .upstreamExit
            )
        )

        if exitedActivePrimaryInitialize {
            if retryPrimaryInitializeOnAlternativeUpstream(
                failedUpstreamIndex: upstreamIndex,
                failedUpstreamID: nil,
                reason: "primary_upstream_exit_\(status)"
            ) {
                return
            }
            globalInit.timeout?.cancel()
            _ = initializeManager.completePrimaryInitializeFailure()
            for item in globalInit.pending {
                removePendingInitializeSessionIfCurrent(item)
                item.eventLoop.execute {
                    item.promise.fail(TimeoutError())
                }
            }
        }

        let shouldResetGlobalInit: Bool
        if globalInit.hadGlobalInit {
            shouldResetGlobalInit = !anyActiveInitializedUpstream()
        } else {
            shouldResetGlobalInit = false
        }
        let shouldClearToolsCatalog = toolsCatalogLostItsSource(upstreamIndex)
        if shouldResetGlobalInit || shouldClearToolsCatalog {
            if shouldResetGlobalInit {
                initializeManager.resetWarmSecondaryForRetry()
            }
            invalidateControlPlane(
                reason: "upstream_exit_\(upstreamIndex)",
                clearInitialize: shouldResetGlobalInit,
                clearToolsCatalog: shouldClearToolsCatalog
            )
        }

        let primaryUpstreamIndex = globalInit.primaryInitUpstreamIndex
            ?? canonicalHandshakeState.initializeSourceUpstream()
            ?? 0
        if upstreamIndex == primaryUpstreamIndex {
            if shouldResetGlobalInit || !globalInit.hadGlobalInit {
                startEagerInitializePrimary(applyBackoff: true)
            } else if suppressProcessRouteWarmRestart == false {
                startUpstreamWarmInitialize(upstreamIndex: upstreamIndex, applyBackoff: true)
            }
        } else if globalInit.hadGlobalInit {
            if shouldResetGlobalInit {
                let primaryInitInFlight = initializeManager.snapshot().initInFlight
                if primaryInitInFlight {
                    initializeManager
                        .setWarmInitRecoveryIntent(.retryPrimaryWhenNoCachedInitialize)
                } else {
                    initializeManager
                        .setWarmInitRecoveryIntent(.none)
                    startEagerInitializePrimary(applyBackoff: true)
                }
            }
            if suppressProcessRouteWarmRestart == false {
                startUpstreamWarmInitialize(upstreamIndex: upstreamIndex, applyBackoff: true)
            }
        }
    }

    func assignUpstreamID(sessionID: String, originalID: JSONRPC.ID, upstreamIndex: Int) -> Int64 {
        upstreamRouter.assign(
            upstreamIndex: upstreamIndex, sessionID: sessionID, originalID: originalID,
            isInitialize: false)
    }

    func removeUpstreamIDMapping(sessionID: String, requestIDKey: String, upstreamIndex: Int) {
        _ = upstreamRouter.remove(
            upstreamIndex: upstreamIndex,
            sessionID: sessionID,
            requestIDKey: requestIDKey
        )
    }

    func onRequestTimeout(sessionID: String, requestIDKey: String, upstreamIndex: Int) {
        removeUpstreamIDMapping(
            sessionID: sessionID, requestIDKey: requestIDKey, upstreamIndex: upstreamIndex)
        markRequestTimedOut(upstreamIndex: upstreamIndex)
    }

    func onRequestSucceeded(sessionID: String, requestIDKey: String, upstreamIndex: Int) {
        _ = sessionID
        _ = requestIDKey
        markRequestSucceeded(upstreamIndex: upstreamIndex)
    }

    func sendUpstream(_ data: Data, upstreamIndex: Int, ensureRunning: Bool = false) {
        sendUpstream(
            data,
            upstreamIndex: upstreamIndex,
            ensureRunning: ensureRunning,
            admission: nil
        )
    }

    func sendUpstream(
        _ data: Data,
        upstreamIndex: Int,
        ensureRunning: Bool,
        admission: RouteForwardingAdmission?,
        initializeClaim: UpstreamHealthManager.InitializeClaim? = nil
    ) {
        guard let context = upstreamSlotContext(upstreamIndex) else {
            return
        }
        if let initializeClaim {
            guard upstreamHealthManager.validate(initializeClaim),
                  initializeClaim.topologyProof == context.proof,
                  upstreamTopology.validate(context.proof) else {
                return
            }
        }
        if let admission {
            guard processControlPlane.validate(admission.route),
                  let expectedProof = admission.proof(for: upstreamIndex),
                  expectedProof == context.proof,
                  upstreamTopology.validate(expectedProof) else {
                failPendingSend(
                    originalRequestData: data,
                    upstreamIndex: upstreamIndex,
                    code: -32001,
                    message: "Xcode process route changed before forwarding"
                )
                return
            }
        }
        addRuntimeTask { [weak self, context, admission, initializeClaim] in
            guard let self else { return }
            if ensureRunning {
                if let initializeClaim {
                    guard self.upstreamHealthManager.validate(
                              initializeClaim
                          ) else {
                        return
                    }
                }
                await context.slot.start()
            }
            if let initializeClaim {
                guard self.upstreamHealthManager.validate(initializeClaim),
                      self.upstreamTopology.validate(context.proof) else {
                    return
                }
            } else if let admission {
                guard self.processControlPlane.validate(admission.route),
                      let expectedProof = admission.proof(for: upstreamIndex),
                      expectedProof == context.proof,
                      self.upstreamTopology.validate(expectedProof) else {
                    self.failPendingSend(
                        originalRequestData: data,
                        upstreamIndex: upstreamIndex,
                        code: -32001,
                        message: "Xcode process route changed before forwarding"
                    )
                    return
                }
            } else {
                guard self.upstreamTopology.validate(context.proof) else { return }
            }
            switch await context.slot.send(data) {
            case .accepted:
                self.recordTraffic(
                    upstreamIndex: upstreamIndex,
                    direction: "outbound",
                    data: data
                )
            case .backpressure:
                self.markUpstreamOverloaded(context.proof)
                self.failPendingSend(
                    originalRequestData: data,
                    upstreamIndex: upstreamIndex,
                    code: -32002,
                    message: "upstream overloaded"
                )
            case .unavailable(let reason):
                // The exit/quarantine machinery owns health for a dead slot;
                // a send into it must not be misdiagnosed as overload.
                self.failPendingSend(
                    originalRequestData: data,
                    upstreamIndex: upstreamIndex,
                    code: -32001,
                    message: "upstream unavailable"
                )
                self.handleUnavailableUpstreamSend(
                    upstreamIndex: upstreamIndex,
                    reason: reason
                )
            }
        }
    }

    private func handleUnavailableUpstreamSend(
        upstreamIndex: Int,
        reason: Upstream.UnavailableReason
    ) {
        switch reason {
        case .terminated, .notStarted, .startFailed:
            clearUpstreamState(upstreamIndex: upstreamIndex)
            if xcodeProcessRouteHasUsableInitializedUpstream(containing: upstreamIndex) == false {
                markXcodeProcessRouteUnavailable(
                    upstreamIndex: upstreamIndex,
                    reason: "upstream_\(reason)"
                )
            }
        case .shuttingDown:
            break
        }
    }

    func forwardServerRequestResponse(
        responseData: Data,
        sessionID: String,
        responseID: JSONRPC.ID,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ServerRequestResponseForwardingResult> {
        let promise = eventLoop.makePromise(of: ServerRequestResponseForwardingResult.self)
        let scheduled = addRuntimeTask { [weak self] in
            guard let self else {
                promise.succeed(.upstreamUnavailable)
                return
            }
            let result = await self.performServerRequestResponseForwarding(
                responseData: responseData,
                sessionID: sessionID,
                responseID: responseID
            )
            promise.succeed(result)
        }
        if !scheduled {
            promise.succeed(.upstreamUnavailable)
        }
        return promise.futureResult
    }

    private func performServerRequestResponseForwarding(
        responseData: Data,
        sessionID: String,
        responseID: JSONRPC.ID
    ) async -> ServerRequestResponseForwardingResult {
        guard let session = sessionRegistry.contextIfPresent(id: sessionID) else {
            return .missingRoute
        }
        guard let route = session.serverRequestTracker.lookup(clientID: responseID) else {
            logger.debug(
                "Acknowledging client JSON-RPC response without a routed upstream request",
                metadata: [
                    "session": .string(sessionID),
                    "id": .string(responseID.key),
                ]
            )
            return .missingRoute
        }
        guard let responseObject = try? JSONSerialization.jsonObject(
            with: responseData,
            options: []
        ) as? [String: Any] else {
            return .invalidResponse
        }
        guard let upstreamData = Self.rewriteServerRequestResponse(
            responseObject,
            id: route.upstreamID
        ) else {
            return .invalidResponse
        }

        switch await sendServerRequestResponseUpstream(
            upstreamData,
            upstreamIndex: route.upstreamIndex
        ) {
        case .accepted:
            _ = session.serverRequestTracker.complete(clientID: responseID, route: route)
            return .accepted
        case .backpressure, .unavailable:
            return .upstreamUnavailable
        }
    }

    private func sendServerRequestResponseUpstream(
        _ data: Data,
        upstreamIndex: Int
    ) async -> Upstream.SendResult {
        guard let context = upstreamSlotContext(upstreamIndex),
              upstreamTopology.validate(context.proof) else {
            return .unavailable(.notStarted)
        }
        switch await context.slot.send(data) {
        case .accepted:
            recordTraffic(
                upstreamIndex: upstreamIndex,
                direction: "outbound",
                data: data
            )
            return .accepted
        case .backpressure:
            markUpstreamOverloaded(context.proof)
            return .backpressure
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    private static func rewriteServerRequestResponse(
        _ responseObject: [String: Any],
        id: JSONRPC.ID
    ) -> Data? {
        try? JSONRPC.Wire.dataByReplacingID(in: responseObject, with: id)
    }

    func debugSnapshot() -> ProxyDebug.Snapshot {
        debugSnapshot(includeSensitiveDebugPayloads: false)
    }

    func debugSnapshot(includeSensitiveDebugPayloads: Bool) -> ProxyDebug.Snapshot {
        let initSnapshot = initializeManager.snapshot()
        let processSnapshot = processControlPlane.snapshot()
        let controlPlaneSnapshot = controlPlaneDebugMirror.snapshot()
        let upstreamStates = upstreamHealthManager.activeStatesSnapshot().map {
            (index: $0.id.rawValue, state: $0.state)
        }
        let leaseSnapshots = leaseManager.debugSnapshots()
        let sessionSnapshots = leaseManager.sessionDebugSnapshots(
            allSessionIDs: sessionRegistry.sessionIDs()
        )
        let schedulerSnapshot = upstreamSlotScheduler.debugSnapshot()
        let processToolCatalogs = processControlPlane.debugCatalogSnapshots(
            exposedCatalog: processSnapshot.canonicalToolsCatalogRaw,
            tabOwnerCountsByProcessID: windowOwnershipAuthority.snapshot()
                .tabOwnerCountsByProcessID(),
            workspaceOwnerCountsByProcessID: windowOwnershipAuthority.snapshot()
                .workspaceOwnerCountsByProcessID()
        )
        return debugRecorder.snapshot(
            proxyInitialized: initSnapshot.hasInitResult && !initSnapshot.isShuttingDown,
            cachedToolsListAvailable: processSnapshot.canonicalToolsCatalogRaw != nil,
            controlPlane: controlPlaneSnapshot,
            processRoutes: processControlPlane.debugRouteSnapshots(
                usableSlotCount: { [weak self] route in
                    guard let self else { return 0 }
                    return self.usableInitializedUpstreamIndices(in: route).count
                }
            ),
            processToolCatalogs: processToolCatalogs,
            upstreamStates: upstreamStates,
            sessionSnapshots: sessionSnapshots,
            leaseSnapshots: leaseSnapshots,
            queuedRequestCount: schedulerSnapshot.queuedRequestCount,
            redactedText: Self.redactedDebugText,
            includeSensitiveDebugPayloads: includeSensitiveDebugPayloads,
            healthFormatter: upstreamHealthManager.debugHealthStateString
        )
    }

    func createRequestLease(
        descriptor: SessionRequestPipeline.Descriptor
    ) -> LeaseManager.ID {
        leaseManager.createLease(descriptor: descriptor)
    }

    func activateRequestLease(
        _ leaseID: LeaseManager.ID,
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

    func completeRequestLease(_ leaseID: LeaseManager.ID) {
        releaseLeases([leaseManager.completeLease(leaseID)].compactMap { $0 })
    }

    func requeueRequestLease(_ leaseID: LeaseManager.ID) {
        releaseLeases([leaseManager.requeueLease(leaseID)].compactMap { $0 })
    }

    func failRequestLease(
        _ leaseID: LeaseManager.ID,
        terminalState: LeaseManager.State,
        reason: LeaseManager.ReleaseReason
    ) {
        releaseLeases(
            [leaseManager.failLease(leaseID, terminalState: terminalState, reason: reason)]
                .compactMap { $0 }
        )
    }

    func handleRequestLeaseTimeout(
        _ leaseID: LeaseManager.ID,
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

    func abandonRequestLease(
        _ leaseID: LeaseManager.ID,
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
        let upstreams = upstreamHealthManager.activeStatesSnapshot().map { _, upstream in
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

    /// Fails the requests pending on an undeliverable send by synthesizing
    /// the matching JSON-RPC error responses back through the router.
    func failPendingSend(
        originalRequestData: Data,
        upstreamIndex: Int,
        code: Int,
        message: String
    ) {
        guard let any = try? JSONSerialization.jsonObject(with: originalRequestData, options: [])
        else {
            return
        }

        let overloadError = JSONRPC.Wire.ErrorPayload(code: code, message: message)

        let responseAny: Any? = {
            if let object = any as? [String: Any] {
                guard let id = JSONRPC.Message.Inspector.requestID(from: object) else { return nil }
                return JSONRPC.Wire.errorResponseObject(id: id, error: overloadError)
            }
            if let array = any as? [Any] {
                let objects = array.compactMap { item -> [String: Any]? in
                    guard let object = item as? [String: Any],
                        let id = JSONRPC.Message.Inspector.requestID(from: object)
                    else {
                        return nil
                    }
                    return JSONRPC.Wire.errorResponseObject(id: id, error: overloadError)
                }
                if objects.isEmpty {
                    return nil
                }
                return objects
            }
            return nil
        }()

        guard let responseAny,
            let data = try? JSONRPC.Wire.data(from: responseAny)
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

    func upstreamID(from id: JSONRPC.ID) -> Int64? {
        upstreamID(from: id.value.foundationObject)
    }

    func isServerInitiatedMessage(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            switch JSONRPC.Message.Inspector.kind(of: object) {
            case .request, .notification:
                return true
            case .response, .malformed, .other:
                return false
            }
        }
        if let array = value as? [Any] {
            return array.contains { item in
                guard let object = item as? [String: Any] else { return false }
                switch JSONRPC.Message.Inspector.kind(of: object) {
                case .request, .notification:
                    return true
                case .response, .malformed, .other:
                    return false
                }
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

        let serverInitiatedPayloads = serverInitiatedPayloads(from: any, originalData: data)

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

        if routeServerInitiatedPayloads(
            serverInitiatedPayloads,
            upstreamIndex: upstreamIndex,
            sourceByteCount: data.count,
            owningTargetOverride: nil
        ) {
            return
        }
    }

    private func serverInitiatedPayload(from object: [String: Any]) -> ServerInitiatedPayload? {
        guard let encoded = try? JSONRPC.Wire.data(from: object) else {
            return nil
        }
        let kind = JSONRPC.Message.Inspector.kind(of: object)
        guard kind.isServerInitiated else {
            return nil
        }
        return ServerInitiatedPayload(
            data: encoded,
            object: object,
            expectsResponse: kind.requestID != nil
        )
    }

    private func serverInitiatedPayloads(
        from any: Any,
        originalData: Data
    ) -> [ServerInitiatedPayload] {
        if let object = any as? [String: Any] {
            let kind = JSONRPC.Message.Inspector.kind(of: object)
            guard kind.isServerInitiated else { return [] }
            return [
                ServerInitiatedPayload(
                    data: originalData,
                    object: object,
                    expectsResponse: kind.requestID != nil
                )
            ]
        }
        if let array = any as? [Any] {
            var payloads: [ServerInitiatedPayload] = []
            payloads.reserveCapacity(array.count)
            for item in array {
                guard let object = item as? [String: Any],
                    let payload = serverInitiatedPayload(from: object)
                else {
                    continue
                }
                payloads.append(payload)
            }
            return payloads
        }
        return []
    }

    private func routeUnmappedBatchItems(_ items: [Any], upstreamIndex: Int) {
        guard !items.isEmpty else {
            return
        }
        let payload: Any = items.count == 1 ? items[0] : items
        guard let data = try? JSONRPC.Wire.data(from: payload) else {
            return
        }
        routeUnmappedUpstreamMessage(data, upstreamIndex: upstreamIndex)
    }

    @discardableResult
    private func routeServerInitiatedPayloads(
        _ serverInitiatedPayloads: [ServerInitiatedPayload],
        upstreamIndex: Int,
        sourceByteCount: Int,
        owningTargetOverride: SessionContext?
    ) -> Bool {
        guard !serverInitiatedPayloads.isEmpty else {
            return false
        }

        var routedTargets: [SessionContext] = []
        var routedSessionIDs = Set<String>()
        var pendingInitializeTargets: [SessionContext] = []

        if isCurrentPrimaryInitializeUpstream(upstreamIndex) {
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
                pendingInitializeTargets.append(target)
                routedTargets.append(target)
            }
        }

        for target in sessionRegistry.activeNotificationTargets() {
            guard routedSessionIDs.insert(target.id).inserted else {
                continue
            }
            routedTargets.append(target)
        }

        for target in sessionRegistry.pendingNotificationClientTargets() {
            guard routedSessionIDs.insert(target.id).inserted else {
                continue
            }
            routedTargets.append(target)
        }

        let owningTarget =
            owningTargetOverride ?? activeLeaseSessionTarget(upstreamIndex: upstreamIndex)
        var routedAnyPayload = false

        for payload in serverInitiatedPayloads {
            let payloadTargets = serverInitiatedTargets(
                expectsResponse: payload.expectsResponse,
                owningTarget: owningTarget,
                pendingInitializeTargets: pendingInitializeTargets,
                routedTargets: routedTargets
            )
            if payload.expectsResponse && payloadTargets.isEmpty {
                logger.debug(
                    "Dropping response-requiring server request without an owning session",
                    metadata: [
                        "upstream": .string("\(upstreamIndex)"),
                        "bytes": .string("\(payload.data.count)"),
                    ]
                )
                continue
            }
            for session in payloadTargets {
                guard let routedData = payload.routedData(
                    for: session,
                    upstreamIndex: upstreamIndex
                ) else {
                    continue
                }
                session.router.handleIncoming(routedData)
                routedAnyPayload = true
            }
        }

        guard routedAnyPayload else {
            logger.debug(
                "Dropping unmapped upstream message (no routed target sessions)",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "bytes": .string("\(sourceByteCount)"),
                ]
            )
            debugRecorder.recordDroppedUnmappedNotification(upstreamIndex: upstreamIndex)
            return false
        }

        return true
    }

    private func activeLeaseSessionTarget(upstreamIndex: Int) -> SessionContext? {
        guard let sessionID = leaseManager.activeSessionID(upstreamIndex: upstreamIndex) else {
            return nil
        }
        return sessionRegistry.contextIfPresent(id: sessionID)
    }

    private func serverInitiatedTargets(
        expectsResponse: Bool,
        owningTarget: SessionContext?,
        pendingInitializeTargets: [SessionContext],
        routedTargets: [SessionContext]
    ) -> [SessionContext] {
        guard expectsResponse else {
            return routedTargets
        }
        if let owningTarget {
            return [owningTarget]
        }
        if pendingInitializeTargets.count == 1 {
            return pendingInitializeTargets
        }
        if routedTargets.count == 1 {
            return routedTargets
        }
        return []
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
        _ protocolViolation: StdioFramer.ProtocolViolation,
        upstreamIndex: Int,
        proof suppliedProof: UpstreamTopologyProof? = nil
    ) {
        let slotID = UpstreamSlotID(rawValue: upstreamIndex)
        guard let proof = suppliedProof ?? upstreamTopology.snapshot().proof(slotID),
              proof.slotID == slotID,
              upstreamTopology.validate(proof) else { return }
        debugRecorder.recordProtocolViolation(protocolViolation, upstreamIndex: upstreamIndex)
        let nowUptimeNs = nowUptimeNanoseconds()
        guard let transition = upstreamHealthManager.markProtocolViolation(
            proof,
            nowUptimeNs: nowUptimeNs
        ) else { return }
        let initSnapshot = initializeManager.snapshot()
        transition.cancelledInitTimeout?.cancel()
        let violatedActivePrimaryInitialize =
            initSnapshot.activePrimaryUpstreamIndex == upstreamIndex && initSnapshot.initInFlight
        upstreamRouter.reset(proof: proof)
        releaseLeases(
            leaseManager.abandonActiveLeases(
                upstreamIndex: upstreamIndex,
                reason: .stdoutProtocolViolation
            )
        )
        failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
        let quarantineUntil = transition.quarantineUntil
        logger.warning(
            "Upstream quarantined after stdout protocol violation",
            metadata: [
                "upstream": .string("\(upstreamIndex)"),
                "quarantine_until_uptime_ns": .string("\(quarantineUntil)"),
                "uptime_ns": .string("\(nowUptimeNs)"),
            ]
        )
        let clearInitialize = violatedActivePrimaryInitialize
            && initSnapshot.hasInitResult == false
        let clearToolsCatalog = toolsCatalogLostItsSource(upstreamIndex)
        if clearInitialize || clearToolsCatalog {
            invalidateControlPlane(
                reason: "protocol_violation_\(upstreamIndex)",
                clearInitialize: clearInitialize,
                clearToolsCatalog: clearToolsCatalog
            )
        }

        if violatedActivePrimaryInitialize {
            if retryPrimaryInitializeOnAlternativeUpstream(
                failedUpstreamIndex: upstreamIndex,
                failedUpstreamID: nil,
                reason: "primary_protocol_violation"
            ) {
                return
            }
            failInitPending(error: TimeoutError())
        }

        let primaryUpstreamIndex = initSnapshot.activePrimaryUpstreamIndex
            ?? canonicalHandshakeState.initializeSourceUpstream()
            ?? 0
        if upstreamIndex == primaryUpstreamIndex {
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

    func releaseLeases(_ actions: [LeaseManager.ReleaseAction]) {
        for action in actions {
            if let upstreamIndex = action.upstreamIndex {
                upstreamSlotScheduler.releaseUpstreamSlot(
                    upstreamIndex: upstreamIndex,
                    leaseID: action.leaseID
                )
            }
            failPendingRequestIfNeeded(for: action)
        }
    }

    private func failPendingRequestIfNeeded(for action: LeaseManager.ReleaseAction) {
        guard action.shouldFailPendingRequest,
              let requestIDKey = action.requestIDKey,
              let session = sessionRegistry.contextIfPresent(id: action.sessionID) else {
            return
        }
        _ = session.router.failPending(idKey: requestIDKey, error: pendingRequestError(for: action))
    }

    private func pendingRequestError(for action: LeaseManager.ReleaseAction) -> Error {
        switch action.reason {
        case .timedOut:
            return TimeoutError()
        case .clientDisconnected:
            return CancellationError()
        case .upstreamUnavailable, .upstreamExit, .upstreamOverloaded, .stdoutProtocolViolation:
            return UpstreamSlotScheduler.AcquisitionError.unavailable
        case .invalidUpstreamResponse, .lateResponse, .completed, nil:
            return ControlPlane.Error.invalidResponse("request released before response")
        }
    }
}
