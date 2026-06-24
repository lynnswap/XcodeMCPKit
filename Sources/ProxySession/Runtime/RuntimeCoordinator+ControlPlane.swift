import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import ProxySessionControlPlane
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

private enum EventLoopFutureWaitResult<Output: Sendable>: Sendable {
    case value(Output)
    case timedOut
}

private func compareDocumentationVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
    lhs.compare(rhs, options: [.numeric])
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
    private struct ProcessToolsCatalogRoute: Sendable {
        let target: XcodeProcessTarget
        let upstreamIndices: [Int]
    }

    private enum ProcessToolsCatalogOutcome: Sendable {
        case success(target: XcodeProcessTarget, result: CanonicalToolsCatalogLoadResult)
        case failure(target: XcodeProcessTarget, upstreamIndex: Int, error: any Error)
    }

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
        let requestDeadlineUptimeNs = deadlineUptimeNanoseconds(for: effectiveRequestTimeout)
        if xcodeProcessRoutes.isEmpty == false {
            return try await loadCanonicalToolsCatalogAcrossProcessRoutes(
                requestTimeout: effectiveRequestTimeout,
                deadlineUptimeNs: requestDeadlineUptimeNs,
                startedAt: startedAt
            )
        }
        return try await loadCanonicalToolsCatalogFromRoute(
            .anyHealthy,
            requestTimeout: effectiveRequestTimeout,
            rpcHandle: rpcHandle,
            startedAt: startedAt,
            purpose: "tools",
            failureRouteMetadata: nil
        )
    }

    private func loadCanonicalToolsCatalogAcrossProcessRoutes(
        requestTimeout: TimeAmount?,
        deadlineUptimeNs: UInt64?,
        startedAt: UInt64
    ) async throws -> CanonicalToolsCatalogLoadResult {
        let candidateProcessOrder = documentationCandidateProcessOrder()
        let processRoutes =
            candidateProcessOrder.map { order in
                order.compactMap { processID in
                    xcodeProcessRoutes.first { $0.target.processID == processID }
                }
            } ?? xcodeProcessRoutes
        let routes = processRoutes.compactMap { route -> ProcessToolsCatalogRoute? in
            let upstreamIndices = usableInitializedUpstreamIndices(in: route)
            guard upstreamIndices.isEmpty == false else {
                return nil
            }
            return ProcessToolsCatalogRoute(target: route.target, upstreamIndices: upstreamIndices)
        }
        guard routes.isEmpty == false else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }

        return try await withThrowingTaskGroup(
            of: ProcessToolsCatalogOutcome.self,
            returning: CanonicalToolsCatalogLoadResult.self
        ) { group in
            for route in routes {
                group.addTask {
                    do {
                        let result = try await self.loadCanonicalToolsCatalogFromProcessRoute(
                            route,
                            requestTimeout: requestTimeout,
                            deadlineUptimeNs: deadlineUptimeNs,
                            startedAt: startedAt
                        )
                        return .success(target: route.target, result: result)
                    } catch is CancellationError {
                        return .failure(
                            target: route.target,
                            upstreamIndex: route.upstreamIndices.last ?? -1,
                            error: CancellationError()
                        )
                    } catch {
                        return .failure(
                            target: route.target,
                            upstreamIndex: route.upstreamIndices.last ?? -1,
                            error: error
                        )
                    }
                }
            }

            var successes: [(target: XcodeProcessTarget, result: CanonicalToolsCatalogLoadResult)] = []
            var failures: [(target: XcodeProcessTarget, upstreamIndex: Int, error: any Error)] = []
            while let outcome = try await group.next() {
                switch outcome {
                case .success(let target, let result):
                    successes.append((target: target, result: result))
                case .failure(let target, let upstreamIndex, let error):
                    if error is CancellationError {
                        throw CancellationError()
                    }
                    failures.append((target, upstreamIndex, error))
                }
            }

            if successes.isEmpty == false {
                for failure in failures {
                    self.processToolCatalogRegistry.removeCatalog(
                        forProcessID: failure.target.processID
                    )
                }
                for success in successes {
                    guard let sourceUpstream = success.result.sourceUpstream else {
                        continue
                    }
                    self.processToolCatalogRegistry.record(
                        target: success.target,
                        upstreamIndex: sourceUpstream,
                        associatedUpstreamIndices: self.xcodeProcessRoutes.first {
                            $0.target.processID == success.target.processID
                        }?.upstreamIndices ?? [],
                        rawResult: success.result.rawResult
                    )
                }
                let unionResult = self.processToolCatalogRegistry.unionToolsListResult()
                    ?? successes[0].result.rawResult
                let successfulProcessIDs = Set(successes.map { $0.target.processID })
                let configuredProcessIDs = self.catalogEligibleConfiguredProcessIDs()
                let hasCompleteProcessCatalog =
                    configuredProcessIDs.isEmpty == false
                    && successfulProcessIDs == configuredProcessIDs
                let sourceUpstream: Int?
                if hasCompleteProcessCatalog {
                    sourceUpstream = successes.sorted {
                        compareDocumentationVersion(
                            $0.target.xcodeVersion,
                            $1.target.xcodeVersion
                        ) == .orderedDescending
                    }.first?.result.sourceUpstream
                } else {
                    sourceUpstream = nil
                }
                return CanonicalToolsCatalogLoadResult(
                    rawResult: unionResult,
                    sourceUpstream: sourceUpstream,
                    durationMilliseconds: self.elapsedMilliseconds(
                        sinceUptimeNanoseconds: startedAt
                    )
                )
            }

            let lastFailure = failures.last
            if let lastFailure {
                throw ControlPlane.RequestError(
                    route: .pinnedUpstream(lastFailure.upstreamIndex),
                    upstreamIndex: lastFailure.upstreamIndex,
                    underlying: lastFailure.error
                )
            }
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
    }

    private func loadCanonicalToolsCatalogFromProcessRoute(
        _ route: ProcessToolsCatalogRoute,
        requestTimeout: TimeAmount?,
        deadlineUptimeNs: UInt64?,
        startedAt: UInt64
    ) async throws -> CanonicalToolsCatalogLoadResult {
        var lastFailure: (upstreamIndex: Int, error: any Error)?
        for upstreamIndex in route.upstreamIndices {
            let rpcHandle = ControlPlane.RPCHandle()
            let routeTimeout = timeAmount(until: deadlineUptimeNs) ?? requestTimeout
            if routeTimeout?.nanoseconds == 0 {
                throw TimeoutError()
            }
            do {
                return try await loadCanonicalToolsCatalogFromRoute(
                    .pinnedUpstream(upstreamIndex),
                    requestTimeout: routeTimeout,
                    rpcHandle: rpcHandle,
                    startedAt: startedAt,
                    purpose: "tools-\(upstreamIndex)",
                    failureRouteMetadata: [
                        "pid": .string("\(route.target.processID)"),
                        "app_path": .string(route.target.appPath),
                        "xcode_version": .string(route.target.xcodeVersion),
                        "upstream": .string("\(upstreamIndex)"),
                    ]
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = (upstreamIndex, error)
            }
        }
        if let lastFailure {
            throw ControlPlane.RequestError(
                route: .pinnedUpstream(lastFailure.upstreamIndex),
                upstreamIndex: lastFailure.upstreamIndex,
                underlying: lastFailure.error
            )
        }
        throw UpstreamSlotScheduler.AcquisitionError.unavailable
    }

    private func loadCanonicalToolsCatalogFromRoute(
        _ route: ControlPlane.Route,
        requestTimeout: TimeAmount?,
        rpcHandle: ControlPlane.RPCHandle,
        startedAt: UInt64,
        purpose: String,
        failureRouteMetadata: Logger.Metadata?
    ) async throws -> CanonicalToolsCatalogLoadResult {
        let nowUptimeNs = nowUptimeNanoseconds()
        do {
            let response = try await performControlPlaneRPC(
                route: route,
                purpose: purpose,
                label: "tools/list",
                requestObject: JSONRPC.Wire.requestObject(
                    id: "__control-plane-tools-\(UUID().uuidString)",
                    method: "tools/list"
                ),
                requestTimeout: requestTimeout,
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
            logProcessToolsCatalogFailureIfNeeded(
                error: error.underlying,
                metadata: failureRouteMetadata
            )
            throw error.underlying
        } catch {
            logProcessToolsCatalogFailureIfNeeded(
                error: error,
                metadata: failureRouteMetadata
            )
            throw error
        }
    }

    private func logProcessToolsCatalogFailureIfNeeded(
        error: any Error,
        metadata: Logger.Metadata?
    ) {
        guard var metadata else {
            return
        }
        metadata["error"] = .string(String(describing: error))
        logger.debug("Process tools/list route failed", metadata: metadata)
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
                requestObject: JSONRPC.Wire.requestObject(
                    id: "__control-plane-windows-\(UUID().uuidString)",
                    method: "tools/call",
                    params: .object([
                        "name": .string("XcodeListWindows"),
                        "arguments": .object([:]),
                    ])
                ),
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
        rpcHandle: ControlPlane.RPCHandle? = nil,
        responseIDOverride: JSONRPC.ID? = nil,
        throwsOnRPCError: Bool = true
    ) async throws -> ControlPlane.RPCResponse {
        let requestDeadlineUptimeNs = deadlineUptimeNanoseconds(for: requestTimeout)
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
                    timeout: upstreamRequestTimeout
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
                guard let requestData = try? JSONRPC.Wire.data(from: upstreamObject)
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
                try await waitForEventLoopFuture(
                    future,
                    deadlineUptimeNs: requestDeadlineUptimeNs,
                    onTimeout: {
                        rpcHandle?.cancel()
                    }
                )
            } onCancel: {
                rpcHandle?.cancel()
            }
            let responseObject = try extractJSONRPCResponseObject(from: response.responseData)
            let isProxyUpstreamFailure = responseIsProxyUpstreamFailure(responseObject)
            if responseObject["error"] != nil, throwsOnRPCError {
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
            let responseData: Data
            if let responseIDOverride {
                responseData = try responseDataByReplacingJSONRPCID(
                    in: responseObject,
                    with: responseIDOverride
                )
            } else {
                responseData = response.responseData
            }
            rpcHandle?.markFinished()
            if !isProxyUpstreamFailure {
                markRequestSucceeded(upstreamIndex: response.upstreamIndex)
            }
            completeRequestLease(leaseID)
            return ControlPlane.RPCResponse(
                responseData: responseData,
                upstreamIndex: response.upstreamIndex
            )
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
        if let error = JSONRPC.Wire.errorPayload(inResponseObject: object) {
            throw ControlPlane.Error.upstreamRPC(
                code: error.code,
                message: error.message
            )
        }
        guard let result = JSONRPC.Wire.resultValue(inResponseObject: object) else {
            throw ControlPlane.Error.invalidResponse("missing result")
        }
        return result
    }

    func extractJSONRPCResponseObject(from responseData: Data) throws -> [String: Any] {
        do {
            return try JSONRPC.Wire.object(fromData: responseData)
        } catch JSONRPC.Wire.DecodingFailure.messageWasNotObject {
            throw ControlPlane.Error.invalidResponse("response was not an object")
        } catch {
            throw error
        }
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

    func extractJSONRPCErrorMessage(from responseObject: [String: Any]) -> String? {
        JSONRPC.Wire.errorPayload(inResponseObject: responseObject)?.message
    }

    func extractJSONRPCErrorCode(from responseObject: [String: Any]) -> Int? {
        JSONRPC.Wire.errorPayload(inResponseObject: responseObject)?.code
    }

    func responseIsProxyUpstreamFailure(_ responseObject: [String: Any]) -> Bool {
        guard
            let code = extractJSONRPCErrorCode(from: responseObject),
            let message = extractJSONRPCErrorMessage(from: responseObject)
        else {
            return false
        }
        return (code == -32001 && message == "upstream unavailable")
            || (code == -32002 && message == "upstream overloaded")
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
            return try await withThrowingTaskGroup(
                of: EventLoopFutureWaitResult<Output>.self
            ) { group in
                group.addTask {
                    .value(try await future.get())
                }
                group.addTask {
                    try await Task.sleep(
                        nanoseconds: UInt64(max(0, timeout.nanoseconds))
                    )
                    return .timedOut
                }
                let result = try await group.next()!
                switch result {
                case .value(let output):
                    group.cancelAll()
                    return output
                case .timedOut:
                    onTimeout()
                    group.cancelAll()
                    throw TimeoutError()
                }
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
