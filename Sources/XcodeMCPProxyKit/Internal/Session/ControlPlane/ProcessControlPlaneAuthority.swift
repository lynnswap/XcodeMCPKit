import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPKit

struct CatalogEpoch: Sendable, Hashable {
    fileprivate let rawValue: UInt64
}

struct CatalogAttemptID: Sendable, Hashable {
    let rawValue: Int
}

struct CatalogLease: Sendable, Hashable {
    fileprivate let catalogEpoch: CatalogEpoch
    fileprivate let routeID: ProcessRouteID
    fileprivate let attemptID: CatalogAttemptID
    fileprivate let upstreamID: UpstreamSlotID
}

enum CatalogInvalidationReason: Sendable {
    case reset
    case routeMembershipChanged
    case exposureChanged
}

enum CatalogOutcome: Sendable {
    case usable(JSONValue, source: UpstreamSlotID)
    case unusable
    case failed
}

enum StaleCatalogReason: Sendable, Equatable {
    case catalogEpochChanged
    case routeRetired
    case routeReplaced
    case upstreamReplaced
    case attemptSuperseded
    case attemptNotLoading
}

enum ProcessControlPlaneEffect: Sendable {
    case cancelTimeout(RuntimeScheduledTimeout)
    case cancelRPC(ControlPlane.RPCHandle)
}

struct ProcessControlPlaneTransition: Sendable {
    let addedRoutes: [XcodeProcessRoute]
    let retiredRoutes: [XcodeProcessRoute]
    let effects: [ProcessControlPlaneEffect]
    let publishesToolsListChanged: Bool

    static let none = ProcessControlPlaneTransition(
        addedRoutes: [],
        retiredRoutes: [],
        effects: [],
        publishesToolsListChanged: false
    )

    var didChangeRoutes: Bool {
        addedRoutes.isEmpty == false || retiredRoutes.isEmpty == false
    }
}

enum CatalogCommit: Sendable {
    case accepted(ProcessControlPlaneAuthority.Snapshot, ProcessControlPlaneTransition)
    case discarded(StaleCatalogReason, ProcessControlPlaneTransition)
}

/// Owns every process-route fact that participates in catalog validity.
///
/// The lock protects only synchronous state transitions. Timers and RPC handles
/// are detached as effects and are cancelled by `RuntimeCoordinator` after the
/// lock has been released.
final class ProcessControlPlaneAuthority: Sendable {
    enum ExposurePolicy: Sendable {
        case toolsCatalog
        case ownerRouting
        case windowDiscovery
        case initialization
    }

    enum CooldownScope: Sendable {
        case route
        case catalog
    }

    enum AttemptPhase: String, Sendable, Equatable, Hashable {
        case pending
        case attaching
        case initialized
        case loadingCatalog
        case cataloged
        case backoff
        case abandoned
    }

    struct UpstreamUsabilitySnapshot: Sendable, Equatable {
        let snapshotUsableUpstreamIDs: Set<UpstreamSlotID>
        let recoveryAwareUsableUpstreamIDs: Set<UpstreamSlotID>

        static let empty = UpstreamUsabilitySnapshot(
            snapshotUsableUpstreamIDs: [],
            recoveryAwareUsableUpstreamIDs: []
        )
    }

    struct RouteExposure: Sendable {
        let ordinal: Int
        let route: XcodeProcessRoute
        let usableUpstreamIDs: [UpstreamSlotID]

        var usableUpstreamIndices: [Int] {
            usableUpstreamIDs.map(\.rawValue)
        }
    }

    struct RoutingSnapshot: Sendable {
        let exposureEpoch: UInt64
        let policy: ExposurePolicy
        let routes: [RouteExposure]
        let processIDs: Set<pid_t>
    }

    struct RouteProof: Sendable, Hashable {
        let exposureEpoch: UInt64
        let routeID: ProcessRouteID
    }

    struct RouteAdmissionLease: Sendable, Hashable {
        let routeID: ProcessRouteID
        fileprivate let routeRevision: UInt64
    }

    struct Catalog: Sendable {
        let routeID: ProcessRouteID
        let target: XcodeProcessTarget
        let upstreamID: UpstreamSlotID
        let rawResult: JSONValue
        let toolsByName: [String: JSONValue]
        let fingerprintsByName: [String: String]
        let ownerBoundToolNames: Set<String>

        var upstreamIndex: Int { upstreamID.rawValue }
        var toolNames: Set<String> { Set(toolsByName.keys) }
    }

    struct AvailableToolCatalog: Sendable {
        let rawResult: JSONValue
        let sourceUpstreamID: UpstreamSlotID?
        let processIDs: Set<pid_t>

        var sourceUpstream: Int? { sourceUpstreamID?.rawValue }
        var isEmpty: Bool { processIDs.isEmpty }
    }

    struct CatalogDebugSnapshot: Codable, Sendable {
        let processID: Int32
        let appPath: String
        let xcodeVersion: String
        let upstreamIndex: Int
        let toolCount: Int
        let ownerBoundToolCount: Int
        let tabOwnerCount: Int
        let workspaceOwnerCount: Int
        let isCanonicalSource: Bool
        let exposurePolicy: String
        let missingFromExposedCatalog: [String]
        let extraBeyondExposedCatalog: [String]
        let schemaConflicts: [String]
    }

    struct AttemptSnapshot: Sendable, Equatable {
        let routeID: ProcessRouteID
        let attemptID: CatalogAttemptID
        let upstreamID: UpstreamSlotID
        let phase: AttemptPhase
        let timeoutCount: Int
        let rpcCount: Int
    }

    struct Snapshot: Sendable {
        let catalogEpoch: CatalogEpoch
        let exposureEpoch: UInt64
        let activeRoutes: [XcodeProcessRoute]
        let catalogProcessIDs: Set<pid_t>
        let canonicalToolsCatalogRaw: JSONValue?
        let canonicalSourceUpstreamID: UpstreamSlotID?
        let attempts: [AttemptSnapshot]

        var canonicalSourceUpstream: Int? { canonicalSourceUpstreamID?.rawValue }
    }

    struct ActivationStart: Sendable {
        let lease: CatalogLease
        let startedAtUptimeNs: UInt64

        var attempt: Int { lease.attemptID.rawValue }
    }

    struct InitializedAttempt: Sendable {
        let lease: CatalogLease
        let startedAtUptimeNs: UInt64

        var attempt: Int { lease.attemptID.rawValue }
    }

    struct Retry: Sendable {
        let attempt: Int
        let delay: TimeAmount
        let delayMilliseconds: Int64
    }

    struct AttemptTimeout: Sendable {
        let transition: ProcessControlPlaneTransition
        let retry: Retry
    }

