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
        let requestSendCompletion: UpstreamRequestSendCompletion?
        let cause: RPCCancellationCause

        var upstreamIndex: Int? { operationLease?.upstreamIndex }

        init(
            registrationToken: UUID?,
            operationLease: UpstreamOperationLease?,
            requestIDKey: String?,
            requestSendCompletion: UpstreamRequestSendCompletion?,
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
        typealias CancellationHandler = @Sendable (
            ControlPlane.RPCCancelSnapshot,
            ControlPlane.RPCCancellationDelivery
        ) -> Void

        private enum State: Sendable {
            case idle
            case armed(CancellationHandler)
            case registered(
                onCancel: CancellationHandler,
                registrationToken: UUID,
                operationLease: UpstreamOperationLease
            )
            case assigned(
                onCancel: CancellationHandler,
                registrationToken: UUID,
                operationLease: UpstreamOperationLease,
                requestIDKey: String,
                requestSendCompletion: UpstreamRequestSendCompletion
            )
            case finished
            case cancelled(
                snapshot: ControlPlane.RPCCancelSnapshot,
                delivery: ControlPlane.RPCCancellationDelivery
            )
        }

        private let state = NIOLockedValueBox<State>(.idle)

        init() {}

        @discardableResult
        func installCancel(
            _ onCancel: @escaping @Sendable (ControlPlane.RPCCancelSnapshot) -> Void
        ) -> Bool {
            installCancelWithDelivery { snapshot, delivery in
                onCancel(snapshot)
                delivery.complete(.noLongerApplicable)
            }
        }

        @discardableResult
        func installCancelWithDelivery(
            _ onCancel: @escaping CancellationHandler
        ) -> Bool {
            state.withLockedValue { state in
                switch state {
                case .idle:
                    state = .armed(onCancel)
                    return true
                case .cancelled, .finished:
                    return false
                case .armed, .registered, .assigned:
                    preconditionFailure(
                        "RPC handle cancellation handler may only be installed once"
                    )
                }
            }
        }

        func markRegistered(
            registrationToken: UUID,
            operationLease: UpstreamOperationLease
        ) -> Bool {
            state.withLockedValue { state in
                switch state {
                case .armed(let onCancel):
                    state = .registered(
                        onCancel: onCancel,
                        registrationToken: registrationToken,
                        operationLease: operationLease
                    )
                    return true
                case .idle, .cancelled, .finished, .registered, .assigned:
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
                switch state {
                case .registered(
                    let onCancel,
                    let token,
                    let registeredOperationLease
                ):
                    guard token == registrationToken,
                          registeredOperationLease.proof == operationLease.proof
                    else {
                        return false
                    }
                    let requestSendCompletion = UpstreamRequestSendCompletion()
                    state = .assigned(
                        onCancel: onCancel,
                        registrationToken: registrationToken,
                        operationLease: operationLease,
                        requestIDKey: requestIDKey,
                        requestSendCompletion: requestSendCompletion
                    )
                    return true
                case .idle, .armed, .assigned, .cancelled, .finished:
                    return false
                }
            }
        }

        func markFinished() {
            state.withLockedValue { state in
                switch state {
                case .idle, .armed, .registered, .assigned:
                    state = .finished
                case .finished, .cancelled:
                    return
                }
            }
        }

        func requestSendCompletion() -> UpstreamRequestSendCompletion? {
            state.withLockedValue { state in
                switch state {
                case .assigned(_, _, _, _, let requestSendCompletion):
                    return requestSendCompletion
                case .cancelled(let snapshot, _):
                    return snapshot.requestSendCompletion
                case .idle, .armed, .registered, .finished:
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
                onCancel: CancellationHandler?,
                snapshot: ControlPlane.RPCCancelSnapshot,
                completesImmediately: Bool
            )? in
                let snapshot: ControlPlane.RPCCancelSnapshot
                let onCancel: CancellationHandler?
                let completesImmediately: Bool
                switch state {
                case .finished:
                    return nil
                case .cancelled(let snapshot, let delivery):
                    return (delivery, nil, snapshot, false)
                case .idle:
                    snapshot = ControlPlane.RPCCancelSnapshot(
                        registrationToken: nil,
                        operationLease: nil,
                        requestIDKey: nil,
                        requestSendCompletion: nil,
                        cause: cause
                    )
                    onCancel = nil
                    completesImmediately = true
                case .armed(let handler):
                    snapshot = ControlPlane.RPCCancelSnapshot(
                        registrationToken: nil,
                        operationLease: nil,
                        requestIDKey: nil,
                        requestSendCompletion: nil,
                        cause: cause
                    )
                    onCancel = handler
                    completesImmediately = false
                case .registered(let handler, let registrationToken, _):
                    snapshot = ControlPlane.RPCCancelSnapshot(
                        registrationToken: registrationToken,
                        operationLease: nil,
                        requestIDKey: nil,
                        requestSendCompletion: nil,
                        cause: cause
                    )
                    onCancel = handler
                    completesImmediately = false
                case .assigned(
                    let handler,
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
                    onCancel = handler
                    completesImmediately = false
                }
                let delivery = ControlPlane.RPCCancellationDelivery()
                state = .cancelled(snapshot: snapshot, delivery: delivery)
                return (delivery, onCancel, snapshot, completesImmediately)
            }
            guard let cancellation else { return nil }
            if let onCancel = cancellation.onCancel {
                onCancel(cancellation.snapshot, cancellation.delivery)
            } else if cancellation.completesImmediately {
                cancellation.delivery.complete(.noLongerApplicable)
            }
            return cancellation.delivery
        }

        func isCancelled() -> Bool {
            state.withLockedValue { state in
                if case .cancelled = state {
                    return true
                }
                return false
            }
        }

        func isBound(to proof: UpstreamTopologyProof) -> Bool {
            state.withLockedValue { state in
                switch state {
                case .registered(_, _, let operationLease),
                     .assigned(_, _, let operationLease, _, _):
                    return operationLease.proof == proof
                case .cancelled(let snapshot, _):
                    return snapshot.operationLease?.proof == proof
                case .idle, .armed, .finished:
                    return false
                }
            }
        }
    }
}
