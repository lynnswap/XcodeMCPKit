import XcodeMCPKit
import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers

struct UpstreamSlotSchedulerTestHooks: Sendable {
    var requestQueued:
        @Sendable (
            _ leaseID: LeaseManager.ID,
            _ descriptor: SessionRequestPipeline.Descriptor,
            _ queuedRequestCount: Int
        ) -> Void

    init(
        requestQueued: @escaping @Sendable (
            _ leaseID: LeaseManager.ID,
            _ descriptor: SessionRequestPipeline.Descriptor,
            _ queuedRequestCount: Int
        ) -> Void = { _, _, _ in }
    ) {
        self.requestQueued = requestQueued
    }

    static let noop = Self()
}

final class UpstreamSlotScheduler: Sendable {
    enum AcquisitionError: Error {
        case unavailable
    }

    struct DebugSnapshot: Codable, Sendable {
        let queuedRequestCount: Int
        let activeLeaseCountByUpstream: [Int: Int]

        init(
            queuedRequestCount: Int,
            activeLeaseCountByUpstream: [Int: Int]
        ) {
            self.queuedRequestCount = queuedRequestCount
            self.activeLeaseCountByUpstream = activeLeaseCountByUpstream
        }
    }

    private struct PendingRequest: Sendable {
        let leaseID: LeaseManager.ID
        let descriptor: SessionRequestPipeline.Descriptor
        let eventLoop: EventLoop
        let preferredUpstreamIndices: [Int]
        let start: @Sendable (UpstreamOperationLease) -> Void
        let failUnavailable: @Sendable () -> Void
        let failCancelled: @Sendable () -> Void
    }

    private struct Reservation: Sendable {
        let request: PendingRequest
        let operationLease: UpstreamOperationLease
        var hasStarted = false

        var upstreamIndex: Int { operationLease.upstreamIndex }
    }

    private struct State: Sendable {
        var pendingRequests: [PendingRequest] = []
        var activeLeaseIDsByUpstream: [Int: LeaseManager.ID] = [:]
        var activeTopLevelLeaseIDsBySession: [String: LeaseManager.ID] = [:]
        var reservationsByLeaseID: [LeaseManager.ID: Reservation] = [:]
    }

    private let logger: Logger
    private let state: NIOLockedValueBox<State>
    private let canUseUpstream: @Sendable (Int) -> UpstreamHealthManager.UseEvaluation
    private let selectUpstream: @Sendable (Set<Int>) -> UpstreamHealthManager.SelectionResult
    private let operationLease:
        @Sendable (UpstreamTopologyProof) -> UpstreamOperationLease?
    private let validateOperationLease: @Sendable (UpstreamOperationLease) -> Bool
    private let applyHealthEffects: @Sendable ([UpstreamHealthManager.Effect]) -> Void
    private let testHooks: UpstreamSlotSchedulerTestHooks

    init(
        logger: Logger = XcodeMCPRuntimeLogging.make("upstream.scheduler"),
        canUseUpstream: @escaping @Sendable (Int) -> UpstreamHealthManager.UseEvaluation,
        selectUpstream: @escaping @Sendable (Set<Int>) -> UpstreamHealthManager.SelectionResult,
        operationLease: @escaping @Sendable (UpstreamTopologyProof) -> UpstreamOperationLease?,
        validateOperationLease: @escaping @Sendable (UpstreamOperationLease) -> Bool,
        applyHealthEffects: @escaping @Sendable ([UpstreamHealthManager.Effect]) -> Void = { _ in },
        testHooks: UpstreamSlotSchedulerTestHooks = .noop
    ) {
        self.logger = logger
        self.canUseUpstream = canUseUpstream
        self.selectUpstream = selectUpstream
        self.operationLease = operationLease
        self.validateOperationLease = validateOperationLease
        self.applyHealthEffects = applyHealthEffects
        self.testHooks = testHooks
        self.state = NIOLockedValueBox(
            State(
                pendingRequests: [],
                activeLeaseIDsByUpstream: [:]
            )
        )
    }