    struct MarkUnavailableResult: Sendable {
        let route: XcodeProcessRoute
        let didChangeExposure: Bool
        let transition: ProcessControlPlaneTransition
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
            processID = target.processID
            appPath = target.appPath
            developerDir = target.developerDir
            mcpbridgePath = target.mcpbridgePath
            xcodeVersion = target.xcodeVersion
        }
    }

    private struct Attempt: Sendable {
        let id: CatalogAttemptID
        let upstreamID: UpstreamSlotID
        let startedAtUptimeNs: UInt64
        var phase: AttemptPhase
        var retryTimeout: RuntimeScheduledTimeout?
        var catalogTimeout: RuntimeScheduledTimeout?
        var rpcHandles: [ControlPlane.RPCHandle]

        func detachedEffects() -> [ProcessControlPlaneEffect] {
            var effects: [ProcessControlPlaneEffect] = []
            if let retryTimeout { effects.append(.cancelTimeout(retryTimeout)) }
            if let catalogTimeout { effects.append(.cancelTimeout(catalogTimeout)) }
            effects.append(contentsOf: rpcHandles.map(ProcessControlPlaneEffect.cancelRPC))
            return effects
        }
    }

    private struct RouteRecord: Sendable {
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
        var admissionRevision: UInt64
        var nextAttemptID: Int
        var attempt: Attempt?

        var unavailableUntilUptimeNs: UInt64 {
            max(routeUnavailableUntilUptimeNs ?? 0, catalogUnavailableUntilUptimeNs ?? 0)
        }

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
        var recordsByKey: [InstanceKey: RouteRecord] = [:]
        var order: [InstanceKey] = []
        var routeGeneration: UInt64 = 0
        var exposureEpoch: UInt64 = 0
        var catalogEpoch = CatalogEpoch(rawValue: 0)
        var usability: UpstreamUsabilitySnapshot = .empty
        var catalogsByProcessID: [pid_t: Catalog] = [:]
        var processIDByUpstreamID: [UpstreamSlotID: pid_t] = [:]
        var canonicalToolsCatalogRaw: JSONValue?
        var canonicalSourceUpstreamID: UpstreamSlotID?
        var nextUnboundAttemptID: Int = 0
        var unboundAttempt: Attempt?
        var unboundCatalogRaw: JSONValue?
        var unboundCatalogSource: UpstreamSlotID?
        var nowUptimeNs: UInt64 = 0
    }

    private let state: NIOLockedValueBox<State>

    init(
        initialRoutes: [XcodeProcessRoute] = [],
        nowUptimeNs: UInt64 = 0,
        reason: String = "startup"
    ) {
        var initialState = State()
        initialState.nowUptimeNs = nowUptimeNs
        for initialRoute in initialRoutes {
            _ = Self.insertNewRoute(
                initialRoute,
                nowUptimeNs: nowUptimeNs,
                reason: reason,
                into: &initialState
            )
        }
        state = NIOLockedValueBox(initialState)
    }

    func activeRoutes() -> [XcodeProcessRoute] {
        state.withLockedValue { state in Self.activeRoutes(in: state) }
    }

    func currentCatalogEpoch() -> CatalogEpoch {
        state.withLockedValue(\.catalogEpoch)
    }

    func currentExposureEpoch() -> UInt64 {
        state.withLockedValue(\.exposureEpoch)
    }

    func snapshot() -> Snapshot {
        state.withLockedValue { state in Self.snapshot(in: state) }
    }

    func updateUsability(
        _ usability: UpstreamUsabilitySnapshot,
        nowUptimeNs: UInt64
    ) -> ProcessControlPlaneTransition {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNs)
            let oldExposed = Self.exposedProcessIDs(
                policy: .toolsCatalog,
                nowUptimeNs: nowUptimeNs,
                state: state
            )
            guard state.usability != usability else { return .none }
            let didChangeRouteUsability = Self.updateAdmissionRevisions(
                from: state.usability,
                to: usability,
                in: &state
            )
            state.usability = usability
            let newExposed = Self.exposedProcessIDs(
                policy: .toolsCatalog,
                nowUptimeNs: nowUptimeNs,
                state: state
            )
            if didChangeRouteUsability {
                state.exposureEpoch &+= 1
            }
            guard oldExposed != newExposed else { return .none }
            state.catalogEpoch = CatalogEpoch(rawValue: state.catalogEpoch.rawValue &+ 1)
            let effects = Self.invalidateCatalogAttempts(in: &state)
            let changed = Self.recomputeCanonicalProjection(in: &state)
            return ProcessControlPlaneTransition(
                addedRoutes: [],
                retiredRoutes: [],
                effects: effects,
                publishesToolsListChanged: changed
            )
        }
    }

    func reconcileRoutes(
        _ observed: [XcodeProcessRoute],
        reason: String,
        nowUptimeNs: UInt64,
        usability: UpstreamUsabilitySnapshot
    ) -> ProcessControlPlaneTransition {
        let ordered = MCPBridgeRuntime.orderedXcodeTargets(observed.map(\.target))
        let observedByKey = Dictionary(uniqueKeysWithValues: observed.map {
            (InstanceKey(target: $0.target), $0)
        })
        return state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNs)
            let startingCatalogEpoch = state.catalogEpoch
            let oldExposed = Self.exposedProcessIDs(
                policy: .toolsCatalog,
                nowUptimeNs: nowUptimeNs,
                state: state
            )
            let didChangeRouteUsability = Self.updateAdmissionRevisions(
                from: state.usability,
                to: usability,
                in: &state
            )
            state.usability = usability
            if didChangeRouteUsability {
                state.exposureEpoch &+= 1
            }
            var added: [XcodeProcessRoute] = []
            var retired: [XcodeProcessRoute] = []
            var effects: [ProcessControlPlaneEffect] = []
            let orderedKeys = ordered.map(InstanceKey.init(target:))
            let liveKeys = Set(orderedKeys)

            for target in ordered {
                let key = InstanceKey(target: target)
                guard let observedRoute = observedByKey[key] else { continue }
                if var record = state.recordsByKey[key], record.state == .active {
                    let membershipChanged =
                        record.route.upstreamIndices != observedRoute.upstreamIndices
                    if membershipChanged {
                        state.routeGeneration &+= 1
                        state.exposureEpoch &+= 1
                        state.catalogEpoch = CatalogEpoch(
                            rawValue: state.catalogEpoch.rawValue &+ 1
                        )
                        if let attempt = record.attempt {
                            effects.append(contentsOf: attempt.detachedEffects())
                            record.attempt = nil
                        }
                        Self.removeCatalog(
                            processID: record.route.target.processID,
                            from: &state
                        )
                        record.route = XcodeProcessRoute(
                            id: ProcessRouteID(
                                processID: target.processID,
                                instanceGeneration: state.routeGeneration
                            ),
                            target: target,
                            upstreamIndices: observedRoute.upstreamIndices
                        )
                        record.lastSeenGeneration = state.routeGeneration
                    } else {
                        record.route = XcodeProcessRoute(
                            id: record.route.id,
                            target: target,
                            upstreamIndices: observedRoute.upstreamIndices
                        )
                    }
                    record.lastSeenUptimeNs = nowUptimeNs
                    record.missingSinceUptimeNs = nil
                    record.lastReconcileReason = reason
                    state.recordsByKey[key] = record
                    continue
                }
                let route = Self.insertNewRoute(
                    observedRoute,
                    nowUptimeNs: nowUptimeNs,
                    reason: reason,
                    into: &state
                )
                added.append(route)
            }

            for key in state.order {
                guard liveKeys.contains(key) == false,
                      var record = state.recordsByKey[key],
                      record.state == .active else { continue }
                state.routeGeneration &+= 1
                state.exposureEpoch &+= 1
                state.catalogEpoch = CatalogEpoch(rawValue: state.catalogEpoch.rawValue &+ 1)
                record.state = .retired
                record.lastSeenGeneration = state.routeGeneration
                record.missingSinceUptimeNs = nowUptimeNs
                record.lastReconcileReason = reason
                if let attempt = record.attempt {
                    effects.append(contentsOf: attempt.detachedEffects())
                    record.attempt = nil
                }
                state.recordsByKey[key] = record
                retired.append(record.route)
                Self.removeCatalog(processID: record.route.target.processID, from: &state)
            }

            Self.reorderActiveKeys(orderedKeys, in: &state)
            let newExposed = Self.exposedProcessIDs(
                policy: .toolsCatalog,
                nowUptimeNs: nowUptimeNs,
                state: state
            )
            if oldExposed != newExposed, state.catalogEpoch == startingCatalogEpoch {
                state.catalogEpoch = CatalogEpoch(rawValue: state.catalogEpoch.rawValue &+ 1)
            }
            if state.catalogEpoch != startingCatalogEpoch {
                effects.append(contentsOf: Self.invalidateCatalogAttempts(in: &state))
            }
            let projectionChanged = Self.recomputeCanonicalProjection(in: &state)
            return ProcessControlPlaneTransition(
                addedRoutes: added,
                retiredRoutes: retired,
                effects: effects,
                publishesToolsListChanged: projectionChanged || added.isEmpty == false
            )
        }
    }

    func routingSnapshot(
        policy: ExposurePolicy,
        nowUptimeNs: UInt64
    ) -> RoutingSnapshot {
        state.withLockedValue { state in
            Self.routingSnapshot(policy: policy, nowUptimeNs: nowUptimeNs, state: state)
        }
    }

    func route(forUpstreamIndex upstreamIndex: Int) -> XcodeProcessRoute? {
        let id = UpstreamSlotID(rawValue: upstreamIndex)
        return state.withLockedValue { state in
            Self.activeRoutes(in: state).first { $0.upstreamIndices.contains(id.rawValue) }
        }
    }

    func route(forProcessID processID: pid_t) -> XcodeProcessRoute? {
        state.withLockedValue { state in
            Self.activeRoutes(in: state).first { $0.target.processID == processID }
        }
    }

    func containsActiveRoute(id routeID: ProcessRouteID) -> Bool {
        state.withLockedValue { state in Self.record(routeID: routeID, in: state) != nil }
    }

    func routeProof(routeID: ProcessRouteID) -> RouteProof? {
        state.withLockedValue { state in
            guard Self.record(routeID: routeID, in: state) != nil else { return nil }
            return RouteProof(exposureEpoch: state.exposureEpoch, routeID: routeID)
        }
    }

    func admit(_ proof: RouteProof) -> RouteAdmissionLease? {
        state.withLockedValue { state in
            guard proof.exposureEpoch == state.exposureEpoch,
                  let record = Self.record(routeID: proof.routeID, in: state),
                  record.isUnavailable(nowUptimeNs: state.nowUptimeNs) == false else { return nil }
            return RouteAdmissionLease(
                routeID: proof.routeID,
                routeRevision: record.admissionRevision
            )
        }
    }

    func validate(_ lease: RouteAdmissionLease) -> Bool {
        state.withLockedValue { state in
            guard let record = Self.record(routeID: lease.routeID, in: state) else { return false }
            return lease.routeRevision == record.admissionRevision
                && record.isUnavailable(nowUptimeNs: state.nowUptimeNs) == false
        }
    }

    func unavailableProcessIDs(nowUptimeNs: UInt64) -> Set<pid_t> {
        state.withLockedValue { state in
            Set(Self.activeRecords(in: state).compactMap { record in
                record.isUnavailable(nowUptimeNs: nowUptimeNs)
                    ? record.route.target.processID
                    : nil
            })
        }
    }

    func markUnavailable(
        upstreamIndex: Int,
        scope: CooldownScope,
        nowUptimeNs: UInt64,
        unavailableUntilUptimeNs: UInt64
    ) -> MarkUnavailableResult? {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNs)
            guard let key = Self.activeKey(upstreamIndex: upstreamIndex, in: state),
                  var record = state.recordsByKey[key] else { return nil }
            let wasUnavailable = record.isUnavailable(nowUptimeNs: nowUptimeNs)
            switch scope {
            case .route:
                let previous = record.routeUnavailableUntilUptimeNs
                record.routeUnavailableUntilUptimeNs = max(previous ?? 0, unavailableUntilUptimeNs)
                guard previous != record.routeUnavailableUntilUptimeNs else { return nil }
            case .catalog:
                let previous = record.catalogUnavailableUntilUptimeNs
                record.catalogUnavailableUntilUptimeNs = max(previous ?? 0, unavailableUntilUptimeNs)
                guard previous != record.catalogUnavailableUntilUptimeNs else { return nil }
            }
            state.routeGeneration &+= 1
            state.exposureEpoch &+= 1
            state.catalogEpoch = CatalogEpoch(rawValue: state.catalogEpoch.rawValue &+ 1)
            record.lastSeenGeneration = state.routeGeneration
            record.admissionRevision &+= 1
            var effects = record.attempt?.detachedEffects() ?? []
            record.attempt = nil
            state.recordsByKey[key] = record
            effects.append(contentsOf: Self.invalidateCatalogAttempts(in: &state))
            let projectionChanged = Self.recomputeCanonicalProjection(in: &state)
            return MarkUnavailableResult(
                route: record.route,
                didChangeExposure: wasUnavailable == false,
                transition: ProcessControlPlaneTransition(
                    addedRoutes: [],
                    retiredRoutes: [],
                    effects: effects,
                    publishesToolsListChanged: projectionChanged
                )
            )
        }
    }

    func markAvailable(
        upstreamIndex: Int,
        scope: CooldownScope,
        nowUptimeNs: UInt64
    ) -> ProcessControlPlaneTransition {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNs)
            guard let key = Self.activeKey(upstreamIndex: upstreamIndex, in: state),
                  var record = state.recordsByKey[key] else { return .none }
            let before = record.isUnavailable(nowUptimeNs: nowUptimeNs)
            switch scope {
            case .route:
                record.routeUnavailableUntilUptimeNs = nil
                _ = record.pruneExpiredUnavailable(nowUptimeNs: nowUptimeNs)
            case .catalog:
                record.routeUnavailableUntilUptimeNs = nil
                record.catalogUnavailableUntilUptimeNs = nil
            }
            let after = record.isUnavailable(nowUptimeNs: nowUptimeNs)
            guard before != after else {
                state.recordsByKey[key] = record
                return .none
            }
            state.routeGeneration &+= 1
            state.exposureEpoch &+= 1
            state.catalogEpoch = CatalogEpoch(rawValue: state.catalogEpoch.rawValue &+ 1)
            record.admissionRevision &+= 1
            state.recordsByKey[key] = record
            let effects = Self.invalidateCatalogAttempts(in: &state)
            let projectionChanged = Self.recomputeCanonicalProjection(in: &state)
            return ProcessControlPlaneTransition(
                addedRoutes: [],
                retiredRoutes: [],
                effects: effects,
                publishesToolsListChanged: projectionChanged
            )
        }
    }

    func beginAttaching(
        routeID: ProcessRouteID,
        upstreamIndex: Int,
        nowUptimeNs: UInt64
    ) -> (ActivationStart, ProcessControlPlaneTransition)? {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNs)
            guard let key = Self.key(routeID: routeID, in: state),
                  var record = state.recordsByKey[key] else { return nil }
            if let attempt = record.attempt,
               [.attaching, .initialized, .loadingCatalog].contains(attempt.phase) {
                return nil
            }
            let effects = record.attempt?.detachedEffects() ?? []
            record.nextAttemptID &+= 1
            let attempt = Attempt(
                id: CatalogAttemptID(rawValue: record.nextAttemptID),
                upstreamID: UpstreamSlotID(rawValue: upstreamIndex),
                startedAtUptimeNs: nowUptimeNs,
                phase: .attaching,
                retryTimeout: nil,
                catalogTimeout: nil,
                rpcHandles: []
            )
            record.attempt = attempt
            state.recordsByKey[key] = record
            let lease = Self.lease(for: attempt, routeID: routeID, catalogEpoch: state.catalogEpoch)
            return (
                ActivationStart(lease: lease, startedAtUptimeNs: nowUptimeNs),
                ProcessControlPlaneTransition(
                    addedRoutes: [], retiredRoutes: [], effects: effects,
                    publishesToolsListChanged: false
                )
            )
        }
    }

    func markInitialized(
        routeID: ProcessRouteID,
        upstreamIndex: Int
    ) -> InitializedAttempt? {
        state.withLockedValue { state in
            guard let key = Self.key(routeID: routeID, in: state),
                  var record = state.recordsByKey[key],
                  var attempt = record.attempt,
                  attempt.upstreamID.rawValue == upstreamIndex,
                  [.attaching, .loadingCatalog].contains(attempt.phase) else { return nil }
            attempt.phase = .initialized
            record.attempt = attempt
            state.recordsByKey[key] = record
            return InitializedAttempt(
                lease: Self.lease(for: attempt, routeID: routeID, catalogEpoch: state.catalogEpoch),
                startedAtUptimeNs: attempt.startedAtUptimeNs
            )
        }
    }

    func beginCatalogAttempt(
        routeID: ProcessRouteID,
        preferredUpstream: UpstreamSlotID,
        nowUptimeNanoseconds: UInt64
    ) -> (CatalogLease, ProcessControlPlaneTransition)? {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNanoseconds)
            guard let key = Self.key(routeID: routeID, in: state),
                  var record = state.recordsByKey[key],
                  record.route.upstreamIndices.contains(preferredUpstream.rawValue) else { return nil }
            if var attempt = record.attempt,
               [.pending, .attaching, .initialized, .loadingCatalog].contains(attempt.phase) {
                attempt.phase = .loadingCatalog
                record.attempt = attempt
                state.recordsByKey[key] = record
                return (
                    Self.lease(for: attempt, routeID: routeID, catalogEpoch: state.catalogEpoch),
                    .none
                )
            }
            let effects = record.attempt?.detachedEffects() ?? []
            record.nextAttemptID &+= 1
            let attempt = Attempt(
                id: CatalogAttemptID(rawValue: record.nextAttemptID),
                upstreamID: preferredUpstream,
                startedAtUptimeNs: nowUptimeNanoseconds,
                phase: .loadingCatalog,
                retryTimeout: nil,
                catalogTimeout: nil,
                rpcHandles: []
            )
            record.attempt = attempt
            state.recordsByKey[key] = record
            return (
                Self.lease(for: attempt, routeID: routeID, catalogEpoch: state.catalogEpoch),
                ProcessControlPlaneTransition(
                    addedRoutes: [], retiredRoutes: [], effects: effects,
                    publishesToolsListChanged: false
                )
            )
        }
    }

    func beginUnboundCatalogAttempt(
        preferredUpstream: UpstreamSlotID,
        nowUptimeNanoseconds: UInt64
    ) -> (CatalogLease, ProcessControlPlaneTransition) {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNanoseconds)
            let effects = state.unboundAttempt?.detachedEffects() ?? []
            state.nextUnboundAttemptID &+= 1
            let attempt = Attempt(
                id: CatalogAttemptID(rawValue: state.nextUnboundAttemptID),
                upstreamID: preferredUpstream,
                startedAtUptimeNs: nowUptimeNanoseconds,
                phase: .loadingCatalog,
                retryTimeout: nil,
                catalogTimeout: nil,
                rpcHandles: []
            )
            state.unboundAttempt = attempt
            return (
                Self.lease(
                    for: attempt,
                    routeID: Self.unboundRouteID,
                    catalogEpoch: state.catalogEpoch
                ),
                ProcessControlPlaneTransition(
                    addedRoutes: [], retiredRoutes: [], effects: effects,
                    publishesToolsListChanged: false
                )
            )
        }
    }

    func attach(
        _ resource: AttemptResource,
        to lease: CatalogLease
    ) -> ProcessControlPlaneTransition {
        state.withLockedValue { state in
            guard let key = Self.key(routeID: lease.routeID, in: state),
                  var record = state.recordsByKey[key],
                  var attempt = record.attempt,
                  Self.matches(lease: lease, attempt: attempt, state: state) else {
                return ProcessControlPlaneTransition(
                    addedRoutes: [], retiredRoutes: [],
                    effects: [resource.cancellationEffect],
                    publishesToolsListChanged: false
                )
            }
            var effects: [ProcessControlPlaneEffect] = []
            switch resource {
            case .retryTimeout(let timeout):
                if let previous = attempt.retryTimeout { effects.append(.cancelTimeout(previous)) }
                attempt.retryTimeout = timeout
            case .catalogTimeout(let timeout):
                if let previous = attempt.catalogTimeout { effects.append(.cancelTimeout(previous)) }
                attempt.catalogTimeout = timeout
            case .rpc(let handle):
                attempt.rpcHandles.append(handle)
            }
            record.attempt = attempt
            state.recordsByKey[key] = record
            return ProcessControlPlaneTransition(
                addedRoutes: [], retiredRoutes: [], effects: effects,
                publishesToolsListChanged: false
            )
        }
    }

    func completeCatalog(
        _ outcome: CatalogOutcome,
        lease: CatalogLease,
        nowUptimeNanoseconds: UInt64
    ) -> CatalogCommit {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNanoseconds)
            guard lease.catalogEpoch == state.catalogEpoch else {
                return .discarded(.catalogEpochChanged, .none)
            }
            if lease.routeID == Self.unboundRouteID {
                return Self.completeUnboundCatalog(
                    outcome,
                    lease: lease,
                    state: &state
                )
            }
            guard let key = Self.key(routeID: lease.routeID, in: state),
                  var record = state.recordsByKey[key] else {
                return .discarded(.routeRetired, .none)
            }
            guard record.route.id == lease.routeID else {
                return .discarded(.routeReplaced, .none)
            }
            guard record.route.upstreamIndices.contains(lease.upstreamID.rawValue) else {
                return .discarded(.upstreamReplaced, .none)
            }
            guard var attempt = record.attempt,
                  attempt.id == lease.attemptID else {
                return .discarded(.attemptSuperseded, .none)
            }
            guard [.attaching, .initialized, .loadingCatalog].contains(attempt.phase) else {
                return .discarded(.attemptNotLoading, .none)
            }

            var effects: [ProcessControlPlaneEffect] = []
            let hadCatalog = state.catalogsByProcessID[record.route.target.processID] != nil
            switch outcome {
            case .usable(let rawResult, let source):
                effects = attempt.detachedEffects()
                attempt.retryTimeout = nil
                attempt.catalogTimeout = nil
                attempt.rpcHandles.removeAll()
                guard record.route.upstreamIndices.contains(source.rawValue) else {
                    return .discarded(.upstreamReplaced, .none)
                }
                let catalog = Self.makeCatalog(
                    route: record.route,
                    upstreamID: source,
                    rawResult: rawResult
                )
                state.catalogsByProcessID[record.route.target.processID] = catalog
                for upstreamIndex in record.route.upstreamIndices {
                    state.processIDByUpstreamID[UpstreamSlotID(rawValue: upstreamIndex)] =
                        record.route.target.processID
                }
                record.routeUnavailableUntilUptimeNs = nil
                record.catalogUnavailableUntilUptimeNs = nil
                attempt.phase = .cataloged
            case .unusable:
                effects = attempt.rpcHandles.map(ProcessControlPlaneEffect.cancelRPC)
                attempt.rpcHandles.removeAll()
                Self.removeCatalog(processID: record.route.target.processID, from: &state)
                attempt.phase = .pending
            case .failed:
                effects = attempt.detachedEffects()
                attempt.retryTimeout = nil
                attempt.catalogTimeout = nil
                attempt.rpcHandles.removeAll()
                attempt.phase = hadCatalog ? .cataloged : .pending
            }
            record.attempt = attempt
            state.recordsByKey[key] = record
            let projectionChanged = Self.recomputeCanonicalProjection(in: &state)
            let transition = ProcessControlPlaneTransition(
                addedRoutes: [],
                retiredRoutes: [],
                effects: effects,
                publishesToolsListChanged: projectionChanged || (hadCatalog == false && {
                    if case .usable = outcome { return true }
                    return false
                }())
            )
            return .accepted(Self.snapshot(in: state), transition)
        }
    }

    func invalidateCatalog(
        _ reason: CatalogInvalidationReason
    ) -> ProcessControlPlaneTransition {
        state.withLockedValue { state in
            state.catalogEpoch = CatalogEpoch(rawValue: state.catalogEpoch.rawValue &+ 1)
            let effects = Self.invalidateAttempts(in: &state)
            switch reason {
            case .reset:
                state.catalogsByProcessID.removeAll()
                state.processIDByUpstreamID.removeAll()
                state.unboundCatalogRaw = nil
                state.unboundCatalogSource = nil
            case .routeMembershipChanged, .exposureChanged:
                break
            }
            let projectionChanged = Self.recomputeCanonicalProjection(in: &state)
            return ProcessControlPlaneTransition(
                addedRoutes: [], retiredRoutes: [], effects: effects,
                publishesToolsListChanged: projectionChanged
            )
        }
    }

    func reset() -> ProcessControlPlaneTransition {
        state.withLockedValue { state in
            let effects = Self.invalidateAttempts(in: &state)
            state.catalogEpoch = CatalogEpoch(rawValue: state.catalogEpoch.rawValue &+ 1)
            state.exposureEpoch &+= 1
            state.catalogsByProcessID.removeAll()
            state.processIDByUpstreamID.removeAll()
            state.canonicalToolsCatalogRaw = nil
            state.canonicalSourceUpstreamID = nil
            state.unboundCatalogRaw = nil
            state.unboundCatalogSource = nil
            for key in state.order {
                guard var record = state.recordsByKey[key] else { continue }
                record.routeUnavailableUntilUptimeNs = nil
                record.catalogUnavailableUntilUptimeNs = nil
                record.attempt = nil
                record.admissionRevision &+= 1
                state.recordsByKey[key] = record
            }
            return ProcessControlPlaneTransition(
                addedRoutes: [], retiredRoutes: [], effects: effects,
                publishesToolsListChanged: true
            )
        }
    }

    func catalog(forUpstreamIndex upstreamIndex: Int) -> Catalog? {
        state.withLockedValue { state in
            guard let processID = state.processIDByUpstreamID[UpstreamSlotID(rawValue: upstreamIndex)]
            else { return nil }
            return state.catalogsByProcessID[processID]
        }
    }

    func catalog(forProcessID processID: pid_t) -> Catalog? {
        state.withLockedValue { $0.catalogsByProcessID[processID] }
    }

    func availableToolCatalogSurface(processIDs: Set<pid_t>? = nil) -> AvailableToolCatalog? {
        state.withLockedValue { Self.availableToolCatalogSurface(in: $0, processIDs: processIDs) }
    }

    func canonicalToolsCatalogRaw() -> JSONValue? {
        state.withLockedValue(\.canonicalToolsCatalogRaw)
    }

    func canonicalSourceUpstream() -> Int? {
        state.withLockedValue { $0.canonicalSourceUpstreamID?.rawValue }
    }

    func processIDsWithCatalog() -> Set<pid_t> {
        state.withLockedValue { Set($0.catalogsByProcessID.keys) }
    }

    func isOwnerBoundTool(_ toolName: String) -> Bool {
        state.withLockedValue { state in
            state.catalogsByProcessID.values.contains { $0.ownerBoundToolNames.contains(toolName) }
        }
    }

    func processIDsHavingTool(_ toolName: String) -> Set<pid_t> {
        state.withLockedValue { state in
            Set(state.catalogsByProcessID.compactMap { processID, catalog in
                catalog.toolsByName[toolName] == nil ? nil : processID
            })
        }
    }

    func hasTool(_ toolName: String, processID: pid_t) -> Bool {
        catalog(forProcessID: processID)?.toolsByName[toolName] != nil
    }

    func tool(_ toolName: String, processID: pid_t, requiresArgument argumentName: String) -> Bool {
        guard let tool = catalog(forProcessID: processID)?.toolsByName[toolName] else { return false }
        return ProcessToolCatalogCodec.tool(tool, requiresArgument: argumentName)
    }

    func pendingCatalogProcessIDs(nowUptimeNs: UInt64) -> Set<pid_t> {
        state.withLockedValue { state in
            let exposed = Self.exposedProcessIDs(
                policy: .toolsCatalog,
                nowUptimeNs: nowUptimeNs,
                state: state
            )
            let activationPending = Set<pid_t>(Self.activeRecords(in: state).compactMap { record in
                guard state.catalogsByProcessID[record.route.target.processID] == nil,
                      let attempt = record.attempt,
                      [.pending, .attaching, .initialized, .loadingCatalog, .backoff]
                        .contains(attempt.phase) else { return nil }
                return record.route.target.processID
            })
            return exposed
                .subtracting(state.catalogsByProcessID.keys)
                .union(activationPending)
        }
    }

    func attemptSnapshot(processID: pid_t) -> AttemptSnapshot? {
        state.withLockedValue { state in
            guard let record = Self.activeRecords(in: state).first(where: {
                $0.route.target.processID == processID
            }), let attempt = record.attempt else { return nil }
            return Self.attemptSnapshot(routeID: record.route.id, attempt: attempt)
        }
    }

    func currentCatalogLease(processID: pid_t, upstreamIndex: Int) -> CatalogLease? {
        state.withLockedValue { state in
            guard let record = Self.activeRecords(in: state).first(where: {
                $0.route.target.processID == processID
            }), let attempt = record.attempt,
            attempt.upstreamID.rawValue == upstreamIndex,
            [.pending, .attaching, .initialized, .loadingCatalog, .backoff].contains(attempt.phase) else {
                return nil
            }
            return Self.lease(for: attempt, routeID: record.route.id, catalogEpoch: state.catalogEpoch)
        }
    }

    func abandon(processID: pid_t) -> ProcessControlPlaneTransition {
        state.withLockedValue { state in
            guard let key = Self.activeRecords(in: state).first(where: {
                $0.route.target.processID == processID
            })?.key,
            var record = state.recordsByKey[key] else { return .none }
            let effects = record.attempt?.detachedEffects() ?? []
            if var attempt = record.attempt {
                attempt.phase = .abandoned
                attempt.retryTimeout = nil
                attempt.catalogTimeout = nil
                attempt.rpcHandles.removeAll()
                record.attempt = attempt
            }
            state.recordsByKey[key] = record
            return ProcessControlPlaneTransition(
                addedRoutes: [], retiredRoutes: [], effects: effects,
                publishesToolsListChanged: false
            )
        }
    }

    func scheduleRetry(
        processID: pid_t
    ) -> (lease: CatalogLease, retry: Retry)? {
        state.withLockedValue { state in
            guard let record = Self.activeRecords(in: state).first(where: {
                $0.route.target.processID == processID
            }), var attempt = record.attempt,
            [.pending, .initialized, .loadingCatalog].contains(attempt.phase),
            let key = Self.key(routeID: record.route.id, in: state) else { return nil }
            attempt.phase = .backoff
            var updated = record
            updated.attempt = attempt
            state.recordsByKey[key] = updated
            return (
                Self.lease(
                    for: attempt,
                    routeID: record.route.id,
                    catalogEpoch: state.catalogEpoch
                ),
                Self.retry(forAttempt: attempt.id.rawValue)
            )
        }
    }

    func resetAttempt(processID: pid_t) -> ProcessControlPlaneTransition {
        state.withLockedValue { state in
            guard let key = Self.activeRecords(in: state).first(where: {
                $0.route.target.processID == processID
            })?.key,
            var record = state.recordsByKey[key], let attempt = record.attempt else { return .none }
            let effects = attempt.detachedEffects()
            record.attempt = nil
            state.recordsByKey[key] = record
            return ProcessControlPlaneTransition(
                addedRoutes: [], retiredRoutes: [], effects: effects,
                publishesToolsListChanged: false
            )
        }
    }

    func resetAllAttempts() -> (processIDs: [pid_t], transition: ProcessControlPlaneTransition) {
        state.withLockedValue { state in
            var processIDs: [pid_t] = []
            var effects: [ProcessControlPlaneEffect] = []
            for key in state.order {
                guard var record = state.recordsByKey[key], let attempt = record.attempt else { continue }
                processIDs.append(record.route.target.processID)
                effects.append(contentsOf: attempt.detachedEffects())
                record.attempt = nil
                state.recordsByKey[key] = record
            }
            return (
                processIDs,
                ProcessControlPlaneTransition(
                    addedRoutes: [], retiredRoutes: [], effects: effects,
                    publishesToolsListChanged: false
                )
            )
        }
    }

    func handleActivationTimeout(
        processID: pid_t,
        upstreamIndex: Int,
        attemptID: Int
    ) -> AttemptTimeout? {
        finishAttemptForRetry(
            processID: processID,
            upstreamIndex: upstreamIndex,
            attemptID: attemptID,
            allowedPhases: [.attaching]
        )
    }

    func handleCatalogTimeout(
        processID: pid_t,
        upstreamIndex: Int,
        attemptID: Int
    ) -> AttemptTimeout? {
        finishAttemptForRetry(
            processID: processID,
            upstreamIndex: upstreamIndex,
            attemptID: attemptID,
            allowedPhases: [.initialized, .loadingCatalog]
        )
    }

    func handleRetryFired(processID: pid_t, attemptID: Int) -> Bool {
        state.withLockedValue { state in
            guard let key = Self.activeRecords(in: state).first(where: {
                $0.route.target.processID == processID
            })?.key,
            var record = state.recordsByKey[key], var attempt = record.attempt,
            attempt.id.rawValue == attemptID, attempt.phase == .backoff else { return false }
            attempt.retryTimeout = nil
            attempt.phase = .pending
            record.attempt = attempt
            state.recordsByKey[key] = record
            return true
        }
    }

    func debugRouteSnapshots(
        usableSlotCount: @Sendable (XcodeProcessRoute) -> Int
    ) -> [ProxyDebug.ProcessRouteSnapshot] {
        let records = state.withLockedValue { state in state.order.compactMap { state.recordsByKey[$0] } }
        return records.map { record in
            ProxyDebug.ProcessRouteSnapshot(
                state: record.state.rawValue,
                processID: record.route.target.processID,
                appPath: record.route.target.appPath,
                developerDir: record.route.target.developerDir,
                mcpbridgePath: record.route.target.mcpbridgePath,
                xcodeVersion: record.route.target.xcodeVersion,
                upstreamIndices: record.route.upstreamIndices,
                usableSlotCount: usableSlotCount(record.route),
                toolsCatalogState: record.state == .retired
                    ? "retired"
                    : (catalog(forProcessID: record.route.target.processID) == nil ? "missing" : "ready"),
                firstSeenGeneration: record.firstSeenGeneration,
                lastSeenGeneration: record.lastSeenGeneration,
                lastSeenUptimeNs: record.lastSeenUptimeNs,
                missingSinceUptimeNs: record.missingSinceUptimeNs,
                lastReconcileReason: record.lastReconcileReason
            )
        }
    }

    func debugCatalogSnapshots(
        exposedCatalog: JSONValue?,
        tabOwnerCountsByProcessID: [pid_t: Int],
        workspaceOwnerCountsByProcessID: [pid_t: Int]
    ) -> [CatalogDebugSnapshot] {
        let exposedNames = Set(ProcessToolCatalogCodec.toolsByName(in: exposedCatalog).keys)
        return state.withLockedValue { state in
            let catalogs = Array(state.catalogsByProcessID.values)
            let conflicts = ProcessToolCatalogCodec.schemaConflicts(in: catalogs)
            return catalogs.sorted(by: ProcessToolCatalogCodec.catalogSort).map { catalog in
                let toolNames = catalog.toolNames
                return CatalogDebugSnapshot(
                    processID: Int32(catalog.target.processID),
                    appPath: catalog.target.appPath,
                    xcodeVersion: catalog.target.xcodeVersion,
                    upstreamIndex: catalog.upstreamIndex,
                    toolCount: toolNames.count,
                    ownerBoundToolCount: catalog.ownerBoundToolNames.count,
                    tabOwnerCount: tabOwnerCountsByProcessID[catalog.target.processID, default: 0],
                    workspaceOwnerCount: workspaceOwnerCountsByProcessID[catalog.target.processID, default: 0],
                    isCanonicalSource: catalog.upstreamID == state.canonicalSourceUpstreamID,
                    exposurePolicy: "available_route_catalog_surface",
                    missingFromExposedCatalog: Array(toolNames.subtracting(exposedNames)).sorted(),
                    extraBeyondExposedCatalog: Array(exposedNames.subtracting(toolNames)).sorted(),
                    schemaConflicts: conflicts
                )
            }
        }
    }

    private func finishAttemptForRetry(
        processID: pid_t,
        upstreamIndex: Int,
        attemptID: Int,
        allowedPhases: Set<AttemptPhase>
    ) -> AttemptTimeout? {
        state.withLockedValue { state in
            guard let key = Self.activeRecords(in: state).first(where: {
                $0.route.target.processID == processID
            })?.key,
            var record = state.recordsByKey[key], var attempt = record.attempt,
            attempt.id.rawValue == attemptID,
            attempt.upstreamID.rawValue == upstreamIndex,
            allowedPhases.contains(attempt.phase) else { return nil }
            let effects = attempt.detachedEffects()
            attempt.retryTimeout = nil
            attempt.catalogTimeout = nil
            attempt.rpcHandles.removeAll()
            attempt.phase = .backoff
            record.attempt = attempt
            state.recordsByKey[key] = record
            return AttemptTimeout(
                transition: ProcessControlPlaneTransition(
                    addedRoutes: [], retiredRoutes: [], effects: effects,
                    publishesToolsListChanged: false
                ),
                retry: Self.retry(forAttempt: attemptID)
            )
        }
    }

    private static func insertNewRoute(
        _ candidate: XcodeProcessRoute,
        nowUptimeNs: UInt64,
        reason: String,
        into state: inout State
    ) -> XcodeProcessRoute {
        state.routeGeneration &+= 1
        state.exposureEpoch &+= 1
        state.catalogEpoch = CatalogEpoch(rawValue: state.catalogEpoch.rawValue &+ 1)
        let route = XcodeProcessRoute(
            id: ProcessRouteID(
                processID: candidate.target.processID,
                instanceGeneration: state.routeGeneration
            ),
            target: candidate.target,
            upstreamIndices: candidate.upstreamIndices
        )
        let key = InstanceKey(target: candidate.target)
        state.recordsByKey[key] = RouteRecord(
            key: key,
            route: route,
            state: .active,
            firstSeenGeneration: state.routeGeneration,
            lastSeenGeneration: state.routeGeneration,
            lastSeenUptimeNs: nowUptimeNs,
            missingSinceUptimeNs: nil,
            lastReconcileReason: reason,
            routeUnavailableUntilUptimeNs: nil,
            catalogUnavailableUntilUptimeNs: nil,
            admissionRevision: 0,
            nextAttemptID: 0,
            attempt: nil
        )
        if state.order.contains(key) == false { state.order.append(key) }
        return route
    }

    private static func reorderActiveKeys(_ orderedKeys: [InstanceKey], in state: inout State) {
        let activeSet = Set(orderedKeys)
        state.order = orderedKeys + state.order.filter { activeSet.contains($0) == false }
    }

    private static func activeRoutes(in state: State) -> [XcodeProcessRoute] {
        activeRecords(in: state).map(\.route)
    }

    private static func activeRecords(in state: State) -> [RouteRecord] {
        state.order.compactMap { key in
            guard let record = state.recordsByKey[key], record.state == .active else { return nil }
            return record
        }
    }

    @discardableResult
    private static func updateAdmissionRevisions(
        from previous: UpstreamUsabilitySnapshot,
        to next: UpstreamUsabilitySnapshot,
        in state: inout State
    ) -> Bool {
        var didChange = false
        for key in state.order {
            guard var record = state.recordsByKey[key], record.state == .active else { continue }
            let routeIDs = Set(record.route.upstreamIndices.map(UpstreamSlotID.init(rawValue:)))
            let previousSnapshot = routeIDs.intersection(previous.snapshotUsableUpstreamIDs)
            let nextSnapshot = routeIDs.intersection(next.snapshotUsableUpstreamIDs)
            let previousRecovery = routeIDs.intersection(previous.recoveryAwareUsableUpstreamIDs)
            let nextRecovery = routeIDs.intersection(next.recoveryAwareUsableUpstreamIDs)
            guard previousSnapshot != nextSnapshot || previousRecovery != nextRecovery else {
                continue
            }
            record.admissionRevision &+= 1
            state.recordsByKey[key] = record
            didChange = true
        }
        return didChange
    }

    private static func activeKey(upstreamIndex: Int, in state: State) -> InstanceKey? {
        activeRecords(in: state).first { $0.route.upstreamIndices.contains(upstreamIndex) }?.key
    }

    private static func key(routeID: ProcessRouteID, in state: State) -> InstanceKey? {
        activeRecords(in: state).first { $0.route.id == routeID }?.key
    }

    private static func record(routeID: ProcessRouteID, in state: State) -> RouteRecord? {
        guard let key = key(routeID: routeID, in: state) else { return nil }
        return state.recordsByKey[key]
    }

    private static func routingSnapshot(
        policy: ExposurePolicy,
        nowUptimeNs: UInt64,
        state: State
    ) -> RoutingSnapshot {
        let usable: Set<UpstreamSlotID>
        switch policy {
        case .toolsCatalog:
            usable = state.usability.recoveryAwareUsableUpstreamIDs
        case .ownerRouting, .windowDiscovery, .initialization:
            usable = state.usability.snapshotUsableUpstreamIDs
        }
        var ordinal = 0
        let routes = activeRecords(in: state).compactMap { record -> RouteExposure? in
            defer { ordinal += 1 }
            guard record.isUnavailable(nowUptimeNs: nowUptimeNs) == false else { return nil }
            let usableIDs = record.route.upstreamIndices
                .map(UpstreamSlotID.init(rawValue:))
                .filter { usable.contains($0) }
            guard usableIDs.isEmpty == false else { return nil }
            return RouteExposure(ordinal: ordinal, route: record.route, usableUpstreamIDs: usableIDs)
        }
        return RoutingSnapshot(
            exposureEpoch: state.exposureEpoch,
            policy: policy,
            routes: routes,
            processIDs: Set(routes.map(\.route.target.processID))
        )
    }

    private static func exposedProcessIDs(
        policy: ExposurePolicy,
        nowUptimeNs: UInt64,
        state: State
    ) -> Set<pid_t> {
        routingSnapshot(policy: policy, nowUptimeNs: nowUptimeNs, state: state).processIDs
    }

    private static func lease(
        for attempt: Attempt,
        routeID: ProcessRouteID,
        catalogEpoch: CatalogEpoch
    ) -> CatalogLease {
        CatalogLease(
            catalogEpoch: catalogEpoch,
            routeID: routeID,
            attemptID: attempt.id,
            upstreamID: attempt.upstreamID
        )
    }

    private static func matches(lease: CatalogLease, attempt: Attempt, state: State) -> Bool {
        lease.catalogEpoch == state.catalogEpoch
            && lease.attemptID == attempt.id
            && lease.upstreamID == attempt.upstreamID
    }

    private static func makeCatalog(
        route: XcodeProcessRoute,
        upstreamID: UpstreamSlotID,
        rawResult: JSONValue
    ) -> Catalog {
        Catalog(
            routeID: route.id,
            target: route.target,
            upstreamID: upstreamID,
            rawResult: rawResult,
            toolsByName: ProcessToolCatalogCodec.toolsByName(in: rawResult),
            fingerprintsByName: ProcessToolCatalogCodec.toolFingerprintsByName(in: rawResult),
            ownerBoundToolNames: ProcessToolCatalogCodec.ownerBoundToolNames(in: rawResult)
        )
    }

    private static func removeCatalog(processID: pid_t, from state: inout State) {
        state.catalogsByProcessID.removeValue(forKey: processID)
        state.processIDByUpstreamID = state.processIDByUpstreamID.filter { $0.value != processID }
    }

    private static func availableToolCatalogSurface(
        in state: State,
        processIDs: Set<pid_t>?
    ) -> AvailableToolCatalog? {
        let catalogs = state.catalogsByProcessID.values.filter { catalog in
            processIDs?.contains(catalog.target.processID) ?? true
        }
        guard let rawResult = ProcessToolCatalogCodec.unionToolsListResult(from: Array(catalogs))
        else { return nil }
        return AvailableToolCatalog(
            rawResult: rawResult,
            sourceUpstreamID: catalogs.sorted(by: ProcessToolCatalogCodec.catalogSort).first?.upstreamID,
            processIDs: Set(catalogs.map(\.target.processID))
        )
    }

    @discardableResult
    private static func recomputeCanonicalProjection(in state: inout State) -> Bool {
        let previousRaw = state.canonicalToolsCatalogRaw
        let previousSource = state.canonicalSourceUpstreamID
        let activeRoutes = activeRoutes(in: state)
        let exposed = exposedProcessIDs(
            policy: .toolsCatalog,
            nowUptimeNs: state.nowUptimeNs,
            state: state
        )
        if activeRoutes.isEmpty,
           let raw = state.unboundCatalogRaw,
           let source = state.unboundCatalogSource {
            state.canonicalToolsCatalogRaw = raw
            state.canonicalSourceUpstreamID = source
        } else if exposed.isEmpty == false,
           let surface = availableToolCatalogSurface(in: state, processIDs: exposed),
           surface.processIDs == exposed,
           let source = surface.sourceUpstreamID {
            state.canonicalToolsCatalogRaw = surface.rawResult
            state.canonicalSourceUpstreamID = source
        } else {
            state.canonicalToolsCatalogRaw = nil
            state.canonicalSourceUpstreamID = nil
        }
        return previousRaw != state.canonicalToolsCatalogRaw
            || previousSource != state.canonicalSourceUpstreamID
    }

    private static func invalidateAttempts(in state: inout State) -> [ProcessControlPlaneEffect] {
        var effects: [ProcessControlPlaneEffect] = []
        if let attempt = state.unboundAttempt {
            effects.append(contentsOf: attempt.detachedEffects())
            state.unboundAttempt = nil
        }
        for key in state.order {
            guard var record = state.recordsByKey[key], let attempt = record.attempt else { continue }
            effects.append(contentsOf: attempt.detachedEffects())
            record.attempt = nil
            state.recordsByKey[key] = record
        }
        return effects
    }

    private static func invalidateCatalogAttempts(
        in state: inout State
    ) -> [ProcessControlPlaneEffect] {
        var effects: [ProcessControlPlaneEffect] = []
        if let attempt = state.unboundAttempt {
            effects.append(contentsOf: attempt.detachedEffects())
            state.unboundAttempt = nil
        }
        for key in state.order {
            guard var record = state.recordsByKey[key],
                  let attempt = record.attempt,
                  attempt.phase == .loadingCatalog else { continue }
            effects.append(contentsOf: attempt.detachedEffects())
            record.attempt = nil
            state.recordsByKey[key] = record
        }
        return effects
    }

    private static func snapshot(in state: State) -> Snapshot {
        Snapshot(
            catalogEpoch: state.catalogEpoch,
            exposureEpoch: state.exposureEpoch,
            activeRoutes: activeRoutes(in: state),
            catalogProcessIDs: Set(state.catalogsByProcessID.keys),
            canonicalToolsCatalogRaw: state.canonicalToolsCatalogRaw,
            canonicalSourceUpstreamID: state.canonicalSourceUpstreamID,
            attempts: activeRecords(in: state).compactMap { record in
                record.attempt.map { attemptSnapshot(routeID: record.route.id, attempt: $0) }
            } + (state.unboundAttempt.map {
                [attemptSnapshot(routeID: unboundRouteID, attempt: $0)]
            } ?? [])
        )
    }

    private static func attemptSnapshot(routeID: ProcessRouteID, attempt: Attempt) -> AttemptSnapshot {
        AttemptSnapshot(
            routeID: routeID,
            attemptID: attempt.id,
            upstreamID: attempt.upstreamID,
            phase: attempt.phase,
            timeoutCount: (attempt.retryTimeout == nil ? 0 : 1) + (attempt.catalogTimeout == nil ? 0 : 1),
            rpcCount: attempt.rpcHandles.count
        )
    }

    private static func retry(forAttempt attempt: Int) -> Retry {
        let delayMilliseconds: Int64
        switch attempt {
        case ...1: delayMilliseconds = 250
        case 2: delayMilliseconds = 500
        case 3: delayMilliseconds = 1_000
        default: delayMilliseconds = 2_000
        }
        return Retry(
            attempt: attempt,
            delay: .milliseconds(delayMilliseconds),
            delayMilliseconds: delayMilliseconds
        )
    }

    private static let unboundRouteID = ProcessRouteID(
        processID: pid_t.min,
        instanceGeneration: 0
    )

    private static func completeUnboundCatalog(
        _ outcome: CatalogOutcome,
        lease: CatalogLease,
        state: inout State
    ) -> CatalogCommit {
        guard var attempt = state.unboundAttempt,
              attempt.id == lease.attemptID,
              attempt.upstreamID == lease.upstreamID,
              attempt.phase == .loadingCatalog else {
            return .discarded(.attemptSuperseded, .none)
        }
        let effects = attempt.detachedEffects()
        attempt.retryTimeout = nil
        attempt.catalogTimeout = nil
        attempt.rpcHandles.removeAll()
        switch outcome {
        case .usable(let raw, let source):
            state.unboundCatalogRaw = raw
            state.unboundCatalogSource = source
            attempt.phase = .cataloged
        case .unusable:
            state.unboundCatalogRaw = nil
            state.unboundCatalogSource = nil
            attempt.phase = .pending
        case .failed:
            attempt.phase = state.unboundCatalogRaw == nil ? .pending : .cataloged
        }
        state.unboundAttempt = attempt
        let changed = recomputeCanonicalProjection(in: &state)
        return .accepted(
            snapshot(in: state),
            ProcessControlPlaneTransition(
                addedRoutes: [],
                retiredRoutes: [],
                effects: effects,
                publishesToolsListChanged: changed
            )
        )
    }
}

