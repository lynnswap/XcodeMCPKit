import NIOConcurrencyHelpers
import XcodeMCPKit

struct UpstreamTopologyProof: Sendable, Hashable {
    let slotID: UpstreamSlotID
    let slotGeneration: UInt64
}

struct UpstreamOperationLease: Sendable {
    let proof: UpstreamTopologyProof
    let slot: any UpstreamSlotControlling

    var upstreamID: UpstreamSlotID { proof.slotID }
    var upstreamIndex: Int { upstreamID.rawValue }
}

final class UpstreamTopologyAuthority: Sendable {
    struct Entry: Sendable {
        let id: UpstreamSlotID
        let generation: UInt64
        let slot: any UpstreamSlotControlling

        var operationLease: UpstreamOperationLease {
            UpstreamOperationLease(
                proof: UpstreamTopologyProof(slotID: id, slotGeneration: generation),
                slot: slot
            )
        }
    }

    struct Snapshot: Sendable {
        let topologyEpoch: UInt64
        let entries: [Entry]

        var slotIDs: [UpstreamSlotID] { entries.map(\.id) }
        var slots: [any UpstreamSlotControlling] { entries.map(\.slot) }

        func slot(_ id: UpstreamSlotID) -> (any UpstreamSlotControlling)? {
            entries.first { $0.id == id }?.slot
        }

        func proof(_ id: UpstreamSlotID) -> UpstreamTopologyProof? {
            guard entries.contains(where: { $0.id == id }) else { return nil }
            guard let entry = entries.first(where: { $0.id == id }) else { return nil }
            return UpstreamTopologyProof(
                slotID: id,
                slotGeneration: entry.generation
            )
        }

        func operationLease(_ id: UpstreamSlotID) -> UpstreamOperationLease? {
            guard let entry = entries.first(where: { $0.id == id }) else { return nil }
            return entry.operationLease
        }
    }

    struct Transition: Sendable {
        let snapshot: Snapshot
        let addedIDs: [UpstreamSlotID]
        let retired: [Entry]
        let replaced: Entry?
    }

    private struct State: Sendable {
        var topologyEpoch: UInt64 = 0
        var nextRawID: Int = 0
        var entriesByID: [UpstreamSlotID: Entry] = [:]
        var order: [UpstreamSlotID] = []
    }

    private let state: NIOLockedValueBox<State>

    init(_ slots: [any UpstreamSlotControlling]) {
        var initial = State()
        for slot in slots {
            let id = UpstreamSlotID(rawValue: initial.nextRawID)
            initial.nextRawID &+= 1
            initial.entriesByID[id] = Entry(id: id, generation: 1, slot: slot)
            initial.order.append(id)
        }
        if slots.isEmpty == false { initial.topologyEpoch = 1 }
        state = NIOLockedValueBox(initial)
    }

    func append(_ slots: [any UpstreamSlotControlling]) -> Transition {
        state.withLockedValue { state in
            var added: [UpstreamSlotID] = []
            for slot in slots {
                let id = UpstreamSlotID(rawValue: state.nextRawID)
                state.nextRawID &+= 1
                state.entriesByID[id] = Entry(id: id, generation: 1, slot: slot)
                state.order.append(id)
                added.append(id)
            }
            if added.isEmpty == false { state.topologyEpoch &+= 1 }
            return Transition(
                snapshot: Self.snapshot(state),
                addedIDs: added,
                retired: [],
                replaced: nil
            )
        }
    }

    func replace(
        _ proof: UpstreamTopologyProof,
        with slot: any UpstreamSlotControlling
    ) -> Transition? {
        state.withLockedValue { state -> Transition? in
            guard let previous = state.entriesByID[proof.slotID],
                  previous.generation == proof.slotGeneration else { return nil }
            state.entriesByID[proof.slotID] = Entry(
                id: proof.slotID,
                generation: previous.generation &+ 1,
                slot: slot
            )
            state.topologyEpoch &+= 1
            return Transition(
                snapshot: Self.snapshot(state),
                addedIDs: [],
                retired: [],
                replaced: previous
            )
        }
    }

