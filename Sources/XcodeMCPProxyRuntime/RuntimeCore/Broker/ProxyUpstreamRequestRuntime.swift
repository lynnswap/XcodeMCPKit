import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPKit

final class UpstreamRequestSendCompletion: @unchecked Sendable {
    enum Outcome: Sendable, Equatable {
        case accepted
        case notSent
    }

    private struct State {
        var outcome: Outcome?
        var waiters: [CheckedContinuation<Outcome, Never>] = []
    }

    private let state = NIOLockedValueBox(State())

    func complete(_ outcome: Outcome) {
        let waiters = state.withLockedValue {
            state -> [CheckedContinuation<Outcome, Never>] in
            guard state.outcome == nil else { return [] }
            state.outcome = outcome
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
    }

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            let outcome = state.withLockedValue { state -> Outcome? in
                if let outcome = state.outcome {
                    return outcome
                }
                state.waiters.append(continuation)
                return nil
            }
            if let outcome {
                continuation.resume(returning: outcome)
            }
        }
    }
}

protocol ProxyUpstreamRequestRuntimePort: Sendable {
    func chooseUpstreamOperationLease() -> UpstreamOperationLease?
    func assignUpstreamID(
        sessionID: String,
        originalID: JSONRPC.ID,
        operationLease: UpstreamOperationLease
    ) -> Int64?
    func removeUpstreamIDMapping(
        sessionID: String,
        requestIDKey: String,
        operationLease: UpstreamOperationLease
    )
    func onRequestTimeout(
        sessionID: String,
        requestIDKey: String,
        operationLease: UpstreamOperationLease
    )
    func onRequestSucceeded(
        sessionID: String,
        requestIDKey: String,
        operationLease: UpstreamOperationLease
    )
    func rewriteOwnerBoundRequest(
        bodyData: Data,
        parsedRequestJSON: Any,
        operationLease: UpstreamOperationLease,
        admission: RouteForwardingAdmission?
    ) -> (bodyData: Data, parsedRequestJSON: Any)
    func sendUpstream(
        _ data: Data,
        operationLease: UpstreamOperationLease,
        ensureRunning: Bool,
        admission: RouteForwardingAdmission?,
        requestSendCompletion: UpstreamRequestSendCompletion?,
        onRejected: @escaping @Sendable () -> Void
    ) -> Bool
    func activateRequestLease(
        _ leaseID: LeaseManager.ID,
        requestIDKey: String?,
        upstreamIndex: Int?,
        timeout: TimeAmount?,
        progressTokenMapping: ProgressTokenMapping?
    )
}

extension ProxyUpstreamRequestRuntimePort {
    func rewriteOwnerBoundRequest(
        bodyData: Data,
        parsedRequestJSON: Any,
        operationLease _: UpstreamOperationLease,
        admission _: RouteForwardingAdmission?
    ) -> (bodyData: Data, parsedRequestJSON: Any) {
        (bodyData, parsedRequestJSON)
    }

    @discardableResult
    func sendUpstream(
        _ data: Data,
        operationLease: UpstreamOperationLease,
        ensureRunning: Bool,
        admission: RouteForwardingAdmission?
    ) -> Bool {
        sendUpstream(
            data,
            operationLease: operationLease,
            ensureRunning: ensureRunning,
            admission: admission,
            requestSendCompletion: nil,
            onRejected: {}
        )
    }

    @discardableResult
    func sendUpstream(
        _ data: Data,
        operationLease: UpstreamOperationLease,
        ensureRunning: Bool,
        admission: RouteForwardingAdmission?,
        onRejected: @escaping @Sendable () -> Void
    ) -> Bool {
        sendUpstream(
            data,
            operationLease: operationLease,
            ensureRunning: ensureRunning,
            admission: admission,
            requestSendCompletion: nil,
            onRejected: onRejected
        )
    }

}

struct ProxyUpstreamRequestRuntime: Sendable {
    struct PreparedRequest: Sendable {
        let transform: RequestTransform
        let sessionID: String
        let operationLease: UpstreamOperationLease
        let admission: RouteForwardingAdmission?

        var upstreamIndex: Int { operationLease.upstreamIndex }

        init(
            transform: RequestTransform,
            sessionID: String,
            operationLease: UpstreamOperationLease,
            admission: RouteForwardingAdmission? = nil
        ) {
            self.transform = transform
            self.sessionID = sessionID
            self.operationLease = operationLease
            self.admission = admission
        }
    }

    struct StartedRegistration: Sendable {
        let operationLease: UpstreamOperationLease
        let routerPendingToken: UUID
        let requestSendCompletion: UpstreamRequestSendCompletion

        var upstreamIndex: Int { operationLease.upstreamIndex }

        init(
            operationLease: UpstreamOperationLease,
            routerPendingToken: UUID,
            requestSendCompletion: UpstreamRequestSendCompletion
        ) {
            self.operationLease = operationLease
            self.routerPendingToken = routerPendingToken
            self.requestSendCompletion = requestSendCompletion
        }
    }

    struct StartedRequest: Sendable {
        let transform: RequestTransform
        let operationLease: UpstreamOperationLease
        let requestTimeout: TimeAmount?
        let routerPendingToken: UUID
        let future: EventLoopFuture<ByteBuffer>

        var upstreamIndex: Int { operationLease.upstreamIndex }

        init(
            transform: RequestTransform,
            operationLease: UpstreamOperationLease,
            requestTimeout: TimeAmount?,
            routerPendingToken: UUID,
            future: EventLoopFuture<ByteBuffer>
        ) {
            self.transform = transform
            self.operationLease = operationLease
            self.requestTimeout = requestTimeout
            self.routerPendingToken = routerPendingToken
            self.future = future
        }
    }

