import Foundation
import NIOConcurrencyHelpers
import XcodeMCPKit

/// Owns initialize-result compatibility, concurrent route participation, and
/// the set of initialized upstreams that support the canonical handshake.
final class CanonicalHandshakeState: Sendable {
    struct InitializeParticipantLease: Sendable, Hashable {
        fileprivate let participantID: UInt64
        fileprivate let sourceProof: UpstreamTopologyProof

        var sourceUpstreamIndex: Int { sourceProof.slotID.rawValue }
        var topologyProof: UpstreamTopologyProof { sourceProof }
    }

    enum InitializeOffer: Sendable {
        case accepted(InitializeParticipantLease)
        case incompatible(Incompatibility)
    }

    enum InitializeCommit: Sendable {
        case published(result: JSONValue, sourceProof: UpstreamTopologyProof)
        case joined
        case incompatible(Incompatibility)
        case stale

        var isAccepted: Bool {
            switch self {
            case .published, .joined:
                return true
            case .incompatible, .stale:
                return false
            }
        }
    }

    struct Incompatibility: Codable, Sendable {
        let upstreamIndex: Int
        let kind: String
        let reason: String
        let observedAt: Date

        init(
            upstreamIndex: Int,
            kind: String,
            reason: String,
            observedAt: Date = Date()
        ) {
            self.upstreamIndex = upstreamIndex
            self.kind = kind
            self.reason = reason
            self.observedAt = observedAt
        }
    }

    struct SupportEligibilityUpdate: Sendable {
        let previousResult: JSONValue?
        let exposedResult: JSONValue?
        let eligibleProofs: Set<UpstreamTopologyProof>
        let newlyIneligibleProofs: Set<UpstreamTopologyProof>
        let newlyEligibleProofs: Set<UpstreamTopologyProof>

        var becameAvailable: Bool {
            previousResult == nil && exposedResult != nil
        }
    }

    struct Snapshot: Sendable {
        let initializeResult: JSONValue?
        let initializeSourceUpstream: Int?
        let initializeSourceProof: UpstreamTopologyProof?
        let supporterProofs: Set<UpstreamTopologyProof>
        let lastIncompatibility: Incompatibility?
        let initializeEpoch: UInt64

        var isInitialized: Bool { initializeResult != nil }
    }

    private struct Participant: Sendable {
        let lease: InitializeParticipantLease
        let rawResult: JSONValue
        let semanticResult: JSONValue
    }

    private struct State: Sendable {
        var initializeResult: JSONValue?
        var initializeSemanticResult: JSONValue?
        var initializeSourceProof: UpstreamTopologyProof?
        var supporterResultsByProof: [UpstreamTopologyProof: JSONValue] = [:]
        var eligibleSupporterProofs: Set<UpstreamTopologyProof> = []
        var participantsByID: [UInt64: Participant] = [:]
        var nextParticipantID: UInt64 = 0
        var lastIncompatibility: Incompatibility?
        var initializeEpoch: UInt64 = 0
    }

    private let state = NIOLockedValueBox(State())

    func snapshot() -> Snapshot {
        state.withLockedValue { state in
            Snapshot(
                initializeResult: state.initializeResult,
                initializeSourceUpstream: state.initializeSourceProof?.slotID.rawValue,
                initializeSourceProof: state.initializeSourceProof,
                supporterProofs: state.eligibleSupporterProofs,
                lastIncompatibility: state.lastIncompatibility,
                initializeEpoch: state.initializeEpoch
            )
        }
    }

    func initializeResult() -> JSONValue? {
        state.withLockedValue(\.initializeResult)
    }

    func initializeSourceUpstream() -> Int? {
        state.withLockedValue { state in
            state.initializeSourceProof?.slotID.rawValue
        }
    }

    func offerInitializeResult(
        _ result: JSONValue,
        sourceProof: UpstreamTopologyProof
    ) -> InitializeOffer {
        state.withLockedValue { state in
            let semanticResult = Self.semanticInitializeResult(result)
            if let canonicalSemanticResult = state.initializeSemanticResult,
               canonicalSemanticResult != semanticResult {
                let incompatibility = Incompatibility(
                    upstreamIndex: sourceProof.slotID.rawValue,
                    kind: "initialize",
                    reason: "initialize.result mismatch"
                )
                state.lastIncompatibility = incompatibility
                return .incompatible(incompatibility)
            }

            state.nextParticipantID &+= 1
            let lease = InitializeParticipantLease(
                participantID: state.nextParticipantID,
                sourceProof: sourceProof
            )
            state.participantsByID[lease.participantID] = Participant(
                lease: lease,
                rawResult: result,
                semanticResult: semanticResult
            )
            return .accepted(lease)
        }
    }

