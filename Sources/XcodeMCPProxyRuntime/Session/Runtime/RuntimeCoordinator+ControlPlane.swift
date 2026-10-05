import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import XcodeMCPCore

extension ControlPlane {
    enum Error: Swift.Error, Sendable {
        case invalidResponse(String)
        case upstreamRPC(code: Int, message: String)
        case proxyFailure(code: Int, message: String)

        init(rpc error: JSONRPC.Wire.ErrorPayload) {
            if (error.code == -32001 && error.message == "upstream unavailable")
                || (error.code == -32002 && error.message == "upstream overloaded") {
                self = .proxyFailure(code: error.code, message: error.message)
            } else {
                self = .upstreamRPC(code: error.code, message: error.message)
            }
        }

        var isProxyFailure: Bool {
            if case .proxyFailure = self { return true }
            return false
        }
    }
}

extension ControlPlane {
    struct RequestError: Swift.Error, Sendable {
        let route: ControlPlane.Route
        let operationLease: UpstreamOperationLease?
        private let requestedUpstreamIndex: Int?
        let underlying: any Swift.Error

        var upstreamIndex: Int? { operationLease?.upstreamIndex ?? requestedUpstreamIndex }

        init(
            route: ControlPlane.Route,
            operationLease: UpstreamOperationLease?,
            underlying: any Swift.Error
        ) {
            self.route = route
            self.operationLease = operationLease
            self.requestedUpstreamIndex = nil
            self.underlying = underlying
        }

        init(
            route: ControlPlane.Route,
            upstreamIndex: Int?,
            underlying: any Swift.Error
        ) {
            self.route = route
            self.operationLease = nil
            self.requestedUpstreamIndex = upstreamIndex
            self.underlying = underlying
        }
    }
}

extension ControlPlane {
    struct RPCResponse: Sendable {
        let responseData: Data
        let operationLease: UpstreamOperationLease

        var upstreamIndex: Int { operationLease.upstreamIndex }
    }
}

/// The one place that decides which JSON-RPC error a control-plane or
/// upstream-acquisition failure surfaces as.
extension ControlPlane {
    enum ErrorMapper {
        static func underlyingError(_ error: Swift.Error) -> Swift.Error {
            if let requestError = error as? ControlPlane.RequestError {
                return underlyingError(requestError.underlying)
            }
            return error
        }

        static func jsonRPCError(for error: Swift.Error) -> (code: Int, message: String) {
            let error = underlyingError(error)
            if error is TimeoutError {
                return (-32000, "upstream timeout")
            }
            if error is CancellationError {
                return (-32800, "request cancelled")
            }
            if error is UpstreamSlotScheduler.AcquisitionError {
                return (-32001, "upstream unavailable")
            }
            if case ProxyUpstreamRequestRuntime.Error.staleUpstreamTopology = error {
                return (-32001, "upstream unavailable")
            }
            if let error = error as? ControlPlane.Error {
                switch error {
                case .invalidResponse:
                    return (-32603, "invalid upstream response")
                case .upstreamRPC(let code, let message), .proxyFailure(let code, let message):
                    return (code, message)
                }
            }
            return (-32603, "upstream request failed")
        }
    }
}

