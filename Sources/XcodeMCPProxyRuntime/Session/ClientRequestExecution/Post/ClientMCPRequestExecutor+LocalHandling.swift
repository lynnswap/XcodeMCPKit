import Foundation
import NIO
import NIOFoundationCompat
import XcodeMCPKit

extension ClientMCPRequestExecutor {
    enum ToolCallRouting {
        case local(responseData: Data?)
        case localOperation(LocalToolOperation)
        case forward(FilteredToolCallRequest)
    }

    struct LocalToolOperation {
        let responseFuture: EventLoopFuture<Data?>
        let cancellationHandle: ClientMCPRequestExecutor.CancellationHandle
    }

    func resolveLocalHandling(
        _ handling: LocalPostHandling,
        prefersEventStream: Bool,
        eventLoop: EventLoop
    ) -> EventLoopFuture<ClientMCPRequestExecutor.Resolution> {
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
                return .responseData(
                    data: data,
                    sessionID: Self.isJSONRPCErrorResponse(data) ? errorSessionID : sessionID,
                    prefersEventStream: prefersEventStream
                )
            }.flatMapError { _ in
                eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: originalID,
                        code: -32000,
                        message: "upstream timeout",
                        sessionID: errorSessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }

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
                    code: code,
                    message: message,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }
    }

    func routeToolCall(
        object: [String: Any],
        bodyData: Data,
        sessionID: String,
        eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount?
    ) -> ToolCallRouting {
        if let toolName = blockedToolName(from: object) {
            return .local(
                responseData: Self.makeBlockedToolResponseData(
                    requestObject: object,
                    toolName: toolName
                )
            )
        }

        guard isDocumentationSearchRequest(object),
            let responseID = JSONRPC.Message.Inspector.requestID(from: object)
        else {
            return .forward(
                FilteredToolCallRequest(
                    bodyData: bodyData,
                    localResponseData: nil,
                    forwardedResponseID: JSONRPC.Message.Inspector.requestID(from: object)
                )
            )
        }

        let descriptor = Self.topLevelRequestDescriptor(
            sessionID: sessionID,
            parsedRequestJSON: object,
            responseID: responseID
        )
        let leaseID = sessionManager.createRequestLease(descriptor: descriptor)
        let cancellationHandle = ClientMCPRequestExecutor.CancellationHandle(
            leaseID: leaseID,
            sessionID: sessionID,
            requestIDKeys: [responseID.key]
        )
        let deadline = timeoutDeadline(
            for: requestTimeoutOverride
                ?? Self.topLevelRequestTimeoutOverride(
                    method: "tools/call",
                    defaultSeconds: requestTimeoutSeconds
                )
        )
        let promise = eventLoop.makePromise(of: Data?.self)
        let task = Task { [self] in
            let responseData: Data?
            if Task.isCancelled {
                responseData = nil
            } else if deadline != nil, remainingRequestTimeout(until: deadline) == nil {
                responseData = Self.makeJSONRPCErrorResponseData(
                    id: responseID,
                    code: -32000,
                    message: "upstream timeout"
                )
            } else {
                do {
                    switch try await sessionManager.callDocumentationSearch(
                        requestData: bodyData,
                        requestTimeoutOverride: remainingRequestTimeout(until: deadline)
                    ) {
                    case .handled(let data):
                        responseData = ToolCallNormalizer(sessionManager: sessionManager)
                            .normalizeResponseDataIfNeeded(
                                method: "tools/call",
                                toolName: DocumentationProvider.ToolCatalog.toolName,
                                upstreamData: data
                            )
                    case .unavailable(let reason):
                        responseData = Self.makeJSONRPCErrorResponseData(
                            id: responseID,
                            code: -32001,
                            message: reason.message
                        )
                    }
                } catch {
                    let mapped = ControlPlane.ErrorMapper.jsonRPCError(for: error)
                    responseData = Self.makeJSONRPCErrorResponseData(
                        id: responseID,
                        code: mapped.code,
                        message: mapped.message
                    )
                }
            }
            let wasCancelled = Task.isCancelled
            eventLoopCompletionExecutor.execute(on: eventLoop) {
                if wasCancelled {
                    promise.fail(CancellationError())
                } else {
                    promise.succeed(responseData)
                }
            }
        }
        cancellationHandle.bindRefreshTask(task)
        return .localOperation(
            LocalToolOperation(
                responseFuture: promise.futureResult,
                cancellationHandle: cancellationHandle
            )
        )
    }

    func blockedToolName(from requestObject: [String: Any]) -> String? {
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

    func refreshCodeIssuesRequest(from requestJSON: Any) -> RefreshCodeIssues.Request? {
        guard let object = requestJSON as? [String: Any] else { return nil }
        return RefreshCodeIssues.Request(requestObject: object)
    }

    private func isDocumentationSearchRequest(_ object: [String: Any]) -> Bool {
        guard sessionManager.hasDocumentationSearchService() else { return false }
        guard case .request("tools/call", _) = JSONRPC.Message.Inspector.kind(of: object),
            let params = object["params"] as? [String: Any],
            params["name"] as? String == DocumentationProvider.ToolCatalog.toolName,
            disabledToolNames.contains(DocumentationProvider.ToolCatalog.toolName) == false
        else {
            return false
        }
        return true
    }

    private static func isJSONRPCErrorResponse(_ data: Data) -> Bool {
        guard let object = try? JSONRPC.Wire.object(fromData: data), object["error"] != nil else {
            return false
        }
        return JSONRPC.Message.Inspector.responseID(from: object) != nil
    }
}