    func retire(_ ids: Set<UpstreamSlotID>) -> Transition {
        state.withLockedValue { state in
            let retired = state.order.compactMap { id in
                ids.contains(id) ? state.entriesByID.removeValue(forKey: id) : nil
            }
            if retired.isEmpty == false {
                state.order.removeAll { ids.contains($0) }
                state.topologyEpoch &+= 1
            }
            return Transition(
                snapshot: Self.snapshot(state),
                addedIDs: [],
                retired: retired,
                replaced: nil
            )
        }
    }

    func retire(_ proof: UpstreamTopologyProof) -> Transition? {
        state.withLockedValue { state -> Transition? in
            guard let retired = state.entriesByID[proof.slotID],
                  retired.generation == proof.slotGeneration else { return nil }
            state.entriesByID.removeValue(forKey: proof.slotID)
            state.order.removeAll { $0 == proof.slotID }
            state.topologyEpoch &+= 1
            return Transition(
                snapshot: Self.snapshot(state),
                addedIDs: [],
                retired: [retired],
                replaced: nil
            )
        }
    }

    func snapshot() -> Snapshot {
        state.withLockedValue { state in Self.snapshot(state) }
    }

    func validate(_ proof: UpstreamTopologyProof) -> Bool {
        state.withLockedValue { state in
            state.entriesByID[proof.slotID]?.generation == proof.slotGeneration
        }
    }

    func operationLease(for proof: UpstreamTopologyProof) -> UpstreamOperationLease? {
        state.withLockedValue { state in
            guard let entry = state.entriesByID[proof.slotID],
                  entry.generation == proof.slotGeneration else { return nil }
            return UpstreamOperationLease(proof: proof, slot: entry.slot)
        }
    }

    func operationLease(for id: UpstreamSlotID) -> UpstreamOperationLease? {
        state.withLockedValue { state in
            guard let entry = state.entriesByID[id] else { return nil }
            return UpstreamOperationLease(
                proof: UpstreamTopologyProof(
                    slotID: id,
                    slotGeneration: entry.generation
                ),
                slot: entry.slot
            )
        }
    }

    func validate(_ lease: UpstreamOperationLease) -> Bool {
        validate(lease.proof)
    }

    func withValidated<Result>(
        _ proof: UpstreamTopologyProof,
        _ operation: () -> Result
    ) -> Result? {
        withValidated([proof], operation)
    }

    func withValidated<Result>(
        _ proofs: [UpstreamTopologyProof],
        _ operation: () -> Result
    ) -> Result? {
        state.withLockedValue { state in
            guard proofs.allSatisfy({ proof in
                state.entriesByID[proof.slotID]?.generation == proof.slotGeneration
            }) else { return nil }
            return operation()
        }
    }

    /// Holds the authoritative topology lock while exposing the exact snapshot
    /// used to validate a handshake-state mutation.
    func withValidatedSnapshot<Result>(
        _ proof: UpstreamTopologyProof,
        _ operation: (Snapshot) -> Result
    ) -> Result? {
        state.withLockedValue { state in
            guard state.entriesByID[proof.slotID]?.generation == proof.slotGeneration else {
                return nil
            }
            return operation(Self.snapshot(state))
        }
    }

    func contains(_ id: UpstreamSlotID) -> Bool {
        state.withLockedValue { $0.entriesByID[id] != nil }
    }

    func slot(_ id: UpstreamSlotID) -> (any UpstreamSlotControlling)? {
        state.withLockedValue { $0.entriesByID[id]?.slot }
    }

    private static func snapshot(_ state: State) -> Snapshot {
        Snapshot(
            topologyEpoch: state.topologyEpoch,
            entries: state.order.compactMap { state.entriesByID[$0] }
        )
    }
}
