import Foundation
import NIO
import NIOHTTP1
import ProxyCore

enum MCPResponseEmitter {
    static func sendJSON(
        on channel: Channel,
        buffer: ByteBuffer,
        keepAlive: Bool,
        sessionID: String?
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        if let sessionID {
            headers.add(name: "Mcp-Session-Id", value: sessionID)
        }
        sendBuffer(on: channel, status: .ok, headers: headers, buffer: buffer, keepAlive: keepAlive)
    }

    static func sendSingleSSE(
        on channel: Channel,
        data: Data,
        keepAlive: Bool,
        sessionID: String
    ) -> Bool {
        guard let payload = SSECodec.encodeDataEvent(data) else {
            return false
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
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
        if !keepAlive {
            channel.close(promise: nil)
        }
        return true
    }

    static func sendPlain(
        on channel: Channel,
        status: HTTPResponseStatus,
        body: String,
        keepAlive: Bool,
        sessionID: String?
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        if let sessionID {
            headers.add(name: "Mcp-Session-Id", value: sessionID)
        }
        var buffer = channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        sendBuffer(on: channel, status: status, headers: headers, buffer: buffer, keepAlive: keepAlive)
    }

    static func sendEmpty(
        on channel: Channel,
        status: HTTPResponseStatus,
        keepAlive: Bool,
        sessionID: String
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Mcp-Session-Id", value: sessionID)
        sendBuffer(on: channel, status: status, headers: headers, buffer: nil, keepAlive: keepAlive)
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
}
