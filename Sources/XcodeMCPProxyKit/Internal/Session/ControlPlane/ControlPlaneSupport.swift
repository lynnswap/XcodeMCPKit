import Foundation
import NIOConcurrencyHelpers
import XcodeMCPRuntime

package enum ControlPlane {}

extension ControlPlane {
    package enum Route: Hashable, Sendable {
        case anyHealthy
        case pinnedUpstream(Int)

        package var debugLabel: String {
            switch self {
            case .anyHealthy:
                return "any_healthy"
            case .pinnedUpstream(let upstreamIndex):
                return "pinned_\(upstreamIndex)"
            }
        }
    }
}

package struct CanonicalToolsCatalogLoadResult: Sendable {
    package let rawResult: JSONValue
    package let sourceUpstream: Int?
    package let durationMilliseconds: Int

    package init(rawResult: JSONValue, sourceUpstream: Int?, durationMilliseconds: Int) {
        self.rawResult = rawResult
        self.sourceUpstream = sourceUpstream
        self.durationMilliseconds = durationMilliseconds
    }
}

extension ControlPlane {
    package struct WaiterCounts: Codable, Sendable {
        package let initialize: Int
        package let toolsCatalog: Int
        package let windows: Int
    }
}

extension ControlPlane {
    package struct DebugSnapshot: Codable, Sendable {
        package let phase: String
        package let canonicalInitializeSourceUpstream: Int?
        package let canonicalToolsSourceUpstream: Int?
        package let canonicalReady: Bool
        package let upstreamHandshakeStates: [String: String]
        package let waiterCounts: ControlPlane.WaiterCounts
        package let inFlightControlPlaneRequests: [String]
        package let lastIncompatibility: CanonicalBrokerState.Incompatibility?
    }
}

extension ControlPlane {
    package final class DebugMirror: Sendable {
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

        package init() {}

        package func snapshot() -> ControlPlane.DebugSnapshot? {
            state.withLockedValue { $0.snapshot }
        }

        package func overwrite(_ snapshot: ControlPlane.DebugSnapshot?) {
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

        package func waitForSnapshot(
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
    package struct RPCCancelSnapshot: Sendable {
        package let registrationToken: UUID?
        package let upstreamIndex: Int?
        package let requestIDKey: String?

        package init(
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
    package final class RPCHandle: Sendable {
        package enum State: Sendable {
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

        package init() {}

        package func installCancel(
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

        package func markRegistered(
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

        package func markAssigned(
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

        package func markFinished() {
            state.withLockedValue { state in
                switch state.state {
                case .queued, .registered, .assigned:
                    state.state = .finished
                case .finished, .cancelled:
                    return
                }
            }
        }

        package func cancel() {
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

        package func isCancelled() -> Bool {
            state.withLockedValue { state in
                if case .cancelled = state.state {
                    return true
                }
                return false
            }
        }
    }
}
