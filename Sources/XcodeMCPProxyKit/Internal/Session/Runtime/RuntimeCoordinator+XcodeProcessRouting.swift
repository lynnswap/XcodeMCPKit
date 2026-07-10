import Foundation
import Logging
import NIOCore
import XcodeMCPKit

extension RuntimeCoordinator {
    private static let xcodeProcessRouteUnavailableCooldownNanoseconds: UInt64 =
        2_000_000_000
    private static let xcodeProcessRouteCatalogUnavailableCooldownNanoseconds: UInt64 =
        30_000_000_000

    private struct ToolRoutingRequest: Sendable {
        let id: JSONRPC.ID?
        let toolName: String
        let tabIdentifier: String?
        let workspacePath: String?
    }

    private struct XcodeListWindowsRoute: Sendable {
        let ordinal: Int
        let target: XcodeProcessTarget
        let upstreamIndices: [Int]
    }

    private enum XcodeListWindowsOutcome: Sendable {
        case success(ordinal: Int, target: XcodeProcessTarget, upstreamIndex: Int, result: JSONValue)
        case failure(target: XcodeProcessTarget, upstreamIndex: Int, error: any Error)
    }

    enum XcodeListWindowsRouteScope: Sendable {
        case catalogSurface
        case ownerDiscovery
    }

    private enum XcodeListWindowsRoutingEligibility {
        case localOnly
        case forwardWholeBatch
        case reject
    }

    private struct OwnerResolutionConflict: Sendable {
        let request: ToolRoutingRequest
        let message: String
    }

    private enum CachedOwnerResolution: Sendable {
        case resolved(processID: pid_t, ownerLabel: String, proof: WindowRouteProof)
        case unresolved
        case conflict(String)
    }

    func liveXcodeListWindowsAcrossProcessRoutes(
        deadlineUptimeNs: UInt64?,
        routeScope: XcodeListWindowsRouteScope
    ) async throws -> JSONValue {
        let exposure = processRouteExposure(policy: .windowDiscovery)
        let usableRoutes = exposure.routes.map { routeExposure in
            return XcodeListWindowsRoute(
                ordinal: routeExposure.ordinal,
                target: routeExposure.route.target,
                upstreamIndices: routeExposure.usableUpstreamIndices
            )
        }
        let usableProcessIDs = Set(usableRoutes.map(\.target.processID))
        let catalogedProcessIDs =
            processControlPlane.processIDsWithCatalog()
            .intersection(usableProcessIDs)
        let catalogProcessIDs =
            processControlPlane.processIDsHavingTool("XcodeListWindows")
            .intersection(usableProcessIDs)
        let routes = usableRoutes.filter {
            includesXcodeListWindowsRoute(
                $0.target,
                catalogedProcessIDs: catalogedProcessIDs,
                catalogProcessIDs: catalogProcessIDs,
                routeScope: routeScope
            )
        }
        let queriedProcessIDs = Set(routes.map(\.target.processID))
        for skippedProcessID in usableProcessIDs.subtracting(queriedProcessIDs) {
            removeXcodeWindowOwners(forProcessID: skippedProcessID)
        }

        guard routes.isEmpty == false else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }

