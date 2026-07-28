import Foundation
import NIO
import XcodeMCPKit

extension ClientMCPRequestExecutor {
    func listXcodeWindows(
        sessionID: String,
        eventLoop: EventLoop,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle? = nil,
        upstreamIndexOverride: Int? = nil,
        requestTimeoutOverride: TimeAmount? = nil
    ) async throws -> [XcodeWindowInfo]? {
        _ = sessionID
        _ = eventLoop
        _ = cancellationHandle
        let route: ControlPlane.Route = upstreamIndexOverride.map {
            .pinnedUpstream($0)
        } ?? .anyHealthy
        do {
            let result = try await sessionManager.liveXcodeListWindowsResult(
                route: route,
                requestTimeoutOverride: requestTimeoutOverride
            )
            return XcodeWindowQueryService().parseWindowsResult(result.foundationObject)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    func forwardOnce(
        bodyData: Data,
        sessionID: String,
        responseID: JSONRPC.ID,
        shouldRequeueLeaseOnRetryableFailure: @Sendable () -> Bool,
        eventLoop: EventLoop,
        leaseID: LeaseManager.ID,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle?,
        requestTimeoutOverride: TimeAmount? = nil
    ) async -> RefreshCodeIssues.Workflow.ForwardAttemptResult {
        guard let requestObject = try? JSONRPC.Wire.object(fromData: bodyData) else {
            return .invalidRequest
        }
        let descriptor = Self.topLevelRequestDescriptor(
            sessionID: sessionID,
            parsedRequestJSON: requestObject,
            responseID: responseID
        )
        let preferredUpstreamIndices: [Int]?
        let admission: RouteForwardingAdmission?
        switch await sessionManager.toolRoutingDecision(
            for: requestObject,
            requestTimeoutOverride: requestTimeoutOverride
        ) {
        case .forward(let resolvedUpstreamIndex):
            preferredUpstreamIndices = resolvedUpstreamIndex.map { [$0] }
            admission = nil
        case .forwardAny(let resolvedUpstreamIndices):
            preferredUpstreamIndices = resolvedUpstreamIndices
            admission = nil
        case .forwardAdmitted(let resolvedUpstreamIndices, let resolvedAdmission):
            preferredUpstreamIndices = resolvedUpstreamIndices
            admission = resolvedAdmission
        case .localXcodeListWindows:
            return .upstreamUnavailable(responseID: responseID)
        case .reject:
            return .upstreamUnavailable(responseID: responseID)
        }

        do {
            let session = sessionManager.session(id: sessionID)
            let resolution = try await sessionManager.enqueueOnUpstreamSlot(
                leaseID: leaseID,
                descriptor: descriptor,
                on: eventLoop,
                preferredUpstreamIndices: preferredUpstreamIndices
            ) { selectedOperationLease -> EventLoopFuture<MCPForwardingService.ResponseResolution> in
                if let cancellationHandle,
                    cancellationHandle.activate(operationLease: selectedOperationLease) == false
                {
                    return eventLoop.makeFailedFuture(CancellationError())
                }
                guard let attemptRequestObject = try? JSONRPC.Wire.object(
                    fromData: bodyData
                ) else {
                    return eventLoop.makeSucceededFuture(
                        MCPForwardingService.ResponseResolution.invalidUpstreamResponse
                    )
                }
                let prepared: MCPForwardingService.PreparedRequest
                do {
                    guard let candidate = try self.forwardingService.prepareRequest(
                        bodyData: bodyData,
                        parsedRequestJSON: attemptRequestObject,
                        sessionID: sessionID,
                        operationLeaseOverride: selectedOperationLease,
                        admission: admission
                    ) else {
                        return eventLoop.makeSucceededFuture(
                            MCPForwardingService.ResponseResolution.invalidUpstreamResponse
                        )
                    }
                    prepared = candidate
                } catch ProxyUpstreamRequestRuntime.Error.staleUpstreamTopology {
                    return eventLoop.makeSucceededFuture(
                        MCPForwardingService.ResponseResolution.upstreamUnavailable
                    )
                } catch {
                    return eventLoop.makeSucceededFuture(
                        MCPForwardingService.ResponseResolution.invalidUpstreamResponse
                    )
                }

                let started: MCPForwardingService.StartedRequest
                do {
                    started = try self.forwardingService.startRequest(
                        prepared,
                        session: session,
                        on: eventLoop,
                        requestTimeoutOverride: requestTimeoutOverride,
                        leaseID: leaseID,
                        cancellationHandle: cancellationHandle,
                        onTimeout: { requestSendCompletion in
                            self.sessionManager.handleRequestLeaseTimeout(
                                leaseID,
                                sessionID: sessionID,
                                requestIDKeys: [responseID.key],
                                operationLease: prepared.operationLease,
                                after: requestSendCompletion
                            )
                        }
                    )
                } catch is CancellationError {
                    return eventLoop.makeFailedFuture(CancellationError())
                } catch ProxyUpstreamRequestRuntime.Error.staleUpstreamTopology {
                    return eventLoop.makeSucceededFuture(.upstreamUnavailable)
                } catch {
                    return eventLoop.makeSucceededFuture(.invalidUpstreamResponse)
                }

                return started.future.map { buffer in
                    self.forwardingService.resolveResponse(
                        .success(buffer),
                        started: started,
                        sessionID: sessionID,
                        accountTimeout: false
                    )
                }.flatMapErrorThrowing { error in
                    self.forwardingService.resolveResponse(
                        .failure(error),
                        started: started,
                        sessionID: sessionID,
                        accountTimeout: false
                    )
                }
            }.get()

            switch resolution {
            case .success(let responseData):
                if RefreshCodeIssues.Workflow.isRetryableRefreshCodeIssuesFailure(responseData),
                    shouldRequeueLeaseOnRetryableFailure()
                {
                    sessionManager.requeueRequestLease(leaseID)
                }
                return .success(responseData)
            case .timeout:
                return .timeout(responseID: responseID)
            case .upstreamUnavailable:
                return .upstreamUnavailable(responseID: responseID)
            case .invalidUpstreamResponse:
                return .invalidUpstreamResponse
            }
        } catch is CancellationError {
            cancellationHandle?.cancel(using: sessionManager)
            return .cancelled(responseID: responseID)
        } catch {
            return .upstreamUnavailable(responseID: responseID)
        }
    }

    func finishRefreshLease(
        _ leaseID: LeaseManager.ID,
        result: RefreshCodeIssues.Workflow.ForwardAttemptResult
    ) {
        switch result {
        case .success:
            sessionManager.completeRequestLease(leaseID)
        case .timeout:
            sessionManager.failRequestLease(leaseID, terminalState: .timedOut, reason: .timedOut)
        case .invalidRequest, .invalidUpstreamResponse:
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .invalidUpstreamResponse
            )
        case .upstreamUnavailable:
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .upstreamUnavailable
            )
        case .cancelled:
            break
        }
    }

