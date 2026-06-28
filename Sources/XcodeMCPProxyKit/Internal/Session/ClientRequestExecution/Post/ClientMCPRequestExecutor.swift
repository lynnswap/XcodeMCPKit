import Foundation
import Logging
import NIO
import XcodeMCPKit

final class ClientMCPRequestExecutor: Sendable {
    struct FilteredToolCallRequest: Sendable {
        let bodyData: Data?
        let localResponseData: Data?
        let forwardedResponseIDs: [JSONRPC.ID]
        let forceBatchArray: Bool

        init(
            bodyData: Data?,
            localResponseData: Data?,
            forwardedResponseIDs: [JSONRPC.ID],
            forceBatchArray: Bool
        ) {
            self.bodyData = bodyData
            self.localResponseData = localResponseData
            self.forwardedResponseIDs = forwardedResponseIDs
            self.forceBatchArray = forceBatchArray
        }
    }

    struct LocalToolBatchResult: Sendable {
        let responseData: Data?
        let fallbackForwardedRequest: FilteredToolCallRequest?

        init(
            responseData: Data?,
            fallbackForwardedRequest: FilteredToolCallRequest?
        ) {
            self.responseData = responseData
            self.fallbackForwardedRequest = fallbackForwardedRequest
        }
    }

    private struct LocalToolFallbackForwardingResult {
        let request: FilteredToolCallRequest
        let resolution: ClientMCPRequestExecutor.Resolution
    }

    struct LocalToolFilterOperation {
        let localResponseFuture: EventLoopFuture<LocalToolBatchResult>
        let forwardedRequest: FilteredToolCallRequest
        let cancellationHandle: ClientMCPRequestExecutor.CancellationHandle
        let deadline: Date?
    }

    let sessionManager: any RuntimeClientMCPRequestPort
    let disabledToolNames: Set<String>
    let usesSynchronousLocalResolution: Bool
    let localResponder: LocalMCPResponder
    let forwardingService: MCPForwardingService
    let refreshWorkflow: RefreshCodeIssues.Workflow
    let requestTimeoutSeconds: TimeInterval
    let deadlineClock: ClockClient
    let logger: Logger

    init(
        config: ProxyConfig,
        sessionManager: any RuntimeClientMCPRequestPort,
        refreshCodeIssuesCoordinator: RefreshCodeIssues.Coordinator,
        refreshCodeIssuesTargetResolver: RefreshCodeIssues.TargetResolver = RefreshCodeIssues.TargetResolver(),
        refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState,
        refreshCodeIssuesClock: ClockClient = .liveValue,
        deadlineClock: ClockClient = .liveValue,
        usesSynchronousLocalResolution: Bool = false,
        logger: Logger = ProxyLogging.make("http")
    ) {
        self.requestTimeoutSeconds = config.requestTimeout
        self.deadlineClock = deadlineClock
        self.sessionManager = sessionManager
        self.disabledToolNames = config.disabledToolNames
        self.usesSynchronousLocalResolution = usesSynchronousLocalResolution
        self.localResponder = LocalMCPResponder(
            sessionManager: sessionManager,
            refreshCodeIssuesMode: config.refreshCodeIssuesMode,
            disabledToolNames: config.disabledToolNames,
            usesSynchronousLocalResolution: usesSynchronousLocalResolution,
            logger: ProxyLogging.make("http.local")
        )
        self.forwardingService = MCPForwardingService(
            config: config,
            sessionManager: sessionManager
        )
        self.refreshWorkflow = RefreshCodeIssues.Workflow(
            mode: config.refreshCodeIssuesMode,
            requestTimeout: config.requestTimeout,
            coordinator: refreshCodeIssuesCoordinator,
            targetResolver: refreshCodeIssuesTargetResolver,
            debugState: refreshCodeIssuesDebugState,
            clock: refreshCodeIssuesClock,
            logger: ProxyLogging.make("http.refresh")
        )
        self.logger = logger
    }

