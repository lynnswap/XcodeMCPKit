import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import ProxyCore
import XcodeMCPRuntime
import ProxyXcodeSupport

extension ClientMCPRequestExecutor {
    package enum Status: Sendable, Equatable {
        case ok
        case accepted
        case badRequest
        case notFound
        case unprocessableEntity
        case badGateway
        case serviceUnavailable

        package var code: UInt {
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

    package enum Resolution {
        case responseData(
            data: Data,
            sessionID: String?,
            prefersEventStream: Bool
        )
        case mcpError(
            id: JSONRPC.ID?,
            ids: [JSONRPC.ID],
            code: Int,
            message: String,
            forceBatchArray: Bool,
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

    package struct Operation {
        package let future: EventLoopFuture<ClientMCPRequestExecutor.Resolution>
        package let cancellationHandle: ClientMCPRequestExecutor.CancellationHandle?
    }

    package struct RefreshRoute: Sendable {
        let request: RefreshCodeIssues.Request
        let bodyData: Data
        let requestIDs: [JSONRPC.ID]
        let requestIsBatch: Bool
    }

    package struct RefreshRouting: Sendable {
        let refreshRoutes: [ClientMCPRequestExecutor.RefreshRoute]
        let remainingBodyData: Data?
        let remainingRequestIDs: [JSONRPC.ID]
        let remainingLocalResponseData: Data?
    }

    package enum CancellationSource: String, Sendable {
        case channelInactive
        case responseWriteFailure
    }

    package final class CancellationHandle: @unchecked Sendable {
        private struct State: Sendable {
            var requestIDKeys: [String]
            var upstreamIndex: Int?
            var routerPendingToken: UUID?
            var refreshTask: Task<Void, Never>?
            var childHandles: [ClientMCPRequestExecutor.CancellationHandle] = []
            var isTerminal = false
        }

        package let leaseID: LeaseManager.ID
        package let sessionID: String
        private let state: NIOLockedValueBox<State>

        package init(
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

        package var requestIDKeys: [String] {
            state.withLockedValue { $0.requestIDKeys }
        }

        package var isCancelled: Bool {
            state.withLockedValue { $0.isTerminal }
        }

        package func activate(upstreamIndex: Int) {
            state.withLockedValue { state in
                guard !state.isTerminal else { return }
                state.upstreamIndex = upstreamIndex
            }
        }

        package func bindRouterPendingToken(_ token: UUID) {
            state.withLockedValue { state in
                guard !state.isTerminal else { return }
                state.routerPendingToken = token
            }
        }

        package func bindRequestIDKeys(_ requestIDKeys: [String]) {
            state.withLockedValue { state in
                guard !state.isTerminal else { return }
                state.requestIDKeys = requestIDKeys
            }
        }

        package func markCompleted() {
            state.withLockedValue { state in
                state.isTerminal = true
                state.refreshTask = nil
                state.childHandles.removeAll()
            }
        }

        package func bindRefreshTask(_ task: Task<Void, Never>) {
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
        package func bindChildHandle(_ handle: ClientMCPRequestExecutor.CancellationHandle) -> Bool {
            state.withLockedValue { state in
                guard !state.isTerminal else { return false }
                state.childHandles.append(handle)
                return true
            }
        }

        package func cancel(using runtime: any RuntimeSessionRegistryPort & RuntimeRequestLeasePort) {
            let snapshot = state.withLockedValue {
                state -> (
                    Int?, UUID?, Task<Void, Never>?, [ClientMCPRequestExecutor.CancellationHandle], [String]
                )?
                in
                guard !state.isTerminal else { return nil }
                state.isTerminal = true
                let snapshot = (
                    state.upstreamIndex,
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
                upstreamIndex: snapshot.0
            )
        }
    }
}
