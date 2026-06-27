import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import ProxyCore
import XcodeMCPRuntime
import ProxyXcodeSupport

extension ClientMCPRequestExecutor {
    package func listXcodeWindows(
        sessionID: String,
        eventLoop: EventLoop,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle? = nil,
        upstreamIndexOverride: Int? = nil,
        requestTimeoutOverride: TimeAmount? = nil
    ) async throws -> [XcodeWindowInfo]? {
        _ = sessionID
        _ = eventLoop
        _ = cancellationHandle
        let windowQueryService = XcodeWindowQueryService()
        let route: ControlPlane.Route = if let upstreamIndexOverride {
            .pinnedUpstream(upstreamIndexOverride)
        } else {
            .anyHealthy
        }
        do {
            let result = try await sessionManager.liveXcodeListWindowsResult(
                route: route,
                requestTimeoutOverride: requestTimeoutOverride
            )
            return windowQueryService.parseWindowsResult(result.foundationObject)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    package func forwardOnce(
        bodyData: Data,
        sessionID: String,
        requestIDs: [JSONRPC.ID],
        requestIsBatch: Bool,
        shouldRequeueLeaseOnRetryableFailure: @Sendable () -> Bool,
        eventLoop: EventLoop,
        leaseID: LeaseManager.ID,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle?,
        requestTimeoutOverride: TimeAmount? = nil
    ) async -> RefreshCodeIssues.Workflow.ForwardAttemptResult {
        let parsedRequestJSON: Any
        do {
            parsedRequestJSON = try JSONSerialization.jsonObject(with: bodyData, options: [])
        } catch {
            return .invalidRequest
        }

        let descriptor = Self.topLevelRequestDescriptor(
            sessionID: sessionID,
            parsedRequestJSON: parsedRequestJSON,
            requestIsBatch: requestIsBatch,
            requestIDs: requestIDs
        )
        let allowsLeaseRetry = Self.isRetryScopedRefreshLeaseRequest(parsedRequestJSON)
        let preferredUpstreamIndices: [Int]?
        switch await sessionManager.toolRoutingDecision(
            for: parsedRequestJSON,
            requestTimeoutOverride: requestTimeoutOverride
        ) {
        case .forward(let resolvedUpstreamIndex):
            preferredUpstreamIndices = resolvedUpstreamIndex.map { [$0] }
        case .forwardAny(let resolvedUpstreamIndices):
            preferredUpstreamIndices = resolvedUpstreamIndices
        case .localXcodeListWindows:
            return .upstreamUnavailable(
                responseIDs: requestIDs,
                isBatch: requestIsBatch
            )
        case .reject:
            return .upstreamUnavailable(
                responseIDs: requestIDs,
                isBatch: requestIsBatch
            )
        }

        do {
            let session = sessionManager.session(id: sessionID)
            let resolution = try await sessionManager.enqueueOnUpstreamSlot(
                leaseID: leaseID,
                descriptor: descriptor,
                on: eventLoop,
                preferredUpstreamIndices: preferredUpstreamIndices
            ) { selectedUpstreamIndex in
                cancellationHandle?.activate(upstreamIndex: selectedUpstreamIndex)

                let parsedAttemptRequestJSON: Any
                do {
                    parsedAttemptRequestJSON = try JSONSerialization.jsonObject(
                        with: bodyData,
                        options: []
                    )
                } catch {
                    return eventLoop.makeSucceededFuture(
                        MCPForwardingService.ResponseResolution.invalidUpstreamResponse
                    )
                }

                let prepared: MCPForwardingService.PreparedRequest
                do {
                    guard let candidate = try self.forwardingService.prepareRequest(
                        bodyData: bodyData,
                        parsedRequestJSON: parsedAttemptRequestJSON,
                        sessionID: sessionID,
                        upstreamIndexOverride: selectedUpstreamIndex
                    ) else {
                        return eventLoop.makeSucceededFuture(
                            MCPForwardingService.ResponseResolution.invalidUpstreamResponse
                        )
                    }
                    prepared = candidate
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
                        onTimeout: {
                            self.sessionManager.handleRequestLeaseTimeout(
                                leaseID,
                                sessionID: sessionID,
                                requestIDKeys: prepared.transform.responseIDs.map(\.key),
                                upstreamIndex: prepared.upstreamIndex
                            )
                        }
                    )
                    cancellationHandle?.bindRouterPendingToken(started.routerPendingToken)
                } catch {
                    return eventLoop.makeSucceededFuture(
                        MCPForwardingService.ResponseResolution.invalidUpstreamResponse
                    )
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
                // Releasing the slot between retry attempts is this
                // function's job; the terminal lease transition belongs to
                // the caller that owns the whole refresh request.
                if allowsLeaseRetry,
                    RefreshCodeIssues.Workflow.isRetryableRefreshCodeIssuesFailure(responseData),
                    shouldRequeueLeaseOnRetryableFailure()
                {
                    sessionManager.requeueRequestLease(leaseID)
                }
                return .success(responseData)
            case .timeout:
                return .timeout(
                    responseIDs: requestIDs,
                    isBatch: requestIsBatch
                )
            case .invalidUpstreamResponse:
                return .invalidUpstreamResponse
            }
        } catch is CancellationError {
            cancellationHandle?.cancel(using: sessionManager)
            return .cancelled(
                responseIDs: requestIDs,
                isBatch: requestIsBatch
            )
        } catch {
            return .upstreamUnavailable(
                responseIDs: requestIDs,
                isBatch: requestIsBatch
            )
        }
    }

    /// The single terminal lease transition for a refresh request,
    /// regardless of whether the proxy answered locally or forwarded.
    package func finishRefreshLease(
        _ leaseID: LeaseManager.ID,
        result: RefreshCodeIssues.Workflow.ForwardAttemptResult
    ) {
        switch result {
        case .success:
            sessionManager.completeRequestLease(leaseID)
        case .timeout:
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .timedOut,
                reason: .timedOut
            )
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
            // The cancellation handle owns lease teardown on this path.
            break
        }
    }

    package static func requestLabel(from requestJSON: Any) -> String {
        if let object = requestJSON as? [String: Any] {
            let method = (object["method"] as? String) ?? "unknown"
            if method == "tools/call",
                let params = object["params"] as? [String: Any],
                let name = params["name"] as? String
            {
                return "\(method):\(name)"
            }
            return method
        }
        if let array = requestJSON as? [Any] {
            return "batch[\(array.count)]"
        }
        return "unknown"
    }

    package static func isRetryScopedRefreshLeaseRequest(_ requestJSON: Any) -> Bool {
        if let object = requestJSON as? [String: Any] {
            return RefreshCodeIssues.Request(requestObject: object) != nil
        }
        guard let array = requestJSON as? [Any],
            array.count == 1,
            let object = array.first as? [String: Any]
        else {
            return false
        }
        return RefreshCodeIssues.Request(requestObject: object) != nil
    }


    package static func topLevelRequestDescriptor(
        sessionID: String,
        parsedRequestJSON: Any,
        requestIsBatch: Bool,
        requestIDs: [JSONRPC.ID]
    ) -> SessionRequestPipeline.Descriptor {
        SessionRequestPipeline.Descriptor(
            sessionID: sessionID,
            label: requestLabel(from: parsedRequestJSON),
            isBatch: requestIsBatch,
            expectsResponse: requestIDs.isEmpty == false,
            isTopLevelClientRequest: true
        )
    }

    package func forwardRefreshCodeIssuesRequest(
        _ refreshRequest: RefreshCodeIssues.Request,
        bodyData: Data,
        sessionID: String,
        requestIDs: [JSONRPC.ID],
        requestIsBatch: Bool,
        requestTimeoutOverride: TimeAmount? = nil,
        eventLoop: EventLoop,
        leaseID: LeaseManager.ID,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle?
    ) async -> RefreshCodeIssues.Workflow.ForwardAttemptResult {
        await refreshWorkflow.run(
            refreshRequest: refreshRequest,
            bodyData: bodyData,
            sessionID: sessionID,
            requestIDs: requestIDs,
            requestIsBatch: requestIsBatch,
            requestTimeoutOverride: requestTimeoutOverride,
            eventLoop: eventLoop,
            windowsProvider: { sessionID, eventLoop, upstreamIndexOverride, requestTimeoutOverride in
                try await self.listXcodeWindows(
                    sessionID: sessionID,
                    eventLoop: eventLoop,
                    cancellationHandle: cancellationHandle,
                    upstreamIndexOverride: upstreamIndexOverride,
                    requestTimeoutOverride: requestTimeoutOverride
                )
            },
            internalUpstreamChooser: { _ in
                self.sessionManager.chooseUpstreamIndex()
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
            forwarder: {
                bodyData, sessionID, requestIDs, requestIsBatch, shouldRequeueLeaseOnRetryableFailure, eventLoop, requestTimeoutOverride in
                await self.forwardOnce(
                    bodyData: bodyData,
                    sessionID: sessionID,
                    requestIDs: requestIDs,
                    requestIsBatch: requestIsBatch,
                    shouldRequeueLeaseOnRetryableFailure: shouldRequeueLeaseOnRetryableFailure,
                    eventLoop: eventLoop,
                    leaseID: leaseID,
                    cancellationHandle: cancellationHandle,
                    requestTimeoutOverride: requestTimeoutOverride
                )
            }
        )
    }

    /// Runs one already-classified refresh route directly. A route is a
    /// pure XcodeRefreshCodeIssuesInFile call extracted by the routing pass,
    /// so re-entering handle() for it would only replay request gates that
    /// are no-ops; this performs exactly the lease/cancellation choreography
    /// the re-entry used to produce.
    package func executeRefreshRoute(
        _ route: ClientMCPRequestExecutor.RefreshRoute,
        sessionID: String,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount?,
        parentCancellationHandle: ClientMCPRequestExecutor.CancellationHandle?
    ) async -> ClientMCPRequestExecutor.Resolution {
        let parsedRoutePayload =
            (try? JSONSerialization.jsonObject(with: route.bodyData, options: []))
            ?? [String: Any]()
        let descriptor = Self.topLevelRequestDescriptor(
            sessionID: sessionID,
            parsedRequestJSON: parsedRoutePayload,
            requestIsBatch: route.requestIsBatch,
            requestIDs: route.requestIDs
        )
        let leaseID = sessionManager.createRequestLease(descriptor: descriptor)
        let cancellationHandle = ClientMCPRequestExecutor.CancellationHandle(
            leaseID: leaseID,
            sessionID: sessionID,
            requestIDKeys: route.requestIDs.map(\.key)
        )
        if let parentCancellationHandle,
            parentCancellationHandle.bindChildHandle(cancellationHandle) == false
        {
            cancellationHandle.cancel(using: sessionManager)
            return .empty(status: .accepted, sessionID: sessionID)
        }
        sessionManager.activateRequestLease(
            leaseID,
            requestIDKey: route.requestIDs.first?.key,
            upstreamIndex: nil,
            timeout: requestTimeoutOverride
                ?? Self.topLevelRequestTimeoutOverride(
                    method: nil,
                    defaultSeconds: requestTimeoutSeconds
                )
        )
        let result = await forwardRefreshCodeIssuesRequest(
            route.request,
            bodyData: route.bodyData,
            sessionID: sessionID,
            requestIDs: route.requestIDs,
            requestIsBatch: route.requestIsBatch,
            requestTimeoutOverride: requestTimeoutOverride,
            eventLoop: eventLoop,
            leaseID: leaseID,
            cancellationHandle: cancellationHandle
        )
        if Task.isCancelled {
            cancellationHandle.markCompleted()
            return .empty(status: .accepted, sessionID: sessionID)
        }
        cancellationHandle.markCompleted()
        finishRefreshLease(leaseID, result: result)
        return makeResolution(
            from: result,
            sessionID: sessionID,
            prefersEventStream: prefersEventStream
        )
    }

    package func makeResolution(
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
        case .timeout(let responseIDs, let isBatch):
            return .mcpError(
                id: nil,
                ids: responseIDs,
                code: -32000,
                message: "upstream timeout",
                forceBatchArray: isBatch,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        case .upstreamUnavailable(let responseIDs, let isBatch):
            if responseIDs.isEmpty {
                return .plain(
                    status: .serviceUnavailable,
                    body: "upstream unavailable",
                    sessionID: sessionID
                )
            }
            return .mcpError(
                id: nil,
                ids: responseIDs,
                code: -32001,
                message: "upstream unavailable",
                forceBatchArray: isBatch,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        case .cancelled(let responseIDs, let isBatch):
            return .mcpError(
                id: nil,
                ids: responseIDs,
                code: -32800,
                message: "request cancelled",
                forceBatchArray: isBatch,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        case .invalidRequest:
            return .mcpError(
                id: nil,
                ids: [],
                code: -32700,
                message: "invalid json",
                forceBatchArray: false,
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

    package func makeImmediateLeaseResolution(
        _ resolution: ClientMCPRequestExecutor.Resolution,
        leaseID: LeaseManager.ID,
        eventLoop: EventLoop,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle?
    ) -> EventLoopFuture<ClientMCPRequestExecutor.Resolution> {
        cancellationHandle?.markCompleted()
        sessionManager.completeRequestLease(leaseID)
        return eventLoop.makeSucceededFuture(resolution)
    }

    package func cancel(
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
