import Foundation
import Logging
import NIOCore
import XcodeMCPCore

extension RuntimeCoordinator {
    struct ProcessRouteUsabilityEvaluation: Sendable {
        let snapshot: ProcessControlPlaneAuthority.UpstreamUsabilitySnapshot
        let effects: [UpstreamHealthManager.Effect]
    }

    private static let xcodeProcessRouteUnavailableCooldownNanoseconds: UInt64 =
        2_000_000_000
    private static let xcodeProcessRouteCatalogUnavailableCooldownNanoseconds: UInt64 =
        30_000_000_000

    private struct ToolRoutingRequest: Sendable {
        let id: JSONRPC.ID?
        let toolName: String
        let tabIdentifier: String?
        let workspaceIdentifier: String?

        var workspacePath: String? {
            workspaceIdentifier.flatMap { $0.hasPrefix("/") ? $0 : nil }
        }
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

    private enum CachedOwnerResolution: Sendable {
        case resolved(processID: pid_t, ownerLabel: String, proof: WindowRouteProof)
        case unresolved
        case conflict(String)
    }

    func liveXcodeListWindowsAcrossProcessRoutes(
        deadlineUptimeNs: UInt64?,
        routeScope: XcodeListWindowsRouteScope,
        requiresCompleteInventory: Bool = false
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

            if requiresCompleteInventory {
                if let lastError { throw lastError }
                if !xcodeWindowOwnerCandidateProcessIDs().isSubset(of: queriedProcessIDs) {
                    throw UpstreamSlotScheduler.AcquisitionError.unavailable
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
        scheduleXcodeProcessCooldownExpiration(
            lease: unavailable.cooldownLease,
            delayNanoseconds: cooldownNanoseconds
        )
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
        _ = processRouteExposure(policy: .toolsCatalog)
    }

    func markXcodeProcessRouteCatalogAvailable(upstreamIndex: Int) {
        applyProcessControlPlaneTransition(processControlPlane.markAvailable(
            upstreamIndex: upstreamIndex,
            scope: .catalog,
            nowUptimeNs: nowUptimeNanoseconds()
        ))
    }

    private func scheduleXcodeProcessCooldownExpiration(
        lease: ProcessControlPlaneAuthority.CooldownLease,
        delayNanoseconds: UInt64
    ) {
        let timeout = scheduleRuntimeTimeout(
            .nanoseconds(Int64(clamping: delayNanoseconds))
        ) { [weak self] in
            self?.handleXcodeProcessCooldownExpiration(lease: lease)
        }
        applyProcessControlPlaneTransition(
            processControlPlane.attachCooldownTimeout(timeout, to: lease)
        )
    }

    private func handleXcodeProcessCooldownExpiration(
        lease: ProcessControlPlaneAuthority.CooldownLease
    ) {
        let nowUptimeNs = nowUptimeNanoseconds()
        if nowUptimeNs < lease.deadlineUptimeNs {
            let timeout = scheduleRuntimeTimeout(
                .nanoseconds(Int64(clamping: lease.deadlineUptimeNs - nowUptimeNs))
            ) { [weak self] in
                self?.handleXcodeProcessCooldownExpiration(lease: lease)
            }
            applyProcessControlPlaneTransition(
                processControlPlane.attachCooldownTimeout(timeout, to: lease)
            )
            return
        }
        guard let transition = processControlPlane.expireCooldown(
            lease,
            nowUptimeNs: nowUptimeNs
        ) else { return }
        applyProcessControlPlaneTransition(transition)
        retryPendingProcessRouteReadiness(reason: "cooldown_expired")
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
        let upstreamUsability = evaluateProcessRouteUpstreamUsability(
            policy: policy,
            nowUptimeNs: nowUptimeNs
        )
        let transition = processControlPlane.updateUsability(
            upstreamUsability.snapshot,
            nowUptimeNs: nowUptimeNs
        )
        applyProcessControlPlaneTransition(transition)
        applyHealthEffects(upstreamUsability.effects)
        return processControlPlane.routingSnapshot(policy: policy, nowUptimeNs: nowUptimeNs)
    }

    func evaluateProcessRouteUpstreamUsability(
        policy: ProcessControlPlaneAuthority.ExposurePolicy,
        nowUptimeNs: UInt64
    ) -> ProcessRouteUsabilityEvaluation {
        let states = upstreamHealthManager.activeStatesSnapshot()
        let snapshotUsable = Set(states.compactMap { upstreamID, state -> Int? in
            guard state.initPhase.isUsableInitialized else {
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
        var effects: [UpstreamHealthManager.Effect] = []
        switch policy {
        case .toolsCatalog:
            recoveryAwareUsable = Set(states.compactMap { upstreamID, _ -> Int? in
                let evaluation = upstreamHealthManager.evaluateUsableInitialized(
                    index: upstreamID.rawValue,
                    nowUptimeNs: nowUptimeNs
                )
                effects.append(contentsOf: evaluation.effects)
                return evaluation.isUsable ? upstreamID.rawValue : nil
            })
        case .ownerRouting, .windowDiscovery, .initialization:
            break
        }

        return ProcessRouteUsabilityEvaluation(
            snapshot: ProcessControlPlaneAuthority.UpstreamUsabilitySnapshot(
                snapshotUsableUpstreamIDs: Set(
                    snapshotUsable.map(UpstreamSlotID.init(rawValue:))
                ),
                recoveryAwareUsableUpstreamIDs: Set(
                    recoveryAwareUsable.map(UpstreamSlotID.init(rawValue:))
                )
            ),
            effects: effects
        )
    }

    func preferredUpstreamIndex(for requestJSON: Any) -> Int? {
        guard let object = requestJSON as? [String: Any] else {
            return nil
        }
        return preferredUpstreamIndex(in: object)
    }

    func toolRoutingDecision(
        for requestJSON: Any,
        requestTimeoutOverride: TimeAmount?
    ) async -> ToolRoutingDecision {
        guard let object = requestJSON as? [String: Any],
              let request = toolRoutingRequest(in: object) else {
            return .forward(preferredUpstreamIndex: nil)
        }
        if let affinityDecision = deviceInteractionAffinityRoutingDecision(
            for: object,
            request: request
        ) {
            if case .forwardAdmitted(_, let admission) = affinityDecision,
               admission.route == nil,
               let path = request.workspacePath,
               let proof = admission.upstreamProofs.first {
                return await existingNativeWorkspacePathRoutingDecision(
                    for: request, path: path, route: .pinnedUpstream(proof.slotID.rawValue),
                    expectedUpstreamProof: proof,
                    deadline: timeoutDeadline(for: requestTimeoutOverride
                        ?? MCP.MethodDispatcher.timeoutForMethod("tools/call", defaultSeconds: config.requestTimeout))
                )
            }
            return affinityDecision
        }
        if let identifier = request.workspaceIdentifier, request.workspacePath == nil, !identifier.isEmpty {
            guard request.tabIdentifier == nil else {
                return .reject(errors: toolRoutingErrors(
                    for: request, message: "Specify either a native workspaceIdentifier or a GUI tabIdentifier"
                ))
            }
            return await workspaceIdentifierRoutingDecision(
                for: object, request: request, identifier: identifier,
                requestTimeoutOverride: requestTimeoutOverride)
        }
        if let path = request.workspacePath {
            return await workspacePathRoutingDecision(
                for: requestJSON, request: request, path: path,
                requestTimeoutOverride: requestTimeoutOverride
            )
        }

        if request.id != nil, request.toolName == "XcodeListWindows" {
            return .localXcodeListWindows
        }
        if !hasOwnerHint(request), !defaultBackendUpstreamIndices.isEmpty {
            let catalog = processControlPlane.unboundToolsCatalogRaw()
            let hasNativeTool = ProcessToolCatalogCodec.toolsByName(in: catalog)[request.toolName] != nil
            let hasGUIProvider = !processControlPlane.processIDsHavingTool(request.toolName).isEmpty
            if hasNativeTool && (!isKnownOwnerBoundTool(request.toolName) || !hasGUIProvider)
                || (catalog == nil && !hasGUIProvider) {
                return nativeHostToolRoutingDecision(for: request)
            }
        }
        guard isOwnerBoundRoutingRequest(request) else {
            if let catalogDecision = catalogToolRoutingDecision(
                for: request
            ) {
                return catalogDecision
            }
            return .forward(preferredUpstreamIndex: preferredUpstreamIndex(for: requestJSON))
        }
        return await ownerBoundToolRoutingDecision(
            for: requestJSON, requestTimeoutOverride: requestTimeoutOverride
        )
    }

    private func nativeHostToolRoutingDecision(
        for request: ToolRoutingRequest, workspaceIdentifier: String? = nil
    ) -> ToolRoutingDecision {
        let topology = upstreamTopology.snapshot()
        let proofs = topology.entries.compactMap {
            $0.backend == .nativeHost ? topology.proof($0.id) : nil
        }
        guard !proofs.isEmpty else {
            return .reject(errors: toolRoutingErrors(for: request, message: "The owned native host is not available"))
        }
        return .forwardAdmitted(
            preferredUpstreamIndices: proofs.map { $0.slotID.rawValue },
            admission: RouteForwardingAdmission(
                upstreamProofs: proofs, workspaceIdentifier: workspaceIdentifier,
                toolDefinition: proofs.first.flatMap { toolDefinition(named: request.toolName, sourceProof: $0) }
            ))
    }

    private func workspaceIdentifierRoutingDecision(
        for object: [String: Any], request: ToolRoutingRequest, identifier: String,
        requestTimeoutOverride: TimeAmount?
    ) async -> ToolRoutingDecision {
        let knownGUIIdentifier = windowOwnershipAuthority.snapshot().identities.contains {
            $0.proxyTabIdentifier == identifier || $0.rawTabIdentifier == identifier
        }
        var nativeInventoryFailure: String?
        if !knownGUIIdentifier {
        do {
            let inventory = try await nativeWorkspaceInventory(
                route: .nativeHost,
                deadline: timeoutDeadline(for: requestTimeoutOverride
                    ?? MCP.MethodDispatcher.timeoutForMethod("tools/call", defaultSeconds: config.requestTimeout))
            )
            if inventory.entries.contains(where: { $0.tabIdentifier == identifier }) {
                return .forwardAdmitted(
                    preferredUpstreamIndices: [inventory.sourceProof.slotID.rawValue],
                    admission: RouteForwardingAdmission(
                        upstreamProofs: [inventory.sourceProof], workspaceIdentifier: identifier,
                        toolDefinition: toolDefinition(named: request.toolName, sourceProof: inventory.sourceProof)
                    )
                )
            }
        } catch {
            nativeInventoryFailure = ControlPlane.ErrorMapper.jsonRPCError(for: error).message
        }
        }
        var resolution = cachedOwnerResolution(tabIdentifier: identifier, workspacePath: nil)
        let candidates = xcodeWindowOwnerCandidateProcessIDs()
        let hasUnqueriedOwners = !candidates.isSubset(of: windowOwnershipAuthority.snapshot().inventoriedProcessIDs)
        let unresolved = if case .unresolved = resolution { true } else { false }
        if !candidates.isEmpty, unresolved || hasUnqueriedOwners {
            do {
                _ = try await refreshXcodeWindowOwnersForRouting(
                    requestTimeoutOverride: requestTimeoutOverride, requiresCompleteInventory: true)
            } catch {
                return .reject(errors: toolRoutingErrors(
                    for: request, message: "Unable to determine GUI workspace ownership: "
                        + ControlPlane.ErrorMapper.jsonRPCError(for: error).message))
            }
            resolution = cachedOwnerResolution(tabIdentifier: identifier, workspacePath: nil)
        }
        switch resolution {
        case .unresolved:
            return .reject(errors: toolRoutingErrors(
                for: request,
                message: nativeInventoryFailure.map { "Unable to determine native workspace ownership: \($0)" }
                    ?? "Unknown workspaceIdentifier '\(identifier)'; select an identifier from the workspace inventory"
            ))
        case .resolved, .conflict:
            var object = object
            var params = object["params"] as? [String: Any] ?? [:]
            var arguments = params["arguments"] as? [String: Any] ?? [:]
            arguments.removeValue(forKey: "workspaceIdentifier")
            arguments["tabIdentifier"] = identifier
            params["arguments"] = arguments
            object["params"] = params
            return await ownerBoundToolRoutingDecision(
                for: object, requestTimeoutOverride: requestTimeoutOverride)
        }
    }

    private struct NativeWorkspaceInventory {
        let sourceProof: UpstreamTopologyProof
        let entries: [XcodeListWindowsEntry]
    }

    private func nativeWorkspaceInventory(
        route: ControlPlane.Route,
        expectedUpstreamProof: UpstreamTopologyProof? = nil,
        deadline: UInt64?
    ) async throws -> NativeWorkspaceInventory {
        try Task.checkCancellation()
        if let deadline, nowUptimeNanoseconds() >= deadline { throw TimeoutError() }
        if route == .nativeHost {
            let nativeIsInitialized = upstreamTopology.snapshot().entries.contains { entry in
                entry.backend == .nativeHost
                    && upstreamHealthManager.state(for: entry.id)?.initPhase.isUsableInitialized == true
            }
            guard nativeIsInitialized else {
                throw ControlPlane.Error.proxyFailure(code: -32001, message: "The owned native host is not available")
            }
        }
        let response = try await performControlPlaneRPC(
            route: route, purpose: "workspaces", label: "tools/call:XcodeListWorkspaces",
            requestObject: JSONRPC.Wire.requestObject(
                id: "__control-plane-workspaces-\(UUID().uuidString)", method: "tools/call",
                params: .object(["name": .string("XcodeListWorkspaces"), "arguments": .object([:])])
            ),
            requestTimeout: timeAmount(until: deadline), expectedUpstreamProof: expectedUpstreamProof
        )
        let result = try extractJSONRPCResult(from: response.responseData)
        guard !Self.xcodeListWindowsIsErrorResult(result),
              let message = Self.xcodeListWindowsMessage(in: result) else {
            throw ControlPlane.Error.proxyFailure(
                code: -32001,
                message: Self.xcodeListWindowsMessage(in: result) ?? "Unable to list native workspaces"
            )
        }
        return NativeWorkspaceInventory(
            sourceProof: response.operationLease.proof,
            entries: XcodeListWindowsMessageParser.parse(message, identifierKey: "workspaceIdentifier")
        )
    }

    private func workspacePathRoutingDecision(
        for requestJSON: Any,
        request: ToolRoutingRequest,
        path: String,
        requestTimeoutOverride: TimeAmount?
    ) async -> ToolRoutingDecision {
        var resolution = cachedOwnerResolution(for: request)
        let potentialOwnerProcessIDs = xcodeWindowOwnerCandidateProcessIDs()
        let hasUnqueriedOwners = !potentialOwnerProcessIDs.isSubset(of: windowOwnershipAuthority.snapshot().inventoriedProcessIDs)
        let needsDiscovery = switch resolution {
        case .unresolved: true
        default: hasUnqueriedOwners && request.tabIdentifier == nil
        }
        if needsDiscovery, !potentialOwnerProcessIDs.isEmpty {
            do {
                _ = try await refreshXcodeWindowOwnersForRouting(
                    requestTimeoutOverride: requestTimeoutOverride,
                    requiresCompleteInventory: true
                )
            } catch {
                return .reject(errors: toolRoutingErrors(
                    for: request,
                    message: "Unable to determine GUI workspace ownership: "
                        + ControlPlane.ErrorMapper.jsonRPCError(for: error).message
                ))
            }
            resolution = cachedOwnerResolution(for: request)
        }
        switch resolution {
        case .resolved, .conflict:
            return await ownerBoundToolRoutingDecision(
                for: requestJSON, requestTimeoutOverride: requestTimeoutOverride
            )
        case .unresolved:
            if request.tabIdentifier != nil {
                return .reject(errors: toolRoutingErrors(for: request, message: "Unable to resolve the selected Xcode tab"))
            }
        }
        return nativeHostToolRoutingDecision(for: request, workspaceIdentifier: path)

    }

    private func xcodeWindowOwnerCandidateProcessIDs() -> Set<pid_t> {
        Set(xcodeProcessRoutes.compactMap { route -> pid_t? in
            let processID = route.target.processID
            return processControlPlane.catalog(forProcessID: processID) == nil
                || processControlPlane.hasTool("XcodeListWindows", processID: processID) ? processID : nil
        })
    }

    private func existingNativeWorkspacePathRoutingDecision(
        for request: ToolRoutingRequest,
        path: String,
        route: ControlPlane.Route,
        expectedUpstreamProof: UpstreamTopologyProof? = nil,
        deadline: UInt64?
    ) async -> ToolRoutingDecision {
        do {
            let inventory = try await nativeWorkspaceInventory(
                route: route, expectedUpstreamProof: expectedUpstreamProof, deadline: deadline
            )
            let identifiers = Set(inventory.entries
                .filter { workspacePathsMatch($0.workspacePath, path) }.map(\.tabIdentifier))
            guard identifiers.count == 1, let identifier = identifiers.first else {
                return .reject(errors: toolRoutingErrors(
                    for: request,
                    message: identifiers.isEmpty
                        ? "Workspace '\(path)' is no longer open in its native owner."
                        : "Multiple native workspaces match '\(path)'; select a workspaceIdentifier from XcodeListWorkspaces"
                ))
            }
            return .forwardAdmitted(
                preferredUpstreamIndices: [inventory.sourceProof.slotID.rawValue],
                admission: RouteForwardingAdmission(
                    upstreamProofs: [inventory.sourceProof], workspaceIdentifier: identifier,
                    toolDefinition: toolDefinition(named: request.toolName, sourceProof: inventory.sourceProof)
                )
            )
        } catch {
            return .reject(errors: toolRoutingErrors(
                for: request,
                message: "Unable to resolve native workspace: " + ControlPlane.ErrorMapper.jsonRPCError(for: error).message
            ))
        }
    }

    func recordDeviceInteractionAffinityIfNeeded(
        requestData: Data,
        responseData: Data,
        operationLease: UpstreamOperationLease
    ) {
        guard let call = DeviceInteractionToolCall.decode(requestData: requestData) else {
            return
        }

        switch call {
        case .startsSession:
            guard let key = DeviceInteractionToolCall.successfulSessionKey(
                from: responseData
            ) else {
                return
            }
            let routeID: ProcessRouteID?
            if !defaultBackendUpstreamIndices.contains(operationLease.upstreamIndex) {
                guard let route = xcodeProcessRoute(
                    forUpstreamIndex: operationLease.upstreamIndex
                ),
                    let routeProof = processControlPlane.routeProof(routeID: route.id)
                else {
                    return
                }
                routeID = routeProof.routeID
            } else {
                routeID = nil
            }
            upstreamTopologyCommitLock.withLock {
                guard upstreamTopology.validate(operationLease) else { return }
                deviceInteractionAffinityAuthority.record(
                    .init(
                        upstreamProof: operationLease.proof,
                        routeID: routeID
                    ),
                    for: key
                )
            }
        case .continuesSession(let key, let endsSession):
            guard endsSession,
                  DeviceInteractionToolCall.isSuccessfulResponse(responseData) else {
                return
            }
            deviceInteractionAffinityAuthority.remove(key: key)
        }
    }

    private func deviceInteractionAffinityRoutingDecision(
        for requestObject: [String: Any],
        request: ToolRoutingRequest
    ) -> ToolRoutingDecision? {
        guard case .continuesSession(let key, _) = DeviceInteractionToolCall.decode(
            requestObject
        ) else {
            return nil
        }
        guard let affinity = deviceInteractionAffinityAuthority.affinity(for: key) else {
            if upstreamTopology.snapshot().entries.count == 1
            {
                return nil
            }
            return .reject(
                errors: deviceInteractionRoutingErrors(
                    id: request.id,
                    message: "unknown device interaction session"
                )
            )
        }
        guard upstreamTopology.validate(affinity.upstreamProof) else {
            deviceInteractionAffinityAuthority.remove(key: key)
            return .reject(
                errors: deviceInteractionRoutingErrors(
                    id: request.id,
                    message: "device interaction session is no longer available"
                )
            )
        }
        guard let affinityRouteID = affinity.routeID else {
            guard defaultBackendUpstreamIndices.contains(affinity.upstreamProof.slotID.rawValue) else {
                deviceInteractionAffinityAuthority.remove(key: key)
                return .reject(
                    errors: deviceInteractionRoutingErrors(
                        id: request.id,
                        message: "device interaction session is no longer available"
                    )
                )
            }
            return .forwardAdmitted(
                preferredUpstreamIndices: [affinity.upstreamProof.slotID.rawValue],
                admission: RouteForwardingAdmission(
                    upstreamProofs: [affinity.upstreamProof]
                )
            )
        }
        guard let routeProof = processControlPlane.routeProof(routeID: affinityRouteID),
              let routeAdmission = processControlPlane.admit(routeProof) else {
            deviceInteractionAffinityAuthority.remove(key: key)
            return .reject(
                errors: deviceInteractionRoutingErrors(
                    id: request.id,
                    message: "device interaction session is no longer available"
                )
            )
        }
        let windowAdmission: WindowRouteAdmission?
        if hasOwnerHint(request) {
            let owners = windowOwnershipAuthority.snapshot()
            guard case .resolved(let processID, _, let windowProof) = cachedOwnerResolution(
                for: request
            ),
                  processID == affinityRouteID.processID,
                  windowProof.route.routeID == affinityRouteID,
                  windowProof.windowEpoch == owners.epoch else {
                return .reject(
                    errors: deviceInteractionRoutingErrors(
                        id: request.id,
                        message: "device interaction session does not own the selected Xcode window"
                    )
                )
            }
            windowAdmission = WindowRouteAdmission(
                proof: windowProof,
                route: routeAdmission,
                rewritePlan: ownerBoundRequestRewritePlan(
                    processID: processID,
                    request: request,
                    owners: owners
                )
            )
        } else {
            windowAdmission = nil
        }
        return .forwardAdmitted(
            preferredUpstreamIndices: [affinity.upstreamProof.slotID.rawValue],
            admission: RouteForwardingAdmission(
                route: routeAdmission,
                upstreamProofs: [affinity.upstreamProof],
                window: windowAdmission
            )
        )
    }

    private func deviceInteractionRoutingErrors(
        id: JSONRPC.ID?,
        message: String
    ) -> [ToolRoutingError] {
        id.map { [ToolRoutingError(id: $0, message: message)] } ?? []
    }

    private func ownerBoundToolRoutingDecision(
        for requestJSON: Any,
        requestTimeoutOverride: TimeAmount?
    ) async -> ToolRoutingDecision {
        guard let object = requestJSON as? [String: Any],
              let request = toolRoutingRequest(in: object) else {
            return .forward(preferredUpstreamIndex: nil)
        }

        var ownerResolution = cachedOwnerResolution(for: request)
        var inferredOwnerProcessID =
            inferredUnambiguousOwnerProcessID(
                for: request,
                ownerResolution: ownerResolution
            )
        let needsOwnerRefresh =
            if case .conflict = ownerResolution {
                true
            } else if case .unresolved = ownerResolution {
                inferredOwnerProcessID == nil
            } else {
                false
            }
        if needsOwnerRefresh {
            _ = try? await refreshXcodeWindowOwnersForRouting(
                requestTimeoutOverride: requestTimeoutOverride
            )
            ownerResolution = cachedOwnerResolution(for: request)
            inferredOwnerProcessID =
                inferredUnambiguousOwnerProcessID(
                    for: request,
                    ownerResolution: ownerResolution
                )
        }

        testHooks.ownerRouteProofsResolved?()
        if case .resolved(_, _, let proof) = ownerResolution,
           (windowOwnershipAuthority.validate(proof.windowEpoch) == false
            || processControlPlane.admit(proof.route) == nil) {
            ownerResolution = cachedOwnerResolution(for: request)
            inferredOwnerProcessID = inferredUnambiguousOwnerProcessID(
                for: request,
                ownerResolution: ownerResolution
            )
        }

        let ownerProcessID: pid_t
        switch ownerResolution {
        case .resolved(let processID, _, _):
            ownerProcessID = processID
        case .conflict(let message):
            return .reject(errors: toolRoutingErrors(for: request, message: message))
        case .unresolved:
            guard let inferredOwnerProcessID else {
                return .reject(
                    errors: toolRoutingErrors(
                        for: request,
                        message: "unable to resolve Xcode window owner for tool"
                    )
                )
            }
            ownerProcessID = inferredOwnerProcessID
        }
        guard let ownerRoute = processControlPlane.route(forProcessID: ownerProcessID) else {
            return .reject(
                errors: toolRoutingErrors(
                    for: request,
                    message: "Xcode process that owns the tool is no longer available"
                )
            )
        }
        let owners = windowOwnershipAuthority.snapshot()
        let windowProof: WindowRouteProof
        if case .resolved(let resolvedProcessID, _, let resolvedProof) = ownerResolution {
            guard resolvedProcessID == ownerProcessID,
                  resolvedProof.route.routeID == ownerRoute.id,
                  resolvedProof.windowEpoch == owners.epoch else {
                return .reject(
                    errors: toolRoutingErrors(
                        for: request,
                        message: "Xcode window ownership changed while routing the request"
                    )
                )
            }
            windowProof = resolvedProof
        } else {
            guard let routeProof = processControlPlane.routeProof(routeID: ownerRoute.id) else {
                return .reject(
                    errors: toolRoutingErrors(
                        for: request,
                        message: "Xcode process route changed while routing the request"
                    )
                )
            }
            windowProof = WindowRouteProof(windowEpoch: owners.epoch, route: routeProof)
        }
        guard windowOwnershipAuthority.validate(windowProof.windowEpoch),
              let routeAdmission = processControlPlane.admit(windowProof.route) else {
            return .reject(
                errors: toolRoutingErrors(
                    for: request,
                    message: "Xcode window ownership changed while routing the request"
                )
            )
        }
        let rewritePlan = ownerBoundRequestRewritePlan(
            processID: ownerProcessID,
            request: request,
            owners: owners
        )
        let ownerUpstreamIndices = usableInitializedUpstreamIndices(in: ownerRoute)

        if processControlPlane.catalog(forProcessID: ownerProcessID) != nil,
           processControlPlane.hasTool(
            request.toolName,
            processID: ownerProcessID
           ) == false {
            return .reject(
                errors: toolRoutingErrors(
                    for: request,
                    message: "tool is not available in the selected Xcode process"
                )
            )
        }

        guard ownerUpstreamIndices.isEmpty == false else {
            return .reject(
                errors: toolRoutingErrors(
                    for: request,
                    message: "no available upstream for the Xcode process that owns the tool"
                )
            )
        }

        let topology = upstreamTopology.snapshot()
        let upstreamProofs = ownerUpstreamIndices.compactMap { topology.proof(
            UpstreamSlotID(rawValue: $0)
        ) }
        guard upstreamProofs.count == ownerUpstreamIndices.count else {
            return .reject(
                errors: toolRoutingErrors(
                    for: request,
                    message: "Xcode upstream topology changed while routing the request"
                )
            )
        }
        return .forwardAdmitted(
            preferredUpstreamIndices: ownerUpstreamIndices,
            admission: RouteForwardingAdmission(
                route: routeAdmission,
                upstreamProofs: upstreamProofs,
                window: WindowRouteAdmission(
                    proof: windowProof,
                    route: routeAdmission,
                    rewritePlan: rewritePlan
                ),
                toolDefinition: upstreamProofs.first.flatMap {
                    toolDefinition(named: request.toolName, sourceProof: $0)
                }
            )
        )
    }

    private func ownerBoundRequestRewritePlan(
        processID: pid_t,
        request: ToolRoutingRequest,
        owners: WindowOwnershipSnapshot
    ) -> OwnerBoundRequestRewritePlan {
        let identities = owners.identities.filter { $0.processID == processID }
        let identity: WindowOwnershipIdentity?
        if let identifier = request.tabIdentifier ?? (request.workspacePath == nil ? request.workspaceIdentifier : nil),
           !identifier.isEmpty {
            identity = identities.first { $0.proxyTabIdentifier == identifier || $0.rawTabIdentifier == identifier }
        } else if let path = request.workspacePath {
            identity = identities.first { workspacePathsMatch($0.workspacePath, path) }
        } else {
            identity = nil
        }
        return OwnerBoundRequestRewritePlan(
            tabIdentifier: identity?.rawTabIdentifier ?? request.tabIdentifier,
            clientTabIdentifier: identity?.proxyTabIdentifier ?? request.tabIdentifier
        )
    }

    private func refreshXcodeWindowOwnersForRouting(
        requestTimeoutOverride: TimeAmount?,
        requiresCompleteInventory: Bool = false
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
            routeScope: .ownerDiscovery,
            requiresCompleteInventory: requiresCompleteInventory
        )
    }

    private func inferredUnambiguousOwnerProcessID(
        for request: ToolRoutingRequest,
        ownerResolution: CachedOwnerResolution
    ) -> pid_t? {
        guard case .unresolved = ownerResolution,
              hasNoOwnerHint(request) else {
            return nil
        }
        let usableRoutes = xcodeProcessRoutes.filter {
            usableInitializedUpstreamIndices(in: $0).isEmpty == false
                && unavailableXcodeProcessIDs().contains($0.target.processID) == false
        }
        let usableProcessIDs = Set(usableRoutes.map(\.target.processID))
        let usableCandidates = processControlPlane
            .processIDsHavingTool(request.toolName)
            .intersection(usableProcessIDs)
        guard usableCandidates.count == 1 else {
            return nil
        }
        return usableCandidates.first
    }

    private func hasNoOwnerHint(_ request: ToolRoutingRequest) -> Bool {
        !hasOwnerHint(request)
    }

    private func hasOwnerHint(_ request: ToolRoutingRequest) -> Bool {
        request.tabIdentifier?.isEmpty == false || request.workspaceIdentifier?.isEmpty == false
    }

    private func hasOwnerHint(tabIdentifier: String?, workspacePath: String?) -> Bool {
        tabIdentifier?.isEmpty == false || workspacePath?.isEmpty == false
    }

    private func toolRoutingErrors(
        for request: ToolRoutingRequest,
        message: String
    ) -> [ToolRoutingError] {
        guard let id = request.id else { return [] }
        return [ToolRoutingError(id: id, message: message)]
    }

    private func catalogToolRoutingDecision(
        for request: ToolRoutingRequest
    ) -> ToolRoutingDecision? {
        let candidateProcessIDs = processControlPlane.processIDsHavingTool(request.toolName)
        guard candidateProcessIDs.isEmpty == false else {
            return nil
        }
        guard let route = preferredAvailableRoute(in: candidateProcessIDs) else {
            return .reject(
                errors: toolRoutingErrors(
                    for: request,
                    message: "no available upstream for an Xcode process that provides tool '\(request.toolName)'"
                )
            )
        }
        let upstreamIndices = usableInitializedUpstreamIndices(in: route)
        let topology = upstreamTopology.snapshot()
        guard let routeProof = processControlPlane.routeProof(routeID: route.id),
              let routeAdmission = processControlPlane.admit(routeProof) else {
            return .reject(
                errors: toolRoutingErrors(
                    for: request,
                    message: "Xcode process route changed while routing the request"
                )
            )
        }
        let upstreamProofs = upstreamIndices.compactMap {
            topology.proof(UpstreamSlotID(rawValue: $0))
        }
        guard upstreamProofs.count == upstreamIndices.count else {
            return .reject(
                errors: toolRoutingErrors(
                    for: request,
                    message: "Xcode upstream topology changed while routing the request"
                )
            )
        }
        return .forwardAdmitted(
            preferredUpstreamIndices: upstreamIndices,
            admission: RouteForwardingAdmission(
                route: routeAdmission,
                upstreamProofs: upstreamProofs,
                toolDefinition: upstreamProofs.first.flatMap {
                    toolDefinition(named: request.toolName, sourceProof: $0)
                }
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

    func xcodeProcessRoute(forUpstreamIndex upstreamIndex: Int) -> XcodeProcessRoute? {
        processControlPlane.route(forUpstreamIndex: upstreamIndex)
    }

    func isActiveProcessBoundUpstream(_ upstreamIndex: Int) -> Bool {
        return defaultBackendUpstreamIndices.contains(upstreamIndex) || xcodeProcessRoute(forUpstreamIndex: upstreamIndex) != nil
    }

    func activeProcessBoundUpstreamIndices() -> Set<Int> {
        return defaultBackendUpstreamIndices.union(xcodeProcessRoutes.flatMap(\.upstreamIndices))
    }

    func routableProcessBoundUpstreamIndices() -> Set<Int> {
        let unavailable = unavailableXcodeProcessIDs()
        return defaultBackendUpstreamIndices.union(
            xcodeProcessRoutes
                .filter { unavailable.contains($0.target.processID) == false }
                .flatMap(\.upstreamIndices)
        )
    }

    func inactiveProcessBoundUpstreamIndices() -> Set<Int> {
        return Set(upstreamSlotIDs.map(\.rawValue)).subtracting(
            routableProcessBoundUpstreamIndices()
        )
    }

    func secondaryUpstreamIndices(excluding upstreamIndex: Int) -> [Int] {
        let candidates = activeProcessBoundUpstreamIndices().sorted()
        return candidates.filter { $0 != upstreamIndex }
    }

    func activeInitializedHealthyishCount() -> Int {
        return routableProcessBoundUpstreamIndices().reduce(into: 0) { count, upstreamIndex in
            guard let upstream = upstreamHealthManager.state(
                for: UpstreamSlotID(rawValue: upstreamIndex)
            ) else { return }
            guard upstream.initPhase.isUsableInitialized else { return }
            switch upstream.healthState {
            case .healthy, .degraded:
                count += 1
            case .quarantined:
                break
            }
        }
    }

    func anyActiveInitializedUpstream() -> Bool {
        return routableProcessBoundUpstreamIndices().contains { upstreamIndex in
            upstreamHealthManager.state(
                for: UpstreamSlotID(rawValue: upstreamIndex)
            )?.initPhase.isUsableInitialized == true
        }
    }

    func anyActiveRecoveryInFlight() -> Bool {
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
        operationLease: UpstreamOperationLease,
        admission: RouteForwardingAdmission?
    ) -> (bodyData: Data, parsedRequestJSON: Any) {
        guard upstreamTopology.validate(operationLease),
              let object = parsedRequestJSON as? [String: Any] else {
            return (bodyData, parsedRequestJSON)
        }
        if let identifier = admission?.workspaceIdentifier,
           var params = object["params"] as? [String: Any],
           var arguments = params["arguments"] as? [String: Any] {
            arguments["workspaceIdentifier"] = identifier
            params["arguments"] = arguments
            var rewritten = object
            rewritten["params"] = params
            if let data = try? JSONSerialization.data(withJSONObject: rewritten) {
                return (data, rewritten)
            }
        }
        guard let rewritePlan = admission?.window?.rewritePlan else { return (bodyData, parsedRequestJSON) }
        let rewritten = rewriteOwnerBoundRequestObject(object, plan: rewritePlan)
        guard rewritten.changed,
              JSONSerialization.isValidJSONObject(rewritten.value),
              let data = try? JSONSerialization.data(
                withJSONObject: rewritten.value,
                options: []
              ) else {
            return (bodyData, parsedRequestJSON)
        }
        return (data, rewritten.value)
    }

    private func rewriteOwnerBoundRequestObject(
        _ object: [String: Any],
        plan: OwnerBoundRequestRewritePlan
    ) -> (value: [String: Any], changed: Bool) {
        guard JSONRPC.Message.Inspector.method(from: object) == "tools/call",
              var params = object["params"] as? [String: Any],
              params["name"] is String,
              var arguments = params["arguments"] as? [String: Any] else {
            return (object, false)
        }

        guard let rawTabIdentifier = plan.tabIdentifier else { return (object, false) }
        arguments.removeValue(forKey: "workspaceIdentifier")
        arguments["tabIdentifier"] = rawTabIdentifier
        params["arguments"] = arguments
        var rewritten = object
        rewritten["params"] = params
        return (rewritten, true)
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
        let workspacePath = (arguments["workspaceIdentifier"] as? String).flatMap {
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
            tabIdentifier: (arguments["tabIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            workspaceIdentifier: arguments["workspaceIdentifier"] as? String
        )
    }

    private func cachedOwnerResolution(for request: ToolRoutingRequest) -> CachedOwnerResolution {
        cachedOwnerResolution(
            tabIdentifier: request.tabIdentifier ?? (request.workspacePath == nil ? request.workspaceIdentifier : nil),
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