    /// Commits only after the route has accepted notifications/initialized and
    /// the health owner is ready to mark the same topology proof initialized.
    func commitInitializeParticipant(
        _ lease: InitializeParticipantLease
    ) -> InitializeCommit {
        state.withLockedValue { state in
            guard let participant = state.participantsByID[lease.participantID],
                  participant.lease == lease else { return .stale }

            if let canonicalSemanticResult = state.initializeSemanticResult {
                guard canonicalSemanticResult == participant.semanticResult else {
                    state.participantsByID.removeValue(forKey: lease.participantID)
                    let incompatibility = Incompatibility(
                        upstreamIndex: lease.sourceUpstreamIndex,
                        kind: "initialize",
                        reason: "initialize.result mismatch"
                    )
                    state.lastIncompatibility = incompatibility
                    return .incompatible(incompatibility)
                }
                state.participantsByID.removeValue(forKey: lease.participantID)
                state.supporterResultsByProof[lease.sourceProof] = participant.rawResult
                state.eligibleSupporterProofs.insert(lease.sourceProof)
                if state.initializeResult == nil {
                    state.initializeResult = participant.rawResult
                    state.initializeSourceProof = lease.sourceProof
                    state.initializeEpoch &+= 1
                    return .published(
                        result: participant.rawResult,
                        sourceProof: lease.sourceProof
                    )
                }
                return .joined
            }

            state.participantsByID.removeValue(forKey: lease.participantID)
            state.initializeResult = participant.rawResult
            state.initializeSemanticResult = participant.semanticResult
            state.initializeSourceProof = lease.sourceProof
            state.supporterResultsByProof[lease.sourceProof] = participant.rawResult
            state.eligibleSupporterProofs.insert(lease.sourceProof)
            state.initializeEpoch &+= 1
            return .published(
                result: participant.rawResult,
                sourceProof: lease.sourceProof
            )
        }
    }

    func cancelInitializeParticipant(_ lease: InitializeParticipantLease) {
        state.withLockedValue { state in
            guard state.participantsByID[lease.participantID]?.lease == lease else {
                return
            }
            state.participantsByID.removeValue(forKey: lease.participantID)
        }
    }

    /// Removes only facts owned by this exact slot generation. A delayed clear
    /// from an old bridge cannot remove a replacement supporter at the same
    /// upstream index. Raw compatible evidence is removed only when its exact
    /// channel generation leaves the topology; temporary health quarantine is
    /// represented separately by eligibility.
    func removeInitializeParticipantAndSupporter(
        sourceProof: UpstreamTopologyProof,
        retaining usableSupporterProofs: Set<UpstreamTopologyProof>
    ) -> SupportEligibilityUpdate {
        state.withLockedValue { state in
            state.participantsByID = state.participantsByID.filter {
                $0.value.lease.sourceProof != sourceProof
            }
            state.supporterResultsByProof.removeValue(forKey: sourceProof)
            state.eligibleSupporterProofs.remove(sourceProof)
            let update = Self.updateSupportEligibility(
                retaining: usableSupporterProofs,
                state: &state
            )
            return SupportEligibilityUpdate(
                previousResult: update.previousResult,
                exposedResult: update.exposedResult,
                eligibleProofs: update.eligibleProofs,
                newlyIneligibleProofs: update.newlyIneligibleProofs.union([sourceProof]),
                newlyEligibleProofs: update.newlyEligibleProofs
            )
        }
    }

    /// Applies the health owner's exact topology-valid usable set while
    /// retaining raw results for temporarily quarantined initialized channels.
    /// Recovery can therefore re-expose the same handshake without inventing a
    /// second source of truth or forcing an unrelated route to reinitialize.
    func updateSupportEligibility(
        retaining usableSupporterProofs: Set<UpstreamTopologyProof>
    ) -> SupportEligibilityUpdate {
        state.withLockedValue { state in
            Self.updateSupportEligibility(
                retaining: usableSupporterProofs,
                state: &state
            )
        }
    }

