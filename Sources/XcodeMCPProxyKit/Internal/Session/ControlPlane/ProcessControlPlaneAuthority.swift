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

struct CatalogLoadID: Sendable, Hashable {
    fileprivate let rawValue: Int
}

struct CatalogLease: Sendable, Hashable {
    fileprivate let catalogEpoch: CatalogEpoch
    fileprivate let routeID: ProcessRouteID
    fileprivate let attemptID: CatalogAttemptID
    fileprivate let loadID: CatalogLoadID
    fileprivate let upstreamProof: UpstreamTopologyProof

    var processID: pid_t { routeID.processID }
    var routeIdentity: ProcessRouteID { routeID }
    var attempt: Int { attemptID.rawValue }
    var upstreamID: UpstreamSlotID { upstreamProof.slotID }
    var upstreamIndex: Int { upstreamID.rawValue }
    var topologyProof: UpstreamTopologyProof { upstreamProof }
    var activationLease: ActivationLease {
        ActivationLease(routeID: routeID, attemptID: attemptID, upstreamProof: upstreamProof)
    }
}

struct ActivationLease: Sendable, Hashable {
    let routeID: ProcessRouteID
    let attemptID: CatalogAttemptID
    let upstreamProof: UpstreamTopologyProof

    var upstreamID: UpstreamSlotID { upstreamProof.slotID }
    var processID: pid_t { routeID.processID }
    var upstreamIndex: Int { upstreamID.rawValue }
    var attempt: Int { attemptID.rawValue }
}

enum CatalogInvalidationReason: Sendable {
    case reset
    case routeMembershipChanged
    case exposureChanged
}

enum CatalogOutcome: Sendable {
    case usable(JSONValue, source: UpstreamTopologyProof)
    case unusable
    case failed

    var sourceProof: UpstreamTopologyProof? {
        guard case .usable(_, let source) = self else { return nil }
        return source
    }
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
    case cancelReadinessWaiter(UpstreamReadinessWaiterToken)
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

    enum CooldownScope: Sendable, Hashable {
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
        let upstreamProof: UpstreamTopologyProof
        let rawResult: JSONValue
        let toolsByName: [String: JSONValue]
        let fingerprintsByName: [String: String]
        let ownerBoundToolNames: Set<String>

        var upstreamID: UpstreamSlotID { upstreamProof.slotID }
        var upstreamIndex: Int { upstreamID.rawValue }
        var toolNames: Set<String> { Set(toolsByName.keys) }
    }

    struct AvailableToolCatalog: Sendable {
        let rawResult: JSONValue
        let sourceProof: UpstreamTopologyProof?
        let processIDs: Set<pid_t>

        var sourceUpstreamID: UpstreamSlotID? { sourceProof?.slotID }
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
        let upstreamProof: UpstreamTopologyProof
        var upstreamID: UpstreamSlotID { upstreamProof.slotID }
        let phase: AttemptPhase
        let timeoutCount: Int
        let rpcCount: Int
        let readinessWaiterCount: Int
    }

    struct Snapshot: Sendable {
        let catalogEpoch: CatalogEpoch
        let exposureEpoch: UInt64
        let activeRoutes: [XcodeProcessRoute]
        let catalogProcessIDs: Set<pid_t>
        let catalogEligibilityEstablishedProcessIDs: Set<pid_t>
        let catalogRequiredProcessIDs: Set<pid_t>
        let canonicalToolsCatalogRaw: JSONValue?
        let canonicalSourceProof: UpstreamTopologyProof?
        let attempts: [AttemptSnapshot]

        var canonicalSourceUpstreamID: UpstreamSlotID? { canonicalSourceProof?.slotID }
        var canonicalSourceUpstream: Int? { canonicalSourceUpstreamID?.rawValue }
    }

    struct ActivationStart: Sendable {
        let lease: ActivationLease
        let startedAtUptimeNs: UInt64

        var processID: pid_t { lease.routeID.processID }
        var upstreamIndex: Int { lease.upstreamID.rawValue }
        var attempt: Int { lease.attemptID.rawValue }
    }

    struct ActivationReservation: Sendable {
        fileprivate let lease: ActivationLease
        let readinessToken: UpstreamReadinessWaiterToken

        var processID: pid_t { lease.routeID.processID }
        var upstreamIndex: Int { lease.upstreamID.rawValue }
        var attempt: Int { lease.attemptID.rawValue }
    }

    struct InitializedAttempt: Sendable {
        let lease: CatalogLease
        let startedAtUptimeNs: UInt64
        let transition: ProcessControlPlaneTransition

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
        let activationLease: ActivationLease
    }

    struct CooldownLease: Sendable, Hashable {
        let routeID: ProcessRouteID
        let scope: CooldownScope
        let generation: UInt64
        let deadlineUptimeNs: UInt64
    }

    struct MarkUnavailableResult: Sendable {
        let route: XcodeProcessRoute
        let cooldownLease: CooldownLease
        let transition: ProcessControlPlaneTransition
    }

    struct SupportEligibilityResult: Sendable {
        let transition: ProcessControlPlaneTransition
        let catalogTimeout: AttemptTimeout?
    }

    private enum RouteState: String, Sendable {
        case active
        case retired
    }

    private enum RetryKind: Sendable, Equatable {
        case activation
        case catalog
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
        struct Load: Sendable {
            var rpcHandles: [ControlPlane.RPCHandle] = []

            func detachedEffects() -> [ProcessControlPlaneEffect] {
                rpcHandles.map(ProcessControlPlaneEffect.cancelRPC)
            }
        }

        let id: CatalogAttemptID
        let upstreamProof: UpstreamTopologyProof
        var upstreamID: UpstreamSlotID { upstreamProof.slotID }
        let startedAtUptimeNs: UInt64
        var phase: AttemptPhase
        var readinessToken: UpstreamReadinessWaiterToken?
        var retryTimeout: RuntimeScheduledTimeout?
        var retryKind: RetryKind?
        var nextLoadID: Int
        var loads: [CatalogLoadID: Load]

        mutating func beginLoad() -> CatalogLoadID {
            nextLoadID &+= 1
            let id = CatalogLoadID(rawValue: nextLoadID)
            loads[id] = Load()
            return id
        }

        func detachedEffects() -> [ProcessControlPlaneEffect] {
            var effects: [ProcessControlPlaneEffect] = []
            if let readinessToken { effects.append(.cancelReadinessWaiter(readinessToken)) }
            if let retryTimeout { effects.append(.cancelTimeout(retryTimeout)) }
            for load in loads.values {
                effects.append(contentsOf: load.detachedEffects())
            }
            return effects
        }

        func sourceBoundEffects(
            to proof: UpstreamTopologyProof
        ) -> [ProcessControlPlaneEffect] {
            loads.values.flatMap { load in
                load.rpcHandles.compactMap { handle in
                    handle.isBound(to: proof) ? .cancelRPC(handle) : nil
                }
            }
        }

