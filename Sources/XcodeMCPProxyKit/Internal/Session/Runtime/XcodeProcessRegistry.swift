import Foundation
import NIOConcurrencyHelpers
import XcodeMCPKit

final class XcodeProcessRegistry: Sendable {
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
            for route in initialRoutes {
                let key = InstanceKey(target: route.target)
                guard state.recordsByKey[key] == nil else { continue }
                state.generation &+= 1
                let record = Record(
                    key: key,
                    route: route,
                    state: .active,
                    firstSeenGeneration: state.generation,
                    lastSeenGeneration: state.generation,
                    lastSeenUptimeNs: nowUptimeNs,
                    missingSinceUptimeNs: nil,
                    lastReconcileReason: reason
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
            let liveKeys = Set(orderedTargets.map(InstanceKey.init(target:)))

            for target in orderedTargets {
                let key = InstanceKey(target: target)
                if var record = state.recordsByKey[key], record.state == .active {
                    state.generation &+= 1
                    record.route = XcodeProcessRoute(
                        target: target,
                        upstreamIndices: record.route.upstreamIndices
                    )
                    record.lastSeenGeneration = state.generation
                    record.lastSeenUptimeNs = nowUptimeNs
                    record.missingSinceUptimeNs = nil
                    record.lastReconcileReason = reason
                    state.recordsByKey[key] = record
                    continue
                }

                let route = makeRoute(target)
                state.generation &+= 1
                let record = Record(
                    key: key,
                    route: route,
                    state: .active,
                    firstSeenGeneration: state.generation,
                    lastSeenGeneration: state.generation,
                    lastSeenUptimeNs: nowUptimeNs,
                    missingSinceUptimeNs: nil,
                    lastReconcileReason: reason
                )
                state.recordsByKey[key] = record
                state.order.append(key)
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

    func debugSnapshots(
        usableSlotCount: @Sendable (XcodeProcessRoute) -> Int,
        toolsCatalogState: @Sendable (XcodeProcessRoute, String) -> String
    ) -> [ProxyDebug.ProcessRouteSnapshot] {
        state.withLockedValue { state in
            state.order.compactMap { key in
                guard let record = state.recordsByKey[key] else { return nil }
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
}
