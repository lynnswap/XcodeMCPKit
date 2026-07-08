import Foundation
import NIOConcurrencyHelpers
import XcodeMCPKit

final class ProcessRouteStore: Sendable {
    struct ReconcileResult: Sendable {
        let addedRoutes: [XcodeProcessRoute]
        let retiredRoutes: [XcodeProcessRoute]
        let activeRoutes: [XcodeProcessRoute]

        var didChange: Bool {
            addedRoutes.isEmpty == false || retiredRoutes.isEmpty == false
        }
    }

    private enum RouteState: String, Sendable {
        case active
        case retired
    }

    enum CooldownScope: Sendable {
        case route
        case catalog
    }

    struct ExposureSnapshot: Sendable {
        enum Policy: Sendable {
            case toolsCatalog
            case ownerRouting
            case windowDiscovery
            case initialization
        }

        let epoch: UInt64
        let policy: Policy
        let routes: [RouteExposure]
        let processIDs: Set<pid_t>
    }

    struct RouteExposure: Sendable {
        let ordinal: Int
        let route: XcodeProcessRoute
        let usableUpstreamIndices: [Int]
    }

    struct UpstreamUsabilitySnapshot: Sendable {
        let snapshotUsableUpstreamIndices: Set<Int>
        let recoveryAwareUsableUpstreamIndices: Set<Int>
    }

    private struct InstanceKey: Hashable, Sendable {
        let processID: pid_t
        let appPath: String
        let developerDir: String
        let mcpbridgePath: String
        let xcodeVersion: String

        init(target: XcodeProcessTarget) {
            self.processID = target.processID
            self.appPath = target.appPath
            self.developerDir = target.developerDir
            self.mcpbridgePath = target.mcpbridgePath
            self.xcodeVersion = target.xcodeVersion
        }
    }

    private struct Record: Sendable {
        let key: InstanceKey
        var route: XcodeProcessRoute
        var state: RouteState
        var firstSeenGeneration: UInt64
        var lastSeenGeneration: UInt64
        var lastSeenUptimeNs: UInt64?
        var missingSinceUptimeNs: UInt64?
        var lastReconcileReason: String
        var routeUnavailableUntilUptimeNs: UInt64?
        var catalogUnavailableUntilUptimeNs: UInt64?

        var unavailableUntilUptimeNs: UInt64 {
            max(routeUnavailableUntilUptimeNs ?? 0, catalogUnavailableUntilUptimeNs ?? 0)
        }

        @discardableResult
        mutating func pruneExpiredUnavailable(nowUptimeNs: UInt64) -> Bool {
            var didChange = false
            if let routeUnavailableUntilUptimeNs,
               routeUnavailableUntilUptimeNs <= nowUptimeNs {
                self.routeUnavailableUntilUptimeNs = nil
                didChange = true
            }
            if let catalogUnavailableUntilUptimeNs,
               catalogUnavailableUntilUptimeNs <= nowUptimeNs {
                self.catalogUnavailableUntilUptimeNs = nil
                didChange = true
            }
            return didChange
        }

        func isUnavailable(nowUptimeNs: UInt64) -> Bool {
            unavailableUntilUptimeNs > nowUptimeNs
        }
    }

    private struct State: Sendable {
        var recordsByKey: [InstanceKey: Record] = [:]
        var order: [InstanceKey] = []
        var generation: UInt64 = 0
    }

    private let state = NIOLockedValueBox(State())

    init(
        initialRoutes: [XcodeProcessRoute] = [],
        nowUptimeNs: UInt64 = 0,
        reason: String = "startup"
    ) {
        guard initialRoutes.isEmpty == false else { return }
        state.withLockedValue { state in
            for initialRoute in initialRoutes {
                let key = InstanceKey(target: initialRoute.target)
                guard state.recordsByKey[key] == nil else { continue }
                state.generation &+= 1
                let route = XcodeProcessRoute(
                    id: ProcessRouteID(
                        processID: initialRoute.target.processID,
                        instanceGeneration: state.generation
                    ),
                    target: initialRoute.target,
                    upstreamIndices: initialRoute.upstreamIndices
                )
                let record = Record(
                    key: key,
                    route: route,
                    state: .active,
                    firstSeenGeneration: state.generation,
                    lastSeenGeneration: state.generation,
                    lastSeenUptimeNs: nowUptimeNs,
                    missingSinceUptimeNs: nil,
                    lastReconcileReason: reason,
                    routeUnavailableUntilUptimeNs: nil,
                    catalogUnavailableUntilUptimeNs: nil
                )
                state.recordsByKey[key] = record
                state.order.append(key)
            }
        }
    }