    func hasInitializeParticipants(excluding sourceProof: UpstreamTopologyProof? = nil) -> Bool {
        state.withLockedValue { state in
            state.participantsByID.values.contains { participant in
                participant.lease.sourceProof != sourceProof
            }
        }
    }

    func clearInitialize() {
        state.withLockedValue { state in
            Self.clearInitializeState(state: &state)
        }
    }

    func reset() {
        state.withLockedValue { state in
            Self.clearInitializeState(state: &state)
            state.lastIncompatibility = nil
        }
    }

    func recordIncompatibility(
        upstreamIndex: Int,
        kind: String,
        reason: String
    ) {
        state.withLockedValue { state in
            state.lastIncompatibility = Incompatibility(
                upstreamIndex: upstreamIndex,
                kind: kind,
                reason: reason
            )
        }
    }

    private static func semanticInitializeResult(_ value: JSONValue) -> JSONValue {
        guard case .object(var object) = value else { return value }
        object.removeValue(forKey: "serverInfo")
        return .object(object)
    }

    private static func firstSupporter(
        in supporters: Set<UpstreamTopologyProof>
    ) -> UpstreamTopologyProof? {
        supporters.min { lhs, rhs in
            if lhs.slotID.rawValue != rhs.slotID.rawValue {
                return lhs.slotID.rawValue < rhs.slotID.rawValue
            }
            return lhs.slotGeneration < rhs.slotGeneration
        }
    }

    @discardableResult
    private static func rebindOrClearCanonicalInitialize(state: inout State) -> Bool {
        let previousResult = state.initializeResult
        let previousSource = state.initializeSourceProof
        if let survivor = firstSupporter(in: state.eligibleSupporterProofs),
           let survivorResult = state.supporterResultsByProof[survivor] {
            state.initializeSourceProof = survivor
            state.initializeResult = survivorResult
            state.initializeSemanticResult = semanticInitializeResult(survivorResult)
        } else {
            state.initializeResult = nil
            state.initializeSourceProof = nil
            if state.supporterResultsByProof.isEmpty {
                state.initializeSemanticResult = nil
            }
        }
        let changed = previousResult != state.initializeResult
            || previousSource != state.initializeSourceProof
        if changed {
            state.initializeEpoch &+= 1
        }
        return changed
    }

    private static func updateSupportEligibility(
        retaining usableSupporterProofs: Set<UpstreamTopologyProof>,
        state: inout State
    ) -> SupportEligibilityUpdate {
        let previousResult = state.initializeResult
        let previousEligible = state.eligibleSupporterProofs
        let evidenceProofs = Set(state.supporterResultsByProof.keys)
        var eligible = usableSupporterProofs.intersection(evidenceProofs)

        if let canonicalSemanticResult = state.initializeSemanticResult {
            eligible = Set(eligible.filter { proof in
                guard let result = state.supporterResultsByProof[proof] else { return false }
                return semanticInitializeResult(result) == canonicalSemanticResult
            })
        } else if let first = firstSupporter(in: eligible),
                  let firstResult = state.supporterResultsByProof[first] {
            let semanticResult = semanticInitializeResult(firstResult)
            eligible = Set(eligible.filter { proof in
                guard let result = state.supporterResultsByProof[proof] else { return false }
                return semanticInitializeResult(result) == semanticResult
            })
        }

        state.eligibleSupporterProofs = eligible
        var exposureChanged = false
        if let source = state.initializeSourceProof,
           eligible.contains(source),
           state.initializeResult != nil {
            // The current exposed source remains valid.
        } else {
            exposureChanged = rebindOrClearCanonicalInitialize(state: &state)
        }
        if exposureChanged == false,
           previousEligible != state.eligibleSupporterProofs {
            state.initializeEpoch &+= 1
        }
        return SupportEligibilityUpdate(
            previousResult: previousResult,
            exposedResult: state.initializeResult,
            eligibleProofs: state.eligibleSupporterProofs,
            newlyIneligibleProofs: previousEligible.subtracting(state.eligibleSupporterProofs),
            newlyEligibleProofs: state.eligibleSupporterProofs.subtracting(previousEligible)
        )
    }

    private static func clearInitializeState(state: inout State) {
        state.initializeResult = nil
        state.initializeSemanticResult = nil
        state.initializeSourceProof = nil
        state.supporterResultsByProof.removeAll()
        state.eligibleSupporterProofs.removeAll()
        state.participantsByID.removeAll()
        state.initializeEpoch &+= 1
    }
}
