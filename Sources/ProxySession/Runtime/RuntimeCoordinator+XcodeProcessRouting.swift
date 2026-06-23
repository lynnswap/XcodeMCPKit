import Foundation
import Logging
import NIOCore
import ProxyCore
import ProxyMCP
import ProxySessionUpstream

extension RuntimeCoordinator {
    private static let xcodeProcessRouteUnavailableCooldownNanoseconds: UInt64 =
        2_000_000_000

    private struct ToolRoutingRequest: Sendable {
        let id: JSONRPC.ID?
        let toolName: String
        let tabIdentifier: String?
        let workspacePath: String?
    }

    private struct XcodeListWindowsRoute: Sendable {
        let ordinal: Int
        let target: XcodeProcessTarget
        let upstreamIndex: Int
    }

    private enum XcodeListWindowsOutcome: Sendable {
        case success(ordinal: Int, target: XcodeProcessTarget, upstreamIndex: Int, result: JSONValue)
        case failure(target: XcodeProcessTarget, upstreamIndex: Int, error: any Error)
    }

    package func liveXcodeListWindowsAcrossProcessRoutes(
        deadlineUptimeNs: UInt64?
    ) async throws -> JSONValue {
        let unavailable = unavailableXcodeProcessIDs()
        let routes = xcodeProcessRoutes.enumerated().compactMap { ordinal, route -> XcodeListWindowsRoute? in
            guard unavailable.contains(route.target.processID) == false else {
                return nil
            }
            guard let upstreamIndex = firstUsableInitializedUpstreamIndex(in: route) else {
                return nil
            }
            return XcodeListWindowsRoute(
                ordinal: ordinal,
                target: route.target,
                upstreamIndex: upstreamIndex
            )
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
                        let result = try await self.awaitControlPlaneOperation {
                            try await self.controlPlaneCoordinator.listWindows(
                                route: .pinnedUpstream(route.upstreamIndex),
                                deadlineUptimeNs: deadlineUptimeNs
                            )
                        }
                        return .success(
                            ordinal: route.ordinal,
                            target: route.target,
                            upstreamIndex: route.upstreamIndex,
                            result: result
                        )
                    } catch {
                        return .failure(
                            target: route.target,
                            upstreamIndex: route.upstreamIndex,
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
            let orderedResults = orderedRouteResults.map(\.result)
            if let merged = Self.mergedXcodeListWindowsResult(orderedResults) {
                return merged
            }
            if let lastError {
                throw lastError
            }
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
    }

    package func primaryUpstreamIndex(forXcodeProcessID processID: pid_t) -> Int? {
        xcodeProcessRoutes.first { $0.target.processID == processID }?.primaryUpstreamIndex
    }

    package func xcodeProcessRouteHasUsableInitializedUpstream(
        containing upstreamIndex: Int
    ) -> Bool {
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex) else {
            return false
        }
        return firstUsableInitializedUpstreamIndex(in: route) != nil
    }

    package func documentationCandidateProcessIDs() -> Set<pid_t>? {
        documentationCandidateProcessOrder().map(Set.init)
    }

    package func documentationCandidateProcessOrder() -> [pid_t]? {
        guard xcodeProcessRoutes.isEmpty == false else {
            return nil
        }
        let unavailable = unavailableXcodeProcessIDs()
        let workspaceOwnerProcesses = Set(workspaceOwnerProcessIDs.withLockedValue(\.values))
        let tabOwnerProcesses = Set(tabOwnerProcessIDs.withLockedValue(\.values))
        let ownerProcesses = workspaceOwnerProcesses.union(tabOwnerProcesses)
        let ownerProcessIDs = orderedProcessIDs(
            Array(ownerProcesses),
            unavailable: unavailable
        )

        let nonOwnerProcessIDs = orderedProcessIDs(
            xcodeProcessRoutes.compactMap { route -> pid_t? in
                guard unavailable.contains(route.target.processID) == false,
                      ownerProcessIDs.contains(route.target.processID) == false
                else {
                    return nil
                }
                return route.target.processID
            },
            unavailable: unavailable
        )
        let candidateProcessIDs = ownerProcessIDs + nonOwnerProcessIDs
        if candidateProcessIDs.isEmpty == false {
            return candidateProcessIDs
        }
        return []
    }

    private func orderedProcessIDs(
        _ processIDs: [pid_t],
        unavailable: Set<pid_t>
    ) -> [pid_t] {
        var seen = Set<pid_t>()
        return processIDs.compactMap { processID -> pid_t? in
            guard unavailable.contains(processID) == false,
                  seen.insert(processID).inserted else {
                return nil
            }
            return processID
        }
    }

    private func unavailableXcodeProcessIDs() -> Set<pid_t> {
        let now = nowUptimeNanoseconds()
        return unavailableXcodeProcessRoutes.withLockedValue { state in
            state = state.filter { $0.value > now }
            return Set(state.keys)
        }
    }

    package func markXcodeProcessRouteUnavailable(
        upstreamIndex: Int,
        reason: String
    ) {
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex) else {
            return
        }
        let unavailableUntil = nowUptimeNanoseconds()
            &+ Self.xcodeProcessRouteUnavailableCooldownNanoseconds
        unavailableXcodeProcessRoutes.withLockedValue { state in
            state[route.target.processID] = unavailableUntil
        }
        processToolCatalogRegistry.removeCatalog(forProcessID: route.target.processID)
        resyncProcessToolsCatalogSurfaceAfterRemoving(upstreamIndex: upstreamIndex)
        removeXcodeWindowOwners(forUpstreamIndex: upstreamIndex)
        logger.debug(
            "Temporarily ignoring Xcode process route",
            metadata: [
                "pid": .string("\(route.target.processID)"),
                "app_path": .string(route.target.appPath),
                "xcode_version": .string(route.target.xcodeVersion),
                "upstream": .string("\(upstreamIndex)"),
                "reason": .string(reason),
                "unavailable_until_uptime_ns": .string("\(unavailableUntil)"),
            ]
        )
    }

