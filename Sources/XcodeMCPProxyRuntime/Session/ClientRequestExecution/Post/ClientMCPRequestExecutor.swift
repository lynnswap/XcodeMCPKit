import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import XcodeMCPCore

final class ClientMCPRequestExecutor: Sendable {
    struct FilteredToolCallRequest: Sendable {
        let bodyData: Data?
        let localResponseData: Data?
        let forwardedResponseID: JSONRPC.ID?
    }

    private struct RequestKey: Hashable {
        let sessionID: String
        let id: String
    }

    private let activeCancellations = NIOLockedValueBox<[RequestKey: CancellationHandle]>([:])

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

        let methodTimeout = Self.topLevelRequestTimeoutOverride(
            method: JSONRPC.Message.Inspector.method(from: requestObject),
            defaultSeconds: requestTimeoutSeconds
        )
        let requestDeadline = timeoutDeadline(
            for: Self.minimumRequestTimeout(requestTimeoutOverride, methodTimeout)
        )
        let admittedHandle: CancellationHandle?
        let requestKey: RequestKey?
        if parentCancellationHandle == nil,
           let sessionID = headerSessionID, !sessionID.isEmpty,
           case .request(let method, let id) = JSONRPC.Message.Inspector.kind(of: requestObject),
           method != "initialize" {
            let leaseID = sessionManager.createRequestLease(descriptor: Self.topLevelRequestDescriptor(
                sessionID: sessionID, parsedRequestJSON: requestObject, responseID: id
            ))
            let handle = CancellationHandle(leaseID: leaseID, sessionID: sessionID, requestIDKeys: [id.key])
            let key = RequestKey(sessionID: sessionID, id: id.key)
            activeCancellations.withLockedValue { $0[key] = handle }
            admittedHandle = handle
            requestKey = key
        } else {
            admittedHandle = nil
            requestKey = nil
        }
        let operation = makeOperation(
            requestObject: requestObject,
            bodyData: bodyData,
            headerSessionID: headerSessionID,
            headerSessionExists: headerSessionExists,
            prefersEventStream: prefersEventStream,
            eventLoop: eventLoop,
            requestTimeoutOverride: requestTimeoutOverride,
            parentCancellationHandle: parentCancellationHandle,
            admittedHandle: admittedHandle,
            requestDeadline: requestDeadline
        )
        guard let handle = admittedHandle, let key = requestKey else { return operation }
        let sessionID = key.sessionID
        let responseID = JSONRPC.Message.Inspector.requestID(from: requestObject)
        let timeoutResolution = Resolution.mcpError(
            id: responseID, code: -32000, message: "upstream timeout",
            sessionID: sessionID, prefersEventStream: prefersEventStream
        )
        let promise = eventLoop.makePromise(of: Resolution.self)
        let timeoutTask = requestDeadline.map { deadline in
            eventLoop.scheduleTask(in: remainingRequestTimeout(until: deadline) ?? .nanoseconds(0)) {
                if handle.timeOut(using: self.sessionManager) {
                    promise.succeed(timeoutResolution)
                }
            }
        }
        operation.future.map { resolution in
            if handle.wasTimedOut { return timeoutResolution }
            return handle.wasCancelled ? .empty(status: .accepted, sessionID: sessionID) : resolution
        }.flatMapError { error in
            if handle.wasTimedOut { return eventLoop.makeSucceededFuture(timeoutResolution) }
            if handle.wasCancelled {
                return eventLoop.makeSucceededFuture(.empty(status: .accepted, sessionID: sessionID))
            }
            return eventLoop.makeFailedFuture(error)
        }.cascade(to: promise)
        let future = promise.futureResult
        let registrations = activeCancellations
        let finishesAtAdmission = operation.cancellationHandle == nil
        future.whenComplete { _ in
            timeoutTask?.cancel()
            handle.markCompleted()
            if finishesAtAdmission, !handle.wasInterrupted {
                self.sessionManager.completeRequestLease(handle.leaseID)
            }
            registrations.withLockedValue { registrations in
                if registrations[key] === handle { registrations.removeValue(forKey: key) }
            }
        }
        return Operation(future: future, cancellationHandle: handle)
    }

    func cancelRequests(in sessionID: String? = nil) {
        let handles = activeCancellations.withLockedValue { registrations in
            let selected = registrations.filter { sessionID == nil || $0.key.sessionID == sessionID }
            for key in selected.keys { registrations.removeValue(forKey: key) }
            return Array(selected.values)
        }
        for handle in handles { handle.cancel(using: sessionManager) }
    }

    private func makeOperation(
        requestObject: [String: Any],
        bodyData: Data,
        headerSessionID: String?,
        headerSessionExists: Bool,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount?,
        parentCancellationHandle: CancellationHandle?,
        admittedHandle: CancellationHandle?,
        requestDeadline: Date?
    ) -> Operation {
        if let localHandling = localResponder.handle(
            object: requestObject,
            headerSessionID: headerSessionID,
            headerSessionExists: headerSessionExists,
            eventLoop: eventLoop,
            requestTimeoutOverride: requestTimeoutOverride
        ) {
            let future = resolveLocalHandling(
                localHandling,
                prefersEventStream: prefersEventStream,
                eventLoop: eventLoop
            )
            var handle: CancellationHandle?
            if case .pendingResponse(_, let sessionID, _, let id, let task?) = localHandling {
                let localHandle = admittedHandle ?? CancellationHandle(
                    leaseID: sessionManager.createRequestLease(descriptor: Self.topLevelRequestDescriptor(
                        sessionID: sessionID, parsedRequestJSON: requestObject, responseID: id
                    )),
                    sessionID: sessionID, requestIDKeys: [id.key]
                )
                localHandle.bindRefreshTask(task)
                if let parentCancellationHandle,
                   !parentCancellationHandle.bindChildHandle(localHandle) {
                    localHandle.cancel(using: sessionManager)
                }
                future.whenComplete { _ in
                    localHandle.markCompleted()
                    if !localHandle.wasInterrupted {
                        self.sessionManager.completeRequestLease(localHandle.leaseID)
                    }
                }
                handle = localHandle
            }
            return Operation(future: future, cancellationHandle: handle)
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

        if case .notification("notifications/cancelled") = JSONRPC.Message.Inspector.kind(of: requestObject) {
            if let params = requestObject["params"] as? [String: Any],
               let rawID = params["requestId"],
               let value = JSONValue(any: rawID) {
                let id: JSONRPC.ID?
                switch value {
                case .string, .number: id = JSONRPC.ID(any: rawID)
                case .array, .object, .bool, .null: id = nil
                }
                if let id,
                   let handle = activeCancellations.withLockedValue({
                       $0[RequestKey(sessionID: sessionID, id: id.key)]
                   }) {
                    cancel(handle, source: .clientNotification)
                }
            }
            return immediate(.empty(status: .accepted, sessionID: sessionID), on: eventLoop)
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
        switch routeToolCall(
            object: requestObject,
            bodyData: bodyData,
            sessionID: sessionID,
            eventLoop: eventLoop,
            requestTimeoutOverride: requestTimeoutOverride,
            admittedHandle: admittedHandle,
            requestDeadline: requestDeadline
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
                parentCancellationHandle: parentCancellationHandle,
                admittedHandle: admittedHandle,
                requestDeadline: requestDeadline
            )
        }
    }

    func makeForwardingOperation(
        filteredRequest: FilteredToolCallRequest,
        sessionID: String,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount?,
        parentCancellationHandle: ClientMCPRequestExecutor.CancellationHandle?,
        admittedHandle: CancellationHandle? = nil,
        requestDeadline: Date?
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
        let cancellationHandle = admittedHandle ?? ClientMCPRequestExecutor.CancellationHandle(
            leaseID: sessionManager.createRequestLease(descriptor: descriptor),
            sessionID: sessionID,
            requestIDKeys: filteredRequest.forwardedResponseID.map { [$0.key] } ?? []
        )
        let leaseID = cancellationHandle.leaseID
        if let parentCancellationHandle,
            parentCancellationHandle.bindChildHandle(cancellationHandle) == false
        {
            cancellationHandle.cancel(using: sessionManager)
            return immediate(.empty(status: .accepted, sessionID: sessionID), on: eventLoop)
        }

        let forwardingDeadline = requestDeadline
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
                    ),
                progressTokenMapping: nil
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
            guard cancellationHandle.isTerminal == false else {
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
                    let remainingTimeout = forwardingTimeout()
                    if forwardingDeadline != nil, remainingTimeout == nil {
                        return timeoutResolution()
                    }
                    guard cancellationHandle.activate(operationLease: operationLease) else {
                        return eventLoop.makeFailedFuture(CancellationError())
                    }
                    self.sessionManager.activateRequestLease(
                        leaseID,
                        requestIDKey: nil,
                        upstreamIndex: operationLease.upstreamIndex,
                        timeout: nil,
                        progressTokenMapping: nil
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
