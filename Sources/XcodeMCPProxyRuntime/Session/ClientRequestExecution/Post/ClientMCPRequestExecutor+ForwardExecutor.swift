import Foundation
import NIO
import XcodeMCPKit

extension ClientMCPRequestExecutor {
    func makeTopLevelRequestFuture(
        filteredRequest: FilteredToolCallRequest,
        sessionID: String,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        session: SessionContext,
        leaseID: LeaseManager.ID,
        operationLease: UpstreamOperationLease?,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle?,
        requestTimeoutOverride: TimeAmount?,
        admission: RouteForwardingAdmission? = nil
    ) -> EventLoopFuture<ClientMCPRequestExecutor.Resolution> {
        guard let bodyData = filteredRequest.bodyData,
            let requestObject = try? JSONRPC.Wire.object(fromData: bodyData)
        else {
            return makeImmediateLeaseResolution(
                .mcpError(
                    id: nil,
                    code: -32600,
                    message: "invalid request",
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                ),
                leaseID: leaseID,
                eventLoop: eventLoop,
                cancellationHandle: cancellationHandle
            )
        }

        if let refreshRequest = refreshCodeIssuesRequest(from: requestObject),
            let responseID = filteredRequest.forwardedResponseID
        {
            let promise = eventLoop.makePromise(of: ClientMCPRequestExecutor.Resolution.self)
            let task = Task { [self] in
                let result = await forwardRefreshCodeIssuesRequest(
                    refreshRequest,
                    bodyData: bodyData,
                    sessionID: sessionID,
                    responseID: responseID,
                    requestTimeoutOverride: requestTimeoutOverride,
                    eventLoop: eventLoop,
                    leaseID: leaseID,
                    cancellationHandle: cancellationHandle
                )
                let wasCancelled = Task.isCancelled
                eventLoopCompletionExecutor.execute(on: eventLoop) {
                    if wasCancelled {
                        cancellationHandle?.markCompleted()
                        promise.succeed(.empty(status: .accepted, sessionID: sessionID))
                        return
                    }
                    cancellationHandle?.markCompleted()
                    self.finishRefreshLease(leaseID, result: result)
                    promise.succeed(
                        self.makeResolution(
                            from: result,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                }
            }
            cancellationHandle?.bindRefreshTask(task)
            return promise.futureResult
        }

        let prepared: MCPForwardingService.PreparedRequest
        do {
            guard let candidate = try forwardingService.prepareRequest(
                bodyData: bodyData,
                parsedRequestJSON: requestObject,
                sessionID: sessionID,
                operationLeaseOverride: operationLease,
                admission: admission,
                cancellationHandle: cancellationHandle
            ) else {
                return makeImmediateLeaseResolution(
                    Self.makeUpstreamUnavailableResolution(
                        responseID: filteredRequest.forwardedResponseID,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    ),
                    leaseID: leaseID,
                    eventLoop: eventLoop,
                    cancellationHandle: cancellationHandle
                )
            }
            prepared = candidate
        } catch is CancellationError {
            return eventLoop.makeFailedFuture(CancellationError())
        } catch ProxyUpstreamRequestRuntime.Error.staleUpstreamTopology {
            return eventLoop.makeFailedFuture(
                ProxyUpstreamRequestRuntime.Error.staleUpstreamTopology
            )
        } catch {
            return makeImmediateLeaseResolution(
                .mcpError(
                    id: nil,
                    code: -32600,
                    message: "invalid request",
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                ),
                leaseID: leaseID,
                eventLoop: eventLoop,
                cancellationHandle: cancellationHandle
            )
        }

        guard prepared.transform.expectsResponse else {
            if prepared.transform.method != "notifications/initialized"
                || sessionManager.isInitialized() == false
            {
                sessionManager.sendUpstream(
                    prepared.transform.upstreamData,
                    operationLease: prepared.operationLease,
                    ensureRunning: false,
                    admission: prepared.admission
                )
            }
            return makeImmediateLeaseResolution(
                .empty(status: .accepted, sessionID: sessionID),
                leaseID: leaseID,
                eventLoop: eventLoop,
                cancellationHandle: cancellationHandle
            )
        }

        let started: MCPForwardingService.StartedRequest
        do {
            let methodTimeout = Self.topLevelRequestTimeoutOverride(
                method: prepared.transform.method,
                defaultSeconds: requestTimeoutSeconds
            )
            let effectiveTimeout = Self.minimumRequestTimeout(
                methodTimeout,
                requestTimeoutOverride
            )
            logger.debug(
                "Starting top-level upstream request",
                metadata: [
                    "lease_id": .string(leaseID.uuidString),
                    "session": .string(sessionID),
                    "label": .string(Self.requestLabel(from: requestObject)),
                    "upstream": .string("\(prepared.upstreamIndex)"),
                    "timeout_ms": .string(
                        effectiveTimeout.map { "\($0.nanoseconds / 1_000_000)" } ?? "disabled"
                    ),
                ]
            )
            started = try forwardingService.startRequest(
                prepared,
                session: session,
                on: eventLoop,
                requestTimeoutOverride: effectiveTimeout,
                leaseID: leaseID,
                cancellationHandle: cancellationHandle,
                onTimeout: { requestSendCompletion in
                    self.sessionManager.handleRequestLeaseTimeout(
                        leaseID,
                        sessionID: sessionID,
                        requestIDKeys: prepared.transform.responseID.map { [$0.key] } ?? [],
                        operationLease: prepared.operationLease,
                        after: requestSendCompletion
                    )
                }
            )
        } catch is CancellationError {
            return eventLoop.makeFailedFuture(CancellationError())
        } catch ProxyUpstreamRequestRuntime.Error.staleUpstreamTopology {
            return eventLoop.makeFailedFuture(
                ProxyUpstreamRequestRuntime.Error.staleUpstreamTopology
            )
        } catch {
            return makeImmediateLeaseResolution(
                .mcpError(
                    id: filteredRequest.forwardedResponseID,
                    code: -32600,
                    message: "missing id",
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                ),
                leaseID: leaseID,
                eventLoop: eventLoop,
                cancellationHandle: cancellationHandle
            )
        }

        let promise = eventLoop.makePromise(of: ClientMCPRequestExecutor.Resolution.self)
        started.future.whenComplete { result in
            let resolution = self.forwardingService.resolveResponse(
                result,
                started: started,
                sessionID: sessionID,
                accountTimeout: false
            )
            let responseID = started.transform.responseID
            switch resolution {
            case .success(let responseData):
                self.sessionManager.recordDeviceInteractionAffinityIfNeeded(
                    requestData: bodyData,
                    responseData: responseData,
                    operationLease: started.operationLease
                )
                cancellationHandle?.markCompleted()
                self.sessionManager.completeRequestLease(leaseID)
                self.logFinishedRequest(
                    leaseID: leaseID,
                    sessionID: sessionID,
                    upstreamIndex: prepared.upstreamIndex,
                    responseID: responseID,
                    reason: "completed"
                )
                promise.succeed(
                    .responseData(
                        data: responseData,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            case .invalidUpstreamResponse:
                cancellationHandle?.markCompleted()
                self.sessionManager.failRequestLease(
                    leaseID,
                    terminalState: .failed,
                    reason: .invalidUpstreamResponse
                )
                self.logFinishedRequest(
                    leaseID: leaseID,
                    sessionID: sessionID,
                    upstreamIndex: prepared.upstreamIndex,
                    responseID: responseID,
                    reason: "invalidUpstreamResponse"
                )
                promise.succeed(
                    .plain(
                        status: .badGateway,
                        body: "invalid upstream response",
                        sessionID: sessionID
                    )
                )
            case .timeout:
                cancellationHandle?.markCompleted()
                self.sessionManager.failRequestLease(
                    leaseID,
                    terminalState: .timedOut,
                    reason: .timedOut
                )
                self.logFinishedRequest(
                    leaseID: leaseID,
                    sessionID: sessionID,
                    upstreamIndex: prepared.upstreamIndex,
                    responseID: responseID,
                    reason: "timedOut"
                )
                promise.succeed(
                    .mcpError(
                        id: responseID,
                        code: -32000,
                        message: "upstream timeout",
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            case .upstreamUnavailable:
                cancellationHandle?.markCompleted()
                self.sessionManager.failRequestLease(
                    leaseID,
                    terminalState: .failed,
                    reason: .upstreamUnavailable
                )
                self.logFinishedRequest(
                    leaseID: leaseID,
                    sessionID: sessionID,
                    upstreamIndex: prepared.upstreamIndex,
                    responseID: responseID,
                    reason: "upstreamUnavailable"
                )
                promise.succeed(
                    Self.makeUpstreamUnavailableResolution(
                        responseID: responseID,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }
        }
        return promise.futureResult
    }

    private func logFinishedRequest(
        leaseID: LeaseManager.ID,
        sessionID: String,
        upstreamIndex: Int,
        responseID: JSONRPC.ID?,
        reason: String
    ) {
        logger.debug(
            "Finished top-level upstream request",
            metadata: [
                "lease_id": .string(leaseID.uuidString),
                "session": .string(sessionID),
                "release_reason": .string(reason),
                "upstream": .string("\(upstreamIndex)"),
                "request_id": .string(responseID?.key ?? "none"),
            ]
        )
    }
}
