import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOFoundationCompat
import NIOConcurrencyHelpers

final class HTTPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct RequestLogContext: Sendable {
        let id: String
        let method: String
        let path: String
        let remoteAddress: String?
    }

    private struct State: Sendable {
        var requestHead: HTTPRequestHead?
        var bodyBuffer: ByteBuffer?
        var isSSE = false
        var sseSessionId: String?
        var bodyTooLarge = false
    }

    private let state = NIOLockedValueBox(State())
    private let config: ProxyConfig
    private let sessionManager: any SessionManaging
    private let logger: Logger = ProxyLogging.make("http")

    init(config: ProxyConfig, sessionManager: any SessionManaging) {
        self.config = config
        self.sessionManager = sessionManager
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
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

    func channelActive(context: ChannelHandlerContext) {
        if let remote = remoteAddressString(for: context.channel) {
            logger.info("Client connected", metadata: ["remote": .string(remote)])
        } else {
            logger.info("Client connected")
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let sessionId = state.withLockedValue { $0.sseSessionId }
        if let sessionId {
            let session = sessionManager.session(id: sessionId)
            session.sseHub.remove(context.channel)
        }
        if let remote = remoteAddressString(for: context.channel) {
            if let sessionId {
                logger.info("Client disconnected", metadata: ["remote": .string(remote), "session": .string(sessionId)])
            } else {
                logger.info("Client disconnected", metadata: ["remote": .string(remote)])
            }
        } else if let sessionId {
            logger.info("Client disconnected", metadata: ["session": .string(sessionId)])
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
            sendPlain(
                on: context.channel,
                status: .payloadTooLarge,
                body: "request body too large",
                keepAlive: head.isKeepAlive,
                sessionId: nil,
                requestLog: requestLog
            )
            return
        }

        switch (head.method, path) {
        case (.GET, "/health"):
            sendPlain(on: context.channel, status: .ok, body: "ok", keepAlive: head.isKeepAlive, sessionId: nil, requestLog: requestLog)
        case (.GET, "/mcp"), (.GET, "/"), (.GET, "/mcp/events"), (.GET, "/events"):
            handleSSE(context: context, head: head, requestLog: requestLog)
        case (.DELETE, "/mcp"), (.DELETE, "/"):
            handleDelete(context: context, head: head, requestLog: requestLog)
        case (.POST, "/mcp"), (.POST, "/"):
            handlePost(context: context, head: head, requestLog: requestLog)
        default:
            sendPlain(on: context.channel, status: .notFound, body: "not found", keepAlive: head.isKeepAlive, sessionId: nil, requestLog: requestLog)
        }
    }

    private func handleSSE(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        let alreadySSE = state.withLockedValue { $0.isSSE }
        if alreadySSE {
            return
        }

        guard acceptsEventStream(head.headers) else {
            sendPlain(
                on: context.channel,
                status: .notAcceptable,
                body: "client must accept text/event-stream",
                keepAlive: head.isKeepAlive,
                sessionId: nil,
                requestLog: requestLog
            )
            return
        }

        guard let sessionId = sessionIdFromHeaders(head.headers) else {
            sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session id required",
                keepAlive: head.isKeepAlive,
                sessionId: nil,
                requestLog: requestLog
            )
            return
        }

        guard sessionManager.hasSession(id: sessionId) else {
            sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session not found",
                keepAlive: head.isKeepAlive,
                sessionId: sessionId,
                requestLog: requestLog
            )
            return
        }

        let session = sessionManager.session(id: sessionId)
        let hadClients = session.sseHub.hasClients

        state.withLockedValue { state in
            state.isSSE = true
            state.sseSessionId = sessionId
        }
        session.sseHub.add(context.channel)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "Mcp-Session-Id", value: sessionId)

        let responseHead = HTTPResponseHead(version: head.version, status: .ok, headers: headers)
        logResponse(requestLog, status: .ok, sessionId: sessionId)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: 8)
        buffer.writeString(": ok\n\n")
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        if !hadClients {
            let buffered = session.router.drainBufferedNotifications()
            for data in buffered {
                sendSSE(to: context.channel, data: data)
            }
        }

        if let remote = requestLog.remoteAddress {
            logger.info("SSE connected", metadata: ["remote": .string(remote), "session": .string(sessionId)])
        } else {
            logger.info("SSE connected", metadata: ["session": .string(sessionId)])
        }
    }

    private func handleDelete(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        guard let sessionId = sessionIdFromHeaders(head.headers) else {
            sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session id required",
                keepAlive: head.isKeepAlive,
                sessionId: nil,
                requestLog: requestLog
            )
            return
        }
        guard sessionManager.hasSession(id: sessionId) else {
            sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session not found",
                keepAlive: head.isKeepAlive,
                sessionId: sessionId,
                requestLog: requestLog
            )
            return
        }
        sessionManager.removeSession(id: sessionId)
        sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionId: sessionId, requestLog: requestLog)
    }

    private func handlePost(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        let wantsEventStream = acceptsEventStream(head.headers)
        let wantsJSON = acceptsJSON(head.headers)
        guard wantsEventStream || wantsJSON else {
            sendPlain(
                on: context.channel,
                status: .notAcceptable,
                body: "client must accept application/json or text/event-stream",
                keepAlive: head.isKeepAlive,
                sessionId: nil,
                requestLog: requestLog
            )
            return
        }

        guard contentTypeIsJSON(head.headers) else {
            sendPlain(
                on: context.channel,
                status: .unsupportedMediaType,
                body: "content-type must be application/json",
                keepAlive: head.isKeepAlive,
                sessionId: nil,
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
            sendPlain(on: context.channel, status: .badRequest, body: "missing body", keepAlive: head.isKeepAlive, sessionId: nil, requestLog: requestLog)
            return
        }

        guard let bodyData = body.readData(length: body.readableBytes) else {
            sendPlain(on: context.channel, status: .badRequest, body: "invalid body", keepAlive: head.isKeepAlive, sessionId: nil, requestLog: requestLog)
            return
        }

        if let object = try? JSONSerialization.jsonObject(with: bodyData, options: []) as? [String: Any],
           let method = object["method"] as? String,
           method == "initialize" {
            guard let originalIdValue = object["id"], let originalId = RPCId(any: originalIdValue) else {
                sendPlain(on: context.channel, status: .badRequest, body: "missing id", keepAlive: head.isKeepAlive, sessionId: nil, requestLog: requestLog)
                return
            }
            let headerSessionId = sessionIdFromHeaders(head.headers)
            let sessionId = headerSessionId ?? UUID().uuidString
            _ = sessionManager.session(id: sessionId)
            let future = sessionManager.registerInitialize(
                originalId: originalId,
                requestObject: object,
                on: context.eventLoop
            )
            let keepAlive = head.isKeepAlive
            let prefersEventStream = wantsEventStream
            let channel = context.channel
            future.whenComplete { result in
                switch result {
                case .success(let buffer):
                    var buffer = buffer
                    guard let data = buffer.readData(length: buffer.readableBytes) else {
                        self.sendPlain(on: channel, status: .badGateway, body: "invalid upstream response", keepAlive: keepAlive, sessionId: sessionId, requestLog: requestLog)
                        return
                    }
                    if prefersEventStream {
                        self.sendSingleSSE(on: channel, data: data, keepAlive: keepAlive, sessionId: sessionId, requestLog: requestLog)
                    } else {
                        var out = channel.allocator.buffer(capacity: data.count)
                        out.writeBytes(data)
                        self.sendJSON(on: channel, buffer: out, keepAlive: keepAlive, sessionId: sessionId, requestLog: requestLog)
                    }
                case .failure:
                    self.sendPlain(on: channel, status: .gatewayTimeout, body: "upstream timeout", keepAlive: keepAlive, sessionId: sessionId, requestLog: requestLog)
                }
            }
            return
        }

        let headerSessionId = sessionIdFromHeaders(head.headers)
        if let headerSessionId, !sessionManager.hasSession(id: headerSessionId) {
            sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session not found",
                keepAlive: head.isKeepAlive,
                sessionId: headerSessionId,
                requestLog: requestLog
            )
            return
        }

        let sessionId = headerSessionId ?? UUID().uuidString

        let transform: RequestTransform
        do {
            transform = try RequestInspector.transform(
                bodyData,
                sessionId: sessionId,
                mapId: { sessionId, originalId in
                    sessionManager.assignUpstreamId(sessionId: sessionId, originalId: originalId)
                }
            )
        } catch {
            sendPlain(on: context.channel, status: .badRequest, body: "invalid json", keepAlive: head.isKeepAlive, sessionId: sessionId, requestLog: requestLog)
            return
        }

        if headerSessionId == nil {
            if transform.isBatch || transform.method != "initialize" || !transform.expectsResponse {
                sendPlain(
                    on: context.channel,
                    status: .unprocessableEntity,
                    body: "expected initialize request",
                    keepAlive: head.isKeepAlive,
                    sessionId: sessionId,
                    requestLog: requestLog
                )
                return
            }
        }

        let session = sessionManager.session(id: sessionId)

        if transform.expectsResponse {
            let future: EventLoopFuture<ByteBuffer>
            if transform.isBatch {
                future = session.router.registerBatch(on: context.eventLoop)
            } else if let idKey = transform.idKey {
                future = session.router.registerRequest(idKey: idKey, on: context.eventLoop)
            } else {
                sendPlain(on: context.channel, status: .badRequest, body: "missing id", keepAlive: head.isKeepAlive, sessionId: sessionId, requestLog: requestLog)
                return
            }

            sessionManager.sendUpstream(transform.upstreamData)
            let keepAlive = head.isKeepAlive
            let sessionIdCopy = sessionId
            let prefersEventStream = wantsEventStream
            let channel = context.channel
            future.whenComplete { result in
                switch result {
                case .success(let buffer):
                    var buffer = buffer
                    guard let data = buffer.readData(length: buffer.readableBytes) else {
                        self.sendPlain(on: channel, status: .badGateway, body: "invalid upstream response", keepAlive: keepAlive, sessionId: sessionIdCopy, requestLog: requestLog)
                        return
                    }
                    if prefersEventStream {
                        self.sendSingleSSE(on: channel, data: data, keepAlive: keepAlive, sessionId: sessionIdCopy, requestLog: requestLog)
                    } else {
                        var out = channel.allocator.buffer(capacity: data.count)
                        out.writeBytes(data)
                        self.sendJSON(on: channel, buffer: out, keepAlive: keepAlive, sessionId: sessionIdCopy, requestLog: requestLog)
                    }
                case .failure:
                    self.sendPlain(on: channel, status: .gatewayTimeout, body: "upstream timeout", keepAlive: keepAlive, sessionId: sessionIdCopy, requestLog: requestLog)
                }
            }
        } else {
            if transform.method == "notifications/initialized" && sessionManager.isInitialized() {
                sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionId: sessionId, requestLog: requestLog)
            } else {
                sessionManager.sendUpstream(transform.upstreamData)
                sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionId: sessionId, requestLog: requestLog)
            }
        }
    }

    private func sendSingleSSE(on channel: Channel, data: Data, keepAlive: Bool, sessionId: String, requestLog: RequestLogContext) {
        logResponse(requestLog, status: .ok, sessionId: sessionId)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Mcp-Session-Id", value: sessionId)

        var head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        head.headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        channel.write(HTTPServerResponsePart.head(head), promise: nil)

        var buffer = channel.allocator.buffer(capacity: data.count + 16)
        buffer.writeString("data: ")
        buffer.writeBytes(data)
        buffer.writeString("\n\n")
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
        if !keepAlive {
            channel.close(promise: nil)
        }
    }

    private func sendJSON(on channel: Channel, buffer: ByteBuffer, keepAlive: Bool, sessionId: String, requestLog: RequestLogContext) {
        logResponse(requestLog, status: .ok, sessionId: sessionId)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Mcp-Session-Id", value: sessionId)
        Self.sendBuffer(on: channel, status: .ok, headers: headers, buffer: buffer, keepAlive: keepAlive)
    }

    private func sendPlain(
        on channel: Channel,
        status: HTTPResponseStatus,
        body: String,
        keepAlive: Bool,
        sessionId: String?,
        requestLog: RequestLogContext
    ) {
        logResponse(requestLog, status: status, sessionId: sessionId)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        if let sessionId {
            headers.add(name: "Mcp-Session-Id", value: sessionId)
        }
        var buffer = channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        Self.sendBuffer(on: channel, status: status, headers: headers, buffer: buffer, keepAlive: keepAlive)
    }

    private func sendEmpty(on channel: Channel, status: HTTPResponseStatus, keepAlive: Bool, sessionId: String, requestLog: RequestLogContext) {
        logResponse(requestLog, status: status, sessionId: sessionId)
        var headers = HTTPHeaders()
        headers.add(name: "Mcp-Session-Id", value: sessionId)
        Self.sendBuffer(on: channel, status: status, headers: headers, buffer: nil, keepAlive: keepAlive)
    }

    private static func sendBuffer(
        on channel: Channel,
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        buffer: ByteBuffer?,
        keepAlive: Bool
    ) {
        var head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        head.headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        if let buffer {
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
        if !keepAlive {
            channel.close(promise: nil)
        }
    }

    private func sendSSE(to channel: Channel, data: Data) {
        let payload = "data: \(String(decoding: data, as: UTF8.self))\n\n"
        channel.eventLoop.execute {
            guard channel.isActive else { return }
            var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
            buffer.writeString(payload)
            _ = channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
        }
    }

    private func sessionIdFromHeaders(_ headers: HTTPHeaders) -> String? {
        headers.first(name: "Mcp-Session-Id")
    }

    private func logRequest(_ request: RequestLogContext) {
        var metadata: Logger.Metadata = [
            "id": .string(request.id),
            "method": .string(request.method),
            "path": .string(request.path),
        ]
        if let remote = request.remoteAddress {
            metadata["remote"] = .string(remote)
        }
        logger.info("HTTP request", metadata: metadata)
    }

    private func logResponse(_ request: RequestLogContext, status: HTTPResponseStatus, sessionId: String?) {
        var metadata: Logger.Metadata = [
            "id": .string(request.id),
            "method": .string(request.method),
            "path": .string(request.path),
            "status": .string("\(status.code)"),
        ]
        if let remote = request.remoteAddress {
            metadata["remote"] = .string(remote)
        }
        if let sessionId {
            metadata["session"] = .string(sessionId)
        }
        logger.info("HTTP response", metadata: metadata)
    }

    private func remoteAddressString(for channel: Channel) -> String? {
        guard let address = channel.remoteAddress else {
            return nil
        }
        if let ip = address.ipAddress, let port = address.port {
            return "\(ip):\(port)"
        }
        return String(describing: address)
    }

    private func acceptsEventStream(_ headers: HTTPHeaders) -> Bool {
        guard let accept = headers.first(name: "Accept")?.lowercased() else { return false }
        return accept.contains("text/event-stream")
    }

    private func acceptsJSON(_ headers: HTTPHeaders) -> Bool {
        guard let accept = headers.first(name: "Accept")?.lowercased() else { return true }
        return accept.contains("application/json") || accept.contains("*/*")
    }

    private func contentTypeIsJSON(_ headers: HTTPHeaders) -> Bool {
        guard let contentType = headers.first(name: "Content-Type")?.lowercased() else { return false }
        return contentType.hasPrefix("application/json")
    }
}

