import XcodeMCPKit
import Foundation
import NIO
import NIOConcurrencyHelpers

final class UpstreamHealthManager: Sendable {
    enum InitializeClaimOwner: Sendable, Hashable {
        case regular
        case processRouteActivation
        case processBridgeRecovery(ProcessBridgeRecovery)
    }

    enum InitializeClaimPhase: Sendable, Equatable {
        case reserved
        case sending
        case responseReceived
        case initializedAwaitingCatalog
        case initializedAwaitingBridgeVerification
    }

    struct InitializeClaim: Sendable, Hashable {
        fileprivate let upstreamID: UpstreamSlotID
        fileprivate let generation: UInt64
        let owner: InitializeClaimOwner
        let topologyProof: UpstreamTopologyProof?

        var upstreamIndex: Int { upstreamID.rawValue }
    }

    struct BridgeAttachmentVerification: Sendable {
        let recovery: ProcessBridgeRecovery
        let initializeParticipant: CanonicalHandshakeState.InitializeParticipantLease
    }

    enum ProbePurpose: Sendable {
        case healthRecovery
        case processBridgeAttachment(BridgeAttachmentVerification)
    }

    struct ProbeRequest: Sendable {
        let topologyProof: UpstreamTopologyProof
        let probeGeneration: UInt64
        let purpose: ProbePurpose

        init(
            topologyProof: UpstreamTopologyProof,
            probeGeneration: UInt64,
            purpose: ProbePurpose = .healthRecovery
        ) {
            self.topologyProof = topologyProof
            self.probeGeneration = probeGeneration
            self.purpose = purpose
        }

        var upstreamID: UpstreamSlotID { topologyProof.slotID }
        var upstreamIndex: Int { upstreamID.rawValue }
    }

    struct QuarantineRecoveryLease: Sendable {
        let topologyProof: UpstreamTopologyProof
        let healthProbeGeneration: UInt64
        let deadlineUptimeNs: UInt64
    }

    enum Effect: Sendable {
        case cancelInitTimeout(RuntimeScheduledTimeout)
        case startHealthProbe(UpstreamHealthManager.ProbeRequest)
        case clearPins
        case failQueuedIfNoRecovery
    }

    struct UseEvaluation: Sendable {
        let proof: UpstreamTopologyProof?
        let effects: [UpstreamHealthManager.Effect]

        var isUsable: Bool { proof != nil }

        init(proof: UpstreamTopologyProof?, effects: [UpstreamHealthManager.Effect]) {
            self.proof = proof
            self.effects = effects
        }
    }

    struct SelectionResult: Sendable {
        let proof: UpstreamTopologyProof?
        let effects: [UpstreamHealthManager.Effect]

        var upstreamID: UpstreamSlotID? { proof?.slotID }
        var upstreamIndex: Int? { upstreamID?.rawValue }

        init(proof: UpstreamTopologyProof?, effects: [UpstreamHealthManager.Effect]) {
            self.proof = proof
            self.effects = effects
        }
    }

    struct ProtocolViolationTransition: Sendable {
        let quarantineUntil: UInt64
        let cancelledInitTimeout: RuntimeScheduledTimeout?
    }

    struct IncompatibilityTransition: Sendable {
        let quarantineUntil: UInt64
        let cancelledInitTimeout: RuntimeScheduledTimeout?
        let initUpstreamID: Int64?
    }

    struct MarkInitializedTransition: Sendable {
        let timeout: RuntimeScheduledTimeout?
    }

    struct BridgeVerificationTransition: Sendable {
        let timeout: RuntimeScheduledTimeout?
        let probe: ProbeRequest
    }

    struct TimeoutAttachment: Sendable {
        let accepted: Bool
        let replaced: RuntimeScheduledTimeout?
    }

    enum CatalogActivationDisposition: Sendable, Equatable {
        case keepWaiting
        case complete
    }

    enum CatalogActivationCommit: Sendable {
        case notOwned
        case kept
        case completed(RuntimeScheduledTimeout?)
    }

    enum InitPhase: Sendable, Equatable {
        case idle
        case initializing(upstreamID: Int64?)
        case initialized(InitializedReadiness)

        enum InitializedReadiness: Sendable, Equatable {
            case usable
            case verifyingBridge(ProcessRouteID)
        }

        var isInitialized: Bool {
            guard case .initialized = self else { return false }
            return true
        }

        var isUsableInitialized: Bool {
            guard case .initialized(.usable) = self else { return false }
            return true
        }

        var isVerifyingBridge: Bool {
            guard case .initialized(.verifyingBridge) = self else { return false }
            return true
        }

        var isInFlight: Bool {
            guard case .initializing = self else { return false }
            return true
        }

        var upstreamID: Int64? {
            guard case .initializing(let upstreamID) = self else { return nil }
            return upstreamID
        }
    }

    enum Event: Sendable {
        case requestSucceeded(UpstreamTopologyProof)
        case upstreamOverloaded(UpstreamTopologyProof)
    }

    struct UpstreamState: Sendable {
        var initPhase: InitPhase = .idle
        var initializeClaim: InitializeClaim?
        var initializeClaimPhase: InitializeClaimPhase?
        var initTimeout: RuntimeScheduledTimeout?
        var didReceiveInitializeResponse = false
        var didSendInitialized = false
        var healthState: Upstream.HealthState = .healthy
        var consecutiveRequestTimeouts = 0
        var healthProbeInFlight = false
        var healthProbeGeneration: UInt64 = 0
        var consecutiveToolsListFailures: Int = 0
        var lastToolsListSuccessUptimeNs: UInt64?
        var requestPickCount: Int = 0

        var isInitialized: Bool {
            get { initPhase.isInitialized }
            set {
                if newValue {
                    initPhase = .initialized(.usable)
                } else if initPhase.isInitialized {
                    initPhase = .idle
                }
            }
        }

