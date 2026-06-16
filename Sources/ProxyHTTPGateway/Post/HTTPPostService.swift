import Foundation
import Logging
import NIO
import ProxyCore
import ProxyMCP
import ProxyXcodeFeatures
import ProxyXcodeSupport
import ProxySession

package final class HTTPPostService: Sendable {
    package struct FilteredToolCallRequest: Sendable {
        let bodyData: Data?
        let localResponseData: Data?
        let forwardedResponseIDs: [RPCID]
        let forceBatchArray: Bool
    }

    package struct LocalToolBatchResult: Sendable {
        let responseData: Data?
        let fallbackForwardedRequest: FilteredToolCallRequest?
    }

    private struct LocalToolFallbackForwardingResult {
        let request: FilteredToolCallRequest
        let resolution: HTTPPostResolution
    }

    package struct LocalToolFilterOperation {
        let localResponseFuture: EventLoopFuture<LocalToolBatchResult>
        let forwardedRequest: FilteredToolCallRequest
        let cancellationHandle: HTTPPostCancellationHandle
        let deadline: Date?
    }

    package let sessionManager: any RuntimeCoordinating
    package let disabledToolNames: Set<String>
    package let usesSynchronousLocalResolution: Bool
    package let localResponder: LocalMCPResponder
    package let forwardingService: MCPForwardingService
    package let refreshWorkflow: RefreshCodeIssuesWorkflow
    package let requestTimeoutSeconds: TimeInterval
    package let logger: Logger

    package init(
        config: ProxyConfig,
        sessionManager: any RuntimeCoordinating,
        refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator,
        refreshCodeIssuesTargetResolver: RefreshCodeIssuesTargetResolver = RefreshCodeIssuesTargetResolver(),
        refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState,
        usesSynchronousLocalResolution: Bool = false,
        logger: Logger = ProxyLogging.make("http")
    ) {
        self.requestTimeoutSeconds = config.requestTimeout
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
        self.refreshWorkflow = RefreshCodeIssuesWorkflow(
            mode: config.refreshCodeIssuesMode,
            requestTimeout: config.requestTimeout,
            coordinator: refreshCodeIssuesCoordinator,
            targetResolver: refreshCodeIssuesTargetResolver,
            debugState: refreshCodeIssuesDebugState,
            logger: ProxyLogging.make("http.refresh")
        )
        self.logger = logger
    }

    package func handle(
        bodyData: Data,
        headerSessionID: String?,
        headerSessionExists: Bool,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount? = nil,
        parentCancellationHandle: HTTPPostCancellationHandle? = nil
    ) -> HTTPPostOperation {
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
            return HTTPPostOperation(
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
            return HTTPPostOperation(
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
            return HTTPPostOperation(
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

        if let responseObject = parsedRequestJSON as? [String: Any],
            let responseID = JSONRPCMessageInspector.responseID(from: responseObject)
        {
            return makeClientResponseForwardingOperation(
                responseObject: responseObject,
                sessionID: sessionID,
                responseID: responseID,
                eventLoop: eventLoop
            )
        }

        if sessionManager.isInitialized() == false {
            return HTTPPostOperation(
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
            return HTTPPostOperation(
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
            return HTTPPostOperation(
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
            return HTTPPostOperation(
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
                return HTTPPostOperation(
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
            return HTTPPostOperation(
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
        cancellationHandle: HTTPPostCancellationHandle
    ) -> EventLoopFuture<HTTPPostResolution> {
        let forwardingTimeout = Self.remainingRequestTimeout(until: deadline)
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

    package func makeForwardingOperation(
        filteredRequest: FilteredToolCallRequest,
        sessionID: String,
        headerSessionID: String?,
        requestIsBatch: Bool,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount?,
        parentCancellationHandle: HTTPPostCancellationHandle?
    ) -> HTTPPostOperation {
        guard let forwardedBodyData = filteredRequest.bodyData else {
            return HTTPPostOperation(
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
            return HTTPPostOperation(
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

        let forwardedRequestIDs = filteredRequest.forwardedResponseIDs
        let localResponseData = filteredRequest.localResponseData
        let descriptor = Self.topLevelRequestDescriptor(
            sessionID: sessionID,
            parsedRequestJSON: forwardedRequestJSON,
            requestIsBatch: requestIsBatch,
            requestIDs: forwardedRequestIDs
        )
        let leaseID = sessionManager.createRequestLease(descriptor: descriptor)
        let cancellationHandle = HTTPPostCancellationHandle(
            leaseID: leaseID,
            sessionID: sessionID,
            requestIDKeys: forwardedRequestIDs.map(\.key)
        )
        if let parentCancellationHandle,
            parentCancellationHandle.bindChildHandle(cancellationHandle) == false
        {
            cancellationHandle.cancel(using: sessionManager)
            return HTTPPostOperation(
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
            return HTTPPostOperation(
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
        let future = sessionManager.enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop,
            preferredUpstreamIndex: nil
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
                requestTimeoutOverride: requestTimeoutOverride
            )
        }.flatMapError { error in
            if error is CancellationError {
                return eventLoop.makeFailedFuture(error)
            }
            cancellationHandle.markCompleted()
            self.sessionManager.failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .upstreamOverloaded
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
        return HTTPPostOperation(
            future: future,
            cancellationHandle: cancellationHandle
        )
    }

    private func makeClientResponseForwardingOperation(
        responseObject: [String: Any],
        sessionID: String,
        responseID: RPCID,
        eventLoop: EventLoop
    ) -> HTTPPostOperation {
        let session = sessionManager.session(id: sessionID)
        if let route = session.serverRequestTracker.consume(clientID: responseID) {
            guard let upstreamData = Self.rewriteClientResponse(
                responseObject,
                id: route.upstreamID
            ) else {
                return HTTPPostOperation(
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
            sessionManager.sendUpstream(
                upstreamData,
                upstreamIndex: route.upstreamIndex,
                ensureRunning: false
            )
        } else {
            logger.debug(
                "Acknowledging client JSON-RPC response without a routed upstream request",
                metadata: [
                    "session": .string(sessionID),
                    "id": .string(responseID.key),
                ]
            )
        }
        return HTTPPostOperation(
            future: eventLoop.makeSucceededFuture(
                .empty(status: .accepted, sessionID: sessionID)
            ),
            cancellationHandle: nil
        )
    }

    private static func rewriteClientResponse(
        _ responseObject: [String: Any],
        id: RPCID
    ) -> Data? {
        var rewritten = responseObject
        rewritten["id"] = id.value.foundationObject
        guard JSONSerialization.isValidJSONObject(rewritten) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: rewritten, options: [])
    }
}
