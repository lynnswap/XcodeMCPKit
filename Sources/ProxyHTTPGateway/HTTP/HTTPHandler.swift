import Foundation
import Logging
import NIO
import NIOFoundationCompat
import NIOHTTP1
import NIOConcurrencyHelpers
import ProxyCore
import ProxyMCP
import ProxySession
import ProxyXcodeFeatures

package final class HTTPHandler: ChannelInboundHandler, Sendable {
    package typealias InboundIn = HTTPServerRequestPart
    package typealias OutboundOut = HTTPServerResponsePart

    package struct RequestLogContext: Sendable {
        package let id: String
        package let method: String
        package let path: String
        package let remoteAddress: String?
    }

    package struct State: Sendable {
        package var requestHead: HTTPRequestHead?
        package var bodyBuffer: ByteBuffer?
        package var isSSE = false
        package var sseSessionID: String?
        package var bodyTooLarge = false
        package var activePostRequestHandles: [String: HTTPPostCancellationHandle] = [:]
        package var responseWriteTail: EventLoopFuture<Void>?
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
        refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState? = nil,
        usesSynchronousLocalResolution: Bool = false
    ) {
        let refreshCoordinator =
            refreshCodeIssuesCoordinator
            ?? RefreshCodeIssuesCoordinator.makeDefault()
        let refreshDebugState =
            refreshCodeIssuesDebugState
            ?? RefreshCodeIssuesDebugState(
                defaultRequestTimeoutSeconds: config.requestTimeout
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
            usesSynchronousLocalResolution: usesSynchronousLocalResolution,
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
            remoteAddress: remoteAddressString(for: context.channel)
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

        let route = HTTPRoute.resolve(method: head.method, path: path)
        if routeRequiresOriginValidation(route),
            rejectInvalidOriginIfNeeded(context: context, head: head, requestLog: requestLog)
        {
            return
        }

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

    private func routeRequiresOriginValidation(_ route: HTTPRoute) -> Bool {
        switch route {
        case .sse, .deleteSession, .post:
            return true
        case .health, .debugSnapshot, .debugReset, .notFound:
            return false
        }
    }

    private func rejectInvalidOriginIfNeeded(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        requestLog: RequestLogContext
    ) -> Bool {
        guard let origin = head.headers.first(name: "Origin"),
            origin.isEmpty == false
        else {
            return false
        }
        guard originIsAllowed(origin, requestHead: head) else {
            _ = sendPlain(
                on: context.channel,
                status: .forbidden,
                body: "origin not allowed",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return true
        }
        return false
    }

    private func originIsAllowed(_ origin: String, requestHead: HTTPRequestHead) -> Bool {
        guard let components = URLComponents(string: origin),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let originHost = components.host
        else {
            return false
        }

        let normalizedOriginHost = Self.normalizedHost(originHost)
        let hostHeader = requestHead.headers.first(name: "Host")
        guard Self.originHostIsAllowed(
            normalizedOriginHost,
            configuredHost: config.listenHost,
            hostHeader: hostHeader
        ) else {
            return false
        }

        let originPort = components.port ?? Self.defaultPort(for: scheme)
        if let hostHeaderPort = Self.port(fromHostHeader: hostHeader),
            originPort != hostHeaderPort
        {
            return false
        }
        if config.listenPort > 0,
            originPort != config.listenPort
        {
            return false
        }
        return true
    }

    private static func normalizedHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
    }

    private static func defaultPort(for scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }

    private static func originHostIsAllowed(
        _ originHost: String,
        configuredHost: String,
        hostHeader: String?
    ) -> Bool {
        if isLoopbackOrConfiguredHost(originHost, configuredHost: configuredHost) {
            return true
        }
        guard isWildcardHost(configuredHost),
            let requestHost = host(fromHostHeader: hostHeader)
        else {
            return false
        }
        return originHost == normalizedHost(requestHost)
    }

    private static func isLoopbackOrConfiguredHost(
        _ host: String,
        configuredHost: String
    ) -> Bool {
        let configured = normalizedHost(configuredHost)
        if host == configured {
            return true
        }
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" {
            return true
        }
        if isIPv4LoopbackHost(host) {
            return true
        }
        return false
    }

    private static func isWildcardHost(_ host: String) -> Bool {
        switch normalizedHost(host) {
        case "0.0.0.0", "::", "0:0:0:0:0:0:0:0":
            return true
        default:
            return false
        }
    }

    private static func isIPv4LoopbackHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }

        var octets: [Int] = []
        for part in parts {
            guard part.isEmpty == false,
                part.allSatisfy({ $0.isNumber }),
                let value = Int(part),
                (0...255).contains(value)
            else {
                return false
            }
            octets.append(value)
        }
        return octets.first == 127
    }

    private static func host(fromHostHeader hostHeader: String?) -> String? {
        guard let hostHeader = hostHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
            hostHeader.isEmpty == false
        else {
            return nil
        }
        if hostHeader.hasPrefix("["),
            let closeBracket = hostHeader.firstIndex(of: "]")
        {
            return String(hostHeader[hostHeader.index(after: hostHeader.startIndex)..<closeBracket])
        }
        let colonCount = hostHeader.reduce(0) { count, character in
            character == ":" ? count + 1 : count
        }
        if colonCount == 1,
            let colon = hostHeader.lastIndex(of: ":"),
            Int(hostHeader[hostHeader.index(after: colon)...]) != nil
        {
            return String(hostHeader[..<colon])
        }
        return hostHeader
    }

    private static func port(fromHostHeader hostHeader: String?) -> Int? {
        guard let hostHeader else { return nil }
        if hostHeader.hasPrefix("["),
            let closeBracket = hostHeader.firstIndex(of: "]")
        {
            let rest = hostHeader[hostHeader.index(after: closeBracket)...]
            guard rest.first == ":" else { return nil }
            return Int(rest.dropFirst())
        }
        guard let colon = hostHeader.lastIndex(of: ":") else {
            return nil
        }
        return Int(hostHeader[hostHeader.index(after: colon)...])
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

        guard let sessionID = validateExistingSession(
            on: context.channel,
            head: head,
            requestLog: requestLog
        ) else {
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
        guard let sessionID = validateDeletableSession(
            on: context.channel,
            head: head,
            requestLog: requestLog
        ) else {
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
                case .request("initialize", _) = JSONRPCMessageInspector.kind(
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
            guard let sessionID = validateExistingSession(
                on: context.channel,
                head: head,
                requestLog: requestLog
            ) else {
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

    private func validateExistingSession(
        on channel: Channel,
        head: HTTPRequestHead,
        requestLog: RequestLogContext
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
        guard let expectedProtocolVersion = controlService.negotiatedProtocolVersion(id: sessionID),
            expectedProtocolVersion.isEmpty == false
        else {
            _ = sendPlain(
                on: channel,
                status: .badRequest,
                body: "session is not initialized",
                keepAlive: head.isKeepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
            return nil
        }
        guard let protocolVersion = HTTPRequestValidator.protocolVersion(from: head.headers),
            protocolVersion.isEmpty == false
        else {
            _ = sendPlain(
                on: channel,
                status: .badRequest,
                body: "protocol version required",
                keepAlive: head.isKeepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
            return nil
        }
        guard MCPProtocolVersion.isSupported(protocolVersion),
            protocolVersion == expectedProtocolVersion
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

    private func validateDeletableSession(
        on channel: Channel,
        head: HTTPRequestHead,
        requestLog: RequestLogContext
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
        guard let expectedProtocolVersion = controlService.negotiatedProtocolVersion(id: sessionID),
            expectedProtocolVersion.isEmpty == false
        else {
            return sessionID
        }
        guard let protocolVersion = HTTPRequestValidator.protocolVersion(from: head.headers),
            protocolVersion.isEmpty == false
        else {
            _ = sendPlain(
                on: channel,
                status: .badRequest,
                body: "protocol version required",
                keepAlive: head.isKeepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
            return nil
        }
        guard MCPProtocolVersion.isSupported(protocolVersion),
            protocolVersion == expectedProtocolVersion
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