        func mustInvalidateWhenSourceIsLost(_ proof: UpstreamTopologyProof) -> Bool {
            if upstreamProof == proof {
                return phase != .abandoned
            }
            guard [.pending, .attaching, .initialized, .loadingCatalog].contains(phase) else {
                return false
            }
            return sourceBoundEffects(to: proof).isEmpty == false
        }
    }

    private struct Cooldown: Sendable {
        var generation: UInt64 = 0
        var deadlineUptimeNs: UInt64?
        var timeout: RuntimeScheduledTimeout?

        var isUnavailable: Bool { deadlineUptimeNs != nil }

        mutating func begin(
            deadlineUptimeNs: UInt64
        ) -> (generation: UInt64, effects: [ProcessControlPlaneEffect])? {
            let updatedDeadline = max(self.deadlineUptimeNs ?? 0, deadlineUptimeNs)
            guard updatedDeadline != self.deadlineUptimeNs else { return nil }
            generation &+= 1
            self.deadlineUptimeNs = updatedDeadline
            let effects = timeout.map { [ProcessControlPlaneEffect.cancelTimeout($0)] } ?? []
            timeout = nil
            return (generation, effects)
        }

        func matches(_ lease: CooldownLease) -> Bool {
            generation == lease.generation
                && deadlineUptimeNs == lease.deadlineUptimeNs
        }

        mutating func attach(
            _ timeout: RuntimeScheduledTimeout
        ) -> [ProcessControlPlaneEffect] {
            let effects = self.timeout.map {
                [ProcessControlPlaneEffect.cancelTimeout($0)]
            } ?? []
            self.timeout = timeout
            return effects
        }

        mutating func clear() -> (
            didChange: Bool,
            effects: [ProcessControlPlaneEffect]
        ) {
            guard deadlineUptimeNs != nil || timeout != nil else { return (false, []) }
            generation &+= 1
            deadlineUptimeNs = nil
            let effects = timeout.map { [ProcessControlPlaneEffect.cancelTimeout($0)] } ?? []
            timeout = nil
            return (true, effects)
        }

        mutating func invalidateTimer() -> [ProcessControlPlaneEffect] {
            guard deadlineUptimeNs != nil || timeout != nil else { return [] }
            generation &+= 1
            let effects = timeout.map { [ProcessControlPlaneEffect.cancelTimeout($0)] } ?? []
            timeout = nil
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
        var routeCooldown: Cooldown
        var catalogCooldown: Cooldown
        var admissionRevision: UInt64
        var catalogEligibilityEstablished: Bool
        var nextAttemptID: Int
        var attempt: Attempt?

        func cooldown(_ scope: CooldownScope) -> Cooldown {
            switch scope {
            case .route: routeCooldown
            case .catalog: catalogCooldown
            }
        }

        mutating func withCooldown<Result>(
            _ scope: CooldownScope,
            _ update: (inout Cooldown) -> Result
        ) -> Result {
            switch scope {
            case .route: update(&routeCooldown)
            case .catalog: update(&catalogCooldown)
            }
        }

        mutating func clearAllCooldowns() -> (
            didChange: Bool,
            effects: [ProcessControlPlaneEffect]
        ) {
            let route = routeCooldown.clear()
            let catalog = catalogCooldown.clear()
            return (
                route.didChange || catalog.didChange,
                route.effects + catalog.effects
            )
        }

        mutating func invalidateAllCooldownTimers() -> [ProcessControlPlaneEffect] {
            routeCooldown.invalidateTimer() + catalogCooldown.invalidateTimer()
        }

        func isUnavailable(nowUptimeNs _: UInt64) -> Bool {
            routeCooldown.isUnavailable || catalogCooldown.isUnavailable
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
        var canonicalSourceProof: UpstreamTopologyProof?
        var nextUnboundAttemptID: Int = 0
        var unboundAttempt: Attempt?
        var unboundCatalogRaw: JSONValue?
        var unboundCatalogSource: UpstreamTopologyProof?
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
            let changed = Self.recomputeCanonicalProjection(in: &state)
            return ProcessControlPlaneTransition(
                addedRoutes: [],
                retiredRoutes: [],
                effects: [],
                publishesToolsListChanged: changed
            )
        }
    }

    /// Applies handshake-source eligibility and removes every catalog artifact
    /// tied to a newly unusable exact channel proof. Raw initialize evidence is
    /// retained by CanonicalHandshakeState, but a recovered channel must load a
    /// fresh tools catalog before routing can expose it again.
    func applySupportEligibility(
        usability: UpstreamUsabilitySnapshot,
        newlyIneligibleProofs: Set<UpstreamTopologyProof>,
        nowUptimeNs: UInt64,
        catalogTimeoutProof: UpstreamTopologyProof? = nil
    ) -> SupportEligibilityResult {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNs)
            let didChangeRouteUsability = Self.updateAdmissionRevisions(
                from: state.usability,
                to: usability,
                in: &state
            )
            state.usability = usability
            if didChangeRouteUsability {
                state.exposureEpoch &+= 1
            }

            var effects: [ProcessControlPlaneEffect] = []
            if newlyIneligibleProofs.isEmpty == false {
                for key in state.order {
                    guard var record = state.recordsByKey[key],
                          var attempt = record.attempt else { continue }
                    let lostProofs = newlyIneligibleProofs.filter {
                        attempt.mustInvalidateWhenSourceIsLost($0)
                    }
                    guard lostProofs.isEmpty == false else { continue }
                    let routeUpstreamIDs = Set(
                        record.route.upstreamIndices.map(UpstreamSlotID.init(rawValue:))
                    )
                    let hasUsableFallback = routeUpstreamIDs.isDisjoint(
                        with: usability.recoveryAwareUsableUpstreamIDs
                    ) == false
                    if hasUsableFallback {
                        for proof in lostProofs {
                            effects.append(contentsOf: attempt.sourceBoundEffects(to: proof))
                        }
                        continue
                    }
                    effects.append(contentsOf: attempt.detachedEffects())
                    attempt.phase = .abandoned
                    attempt.readinessToken = nil
                    attempt.retryTimeout = nil
                    attempt.retryKind = nil
                    attempt.loads.removeAll()
                    record.attempt = attempt
                    state.recordsByKey[key] = record
                }
                let invalidCatalogProcessIDs = state.catalogsByProcessID.compactMap {
                    processID, catalog in
                    newlyIneligibleProofs.contains(catalog.upstreamProof) ? processID : nil
                }
                for processID in invalidCatalogProcessIDs {
                    Self.removeCatalog(processID: processID, from: &state)
                }
                if let unboundSource = state.unboundCatalogSource,
                   newlyIneligibleProofs.contains(unboundSource) {
                    state.unboundCatalogRaw = nil
                    state.unboundCatalogSource = nil
                }
            }
            // Invalidate the timed-out channel's old proof-bound attempt and
            // catalog first. The timeout transition then creates the fresh
            // backoff attempt that owns retry; eligibility invalidation must
            // not immediately abandon that replacement attempt.
            let catalogTimeout = catalogTimeoutProof.flatMap {
                Self.handleCatalogChannelTimeout(
                    upstreamProof: $0,
                    nowUptimeNs: nowUptimeNs,
                    state: &state
                )
            }
            let projectionChanged = Self.recomputeCanonicalProjection(in: &state)
            return SupportEligibilityResult(
                transition: ProcessControlPlaneTransition(
                    addedRoutes: [],
                    retiredRoutes: [],
                    effects: effects,
                    publishesToolsListChanged: projectionChanged
                ),
                catalogTimeout: catalogTimeout
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
            let hadActiveRoutes = Self.activeRecords(in: state).isEmpty == false
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
                        let clearedCooldowns = record.clearAllCooldowns()
                        effects.append(contentsOf: clearedCooldowns.effects)
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
                        if record.catalogEligibilityEstablished == false {
                            let replacementIDs = Set(
                                observedRoute.upstreamIndices.map(
                                    UpstreamSlotID.init(rawValue:)
                                )
                            )
                            record.catalogEligibilityEstablished = replacementIDs.isDisjoint(
                                with: usability.recoveryAwareUsableUpstreamIDs
                            ) == false
                        }
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
                record.state = .retired
                record.lastSeenGeneration = state.routeGeneration
                record.missingSinceUptimeNs = nowUptimeNs
                record.lastReconcileReason = reason
                effects.append(contentsOf: record.clearAllCooldowns().effects)
                if let attempt = record.attempt {
                    effects.append(contentsOf: attempt.detachedEffects())
                    record.attempt = nil
                }
                state.recordsByKey[key] = record
                retired.append(record.route)
                Self.removeCatalog(processID: record.route.target.processID, from: &state)
            }

