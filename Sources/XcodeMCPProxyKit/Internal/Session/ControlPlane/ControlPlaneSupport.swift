import Foundation
import NIOConcurrencyHelpers
import XcodeMCPCore
import XcodeMCPProcessRuntime

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
    let sourceUpstream: Int?
    let durationMilliseconds: Int

    init(rawResult: JSONValue, sourceUpstream: Int?, durationMilliseconds: Int) {
        self.rawResult = rawResult
        self.sourceUpstream = sourceUpstream
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
        let lastIncompatibility: CanonicalBrokerState.Incompatibility?
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
    struct RPCCancelSnapshot: Sendable {
        let registrationToken: UUID?
        let upstreamIndex: Int?
        let requestIDKey: String?

        init(
            registrationToken: UUID?,
            upstreamIndex: Int?,
            requestIDKey: String?
        ) {
            self.registrationToken = registrationToken
            self.upstreamIndex = upstreamIndex
            self.requestIDKey = requestIDKey
        }
    }
}

extension ControlPlane {
    final class RPCHandle: Sendable {
        enum State: Sendable {
            case queued
            case registered(registrationToken: UUID, upstreamIndex: Int)
            case assigned(registrationToken: UUID, upstreamIndex: Int, requestIDKey: String)
            case finished
            case cancelled(ControlPlane.RPCCancelSnapshot)
        }

        private struct HandleState: Sendable {
            var state: State = .queued
            var onCancel: (@Sendable (ControlPlane.RPCCancelSnapshot) -> Void)?
        }

        private let state = NIOLockedValueBox(HandleState())

        init() {}

        func installCancel(
            _ onCancel: @escaping @Sendable (ControlPlane.RPCCancelSnapshot) -> Void
        ) {
            let snapshot = state.withLockedValue { state -> ControlPlane.RPCCancelSnapshot? in
                state.onCancel = onCancel
                if case .cancelled(let snapshot) = state.state {
                    return snapshot
                }
                return nil
            }
            if let snapshot {
                onCancel(snapshot)
            }
        }

        func markRegistered(
            registrationToken: UUID,
            upstreamIndex: Int
        ) -> Bool {
            state.withLockedValue { state in
                switch state.state {
                case .queued:
                    state.state = .registered(
                        registrationToken: registrationToken,
                        upstreamIndex: upstreamIndex
                    )
                    return true
                case .cancelled, .finished, .registered, .assigned:
                    return false
                }
            }
        }

        func markAssigned(
            registrationToken: UUID,
            upstreamIndex: Int,
            requestIDKey: String
        ) -> Bool {
            state.withLockedValue { state in
                switch state.state {
                case .registered(let token, let registeredUpstreamIndex):
                    guard token == registrationToken, registeredUpstreamIndex == upstreamIndex
                    else {
                        return false
                    }
                    state.state = .assigned(
                        registrationToken: registrationToken,
                        upstreamIndex: upstreamIndex,
                        requestIDKey: requestIDKey
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

        func cancel() {
            let cancellation = state.withLockedValue {
                state -> (
                    (@Sendable (ControlPlane.RPCCancelSnapshot) -> Void),
                    ControlPlane.RPCCancelSnapshot
                )? in
                let snapshot: ControlPlane.RPCCancelSnapshot
                switch state.state {
                case .finished, .cancelled:
                    return nil
                case .queued:
                    snapshot = ControlPlane.RPCCancelSnapshot(
                        registrationToken: nil,
                        upstreamIndex: nil,
                        requestIDKey: nil
                    )
                case .registered(let registrationToken, let upstreamIndex):
                    snapshot = ControlPlane.RPCCancelSnapshot(
                        registrationToken: registrationToken,
                        upstreamIndex: upstreamIndex,
                        requestIDKey: nil
                    )
                case .assigned(let registrationToken, let upstreamIndex, let requestIDKey):
                    snapshot = ControlPlane.RPCCancelSnapshot(
                        registrationToken: registrationToken,
                        upstreamIndex: upstreamIndex,
                        requestIDKey: requestIDKey
                    )
                }
                state.state = .cancelled(snapshot)
                guard let onCancel = state.onCancel else {
                    return nil
                }
                return (onCancel, snapshot)
            }
            if let (onCancel, snapshot) = cancellation {
                onCancel(snapshot)
            }
        }

        func isCancelled() -> Bool {
            state.withLockedValue { state in
                if case .cancelled = state.state {
                    return true
                }
                return false
            }
        }
    }
}
