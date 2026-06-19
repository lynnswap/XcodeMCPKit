import Foundation
import NIOConcurrencyHelpers
import ProxyCore
import ProxyMCP

extension RuntimeCoordinator {
    package struct DefaultUpstreamPlan: Sendable {
        package let upstreams: [ManagedUpstreamSlot]
        package let documentationRoutes: [DocumentationProviderRoute]

        package init(
            upstreams: [ManagedUpstreamSlot],
            documentationRoutes: [DocumentationProviderRoute]
        ) {
            self.upstreams = upstreams
            self.documentationRoutes = documentationRoutes
        }
    }

    static func makeDefaultUpstreams(
        config: ProxyConfig,
        sharedSessionID: String?,
        count: Int
    ) -> [ManagedUpstreamSlot] {
        makeDefaultUpstreamPlan(
            config: config,
            sharedSessionID: sharedSessionID,
            count: count,
            documentationTargets: []
        ).upstreams
    }

    package static func makeDefaultUpstreamPlan(
        config: ProxyConfig,
        sharedSessionID: String?,
        count: Int,
        documentationTargets: [DocumentationProviderTarget]
    ) -> DefaultUpstreamPlan {
        let orderedDocumentationTargets = orderedDocumentationTargets(
            documentationTargets,
            pinnedProcessID: ProcessInfo.processInfo.environment["MCP_XCODE_PID"]
                .flatMap(pid_t.init)
        )
        let canReuseDefaultUpstreamForDocumentation =
            orderedDocumentationTargets.isEmpty == false
            && config.disabledToolNames.contains(DocumentationProvider.ToolCatalog.toolName) == false
            && XcrunArguments.isDefaultMCPBridgeInvocation(config: config)
        let reusableDocumentationTarget: DocumentationProviderTarget?
        if canReuseDefaultUpstreamForDocumentation,
            ProcessInfo.processInfo.environment["MCP_XCODE_PID"].flatMap(pid_t.init) != nil
                || orderedDocumentationTargets.count == 1
        {
            reusableDocumentationTarget = orderedDocumentationTargets.first
        } else {
            reusableDocumentationTarget = nil
        }
        var upstreams: [ManagedUpstreamSlot] = []
        var documentationRoutes: [DocumentationProviderRoute] = []
        let upstreamCount = max(1, count)
        upstreams.reserveCapacity(upstreamCount)
        documentationRoutes.reserveCapacity(reusableDocumentationTarget == nil ? 0 : 1)
        for _ in 0..<upstreamCount {
            let upstreamConfig = makeDefaultUpstreamConfig(
                config: config,
                sharedSessionID: sharedSessionID,
                documentationTarget: nil
            )
            upstreams.append(
                ManagedUpstreamSlot(factory: UpstreamProcess(config: upstreamConfig))
            )
        }
        if let reusableDocumentationTarget {
            documentationRoutes.append(
                DocumentationProviderRoute(
                    id: "upstream-0-pid-\(reusableDocumentationTarget.processID)",
                    target: reusableDocumentationTarget,
                    upstreamIndex: 0
                )
            )
        }
        return DefaultUpstreamPlan(
            upstreams: upstreams,
            documentationRoutes: documentationRoutes
        )
    }