struct RequestInfo {
    let expectsResponse: Bool
    let isBatch: Bool
    let idKey: String?
}

struct RequestTransform {
    let upstreamData: Data
    let expectsResponse: Bool
    let isBatch: Bool
    let idKey: String?
    let method: String?
}

enum RequestInspector {
    static func transform(
        _ data: Data,
        sessionId: String,
        mapId: (_ sessionId: String, _ originalId: RPCId) -> Int64
    ) throws -> RequestTransform {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        if var object = json as? [String: Any] {
            let method = object["method"] as? String
            if let id = object["id"], let rpcId = RPCId(any: id) {
                let upstreamId = mapId(sessionId, rpcId)
                object["id"] = upstreamId
                let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
                return RequestTransform(
                    upstreamData: upstream,
                    expectsResponse: true,
                    isBatch: false,
                    idKey: rpcId.key,
                    method: method
                )
            }
            let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
            return RequestTransform(
                upstreamData: upstream,
                expectsResponse: false,
                isBatch: false,
                idKey: nil,
                method: method
            )
        }

        if let array = json as? [Any] {
            var transformed: [Any] = []
            var hasRequest = false
            for item in array {
                if var object = item as? [String: Any] {
                    if let id = object["id"], let rpcId = RPCId(any: id) {
                        let upstreamId = mapId(sessionId, rpcId)
                        object["id"] = upstreamId
                        hasRequest = true
                    }
                    transformed.append(object)
                } else {
                    transformed.append(item)
                }
            }
            let upstream = try JSONSerialization.data(withJSONObject: transformed, options: [])
            return RequestTransform(
                upstreamData: upstream,
                expectsResponse: hasRequest,
                isBatch: true,
                idKey: nil,
                method: nil
            )
        }

        return RequestTransform(
            upstreamData: data,
            expectsResponse: false,
            isBatch: false,
            idKey: nil,
            method: nil
        )
    }
}
