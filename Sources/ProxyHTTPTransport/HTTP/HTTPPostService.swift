import Foundation
import Logging
import NIO
import NIOFoundationCompat
import NIOHTTP1
import ProxyCore
import ProxyFeatureXcode
import ProxyRuntime

package enum HTTPPostResolution {
    case responseData(
        data: Data,
        sessionID: String,
        prefersEventStream: Bool
    )
    case mcpError(
        id: RPCID?,
        ids: [RPCID],
        code: Int,
        message: String,
        forceBatchArray: Bool,
        sessionID: String,
        prefersEventStream: Bool
    )
    case plain(
        status: HTTPResponseStatus,
        body: String,
        sessionID: String?
    )
    case empty(
        status: HTTPResponseStatus,
        sessionID: String
    )
}

package final class HTTPPostService: Sendable {
    private let sessionManager: any RuntimeCoordinating
    private let localResponder: LocalMCPResponder
    private let forwardingService: MCPForwardingService
    private let windowQueryService: XcodeWindowQueryService
    private let refreshWorkflow: RefreshCodeIssuesWorkflow
    private let runDestinationService: XcodeRunDestinationService
    private let logger: Logger

    package init(
        config: ProxyConfig,
        sessionManager: any RuntimeCoordinating,
        refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator,
        refreshCodeIssuesTargetResolver: RefreshCodeIssuesTargetResolver = RefreshCodeIssuesTargetResolver(),
        refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState,
        runDestinationProcessRunner: (any ProcessRunning)? = nil,
        logger: Logger = ProxyLogging.make("http")
    ) {
        self.sessionManager = sessionManager
        self.localResponder = LocalMCPResponder(
            sessionManager: sessionManager,
            refreshCodeIssuesMode: config.refreshCodeIssuesMode,
            logger: ProxyLogging.make("http.local")
        )
        self.forwardingService = MCPForwardingService(
            config: config,
            sessionManager: sessionManager
        )
        self.windowQueryService = XcodeWindowQueryService()
        self.refreshWorkflow = RefreshCodeIssuesWorkflow(
            mode: config.refreshCodeIssuesMode,
            requestTimeout: config.requestTimeout,
            coordinator: refreshCodeIssuesCoordinator,
            targetResolver: refreshCodeIssuesTargetResolver,
            debugState: refreshCodeIssuesDebugState,
            logger: ProxyLogging.make("http.refresh")
        )
        self.runDestinationService = XcodeRunDestinationService(
            processRunner: runDestinationProcessRunner ?? ProcessRunner()
        )
        self.logger = logger
    }

    package func handle(
        bodyData: Data,
        headerSessionID: String?,
        headerSessionExists: Bool,
        prefersEventStream: Bool,
        eventLoop: EventLoop
    ) -> EventLoopFuture<HTTPPostResolution> {
        let requestMetadata = MCPErrorResponder.requestMetadata(from: bodyData)
        let requestIDs = requestMetadata.ids
        let requestIsBatch = requestMetadata.isBatch
        let parsedRequestJSON = try? JSONSerialization.jsonObject(with: bodyData, options: [])

        if let object = parsedRequestJSON as? [String: Any],
            let localHandling = localResponder.handle(
                object: object,
                headerSessionID: headerSessionID,
                headerSessionExists: headerSessionExists,
                eventLoop: eventLoop
            )
        {
            return resolveLocalHandling(
                localHandling,
                prefersEventStream: prefersEventStream,
                eventLoop: eventLoop
            )
        }

        if let headerSessionID, !headerSessionExists {
            _ = sessionManager.session(id: headerSessionID)
        }

        let sessionID = headerSessionID ?? UUID().uuidString

        if sessionManager.isInitialized() == false {
            if requestIDs.isEmpty {
                return eventLoop.makeSucceededFuture(
                    .plain(
                        status: .unprocessableEntity,
                        body: "expected initialize request",
                        sessionID: sessionID
                    )
                )
            }
            return eventLoop.makeSucceededFuture(
                .mcpError(
                    id: nil,
                    ids: requestIDs,
                    code: -32000,
                    message: "expected initialize request",
                    forceBatchArray: requestIsBatch,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }

        guard let parsedRequestJSON else {
            return eventLoop.makeSucceededFuture(
                .mcpError(
                    id: nil,
                    ids: [],
                    code: -32700,
                    message: "invalid json",
                    forceBatchArray: false,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }

        if requestIsBatch,
            let batchObjects = parsedRequestJSON as? [Any],
            batchObjects.contains(where: { XcodeRunDestinationToolRequest.parse(from: $0) != nil })
        {
            if headerSessionID == nil {
                return eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: requestIDs,
                        code: -32000,
                        message: "expected initialize request",
                        forceBatchArray: true,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }
            let promise = eventLoop.makePromise(of: HTTPPostResolution.self)
            Task { [self] in
                let responseData = await localBatchResponseData(
                    for: batchObjects,
                    sessionID: sessionID,
                    eventLoop: eventLoop
                )
                eventLoop.execute {
                    promise.succeed(
                        .responseData(
                            data: responseData,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                }
            }
            return promise.futureResult
        }

        let refreshRequest = requestIsBatch ? nil : refreshCodeIssuesRequest(from: parsedRequestJSON)
        if let refreshRequest, requestIDs.isEmpty == false {
            if headerSessionID == nil {
                return eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: requestIDs,
                        code: -32000,
                        message: "expected initialize request",
                        forceBatchArray: requestIsBatch,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }

            let promise = eventLoop.makePromise(of: HTTPPostResolution.self)
            Task { [self] in
                let attemptResult = await forwardRefreshCodeIssuesRequest(
                    refreshRequest,
                    bodyData: bodyData,
                    sessionID: sessionID,
                    requestIDs: requestIDs,
                    requestIsBatch: requestIsBatch,
                    eventLoop: eventLoop
                )
                eventLoop.execute {
                    promise.succeed(
                        self.makeResolution(
                            from: attemptResult,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                }
            }
            return promise.futureResult
        }

        let runDestinationRequest = requestIsBatch ? nil : runDestinationToolRequest(from: parsedRequestJSON)
        if let runDestinationRequest {
            if requestIDs.isEmpty {
                return eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: [],
                        code: -32600,
                        message: "missing id",
                        forceBatchArray: false,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }

            if headerSessionID == nil {
                return eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: requestIDs,
                        code: -32000,
                        message: "expected initialize request",
                        forceBatchArray: requestIsBatch,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }

            let promise = eventLoop.makePromise(of: HTTPPostResolution.self)
            let originalID = requestIDs[0]
            Task { [self] in
                let responseData = await runDestinationToolResponseData(
                    for: runDestinationRequest,
                    originalID: originalID,
                    sessionID: sessionID,
                    eventLoop: eventLoop
                )
                eventLoop.execute {
                    promise.succeed(
                        .responseData(
                            data: responseData,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                }
            }
            return promise.futureResult
        }

        let prepared: MCPForwardingService.PreparedRequest
        do {
            guard let candidate = try forwardingService.prepareRequest(
                bodyData: bodyData,
                parsedRequestJSON: parsedRequestJSON,
                sessionID: sessionID
            ) else {
                if requestIDs.isEmpty {
                    return eventLoop.makeSucceededFuture(
                        .plain(
                            status: .serviceUnavailable,
                            body: "upstream unavailable",
                            sessionID: sessionID
                        )
                    )
                }
                return eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: requestIDs,
                        code: -32001,
                        message: "upstream unavailable",
                        forceBatchArray: requestIsBatch,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }
            prepared = candidate
        } catch {
            return eventLoop.makeSucceededFuture(
                .mcpError(
                    id: nil,
                    ids: [],
                    code: -32700,
                    message: "invalid json",
                    forceBatchArray: false,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }

        if prepared.transform.method == "tools/list" {
            let hasCache = sessionManager.cachedToolsListResult() != nil
            let params = (parsedRequestJSON as? [String: Any])?["params"]
            let hasParams = params != nil && !(params is NSNull)
            logger.debug(
                "tools/list cache miss; forwarding upstream",
                metadata: [
                    "session": .string(sessionID),
                    "has_cache": .string(hasCache ? "true" : "false"),
                    "has_params": .string(hasParams ? "true" : "false"),
                    "upstream": .string("\(prepared.upstreamIndex)"),
                ]
            )
        }

        if headerSessionID == nil {
            if prepared.transform.isBatch || prepared.transform.method != "initialize"
                || !prepared.transform.expectsResponse
            {
                if prepared.transform.responseIDs.isEmpty {
                    return eventLoop.makeSucceededFuture(
                        .plain(
                            status: .unprocessableEntity,
                            body: "expected initialize request",
                            sessionID: sessionID
                        )
                    )
                }
                return eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: prepared.transform.responseIDs,
                        code: -32000,
                        message: "expected initialize request",
                        forceBatchArray: prepared.transform.isBatch,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }
        }

        let session = sessionManager.session(id: sessionID)

        if prepared.transform.expectsResponse {
            let started: MCPForwardingService.StartedRequest
            do {
                started = try forwardingService.startRequest(
                    prepared,
                    session: session,
                    on: eventLoop
                )
            } catch {
                return eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: [],
                        code: -32600,
                        message: "missing id",
                        forceBatchArray: false,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }

            let promise = eventLoop.makePromise(of: HTTPPostResolution.self)
            started.future.whenComplete { result in
                let resolution = self.forwardingService.resolveResponse(
                    result,
                    started: started,
                    sessionID: sessionID
                )
                switch resolution {
                case .success(let responseData):
                    promise.succeed(
                        .responseData(
                            data: responseData,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                case .invalidUpstreamResponse:
                    promise.succeed(
                        .plain(
                            status: .badGateway,
                            body: "invalid upstream response",
                            sessionID: sessionID
                        )
                    )
                case .timeout:
                    promise.succeed(
                        .mcpError(
                            id: nil,
                            ids: started.transform.responseIDs,
                            code: -32000,
                            message: "upstream timeout",
                            forceBatchArray: started.transform.isBatch,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                }
            }
            return promise.futureResult
        }

        if prepared.transform.method == "notifications/initialized" && sessionManager.isInitialized() {
            return eventLoop.makeSucceededFuture(
                .empty(status: .accepted, sessionID: sessionID)
            )
        }

        sessionManager.sendUpstream(
            prepared.transform.upstreamData,
            upstreamIndex: prepared.upstreamIndex
        )
        return eventLoop.makeSucceededFuture(
            .empty(status: .accepted, sessionID: sessionID)
        )
    }

    private func resolveLocalHandling(
        _ handling: LocalPostHandling,
        prefersEventStream: Bool,
        eventLoop: EventLoop
    ) -> EventLoopFuture<HTTPPostResolution> {
        switch handling {
        case .initialize(let future, let sessionID, let originalID):
            let promise = eventLoop.makePromise(of: HTTPPostResolution.self)
            future.whenComplete { result in
                switch result {
                case .success(let buffer):
                    var buffer = buffer
                    guard let data = buffer.readData(length: buffer.readableBytes) else {
                        promise.succeed(
                            .plain(
                                status: .badGateway,
                                body: "invalid upstream response",
                                sessionID: sessionID
                            )
                        )
                        return
                    }
                    promise.succeed(
                        .responseData(
                            data: data,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                case .failure:
                    promise.succeed(
                        .mcpError(
                            id: originalID,
                            ids: [],
                            code: -32000,
                            message: "upstream timeout",
                            forceBatchArray: false,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                }
            }
            return promise.futureResult

        case .immediateResponse(let data, let sessionID):
            return eventLoop.makeSucceededFuture(
                .responseData(
                    data: data,
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
                    forceBatchArray: false,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }
    }

    private func refreshCodeIssuesRequest(from requestJSON: Any) -> RefreshCodeIssuesRequest? {
        guard let object = requestJSON as? [String: Any],
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

    private func runDestinationToolRequest(from requestJSON: Any) -> XcodeRunDestinationToolRequest? {
        XcodeRunDestinationToolRequest.parse(from: requestJSON)
    }

    private func callInternalTool(
        name: String,
        arguments: [String: Any],
        sessionID: String,
        eventLoop: EventLoop,
        upstreamIndexOverride: Int? = nil,
        requestTimeoutOverride: TimeAmount? = nil
    ) async -> RefreshInternalToolResult {
        await forwardingService.callInternalTool(
            name: name,
            arguments: arguments,
            sessionID: sessionID,
            eventLoop: eventLoop,
            upstreamIndexOverride: upstreamIndexOverride,
            requestTimeoutOverride: requestTimeoutOverride
        )
    }

    private func listXcodeWindows(
        sessionID: String,
        eventLoop: EventLoop,
        upstreamIndexOverride: Int? = nil,
        requestTimeoutOverride: TimeAmount? = nil
    ) async -> [XcodeWindowInfo]? {
        await windowQueryService.listWindows(
            sessionID: sessionID,
            eventLoop: eventLoop,
            toolCaller: { name, arguments, sessionID, eventLoop in
                switch await self.callInternalTool(
                    name: name,
                    arguments: arguments,
                    sessionID: sessionID,
                    eventLoop: eventLoop,
                    upstreamIndexOverride: upstreamIndexOverride,
                    requestTimeoutOverride: requestTimeoutOverride
                ) {
                case .success(let result):
                    return result
                case .timeout, .unavailable:
                    return nil
                }
            }
        )
    }

    private func forwardOnce(
        bodyData: Data,
        sessionID: String,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount? = nil
    ) async -> RefreshForwardAttemptResult {
        let parsedRequestJSON: Any
        do {
            parsedRequestJSON = try JSONSerialization.jsonObject(with: bodyData, options: [])
        } catch {
            return .invalidRequest
        }

        let prepared: MCPForwardingService.PreparedRequest
        do {
            guard let candidate = try forwardingService.prepareRequest(
                bodyData: bodyData,
                parsedRequestJSON: parsedRequestJSON,
                sessionID: sessionID
            ) else {
                return .upstreamUnavailable(
                    responseIDs: requestIDs,
                    isBatch: requestIsBatch
                )
            }
            prepared = candidate
        } catch {
            return .invalidRequest
        }

        let session = sessionManager.session(id: sessionID)
        let started: MCPForwardingService.StartedRequest
        do {
            started = try forwardingService.startRequest(
                prepared,
                session: session,
                on: eventLoop,
                requestTimeoutOverride: requestTimeoutOverride
            )
        } catch {
            return .invalidRequest
        }

        let resolution: MCPForwardingService.ResponseResolution
        do {
            let buffer = try await started.future.get()
            resolution = forwardingService.resolveResponse(
                .success(buffer),
                started: started,
                sessionID: sessionID
            )
        } catch {
            resolution = forwardingService.resolveResponse(
                .failure(error),
                started: started,
                sessionID: sessionID
            )
        }

        switch resolution {
        case .success(let responseData):
            return .success(responseData)
        case .timeout:
            return .timeout(
                responseIDs: started.transform.responseIDs,
                isBatch: started.transform.isBatch
            )
        case .invalidUpstreamResponse:
            return .invalidUpstreamResponse
        }
    }

    private func forwardRefreshCodeIssuesRequest(
        _ refreshRequest: RefreshCodeIssuesRequest,
        bodyData: Data,
        sessionID: String,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        eventLoop: EventLoop
    ) async -> RefreshForwardAttemptResult {
        await refreshWorkflow.run(
            refreshRequest: refreshRequest,
            bodyData: bodyData,
            sessionID: sessionID,
            requestIDs: requestIDs,
            requestIsBatch: requestIsBatch,
            eventLoop: eventLoop,
            windowsProvider: { sessionID, eventLoop, upstreamIndexOverride, requestTimeoutOverride in
                await self.listXcodeWindows(
                    sessionID: sessionID,
                    eventLoop: eventLoop,
                    upstreamIndexOverride: upstreamIndexOverride,
                    requestTimeoutOverride: requestTimeoutOverride
                )
            },
            internalUpstreamChooser: { sessionID in
                self.sessionManager.chooseInitializeUpstreamIndex(sessionID: sessionID)
            },
            internalToolCaller: {
                name, arguments, sessionID, eventLoop, upstreamIndexOverride, requestTimeoutOverride in
                await self.callInternalTool(
                    name: name,
                    arguments: arguments,
                    sessionID: sessionID,
                    eventLoop: eventLoop,
                    upstreamIndexOverride: upstreamIndexOverride,
                    requestTimeoutOverride: requestTimeoutOverride
                )
            },
            forwarder: {
                bodyData, sessionID, requestIDs, requestIsBatch, eventLoop, requestTimeoutOverride in
                await self.forwardOnce(
                    bodyData: bodyData,
                    sessionID: sessionID,
                    requestIDs: requestIDs,
                    requestIsBatch: requestIsBatch,
                    eventLoop: eventLoop,
                    requestTimeoutOverride: requestTimeoutOverride
                )
            }
        )
    }

    private func makeResolution(
        from result: RefreshForwardAttemptResult,
        sessionID: String,
        prefersEventStream: Bool
    ) -> HTTPPostResolution {
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
        case .overloaded(let responseIDs, let isBatch):
            if responseIDs.isEmpty {
                return .plain(
                    status: .tooManyRequests,
                    body: "refresh queue overloaded",
                    sessionID: sessionID
                )
            }
            return .mcpError(
                id: nil,
                ids: responseIDs,
                code: -32003,
                message: "refresh queue overloaded",
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

    private func runDestinationToolResponseData(
        for request: XcodeRunDestinationToolRequest,
        originalID: RPCID,
        sessionID: String,
        eventLoop: EventLoop
    ) async -> Data {
        func failureResponse(
            _ message: String,
            _ structuredContent: [String: JSONValue] = [:]
        ) -> Data {
            self.makeToolCallResponseData(
                id: originalID,
                text: message,
                structuredContent: structuredContent.mapValues(\.foundationObject),
                isError: true
            )
        }

        let workspacePath: String
        switch request {
        case .list(let listRequest):
            guard let tabIdentifier = normalizedNonEmptyString(listRequest.tabIdentifier) else {
                return failureResponse("tabIdentifier is required")
            }
            guard let resolvedWorkspacePath = await resolveWorkspacePath(
                tabIdentifier: tabIdentifier,
                sessionID: sessionID,
                eventLoop: eventLoop
            ) else {
                return failureResponse(
                    "Could not resolve workspace for tabIdentifier \"\(tabIdentifier)\".",
                    ["tabIdentifier": .string(tabIdentifier)]
                )
            }
            workspacePath = resolvedWorkspacePath

        case .set(let setRequest):
            guard let tabIdentifier = normalizedNonEmptyString(setRequest.tabIdentifier) else {
                return failureResponse("tabIdentifier is required")
            }
            guard let resolvedWorkspacePath = await resolveWorkspacePath(
                tabIdentifier: tabIdentifier,
                sessionID: sessionID,
                eventLoop: eventLoop
            ) else {
                return failureResponse(
                    "Could not resolve workspace for tabIdentifier \"\(tabIdentifier)\".",
                    ["tabIdentifier": .string(tabIdentifier)]
                )
            }
            workspacePath = resolvedWorkspacePath
        }

        switch request {
        case .list:
            switch await runDestinationService.listRunDestinations(workspacePath: workspacePath) {
            case .success(let output):
                return makeToolCallResponseData(
                    id: originalID,
                    text: output.summaryText,
                    structuredContent: output.foundationObject,
                    isError: false
                )
            case .failure(let error):
                return failureResponse(error.message, error.structuredContent)
            }

        case .set(let setRequest):
            guard let platform = normalizedNonEmptyString(setRequest.platform) else {
                return failureResponse("platform is required")
            }
            switch await runDestinationService.setActiveRunDestination(
                workspacePath: workspacePath,
                platform: platform,
                osVersion: normalizedNonEmptyString(setRequest.osVersion),
                deviceFamily: setRequest.deviceFamily
            ) {
            case .success(let output):
                return makeToolCallResponseData(
                    id: originalID,
                    text: output.summaryText,
                    structuredContent: output.foundationObject,
                    isError: false
                )
            case .failure(let error):
                return failureResponse(error.message, error.structuredContent)
            }
        }
    }

    private func localBatchResponseData(
        for batchObjects: [Any],
        sessionID: String,
        eventLoop: EventLoop
    ) async -> Data {
        var responseObjects: [[String: Any]] = []
        responseObjects.reserveCapacity(batchObjects.count)

        for item in batchObjects {
            guard let itemObject = item as? [String: Any] else {
                responseObjects.append(
                    batchErrorObject(
                        id: nil,
                        code: -32600,
                        message: "invalid request"
                    )
                )
                continue
            }

            let itemData = (try? JSONSerialization.data(withJSONObject: itemObject, options: [])) ?? Data()
            let requestMetadata = MCPErrorResponder.requestMetadata(from: itemData)
            let originalID = requestMetadata.ids.first

            if let localHandling = localResponder.handle(
                object: itemObject,
                headerSessionID: sessionID,
                headerSessionExists: true,
                eventLoop: eventLoop
            ) {
                if let responseObject = await batchResponseObject(
                    from: localHandling,
                    fallbackID: originalID
                ) {
                    responseObjects.append(responseObject)
                }
                continue
            }

            if let refreshRequest = refreshCodeIssuesRequest(from: itemObject) {
                guard let originalID else {
                    forwardBatchNotification(
                        itemObject,
                        sessionID: sessionID
                    )
                    continue
                }

                let result = await forwardRefreshCodeIssuesRequest(
                    refreshRequest,
                    bodyData: itemData,
                    sessionID: sessionID,
                    requestIDs: [originalID],
                    requestIsBatch: false,
                    eventLoop: eventLoop
                )
                if let responseObject = batchResponseObject(
                    from: result,
                    fallbackID: originalID
                ) {
                    responseObjects.append(responseObject)
                }
                continue
            }

            if let localRequest = XcodeRunDestinationToolRequest.parse(from: itemObject) {
                guard let originalID else {
                    responseObjects.append(
                        batchErrorObject(
                            id: nil,
                            code: -32600,
                            message: "missing id"
                        )
                    )
                    continue
                }
                let responseData = await runDestinationToolResponseData(
                    for: localRequest,
                    originalID: originalID,
                    sessionID: sessionID,
                    eventLoop: eventLoop
                )
                if let object = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] {
                    responseObjects.append(object)
                }
                continue
            }

            guard let originalID else {
                forwardBatchNotification(
                    itemObject,
                    sessionID: sessionID
                )
                continue
            }

            let result = await forwardOnce(
                bodyData: itemData,
                sessionID: sessionID,
                requestIDs: [originalID],
                requestIsBatch: false,
                eventLoop: eventLoop
            )
            if let responseObject = batchResponseObject(
                from: result,
                fallbackID: originalID
            ) {
                responseObjects.append(responseObject)
            }
        }

        let responseArray: [Any] = responseObjects
        return (try? JSONSerialization.data(withJSONObject: responseArray, options: [])) ?? Data("[]".utf8)
    }

    private func batchResponseObject(
        from handling: LocalPostHandling,
        fallbackID: RPCID?
    ) async -> [String: Any]? {
        switch handling {
        case .initialize(let future, _, let originalID):
            do {
                var responseBuffer = try await future.get()
                guard let data = responseBuffer.readData(length: responseBuffer.readableBytes) else {
                    return batchErrorObject(
                        id: originalID,
                        code: -32000,
                        message: "invalid upstream response"
                    )
                }
                return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            } catch {
                return batchErrorObject(
                    id: originalID,
                    code: -32000,
                    message: "upstream timeout"
                )
            }

        case .immediateResponse(let data, _):
            return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]

        case .mcpError(let id, let code, let message, _):
            return batchErrorObject(
                id: id ?? fallbackID,
                code: code,
                message: message
            )
        }
    }

    private func forwardBatchNotification(
        _ itemObject: [String: Any],
        sessionID: String
    ) {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: itemObject, options: []),
            let prepared = try? forwardingService.prepareRequest(
                bodyData: bodyData,
                parsedRequestJSON: itemObject,
                sessionID: sessionID
            )
        else {
            return
        }

        guard prepared.transform.expectsResponse == false else {
            return
        }
        if prepared.transform.method == "notifications/initialized" && sessionManager.isInitialized() {
            return
        }
        sessionManager.sendUpstream(
            prepared.transform.upstreamData,
            upstreamIndex: prepared.upstreamIndex
        )
    }

    private func batchResponseObject(
        from result: RefreshForwardAttemptResult,
        fallbackID: RPCID
    ) -> [String: Any]? {
        switch result {
        case .success(let responseData):
            return try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any]
        case .timeout:
            return batchErrorObject(
                id: fallbackID,
                code: -32000,
                message: "upstream timeout"
            )
        case .upstreamUnavailable:
            return batchErrorObject(
                id: fallbackID,
                code: -32001,
                message: "upstream unavailable"
            )
        case .overloaded:
            return batchErrorObject(
                id: fallbackID,
                code: -32003,
                message: "refresh queue overloaded"
            )
        case .invalidRequest:
            return batchErrorObject(
                id: fallbackID,
                code: -32700,
                message: "invalid json"
            )
        case .invalidUpstreamResponse:
            return batchErrorObject(
                id: fallbackID,
                code: -32000,
                message: "invalid upstream response"
            )
        }
    }

    private func batchErrorObject(
        id: RPCID?,
        code: Int,
        message: String
    ) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id?.value.foundationObject ?? NSNull(),
            "error": [
                "code": code,
                "message": message,
            ],
        ]
    }

    private func resolveWorkspacePath(
        tabIdentifier: String,
        sessionID: String,
        eventLoop: EventLoop
    ) async -> String? {
        let initializeUpstreamIndex = sessionManager.chooseInitializeUpstreamIndex(
            sessionID: sessionID
        )
        let windows = await listXcodeWindows(
            sessionID: sessionID,
            eventLoop: eventLoop,
            upstreamIndexOverride: initializeUpstreamIndex
        )
        return windows?.first(where: { $0.tabIdentifier == tabIdentifier })?.workspacePath
    }

    private func makeToolCallResponseData(
        id: RPCID,
        text: String,
        structuredContent: [String: Any],
        isError: Bool
    ) -> Data {
        var result: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": text,
                ]
            ]
        ]
        if structuredContent.isEmpty == false {
            result["structuredContent"] = structuredContent
        }
        if isError {
            result["isError"] = true
        }

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.value.foundationObject,
            "result": result,
        ]

        guard JSONSerialization.isValidJSONObject(response),
            let data = try? JSONSerialization.data(withJSONObject: response, options: [])
        else {
            let fallback: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id.value.foundationObject,
                "result": [
                    "content": [
                        [
                            "type": "text",
                            "text": isError ? "local tool error" : "local tool success",
                        ]
                    ],
                    "isError": isError,
                ],
            ]
            return (try? JSONSerialization.data(withJSONObject: fallback, options: [])) ?? Data()
        }
        return data
    }

    private func normalizedNonEmptyString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            trimmed.isEmpty == false
        else {
            return nil
        }
        return trimmed
    }
}
