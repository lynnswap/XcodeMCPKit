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

    private enum CachedOwnerResolution: Sendable {
        case resolved(processID: pid_t, ownerLabel: String)
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
            processToolSurfaceStore.processIDsWithCatalog()
            .intersection(usableProcessIDs)
        let catalogProcessIDs =
            processToolSurfaceStore.processIDsHavingTool("XcodeListWindows")
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
        processRouteStore.unavailableProcessIDs(nowUptimeNs: nowUptimeNanoseconds())
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
        scope: ProcessRouteStore.CooldownScope
    ) {
        let nowUptimeNs = nowUptimeNanoseconds()
        let unavailableUntil = nowUptimeNs
            &+ cooldownNanoseconds
        guard let unavailable = processRouteStore.markUnavailable(
            upstreamIndex: upstreamIndex,
            scope: scope,
            nowUptimeNs: nowUptimeNs,
            unavailableUntilUptimeNs: unavailableUntil
        ) else {
            return
        }
        let route = unavailable.route
        processRouteReadinessStore.removePendingCatalogRefresh(processID: route.target.processID)
        cancelScheduledProcessToolsCatalogRetry(processID: route.target.processID)
        if unavailable.didChangeExposure {
            applyToolCatalogSurfaceMutation {
                removeProcessToolCatalogAfterExposureLoss(
                    processID: route.target.processID
                )
            }
        }
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
        _ = processRouteStore.markRouteAvailable(
            upstreamIndex: upstreamIndex,
            nowUptimeNs: nowUptimeNanoseconds()
        )
    }

    func markXcodeProcessRouteCatalogAvailable(upstreamIndex: Int) {
        _ = processRouteStore.markCatalogAvailable(upstreamIndex: upstreamIndex)
    }

    func removeXcodeWindowOwners(forUpstreamIndex upstreamIndex: Int) {
        guard let processID = processID(forUpstreamIndex: upstreamIndex) else {
            return
        }
        removeXcodeWindowOwners(forProcessID: processID)
    }

    func removeXcodeWindowOwners(forProcessID processID: pid_t) {
        let changed = windowOwnerIndex.withLockedValue { index in
            index.remove(processID: processID)
        }
        if changed {
            invalidateControlPlane(
                reason: "xcode_window_owners_updated",
                clearInitialize: false,
                clearToolsCatalog: true
            )
        }
    }

    func clearXcodeWindowOwners() {
        let changed = windowOwnerIndex.withLockedValue { index in
            guard index.isEmpty == false else {
                return false
            }
            index.removeAll()
            return true
        }
        if changed {
            invalidateControlPlane(
                reason: "xcode_window_owners_updated",
                clearInitialize: false,
                clearToolsCatalog: true
            )
        }
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
        policy: ProcessRouteStore.ExposureSnapshot.Policy
    ) -> ProcessRouteStore.ExposureSnapshot {
        let nowUptimeNs = nowUptimeNanoseconds()
        let upstreamUsability = processRouteUpstreamUsabilitySnapshot(
            policy: policy,
            nowUptimeNs: nowUptimeNs
        )
        return processRouteStore.exposure(
            policy: policy,
            upstreamUsability: upstreamUsability,
            nowUptimeNs: nowUptimeNs
        )
    }

    func processRouteUpstreamUsabilitySnapshot(
        policy: ProcessRouteStore.ExposureSnapshot.Policy,
        nowUptimeNs: UInt64
    ) -> ProcessRouteStore.UpstreamUsabilitySnapshot {
        let states = upstreamHealthManager.statesSnapshot()
        let snapshotUsable = Set(states.indices.filter { upstreamIndex in
            guard states[upstreamIndex].isInitialized else {
                return false
            }
            switch states[upstreamIndex].healthState {
            case .healthy, .degraded:
                return true
            case .quarantined:
                return false
            }
        })

        var recoveryAwareUsable = snapshotUsable
        switch policy {
        case .toolsCatalog:
            var effects: [UpstreamHealthManager.Effect] = []
            recoveryAwareUsable = Set(states.indices.filter { upstreamIndex in
                let evaluation = upstreamHealthManager.evaluateUsableInitialized(
                    index: upstreamIndex,
                    nowUptimeNs: nowUptimeNs
                )
                effects.append(contentsOf: evaluation.effects)
                return evaluation.isUsable
            })
            applyHealthEffects(effects)
        case .ownerRouting, .windowDiscovery, .initialization:
            break
        }

        return ProcessRouteStore.UpstreamUsabilitySnapshot(
            snapshotUsableUpstreamIndices: snapshotUsable,
            recoveryAwareUsableUpstreamIndices: recoveryAwareUsable
        )
    }

    func preferredUpstreamIndex(for requestJSON: Any) -> Int? {
        guard processRoutingEnabled,
              let object = requestJSON as? [String: Any] else {
            return nil
        }
        return preferredUpstreamIndex(in: object)
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
        guard let object = requestJSON as? [String: Any],
              let request = toolRoutingRequest(in: object) else {
            return .forward(preferredUpstreamIndex: nil)
        }
        if request.id != nil, request.toolName == "XcodeListWindows" {
            return .localXcodeListWindows
        }
        guard isOwnerBoundRoutingRequest(request) else {
            if let catalogDecision = catalogToolRoutingDecision(
                for: request
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

        let ownerProcessID: pid_t
        switch ownerResolution {
        case .resolved(let processID, _):
            ownerProcessID = processID
        case .conflict(let message):
            return .reject(
                errors: toolRoutingErrors(for: request, message: message)
            )
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

        guard let ownerRoute = xcodeProcessRoutes.first(where: {
            $0.target.processID == ownerProcessID
        }) else {
            return .reject(
                errors: toolRoutingErrors(
                    for: request,
                    message: "Xcode process that owns the tool is no longer available"
                )
            )
        }
        let ownerUpstreamIndices = usableInitializedUpstreamIndices(in: ownerRoute)

        if processToolSurfaceStore.catalog(forProcessID: ownerProcessID) != nil,
           processToolSurfaceStore.hasTool(
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

        return .forwardAny(preferredUpstreamIndices: ownerUpstreamIndices)
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
        if usableRoutes.count == 1 {
            return usableRoutes[0].target.processID
        }

        let usableProcessIDs = Set(usableRoutes.map(\.target.processID))
        let usableCandidates = processToolSurfaceStore
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
        hasOwnerHint(
            tabIdentifier: request.tabIdentifier,
            workspacePath: request.workspacePath
        )
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
        let candidateProcessIDs = processToolSurfaceStore.processIDsHavingTool(request.toolName)
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
        return .forwardAny(
            preferredUpstreamIndices: usableInitializedUpstreamIndices(in: route)
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
        let changed = windowOwnerIndex.withLockedValue { index in
            let before = index
            for processID in processIDs {
                index.remove(processID: processID)
            }
            for entry in entriesByProcessID {
                index.record(processID: entry.processID, entries: entry.entries)
            }
            return index != before
        }
        if changed {
            invalidateControlPlane(
                reason: "xcode_window_owners_updated",
                clearInitialize: false,
                clearToolsCatalog: true
            )
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
        let changed = windowOwnerIndex.withLockedValue { index in
            let before = index
            if removeExistingOwners {
                index.remove(processID: processID)
            }
            index.record(processID: processID, entries: entries)
            return index != before
        }
        if changed {
            invalidateControlPlane(
                reason: "xcode_window_owners_updated",
                clearInitialize: false,
                clearToolsCatalog: true
            )
        }
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
        let message = windowOwnerIndex.withLockedValue { index in
            entries.map { entry in
                let proxyTabIdentifier = index.proxyTabIdentifier(
                    processID: processID,
                    rawTabIdentifier: entry.tabIdentifier,
                    workspacePath: entry.workspacePath
                )
                return "* tabIdentifier: \(proxyTabIdentifier), workspacePath: \(entry.workspacePath)"
            }
            .joined(separator: "\n")
        }
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
        processRouteStore.route(forUpstreamIndex: upstreamIndex)
    }

    func isActiveProcessBoundUpstream(_ upstreamIndex: Int) -> Bool {
        guard processRoutingEnabled else { return true }
        return xcodeProcessRoute(forUpstreamIndex: upstreamIndex) != nil
    }

    func activeProcessBoundUpstreamIndices() -> Set<Int> {
        guard processRoutingEnabled else {
            return Set(upstreams.indices)
        }
        return Set(xcodeProcessRoutes.flatMap(\.upstreamIndices))
    }

    func routableProcessBoundUpstreamIndices() -> Set<Int> {
        guard processRoutingEnabled else {
            return Set(upstreams.indices)
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
        return Set(upstreams.indices).subtracting(routableProcessBoundUpstreamIndices())
    }

    func secondaryUpstreamIndices(excluding upstreamIndex: Int) -> [Int] {
        let candidates = processRoutingEnabled
            ? xcodeProcessRoutes.flatMap(\.upstreamIndices)
            : Array(upstreams.indices)
        return candidates.filter { $0 != upstreamIndex }
    }

    func activeInitializedHealthyishCount() -> Int {
        guard processRoutingEnabled else {
            return upstreamHealthManager.initializedHealthyishCount()
        }
        let states = upstreamHealthManager.statesSnapshot()
        return routableProcessBoundUpstreamIndices().reduce(into: 0) { count, upstreamIndex in
            guard upstreamIndex >= 0, upstreamIndex < states.count else { return }
            let upstream = states[upstreamIndex]
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
        let states = upstreamHealthManager.statesSnapshot()
        return routableProcessBoundUpstreamIndices().contains { upstreamIndex in
            guard upstreamIndex >= 0, upstreamIndex < states.count else { return false }
            return states[upstreamIndex].isInitialized
        }
    }

    func anyActiveRecoveryInFlight() -> Bool {
        guard processRoutingEnabled else {
            return upstreamHealthManager.anyRecoveryInFlight()
        }
        let states = upstreamHealthManager.statesSnapshot()
        return routableProcessBoundUpstreamIndices().contains { upstreamIndex in
            guard upstreamIndex >= 0, upstreamIndex < states.count else { return false }
            let upstream = states[upstreamIndex]
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
        guard let object = parsedRequestJSON as? [String: Any] else {
            return (bodyData, parsedRequestJSON)
        }
        let rewritten = rewriteOwnerBoundRequestObject(object, processID: processID)
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
                  processToolSurfaceStore.tool(
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
        windowOwnerIndex.withLockedValue { index in
            guard let identity = index.identity(forProxyTabIdentifier: tabIdentifier),
                  identity.processID == processID else {
                return nil
            }
            return identity.rawTabIdentifier
        }
    }

    private func singleRawTabIdentifier(
        workspacePath: String,
        processID: pid_t
    ) -> String? {
        windowOwnerIndex.withLockedValue { index in
            let identities = index.identities(
                workspacePath: workspacePath,
                processID: processID
            )
            guard identities.count == 1 else {
                return nil
            }
            return identities[0].rawTabIdentifier
        }
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
              case .resolved(let processID, _) = cachedOwnerResolution(
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
        let eligibleProcessIDs = ownerRoutingEligibleProcessIDs()
        return windowOwnerIndex.withLockedValue { index in
            let nonEmptyWorkspacePath = workspacePath.flatMap { $0.isEmpty ? nil : $0 }
            let nonEmptyTabIdentifier = tabIdentifier.flatMap { $0.isEmpty ? nil : $0 }

            func proxyTabResolution(
                tabIdentifier: String,
                workspacePath: String?
            ) -> CachedOwnerResolution? {
                guard tabIdentifier.hasPrefix(WindowOwnerIndex.proxyTabIdentifierPrefix) else {
                    return nil
                }
                guard let identity = index.identity(forProxyTabIdentifier: tabIdentifier) else {
                    return .conflict(
                        "stale or unknown XcodeMCPKit tabIdentifier '\(tabIdentifier)'"
                    )
                }
                guard eligibleProcessIDs.contains(identity.processID) else {
                    return .conflict(
                        "stale or unavailable XcodeMCPKit tabIdentifier '\(tabIdentifier)'"
                    )
                }
                if let workspacePath, identity.workspacePath != workspacePath {
                    return .conflict(
                        "tabIdentifier '\(tabIdentifier)' does not belong to workspacePath"
                            + " '\(workspacePath)'"
                    )
                }
                return .resolved(
                    processID: identity.processID,
                    ownerLabel: identity.proxyTabIdentifier
                )
            }

            if let workspacePath = nonEmptyWorkspacePath {
                if let tabIdentifier = nonEmptyTabIdentifier,
                   let resolution = proxyTabResolution(
                       tabIdentifier: tabIdentifier,
                       workspacePath: workspacePath
                   ) {
                    return resolution
                }

                switch index.owner(
                    forWorkspacePath: workspacePath,
                    eligibleProcessIDs: eligibleProcessIDs
                ) {
                case .resolved(let processID):
                    if let tabIdentifier = nonEmptyTabIdentifier,
                       let conflict = tabConflictMessage(
                           tabIdentifier: tabIdentifier,
                           workspacePath: workspacePath,
                           ownerProcessID: processID,
                           index: index,
                           eligibleProcessIDs: eligibleProcessIDs
                       ) {
                        return CachedOwnerResolution.conflict(conflict)
                    }
                    return .resolved(processID: processID, ownerLabel: workspacePath)
                case .conflicting(let processIDs):
                    let candidates = processIDs.map(String.init).sorted().joined(separator: ",")
                    return .conflict(
                        "conflicting Xcode window owners for workspacePath '\(workspacePath)'"
                            + " (processes: \(candidates))"
                    )
                case .unresolved:
                    if let tabIdentifier = nonEmptyTabIdentifier {
                        if index.identity(forProxyTabIdentifier: tabIdentifier) != nil {
                            return .conflict(
                                "tabIdentifier '\(tabIdentifier)' does not belong to workspacePath '\(workspacePath)'"
                            )
                        }
                        if tabIdentifier.hasPrefix(WindowOwnerIndex.proxyTabIdentifierPrefix) {
                            return .conflict(
                                "stale or unknown XcodeMCPKit tabIdentifier '\(tabIdentifier)'"
                            )
                        }
                    }
                    return .unresolved
                }
            }

            guard let tabIdentifier = nonEmptyTabIdentifier else {
                return .unresolved
            }
            if let resolution = proxyTabResolution(
                tabIdentifier: tabIdentifier,
                workspacePath: nil
            ) {
                return resolution
            }

            let rawIdentities = index.identities(
                forRawTabIdentifier: tabIdentifier,
                eligibleProcessIDs: eligibleProcessIDs
            )
            switch rawIdentities.count {
            case 0:
                return .unresolved
            case 1:
                return .resolved(processID: rawIdentities[0].processID, ownerLabel: tabIdentifier)
            default:
                let processIDs = Set(rawIdentities.map(\.processID))
                let candidates = processIDs.map(String.init).sorted().joined(separator: ",")
                return .conflict(
                    "ambiguous raw Xcode tabIdentifier '\(tabIdentifier)'"
                        + " (processes: \(candidates))"
                )
            }
        }
    }

    private func ownerRoutingEligibleProcessIDs() -> Set<pid_t> {
        processRouteExposure(policy: .ownerRouting).processIDs
    }

    private func tabConflictMessage(
        tabIdentifier: String,
        workspacePath: String,
        ownerProcessID: pid_t,
        index: WindowOwnerIndex,
        eligibleProcessIDs: Set<pid_t>
    ) -> String? {
        if let identity = index.identity(forProxyTabIdentifier: tabIdentifier) {
            guard identity.processID == ownerProcessID,
                  identity.workspacePath == workspacePath else {
                return "tabIdentifier '\(tabIdentifier)' does not belong to workspacePath '\(workspacePath)'"
            }
            return nil
        }
        if tabIdentifier.hasPrefix(WindowOwnerIndex.proxyTabIdentifierPrefix) {
            return "stale or unknown XcodeMCPKit tabIdentifier '\(tabIdentifier)'"
        }
        let rawIdentities = index.identities(
            forRawTabIdentifier: tabIdentifier,
            eligibleProcessIDs: eligibleProcessIDs
        )
        guard rawIdentities.isEmpty == false else {
            return nil
        }
        let matchesWorkspaceOwner = rawIdentities.contains {
            $0.processID == ownerProcessID && $0.workspacePath == workspacePath
        }
        return matchesWorkspaceOwner
            ? nil
            : "tabIdentifier '\(tabIdentifier)' does not belong to workspacePath '\(workspacePath)'"
    }

    private func cachedOwnerBoundToolNames() -> Set<String> {
        let toolsByName = ProcessToolSurfaceStore.toolsByName(in: cachedToolsListResult())
        return Set(
            toolsByName.compactMap { name, tool in
                ProcessToolSurfaceStore.isOwnerBoundTool(tool) ? name : nil
            }
        )
    }

    private func isKnownOwnerBoundTool(_ toolName: String) -> Bool {
        if processToolSurfaceStore.isOwnerBoundTool(toolName) {
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
