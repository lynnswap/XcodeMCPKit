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

package enum HTTPPostResolution {
    case responseData(
        data: Data,
        sessionID: String,
        prefersEventStream: Bool
    )
    case mcpError(
        id: RPCID?,
        ids: [RPCID],
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

package struct HTTPPostOperation {
    package let future: EventLoopFuture<HTTPPostResolution>
    package let cancellationHandle: HTTPPostCancellationHandle?
}

package struct RefreshRequestRoute: Sendable {
    let request: RefreshCodeIssuesRequest
    let bodyData: Data
    let requestIDs: [RPCID]
    let requestIsBatch: Bool
}

package struct RefreshRequestRouting: Sendable {
    let refreshRoutes: [RefreshRequestRoute]
    let remainingBodyData: Data?
    let remainingRequestIDs: [RPCID]
    let remainingLocalResponseData: Data?
}

package enum HTTPPostCancellationSource: String, Sendable {
    case channelInactive
    case responseWriteFailure
}

package final class HTTPPostCancellationHandle: @unchecked Sendable {
    private struct State: Sendable {
        var requestIDKeys: [String]
        var upstreamIndex: Int?
        var routerPendingToken: UUID?
        var refreshTask: Task<Void, Never>?
        var childHandles: [HTTPPostCancellationHandle] = []
        var isTerminal = false
    }

    package let leaseID: RequestLeaseID
    package let sessionID: String
    private let state: NIOLockedValueBox<State>

    package init(
        leaseID: RequestLeaseID,
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
    package func bindChildHandle(_ handle: HTTPPostCancellationHandle) -> Bool {
        state.withLockedValue { state in
            guard !state.isTerminal else { return false }
            state.childHandles.append(handle)
            return true
        }
    }

    package func cancel(using runtime: any RuntimeCoordinating) {
        let snapshot = state.withLockedValue {
            state -> (Int?, UUID?, Task<Void, Never>?, [HTTPPostCancellationHandle], [String])? in
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
