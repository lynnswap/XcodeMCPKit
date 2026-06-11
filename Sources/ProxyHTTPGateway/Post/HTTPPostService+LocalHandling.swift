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

extension HTTPPostService {
    package func resolveLocalHandling(
        _ handling: LocalPostHandling,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        forceBatchArray: Bool
    ) -> EventLoopFuture<HTTPPostResolution> {
        switch handling {
        case .pendingResponse(let future, let sessionID, let originalID):
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
                return .responseData(
                    data: responseData,
                    sessionID: sessionID,
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
                        sessionID: sessionID,
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

    package func filterDisabledToolCalls(
        bodyData: Data,
        parsedRequestJSON: Any,
        forceBatchArray: Bool
    ) throws -> FilteredToolCallRequest {
        guard disabledToolNames.isEmpty == false else {
            return FilteredToolCallRequest(
                bodyData: bodyData,
                localResponseData: nil,
                forwardedResponseIDs: Self.extractResponseIDs(from: parsedRequestJSON),
                forceBatchArray: forceBatchArray
            )
        }

        if let object = parsedRequestJSON as? [String: Any] {
            guard let toolName = blockedToolName(from: object) else {
                return FilteredToolCallRequest(
                    bodyData: bodyData,
                    localResponseData: nil,
                    forwardedResponseIDs: Self.extractResponseIDs(from: parsedRequestJSON),
                    forceBatchArray: forceBatchArray
                )
            }

            return FilteredToolCallRequest(
                bodyData: nil,
                localResponseData: Self.makeToolResponseData(
                    from: Self.makeBlockedToolResponseObjects(
                        requestObject: object,
                        toolName: toolName
                    ),
                    forceBatchArray: forceBatchArray
                ),
                forwardedResponseIDs: [],
                forceBatchArray: forceBatchArray
            )
        }

        guard let array = parsedRequestJSON as? [Any] else {
            return FilteredToolCallRequest(
                bodyData: bodyData,
                localResponseData: nil,
                forwardedResponseIDs: [],
                forceBatchArray: forceBatchArray
            )
        }

        var forwardedObjects: [Any] = []
        forwardedObjects.reserveCapacity(array.count)
        var localResponseObjects: [[String: Any]] = []
        localResponseObjects.reserveCapacity(array.count)

        for item in array {
            guard let object = item as? [String: Any],
                let toolName = blockedToolName(from: object)
            else {
                forwardedObjects.append(item)
                continue
            }
            localResponseObjects.append(
                contentsOf: Self.makeBlockedToolResponseObjects(
                    requestObject: object,
                    toolName: toolName
                )
            )
        }

        let localResponseData = Self.makeToolResponseData(
            from: localResponseObjects,
            forceBatchArray: forceBatchArray
        )

        guard forwardedObjects.isEmpty == false else {
            return FilteredToolCallRequest(
                bodyData: nil,
                localResponseData: localResponseData,
                forwardedResponseIDs: [],
                forceBatchArray: forceBatchArray
            )
        }

        if localResponseData == nil {
            let filteredPayload: Any = (forceBatchArray || forwardedObjects.count > 1)
                ? forwardedObjects
                : forwardedObjects[0]
            let filteredBodyData = try JSONSerialization.data(
                withJSONObject: filteredPayload,
                options: []
            )
            return FilteredToolCallRequest(
                bodyData: filteredBodyData,
                localResponseData: nil,
                forwardedResponseIDs: Self.extractResponseIDs(from: filteredPayload),
                forceBatchArray: forceBatchArray
            )
        }

        let filteredBodyData = try JSONSerialization.data(
            withJSONObject: forwardedObjects,
            options: []
        )
        return FilteredToolCallRequest(
            bodyData: filteredBodyData,
            localResponseData: localResponseData,
            forwardedResponseIDs: Self.extractResponseIDs(from: forwardedObjects),
            forceBatchArray: forceBatchArray
        )
    }

    package func filterLocalToolCalls(
        filteredRequest: FilteredToolCallRequest,
        sessionID: String,
        eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount?
    ) -> LocalToolFilterOperation? {
        guard let bodyData = filteredRequest.bodyData,
              let parsedRequestJSON = try? JSONSerialization.jsonObject(with: bodyData, options: [])
        else {
            return nil
        }
        guard !Self.shouldUseEmbeddedTestSynchronousResolution(on: eventLoop) else {
            return nil
        }

        let requestItems: [Any]
        if let object = parsedRequestJSON as? [String: Any] {
            requestItems = [object]
        } else if let array = parsedRequestJSON as? [Any] {
            requestItems = array
        } else {
            return nil
        }

        let hasLocalToolsListRequest = requestItems.contains { item in
            guard let object = item as? [String: Any] else {
                return false
            }
            return isToolsListRequest(object)
        }
        var toolsListRequests: [[String: Any]] = []
        toolsListRequests.reserveCapacity(requestItems.count)
        var documentationRequests: [[String: Any]] = []
        documentationRequests.reserveCapacity(requestItems.count)
        var deferredDocumentationRequests: [[String: Any]] = []
        deferredDocumentationRequests.reserveCapacity(requestItems.count)
        var forwardedObjects: [Any] = []
        forwardedObjects.reserveCapacity(requestItems.count)

        for item in requestItems {
            guard let object = item as? [String: Any] else {
                forwardedObjects.append(item)
                continue
            }
            if isToolsListRequest(object) {
                toolsListRequests.append(object)
            } else if isDocumentationSearchRequest(object) {
                documentationRequests.append(object)
            } else if hasLocalToolsListRequest,
                      isDocumentationSearchRequest(object, allowInactiveProvider: true) {
                deferredDocumentationRequests.append(object)
            } else {
                forwardedObjects.append(item)
            }
        }

        guard toolsListRequests.isEmpty == false || documentationRequests.isEmpty == false else {
            return nil
        }

        let requestIDs = Self.extractResponseIDs(from: parsedRequestJSON)
        let descriptor = Self.topLevelRequestDescriptor(
            sessionID: sessionID,
            parsedRequestJSON: parsedRequestJSON,
            requestIsBatch: filteredRequest.forceBatchArray,
            requestIDs: requestIDs
        )
        let leaseID = sessionManager.createRequestLease(descriptor: descriptor)
        let cancellationHandle = HTTPPostCancellationHandle(
            leaseID: leaseID,
            sessionID: sessionID,
            requestIDKeys: requestIDs.map(\.key)
        )
        let deadline = Self.timeoutDeadline(
            for: requestTimeoutOverride
                ?? Self.topLevelRequestTimeoutOverride(
                    method: nil,
                    defaultSeconds: requestTimeoutSeconds
                )
        )
        let forwardedRequest = makeForwardedLocalToolRequest(
            forwardedObjects: forwardedObjects,
            forceBatchArray: filteredRequest.forceBatchArray
        )
        let promise = eventLoop.makePromise(of: LocalToolBatchResult.self)
        let task = Task { [self] in
            guard !Task.isCancelled else {
                eventLoop.execute {
                    promise.fail(CancellationError())
                }
                return
            }
            let localBatchResult = await makeLocalToolBatchResult(
                initialLocalResponseData: filteredRequest.localResponseData,
                toolsListRequests: toolsListRequests,
                documentationRequests: documentationRequests,
                deferredDocumentationRequests: deferredDocumentationRequests,
                sessionID: sessionID,
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
        return LocalToolFilterOperation(
            localResponseFuture: promise.futureResult,
            forwardedRequest: forwardedRequest,
            cancellationHandle: cancellationHandle,
            deadline: deadline
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
        deferredDocumentationRequests: [[String: Any]],
        sessionID: String,
        deadline: Date?
    ) async -> LocalToolBatchResult {
        let toolsListResponseData = await makeToolsListBatchResponseData(
            requests: toolsListRequests,
            sessionID: sessionID,
            deadline: deadline
        )
        var localDocumentationRequests = documentationRequests
        let fallbackDocumentationRequests: [[String: Any]]
        if deferredDocumentationRequests.isEmpty {
            fallbackDocumentationRequests = []
        } else if sessionManager.hasActiveDocumentationProvider() {
            localDocumentationRequests.append(contentsOf: deferredDocumentationRequests)
            fallbackDocumentationRequests = []
        } else {
            fallbackDocumentationRequests = deferredDocumentationRequests
        }
        let documentationResponseData = await makeDocumentationSearchBatchResponseData(
            requests: localDocumentationRequests,
            deadline: deadline
        )
        let localResponseData = Self.mergeBatchResponsePayloads(
            [
                initialLocalResponseData,
                toolsListResponseData,
                documentationResponseData,
            ],
            forceBatchArray: true
        )
        let fallbackForwardedRequest = fallbackDocumentationRequests.isEmpty
            ? nil
            : makeForwardedLocalToolRequest(
                forwardedObjects: fallbackDocumentationRequests,
                forceBatchArray: true
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
            guard let idValue = request["id"],
                  let originalID = RPCID(any: idValue) else {
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
                let mapped = Self.mapDocumentationSearchError(error)
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

    private func makeDocumentationSearchBatchResponseData(
        requests: [[String: Any]],
        deadline: Date?
    ) async -> Data? {
        var responseObjects: [[String: Any]] = []
        responseObjects.reserveCapacity(requests.count)
        let normalizer = ToolCallNormalizer(sessionManager: sessionManager)

        for request in requests {
            guard !Task.isCancelled else {
                break
            }
            guard let idValue = request["id"],
                  let originalID = RPCID(any: idValue) else {
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
                let responseData = try await sessionManager.callDocumentationSearch(
                    requestData: requestData,
                    requestTimeoutOverride: requestTimeout
                )
                let normalizedData = normalizer.normalizeResponseDataIfNeeded(
                    method: "tools/call",
                    toolName: DocumentationToolCatalog.toolName,
                    upstreamData: responseData
                )
                responseObjects.append(
                    contentsOf: Self.responseObjects(from: normalizedData)
                )
            } catch {
                let mapped = Self.mapDocumentationSearchError(error)
                responseObjects.append(
                    Self.makeJSONRPCErrorResponseObject(
                        id: originalID,
                        code: mapped.code,
                        message: mapped.message
                    )
                )
            }
        }

        return Self.makeToolResponseData(
            from: responseObjects,
            forceBatchArray: true
        )
    }

    private func isDocumentationSearchRequest(
        _ object: [String: Any],
        allowInactiveProvider: Bool = false
    ) -> Bool {
        let hasRoute =
            allowInactiveProvider
            ? sessionManager.hasDocumentationProvider()
            : sessionManager.hasActiveDocumentationProvider()
        guard hasRoute else {
            return false
        }
        guard object["method"] as? String == "tools/call",
              object["id"] != nil,
              let params = object["params"] as? [String: Any],
              params["name"] as? String == DocumentationToolCatalog.toolName,
              disabledToolNames.contains(DocumentationToolCatalog.toolName) == false else {
            return false
        }
        return true
    }

    private func isToolsListRequest(_ object: [String: Any]) -> Bool {
        object["method"] as? String == "tools/list"
            && object["id"] != nil
            && sessionManager.isInitialized()
    }

    private static func shouldUseEmbeddedTestSynchronousResolution(on eventLoop: EventLoop) -> Bool {
        String(describing: type(of: eventLoop)).contains("EmbeddedEventLoop")
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

    package func refreshCodeIssuesRequest(from requestJSON: Any) -> RefreshCodeIssuesRequest? {
        if let object = requestJSON as? [String: Any] {
            return refreshCodeIssuesRequest(from: object)
        }

        guard let requests = requestJSON as? [Any],
            requests.count == 1,
            let object = requests.first as? [String: Any]
        else {
            return nil
        }
        return refreshCodeIssuesRequest(from: object)
    }

    package func refreshCodeIssuesRequest(from object: [String: Any]) -> RefreshCodeIssuesRequest? {
        guard
            let method = object["method"] as? String,
            method == "tools/call",
            let params = object["params"] as? [String: Any],
            let toolName = params["name"] as? String,
            toolName == RefreshCodeIssuesRequest.toolName
        else {
            return nil
        }

        let arguments = params["arguments"] as? [String: Any]
        let tabIdentifier = arguments?["tabIdentifier"] as? String
        let filePath = arguments?["filePath"] as? String
        return RefreshCodeIssuesRequest(tabIdentifier: tabIdentifier, filePath: filePath)
    }

    package func refreshRequestRouting(from requestJSON: Any) -> RefreshRequestRouting? {
        if let object = requestJSON as? [String: Any],
            let refreshRequest = refreshCodeIssuesRequest(from: object),
            let bodyData = try? JSONSerialization.data(withJSONObject: object, options: [])
        {
            return RefreshRequestRouting(
                refreshRoutes: [
                    RefreshRequestRoute(
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
        var refreshRoutes: [RefreshRequestRoute] = []
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
            guard let candidate = refreshCodeIssuesRequest(from: object) else {
                remainingRequestObjects.append(object)
                continue
            }
            let payload: Any = requests.count == 1 ? requests : object
            guard let bodyData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                return nil
            }
            refreshRoutes.append(
                RefreshRequestRoute(
                    request: candidate,
                    bodyData: bodyData,
                    requestIDs: Self.extractResponseIDs(from: object),
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
        return RefreshRequestRouting(
            refreshRoutes: refreshRoutes,
            remainingBodyData: remainingBodyData,
            remainingRequestIDs: Self.extractResponseIDs(from: remainingPayload as Any),
            remainingLocalResponseData: remainingLocalResponseData
        )
    }

}
