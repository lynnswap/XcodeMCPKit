import Foundation
import Logging
import NIO
import NIOFoundationCompat
import NIOHTTP1
import NIOConcurrencyHelpers
import ProxyCore
import ProxyRuntime
import ProxyFeatureXcode

package final class HTTPHandler: ChannelInboundHandler, Sendable {
    package typealias InboundIn = HTTPServerRequestPart
    package typealias OutboundOut = HTTPServerResponsePart

    package struct RequestLogContext: Sendable {
        package let id: String
        package let method: String
        package let path: String
        package let remoteAddress: String?
        package let mcpInvocation: String
        package let requestParamsJSON: String

        package func withMCPDetails(invocation: String, paramsJSON: String) -> RequestLogContext {
            RequestLogContext(
                id: id,
                method: method,
                path: path,
                remoteAddress: remoteAddress,
                mcpInvocation: invocation,
                requestParamsJSON: paramsJSON
            )
        }
    }

    package struct State: Sendable {
        package var requestHead: HTTPRequestHead?
        package var bodyBuffer: ByteBuffer?
        package var isSSE = false
        package var sseSessionID: String?
        package var bodyTooLarge = false
        package var activePostRequestHandles: [String: HTTPPostCancellationHandle] = [:]
    }

    package let state = NIOLockedValueBox(State())
    package let config: ProxyConfig
    package let controlService: HTTPControlService
    package let postService: HTTPPostService
    package let responseWriter: HTTPResponseWriter
    package let logger: Logger = ProxyLogging.make("http")

    package init(
        config: ProxyConfig,
        sessionManager: any RuntimeCoordinating,
        refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator? = nil,
        refreshCodeIssuesTargetResolver: RefreshCodeIssuesTargetResolver = RefreshCodeIssuesTargetResolver(),
        refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState? = nil
    ) {
        let refreshCoordinator =
            refreshCodeIssuesCoordinator
            ?? RefreshCodeIssuesCoordinator.makeDefault(
                requestTimeout: config.requestTimeout
            )
        let refreshDebugState =
            refreshCodeIssuesDebugState
            ?? RefreshCodeIssuesDebugState(
                maxPendingPerKey: refreshCoordinator.maxPendingPerKey,
                maxPendingTotal: refreshCoordinator.maxPendingTotal,
                queueWaitTimeoutSeconds: refreshCoordinator.queueWaitTimeoutSeconds
            )
        self.config = config
        self.controlService = HTTPControlService(
            runtimeCoordinator: sessionManager,
            refreshCodeIssuesCoordinator: refreshCoordinator,
            refreshCodeIssuesDebugState: refreshDebugState
        )
        self.postService = HTTPPostService(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: refreshCoordinator,
            refreshCodeIssuesTargetResolver: refreshCodeIssuesTargetResolver,
            refreshCodeIssuesDebugState: refreshDebugState,
            logger: ProxyLogging.make("http")
        )
        self.responseWriter = HTTPResponseWriter(logger: ProxyLogging.make("http.response"))
    }

    package func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            state.withLockedValue { state in
                state.requestHead = head
                state.bodyBuffer = context.channel.allocator.buffer(capacity: 0)
                state.bodyTooLarge = false
            }
        case .body(var buffer):
            var shouldReturn = false
            state.withLockedValue { state in
                guard var body = state.bodyBuffer, !state.bodyTooLarge else {
                    shouldReturn = true
                    return
                }
                if body.readableBytes + buffer.readableBytes > config.maxBodyBytes {
                    state.bodyTooLarge = true
                    state.bodyBuffer = body
                    shouldReturn = true
                    return
                }
                body.writeBuffer(&buffer)
                state.bodyBuffer = body
            }
            if shouldReturn {
                return
            }
        case .end:
            handleRequest(context: context)
        }
    }

    package func channelActive(context: ChannelHandlerContext) {
        if let remote = remoteAddressString(for: context.channel) {
            logger.info("Client connected", metadata: ["remote": .string(remote)])
        } else {
            logger.info("Client connected")
        }
    }

    package func channelInactive(context: ChannelHandlerContext) {
        let (sessionID, activePostRequestHandles) = state.withLockedValue { state in
            let handles = Array(state.activePostRequestHandles.values)
            state.activePostRequestHandles.removeAll()
            return (state.sseSessionID, handles)
        }
        if let sessionID {
            controlService.closeSSE(sessionID: sessionID, channel: context.channel)
        }
        for handle in activePostRequestHandles {
            postService.cancel(handle, source: .channelInactive)
        }
        if let remote = remoteAddressString(for: context.channel) {
            if let sessionID {
                logger.info("Client disconnected", metadata: ["remote": .string(remote), "session": .string(sessionID)])
            } else {
                logger.info("Client disconnected", metadata: ["remote": .string(remote)])
            }
        } else if let sessionID {
            logger.info("Client disconnected", metadata: ["session": .string(sessionID)])
        } else {
            logger.info("Client disconnected")
        }
    }

    private func handleRequest(context: ChannelHandlerContext) {
        let head = state.withLockedValue { state -> HTTPRequestHead? in
            let head = state.requestHead
            state.requestHead = nil
            return head
        }
        guard let head else { return }

        let path = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? head.uri
        let requestLog = RequestLogContext(
            id: UUID().uuidString,
            method: head.method.rawValue,
            path: path,
            remoteAddress: remoteAddressString(for: context.channel),
            mcpInvocation: "unknown",
            requestParamsJSON: "null"
        )
        logRequest(requestLog)

        let bodyTooLarge = state.withLockedValue { $0.bodyTooLarge }
        if bodyTooLarge {
            _ = sendPlain(
                on: context.channel,
                status: .payloadTooLarge,
                body: "request body too large",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        switch HTTPRoute.resolve(method: head.method, path: path) {
        case .health:
            _ = sendPlain(on: context.channel, status: .ok, body: "ok", keepAlive: head.isKeepAlive, sessionID: nil, requestLog: requestLog)
        case .debugSnapshot:
            handleDebugSnapshot(context: context, head: head, requestLog: requestLog)
        case .debugReset:
            handleDebugReset(context: context, head: head, requestLog: requestLog)
        case .sse:
            handleSSE(context: context, head: head, requestLog: requestLog)
        case .deleteSession:
            handleDelete(context: context, head: head, requestLog: requestLog)
        case .post:
            handlePost(context: context, head: head, requestLog: requestLog)
        case .notFound:
            _ = sendPlain(on: context.channel, status: .notFound, body: "not found", keepAlive: head.isKeepAlive, sessionID: nil, requestLog: requestLog)
        }
    }

    private func handleDebugSnapshot(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        guard isLoopbackDebugEndpointEnabled else {
            _ = sendPlain(
                on: context.channel,
                status: .notFound,
                body: "not found",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        let includeSensitiveDebugPayloads = Self.shouldIncludeSensitiveDebugPayloads(
            from: head.uri
        )
        guard let data = controlService.debugSnapshotData(
            includeSensitiveDebugPayloads: includeSensitiveDebugPayloads
        ) else {
            _ = sendPlain(
                on: context.channel,
                status: .internalServerError,
                body: "debug snapshot unavailable",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        _ = sendJSONData(
            on: context.channel,
            data: data,
            keepAlive: head.isKeepAlive,
            sessionID: nil,
            requestLog: requestLog
        )
    }

    private func handleDebugReset(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        guard isLoopbackDebugEndpointEnabled else {
            _ = sendPlain(
                on: context.channel,
                status: .notFound,
                body: "not found",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        controlService.debugReset(on: context.eventLoop).whenComplete { [self, weak channel = context.channel] result in
            guard let channel else { return }
            switch result {
            case .success:
                _ = sendPlain(
                    on: channel,
                    status: .accepted,
                    body: "reset scheduled",
                    keepAlive: head.isKeepAlive,
                    sessionID: nil,
                    requestLog: requestLog
                )
            case .failure:
                _ = sendPlain(
                    on: channel,
                    status: .internalServerError,
                    body: "debug reset failed",
                    keepAlive: head.isKeepAlive,
                    sessionID: nil,
                    requestLog: requestLog
                )
            }
        }
    }

    private static func shouldIncludeSensitiveDebugPayloads(from uri: String) -> Bool {
        guard let components = URLComponents(string: uri) else { return false }
        return components.queryItems?.contains(where: { item in
            guard item.name == "includeSensitive" else { return false }
            guard let value = item.value?.lowercased() else { return false }
            return value == "1" || value == "true" || value == "yes"
        }) == true
    }

    private func handleSSE(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        let alreadySSE = state.withLockedValue { $0.isSSE }
        if alreadySSE {
            return
        }

        guard HTTPRequestValidator.acceptsEventStream(head.headers) else {
            _ = sendPlain(
                on: context.channel,
                status: .notAcceptable,
                body: "client must accept text/event-stream",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        guard let sessionID = HTTPRequestValidator.sessionID(from: head.headers) else {
            _ = sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session id required",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        state.withLockedValue { state in
            state.isSSE = true
            state.sseSessionID = sessionID
        }
        let openResult = controlService.openSSE(sessionID: sessionID, channel: context.channel)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "Mcp-Session-Id", value: sessionID)

        let responseHead = HTTPResponseHead(version: head.version, status: .ok, headers: headers)
        logResponse(requestLog, status: .ok, sessionID: sessionID)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: 8)
        buffer.writeString(": ok\n\n")
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        for data in openResult.bufferedNotifications {
            sendSSE(to: context.channel, data: data)
        }

        if let remote = requestLog.remoteAddress {
            logger.info("SSE connected", metadata: ["remote": .string(remote), "session": .string(sessionID)])
        } else {
            logger.info("SSE connected", metadata: ["session": .string(sessionID)])
        }
    }

    private func handleDelete(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        guard let sessionID = HTTPRequestValidator.sessionID(from: head.headers) else {
            _ = sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session id required",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }
        controlService.deleteSession(id: sessionID)
        _ = sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionID: sessionID, requestLog: requestLog)
    }

    private func handlePost(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        let prefersEventStream: Bool
        do {
            prefersEventStream = try HTTPRequestValidator.postPreference(for: head.headers)
        } catch HTTPRequestValidationFailure.notAcceptable {
            _ = sendPlain(
                on: context.channel,
                status: .notAcceptable,
                body: "client must accept application/json or text/event-stream",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        } catch HTTPRequestValidationFailure.unsupportedMediaType {
            _ = sendPlain(
                on: context.channel,
                status: .unsupportedMediaType,
                body: "content-type must be application/json",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        } catch {
            _ = sendPlain(
                on: context.channel,
                status: .badRequest,
                body: "invalid request headers",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        let body = state.withLockedValue { state -> ByteBuffer? in
            let body = state.bodyBuffer
            state.bodyBuffer = nil
            return body
        }
        guard var body = body else {
            _ = sendPlain(on: context.channel, status: .badRequest, body: "missing body", keepAlive: head.isKeepAlive, sessionID: nil, requestLog: requestLog)
            return
        }

        guard let bodyData = body.readData(length: body.readableBytes) else {
            _ = sendPlain(on: context.channel, status: .badRequest, body: "invalid body", keepAlive: head.isKeepAlive, sessionID: nil, requestLog: requestLog)
            return
        }

        let details = Self.mcpLogDetails(from: bodyData)
        let requestLog = requestLog.withMCPDetails(
            invocation: details.invocation,
            paramsJSON: details.paramsJSON
        )

        let headerSessionID = HTTPRequestValidator.sessionID(from: head.headers)
        let headerSessionExists = headerSessionID.map { controlService.hasSession(id: $0) } ?? false
        let keepAlive = head.isKeepAlive
        let channel = context.channel
        let operation = postService.handle(
            bodyData: bodyData,
            headerSessionID: headerSessionID,
            headerSessionExists: headerSessionExists,
            prefersEventStream: prefersEventStream,
            eventLoop: context.eventLoop
        )
        if let handle = operation.cancellationHandle {
            state.withLockedValue { state in
                state.activePostRequestHandles[requestLog.id] = handle
            }
        }
        operation.future.whenComplete { result in
            switch result {
            case .success(let resolution):
                let writeFuture = self.sendPostResolution(
                    resolution,
                    on: channel,
                    keepAlive: keepAlive,
                    requestLog: requestLog
                )
                writeFuture.whenFailure { error in
                    guard let handle = operation.cancellationHandle else { return }
                    self.logger.warning(
                        "HTTP response write failed",
                        metadata: [
                            "request_id": .string(requestLog.id),
                            "disconnect_source": .string("responseWriteFailure"),
                            "error": .string("\(error)"),
                        ]
                    )
                    self.postService.cancel(handle, source: .responseWriteFailure)
                }
                writeFuture.whenComplete { _ in
                    _ = self.state.withLockedValue { state in
                        state.activePostRequestHandles.removeValue(forKey: requestLog.id)
                    }
                }
            case .failure:
                if let handle = operation.cancellationHandle {
                    handle.markCompleted()
                }
                _ = self.state.withLockedValue { state in
                    state.activePostRequestHandles.removeValue(forKey: requestLog.id)
                }
                _ = self.sendPlain(
                    on: channel,
                    status: .internalServerError,
                    body: "internal server error",
                    keepAlive: keepAlive,
                    sessionID: headerSessionID,
                    requestLog: requestLog
                )
            }
        }
    }

    package static func mcpLogDetails(from bodyData: Data) -> (invocation: String, paramsJSON: String) {
        guard let requestJSON = try? JSONSerialization.jsonObject(with: bodyData, options: []) else {
            return ("unknown", "null")
        }

        if let object = requestJSON as? [String: Any] {
            return (
                mcpInvocation(from: object),
                jsonString((object["params"] as Any?) ?? NSNull())
            )
        }

        if let array = requestJSON as? [Any] {
            let paramsArray = array.map { item -> Any in
                guard let object = item as? [String: Any] else { return NSNull() }
                return object["params"] ?? NSNull()
            }
            return (
                "batch[\(array.count)]",
                jsonString(paramsArray)
            )
        }

        return ("unknown", "null")
    }

    private static func mcpInvocation(from object: [String: Any]) -> String {
        let method = (object["method"] as? String) ?? "unknown"
        guard method == "tools/call",
            let params = object["params"] as? [String: Any],
            let toolName = params["name"] as? String,
            toolName.isEmpty == false
        else {
            return method
        }
        return "\(method):\(toolName)"
    }

    private static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: []),
            let string = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        return string
    }

}