    func activeRoutes() -> [XcodeProcessRoute] {
        state.withLockedValue { state in
            state.order.compactMap { key in
                guard let record = state.recordsByKey[key], record.state == .active else {
                    return nil
                }
                return record.route
            }
        }
    }

    func currentEpoch() -> UInt64 {
        state.withLockedValue(\.generation)
    }

    func containsActiveRoute(id routeID: ProcessRouteID) -> Bool {
        state.withLockedValue { state in
            state.recordsByKey.values.contains { record in
                record.state == .active && record.route.id == routeID
            }
        }
    }

    func resetExposureState() {
        state.withLockedValue { state in
            state.generation &+= 1
            for key in state.order {
                guard var record = state.recordsByKey[key] else {
                    continue
                }
                record.routeUnavailableUntilUptimeNs = nil
                record.catalogUnavailableUntilUptimeNs = nil
                record.lastSeenGeneration = state.generation
                state.recordsByKey[key] = record
            }
        }
    }

    func reconcile(
        targets: [XcodeProcessTarget],
        reason: String,
        nowUptimeNs: UInt64,
        makeRoute: (XcodeProcessTarget) -> XcodeProcessRoute
    ) -> ReconcileResult {
        let orderedTargets = MCPBridgeRuntime.orderedXcodeTargets(targets)
        return state.withLockedValue { state in
            var addedRoutes: [XcodeProcessRoute] = []
            var retiredRoutes: [XcodeProcessRoute] = []
            let orderedKeys = orderedTargets.map(InstanceKey.init(target:))
            let liveKeys = Set(orderedKeys)

            for target in orderedTargets {
                let key = InstanceKey(target: target)
                if var record = state.recordsByKey[key], record.state == .active {
                    record.route = XcodeProcessRoute(
                        id: record.route.id,
                        target: target,
                        upstreamIndices: record.route.upstreamIndices
                    )
                    record.lastSeenUptimeNs = nowUptimeNs
                    record.missingSinceUptimeNs = nil
                    record.lastReconcileReason = reason
                    state.recordsByKey[key] = record
                    continue
                }

                state.generation &+= 1
                let madeRoute = makeRoute(target)
                let route = XcodeProcessRoute(
                    id: ProcessRouteID(
                        processID: target.processID,
                        instanceGeneration: state.generation
                    ),
                    target: target,
                    upstreamIndices: madeRoute.upstreamIndices
                )
                let record = Record(
                    key: key,
                    route: route,
                    state: .active,
                    firstSeenGeneration: state.generation,
                    lastSeenGeneration: state.generation,
                    lastSeenUptimeNs: nowUptimeNs,
                    missingSinceUptimeNs: nil,
                    lastReconcileReason: reason,
                    routeUnavailableUntilUptimeNs: nil,
                    catalogUnavailableUntilUptimeNs: nil
                )
                state.recordsByKey[key] = record
                if state.order.contains(key) == false {
                    state.order.append(key)
                }
                addedRoutes.append(route)
            }

            for key in state.order {
                guard liveKeys.contains(key) == false,
                      var record = state.recordsByKey[key],
                      record.state == .active else {
                    continue
                }
                state.generation &+= 1
                record.state = .retired
                record.lastSeenGeneration = state.generation
                record.missingSinceUptimeNs = nowUptimeNs
                record.lastReconcileReason = reason
                state.recordsByKey[key] = record
                retiredRoutes.append(record.route)
            }

            reorderActiveKeys(orderedKeys, in: &state)
            let activeRoutes: [XcodeProcessRoute] = state.order.compactMap { key in
                guard let record = state.recordsByKey[key], record.state == .active else {
                    return nil
                }
                return record.route
            }
            return ReconcileResult(
                addedRoutes: addedRoutes,
                retiredRoutes: retiredRoutes,
                activeRoutes: activeRoutes
            )
        }
    }

    private func reorderActiveKeys(_ orderedKeys: [InstanceKey], in state: inout State) {
        var activeKeys: [InstanceKey] = []
        var activeKeySet = Set<InstanceKey>()
        for key in orderedKeys {
            guard let record = state.recordsByKey[key],
                  record.state == .active,
                  activeKeySet.insert(key).inserted else {
                continue
            }
            activeKeys.append(key)
        }
        let historicalKeys = state.order.filter { activeKeySet.contains($0) == false }
        state.order = activeKeys + historicalKeys
    }