    static func requestLabel(from requestJSON: Any) -> String {
        guard let object = requestJSON as? [String: Any] else { return "unknown" }
        let method = (object["method"] as? String) ?? "unknown"
        if method == "tools/call",
            let params = object["params"] as? [String: Any],
            let name = params["name"] as? String
        {
            return "\(method):\(name)"
        }
        return method
    }

    static func topLevelRequestDescriptor(
        sessionID: String,
        parsedRequestJSON: Any,
        responseID: JSONRPC.ID?
    ) -> SessionRequestPipeline.Descriptor {
        SessionRequestPipeline.Descriptor(
            sessionID: sessionID,
            label: requestLabel(from: parsedRequestJSON),
            expectsResponse: responseID != nil,
            isTopLevelClientRequest: true
        )
    }

    func forwardRefreshCodeIssuesRequest(
        _ refreshRequest: RefreshCodeIssues.Request,
        bodyData: Data,
        sessionID: String,
        responseID: JSONRPC.ID,
        requestTimeoutOverride: TimeAmount? = nil,
        eventLoop: EventLoop,
        leaseID: LeaseManager.ID,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle?
    ) async -> RefreshCodeIssues.Workflow.ForwardAttemptResult {
        await refreshWorkflow.run(
            refreshRequest: refreshRequest,
            bodyData: bodyData,
            sessionID: sessionID,
            responseID: responseID,
            requestTimeoutOverride: requestTimeoutOverride,
            eventLoop: eventLoop,
            windowsProvider: { sessionID, eventLoop, upstreamIndex, timeout in
                try await self.listXcodeWindows(
                    sessionID: sessionID,
                    eventLoop: eventLoop,
                    cancellationHandle: cancellationHandle,
                    upstreamIndexOverride: upstreamIndex,
                    requestTimeoutOverride: timeout
                )
            },
            internalUpstreamChooser: { _ in
                self.sessionManager.chooseUpstreamOperationLease()?.upstreamIndex
            },
            internalToolCaller: {
                name, arguments, sessionID, eventLoop, upstreamIndexOverride, requestTimeoutOverride in
                await self.forwardingService.callInternalTool(
                    name: name,
                    arguments: arguments,
                    sessionID: sessionID,
                    eventLoop: eventLoop,
                    cancellationHandle: cancellationHandle,
                    upstreamIndexOverride: upstreamIndexOverride,
                    requestTimeoutOverride: requestTimeoutOverride
                )
            },
            forwarder: { bodyData, sessionID, responseID, shouldRequeue, eventLoop, timeout in
                await self.forwardOnce(
                    bodyData: bodyData,
                    sessionID: sessionID,
                    responseID: responseID,
                    shouldRequeueLeaseOnRetryableFailure: shouldRequeue,
                    eventLoop: eventLoop,
                    leaseID: leaseID,
                    cancellationHandle: cancellationHandle,
                    requestTimeoutOverride: timeout
                )
            }
        )
    }

