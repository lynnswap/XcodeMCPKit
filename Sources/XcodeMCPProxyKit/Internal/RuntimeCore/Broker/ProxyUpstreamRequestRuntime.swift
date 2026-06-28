import Foundation
import NIO
import XcodeMCPKit

protocol ProxyUpstreamRequestRuntimePort: Sendable {
    func chooseUpstreamIndex() -> Int?
    func assignUpstreamID(sessionID: String, originalID: JSONRPC.ID, upstreamIndex: Int) -> Int64
    func removeUpstreamIDMapping(sessionID: String, requestIDKey: String, upstreamIndex: Int)
    func onRequestTimeout(sessionID: String, requestIDKey: String, upstreamIndex: Int)
    func onRequestSucceeded(sessionID: String, requestIDKey: String, upstreamIndex: Int)
    func sendUpstream(_ data: Data, upstreamIndex: Int, ensureRunning: Bool)
    func activateRequestLease(
        _ leaseID: LeaseManager.ID,
        requestIDKey: String?,
        upstreamIndex: Int?,
        timeout: TimeAmount?
    )
}

extension ProxyUpstreamRequestRuntimePort {
    func sendUpstream(_ data: Data, upstreamIndex: Int) {
        sendUpstream(data, upstreamIndex: upstreamIndex, ensureRunning: false)
    }
}

struct ProxyUpstreamRequestRuntime: Sendable {
    struct PreparedRequest: Sendable {
        let transform: RequestTransform
        let upstreamIndex: Int

        init(transform: RequestTransform, upstreamIndex: Int) {
            self.transform = transform
            self.upstreamIndex = upstreamIndex
        }
    }

    struct StartedRegistration: Sendable {
        let upstreamIndex: Int
        let routerPendingToken: UUID

        init(upstreamIndex: Int, routerPendingToken: UUID) {
            self.upstreamIndex = upstreamIndex
            self.routerPendingToken = routerPendingToken
        }
    }

    struct StartedRequest: Sendable {
        let transform: RequestTransform
        let upstreamIndex: Int
        let requestTimeout: TimeAmount?
        let routerPendingToken: UUID
        let future: EventLoopFuture<ByteBuffer>

        init(
            transform: RequestTransform,
            upstreamIndex: Int,
            requestTimeout: TimeAmount?,
            routerPendingToken: UUID,
            future: EventLoopFuture<ByteBuffer>
        ) {
            self.transform = transform
            self.upstreamIndex = upstreamIndex
            self.requestTimeout = requestTimeout
            self.routerPendingToken = routerPendingToken
            self.future = future
        }
    }

    enum Error: Swift.Error, Sendable {
        case missingRequestID
    }

    private let port: any ProxyUpstreamRequestRuntimePort

    init(port: any ProxyUpstreamRequestRuntimePort) {
        self.port = port
    }

    func prepareRequest(
        bodyData: Data,
        parsedRequestJSON: Any,
        sessionID: String,
        upstreamIndexOverride: Int? = nil
    ) throws -> PreparedRequest? {
        let upstreamIndex: Int
        if let upstreamIndexOverride {
            upstreamIndex = upstreamIndexOverride
        } else {
            guard let chosen = port.chooseUpstreamIndex() else {
                return nil
            }
            upstreamIndex = chosen
        }

        let transform = try RequestInspector.transform(
            bodyData,
            parsedJSON: parsedRequestJSON,
            sessionID: sessionID,
            mapID: { sessionID, originalID in
                port.assignUpstreamID(
                    sessionID: sessionID,
                    originalID: originalID,
                    upstreamIndex: upstreamIndex
                )
            }
        )
        return PreparedRequest(transform: transform, upstreamIndex: upstreamIndex)
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
        let registration: JSONRPCResponseRouter.PendingRegistration
        if prepared.transform.isBatch {
            let responseIDKeys = prepared.transform.responseIDs.map(\.key)
            guard responseIDKeys.isEmpty == false else {
                throw Error.missingRequestID
            }
            registration = router.registerBatchPending(
                on: eventLoop,
                timeout: requestTimeout,
                responseIDKeys: responseIDKeys,
                onTimeout: onTimeout
            )
        } else if let idKey = prepared.transform.idKey {
            registration = router.registerRequestPending(
                idKey: idKey,
                on: eventLoop,
                timeout: requestTimeout,
                onTimeout: onTimeout
            )
        } else {
            throw Error.missingRequestID
        }

        if let leaseID {
            port.activateRequestLease(
                leaseID,
                requestIDKey: prepared.transform.responseIDs.first?.key,
                upstreamIndex: prepared.upstreamIndex,
                timeout: requestTimeout
            )
        }
        onRegistered?(
            StartedRegistration(
                upstreamIndex: prepared.upstreamIndex,
                routerPendingToken: registration.token
            )
        )
        port.sendUpstream(
            prepared.transform.upstreamData,
            upstreamIndex: prepared.upstreamIndex,
            ensureRunning: false
        )
        return StartedRequest(
            transform: prepared.transform,
            upstreamIndex: prepared.upstreamIndex,
            requestTimeout: requestTimeout,
            routerPendingToken: registration.token,
            future: registration.future
        )
    }

    func recordRequestSucceeded(
        sessionID: String,
        started: StartedRequest
    ) {
        for responseID in started.transform.responseIDs {
            port.onRequestSucceeded(
                sessionID: sessionID,
                requestIDKey: responseID.key,
                upstreamIndex: started.upstreamIndex
            )
        }
    }

    func recordRequestTimedOut(
        sessionID: String,
        started: StartedRequest,
        accountTimeout: Bool
    ) {
        guard let firstResponseID = started.transform.responseIDs.first else {
            return
        }
        if accountTimeout {
            port.onRequestTimeout(
                sessionID: sessionID,
                requestIDKey: firstResponseID.key,
                upstreamIndex: started.upstreamIndex
            )
        } else {
            port.removeUpstreamIDMapping(
                sessionID: sessionID,
                requestIDKey: firstResponseID.key,
                upstreamIndex: started.upstreamIndex
            )
        }
        for responseID in started.transform.responseIDs.dropFirst() {
            port.removeUpstreamIDMapping(
                sessionID: sessionID,
                requestIDKey: responseID.key,
                upstreamIndex: started.upstreamIndex
            )
        }
    }
}
