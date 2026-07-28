import Foundation
import NIOConcurrencyHelpers
import XcodeMCPKit

enum ControlPlane {}

extension ControlPlane {
    enum Route: Hashable, Sendable {
        case anyHealthy
        case pinnedUpstream(Int)

        var debugLabel: String {
            switch self {
            case .anyHealthy:
                return "any_healthy"
            case .pinnedUpstream(let upstreamIndex):
                return "pinned_\(upstreamIndex)"
            }
        }
    }
}

struct CanonicalToolsCatalogLoadResult: Sendable {
    let rawResult: JSONValue
    let sourceProof: UpstreamTopologyProof?
    let durationMilliseconds: Int

    var sourceUpstream: Int? { sourceProof?.slotID.rawValue }

    init(
        rawResult: JSONValue,
        sourceProof: UpstreamTopologyProof?,
        durationMilliseconds: Int
    ) {
        self.rawResult = rawResult
        self.sourceProof = sourceProof
        self.durationMilliseconds = durationMilliseconds
    }
}

extension ControlPlane {
    struct WaiterCounts: Codable, Sendable {
        let initialize: Int
        let toolsCatalog: Int
        let windows: Int
    }
}

extension ControlPlane {
    struct DebugSnapshot: Codable, Sendable {
        let phase: String
        let canonicalInitializeSourceUpstream: Int?
        let canonicalToolsSourceUpstream: Int?
        let canonicalReady: Bool
        let upstreamHandshakeStates: [String: String]
        let waiterCounts: ControlPlane.WaiterCounts
        let inFlightControlPlaneRequests: [String]
        let lastIncompatibility: CanonicalHandshakeState.Incompatibility?
    }
}

extension ControlPlane {
    final class DebugMirror: Sendable {
        private struct Waiter {
            let id: UUID
            let predicate: @Sendable (ControlPlane.DebugSnapshot) -> Bool
            let continuation: CheckedContinuation<ControlPlane.DebugSnapshot, any Swift.Error>
        }

        private struct State {
            var snapshot: ControlPlane.DebugSnapshot?
            var waiters: [Waiter] = []
        }

        private let state = NIOLockedValueBox(State())

        init() {}

        func snapshot() -> ControlPlane.DebugSnapshot? {
            state.withLockedValue { $0.snapshot }
        }

        func overwrite(_ snapshot: ControlPlane.DebugSnapshot?) {
            let resumptions = state.withLockedValue { state -> [Waiter] in
                state.snapshot = snapshot
                guard let snapshot else {
                    return []
                }
                var ready: [Waiter] = []
                var remaining: [Waiter] = []
                for waiter in state.waiters {
                    if waiter.predicate(snapshot) {
                        ready.append(waiter)
                    } else {
                        remaining.append(waiter)
                    }
                }
                state.waiters = remaining
                return ready
            }

            if let snapshot {
                for waiter in resumptions {
                    waiter.continuation.resume(returning: snapshot)
                }
            }
        }