            Self.reorderActiveKeys(orderedKeys, in: &state)
            if hadActiveRoutes == false,
               Self.activeRecords(in: state).isEmpty == false,
               let unboundAttempt = state.unboundAttempt {
                effects.append(contentsOf: unboundAttempt.detachedEffects())
                state.unboundAttempt = nil
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
            guard let cooldown = record.withCooldown(scope, { cooldown in
                cooldown.begin(deadlineUptimeNs: unavailableUntilUptimeNs)
            }) else { return nil }
            state.routeGeneration &+= 1
            state.exposureEpoch &+= 1
            record.lastSeenGeneration = state.routeGeneration
            record.admissionRevision &+= 1
            let effects = record.attempt?.detachedEffects() ?? []
            if var attempt = record.attempt {
                attempt.phase = .abandoned
                attempt.readinessToken = nil
                attempt.retryTimeout = nil
                attempt.retryKind = nil
                attempt.loads.removeAll()
                record.attempt = attempt
            }
            state.recordsByKey[key] = record
            if wasUnavailable == false {
                Self.removeCatalog(
                    processID: record.route.target.processID,
                    from: &state
                )
            }
            let projectionChanged = Self.recomputeCanonicalProjection(in: &state)
            return MarkUnavailableResult(
                route: record.route,
                cooldownLease: CooldownLease(
                    routeID: record.route.id,
                    scope: scope,
                    generation: cooldown.generation,
                    deadlineUptimeNs: unavailableUntilUptimeNs
                ),
                transition: ProcessControlPlaneTransition(
                    addedRoutes: [],
                    retiredRoutes: [],
                    effects: cooldown.effects + effects,
                    publishesToolsListChanged: projectionChanged
                )
            )
        }
    }

    func attachCooldownTimeout(
        _ timeout: RuntimeScheduledTimeout,
        to lease: CooldownLease
    ) -> ProcessControlPlaneTransition {
        state.withLockedValue { state in
            guard let key = Self.key(routeID: lease.routeID, in: state),
                  var record = state.recordsByKey[key],
                  record.cooldown(lease.scope).matches(lease) else {
                return ProcessControlPlaneTransition(
                    addedRoutes: [],
                    retiredRoutes: [],
                    effects: [.cancelTimeout(timeout)],
                    publishesToolsListChanged: false
                )
            }
            let effects = record.withCooldown(lease.scope) { cooldown in
                cooldown.attach(timeout)
            }
            state.recordsByKey[key] = record
            return ProcessControlPlaneTransition(
                addedRoutes: [],
                retiredRoutes: [],
                effects: effects,
                publishesToolsListChanged: false
            )
        }
    }