    package func markXcodeProcessRouteAvailable(upstreamIndex: Int) {
        guard let route = xcodeProcessRoute(forUpstreamIndex: upstreamIndex) else {
            return
        }
        _ = unavailableXcodeProcessRoutes.withLockedValue { state in
            state.removeValue(forKey: route.target.processID)
        }
    }

    package func removeXcodeWindowOwners(forUpstreamIndex upstreamIndex: Int) {
        guard let processID = processID(forUpstreamIndex: upstreamIndex) else {
            return
        }
        removeXcodeWindowOwners(forProcessID: processID)
    }

    package func removeXcodeWindowOwners(forProcessID processID: pid_t) {
        tabOwnerProcessIDs.withLockedValue { owners in
            owners = owners.filter { $0.value != processID }
        }
        workspaceOwnerProcessIDs.withLockedValue { owners in
            owners = owners.filter { $0.value != processID }
        }
    }

    package func clearXcodeWindowOwners() {
        tabOwnerProcessIDs.withLockedValue { $0.removeAll() }
        workspaceOwnerProcessIDs.withLockedValue { $0.removeAll() }
    }

    package func documentationUpstreamIndex(for target: XcodeProcessTarget) -> Int? {
        guard let route = xcodeProcessRoutes.first(where: {
            $0.target.processID == target.processID
        }) else {
            return nil
        }
        return firstUsableInitializedUpstreamIndex(in: route)
    }

    package func firstUsableInitializedUpstreamIndex(in route: XcodeProcessRoute) -> Int? {
        usableInitializedUpstreamIndices(in: route).first
    }

    package func usableInitializedUpstreamIndices(in route: XcodeProcessRoute) -> [Int] {
        let states = upstreamHealthManager.statesSnapshot()
        return route.upstreamIndices.filter { upstreamIndex in
            guard upstreamIndex >= 0, upstreamIndex < states.count else {
                return false
            }
            guard states[upstreamIndex].isInitialized else {
                return false
            }
            switch states[upstreamIndex].healthState {
            case .healthy, .degraded:
                return true
            case .quarantined:
                return false
            }
        }
    }