enum AttemptResource: Sendable {
    case retryTimeout(RuntimeScheduledTimeout)
    case catalogTimeout(RuntimeScheduledTimeout)
    case rpc(ControlPlane.RPCHandle)

    fileprivate var cancellationEffect: ProcessControlPlaneEffect {
        switch self {
        case .retryTimeout(let timeout), .catalogTimeout(let timeout):
            return .cancelTimeout(timeout)
        case .rpc(let handle):
            return .cancelRPC(handle)
        }
    }
}

enum ProcessToolCatalogCodec {
    static func toolsByName(in result: JSONValue?) -> [String: JSONValue] {
        guard let result,
              case .object(let object) = result,
              case .array(let tools)? = object["tools"] else { return [:] }
        var toolsByName: [String: JSONValue] = [:]
        for tool in tools {
            guard case .object(let object) = tool,
                  case .string(let name)? = object["name"] else { continue }
            toolsByName[name] = tool
        }
        return toolsByName
    }

    static func hasUsableUpstreamToolsCatalog(in result: JSONValue) -> Bool {
        toolsByName(in: result).isEmpty == false
    }

    static func isOwnerBoundTool(_ tool: JSONValue) -> Bool {
        guard case .object(let object) = tool,
              case .object(let schema)? = object["inputSchema"] else { return false }
        if case .object(let properties)? = schema["properties"],
           properties["tabIdentifier"] != nil || properties["workspacePath"] != nil {
            return true
        }
        if case .array(let required)? = schema["required"] {
            return required.contains { value in
                guard case .string(let key) = value else { return false }
                return key == "tabIdentifier" || key == "workspacePath"
            }
        }
        return false
    }

