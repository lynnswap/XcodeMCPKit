import Foundation
import NIO
import ProxyCore
import ProxyFeatureXcode
import ProxyRuntime

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
    private let sessionManager: any RuntimeCoordinating

    package init(config: ProxyConfig, sessionManager: any RuntimeCoordinating) {
        self.config = config
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
                upstreamData: data
            )
            let responseData = Self.rewriteToolsListResponseIfNeeded(
                method: started.transform.method,
                upstreamData: rewrittenResourcesData,
                mode: config.refreshCodeIssuesMode
            )
            let normalizedToolCallData = Self.rewriteToolCallStructuredContentIfNeeded(
                method: started.transform.method,
                toolName: started.transform.toolName,
                upstreamData: responseData,
                cachedToolsListResult: sessionManager.cachedToolsListResult()
            )
            if started.transform.isCacheableToolsListRequest,
                let object = try? JSONSerialization.jsonObject(with: normalizedToolCallData, options: [])
                    as? [String: Any],
                let resultAny = object["result"],
                let result = JSONValue(any: resultAny)
            {
                sessionManager.setCachedToolsListResult(result)
            }
            if accountSuccess, Self.shouldNotifyUpstreamSuccess(for: normalizedToolCallData) {
                for responseID in started.transform.responseIDs {
                    sessionManager.onRequestSucceeded(
                        sessionID: sessionID,
                        requestIDKey: responseID.key,
                        upstreamIndex: started.upstreamIndex
                    )
                }
            }
            return .success(normalizedToolCallData)

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
        let session = sessionManager.session(id: sessionID)

        let resolution: ResponseResolution
        do {
            resolution = try await sessionManager.enqueueOnUpstreamSlot(
                leaseID: leaseID,
                descriptor: descriptor,
                on: eventLoop,
                preferredUpstreamIndex: upstreamIndexOverride
            ) { selectedUpstreamIndex in
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
                        sessionID: sessionID,
                        accountSuccess: false,
                        accountTimeout: false
                    )
                }.flatMapErrorThrowing { error in
                    self.resolveResponse(
                        .failure(error),
                        started: started,
                        sessionID: sessionID,
                        accountSuccess: false,
                        accountTimeout: false
                    )
                }
            }.get()
        } catch is CancellationError {
            return .timeout
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
            sessionManager.completeRequestLease(leaseID)
            guard let object = try? JSONSerialization.jsonObject(with: responseData, options: [])
                as? [String: Any],
                let result = object["result"] as? [String: Any]
            else {
                return .unavailable
            }
            if let isError = result["isError"] as? Bool, isError {
                return .unavailable
            }
            return .success(result)
        case .timeout:
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .timedOut,
                reason: .timedOut
            )
            return .timeout
        case .invalidUpstreamResponse:
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
        upstreamData: Data
    ) -> Data {
        guard let method,
            method == "resources/list" || method == "resources/templates/list"
        else {
            return upstreamData
        }
        guard let originalID else { return upstreamData }

        let expectedKey = method == "resources/list" ? "resources" : "resourceTemplates"

        guard let object = try? JSONSerialization.jsonObject(with: upstreamData, options: [])
            as? [String: Any]
        else {
            return upstreamData
        }

        let result = object["result"]

        if let resultObject = result as? [String: Any], resultObject[expectedKey] is [Any] {
            return upstreamData
        }

        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? (error["code"] as? Int)
            guard code == -32601 else {
                return upstreamData
            }
            if let result,
                isNonStandardUnsupportedResourcesResult(result, method: method),
                let empty = emptyResourcesListResponseData(method: method, originalID: originalID)
            {
                return empty
            }
            return emptyResourcesListResponseData(method: method, originalID: originalID)
                ?? upstreamData
        }

        if let result,
            isNonStandardUnsupportedResourcesResult(result, method: method),
            let empty = emptyResourcesListResponseData(method: method, originalID: originalID)
        {
            return empty
        }

        return upstreamData
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

    private static func emptyResourcesListResponseData(method: String, originalID: RPCID)
        -> Data?
    {
        let result: [String: Any] = method == "resources/list"
            ? ["resources": [Any]()]
            : ["resourceTemplates": [Any]()]
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalID.value.foundationObject,
            "result": result,
        ]
        guard JSONSerialization.isValidJSONObject(response) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: response, options: [])
    }

    private static func rewriteToolsListResponseIfNeeded(
        method: String?,
        upstreamData: Data,
        mode: RefreshCodeIssuesMode
    ) -> Data {
        guard method == "tools/list" else {
            return upstreamData
        }
        return RefreshCodeIssuesToolsListRewriter.rewriteResponseDataIfNeeded(
            upstreamData,
            mode: mode
        )
    }

    private static func rewriteToolCallStructuredContentIfNeeded(
        method: String?,
        toolName: String?,
        upstreamData: Data,
        cachedToolsListResult: JSONValue?
    ) -> Data {
        guard method == "tools/call",
            let toolName,
            toolHasOutputSchema(named: toolName, in: cachedToolsListResult),
            let object = try? JSONSerialization.jsonObject(with: upstreamData, options: []) as? [String: Any],
            let result = object["result"] as? [String: Any],
            (result["isError"] as? Bool) != true
        else {
            return upstreamData
        }

        let rewrittenResult = rewrittenToolCallResult(toolName: toolName, result: result)
        guard rewrittenResult.changed else {
            return upstreamData
        }

        var rewrittenObject = object
        rewrittenObject["result"] = rewrittenResult.result
        guard JSONSerialization.isValidJSONObject(rewrittenObject),
            let rewrittenData = try? JSONSerialization.data(withJSONObject: rewrittenObject, options: [])
        else {
            return upstreamData
        }
        return rewrittenData
    }

    private static func toolHasOutputSchema(named toolName: String, in toolsListResult: JSONValue?) -> Bool {
        guard let toolsListResult,
            case .object(let resultObject) = toolsListResult,
            case .array(let tools) = resultObject["tools"]
        else {
            return false
        }

        for tool in tools {
            guard case .object(let toolObject) = tool,
                case .string(let candidateName) = toolObject["name"],
                candidateName == toolName
            else {
                continue
            }
            return toolObject["outputSchema"] != nil
        }
        return false
    }

    private static func structuredToolContent(from result: [String: Any]) -> Any? {
        guard let content = result["content"] as? [[String: Any]] else {
            return nil
        }

        for item in content {
            guard let text = item["text"] as? String,
                text.isEmpty == false,
                let textData = text.data(using: .utf8),
                let structuredContent = try? JSONSerialization.jsonObject(with: textData, options: [])
            else {
                continue
            }

            if structuredContent is [String: Any] || structuredContent is [Any] {
                return structuredContent
            }
        }

        return nil
    }

    private static func rewrittenToolCallResult(toolName: String, result: [String: Any]) -> (
        result: [String: Any], changed: Bool
    ) {
        var rewrittenResult = result
        var changed = false

        if rewrittenResult["structuredContent"] == nil,
            let structuredContent = structuredToolContent(from: rewrittenResult)
        {
            rewrittenResult["structuredContent"] = structuredContent
            changed = true
        }

        if let structuredContent = rewrittenResult["structuredContent"],
            let normalizedStructuredContent = normalizeStructuredContentIfNeeded(
                toolName: toolName,
                structuredContent: structuredContent
            )
        {
            rewrittenResult["structuredContent"] = normalizedStructuredContent
            changed = true
        }

        return (rewrittenResult, changed)
    }

    private static func normalizeStructuredContentIfNeeded(
        toolName: String,
        structuredContent: Any
    ) -> Any? {
        switch toolName {
        case "GetBuildLog":
            guard let object = structuredContent as? [String: Any] else {
                return nil
            }
            return normalizeGetBuildLogStructuredContentIfNeeded(object)
        default:
            return nil
        }
    }

    private static func normalizeGetBuildLogStructuredContentIfNeeded(
        _ structuredContent: [String: Any]
    ) -> [String: Any]? {
        guard let buildLogEntries = structuredContent["buildLogEntries"] as? [[String: Any]] else {
            return nil
        }

        var normalizedEntries: [[String: Any]] = []
        normalizedEntries.reserveCapacity(buildLogEntries.count)
        var changed = false

        for entry in buildLogEntries {
            guard let emittedIssues = entry["emittedIssues"] as? [[String: Any]] else {
                normalizedEntries.append(entry)
                continue
            }

            var normalizedIssues: [[String: Any]] = []
            normalizedIssues.reserveCapacity(emittedIssues.count)
            var entryChanged = false

            for issue in emittedIssues {
                guard issue["line"] == nil else {
                    normalizedIssues.append(issue)
                    continue
                }

                var normalizedIssue = issue
                normalizedIssue["line"] = 0
                normalizedIssues.append(normalizedIssue)
                entryChanged = true
            }

            if entryChanged {
                var normalizedEntry = entry
                normalizedEntry["emittedIssues"] = normalizedIssues
                normalizedEntries.append(normalizedEntry)
                changed = true
            } else {
                normalizedEntries.append(entry)
            }
        }

        guard changed else {
            return nil
        }

        var normalizedStructuredContent = structuredContent
        normalizedStructuredContent["buildLogEntries"] = normalizedEntries
        return normalizedStructuredContent
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
