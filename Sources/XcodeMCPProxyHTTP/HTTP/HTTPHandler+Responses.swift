import Foundation
import NIO
import NIOHTTP1
import XcodeMCPKit
import XcodeMCPProxyRuntime

extension HTTPHandler {
    func sendPostResolution(
        _ resolution: ProxyRuntimeReply,
        on channel: Channel,
        keepAlive: Bool,
        requestLog: RequestLogContext
    ) -> EventLoopFuture<Void> {
        switch resolution {
        case .response(let data, let sessionID, let prefersEventStream):
            if prefersEventStream {
                return sendSingleSSE(
                    on: channel,
                    data: data,
                    keepAlive: keepAlive,
                    sessionID: sessionID?.rawValue,
                    requestLog: requestLog
                )
            } else {
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                return sendJSON(
                    on: channel,
                    buffer: buffer,
                    keepAlive: keepAlive,
                    sessionID: sessionID?.rawValue,
                    requestLog: requestLog
                )
            }
        case .mcpError(
            let id,
            let code,
            let message,
            let sessionID,
            let prefersEventStream
        ):
            return sendMCPError(
                on: channel,
                id: id,
                code: code,
                message: message,
                prefersEventStream: prefersEventStream,
                keepAlive: keepAlive,
                sessionID: sessionID?.rawValue,
                requestLog: requestLog
            )
        case .failure(let kind, let body, let sessionID):
            return sendPlain(
                on: channel,
                status: Self.httpStatus(from: kind),
                body: body,
                keepAlive: keepAlive,
                sessionID: sessionID?.rawValue,
                requestLog: requestLog
            )
        case .accepted(let sessionID):
            return sendEmpty(
                on: channel,
                status: .accepted,
                keepAlive: keepAlive,
                sessionID: sessionID.rawValue,
                requestLog: requestLog
            )
        }
    }

    private static func httpStatus(from kind: ProxyRuntimeFailureKind) -> HTTPResponseStatus {
        switch kind {
        case .invalidRequest:
            return .badRequest
        case .sessionNotFound:
            return .notFound
        case .unprocessableRequest:
            return .unprocessableEntity
        case .invalidUpstreamResponse:
            return .badGateway
        case .runtimeUnavailable:
            return .serviceUnavailable
        }
    }

    func sendSingleSSE(on channel: Channel, data: Data, keepAlive: Bool, sessionID: String?, requestLog: RequestLogContext) -> EventLoopFuture<Void> {
        responseWriter.sendSingleSSE(
            on: channel,
            data: data,
            keepAlive: keepAlive,
            sessionID: sessionID,
            requestLog: requestLog
        )
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

    func sendEmpty(on channel: Channel, status: HTTPResponseStatus, keepAlive: Bool, sessionID: String, requestLog: RequestLogContext) -> EventLoopFuture<Void> {
        responseWriter.sendEmpty(
            on: channel,
            status: status,
            keepAlive: keepAlive,
            sessionID: sessionID,
            requestLog: requestLog
        )
    }

    func sendMCPError(
        on channel: Channel,
        id: JSONRPC.ID?,
        code: Int,
        message: String,
        prefersEventStream: Bool,
        keepAlive: Bool,
        sessionID: String?,
        requestLog: RequestLogContext
    ) -> EventLoopFuture<Void> {
        responseWriter.sendMCPError(
            on: channel,
            id: id,
            code: code,
            message: message,
            prefersEventStream: prefersEventStream,
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

    var isLoopbackDebugEndpointEnabled: Bool {
        switch config.listenHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "localhost", "127.0.0.1", "::1", "[::1]":
            return true
        default:
            return false
        }
    }
}
