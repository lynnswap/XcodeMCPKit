import Foundation
import NIO
import NIOHTTP1
import ProxyCore

extension HTTPHandler {
    func sendPostResolution(
        _ resolution: HTTPPostResolution,
        on channel: Channel,
        keepAlive: Bool,
        requestLog: RequestLogContext
    ) {
        switch resolution {
        case .responseData(let data, let sessionID, let prefersEventStream):
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
                sendMCPError(
                    on: channel,
                    id: id,
                    code: code,
                    message: message,
                    prefersEventStream: prefersEventStream,
                    keepAlive: keepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            } else {
                sendMCPError(
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
            sendPlain(
                on: channel,
                status: status,
                body: body,
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
        case .empty(let status, let sessionID):
            sendEmpty(
                on: channel,
                status: status,
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
        }
    }

    func sendSingleSSE(on channel: Channel, data: Data, keepAlive: Bool, sessionID: String, requestLog: RequestLogContext) {
        responseWriter.sendSingleSSE(
            on: channel,
            data: data,
            keepAlive: keepAlive,
            sessionID: sessionID,
            requestLog: requestLog
        )
    }

    func sendJSON(on channel: Channel, buffer: ByteBuffer, keepAlive: Bool, sessionID: String, requestLog: RequestLogContext) {
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
    ) {
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
    ) {
        responseWriter.sendPlain(
            on: channel,
            status: status,
            body: body,
            keepAlive: keepAlive,
            sessionID: sessionID,
            requestLog: requestLog
        )
    }

    func sendEmpty(on channel: Channel, status: HTTPResponseStatus, keepAlive: Bool, sessionID: String, requestLog: RequestLogContext) {
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
        id: RPCID?,
        code: Int,
        message: String,
        prefersEventStream: Bool,
        keepAlive: Bool,
        sessionID: String,
        requestLog: RequestLogContext
    ) {
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

    func sendMCPError(
        on channel: Channel,
        ids: [RPCID],
        code: Int,
        message: String,
        forceBatchArray: Bool = false,
        prefersEventStream: Bool,
        keepAlive: Bool,
        sessionID: String,
        requestLog: RequestLogContext
    ) {
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
