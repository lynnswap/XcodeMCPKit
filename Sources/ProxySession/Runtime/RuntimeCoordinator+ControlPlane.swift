import Foundation
import NIO
import NIOConcurrencyHelpers
import ProxyCore
import ProxyMCP

extension ControlPlane {
    package enum Error: Swift.Error, Sendable {
        case invalidResponse(String)
        case upstreamRPC(code: Int, message: String)
    }
}

extension ControlPlane {
    package struct RequestError: Swift.Error, Sendable {
        package let route: ControlPlane.Route
        package let upstreamIndex: Int?
        package let underlying: any Swift.Error
    }
}

extension ControlPlane {
    package struct RPCResponse: Sendable {
        package let responseData: Data
        package let upstreamIndex: Int
    }
}

/// The one place that decides which JSON-RPC error a control-plane or
/// upstream-acquisition failure surfaces as.
extension ControlPlane {
    package enum ErrorMapper {
        package static func jsonRPCError(for error: Swift.Error) -> (code: Int, message: String) {
            if let error = error as? DocumentationProvider.UnavailableReason {
                return (-32001, error.message)
            }
            if error is UpstreamSlotScheduler.AcquisitionError {
                return (-32001, "upstream unavailable")
            }
            if let error = error as? ControlPlane.RequestError {
                return jsonRPCError(for: error.underlying)
            }
            if let error = error as? ControlPlane.Error {
                switch error {
                case .invalidResponse:
                    return (-32000, "upstream timeout")
                case .upstreamRPC(let code, let message):
                    return (code, message)
                }
            }
            return (-32000, "upstream timeout")
        }
    }
}

