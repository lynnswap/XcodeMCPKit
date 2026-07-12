import Foundation
import NIO
import XcodeMCPKit

extension ClientMCPRequestExecutor {
    static func topLevelRequestTimeoutOverride(
        method: String?,
        defaultSeconds: TimeInterval
    ) -> TimeAmount? {
        MCP.MethodDispatcher.timeoutForMethod(method, defaultSeconds: defaultSeconds)
    }

    static func minimumRequestTimeout(
        _ lhs: TimeAmount?,
        _ rhs: TimeAmount?
    ) -> TimeAmount? {
        switch (lhs, rhs) {
        case (.none, .none):
            return nil
        case let (.some(value), .none), let (.none, .some(value)):
            return value
        case let (.some(lhs), .some(rhs)):
            return lhs.nanoseconds <= rhs.nanoseconds ? lhs : rhs
        }
    }

    func timeoutDeadline(for timeout: TimeAmount?) -> Date? {
        Self.timeoutDeadline(for: timeout, now: deadlineClock.now())
    }

    func remainingRequestTimeout(until deadline: Date?) -> TimeAmount? {
        Self.remainingRequestTimeout(until: deadline, now: deadlineClock.now())
    }

    static func timeoutDeadline(
        for timeout: TimeAmount?,
        now: Date = Date()
    ) -> Date? {
        guard let timeout else { return nil }
        let seconds = Double(timeout.nanoseconds) / 1_000_000_000
        return now.addingTimeInterval(seconds)
    }

    static func remainingRequestTimeout(
        until deadline: Date?,
        now: Date = Date()
    ) -> TimeAmount? {
        guard let deadline else { return nil }
        let remainingSeconds = deadline.timeIntervalSince(now)
        guard remainingSeconds > 0 else { return nil }
        return .nanoseconds(Int64((remainingSeconds * 1_000_000_000).rounded(.up)))
    }

    static func makeExpectedInitializeResolution(
        requestID: JSONRPC.ID?,
        sessionID: String,
        prefersEventStream: Bool
    ) -> ClientMCPRequestExecutor.Resolution {
        guard let requestID else {
            return .plain(
                status: .unprocessableEntity,
                body: "expected initialize request",
                sessionID: sessionID
            )
        }
        return .mcpError(
            id: requestID,
            code: -32000,
            message: "expected initialize request",
            sessionID: sessionID,
            prefersEventStream: prefersEventStream
        )
    }

    static func makeUpstreamUnavailableResolution(
        responseID: JSONRPC.ID?,
        sessionID: String,
        prefersEventStream: Bool
    ) -> ClientMCPRequestExecutor.Resolution {
        guard let responseID else {
            return .plain(
                status: .serviceUnavailable,
                body: "upstream unavailable",
                sessionID: sessionID
            )
        }
        return .mcpError(
            id: responseID,
            code: -32001,
            message: "upstream unavailable",
            sessionID: sessionID,
            prefersEventStream: prefersEventStream
        )
    }

    static func makeLocalResponseResolution(
        responseData: Data?,
        sessionID: String,
        prefersEventStream: Bool,
        emptyStatus: Status
    ) -> ClientMCPRequestExecutor.Resolution {
        guard let responseData else {
            return .empty(status: emptyStatus, sessionID: sessionID)
        }
        return .responseData(
            data: responseData,
            sessionID: sessionID,
            prefersEventStream: prefersEventStream
        )
    }

    static func makeToolResultErrorResponseObject(
        id: JSONRPC.ID,
        toolName: String
    ) -> [String: Any] {
        makeToolResultErrorResponseObject(
            id: id,
            message: "tool '\(toolName)' is disabled by proxy config"
        )
    }

    static func makeToolResultErrorResponseObject(
        id: JSONRPC.ID,
        message: String
    ) -> [String: Any] {
        JSONRPC.Wire.resultResponseObject(
            id: id,
            result: .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(message),
                    ])
                ]),
                "isError": .bool(true),
            ])
        )
    }

    static func makeBlockedToolResponseData(
        requestObject: [String: Any],
        toolName: String
    ) -> Data? {
        guard let id = JSONRPC.Message.Inspector.requestID(from: requestObject) else {
            return nil
        }
        return try? JSONRPC.Wire.data(
            from: makeToolResultErrorResponseObject(id: id, toolName: toolName)
        )
    }

    static func makeToolRoutingErrorResponseData(errors: [ToolRoutingError]) -> Data? {
        guard let error = errors.first else { return nil }
        return try? JSONRPC.Wire.data(
            from: makeToolResultErrorResponseObject(id: error.id, message: error.message)
        )
    }

    static func makeJSONRPCErrorResponseData(
        id: JSONRPC.ID?,
        code: Int,
        message: String
    ) -> Data? {
        try? JSONRPC.Wire.errorResponseData(id: id, code: code, message: message)
    }

    static func makeJSONRPCResultResponseData(
        id: JSONRPC.ID,
        result: JSONValue
    ) -> Data? {
        try? JSONRPC.Wire.resultResponseData(id: id, result: result)
    }

    static func extractResponseID(from requestJSON: Any) -> JSONRPC.ID? {
        guard let object = requestJSON as? [String: Any] else { return nil }
        return JSONRPC.Message.Inspector.requestID(from: object)
    }
}