    func enqueueRequest(
        leaseID: LeaseManager.ID,
        descriptor: SessionRequestPipeline.Descriptor,
        on eventLoop: EventLoop,
        preferredUpstreamIndex: Int? = nil,
        starter: @escaping @Sendable (UpstreamOperationLease) -> Void,
        failUnavailable: @escaping @Sendable () -> Void,
        failCancelled: @escaping @Sendable () -> Void
    ) {
        enqueueRequest(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop,
            preferredUpstreamIndices: preferredUpstreamIndex.map { [$0] } ?? [],
            starter: starter,
            failUnavailable: failUnavailable,
            failCancelled: failCancelled
        )
    }

    func enqueueRequest(
        leaseID: LeaseManager.ID,
        descriptor: SessionRequestPipeline.Descriptor,
        on eventLoop: EventLoop,
        preferredUpstreamIndices: [Int],
        starter: @escaping @Sendable (UpstreamOperationLease) -> Void,
        failUnavailable: @escaping @Sendable () -> Void,
        failCancelled: @escaping @Sendable () -> Void
    ) {
        let request = PendingRequest(
            leaseID: leaseID,
            descriptor: descriptor,
            eventLoop: eventLoop,
            preferredUpstreamIndices: Self.uniquePreferredUpstreamIndices(
                preferredUpstreamIndices
            ),
            start: starter,
            failUnavailable: failUnavailable,
            failCancelled: failCancelled
        )

        let queuedRequestCount = state.withLockedValue { state in
            state.pendingRequests.append(request)
            return state.pendingRequests.count
        }
        testHooks.requestQueued(leaseID, descriptor, queuedRequestCount)
        dispatchQueuedRequestsIfPossible()
    }

    private static func uniquePreferredUpstreamIndices(_ indices: [Int]) -> [Int] {
        var seen = Set<Int>()
        return indices.filter { index in
            guard index >= 0, seen.contains(index) == false else {
                return false
            }
            seen.insert(index)
            return true
        }
    }

    func releaseUpstreamSlot(upstreamIndex: Int, leaseID: LeaseManager.ID) {
        let released = state.withLockedValue { state -> Bool in
            guard state.activeLeaseIDsByUpstream[upstreamIndex] == leaseID else { return false }
            state.activeLeaseIDsByUpstream.removeValue(forKey: upstreamIndex)
            if let reservation = state.reservationsByLeaseID.removeValue(forKey: leaseID),
                reservation.request.descriptor.isTopLevelClientRequest,
                state.activeTopLevelLeaseIDsBySession[reservation.request.descriptor.sessionID]
                    == leaseID
            {
                state.activeTopLevelLeaseIDsBySession.removeValue(
                    forKey: reservation.request.descriptor.sessionID
                )
            }
            return true
        }
        guard released else { return }
        logger.debug(
            "Released upstream slot",
            metadata: [
                "lease_id": .string(leaseID.uuidString),
                "upstream": .string("\(upstreamIndex)"),
            ]
        )
        dispatchQueuedRequestsIfPossible()
    }

    func failQueuedRequests() {
        let failed = state.withLockedValue { state -> [PendingRequest] in
            let pending = state.pendingRequests
            state.pendingRequests.removeAll()
            let reserved = state.reservationsByLeaseID.values
                .filter { $0.hasStarted == false }
                .map(\.request)

            for reservation in state.reservationsByLeaseID.values
            where reservation.hasStarted == false {
                if state.activeLeaseIDsByUpstream[reservation.upstreamIndex]
                    == reservation.request.leaseID
                {
                    state.activeLeaseIDsByUpstream.removeValue(forKey: reservation.upstreamIndex)
                }
                if reservation.request.descriptor.isTopLevelClientRequest,
                    state.activeTopLevelLeaseIDsBySession[reservation.request.descriptor.sessionID]
                        == reservation.request.leaseID
                {
                    state.activeTopLevelLeaseIDsBySession.removeValue(
                        forKey: reservation.request.descriptor.sessionID
                    )
                }
            }
            state.reservationsByLeaseID = state.reservationsByLeaseID.filter { _, reservation in
                reservation.hasStarted
            }

            return pending + reserved
        }
        guard failed.isEmpty == false else { return }

        for request in failed {
            logger.debug(
                "Failing queued request before upstream dispatch",
                metadata: [
                    "lease_id": .string(request.leaseID.uuidString),
                    "label": .string(request.descriptor.label),
                ]
            )
            request.eventLoop.execute {
                request.failUnavailable()
            }
        }
    }