        func waitForSnapshot(
            matching predicate: @escaping @Sendable (ControlPlane.DebugSnapshot) -> Bool
        ) async throws -> ControlPlane.DebugSnapshot {
            if let snapshot = self.snapshot(), predicate(snapshot) {
                return snapshot
            }

            let waiterID = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let immediate = state.withLockedValue {
                        state -> ControlPlane.DebugSnapshot? in
                        if let snapshot = state.snapshot, predicate(snapshot) {
                            return snapshot
                        }
                        state.waiters.append(
                            Waiter(
                                id: waiterID,
                                predicate: predicate,
                                continuation: continuation
                            )
                        )
                        return nil
                    }
                    if let immediate {
                        continuation.resume(returning: immediate)
                    }
                }
            } onCancel: {
                cancelWaiter(id: waiterID)
            }
        }

        private func cancelWaiter(id: UUID) {
            let waiter = state.withLockedValue { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}

extension ControlPlane {
    enum RPCCancellationCause: Sendable, Equatable {
        case cancelled
        case timedOut
    }

    struct RPCCancelSnapshot: Sendable {
        let registrationToken: UUID?
        let operationLease: UpstreamOperationLease?
        let requestIDKey: String?
        let requestSendCompletion: AsyncTerminalSignal?
        let cause: RPCCancellationCause

        var upstreamIndex: Int? { operationLease?.upstreamIndex }

        init(
            registrationToken: UUID?,
            operationLease: UpstreamOperationLease?,
            requestIDKey: String?,
            requestSendCompletion: AsyncTerminalSignal?,
            cause: RPCCancellationCause
        ) {
            self.registrationToken = registrationToken
            self.operationLease = operationLease
            self.requestIDKey = requestIDKey
            self.requestSendCompletion = requestSendCompletion
            self.cause = cause
        }
    }

    final class RPCCancellationDelivery: @unchecked Sendable {
        enum Result: Sendable, Equatable {
            case delivered
            case noLongerApplicable
            case rejected

            var allowsRetryScheduling: Bool {
                self != .rejected
            }
        }

        private struct DeliveryState {
            var result: Result?
            var waiters: [CheckedContinuation<Result, Never>] = []
        }

        private let state = NIOLockedValueBox(DeliveryState())

        func complete(_ result: Result) {
            let waiters = state.withLockedValue {
                state -> [CheckedContinuation<Result, Never>] in
                guard state.result == nil else { return [] }
                state.result = result
                let waiters = state.waiters
                state.waiters.removeAll()
                return waiters
            }
            for waiter in waiters {
                waiter.resume(returning: result)
            }
        }

        func wait() async -> Result {
            await withCheckedContinuation { continuation in
                let result = state.withLockedValue { state -> Result? in
                    if let result = state.result {
                        return result
                    }
                    state.waiters.append(continuation)
                    return nil
                }
                if let result {
                    continuation.resume(returning: result)
                }
            }
        }
    }
}

extension ControlPlane {
    final class RPCHandle: Sendable {
        enum State: Sendable {
            case queued
            case registered(registrationToken: UUID, operationLease: UpstreamOperationLease)
            case assigned(
                registrationToken: UUID,
                operationLease: UpstreamOperationLease,
                requestIDKey: String,
                requestSendCompletion: AsyncTerminalSignal
            )
            case finished
            case cancelled(ControlPlane.RPCCancelSnapshot)
        }

        private struct HandleState: Sendable {
            var state: State = .queued
            var onCancel: (
                @Sendable (
                    ControlPlane.RPCCancelSnapshot,
                    ControlPlane.RPCCancellationDelivery
                ) -> Void
            )?
            var cancellationDelivery: ControlPlane.RPCCancellationDelivery?
        }

        private let state = NIOLockedValueBox(HandleState())

        init() {}

        func installCancel(
            _ onCancel: @escaping @Sendable (ControlPlane.RPCCancelSnapshot) -> Void
        ) {
            installCancelWithDelivery { snapshot, delivery in
                onCancel(snapshot)
                delivery.complete(.noLongerApplicable)
            }
        }

        func installCancelWithDelivery(
            _ onCancel: @escaping @Sendable (
                ControlPlane.RPCCancelSnapshot,
                ControlPlane.RPCCancellationDelivery
            ) -> Void
        ) {
            let pendingCancellation = state.withLockedValue {
                state -> (
                    ControlPlane.RPCCancelSnapshot,
                    ControlPlane.RPCCancellationDelivery
                )? in
                state.onCancel = onCancel
                if case .cancelled(let snapshot) = state.state {
                    let delivery =
                        state.cancellationDelivery
                        ?? ControlPlane.RPCCancellationDelivery()
                    state.cancellationDelivery = delivery
                    return (snapshot, delivery)
                }
                return nil
            }
            if let (snapshot, delivery) = pendingCancellation {
                onCancel(snapshot, delivery)
            }
        }

        func markRegistered(
            registrationToken: UUID,
            operationLease: UpstreamOperationLease
        ) -> Bool {
            state.withLockedValue { state in
                switch state.state {
                case .queued:
                    state.state = .registered(
                        registrationToken: registrationToken,
                        operationLease: operationLease
                    )
                    return true
                case .cancelled, .finished, .registered, .assigned:
                    return false
                }
            }
        }

        func markAssigned(
            registrationToken: UUID,
            operationLease: UpstreamOperationLease,
            requestIDKey: String
        ) -> Bool {
            state.withLockedValue { state in
                switch state.state {
                case .registered(let token, let registeredOperationLease):
                    guard token == registrationToken,
                          registeredOperationLease.proof == operationLease.proof
                    else {
                        return false
                    }
                    let requestSendCompletion = AsyncTerminalSignal()
                    state.state = .assigned(
                        registrationToken: registrationToken,
                        operationLease: operationLease,
                        requestIDKey: requestIDKey,
                        requestSendCompletion: requestSendCompletion
                    )
                    return true
                case .queued, .assigned, .cancelled, .finished:
                    return false
                }
            }
        }

        func markFinished() {
            state.withLockedValue { state in
                switch state.state {
                case .queued, .registered, .assigned:
                    state.state = .finished
                case .finished, .cancelled:
                    return
                }
            }
        }

        func requestSendCompletion() -> AsyncTerminalSignal? {
            state.withLockedValue { state in
                switch state.state {
                case .assigned(_, _, _, let requestSendCompletion):
                    return requestSendCompletion
                case .cancelled(let snapshot):
                    return snapshot.requestSendCompletion
                case .queued, .registered, .finished:
                    return nil
                }
            }
        }

        @discardableResult
        func cancel(
            cause: ControlPlane.RPCCancellationCause = .cancelled
        ) -> ControlPlane.RPCCancellationDelivery? {
            let cancellation = state.withLockedValue { state -> (
                delivery: ControlPlane.RPCCancellationDelivery,
                onCancel: (
                    @Sendable (
                        ControlPlane.RPCCancelSnapshot,
                        ControlPlane.RPCCancellationDelivery
                    ) -> Void
                )?,
                snapshot: ControlPlane.RPCCancelSnapshot?
            )? in
                let snapshot: ControlPlane.RPCCancelSnapshot
                switch state.state {
                case .finished:
                    return nil
                case .cancelled:
                    guard let delivery = state.cancellationDelivery else {
                        preconditionFailure(
                            "cancelled RPC handle must own its cancellation delivery"
                        )
                    }
                    return (delivery, nil, nil)
                case .queued:
                    snapshot = ControlPlane.RPCCancelSnapshot(
                        registrationToken: nil,
                        operationLease: nil,
                        requestIDKey: nil,
                        requestSendCompletion: nil,
                        cause: cause
                    )
                case .registered(let registrationToken, let operationLease):
                    snapshot = ControlPlane.RPCCancelSnapshot(
                        registrationToken: registrationToken,
                        operationLease: operationLease,
                        requestIDKey: nil,
                        requestSendCompletion: nil,
                        cause: cause
                    )
                case .assigned(
                    let registrationToken,
                    let operationLease,
                    let requestIDKey,
                    let requestSendCompletion
                ):
                    snapshot = ControlPlane.RPCCancelSnapshot(
                        registrationToken: registrationToken,
                        operationLease: operationLease,
                        requestIDKey: requestIDKey,
                        requestSendCompletion: requestSendCompletion,
                        cause: cause
                    )
                }
                let delivery = ControlPlane.RPCCancellationDelivery()
                state.state = .cancelled(snapshot)
                state.cancellationDelivery = delivery
                return (delivery, state.onCancel, snapshot)
            }
            guard let cancellation else { return nil }
            if let onCancel = cancellation.onCancel,
               let snapshot = cancellation.snapshot {
                onCancel(snapshot, cancellation.delivery)
            }
            return cancellation.delivery
        }

        func isCancelled() -> Bool {
            state.withLockedValue { state in
                if case .cancelled = state.state {
                    return true
                }
                return false
            }
        }

        func isBound(to proof: UpstreamTopologyProof) -> Bool {
            state.withLockedValue { state in
                switch state.state {
                case .registered(_, let operationLease),
                     .assigned(_, let operationLease, _, _):
                    return operationLease.proof == proof
                case .cancelled(let snapshot):
                    return snapshot.operationLease?.proof == proof
                case .queued, .finished:
                    return false
                }
            }
        }
    }
}
