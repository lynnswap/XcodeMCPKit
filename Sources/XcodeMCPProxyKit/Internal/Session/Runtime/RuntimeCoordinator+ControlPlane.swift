import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import XcodeMCPKit

extension ControlPlane {
    enum Error: Swift.Error, Sendable {
        case invalidResponse(String)
        case upstreamRPC(code: Int, message: String)
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
        static func jsonRPCError(for error: Swift.Error) -> (code: Int, message: String) {
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
    private struct AvailableToolsCatalogRoute: Sendable {
        let route: XcodeProcessRoute
        let target: XcodeProcessTarget
        let upstreamIndices: [Int]
        let lease: CatalogLease
    }

    private enum AvailableToolsCatalogOutcome: Sendable {
        case success(route: AvailableToolsCatalogRoute, result: CanonicalToolsCatalogLoadResult)
        case failure(route: AvailableToolsCatalogRoute, upstreamIndex: Int, error: any Error)
        case stale
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
        if processRoutingEnabled {
            return try await loadAvailableToolsCatalogSurfaceAcrossProcessRoutes(
                requestTimeout: effectiveRequestTimeout,
                deadlineUptimeNs: requestDeadlineUptimeNs,
                startedAt: startedAt
            )
        }
        guard let preferredUpstream = upstreamSlotIDs.first else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        guard let preferredProof = upstreamTopology.operationLease(
            for: preferredUpstream
        )?.proof else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        let (lease, transition) = processControlPlane.beginUnboundCatalogAttempt(
            preferredUpstreamProof: preferredProof,
            nowUptimeNanoseconds: startedAt
        )
        applyProcessControlPlaneTransition(transition)
        applyProcessControlPlaneTransition(
            processControlPlane.attach(.rpc(rpcHandle), to: lease)
        )
        do {
            let result = try await loadCanonicalToolsCatalogFromRoute(
                .anyHealthy,
                requestTimeout: effectiveRequestTimeout,
                rpcHandle: rpcHandle,
                startedAt: startedAt,
                purpose: "tools",
                failureRouteMetadata: nil
            )
            guard let sourceProof = result.sourceProof else {
                applyCatalogCommit(commitProcessCatalog(
                    .failed,
                    lease: lease,
                    nowUptimeNanoseconds: nowUptimeNanoseconds()
                ))
                throw ControlPlane.Error.invalidResponse("tools/list source upstream missing")
            }
            let commit = commitProcessCatalog(
                .usable(result.rawResult, source: sourceProof),
                lease: lease,
                nowUptimeNanoseconds: nowUptimeNanoseconds()
            )
            switch commit {
            case .accepted(let snapshot, let transition):
                applyProcessControlPlaneTransition(transition)
                guard let rawResult = snapshot.canonicalToolsCatalogRaw else {
                    throw UpstreamSlotScheduler.AcquisitionError.unavailable
                }
                return CanonicalToolsCatalogLoadResult(
                    rawResult: rawResult,
                    sourceProof: snapshot.canonicalSourceProof,
                    durationMilliseconds: elapsedMilliseconds(
                        sinceUptimeNanoseconds: startedAt
                    )
                )
            case .discarded(_, let transition):
                applyProcessControlPlaneTransition(transition)
                guard let rawResult = processControlPlane.canonicalToolsCatalogRaw() else {
                    throw UpstreamSlotScheduler.AcquisitionError.unavailable
                }
                return CanonicalToolsCatalogLoadResult(
                    rawResult: rawResult,
                    sourceProof: processControlPlane.canonicalSourceProof(),
                    durationMilliseconds: elapsedMilliseconds(
                        sinceUptimeNanoseconds: startedAt
                    )
                )
            }
        } catch {
            let isCurrentLoad = processControlPlane.validateCatalogLoad(lease)
            applyCatalogCommit(commitProcessCatalog(
                .failed,
                lease: lease,
                nowUptimeNanoseconds: nowUptimeNanoseconds()
            ))
            if isCurrentLoad == false,
               let rawResult = processControlPlane.canonicalToolsCatalogRaw() {
                return CanonicalToolsCatalogLoadResult(
                    rawResult: rawResult,
                    sourceProof: processControlPlane.canonicalSourceProof(),
                    durationMilliseconds: elapsedMilliseconds(
                        sinceUptimeNanoseconds: startedAt
                    )
                )
            }
            throw error
        }
    }

    private func loadAvailableToolsCatalogSurfaceAcrossProcessRoutes(
        requestTimeout: TimeAmount?,
        deadlineUptimeNs: UInt64?,
        startedAt: UInt64
    ) async throws -> CanonicalToolsCatalogLoadResult {
        let exposure = processRouteExposure(policy: .toolsCatalog)
        guard exposure.routes.isEmpty == false else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }

        let exposedProcessIDs = exposure.processIDs
        let currentSurface = processControlPlane.availableToolCatalogSurface(
            processIDs: exposedProcessIDs
        )
        if let surface = currentSurface,
           let sourceProof = surface.sourceProof,
           surface.processIDs == exposedProcessIDs {
            return CanonicalToolsCatalogLoadResult(
                rawResult: surface.rawResult,
                sourceProof: sourceProof,
                durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt)
            )
        }