        var initInFlight: Bool {
            get { initPhase.isInFlight }
            set {
                if newValue {
                    initPhase = .initializing(upstreamID: initPhase.upstreamID)
                } else if initPhase.isInFlight {
                    initPhase = .idle
                }
            }
        }

        var initUpstreamID: Int64? {
            get { initPhase.upstreamID }
            set {
                if initPhase.isInFlight || newValue != nil {
                    initPhase = .initializing(upstreamID: newValue)
                }
            }
        }
    }

    private struct State: Sendable {
        var upstreamStates: [UpstreamSlotID: UpstreamState] = [:]
        var topology: UpstreamTopologyAuthority.Snapshot?
        var nextPick: Int = 0
        var nextInitializeClaimGeneration: UInt64 = 0
    }

    private let state: NIOLockedValueBox<State>

    init() {
        self.state = NIOLockedValueBox(State())
    }

    func applyTopology(_ snapshot: UpstreamTopologyAuthority.Snapshot) {
        let cancelledTimeouts = state.withLockedValue { state -> [RuntimeScheduledTimeout] in
            var cancelledTimeouts: [RuntimeScheduledTimeout] = []
            let previousStates = state.upstreamStates
            var nextStates: [UpstreamSlotID: UpstreamState] = [:]
            nextStates.reserveCapacity(snapshot.entries.count)

            for entry in snapshot.entries {
                let id = entry.id
                let keepsState = state.topology?.proof(id)?.slotGeneration == entry.generation
                if keepsState, let existing = previousStates[id] {
                    nextStates[id] = existing
                } else {
                    if let timeout = previousStates[id]?.initTimeout {
                        cancelledTimeouts.append(timeout)
                    }
                    nextStates[id] = UpstreamState()
                }
            }
            let nextIDs = Set(snapshot.slotIDs)
            for (id, previous) in previousStates where nextIDs.contains(id) == false {
                if let timeout = previous.initTimeout {
                    cancelledTimeouts.append(timeout)
                }
            }

            state.upstreamStates = nextStates
            state.topology = snapshot
            state.nextPick = snapshot.slotIDs.isEmpty
                ? 0
                : state.nextPick % snapshot.slotIDs.count
            return cancelledTimeouts
        }
        cancelledTimeouts.forEach { $0.cancel() }
    }

    func state(for upstreamID: UpstreamSlotID) -> UpstreamState? {
        state.withLockedValue { state in
            guard Self.isActive(upstreamID, state: state) else { return nil }
            return state.upstreamStates[upstreamID]
        }
    }

    func activeStatesSnapshot() -> [(id: UpstreamSlotID, state: UpstreamState)] {
        state.withLockedValue { state in
            Self.activeIDs(in: state).compactMap { id in
                state.upstreamStates[id].map { (id, $0) }
            }
        }
    }

    func clearInitTimeoutsForShutdown() -> [RuntimeScheduledTimeout?] {
        state.withLockedValue { state -> [RuntimeScheduledTimeout?] in
            var timeouts: [RuntimeScheduledTimeout?] = []
            let activeIndices = Self.activeIndices(in: state)
            timeouts.reserveCapacity(activeIndices.count)
            for index in activeIndices {
                timeouts.append(state.upstreamStates[index].initTimeout)
                state.upstreamStates[index].initTimeout = nil
                state.upstreamStates[index].initInFlight = false
                state.upstreamStates[index].initUpstreamID = nil
            }
            return timeouts
        }
    }

    func anyInitialized() -> Bool {
        state.withLockedValue { state in
            Self.activeIndices(in: state).contains {
                state.upstreamStates[$0].initPhase.isUsableInitialized
            }
        }
    }

    func withUsableInitializedSource<Result>(
        _ proof: UpstreamTopologyProof,
        _ operation: () -> Result
    ) -> Result? {
        state.withLockedValue { state in
            guard Self.isUsableInitialized(proof, state: state) else {
                return nil
            }
            return operation()
        }
    }

    /// Returns the exact active slot generations that can currently support
    /// cached handshake state. A quarantined or merely in-flight channel is
    /// not a valid source-rebind candidate.
    func withUsableInitializedTopologyProofs<Result>(
        retaining authoritativeProofs: Set<UpstreamTopologyProof>,
        _ operation: (Set<UpstreamTopologyProof>) -> Result
    ) -> Result {
        state.withLockedValue { state in
            let proofs = Set<UpstreamTopologyProof>(
                Self.activeIDs(in: state).compactMap { upstreamID in
                guard let proof = state.topology?.proof(upstreamID),
                      authoritativeProofs.contains(proof),
                      Self.isUsableInitialized(proof, state: state) else {
                    return nil
                }
                return proof
                }
            )
            return operation(proofs)
        }
    }

    func earliestInitializedQuarantineRecovery() -> QuarantineRecoveryLease? {
        state.withLockedValue { state in
            Self.activeIDs(in: state).compactMap { upstreamID -> QuarantineRecoveryLease? in
                guard let proof = state.topology?.proof(upstreamID),
                      let upstream = state.upstreamStates[upstreamID],
                      upstream.isInitialized,
                      upstream.healthProbeInFlight == false,
                      case .quarantined(let deadlineUptimeNs) = upstream.healthState else {
                    return nil
                }
                return QuarantineRecoveryLease(
                    topologyProof: proof,
                    healthProbeGeneration: upstream.healthProbeGeneration,
                    deadlineUptimeNs: deadlineUptimeNs
                )
            }.min { lhs, rhs in
                if lhs.deadlineUptimeNs != rhs.deadlineUptimeNs {
                    return lhs.deadlineUptimeNs < rhs.deadlineUptimeNs
                }
                if lhs.topologyProof.slotID != rhs.topologyProof.slotID {
                    return lhs.topologyProof.slotID.rawValue
                        < rhs.topologyProof.slotID.rawValue
                }
                return lhs.topologyProof.slotGeneration < rhs.topologyProof.slotGeneration
            }
        }
    }

