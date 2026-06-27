import Foundation
import NIO
import NIOHTTP1
import XcodeMCPCore
import XcodeMCPProcessRuntime
import XcodeMCPProxyRuntime

extension HTTPHandler {
    func sendPostResolution(
        _ resolution: ClientMCPRequestExecutor.Resolution,
        on channel: Channel,
        keepAlive: Bool,
        requestLog: RequestLogContext
    ) -> EventLoopFuture<Void> {
        switch resolution {
        case .responseData(let data, let sessionID, let prefersEventStream):
            if prefersEventStream {
                return sendSingleSSE(
                    on: channel,
                    data: data,
                    keepAlive: keepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            } else {
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                return sendJSON(
                    on: channel,
                    buffer: buffer,
                    keepAlive: keepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            }
        case .mcpError(
            let id,
            let ids,
            let code,
            let message,
            let forceBatchArray,
            let sessionID,
            let prefersEventStream
        ):
            if ids.isEmpty {
                return sendMCPError(
                    on: channel,
                    id: id,
                    code: code,
                    message: message,
                    forceBatchArray: forceBatchArray,
                    prefersEventStream: prefersEventStream,
                    keepAlive: keepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            } else {
                return sendMCPError(
                    on: channel,
                    ids: ids,
                    code: code,
                    message: message,
                    forceBatchArray: forceBatchArray,
                    prefersEventStream: prefersEventStream,
                    keepAlive: keepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            }
        case .plain(let status, let body, let sessionID):
            return sendPlain(
                on: channel,
                status: Self.httpStatus(from: status),
                body: body,
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
        case .empty(let status, let sessionID):
            return sendEmpty(
                on: channel,
                status: Self.httpStatus(from: status),
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
        }
    }

    private static func httpStatus(from status: ClientMCPRequestExecutor.Status) -> HTTPResponseStatus {
        switch status {
        case .ok:
            return .ok
        case .accepted:
            return .accepted
        case .badRequest:
            return .badRequest
        case .notFound:
            return .notFound
        case .unprocessableEntity:
            return .unprocessableEntity
        case .badGateway:
            return .badGateway
        case .serviceUnavailable:
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
        forceBatchArray: Bool = false,
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
            forceBatchArray: forceBatchArray,
            prefersEventStream: prefersEventStream,
            keepAlive: keepAlive,
            sessionID: sessionID,
            requestLog: requestLog
        )
    }

    func sendMCPError(
        on channel: Channel,
        ids: [JSONRPC.ID],
        code: Int,
        message: String,
        forceBatchArray: Bool = false,
        prefersEventStream: Bool,
        keepAlive: Bool,
        sessionID: String?,
        requestLog: RequestLogContext
    ) -> EventLoopFuture<Void> {
        responseWriter.sendMCPError(
            on: channel,
            ids: ids,
            code: code,
            message: message,
            forceBatchArray: forceBatchArray,
            prefersEventStream: prefersEventStream,
            keepAlive: keepAlive,
            sessionID: sessionID,
            requestLog: requestLog
        )
    }

    func sendSSE(to channel: Channel, data: Data) {
        responseWriter.sendSSE(to: channel, data: data)
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
