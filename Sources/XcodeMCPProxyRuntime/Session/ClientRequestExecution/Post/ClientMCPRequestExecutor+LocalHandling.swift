import Foundation
import NIO
import NIOFoundationCompat
import XcodeMCPCore

extension ClientMCPRequestExecutor {
    func resolveLocalHandling(
        _ handling: LocalPostHandling,
        prefersEventStream: Bool,
        eventLoop: EventLoop
    ) -> EventLoopFuture<ClientMCPRequestExecutor.Resolution> {
        switch handling {
        case .pendingResponse(let future, let sessionID, let errorSessionID, let originalID, _):
            return future.map { buffer in
                var buffer = buffer
                guard let data = buffer.readData(length: buffer.readableBytes) else {
                    return .plain(
                        status: .badGateway,
                        body: "invalid upstream response",
                        sessionID: sessionID
                    )
                }
                return .responseData(
                    data: data,
                    sessionID: Self.isJSONRPCErrorResponse(data) ? errorSessionID : sessionID,
                    prefersEventStream: prefersEventStream
                )
            }.flatMapError { error in
                let mapped = ControlPlane.ErrorMapper.jsonRPCError(for: error)
                return eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: originalID,
                        code: mapped.code,
                        message: mapped.message,
                        sessionID: errorSessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }

        case .immediateResponse(let data, let sessionID):
            return eventLoop.makeSucceededFuture(
                .responseData(
                    data: data,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )

        case .mcpError(let id, let code, let message, let sessionID):
            return eventLoop.makeSucceededFuture(
                .mcpError(
                    id: id,
                    code: code,
                    message: message,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }
    }

    private static func isJSONRPCErrorResponse(_ data: Data) -> Bool {
        guard let object = try? JSONRPC.Wire.object(fromData: data), object["error"] != nil else {
            return false
        }
        return JSONRPC.Message.Inspector.responseID(from: object) != nil
    }
}