extension RuntimeCoordinator {
    func loadCanonicalToolsCatalog(
        requestTimeout: TimeAmount?,
        rpcHandle: ControlPlane.RPCHandle
    ) async throws -> CanonicalToolsCatalogLoadResult {
        let startedAt = nowUptimeNanoseconds()
        guard let source = chooseUpstreamOperationLease() else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        var load: (CatalogLease, CatalogTransition)?
        guard initializeManager.performIfRunning({
            load = toolsCatalog.beginLoad(sourceProof: source.proof)
        }), let (lease, transition) = load else { throw CancellationError() }
        applyCatalogTransition(transition)
        applyCatalogTransition(toolsCatalog.attach(rpcHandle, to: lease))
        do {
            let result = try await loadCanonicalToolsCatalogFromRoute(
                .pinnedUpstream(source.upstreamIndex),
                requestTimeout: requestTimeout,
                rpcHandle: rpcHandle,
                startedAt: startedAt,
                purpose: "tools"
            )
            guard let proof = result.sourceProof else {
                throw ControlPlane.Error.invalidResponse("tools/list source upstream missing")
            }
            let provider = ToolCatalogProvider(sourceProof: proof, rawResult: result.rawResult)
            let commit = upstreamTopology.withValidated(proof) {
                upstreamHealthManager.withUsableInitializedSource(proof) {
                    toolsCatalog.complete(provider, lease: lease)
                }
            } ?? nil
            switch commit {
            case .accepted(let snapshot, let transition):
                applyCatalogTransition(transition)
                testHooks.nativeToolsCatalogCommitted?(proof.slotID.rawValue)
                guard let raw = snapshot.canonicalToolsCatalogRaw else {
                    throw UpstreamSlotScheduler.AcquisitionError.unavailable
                }
                return CanonicalToolsCatalogLoadResult(
                    rawResult: raw, sourceProof: snapshot.canonicalSourceProof,
                    durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt))
            case .discarded(let transition):
                applyCatalogTransition(transition)
            case nil:
                break
            }
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        } catch {
            switch toolsCatalog.complete(nil, lease: lease) {
            case .accepted(_, let transition), .discarded(let transition):
                applyCatalogTransition(transition)
            }
            try Task.checkCancellation()
            if let provider = toolsCatalog.satisfiedCatalogProvider(for: lease) {
                return CanonicalToolsCatalogLoadResult(
                    rawResult: provider.rawResult, sourceProof: provider.sourceProof,
                    durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt))
            }
            if ControlPlane.ErrorMapper.underlyingError(error) is CancellationError {
                throw UpstreamSlotScheduler.AcquisitionError.unavailable
            }
            throw error
        }
    }

    func loadToolsCatalogFromRoute(
        _ route: ControlPlane.Route,
        requestTimeout: TimeAmount?,
        rpcHandle: ControlPlane.RPCHandle,
        startedAt: UInt64,
        purpose: String,
        label: String = "tools/list"
    ) async throws -> CanonicalToolsCatalogLoadResult {
        let deadline = deadlineUptimeNanoseconds(for: requestTimeout)
        let currentPage = NIOLockedValueBox<ControlPlane.RPCHandle?>(nil)
        guard rpcHandle.installCancelWithDelivery({ [self] snapshot, delivery in
            guard let page = currentPage.withLockedValue({ $0 }),
                  let pageDelivery = page.cancel(cause: snapshot.cause) else {
                delivery.complete(.noLongerApplicable)
                return
            }
            if addRuntimeTask({ delivery.complete(await pageDelivery.wait()) }) == false {
                delivery.complete(.rejected)
            }
        }) else {
            throw CancellationError()
        }
        defer { rpcHandle.markFinished() }
        var sourceProof: UpstreamTopologyProof?
        var pageRoute = route
        var pagination = ToolsListPagination()
        repeat {
            try Task.checkCancellation()
            let pageHandle = ControlPlane.RPCHandle()
            currentPage.withLockedValue { $0 = pageHandle }
            guard rpcHandle.isCancelled() == false else {
                throw CancellationError()
            }
            let remainingTimeout = timeAmount(until: deadline)
            guard remainingTimeout?.nanoseconds != 0 else { throw TimeoutError() }
            let response = try await performControlPlaneRPC(
                route: pageRoute,
                purpose: purpose,
                label: label,
                requestObject: JSONRPC.Wire.requestObject(
                    id: "__control-plane-tools-\(UUID().uuidString)",
                    method: "tools/list",
                    params: pagination.nextCursor.map { .object(["cursor": .string($0)]) }
                ),
                requestTimeout: remainingTimeout,
                rpcHandle: pageHandle,
                expectedUpstreamProof: sourceProof
            )
            sourceProof = response.operationLease.proof
            pageRoute = .pinnedUpstream(response.upstreamIndex)
            do {
                try pagination.append(extractJSONRPCResult(from: response.responseData))
            } catch {
                throw ControlPlane.RequestError(
                    route: pageRoute,
                    operationLease: response.operationLease,
                    underlying: error
                )
            }
        } while pagination.nextCursor != nil
        try Task.checkCancellation()
        guard rpcHandle.isCancelled() == false, let sourceProof else {
            throw CancellationError()
        }
        return CanonicalToolsCatalogLoadResult(
            rawResult: pagination.result,
            sourceProof: sourceProof,
            durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt)
        )
    }

    private func loadCanonicalToolsCatalogFromRoute(
        _ route: ControlPlane.Route,
        requestTimeout: TimeAmount?,
        rpcHandle: ControlPlane.RPCHandle,
        startedAt: UInt64,
        purpose: String
    ) async throws -> CanonicalToolsCatalogLoadResult {
        let nowUptimeNs = nowUptimeNanoseconds()
        do {
            let result = try await loadToolsCatalogFromRoute(
                route,
                requestTimeout: requestTimeout,
                rpcHandle: rpcHandle,
                startedAt: startedAt,
                purpose: purpose
            )
            if let proof = result.sourceProof {
                markToolsListRefreshSucceeded(proof, nowUptimeNs: nowUptimeNs)
            }
            return result
        } catch let error as ControlPlane.RequestError {
            if error.underlying is CancellationError {
                throw error.underlying
            }
            if let proof = error.operationLease?.proof {
                if case ControlPlane.Error.upstreamRPC = error.underlying {
                    // A valid RPC error reports an operation failure, not a broken connection.
                    testHooks.toolsListRefreshCompleted?(proof.slotID.rawValue, false)
                } else {
                    markToolsListRefreshFailed(
                        proof,
                        nowUptimeNs: nowUptimeNs,
                        reason: controlPlaneFailureReason(for: error.underlying)
                    )
                }
            }
            throw error.underlying
        }
    }

    func performControlPlaneRPC(
        route: ControlPlane.Route,
        purpose: String,
        label: String,
        requestObject: [String: Any],
        requestTimeout: TimeAmount?,
        rpcHandle: ControlPlane.RPCHandle? = nil,
        expectedUpstreamProof: UpstreamTopologyProof? = nil,
        responseIDOverride: JSONRPC.ID? = nil,
        throwsOnRPCError: Bool = true
    ) async throws -> ControlPlane.RPCResponse {
        let preferredUpstreamIndices: [Int]?
        switch route {
        case .anyHealthy:
            preferredUpstreamIndices = nil
        case .pinnedUpstream(let index):
            preferredUpstreamIndices = [index]

        }
        let requestDeadlineUptimeNs = deadlineUptimeNanoseconds(for: requestTimeout)
        let internalSessionID = controlPlaneSessionID(for: purpose, route: route)
        let session = session(id: internalSessionID)
        let router = session.router
        guard let originalID = JSONRPC.Message.Inspector.requestID(from: requestObject) else {
            throw ControlPlane.Error.invalidResponse("missing request id")
        }
        let rpcHandle = rpcHandle ?? ControlPlane.RPCHandle()
        let requestTemplate = requestObject.reduce(into: [String: JSONValue]()) { partial, entry in
            if entry.key == "id" { return }
            if let value = JSONValue(any: entry.value) {
                partial[entry.key] = value
            }
        }
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: internalSessionID,
            label: label,
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let leaseID = createRequestLease(descriptor: descriptor)
        let installedCancellationHandler = rpcHandle.installCancelWithDelivery {
            [self, router] snapshot, cancellationDelivery in
            if let registrationToken = snapshot.registrationToken {
                _ = router.cancelPending(token: registrationToken)
            }
            let requestIDKeys = snapshot.requestIDKey.map { [$0] } ?? [originalID.key]
            let upstreamDelivery: ControlPlane.RPCCancellationDelivery?
            switch snapshot.cause {
            case .cancelled:
                upstreamDelivery = self.abandonRequestLeaseWithCancellationDelivery(
                    leaseID,
                    sessionID: internalSessionID,
                    requestIDKeys: requestIDKeys,
                    operationLease: snapshot.operationLease,
                    after: snapshot.requestSendCompletion
                )
            case .timedOut:
                upstreamDelivery = self.handleRequestLeaseTimeoutWithCancellationDelivery(
                    leaseID,
                    sessionID: internalSessionID,
                    requestIDKeys: requestIDKeys,
                    operationLease: snapshot.operationLease,
                    after: snapshot.requestSendCompletion
                )
            }
            guard let upstreamDelivery else {
                cancellationDelivery.complete(.noLongerApplicable)
                return
            }
            let scheduled = self.addRuntimeTask {
                cancellationDelivery.complete(await upstreamDelivery.wait())
            }
            if scheduled == false {
                cancellationDelivery.complete(.rejected)
            }
        }
        guard installedCancellationHandler else {
            abandonRequestLease(
                leaseID,
                sessionID: internalSessionID,
                requestIDKeys: [originalID.key],
                operationLease: nil
            )
            throw CancellationError()
        }
        if rpcHandle.isCancelled() {
            throw CancellationError()
        }

        let response: ControlPlane.RPCResponse
        do {
            testHooks.controlPlaneRPCWillEnqueue?()
            let future: EventLoopFuture<ControlPlane.RPCResponse> = enqueueOnUpstreamSlot(
                leaseID: leaseID,
                descriptor: descriptor,
                on: eventLoop,
                preferredUpstreamIndices: preferredUpstreamIndices
            ) { [self, requestTemplate, originalID] selectedOperationLease in
                let selectedUpstreamIndex = selectedOperationLease.upstreamIndex
                if let expectedUpstreamProof,
                   selectedOperationLease.proof != expectedUpstreamProof {
                    return self.eventLoop.makeFailedFuture(
                        UpstreamSlotScheduler.AcquisitionError.unavailable
                    )
                }
                if rpcHandle.isCancelled() {
                    return self.eventLoop.makeFailedFuture(CancellationError())
                }
                let upstreamRequestTimeout = self.timeAmount(until: requestDeadlineUptimeNs)
                if upstreamRequestTimeout?.nanoseconds == 0 {
                    self.activateRequestLease(
                        leaseID,
                        requestIDKey: nil,
                        upstreamIndex: selectedUpstreamIndex,
                        timeout: .nanoseconds(0)
                    )
                    self.failRequestLease(
                        leaseID,
                        terminalState: .timedOut,
                        reason: .timedOut
                    )
                    return self.eventLoop.makeFailedFuture(TimeoutError())
                }
                let registration = session.router.registerRequestPending(
                    idKey: originalID.key,
                    on: self.eventLoop,
                    timeout: upstreamRequestTimeout,
                    onTimeout: {
                        rpcHandle.cancel(cause: .timedOut)
                    }
                )
                if rpcHandle.markRegistered(
                    registrationToken: registration.token,
                    operationLease: selectedOperationLease
                ) == false {
                    _ = session.router.cancelPending(token: registration.token)
                    self.abandonRequestLease(
                        leaseID,
                        sessionID: internalSessionID,
                        requestIDKeys: [originalID.key],
                        operationLease: selectedOperationLease
                    )
                    return self.eventLoop.makeFailedFuture(CancellationError())
                }
                self.activateRequestLease(
                    leaseID,
                    requestIDKey: originalID.key,
                    upstreamIndex: selectedUpstreamIndex,
                    timeout: upstreamRequestTimeout
                )
                guard let upstreamID = self.assignUpstreamID(
                    sessionID: internalSessionID,
                    originalID: originalID,
                    operationLease: selectedOperationLease
                ) else {
                    _ = session.router.cancelPending(token: registration.token)
                    self.abandonRequestLease(
                        leaseID,
                        sessionID: internalSessionID,
                        requestIDKeys: [originalID.key],
                        operationLease: selectedOperationLease
                    )
                    return self.eventLoop.makeFailedFuture(
                        UpstreamSlotScheduler.AcquisitionError.unavailable
                    )
                }
                self.testHooks.controlPlaneRPCAssignedUpstreamID?()
                if rpcHandle.markAssigned(
                    registrationToken: registration.token,
                    operationLease: selectedOperationLease,
                    requestIDKey: originalID.key
                ) == false {
                    _ = session.router.cancelPending(token: registration.token)
                    self.removeUpstreamIDMapping(
                        sessionID: internalSessionID,
                        requestIDKey: originalID.key,
                        operationLease: selectedOperationLease
                    )
                    self.abandonRequestLease(
                        leaseID,
                        sessionID: internalSessionID,
                        requestIDKeys: [originalID.key],
                        operationLease: selectedOperationLease
                    )
                    return self.eventLoop.makeFailedFuture(CancellationError())
                }
                guard let requestSendCompletion = rpcHandle.requestSendCompletion() else {
                    preconditionFailure("assigned RPC must own request send completion")
                }
                var upstreamObject = requestTemplate.mapValues(\.foundationObject)
                upstreamObject["id"] = upstreamID
                guard let requestData = try? JSONRPC.Wire.data(from: upstreamObject)
                else {
                    requestSendCompletion.complete(.notSent)
                    _ = session.router.cancelPending(token: registration.token)
                    self.removeUpstreamIDMapping(
                        sessionID: internalSessionID,
                        requestIDKey: originalID.key,
                        operationLease: selectedOperationLease
                    )
                    self.failRequestLease(
                        leaseID,
                        terminalState: .failed,
                        reason: .invalidUpstreamResponse
                    )
                    return self.eventLoop.makeFailedFuture(
                        ControlPlane.RequestError(
                            route: route,
                            operationLease: selectedOperationLease,
                            underlying: ControlPlane.Error.invalidResponse(
                                "invalid control-plane request"
                            )
                        )
                    )
                }
                if rpcHandle.isCancelled() {
                    requestSendCompletion.complete(.notSent)
                    _ = session.router.cancelPending(token: registration.token)
                    self.removeUpstreamIDMapping(
                        sessionID: internalSessionID,
                        requestIDKey: originalID.key,
                        operationLease: selectedOperationLease
                    )
                    self.abandonRequestLease(
                        leaseID,
                        sessionID: internalSessionID,
                        requestIDKeys: [originalID.key],
                        operationLease: selectedOperationLease
                    )
                    return self.eventLoop.makeFailedFuture(CancellationError())
                }

                let sent = self.sendUpstream(
                    requestData,
                    operationLease: selectedOperationLease,
                    ensureRunning: false,
                    requestSendCompletion: requestSendCompletion,
                    onRejected: {
                        _ = session.router.failPending(
                            token: registration.token,
                            error: UpstreamSlotScheduler.AcquisitionError.unavailable
                        )
                        self.removeUpstreamIDMapping(
                            sessionID: internalSessionID,
                            requestIDKey: originalID.key,
                            operationLease: selectedOperationLease
                        )
                    }
                )
                guard sent else {
                    _ = session.router.failPending(
                        token: registration.token,
                        error: UpstreamSlotScheduler.AcquisitionError.unavailable
                    )
                    self.abandonRequestLease(
                        leaseID,
                        sessionID: internalSessionID,
                        requestIDKeys: [originalID.key],
                        operationLease: selectedOperationLease,
                        after: requestSendCompletion
                    )
                    return self.eventLoop.makeFailedFuture(
                        UpstreamSlotScheduler.AcquisitionError.unavailable
                    )
                }
                return registration.future.flatMapThrowing { buffer in
                    var buffer = buffer
                    guard let responseData = buffer.readData(length: buffer.readableBytes) else {
                        throw ControlPlane.Error.invalidResponse("missing response data")
                    }
                    return ControlPlane.RPCResponse(
                        responseData: responseData,
                        operationLease: selectedOperationLease
                    )
                }.flatMapErrorThrowing { error in
                    throw ControlPlane.RequestError(
                        route: route,
                        operationLease: selectedOperationLease,
                        underlying: error
                    )
                }
            }
            if rpcHandle.isCancelled() {
                abandonRequestLease(
                    leaseID,
                    sessionID: internalSessionID,
                    requestIDKeys: [originalID.key],
                    operationLease: nil
                )
            }
            response = try await withTaskCancellationHandler {
                try await waitForEventLoopFuture(
                    future,
                    deadlineUptimeNs: requestDeadlineUptimeNs,
                    onTimeout: {
                        rpcHandle.cancel(cause: .timedOut)
                    }
                )
            } onCancel: {
                rpcHandle.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is TimeoutError {
            throw TimeoutError()
        } catch let error as UpstreamSlotScheduler.AcquisitionError {
            failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .upstreamUnavailable
            )
            throw error
        } catch {
            failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .invalidUpstreamResponse
            )
            throw error
        }
        rpcHandle.markFinished()
        let decoded: (object: [String: Any], error: JSONRPC.Wire.ErrorPayload?)
        let responseData: Data
        do {
            decoded = try decodeJSONRPCResponse(from: response.responseData)
            if let responseIDOverride {
                responseData = try responseDataByReplacingJSONRPCID(in: decoded.object, with: responseIDOverride)
            } else {
                responseData = response.responseData
            }
        } catch {
            failRequestLease(leaseID, terminalState: .failed, reason: .invalidUpstreamResponse)
            throw ControlPlane.RequestError(route: route, operationLease: response.operationLease, underlying: error)
        }
        let rpcError = decoded.error.map(ControlPlane.Error.init(rpc:))
        if rpcError?.isProxyFailure == true {
            failRequestLease(
                leaseID, terminalState: .failed,
                reason: decoded.error?.code == -32002 ? .upstreamOverloaded : .upstreamUnavailable
            )
        } else {
            markRequestSucceeded(response.operationLease)
            completeRequestLease(leaseID)
        }
        if let rpcError, throwsOnRPCError {
            throw ControlPlane.RequestError(route: route, operationLease: response.operationLease, underlying: rpcError)
        }
        return ControlPlane.RPCResponse(responseData: responseData, operationLease: response.operationLease)
    }

    func controlPlaneSessionID(
        for purpose: String,
        route: ControlPlane.Route?
    ) -> String {
        let suffix: String
        switch route {
        case .none, .some(.anyHealthy):
            suffix = "any"
        case .some(.pinnedUpstream(let upstreamIndex)):
            suffix = "pinned-\(upstreamIndex)"
        }
        return "__control_plane__:\(purpose):\(suffix)"
    }

    func extractJSONRPCResult(from responseData: Data) throws -> JSONValue {
        let decoded = try decodeJSONRPCResponse(from: responseData)
        if let error = decoded.error {
            throw ControlPlane.Error(rpc: error)
        }
        guard let result = JSONRPC.Wire.resultValue(inResponseObject: decoded.object) else {
            throw ControlPlane.Error.invalidResponse("missing result")
        }
        return result
    }

    private func decodeJSONRPCResponse(from responseData: Data) throws
        -> (object: [String: Any], error: JSONRPC.Wire.ErrorPayload?)
    {
        let object: [String: Any]
        do {
            object = try JSONRPC.Wire.object(fromData: responseData)
        } catch {
            throw ControlPlane.Error.invalidResponse("response is not a JSON object")
        }
        guard object["jsonrpc"] as? String == JSONRPC.Wire.version,
              object["method"] == nil else {
            throw ControlPlane.Error.invalidResponse("invalid JSON-RPC response envelope")
        }
        if object["error"] != nil {
            guard let error = JSONRPC.Wire.errorPayload(inResponseObject: object) else {
                throw ControlPlane.Error.invalidResponse("invalid JSON-RPC error response")
            }
            return (object, error)
        }
        guard object["result"] != nil else {
            throw ControlPlane.Error.invalidResponse("missing result")
        }
        return (object, nil)
    }

    func responseDataByReplacingJSONRPCID(
        in responseObject: [String: Any],
        with responseID: JSONRPC.ID
    ) throws -> Data {
        do {
            return try JSONRPC.Wire.dataByReplacingID(in: responseObject, with: responseID)
        } catch JSONRPC.Wire.EncodingFailure.invalidJSONObject {
            throw ControlPlane.Error.invalidResponse("invalid rewritten response")
        } catch {
            throw error
        }
    }

    func controlPlaneFailureReason(for error: any Error) -> String {
        if error is TimeoutError {
            return "timeout"
        }
        if let error = error as? ControlPlane.Error {
            switch error {
            case .invalidResponse(let reason):
                return reason
            case .upstreamRPC(_, let message), .proxyFailure(_, let message):
                return message
            }
        }
        return String(describing: error)
    }

    func elapsedMilliseconds(sinceUptimeNanoseconds startedAt: UInt64) -> Int {
        let elapsed = nowUptimeNanoseconds() &- startedAt
        return Int(elapsed / 1_000_000)
    }

    func timeAmount(until deadlineUptimeNs: UInt64?) -> TimeAmount? {
        guard let deadlineUptimeNs else { return nil }
        let now = nowUptimeNanoseconds()
        guard deadlineUptimeNs > now else {
            return .nanoseconds(0)
        }
        let remaining = deadlineUptimeNs - now
        let maxNanos = UInt64(Int64.max)
        return .nanoseconds(Int64(min(remaining, maxNanos)))
    }

    func deadlineUptimeNanoseconds(for requestTimeout: TimeAmount?) -> UInt64? {
        guard let requestTimeout, requestTimeout.nanoseconds > 0 else {
            return nil
        }
        let now = nowUptimeNanoseconds()
        let clamped = min(UInt64(requestTimeout.nanoseconds), UInt64.max &- now)
        return now &+ clamped
    }

    func waitForEventLoopFuture<Output: Sendable>(
        _ future: EventLoopFuture<Output>,
        deadlineUptimeNs: UInt64?,
        onTimeout: @escaping @Sendable () -> Void = {}
    ) async throws -> Output {
        if let deadlineUptimeNs, let timeout = timeAmount(until: deadlineUptimeNs) {
            let timeoutFuture = eventLoop.makePromise(of: Output.self)
            let didComplete = NIOLockedValueBox(false)
            let timeoutTask = Task { [clock] in
                await clock.sleep(.nanoseconds(max(0, timeout.nanoseconds)))
                let shouldComplete = didComplete.withLockedValue { completed in
                    guard completed == false else { return false }
                    completed = true
                    return true
                }
                guard shouldComplete else { return }
                onTimeout()
                timeoutFuture.fail(TimeoutError())
            }
            future.whenComplete { result in
                let shouldComplete = didComplete.withLockedValue { completed in
                    guard completed == false else { return false }
                    completed = true
                    return true
                }
                guard shouldComplete else { return }
                timeoutTask.cancel()
                timeoutFuture.completeWith(result)
            }
            return try await timeoutFuture.futureResult.get()
        }
        return try await future.get()
    }

    func noteIncompatibleUpstream(
        initializeClaim: UpstreamHealthManager.InitializeClaim,
        kind: String,
        reason: String
    ) {
        guard let proof = initializeClaim.topologyProof else { return }
        let upstreamIndex = proof.slotID.rawValue
        canonicalHandshakeState.recordIncompatibility(
            upstreamIndex: upstreamIndex,
            kind: kind,
            reason: reason
        )
        let nowUptimeNs = nowUptimeNanoseconds()
        let transition = upstreamHealthManager.quarantineIncompatibleUpstream(
            proof,
            nowUptimeNs: nowUptimeNs
        )
        transition?.cancelledInitTimeout?.cancel()
        if let initUpstreamID = transition?.initUpstreamID {
            upstreamRouter.remove(proof: proof, upstreamID: initUpstreamID)
        }
        debugRecorder.resetUpstream(upstreamIndex)
        if let quarantineUntil = transition?.quarantineUntil {
            logger.warning(
                "Upstream quarantined because it diverged from canonical broker state",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "kind": .string(kind),
                    "reason": .string(reason),
                    "quarantine_until_uptime_ns": .string("\(quarantineUntil)"),
                ]
            )
        }

    }

}