    func beginQuarantineRecovery(
        _ lease: QuarantineRecoveryLease,
        nowUptimeNs: UInt64
    ) -> ProbeRequest? {
        state.withLockedValue { state in
            guard Self.isActive(lease.topologyProof, state: state) else { return nil }
            let upstreamIndex = lease.topologyProof.slotID.rawValue
            guard state.upstreamStates[upstreamIndex].initPhase.isUsableInitialized,
                  state.upstreamStates[upstreamIndex].healthProbeInFlight == false,
                  state.upstreamStates[upstreamIndex].healthProbeGeneration
                    == lease.healthProbeGeneration,
                  case .quarantined(let deadlineUptimeNs) =
                    state.upstreamStates[upstreamIndex].healthState,
                  deadlineUptimeNs == lease.deadlineUptimeNs,
                  nowUptimeNs >= deadlineUptimeNs else { return nil }
            state.upstreamStates[upstreamIndex].healthProbeInFlight = true
            state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
            return ProbeRequest(
                topologyProof: lease.topologyProof,
                probeGeneration: state.upstreamStates[upstreamIndex].healthProbeGeneration
            )
        }
    }

    func primaryInitInFlight() -> Bool {
        state.withLockedValue { state in
            guard let primary = Self.activeIndices(in: state).first else { return false }
            return state.upstreamStates[primary].initInFlight
        }
    }

    func anyRecoveryInFlight() -> Bool {
        state.withLockedValue { state in
            Self.activeIndices(in: state).contains {
                state.upstreamStates[$0].initInFlight
                    || state.upstreamStates[$0].healthProbeInFlight
            }
        }
    }

    func initializedHealthyishCount() -> Int {
        state.withLockedValue { state in
            Self.activeIndices(in: state).reduce(into: 0) { count, index in
                let upstream = state.upstreamStates[index]
                guard upstream.initPhase.isUsableInitialized else { return }
                switch upstream.healthState {
                case .healthy, .degraded:
                    count += 1
                case .quarantined:
                    break
                }
            }
        }
    }

    func evaluateUsableInitialized(
        index: Int,
        nowUptimeNs: UInt64
    ) -> UpstreamHealthManager.UseEvaluation {
        var effects: [UpstreamHealthManager.Effect] = []
        let proof = state.withLockedValue { state -> UpstreamTopologyProof? in
            guard Self.isActive(index, state: state) else { return nil }
            let health = Self.classifyHealthAndCollectEffectsIfNeeded(
                upstreamIndex: index,
                nowUptimeNs: nowUptimeNs,
                state: &state,
                effects: &effects
            )
            let isHealthyEnough: Bool
            switch health {
            case .healthy, .degraded:
                isHealthyEnough = true
            case .quarantined:
                isHealthyEnough = false
            }
            guard isHealthyEnough,
                  state.upstreamStates[index].initPhase.isUsableInitialized else { return nil }
            return state.topology?.proof(UpstreamSlotID(rawValue: index))
        }
        return UpstreamHealthManager.UseEvaluation(
            proof: proof,
            effects: effects
        )
    }

    func chooseBestInitializedUpstream(
        nowUptimeNs: UInt64,
        occupiedUpstreams: Set<Int>
    ) -> UpstreamHealthManager.SelectionResult {
        var effects: [UpstreamHealthManager.Effect] = []
        let chosen = state.withLockedValue { state -> UpstreamTopologyProof? in
            let candidates = Self.activeIndices(in: state)
            let count = candidates.count
            guard count > 0 else { return nil }

            let rawStart = state.nextPick % count
            let start = rawStart >= 0 ? rawStart : rawStart + count
            state.nextPick &+= 1

            var degradedCandidate: Int?
            for offset in 0..<count {
                let candidate = candidates[(start + offset) % count]
                if occupiedUpstreams.contains(candidate) {
                    continue
                }
                guard state.upstreamStates[candidate].initPhase.isUsableInitialized else {
                    continue
                }
                let health = Self.classifyHealthAndCollectEffectsIfNeeded(
                    upstreamIndex: candidate,
                    nowUptimeNs: nowUptimeNs,
                    state: &state,
                    effects: &effects
                )
                switch health {
                case .healthy:
                    state.upstreamStates[candidate].requestPickCount += 1
                    return state.topology?.proof(UpstreamSlotID(rawValue: candidate))
                case .degraded:
                    if degradedCandidate == nil {
                        degradedCandidate = candidate
                    }
                case .quarantined:
                    continue
                }
            }
            if let degradedCandidate {
                state.upstreamStates[degradedCandidate].requestPickCount += 1
            }
            return degradedCandidate.flatMap {
                state.topology?.proof(UpstreamSlotID(rawValue: $0))
            }
        }
        return UpstreamHealthManager.SelectionResult(proof: chosen, effects: effects)
    }

    func markRequestSucceeded(_ proof: UpstreamTopologyProof) {
        _ = apply(event: .requestSucceeded(proof))
    }

    func markUpstreamOverloaded(_ proof: UpstreamTopologyProof) -> Bool {
        apply(event: .upstreamOverloaded(proof)).isEmpty == false
    }

    func markRequestTimedOut(
        _ proof: UpstreamTopologyProof,
        nowUptimeNs: UInt64
    ) -> (shouldClearPins: Bool, timeoutCount: Int) {
        state.withLockedValue { state in
            guard Self.isActive(proof, state: state) else {
                return (false, 0)
            }
            let upstreamIndex = proof.slotID.rawValue
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts += 1
            let timeoutCount = state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts
            if timeoutCount >= 3 {
                let quarantineUntil = nowUptimeNs &+ 15_000_000_000
                state.upstreamStates[upstreamIndex].healthState = .quarantined(untilUptimeNs: quarantineUntil)
                if state.upstreamStates[upstreamIndex].initPhase.isVerifyingBridge == false {
                    state.upstreamStates[upstreamIndex].healthProbeInFlight = false
                    state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
                }
                return (true, timeoutCount)
            } else {
                state.upstreamStates[upstreamIndex].healthState = .degraded
                return (false, timeoutCount)
            }
        }
    }