extension RuntimeCoordinator {
    func loadCanonicalToolsCatalog(
        requestTimeout: TimeAmount?,
        rpcHandle: ControlPlane.RPCHandle
    ) async throws -> CanonicalToolsCatalogLoadResult {
        let startedAt = nowUptimeNanoseconds()
        let effectiveRequestTimeout =
            requestTimeout
            ?? MCP.MethodDispatcher.timeoutForControlPlane(
                defaultSeconds: config.requestTimeout
            )
        let nowUptimeNs = nowUptimeNanoseconds()
        do {
            let response = try await performControlPlaneRPC(
                route: .anyHealthy,
                purpose: "tools",
                label: "tools/list",
                requestObject: [
                    "jsonrpc": "2.0",
                    "id": "__control-plane-tools-\(UUID().uuidString)",
                    "method": "tools/list",
                ],
                requestTimeout: effectiveRequestTimeout,
                rpcHandle: rpcHandle
            )
            let result = try extractJSONRPCResult(from: response.responseData)
            guard isValidToolsListResult(result) else {
                markToolsListRefreshFailed(
                    upstreamIndex: response.upstreamIndex,
                    nowUptimeNs: nowUptimeNs,
                    reason: "invalid_response"
                )
                throw ControlPlane.Error.invalidResponse("invalid tools/list result")
            }
            markToolsListRefreshSucceeded(
                upstreamIndex: response.upstreamIndex,
                nowUptimeNs: nowUptimeNs
            )
            return CanonicalToolsCatalogLoadResult(
                rawResult: result,
                sourceUpstream: response.upstreamIndex,
                durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt)
            )
        } catch let error as ControlPlane.RequestError {
            if error.underlying is CancellationError {
                throw error.underlying
            }
            if let upstreamIndex = error.upstreamIndex {
                markToolsListRefreshFailed(
                    upstreamIndex: upstreamIndex,
                    nowUptimeNs: nowUptimeNs,
                    reason: controlPlaneFailureReason(for: error.underlying)
                )
            }
            throw error.underlying
        }
    }

    func loadLiveXcodeListWindows(
        route: ControlPlane.Route,
        requestTimeout: TimeAmount?,
        rpcHandle: ControlPlane.RPCHandle
    ) async throws -> JSONValue {
        let effectiveRequestTimeout =
            requestTimeout
            ?? MCP.MethodDispatcher.timeoutForControlPlane(
                defaultSeconds: config.requestTimeout
            )
        do {
            let response = try await performControlPlaneRPC(
                route: route,
                purpose: "windows",
                label: "tools/call:XcodeListWindows",
                requestObject: [
                    "jsonrpc": "2.0",
                    "id": "__control-plane-windows-\(UUID().uuidString)",
                    "method": "tools/call",
                    "params": [
                        "name": "XcodeListWindows",
                        "arguments": [:],
                    ],
                ],
                requestTimeout: effectiveRequestTimeout,
                rpcHandle: rpcHandle
            )
            return try extractJSONRPCResult(from: response.responseData)
        } catch let error as ControlPlane.RequestError {
            throw error.underlying
        }
    }

    func performControlPlaneRPC(
        route: ControlPlane.Route,
        purpose: String,
        label: String,
        requestObject: [String: Any],
        requestTimeout: TimeAmount?,
        rpcHandle: ControlPlane.RPCHandle? = nil
    ) async throws -> ControlPlane.RPCResponse {
        let internalSessionID = controlPlaneSessionID(for: purpose, route: route)
        let session = session(id: internalSessionID)
        let router = session.router
        guard let originalID = JSONRPC.Message.Inspector.requestID(from: requestObject) else {
            throw ControlPlane.Error.invalidResponse("missing request id")
        }
        let requestTemplate = requestObject.reduce(into: [String: JSONValue]()) { partial, entry in
            if entry.key == "id" { return }
            if let value = JSONValue(any: entry.value) {
                partial[entry.key] = value
            }
        }
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: internalSessionID,
            label: label,
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let leaseID = createRequestLease(descriptor: descriptor)
        let preferredUpstreamIndex: Int? =
            switch route {
            case .anyHealthy:
                nil
            case .pinnedUpstream(let upstreamIndex):
                upstreamIndex
            }
        rpcHandle?.installCancel { [self, router] snapshot in
            if let registrationToken = snapshot.registrationToken {
                _ = router.cancelPending(token: registrationToken)
            }
            if let upstreamIndex = snapshot.upstreamIndex,
                let requestIDKey = snapshot.requestIDKey
            {
                removeUpstreamIDMapping(
                    sessionID: internalSessionID,
                    requestIDKey: requestIDKey,
                    upstreamIndex: upstreamIndex
                )
            }
            self.abandonRequestLease(
                leaseID,
                sessionID: internalSessionID,
                requestIDKeys: snapshot.requestIDKey.map { [$0] } ?? [originalID.key],
                upstreamIndex: snapshot.upstreamIndex
            )
        }
        if rpcHandle?.isCancelled() == true {
            throw CancellationError()
        }

        do {
            let future: EventLoopFuture<ControlPlane.RPCResponse> = enqueueOnUpstreamSlot(
                leaseID: leaseID,
                descriptor: descriptor,
                on: eventLoop,
                preferredUpstreamIndex: preferredUpstreamIndex
            ) { [self, requestTemplate, originalID] selectedUpstreamIndex in
                if rpcHandle?.isCancelled() == true {
                    return self.eventLoop.makeFailedFuture(CancellationError())
                }
                let registration = session.router.registerRequestPending(
                    idKey: originalID.key,
                    on: self.eventLoop,
                    timeout: requestTimeout,
                    onTimeout: {
                        self.handleRequestLeaseTimeout(
                            leaseID,
                            sessionID: internalSessionID,
                            requestIDKeys: [originalID.key],
                            upstreamIndex: selectedUpstreamIndex
                        )
                    }
                )
                if rpcHandle?.markRegistered(
                    registrationToken: registration.token,
                    upstreamIndex: selectedUpstreamIndex
                ) == false {
                    _ = session.router.cancelPending(token: registration.token)
                    self.abandonRequestLease(
                        leaseID,
                        sessionID: internalSessionID,
                        requestIDKeys: [originalID.key],
                        upstreamIndex: selectedUpstreamIndex
                    )
                    return self.eventLoop.makeFailedFuture(CancellationError())
                }
                self.activateRequestLease(
                    leaseID,
                    requestIDKey: originalID.key,
                    upstreamIndex: selectedUpstreamIndex,
                    timeout: requestTimeout
                )
                let upstreamID = self.assignUpstreamID(
                    sessionID: internalSessionID,
                    originalID: originalID,
                    upstreamIndex: selectedUpstreamIndex
                )
                if rpcHandle?.markAssigned(
                    registrationToken: registration.token,
                    upstreamIndex: selectedUpstreamIndex,
                    requestIDKey: originalID.key
                ) == false {
                    _ = session.router.cancelPending(token: registration.token)
                    self.removeUpstreamIDMapping(
                        sessionID: internalSessionID,
                        requestIDKey: originalID.key,
                        upstreamIndex: selectedUpstreamIndex
                    )
                    self.abandonRequestLease(
                        leaseID,
                        sessionID: internalSessionID,
                        requestIDKeys: [originalID.key],
                        upstreamIndex: selectedUpstreamIndex
                    )
                    return self.eventLoop.makeFailedFuture(CancellationError())
                }
                var upstreamObject = requestTemplate.mapValues(\.foundationObject)
                upstreamObject["id"] = upstreamID
                guard JSONSerialization.isValidJSONObject(upstreamObject),
                    let requestData = try? JSONSerialization.data(
                        withJSONObject: upstreamObject,
                        options: []
                    )
                else {
                    self.failRequestLease(
                        leaseID,
                        terminalState: .failed,
                        reason: .invalidUpstreamResponse
                    )
                    return self.eventLoop.makeFailedFuture(
                        ControlPlane.RequestError(
                            route: route,
                            upstreamIndex: selectedUpstreamIndex,
                            underlying: ControlPlane.Error.invalidResponse(
                                "invalid control-plane request"
                            )
                        )
                    )
                }
                if rpcHandle?.isCancelled() == true {
                    _ = session.router.cancelPending(token: registration.token)
                    self.removeUpstreamIDMapping(
                        sessionID: internalSessionID,
                        requestIDKey: originalID.key,
                        upstreamIndex: selectedUpstreamIndex
                    )
                    self.abandonRequestLease(
                        leaseID,
                        sessionID: internalSessionID,
                        requestIDKeys: [originalID.key],
                        upstreamIndex: selectedUpstreamIndex
                    )
                    return self.eventLoop.makeFailedFuture(CancellationError())
                }

                self.sendUpstream(
                    requestData,
                    upstreamIndex: selectedUpstreamIndex,
                    ensureRunning: false
                )
                return registration.future.flatMapThrowing { buffer in
                    var buffer = buffer
                    guard let responseData = buffer.readData(length: buffer.readableBytes) else {
                        throw ControlPlane.Error.invalidResponse("missing response data")
                    }
                    return ControlPlane.RPCResponse(
                        responseData: responseData,
                        upstreamIndex: selectedUpstreamIndex
                    )
                }.flatMapErrorThrowing { error in
                    throw ControlPlane.RequestError(
                        route: route,
                        upstreamIndex: selectedUpstreamIndex,
                        underlying: error
                    )
                }
            }
            let response = try await withTaskCancellationHandler {
                try await future.get()
            } onCancel: {
                rpcHandle?.cancel()
            }
            let responseObject = try extractJSONRPCResponseObject(from: response.responseData)
            if responseObject["error"] != nil {
                failRequestLease(
                    leaseID,
                    terminalState: .failed,
                    reason: .invalidUpstreamResponse
                )
                throw ControlPlane.RequestError(
                    route: route,
                    upstreamIndex: response.upstreamIndex,
                    underlying: ControlPlane.Error.upstreamRPC(
                        code: extractJSONRPCErrorCode(from: responseObject) ?? -32000,
                        message: extractJSONRPCErrorMessage(from: responseObject)
                            ?? "upstream error"
                    )
                )
            }
            rpcHandle?.markFinished()
            markRequestSucceeded(upstreamIndex: response.upstreamIndex)
            completeRequestLease(leaseID)
            return response
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
        let object = try extractJSONRPCResponseObject(from: responseData)
        if let errorObject = object["error"] as? [String: Any] {
            throw ControlPlane.Error.upstreamRPC(
                code: (errorObject["code"] as? NSNumber)?.intValue ?? -32000,
                message: errorObject["message"] as? String ?? "upstream error"
            )
        }
        guard let resultAny = object["result"],
            let result = JSONValue(any: resultAny)
        else {
            throw ControlPlane.Error.invalidResponse("missing result")
        }
        return result
    }

    func extractJSONRPCResponseObject(from responseData: Data) throws -> [String: Any] {
        guard
            let responseObject = try JSONSerialization.jsonObject(
                with: responseData,
                options: []
            ) as? [String: Any]
        else {
            throw ControlPlane.Error.invalidResponse("response was not an object")
        }
        return responseObject
    }

    func extractJSONRPCErrorMessage(from responseObject: [String: Any]) -> String? {
        (responseObject["error"] as? [String: Any])?["message"] as? String
    }

    func extractJSONRPCErrorCode(from responseObject: [String: Any]) -> Int? {
        ((responseObject["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue
    }

    func controlPlaneFailureReason(for error: any Error) -> String {
        if error is TimeoutError {
            return "timeout"
        }
        if let error = error as? ControlPlane.Error {
            switch error {
            case .invalidResponse(let reason):
                return reason
            case .upstreamRPC(_, let message):
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

    func waitForEventLoopFuture<Output: Sendable>(
        _ future: EventLoopFuture<Output>,
        deadlineUptimeNs: UInt64?
    ) async throws -> Output {
        if let deadlineUptimeNs, let timeout = timeAmount(until: deadlineUptimeNs) {
            return try await withThrowingTaskGroup(of: Output.self) { group in
                group.addTask {
                    try await future.get()
                }
                group.addTask {
                    try await Task.sleep(
                        nanoseconds: UInt64(max(0, timeout.nanoseconds))
                    )
                    throw TimeoutError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        }
        return try await future.get()
    }

    func noteIncompatibleUpstream(
        upstreamIndex: Int,
        kind: String,
        reason: String
    ) {
        canonicalBrokerState.recordIncompatibility(
            upstreamIndex: upstreamIndex,
            kind: kind,
            reason: reason
        )
        let nowUptimeNs = nowUptimeNanoseconds()
        let transition = upstreamHealthManager.quarantineIncompatibleUpstream(
            upstreamIndex: upstreamIndex,
            nowUptimeNs: nowUptimeNs
        )
        transition?.cancelledInitTimeout?.cancel()
        if let initUpstreamID = transition?.initUpstreamID {
            upstreamRouter.remove(upstreamIndex: upstreamIndex, upstreamID: initUpstreamID)
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

    func jsonValuesEquivalent(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        canonicalJSONData(for: lhs) == canonicalJSONData(for: rhs)
    }

    func initializeResultsEquivalent(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        canonicalJSONData(for: normalizedInitializeResult(lhs))
            == canonicalJSONData(for: normalizedInitializeResult(rhs))
    }

    private func canonicalJSONData(for value: JSONValue) -> Data? {
        let object = value.foundationObject
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    private func normalizedInitializeResult(_ value: JSONValue) -> JSONValue {
        guard case .object(var object) = value else { return value }
        object.removeValue(forKey: "serverInfo")
        return .object(object)
    }
}
