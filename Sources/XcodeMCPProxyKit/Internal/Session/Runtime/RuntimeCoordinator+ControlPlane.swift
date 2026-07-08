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
        let upstreamIndex: Int?
        let underlying: any Swift.Error
    }
}

extension ControlPlane {
    struct RPCResponse: Sendable {
        let responseData: Data
        let upstreamIndex: Int
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
        let target: XcodeProcessTarget
        let upstreamIndices: [Int]
        let activationUpstreamIndex: Int?
        let activationAttempt: Int?
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
        return try await loadCanonicalToolsCatalogFromRoute(
            .anyHealthy,
            requestTimeout: effectiveRequestTimeout,
            rpcHandle: rpcHandle,
            startedAt: startedAt,
            purpose: "tools",
            failureRouteMetadata: nil
        )
    }

    private func loadAvailableToolsCatalogSurfaceAcrossProcessRoutes(
        requestTimeout: TimeAmount?,
        deadlineUptimeNs: UInt64?,
        startedAt: UInt64
    ) async throws -> CanonicalToolsCatalogLoadResult {
        let brokerGeneration = canonicalBrokerState.generation()
        let unavailable = unavailableXcodeProcessIDs()
        let routes = xcodeProcessRoutes.compactMap { route -> AvailableToolsCatalogRoute? in
            guard unavailable.contains(route.target.processID) == false else {
                return nil
            }
            let upstreamIndices = recoveryAwareUsableInitializedUpstreamIndices(in: route)
            guard upstreamIndices.isEmpty == false else {
                return nil
            }
            let activation = availableToolsCatalogActivation(
                route: route,
                upstreamIndices: upstreamIndices
            )
            return AvailableToolsCatalogRoute(
                target: route.target,
                upstreamIndices: upstreamIndices,
                activationUpstreamIndex: activation?.upstreamIndex,
                activationAttempt: activation?.attempt
            )
        }
        guard routes.isEmpty == false else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }

        let exposedProcessIDs = Set(routes.map { $0.target.processID })
        let currentSurface = processToolCatalogRegistry.availableToolCatalogSurface(
            processIDs: exposedProcessIDs
        )
        if let surface = currentSurface,
           let sourceUpstream = surface.sourceUpstream,
           surface.processIDs == exposedProcessIDs {
            return CanonicalToolsCatalogLoadResult(
                rawResult: surface.rawResult,
                sourceUpstream: sourceUpstream,
                durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt)
            )
        }

        let cachedProcessIDs = currentSurface?.processIDs ?? []
        let uncachedRoutes = routes.filter { cachedProcessIDs.contains($0.target.processID) == false }
        guard uncachedRoutes.isEmpty == false else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        if let surface = currentSurface,
           let sourceUpstream = surface.sourceUpstream {
            scheduleAvailableToolsCatalogCompletion(
                uncachedRoutes,
                requestTimeout: requestTimeout,
                exposedProcessIDs: exposedProcessIDs
            )
            return CanonicalToolsCatalogLoadResult(
                rawResult: surface.rawResult,
                sourceUpstream: sourceUpstream,
                durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt),
                cacheableAsCanonical: false
            )
        }

        do {
            return try await loadAvailableToolsCatalogsInBatch(
                uncachedRoutes,
                requestTimeout: requestTimeout,
                deadlineUptimeNs: deadlineUptimeNs,
                startedAt: startedAt,
                exposedProcessIDs: exposedProcessIDs,
                brokerGeneration: brokerGeneration
            )
        } catch is CancellationError {
            guard Task.isCancelled == false,
                  let surface = try await waitForAvailableToolsCatalogSurface(
                      exposedProcessIDs: exposedProcessIDs,
                      deadlineUptimeNs: deadlineUptimeNs
                  ),
                  let sourceUpstream = surface.sourceUpstream else {
                throw CancellationError()
            }
            return CanonicalToolsCatalogLoadResult(
                rawResult: surface.rawResult,
                sourceUpstream: sourceUpstream,
                durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt),
                cacheableAsCanonical: surface.processIDs == exposedProcessIDs
            )
        } catch {
            guard let surface = currentSurface,
                  let sourceUpstream = surface.sourceUpstream else {
                throw error
            }
            return CanonicalToolsCatalogLoadResult(
                rawResult: surface.rawResult,
                sourceUpstream: sourceUpstream,
                durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt),
                cacheableAsCanonical: surface.processIDs == exposedProcessIDs
            )
        }
    }

    private func waitForAvailableToolsCatalogSurface(
        exposedProcessIDs: Set<pid_t>,
        deadlineUptimeNs: UInt64?
    ) async throws -> ProcessToolCatalogRegistry.AvailableToolCatalog? {
        while true {
            if let surface = processToolCatalogRegistry.availableToolCatalogSurface(
                processIDs: exposedProcessIDs
            ),
                surface.processIDs == exposedProcessIDs
            {
                return surface
            }
            try Task.checkCancellation()
            if let deadlineUptimeNs,
               nowUptimeNanoseconds() >= deadlineUptimeNs {
                return nil
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func loadAvailableToolsCatalogsInBatch(
        _ routes: [AvailableToolsCatalogRoute],
        requestTimeout: TimeAmount?,
        deadlineUptimeNs: UInt64?,
        startedAt: UInt64,
        exposedProcessIDs: Set<pid_t>,
        brokerGeneration: UInt64? = nil,
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
                        if let sourceUpstream = result.sourceUpstream,
                           let hook = self.testHooks.processToolsCatalogLoadedBeforeRecord {
                            await hook(route.target, sourceUpstream)
                        }
                        guard let recordedResult = self.recordAvailableToolsCatalog(
                            target: route.target,
                            activationUpstreamIndex: route.activationUpstreamIndex,
                            activationAttempt: route.activationAttempt,
                            result: result,
                            startedAt: startedAt,
                            exposedProcessIDs: exposedProcessIDs,
                            brokerGeneration: brokerGeneration
                        ) else {
                            return .stale
                        }
                        return .success(
                            route: route,
                            result: recordedResult
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch is TimeoutError {
                        throw TimeoutError()
                    } catch {
                        guard self.processToolsCatalogMutationIsCurrent(
                            brokerGeneration,
                            target: route.target,
                            sourceUpstream: route.upstreamIndices.last ?? -1
                        ) else {
                            return .stale
                        }
                        if let hook = self.testHooks.processToolsCatalogFailureCleanupBeforeApply {
                            await hook(route.target, route.upstreamIndices.last ?? -1)
                        }
                        let previousCatalog = self.processToolCatalogRegistry.catalog(
                            forProcessID: route.target.processID
                        )
                        let applied = self.applyToolCatalogSurfaceUpdate(
                            self.processToolCatalogRegistry.removeProcess(
                                processID: route.target.processID,
                                exposedProcessIDs: self.processToolCatalogExposedProcessIDs()
                            ),
                            onlyIfGeneration: brokerGeneration
                        )
                        guard applied else {
                            if let previousCatalog {
                                self.processToolCatalogRegistry.restoreCatalogIfMissing(
                                    previousCatalog,
                                    associatedUpstreamIndices: route.upstreamIndices
                                )
                            }
                            return .stale
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
        guard processRoutingEnabled, isInitialized() else {
            return
        }
        let unavailable = unavailableXcodeProcessIDs()
        let routes = xcodeProcessRoutes.compactMap { route -> AvailableToolsCatalogRoute? in
            guard unavailable.contains(route.target.processID) == false else {
                return nil
            }
            let upstreamIndices = recoveryAwareUsableInitializedUpstreamIndices(in: route)
            guard upstreamIndices.isEmpty == false else {
                return nil
            }
            let activation = availableToolsCatalogActivation(
                route: route,
                upstreamIndices: upstreamIndices
            )
            return AvailableToolsCatalogRoute(
                target: route.target,
                upstreamIndices: upstreamIndices,
                activationUpstreamIndex: activation?.upstreamIndex,
                activationAttempt: activation?.attempt
            )
        }
        let missingRoutes = routes.filter {
            if let requestedProcessIDs,
               requestedProcessIDs.contains($0.target.processID) == false {
                return false
            }
            return processToolCatalogRegistry.catalog(forProcessID: $0.target.processID) == nil
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
        scheduleAvailableToolsCatalogCompletion(
            missingRoutes,
            requestTimeout: MCP.MethodDispatcher.timeoutForControlPlane(
                defaultSeconds: config.requestTimeout
            ),
            exposedProcessIDs: Set(routes.map { $0.target.processID })
        )
    }

    func scheduleMissingProcessToolsCatalogRetry(
        processID: pid_t,
        reason: String
    ) {
        _ = pendingProcessToolsCatalogRefreshProcessIDs.withLockedValue {
            $0.insert(processID)
        }
        let delay = TimeAmount.milliseconds(250)
        let generation = canonicalBrokerState.generation()
        let shouldSchedule = scheduledProcessToolsCatalogRetries.withLockedValue {
            $0[processID] == nil
        }
        guard shouldSchedule else {
            return
        }
        logger.debug(
            "Scheduling missing process tools/list catalog retry",
            metadata: [
                "pid": .string("\(processID)"),
                "delay_ms": .string("250"),
                "reason": .string(reason),
            ]
        )
        let timeout = scheduleRuntimeTimeout(delay) { [weak self] in
            guard let self else { return }
            let isScheduledRetry = self.scheduledProcessToolsCatalogRetries.withLockedValue {
                retries -> Bool in
                guard let retry = retries[processID],
                      retry.generation == generation else {
                    return false
                }
                retries.removeValue(forKey: processID)
                return true
            }
            guard isScheduledRetry,
                  self.canonicalBrokerState.generation() == generation,
                  self.processRoutingEnabled,
                  self.xcodeProcessRoutes.contains(where: {
                      $0.target.processID == processID
                  }),
                  self.pendingProcessToolsCatalogRefreshProcessIDs.withLockedValue({
                      $0.contains(processID)
                  }),
                  self.processToolCatalogRegistry.catalog(forProcessID: processID) == nil
            else {
                return
            }
            self.refreshMissingProcessToolsCatalogsIfNeeded(
                reason: "scheduled_\(reason)",
                processIDs: [processID]
            )
        }
        let didSchedule = scheduledProcessToolsCatalogRetries.withLockedValue { retries in
            guard retries[processID] == nil else {
                return false
            }
            retries[processID] = ScheduledProcessToolsCatalogRetry(
                generation: generation,
                timeout: timeout
            )
            return true
        }
        if didSchedule == false {
            timeout.cancel()
        }
    }

    private func availableToolsCatalogSurfaceResult(
        startedAt: UInt64,
        exposedProcessIDs: Set<pid_t>,
        fallback: CanonicalToolsCatalogLoadResult
    ) -> CanonicalToolsCatalogLoadResult {
        guard let surface = processToolCatalogRegistry.availableToolCatalogSurface(
            processIDs: exposedProcessIDs
        ) else {
            return fallback
        }
        return CanonicalToolsCatalogLoadResult(
            rawResult: surface.rawResult,
            sourceUpstream: surface.sourceUpstream ?? fallback.sourceUpstream,
            durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt),
            cacheableAsCanonical: surface.processIDs == exposedProcessIDs
        )
    }

    private func recordAvailableToolsCatalog(
        target: XcodeProcessTarget,
        activationUpstreamIndex: Int?,
        activationAttempt: Int?,
        result: CanonicalToolsCatalogLoadResult,
        startedAt: UInt64,
        exposedProcessIDs: Set<pid_t>,
        brokerGeneration: UInt64?
    ) -> CanonicalToolsCatalogLoadResult? {
        guard let sourceUpstream = result.sourceUpstream else {
            return result
        }
        guard let activeRoute = xcodeProcessRoutes.first(where: {
            $0.target == target && $0.upstreamIndices.contains(sourceUpstream)
        }) else {
            logger.debug(
                "Dropping stale process tools/list catalog",
                metadata: [
                    "pid": .string("\(target.processID)"),
                    "app_path": .string(target.appPath),
                    "xcode_version": .string(target.xcodeVersion),
                    "upstream": .string("\(sourceUpstream)"),
                ]
            )
            return nil
        }
        guard processToolsCatalogMutationIsCurrent(
            brokerGeneration,
            target: target,
            sourceUpstream: sourceUpstream
        ) else {
            return nil
        }
        let hadProcessCatalog =
            processToolCatalogRegistry.catalog(forProcessID: target.processID) != nil
        // Empty tools arrays are valid MCP wire shape, but they are not a
        // usable process-bound Xcode catalog surface.
        guard ProcessToolCatalogRegistry.hasUsableTools(in: result.rawResult) else {
            logger.debug(
                "Dropping empty process tools/list catalog",
                metadata: [
                    "pid": .string("\(target.processID)"),
                    "app_path": .string(target.appPath),
                    "xcode_version": .string(target.xcodeVersion),
                    "upstream": .string("\(sourceUpstream)"),
                ]
            )
            if let activationUpstreamIndex, let activationAttempt {
                xcodeProcessRouteActivationTracker.finishCatalogWaitWithoutCatalog(
                    processID: target.processID,
                    upstreamIndex: activationUpstreamIndex,
                    attempt: activationAttempt
                )
            }
            scheduleMissingProcessToolsCatalogRetry(
                processID: target.processID,
                reason: "empty_process_catalog"
            )
            if hadProcessCatalog {
                let previousCatalog = processToolCatalogRegistry.catalog(
                    forProcessID: target.processID
                )
                let applied = applyToolCatalogSurfaceUpdate(
                    processToolCatalogRegistry.removeProcess(
                        processID: target.processID,
                        exposedProcessIDs: processToolCatalogExposedProcessIDs()
                    ),
                    onlyIfGeneration: brokerGeneration
                )
                guard applied else {
                    if let brokerGeneration {
                        cancelScheduledProcessToolsCatalogRetry(
                            processID: target.processID,
                            generation: brokerGeneration
                        )
                    }
                    if let previousCatalog {
                        processToolCatalogRegistry.restoreCatalogIfMissing(
                            previousCatalog,
                            associatedUpstreamIndices: activeRoute.upstreamIndices
                        )
                    }
                    return nil
                }
                guard let surface = processToolCatalogRegistry.availableToolCatalogSurface(
                    processIDs: exposedProcessIDs
                ),
                    let surfaceSourceUpstream = surface.sourceUpstream
                else {
                    return nil
                }
                return CanonicalToolsCatalogLoadResult(
                    rawResult: surface.rawResult,
                    sourceUpstream: surfaceSourceUpstream,
                    durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt),
                    cacheableAsCanonical: surface.processIDs == exposedProcessIDs
                )
            }
            return nil
        }
        let resolvedActivation: (upstreamIndex: Int, attempt: Int)?
        if let activationUpstreamIndex, let activationAttempt {
            resolvedActivation = (activationUpstreamIndex, activationAttempt)
        } else {
            resolvedActivation = availableToolsCatalogActivation(
                route: activeRoute,
                upstreamIndices: activeRoute.upstreamIndices
            )
        }
        if let resolvedActivation,
           markProcessRouteActivationCataloged(
               target: target,
               upstreamIndex: sourceUpstream,
               activationUpstreamIndex: resolvedActivation.upstreamIndex,
               attempt: resolvedActivation.attempt
           ) == false {
            if hadProcessCatalog {
                return availableToolsCatalogSurfaceResult(
                    startedAt: startedAt,
                    exposedProcessIDs: exposedProcessIDs,
                    fallback: result
                )
            }
            guard xcodeProcessRouteActivationTracker.isCataloged(
                processID: target.processID,
                attempt: resolvedActivation.attempt
            ) else {
                logger.debug(
                    "Dropping stale process tools/list catalog",
                    metadata: [
                        "pid": .string("\(target.processID)"),
                        "app_path": .string(target.appPath),
                        "xcode_version": .string(target.xcodeVersion),
                        "upstream": .string("\(sourceUpstream)"),
                        "activation_attempt": .string("\(resolvedActivation.attempt)"),
                    ]
                )
                return nil
            }
        }
        let previousCatalog = processToolCatalogRegistry.catalog(forProcessID: target.processID)
        let applied = applyToolCatalogSurfaceUpdate(
            processToolCatalogRegistry.recordCatalog(
                target: target,
                upstreamIndex: sourceUpstream,
                associatedUpstreamIndices: activeRoute.upstreamIndices,
                rawResult: result.rawResult,
                exposedProcessIDs: processToolCatalogExposedProcessIDs()
            ),
            onlyIfGeneration: brokerGeneration
        )
        guard applied else {
            processToolCatalogRegistry.rollbackRecordCatalogIfCurrent(
                processID: target.processID,
                attemptedUpstreamIndex: sourceUpstream,
                attemptedRawResult: result.rawResult,
                previousCatalog: previousCatalog,
                associatedUpstreamIndices: activeRoute.upstreamIndices
            )
            return nil
        }
        if resolvedActivation == nil {
            _ = markProcessRouteActivationCataloged(
                target: target,
                upstreamIndex: sourceUpstream
            )
        }
        _ = pendingProcessToolsCatalogRefreshProcessIDs.withLockedValue {
            $0.remove(target.processID)
        }
        cancelScheduledProcessToolsCatalogRetry(processID: target.processID)
        let surface = processToolCatalogRegistry.availableToolCatalogSurface(
            processIDs: exposedProcessIDs
        )
        return CanonicalToolsCatalogLoadResult(
            rawResult: surface?.rawResult ?? result.rawResult,
            sourceUpstream: surface?.sourceUpstream ?? sourceUpstream,
            durationMilliseconds: elapsedMilliseconds(sinceUptimeNanoseconds: startedAt),
            cacheableAsCanonical: surface?.processIDs == exposedProcessIDs
        )
    }

    private func processToolsCatalogMutationIsCurrent(
        _ expectedGeneration: UInt64?,
        target: XcodeProcessTarget,
        sourceUpstream: Int
    ) -> Bool {
        guard let expectedGeneration else {
            return true
        }
        guard canonicalBrokerState.generation() == expectedGeneration else {
            logger.debug(
                "Dropping stale process tools/list catalog",
                metadata: [
                    "pid": .string("\(target.processID)"),
                    "app_path": .string(target.appPath),
                    "xcode_version": .string(target.xcodeVersion),
                    "upstream": .string("\(sourceUpstream)"),
                    "expected_generation": .string("\(expectedGeneration)"),
                    "current_generation": .string("\(canonicalBrokerState.generation())"),
                ]
            )
            return false
        }
        return true
    }

    private func availableToolsCatalogActivation(
        route: XcodeProcessRoute,
        upstreamIndices: [Int]
    ) -> (upstreamIndex: Int, attempt: Int)? {
        guard processToolCatalogRegistry.catalog(forProcessID: route.target.processID) == nil,
              let primaryUpstreamIndex = route.primaryUpstreamIndex
        else {
            return nil
        }
        guard let attempt = processRouteActivationCatalogAttempt(
            processID: route.target.processID,
            upstreamIndex: primaryUpstreamIndex
        ) else {
            return nil
        }
        return (primaryUpstreamIndex, attempt)
    }

    private func scheduleAvailableToolsCatalogCompletion(
        _ routes: [AvailableToolsCatalogRoute],
        requestTimeout: TimeAmount?,
        exposedProcessIDs: Set<pid_t>
    ) {
        let key = availableToolsCatalogRefreshKey(for: routes)
        let shouldStart = availableToolsCatalogRefreshKeys.withLockedValue { keys in
            keys.insert(key).inserted
        }
        guard shouldStart else {
            return
        }
        let accepted = addRuntimeTask { [weak self] in
            guard let self else { return }
            defer {
                _ = self.availableToolsCatalogRefreshKeys.withLockedValue { keys in
                    keys.remove(key)
                }
            }
            let startedAt = self.nowUptimeNanoseconds()
            let generation = self.canonicalBrokerState.generation()
            do {
                let result = try await self.loadAvailableToolsCatalogsInBatch(
                    routes,
                    requestTimeout: requestTimeout,
                    deadlineUptimeNs: self.deadlineUptimeNanoseconds(for: requestTimeout),
                    startedAt: startedAt,
                    exposedProcessIDs: exposedProcessIDs,
                    brokerGeneration: generation,
                    returnAfterFirstSuccess: false
                )
                guard result.cacheableAsCanonical,
                      let sourceUpstream = result.sourceUpstream,
                      self.canonicalBrokerState.generation() == generation else {
                    return
                }
                self.canonicalBrokerState.syncCanonicalToolsCatalog(
                    result.rawResult,
                    sourceUpstream: sourceUpstream,
                    onlyIfGeneration: generation
                )
                await self.controlPlaneCoordinator.syncDebug()
            } catch is CancellationError {
            } catch {
            }
        }
        if accepted == false {
            _ = availableToolsCatalogRefreshKeys.withLockedValue { keys in
                keys.remove(key)
            }
        }
    }

    private func availableToolsCatalogRefreshKey(
        for routes: [AvailableToolsCatalogRoute]
    ) -> String {
        routes
            .map { route in
                if let activationAttempt = route.activationAttempt {
                    return "\(route.target.processID):\(activationAttempt)"
                }
                return "\(route.target.processID)"
            }
            .sorted()
            .joined(separator: ",")
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
            // Fallback-upstream RPCs are registered on the activation attempt
            // too; otherwise they outlive the catalog-phase timeout and their
            // late failure would drop a catalog recorded by a newer attempt.
            if let activationUpstreamIndex = route.activationUpstreamIndex,
               let activationAttempt = route.activationAttempt {
                xcodeProcessRouteActivationTracker.storeCatalogRPCHandle(
                    processID: route.target.processID,
                    upstreamIndex: activationUpstreamIndex,
                    attempt: activationAttempt,
                    rpcHandle: rpcHandle
                )
            }
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
                throw CancellationError()
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