    func cancelQueuedRequest(leaseID: LeaseManager.ID) {
        enum CancelledRequest {
            case pending(PendingRequest)
            case reserved(PendingRequest, Int)
        }

        let removed = state.withLockedValue { state -> CancelledRequest? in
            guard let index = state.pendingRequests.firstIndex(where: { $0.leaseID == leaseID })
            else {
                guard let reservation = state.reservationsByLeaseID[leaseID],
                    reservation.hasStarted == false
                else {
                    return nil
                }
                state.reservationsByLeaseID.removeValue(forKey: leaseID)
                if state.activeLeaseIDsByUpstream[reservation.upstreamIndex] == leaseID {
                    state.activeLeaseIDsByUpstream.removeValue(forKey: reservation.upstreamIndex)
                }
                if reservation.request.descriptor.isTopLevelClientRequest,
                    state.activeTopLevelLeaseIDsBySession[reservation.request.descriptor.sessionID]
                        == leaseID
                {
                    state.activeTopLevelLeaseIDsBySession.removeValue(
                        forKey: reservation.request.descriptor.sessionID
                    )
                }
                return .reserved(reservation.request, reservation.upstreamIndex)
            }
            return .pending(state.pendingRequests.remove(at: index))
        }
        guard let removed else { return }

        let request: PendingRequest
        let wasReserved = if case .reserved = removed { true } else { false }
        switch removed {
        case .pending(let pendingRequest):
            request = pendingRequest
        case .reserved(let reservedRequest, _):
            request = reservedRequest
        }

        logger.debug(
            "Cancelled queued request before upstream dispatch",
            metadata: [
                "lease_id": .string(leaseID.uuidString)
            ]
        )
        request.eventLoop.execute {
            request.failCancelled()
        }
        if wasReserved {
            dispatchQueuedRequestsIfPossible()
        }
    }

    func debugSnapshot() -> UpstreamSlotScheduler.DebugSnapshot {
        state.withLockedValue { state in
            UpstreamSlotScheduler.DebugSnapshot(
                queuedRequestCount: state.pendingRequests.count,
                activeLeaseCountByUpstream: state.activeLeaseIDsByUpstream.reduce(into: [:]) {
                    counts, item in
                    counts[item.key] = 1
                }
            )
        }
    }

    func occupiedUpstreamIndices() -> Set<Int> {
        state.withLockedValue { Set($0.activeLeaseIDsByUpstream.keys) }
    }

    func reset() {
        let cancelled = state.withLockedValue { state -> [PendingRequest] in
            let pendingRequests = state.pendingRequests
            let reservedRequests = state.reservationsByLeaseID.values
                .filter { $0.hasStarted == false }
                .map(\.request)
            state.pendingRequests.removeAll()
            state.activeLeaseIDsByUpstream.removeAll()
            state.activeTopLevelLeaseIDsBySession.removeAll()
            state.reservationsByLeaseID.removeAll()
            return pendingRequests + reservedRequests
        }

        for request in cancelled {
            logger.debug(
                "Cancelled queued request during scheduler reset",
                metadata: [
                    "lease_id": .string(request.leaseID.uuidString),
                    "label": .string(request.descriptor.label),
                ]
            )
            request.eventLoop.execute {
                request.failCancelled()
            }
        }
    }

    func wake() {
        dispatchQueuedRequestsIfPossible()
    }