        return try await withThrowingTaskGroup(
            of: XcodeListWindowsOutcome.self,
            returning: JSONValue.self
        ) { group in
            for route in routes {
                group.addTask {
                    do {
                        let loaded = try await self.loadXcodeListWindowsFromProcessRoute(
                            route,
                            deadlineUptimeNs: deadlineUptimeNs
                        )
                        return .success(
                            ordinal: route.ordinal,
                            target: route.target,
                            upstreamIndex: loaded.upstreamIndex,
                            result: loaded.result
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

            var results: [(ordinal: Int, upstreamIndex: Int, result: JSONValue)] = []
            var lastError: (any Error)?
            while let outcome = try await group.next() {
                switch outcome {
                case .success(let ordinal, _, let upstreamIndex, let result):
                    markXcodeProcessRouteAvailable(upstreamIndex: upstreamIndex)
                    results.append(
                        (ordinal: ordinal, upstreamIndex: upstreamIndex, result: result)
                    )
                case .failure(let target, let upstreamIndex, let error):
                    if error is CancellationError {
                        throw CancellationError()
                    }
                    lastError = error
                    markXcodeProcessRouteUnavailable(
                        upstreamIndex: upstreamIndex,
                        reason: "xcode_list_windows_failed"
                    )
                    logger.debug(
                        "XcodeListWindows process route failed",
                        metadata: [
                            "pid": .string("\(target.processID)"),
                            "upstream": .string("\(upstreamIndex)"),
                            "error": .string(String(describing: error)),
                        ]
                    )
                }
            }

            let orderedRouteResults = results.sorted { $0.ordinal < $1.ordinal }
            recordXcodeWindowOwners(fromOrderedRouteResults: orderedRouteResults)
            let orderedResults = orderedRouteResults.map {
                rewriteXcodeListWindowsResultForClients(
                    $0.result,
                    upstreamIndex: $0.upstreamIndex
                )
            }
            if let merged = Self.mergedXcodeListWindowsResult(orderedResults) {
                return merged
            }
            if let lastError {
                throw lastError
            }
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
    }

    private func includesXcodeListWindowsRoute(
        _ target: XcodeProcessTarget,
        catalogedProcessIDs: Set<pid_t>,
        catalogProcessIDs: Set<pid_t>,
        routeScope: XcodeListWindowsRouteScope
    ) -> Bool {
        let processID = target.processID
        if catalogProcessIDs.contains(processID) {
            return true
        }
        if catalogedProcessIDs.contains(processID) {
            return false
        }
        switch routeScope {
        case .catalogSurface:
            return catalogedProcessIDs.isEmpty
        case .ownerDiscovery:
            return true
        }
    }

    private func loadXcodeListWindowsFromProcessRoute(
        _ route: XcodeListWindowsRoute,
        deadlineUptimeNs: UInt64?
    ) async throws -> (upstreamIndex: Int, result: JSONValue) {
        var lastFailure: (upstreamIndex: Int, error: any Error)?
        for upstreamIndex in route.upstreamIndices {
            do {
                let result = try await self.awaitControlPlaneOperation {
                    try await self.controlPlaneCoordinator.listWindows(
                        route: .pinnedUpstream(upstreamIndex),
                        deadlineUptimeNs: deadlineUptimeNs
                    )
                }
                if Self.xcodeListWindowsIsErrorResult(result) {
                    throw ControlPlane.Error.upstreamRPC(
                        code: -32000,
                        message: Self.xcodeListWindowsMessage(in: result)
                            ?? "XcodeListWindows returned tool error"
                    )
                }
                return (upstreamIndex, result)
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

    func primaryUpstreamIndex(forXcodeProcessID processID: pid_t) -> Int? {
        xcodeProcessRoutes.first { $0.target.processID == processID }?.primaryUpstreamIndex
    }

    func xcodeProcessRouteHasUsableInitializedUpstream(
        containing upstreamIndex: Int
    ) -> Bool {
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex) else {
            return false
        }
        return firstUsableInitializedUpstreamIndex(in: route) != nil
    }

    func documentationCandidateProcessIDs() -> Set<pid_t>? {
        guard processRoutingEnabled else {
            return nil
        }
        let unavailable = unavailableXcodeProcessIDs()
        return Set(xcodeProcessRoutes.compactMap { route in
            unavailable.contains(route.target.processID) == false
                && firstUsableInitializedUpstreamIndex(in: route) != nil
                ? route.target.processID
                : nil
        })
    }

    func catalogEligibleConfiguredProcessIDs() -> Set<pid_t> {
        let unavailable = unavailableXcodeProcessIDs()
        return Set(xcodeProcessRoutes.compactMap { route in
            unavailable.contains(route.target.processID) ? nil : route.target.processID
        })
    }

    func catalogExposedUsableProcessIDs() -> Set<pid_t> {
        processRouteExposure(policy: .toolsCatalog).processIDs
    }

    func unavailableXcodeProcessIDs() -> Set<pid_t> {
        processControlPlane.unavailableProcessIDs(nowUptimeNs: nowUptimeNanoseconds())
    }

    func markXcodeProcessRouteUnavailable(
        upstreamIndex: Int,
        reason: String
    ) {
        markXcodeProcessRouteUnavailable(
            upstreamIndex: upstreamIndex,
            reason: reason,
            cooldownNanoseconds: Self.xcodeProcessRouteUnavailableCooldownNanoseconds,
            scope: .route
        )
    }

    func markXcodeProcessRouteUnavailableAfterCatalogFailure(
        upstreamIndex: Int,
        reason: String
    ) {
        markXcodeProcessRouteUnavailable(
            upstreamIndex: upstreamIndex,
            reason: reason,
            cooldownNanoseconds: Self.xcodeProcessRouteCatalogUnavailableCooldownNanoseconds,
            scope: .catalog
        )
    }

    private func markXcodeProcessRouteUnavailable(
        upstreamIndex: Int,
        reason: String,
        cooldownNanoseconds: UInt64,
        scope: ProcessControlPlaneAuthority.CooldownScope
    ) {
        let nowUptimeNs = nowUptimeNanoseconds()
        let unavailableUntil = nowUptimeNs
            &+ cooldownNanoseconds
        guard let unavailable = processControlPlane.markUnavailable(
            upstreamIndex: upstreamIndex,
            scope: scope,
            nowUptimeNs: nowUptimeNs,
            unavailableUntilUptimeNs: unavailableUntil
        ) else {
            return
        }
        let route = unavailable.route
        applyProcessControlPlaneTransition(unavailable.transition)
        removeXcodeWindowOwners(forUpstreamIndex: upstreamIndex)
        logger.debug(
            "Temporarily ignoring Xcode process route",
            metadata: [
                "pid": .string("\(route.target.processID)"),
                "app_path": .string(route.target.appPath),
                "xcode_version": .string(route.target.xcodeVersion),
                "upstream": .string("\(upstreamIndex)"),
                "reason": .string(reason),
                "cooldown_ms": .string("\(cooldownNanoseconds / 1_000_000)"),
                "unavailable_until_uptime_ns": .string("\(unavailableUntil)"),
            ]
        )
    }

    func markXcodeProcessRouteAvailable(upstreamIndex: Int) {
        applyProcessControlPlaneTransition(processControlPlane.markAvailable(
            upstreamIndex: upstreamIndex,
            scope: .route,
            nowUptimeNs: nowUptimeNanoseconds()
        ))
    }

    func markXcodeProcessRouteCatalogAvailable(upstreamIndex: Int) {
        applyProcessControlPlaneTransition(processControlPlane.markAvailable(
            upstreamIndex: upstreamIndex,
            scope: .catalog,
            nowUptimeNs: nowUptimeNanoseconds()
        ))
    }

    func removeXcodeWindowOwners(forUpstreamIndex upstreamIndex: Int) {
        guard let processID = processID(forUpstreamIndex: upstreamIndex) else {
            return
        }
        removeXcodeWindowOwners(forProcessID: processID)
    }

    func removeXcodeWindowOwners(forProcessID processID: pid_t) {
        _ = windowOwnershipAuthority.remove(processID: processID)
    }

    func clearXcodeWindowOwners() {
        _ = windowOwnershipAuthority.removeAll()
    }

    func documentationUpstreamIndex(for target: XcodeProcessTarget) -> Int? {
        guard let route = xcodeProcessRoutes.first(where: {
            $0.target.processID == target.processID
        }) else {
            return nil
        }
        return firstUsableInitializedUpstreamIndex(in: route)
    }

    func firstUsableInitializedUpstreamIndex(in route: XcodeProcessRoute) -> Int? {
        usableInitializedUpstreamIndices(in: route).first
    }

    func usableInitializedUpstreamIndices(in route: XcodeProcessRoute) -> [Int] {
        processRouteExposure(policy: .ownerRouting)
            .routes
            .first { $0.route.id == route.id }?
            .usableUpstreamIndices ?? []
    }

    func processRouteExposure(
        policy: ProcessControlPlaneAuthority.ExposurePolicy
    ) -> ProcessControlPlaneAuthority.RoutingSnapshot {
        let nowUptimeNs = nowUptimeNanoseconds()
        let upstreamUsability = processRouteUpstreamUsabilitySnapshot(
            policy: policy,
            nowUptimeNs: nowUptimeNs
        )
        applyProcessControlPlaneTransition(
            processControlPlane.updateUsability(upstreamUsability, nowUptimeNs: nowUptimeNs)
        )
        return processControlPlane.routingSnapshot(policy: policy, nowUptimeNs: nowUptimeNs)
    }

    func processRouteUpstreamUsabilitySnapshot(
        policy: ProcessControlPlaneAuthority.ExposurePolicy,
        nowUptimeNs: UInt64
    ) -> ProcessControlPlaneAuthority.UpstreamUsabilitySnapshot {
        let states = upstreamHealthManager.activeStatesSnapshot()
        let snapshotUsable = Set(states.compactMap { upstreamID, state -> Int? in
            guard state.isInitialized else {
                return nil
            }
            switch state.healthState {
            case .healthy, .degraded:
                return upstreamID.rawValue
            case .quarantined:
                return nil
            }
        })

        var recoveryAwareUsable = snapshotUsable
        switch policy {
        case .toolsCatalog:
            var effects: [UpstreamHealthManager.Effect] = []
            recoveryAwareUsable = Set(states.compactMap { upstreamID, _ -> Int? in
                let evaluation = upstreamHealthManager.evaluateUsableInitialized(
                    index: upstreamID.rawValue,
                    nowUptimeNs: nowUptimeNs
                )
                effects.append(contentsOf: evaluation.effects)
                return evaluation.isUsable ? upstreamID.rawValue : nil
            })
            applyHealthEffects(effects)
        case .ownerRouting, .windowDiscovery, .initialization:
            break
        }

        return ProcessControlPlaneAuthority.UpstreamUsabilitySnapshot(
            snapshotUsableUpstreamIDs: Set(snapshotUsable.map(UpstreamSlotID.init(rawValue:))),
            recoveryAwareUsableUpstreamIDs: Set(
                recoveryAwareUsable.map(UpstreamSlotID.init(rawValue:))
            )
        )
    }

    func preferredUpstreamIndex(for requestJSON: Any) -> Int? {
        guard processRoutingEnabled else {
            return nil
        }
        let indices = preferredUpstreamIndices(in: requestJSON)
        guard indices.count == 1 else {
            return nil
        }
        return indices.first
    }

    func toolRoutingDecision(
        for requestJSON: Any,
        requestTimeoutOverride: TimeAmount?
    ) async -> ToolRoutingDecision {
        if let immediate = immediateToolRoutingDecision(for: requestJSON) {
            return immediate
        }
        return await ownerBoundToolRoutingDecision(
            for: requestJSON,
            requestTimeoutOverride: requestTimeoutOverride
        )
    }

    func immediateToolRoutingDecision(for requestJSON: Any) -> ToolRoutingDecision? {
        guard processRoutingEnabled else {
            return .forward(preferredUpstreamIndex: nil)
        }
        let requests = toolRoutingRequests(in: requestJSON)
        let xcodeListWindowsRequests = requests.filter {
            $0.id != nil && $0.toolName == "XcodeListWindows"
        }
        if xcodeListWindowsRequests.isEmpty == false {
            switch xcodeListWindowsRoutingEligibility(in: requestJSON) {
            case .localOnly:
                return .localXcodeListWindows
            case .forwardWholeBatch:
                break
            case .reject:
                return .reject(
                    errors: toolRoutingErrors(
                        for: requests,
                        message: "XcodeListWindows must be resolved locally before forwarding mixed batches"
                    ),
                    forceBatchArray: requestJSON is [Any]
                )
            }
        }
        let ownerBoundRequests = requests.filter {
            isOwnerBoundRoutingRequest($0)
        }
        guard ownerBoundRequests.isEmpty == false else {
            if let catalogDecision = catalogToolRoutingDecision(
                for: requests,
                requiredProcessID: nil,
                forceBatchArray: requestJSON is [Any]
            ) {
                return catalogDecision
            }
            return .forward(preferredUpstreamIndex: preferredUpstreamIndex(for: requestJSON))
        }
        return nil
    }

    private func ownerBoundToolRoutingDecision(
        for requestJSON: Any,
        requestTimeoutOverride: TimeAmount?
    ) async -> ToolRoutingDecision {
        let requests = toolRoutingRequests(in: requestJSON)
        let ownerBoundRequests = requests.filter {
            isOwnerBoundRoutingRequest($0)
        }

        var ownerResolution = resolvedOwnerProcessIDs(for: ownerBoundRequests)
        var inferredOwnerProcessID =
            inferredUnambiguousOwnerProcessID(
                for: requests,
                unresolvedOwnerBoundRequests: ownerResolution.unresolved
            )
        let needsOwnerRefresh =
            ownerResolution.conflicts.isEmpty == false
            || (ownerResolution.unresolved.isEmpty == false && inferredOwnerProcessID == nil)
        if needsOwnerRefresh {
            _ = try? await refreshXcodeWindowOwnersForRouting(
                requestTimeoutOverride: requestTimeoutOverride
            )
            ownerResolution = resolvedOwnerProcessIDs(for: ownerBoundRequests)
            inferredOwnerProcessID =
                inferredUnambiguousOwnerProcessID(
                    for: requests,
                    unresolvedOwnerBoundRequests: ownerResolution.unresolved
                )
        }

        if ownerResolution.conflicts.isEmpty == false {
            let errors = ownerResolution.conflicts.compactMap { conflict -> ToolRoutingError? in
                guard let id = conflict.request.id else { return nil }
                return ToolRoutingError(id: id, message: conflict.message)
            }
            return .reject(
                errors: errors.isEmpty
                    ? toolRoutingErrors(
                        for: requests,
                        message: "conflicting Xcode window owners for one or more tools"
                    )
                    : errors,
                forceBatchArray: requestJSON is [Any]
            )
        }

        if ownerResolution.unresolved.isEmpty == false, inferredOwnerProcessID == nil {
            return .reject(
                errors: toolRoutingErrors(
                    for: requests,
                    message: "unable to resolve Xcode window owner for one or more tools"
                ),
                forceBatchArray: requestJSON is [Any]
            )
        }

        var proofsRemainCurrent = ownerResolution.resolved.allSatisfy { resolved in
            windowOwnershipAuthority.validate(resolved.proof.windowEpoch)
                && processControlPlane.admit(resolved.proof.route) != nil
        }
        if proofsRemainCurrent == false {
            ownerResolution = resolvedOwnerProcessIDs(for: ownerBoundRequests)
            inferredOwnerProcessID = inferredUnambiguousOwnerProcessID(
                for: requests,
                unresolvedOwnerBoundRequests: ownerResolution.unresolved
            )
            if ownerResolution.conflicts.isEmpty == false {
                let errors = ownerResolution.conflicts.compactMap {
                    conflict -> ToolRoutingError? in
                    guard let id = conflict.request.id else { return nil }
                    return ToolRoutingError(id: id, message: conflict.message)
                }
                return .reject(
                    errors: errors.isEmpty
                        ? toolRoutingErrors(
                            for: requests,
                            message: "conflicting Xcode window owners for one or more tools"
                        )
                        : errors,
                    forceBatchArray: requestJSON is [Any]
                )
            }
            if ownerResolution.unresolved.isEmpty == false,
               inferredOwnerProcessID == nil {
                return .reject(
                    errors: toolRoutingErrors(
                        for: requests,
                        message: "unable to resolve Xcode window owner for one or more tools"
                    ),
                    forceBatchArray: requestJSON is [Any]
                )
            }
            proofsRemainCurrent = ownerResolution.resolved.allSatisfy { resolved in
                windowOwnershipAuthority.validate(resolved.proof.windowEpoch)
                    && processControlPlane.admit(resolved.proof.route) != nil
            }
        }
        guard proofsRemainCurrent else {
            return .reject(
                errors: toolRoutingErrors(
                    for: requests,
                    message: "Xcode window ownership changed while routing the request"
                ),
                forceBatchArray: requestJSON is [Any]
            )
        }

        var distinctOwners = Set(ownerResolution.resolved.map(\.processID))
        if let inferredOwnerProcessID {
            distinctOwners.insert(inferredOwnerProcessID)
        }
        if distinctOwners.count > 1 {
            return .reject(
                errors: requests.compactMap { request in
                    guard let id = request.id else { return nil }
                    return ToolRoutingError(
                        id: id,
                        message: "mixed Xcode window owners in one batch are not supported"
                    )
                },
                forceBatchArray: true
            )
        }

        guard let ownerProcessID = distinctOwners.first else {
            return .forward(preferredUpstreamIndex: preferredUpstreamIndex(for: requestJSON))
        }
        guard let ownerRoute = processControlPlane.route(forProcessID: ownerProcessID),
              let routeProof = processControlPlane.routeProof(routeID: ownerRoute.id),
              let routeAdmission = processControlPlane.admit(routeProof) else {
            return .reject(
                errors: toolRoutingErrors(
                    for: requests,
                    message: "Xcode process that owns one or more tools is no longer available"
                ),
                forceBatchArray: requestJSON is [Any]
            )
        }
        let ownerUpstreamIndices = usableInitializedUpstreamIndices(in: ownerRoute)

        let hasMissingTools = requests.contains { request in
            guard processControlPlane.catalog(forProcessID: ownerProcessID) != nil,
                  processControlPlane.hasTool(
                      request.toolName,
                      processID: ownerProcessID
                  ) == false else {
                return false
            }
            return true
        }
        if hasMissingTools {
            return .reject(
                errors: toolRoutingErrors(
                    for: requests,
                    message: "one or more tools are not available in the selected Xcode process"
                ),
                forceBatchArray: requestJSON is [Any]
            )
        }

        guard ownerUpstreamIndices.isEmpty == false else {
            return .reject(
                errors: toolRoutingErrors(
                    for: requests,
                    message: "no available upstream for Xcode process that owns one or more tools"
                ),
                forceBatchArray: requestJSON is [Any]
            )
        }

        let topology = upstreamTopology.snapshot()
        let upstreamProofs = ownerUpstreamIndices.compactMap { topology.proof(
            UpstreamSlotID(rawValue: $0)
        ) }
        guard upstreamProofs.count == ownerUpstreamIndices.count else {
            return .reject(
                errors: toolRoutingErrors(
                    for: requests,
                    message: "Xcode upstream topology changed while routing the request"
                ),
                forceBatchArray: requestJSON is [Any]
            )
        }
        return .forwardAdmitted(
            preferredUpstreamIndices: ownerUpstreamIndices,
            admission: RouteForwardingAdmission(
                route: routeAdmission,
                upstreamProofs: upstreamProofs
            )
        )
    }

    private func refreshXcodeWindowOwnersForRouting(
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue {
        let timeout =
            requestTimeoutOverride
            ?? MCP.MethodDispatcher.timeoutForMethod(
                "tools/call",
                defaultSeconds: config.requestTimeout
            )
        let deadline = timeoutDeadline(for: timeout)
        return try await liveXcodeListWindowsAcrossProcessRoutes(
            deadlineUptimeNs: deadline,
            routeScope: .ownerDiscovery
        )
    }

    private func inferredUnambiguousOwnerProcessID(
        for requests: [ToolRoutingRequest],
        unresolvedOwnerBoundRequests: [ToolRoutingRequest]
    ) -> pid_t? {
        guard unresolvedOwnerBoundRequests.isEmpty == false,
              unresolvedOwnerBoundRequests.allSatisfy({ hasNoOwnerHint($0) }) else {
            return nil
        }
        let usableRoutes = xcodeProcessRoutes.filter {
            usableInitializedUpstreamIndices(in: $0).isEmpty == false
                && unavailableXcodeProcessIDs().contains($0.target.processID) == false
        }
        if usableRoutes.count == 1 {
            return usableRoutes[0].target.processID
        }

        let processIDSets = Set(requests.map(\.toolName)).compactMap { toolName -> Set<pid_t>? in
            let processIDs = processControlPlane.processIDsHavingTool(toolName)
            return processIDs.isEmpty ? nil : processIDs
        }
        guard processIDSets.isEmpty == false else {
            return nil
        }
        let candidateProcessIDs = processIDSets.dropFirst().reduce(processIDSets[0]) {
            $0.intersection($1)
        }
        let usableProcessIDs = Set(usableRoutes.map(\.target.processID))
        let usableCandidates = candidateProcessIDs.intersection(usableProcessIDs)
        guard usableCandidates.count == 1 else {
            return nil
        }
        return usableCandidates.first
    }

    private func hasNoOwnerHint(_ request: ToolRoutingRequest) -> Bool {
        !hasOwnerHint(request)
    }

    private func hasOwnerHint(_ request: ToolRoutingRequest) -> Bool {
        hasOwnerHint(
            tabIdentifier: request.tabIdentifier,
            workspacePath: request.workspacePath
        )
    }

    private func hasOwnerHint(tabIdentifier: String?, workspacePath: String?) -> Bool {
        tabIdentifier?.isEmpty == false || workspacePath?.isEmpty == false
    }

    private func toolRoutingErrors(
        for requests: [ToolRoutingRequest],
        message: String
    ) -> [ToolRoutingError] {
        requests.compactMap { request in
            guard let id = request.id else { return nil }
            return ToolRoutingError(id: id, message: message)
        }
    }

    private func catalogToolRoutingDecision(
        for requests: [ToolRoutingRequest],
        requiredProcessID: pid_t?,
        forceBatchArray: Bool
    ) -> ToolRoutingDecision? {
        let processIDSets = Set(requests.map(\.toolName)).compactMap { toolName -> Set<pid_t>? in
            let processIDs = processControlPlane.processIDsHavingTool(toolName)
            return processIDs.isEmpty ? nil : processIDs
        }
        guard processIDSets.isEmpty == false else {
            return nil
        }

        let candidateProcessIDs = processIDSets.dropFirst().reduce(processIDSets[0]) {
            $0.intersection($1)
        }
        let effectiveCandidates: Set<pid_t>
        if let requiredProcessID {
            effectiveCandidates = candidateProcessIDs.contains(requiredProcessID)
                ? [requiredProcessID]
                : []
        } else {
            effectiveCandidates = candidateProcessIDs
        }
        guard effectiveCandidates.isEmpty == false else {
            return .reject(
                errors: requests.compactMap { request in
                    guard let id = request.id else { return nil }
                    return ToolRoutingError(
                        id: id,
                        message: "no single Xcode process provides all requested tools"
                    )
                },
                forceBatchArray: forceBatchArray
            )
        }
        guard let route = preferredAvailableRoute(in: effectiveCandidates) else {
            return .reject(
                errors: requests.compactMap { request in
                    guard let id = request.id else { return nil }
                    return ToolRoutingError(
                        id: id,
                        message: "no available upstream for an Xcode process that provides tool '\(request.toolName)'"
                    )
                },
                forceBatchArray: forceBatchArray
            )
        }
        let upstreamIndices = usableInitializedUpstreamIndices(in: route)
        let topology = upstreamTopology.snapshot()
        guard let routeProof = processControlPlane.routeProof(routeID: route.id),
              let routeAdmission = processControlPlane.admit(routeProof) else {
            return .reject(
                errors: toolRoutingErrors(
                    for: requests,
                    message: "Xcode process route changed while routing the request"
                ),
                forceBatchArray: forceBatchArray
            )
        }
        let upstreamProofs = upstreamIndices.compactMap {
            topology.proof(UpstreamSlotID(rawValue: $0))
        }
        guard upstreamProofs.count == upstreamIndices.count else {
            return .reject(
                errors: toolRoutingErrors(
                    for: requests,
                    message: "Xcode upstream topology changed while routing the request"
                ),
                forceBatchArray: forceBatchArray
            )
        }
        return .forwardAdmitted(
            preferredUpstreamIndices: upstreamIndices,
            admission: RouteForwardingAdmission(
                route: routeAdmission,
                upstreamProofs: upstreamProofs
            )
        )
    }

    private func preferredAvailableRoute(in processIDs: Set<pid_t>) -> XcodeProcessRoute? {
        let unavailable = unavailableXcodeProcessIDs()
        return xcodeProcessRoutes
            .filter {
                processIDs.contains($0.target.processID)
                    && unavailable.contains($0.target.processID) == false
            }
            .sorted { lhs, rhs in
                let versionComparison = lhs.target.xcodeVersion.compare(
                    rhs.target.xcodeVersion,
                    options: [.numeric]
                )
                if versionComparison != .orderedSame {
                    return versionComparison == .orderedDescending
                }
                if lhs.target.appPath != rhs.target.appPath {
                    return lhs.target.appPath < rhs.target.appPath
                }
                return lhs.target.processID < rhs.target.processID
            }
            .first { firstUsableInitializedUpstreamIndex(in: $0) != nil }
    }

    @discardableResult
    func recordXcodeWindowOwners(
        from result: JSONValue,
        upstreamIndex: Int
    ) -> Bool {
        recordXcodeWindowOwners(
            from: result,
            upstreamIndex: upstreamIndex,
            removeExistingOwners: true,
            overwriteExistingOwners: true
        )
    }

    private func recordXcodeWindowOwners(
        fromOrderedRouteResults results: [(ordinal: Int, upstreamIndex: Int, result: JSONValue)]
    ) {
        let processIDs = Set(results.compactMap { processID(forUpstreamIndex: $0.upstreamIndex) })
        let entriesByProcessID: [(processID: pid_t, entries: [XcodeListWindowsEntry])] =
            results.compactMap { result in
                guard let processID = processID(forUpstreamIndex: result.upstreamIndex) else {
                    return nil
                }
                return (processID, Self.windowEntries(in: result.result))
            }
        let entries = Dictionary(uniqueKeysWithValues: entriesByProcessID.map {
            ($0.processID, $0.entries)
        })
        _ = windowOwnershipAuthority.replace(entries)
        for processID in processIDs where entries[processID] == nil {
            _ = windowOwnershipAuthority.remove(processID: processID)
        }
    }

    @discardableResult
    private func recordXcodeWindowOwners(
        from result: JSONValue,
        upstreamIndex: Int,
        removeExistingOwners: Bool,
        overwriteExistingOwners _: Bool
    ) -> Bool {
        guard let processID = processID(forUpstreamIndex: upstreamIndex) else {
            return false
        }
        let entries = Self.windowEntries(in: result)
        _ = removeExistingOwners
        _ = windowOwnershipAuthority.record(processID: processID, entries: entries)
        return entries.isEmpty == false
    }

    static func mergedXcodeListWindowsResult(
        _ results: [JSONValue]
    ) -> JSONValue? {
        let successfulResults = results.filter {
            xcodeListWindowsIsErrorResult($0) == false
        }
        let messages = successfulResults.compactMap(Self.xcodeListWindowsMessage(in:))
            .filter { $0.isEmpty == false }
        guard messages.isEmpty == false else {
            return successfulResults.first
                ?? results.first { Self.xcodeListWindowsIsErrorResult($0) }
                ?? results.first
        }
        let message = messages.joined(separator: "\n")
        let encodedMessage: String
        if let data = try? JSONSerialization.data(
            withJSONObject: ["message": message],
            options: [.sortedKeys]
        ) {
            encodedMessage = String(decoding: data, as: UTF8.self)
        } else {
            encodedMessage = message
        }
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(encodedMessage),
                ]),
            ]),
            "structuredContent": .object([
                "message": .string(message),
            ]),
        ])
    }

    func rewriteXcodeListWindowsResultForClients(
        _ result: JSONValue,
        upstreamIndex: Int
    ) -> JSONValue {
        guard let processID = processID(forUpstreamIndex: upstreamIndex) else {
            return result
        }
        let entries = Self.windowEntries(in: result)
        guard entries.isEmpty == false else {
            return result
        }
        let index = windowOwnershipAuthority.snapshot()
        let message = {
            entries.map { entry in
                let proxyTabIdentifier = index.proxyTabIdentifier(
                    processID: processID,
                    rawTabIdentifier: entry.tabIdentifier,
                    workspacePath: entry.workspacePath
                )
                return "* tabIdentifier: \(proxyTabIdentifier), workspacePath: \(entry.workspacePath)"
            }
            .joined(separator: "\n")
        }()
        return Self.xcodeListWindowsResult(message: message)
    }

    private static func xcodeListWindowsResult(message: String) -> JSONValue {
        let encodedMessage: String
        if let data = try? JSONSerialization.data(
            withJSONObject: ["message": message],
            options: [.sortedKeys]
        ) {
            encodedMessage = String(decoding: data, as: UTF8.self)
        } else {
            encodedMessage = message
        }
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(encodedMessage),
                ]),
            ]),
            "structuredContent": .object([
                "message": .string(message),
            ]),
        ])
    }

    private func preferredUpstreamIndices(in value: Any) -> Set<Int> {
        if let object = value as? [String: Any] {
            return Set(preferredUpstreamIndex(in: object).map { [$0] } ?? [])
        }
        guard let array = value as? [Any] else {
            return []
        }
        return array.reduce(into: Set<Int>()) { result, item in
            for upstreamIndex in preferredUpstreamIndices(in: item) {
                result.insert(upstreamIndex)
            }
        }
    }

    func xcodeProcessRoute(forUpstreamIndex upstreamIndex: Int) -> XcodeProcessRoute? {
        processControlPlane.route(forUpstreamIndex: upstreamIndex)
    }

    func isActiveProcessBoundUpstream(_ upstreamIndex: Int) -> Bool {
        guard processRoutingEnabled else { return true }
        return xcodeProcessRoute(forUpstreamIndex: upstreamIndex) != nil
    }

    func activeProcessBoundUpstreamIndices() -> Set<Int> {
        guard processRoutingEnabled else {
            return Set(upstreamSlotIDs.map(\.rawValue))
        }
        return Set(xcodeProcessRoutes.flatMap(\.upstreamIndices))
    }

    func routableProcessBoundUpstreamIndices() -> Set<Int> {
        guard processRoutingEnabled else {
            return Set(upstreamSlotIDs.map(\.rawValue))
        }
        let unavailable = unavailableXcodeProcessIDs()
        return Set(
            xcodeProcessRoutes
                .filter { unavailable.contains($0.target.processID) == false }
                .flatMap(\.upstreamIndices)
        )
    }

    func inactiveProcessBoundUpstreamIndices() -> Set<Int> {
        guard processRoutingEnabled else { return [] }
        return Set(upstreamSlotIDs.map(\.rawValue)).subtracting(
            routableProcessBoundUpstreamIndices()
        )
    }

    func secondaryUpstreamIndices(excluding upstreamIndex: Int) -> [Int] {
        let candidates = processRoutingEnabled
            ? xcodeProcessRoutes.flatMap(\.upstreamIndices)
            : upstreamSlotIDs.map(\.rawValue)
        return candidates.filter { $0 != upstreamIndex }
    }

    func activeInitializedHealthyishCount() -> Int {
        guard processRoutingEnabled else {
            return upstreamHealthManager.initializedHealthyishCount()
        }
        return routableProcessBoundUpstreamIndices().reduce(into: 0) { count, upstreamIndex in
            guard let upstream = upstreamHealthManager.state(
                for: UpstreamSlotID(rawValue: upstreamIndex)
            ) else { return }
            guard upstream.isInitialized else { return }
            switch upstream.healthState {
            case .healthy, .degraded:
                count += 1
            case .quarantined:
                break
            }
        }
    }

    func anyActiveInitializedUpstream() -> Bool {
        guard processRoutingEnabled else {
            return upstreamHealthManager.anyInitialized()
        }
        return routableProcessBoundUpstreamIndices().contains { upstreamIndex in
            upstreamHealthManager.state(
                for: UpstreamSlotID(rawValue: upstreamIndex)
            )?.isInitialized == true
        }
    }

    func anyActiveRecoveryInFlight() -> Bool {
        guard processRoutingEnabled else {
            return upstreamHealthManager.anyRecoveryInFlight()
        }
        return routableProcessBoundUpstreamIndices().contains { upstreamIndex in
            guard let upstream = upstreamHealthManager.state(
                for: UpstreamSlotID(rawValue: upstreamIndex)
            ) else { return false }
            return upstream.initInFlight || upstream.healthProbeInFlight
        }
    }

    private func processID(forUpstreamIndex upstreamIndex: Int) -> pid_t? {
        xcodeProcessRoute(forUpstreamIndex: upstreamIndex)?.target.processID
    }

    func rewriteOwnerBoundRequest(
        bodyData: Data,
        parsedRequestJSON: Any,
        upstreamIndex: Int
    ) -> (bodyData: Data, parsedRequestJSON: Any) {
        guard processRoutingEnabled,
              let processID = processID(forUpstreamIndex: upstreamIndex) else {
            return (bodyData, parsedRequestJSON)
        }
        let rewritten = rewriteOwnerBoundRequestJSON(
            parsedRequestJSON,
            processID: processID
        )
        guard rewritten.changed else {
            return (bodyData, parsedRequestJSON)
        }
        guard JSONSerialization.isValidJSONObject(rewritten.value),
              let data = try? JSONSerialization.data(
                withJSONObject: rewritten.value,
                options: []
              ) else {
            return (bodyData, parsedRequestJSON)
        }
        return (data, rewritten.value)
    }

    private func rewriteOwnerBoundRequestJSON(
        _ value: Any,
        processID: pid_t
    ) -> (value: Any, changed: Bool) {
        if let object = value as? [String: Any] {
            return rewriteOwnerBoundRequestObject(object, processID: processID)
        }
        guard let array = value as? [Any] else {
            return (value, false)
        }
        var changed = false
        let rewritten = array.map { item -> Any in
            guard let object = item as? [String: Any] else {
                return item
            }
            let result = rewriteOwnerBoundRequestObject(object, processID: processID)
            changed = changed || result.changed
            return result.value
        }
        return (rewritten, changed)
    }

    private func rewriteOwnerBoundRequestObject(
        _ object: [String: Any],
        processID: pid_t
    ) -> (value: [String: Any], changed: Bool) {
        guard JSONRPC.Message.Inspector.method(from: object) == "tools/call",
              var params = object["params"] as? [String: Any],
              let toolName = params["name"] as? String,
              var arguments = params["arguments"] as? [String: Any] else {
            return (object, false)
        }
        var changed = false

        if let tabIdentifier = arguments["tabIdentifier"] as? String,
           tabIdentifier.isEmpty == false,
           let rawTabIdentifier = rawTabIdentifierForForwarding(
            tabIdentifier: tabIdentifier,
            processID: processID
           ),
           rawTabIdentifier != tabIdentifier {
            arguments["tabIdentifier"] = rawTabIdentifier
            changed = true
        } else if (arguments["tabIdentifier"] as? String)?.isEmpty ?? true,
                  let workspacePath = arguments["workspacePath"] as? String,
                  workspacePath.isEmpty == false,
                  processControlPlane.tool(
                    toolName,
                    processID: processID,
                    requiresArgument: "tabIdentifier"
                  ),
                  let rawTabIdentifier = singleRawTabIdentifier(
                    workspacePath: workspacePath,
                    processID: processID
                  ) {
            arguments["tabIdentifier"] = rawTabIdentifier
            changed = true
        }

        guard changed else {
            return (object, false)
        }
        params["arguments"] = arguments
        var rewritten = object
        rewritten["params"] = params
        return (rewritten, true)
    }

    private func rawTabIdentifierForForwarding(
        tabIdentifier: String,
        processID: pid_t
    ) -> String? {
        let index = windowOwnershipAuthority.snapshot()
        guard let identity = index.identity(forProxyTabIdentifier: tabIdentifier),
              identity.processID == processID else { return nil }
        return identity.rawTabIdentifier
    }

    private func singleRawTabIdentifier(
        workspacePath: String,
        processID: pid_t
    ) -> String? {
        let identities = windowOwnershipAuthority.snapshot().identities(
            workspacePath: workspacePath,
            processID: processID
        )
        guard identities.count == 1 else { return nil }
        return identities[0].rawTabIdentifier
    }

    private func preferredUpstreamIndex(in object: [String: Any]) -> Int? {
        guard JSONRPC.Message.Inspector.method(from: object) == "tools/call",
              let params = object["params"] as? [String: Any],
              let toolName = params["name"] as? String,
              let arguments = params["arguments"] as? [String: Any] else {
            return nil
        }
        guard isKnownOwnerBoundTool(toolName) else {
            return nil
        }
        let tabIdentifier = (arguments["tabIdentifier"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        let workspacePath = (arguments["workspacePath"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        guard tabIdentifier != nil || workspacePath != nil,
              case .resolved(let processID, _, _) = cachedOwnerResolution(
                  tabIdentifier: tabIdentifier,
                  workspacePath: workspacePath
              ),
              let route = xcodeProcessRoutes.first(where: {
                  $0.target.processID == processID
              }) else {
            return nil
        }
        return firstUsableInitializedUpstreamIndex(in: route)
    }

    private func toolRoutingRequests(in value: Any) -> [ToolRoutingRequest] {
        if let object = value as? [String: Any] {
            return toolRoutingRequest(in: object).map { [$0] } ?? []
        }
        guard let array = value as? [Any] else {
            return []
        }
        return array.compactMap { item in
            guard let object = item as? [String: Any] else { return nil }
            return toolRoutingRequest(in: object)
        }
    }

    private func xcodeListWindowsRoutingEligibility(
        in value: Any
    ) -> XcodeListWindowsRoutingEligibility {
        if let object = value as? [String: Any] {
            return JSONRPC.Message.Inspector.requestID(from: object) != nil
                && isXcodeListWindowsToolCall(object)
                ? .localOnly
                : .reject
        }
        guard let array = value as? [Any],
              array.isEmpty == false else {
            return .reject
        }
        var sawResponseBearingItem = false
        var sawNotificationOrUnroutedItem = false
        for item in array {
            guard let object = item as? [String: Any] else {
                return .reject
            }
            guard JSONRPC.Message.Inspector.requestID(from: object) != nil else {
                sawNotificationOrUnroutedItem = true
                continue
            }
            sawResponseBearingItem = true
            guard isXcodeListWindowsToolCall(object) else {
                return .reject
            }
        }
        guard sawResponseBearingItem else {
            return .reject
        }
        return sawNotificationOrUnroutedItem ? .forwardWholeBatch : .localOnly
    }

    private func isXcodeListWindowsToolCall(_ object: [String: Any]) -> Bool {
        guard JSONRPC.Message.Inspector.method(from: object) == "tools/call",
              let params = object["params"] as? [String: Any],
              params["name"] as? String == "XcodeListWindows" else {
            return false
        }
        return true
    }

    private func toolRoutingRequest(in object: [String: Any]) -> ToolRoutingRequest? {
        guard JSONRPC.Message.Inspector.method(from: object) == "tools/call",
              let params = object["params"] as? [String: Any],
              let toolName = params["name"] as? String else {
            return nil
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        return ToolRoutingRequest(
            id: JSONRPC.Message.Inspector.requestID(from: object),
            toolName: toolName,
            tabIdentifier: arguments["tabIdentifier"] as? String,
            workspacePath: arguments["workspacePath"] as? String
        )
    }

    private func cachedOwnerResolution(for request: ToolRoutingRequest) -> CachedOwnerResolution {
        cachedOwnerResolution(
            tabIdentifier: request.tabIdentifier,
            workspacePath: request.workspacePath
        )
    }

    private func cachedOwnerResolution(
        tabIdentifier: String?,
        workspacePath: String?
    ) -> CachedOwnerResolution {
        let query = WindowOwnerQuery(
            tabIdentifier: tabIdentifier,
            workspacePath: workspacePath
        )
        for _ in 0..<2 {
            let owners = windowOwnershipAuthority.snapshot()
            let routes = processRouteExposure(policy: .ownerRouting)
            switch windowRoutingResolver.resolve(query, owners: owners, routes: routes) {
            case .resolved(let processID, let ownerLabel, let proof):
                guard windowOwnershipAuthority.validate(proof.windowEpoch),
                      processControlPlane.admit(proof.route) != nil else {
                    continue
                }
                return .resolved(
                    processID: processID,
                    ownerLabel: ownerLabel,
                    proof: proof
                )
            case .unresolved:
                return .unresolved
            case .conflict(let message):
                return .conflict(message)
            }
        }
        return .unresolved
    }
    private func resolvedOwnerProcessIDs(
        for requests: [ToolRoutingRequest]
    ) -> (
        resolved: [(
            request: ToolRoutingRequest,
            processID: pid_t,
            ownerLabel: String,
            proof: WindowRouteProof
        )],
        unresolved: [ToolRoutingRequest],
        conflicts: [OwnerResolutionConflict]
    ) {
        var resolved: [(
            request: ToolRoutingRequest,
            processID: pid_t,
            ownerLabel: String,
            proof: WindowRouteProof
        )] = []
        var unresolved: [ToolRoutingRequest] = []
        var conflicts: [OwnerResolutionConflict] = []
        for request in requests {
            switch cachedOwnerResolution(for: request) {
            case .resolved(let processID, let ownerLabel, let proof):
                resolved.append((request, processID, ownerLabel, proof))
            case .unresolved:
                unresolved.append(request)
            case .conflict(let message):
                conflicts.append(OwnerResolutionConflict(request: request, message: message))
            }
        }
        return (resolved, unresolved, conflicts)
    }

    private func cachedOwnerBoundToolNames() -> Set<String> {
        let toolsByName = ProcessToolCatalogCodec.toolsByName(in: cachedToolsListResult())
        return Set(
            toolsByName.compactMap { name, tool in
                ProcessToolCatalogCodec.isOwnerBoundTool(tool) ? name : nil
            }
        )
    }

    private func isKnownOwnerBoundTool(_ toolName: String) -> Bool {
        if processControlPlane.isOwnerBoundTool(toolName) {
            return true
        }
        guard processRoutingEnabled == false else {
            return false
        }
        return cachedOwnerBoundToolNames().contains(toolName)
    }

    private func isOwnerBoundRoutingRequest(_ request: ToolRoutingRequest) -> Bool {
        isKnownOwnerBoundTool(request.toolName) || hasOwnerHint(request)
    }

    private static func windowEntries(in result: JSONValue) -> [XcodeListWindowsEntry] {
        guard xcodeListWindowsIsErrorResult(result) == false else {
            return []
        }
        guard let message = xcodeListWindowsMessage(in: result) else {
            return []
        }
        return XcodeListWindowsMessageParser.parse(message)
    }

    private static func xcodeListWindowsIsErrorResult(_ result: JSONValue) -> Bool {
        guard case .object(let object) = result,
              case .bool(true)? = object["isError"] else {
            return false
        }
        return true
    }

    private static func xcodeListWindowsMessage(in result: JSONValue) -> String? {
        guard case .object(let object) = result else {
            return nil
        }
        if case .object(let structuredContent)? = object["structuredContent"],
           case .string(let message)? = structuredContent["message"],
           message.isEmpty == false
        {
            return message
        }
        guard case .array(let content)? = object["content"] else {
            return nil
        }
        var fallbackText: String?
        for item in content {
            guard case .object(let contentObject) = item,
                  case .string(let text)? = contentObject["text"],
                  text.isEmpty == false else {
                continue
            }
            if let textData = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: textData, options: []) as? [String: Any],
               let message = json["message"] as? String,
               message.isEmpty == false
            {
                return message
            }
            if fallbackText == nil {
                fallbackText = text
            }
        }
        return fallbackText
    }

}
