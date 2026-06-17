import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOHTTP1
import ProxyCore
import ProxyMCP
import ProxyXcodeFeatures
import ProxyXcodeSupport
import ProxySession

extension HTTPPostService {
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
        status: HTTPResponseStatus,
        body: String,
        sessionID: String?
    )
    case empty(
        status: HTTPResponseStatus,
        sessionID: String
    )
    }

    package struct Operation {
    package let future: EventLoopFuture<HTTPPostService.Resolution>
    package let cancellationHandle: HTTPPostService.CancellationHandle?
    }

    package struct RefreshRoute: Sendable {
    let request: RefreshCodeIssues.Request
    let bodyData: Data
    let requestIDs: [JSONRPC.ID]
    let requestIsBatch: Bool
    }

    package struct RefreshRouting: Sendable {
    let refreshRoutes: [HTTPPostService.RefreshRoute]
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
        var childHandles: [HTTPPostService.CancellationHandle] = []
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
    package func bindChildHandle(_ handle: HTTPPostService.CancellationHandle) -> Bool {
        state.withLockedValue { state in
            guard !state.isTerminal else { return false }
            state.childHandles.append(handle)
            return true
        }
    }

    package func cancel(using runtime: any RuntimeCoordinating) {
        let snapshot = state.withLockedValue {
            state -> (Int?, UUID?, Task<Void, Never>?, [HTTPPostService.CancellationHandle], [String])? in
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
