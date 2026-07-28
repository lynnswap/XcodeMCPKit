import Foundation
import Logging
import NIO
import XcodeMCPKit

extension RuntimeCoordinator {
    private enum ServerInitiatedRoutingPolicy: Equatable {
        case serverRequest
        case operationOwnerNotification
        case broadcastNotification
    }

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
        let method: String
        let routingPolicy: ServerInitiatedRoutingPolicy
        let upstreamProgressToken: String?

        func routedData(
            for session: SessionContext,
            operationLease: UpstreamOperationLease,
            clientProgressToken: JSONValue?
        ) -> Data? {
            if let clientProgressToken {
                guard var params = object["params"] as? [String: Any] else {
                    return nil
                }
                params["progressToken"] = clientProgressToken.foundationObject
                var routedObject = object
                routedObject["params"] = params
                return try? JSONRPC.Wire.data(from: routedObject)
            }
            guard case .request(_, let upstreamID) =
                JSONRPC.Message.Inspector.kind(of: object)
            else {
                return data
            }
            let clientID = session.serverRequestTracker.record(
                upstreamID: upstreamID,
                operationLease: operationLease
            )
            return try? JSONRPC.Wire.dataByReplacingID(in: object, with: clientID)
        }
    }

    func routeUpstreamMessage(
        _ data: Data,
        upstreamIndex: Int,
        proof: UpstreamTopologyProof
    ) {
        let slotID = UpstreamSlotID(rawValue: upstreamIndex)
        guard proof.slotID == slotID,
              let operationLease = upstreamTopology.operationLease(for: proof) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            guard upstreamTopology.validate(proof) else { return }
            routeUnmappedUpstreamMessage(data, operationLease: operationLease)
            return
        }

        if let object = json as? [String: Any] {
            switch mappedResponseRoutingOutcome(
                object,
                upstreamIndex: upstreamIndex,
                proof: proof
            ) {
            case .routed(let sessionID, let object):
                if deliverClientResponseObject(
                    object,
                    sessionID: sessionID,
                    upstreamIndex: upstreamIndex
                ) {
                    return
                }
            case .handled, .late:
                return
            case .unmappedResponse, .notResponse:
                break
            }
            guard upstreamTopology.validate(proof) else { return }
            routeUnmappedUpstreamMessage(data, operationLease: operationLease)
            return
        }

        routeUnmappedUpstreamMessage(data, operationLease: operationLease)
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

    private func deliverClientResponseObject(
        _ object: [String: Any],
        sessionID: String,
        upstreamIndex: Int
    ) -> Bool {
        guard let data = try? JSONRPC.Wire.data(from: object) else {
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

    func handleUpstreamExit(
        _ status: Int32,
        upstreamIndex: Int,
        proof: UpstreamTopologyProof
    ) {
        let slotID = UpstreamSlotID(rawValue: upstreamIndex)
        guard proof.slotID == slotID,
              upstreamTopology.validate(proof) else { return }
        let bridgeRecovery = upstreamHealthManager.currentBridgeRecovery(for: proof)
        guard clearUpstreamState(proof: proof) else { return }
        let globalInit = initializeManager.handleUpstreamExit(upstreamIndex: upstreamIndex)
        guard let globalInit else { return }
        let suppressProcessRouteWarmRestart =
            clearsInitializedProcessRouteActivationBeforeCatalog(upstreamIndex: upstreamIndex)

        let exitedActivePrimaryInitialize =
            globalInit.primaryInitUpstreamIndex == upstreamIndex && globalInit.wasInFlight
        if exitedActivePrimaryInitialize {
            if let upstreamID = globalInit.primaryInitUpstreamID {
                upstreamRouter.remove(proof: proof, upstreamID: upstreamID)
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

        if let bridgeRecovery, exitedActivePrimaryInitialize == false {
            replaceProcessBridgeRecoveryChannelAndScheduleRetry(
                bridgeRecovery,
                reason: "upstream_exit_\(status)"
            )
            failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
            return
        }

        if exitedActivePrimaryInitialize {
            if retryPrimaryInitializeOnAlternativeUpstream(
                failedUpstreamIndex: upstreamIndex,
                failedUpstreamID: nil,
                reason: "primary_upstream_exit_\(status)"
            ) {
                return
            }
            guard let failure = initializeManager.completePrimaryInitializeFailure() else {
                return
            }
            failure.timeout?.cancel()
            failure.recoveryTimeout?.cancel()
            for item in failure.pending {
                removePendingInitializeSessionIfCurrent(item)
                item.eventLoop.execute {
                    item.promise.fail(TimeoutError())
                }
            }
        }

        let shouldResetGlobalInit: Bool
        if globalInit.hadGlobalInit {
            shouldResetGlobalInit = canonicalHandshakeState.initializeResult() == nil
                && canonicalHandshakeState.hasInitializeParticipants() == false
                && anyActiveRecoveryInFlight() == false
        } else {
            shouldResetGlobalInit = false
        }
        if shouldResetGlobalInit {
            initializeManager.resetWarmSecondaryForRetry()
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
                    || upstreamHealthManager.state(
                        for: UpstreamSlotID(rawValue: primaryUpstreamIndex)
                    )?.initInFlight == true
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

        if canonicalHandshakeState.initializeResult() == nil,
           anyActiveInitializedUpstream() == false {
            if anyActiveRecoveryInFlight() {
                initializeManager
                    .setWarmInitRecoveryIntent(.retryPrimaryWhenNoCachedInitialize)
            } else {
                startEagerInitializePrimary(applyBackoff: true)
            }
        }
    }

    func assignUpstreamID(
        sessionID: String,
        originalID: JSONRPC.ID,
        operationLease: UpstreamOperationLease
    ) -> Int64? {
        upstreamRouter.assign(
            proof: operationLease.proof,
            sessionID: sessionID,
            originalID: originalID,
            isInitialize: false
        )
    }

    func removeUpstreamIDMapping(
        sessionID: String,
        requestIDKey: String,
        operationLease: UpstreamOperationLease
    ) {
        _ = upstreamRouter.remove(
            proof: operationLease.proof,
            sessionID: sessionID,
            requestIDKey: requestIDKey
        )
    }

    private func cancelUpstreamRequest(
        sessionID: String,
        requestIDKey: String,
        operationLease: UpstreamOperationLease,
        after requestSendCompletion: AsyncTerminalSignal? = nil
    ) -> ControlPlane.RPCCancellationDelivery? {
        guard let upstreamID = upstreamRouter.remove(
            proof: operationLease.proof,
            sessionID: sessionID,
            requestIDKey: requestIDKey
        ), let data = try? JSONRPC.Wire.data(
            from: JSONRPC.Wire.notificationObject(
                method: "notifications/cancelled",
                params: .object([
                    "requestId": .number(.int(upstreamID))
                ])
            )
        ) else {
            return nil
        }
        let delivery = ControlPlane.RPCCancellationDelivery()
        let scheduled = addRuntimeTask {
            [weak self, operationLease, requestSendCompletion] in
            await requestSendCompletion?.wait()
            guard let self else {
                delivery.complete(.noLongerApplicable)
                return
            }
            guard self.upstreamTopology.validate(operationLease) else {
                delivery.complete(.noLongerApplicable)
                return
            }
            let result = await operationLease.slot.send(data)
            guard self.upstreamTopology.validate(operationLease) else {
                delivery.complete(.noLongerApplicable)
                return
            }
            switch result {
            case .accepted:
                self.recordTraffic(
                    upstreamIndex: operationLease.upstreamIndex,
                    direction: "outbound",
                    data: data
                )
                delivery.complete(.delivered)
            case .backpressure:
                self.markUpstreamOverloaded(operationLease.proof)
                delivery.complete(.rejected)
            case .unavailable(let reason):
                self.handleUnavailableUpstreamSend(
                    operationLease: operationLease,
                    reason: reason
                )
                delivery.complete(.noLongerApplicable)
            }
        }
        if scheduled == false {
            delivery.complete(.rejected)
        }
        return delivery
    }

    private func cancellationDelivery(
        waitingFor deliveries: [ControlPlane.RPCCancellationDelivery]
    ) -> ControlPlane.RPCCancellationDelivery? {
        guard deliveries.isEmpty == false else { return nil }
        guard deliveries.count > 1 else { return deliveries[0] }
        let aggregate = ControlPlane.RPCCancellationDelivery()
        let scheduled = addRuntimeTask {
            var result = ControlPlane.RPCCancellationDelivery.Result.delivered
            for delivery in deliveries {
                let next = await delivery.wait()
                if next == .rejected {
                    result = .rejected
                } else if next == .noLongerApplicable, result == .delivered {
                    result = .noLongerApplicable
                }
            }
            aggregate.complete(result)
        }
        if scheduled == false {
            aggregate.complete(.rejected)
        }
        return aggregate
    }

    func onRequestTimeout(
        sessionID: String,
        requestIDKey: String,
        operationLease: UpstreamOperationLease
    ) {
        _ = cancelUpstreamRequest(
            sessionID: sessionID,
            requestIDKey: requestIDKey,
            operationLease: operationLease
        )
        markRequestTimedOut(operationLease)
    }

    func onRequestSucceeded(
        sessionID: String,
        requestIDKey: String,
        operationLease: UpstreamOperationLease
    ) {
        _ = sessionID
        _ = requestIDKey
        markRequestSucceeded(operationLease)
    }

    @discardableResult
    func sendUpstream(
        _ data: Data,
        operationLease: UpstreamOperationLease,
        ensureRunning: Bool,
        admission: RouteForwardingAdmission?,
        onRejected: @escaping @Sendable () -> Void
    ) -> Bool {
        sendUpstream(
            data,
            operationLease: operationLease,
            ensureRunning: ensureRunning,
            admission: admission,
            requestSendCompletion: nil,
            onRejected: onRejected
        )
    }

    @discardableResult
    func sendUpstream(
        _ data: Data,
        operationLease: UpstreamOperationLease,
        ensureRunning: Bool,
        admission: RouteForwardingAdmission?,
        requestSendCompletion: AsyncTerminalSignal?,
        onRejected: @escaping @Sendable () -> Void
    ) -> Bool {
        let upstreamIndex = operationLease.upstreamIndex
        guard upstreamTopology.validate(operationLease) else {
            onRejected()
            requestSendCompletion?.signal()
            return false
        }
        if let admission {
            guard processControlPlane.validate(admission.route),
                  admission.proof(for: upstreamIndex) == operationLease.proof else {
                onRejected()
                requestSendCompletion?.signal()
                return false
            }
        }
        let scheduled = addRuntimeTask {
            [weak self, operationLease, admission, requestSendCompletion, onRejected] in
            defer { requestSendCompletion?.signal() }
            guard let self else { return }
            if ensureRunning {
                await operationLease.slot.start()
            }
            guard self.upstreamTopology.validate(operationLease) else {
                onRejected()
                return
            }
            if let admission {
                guard self.processControlPlane.validate(admission.route),
                      admission.proof(for: upstreamIndex) == operationLease.proof else {
                    onRejected()
                    return
                }
            }
            let result = await operationLease.slot.send(data)
            guard self.upstreamTopology.validate(operationLease) else {
                onRejected()
                return
            }
            switch result {
            case .accepted:
                self.recordTraffic(
                    upstreamIndex: upstreamIndex,
                    direction: "outbound",
                    data: data
                )
            case .backpressure:
                self.markUpstreamOverloaded(operationLease.proof)
                self.failPendingSend(
                    originalRequestData: data,
                    proof: operationLease.proof,
                    code: -32002,
                    message: "upstream overloaded"
                )
            case .unavailable(let reason):
                self.failPendingSend(
                    originalRequestData: data,
                    proof: operationLease.proof,
                    code: -32001,
                    message: "upstream unavailable"
                )
                self.handleUnavailableUpstreamSend(
                    operationLease: operationLease,
                    reason: reason
                )
            }
        }
        if scheduled == false {
            onRejected()
            requestSendCompletion?.signal()
        }
        return scheduled
    }

    private func handleUnavailableUpstreamSend(
        operationLease: UpstreamOperationLease,
        reason: Upstream.UnavailableReason
    ) {
        let upstreamIndex = operationLease.upstreamIndex
        switch reason {
        case .terminated, .notStarted, .startFailed:
            let bridgeRecovery = upstreamHealthManager.currentBridgeRecovery(
                for: operationLease.proof
            )
            guard clearUpstreamState(
                proof: operationLease.proof,
                resetsProcessRouteActivation: bridgeRecovery == nil
            ) else { return }
            if let bridgeRecovery {
                replaceProcessBridgeRecoveryChannelAndScheduleRetry(
                    bridgeRecovery,
                    reason: "upstream_\(reason)"
                )
                failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
                return
            }
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
            operationLease: route.operationLease
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
        operationLease: UpstreamOperationLease
    ) async -> Upstream.SendResult {
        guard upstreamTopology.validate(operationLease) else {
            return .unavailable(.notStarted)
        }
        let result = await operationLease.slot.send(data)
        guard upstreamTopology.validate(operationLease) else {
            return .unavailable(.notStarted)
        }
        switch result {
        case .accepted:
            recordTraffic(
                upstreamIndex: operationLease.upstreamIndex,
                direction: "outbound",
                data: data
            )
            return .accepted
        case .backpressure:
            markUpstreamOverloaded(operationLease.proof)
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
        timeout: TimeAmount?,
        progressTokenMapping: ProgressTokenMapping? = nil
    ) {
        let timeoutAt = timeout.map {
            Date().addingTimeInterval(Double($0.nanoseconds) / 1_000_000_000)
        }
        leaseManager.activateLease(
            leaseID,
            requestIDKey: requestIDKey,
            upstreamIndex: upstreamIndex,
            timeoutAt: timeoutAt,
            progressTokenMapping: progressTokenMapping
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
        operationLease: UpstreamOperationLease
    ) {
        _ = handleRequestLeaseTimeoutWithCancellationDelivery(
            leaseID,
            sessionID: sessionID,
            requestIDKeys: requestIDKeys,
            operationLease: operationLease
        )
    }

    func handleRequestLeaseTimeoutWithCancellationDelivery(
        _ leaseID: LeaseManager.ID,
        sessionID: String,
        requestIDKeys: [String],
        operationLease: UpstreamOperationLease?,
        after requestSendCompletion: AsyncTerminalSignal? = nil
    ) -> ControlPlane.RPCCancellationDelivery? {
        var cancellationDeliveries: [ControlPlane.RPCCancellationDelivery] = []
        if let operationLease, let first = requestIDKeys.first {
            if let delivery = cancelUpstreamRequest(
                sessionID: sessionID,
                requestIDKey: first,
                operationLease: operationLease,
                after: requestSendCompletion
            ) {
                cancellationDeliveries.append(delivery)
            }
            for requestIDKey in requestIDKeys.dropFirst() {
                if let delivery = cancelUpstreamRequest(
                    sessionID: sessionID,
                    requestIDKey: requestIDKey,
                    operationLease: operationLease,
                    after: requestSendCompletion
                ) {
                    cancellationDeliveries.append(delivery)
                }
            }
            markRequestTimedOut(operationLease)
        }
        upstreamSlotScheduler.cancelQueuedRequest(leaseID: leaseID)
        releaseLeases([leaseManager.timeoutLease(leaseID)].compactMap { $0 })
        return cancellationDelivery(waitingFor: cancellationDeliveries)
    }

    func abandonRequestLease(
        _ leaseID: LeaseManager.ID,
        sessionID: String,
        requestIDKeys: [String],
        operationLease: UpstreamOperationLease?
    ) {
        _ = abandonRequestLeaseWithCancellationDelivery(
            leaseID,
            sessionID: sessionID,
            requestIDKeys: requestIDKeys,
            operationLease: operationLease
        )
    }

    func abandonRequestLeaseWithCancellationDelivery(
        _ leaseID: LeaseManager.ID,
        sessionID: String,
        requestIDKeys: [String],
        operationLease: UpstreamOperationLease?,
        after requestSendCompletion: AsyncTerminalSignal? = nil
    ) -> ControlPlane.RPCCancellationDelivery? {
        var deliveries: [ControlPlane.RPCCancellationDelivery] = []
        if let operationLease {
            for requestIDKey in requestIDKeys {
                if let delivery = cancelUpstreamRequest(
                    sessionID: sessionID,
                    requestIDKey: requestIDKey,
                    operationLease: operationLease,
                    after: requestSendCompletion
                ) {
                    deliveries.append(delivery)
                }
            }
        }
        upstreamSlotScheduler.cancelQueuedRequest(leaseID: leaseID)
        upstreamSlotScheduler.releaseUpstreamSlot(leaseID: leaseID)
        releaseLeases(
            [leaseManager.failLease(
                leaseID,
                terminalState: .abandoned,
                reason: .clientDisconnected
            )].compactMap { $0 }
        )
        return cancellationDelivery(waitingFor: deliveries)
    }

    func testStateSnapshot() -> TestSnapshot {
        let initSnapshot = initializeManager.snapshot()
        let upstreams = upstreamHealthManager.activeStatesSnapshot().map { id, upstream in
            TestSnapshot.Upstream(
                id: id.rawValue,
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
        proof: UpstreamTopologyProof,
        code: Int,
        message: String
    ) {
        let upstreamIndex = proof.slotID.rawValue
        guard let any = try? JSONSerialization.jsonObject(with: originalRequestData, options: [])
        else {
            return
        }

        let overloadError = JSONRPC.Wire.ErrorPayload(code: code, message: message)

        guard let object = any as? [String: Any],
            let id = JSONRPC.Message.Inspector.requestID(from: object),
            let data = try? JSONRPC.Wire.data(
                from: JSONRPC.Wire.errorResponseObject(id: id, error: overloadError)
            )
        else {
            return
        }

        routeUpstreamMessage(data, upstreamIndex: upstreamIndex, proof: proof)
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

    func routeUnmappedUpstreamMessage(
        _ data: Data,
        operationLease: UpstreamOperationLease
    ) {
        let upstreamIndex = operationLease.upstreamIndex
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

        guard let object = any as? [String: Any],
              let serverInitiatedPayload = serverInitiatedPayload(
                from: object,
                originalData: data
              ) else {
            logger.debug(
                "Dropping unmapped upstream response",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "bytes": .string("\(data.count)"),
                ]
            )
            return
        }

        if routeServerInitiatedPayload(
            serverInitiatedPayload,
            operationLease: operationLease,
            sourceByteCount: data.count,
            owningTargetOverride: nil
        ) {
            return
        }
    }

    private func serverInitiatedPayload(
        from object: [String: Any],
        originalData: Data
    ) -> ServerInitiatedPayload? {
        let kind = JSONRPC.Message.Inspector.kind(of: object)
        let method: String
        let routingPolicy: ServerInitiatedRoutingPolicy
        switch kind {
        case .request(let requestMethod, _):
            method = requestMethod
            routingPolicy = .serverRequest
        case .notification(let notificationMethod):
            method = notificationMethod
            routingPolicy =
                notificationMethod == "notifications/progress"
                ? .operationOwnerNotification
                : .broadcastNotification
        case .response, .malformed, .other:
            return nil
        }
        return ServerInitiatedPayload(
            data: originalData,
            object: object,
            method: method,
            routingPolicy: routingPolicy,
            upstreamProgressToken: routingPolicy == .operationOwnerNotification
                ? Self.progressToken(from: object)
                : nil
        )
    }

    private static func progressToken(from object: [String: Any]) -> String? {
        guard let params = object["params"] as? [String: Any] else { return nil }
        return params["progressToken"] as? String
    }

    @discardableResult
    private func routeServerInitiatedPayload(
        _ serverInitiatedPayload: ServerInitiatedPayload,
        operationLease: UpstreamOperationLease,
        sourceByteCount: Int,
        owningTargetOverride: SessionContext?
    ) -> Bool {
        let upstreamIndex = operationLease.upstreamIndex
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

        for target in sessionRegistry.initializedNotificationTargets() {
            guard routedSessionIDs.insert(target.id).inserted else {
                continue
            }
            routedTargets.append(target)
        }

        let progressTarget: LeaseManager.ProgressTarget?
        let owningTarget: SessionContext?
        if serverInitiatedPayload.routingPolicy == .operationOwnerNotification {
            progressTarget = serverInitiatedPayload.upstreamProgressToken.flatMap {
                leaseManager.activeProgressTarget(
                    upstreamIndex: upstreamIndex,
                    upstreamToken: $0
                )
            }
            owningTarget = progressTarget.flatMap {
                sessionRegistry.contextIfPresent(id: $0.sessionID)
            }
        } else {
            progressTarget = nil
            owningTarget =
                owningTargetOverride ?? activeLeaseSessionTarget(upstreamIndex: upstreamIndex)
        }
        let payloadTargets = serverInitiatedTargets(
            routingPolicy: serverInitiatedPayload.routingPolicy,
            owningTarget: owningTarget,
            pendingInitializeTargets: pendingInitializeTargets,
            routedTargets: routedTargets
        )
        if serverInitiatedPayload.routingPolicy == .serverRequest && payloadTargets.isEmpty {
            logger.debug(
                "Dropping response-requiring server request without an owning session",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "method": .string(serverInitiatedPayload.method),
                    "bytes": .string("\(serverInitiatedPayload.data.count)"),
                ]
            )
            return false
        }

        var routedAnyPayload = false
        for session in payloadTargets {
            guard let routedData = serverInitiatedPayload.routedData(
                for: session,
                operationLease: operationLease,
                clientProgressToken: progressTarget?.clientToken
            ) else {
                continue
            }
            session.router.handleIncoming(routedData)
            routedAnyPayload = true
        }

        guard routedAnyPayload else {
            logger.debug(
                "Dropping unmapped upstream message (no routed target sessions)",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "method": .string(serverInitiatedPayload.method),
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
        routingPolicy: ServerInitiatedRoutingPolicy,
        owningTarget: SessionContext?,
        pendingInitializeTargets: [SessionContext],
        routedTargets: [SessionContext]
    ) -> [SessionContext] {
        switch routingPolicy {
        case .broadcastNotification:
            return routedTargets
        case .operationOwnerNotification:
            return owningTarget.map { [$0] } ?? []
        case .serverRequest:
            break
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
        proof: UpstreamTopologyProof
    ) {
        let slotID = UpstreamSlotID(rawValue: upstreamIndex)
        guard proof.slotID == slotID,
              upstreamTopology.validate(proof) else { return }
        let bridgeRecovery = upstreamHealthManager.currentBridgeRecovery(for: proof)
        debugRecorder.recordProtocolViolation(protocolViolation, upstreamIndex: upstreamIndex)
        let nowUptimeNs = nowUptimeNanoseconds()
        let initSnapshot = initializeManager.snapshot()
        let wasCanonicalSource = canonicalHandshakeState.initializeSourceUpstream()
            == upstreamIndex
        guard let transition = commitVerifiedHealthSupportMutation(
            proof: proof,
            detachedProof: proof,
            mutation: {
                upstreamHealthManager.markProtocolViolation(
                    proof,
                    nowUptimeNs: nowUptimeNs
                )
            }
        ) else { return }
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
        if let bridgeRecovery {
            replaceProcessBridgeRecoveryChannelAndScheduleRetry(
                bridgeRecovery,
                reason: "stdout_protocol_violation"
            )
            return
        }
        if processRoutingEnabled,
           let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex) {
            startProcessRouteActivation(for: route)
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

        if processRoutingEnabled {
            return
        }
        let primaryUpstreamIndex = initSnapshot.activePrimaryUpstreamIndex ?? 0
        if upstreamIndex == primaryUpstreamIndex {
            if initSnapshot.hasInitResult || wasCanonicalSource {
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
            upstreamSlotScheduler.releaseUpstreamSlot(
                upstreamIndex: action.upstreamIndex,
                leaseID: action.leaseID
            )
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
