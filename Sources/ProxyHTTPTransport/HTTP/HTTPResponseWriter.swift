import Foundation
import Logging
import NIO
import NIOHTTP1
import ProxyCore

package struct HTTPResponseWriter: Sendable {
    private let logger: Logger

    package init(logger: Logger) {
        self.logger = logger
    }

    package func sendSingleSSE(
        on channel: Channel,
        data: Data,
        keepAlive: Bool,
        sessionID: String,
        requestLog: HTTPHandler.RequestLogContext
    ) {
        guard MCPResponseEmitter.sendSingleSSE(
            on: channel,
            data: data,
            keepAlive: keepAlive,
            sessionID: sessionID
        ) else {
            sendPlain(
                on: channel,
                status: .badGateway,
                body: "invalid upstream response",
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
            return
        }
        logResponse(requestLog, status: .ok, sessionID: sessionID)
    }

    package func sendJSON(
        on channel: Channel,
        buffer: ByteBuffer,
        keepAlive: Bool,
        sessionID: String,
        requestLog: HTTPHandler.RequestLogContext
    ) {
        logResponse(requestLog, status: .ok, sessionID: sessionID)
        MCPResponseEmitter.sendJSON(
            on: channel,
            buffer: buffer,
            keepAlive: keepAlive,
            sessionID: sessionID
        )
    }

    package func sendJSONData(
        on channel: Channel,
        data: Data,
        keepAlive: Bool,
        sessionID: String?,
        requestLog: HTTPHandler.RequestLogContext
    ) {
        logResponse(requestLog, status: .ok, sessionID: sessionID)
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        MCPResponseEmitter.sendJSON(
            on: channel,
            buffer: buffer,
            keepAlive: keepAlive,
            sessionID: sessionID
        )
    }

    package func sendPlain(
        on channel: Channel,
        status: HTTPResponseStatus,
        body: String,
        keepAlive: Bool,
        sessionID: String?,
        requestLog: HTTPHandler.RequestLogContext
    ) {
        logResponse(requestLog, status: status, sessionID: sessionID)
        MCPResponseEmitter.sendPlain(
            on: channel,
            status: status,
            body: body,
            keepAlive: keepAlive,
            sessionID: sessionID
        )
    }

    package func sendEmpty(
        on channel: Channel,
        status: HTTPResponseStatus,
        keepAlive: Bool,
        sessionID: String,
        requestLog: HTTPHandler.RequestLogContext
    ) {
        logResponse(requestLog, status: status, sessionID: sessionID)
        MCPResponseEmitter.sendEmpty(
            on: channel,
            status: status,
            keepAlive: keepAlive,
            sessionID: sessionID
        )
    }

    package func sendMCPError(
        on channel: Channel,
        id: RPCID?,
        code: Int,
        message: String,
        prefersEventStream: Bool,
        keepAlive: Bool,
        sessionID: String,
        requestLog: HTTPHandler.RequestLogContext
    ) {
        guard let data = MCPErrorResponder.errorResponseData(
            id: id,
            code: code,
            message: message
        ) else {
            sendPlain(
                on: channel,
                status: .badGateway,
                body: "invalid error response",
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
            return
        }
        sendErrorPayload(
            on: channel,
            data: data,
            prefersEventStream: prefersEventStream,
            keepAlive: keepAlive,
            sessionID: sessionID,
            requestLog: requestLog
        )
    }

    package func sendMCPError(
        on channel: Channel,
        ids: [RPCID],
        code: Int,
        message: String,
        forceBatchArray: Bool = false,
        prefersEventStream: Bool,
        keepAlive: Bool,
        sessionID: String,
        requestLog: HTTPHandler.RequestLogContext
    ) {
        guard let data = MCPErrorResponder.errorResponseData(
            ids: ids,
            code: code,
            message: message,
            forceBatchArray: forceBatchArray
        ) else {
            sendPlain(
                on: channel,
                status: .badGateway,
                body: "invalid error response",
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
            return
        }
        sendErrorPayload(
            on: channel,
            data: data,
            prefersEventStream: prefersEventStream,
            keepAlive: keepAlive,
            sessionID: sessionID,
            requestLog: requestLog
        )
    }

    package func sendSSE(to channel: Channel, data: Data) {
        guard let payload = SSECodec.encodeDataEvent(data) else {
            logger.warning("Dropping non-UTF8 SSE payload", metadata: ["bytes": "\(data.count)"])
            return
        }
        channel.eventLoop.execute {
            guard channel.isActive else { return }
            var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
            buffer.writeString(payload)
            _ = channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
        }
    }

    package func logRequest(_ request: HTTPHandler.RequestLogContext) {
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

    package func logResponse(
        _ request: HTTPHandler.RequestLogContext,
        status: HTTPResponseStatus,
        sessionID: String?
    ) {
        var metadata: Logger.Metadata = [
            "id": .string(request.id),
            "method": .string(request.method),
            "path": .string(request.path),
            "status": .string("\(status.code)"),
        ]
        if let remote = request.remoteAddress {
            metadata["remote"] = .string(remote)
        }
        if let sessionID {
            metadata["session"] = .string(sessionID)
        }
        logger.info("HTTP response", metadata: metadata)
    }

    private func sendResponseData(
        on channel: Channel,
        data: Data,
        prefersEventStream: Bool,
        keepAlive: Bool,
        sessionID: String,
        requestLog: HTTPHandler.RequestLogContext
    ) {
        if prefersEventStream {
            sendSingleSSE(
                on: channel,
                data: data,
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
        } else {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            sendJSON(
                on: channel,
                buffer: buffer,
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
        }
    }

    private func sendErrorPayload(
        on channel: Channel,
        data: Data,
        prefersEventStream: Bool,
        keepAlive: Bool,
        sessionID: String,
        requestLog: HTTPHandler.RequestLogContext
    ) {
        if prefersEventStream {
            sendSingleSSE(
                on: channel,
                data: data,
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
        } else {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            sendJSON(
                on: channel,
                buffer: buffer,
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
        }
    }
}
