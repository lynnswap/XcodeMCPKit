import Foundation
import Logging
import NIO
import NIOFoundationCompat
import NIOHTTP1
import NIOConcurrencyHelpers
import XcodeMCPKit

final class HTTPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    struct RequestLogContext: Sendable {
        let id: String
        let method: String
        let path: String
        let remoteAddress: String?
    }

    struct State: Sendable {
        var requestHead: HTTPRequestHead?
        var bodyBuffer: ByteBuffer?
        var isSSE = false
        var sseSessionID: String?
        var bodyTooLarge = false
        var originRejected = false
        var activePostRequestHandles: [String: ClientMCPRequestExecutor.CancellationHandle] = [:]
        var responseWriteTail: EventLoopFuture<Void>?
    }

    let state = NIOLockedValueBox(State())
    let config: ProxyConfig
    let controlService: HTTPControlService
    let postService: ClientMCPRequestExecutor
    let responseWriter: HTTPResponseWriter
    let requestSecurityPolicy: HTTPRequestSecurityPolicy
    let logger: Logger = ProxyLogging.make("http")

    init(
        config: ProxyConfig,
        sessionManager: any RuntimeHTTPGatewayPort,
        refreshCodeIssuesCoordinator: RefreshCodeIssues.Coordinator? = nil,
        refreshCodeIssuesTargetResolver: RefreshCodeIssues.TargetResolver = RefreshCodeIssues.TargetResolver(),
        refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState? = nil,
        refreshCodeIssuesClock: ClockClient = .liveValue,
        eventLoopCompletionExecutor: EventLoopCompletionExecutor = .eventLoop
    ) {
        let refreshCoordinator =
            refreshCodeIssuesCoordinator
            ?? RefreshCodeIssues.Coordinator.makeDefault()
        let refreshDebugState =
            refreshCodeIssuesDebugState
            ?? RefreshCodeIssues.DebugState(
                defaultRequestTimeoutSeconds: config.requestTimeout
            )
        self.config = config
        self.controlService = HTTPControlService(
            runtimeCoordinator: sessionManager,
            refreshCodeIssuesCoordinator: refreshCoordinator,
            refreshCodeIssuesDebugState: refreshDebugState
        )
        self.postService = ClientMCPRequestExecutor(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: refreshCoordinator,
            refreshCodeIssuesTargetResolver: refreshCodeIssuesTargetResolver,
            refreshCodeIssuesDebugState: refreshDebugState,
            refreshCodeIssuesClock: refreshCodeIssuesClock,
            eventLoopCompletionExecutor: eventLoopCompletionExecutor,
            logger: ProxyLogging.make("http")
        )
        self.responseWriter = HTTPResponseWriter(logger: ProxyLogging.make("http.response"))
        self.requestSecurityPolicy = HTTPRequestSecurityPolicy(
            configuredHost: config.listenHost,
            configuredPort: config.listenPort
        )
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            let originRejected =
                requestSecurityPolicy.evaluate(
                    head,
                    localAddress: context.channel.localAddress
                ) == .rejectOrigin
            state.withLockedValue { state in
                state.requestHead = head
                state.bodyBuffer =
                    originRejected
                    ? nil
                    : context.channel.allocator.buffer(capacity: 0)
                state.bodyTooLarge = false
                state.originRejected = originRejected
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

    func channelActive(context: ChannelHandlerContext) {
        if let remote = remoteAddressString(for: context.channel) {
            logger.info("Client connected", metadata: ["remote": .string(remote)])
        } else {
            logger.info("Client connected")
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
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
        let request = state.withLockedValue { state -> (HTTPRequestHead, Bool)? in
            guard let head = state.requestHead else {
                return nil
            }
            state.requestHead = nil
            let originRejected = state.originRejected
            state.originRejected = false
            return (head, originRejected)
        }
        guard let (head, originRejected) = request else { return }

        let path = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? head.uri
        let requestLog = RequestLogContext(
            id: UUID().uuidString,
            method: head.method.rawValue,
            path: path,
            remoteAddress: remoteAddressString(for: context.channel)
        )
        logRequest(requestLog)

        if originRejected {
            _ = sendPlain(
                on: context.channel,
                status: .forbidden,
                body: "origin not allowed",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

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

        let route = HTTPRoute.resolve(method: head.method, path: path)

        switch route {
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

        guard
            let sessionID = validateSession(
                on: context.channel,
                head: head,
                requestLog: requestLog,
                initialization: .required
            )
        else {
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
        guard
            let sessionID = validateSession(
                on: context.channel,
                head: head,
                requestLog: requestLog,
                initialization: .allowUninitializedDelete
            )
        else {
            return
        }
        controlService.deleteSession(id: sessionID)
        _ = sendEmpty(on: context.channel, status: .ok, keepAlive: head.isKeepAlive, sessionID: sessionID, requestLog: requestLog)
    }

    private func handlePost(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        let prefersEventStream: Bool
        do {
            prefersEventStream = try HTTPRequestValidator.postPreference(for: head.headers)
        } catch HTTPRequestValidationFailure.notAcceptable {
            _ = sendPlain(
                on: context.channel,
                status: .notAcceptable,
                body: "client must accept application/json and text/event-stream",
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

        let parsedRequestJSON = try? JSONSerialization.jsonObject(with: bodyData, options: [])
        if parsedRequestJSON is [Any] {
            _ = sendPlain(
                on: context.channel,
                status: .badRequest,
                body: "JSON-RPC batching is not supported",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        let parsedRequestObject = parsedRequestJSON as? [String: Any]
        let isInitializeRequest = parsedRequestObject?["method"] as? String == "initialize"
        let hasValidInitializeID: Bool = {
            guard let parsedRequestObject,
                case .request("initialize", _) = JSONRPC.Message.Inspector.kind(
                    of: parsedRequestObject
                )
            else {
                return false
            }
            return true
        }()
        let effectiveSessionID: String?
        let headerSessionExists: Bool
        if isInitializeRequest {
            effectiveSessionID = hasValidInitializeID ? UUID().uuidString : nil
            headerSessionExists = false
        } else {
            guard
                let sessionID = validateSession(
                    on: context.channel,
                    head: head,
                    requestLog: requestLog,
                    initialization: .required
                )
            else {
                return
            }
            effectiveSessionID = sessionID
            headerSessionExists = true
        }
        let keepAlive = head.isKeepAlive
        let channel = context.channel
        let operation = postService.handle(
            bodyData: bodyData,
            headerSessionID: effectiveSessionID,
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
                let writeFuture = self.enqueueOrderedWrite(on: channel) {
                    self.sendPostResolution(
                        resolution,
                        on: channel,
                        keepAlive: keepAlive,
                        requestLog: requestLog
                    )
                }
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
                _ = self.enqueueOrderedWrite(on: channel) {
                    self.sendPlain(
                        on: channel,
                        status: .internalServerError,
                        body: "internal server error",
                        keepAlive: keepAlive,
                        sessionID: effectiveSessionID,
                        requestLog: requestLog
                    )
                }
            }
        }
    }

    private enum SessionInitializationRequirement {
        case required
        case allowUninitializedDelete
    }

    private func validateSession(
        on channel: Channel,
        head: HTTPRequestHead,
        requestLog: RequestLogContext,
        initialization: SessionInitializationRequirement
    ) -> String? {
        guard let sessionID = HTTPRequestValidator.sessionID(from: head.headers),
            sessionID.isEmpty == false
        else {
            _ = sendPlain(
                on: channel,
                status: .badRequest,
                body: "session id required",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return nil
        }
        guard controlService.hasSession(id: sessionID) else {
            _ = sendPlain(
                on: channel,
                status: .notFound,
                body: "session not found",
                keepAlive: head.isKeepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
            return nil
        }
        if case .allowUninitializedDelete = initialization,
            controlService.isSessionInitialized(id: sessionID) == false
        {
            return sessionID
        }
        let negotiatedVersion = controlService.negotiatedProtocolVersion(id: sessionID)
        guard
            case .accepted = HTTPRequestProtocolVersionResolver.resolve(
                headers: head.headers,
                negotiatedVersion: negotiatedVersion
            )
        else {
            _ = sendPlain(
                on: channel,
                status: .badRequest,
                body: "protocol version mismatch",
                keepAlive: head.isKeepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
            return nil
        }
        return sessionID
    }

    private func enqueueOrderedWrite(
        on channel: Channel,
        start: @escaping @Sendable () -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        let gate = channel.eventLoop.makePromise(of: Void.self)
        let writePromise = channel.eventLoop.makePromise(of: Void.self)
        let previous = state.withLockedValue { state in
            let previous = state.responseWriteTail ?? channel.eventLoop.makeSucceededFuture(())
            state.responseWriteTail = gate.futureResult
            return previous
        }
        previous.whenComplete { _ in
            let future = start()
            future.cascade(to: writePromise)
            future.whenComplete { _ in
                gate.succeed(())
            }
        }
        return writePromise.futureResult
    }

}