    func route(forUpstreamIndex upstreamIndex: Int) -> XcodeProcessRoute? {
        state.withLockedValue { state in
            state.order.compactMap { key -> XcodeProcessRoute? in
                guard let record = state.recordsByKey[key],
                      record.state == .active,
                      record.route.upstreamIndices.contains(upstreamIndex) else {
                    return nil
                }
                return record.route
            }.first
        }
    }

    func unavailableProcessIDs(nowUptimeNs: UInt64) -> Set<pid_t> {
        state.withLockedValue { state in
            var unavailable: Set<pid_t> = []
            for key in state.order {
                guard var record = state.recordsByKey[key],
                      record.state == .active else {
                    continue
                }
                if record.pruneExpiredUnavailable(nowUptimeNs: nowUptimeNs) {
                    state.generation &+= 1
                    record.lastSeenGeneration = state.generation
                }
                if record.isUnavailable(nowUptimeNs: nowUptimeNs) {
                    unavailable.insert(record.route.target.processID)
                }
                state.recordsByKey[key] = record
            }
            return unavailable
        }
    }

    @discardableResult
    func markUnavailable(
        upstreamIndex: Int,
        scope: CooldownScope,
        unavailableUntilUptimeNs: UInt64
    ) -> XcodeProcessRoute? {
        state.withLockedValue { state in
            for key in state.order {
                guard var record = state.recordsByKey[key],
                      record.state == .active,
                      record.route.upstreamIndices.contains(upstreamIndex) else {
                    continue
                }
                switch scope {
                case .route:
                    let previousUnavailableUntilUptimeNs = record.routeUnavailableUntilUptimeNs
                    record.routeUnavailableUntilUptimeNs = max(
                        record.routeUnavailableUntilUptimeNs ?? 0,
                        unavailableUntilUptimeNs
                    )
                    guard previousUnavailableUntilUptimeNs != record.routeUnavailableUntilUptimeNs
                    else {
                        return record.route
                    }
                case .catalog:
                    let previousUnavailableUntilUptimeNs = record.catalogUnavailableUntilUptimeNs
                    record.catalogUnavailableUntilUptimeNs = max(
                        record.catalogUnavailableUntilUptimeNs ?? 0,
                        unavailableUntilUptimeNs
                    )
                    guard previousUnavailableUntilUptimeNs != record.catalogUnavailableUntilUptimeNs
                    else {
                        return record.route
                    }
                }
                state.generation &+= 1
                record.lastSeenGeneration = state.generation
                state.recordsByKey[key] = record
                return record.route
            }
            return nil
        }
    }

    @discardableResult
    func markRouteAvailable(upstreamIndex: Int, nowUptimeNs: UInt64) -> XcodeProcessRoute? {
        state.withLockedValue { state in
            for key in state.order {
                guard var record = state.recordsByKey[key],
                      record.state == .active,
                      record.route.upstreamIndices.contains(upstreamIndex) else {
                    continue
                }
                let previousRouteUnavailableUntilUptimeNs = record.routeUnavailableUntilUptimeNs
                let previousCatalogUnavailableUntilUptimeNs = record.catalogUnavailableUntilUptimeNs
                record.routeUnavailableUntilUptimeNs = nil
                record.pruneExpiredUnavailable(nowUptimeNs: nowUptimeNs)
                if previousRouteUnavailableUntilUptimeNs != record.routeUnavailableUntilUptimeNs
                    || previousCatalogUnavailableUntilUptimeNs != record.catalogUnavailableUntilUptimeNs {
                    state.generation &+= 1
                    record.lastSeenGeneration = state.generation
                }
                state.recordsByKey[key] = record
                return record.route
            }
            return nil
        }
    }

    @discardableResult
    func markCatalogAvailable(upstreamIndex: Int) -> XcodeProcessRoute? {
        state.withLockedValue { state in
            for key in state.order {
                guard var record = state.recordsByKey[key],
                      record.state == .active,
                      record.route.upstreamIndices.contains(upstreamIndex) else {
                    continue
                }
                let previousRouteUnavailableUntilUptimeNs = record.routeUnavailableUntilUptimeNs
                let previousCatalogUnavailableUntilUptimeNs = record.catalogUnavailableUntilUptimeNs
                record.routeUnavailableUntilUptimeNs = nil
                record.catalogUnavailableUntilUptimeNs = nil
                if previousRouteUnavailableUntilUptimeNs != nil
                    || previousCatalogUnavailableUntilUptimeNs != nil {
                    state.generation &+= 1
                    record.lastSeenGeneration = state.generation
                }
                state.recordsByKey[key] = record
                return record.route
            }
            return nil
        }
    }

