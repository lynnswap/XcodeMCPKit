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
        private enum ActiveRequest: Sendable {
            case selected(UpstreamOperationLease)
            case sendRegistered(
                operationLease: UpstreamOperationLease,
                routerPendingToken: UUID,
                requestSendCompletion: UpstreamRequestSendCompletion
            )

            var routerPendingToken: UUID? {
                guard case .sendRegistered(_, let routerPendingToken, _) = self else {
                    return nil
                }
                return routerPendingToken
            }

            var cancellationOperationLease: UpstreamOperationLease? {
                guard case .sendRegistered(let operationLease, _, _) = self else {
                    return nil
                }
                return operationLease
            }

            var requestSendCompletion: UpstreamRequestSendCompletion? {
                guard case .sendRegistered(_, _, let requestSendCompletion) = self else {
                    return nil
                }
                return requestSendCompletion
            }
        }

        private struct CancellationSnapshot: Sendable {
            let activeRequest: ActiveRequest?
            let refreshTask: Task<Void, Never>?
            let childHandles: [ClientMCPRequestExecutor.CancellationHandle]
            let requestIDKeys: [String]
        }

        private struct State: Sendable {
            var requestIDKeys: [String]
            var activeRequest: ActiveRequest?
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
                state.activeRequest = .selected(operationLease)
                return true
            }
        }

        func bindStartedRegistration(
            operationLease: UpstreamOperationLease,
            routerPendingToken: UUID,
            requestSendCompletion: UpstreamRequestSendCompletion
        ) -> Bool {
            state.withLockedValue { state in
                guard !state.isTerminal,
                      case .selected(let selected) = state.activeRequest,
                      selected.proof == operationLease.proof else { return false }
                state.activeRequest = .sendRegistered(
                    operationLease: operationLease,
                    routerPendingToken: routerPendingToken,
                    requestSendCompletion: requestSendCompletion
                )
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
                state -> CancellationSnapshot? in
                guard !state.isTerminal else { return nil }
                state.isTerminal = true
                let snapshot = CancellationSnapshot(
                    activeRequest: state.activeRequest,
                    refreshTask: state.refreshTask,
                    childHandles: state.childHandles,
                    requestIDKeys: state.requestIDKeys
                )
                state.refreshTask = nil
                state.childHandles = []
                return snapshot
            }
            guard let snapshot else { return }
            snapshot.refreshTask?.cancel()
            for childHandle in snapshot.childHandles {
                childHandle.cancel(using: runtime)
            }
            if let routerPendingToken = snapshot.activeRequest?.routerPendingToken,
               runtime.hasSession(id: sessionID) {
                _ = runtime.session(id: sessionID).router.cancelPending(token: routerPendingToken)
            }
            runtime.abandonRequestLease(
                leaseID,
                sessionID: sessionID,
                requestIDKeys: snapshot.requestIDKeys,
                operationLease: snapshot.activeRequest?.cancellationOperationLease,
                after: snapshot.activeRequest?.requestSendCompletion
            )
        }
    }
}