        let cachedProcessIDs = currentSurface?.processIDs ?? []
        let uncachedExposures = exposure.routes.filter {
            cachedProcessIDs.contains($0.route.target.processID) == false
        }
        guard uncachedExposures.isEmpty == false else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        let routes = uncachedExposures.compactMap { exposure -> AvailableToolsCatalogRoute? in
            guard let preferred = exposure.usableUpstreamIDs.first,
                  let preferredProof = upstreamTopology.operationLease(for: preferred)?.proof,
                  let (lease, transition) = processControlPlane.beginCatalogAttempt(
                      routeID: exposure.route.id,
                      preferredUpstreamProof: preferredProof,
                      nowUptimeNanoseconds: nowUptimeNanoseconds()
                  ) else { return nil }
            applyProcessControlPlaneTransition(transition)
            return AvailableToolsCatalogRoute(
                route: exposure.route,
                target: exposure.route.target,
                upstreamIndices: exposure.usableUpstreamIndices,
                lease: lease
            )
        }
        guard routes.isEmpty == false else {
            if let current = processControlPlane.canonicalToolsCatalogRaw() {
                return CanonicalToolsCatalogLoadResult(
                    rawResult: current,
                    sourceProof: processControlPlane.canonicalSourceProof(),
                    durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt)
                )
            }
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }

