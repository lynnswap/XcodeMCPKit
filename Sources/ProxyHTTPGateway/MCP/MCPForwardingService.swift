import Foundation
import NIO
import ProxyCore
import ProxyMCP
import ProxyXcodeFeatures
import ProxySession

package struct MCPForwardingService: Sendable {
    package struct PreparedRequest: Sendable {
        package let transform: RequestTransform
        package let upstreamIndex: Int
    }

    package struct StartedRequest: Sendable {
        package let transform: RequestTransform
        package let upstreamIndex: Int
        package let requestTimeout: TimeAmount?
        package let routerPendingToken: UUID
        package let future: EventLoopFuture<ByteBuffer>
    }

    package enum ResponseResolution: Sendable {
        case success(Data)
        case timeout
        case invalidUpstreamResponse
    }

    private let config: ProxyConfig
    private let sessionManager: any RuntimeCoordinating
    private let toolSurface: ToolSurface

    package init(config: ProxyConfig, sessionManager: any RuntimeCoordinating) {
        self.config = config
        self.sessionManager = sessionManager
        self.toolSurface = ToolSurface(config: config, sessionManager: sessionManager)
    }

    package func prepareRequest(
        bodyData: Data,
        parsedRequestJSON: Any,
        sessionID: String,
        upstreamIndexOverride: Int? = nil
    ) throws -> PreparedRequest? {
        let upstreamIndex: Int
        if let upstreamIndexOverride {
            upstreamIndex = upstreamIndexOverride
        } else {
            guard let chosen = sessionManager.chooseUpstreamIndex() else {
                return nil
            }
            upstreamIndex = chosen
        }

        let transform = try RequestInspector.transform(
            bodyData,
            parsedJSON: parsedRequestJSON,
            sessionID: sessionID,
            mapID: { sessionID, originalID in
                sessionManager.assignUpstreamID(
                    sessionID: sessionID,
                    originalID: originalID,
                    upstreamIndex: upstreamIndex
                )
            }
        )
        return PreparedRequest(transform: transform, upstreamIndex: upstreamIndex)
    }

    package func startRequest(
        _ prepared: PreparedRequest,
        session: SessionContext,
        on eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount? = nil,
        leaseID: LeaseManager.ID? = nil,
        cancellationHandle: HTTPPostService.CancellationHandle? = nil,
        onTimeout: (@Sendable () -> Void)? = nil
    ) throws -> StartedRequest {
        let requestTimeout =
            requestTimeoutOverride
            ?? MCP.MethodDispatcher.timeoutForMethod(
                prepared.transform.method,
                defaultSeconds: config.requestTimeout
            )
        struct MissingRequestIDError: Error {}
        let registration: ProxyRouter.PendingRegistration
        if prepared.transform.isBatch {
            let responseIDKeys = prepared.transform.responseIDs.map(\.key)
            guard responseIDKeys.isEmpty == false else {
                throw MissingRequestIDError()
            }
            registration = session.router.registerBatchPending(
                on: eventLoop,
                timeout: requestTimeout,
                responseIDKeys: responseIDKeys,
                onTimeout: onTimeout
            )
        } else if let idKey = prepared.transform.idKey {
            registration = session.router.registerRequestPending(
                idKey: idKey,
                on: eventLoop,
                timeout: requestTimeout,
                onTimeout: onTimeout
            )
        } else {
            throw MissingRequestIDError()
        }

        if let leaseID {
            sessionManager.activateRequestLease(
                leaseID,
                requestIDKey: prepared.transform.responseIDs.first?.key,
                upstreamIndex: prepared.upstreamIndex,
                timeout: requestTimeout
            )
        }
        cancellationHandle?.activate(upstreamIndex: prepared.upstreamIndex)
        cancellationHandle?.bindRouterPendingToken(registration.token)

        sessionManager.sendUpstream(
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

    package func resolveResponse(
        _ result: Result<ByteBuffer, Error>,
        started: StartedRequest,
        sessionID: String,
        accountSuccess: Bool = true,
        accountTimeout: Bool = true
    ) -> ResponseResolution {
        switch result {
        case .success(let buffer):
            var buffer = buffer
            guard let data = buffer.readData(length: buffer.readableBytes) else {
                return .invalidUpstreamResponse
            }
            let rewritten = toolSurface.rewriteForwardedResponse(
                method: started.transform.method,
                toolName: started.transform.toolName,
                originalID: started.transform.originalID,
                responseMethodsByIDKey: started.transform.responseMethodsByIDKey,
                responseToolNamesByIDKey: started.transform.responseToolNamesByIDKey,
                responseOriginalIDsByKey: started.transform.responseOriginalIDsByKey,
                normalizationToolsListResponseIDKey: started.transform.normalizationToolsListResponseIDKey,
                cacheableToolsListResponseIDKey: started.transform.cacheableToolsListResponseIDKey,
                upstreamData: data
            )
            let responseData = rewritten.responseData
            if let result = rewritten.cacheableToolsListResult {
                sessionManager.setCachedToolsListResult(
                    result,
                    sourceUpstream: started.upstreamIndex
                )
            }
            if accountSuccess, toolSurface.shouldNotifyUpstreamSuccess(for: responseData) {
                for responseID in started.transform.responseIDs {
                    sessionManager.onRequestSucceeded(
                        sessionID: sessionID,
                        requestIDKey: responseID.key,
                        upstreamIndex: started.upstreamIndex
                    )
                }
            }
            return .success(responseData)

        case .failure:
            if let firstResponseID = started.transform.responseIDs.first {
                if accountTimeout {
                    sessionManager.onRequestTimeout(
                        sessionID: sessionID,
                        requestIDKey: firstResponseID.key,
                        upstreamIndex: started.upstreamIndex
                    )
                } else {
                    sessionManager.removeUpstreamIDMapping(
                        sessionID: sessionID,
                        requestIDKey: firstResponseID.key,
                        upstreamIndex: started.upstreamIndex
                    )
                }
                for responseID in started.transform.responseIDs.dropFirst() {
                    sessionManager.removeUpstreamIDMapping(
                        sessionID: sessionID,
                        requestIDKey: responseID.key,
                        upstreamIndex: started.upstreamIndex
                    )
                }
            }
            return .timeout
        }
    }

    package func callInternalTool(
        name: String,
        arguments: [String: Any],
        sessionID: String,
        eventLoop: EventLoop,
        cancellationHandle: HTTPPostService.CancellationHandle? = nil,
        upstreamIndexOverride: Int? = nil,
        requestTimeoutOverride: TimeAmount? = nil
    ) async -> RefreshCodeIssues.Workflow.InternalToolResult {
        let requestObject: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "__internal-\(UUID().uuidString)",
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments,
            ],
        ]
        let internalRequestID = JSONRPC.ID(any: requestObject["id"]!)!

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestObject, options: [])
        else {
            return .unavailable
        }
        guard let parsedRequestJSONValue = JSONValue(any: requestObject) else {
            return .unavailable
        }
        let preferredUpstreamIndex =
            upstreamIndexOverride
            ?? sessionManager.preferredUpstreamIndex(for: requestObject)

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: sessionID,
            label: "tools/call:\(name)",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let leaseID = sessionManager.createRequestLease(descriptor: descriptor)
        let internalCancellationHandle = HTTPPostService.CancellationHandle(
            leaseID: leaseID,
            sessionID: sessionID,
            requestIDKeys: []
        )
        let session = sessionManager.session(id: sessionID)

        let resolution: ResponseResolution
        do {
            resolution = try await sessionManager.enqueueOnUpstreamSlot(
                leaseID: leaseID,
                descriptor: descriptor,
                on: eventLoop,
                preferredUpstreamIndex: preferredUpstreamIndex
            ) { selectedUpstreamIndex in
                internalCancellationHandle.activate(upstreamIndex: selectedUpstreamIndex)
                self.sessionManager.activateRequestLease(
                    leaseID,
                    requestIDKey: nil,
                    upstreamIndex: selectedUpstreamIndex,
                    timeout: nil
                )
                let parsedRequestJSON = parsedRequestJSONValue.foundationObject
                let prepared: PreparedRequest
                do {
                    guard let candidate = try prepareRequest(
                        bodyData: bodyData,
                        parsedRequestJSON: parsedRequestJSON,
                        sessionID: sessionID,
                        upstreamIndexOverride: selectedUpstreamIndex
                    ) else {
                        return eventLoop.makeSucceededFuture(.invalidUpstreamResponse)
                    }
                    prepared = candidate
                    internalCancellationHandle.bindRequestIDKeys(
                        prepared.transform.responseIDs.map(\.key)
                    )
                    if let cancellationHandle,
                        cancellationHandle.bindChildHandle(internalCancellationHandle) == false
                    {
                        internalCancellationHandle.cancel(using: sessionManager)
                        return eventLoop.makeFailedFuture(CancellationError())
                    }
                } catch {
                    return eventLoop.makeSucceededFuture(.invalidUpstreamResponse)
                }

                let started: StartedRequest
                do {
                    started = try startRequest(
                        prepared,
                        session: session,
                        on: eventLoop,
                        requestTimeoutOverride: requestTimeoutOverride,
                        leaseID: leaseID,
                        cancellationHandle: internalCancellationHandle,
                        onTimeout: {
                            self.sessionManager.handleRequestLeaseTimeout(
                                leaseID,
                                sessionID: sessionID,
                                requestIDKeys: prepared.transform.responseIDs.map(\.key),
                                upstreamIndex: prepared.upstreamIndex
                            )
                        }
                    )
                } catch {
                    return eventLoop.makeSucceededFuture(.invalidUpstreamResponse)
                }

                return started.future.map { buffer in
                    self.resolveResponse(
                        .success(buffer),
                        started: started,
                        sessionID: sessionID
                    )
                }.flatMapErrorThrowing { error in
                    if error is CancellationError {
                        throw error
                    }
                    return self.resolveResponse(
                        .failure(error),
                        started: started,
                        sessionID: sessionID
                    )
                }
            }.get()
        } catch is CancellationError {
            internalCancellationHandle.cancel(using: sessionManager)
            return .cancelled
        } catch {
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .upstreamUnavailable
            )
            return .unavailable
        }

        switch resolution {
        case .success(let responseData):
            internalCancellationHandle.markCompleted()
            sessionManager.completeRequestLease(leaseID)
            guard let object = ToolSurface.responseObject(
                from: responseData,
                matching: internalRequestID.key
            ),
                let result = object["result"] as? [String: Any]
            else {
                return .unavailable
            }
            if let isError = result["isError"] as? Bool, isError {
                return .unavailable
            }
            return .success(result)
        case .timeout:
            internalCancellationHandle.markCompleted()
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .timedOut,
                reason: .timedOut
            )
            return .timeout
        case .invalidUpstreamResponse:
            internalCancellationHandle.markCompleted()
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .invalidUpstreamResponse
            )
            return .unavailable
        }
    }

}
