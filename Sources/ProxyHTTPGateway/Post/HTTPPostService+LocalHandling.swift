import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOHTTP1
import ProxyCore
import ProxyMCP
import ProxyXcodeFeatures
import ProxyXcodeSupport
import ProxySession
import ProxySessionControlPlane

extension HTTPPostService {
    package func resolveLocalHandling(
        _ handling: LocalPostHandling,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        forceBatchArray: Bool
    ) -> EventLoopFuture<HTTPPostService.Resolution> {
        switch handling {
        case .pendingResponse(let future, let sessionID, let errorSessionID, let originalID):
            return future.map { buffer in
                var buffer = buffer
                guard let data = buffer.readData(length: buffer.readableBytes) else {
                    return .plain(
                        status: .badGateway,
                        body: "invalid upstream response",
                        sessionID: sessionID
                    )
                }
                let responseData = forceBatchArray
                    ? Self.forceBatchArrayResponseDataIfNeeded(data)
                    : data
                let responseSessionID = Self.isJSONRPCErrorResponse(data)
                    ? errorSessionID
                    : sessionID
                return .responseData(
                    data: responseData,
                    sessionID: responseSessionID,
                    prefersEventStream: prefersEventStream
                )
            }.flatMapError { _ in
                eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: originalID,
                        ids: [],
                        code: -32000,
                        message: "upstream timeout",
                        forceBatchArray: forceBatchArray,
                        sessionID: errorSessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }

        case .immediateResponse(let data, let sessionID):
            let responseData = forceBatchArray
                ? Self.forceBatchArrayResponseDataIfNeeded(data)
                : data
            return eventLoop.makeSucceededFuture(
                .responseData(
                    data: responseData,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )

        case .mcpError(let id, let code, let message, let sessionID):
            return eventLoop.makeSucceededFuture(
                .mcpError(
                    id: id,
                    ids: [],
                    code: code,
                    message: message,
                    forceBatchArray: forceBatchArray,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }
    }

    package static func localHandlingRequest(from parsedRequestJSON: Any?) -> (
        object: [String: Any], forceBatchArray: Bool
    )? {
        if let object = parsedRequestJSON as? [String: Any] {
            return (object, false)
        }
        guard let array = parsedRequestJSON as? [Any],
            array.count == 1,
            let object = array.first as? [String: Any]
        else {
            return nil
        }
        return (object, true)
    }

    package static func forceBatchArrayResponseDataIfNeeded(_ data: Data) -> Data {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return data
        }
        guard payload is [Any] == false,
            JSONSerialization.isValidJSONObject([payload])
        else {
            return data
        }
        return (try? JSONSerialization.data(withJSONObject: [payload], options: [])) ?? data
    }

    private static func isJSONRPCErrorResponse(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [])
                as? [String: Any],
            object["error"] != nil
        else {
            return false
        }
        return JSONRPC.Message.Inspector.responseID(from: object) != nil
    }

    package struct ToolCallRouting {
        /// The remainder to forward. When no local tool routes exist this
        /// also carries the blocked-tool responses as localResponseData.
        let forwardedRequest: FilteredToolCallRequest
        let localOperation: LocalToolFilterOperation?
    }

    /// The single classification pass over an incoming POST body: disabled
    /// tools are answered locally, tools/list and DocumentationSearch items
    /// run on the local path (with the remainder forwarded in parallel), and
    /// everything else forwards. The body is parsed here, not handed in, so
    /// the derived groups form a disconnected region that can transfer into
    /// the local-execution task under strict concurrency.
    package func routeToolCalls(
        bodyData: Data,
        sessionID: String,
        forceBatchArray: Bool,
        eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount?
    ) throws -> ToolCallRouting {
        let parsedRequestJSON = try JSONSerialization.jsonObject(with: bodyData, options: [])

        let items: [Any]
        if let object = parsedRequestJSON as? [String: Any] {
            items = [object]
        } else if let array = parsedRequestJSON as? [Any] {
            items = array
        } else {
            items = []
        }
        guard items.isEmpty == false else {
            return ToolCallRouting(
                forwardedRequest: FilteredToolCallRequest(
                    bodyData: bodyData,
                    localResponseData: nil,
                    forwardedResponseIDs: [],
                    forceBatchArray: forceBatchArray
                ),
                localOperation: nil
            )
        }

        let allowLocalToolRoutes = !usesSynchronousLocalResolution
        var didBlockItem = false
        var blockedResponseObjects: [[String: Any]] = []
        var toolsListRequests: [[String: Any]] = []
        var documentationRequests: [[String: Any]] = []
        var forwardedObjects: [Any] = []
        var routedObjects: [Any] = []

        for item in items {
            guard let object = item as? [String: Any] else {
                forwardedObjects.append(item)
                routedObjects.append(item)
                continue
            }
            if let toolName = blockedToolName(from: object) {
                didBlockItem = true
                blockedResponseObjects.append(
                    contentsOf: Self.makeBlockedToolResponseObjects(
                        requestObject: object,
                        toolName: toolName
                    )
                )
            } else if allowLocalToolRoutes, isToolsListRequest(object) {
                toolsListRequests.append(object)
                routedObjects.append(object)
            } else if allowLocalToolRoutes, isDocumentationSearchRequest(object) {
                documentationRequests.append(object)
                routedObjects.append(object)
            } else {
                forwardedObjects.append(item)
                routedObjects.append(item)
            }
        }

        let hasLocalToolRoutes =
            toolsListRequests.isEmpty == false
                || documentationRequests.isEmpty == false

        // Untouched requests forward with their original bytes. A blocked
        // notification produces no response object but must still be dropped.
        if didBlockItem == false, hasLocalToolRoutes == false {
            return ToolCallRouting(
                forwardedRequest: FilteredToolCallRequest(
                    bodyData: bodyData,
                    localResponseData: nil,
                    forwardedResponseIDs: Self.extractResponseIDs(from: parsedRequestJSON),
                    forceBatchArray: forceBatchArray
                ),
                localOperation: nil
            )
        }

        let blockedResponseData = Self.makeToolResponseData(
            from: blockedResponseObjects,
            forceBatchArray: forceBatchArray
        )
        let forwardRemainder = makeForwardedLocalToolRequest(
            forwardedObjects: forwardedObjects,
            forceBatchArray: forceBatchArray
        )

        guard hasLocalToolRoutes else {
            return ToolCallRouting(
                forwardedRequest: FilteredToolCallRequest(
                    bodyData: forwardRemainder.bodyData,
                    localResponseData: blockedResponseData,
                    forwardedResponseIDs: forwardRemainder.forwardedResponseIDs,
                    forceBatchArray: forceBatchArray
                ),
                localOperation: nil
            )
        }

        // One lease and cancellation scope covers every non-blocked item.
        let routedPayload: Any = (forceBatchArray || routedObjects.count > 1)
            ? routedObjects
            : routedObjects[0]
        let routedResponseIDs = Self.extractResponseIDs(from: routedPayload)
        let descriptor = Self.topLevelRequestDescriptor(
            sessionID: sessionID,
            parsedRequestJSON: routedPayload,
            requestIsBatch: forceBatchArray,
            requestIDs: routedResponseIDs
        )
        let leaseID = sessionManager.createRequestLease(descriptor: descriptor)
        let cancellationHandle = HTTPPostService.CancellationHandle(
            leaseID: leaseID,
            sessionID: sessionID,
            requestIDKeys: routedResponseIDs.map(\.key)
        )
        let deadline = Self.timeoutDeadline(
            for: requestTimeoutOverride
                ?? Self.topLevelRequestTimeoutOverride(
                    method: nil,
                    defaultSeconds: requestTimeoutSeconds
                )
        )
        let initialLocalResponseData = blockedResponseData
        let promise = eventLoop.makePromise(of: LocalToolBatchResult.self)
        let task = Task { [self] in
            guard !Task.isCancelled else {
                eventLoop.execute {
                    promise.fail(CancellationError())
                }
                return
            }
            let localBatchResult = await makeLocalToolBatchResult(
                initialLocalResponseData: initialLocalResponseData,
                toolsListRequests: toolsListRequests,
                documentationRequests: documentationRequests,
                sessionID: sessionID,
                forceBatchArray: forceBatchArray,
                deadline: deadline
            )
            let wasCancelled = Task.isCancelled
            eventLoop.execute {
                if wasCancelled {
                    promise.fail(CancellationError())
                    return
                }
                promise.succeed(localBatchResult)
            }
        }
        cancellationHandle.bindRefreshTask(task)
        return ToolCallRouting(
            forwardedRequest: forwardRemainder,
            localOperation: LocalToolFilterOperation(
                localResponseFuture: promise.futureResult,
                forwardedRequest: forwardRemainder,
                cancellationHandle: cancellationHandle,
                deadline: deadline
            )
        )
    }

    private func makeForwardedLocalToolRequest(
        forwardedObjects: [Any],
        forceBatchArray: Bool
    ) -> FilteredToolCallRequest {
        let forwardedPayload: Any?
        if forwardedObjects.isEmpty {
            forwardedPayload = nil
        } else if forceBatchArray || forwardedObjects.count > 1 {
            forwardedPayload = forwardedObjects
        } else {
            forwardedPayload = forwardedObjects[0]
        }
        let forwardedBodyData = forwardedPayload.flatMap {
            try? JSONSerialization.data(withJSONObject: $0, options: [])
        }
        let forwardedResponseIDs = forwardedPayload.map {
            Self.extractResponseIDs(from: $0)
        } ?? []

        return FilteredToolCallRequest(
            bodyData: forwardedBodyData,
            localResponseData: nil,
            forwardedResponseIDs: forwardedResponseIDs,
            forceBatchArray: forceBatchArray
        )
    }

    private func makeLocalToolBatchResult(
        initialLocalResponseData: Data?,
        toolsListRequests: [[String: Any]],
        documentationRequests: [[String: Any]],
        sessionID: String,
        forceBatchArray: Bool,
        deadline: Date?
    ) async -> LocalToolBatchResult {
        let toolsListResponseData = await makeToolsListBatchResponseData(
            requests: toolsListRequests,
            sessionID: sessionID,
            deadline: deadline
        )
        let documentationResult = await makeDocumentationSearchBatchResult(
            requests: documentationRequests,
            deadline: deadline
        )
        let localResponseData = Self.mergeBatchResponsePayloads(
            [
                initialLocalResponseData,
                toolsListResponseData,
                documentationResult.responseData,
            ],
            forceBatchArray: true
        )
        let fallbackForwardedRequest = documentationResult.fallbackRequests.isEmpty
            ? nil
            : makeForwardedLocalToolRequest(
                forwardedObjects: documentationResult.fallbackRequests,
                forceBatchArray: forceBatchArray
            )
        return LocalToolBatchResult(
            responseData: localResponseData,
            fallbackForwardedRequest: fallbackForwardedRequest
        )
    }

    private func makeToolsListBatchResponseData(
        requests: [[String: Any]],
        sessionID: String,
        deadline: Date?
    ) async -> Data? {
        var responseObjects: [[String: Any]] = []
        responseObjects.reserveCapacity(requests.count)

        for request in requests {
            guard !Task.isCancelled else {
                break
            }
            guard let originalID = JSONRPC.Message.Inspector.requestID(from: request) else {
                continue
            }
            let requestTimeout = Self.remainingRequestTimeout(until: deadline)
            if deadline != nil,
                requestTimeout == nil
            {
                responseObjects.append(
                    Self.makeJSONRPCErrorResponseObject(
                        id: originalID,
                        code: -32000,
                        message: "upstream timeout"
                    )
                )
                continue
            }
            do {
                let responseData = try await localResponder.toolsListResponseData(
                    object: request,
                    sessionID: sessionID,
                    requestTimeoutOverride: requestTimeout
                )
                responseObjects.append(
                    contentsOf: Self.responseObjects(from: responseData)
                )
            } catch {
                let mapped = ControlPlane.ErrorMapper.jsonRPCError(for: error)
                if let responseData = Self.responseDataForBatchResolution(
                    .mcpError(
                        id: originalID,
                        ids: [originalID],
                        code: mapped.code,
                        message: mapped.message,
                        forceBatchArray: false,
                        sessionID: sessionID,
                        prefersEventStream: false
                    ),
                    fallbackRequestIDs: [originalID],
                    forceBatchArray: false
                ) {
                    responseObjects.append(
                        contentsOf: Self.responseObjects(from: responseData)
                    )
                }
            }
        }

        return Self.makeToolResponseData(
            from: responseObjects,
            forceBatchArray: true
        )
    }

    private func makeDocumentationSearchBatchResult(
        requests: [[String: Any]],
        deadline: Date?
    ) async -> (responseData: Data?, fallbackRequests: [[String: Any]]) {
        var responseObjects: [[String: Any]] = []
        responseObjects.reserveCapacity(requests.count)
        var fallbackRequests: [[String: Any]] = []
        fallbackRequests.reserveCapacity(requests.count)
        let normalizer = ToolCallNormalizer(sessionManager: sessionManager)

        for request in requests {
            guard !Task.isCancelled else {
                break
            }
            guard let originalID = JSONRPC.Message.Inspector.requestID(from: request) else {
                continue
            }
            guard JSONSerialization.isValidJSONObject(request),
                  let requestData = try? JSONSerialization.data(withJSONObject: request, options: []) else {
                responseObjects.append(
                    Self.makeJSONRPCErrorResponseObject(
                        id: originalID,
                        code: -32600,
                        message: "invalid request"
                    )
                )
                continue
            }
            let requestTimeout = Self.remainingRequestTimeout(until: deadline)
            if deadline != nil,
                requestTimeout == nil
            {
                responseObjects.append(
                    Self.makeJSONRPCErrorResponseObject(
                        id: originalID,
                        code: -32000,
                        message: "upstream timeout"
                    )
                )
                continue
            }
            do {
                switch try await sessionManager.callDocumentationSearch(
                    requestData: requestData,
                    requestTimeoutOverride: requestTimeout
                ) {
                case .handled(let responseData):
                    let normalizedData = normalizer.normalizeResponseDataIfNeeded(
                        method: "tools/call",
                        toolName: DocumentationProvider.ToolCatalog.toolName,
                        upstreamData: responseData
                    )
                    responseObjects.append(
                        contentsOf: Self.responseObjects(from: normalizedData)
                    )
                case .unavailable(let reason):
                    responseObjects.append(
                        Self.makeJSONRPCErrorResponseObject(
                            id: originalID,
                            code: -32001,
                            message: reason.message
                        )
                    )
                }
            } catch {
                let mapped = ControlPlane.ErrorMapper.jsonRPCError(for: error)
                responseObjects.append(
                    Self.makeJSONRPCErrorResponseObject(
                        id: originalID,
                        code: mapped.code,
                        message: mapped.message
                    )
                )
            }
        }

        return (
            Self.makeToolResponseData(
                from: responseObjects,
                forceBatchArray: true
            ),
            fallbackRequests
        )
    }

    private func isDocumentationSearchRequest(_ object: [String: Any]) -> Bool {
        guard sessionManager.hasDocumentationSearchService() else {
            return false
        }
        guard case .request("tools/call", _) = JSONRPC.Message.Inspector.kind(of: object),
            let params = object["params"] as? [String: Any],
            params["name"] as? String == DocumentationProvider.ToolCatalog.toolName,
            disabledToolNames.contains(DocumentationProvider.ToolCatalog.toolName) == false else {
            return false
        }
        return true
    }

    private func isToolsListRequest(_ object: [String: Any]) -> Bool {
        JSONRPC.Message.Inspector.requestID(from: object) != nil
            && JSONRPC.Message.Inspector.method(from: object) == "tools/list"
            && sessionManager.isInitialized()
    }

    package func blockedToolName(from requestObject: [String: Any]) -> String? {
        guard let method = requestObject["method"] as? String,
            method == "tools/call",
            let params = requestObject["params"] as? [String: Any],
            let toolName = params["name"] as? String,
            disabledToolNames.contains(toolName)
        else {
            return nil
        }
        return toolName
    }

    package func refreshCodeIssuesRequest(from requestJSON: Any) -> RefreshCodeIssues.Request? {
        guard let object = RefreshCodeIssues.Request.singleRequestObject(from: requestJSON) else {
            return nil
        }
        return RefreshCodeIssues.Request(requestObject: object)
    }

    package func refreshRequestRouting(from requestJSON: Any) -> HTTPPostService.RefreshRouting? {
        if let object = requestJSON as? [String: Any],
            let refreshRequest = RefreshCodeIssues.Request(requestObject: object),
            Self.extractResponseIDs(from: object).isEmpty == false,
            let bodyData = try? JSONSerialization.data(withJSONObject: object, options: [])
        {
            return HTTPPostService.RefreshRouting(
                refreshRoutes: [
                    HTTPPostService.RefreshRoute(
                        request: refreshRequest,
                        bodyData: bodyData,
                        requestIDs: Self.extractResponseIDs(from: object),
                        requestIsBatch: false
                    )
                ],
                remainingBodyData: nil,
                remainingRequestIDs: [],
                remainingLocalResponseData: nil
            )
        }

        guard let requests = requestJSON as? [Any] else {
            return nil
        }
        var refreshRoutes: [HTTPPostService.RefreshRoute] = []
        var remainingRequestObjects: [[String: Any]] = []
        var remainingInvalidResponseObjects: [[String: Any]] = []
        for item in requests {
            guard let object = item as? [String: Any] else {
                remainingInvalidResponseObjects.append(
                    Self.makeJSONRPCErrorResponseObject(
                        id: NSNull(),
                        code: -32600,
                        message: "invalid request"
                    )
                )
                continue
            }
            guard let candidate = RefreshCodeIssues.Request(requestObject: object) else {
                remainingRequestObjects.append(object)
                continue
            }
            let responseIDs = Self.extractResponseIDs(from: object)
            guard responseIDs.isEmpty == false else {
                remainingRequestObjects.append(object)
                continue
            }
            let payload: Any = requests.count == 1 ? requests : object
            guard let bodyData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                return nil
            }
            refreshRoutes.append(
                HTTPPostService.RefreshRoute(
                    request: candidate,
                    bodyData: bodyData,
                    requestIDs: responseIDs,
                    requestIsBatch: requests.count == 1
                )
            )
        }
        guard !refreshRoutes.isEmpty else {
            return nil
        }

        let shouldKeepRemainingPayloadAsBatch = remainingInvalidResponseObjects.isEmpty == false
        let remainingPayload: Any? = {
            guard !remainingRequestObjects.isEmpty else { return nil }
            if remainingRequestObjects.count == 1,
                shouldKeepRemainingPayloadAsBatch == false
            {
                return remainingRequestObjects[0]
            }
            return remainingRequestObjects
        }()
        let remainingBodyData = remainingPayload.flatMap {
            try? JSONSerialization.data(withJSONObject: $0, options: [])
        }
        let remainingLocalResponseData = Self.makeToolResponseData(
            from: remainingInvalidResponseObjects,
            forceBatchArray: remainingInvalidResponseObjects.count > 1
        )
        return HTTPPostService.RefreshRouting(
            refreshRoutes: refreshRoutes,
            remainingBodyData: remainingBodyData,
            remainingRequestIDs: Self.extractResponseIDs(from: remainingPayload as Any),
            remainingLocalResponseData: remainingLocalResponseData
        )
    }

}
