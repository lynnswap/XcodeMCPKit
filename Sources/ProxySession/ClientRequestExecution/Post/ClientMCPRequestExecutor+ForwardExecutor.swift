import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import ProxyCore
import XcodeMCPRuntime
import ProxyXcodeFeatures
import ProxyXcodeSupport

extension ClientMCPRequestExecutor {
    package func makeTopLevelRequestFuture(
        filteredRequest: FilteredToolCallRequest,
        sessionID: String,
        headerSessionID: String?,
        requestIsBatch: Bool,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        session: SessionContext,
        leaseID: LeaseManager.ID,
        upstreamIndex: Int,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle?,
        requestTimeoutOverride: TimeAmount?
    ) -> EventLoopFuture<ClientMCPRequestExecutor.Resolution> {
        guard let forwardedBodyData = filteredRequest.bodyData
        else {
            return makeImmediateLeaseResolution(
                Self.makeLocalResponseResolution(
                    responseData: filteredRequest.localResponseData,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream,
                    emptyStatus: .accepted
                ),
                leaseID: leaseID,
                eventLoop: eventLoop,
                cancellationHandle: cancellationHandle
            )
        }

        let forwardedRequestJSON: Any
        do {
            forwardedRequestJSON = try JSONSerialization.jsonObject(with: forwardedBodyData, options: [])
        } catch {
            return makeImmediateLeaseResolution(
                .mcpError(
                    id: nil,
                    ids: [],
                    code: -32700,
                    message: "invalid json",
                    forceBatchArray: false,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                ),
                leaseID: leaseID,
                eventLoop: eventLoop,
                cancellationHandle: cancellationHandle
            )
        }
        let localResponseData = filteredRequest.localResponseData
        let refreshRouting = refreshRequestRouting(from: forwardedRequestJSON)

        if let refreshRouting, filteredRequest.forwardedResponseIDs.isEmpty == false {
            if headerSessionID == nil {
                return makeImmediateLeaseResolution(
                    Self.makeExpectedInitializeResolution(
                        requestIDs: filteredRequest.forwardedResponseIDs,
                        requestIsBatch: requestIsBatch,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    ),
                    leaseID: leaseID,
                    eventLoop: eventLoop,
                    cancellationHandle: cancellationHandle
                )
            }

            if refreshRouting.refreshRoutes.count == 1,
                refreshRouting.remainingBodyData == nil,
                refreshRouting.remainingLocalResponseData == nil,
                let route = refreshRouting.refreshRoutes.first
            {
                let promise = eventLoop.makePromise(of: ClientMCPRequestExecutor.Resolution.self)
                let refreshTask = Task { [self] in
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
                    let wasCancelled = Task.isCancelled
                    eventLoop.execute {
                        if wasCancelled {
                            cancellationHandle?.markCompleted()
                            promise.succeed(.empty(status: .accepted, sessionID: sessionID))
                            return
                        }
                        cancellationHandle?.markCompleted()
                        self.finishRefreshLease(leaseID, result: result)
                        let resolution = self.makeResolution(
                            from: result,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                        promise.succeed(
                            Self.makeLocalResponseResolution(
                                responseData: Self.mergeBatchResponsePayloads(
                                    [
                                        Self.responseDataForBatchResolution(
                                            resolution,
                                            fallbackRequestIDs: route.requestIDs,
                                            forceBatchArray: route.requestIsBatch
                                        ),
                                        localResponseData,
                                    ],
                                    forceBatchArray: requestIsBatch
                                ),
                                sessionID: sessionID,
                                prefersEventStream: prefersEventStream,
                                emptyStatus: .accepted
                            )
                        )
                    }
                }
                cancellationHandle?.bindRefreshTask(refreshTask)
                return promise.futureResult
            }

            let promise = eventLoop.makePromise(of: ClientMCPRequestExecutor.Resolution.self)
            let refreshTask = Task { [self] in
                var payloads: [Data?] = []
                let splitDeadline = timeoutDeadline(
                    for: requestTimeoutOverride
                        ?? Self.topLevelRequestTimeoutOverride(
                            method: nil,
                            defaultSeconds: requestTimeoutSeconds
                        )
                )

                for route in refreshRouting.refreshRoutes {
                    guard !Task.isCancelled else { break }
                    let remainingTimeout = remainingRequestTimeout(
                        until: splitDeadline
                    )
                    if splitDeadline != nil, remainingTimeout == nil {
                        payloads.append(
                            Self.makeRequestTimeoutResponseData(
                                requestIDs: route.requestIDs,
                                forceBatchArray: route.requestIsBatch
                            )
                        )
                        continue
                    }
                    let resolution = await self.executeRefreshRoute(
                        route,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream,
                        eventLoop: eventLoop,
                        requestTimeoutOverride: remainingTimeout,
                        parentCancellationHandle: cancellationHandle
                    )
                    payloads.append(
                        Self.responseDataForBatchResolution(
                            resolution,
                            fallbackRequestIDs: route.requestIDs,
                            forceBatchArray: route.requestIsBatch
                        )
                    )
                }

                if !Task.isCancelled {
                    payloads.append(refreshRouting.remainingLocalResponseData)
                }

                if !Task.isCancelled,
                    let remainingBodyData = refreshRouting.remainingBodyData
                {
                    let remainingTimeout = remainingRequestTimeout(
                        until: splitDeadline
                    )
                    if splitDeadline != nil, remainingTimeout == nil {
                        payloads.append(
                            Self.makeRequestTimeoutResponseData(
                                requestIDs: refreshRouting.remainingRequestIDs,
                                forceBatchArray: true
                            )
                        )
                    } else {
                        // Bounded single re-entry: the routing pass removed
                        // every refresh item, so the remainder cannot reach
                        // this branch again (depth <= 1 structurally).
                        let operation = self.handle(
                            bodyData: remainingBodyData,
                            headerSessionID: sessionID,
                            headerSessionExists: true,
                            prefersEventStream: prefersEventStream,
                            eventLoop: eventLoop,
                            requestTimeoutOverride: remainingTimeout,
                            parentCancellationHandle: cancellationHandle
                        )
                        let resolution = try? await operation.future.get()
                        payloads.append(
                            Self.responseDataForBatchResolution(
                                resolution,
                                fallbackRequestIDs: refreshRouting.remainingRequestIDs,
                                forceBatchArray: true
                            )
                        )
                    }
                }

                let wasCancelled = Task.isCancelled
                let mergedPayloadInputs = payloads + [localResponseData]
                eventLoop.execute {
                    if wasCancelled {
                        cancellationHandle?.markCompleted()
                        promise.succeed(.empty(status: .accepted, sessionID: sessionID))
                        return
                    }
                    cancellationHandle?.markCompleted()
                    let mergedData = Self.mergeBatchResponsePayloads(
                        mergedPayloadInputs,
                        forceBatchArray: requestIsBatch
                    )
                    promise.succeed(
                        Self.makeLocalResponseResolution(
                            responseData: mergedData,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream,
                            emptyStatus: .accepted
                        )
                    )
                    self.sessionManager.completeRequestLease(leaseID)
                }
            }
            cancellationHandle?.bindRefreshTask(refreshTask)
            return promise.futureResult
        }

        let prepared: MCPForwardingService.PreparedRequest
        do {
            guard let candidate = try forwardingService.prepareRequest(
                bodyData: forwardedBodyData,
                parsedRequestJSON: forwardedRequestJSON,
                sessionID: sessionID,
                upstreamIndexOverride: upstreamIndex
            ) else {
                return makeImmediateLeaseResolution(
                    Self.makeUpstreamUnavailableResolution(
                        localResponseData: localResponseData,
                        responseIDs: filteredRequest.forwardedResponseIDs,
                        forceBatchArray: filteredRequest.forceBatchArray,
                        requestIsBatch: requestIsBatch,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    ),
                    leaseID: leaseID,
                    eventLoop: eventLoop,
                    cancellationHandle: cancellationHandle
                )
            }
            prepared = candidate
        } catch {
            return makeImmediateLeaseResolution(
                .mcpError(
                id: nil,
                ids: [],
                code: -32700,
                message: "invalid json",
                forceBatchArray: false,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
                ),
                leaseID: leaseID,
                eventLoop: eventLoop,
                cancellationHandle: cancellationHandle
            )
        }

        if headerSessionID == nil {
            if prepared.transform.isBatch || prepared.transform.method != "initialize"
                || !prepared.transform.expectsResponse
            {
                return makeImmediateLeaseResolution(
                    Self.makeExpectedInitializeResolution(
                        requestIDs: prepared.transform.responseIDs,
                        requestIsBatch: prepared.transform.isBatch,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    ),
                    leaseID: leaseID,
                    eventLoop: eventLoop,
                    cancellationHandle: cancellationHandle
                )
            }
        }

        if prepared.transform.expectsResponse {
            let started: MCPForwardingService.StartedRequest
            do {
                let methodRequestTimeoutOverride = Self.topLevelRequestTimeoutOverride(
                    method: prepared.transform.method,
                    defaultSeconds: requestTimeoutSeconds
                )
                let effectiveRequestTimeoutOverride = Self.minimumRequestTimeout(
                    methodRequestTimeoutOverride,
                    requestTimeoutOverride
                )
                logger.debug(
                    "Starting top-level upstream request",
                    metadata: [
                        "lease_id": .string(leaseID.uuidString),
                        "session": .string(sessionID),
                        "label": .string(Self.requestLabel(from: forwardedRequestJSON)),
                        "upstream": .string("\(prepared.upstreamIndex)"),
                        "timeout_ms": .string(
                            effectiveRequestTimeoutOverride.map {
                                "\($0.nanoseconds / 1_000_000)"
                            }
                                ?? "disabled"
                        ),
                    ]
                )
                started = try forwardingService.startRequest(
                    prepared,
                    session: session,
                    on: eventLoop
                    ,
                    requestTimeoutOverride: effectiveRequestTimeoutOverride,
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
                return makeImmediateLeaseResolution(
                    .mcpError(
                    id: nil,
                    ids: [],
                    code: -32600,
                    message: "missing id",
                    forceBatchArray: false,
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
                switch resolution {
                case .success(let responseData):
                    cancellationHandle?.markCompleted()
                    self.sessionManager.completeRequestLease(leaseID)
                    self.logger.debug(
                        "Finished top-level upstream request",
                        metadata: [
                            "lease_id": .string(leaseID.uuidString),
                            "session": .string(sessionID),
                            "release_reason": .string("completed"),
                            "upstream": .string("\(prepared.upstreamIndex)"),
                            "request_ids": .string(started.transform.responseIDs.map(\.key).joined(separator: ",")),
                        ]
                    )
                    promise.succeed(
                        .responseData(
                            data: Self.mergeLocalBatchResponses(
                                into: responseData,
                                localResponseData: localResponseData
                            ),
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
                    self.logger.debug(
                        "Finished top-level upstream request",
                        metadata: [
                            "lease_id": .string(leaseID.uuidString),
                            "session": .string(sessionID),
                            "release_reason": .string("invalidUpstreamResponse"),
                            "upstream": .string("\(prepared.upstreamIndex)"),
                            "request_ids": .string(started.transform.responseIDs.map(\.key).joined(separator: ",")),
                        ]
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
                    self.logger.debug(
                        "Finished top-level upstream request",
                        metadata: [
                            "lease_id": .string(leaseID.uuidString),
                            "session": .string(sessionID),
                            "release_reason": .string("timedOut"),
                            "upstream": .string("\(prepared.upstreamIndex)"),
                            "request_ids": .string(started.transform.responseIDs.map(\.key).joined(separator: ",")),
                        ]
                    )
                    promise.succeed(
                        Self.makePartialBatchErrorResolution(
                            localResponseData: localResponseData,
                            responseIDs: started.transform.responseIDs,
                            code: -32000,
                            message: "upstream timeout",
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream,
                            forceBatchArray: started.transform.isBatch,
                            fallbackStatus: .ok,
                            fallbackBody: ""
                        )
                    )
                }
            }
            return promise.futureResult
        }

        if prepared.transform.method == "notifications/initialized" && sessionManager.isInitialized() {
            return makeImmediateLeaseResolution(
                .empty(status: .accepted, sessionID: sessionID),
                leaseID: leaseID,
                eventLoop: eventLoop,
                cancellationHandle: cancellationHandle
            )
        }

        sessionManager.sendUpstream(
            prepared.transform.upstreamData,
            upstreamIndex: prepared.upstreamIndex,
            ensureRunning: false
        )
        return makeImmediateLeaseResolution(
            Self.makeLocalResponseResolution(
                responseData: localResponseData,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream,
                emptyStatus: .accepted
            ),
            leaseID: leaseID,
            eventLoop: eventLoop,
            cancellationHandle: cancellationHandle
        )
    }
}