    func markProtocolViolation(
        _ proof: UpstreamTopologyProof,
        nowUptimeNs: UInt64
    ) -> UpstreamHealthManager.ProtocolViolationTransition? {
        state.withLockedValue { state in
            guard Self.isActive(proof, state: state) else { return nil }
            let upstreamIndex = proof.slotID.rawValue
            let quarantineUntil = nowUptimeNs &+ 15_000_000_000
            let cancelledInitTimeout = state.upstreamStates[upstreamIndex].initTimeout
            state.upstreamStates[upstreamIndex].isInitialized = false
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].initTimeout = nil
            state.upstreamStates[upstreamIndex].initUpstreamID = nil
            state.upstreamStates[upstreamIndex].didSendInitialized = false
            state.upstreamStates[upstreamIndex].healthState = .quarantined(
                untilUptimeNs: quarantineUntil
            )
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
            return UpstreamHealthManager.ProtocolViolationTransition(
                quarantineUntil: quarantineUntil,
                cancelledInitTimeout: cancelledInitTimeout
            )
        }
    }

    func quarantineIncompatibleUpstream(
        _ proof: UpstreamTopologyProof,
        nowUptimeNs: UInt64
    ) -> UpstreamHealthManager.IncompatibilityTransition? {
        state.withLockedValue { state in
            guard Self.isActive(proof, state: state) else { return nil }
            let upstreamIndex = proof.slotID.rawValue
            let quarantineUntil = nowUptimeNs &+ 30_000_000_000
            let cancelledInitTimeout = state.upstreamStates[upstreamIndex].initTimeout
            let initUpstreamID = state.upstreamStates[upstreamIndex].initUpstreamID
            state.upstreamStates[upstreamIndex].isInitialized = false
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].initTimeout = nil
            state.upstreamStates[upstreamIndex].initUpstreamID = nil
            state.upstreamStates[upstreamIndex].didSendInitialized = false
            state.upstreamStates[upstreamIndex].healthState = .quarantined(
                untilUptimeNs: quarantineUntil
            )
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
            return UpstreamHealthManager.IncompatibilityTransition(
                quarantineUntil: quarantineUntil,
                cancelledInitTimeout: cancelledInitTimeout,
                initUpstreamID: initUpstreamID
            )
        }
    }

    func finishHealthProbe(
        _ request: ProbeRequest,
        success: Bool,
        nowUptimeNs: UInt64
    ) -> Bool {
        state.withLockedValue { state in
            guard Self.isActive(request.topologyProof, state: state) else { return false }
            let upstreamIndex = request.upstreamIndex
            guard state.upstreamStates[upstreamIndex].healthProbeInFlight,
                  state.upstreamStates[upstreamIndex].healthProbeGeneration
                    == request.probeGeneration else { return false }
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
            if success {
                state.upstreamStates[upstreamIndex].healthState = .healthy
                state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
            } else {
                state.upstreamStates[upstreamIndex].healthState = .quarantined(
                    untilUptimeNs: nowUptimeNs &+ 15_000_000_000
                )
            }
            return true
        }
    }

    func finishBridgeAttachVerification(
        _ request: ProbeRequest,
        success: Bool,
        nowUptimeNs: UInt64,
        commit: () -> Bool
    ) -> (
        recovery: ProcessBridgePoolRecovery,
        cleared: (
            timeout: RuntimeScheduledTimeout?,
            initUpstreamID: Int64?,
            didReceiveInitializeResponse: Bool,
            didSendInitialized: Bool
        )?
    )? {
        state.withLockedValue { state in
            guard case .processBridgeAttachment(let verification) = request.purpose else {
                return nil
            }
            let recovery = verification.recovery
            guard Self.isActive(request.topologyProof, state: state),
                  recovery.upstreamID == request.topologyProof.slotID else { return nil }
            let upstreamIndex = request.upstreamIndex
            guard state.upstreamStates[upstreamIndex].healthProbeInFlight,
                  state.upstreamStates[upstreamIndex].healthProbeGeneration
                    == request.probeGeneration,
                  state.upstreamStates[upstreamIndex].initPhase
                    == .initialized(.verifyingBridge(recovery.routeID)),
                  state.upstreamStates[upstreamIndex].initializeClaimPhase
                    == .initializedAwaitingBridgeVerification,
                  let claim = state.upstreamStates[upstreamIndex].initializeClaim,
                  case .processBridgeRecovery(let current) = claim.owner,
                  current == recovery else { return nil }
            if success {
                let previousUpstream = state.upstreamStates[upstreamIndex]
                state.upstreamStates[upstreamIndex].initPhase = .initialized(.usable)
                state.upstreamStates[upstreamIndex].initializeClaim = nil
                state.upstreamStates[upstreamIndex].initializeClaimPhase = nil
                state.upstreamStates[upstreamIndex].healthState = .healthy
                state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
                state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
                state.upstreamStates[upstreamIndex].consecutiveToolsListFailures = 0
                state.upstreamStates[upstreamIndex].lastToolsListSuccessUptimeNs = nowUptimeNs
                guard commit() else {
                    state.upstreamStates[upstreamIndex] = previousUpstream
                    return nil
                }
                return (recovery.reservation, nil)
            }
            guard commit() else { return nil }
            return (
                recovery.reservation,
                Self.clearUpstreamState(at: upstreamIndex, state: &state)
            )
        }
    }

    func markToolsListRefreshSucceeded(
        _ proof: UpstreamTopologyProof,
        nowUptimeNs: UInt64
    ) -> Bool {
        state.withLockedValue { state in
            guard Self.isActive(proof, state: state) else { return false }
            let upstreamIndex = proof.slotID.rawValue
            let isVerifyingBridge = state.upstreamStates[upstreamIndex]
                .initPhase.isVerifyingBridge
            if state.upstreamStates[upstreamIndex].healthProbeInFlight,
               isVerifyingBridge == false {
                state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
            }
            state.upstreamStates[upstreamIndex].healthState = .healthy
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
            if isVerifyingBridge == false {
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            }
            state.upstreamStates[upstreamIndex].consecutiveToolsListFailures = 0
            state.upstreamStates[upstreamIndex].lastToolsListSuccessUptimeNs = nowUptimeNs
            return true
        }
    }

    func markToolsListRefreshFailed(
        _ proof: UpstreamTopologyProof,
        nowUptimeNs: UInt64
    ) -> (failures: Int, quarantineUntil: UInt64)? {
        state.withLockedValue { state in
            guard Self.isActive(proof, state: state) else { return nil }
            let upstreamIndex = proof.slotID.rawValue
            let isVerifyingBridge = state.upstreamStates[upstreamIndex]
                .initPhase.isVerifyingBridge
            if state.upstreamStates[upstreamIndex].healthProbeInFlight,
               isVerifyingBridge == false {
                state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
            }
            let quarantineUntil = nowUptimeNs &+ 30 * 1_000_000_000
            state.upstreamStates[upstreamIndex].healthState = .quarantined(untilUptimeNs: quarantineUntil)
            if isVerifyingBridge == false {
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            }
            state.upstreamStates[upstreamIndex].consecutiveToolsListFailures += 1
            return (state.upstreamStates[upstreamIndex].consecutiveToolsListFailures, quarantineUntil)
        }
    }

    func shouldSendInitializedNotification(_ claim: InitializeClaim) -> Bool {
        state.withLockedValue { state in
            guard Self.matches(claim, state: state) else { return false }
            return state.upstreamStates[claim.upstreamIndex].didSendInitialized == false
        }
    }

    func resetForDebug() -> [RuntimeScheduledTimeout?] {
        state.withLockedValue { state in
            let activeIndices = Self.activeIndices(in: state)
            let timeouts = activeIndices.map {
                state.upstreamStates[$0].initTimeout
            }
            for index in activeIndices {
                let nextProbeGeneration =
                    state.upstreamStates[index].healthProbeGeneration &+ 1
                state.upstreamStates[index] = UpstreamState()
                state.upstreamStates[index].healthProbeGeneration = nextProbeGeneration
            }
            state.nextPick = 0
            return timeouts
        }
    }

    func claimWarmInitialize(
        upstreamIndex: Int,
        owner: InitializeClaimOwner = .regular
    ) -> InitializeClaim? {
        state.withLockedValue { state in
            guard Self.isActive(upstreamIndex, state: state) else { return nil }
            if state.upstreamStates[upstreamIndex].isInitialized || state.upstreamStates[upstreamIndex].initInFlight {
                return nil
            }
            state.nextInitializeClaimGeneration &+= 1
            let claim = InitializeClaim(
                upstreamID: UpstreamSlotID(rawValue: upstreamIndex),
                generation: state.nextInitializeClaimGeneration,
                owner: owner,
                topologyProof: state.topology?.proof(
                    UpstreamSlotID(rawValue: upstreamIndex)
                )
            )
            state.upstreamStates[upstreamIndex].initInFlight = true
            state.upstreamStates[upstreamIndex].initializeClaim = claim
            state.upstreamStates[upstreamIndex].initializeClaimPhase = .reserved
            return claim
        }
    }

    func validate(_ claim: InitializeClaim) -> Bool {
        state.withLockedValue { state in
            Self.matches(claim, state: state)
        }
    }

    func beginInitializeSend(_ claim: InitializeClaim) -> Bool {
        state.withLockedValue { state in
            guard Self.matches(claim, state: state),
                  state.upstreamStates[claim.upstreamIndex].initializeClaimPhase
                    == .reserved else { return false }
            state.upstreamStates[claim.upstreamIndex].initializeClaimPhase = .sending
            return true
        }
    }

    func currentInitializeClaim(
        upstreamIndex: Int,
        expectedUpstreamID: Int64
    ) -> InitializeClaim? {
        state.withLockedValue { state in
            guard Self.isActive(upstreamIndex, state: state),
                  state.upstreamStates[upstreamIndex].initUpstreamID == expectedUpstreamID,
                  let claim = state.upstreamStates[upstreamIndex].initializeClaim,
                  Self.matches(claim, state: state) else { return nil }
            return claim
        }
    }

    func currentBridgeRecovery(
        for proof: UpstreamTopologyProof
    ) -> ProcessBridgeRecovery? {
        state.withLockedValue { state in
            guard Self.isActive(proof, state: state),
                  let upstream = state.upstreamStates[proof.slotID],
                  let claim = upstream.initializeClaim,
                  claim.topologyProof == proof,
                  case .processBridgeRecovery(let recovery) = claim.owner else { return nil }
            return recovery
        }
    }

    func transferInitializeResponse(
        _ claim: InitializeClaim,
        expectedUpstreamID: Int64
    ) -> Bool {
        state.withLockedValue { state in
            guard Self.matches(claim, state: state),
                  state.upstreamStates[claim.upstreamIndex].initUpstreamID
                    == expectedUpstreamID,
                  state.upstreamStates[claim.upstreamIndex].initializeClaimPhase
                    == .sending else { return false }
            state.upstreamStates[claim.upstreamIndex].didReceiveInitializeResponse = true
            state.upstreamStates[claim.upstreamIndex].initializeClaimPhase = .responseReceived
            return true
        }
    }

    @discardableResult
    func setWarmInitializeUpstreamID(
        _ upstreamID: Int64,
        for claim: InitializeClaim
    ) -> Bool {
        state.withLockedValue { state in
            guard Self.matches(claim, state: state) else { return false }
            state.upstreamStates[claim.upstreamIndex].initUpstreamID = upstreamID
            return true
        }
    }

    func clearInitializeClaim(
        _ claim: InitializeClaim
    ) -> (
        timeout: RuntimeScheduledTimeout?,
        initUpstreamID: Int64?,
        didReceiveInitializeResponse: Bool,
        didSendInitialized: Bool
    )? {
        state.withLockedValue { state in
            guard Self.owns(claim, state: state) else { return nil }
            return Self.clearUpstreamState(at: claim.upstreamIndex, state: &state)
        }
    }

    func replaceInitTimeout(
        _ timeout: RuntimeScheduledTimeout,
        for claim: InitializeClaim
    ) -> TimeoutAttachment {
        state.withLockedValue { state in
            guard Self.matches(claim, state: state) else {
                return TimeoutAttachment(accepted: false, replaced: nil)
            }
            let replaced = state.upstreamStates[claim.upstreamIndex].initTimeout
            state.upstreamStates[claim.upstreamIndex].initTimeout = timeout
            return TimeoutAttachment(accepted: true, replaced: replaced)
        }
    }

    func clearUpstreamState(
        _ proof: UpstreamTopologyProof,
        expectedUpstreamID: Int64? = nil
    ) -> (
        timeout: RuntimeScheduledTimeout?,
        initUpstreamID: Int64?,
        didReceiveInitializeResponse: Bool,
        didSendInitialized: Bool
    )? {
        state.withLockedValue { state in
            guard Self.isActive(proof, state: state) else { return nil }
            let upstreamIndex = proof.slotID.rawValue
            if let expectedUpstreamID,
               state.upstreamStates[upstreamIndex].initUpstreamID != expectedUpstreamID
            {
                return nil
            }
            return Self.clearUpstreamState(at: upstreamIndex, state: &state)
        }
    }

    func markInitialized(
        _ proof: UpstreamTopologyProof,
        expectedUpstreamID: Int64? = nil
    ) -> UpstreamHealthManager.MarkInitializedTransition? {
        state.withLockedValue { state in
            guard Self.isActive(proof, state: state) else { return nil }
            let upstreamIndex = proof.slotID.rawValue
            if let owner = state.upstreamStates[upstreamIndex].initializeClaim?.owner,
               owner != .regular {
                return nil
            }
            if let expectedUpstreamID,
               state.upstreamStates[upstreamIndex].initUpstreamID != expectedUpstreamID
            {
                return nil
            }
            state.upstreamStates[upstreamIndex].isInitialized = true
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].initUpstreamID = nil
            state.upstreamStates[upstreamIndex].initializeClaim = nil
            state.upstreamStates[upstreamIndex].initializeClaimPhase = nil
            state.upstreamStates[upstreamIndex].healthState = .healthy
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            let timeout = state.upstreamStates[upstreamIndex].initTimeout
            state.upstreamStates[upstreamIndex].initTimeout = nil
            return UpstreamHealthManager.MarkInitializedTransition(timeout: timeout)
        }
    }

    func markInitialized(
        _ claim: InitializeClaim,
        expectedUpstreamID: Int64,
        commit: () -> Bool
    ) -> UpstreamHealthManager.MarkInitializedTransition? {
        if case .processBridgeRecovery = claim.owner {
            return nil
        }
        return state.withLockedValue { state in
            guard Self.matches(claim, state: state),
                  state.upstreamStates[claim.upstreamIndex].initUpstreamID
                    == expectedUpstreamID,
                  state.upstreamStates[claim.upstreamIndex].initializeClaimPhase
                    == .responseReceived,
                  commit() else { return nil }
            let timeout = state.upstreamStates[claim.upstreamIndex].initTimeout
            state.upstreamStates[claim.upstreamIndex].initPhase = .initialized(.usable)
            state.upstreamStates[claim.upstreamIndex].initInFlight = false
            state.upstreamStates[claim.upstreamIndex].initUpstreamID = nil
            if claim.owner == .processRouteActivation {
                state.upstreamStates[claim.upstreamIndex].initializeClaimPhase =
                    .initializedAwaitingCatalog
            } else {
                state.upstreamStates[claim.upstreamIndex].initializeClaim = nil
                state.upstreamStates[claim.upstreamIndex].initializeClaimPhase = nil
            }
            state.upstreamStates[claim.upstreamIndex].initTimeout = nil
            state.upstreamStates[claim.upstreamIndex].healthState = .healthy
            state.upstreamStates[claim.upstreamIndex].consecutiveRequestTimeouts = 0
            state.upstreamStates[claim.upstreamIndex].healthProbeInFlight = false
            return UpstreamHealthManager.MarkInitializedTransition(timeout: timeout)
        }
    }

    func beginBridgeAttachVerification(
        _ claim: InitializeClaim,
        expectedUpstreamID: Int64,
        initializeParticipant: CanonicalHandshakeState.InitializeParticipantLease
    ) -> UpstreamHealthManager.BridgeVerificationTransition? {
        guard case .processBridgeRecovery(let recovery) = claim.owner,
              initializeParticipant.topologyProof == recovery.topologyProof else {
            return nil
        }
        return state.withLockedValue { state in
            guard Self.matches(claim, state: state),
                  state.upstreamStates[claim.upstreamIndex].initUpstreamID
                    == expectedUpstreamID,
                  state.upstreamStates[claim.upstreamIndex].initializeClaimPhase
                    == .responseReceived else { return nil }
            let timeout = state.upstreamStates[claim.upstreamIndex].initTimeout
            state.upstreamStates[claim.upstreamIndex].initPhase = .initialized(
                .verifyingBridge(recovery.routeID)
            )
            state.upstreamStates[claim.upstreamIndex].initInFlight = false
            state.upstreamStates[claim.upstreamIndex].initUpstreamID = nil
            state.upstreamStates[claim.upstreamIndex].initializeClaimPhase =
                .initializedAwaitingBridgeVerification
            state.upstreamStates[claim.upstreamIndex].initTimeout = nil
            state.upstreamStates[claim.upstreamIndex].healthState = .healthy
            state.upstreamStates[claim.upstreamIndex].consecutiveRequestTimeouts = 0
            state.upstreamStates[claim.upstreamIndex].healthProbeInFlight = true
            state.upstreamStates[claim.upstreamIndex].healthProbeGeneration &+= 1
            let probe = ProbeRequest(
                topologyProof: recovery.topologyProof,
                probeGeneration: state.upstreamStates[claim.upstreamIndex]
                    .healthProbeGeneration,
                purpose: .processBridgeAttachment(
                    BridgeAttachmentVerification(
                        recovery: recovery,
                        initializeParticipant: initializeParticipant
                    )
                )
            )
            return UpstreamHealthManager.BridgeVerificationTransition(
                timeout: timeout,
                probe: probe
            )
        }
    }

    func replaceCatalogTimeout(
        _ timeout: RuntimeScheduledTimeout,
        for claim: InitializeClaim
    ) -> TimeoutAttachment {
        state.withLockedValue { state in
            guard Self.owns(claim, state: state),
                  state.upstreamStates[claim.upstreamIndex].isInitialized,
                  state.upstreamStates[claim.upstreamIndex].initializeClaimPhase
                    == .initializedAwaitingCatalog else {
                return TimeoutAttachment(accepted: false, replaced: nil)
            }
            let replaced = state.upstreamStates[claim.upstreamIndex].initTimeout
            state.upstreamStates[claim.upstreamIndex].initTimeout = timeout
            return TimeoutAttachment(accepted: true, replaced: replaced)
        }
    }

    func currentCatalogActivationClaim(
        upstreamIndex: Int
    ) -> InitializeClaim? {
        state.withLockedValue { state in
            guard Self.isActive(upstreamIndex, state: state),
                  let claim = state.upstreamStates[upstreamIndex].initializeClaim,
                  claim.owner == .processRouteActivation,
                  state.upstreamStates[upstreamIndex].initializeClaimPhase
                    == .initializedAwaitingCatalog else { return nil }
            return claim
        }
    }

    func commitCatalogActivation(
        _ claim: InitializeClaim,
        sourceProof: UpstreamTopologyProof,
        commit: (InitializeClaim) -> CatalogActivationDisposition
    ) -> CatalogActivationCommit {
        state.withLockedValue { state in
            let upstreamIndex = claim.upstreamIndex
            guard Self.owns(claim, state: state),
                  state.upstreamStates[upstreamIndex].isInitialized,
                  Self.isUsableInitialized(sourceProof, state: state),
                  claim.owner == .processRouteActivation,
                  state.upstreamStates[upstreamIndex].initializeClaimPhase
                    == .initializedAwaitingCatalog else { return .notOwned }
            guard commit(claim) == .complete else { return .kept }
            let timeout = state.upstreamStates[upstreamIndex].initTimeout
            state.upstreamStates[upstreamIndex].initTimeout = nil
            state.upstreamStates[upstreamIndex].initializeClaim = nil
            state.upstreamStates[upstreamIndex].initializeClaimPhase = nil
            return .completed(timeout)
        }
    }

    func timeoutCatalogActivation(
        _ claim: InitializeClaim,
        commit: (InitializeClaim) -> Bool
    ) -> (
        timeout: RuntimeScheduledTimeout?,
        initUpstreamID: Int64?,
        didReceiveInitializeResponse: Bool,
        didSendInitialized: Bool
    )? {
        state.withLockedValue { state in
            guard Self.owns(claim, state: state),
                  state.upstreamStates[claim.upstreamIndex].isInitialized,
                  state.upstreamStates[claim.upstreamIndex].initializeClaimPhase
                    == .initializedAwaitingCatalog,
                  commit(claim) else { return nil }
            return Self.clearUpstreamState(at: claim.upstreamIndex, state: &state)
        }
    }

    func markInitializedNotificationSent(
        _ claim: InitializeClaim,
        expectedUpstreamID: Int64
    ) -> Bool {
        state.withLockedValue { state in
            guard Self.matches(claim, state: state),
                  state.upstreamStates[claim.upstreamIndex].initUpstreamID
                    == expectedUpstreamID,
                  state.upstreamStates[claim.upstreamIndex].initializeClaimPhase
                    == .responseReceived else { return false }
            state.upstreamStates[claim.upstreamIndex].didSendInitialized = true
            return true
        }
    }

    func debugHealthStateString(_ state: Upstream.HealthState) -> String {
        switch state {
        case .healthy:
            return "healthy"
        case .degraded:
            return "degraded"
        case .quarantined(let untilUptimeNs):
            return "quarantined(untilUptimeNs:\(untilUptimeNs))"
        }
    }

    func apply(event: Event) -> [UpstreamHealthManager.Effect] {
        state.withLockedValue { state in
            switch event {
            case .requestSucceeded(let proof):
                guard Self.isActive(proof, state: state) else { return [] }
                let upstreamIndex = proof.slotID.rawValue
                if case .quarantined = state.upstreamStates[upstreamIndex].healthState {
                    return []
                }
                state.upstreamStates[upstreamIndex].healthState = .healthy
                state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
                let isVerifyingBridge = state.upstreamStates[upstreamIndex]
                    .initPhase.isVerifyingBridge
                if state.upstreamStates[upstreamIndex].healthProbeInFlight,
                   isVerifyingBridge == false {
                    state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
                }
                if isVerifyingBridge == false {
                    state.upstreamStates[upstreamIndex].healthProbeInFlight = false
                }
                return [.failQueuedIfNoRecovery]

            case .upstreamOverloaded(let proof):
                guard Self.isActive(proof, state: state) else { return [] }
                let upstreamIndex = proof.slotID.rawValue
                if case .healthy = state.upstreamStates[upstreamIndex].healthState {
                    state.upstreamStates[upstreamIndex].healthState = .degraded
                }
                let isVerifyingBridge = state.upstreamStates[upstreamIndex]
                    .initPhase.isVerifyingBridge
                if state.upstreamStates[upstreamIndex].healthProbeInFlight,
                   isVerifyingBridge == false {
                    state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
                }
                if isVerifyingBridge == false {
                    state.upstreamStates[upstreamIndex].healthProbeInFlight = false
                }
                return [.failQueuedIfNoRecovery]

            }
        }
    }

    private static func classifyHealthAndCollectEffectsIfNeeded(
        upstreamIndex: Int,
        nowUptimeNs: UInt64,
        state: inout State,
        effects: inout [UpstreamHealthManager.Effect]
    ) -> Upstream.HealthState {
        guard Self.isActive(upstreamIndex, state: state) else {
            return .quarantined(untilUptimeNs: nowUptimeNs)
        }
        let current = state.upstreamStates[upstreamIndex].healthState
        switch current {
        case .healthy:
            return .healthy
        case .degraded:
            return .degraded
        case .quarantined(let untilUptimeNs):
            if nowUptimeNs < untilUptimeNs {
                return .quarantined(untilUptimeNs: untilUptimeNs)
            }
            if state.upstreamStates[upstreamIndex].healthProbeInFlight == false {
                guard let topologyProof = state.topology?.proof(
                    UpstreamSlotID(rawValue: upstreamIndex)
                ) else {
                    return .quarantined(untilUptimeNs: untilUptimeNs)
                }
                state.upstreamStates[upstreamIndex].healthProbeInFlight = true
                state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
                effects.append(
                    .startHealthProbe(UpstreamHealthManager.ProbeRequest(
                        topologyProof: topologyProof,
                        probeGeneration: state.upstreamStates[upstreamIndex].healthProbeGeneration
                    ))
                )
            }
            return .quarantined(untilUptimeNs: untilUptimeNs)
        }
    }

    func topologyProof(for upstreamIndex: Int) -> UpstreamTopologyProof? {
        state.withLockedValue { state in
            let upstreamID = UpstreamSlotID(rawValue: upstreamIndex)
            guard state.upstreamStates[upstreamID] != nil else { return nil }
            return state.topology?.proof(upstreamID)
        }
    }

    private static func isActive(_ upstreamIndex: Int, state: State) -> Bool {
        isActive(UpstreamSlotID(rawValue: upstreamIndex), state: state)
    }

    private static func isActive(_ upstreamID: UpstreamSlotID, state: State) -> Bool {
        state.topology?.proof(upstreamID) != nil
            && state.upstreamStates[upstreamID] != nil
    }

    private static func isActive(_ proof: UpstreamTopologyProof, state: State) -> Bool {
        state.topology?.proof(proof.slotID) == proof
            && state.upstreamStates[proof.slotID] != nil
    }

    private static func isUsableInitialized(
        _ proof: UpstreamTopologyProof,
        state: State
    ) -> Bool {
        guard isActive(proof, state: state),
              let source = state.upstreamStates[proof.slotID],
              source.initPhase.isUsableInitialized else {
            return false
        }
        switch source.healthState {
        case .healthy, .degraded:
            return true
        case .quarantined:
            return false
        }
    }

    private static func matches(_ claim: InitializeClaim, state: State) -> Bool {
        let upstreamIndex = claim.upstreamIndex
        guard isActive(upstreamIndex, state: state),
              state.upstreamStates[upstreamIndex].initInFlight,
              state.upstreamStates[upstreamIndex].initializeClaim == claim
        else {
            return false
        }
        guard let proof = claim.topologyProof else { return false }
        return isActive(proof, state: state)
    }

    private static func owns(_ claim: InitializeClaim, state: State) -> Bool {
        let upstreamIndex = claim.upstreamIndex
        return isActive(upstreamIndex, state: state)
            && state.upstreamStates[upstreamIndex].initializeClaim == claim
    }

    private static func clearUpstreamState(
        at upstreamIndex: Int,
        state: inout State
    ) -> (
        timeout: RuntimeScheduledTimeout?,
        initUpstreamID: Int64?,
        didReceiveInitializeResponse: Bool,
        didSendInitialized: Bool
    ) {
        let timeout = state.upstreamStates[upstreamIndex].initTimeout
        let initUpstreamID = state.upstreamStates[upstreamIndex].initUpstreamID
        let didReceiveInitializeResponse =
            state.upstreamStates[upstreamIndex].didReceiveInitializeResponse
        let didSendInitialized = state.upstreamStates[upstreamIndex].didSendInitialized
        let nextProbeGeneration = state.upstreamStates[upstreamIndex].healthProbeGeneration &+ 1
        state.upstreamStates[upstreamIndex] = UpstreamState()
        state.upstreamStates[upstreamIndex].healthProbeGeneration = nextProbeGeneration
        return (
            timeout,
            initUpstreamID,
            didReceiveInitializeResponse,
            didSendInitialized
        )
    }

    private static func activeIDs(in state: State) -> [UpstreamSlotID] {
        state.topology?.slotIDs.filter { state.upstreamStates[$0] != nil } ?? []
    }

    private static func activeIndices(in state: State) -> [Int] {
        activeIDs(in: state).map(\.rawValue)
    }
}

private extension Dictionary
where Key == UpstreamSlotID, Value == UpstreamHealthManager.UpstreamState {
    subscript(_ upstreamIndex: Int) -> Value {
        get {
            guard let value = self[UpstreamSlotID(rawValue: upstreamIndex)] else {
                preconditionFailure("inactive upstream slot ID: \(upstreamIndex)")
            }
            return value
        }
        set {
            self[UpstreamSlotID(rawValue: upstreamIndex)] = newValue
        }
    }
}
