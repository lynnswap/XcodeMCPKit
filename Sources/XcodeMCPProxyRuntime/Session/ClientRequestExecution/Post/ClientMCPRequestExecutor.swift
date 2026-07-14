import Foundation
import Logging
import NIO
import XcodeMCPKit

final class ClientMCPRequestExecutor: Sendable {
    struct FilteredToolCallRequest: Sendable {
        let bodyData: Data?
        let localResponseData: Data?
        let forwardedResponseID: JSONRPC.ID?
    }

    let sessionManager: any RuntimeClientMCPRequestPort
    let disabledToolNames: Set<String>
    let localResponder: LocalMCPResponder
    let forwardingService: MCPForwardingService
    let refreshWorkflow: RefreshCodeIssues.Workflow
    let eventLoopCompletionExecutor: EventLoopCompletionExecutor
    let requestTimeoutSeconds: TimeInterval
    let deadlineClock: ClockClient
    let logger: Logger

    init(
        config: ProxyRuntimeConfiguration,
        sessionManager: any RuntimeClientMCPRequestPort,
        refreshCodeIssuesCoordinator: RefreshCodeIssues.Coordinator,
        refreshCodeIssuesTargetResolver: RefreshCodeIssues.TargetResolver = RefreshCodeIssues.TargetResolver(),
        refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState,
        refreshCodeIssuesClock: ClockClient = .liveValue,
        deadlineClock: ClockClient = .liveValue,
        eventLoopCompletionExecutor: EventLoopCompletionExecutor = .eventLoop,
        logger: Logger = ProxyLogging.make("http")
    ) {
        self.requestTimeoutSeconds = config.requestTimeout
        self.deadlineClock = deadlineClock
        self.sessionManager = sessionManager
        self.disabledToolNames = config.disabledToolNames
        self.eventLoopCompletionExecutor = eventLoopCompletionExecutor
        self.localResponder = LocalMCPResponder(
            sessionManager: sessionManager,
            refreshCodeIssuesMode: config.refreshCodeIssuesMode,
            disabledToolNames: config.disabledToolNames,
            eventLoopCompletionExecutor: eventLoopCompletionExecutor,
            logger: ProxyLogging.make("http.local")
        )
        self.forwardingService = MCPForwardingService(
            configuration: config,
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
        let parsedJSON: Any
        do {
            parsedJSON = try JSONSerialization.jsonObject(with: bodyData, options: [])
        } catch {
            return immediate(
                .mcpError(
                    id: nil,
                    code: -32700,
                    message: "invalid json",
                    sessionID: headerSessionID,
                    prefersEventStream: prefersEventStream
                ),
                on: eventLoop
            )
        }
        guard let requestObject = parsedJSON as? [String: Any] else {
            return immediate(
                .mcpError(
                    id: nil,
                    code: -32600,
                    message: "invalid request",
                    sessionID: headerSessionID,
                    prefersEventStream: prefersEventStream
                ),
                on: eventLoop
            )
        }

        if let localHandling = localResponder.handle(
            object: requestObject,
            headerSessionID: headerSessionID,
            headerSessionExists: headerSessionExists,
            eventLoop: eventLoop,
            requestTimeoutOverride: requestTimeoutOverride
        ) {
            return ClientMCPRequestExecutor.Operation(
                future: resolveLocalHandling(
                    localHandling,
                    prefersEventStream: prefersEventStream,
                    eventLoop: eventLoop
                ),
                cancellationHandle: nil
            )
        }

        guard let sessionID = headerSessionID, sessionID.isEmpty == false else {
            return immediate(
                .plain(status: .badRequest, body: "session id required", sessionID: nil),
                on: eventLoop
            )
        }
        guard headerSessionExists else {
            return immediate(
                .plain(status: .notFound, body: "session not found", sessionID: sessionID),
                on: eventLoop
            )
        }

        switch JSONRPC.Message.Inspector.kind(of: requestObject) {
        case .malformed(let invalidID):
            return immediate(
                .mcpError(
                    id: invalidID,
                    code: -32600,
                    message: "invalid request",
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                ),
                on: eventLoop
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

        let responseID = JSONRPC.Message.Inspector.requestID(from: requestObject)
        if sessionManager.isInitialized() == false {
            return immediate(
                Self.makeExpectedInitializeResolution(
                    requestID: responseID,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                ),
                on: eventLoop
            )
        }

        switch routeToolCall(
            object: requestObject,
            bodyData: bodyData,
            sessionID: sessionID,
            eventLoop: eventLoop,
            requestTimeoutOverride: requestTimeoutOverride
        ) {
        case .local(let responseData):
            return immediate(
                Self.makeLocalResponseResolution(
                    responseData: responseData,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream,
                    emptyStatus: .accepted
                ),
                on: eventLoop
            )

        case .localOperation(let operation):
            if let parentCancellationHandle,
                parentCancellationHandle.bindChildHandle(operation.cancellationHandle) == false
            {
                operation.cancellationHandle.cancel(using: sessionManager)
                return immediate(.empty(status: .accepted, sessionID: sessionID), on: eventLoop)
            }
            let future = operation.responseFuture.map { responseData in
                operation.cancellationHandle.markCompleted()
                self.sessionManager.completeRequestLease(operation.cancellationHandle.leaseID)
                return Self.makeLocalResponseResolution(
                    responseData: responseData,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream,
                    emptyStatus: .accepted
                )
            }
            return ClientMCPRequestExecutor.Operation(
                future: future,
                cancellationHandle: operation.cancellationHandle
            )

        case .forward(let request):
            return makeForwardingOperation(
                filteredRequest: request,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream,
                eventLoop: eventLoop,
                requestTimeoutOverride: requestTimeoutOverride,
                parentCancellationHandle: parentCancellationHandle
            )
        }
    }

    func makeForwardingOperation(
        filteredRequest: FilteredToolCallRequest,
        sessionID: String,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount?,
        parentCancellationHandle: ClientMCPRequestExecutor.CancellationHandle?
    ) -> ClientMCPRequestExecutor.Operation {
        guard let forwardedBodyData = filteredRequest.bodyData else {
            return immediate(
                Self.makeLocalResponseResolution(
                    responseData: filteredRequest.localResponseData,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream,
                    emptyStatus: .accepted
                ),
                on: eventLoop
            )
        }
        guard let forwardedRequestJSON = try? JSONRPC.Wire.object(fromData: forwardedBodyData) else {
            return immediate(
                .mcpError(
                    id: nil,
                    code: -32600,
                    message: "invalid request",
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                ),
                on: eventLoop
            )
        }

        let descriptor = Self.topLevelRequestDescriptor(
            sessionID: sessionID,
            parsedRequestJSON: forwardedRequestJSON,
            responseID: filteredRequest.forwardedResponseID
        )
        let leaseID = sessionManager.createRequestLease(descriptor: descriptor)
        let cancellationHandle = ClientMCPRequestExecutor.CancellationHandle(
            leaseID: leaseID,
            sessionID: sessionID,
            requestIDKeys: filteredRequest.forwardedResponseID.map { [$0.key] } ?? []
        )
        if let parentCancellationHandle,
            parentCancellationHandle.bindChildHandle(cancellationHandle) == false
        {
            cancellationHandle.cancel(using: sessionManager)
            return immediate(.empty(status: .accepted, sessionID: sessionID), on: eventLoop)
        }

        let forwardingDeadline = timeoutDeadline(
            for: requestTimeoutOverride
                ?? Self.topLevelRequestTimeoutOverride(
                    method: nil,
                    defaultSeconds: requestTimeoutSeconds
                )
        )
        let session = sessionManager.session(id: sessionID)

        if refreshCodeIssuesRequest(from: forwardedRequestJSON) != nil,
            filteredRequest.forwardedResponseID != nil
        {
            sessionManager.activateRequestLease(
                leaseID,
                requestIDKey: filteredRequest.forwardedResponseID?.key,
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
                    prefersEventStream: prefersEventStream,
                    eventLoop: eventLoop,
                    session: session,
                    leaseID: leaseID,
                    operationLease: nil,
                    cancellationHandle: cancellationHandle,
                    requestTimeoutOverride: requestTimeoutOverride
                ),
                cancellationHandle: cancellationHandle
            )
        }

        @Sendable func forwardingTimeout() -> TimeAmount? {
            remainingRequestTimeout(until: forwardingDeadline)
        }
        @Sendable func timeoutResolution() -> EventLoopFuture<ClientMCPRequestExecutor.Resolution> {
            cancellationHandle.markCompleted()
            self.sessionManager.failRequestLease(
                leaseID,
                terminalState: .timedOut,
                reason: .timedOut
            )
            return eventLoop.makeSucceededFuture(
                .mcpError(
                    id: filteredRequest.forwardedResponseID,
                    code: -32000,
                    message: "upstream timeout",
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }
        @Sendable func route(
            _ decision: ToolRoutingDecision
        ) -> EventLoopFuture<ClientMCPRequestExecutor.Resolution> {
            guard cancellationHandle.isCancelled == false else {
                return eventLoop.makeSucceededFuture(.empty(status: .accepted, sessionID: sessionID))
            }
            func forward(
                preferredUpstreamIndices: [Int]?,
                admission: RouteForwardingAdmission? = nil
            ) -> EventLoopFuture<ClientMCPRequestExecutor.Resolution> {
                let remainingTimeout = forwardingTimeout()
                if forwardingDeadline != nil, remainingTimeout == nil {
                    return timeoutResolution()
                }
                return self.sessionManager.enqueueOnUpstreamSlot(
                    leaseID: leaseID,
                    descriptor: descriptor,
                    on: eventLoop,
                    preferredUpstreamIndices: preferredUpstreamIndices
                ) { operationLease in
                    guard cancellationHandle.activate(operationLease: operationLease) else {
                        return eventLoop.makeFailedFuture(CancellationError())
                    }
                    self.sessionManager.activateRequestLease(
                        leaseID,
                        requestIDKey: nil,
                        upstreamIndex: operationLease.upstreamIndex,
                        timeout: nil
                    )
                    return self.makeTopLevelRequestFuture(
                        filteredRequest: filteredRequest,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream,
                        eventLoop: eventLoop,
                        session: session,
                        leaseID: leaseID,
                        operationLease: operationLease,
                        cancellationHandle: cancellationHandle,
                        requestTimeoutOverride: remainingTimeout,
                        admission: admission
                    )
                }.flatMapError { error in
                    if error is CancellationError {
                        return eventLoop.makeFailedFuture(error)
                    }
                    cancellationHandle.markCompleted()
                    let releaseReason: LeaseManager.ReleaseReason
                    if error is UpstreamSlotScheduler.AcquisitionError {
                        releaseReason = .upstreamUnavailable
                    } else if case ProxyUpstreamRequestRuntime.Error.staleUpstreamTopology = error {
                        releaseReason = .upstreamUnavailable
                    } else {
                        releaseReason = .upstreamOverloaded
                    }
                    self.sessionManager.failRequestLease(
                        leaseID,
                        terminalState: .failed,
                        reason: releaseReason
                    )
                    return eventLoop.makeSucceededFuture(
                        Self.makeUpstreamUnavailableResolution(
                            responseID: filteredRequest.forwardedResponseID,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                }
            }

            switch decision {
            case .reject(let errors):
                cancellationHandle.markCompleted()
                self.sessionManager.completeRequestLease(leaseID)
                return eventLoop.makeSucceededFuture(
                    Self.makeLocalResponseResolution(
                        responseData: Self.makeToolRoutingErrorResponseData(errors: errors),
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream,
                        emptyStatus: .accepted
                    )
                )
            case .localXcodeListWindows:
                guard let responseID = filteredRequest.forwardedResponseID else {
                    cancellationHandle.markCompleted()
                    self.sessionManager.completeRequestLease(leaseID)
                    return eventLoop.makeSucceededFuture(
                        .empty(status: .accepted, sessionID: sessionID)
                    )
                }
                let remainingTimeout = forwardingTimeout()
                if forwardingDeadline != nil, remainingTimeout == nil {
                    return timeoutResolution()
                }
                let promise = eventLoop.makePromise(of: ClientMCPRequestExecutor.Resolution.self)
                let task = Task { [self] in
                    let responseData: Data?
                    do {
                        let result = try await sessionManager.liveXcodeListWindowsResult(
                            route: .anyHealthy,
                            requestTimeoutOverride: remainingTimeout
                        )
                        responseData = Self.makeJSONRPCResultResponseData(id: responseID, result: result)
                    } catch {
                        let mapped = ControlPlane.ErrorMapper.jsonRPCError(for: error)
                        responseData = Self.makeJSONRPCErrorResponseData(
                            id: responseID,
                            code: mapped.code,
                            message: mapped.message
                        )
                    }
                    eventLoopCompletionExecutor.execute(on: eventLoop) {
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
                return forward(preferredUpstreamIndices: preferredUpstreamIndex.map { [$0] })
            case .forwardAny(let preferredUpstreamIndices):
                return forward(
                    preferredUpstreamIndices: preferredUpstreamIndices
                )
            case .forwardAdmitted(let preferredUpstreamIndices, let admission):
                return forward(
                    preferredUpstreamIndices: preferredUpstreamIndices,
                    admission: admission
                )
            }
        }

        if let immediateDecision = sessionManager.immediateToolRoutingDecision(
            for: forwardedRequestJSON
        ) {
            return ClientMCPRequestExecutor.Operation(
                future: route(immediateDecision),
                cancellationHandle: cancellationHandle
            )
        }

        let promise = eventLoop.makePromise(of: ClientMCPRequestExecutor.Resolution.self)
        let task = Task { [self] in
            let remainingTimeout = forwardingTimeout()
            if forwardingDeadline != nil, remainingTimeout == nil {
                eventLoopCompletionExecutor.execute(on: eventLoop) {
                    timeoutResolution().cascade(to: promise)
                }
                return
            }
            let decision = await sessionManager.toolRoutingDecision(
                for: forwardedRequestJSON,
                requestTimeoutOverride: remainingTimeout
            )
            eventLoopCompletionExecutor.execute(on: eventLoop) {
                route(decision).cascade(to: promise)
            }
        }
        cancellationHandle.bindRefreshTask(task)
        return ClientMCPRequestExecutor.Operation(
            future: promise.futureResult,
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
            return immediate(
                .plain(
                    status: .badRequest,
                    body: "invalid json-rpc response",
                    sessionID: sessionID
                ),
                on: eventLoop
            )
        }
        let future = sessionManager.forwardServerRequestResponse(
            responseData: responseData,
            sessionID: sessionID,
            responseID: responseID,
            on: eventLoop
        ).map { result -> ClientMCPRequestExecutor.Resolution in
            switch result {
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
        return ClientMCPRequestExecutor.Operation(future: future, cancellationHandle: nil)
    }

    private func immediate(
        _ resolution: ClientMCPRequestExecutor.Resolution,
        on eventLoop: EventLoop
    ) -> ClientMCPRequestExecutor.Operation {
        ClientMCPRequestExecutor.Operation(
            future: eventLoop.makeSucceededFuture(resolution),
            cancellationHandle: nil
        )
    }
}