    private func dispatchQueuedRequestsIfPossible() {
        let dispatch = state.withLockedValue {
            state -> (
                starts: [(PendingRequest, UpstreamOperationLease)],
                unavailable: [PendingRequest],
                healthEffects: [UpstreamHealthManager.Effect]
            ) in
            var ready: [(PendingRequest, UpstreamOperationLease)] = []
            var unavailable: [PendingRequest] = []
            var healthEffects: [UpstreamHealthManager.Effect] = []

            while state.pendingRequests.isEmpty == false {
                let occupied = Set(state.activeLeaseIDsByUpstream.keys)
                var chosenPendingIndex: Int?
                var chosenOperationLease: UpstreamOperationLease?
                var unavailablePendingIndex: Int?

                for (pendingIndex, request) in state.pendingRequests.enumerated() {
                    if request.descriptor.isTopLevelClientRequest,
                        state.activeTopLevelLeaseIDsBySession[request.descriptor.sessionID] != nil
                    {
                        continue
                    }

                    if request.preferredUpstreamIndices.isEmpty == false {
                        var preferredCandidateIsOccupied = false
                        var preferredRecoveryStarted = false
                        for preferredUpstreamIndex in request.preferredUpstreamIndices {
                            guard state.activeLeaseIDsByUpstream[preferredUpstreamIndex] == nil
                            else {
                                preferredCandidateIsOccupied = true
                                continue
                            }
                            let evaluation = canUseUpstream(preferredUpstreamIndex)
                            healthEffects.append(contentsOf: evaluation.effects)
                            if Self.effectsStartRecovery(evaluation.effects) {
                                preferredRecoveryStarted = true
                            }
                            guard evaluation.isUsable else {
                                continue
                            }
                            guard let proof = evaluation.proof,
                                  let lease = operationLease(proof) else { continue }
                            chosenPendingIndex = pendingIndex
                            chosenOperationLease = lease
                            break
                        }
                        if chosenPendingIndex != nil {
                            break
                        } else if preferredCandidateIsOccupied || preferredRecoveryStarted {
                            continue
                        } else {
                            unavailablePendingIndex = pendingIndex
                            break
                        }
                    }

                    let selection = selectUpstream(occupied)
                    healthEffects.append(contentsOf: selection.effects)
                    guard let proof = selection.proof,
                          let selectedLease = operationLease(proof) else {
                        break
                    }
                    let selectedUpstreamIndex = selectedLease.upstreamIndex
                    guard state.activeLeaseIDsByUpstream[selectedUpstreamIndex] == nil else {
                        break
                    }
                    chosenPendingIndex = pendingIndex
                    chosenOperationLease = selectedLease
                    break
                }

                if let unavailablePendingIndex {
                    let pendingRequest = state.pendingRequests.remove(at: unavailablePendingIndex)
                    unavailable.append(pendingRequest)
                    continue
                }

                guard let chosenPendingIndex, let chosenOperationLease else {
                    break
                }

                let pendingRequest = state.pendingRequests.remove(at: chosenPendingIndex)
                let upstreamIndex = chosenOperationLease.upstreamIndex
                state.activeLeaseIDsByUpstream[upstreamIndex] = pendingRequest.leaseID
                state.reservationsByLeaseID[pendingRequest.leaseID] = Reservation(
                    request: pendingRequest,
                    operationLease: chosenOperationLease
                )
                if pendingRequest.descriptor.isTopLevelClientRequest {
                    state.activeTopLevelLeaseIDsBySession[pendingRequest.descriptor.sessionID] =
                        pendingRequest.leaseID
                }
                ready.append((pendingRequest, chosenOperationLease))
            }

            return (ready, unavailable, healthEffects)
        }

        if dispatch.healthEffects.isEmpty == false {
            applyHealthEffects(dispatch.healthEffects)
        }

        for request in dispatch.unavailable {
            logger.debug(
                "Failing queued preferred request because all preferred upstreams are unavailable",
                metadata: [
                    "lease_id": .string(request.leaseID.uuidString),
                    "label": .string(request.descriptor.label),
                ]
            )
            request.eventLoop.execute {
                request.failUnavailable()
            }
        }

        for (request, operationLease) in dispatch.starts {
            let upstreamIndex = operationLease.upstreamIndex
            logger.debug(
                "Dispatching queued request to upstream slot",
                metadata: [
                    "lease_id": .string(request.leaseID.uuidString),
                    "label": .string(request.descriptor.label),
                    "upstream": .string("\(upstreamIndex)"),
                ]
            )
            request.eventLoop.execute {
                let shouldStart = self.state.withLockedValue { state -> Bool in
                    guard var reservation = state.reservationsByLeaseID[request.leaseID],
                        reservation.operationLease.proof == operationLease.proof
                    else {
                        return false
                    }
                    reservation.hasStarted = true
                    state.reservationsByLeaseID[request.leaseID] = reservation
                    return true
                }
                guard shouldStart else { return }
                guard self.validateOperationLease(operationLease) else {
                    self.releaseUpstreamSlot(
                        upstreamIndex: upstreamIndex,
                        leaseID: request.leaseID
                    )
                    request.failUnavailable()
                    return
                }
                request.start(operationLease)
            }
        }
    }

    private static func effectsStartRecovery(_ effects: [UpstreamHealthManager.Effect]) -> Bool {
        effects.contains { effect in
            if case .startHealthProbe = effect {
                return true
            }
            return false
        }
    }
}
