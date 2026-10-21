import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import XcodeMCPCore
import XcodeMCPProxyRuntimeContract

/// The response to one POST request. The request's first progress notification opens it as an
/// event stream, which then carries the reply; without progress, the reply is sent as JSON.
final class HTTPPostResponse: Sendable {
    enum Event {
        /// The notification opens the stream.
        case opensStream
        case continuesStream
        /// The reply was sent, so the notification is dropped.
        case dropped
    }

    private enum Phase {
        case waiting
        case streaming
        case finished
    }

    private let phase = NIOLockedValueBox(Phase.waiting)

    func beginEvent() -> Event {
        phase.withLockedValue { phase in
            switch phase {
            case .waiting:
                phase = .streaming
                return .opensStream
            case .streaming:
                return .continuesStream
            case .finished:
                return .dropped
            }
        }
    }

    /// Marks the reply as sent, and returns whether progress opened the stream it goes on.
    func finish() -> Bool {
        phase.withLockedValue { phase in
            defer { phase = .finished }
            return phase == .streaming
        }
    }
}

extension HTTPHandler {
    func sendProgress(
        _ data: Data,
        in response: HTTPPostResponse,
        on channel: Channel,
        keepAlive: Bool,
        sessionID: String,
        requestLog: RequestLogContext
    ) {
        switch response.beginEvent() {
        case .dropped:
            return
        case .opensStream:
            logResponse(requestLog, status: .ok, sessionID: sessionID)
            MCPResponseEmitter.openEventStream(on: channel, keepAlive: keepAlive, sessionID: sessionID)
        case .continuesStream:
            // Progress only reports state, so a client that falls behind skips updates rather than
            // the server queueing them without bound.
            guard channel.isWritable else { return }
        }
        _ = MCPResponseEmitter.sendEvent(data, on: channel)
    }

    func sendPostResolution(
        _ resolution: ProxyRuntimeReply,
        in response: HTTPPostResponse,
        on channel: Channel,
        keepAlive: Bool,
        sessionID: String?,
        requestLog: RequestLogContext
    ) -> EventLoopFuture<Void> {
        if response.finish() {
            if case .response(let data) = resolution {
                _ = MCPResponseEmitter.sendEvent(data, on: channel)
            }
            return MCPResponseEmitter.endEventStream(on: channel, keepAlive: keepAlive)
        }
        switch resolution {
        case .response(let data):
            return sendJSONData(on: channel, data: data, keepAlive: keepAlive, sessionID: sessionID, requestLog: requestLog)
        case .accepted:
            return sendEmpty(on: channel, status: .accepted, keepAlive: keepAlive, sessionID: sessionID,
                             requestLog: requestLog)
        }
    }

    func sendJSON(on channel: Channel, buffer: ByteBuffer, keepAlive: Bool, sessionID: String?, requestLog: RequestLogContext) -> EventLoopFuture<Void> {
        responseWriter.sendJSON(
            on: channel,
            buffer: buffer,
            keepAlive: keepAlive,
            sessionID: sessionID,
            requestLog: requestLog
        )
    }

    func sendJSONData(
        on channel: Channel,
        data: Data,
        keepAlive: Bool,
        sessionID: String?,
        requestLog: RequestLogContext
    ) -> EventLoopFuture<Void> {
        responseWriter.sendJSONData(
            on: channel,
            data: data,
            keepAlive: keepAlive,
            sessionID: sessionID,
            requestLog: requestLog
        )
    }

    func sendPlain(
        on channel: Channel,
        status: HTTPResponseStatus,
        body: String,
        keepAlive: Bool,
        sessionID: String?,
        requestLog: RequestLogContext
    ) -> EventLoopFuture<Void> {
        responseWriter.sendPlain(
            on: channel,
            status: status,
            body: body,
            keepAlive: keepAlive,
            sessionID: sessionID,
            requestLog: requestLog
        )
    }

    func sendEmpty(on channel: Channel, status: HTTPResponseStatus, keepAlive: Bool, sessionID: String?, requestLog: RequestLogContext) -> EventLoopFuture<Void> {
        responseWriter.sendEmpty(
            on: channel,
            status: status,
            keepAlive: keepAlive,
            sessionID: sessionID,
            requestLog: requestLog
        )
    }

    func logRequest(_ request: RequestLogContext) {
        responseWriter.logRequest(request)
    }

    func logResponse(_ request: RequestLogContext, status: HTTPResponseStatus, sessionID: String?) {
        responseWriter.logResponse(request, status: status, sessionID: sessionID)
    }

    func remoteAddressString(for channel: Channel) -> String? {
        guard let address = channel.remoteAddress else {
            return nil
        }
        if let ip = address.ipAddress, let port = address.port {
            return "\(ip):\(port)"
        }
        return String(describing: address)
    }

    /// Debug endpoints can reset the runtime and expose payloads, so they need an explicit opt-in
    /// and a loopback listener.
    var debugEndpointsEnabled: Bool {
        guard config.enablesDebugEndpoints else { return false }
        switch config.listenHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "localhost", "127.0.0.1", "::1", "[::1]":
            return true
        default:
            return false
        }
    }
}