    func removeUnavailableState(processID: pid_t) {
        state.withLockedValue { state in
            for key in state.order {
                guard var record = state.recordsByKey[key],
                      record.route.target.processID == processID else {
                    continue
                }
                if record.routeUnavailableUntilUptimeNs != nil
                    || record.catalogUnavailableUntilUptimeNs != nil {
                    record.routeUnavailableUntilUptimeNs = nil
                    record.catalogUnavailableUntilUptimeNs = nil
                    state.generation &+= 1
                    record.lastSeenGeneration = state.generation
                    state.recordsByKey[key] = record
                }
            }
        }
    }

    func containsExposedRoute(
        id routeID: ProcessRouteID,
        policy: ExposureSnapshot.Policy,
        upstreamUsability: UpstreamUsabilitySnapshot,
        nowUptimeNs: UInt64
    ) -> Bool {
        exposure(
            policy: policy,
            upstreamUsability: upstreamUsability,
            nowUptimeNs: nowUptimeNs
        )
        .routes
        .contains { $0.route.id == routeID }
    }

    func exposure(
        policy: ExposureSnapshot.Policy,
        upstreamUsability: UpstreamUsabilitySnapshot,
        nowUptimeNs: UInt64
    ) -> ExposureSnapshot {
        state.withLockedValue { state in
            var exposures: [RouteExposure] = []
            let usableUpstreamIndicesForPolicy: Set<Int>
            switch policy {
            case .toolsCatalog:
                usableUpstreamIndicesForPolicy =
                    upstreamUsability.recoveryAwareUsableUpstreamIndices
            case .ownerRouting, .windowDiscovery, .initialization:
                usableUpstreamIndicesForPolicy =
                    upstreamUsability.snapshotUsableUpstreamIndices
            }
            var activeOrdinal = 0
            for key in state.order {
                guard var record = state.recordsByKey[key],
                      record.state == .active else {
                    continue
                }
                let ordinal = activeOrdinal
                activeOrdinal += 1
                if record.pruneExpiredUnavailable(nowUptimeNs: nowUptimeNs) {
                    state.generation &+= 1
                    record.lastSeenGeneration = state.generation
                }
                state.recordsByKey[key] = record
                guard record.isUnavailable(nowUptimeNs: nowUptimeNs) == false else {
                    continue
                }
                let usableUpstreamIndices = record.route.upstreamIndices.filter { upstreamIndex in
                    usableUpstreamIndicesForPolicy.contains(upstreamIndex)
                }
                guard usableUpstreamIndices.isEmpty == false else {
                    continue
                }
                exposures.append(
                    RouteExposure(
                        ordinal: ordinal,
                        route: record.route,
                        usableUpstreamIndices: usableUpstreamIndices
                    )
                )
            }
            return ExposureSnapshot(
                epoch: state.generation,
                policy: policy,
                routes: exposures,
                processIDs: Set(exposures.map(\.route.target.processID))
            )
        }
    }

    func debugSnapshots(
        usableSlotCount: @Sendable (XcodeProcessRoute) -> Int,
        toolsCatalogState: @Sendable (XcodeProcessRoute, String) -> String
    ) -> [ProxyDebug.ProcessRouteSnapshot] {
        let records = state.withLockedValue { state in
            state.order.compactMap { key in
                state.recordsByKey[key]
            }
        }
        return records.map { record in
            let routeState = record.state.rawValue
            return ProxyDebug.ProcessRouteSnapshot(
                state: routeState,
                processID: record.route.target.processID,
                appPath: record.route.target.appPath,
                developerDir: record.route.target.developerDir,
                mcpbridgePath: record.route.target.mcpbridgePath,
                xcodeVersion: record.route.target.xcodeVersion,
                upstreamIndices: record.route.upstreamIndices,
                usableSlotCount: usableSlotCount(record.route),
                toolsCatalogState: toolsCatalogState(record.route, routeState),
                firstSeenGeneration: record.firstSeenGeneration,
                lastSeenGeneration: record.lastSeenGeneration,
                lastSeenUptimeNs: record.lastSeenUptimeNs,
                missingSinceUptimeNs: record.missingSinceUptimeNs,
                lastReconcileReason: record.lastReconcileReason
            )
        }
    }
}
