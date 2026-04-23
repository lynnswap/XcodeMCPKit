import Foundation
import NIO
import ProxyCore
import ProxyMCP
import ProxyXcodeFeatures
import ProxySession

package struct MCPForwardingService: Sendable {
    package struct PreparedRequest: Sendable {
        package let transform: RequestTransform
        package let upstreamIndex: Int
    }

    package struct StartedRequest: Sendable {
        package let transform: RequestTransform
        package let upstreamIndex: Int
        package let requestTimeout: TimeAmount?
        package let routerPendingToken: UUID
        package let future: EventLoopFuture<ByteBuffer>
    }

    package enum ResponseResolution: Sendable {
        case success(Data)
        case timeout
        case invalidUpstreamResponse
    }

    private let config: ProxyConfig
    private let disabledToolNames: Set<String>
    private let sessionManager: any RuntimeCoordinating

    package init(config: ProxyConfig, sessionManager: any RuntimeCoordinating) {
        self.config = config
        self.disabledToolNames = config.disabledToolNames
        self.sessionManager = sessionManager
    }

    package func prepareRequest(
        bodyData: Data,
        parsedRequestJSON: Any,
        sessionID: String,
        upstreamIndexOverride: Int? = nil
    ) throws -> PreparedRequest? {
        let upstreamIndex: Int
        if let upstreamIndexOverride {
            upstreamIndex = upstreamIndexOverride
        } else {
            guard let chosen = sessionManager.chooseUpstreamIndex() else {
                return nil
            }
            upstreamIndex = chosen
        }

        let transform = try RequestInspector.transform(
            bodyData,
            sessionID: sessionID,
            mapID: { sessionID, originalID in
                sessionManager.assignUpstreamID(
                    sessionID: sessionID,
                    originalID: originalID,
                    upstreamIndex: upstreamIndex
                )
            }
        )
        return PreparedRequest(transform: transform, upstreamIndex: upstreamIndex)
    }

    package func startRequest(
        _ prepared: PreparedRequest,
        session: SessionContext,
        on eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount? = nil,
        leaseID: RequestLeaseID? = nil,
        cancellationHandle: HTTPPostCancellationHandle? = nil,
        onTimeout: (@Sendable () -> Void)? = nil
    ) throws -> StartedRequest {
        let requestTimeout =
            requestTimeoutOverride
            ?? MCPMethodDispatcher.timeoutForMethod(
                prepared.transform.method,
                defaultSeconds: config.requestTimeout
            )
        let registration: ProxyRouter.PendingRegistration
        if prepared.transform.isBatch {
            registration = session.router.registerBatchPending(
                on: eventLoop,
                timeout: requestTimeout,
                onTimeout: onTimeout
            )
        } else if let idKey = prepared.transform.idKey {
            registration = session.router.registerRequestPending(
                idKey: idKey,
                on: eventLoop,
                timeout: requestTimeout,
                onTimeout: onTimeout
            )
        } else {
            struct MissingRequestIDError: Error {}
            throw MissingRequestIDError()
        }

        if let leaseID {
            sessionManager.activateRequestLease(
                leaseID,
                requestIDKey: prepared.transform.responseIDs.first?.key,
                upstreamIndex: prepared.upstreamIndex,
                timeout: requestTimeout
            )
        }
        cancellationHandle?.activate(upstreamIndex: prepared.upstreamIndex)
        cancellationHandle?.bindRouterPendingToken(registration.token)

        sessionManager.sendUpstream(
            prepared.transform.upstreamData,
            upstreamIndex: prepared.upstreamIndex,
            ensureRunning: false
        )
        return StartedRequest(
            transform: prepared.transform,
            upstreamIndex: prepared.upstreamIndex,
            requestTimeout: requestTimeout,
            routerPendingToken: registration.token,
            future: registration.future
        )
    }

    package func resolveResponse(
        _ result: Result<ByteBuffer, Error>,
        started: StartedRequest,
        sessionID: String,
        accountSuccess: Bool = true,
        accountTimeout: Bool = true
    ) -> ResponseResolution {
        switch result {
        case .success(let buffer):
            var buffer = buffer
            guard let data = buffer.readData(length: buffer.readableBytes) else {
                return .invalidUpstreamResponse
            }
            let rewrittenResourcesData = Self.rewriteUnsupportedResourcesListResponseIfNeeded(
                method: started.transform.method,
                originalID: started.transform.originalID,
                responseMethodsByIDKey: started.transform.responseMethodsByIDKey,
                responseOriginalIDsByKey: started.transform.responseOriginalIDsByKey,
                upstreamData: data
            )
            let cacheableToolsListData = Self.rewriteToolsListResponseIfNeeded(
                method: started.transform.method,
                upstreamData: rewrittenResourcesData,
                responseMethodsByIDKey: started.transform.responseMethodsByIDKey,
                mode: config.refreshCodeIssuesMode
            )
            let responseData = Self.rewriteToolsListResponseIfNeeded(
                method: started.transform.method,
                upstreamData: cacheableToolsListData,
                responseMethodsByIDKey: started.transform.responseMethodsByIDKey,
                mode: config.refreshCodeIssuesMode,
                hiddenToolNames: disabledToolNames
            )
            if started.transform.isCacheableToolsListRequest,
                let responseIDKey = started.transform.cacheableToolsListResponseIDKey,
                let result = Self.extractToolsListResult(
                    from: cacheableToolsListData,
                    matching: responseIDKey
                )
            {
                sessionManager.setCachedToolsListResult(result)
            }
            if accountSuccess, Self.shouldNotifyUpstreamSuccess(for: responseData) {
                for responseID in started.transform.responseIDs {
                    sessionManager.onRequestSucceeded(
                        sessionID: sessionID,
                        requestIDKey: responseID.key,
                        upstreamIndex: started.upstreamIndex
                    )
                }
            }
            return .success(responseData)

        case .failure:
            if let firstResponseID = started.transform.responseIDs.first {
                if accountTimeout {
                    sessionManager.onRequestTimeout(
                        sessionID: sessionID,
                        requestIDKey: firstResponseID.key,
                        upstreamIndex: started.upstreamIndex
                    )
                } else {
                    sessionManager.removeUpstreamIDMapping(
                        sessionID: sessionID,
                        requestIDKey: firstResponseID.key,
                        upstreamIndex: started.upstreamIndex
                    )
                }
                for responseID in started.transform.responseIDs.dropFirst() {
                    sessionManager.removeUpstreamIDMapping(
                        sessionID: sessionID,
                        requestIDKey: responseID.key,
                        upstreamIndex: started.upstreamIndex
                    )
                }
            }
            return .timeout
        }
    }

    package func callInternalTool(
        name: String,
        arguments: [String: Any],
        sessionID: String,
        eventLoop: EventLoop,
        cancellationHandle: HTTPPostCancellationHandle? = nil,
        upstreamIndexOverride: Int? = nil,
        requestTimeoutOverride: TimeAmount? = nil
    ) async -> RefreshInternalToolResult {
        let requestObject: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "__internal-\(UUID().uuidString)",
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments,
            ],
        ]
        let internalRequestID = RPCID(any: requestObject["id"]!)!

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestObject, options: [])
        else {
            return .unavailable
        }

        let descriptor = SessionPipelineRequestDescriptor(
            sessionID: sessionID,
            label: "tools/call:\(name)",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let leaseID = sessionManager.createRequestLease(descriptor: descriptor)
        let internalCancellationHandle = HTTPPostCancellationHandle(
            leaseID: leaseID,
            sessionID: sessionID,
            requestIDKeys: []
        )
        let session = sessionManager.session(id: sessionID)

        let resolution: ResponseResolution
        do {
            resolution = try await sessionManager.enqueueOnUpstreamSlot(
                leaseID: leaseID,
                descriptor: descriptor,
                on: eventLoop,
                preferredUpstreamIndex: upstreamIndexOverride
            ) { selectedUpstreamIndex in
                internalCancellationHandle.activate(upstreamIndex: selectedUpstreamIndex)
                self.sessionManager.activateRequestLease(
                    leaseID,
                    requestIDKey: nil,
                    upstreamIndex: selectedUpstreamIndex,
                    timeout: nil
                )
                let parsedRequestJSON: Any
                do {
                    parsedRequestJSON = try JSONSerialization.jsonObject(
                        with: bodyData,
                        options: []
                    )
                } catch {
                    return eventLoop.makeSucceededFuture(.invalidUpstreamResponse)
                }
                let prepared: PreparedRequest
                do {
                    guard let candidate = try prepareRequest(
                        bodyData: bodyData,
                        parsedRequestJSON: parsedRequestJSON,
                        sessionID: sessionID,
                        upstreamIndexOverride: selectedUpstreamIndex
                    ) else {
                        return eventLoop.makeSucceededFuture(.invalidUpstreamResponse)
                    }
                    prepared = candidate
                    internalCancellationHandle.bindRequestIDKeys(
                        prepared.transform.responseIDs.map(\.key)
                    )
                    if let cancellationHandle,
                        cancellationHandle.bindChildHandle(internalCancellationHandle) == false
                    {
                        internalCancellationHandle.cancel(using: sessionManager)
                        return eventLoop.makeFailedFuture(CancellationError())
                    }
                } catch {
                    return eventLoop.makeSucceededFuture(.invalidUpstreamResponse)
                }

                let started: StartedRequest
                do {
                    started = try startRequest(
                        prepared,
                        session: session,
                        on: eventLoop,
                        requestTimeoutOverride: requestTimeoutOverride,
                        leaseID: leaseID,
                        cancellationHandle: internalCancellationHandle,
                        onTimeout: {
                            self.sessionManager.handleRequestLeaseTimeout(
                                leaseID,
                                sessionID: sessionID,
                                requestIDKeys: prepared.transform.responseIDs.map(\.key),
                                upstreamIndex: prepared.upstreamIndex
                            )
                        }
                    )
                } catch {
                    return eventLoop.makeSucceededFuture(.invalidUpstreamResponse)
                }

                return started.future.map { buffer in
                    self.resolveResponse(
                        .success(buffer),
                        started: started,
                        sessionID: sessionID
                    )
                }.flatMapErrorThrowing { error in
                    if error is CancellationError {
                        throw error
                    }
                    return self.resolveResponse(
                        .failure(error),
                        started: started,
                        sessionID: sessionID
                    )
                }
            }.get()
        } catch is CancellationError {
            internalCancellationHandle.cancel(using: sessionManager)
            return .cancelled
        } catch {
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .upstreamUnavailable
            )
            return .unavailable
        }

        switch resolution {
        case .success(let responseData):
            internalCancellationHandle.markCompleted()
            sessionManager.completeRequestLease(leaseID)
            guard let object = Self.responseObject(
                from: responseData,
                matching: internalRequestID.key
            ),
                let result = object["result"] as? [String: Any]
            else {
                return .unavailable
            }
            if let isError = result["isError"] as? Bool, isError {
                return .unavailable
            }
            return .success(result)
        case .timeout:
            internalCancellationHandle.markCompleted()
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .timedOut,
                reason: .timedOut
            )
            return .timeout
        case .invalidUpstreamResponse:
            internalCancellationHandle.markCompleted()
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .invalidUpstreamResponse
            )
            return .unavailable
        }
    }

    private static func rewriteUnsupportedResourcesListResponseIfNeeded(
        method: String?,
        originalID: RPCID?,
        responseMethodsByIDKey: [String: String] = [:],
        responseOriginalIDsByKey: [String: RPCID] = [:],
        upstreamData: Data
    ) -> Data {
        guard let payload = try? JSONSerialization.jsonObject(with: upstreamData, options: []) else {
            return upstreamData
        }

        if let object = payload as? [String: Any] {
            let resolvedRequest: (method: String, originalID: RPCID)? = {
                if let method, let originalID {
                    return (method, originalID)
                }
                guard let responseIDValue = object["id"],
                    let responseID = RPCID(any: responseIDValue),
                    let method = responseMethodsByIDKey[responseID.key],
                    let originalID = responseOriginalIDsByKey[responseID.key]
                else {
                    return nil
                }
                return (method, originalID)
            }()
            guard let resolvedRequest else { return upstreamData }
            let rewrittenObject = rewriteUnsupportedResourcesListResponseObjectIfNeeded(
                object,
                method: resolvedRequest.method,
                originalID: resolvedRequest.originalID
            )
            guard JSONSerialization.isValidJSONObject(rewrittenObject),
                let rewrittenData = try? JSONSerialization.data(
                    withJSONObject: rewrittenObject,
                    options: []
                )
            else {
                return upstreamData
            }
            return rewrittenData
        }

        guard let array = payload as? [Any] else {
            return upstreamData
        }

        var rewroteAny = false
        let rewrittenArray = array.map { item -> Any in
            guard let object = item as? [String: Any],
                let responseIDValue = object["id"],
                let responseID = RPCID(any: responseIDValue),
                let method = responseMethodsByIDKey[responseID.key],
                let originalID = responseOriginalIDsByKey[responseID.key]
            else {
                return item
            }

            guard method == "resources/list" || method == "resources/templates/list" else {
                return item
            }

            rewroteAny = true
            return rewriteUnsupportedResourcesListResponseObjectIfNeeded(
                object,
                method: method,
                originalID: originalID
            )
        }
        guard rewroteAny,
            JSONSerialization.isValidJSONObject(rewrittenArray),
            let rewrittenData = try? JSONSerialization.data(
                withJSONObject: rewrittenArray,
                options: []
            )
        else {
            return upstreamData
        }
        return rewrittenData
    }

    private static func isNonStandardUnsupportedResourcesResult(_ result: Any, method: String)
        -> Bool
    {
        guard let resultObject = result as? [String: Any] else {
            return false
        }
        guard let isError = resultObject["isError"] as? Bool, isError else {
            return false
        }
        guard let content = resultObject["content"] as? [Any], !content.isEmpty else {
            return false
        }

        let methodToken = method.lowercased()
        for item in content {
            guard let contentObject = item as? [String: Any],
                let text = contentObject["text"] as? String
            else {
                continue
            }
            let normalized = text.lowercased()
            if normalized.contains("unknown method"), normalized.contains(methodToken) {
                return true
            }
        }
        return false
    }

    private static func emptyResourcesListResponseObject(method: String, originalID: RPCID)
        -> [String: Any]
    {
        let result: [String: Any] = method == "resources/list"
            ? ["resources": [Any]()]
            : ["resourceTemplates": [Any]()]
        return [
            "jsonrpc": "2.0",
            "id": originalID.value.foundationObject,
            "result": result,
        ]
    }

    private static func rewriteUnsupportedResourcesListResponseObjectIfNeeded(
        _ object: [String: Any],
        method: String,
        originalID: RPCID
    ) -> [String: Any] {
        guard method == "resources/list" || method == "resources/templates/list" else {
            return object
        }

        let expectedKey = method == "resources/list" ? "resources" : "resourceTemplates"
        let result = object["result"]

        if let resultObject = result as? [String: Any], resultObject[expectedKey] is [Any] {
            return object
        }

        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? (error["code"] as? Int)
            guard code == -32601 else {
                return object
            }
            return emptyResourcesListResponseObject(method: method, originalID: originalID)
        }

        if let result, isNonStandardUnsupportedResourcesResult(result, method: method) {
            return emptyResourcesListResponseObject(method: method, originalID: originalID)
        }

        return object
    }

    private static func emptyResourcesListResponseData(method: String, originalID: RPCID)
        -> Data?
    {
        let response = emptyResourcesListResponseObject(method: method, originalID: originalID)
        guard JSONSerialization.isValidJSONObject(response) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: response, options: [])
    }

    private static func rewriteToolsListResponseIfNeeded(
        method: String?,
        upstreamData: Data,
        responseMethodsByIDKey: [String: String] = [:],
        mode: RefreshCodeIssuesMode,
        hiddenToolNames: Set<String> = []
    ) -> Data {
        return RefreshCodeIssuesToolsListRewriter.rewriteResponseDataIfNeeded(
            upstreamData,
            method: method,
            responseMethodsByIDKey: responseMethodsByIDKey,
            mode: mode,
            hiddenToolNames: hiddenToolNames
        )
    }

    private static func extractToolsListResult(
        from responseData: Data,
        matching responseIDKey: String
    ) -> JSONValue? {
        guard let object = responseObject(
            from: responseData,
            matching: responseIDKey
        ),
            let resultAny = object["result"]
        else {
            return nil
        }
        return JSONValue(any: resultAny)
    }

    package static func responseObject(
        from responseData: Data,
        matching responseIDKey: String
    ) -> [String: Any]? {
        guard let payload = try? JSONSerialization.jsonObject(with: responseData, options: []) else {
            return nil
        }
        if let object = payload as? [String: Any] {
            guard let responseIDValue = object["id"],
                let responseID = RPCID(any: responseIDValue),
                responseID.key == responseIDKey
            else {
                return nil
            }
            return object
        }
        guard let array = payload as? [Any] else {
            return nil
        }
        for item in array {
            guard let object = item as? [String: Any],
                let responseIDValue = object["id"],
                let responseID = RPCID(any: responseIDValue),
                responseID.key == responseIDKey
            else {
                continue
            }
            return object
        }
        return nil
    }

    private static func shouldNotifyUpstreamSuccess(for responseData: Data) -> Bool {
        guard let any = try? JSONSerialization.jsonObject(with: responseData, options: []) else {
            return true
        }

        if let object = any as? [String: Any] {
            return isUpstreamOverloadedErrorResponse(object) == false
        }

        if let array = any as? [Any] {
            let objects = array.compactMap { $0 as? [String: Any] }
            guard objects.isEmpty == false else {
                return true
            }
            return objects.allSatisfy(isUpstreamOverloadedErrorResponse) == false
        }

        return true
    }

    private static func isUpstreamOverloadedErrorResponse(_ object: [String: Any]) -> Bool {
        guard let error = object["error"] as? [String: Any] else {
            return false
        }

        let code: Int?
        if let number = error["code"] as? NSNumber {
            code = number.intValue
        } else {
            code = error["code"] as? Int
        }
        guard code == -32002 else {
            return false
        }

        return (error["message"] as? String) == "upstream overloaded"
    }
}
