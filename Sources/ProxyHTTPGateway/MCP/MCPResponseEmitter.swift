import Foundation
import NIO
import NIOHTTP1
import ProxyCore
import ProxyMCP

enum MCPResponseEmitter {
    enum EmitterError: Error {
        case invalidEventStreamPayload
    }

    static func sendJSON(
        on channel: Channel,
        buffer: ByteBuffer,
        keepAlive: Bool,
        sessionID: String?
    ) -> EventLoopFuture<Void> {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        if let sessionID {
            headers.add(name: "Mcp-Session-Id", value: sessionID)
        }
        return sendBuffer(on: channel, status: .ok, headers: headers, buffer: buffer, keepAlive: keepAlive)
    }

    static func sendSingleSSE(
        on channel: Channel,
        data: Data,
        keepAlive: Bool,
        sessionID: String
    ) -> EventLoopFuture<Void> {
        guard let payload = SSECodec.encodeDataEvent(data) else {
            return channel.eventLoop.makeFailedFuture(EmitterError.invalidEventStreamPayload)
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Mcp-Session-Id", value: sessionID)

        var head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        head.headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        channel.write(HTTPServerResponsePart.head(head), promise: nil)

        var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
        buffer.writeString(payload)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: promise)
        if !keepAlive {
            promise.futureResult.whenComplete { _ in
                channel.close(promise: nil)
            }
        }
        return promise.futureResult
    }

    static func sendPlain(
        on channel: Channel,
        status: HTTPResponseStatus,
        body: String,
        keepAlive: Bool,
        sessionID: String?
    ) -> EventLoopFuture<Void> {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        if let sessionID {
            headers.add(name: "Mcp-Session-Id", value: sessionID)
        }
        var buffer = channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        return sendBuffer(on: channel, status: status, headers: headers, buffer: buffer, keepAlive: keepAlive)
    }

    static func sendEmpty(
        on channel: Channel,
        status: HTTPResponseStatus,
        keepAlive: Bool,
        sessionID: String
    ) -> EventLoopFuture<Void> {
        var headers = HTTPHeaders()
        headers.add(name: "Mcp-Session-Id", value: sessionID)
        return sendBuffer(on: channel, status: status, headers: headers, buffer: nil, keepAlive: keepAlive)
    }

    private static func sendBuffer(
        on channel: Channel,
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        buffer: ByteBuffer?,
        keepAlive: Bool
    ) -> EventLoopFuture<Void> {
        var headers = headers
        headers.replaceOrAdd(
            name: "Content-Length",
            value: "\(buffer?.readableBytes ?? 0)"
        )
        var head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        head.headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        if let buffer {
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: promise)
        if !keepAlive {
            promise.futureResult.whenComplete { _ in
                channel.close(promise: nil)
            }
        }
        return promise.futureResult
    }
}