    private static func makeDefaultUpstreamConfig(
        config: ProxyConfig,
        sharedSessionID: String?,
        documentationTarget: DocumentationProviderTarget?
    ) -> UpstreamProcess.Config {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "XCODE_PID")
        if let sharedSessionID, !sharedSessionID.isEmpty {
            environment["MCP_XCODE_SESSION_ID"] = sharedSessionID
        } else {
            environment.removeValue(forKey: "MCP_XCODE_SESSION_ID")
        }
        let command: String
        let args: [String]
        if let documentationTarget {
            environment["MCP_XCODE_PID"] = String(documentationTarget.processID)
            environment["DEVELOPER_DIR"] = documentationTarget.developerDir
            command = documentationTarget.mcpbridgePath
            args = []
        } else {
            command = config.upstreamCommand
            args = config.upstreamArgs
        }
        return UpstreamProcess.Config(
            command: command,
            args: args,
            environment: environment,
            maxQueuedWriteBytes: maxQueuedWriteBytes(for: config)
        )
    }

    private static func maxQueuedWriteBytes(for config: ProxyConfig) -> Int {
        let minimum = 1_048_576
        guard config.maxBodyBytes > 0 else { return minimum }
        let multiplied = config.maxBodyBytes.multipliedReportingOverflow(by: 4)
        if multiplied.overflow {
            return Int.max
        }
        return max(minimum, multiplied.partialValue)
    }

    private static func orderedDocumentationTargets(
        _ targets: [DocumentationProviderTarget],
        pinnedProcessID: pid_t?
    ) -> [DocumentationProviderTarget] {
        let filtered: [DocumentationProviderTarget]
        if let pinnedProcessID {
            filtered = targets.filter { $0.processID == pinnedProcessID }
        } else {
            filtered = targets
        }
        return filtered.sorted { lhs, rhs in
            let versionComparison = compareDocumentationVersion(
                lhs.xcodeVersion,
                rhs.xcodeVersion
            )
            if versionComparison != .orderedSame {
                return versionComparison == .orderedDescending
            }
            if lhs.appPath != rhs.appPath {
                return lhs.appPath < rhs.appPath
            }
            return lhs.processID < rhs.processID
        }
    }

    private static func compareDocumentationVersion(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult {
        let lhsParts = numericDocumentationVersionParts(lhs)
        let rhsParts = numericDocumentationVersionParts(rhs)
        let count = max(lhsParts.count, rhsParts.count)
        for index in 0..<count {
            let lhsValue = index < lhsParts.count ? lhsParts[index] : 0
            let rhsValue = index < rhsParts.count ? rhsParts[index] : 0
            if lhsValue < rhsValue {
                return .orderedAscending
            }
            if lhsValue > rhsValue {
                return .orderedDescending
            }
        }
        return lhs.localizedStandardCompare(rhs)
    }

    private static func numericDocumentationVersionParts(_ version: String) -> [Int] {
        version
            .split { character in
                !character.isNumber
            }
            .compactMap { Int($0) }
    }
}