    func handle(
        bodyData: Data,
        headerSessionID: String?,
        headerSessionExists: Bool,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount? = nil,
        parentCancellationHandle: ClientMCPRequestExecutor.CancellationHandle? = nil
    ) -> ClientMCPRequestExecutor.Operation {
        let parsedRequestJSON = try? JSONSerialization.jsonObject(with: bodyData, options: [])
        let requestMetadata = MCPErrorResponder.requestMetadata(fromParsed: parsedRequestJSON)
        let requestIDs = requestMetadata.ids
        let requestIsBatch = requestMetadata.isBatch

        if let localRequest = Self.localHandlingRequest(from: parsedRequestJSON),
            let localHandling = localResponder.handle(
                object: localRequest.object,
                headerSessionID: headerSessionID,
                headerSessionExists: headerSessionExists,
                eventLoop: eventLoop,
                requestTimeoutOverride: requestTimeoutOverride
            )
        {
            return ClientMCPRequestExecutor.Operation(
                future: resolveLocalHandling(
                    localHandling,
                    prefersEventStream: prefersEventStream,
                    eventLoop: eventLoop,
                    forceBatchArray: localRequest.forceBatchArray
                ),
                cancellationHandle: nil
            )
        }

        guard let sessionID = headerSessionID, sessionID.isEmpty == false else {
            return ClientMCPRequestExecutor.Operation(
                future: eventLoop.makeSucceededFuture(
                    .plain(
                        status: .badRequest,
                        body: "session id required",
                        sessionID: nil
                    )
                ),
                cancellationHandle: nil
            )
        }

        guard headerSessionExists else {
            return ClientMCPRequestExecutor.Operation(
                future: eventLoop.makeSucceededFuture(
                    .plain(
                        status: .notFound,
                        body: "session not found",
                        sessionID: sessionID
                    )
                ),
                cancellationHandle: nil
            )
        }

        if let requestObject = parsedRequestJSON as? [String: Any] {
            switch JSONRPC.Message.Inspector.kind(of: requestObject) {
            case .malformed(let invalidID):
                return ClientMCPRequestExecutor.Operation(
                    future: eventLoop.makeSucceededFuture(
                        .mcpError(
                            id: invalidID,
                            ids: [],
                            code: -32600,
                            message: "invalid request",
                            forceBatchArray: false,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    ),
                    cancellationHandle: nil
                )
            case .response(let responseID):
                return makeClientResponseForwardingOperation(
                    responseObject: requestObject,
                    sessionID: sessionID,
                    responseID: responseID,
                    eventLoop: eventLoop
                )
            case .request, .notification, .other:
                break
            }
        }

        if sessionManager.isInitialized() == false {
            return ClientMCPRequestExecutor.Operation(
                future: eventLoop.makeSucceededFuture(
                    Self.makeExpectedInitializeResolution(
                        requestIDs: requestIDs,
                        requestIsBatch: requestIsBatch,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                ),
                cancellationHandle: nil
            )
        }

        guard let parsedRequestJSON else {
            return ClientMCPRequestExecutor.Operation(
                future: eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: [],
                        code: -32700,
                        message: "invalid json",
                        forceBatchArray: false,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                ),
                cancellationHandle: nil
            )
        }

        if headerSessionID == nil,
            let initializeResolution = Self.makeMissingInitializeResolution(
                parsedRequestJSON: parsedRequestJSON,
                requestIDs: requestIDs,
                requestIsBatch: requestIsBatch,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        {
            return ClientMCPRequestExecutor.Operation(
                future: eventLoop.makeSucceededFuture(initializeResolution),
                cancellationHandle: nil
            )
        }

        let routing: ToolCallRouting
        do {
            routing = try routeToolCalls(
                bodyData: bodyData,
                sessionID: sessionID,
                forceBatchArray: requestIsBatch,
                eventLoop: eventLoop,
                requestTimeoutOverride: requestTimeoutOverride
            )
        } catch {
            return ClientMCPRequestExecutor.Operation(
                future: eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: [],
                        code: -32700,
                        message: "invalid json",
                        forceBatchArray: false,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                ),
                cancellationHandle: nil
            )
        }

        if let localToolFilter = routing.localOperation {
            if let parentCancellationHandle,
                parentCancellationHandle.bindChildHandle(localToolFilter.cancellationHandle) == false
            {
                localToolFilter.cancellationHandle.cancel(using: sessionManager)
                return ClientMCPRequestExecutor.Operation(
                    future: eventLoop.makeSucceededFuture(
                        .empty(status: .accepted, sessionID: sessionID)
                    ),
                    cancellationHandle: nil
                )
            }

            let forwardingFuture = makeLocalToolForwardingFuture(
                request: localToolFilter.forwardedRequest,
                sessionID: sessionID,
                headerSessionID: headerSessionID,
                requestIsBatch: requestIsBatch,
                prefersEventStream: prefersEventStream,
                eventLoop: eventLoop,
                deadline: localToolFilter.deadline,
                cancellationHandle: localToolFilter.cancellationHandle
            )
            let localAndFallbackFuture = localToolFilter.localResponseFuture.flatMap {
                localBatchResult -> EventLoopFuture<(
                    LocalToolBatchResult,
                    LocalToolFallbackForwardingResult?
                )> in
                guard let fallbackRequest = localBatchResult.fallbackForwardedRequest else {
                    return eventLoop.makeSucceededFuture((localBatchResult, nil))
                }
                return self.makeLocalToolForwardingFuture(
                    request: fallbackRequest,
                    sessionID: sessionID,
                    headerSessionID: headerSessionID,
                    requestIsBatch: requestIsBatch,
                    prefersEventStream: prefersEventStream,
                    eventLoop: eventLoop,
                    deadline: localToolFilter.deadline,
                    cancellationHandle: localToolFilter.cancellationHandle
                ).map { fallbackResolution in
                    (
                        localBatchResult,
                        LocalToolFallbackForwardingResult(
                            request: fallbackRequest,
                            resolution: fallbackResolution
                        )
                    )
                }
            }
            let future = forwardingFuture.and(localAndFallbackFuture).map {
                forwardingResolution,
                localAndFallback in
                let (localBatchResult, fallbackForwarding) = localAndFallback
                let initialResolution = Self.mergeLocalToolResponseData(
                    localBatchResult.responseData,
                    into: forwardingResolution,
                    fallbackRequestIDs: localToolFilter.forwardedRequest.forwardedResponseIDs,
                    forceBatchArray: localToolFilter.forwardedRequest.forceBatchArray,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
                guard let fallbackForwarding else {
                    return initialResolution
                }
                let initialData = Self.responseDataForBatchResolution(
                    initialResolution,
                    fallbackRequestIDs: localToolFilter.forwardedRequest.forwardedResponseIDs,
                    forceBatchArray: localToolFilter.forwardedRequest.forceBatchArray
                )
                return Self.mergeLocalToolResponseData(
                    initialData,
                    into: fallbackForwarding.resolution,
                    fallbackRequestIDs: fallbackForwarding.request.forwardedResponseIDs,
                    forceBatchArray: fallbackForwarding.request.forceBatchArray,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            }
            future.whenComplete { result in
                guard (try? result.get()) != nil else { return }
                localToolFilter.cancellationHandle.markCompleted()
                self.sessionManager.completeRequestLease(localToolFilter.cancellationHandle.leaseID)
            }
            return ClientMCPRequestExecutor.Operation(
                future: future,
                cancellationHandle: localToolFilter.cancellationHandle
            )
        }

        return makeForwardingOperation(
            filteredRequest: routing.forwardedRequest,
            sessionID: sessionID,
            headerSessionID: headerSessionID,
            requestIsBatch: requestIsBatch,
            prefersEventStream: prefersEventStream,
            eventLoop: eventLoop,
            requestTimeoutOverride: requestTimeoutOverride,
            parentCancellationHandle: parentCancellationHandle
        )
    }

    private func makeLocalToolForwardingFuture(
        request: FilteredToolCallRequest,
        sessionID: String,
        headerSessionID: String?,
        requestIsBatch: Bool,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        deadline: Date?,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle
    ) -> EventLoopFuture<ClientMCPRequestExecutor.Resolution> {
        let forwardingTimeout = remainingRequestTimeout(until: deadline)
        if deadline != nil,
            forwardingTimeout == nil,
            request.bodyData != nil
        {
            return eventLoop.makeSucceededFuture(
                .mcpError(
                    id: nil,
                    ids: request.forwardedResponseIDs,
                    code: -32000,
                    message: "upstream timeout",
                    forceBatchArray: request.forceBatchArray,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }
        return makeForwardingOperation(
            filteredRequest: request,
            sessionID: sessionID,
            headerSessionID: headerSessionID,
            requestIsBatch: requestIsBatch,
            prefersEventStream: prefersEventStream,
            eventLoop: eventLoop,
            requestTimeoutOverride: forwardingTimeout,
            parentCancellationHandle: cancellationHandle
        ).future
    }

    func makeForwardingOperation(
        filteredRequest: FilteredToolCallRequest,
        sessionID: String,
        headerSessionID: String?,
        requestIsBatch: Bool,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount?,
        parentCancellationHandle: ClientMCPRequestExecutor.CancellationHandle?
    ) -> ClientMCPRequestExecutor.Operation {
        guard let forwardedBodyData = filteredRequest.bodyData else {
            return ClientMCPRequestExecutor.Operation(
                future: eventLoop.makeSucceededFuture(
                    Self.makeLocalResponseResolution(
                        responseData: filteredRequest.localResponseData,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream,
                        emptyStatus: .accepted
                    )
                ),
                cancellationHandle: nil
            )
        }

        let forwardedRequestJSON: Any
        do {
            forwardedRequestJSON = try JSONSerialization.jsonObject(with: forwardedBodyData, options: [])
        } catch {
            return ClientMCPRequestExecutor.Operation(
                future: eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: [],
                        code: -32700,
                        message: "invalid json",
                        forceBatchArray: false,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                ),
                cancellationHandle: nil
            )
        }

        let forwardingDeadline = timeoutDeadline(
            for: requestTimeoutOverride
                ?? Self.topLevelRequestTimeoutOverride(
                    method: nil,
                    defaultSeconds: requestTimeoutSeconds
                )
        )
        let forwardedRequestIDs = filteredRequest.forwardedResponseIDs
        let localResponseData = filteredRequest.localResponseData
        let descriptor = Self.topLevelRequestDescriptor(
            sessionID: sessionID,
            parsedRequestJSON: forwardedRequestJSON,
            requestIsBatch: requestIsBatch,
            requestIDs: forwardedRequestIDs
        )
        let leaseID = sessionManager.createRequestLease(descriptor: descriptor)
        let cancellationHandle = ClientMCPRequestExecutor.CancellationHandle(
            leaseID: leaseID,
            sessionID: sessionID,
            requestIDKeys: forwardedRequestIDs.map(\.key)
        )
        if let parentCancellationHandle,
            parentCancellationHandle.bindChildHandle(cancellationHandle) == false
        {
            cancellationHandle.cancel(using: sessionManager)
            return ClientMCPRequestExecutor.Operation(
                future: eventLoop.makeSucceededFuture(
                    .empty(status: .accepted, sessionID: sessionID)
                ),
                cancellationHandle: nil
            )
        }
        let session = sessionManager.session(id: sessionID)
        let refreshRouting = refreshRequestRouting(from: forwardedRequestJSON)
        if refreshRouting != nil, forwardedRequestIDs.isEmpty == false {
            sessionManager.activateRequestLease(
                leaseID,
                requestIDKey: forwardedRequestIDs.first?.key,
                upstreamIndex: nil,
                timeout: requestTimeoutOverride
                    ?? Self.topLevelRequestTimeoutOverride(
                        method: nil,
                        defaultSeconds: requestTimeoutSeconds
                    )
            )
            return ClientMCPRequestExecutor.Operation(
                future: makeTopLevelRequestFuture(
                    filteredRequest: filteredRequest,
                    sessionID: sessionID,
                    headerSessionID: headerSessionID,
                    requestIsBatch: requestIsBatch,
                    prefersEventStream: prefersEventStream,
                    eventLoop: eventLoop,
                    session: session,
                    leaseID: leaseID,
                    upstreamIndex: -1,
                    cancellationHandle: cancellationHandle,
                    requestTimeoutOverride: requestTimeoutOverride
                ),
                cancellationHandle: cancellationHandle
            )
        }
        @Sendable func remainingForwardingTimeout() -> TimeAmount? {
            remainingRequestTimeout(until: forwardingDeadline)
        }
        @Sendable func makeForwardingTimeoutFuture() -> EventLoopFuture<ClientMCPRequestExecutor.Resolution> {
            cancellationHandle.markCompleted()
            self.sessionManager.failRequestLease(
                leaseID,
                terminalState: .timedOut,
                reason: .timedOut
            )
            return eventLoop.makeSucceededFuture(
                Self.makePartialBatchErrorResolution(
                    localResponseData: localResponseData,
                    responseIDs: forwardedRequestIDs,
                    code: -32000,
                    message: "upstream timeout",
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream,
                    forceBatchArray: requestIsBatch || filteredRequest.forceBatchArray,
                    fallbackStatus: .ok,
                    fallbackBody: ""
                )
            )
        }
        @Sendable func makeRoutingFuture(
            decision: ToolRoutingDecision
        ) -> EventLoopFuture<ClientMCPRequestExecutor.Resolution> {
            guard cancellationHandle.isCancelled == false else {
                return eventLoop.makeSucceededFuture(.empty(status: .accepted, sessionID: sessionID))
            }
            func makeForwardingFuture(
                preferredUpstreamIndices: [Int]?
            ) -> EventLoopFuture<ClientMCPRequestExecutor.Resolution> {
                let forwardingTimeout = remainingForwardingTimeout()
                if forwardingDeadline != nil, forwardingTimeout == nil {
                    return makeForwardingTimeoutFuture()
                }
                return self.sessionManager.enqueueOnUpstreamSlot(
                    leaseID: leaseID,
                    descriptor: descriptor,
                    on: eventLoop,
                    preferredUpstreamIndices: preferredUpstreamIndices
                ) { upstreamIndex in
                    cancellationHandle.activate(upstreamIndex: upstreamIndex)
                    self.sessionManager.activateRequestLease(
                        leaseID,
                        requestIDKey: nil,
                        upstreamIndex: upstreamIndex,
                        timeout: nil
                    )
                    return self.makeTopLevelRequestFuture(
                        filteredRequest: filteredRequest,
                        sessionID: sessionID,
                        headerSessionID: headerSessionID,
                        requestIsBatch: requestIsBatch,
                        prefersEventStream: prefersEventStream,
                        eventLoop: eventLoop,
                        session: session,
                        leaseID: leaseID,
                        upstreamIndex: upstreamIndex,
                        cancellationHandle: cancellationHandle,
                        requestTimeoutOverride: forwardingTimeout
                    )
                }.flatMapError { error in
                    if error is CancellationError {
                        return eventLoop.makeFailedFuture(error)
                    }
                    let releaseReason: LeaseManager.ReleaseReason =
                        error is UpstreamSlotScheduler.AcquisitionError
                        ? .upstreamUnavailable
                        : .upstreamOverloaded
                    cancellationHandle.markCompleted()
                    self.sessionManager.failRequestLease(
                        leaseID,
                        terminalState: .failed,
                        reason: releaseReason
                    )
                    return eventLoop.makeSucceededFuture(
                        Self.makeUpstreamUnavailableResolution(
                            localResponseData: localResponseData,
                            responseIDs: forwardedRequestIDs,
                            forceBatchArray: filteredRequest.forceBatchArray,
                            requestIsBatch: requestIsBatch,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                }
            }
            switch decision {
            case .reject(let errors, let forceBatchArray):
                let routedErrorIDKeys = Set(errors.map(\.id.key))
                let unroutedRequestIDs = forwardedRequestIDs.filter {
                    routedErrorIDKeys.contains($0.key) == false
                }
                let errorData = Self.makeToolRoutingErrorResponseData(
                    errors: errors,
                    forceBatchArray: forceBatchArray || requestIsBatch
                )
                let unroutedErrorData = Self.makeJSONRPCErrorResponseData(
                    ids: unroutedRequestIDs,
                    code: -32000,
                    message: "request not forwarded because tool routing rejected the batch",
                    forceBatchArray: true
                )
                let responseData = Self.mergeBatchResponsePayloads(
                    [
                        errorData,
                        unroutedErrorData,
                        localResponseData,
                    ],
                    forceBatchArray: forceBatchArray || requestIsBatch
                )
                cancellationHandle.markCompleted()
                self.sessionManager.completeRequestLease(leaseID)
                return eventLoop.makeSucceededFuture(
                    Self.makeLocalResponseResolution(
                        responseData: responseData,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream,
                        emptyStatus: .accepted
                    )
                )
            case .localXcodeListWindows:
                guard forwardedRequestIDs.isEmpty == false else {
                    cancellationHandle.markCompleted()
                    self.sessionManager.completeRequestLease(leaseID)
                    return eventLoop.makeSucceededFuture(
                        Self.makeLocalResponseResolution(
                            responseData: localResponseData,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream,
                            emptyStatus: .accepted
                        )
                    )
                }
                let promise = eventLoop.makePromise(of: ClientMCPRequestExecutor.Resolution.self)
                let responseIDs = forwardedRequestIDs
                let forceBatchArray = requestIsBatch || filteredRequest.forceBatchArray
                let windowsTimeout = remainingForwardingTimeout()
                if forwardingDeadline != nil, windowsTimeout == nil {
                    return makeForwardingTimeoutFuture()
                }
                let task = Task { [self] in
                    let responseData: Data?
                    if Task.isCancelled {
                        responseData = localResponseData
                    } else {
                        do {
                            let result = try await sessionManager.liveXcodeListWindowsResult(
                                route: .anyHealthy,
                                requestTimeoutOverride: windowsTimeout
                            )
                            let resultData = Self.makeJSONRPCResultResponseData(
                                ids: responseIDs,
                                result: result,
                                forceBatchArray: forceBatchArray
                            )
                            responseData = Self.mergeBatchResponsePayloads(
                                [
                                    resultData,
                                    localResponseData,
                                ],
                                forceBatchArray: forceBatchArray
                            )
                        } catch {
                            let mapped = ControlPlane.ErrorMapper.jsonRPCError(for: error)
                            let errorData = Self.makeJSONRPCErrorResponseData(
                                ids: responseIDs,
                                code: mapped.code,
                                message: mapped.message,
                                forceBatchArray: forceBatchArray
                            )
                            responseData = Self.mergeBatchResponsePayloads(
                                [
                                    errorData,
                                    localResponseData,
                                ],
                                forceBatchArray: forceBatchArray
                            )
                        }
                    }
                    eventLoop.execute {
                        cancellationHandle.markCompleted()
                        self.sessionManager.completeRequestLease(leaseID)
                        promise.succeed(
                            Self.makeLocalResponseResolution(
                                responseData: responseData,
                                sessionID: sessionID,
                                prefersEventStream: prefersEventStream,
                                emptyStatus: .accepted
                            )
                        )
                    }
                }
                cancellationHandle.bindRefreshTask(task)
                return promise.futureResult
            case .forward(let preferredUpstreamIndex):
                return makeForwardingFuture(
                    preferredUpstreamIndices: preferredUpstreamIndex.map { [$0] }
                )
            case .forwardAny(let preferredUpstreamIndices):
                return makeForwardingFuture(
                    preferredUpstreamIndices: preferredUpstreamIndices
                )
            }
        }

        if let immediateDecision = sessionManager.immediateToolRoutingDecision(
            for: forwardedRequestJSON
        ) {
            return ClientMCPRequestExecutor.Operation(
                future: makeRoutingFuture(decision: immediateDecision),
                cancellationHandle: cancellationHandle
            )
        }

        let routingPromise = eventLoop.makePromise(of: ClientMCPRequestExecutor.Resolution.self)
        let routingTask = Task { [self] in
            let routingTimeout = remainingRequestTimeout(until: forwardingDeadline)
            if forwardingDeadline != nil, routingTimeout == nil {
                eventLoop.execute {
                    makeForwardingTimeoutFuture().cascade(to: routingPromise)
                }
                return
            }
            let decision = await sessionManager.toolRoutingDecision(
                for: forwardedRequestJSON,
                requestTimeoutOverride: routingTimeout
            )
            eventLoop.execute {
                makeRoutingFuture(decision: decision).cascade(to: routingPromise)
            }
        }
        cancellationHandle.bindRefreshTask(routingTask)
        return ClientMCPRequestExecutor.Operation(
            future: routingPromise.futureResult,
            cancellationHandle: cancellationHandle
        )
    }

    private func makeClientResponseForwardingOperation(
        responseObject: [String: Any],
        sessionID: String,
        responseID: JSONRPC.ID,
        eventLoop: EventLoop
    ) -> ClientMCPRequestExecutor.Operation {
        guard let responseData = try? JSONRPC.Wire.data(from: responseObject) else {
            return ClientMCPRequestExecutor.Operation(
                future: eventLoop.makeSucceededFuture(
                    .plain(
                        status: .badRequest,
                        body: "invalid json-rpc response",
                        sessionID: sessionID
                    )
                ),
                cancellationHandle: nil
            )
        }
        let future = sessionManager.forwardServerRequestResponse(
            responseData: responseData,
            sessionID: sessionID,
            responseID: responseID,
            on: eventLoop
        ).map { forwardingResult -> ClientMCPRequestExecutor.Resolution in
            switch forwardingResult {
            case .accepted, .missingRoute:
                return .empty(status: .accepted, sessionID: sessionID)
            case .invalidResponse:
                return .plain(
                    status: .badRequest,
                    body: "invalid json-rpc response",
                    sessionID: sessionID
                )
            case .upstreamUnavailable:
                return .plain(
                    status: .serviceUnavailable,
                    body: "upstream unavailable",
                    sessionID: sessionID
                )
            }
        }
        return ClientMCPRequestExecutor.Operation(
            future: future,
            cancellationHandle: nil
        )
    }
}