    static func tool(_ tool: JSONValue, requiresArgument argumentName: String) -> Bool {
        guard case .object(let object) = tool,
              case .object(let schema)? = object["inputSchema"],
              case .array(let required)? = schema["required"] else { return false }
        return required.contains { value in
            guard case .string(let key) = value else { return false }
            return key == argumentName
        }
    }

    static func ownerBoundToolNames(in result: JSONValue) -> Set<String> {
        Set(toolsByName(in: result).compactMap { name, tool in
            isOwnerBoundTool(tool) ? name : nil
        })
    }

    static func toolFingerprintsByName(in result: JSONValue) -> [String: String] {
        toolsByName(in: result).mapValues(fingerprint)
    }

    static func unionToolsListResult(
        from catalogs: [ProcessControlPlaneAuthority.Catalog]
    ) -> JSONValue? {
        guard catalogs.isEmpty == false else { return nil }
        var selected: [String: JSONValue] = [:]
        for catalog in catalogs.sorted(by: catalogSort) {
            for (name, tool) in catalog.toolsByName where selected[name] == nil {
                selected[name] = tool
            }
        }
        let tools = selected.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.compactMap { selected[$0] }
        return .object(["tools": .array(tools)])
    }

    static func schemaConflicts(
        in catalogs: [ProcessControlPlaneAuthority.Catalog]
    ) -> [String] {
        var fingerprints: [String: Set<String>] = [:]
        for catalog in catalogs {
            for (name, value) in catalog.fingerprintsByName {
                fingerprints[name, default: []].insert(value)
            }
        }
        return fingerprints.compactMap { $0.value.count > 1 ? $0.key : nil }.sorted()
    }

    static func catalogSort(
        _ lhs: ProcessControlPlaneAuthority.Catalog,
        _ rhs: ProcessControlPlaneAuthority.Catalog
    ) -> Bool {
        let comparison = lhs.target.xcodeVersion.compare(rhs.target.xcodeVersion, options: [.numeric])
        if comparison != .orderedSame { return comparison == .orderedDescending }
        if lhs.target.appPath != rhs.target.appPath { return lhs.target.appPath < rhs.target.appPath }
        return lhs.target.processID < rhs.target.processID
    }

    private static func fingerprint(_ value: JSONValue) -> String {
        guard JSONSerialization.isValidJSONObject(value.foundationObject),
              let data = try? JSONSerialization.data(
                  withJSONObject: value.foundationObject,
                  options: [.sortedKeys]
              ) else { return String(describing: value.foundationObject) }
        return String(decoding: data, as: UTF8.self)
    }
}