    func expireCooldown(
        _ lease: CooldownLease,
        nowUptimeNs: UInt64
    ) -> ProcessControlPlaneTransition? {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNs)
            guard nowUptimeNs >= lease.deadlineUptimeNs,
                  let key = Self.key(routeID: lease.routeID, in: state),
                  var record = state.recordsByKey[key],
                  record.cooldown(lease.scope).matches(lease) else { return nil }
            let cleared = record.withCooldown(lease.scope) { $0.clear() }
            state.exposureEpoch &+= 1
            record.admissionRevision &+= 1
            state.recordsByKey[key] = record
            let projectionChanged = Self.recomputeCanonicalProjection(in: &state)
            return ProcessControlPlaneTransition(
                addedRoutes: [],
                retiredRoutes: [],
                effects: cleared.effects,
                publishesToolsListChanged: projectionChanged
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
            var effects: [ProcessControlPlaneEffect] = []
            var didClear = false
            switch scope {
            case .route:
                let cleared = record.withCooldown(.route) { $0.clear() }
                didClear = cleared.didChange
                effects = cleared.effects
            case .catalog:
                let cleared = record.clearAllCooldowns()
                didClear = cleared.didChange
                effects = cleared.effects
            }
            let after = record.isUnavailable(nowUptimeNs: nowUptimeNs)
            guard didClear else { return .none }
            record.admissionRevision &+= 1
            if before == after {
                state.recordsByKey[key] = record
                return ProcessControlPlaneTransition(
                    addedRoutes: [],
                    retiredRoutes: [],
                    effects: effects,
                    publishesToolsListChanged: false
                )
            }
            state.routeGeneration &+= 1
            state.exposureEpoch &+= 1
            state.recordsByKey[key] = record
            let projectionChanged = Self.recomputeCanonicalProjection(in: &state)
            return ProcessControlPlaneTransition(
                addedRoutes: [],
                retiredRoutes: [],
                effects: effects,
                publishesToolsListChanged: projectionChanged
            )
        }
    }

    func detachAllCooldownTimeouts() -> ProcessControlPlaneTransition {
        state.withLockedValue { state in
            var effects: [ProcessControlPlaneEffect] = []
            for key in state.order {
                guard var record = state.recordsByKey[key] else { continue }
                effects.append(contentsOf: record.invalidateAllCooldownTimers())
                state.recordsByKey[key] = record
            }
            return ProcessControlPlaneTransition(
                addedRoutes: [],
                retiredRoutes: [],
                effects: effects,
                publishesToolsListChanged: false
            )
        }
    }

    func reserveActivation(
        routeID: ProcessRouteID,
        upstreamProof: UpstreamTopologyProof,
        nowUptimeNs: UInt64,
        readinessToken: UpstreamReadinessWaiterToken
    ) -> (ActivationReservation, ProcessControlPlaneTransition)? {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNs)
            guard let key = Self.key(routeID: routeID, in: state),
                  var record = state.recordsByKey[key],
                  record.route.upstreamIndices.contains(upstreamProof.slotID.rawValue) else {
                return nil
            }
            if let attempt = record.attempt,
               [.pending, .attaching, .initialized, .loadingCatalog, .backoff]
                .contains(attempt.phase) {
                return nil
            }
            let effects = record.attempt?.detachedEffects() ?? []
            record.nextAttemptID &+= 1
            let attempt = Attempt(
                id: CatalogAttemptID(rawValue: record.nextAttemptID),
                upstreamProof: upstreamProof,
                startedAtUptimeNs: nowUptimeNs,
                phase: .pending,
                readinessToken: readinessToken,
                retryTimeout: nil,
                retryKind: nil,
                nextLoadID: 0,
                loads: [:]
            )
            record.attempt = attempt
            state.recordsByKey[key] = record
            let reservation = ActivationReservation(
                lease: ActivationLease(
                    routeID: routeID,
                    attemptID: attempt.id,
                    upstreamProof: attempt.upstreamProof
                ),
                readinessToken: readinessToken
            )
            return (
                reservation,
                ProcessControlPlaneTransition(
                    addedRoutes: [], retiredRoutes: [], effects: effects,
                    publishesToolsListChanged: false
                )
            )
        }
    }

    func beginAttaching(
        _ reservation: ActivationReservation,
        nowUptimeNs: UInt64
    ) -> (ActivationStart, ProcessControlPlaneTransition)? {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNs)
            let lease = reservation.lease
            guard let key = Self.key(routeID: lease.routeID, in: state),
                  var record = state.recordsByKey[key],
                  record.route.upstreamIndices.contains(lease.upstreamID.rawValue),
                  var attempt = record.attempt,
                  attempt.id == lease.attemptID,
                  attempt.upstreamID == lease.upstreamID,
                  attempt.phase == .pending,
                  attempt.readinessToken === reservation.readinessToken else { return nil }
            attempt.phase = .attaching
            attempt.readinessToken = nil
            record.attempt = attempt
            state.recordsByKey[key] = record
            return (
                ActivationStart(
                    lease: ActivationLease(
                        routeID: lease.routeID,
                        attemptID: attempt.id,
                        upstreamProof: attempt.upstreamProof
                    ),
                    startedAtUptimeNs: attempt.startedAtUptimeNs
                ),
                .none
            )
        }
    }

    func cancelActivation(
        _ start: ActivationStart
    ) -> ProcessControlPlaneTransition {
        state.withLockedValue { state in
            let lease = start.lease
            guard let key = Self.key(routeID: lease.routeID, in: state),
                  var record = state.recordsByKey[key],
                  let attempt = record.attempt,
                  attempt.id == lease.attemptID,
                  attempt.upstreamID == lease.upstreamID,
                  attempt.phase == .attaching else { return .none }
            let effects = attempt.detachedEffects()
            record.attempt = nil
            state.recordsByKey[key] = record
            return ProcessControlPlaneTransition(
                addedRoutes: [],
                retiredRoutes: [],
                effects: effects,
                publishesToolsListChanged: false
            )
        }
    }

    func validate(_ start: ActivationStart) -> Bool {
        state.withLockedValue { state in
            let lease = start.lease
            guard let record = Self.record(routeID: lease.routeID, in: state),
                  record.route.upstreamIndices.contains(lease.upstreamID.rawValue),
                  let attempt = record.attempt else { return false }
            return attempt.id == lease.attemptID
                && attempt.upstreamID == lease.upstreamID
                && attempt.phase == .attaching
        }
    }

    func attachRetryTimeout(
        _ timeout: RuntimeScheduledTimeout,
        to lease: ActivationLease
    ) -> ProcessControlPlaneTransition {
        state.withLockedValue { state in
            guard let key = Self.key(routeID: lease.routeID, in: state),
                  var record = state.recordsByKey[key],
                  var attempt = record.attempt,
                  attempt.id == lease.attemptID,
                  attempt.upstreamID == lease.upstreamID,
                  attempt.phase == .backoff,
                  attempt.retryKind == .activation else {
                return ProcessControlPlaneTransition(
                    addedRoutes: [],
                    retiredRoutes: [],
                    effects: [.cancelTimeout(timeout)],
                    publishesToolsListChanged: false
                )
            }
            let effects = attempt.retryTimeout.map {
                [ProcessControlPlaneEffect.cancelTimeout($0)]
            } ?? []
            attempt.retryTimeout = timeout
            record.attempt = attempt
            state.recordsByKey[key] = record
            return ProcessControlPlaneTransition(
                addedRoutes: [],
                retiredRoutes: [],
                effects: effects,
                publishesToolsListChanged: false
            )
        }
    }

    func markInitialized(
        routeID: ProcessRouteID,
        upstreamProof: UpstreamTopologyProof
    ) -> InitializedAttempt? {
        state.withLockedValue { state in
            guard let key = Self.key(routeID: routeID, in: state),
                  var record = state.recordsByKey[key],
                  var attempt = record.attempt,
                  attempt.upstreamProof == upstreamProof,
                  [.attaching, .loadingCatalog].contains(attempt.phase) else { return nil }
            attempt.retryKind = nil
            attempt.phase = .initialized
            let loadID = attempt.beginLoad()
            record.attempt = attempt
            state.recordsByKey[key] = record
            return InitializedAttempt(
                lease: Self.lease(
                    for: attempt,
                    loadID: loadID,
                    routeID: routeID,
                    catalogEpoch: state.catalogEpoch
                ),
                startedAtUptimeNs: attempt.startedAtUptimeNs,
                transition: ProcessControlPlaneTransition(
                    addedRoutes: [],
                    retiredRoutes: [],
                    effects: [],
                    publishesToolsListChanged: false
                )
            )
        }
    }

    func markChannelInitialized(
        routeID: ProcessRouteID,
        upstreamProof: UpstreamTopologyProof
    ) -> Int? {
        state.withLockedValue { state in
            guard let key = Self.key(routeID: routeID, in: state),
                  var record = state.recordsByKey[key],
                  var attempt = record.attempt,
                  attempt.upstreamProof == upstreamProof,
                  attempt.phase == .attaching else { return nil }
            attempt.retryKind = nil
            attempt.phase = .initialized
            record.attempt = attempt
            state.recordsByKey[key] = record
            return attempt.id.rawValue
        }
    }

    func beginCatalogAttempt(
        routeID: ProcessRouteID,
        preferredUpstreamProof: UpstreamTopologyProof,
        nowUptimeNanoseconds: UInt64
    ) -> (CatalogLease, ProcessControlPlaneTransition)? {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNanoseconds)
            guard let key = Self.key(routeID: routeID, in: state),
                  var record = state.recordsByKey[key],
                  record.route.upstreamIndices.contains(
                    preferredUpstreamProof.slotID.rawValue
                  ) else { return nil }
            if var attempt = record.attempt,
               [.pending, .attaching, .initialized, .loadingCatalog].contains(attempt.phase) {
                let effects = attempt.readinessToken.map {
                    [ProcessControlPlaneEffect.cancelReadinessWaiter($0)]
                } ?? []
                attempt.readinessToken = nil
                attempt.retryKind = nil
                attempt.phase = .loadingCatalog
                let loadID = attempt.beginLoad()
                record.attempt = attempt
                state.recordsByKey[key] = record
                return (
                    Self.lease(
                        for: attempt,
                        loadID: loadID,
                        routeID: routeID,
                        catalogEpoch: state.catalogEpoch
                    ),
                    ProcessControlPlaneTransition(
                        addedRoutes: [],
                        retiredRoutes: [],
                        effects: effects,
                        publishesToolsListChanged: false
                    )
                )
            }
            let effects = record.attempt?.detachedEffects() ?? []
            record.nextAttemptID &+= 1
            var attempt = Attempt(
                id: CatalogAttemptID(rawValue: record.nextAttemptID),
                upstreamProof: preferredUpstreamProof,
                startedAtUptimeNs: nowUptimeNanoseconds,
                phase: .loadingCatalog,
                readinessToken: nil,
                retryTimeout: nil,
                retryKind: nil,
                nextLoadID: 0,
                loads: [:]
            )
            let loadID = attempt.beginLoad()
            record.attempt = attempt
            state.recordsByKey[key] = record
            return (
                Self.lease(
                    for: attempt,
                    loadID: loadID,
                    routeID: routeID,
                    catalogEpoch: state.catalogEpoch
                ),
                ProcessControlPlaneTransition(
                    addedRoutes: [], retiredRoutes: [], effects: effects,
                    publishesToolsListChanged: false
                )
            )
        }
    }

    func beginUnboundCatalogAttempt(
        preferredUpstreamProof: UpstreamTopologyProof,
        nowUptimeNanoseconds: UInt64
    ) -> (CatalogLease, ProcessControlPlaneTransition) {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNanoseconds)
            if var attempt = state.unboundAttempt,
               attempt.phase == .loadingCatalog,
               attempt.upstreamProof == preferredUpstreamProof {
                let loadID = attempt.beginLoad()
                state.unboundAttempt = attempt
                return (
                    Self.lease(
                        for: attempt,
                        loadID: loadID,
                        routeID: Self.unboundRouteID,
                        catalogEpoch: state.catalogEpoch
                    ),
                    .none
                )
            }
            let effects = state.unboundAttempt?.detachedEffects() ?? []
            state.nextUnboundAttemptID &+= 1
            var attempt = Attempt(
                id: CatalogAttemptID(rawValue: state.nextUnboundAttemptID),
                upstreamProof: preferredUpstreamProof,
                startedAtUptimeNs: nowUptimeNanoseconds,
                phase: .loadingCatalog,
                readinessToken: nil,
                retryTimeout: nil,
                retryKind: nil,
                nextLoadID: 0,
                loads: [:]
            )
            let loadID = attempt.beginLoad()
            state.unboundAttempt = attempt
            return (
                Self.lease(
                    for: attempt,
                    loadID: loadID,
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
            if lease.routeID == Self.unboundRouteID {
                guard var attempt = state.unboundAttempt,
                      Self.matches(lease: lease, attempt: attempt, state: state),
                      let effects = Self.attach(
                          resource,
                          loadID: lease.loadID,
                          to: &attempt
                      ) else {
                    return ProcessControlPlaneTransition(
                        addedRoutes: [], retiredRoutes: [],
                        effects: [resource.cancellationEffect],
                        publishesToolsListChanged: false
                    )
                }
                state.unboundAttempt = attempt
                return ProcessControlPlaneTransition(
                    addedRoutes: [], retiredRoutes: [], effects: effects,
                    publishesToolsListChanged: false
                )
            }
            guard let key = Self.key(routeID: lease.routeID, in: state),
                  var record = state.recordsByKey[key],
                  var attempt = record.attempt,
                  Self.matches(lease: lease, attempt: attempt, state: state),
                  let effects = Self.attach(
                      resource,
                      loadID: lease.loadID,
                      to: &attempt
                  ) else {
                return ProcessControlPlaneTransition(
                    addedRoutes: [], retiredRoutes: [],
                    effects: [resource.cancellationEffect],
                    publishesToolsListChanged: false
                )
            }
            record.attempt = attempt
            state.recordsByKey[key] = record
            return ProcessControlPlaneTransition(
                addedRoutes: [], retiredRoutes: [], effects: effects,
                publishesToolsListChanged: false
            )
        }
    }

    func validateCatalogLoad(_ lease: CatalogLease) -> Bool {
        state.withLockedValue { state in
            guard lease.catalogEpoch == state.catalogEpoch else { return false }
            let attempt: Attempt?
            if lease.routeID == Self.unboundRouteID {
                attempt = state.unboundAttempt
            } else {
                attempt = Self.record(routeID: lease.routeID, in: state)?.attempt
            }
            guard let attempt,
                  attempt.id == lease.attemptID,
                  attempt.upstreamID == lease.upstreamID,
                  [.attaching, .initialized, .loadingCatalog].contains(attempt.phase)
            else { return false }
            return attempt.loads[lease.loadID] != nil
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
            guard [.attaching, .initialized, .loadingCatalog].contains(attempt.phase),
                  attempt.loads[lease.loadID] != nil else {
                return .discarded(.attemptNotLoading, .none)
            }

            var effects: [ProcessControlPlaneEffect] = []
            var removesAttempt = false
            let hadCatalog = state.catalogsByProcessID[record.route.target.processID] != nil
            let wasUnavailable = record.isUnavailable(nowUptimeNs: state.nowUptimeNs)
            switch outcome {
            case .usable(let rawResult, let source):
                effects.append(contentsOf: attempt.detachedEffects())
                attempt.readinessToken = nil
                attempt.retryTimeout = nil
                attempt.retryKind = nil
                attempt.loads.removeAll()
                guard record.route.upstreamIndices.contains(source.slotID.rawValue) else {
                    return .discarded(.upstreamReplaced, .none)
                }
                let catalog = Self.makeCatalog(
                    route: record.route,
                    upstreamProof: source,
                    rawResult: rawResult
                )
                state.catalogsByProcessID[record.route.target.processID] = catalog
                for upstreamIndex in record.route.upstreamIndices {
                    state.processIDByUpstreamID[UpstreamSlotID(rawValue: upstreamIndex)] =
                        record.route.target.processID
                }
                effects.append(contentsOf: record.clearAllCooldowns().effects)
                attempt.phase = .cataloged
            case .unusable:
                effects = attempt.loads.removeValue(forKey: lease.loadID)?
                    .detachedEffects() ?? []
                if attempt.loads.isEmpty {
                    attempt.readinessToken = nil
                    attempt.retryTimeout = nil
                    Self.removeCatalog(processID: record.route.target.processID, from: &state)
                    attempt.phase = .pending
                    attempt.retryKind = .catalog
                } else {
                    attempt.phase = .loadingCatalog
                }
            case .failed:
                effects = attempt.loads.removeValue(forKey: lease.loadID)?
                    .detachedEffects() ?? []
                if attempt.loads.isEmpty {
                    effects.append(contentsOf: attempt.detachedEffects())
                    attempt.readinessToken = nil
                    attempt.retryTimeout = nil
                    attempt.retryKind = nil
                    attempt.phase = hadCatalog ? .cataloged : .abandoned
                    removesAttempt = true
                } else {
                    attempt.phase = .loadingCatalog
                }
            }
            if removesAttempt {
                record.attempt = nil
            } else {
                record.attempt = attempt
            }
            if wasUnavailable && record.isUnavailable(nowUptimeNs: state.nowUptimeNs) == false {
                state.routeGeneration &+= 1
                state.exposureEpoch &+= 1
                record.admissionRevision &+= 1
            }
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
            var effects = Self.invalidateAttempts(in: &state)
            state.catalogEpoch = CatalogEpoch(rawValue: state.catalogEpoch.rawValue &+ 1)
            state.exposureEpoch &+= 1
            state.catalogsByProcessID.removeAll()
            state.processIDByUpstreamID.removeAll()
            state.canonicalToolsCatalogRaw = nil
            state.canonicalSourceProof = nil
            state.unboundCatalogRaw = nil
            state.unboundCatalogSource = nil
            state.usability = .empty
            for key in state.order {
                guard var record = state.recordsByKey[key] else { continue }
                effects.append(contentsOf: record.clearAllCooldowns().effects)
                record.attempt = nil
                record.catalogEligibilityEstablished = false
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

    func invalidateCatalogSource(
        processID: pid_t,
        source proof: UpstreamTopologyProof
    ) -> ProcessControlPlaneTransition {
        state.withLockedValue { state in
            var effects: [ProcessControlPlaneEffect] = []
            if let key = Self.activeRecords(in: state).first(where: {
                $0.route.target.processID == processID
            })?.key,
               var record = state.recordsByKey[key],
               let attempt = record.attempt,
               attempt.mustInvalidateWhenSourceIsLost(proof) {
                effects = attempt.detachedEffects()
                record.attempt = nil
                state.recordsByKey[key] = record
            }
            guard let catalog = state.catalogsByProcessID[processID],
                  catalog.upstreamProof == proof else {
                guard effects.isEmpty == false else { return .none }
                return ProcessControlPlaneTransition(
                    addedRoutes: [],
                    retiredRoutes: [],
                    effects: effects,
                    publishesToolsListChanged: false
                )
            }

            Self.removeCatalog(processID: processID, from: &state)
            let projectionChanged = Self.recomputeCanonicalProjection(in: &state)
            return ProcessControlPlaneTransition(
                addedRoutes: [],
                retiredRoutes: [],
                effects: effects,
                publishesToolsListChanged: projectionChanged
            )
        }
    }

    func availableToolCatalogSurface(processIDs: Set<pid_t>? = nil) -> AvailableToolCatalog? {
        state.withLockedValue { Self.availableToolCatalogSurface(in: $0, processIDs: processIDs) }
    }

    func canonicalToolsCatalogRaw() -> JSONValue? {
        state.withLockedValue(\.canonicalToolsCatalogRaw)
    }

    func canonicalSourceUpstream() -> Int? {
        state.withLockedValue { $0.canonicalSourceProof?.slotID.rawValue }
    }

    func canonicalSourceProof() -> UpstreamTopologyProof? {
        state.withLockedValue(\.canonicalSourceProof)
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

    func abandon(processID: pid_t) -> ProcessControlPlaneTransition {
        state.withLockedValue { state in
            guard let key = Self.activeRecords(in: state).first(where: {
                $0.route.target.processID == processID
            })?.key,
            var record = state.recordsByKey[key] else { return .none }
            let effects = record.attempt?.detachedEffects() ?? []
            if var attempt = record.attempt {
                attempt.phase = .abandoned
                attempt.readinessToken = nil
                attempt.retryTimeout = nil
                attempt.retryKind = nil
                attempt.loads.removeAll()
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
        lease: CatalogLease
    ) -> (
        lease: CatalogLease,
        retry: Retry,
        transition: ProcessControlPlaneTransition
    )? {
        state.withLockedValue { state in
            guard lease.catalogEpoch == state.catalogEpoch,
                  let key = Self.key(routeID: lease.routeID, in: state),
                  let record = state.recordsByKey[key],
                  var attempt = record.attempt,
                  attempt.id == lease.attemptID,
                  attempt.upstreamID == lease.upstreamID,
                  attempt.phase == .pending,
                  attempt.retryKind == .catalog else { return nil }
            let readinessToken = attempt.readinessToken
            attempt.readinessToken = nil
            attempt.phase = .backoff
            var updated = record
            updated.attempt = attempt
            state.recordsByKey[key] = updated
            return (
                Self.lease(
                    for: attempt,
                    loadID: lease.loadID,
                    routeID: lease.routeID,
                    catalogEpoch: state.catalogEpoch
                ),
                Self.retry(forAttempt: attempt.id.rawValue),
                ProcessControlPlaneTransition(
                    addedRoutes: [],
                    retiredRoutes: [],
                    effects: readinessToken.map {
                        [.cancelReadinessWaiter($0)]
                    } ?? [],
                    publishesToolsListChanged: false
                )
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

    func retireRoute(
        routeID: ProcessRouteID,
        reason: String,
        nowUptimeNs: UInt64
    ) -> ProcessControlPlaneTransition {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNs)
            guard let key = Self.key(routeID: routeID, in: state),
                  var record = state.recordsByKey[key] else { return .none }
            state.routeGeneration &+= 1
            state.exposureEpoch &+= 1
            record.state = .retired
            record.lastSeenGeneration = state.routeGeneration
            record.missingSinceUptimeNs = nowUptimeNs
            record.lastReconcileReason = reason
            record.admissionRevision &+= 1
            var effects = record.attempt?.detachedEffects() ?? []
            effects.append(contentsOf: record.clearAllCooldowns().effects)
            record.attempt = nil
            state.recordsByKey[key] = record
            Self.removeCatalog(processID: record.route.target.processID, from: &state)
            let projectionChanged = Self.recomputeCanonicalProjection(in: &state)
            return ProcessControlPlaneTransition(
                addedRoutes: [],
                retiredRoutes: [record.route],
                effects: effects,
                publishesToolsListChanged: projectionChanged
            )
        }
    }

    func handleChannelInitializeTimeout(
        _ lease: ActivationLease
    ) -> AttemptTimeout? {
        finishActivationAttemptForRetry(
            lease: lease,
            allowedPhases: [.attaching, .initialized]
        )
    }

    private static func handleCatalogChannelTimeout(
        upstreamProof: UpstreamTopologyProof,
        nowUptimeNs: UInt64,
        state: inout State
    ) -> AttemptTimeout? {
        state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNs)
        let upstreamIndex = upstreamProof.slotID.rawValue
        guard let key = activeKey(upstreamIndex: upstreamIndex, in: state),
              var record = state.recordsByKey[key] else { return nil }

        let effects: [ProcessControlPlaneEffect]
        let retryOrdinal: Int
        let attempt: Attempt
        if var current = record.attempt,
           current.upstreamProof == upstreamProof,
           [.pending, .attaching, .initialized, .loadingCatalog, .backoff]
            .contains(current.phase) {
            effects = current.detachedEffects()
            retryOrdinal = current.id.rawValue
            current.readinessToken = nil
            current.retryTimeout = nil
            current.retryKind = .activation
            current.loads.removeAll()
            current.phase = .backoff
            attempt = current
        } else {
            effects = record.attempt?.detachedEffects() ?? []
            retryOrdinal = max(1, record.nextAttemptID)
            record.nextAttemptID &+= 1
            attempt = Attempt(
                id: CatalogAttemptID(rawValue: record.nextAttemptID),
                upstreamProof: upstreamProof,
                startedAtUptimeNs: nowUptimeNs,
                phase: .backoff,
                readinessToken: nil,
                retryTimeout: nil,
                retryKind: .activation,
                nextLoadID: 0,
                loads: [:]
            )
        }
        record.attempt = attempt
        state.recordsByKey[key] = record
        let lease = ActivationLease(
            routeID: record.route.id,
            attemptID: attempt.id,
            upstreamProof: attempt.upstreamProof
        )
        return AttemptTimeout(
            transition: ProcessControlPlaneTransition(
                addedRoutes: [],
                retiredRoutes: [],
                effects: effects,
                publishesToolsListChanged: false
            ),
            retry: retry(forAttempt: retryOrdinal),
            activationLease: lease
        )
    }

    func handleRetryFired(_ lease: CatalogLease) -> Bool {
        state.withLockedValue { state in
            guard lease.catalogEpoch == state.catalogEpoch,
            let key = Self.key(routeID: lease.routeID, in: state),
            var record = state.recordsByKey[key], var attempt = record.attempt,
            attempt.id == lease.attemptID,
            attempt.upstreamID == lease.upstreamID,
            attempt.phase == .backoff,
            attempt.retryKind == .catalog else { return false }
            attempt.retryTimeout = nil
            attempt.phase = .pending
            record.attempt = attempt
            state.recordsByKey[key] = record
            return true
        }
    }

    func handleActivationRetryFired(_ lease: ActivationLease) -> Bool {
        state.withLockedValue { state in
            guard let key = Self.key(routeID: lease.routeID, in: state),
            var record = state.recordsByKey[key], let attempt = record.attempt,
            attempt.id == lease.attemptID,
            attempt.upstreamID == lease.upstreamID,
            attempt.phase == .backoff,
            attempt.retryKind == .activation else { return false }
            record.attempt = nil
            state.recordsByKey[key] = record
            return true
        }
    }

    func prepareFreshActivationRetry(
        routeID: ProcessRouteID,
        upstreamProof: UpstreamTopologyProof,
        nowUptimeNs: UInt64
    ) -> (ActivationLease, Retry, ProcessControlPlaneTransition)? {
        state.withLockedValue { state in
            state.nowUptimeNs = max(state.nowUptimeNs, nowUptimeNs)
            guard let key = Self.key(routeID: routeID, in: state),
                  var record = state.recordsByKey[key],
                  record.route.upstreamIndices.contains(upstreamProof.slotID.rawValue) else {
                return nil
            }
            let effects = record.attempt?.detachedEffects() ?? []
            let retryOrdinal = max(1, record.nextAttemptID)
            record.nextAttemptID &+= 1
            let attempt = Attempt(
                id: CatalogAttemptID(rawValue: record.nextAttemptID),
                upstreamProof: upstreamProof,
                startedAtUptimeNs: nowUptimeNs,
                phase: .backoff,
                readinessToken: nil,
                retryTimeout: nil,
                retryKind: .activation,
                nextLoadID: 0,
                loads: [:]
            )
            record.attempt = attempt
            state.recordsByKey[key] = record
            return (
                ActivationLease(
                    routeID: routeID,
                    attemptID: attempt.id,
                    upstreamProof: attempt.upstreamProof
                ),
                Self.retry(forAttempt: retryOrdinal),
                ProcessControlPlaneTransition(
                    addedRoutes: [], retiredRoutes: [], effects: effects,
                    publishesToolsListChanged: false
                )
            )
        }
    }

    func debugRouteSnapshots(
        usableSlotCount: @Sendable (XcodeProcessRoute) -> Int
    ) -> [ProxyDebug.ProcessRouteSnapshot] {
        let records = state.withLockedValue { state in
            state.order.compactMap { key -> (RouteRecord, Bool, UInt64)? in
                guard let record = state.recordsByKey[key] else { return nil }
                let hasCatalog = state.catalogsByProcessID[record.route.target.processID] != nil
                return (record, hasCatalog, state.nowUptimeNs)
            }
        }
        return records.map { record, hasCatalog, nowUptimeNs in
            let toolsCatalogState: String
            if record.state == .retired {
                toolsCatalogState = "retired"
            } else if hasCatalog {
                toolsCatalogState = "available"
            } else if record.isUnavailable(nowUptimeNs: nowUptimeNs) {
                toolsCatalogState = "unavailable"
            } else if let attempt = record.attempt,
                      [.pending, .attaching, .initialized, .loadingCatalog, .backoff]
                        .contains(attempt.phase) {
                toolsCatalogState = "pending"
            } else {
                toolsCatalogState = "missing"
            }
            return ProxyDebug.ProcessRouteSnapshot(
                state: record.state.rawValue,
                processID: record.route.target.processID,
                appPath: record.route.target.appPath,
                developerDir: record.route.target.developerDir,
                mcpbridgePath: record.route.target.mcpbridgePath,
                xcodeVersion: record.route.target.xcodeVersion,
                upstreamIndices: record.route.upstreamIndices,
                usableSlotCount: usableSlotCount(record.route),
                toolsCatalogState: toolsCatalogState,
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
                    isCanonicalSource: catalog.upstreamProof == state.canonicalSourceProof,
                    exposurePolicy: "available_route_catalog_surface",
                    missingFromExposedCatalog: Array(toolNames.subtracting(exposedNames)).sorted(),
                    extraBeyondExposedCatalog: Array(exposedNames.subtracting(toolNames)).sorted(),
                    schemaConflicts: conflicts
                )
            }
        }
    }

    private func finishActivationAttemptForRetry(
        lease: ActivationLease,
        allowedPhases: Set<AttemptPhase>
    ) -> AttemptTimeout? {
        state.withLockedValue { state in
            guard let key = Self.key(routeID: lease.routeID, in: state),
                  var record = state.recordsByKey[key],
                  var attempt = record.attempt,
                  attempt.id == lease.attemptID,
                  attempt.upstreamID == lease.upstreamID,
                  allowedPhases.contains(attempt.phase) else { return nil }
            let effects = attempt.detachedEffects()
            attempt.readinessToken = nil
            attempt.retryTimeout = nil
            attempt.retryKind = .activation
            attempt.loads.removeAll()
            attempt.phase = .backoff
            record.attempt = attempt
            state.recordsByKey[key] = record
            return AttemptTimeout(
                transition: ProcessControlPlaneTransition(
                    addedRoutes: [], retiredRoutes: [], effects: effects,
                    publishesToolsListChanged: false
                ),
                retry: Self.retry(forAttempt: attempt.id.rawValue),
                activationLease: lease
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
            routeCooldown: Cooldown(),
            catalogCooldown: Cooldown(),
            admissionRevision: 0,
            catalogEligibilityEstablished: Set(
                route.upstreamIndices.map(UpstreamSlotID.init(rawValue:))
            ).isDisjoint(with: state.usability.recoveryAwareUsableUpstreamIDs) == false,
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
            let establishesCatalogEligibility =
                record.catalogEligibilityEstablished == false && nextRecovery.isEmpty == false
            guard previousSnapshot != nextSnapshot
                    || previousRecovery != nextRecovery
                    || establishesCatalogEligibility else {
                continue
            }
            if establishesCatalogEligibility {
                record.catalogEligibilityEstablished = true
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
        loadID: CatalogLoadID,
        routeID: ProcessRouteID,
        catalogEpoch: CatalogEpoch
    ) -> CatalogLease {
        CatalogLease(
            catalogEpoch: catalogEpoch,
            routeID: routeID,
            attemptID: attempt.id,
            loadID: loadID,
            upstreamProof: attempt.upstreamProof
        )
    }

    private static func matches(lease: CatalogLease, attempt: Attempt, state: State) -> Bool {
        lease.catalogEpoch == state.catalogEpoch
            && lease.attemptID == attempt.id
            && lease.upstreamID == attempt.upstreamID
    }

    private static func attach(
        _ resource: AttemptResource,
        loadID: CatalogLoadID,
        to attempt: inout Attempt
    ) -> [ProcessControlPlaneEffect]? {
        var effects: [ProcessControlPlaneEffect] = []
        switch resource {
        case .retryTimeout(let timeout):
            guard attempt.phase == .backoff,
                  attempt.retryKind == .catalog else { return nil }
            if let previous = attempt.retryTimeout {
                effects.append(.cancelTimeout(previous))
            }
            attempt.retryTimeout = timeout
        case .rpc(let handle):
            guard attempt.phase == .loadingCatalog,
                  var load = attempt.loads[loadID] else { return nil }
            load.rpcHandles.append(handle)
            attempt.loads[loadID] = load
        }
        return effects
    }

    private static func makeCatalog(
        route: XcodeProcessRoute,
        upstreamProof: UpstreamTopologyProof,
        rawResult: JSONValue
    ) -> Catalog {
        Catalog(
            routeID: route.id,
            target: route.target,
            upstreamProof: upstreamProof,
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
            sourceProof: catalogs.sorted(by: ProcessToolCatalogCodec.catalogSort).first?.upstreamProof,
            processIDs: Set(catalogs.map(\.target.processID))
        )
    }

    private static func catalogEligibilityEstablishedProcessIDs(
        in state: State
    ) -> Set<pid_t> {
        Set(activeRecords(in: state).compactMap { record in
            record.catalogEligibilityEstablished
                ? record.route.target.processID
                : nil
        })
    }

    private static func catalogRequiredProcessIDs(in state: State) -> Set<pid_t> {
        Set(activeRecords(in: state).compactMap { record in
            record.catalogEligibilityEstablished
                && record.isUnavailable(nowUptimeNs: state.nowUptimeNs) == false
                ? record.route.target.processID
                : nil
        })
    }

    @discardableResult
    private static func recomputeCanonicalProjection(in state: inout State) -> Bool {
        let previousRaw = state.canonicalToolsCatalogRaw
        let previousSource = state.canonicalSourceProof
        let activeRoutes = activeRoutes(in: state)
        let requiredProcessIDs = catalogRequiredProcessIDs(in: state)
        if activeRoutes.isEmpty,
           let raw = state.unboundCatalogRaw,
           let source = state.unboundCatalogSource {
            state.canonicalToolsCatalogRaw = raw
            state.canonicalSourceProof = source
        } else if requiredProcessIDs.isEmpty == false,
           let surface = availableToolCatalogSurface(
               in: state,
               processIDs: requiredProcessIDs
           ),
           surface.processIDs == requiredProcessIDs,
           let source = surface.sourceProof {
            state.canonicalToolsCatalogRaw = surface.rawResult
            state.canonicalSourceProof = source
        } else {
            state.canonicalToolsCatalogRaw = nil
            state.canonicalSourceProof = nil
        }
        return previousRaw != state.canonicalToolsCatalogRaw
            || previousSource != state.canonicalSourceProof
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

    private static func snapshot(in state: State) -> Snapshot {
        Snapshot(
            catalogEpoch: state.catalogEpoch,
            exposureEpoch: state.exposureEpoch,
            activeRoutes: activeRoutes(in: state),
            catalogProcessIDs: Set(state.catalogsByProcessID.keys),
            catalogEligibilityEstablishedProcessIDs:
                catalogEligibilityEstablishedProcessIDs(in: state),
            catalogRequiredProcessIDs: catalogRequiredProcessIDs(in: state),
            canonicalToolsCatalogRaw: state.canonicalToolsCatalogRaw,
            canonicalSourceProof: state.canonicalSourceProof,
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
            upstreamProof: attempt.upstreamProof,
            phase: attempt.phase,
            timeoutCount: attempt.retryTimeout == nil ? 0 : 1,
            rpcCount: attempt.loads.values.reduce(0) { $0 + $1.rpcHandles.count },
            readinessWaiterCount: attempt.readinessToken == nil ? 0 : 1
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
              attempt.phase == .loadingCatalog,
              attempt.loads[lease.loadID] != nil else {
            return .discarded(.attemptSuperseded, .none)
        }
        var effects: [ProcessControlPlaneEffect]
        var removesAttempt = false
        switch outcome {
        case .usable(let raw, let source):
            effects = attempt.detachedEffects()
            attempt.readinessToken = nil
            attempt.retryTimeout = nil
            attempt.retryKind = nil
            attempt.loads.removeAll()
            state.unboundCatalogRaw = raw
            state.unboundCatalogSource = source
            attempt.phase = .cataloged
        case .unusable:
            effects = attempt.loads.removeValue(forKey: lease.loadID)?
                .detachedEffects() ?? []
            if attempt.loads.isEmpty {
                state.unboundCatalogRaw = nil
                state.unboundCatalogSource = nil
                attempt.phase = .pending
            } else {
                attempt.phase = .loadingCatalog
            }
        case .failed:
            effects = attempt.loads.removeValue(forKey: lease.loadID)?
                .detachedEffects() ?? []
            if attempt.loads.isEmpty {
                attempt.phase = state.unboundCatalogRaw == nil ? .pending : .cataloged
                removesAttempt = true
            } else {
                attempt.phase = .loadingCatalog
            }
        }
        if removesAttempt {
            state.unboundAttempt = nil
        } else {
            state.unboundAttempt = attempt
        }
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
    case rpc(ControlPlane.RPCHandle)

    fileprivate var cancellationEffect: ProcessControlPlaneEffect {
        switch self {
        case .retryTimeout(let timeout):
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