        return try await loadAvailableToolsCatalogsInBatch(
            routes,
            requestTimeout: requestTimeout,
            deadlineUptimeNs: deadlineUptimeNs,
            startedAt: startedAt,
            exposedProcessIDs: exposedProcessIDs,
            returnAfterFirstSuccess: false
        )
    }

    private func loadAvailableToolsCatalogsInBatch(
        _ routes: [AvailableToolsCatalogRoute],
        requestTimeout: TimeAmount?,
        deadlineUptimeNs: UInt64?,
        startedAt: UInt64,
        exposedProcessIDs: Set<pid_t>,
        returnAfterFirstSuccess: Bool = true
    ) async throws -> CanonicalToolsCatalogLoadResult {
        try await withThrowingTaskGroup(
            of: AvailableToolsCatalogOutcome.self,
            returning: CanonicalToolsCatalogLoadResult.self
        ) { group in
            for route in routes {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let result = try await self.loadToolsCatalogFromAvailableProcessRoute(
                            route,
                            requestTimeout: requestTimeout,
                            deadlineUptimeNs: deadlineUptimeNs,
                            startedAt: startedAt
                        )
                        guard let recordedResult = self.commitProcessCatalog(
                            route: route,
                            result: result,
                            startedAt: startedAt,
                            exposedProcessIDs: exposedProcessIDs
                        ) else {
                            return .stale
                        }
                        return .success(
                            route: route,
                            result: recordedResult
                        )
                    } catch is CancellationError {
                        if self.processControlPlane.validateCatalogLoad(route.lease) == false {
                            if let current = self.currentCatalogResult(
                                startedAt: startedAt,
                                exposedProcessIDs: self.processToolCatalogExposedProcessIDs()
                            ) {
                                return .success(route: route, result: current)
                            }
                            return .stale
                        }
                        self.applyCatalogCommit(self.commitProcessCatalog(
                            .failed,
                            lease: route.lease,
                            nowUptimeNanoseconds: self.nowUptimeNanoseconds()
                        ))
                        throw CancellationError()
                    } catch is TimeoutError {
                        if self.processControlPlane.validateCatalogLoad(route.lease) == false {
                            if let current = self.currentCatalogResult(
                                startedAt: startedAt,
                                exposedProcessIDs: self.processToolCatalogExposedProcessIDs()
                            ) {
                                return .success(route: route, result: current)
                            }
                            return .stale
                        }
                        self.applyCatalogCommit(self.commitProcessCatalog(
                            .failed,
                            lease: route.lease,
                            nowUptimeNanoseconds: self.nowUptimeNanoseconds()
                        ))
                        throw TimeoutError()
                    } catch {
                        let commit = self.commitProcessCatalog(
                            .failed,
                            lease: route.lease,
                            nowUptimeNanoseconds: self.nowUptimeNanoseconds()
                        )
                        self.applyCatalogCommit(commit)
                        if let surface = self.processControlPlane.availableToolCatalogSurface(
                            processIDs: exposedProcessIDs
                        ), let surfaceSourceProof = surface.sourceProof {
                            return .success(
                                route: route,
                                result: CanonicalToolsCatalogLoadResult(
                                    rawResult: surface.rawResult,
                                    sourceProof: surfaceSourceProof,
                                    durationMilliseconds: self.elapsedMilliseconds(
                                        sinceUptimeNanoseconds: startedAt
                                    )
                                )
                            )
                        }
                        return .failure(
                            route: route,
                            upstreamIndex: route.upstreamIndices.last ?? -1,
                            error: error
                        )
                    }
                }
            }

            var failures: [(target: XcodeProcessTarget, upstreamIndex: Int, error: any Error)] = []
            var firstSuccess: CanonicalToolsCatalogLoadResult?
            while let outcome = try await group.next() {
                switch outcome {
                case .success(_, let result):
                    if returnAfterFirstSuccess {
                        group.cancelAll()
                        return availableToolsCatalogSurfaceResult(
                            startedAt: startedAt,
                            exposedProcessIDs: exposedProcessIDs,
                            fallback: result
                        )
                    }
                    if firstSuccess == nil {
                        firstSuccess = result
                    }
                case .failure(let route, let upstreamIndex, let error):
                    failures.append((target: route.target, upstreamIndex: upstreamIndex, error: error))
                case .stale:
                    continue
                }
            }
            if let firstSuccess {
                return availableToolsCatalogSurfaceResult(
                    startedAt: startedAt,
                    exposedProcessIDs: exposedProcessIDs,
                    fallback: firstSuccess
                )
            }
            if let lastFailure = failures.last {
                throw ControlPlane.RequestError(
                    route: .pinnedUpstream(lastFailure.upstreamIndex),
                    upstreamIndex: lastFailure.upstreamIndex,
                    underlying: lastFailure.error
                )
            }
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
    }

    func refreshMissingProcessToolsCatalogsIfNeeded(
        reason: String,
        processIDs requestedProcessIDs: Set<pid_t>? = nil
    ) {
        guard processRoutingEnabled else {
            return
        }
        let exposure = processRouteExposure(policy: .toolsCatalog)
        // Exposure evaluation is also the health-probe trigger for expired
        // quarantines. Run it before requiring an exposed handshake so a
        // temporarily hidden raw supporter can validate itself and restore
        // the canonical initialize result.
        guard isInitialized() else {
            return
        }
        let missingExposures = exposure.routes.filter {
            if let requestedProcessIDs,
               requestedProcessIDs.contains($0.route.target.processID) == false {
                return false
            }
            return processControlPlane.catalog(forProcessID: $0.route.target.processID) == nil
        }
        let missingRoutes = missingExposures.compactMap { exposure -> AvailableToolsCatalogRoute? in
            guard let preferred = exposure.usableUpstreamIDs.first,
                  let preferredProof = upstreamTopology.operationLease(for: preferred)?.proof,
                  let (lease, transition) = processControlPlane.beginCatalogAttempt(
                      routeID: exposure.route.id,
                      preferredUpstreamProof: preferredProof,
                      nowUptimeNanoseconds: nowUptimeNanoseconds()
                  ) else { return nil }
            applyProcessControlPlaneTransition(transition)
            return AvailableToolsCatalogRoute(
                route: exposure.route,
                target: exposure.route.target,
                upstreamIndices: exposure.usableUpstreamIndices,
                lease: lease
            )
        }
        guard missingRoutes.isEmpty == false else {
            return
        }
        logger.debug(
            "Refreshing missing process tools/list catalogs",
            metadata: [
                "reason": .string(reason),
                "process_ids": .string(
                    missingRoutes
                        .map { "\($0.target.processID)" }
                        .joined(separator: ",")
                ),
            ]
        )
        let requestTimeout = MCP.MethodDispatcher.timeoutForControlPlane(
            defaultSeconds: config.requestTimeout
        )
        addRuntimeTask { [weak self] in
            guard let self else { return }
            let startedAt = self.nowUptimeNanoseconds()
            do {
                _ = try await self.loadAvailableToolsCatalogsInBatch(
                    missingRoutes,
                    requestTimeout: requestTimeout,
                    deadlineUptimeNs: self.deadlineUptimeNanoseconds(for: requestTimeout),
                    startedAt: startedAt,
                    exposedProcessIDs: self.processToolCatalogExposedProcessIDs(),
                    returnAfterFirstSuccess: false
                )
                await self.controlPlaneCoordinator.syncDebug()
            } catch is CancellationError {
            } catch {
                self.logger.debug(
                    "Background process tools/list refresh failed",
                    metadata: ["error": .string(String(describing: error))]
                )
            }
        }
    }

    func scheduleMissingProcessToolsCatalogRetry(
        processID: pid_t,
        lease: CatalogLease,
        reason: String
    ) {
        guard let scheduled = processControlPlane.scheduleRetry(lease: lease) else { return }
        applyProcessControlPlaneTransition(scheduled.transition)
        let delay = scheduled.retry.delay
        logger.debug(
            "Scheduling missing process tools/list catalog retry",
            metadata: [
                "pid": .string("\(processID)"),
                "delay_ms": .string("\(scheduled.retry.delayMilliseconds)"),
                "reason": .string(reason),
            ]
        )
        let timeout = scheduleRuntimeTimeout(delay) { [weak self] in
            guard let self else { return }
            guard self.processControlPlane.handleRetryFired(scheduled.lease),
                  self.processRoutingEnabled,
                  self.xcodeProcessRoutes.contains(where: {
                      $0.id == scheduled.lease.routeIdentity
                  }),
                  self.processControlPlane.catalog(forProcessID: processID) == nil
            else {
                return
            }
            self.refreshMissingProcessToolsCatalogsIfNeeded(
                reason: "scheduled_\(reason)",
                processIDs: [processID]
            )
        }
        applyProcessControlPlaneTransition(
            processControlPlane.attach(.retryTimeout(timeout), to: scheduled.lease)
        )
    }

    private func availableToolsCatalogSurfaceResult(
        startedAt: UInt64,
        exposedProcessIDs: Set<pid_t>,
        fallback: CanonicalToolsCatalogLoadResult
    ) -> CanonicalToolsCatalogLoadResult {
        guard let surface = processControlPlane.availableToolCatalogSurface(
            processIDs: exposedProcessIDs
        ) else {
            return fallback
        }
        return CanonicalToolsCatalogLoadResult(
            rawResult: surface.rawResult,
            sourceProof: surface.sourceProof ?? fallback.sourceProof,
            durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt)
        )
    }

    private func commitProcessCatalog(
        route: AvailableToolsCatalogRoute,
        result: CanonicalToolsCatalogLoadResult,
        startedAt: UInt64,
        exposedProcessIDs: Set<pid_t>
    ) -> CanonicalToolsCatalogLoadResult? {
        guard let sourceProof = result.sourceProof else {
            applyCatalogCommit(
                commitProcessCatalog(
                    .failed,
                    lease: route.lease,
                    nowUptimeNanoseconds: nowUptimeNanoseconds()
                )
            )
            return currentCatalogResult(
                startedAt: startedAt,
                exposedProcessIDs: exposedProcessIDs
            )
        }
        let sourceUpstream = sourceProof.slotID.rawValue

        guard ProcessToolCatalogCodec.hasUsableUpstreamToolsCatalog(in: result.rawResult) else {
            logger.debug(
                "Dropping empty process tools/list catalog",
                metadata: [
                    "pid": .string("\(route.target.processID)"),
                    "app_path": .string(route.target.appPath),
                    "xcode_version": .string(route.target.xcodeVersion),
                    "upstream": .string("\(sourceUpstream)"),
                ]
            )
            applyCatalogCommit(
                commitProcessCatalog(
                    .unusable,
                    lease: route.lease,
                    nowUptimeNanoseconds: nowUptimeNanoseconds()
                )
            )
            scheduleMissingProcessToolsCatalogRetry(
                processID: route.target.processID,
                lease: route.lease,
                reason: "empty_process_catalog"
            )
            return currentCatalogResult(
                startedAt: startedAt,
                exposedProcessIDs: exposedProcessIDs
            )
        }

        let commit = commitProcessCatalog(
            .usable(result.rawResult, source: sourceProof),
            lease: route.lease,
            nowUptimeNanoseconds: nowUptimeNanoseconds()
        )
        switch commit {
        case .accepted(let snapshot, let transition):
            applyProcessControlPlaneTransition(transition)
            markXcodeProcessRouteCatalogAvailable(upstreamIndex: sourceUpstream)
            logger.info(
                "route_activation_cataloged",
                metadata: [
                    "pid": .string("\(route.target.processID)"),
                    "upstream": .string("\(sourceUpstream)"),
                    "duration_ms": .string(
                        "\(elapsedMilliseconds(sinceUptimeNanoseconds: startedAt))"
                    ),
                ]
            )
            if let raw = snapshot.canonicalToolsCatalogRaw {
                return CanonicalToolsCatalogLoadResult(
                    rawResult: raw,
                    sourceProof: snapshot.canonicalSourceProof,
                    durationMilliseconds: elapsedMilliseconds(
                        sinceUptimeNanoseconds: startedAt
                    )
                )
            }
            return currentCatalogResult(
                startedAt: startedAt,
                exposedProcessIDs: exposedProcessIDs
            )
        case .discarded(let reason, let transition):
            applyProcessControlPlaneTransition(transition)
            logger.debug(
                "Discarding stale process tools/list completion",
                metadata: [
                    "pid": .string("\(route.target.processID)"),
                    "upstream": .string("\(sourceUpstream)"),
                    "reason": .string(String(describing: reason)),
                ]
            )
            return currentCatalogResult(
                startedAt: startedAt,
                exposedProcessIDs: processToolCatalogExposedProcessIDs()
            )
        }
    }

    private func currentCatalogResult(
        startedAt: UInt64,
        exposedProcessIDs: Set<pid_t>
    ) -> CanonicalToolsCatalogLoadResult? {
        if let raw = processControlPlane.canonicalToolsCatalogRaw() {
            return CanonicalToolsCatalogLoadResult(
                rawResult: raw,
                sourceProof: processControlPlane.canonicalSourceProof(),
                durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt)
            )
        }
        guard let surface = processControlPlane.availableToolCatalogSurface(
            processIDs: exposedProcessIDs
        ), let source = surface.sourceProof else {
            return nil
        }
        return CanonicalToolsCatalogLoadResult(
            rawResult: surface.rawResult,
            sourceProof: source,
            durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt)
        )
    }
    private func loadToolsCatalogFromAvailableProcessRoute(
        _ route: AvailableToolsCatalogRoute,
        requestTimeout: TimeAmount?,
        deadlineUptimeNs: UInt64?,
        startedAt: UInt64
    ) async throws -> CanonicalToolsCatalogLoadResult {
        var lastFailure: (upstreamIndex: Int, error: any Error)?
        for upstreamIndex in route.upstreamIndices {
            let rpcHandle = ControlPlane.RPCHandle()
            applyProcessControlPlaneTransition(
                processControlPlane.attach(.rpc(rpcHandle), to: route.lease)
            )
            let routeTimeout = timeAmount(until: deadlineUptimeNs) ?? requestTimeout
            if routeTimeout?.nanoseconds == 0 {
                throw TimeoutError()
            }
            do {
                // First-success catalog loads cancel sibling routes; the route-level
                // handle must release queued or in-flight fallback RPCs.
                return try await withTaskCancellationHandler {
                    try await loadCanonicalToolsCatalogFromRoute(
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
                } onCancel: {
                    rpcHandle.cancel()
                }
            } catch is CancellationError {
                guard Task.isCancelled == false else {
                    throw CancellationError()
                }
                lastFailure = (
                    upstreamIndex,
                    UpstreamSlotScheduler.AcquisitionError.unavailable
                )
            } catch is TimeoutError {
                lastFailure = (upstreamIndex, TimeoutError())
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
                    response.operationLease.proof,
                    nowUptimeNs: nowUptimeNs,
                    reason: "invalid_response"
                )
                throw ControlPlane.Error.invalidResponse("invalid tools/list result")
            }
            markToolsListRefreshSucceeded(
                response.operationLease.proof,
                nowUptimeNs: nowUptimeNs
            )
            return CanonicalToolsCatalogLoadResult(
                rawResult: result,
                sourceProof: response.operationLease.proof,
                durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt)
            )
        } catch let error as ControlPlane.RequestError {
            if error.underlying is CancellationError {
                throw error.underlying
            }
            if let proof = error.operationLease?.proof {
                markToolsListRefreshFailed(
                    proof,
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
            let requestIDKeys = snapshot.requestIDKey.map { [$0] } ?? [originalID.key]
            if let operationLease = snapshot.operationLease {
                self.abandonRequestLease(
                    leaseID,
                    sessionID: internalSessionID,
                    requestIDKeys: requestIDKeys,
                    operationLease: operationLease
                )
            } else {
                self.abandonRequestLease(
                    leaseID,
                    sessionID: internalSessionID,
                    requestIDKeys: requestIDKeys,
                    operationLease: nil
                )
            }
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
            ) { [self, requestTemplate, originalID] selectedOperationLease in
                let selectedUpstreamIndex = selectedOperationLease.upstreamIndex
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
                            operationLease: selectedOperationLease
                        )
                    }
                )
                if rpcHandle?.markRegistered(
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
                if rpcHandle?.markAssigned(
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
                            operationLease: selectedOperationLease,
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
                    admission: nil,
                    onRejected: {
                        _ = session.router.cancelPending(token: registration.token)
                    }
                )
                guard sent else {
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
                    operationLease: response.operationLease,
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
                markRequestSucceeded(response.operationLease)
            }
            completeRequestLease(leaseID)
            return ControlPlane.RPCResponse(
                responseData: responseData,
                operationLease: response.operationLease
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
        guard processRoutingEnabled,
              let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex) else {
            return
        }
        abandonProcessRouteActivation(
            processID: route.target.processID,
            reason: reason
        )
        markXcodeProcessRouteUnavailable(
            upstreamIndex: upstreamIndex,
            reason: reason
        )
    }

}