    func makeResolution(
        from result: RefreshCodeIssues.Workflow.ForwardAttemptResult,
        sessionID: String,
        prefersEventStream: Bool
    ) -> ClientMCPRequestExecutor.Resolution {
        switch result {
        case .success(let responseData):
            return .responseData(
                data: responseData,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        case .timeout(let responseID):
            return .mcpError(
                id: responseID,
                code: -32000,
                message: "upstream timeout",
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        case .upstreamUnavailable(let responseID):
            return .mcpError(
                id: responseID,
                code: -32001,
                message: "upstream unavailable",
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        case .cancelled(let responseID):
            return .mcpError(
                id: responseID,
                code: -32800,
                message: "request cancelled",
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        case .invalidRequest:
            return .mcpError(
                id: nil,
                code: -32600,
                message: "invalid request",
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        case .invalidUpstreamResponse:
            return .plain(
                status: .badGateway,
                body: "invalid upstream response",
                sessionID: sessionID
            )
        }
    }

    func makeImmediateLeaseResolution(
        _ resolution: ClientMCPRequestExecutor.Resolution,
        leaseID: LeaseManager.ID,
        eventLoop: EventLoop,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle?
    ) -> EventLoopFuture<ClientMCPRequestExecutor.Resolution> {
        cancellationHandle?.markCompleted()
        sessionManager.completeRequestLease(leaseID)
        return eventLoop.makeSucceededFuture(resolution)
    }

    func cancel(
        _ handle: ClientMCPRequestExecutor.CancellationHandle,
        source: ClientMCPRequestExecutor.CancellationSource = .channelInactive
    ) {
        logger.debug(
            "Cancelling top-level upstream request",
            metadata: [
                "lease_id": .string(handle.leaseID.uuidString),
                "session": .string(handle.sessionID),
                "disconnect_source": .string(source.rawValue),
                "request_ids": .string(handle.requestIDKeys.joined(separator: ",")),
            ]
        )
        handle.cancel(using: sessionManager)
    }
}
