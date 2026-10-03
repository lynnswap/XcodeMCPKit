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
            if let error = error as? DocumentationProvider.UnavailableReason {
                return (-32001, error.message)
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
        rpcHandle: ControlPlane.RPCHandle,
        onFreshProvider: @escaping @Sendable (UpstreamTopologyProof) async -> Void = { _ in }
    ) async throws -> CanonicalToolsCatalogLoadResult {
        let startedAt = nowUptimeNanoseconds()
        let timeout = requestTimeout ?? MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: config.requestTimeout)
        let deadline = deadlineUptimeNanoseconds(for: timeout)
        let topology = upstreamTopology.snapshot()
        let exposure = processRouteExposure(policy: .toolsCatalog)
        let routes = exposure.routes.compactMap { exposed -> AvailableToolsCatalogRoute? in
            guard let id = exposed.usableUpstreamIDs.first,
                  let proof = topology.proof(id),
                  let (lease, transition) = beginProcessCatalogAttemptIfRunning(
                      routeID: exposed.route.id, preferredUpstreamProof: proof
                  ) else { return nil }
            applyProcessControlPlaneTransition(transition)
            return AvailableToolsCatalogRoute(route: exposed.route, target: exposed.route.target,
                upstreamIndices: exposed.usableUpstreamIndices, lease: lease)
        }
        async let guiLoad = loadAvailableToolsCatalogsInBatch(
            routes, requestTimeout: timeout, deadlineUptimeNs: deadline, startedAt: startedAt,
            exposedProcessIDs: exposure.processIDs, returnAfterFirstSuccess: false,
            onFreshProvider: onFreshProvider)
        let nativeIsInitialized = topology.entries.contains { entry in
            entry.backend == .nativeHost
                && upstreamHealthManager.state(for: entry.id)?.initPhase.isUsableInitialized == true
        }
        var nativeFailure: (any Error)?
        var refreshedProvider = false
        if nativeIsInitialized {
            do {
                _ = try await loadUnboundToolsCatalog(
                    requestTimeout: timeout, rpcHandle: rpcHandle, startedAt: startedAt,
                    onFreshProvider: onFreshProvider)
                refreshedProvider = true
            } catch {
                if error is CancellationError { throw error }
                nativeFailure = error
            }
        }
        var guiFailure: (any Error)?
        do {
            _ = try await guiLoad
            refreshedProvider = true
        } catch {
            if error is CancellationError { throw error }
            guiFailure = error
        }
        try Task.checkCancellation()
        if refreshedProvider, let current = currentCatalogResult(
            startedAt: startedAt, exposedProcessIDs: processToolCatalogExposedProcessIDs()) {
            return current
        }
        throw nativeFailure ?? guiFailure ?? UpstreamSlotScheduler.AcquisitionError.unavailable
    }

    private func beginDefaultBackendCatalogLoad(allowsConcurrentLoad: Bool) -> CatalogLease? {
        guard let upstreamID = defaultBackendUpstreamIndices.sorted().first.map(UpstreamSlotID.init(rawValue:)),
              let proof = upstreamTopology.operationLease(for: upstreamID)?.proof else { return nil }
        var attempt: (CatalogLease, ProcessControlPlaneTransition)?
        guard initializeManager.performIfRunning({
            attempt = processControlPlane.beginUnboundCatalogAttempt(
                preferredUpstreamProof: proof,
                nowUptimeNanoseconds: nowUptimeNanoseconds(),
                allowsConcurrentLoad: allowsConcurrentLoad
            )
        }), let (lease, transition) = attempt else { return nil }
        applyProcessControlPlaneTransition(transition)
        return lease
    }

    private func loadUnboundToolsCatalog(
        requestTimeout: TimeAmount?, rpcHandle: ControlPlane.RPCHandle, startedAt: UInt64,
        onFreshProvider: @escaping @Sendable (UpstreamTopologyProof) async -> Void
    ) async throws -> CanonicalToolsCatalogLoadResult {
        guard let lease = beginDefaultBackendCatalogLoad(allowsConcurrentLoad: true) else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        return try await loadUnboundToolsCatalog(
            lease: lease, requestTimeout: requestTimeout, rpcHandle: rpcHandle, startedAt: startedAt,
            onFreshProvider: onFreshProvider
        )
    }

    private func loadUnboundToolsCatalog(
        lease: CatalogLease,
        requestTimeout: TimeAmount?,
        rpcHandle: ControlPlane.RPCHandle,
        startedAt: UInt64,
        onFreshProvider: @escaping @Sendable (UpstreamTopologyProof) async -> Void
    ) async throws -> CanonicalToolsCatalogLoadResult {
        applyProcessControlPlaneTransition(
            processControlPlane.attach(.rpc(rpcHandle), to: lease)
        )
        do {
            let result = try await loadCanonicalToolsCatalogFromRoute(
                .nativeHost,
                requestTimeout: requestTimeout,
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
                await onFreshProvider(sourceProof)
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
                guard processControlPlane.catalogLoadWasSatisfied(lease),
                      let rawResult = processControlPlane.canonicalToolsCatalogRaw() else {
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
            if isCurrentLoad == false, processControlPlane.catalogLoadWasSatisfied(lease),
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

    private func loadAvailableToolsCatalogsInBatch(
        _ routes: [AvailableToolsCatalogRoute],
        requestTimeout: TimeAmount?,
        deadlineUptimeNs: UInt64?,
        startedAt: UInt64,
        exposedProcessIDs: Set<pid_t>,
        returnAfterFirstSuccess: Bool = true,
        onFreshProvider: @escaping @Sendable (UpstreamTopologyProof) async -> Void = { _ in }
    ) async throws -> CanonicalToolsCatalogLoadResult {
        for route in routes {
            scheduleProcessRouteActivationCatalogTimeoutIfNeeded(lease: route.lease)
        }
        var pendingProcessIDs = Set(routes.map { $0.target.processID })
        let result = try await withThrowingTaskGroup(
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
                        if let source = result.sourceProof { await onFreshProvider(source) }
                        return .success(
                            route: route,
                            result: recordedResult
                        )
                    } catch is CancellationError {
                        if self.processControlPlane.validateCatalogLoad(route.lease) == false {
                            if self.processControlPlane.catalogLoadWasSatisfied(route.lease),
                               let current = self.currentCatalogResult(
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
                            if self.processControlPlane.catalogLoadWasSatisfied(route.lease),
                               let current = self.currentCatalogResult(
                                startedAt: startedAt,
                                exposedProcessIDs: self.processToolCatalogExposedProcessIDs()
                            ) {
                                return .success(route: route, result: current)
                            }
                            return .stale
                        }
                        let cancellationDeliveries = self.applyCatalogCommit(
                            self.commitProcessCatalog(
                                .unusable,
                                lease: route.lease,
                                nowUptimeNanoseconds: self.nowUptimeNanoseconds()
                            )
                        )
                        self.scheduleMissingProcessToolsCatalogRetry(
                            processID: route.target.processID,
                            lease: route.lease,
                            after: cancellationDeliveries,
                            reason: "process_catalog_timeout"
                        )
                        return .failure(route: route,
                            upstreamIndex: route.upstreamIndices.last ?? -1,
                            error: TimeoutError())
                    } catch {
                        let retriesActivation: Bool
                        if case ControlPlane.Error.upstreamRPC = ControlPlane.ErrorMapper.underlyingError(error),
                           let claim = self.upstreamHealthManager.currentCatalogActivationClaim(
                               upstreamIndex: route.lease.upstreamIndex
                           ), claim.topologyProof == route.lease.topologyProof {
                            retriesActivation = true
                        } else {
                            retriesActivation = false
                        }
                        let commit = self.commitProcessCatalog(
                            retriesActivation ? .unusable : .failed,
                            lease: route.lease,
                            nowUptimeNanoseconds: self.nowUptimeNanoseconds()
                        )
                        let deliveries = self.applyCatalogCommit(commit)
                        if retriesActivation {
                            self.scheduleMissingProcessToolsCatalogRetry(
                                processID: route.target.processID, lease: route.lease,
                                after: deliveries, reason: "activation_catalog_rpc_error"
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
                case .success(let route, let result):
                    pendingProcessIDs.remove(route.target.processID)
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
                    pendingProcessIDs.remove(route.target.processID)
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
        if returnAfterFirstSuccess, pendingProcessIDs.isEmpty == false {
            refreshProcessToolsCatalogsIfNeeded(
                reason: "foreground_remaining_catalogs",
                processIDs: pendingProcessIDs,
                refreshCached: true
            )
        }
        return result
    }

    func refreshProcessToolsCatalogsIfNeeded(
        reason: String,
        processIDs requestedProcessIDs: Set<pid_t>? = nil,
        refreshCached: Bool = false
    ) {
        guard initializeManager.snapshot().isShuttingDown == false else { return }

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
            return refreshCached || processControlPlane.catalog(forProcessID: $0.route.target.processID) == nil
        }
        let missingRoutes = missingExposures.compactMap { exposure -> AvailableToolsCatalogRoute? in
            guard let preferred = exposure.usableUpstreamIDs.first,
                  let preferredProof = upstreamTopology.operationLease(for: preferred)?.proof,
                  let (lease, transition) = beginProcessCatalogAttemptIfRunning(
                      routeID: exposure.route.id,
                      preferredUpstreamProof: preferredProof,
                      allowsConcurrentLoad: false
                  ) else { return nil }
            applyProcessControlPlaneTransition(transition)
            return AvailableToolsCatalogRoute(
                route: exposure.route,
                target: exposure.route.target,
                upstreamIndices: exposure.usableUpstreamIndices,
                lease: lease
            )
        }
        refreshProcessToolsCatalogs(missingRoutes, reason: reason)
    }

    func refreshProcessRouteToolsCatalog(
        route: XcodeProcessRoute,
        upstreamProof: UpstreamTopologyProof,
        reason: String
    ) {
        guard isInitialized(),
              processControlPlane.catalog(forProcessID: route.target.processID) == nil,
              let (lease, transition) = beginProcessCatalogAttemptIfRunning(
                  routeID: route.id,
                  preferredUpstreamProof: upstreamProof
              ) else { return }
        applyProcessControlPlaneTransition(transition)
        refreshProcessToolsCatalogs(
            [
                AvailableToolsCatalogRoute(
                    route: route,
                    target: route.target,
                    upstreamIndices: [upstreamProof.slotID.rawValue],
                    lease: lease
                )
            ],
            reason: reason
        )
    }

    func beginProcessCatalogAttemptIfRunning(
        routeID: ProcessRouteID,
        preferredUpstreamProof: UpstreamTopologyProof,
        allowsConcurrentLoad: Bool = true
    ) -> (CatalogLease, ProcessControlPlaneTransition)? {
        let nowUptimeNanoseconds = nowUptimeNanoseconds()
        var attempt: (CatalogLease, ProcessControlPlaneTransition)?
        guard initializeManager.performIfRunning({
            attempt = processControlPlane.beginCatalogAttempt(
                routeID: routeID,
                preferredUpstreamProof: preferredUpstreamProof,
                nowUptimeNanoseconds: nowUptimeNanoseconds,
                allowsConcurrentLoad: allowsConcurrentLoad
            )
        }) else {
            return nil
        }
        return attempt
    }

    private func refreshProcessToolsCatalogs(
        _ missingRoutes: [AvailableToolsCatalogRoute],
        reason: String
    ) {
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
        let requestTimeout = processRouteToolsCatalogRequestTimeoutAmount()
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

    func processRouteToolsCatalogRequestTimeoutAmount() -> TimeAmount? {
        MCP.MethodDispatcher.timeoutForMethod(
            "tools/list",
            defaultSeconds: config.requestTimeout
        )
    }

    func scheduleMissingProcessToolsCatalogRetry(
        processID: pid_t,
        lease: CatalogLease,
        after cancellationDeliveries: [ControlPlane.RPCCancellationDelivery] = [],
        reason: String
    ) {
        var scheduled: (
            lease: CatalogLease,
            retry: ProcessControlPlaneAuthority.Retry,
            transition: ProcessControlPlaneTransition
        )?
        guard initializeManager.performIfRunning({
            scheduled = processControlPlane.scheduleRetry(lease: lease)
        }), let scheduled else { return }
        let retryCancellationDeliveries = applyProcessControlPlaneTransition(
            scheduled.transition
        )
        scheduleMissingProcessToolsCatalogRetry(
            processID: processID,
            lease: scheduled.lease,
            retry: scheduled.retry,
            after: cancellationDeliveries + retryCancellationDeliveries,
            reason: reason
        )
    }

    func scheduleMissingProcessToolsCatalogRetry(
        processID: pid_t,
        lease: CatalogLease,
        retry: ProcessControlPlaneAuthority.Retry,
        after cancellationDeliveries: [ControlPlane.RPCCancellationDelivery],
        reason: String
    ) {
        guard cancellationDeliveries.isEmpty else {
            addRuntimeTask { [weak self] in
                var rejected = false
                for delivery in cancellationDeliveries {
                    let result = await delivery.wait()
                    rejected = rejected || result.allowsRetryScheduling == false
                }
                guard let self else { return }
                guard rejected == false else {
                    return
                }
                self.armMissingProcessToolsCatalogRetry(
                    processID: processID,
                    lease: lease,
                    retry: retry,
                    reason: reason
                )
            }
            return
        }
        armMissingProcessToolsCatalogRetry(
            processID: processID,
            lease: lease,
            retry: retry,
            reason: reason
        )
    }

    private func armMissingProcessToolsCatalogRetry(
        processID: pid_t,
        lease: CatalogLease,
        retry: ProcessControlPlaneAuthority.Retry,
        reason: String
    ) {
        let delay = retry.delay
        logger.debug(
            "Scheduling missing process tools/list catalog retry",
            metadata: [
                "pid": .string("\(processID)"),
                "delay_ms": .string("\(retry.delayMilliseconds)"),
                "reason": .string(reason),
            ]
        )
        let timeout = scheduleRuntimeTimeout(delay) { [weak self] in
            guard let self else { return }
            guard self.processControlPlane.handleRetryFired(lease),
                  self.xcodeProcessRoutes.contains(where: {
                      $0.id == lease.routeIdentity
                  }),
                  self.processControlPlane.catalog(forProcessID: processID) == nil
            else {
                return
            }
            self.refreshProcessToolsCatalogsIfNeeded(
                reason: "scheduled_\(reason)",
                processIDs: [processID]
            )
        }
        var transition = ProcessControlPlaneTransition.none
        guard initializeManager.performIfRunning({
            transition = processControlPlane.attach(.retryTimeout(timeout), to: lease)
        }) else {
            timeout.cancel()
            return
        }
        applyProcessControlPlaneTransition(transition)
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
            return nil
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
            let cancellationDeliveries = applyCatalogCommit(
                commitProcessCatalog(
                    .unusable,
                    lease: route.lease,
                    nowUptimeNanoseconds: nowUptimeNanoseconds()
                )
            )
            scheduleMissingProcessToolsCatalogRetry(
                processID: route.target.processID,
                lease: route.lease,
                after: cancellationDeliveries,
                reason: "empty_process_catalog"
            )
            return nil
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
            testHooks.processRouteCatalogCommitted?(
                route.target.processID,
                sourceUpstream
            )
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
            let clientVisibleResult = toolsListResultWithConfiguredOverlay(
                baseResult: result.rawResult,
                metadata: [
                    "origin": .string("process_catalog_log"),
                    "pid": .string("\(route.target.processID)"),
                ]
            )
            let summary = ToolCatalogStartupLogFormatter.summary(
                from: clientVisibleResult,
                process: ToolCatalogStartupLogFormatter.Process(
                    appPath: route.target.appPath,
                    processID: route.target.processID
                )
            )
            logger.info("\(summary)")
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
            guard processControlPlane.catalogLoadWasSatisfied(route.lease) else { return nil }
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
            let routeTimeout = timeAmount(until: deadlineUptimeNs) ?? requestTimeout
            if routeTimeout?.nanoseconds == 0 {
                throw TimeoutError()
            }
            let rpcHandle = ControlPlane.RPCHandle()
            applyProcessControlPlaneTransition(
                processControlPlane.attach(.rpc(rpcHandle), to: route.lease)
            )
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
        purpose: String,
        failureRouteMetadata: Logger.Metadata?
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
        case .nativeHost:
            let indices = upstreamTopology.snapshot().entries.compactMap { entry in
                entry.backend == .nativeHost ? entry.id.rawValue : nil
            }
            guard !indices.isEmpty else { throw UpstreamSlotScheduler.AcquisitionError.unavailable }
            preferredUpstreamIndices = indices
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
                    admission: nil,
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
        case .some(.nativeHost):
            suffix = "xcode-service"
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
        if case .processBridgeRecovery = initializeClaim.owner {
            return
        }
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex) else {
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
