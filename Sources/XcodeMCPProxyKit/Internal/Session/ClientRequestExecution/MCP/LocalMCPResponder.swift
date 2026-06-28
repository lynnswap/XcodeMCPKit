import Foundation
import Logging
import NIO
import XcodeMCPKit

enum LocalPostHandling {
    case pendingResponse(
        future: EventLoopFuture<ByteBuffer>,
        sessionID: String,
        errorSessionID: String?,
        originalID: JSONRPC.ID
    )
    case immediateResponse(data: Data, sessionID: String)
    case mcpError(id: JSONRPC.ID?, code: Int, message: String, sessionID: String?)
}

struct LocalMCPResponder {
    private typealias LocalResultOperation = @Sendable () async throws -> JSONValue

    private let sessionManager: any RuntimeClientLocalMCPResponderPort
    private let refreshCodeIssuesMode: ProxyConfig.RefreshCodeIssuesMode
    private let disabledToolNames: Set<String>
    private let eventLoopCompletionExecutor: EventLoopCompletionExecutor
    private let logger: Logger

    init(
        sessionManager: any RuntimeClientLocalMCPResponderPort,
        refreshCodeIssuesMode: ProxyConfig.RefreshCodeIssuesMode,
        disabledToolNames: Set<String>,
        eventLoopCompletionExecutor: EventLoopCompletionExecutor = .eventLoop,
        logger: Logger
    ) {
        self.sessionManager = sessionManager
        self.refreshCodeIssuesMode = refreshCodeIssuesMode
        self.disabledToolNames = disabledToolNames
        self.eventLoopCompletionExecutor = eventLoopCompletionExecutor
        self.logger = logger
    }

