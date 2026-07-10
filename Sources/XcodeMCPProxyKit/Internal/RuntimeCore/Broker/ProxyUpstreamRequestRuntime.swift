import Foundation
import NIO
import XcodeMCPKit

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
        onRejected: @escaping @Sendable () -> Void
    ) -> Bool
    func activateRequestLease(
        _ leaseID: LeaseManager.ID,
        requestIDKey: String?,
        upstreamIndex: Int?,
        timeout: TimeAmount?
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
            onRejected: {}
        )
    }

}

struct ProxyUpstreamRequestRuntime: Sendable {
    struct PreparedRequest: Sendable {
        let transform: RequestTransform
        let operationLease: UpstreamOperationLease
        let admission: RouteForwardingAdmission?

        var upstreamIndex: Int { operationLease.upstreamIndex }

        init(
            transform: RequestTransform,
            operationLease: UpstreamOperationLease,
            admission: RouteForwardingAdmission? = nil
        ) {
            self.transform = transform
            self.operationLease = operationLease
            self.admission = admission
        }
    }

    struct StartedRegistration: Sendable {
        let operationLease: UpstreamOperationLease
        let routerPendingToken: UUID

        var upstreamIndex: Int { operationLease.upstreamIndex }

        init(operationLease: UpstreamOperationLease, routerPendingToken: UUID) {
            self.operationLease = operationLease
            self.routerPendingToken = routerPendingToken
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

    init(port: any ProxyUpstreamRequestRuntimePort) {
        self.port = port
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
        onRegistered: (@Sendable (StartedRegistration) -> Void)? = nil,
        onTimeout: (@Sendable () -> Void)? = nil
    ) throws -> StartedRequest {
        guard let idKey = prepared.transform.idKey else {
            throw Error.missingRequestID
        }
        let registration = router.registerRequestPending(
            idKey: idKey,
            on: eventLoop,
            timeout: requestTimeout,
            onTimeout: onTimeout
        )

        if let leaseID {
            port.activateRequestLease(
                leaseID,
                requestIDKey: prepared.transform.responseID?.key,
                upstreamIndex: prepared.upstreamIndex,
                timeout: requestTimeout
            )
        }
        onRegistered?(
            StartedRegistration(
                operationLease: prepared.operationLease,
                routerPendingToken: registration.token
            )
        )
        let sent = port.sendUpstream(
            prepared.transform.upstreamData,
            operationLease: prepared.operationLease,
            ensureRunning: false,
            admission: prepared.admission,
            onRejected: {
                _ = router.cancelPending(token: registration.token)
            }
        )
        guard sent else {
            _ = router.cancelPending(token: registration.token)
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