package final class UpstreamRouter: Sendable {
    private struct RequestLookupKey: Hashable, Sendable {
        let sessionID: String
        let requestIDKey: String
    }

    private struct State: Sendable {
        var nextID: Int64 = 1
        var mappingsByUpstream: [[Int64: UpstreamRouter.Mapping]] = []
        var upstreamIDByRequestKeyByUpstream: [[RequestLookupKey: Int64]] = []
        var recentlyReleasedResponseIDsByUpstream: [[Int64]] = []
    }

    private let state = NIOLockedValueBox(State())
    private let lateResponseMarkerLimit = 512

    init(upstreamCount: Int) {
        state.withLockedValue { state in
            state.mappingsByUpstream = Array(repeating: [:], count: upstreamCount)
            state.upstreamIDByRequestKeyByUpstream = Array(repeating: [:], count: upstreamCount)
            state.recentlyReleasedResponseIDsByUpstream = Array(repeating: [], count: upstreamCount)
        }
    }

    func assign(upstreamIndex: Int, sessionID: String, originalID: JSONRPC.ID, isInitialize: Bool)
        -> Int64
    {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return 0
            }
            let id = state.nextID
            state.nextID += 1
            state.mappingsByUpstream[upstreamIndex][id] = UpstreamRouter.Mapping(
                sessionID: sessionID,
                originalID: originalID,
                isInitialize: isInitialize
            )
            if isInitialize == false {
                let requestKey = Self.requestLookupKey(
                    sessionID: sessionID, requestIDKey: originalID.key)
                state.upstreamIDByRequestKeyByUpstream[upstreamIndex][requestKey] = id
            }
            return id
        }
    }

    func assignInitialize(upstreamIndex: Int) -> Int64 {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return 0
            }
            let id = state.nextID
            state.nextID += 1
            state.mappingsByUpstream[upstreamIndex][id] = UpstreamRouter.Mapping(
                sessionID: nil,
                originalID: nil,
                isInitialize: true
            )
            return id
        }
    }

    func consume(upstreamIndex: Int, upstreamID: Int64) -> UpstreamRouter.Mapping? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return nil
            }
            let mapping = state.mappingsByUpstream[upstreamIndex].removeValue(forKey: upstreamID)
            if let mapping,
                let sessionID = mapping.sessionID,
                let originalID = mapping.originalID
            {
                let requestKey = Self.requestLookupKey(
                    sessionID: sessionID, requestIDKey: originalID.key)
                state.upstreamIDByRequestKeyByUpstream[upstreamIndex].removeValue(
                    forKey: requestKey)
            }
            state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].removeAll { $0 == upstreamID }
            return mapping
        }
    }

    func remove(upstreamIndex: Int, upstreamID: Int64) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else { return }
            let mapping = state.mappingsByUpstream[upstreamIndex].removeValue(forKey: upstreamID)
            if let mapping,
                let sessionID = mapping.sessionID,
                let originalID = mapping.originalID
            {
                let requestKey = Self.requestLookupKey(
                    sessionID: sessionID, requestIDKey: originalID.key)
                state.upstreamIDByRequestKeyByUpstream[upstreamIndex].removeValue(
                    forKey: requestKey)
            }
            if mapping?.isInitialize == false {
                Self.recordReleasedResponseID(
                    upstreamID,
                    upstreamIndex: upstreamIndex,
                    state: &state,
                    limit: lateResponseMarkerLimit
                )
            }
        }
    }

    func remove(
        upstreamIndex: Int,
        sessionID: String,
        requestIDKey: String
    ) -> Int64? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else {
                return nil
            }
            let requestKey = Self.requestLookupKey(sessionID: sessionID, requestIDKey: requestIDKey)
            guard
                let upstreamID = state.upstreamIDByRequestKeyByUpstream[upstreamIndex].removeValue(
                    forKey: requestKey)
            else {
                return nil
            }
            state.mappingsByUpstream[upstreamIndex].removeValue(forKey: upstreamID)
            Self.recordReleasedResponseID(
                upstreamID,
                upstreamIndex: upstreamIndex,
                state: &state,
                limit: lateResponseMarkerLimit
            )
            return upstreamID
        }
    }

    func reset(upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.mappingsByUpstream.count else { return }
            state.mappingsByUpstream[upstreamIndex].removeAll()
            state.upstreamIDByRequestKeyByUpstream[upstreamIndex].removeAll()
            state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].removeAll()
        }
    }

    func resetAll() {
        state.withLockedValue { state in
            for upstreamIndex in state.mappingsByUpstream.indices {
                state.mappingsByUpstream[upstreamIndex].removeAll()
                state.upstreamIDByRequestKeyByUpstream[upstreamIndex].removeAll()
                state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].removeAll()
            }
        }
    }

    func consumeReleasedResponseMarker(upstreamIndex: Int, upstreamID: Int64) -> Bool {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.recentlyReleasedResponseIDsByUpstream.count else {
                return false
            }
            guard let index = state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].firstIndex(of: upstreamID)
            else {
                return false
            }
            state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].remove(at: index)
            return true
        }
    }

    private static func requestLookupKey(sessionID: String, requestIDKey: String)
        -> RequestLookupKey
    {
        RequestLookupKey(sessionID: sessionID, requestIDKey: requestIDKey)
    }

    private static func recordReleasedResponseID(
        _ upstreamID: Int64,
        upstreamIndex: Int,
        state: inout State,
        limit: Int
    ) {
        guard upstreamIndex >= 0, upstreamIndex < state.recentlyReleasedResponseIDsByUpstream.count else {
            return
        }
        state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].append(upstreamID)
        if state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].count > limit {
            state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].removeFirst(
                state.recentlyReleasedResponseIDsByUpstream[upstreamIndex].count - limit
            )
        }
    }
    package struct Mapping: Sendable {
        package let sessionID: String?
        package let originalID: JSONRPC.ID?
        package let isInitialize: Bool
    }
}