    func toolsListResponseData(
        object: [String: Any],
        sessionID: String,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> Data {
        guard let originalID = JSONRPC.Message.Inspector.requestID(from: object) else {
            throw ControlPlane.Error.invalidResponse("missing id")
        }
        let result = try await sessionManager.sharedToolsList(
            sessionID: sessionID,
            requestTimeoutOverride: requestTimeoutOverride
        )
        let rewrittenResult = RefreshCodeIssues.ToolsListRewriter.rewriteResult(
            result,
            mode: refreshCodeIssuesMode,
            hiddenToolNames: disabledToolNames
        )
        return try Self.encodeResultData(id: originalID, result: rewrittenResult)
    }

    func handle(
        object: [String: Any],
        headerSessionID: String?,
        headerSessionExists: Bool,
        eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount? = nil
    ) -> LocalPostHandling? {
        guard let method = JSONRPC.Message.Inspector.method(from: object) else {
            return nil
        }

        if method == "initialize" {
            guard let originalID = JSONRPC.Message.Inspector.requestID(from: object) else {
                return .mcpError(
                    id: nil,
                    code: -32600,
                    message: "missing id",
                    sessionID: headerSessionID
                )
            }
            let sessionID = headerSessionID ?? UUID().uuidString
            _ = sessionManager.session(id: sessionID)
            let future = sessionManager.registerInitialize(
                sessionID: sessionID,
                originalID: originalID,
                requestObject: object,
                on: eventLoop
            )
            return .pendingResponse(
                future: future,
                sessionID: sessionID,
                errorSessionID: nil,
                originalID: originalID
            )
        }

        if (method == "resources/list" || method == "resources/templates/list") && sessionManager.isInitialized() == false {
            guard let originalID = JSONRPC.Message.Inspector.requestID(from: object) else {
                return .mcpError(
                    id: nil,
                    code: -32600,
                    message: "missing id",
                    sessionID: headerSessionID ?? UUID().uuidString
                )
            }

            let sessionID = headerSessionID ?? UUID().uuidString
            if let headerSessionID, headerSessionExists == false {
                _ = sessionManager.session(id: headerSessionID)
            }

            let result: [String: Any] = (method == "resources/list")
                ? ["resources": [Any]()]
                : ["resourceTemplates": [Any]()]
            guard let resultValue = JSONValue(any: result),
                let data = try? JSONRPC.Wire.resultResponseData(
                    id: originalID,
                    result: resultValue
                )
            else {
                return nil
            }
            return .immediateResponse(data: data, sessionID: sessionID)
        }

        if method == "tools/list",
            let headerSessionID,
            sessionManager.isInitialized(),
            let originalID = JSONRPC.Message.Inspector.requestID(from: object)
        {
            if headerSessionExists == false {
                _ = sessionManager.session(id: headerSessionID)
            }
            let sessionManager = self.sessionManager
            let refreshCodeIssuesMode = self.refreshCodeIssuesMode
            let hiddenToolNames = disabledToolNames
            return handleLocalResult(
                originalID: originalID,
                sessionID: headerSessionID,
                eventLoop: eventLoop
            ) {
                let result = try await sessionManager.sharedToolsList(
                    sessionID: headerSessionID,
                    requestTimeoutOverride: requestTimeoutOverride
                )
                return RefreshCodeIssues.ToolsListRewriter.rewriteResult(
                    result,
                    mode: refreshCodeIssuesMode,
                    hiddenToolNames: hiddenToolNames
                )
            }
        }

        if method == "tools/call",
            let headerSessionID,
            sessionManager.isInitialized(),
            let originalID = JSONRPC.Message.Inspector.requestID(from: object),
            let params = object["params"] as? [String: Any],
            let toolName = params["name"] as? String,
            toolName == "XcodeListWindows",
            disabledToolNames.contains(toolName) == false
        {
            if headerSessionExists == false {
                _ = sessionManager.session(id: headerSessionID)
            }
            let sessionManager = self.sessionManager
            return handleLocalResult(
                originalID: originalID,
                sessionID: headerSessionID,
                eventLoop: eventLoop
            ) {
                try await sessionManager.liveXcodeListWindowsResult(
                    route: .anyHealthy,
                    requestTimeoutOverride: requestTimeoutOverride
                )
            }
        }

        return nil
    }

    private func handleLocalResult(
        originalID: JSONRPC.ID,
        sessionID: String,
        eventLoop: EventLoop,
        operation: @escaping LocalResultOperation
    ) -> LocalPostHandling {
        let promise = eventLoop.makePromise(of: ByteBuffer.self)
        Task {
            do {
                let result = try await operation()
                let buffer = try Self.encodeResultBuffer(id: originalID, result: result)
                eventLoopCompletionExecutor.execute(on: eventLoop) {
                    promise.succeed(buffer)
                }
            } catch {
                do {
                    let buffer = try Self.encodeErrorBuffer(id: originalID, error: error)
                    eventLoopCompletionExecutor.execute(on: eventLoop) {
                        promise.succeed(buffer)
                    }
                } catch {
                    eventLoopCompletionExecutor.execute(on: eventLoop) {
                        promise.fail(error)
                    }
                }
            }
        }
        return .pendingResponse(
            future: promise.futureResult,
            sessionID: sessionID,
            errorSessionID: sessionID,
            originalID: originalID
        )
    }

    private static func encodeResultData(
        id: JSONRPC.ID,
        result: JSONValue
    ) throws -> Data {
        try JSONRPC.Wire.resultResponseData(id: id, result: result)
    }

    private static func encodeResultBuffer(
        id: JSONRPC.ID,
        result: JSONValue
    ) throws -> ByteBuffer {
        let data = try encodeResultData(id: id, result: result)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    private static func encodeErrorBuffer(
        id: JSONRPC.ID,
        error: Error
    ) throws -> ByteBuffer {
        let data = try encodeErrorData(id: id, error: error)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    private static func encodeErrorData(
        id: JSONRPC.ID,
        error: Error
    ) throws -> Data {
        let mapped = ControlPlane.ErrorMapper.jsonRPCError(for: error)
        return try JSONRPC.Wire.errorResponseData(
            id: id,
            code: mapped.code,
            message: mapped.message
        )
    }

}