    enum Error: Swift.Error, Sendable {
        case missingRequestID
        case staleUpstreamTopology
    }

    private let port: any ProxyUpstreamRequestRuntimePort
    private let makeUpstreamProgressToken: @Sendable () -> String

    init(
        port: any ProxyUpstreamRequestRuntimePort,
        makeUpstreamProgressToken: @escaping @Sendable () -> String = {
            UUID().uuidString
        }
    ) {
        self.port = port
        self.makeUpstreamProgressToken = makeUpstreamProgressToken
    }

    func prepareRequest(
        bodyData: Data,
        parsedRequestJSON: Any,
        sessionID: String,
        operationLeaseOverride: UpstreamOperationLease? = nil,
        admission: RouteForwardingAdmission? = nil
    ) throws -> PreparedRequest? {
        let operationLease: UpstreamOperationLease
        if let operationLeaseOverride {
            operationLease = operationLeaseOverride
        } else {
            guard let chosen = port.chooseUpstreamOperationLease() else {
                return nil
            }
            operationLease = chosen
        }

        let rewritten = port.rewriteOwnerBoundRequest(
            bodyData: bodyData,
            parsedRequestJSON: parsedRequestJSON,
            operationLease: operationLease,
            admission: admission
        )
        let transform = try RequestInspector.transform(
            rewritten.bodyData,
            parsedJSON: rewritten.parsedRequestJSON,
            sessionID: sessionID,
            mapProgressToken: { _ in makeUpstreamProgressToken() },
            mapID: { sessionID, originalID in
                guard let upstreamID = port.assignUpstreamID(
                    sessionID: sessionID,
                    originalID: originalID,
                    operationLease: operationLease
                ) else {
                    throw Error.staleUpstreamTopology
                }
                return upstreamID
            }
        )
        return PreparedRequest(
            transform: transform,
            sessionID: sessionID,
            operationLease: operationLease,
            admission: admission
        )
    }

    func startRequest(
        _ prepared: PreparedRequest,
        router: JSONRPCResponseRouter,
        on eventLoop: EventLoop,
        requestTimeout: TimeAmount?,
        leaseID: LeaseManager.ID? = nil,
        onRegistered: (@Sendable (StartedRegistration) throws -> Void)? = nil,
        onTimeout: (@Sendable (UpstreamRequestSendCompletion) -> Void)? = nil
    ) throws -> StartedRequest {
        guard let idKey = prepared.transform.idKey else {
            throw Error.missingRequestID
        }
        let requestSendCompletion = UpstreamRequestSendCompletion()
        let timeoutHandler: (@Sendable () -> Void)?
        if let onTimeout {
            timeoutHandler = {
                onTimeout(requestSendCompletion)
            }
        } else {
            timeoutHandler = nil
        }
        let registration = router.registerRequestPending(
            idKey: idKey,
            on: eventLoop,
            timeout: requestTimeout,
            onTimeout: timeoutHandler
        )

        if let leaseID {
            port.activateRequestLease(
                leaseID,
                requestIDKey: prepared.transform.responseID?.key,
                upstreamIndex: prepared.upstreamIndex,
                timeout: requestTimeout,
                progressTokenMapping: prepared.transform.progressTokenMapping
            )
        }
        let reject: @Sendable () -> Void = {
            guard router.failPending(
                token: registration.token,
                error: Error.staleUpstreamTopology
            ) else {
                return
            }
            if let responseID = prepared.transform.responseID {
                port.removeUpstreamIDMapping(
                    sessionID: prepared.sessionID,
                    requestIDKey: responseID.key,
                    operationLease: prepared.operationLease
                )
            }
        }
        do {
            try onRegistered?(
                StartedRegistration(
                    operationLease: prepared.operationLease,
                    routerPendingToken: registration.token,
                    requestSendCompletion: requestSendCompletion
                )
            )
        } catch {
            requestSendCompletion.complete(.notSent)
            if router.failPending(token: registration.token, error: error),
                let responseID = prepared.transform.responseID
            {
                port.removeUpstreamIDMapping(
                    sessionID: prepared.sessionID,
                    requestIDKey: responseID.key,
                    operationLease: prepared.operationLease
                )
            }
            throw error
        }
        let sent = port.sendUpstream(
            prepared.transform.upstreamData,
            operationLease: prepared.operationLease,
            ensureRunning: false,
            admission: prepared.admission,
            requestSendCompletion: requestSendCompletion,
            onRejected: reject
        )
        guard sent else {
            requestSendCompletion.complete(.notSent)
            reject()
            throw Error.staleUpstreamTopology
        }
        return StartedRequest(
            transform: prepared.transform,
            operationLease: prepared.operationLease,
            requestTimeout: requestTimeout,
            routerPendingToken: registration.token,
            future: registration.future
        )
    }

    func recordRequestSucceeded(
        sessionID: String,
        started: StartedRequest
    ) {
        guard let responseID = started.transform.responseID else { return }
        port.onRequestSucceeded(
            sessionID: sessionID,
            requestIDKey: responseID.key,
            operationLease: started.operationLease
        )
    }

    func recordRequestTimedOut(
        sessionID: String,
        started: StartedRequest,
        accountTimeout: Bool
    ) {
        guard let responseID = started.transform.responseID else {
            return
        }
        if accountTimeout {
            port.onRequestTimeout(
                sessionID: sessionID,
                requestIDKey: responseID.key,
                operationLease: started.operationLease
            )
        } else {
            port.removeUpstreamIDMapping(
                sessionID: sessionID,
                requestIDKey: responseID.key,
                operationLease: started.operationLease
            )
        }
    }
}
