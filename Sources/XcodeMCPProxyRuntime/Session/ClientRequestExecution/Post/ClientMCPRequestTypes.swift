import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import XcodeMCPKit

extension ClientMCPRequestExecutor {
    enum Status: Sendable, Equatable {
        case ok
        case accepted
        case badRequest
        case notFound
        case unprocessableEntity
        case badGateway
        case serviceUnavailable

        var code: UInt {
            switch self {
            case .ok:
                return 200
            case .accepted:
                return 202
            case .badRequest:
                return 400
            case .notFound:
                return 404
            case .unprocessableEntity:
                return 422
            case .badGateway:
                return 502
            case .serviceUnavailable:
                return 503
            }
        }
    }

    enum Resolution {
        case responseData(
            data: Data,
            sessionID: String?,
            prefersEventStream: Bool
        )
        case mcpError(
            id: JSONRPC.ID?,
            code: Int,
            message: String,
            sessionID: String?,
            prefersEventStream: Bool
        )
        case plain(
            status: Status,
            body: String,
            sessionID: String?
        )
        case empty(
            status: Status,
            sessionID: String
        )
    }

    struct Operation {
        let future: EventLoopFuture<ClientMCPRequestExecutor.Resolution>
        let cancellationHandle: ClientMCPRequestExecutor.CancellationHandle?
    }

    enum CancellationSource: String, Sendable {
        case channelInactive
        case responseWriteFailure
    }

    final class CancellationHandle: @unchecked Sendable {
        private struct State: Sendable {
            var requestIDKeys: [String]
            var operationLease: UpstreamOperationLease?
            var routerPendingToken: UUID?
            var refreshTask: Task<Void, Never>?
            var childHandles: [ClientMCPRequestExecutor.CancellationHandle] = []
            var isTerminal = false
        }

        let leaseID: LeaseManager.ID
        let sessionID: String
        private let state: NIOLockedValueBox<State>

        init(
            leaseID: LeaseManager.ID,
            sessionID: String,
            requestIDKeys: [String]
        ) {
            self.leaseID = leaseID
            self.sessionID = sessionID
            self.state = NIOLockedValueBox(
                State(requestIDKeys: requestIDKeys)
            )
        }

        var requestIDKeys: [String] {
            state.withLockedValue { $0.requestIDKeys }
        }

        var isCancelled: Bool {
            state.withLockedValue { $0.isTerminal }
        }

        func activate(operationLease: UpstreamOperationLease) -> Bool {
            state.withLockedValue { state in
                guard !state.isTerminal else { return false }
                state.operationLease = operationLease
                return true
            }
        }

        func bindStartedRegistration(
            operationLease: UpstreamOperationLease,
            routerPendingToken: UUID
        ) -> Bool {
            state.withLockedValue { state in
                guard !state.isTerminal else { return false }
                state.operationLease = operationLease
                state.routerPendingToken = routerPendingToken
                return true
            }
        }

        func bindRequestIDKeys(_ requestIDKeys: [String]) {
            state.withLockedValue { state in
                guard !state.isTerminal else { return }
                state.requestIDKeys = requestIDKeys
            }
        }

        func markCompleted() {
            state.withLockedValue { state in
                state.isTerminal = true
                state.refreshTask = nil
                state.childHandles.removeAll()
            }
        }

        func bindRefreshTask(_ task: Task<Void, Never>) {
            let shouldCancel = state.withLockedValue { state -> Bool in
                guard !state.isTerminal else { return true }
                state.refreshTask = task
                return false
            }
            if shouldCancel {
                task.cancel()
            }
        }

        @discardableResult
        func bindChildHandle(_ handle: ClientMCPRequestExecutor.CancellationHandle) -> Bool {
            state.withLockedValue { state in
                guard !state.isTerminal else { return false }
                state.childHandles.append(handle)
                return true
            }
        }

        func cancel(using runtime: any RuntimeSessionRegistryPort & RuntimeRequestLeasePort) {
            let snapshot = state.withLockedValue {
                state -> (
                    UpstreamOperationLease?, UUID?, Task<Void, Never>?, [ClientMCPRequestExecutor.CancellationHandle], [String]
                )?
                in
                guard !state.isTerminal else { return nil }
                state.isTerminal = true
                let snapshot = (
                    state.operationLease,
                    state.routerPendingToken,
                    state.refreshTask,
                    state.childHandles,
                    state.requestIDKeys
                )
                state.refreshTask = nil
                state.childHandles = []
                return snapshot
            }
            guard let snapshot else { return }
            snapshot.2?.cancel()
            for childHandle in snapshot.3 {
                childHandle.cancel(using: runtime)
            }
            if let routerPendingToken = snapshot.1, runtime.hasSession(id: sessionID) {
                _ = runtime.session(id: sessionID).router.cancelPending(token: routerPendingToken)
            }
            runtime.abandonRequestLease(
                leaseID,
                sessionID: sessionID,
                requestIDKeys: snapshot.4,
                operationLease: snapshot.0
            )
        }
    }
}
