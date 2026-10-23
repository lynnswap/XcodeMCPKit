import Foundation
import Logging
import NIO
import NIOFoundationCompat
import NIOHTTP1
import NIOConcurrencyHelpers
import XcodeMCPCore
import XcodeMCPProxyRuntimeContract

final class HTTPHandler: ChannelDuplexHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    /// How often an event stream with nothing to send carries a comment, and how long a reply can
    /// take before its response starts as an event stream. Clients give up on responses that do
    /// not start within a minute, and on streams that stay silent for a few minutes.
    static let keepaliveInterval: TimeAmount = .seconds(15)

    struct RequestLogContext: Sendable {
        let id: String
        let method: String
        let path: String
        let remoteAddress: String?
    }

    struct ActivePostRequest: Sendable {
        let call: any ProxyRuntimeCall
        /// The session the request holds until its reply is written.
        let sessionID: ProxySessionID
        let progressRoute: HTTPProgressRoute?
        let keepalive: RepeatedTask?
    }

    struct State: Sendable {
        var requestHead: HTTPRequestHead?
        var bodyBuffer: ByteBuffer?
        var sseSessionID: String?
        var sseKeepalive: RepeatedTask?
        var bodyTooLarge = false
        var securityDecision: HTTPRequestSecurityPolicy.Decision = .allow
        var activePostRequests: [String: ActivePostRequest] = [:]
        /// Whether the current request's response has not ended. Responses go out in request
        /// order, so the connection serves one request at a time.
        var responseInProgress = false
    }

    let state = NIOLockedValueBox(State())
    let config: ProxyHTTPConfiguration
    let controlService: HTTPControlService
    let responseWriter: HTTPResponseWriter
    let requestSecurityPolicy: HTTPRequestSecurityPolicy
    let scheduleResponseCompletion:
        @Sendable (EventLoop, @escaping @Sendable () -> Void) -> Void
    let logger: Logger = Logger(label: "XcodeMCPProxy.http")

    init(
        config: ProxyHTTPConfiguration,
        controlService: HTTPControlService,
        scheduleResponseCompletion: @escaping @Sendable (
            EventLoop,
            @escaping @Sendable () -> Void
        ) -> Void = { eventLoop, operation in
            eventLoop.execute(operation)
        }
    ) {
        self.config = config
        self.controlService = controlService
        self.responseWriter = HTTPResponseWriter(logger: Logger(label: "XcodeMCPProxy.http.response"))
        self.requestSecurityPolicy = HTTPRequestSecurityPolicy(
            configuredHost: config.listenHost,
            configuredPort: config.listenPort
        )
        self.scheduleResponseCompletion = scheduleResponseCompletion
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            let pipelined = state.withLockedValue { state in
                defer { state.responseInProgress = true }
                return state.responseInProgress
            }
            guard !pipelined else {
                logger.debug("Closing a connection that sent a request before the previous response ended")
                context.close(promise: nil)
                return
            }
            let securityDecision = requestSecurityPolicy.evaluate(
                head,
                localAddress: context.channel.localAddress
            )
            state.withLockedValue { state in
                state.requestHead = head
                state.bodyBuffer =
                    securityDecision == .allow
                    ? context.channel.allocator.buffer(capacity: 0)
                    : nil
                state.bodyTooLarge = false
                state.securityDecision = securityDecision
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

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if case .end = unwrapOutboundIn(data) {
            state.withLockedValue { $0.responseInProgress = false }
        }
        context.write(data, promise: promise)
    }

    func channelActive(context: ChannelHandlerContext) {
        if let remote = remoteAddressString(for: context.channel) {
            logger.debug("Client connected", metadata: ["remote": .string(remote)])
        } else {
            logger.debug("Client connected")
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let (sessionID, sseKeepalive, activePostRequests) = state.withLockedValue { state in
            let requests = Array(state.activePostRequests.values)
            state.activePostRequests.removeAll()
            defer { state.sseKeepalive = nil }
            return (state.sseSessionID, state.sseKeepalive, requests)
        }
        sseKeepalive?.cancel()
        if let sessionID {
            controlService.sessions.closeStream(ProxySessionID(rawValue: sessionID), channel: context.channel)
        }
        // The runtime replies to a cancelled request at once; nothing is left to write it to.
        for request in activePostRequests {
            request.keepalive?.cancel()
            if let route = request.progressRoute { controlService.sessions.delivery.removeProgressRoute(route) }
            request.call.cancel()
            controlService.sessions.release(request.sessionID)
        }
        if let remote = remoteAddressString(for: context.channel) {
            if let sessionID {
                logger.debug("Client disconnected", metadata: ["remote": .string(remote), "session": .string(sessionID)])
            } else {
                logger.debug("Client disconnected", metadata: ["remote": .string(remote)])
            }
        } else if let sessionID {
            logger.debug("Client disconnected", metadata: ["session": .string(sessionID)])
        } else {
            logger.debug("Client disconnected")
        }
    }

    private func handleRequest(context: ChannelHandlerContext) {
        let request = state.withLockedValue {
            state -> (HTTPRequestHead, ByteBuffer?, Bool, HTTPRequestSecurityPolicy.Decision)? in
            guard let head = state.requestHead else {
                return nil
            }
            defer {
                state.requestHead = nil
                state.bodyBuffer = nil
                state.bodyTooLarge = false
                state.securityDecision = .allow
            }
            return (head, state.bodyBuffer, state.bodyTooLarge, state.securityDecision)
        }
        guard let (head, body, bodyTooLarge, securityDecision) = request else { return }

        let path = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? head.uri
        let requestLog = RequestLogContext(
            id: UUID().uuidString,
            method: head.method.rawValue,
            path: path,
            remoteAddress: remoteAddressString(for: context.channel)
        )
        logRequest(requestLog)

        let rejection: String? = switch securityDecision {
        case .allow: nil
        case .rejectHost: "host not allowed"
        case .rejectOrigin: "origin not allowed"
        }
        if let rejection {
            _ = sendPlain(
                on: context.channel,
                status: .forbidden,
                body: rejection,
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

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
            handlePost(context: context, head: head, body: body, requestLog: requestLog)
        case .notFound:
            _ = sendPlain(on: context.channel, status: .notFound, body: "not found", keepAlive: head.isKeepAlive, sessionID: nil, requestLog: requestLog)
        }
    }

    private func handleDebugSnapshot(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        guard debugEndpointsEnabled else {
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
        guard debugEndpointsEnabled else {
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

        guard controlService.sessions.openStream(ProxySessionID(rawValue: sessionID), channel: context.channel) else {
            _ = sendPlain(
                on: context.channel,
                status: .notFound,
                body: "session not found",
                keepAlive: head.isKeepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
            return
        }

        let channel = context.channel
        let keepalive = context.eventLoop.scheduleRepeatedTask(
            initialDelay: Self.keepaliveInterval,
            delay: Self.keepaliveInterval
        ) { _ in
            _ = MCPResponseEmitter.sendKeepalive(on: channel)
        }
        state.withLockedValue { state in
            state.sseSessionID = sessionID
            state.sseKeepalive = keepalive
        }
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

        if let remote = requestLog.remoteAddress {
            logger.debug("SSE connected", metadata: ["remote": .string(remote), "session": .string(sessionID)])
        } else {
            logger.debug("SSE connected", metadata: ["session": .string(sessionID)])
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
        controlService.sessions.delete(ProxySessionID(rawValue: sessionID))
        _ = sendEmpty(on: context.channel, status: .ok, keepAlive: head.isKeepAlive, sessionID: sessionID, requestLog: requestLog)
    }

    private func handlePost(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        body: ByteBuffer?,
        requestLog: RequestLogContext
    ) {
        guard HTTPRequestValidator.contentTypeIsJSON(head.headers) else {
            _ = sendPlain(
                on: context.channel,
                status: .unsupportedMediaType,
                body: "content-type must be application/json",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        guard var body = body else {
            _ = sendPlain(on: context.channel, status: .badRequest, body: "missing body", keepAlive: head.isKeepAlive, sessionID: nil, requestLog: requestLog)
            return
        }

        guard let bodyData = body.readData(length: body.readableBytes) else {
            _ = sendPlain(on: context.channel, status: .badRequest, body: "invalid body", keepAlive: head.isKeepAlive, sessionID: nil, requestLog: requestLog)
            return
        }

        let request = ProxyRuntimeRequest(data: bodyData)
        let parsedRequestJSON = request.decodedJSON?.foundationObject
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
        let keepAlive = head.isKeepAlive
        let channel = context.channel
        let eventLoop = context.eventLoop
        let sessionID: ProxySessionID
        let session: any ProxyRuntimeSession
        if isInitializeRequest {
            guard hasValidInitializeID else {
                // Without a request id, `initialize` cannot start a session.
                let data = (try? JSONRPC.Wire.errorResponseData(id: nil, code: -32600, message: "invalid request")) ?? Data()
                _ = sendJSONData(on: channel, data: data, keepAlive: keepAlive, sessionID: nil, requestLog: requestLog)
                return
            }
            sessionID = ProxySessionID(rawValue: UUID().uuidString)
            do {
                session = try controlService.sessions.create(sessionID)
            } catch {
                _ = sendPlain(on: channel, status: .serviceUnavailable, body: "server unavailable",
                              keepAlive: keepAlive, sessionID: nil, requestLog: requestLog)
                return
            }
        } else {
            guard
                let validated = validateSession(
                    on: context.channel,
                    head: head,
                    requestLog: requestLog,
                    initialization: .required
                )
            else {
                return
            }
            sessionID = ProxySessionID(rawValue: validated)
            // The only "session not found" for a POST is answered here, before processing starts.
            guard let acquired = controlService.sessions.acquire(sessionID) else {
                _ = sendPlain(on: channel, status: .notFound, body: "session not found", keepAlive: keepAlive,
                              sessionID: validated, requestLog: requestLog)
                return
            }
            session = acquired
        }
        let response = HTTPPostResponse()
        // An `initialize` reply decides whether the session exists, so it is never streamed. A
        // notification is answered with 202, which has no body to stream.
        let streamsResponse = !isInitializeRequest
            && parsedRequestObject.flatMap(JSONRPC.Message.Inspector.requestID(from:)) != nil
            && HTTPRequestValidator.acceptsEventStream(head.headers)
        let progressRoute = !streamsResponse ? nil : Self.progressToken(in: parsedRequestObject).flatMap { token in
            controlService.sessions.delivery.routeProgress(token, of: sessionID) { [self] data in
                // Progress does not wait for earlier writes to complete, so a client that stops
                // reading cannot make it queue up; the event loop still orders it before the reply.
                scheduleResponseCompletion(eventLoop) {
                    self.sendStreamEvent(.message(data), in: response, on: channel, keepAlive: keepAlive,
                                         sessionID: sessionID.rawValue, requestLog: requestLog)
                }
            }
        }
        let keepalive = !streamsResponse ? nil : eventLoop.scheduleRepeatedTask(
            initialDelay: Self.keepaliveInterval,
            delay: Self.keepaliveInterval
        ) { [self] _ in
            sendStreamEvent(.keepalive, in: response, on: channel, keepAlive: keepAlive,
                            sessionID: sessionID.rawValue, requestLog: requestLog)
        }
        let call = session.receive(request)
        state.withLockedValue { state in
            state.activePostRequests[requestLog.id] = ActivePostRequest(
                call: call, sessionID: sessionID, progressRoute: progressRoute, keepalive: keepalive)
        }
        Task {
            let reply = await call.reply
            if let progressRoute { controlService.sessions.delivery.removeProgressRoute(progressRoute) }
            let responseSessionID: String?
            if isInitializeRequest, let version = Self.negotiatedProtocolVersion(in: reply) {
                controlService.sessions.markInitialized(sessionID, protocolVersion: version)
                responseSessionID = sessionID.rawValue
            } else if isInitializeRequest {
                // A failed `initialize` leaves nothing to resume.
                controlService.sessions.delete(sessionID)
                responseSessionID = nil
            } else {
                responseSessionID = sessionID.rawValue
            }
            self.scheduleResponseCompletion(eventLoop) {
                keepalive?.cancel()
                // A client that left already had its request cancelled and its session released.
                guard self.state.withLockedValue({ $0.activePostRequests[requestLog.id] != nil }) else { return }
                let writeFuture = self.sendPostResolution(reply, in: response, on: channel, keepAlive: keepAlive,
                                                          sessionID: responseSessionID, requestLog: requestLog)
                writeFuture.whenFailure { error in
                    self.logger.warning(
                        "HTTP response write failed",
                        metadata: [
                            "request_id": .string(requestLog.id),
                            "disconnect_source": .string("responseWriteFailure"),
                            "error": .string("\(error)"),
                        ]
                    )
                }
                writeFuture.whenComplete { _ in
                    self.finishActivePostRequest(requestID: requestLog.id)
                }
            }
        }
    }

    /// The progress token of a request, which asks for its progress notifications.
    private static func progressToken(in object: [String: Any]?) -> Any? {
        guard let object, JSONRPC.Message.Inspector.requestID(from: object) != nil,
              let meta = (object["params"] as? [String: Any])?["_meta"] as? [String: Any] else { return nil }
        return meta["progressToken"]
    }

    /// The protocol version a successful `initialize` reply negotiated, or `nil` for a failed one.
    private static func negotiatedProtocolVersion(in reply: ProxyRuntimeReply) -> String?? {
        guard case .response(let data) = reply, let object = try? JSONRPC.Wire.object(fromData: data),
              let result = object["result"] as? [String: Any] else { return nil }
        return .some(result["protocolVersion"] as? String)
    }

    private func finishActivePostRequest(requestID: String) {
        let sessionID = state.withLockedValue { state in
            state.activePostRequests.removeValue(forKey: requestID)?.sessionID
        }
        if let sessionID {
            controlService.sessions.release(sessionID)
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
        let sessionIDValue = ProxySessionID(rawValue: sessionID)
        guard let phase = controlService.sessions.phase(of: sessionIDValue) else {
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
        if case .allowUninitializedDelete = initialization, phase == .initializing {
            return sessionID
        }
        guard case .initialized(let negotiatedVersion) = phase else {
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
}