    package func preferredUpstreamIndex(for requestJSON: Any) -> Int? {
        guard xcodeProcessRoutes.isEmpty == false else {
            return nil
        }
        let indices = preferredUpstreamIndices(in: requestJSON)
        guard indices.count == 1 else {
            return nil
        }
        return indices.first
    }

    package func toolRoutingDecision(
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

    package func immediateToolRoutingDecision(for requestJSON: Any) -> ToolRoutingDecision? {
        guard xcodeProcessRoutes.isEmpty == false else {
            return .forward(preferredUpstreamIndex: nil)
        }
        let requests = toolRoutingRequests(in: requestJSON)
        let xcodeListWindowsRequests = requests.filter {
            $0.id != nil && $0.toolName == "XcodeListWindows"
        }
        if xcodeListWindowsRequests.isEmpty == false {
            guard allResponseBearingItemsAreXcodeListWindowsToolCalls(in: requestJSON) else {
                return .reject(
                    errors: toolRoutingErrors(
                        for: requests,
                        message: "XcodeListWindows must be resolved locally before forwarding mixed batches"
                    ),
                    forceBatchArray: requestJSON is [Any]
                )
            }
            return .localXcodeListWindows
        }
        let ownerBoundRequests = requests.filter {
            processToolCatalogRegistry.isOwnerBoundTool($0.toolName)
                || cachedOwnerBoundToolNames().contains($0.toolName)
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
            processToolCatalogRegistry.isOwnerBoundTool($0.toolName)
                || cachedOwnerBoundToolNames().contains($0.toolName)
        }

        var ownerResolution = resolvedOwnerProcessIDs(for: ownerBoundRequests)
        if ownerResolution.unresolved.isEmpty == false {
            _ = try? await liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: requestTimeoutOverride
            )
            ownerResolution = resolvedOwnerProcessIDs(for: ownerBoundRequests)
        }

        if ownerResolution.unresolved.isEmpty == false {
            return .reject(
                errors: toolRoutingErrors(
                    for: requests,
                    message: "unable to resolve Xcode window owner for one or more tools"
                ),
                forceBatchArray: requestJSON is [Any]
            )
        }

        let distinctOwners = Set(ownerResolution.resolved.map(\.processID))
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
        guard let ownerRoute = xcodeProcessRoutes.first(where: {
            $0.target.processID == ownerProcessID
        }) else {
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
            guard processToolCatalogRegistry.catalog(forProcessID: ownerProcessID) != nil,
                  processToolCatalogRegistry.hasTool(
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

        return .forwardAny(preferredUpstreamIndices: ownerUpstreamIndices)
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
            let processIDs = processToolCatalogRegistry.processIDsHavingTool(toolName)
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
    package func recordXcodeWindowOwners(
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
        for processID in processIDs {
            removeXcodeWindowOwners(forProcessID: processID)
        }
        for result in results {
            _ = recordXcodeWindowOwners(
                from: result.result,
                upstreamIndex: result.upstreamIndex,
                removeExistingOwners: false,
                overwriteExistingOwners: false
            )
        }
    }

    @discardableResult
    private func recordXcodeWindowOwners(
        from result: JSONValue,
        upstreamIndex: Int,
        removeExistingOwners: Bool,
        overwriteExistingOwners: Bool
    ) -> Bool {
        guard let processID = processID(forUpstreamIndex: upstreamIndex) else {
            return false
        }
        if removeExistingOwners {
            removeXcodeWindowOwners(forProcessID: processID)
        }
        let entries = Self.windowEntries(in: result)
        guard entries.isEmpty == false else {
            return false
        }
        tabOwnerProcessIDs.withLockedValue { owners in
            for entry in entries {
                if overwriteExistingOwners || owners[entry.tabIdentifier] == nil {
                    owners[entry.tabIdentifier] = processID
                }
            }
        }
        workspaceOwnerProcessIDs.withLockedValue { owners in
            for entry in entries {
                if overwriteExistingOwners || owners[entry.workspacePath] == nil {
                    owners[entry.workspacePath] = processID
                }
            }
        }
        return true
    }

    package static func mergedXcodeListWindowsResult(
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

    package func xcodeProcessRoute(forUpstreamIndex upstreamIndex: Int) -> XcodeProcessRoute? {
        xcodeProcessRoutes.first { $0.upstreamIndices.contains(upstreamIndex) }
    }

    private func processID(forUpstreamIndex upstreamIndex: Int) -> pid_t? {
        xcodeProcessRoute(forUpstreamIndex: upstreamIndex)?.target.processID
    }

    private func preferredUpstreamIndex(in object: [String: Any]) -> Int? {
        guard JSONRPC.Message.Inspector.method(from: object) == "tools/call",
              let params = object["params"] as? [String: Any],
              let arguments = params["arguments"] as? [String: Any] else {
            return nil
        }
        if let tabIdentifier = arguments["tabIdentifier"] as? String,
           tabIdentifier.isEmpty == false,
           let upstreamIndex = upstreamIndexForOwner(tabIdentifier: tabIdentifier)
        {
            return upstreamIndex
        }
        if let workspacePath = arguments["workspacePath"] as? String,
           workspacePath.isEmpty == false,
           let upstreamIndex = upstreamIndexForOwner(workspacePath: workspacePath)
        {
            return upstreamIndex
        }
        return nil
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

    private func allResponseBearingItemsAreXcodeListWindowsToolCalls(in value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return JSONRPC.Message.Inspector.requestID(from: object) != nil
                && isXcodeListWindowsToolCall(object)
        }
        guard let array = value as? [Any],
              array.isEmpty == false else {
            return false
        }
        var sawResponseBearingItem = false
        for item in array {
            guard let object = item as? [String: Any] else {
                return false
            }
            guard JSONRPC.Message.Inspector.requestID(from: object) != nil else {
                continue
            }
            sawResponseBearingItem = true
            guard isXcodeListWindowsToolCall(object) else {
                return false
            }
        }
        return sawResponseBearingItem
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

    private func resolvedOwnerProcessIDs(
        for requests: [ToolRoutingRequest]
    ) -> (
        resolved: [(request: ToolRoutingRequest, processID: pid_t, ownerLabel: String)],
        unresolved: [ToolRoutingRequest]
    ) {
        var resolved: [(request: ToolRoutingRequest, processID: pid_t, ownerLabel: String)] = []
        var unresolved: [ToolRoutingRequest] = []
        for request in requests {
            if let tabIdentifier = request.tabIdentifier,
               tabIdentifier.isEmpty == false,
               let processID = tabOwnerProcessIDs.withLockedValue({ $0[tabIdentifier] }) {
                resolved.append((request, processID, tabIdentifier))
                continue
            }
            if let workspacePath = request.workspacePath,
               workspacePath.isEmpty == false,
               let processID = workspaceOwnerProcessIDs.withLockedValue({ $0[workspacePath] }) {
                resolved.append((request, processID, workspacePath))
                continue
            }
            unresolved.append(request)
        }
        return (resolved, unresolved)
    }

    private func upstreamIndexForOwner(tabIdentifier: String) -> Int? {
        guard let processID = tabOwnerProcessIDs.withLockedValue({ $0[tabIdentifier] }),
              let route = xcodeProcessRoutes.first(where: { $0.target.processID == processID }) else {
            return nil
        }
        return firstUsableInitializedUpstreamIndex(in: route)
    }

    private func upstreamIndexForOwner(workspacePath: String) -> Int? {
        guard let processID = workspaceOwnerProcessIDs.withLockedValue({ $0[workspacePath] }),
              let route = xcodeProcessRoutes.first(where: { $0.target.processID == processID }) else {
            return nil
        }
        return firstUsableInitializedUpstreamIndex(in: route)
    }

    private func cachedOwnerBoundToolNames() -> Set<String> {
        let toolsByName = ProcessToolCatalogRegistry.toolsByName(in: cachedToolsListResult())
        return Set(
            toolsByName.compactMap { name, tool in
                ProcessToolCatalogRegistry.isOwnerBoundTool(tool) ? name : nil
            }
        )
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
