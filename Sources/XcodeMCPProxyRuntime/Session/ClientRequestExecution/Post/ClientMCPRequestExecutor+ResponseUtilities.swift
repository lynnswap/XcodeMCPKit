import Foundation
import NIO
import XcodeMCPCore

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

    static func requestLabel(from requestJSON: Any) -> String {
        guard let object = requestJSON as? [String: Any] else { return "unknown" }
        let method = (object["method"] as? String) ?? "unknown"
        if method == "tools/call",
            let params = object["params"] as? [String: Any],
            let name = params["name"] as? String
        {
            return "\(method):\(name)"
        }
        return method
    }

    static func topLevelRequestDescriptor(
        sessionID: String,
        parsedRequestJSON: Any,
        responseID: JSONRPC.ID?
    ) -> SessionRequestPipeline.Descriptor {
        SessionRequestPipeline.Descriptor(
            sessionID: sessionID,
            label: requestLabel(from: parsedRequestJSON),
            expectsResponse: responseID != nil,
            isTopLevelClientRequest: true
        )
    }

    func makeImmediateLeaseResolution(
        _ resolution: ClientMCPRequestExecutor.Resolution,
        leaseID: LeaseManager.ID,
        eventLoop: EventLoop,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle?
    ) -> EventLoopFuture<ClientMCPRequestExecutor.Resolution> {
        cancellationHandle?.markCompleted()
        sessionManager.completeRequestLease(leaseID)
        return eventLoop.makeSucceededFuture(resolution)
    }

    func cancel(
        _ handle: ClientMCPRequestExecutor.CancellationHandle,
        source: ClientMCPRequestExecutor.CancellationSource = .channelInactive
    ) {
        logger.debug(
            "Cancelling top-level upstream request",
            metadata: [
                "lease_id": .string(handle.leaseID.uuidString),
                "session": .string(handle.sessionID),
                "cancellation_source": .string(source.rawValue),
                "request_ids": .string(handle.requestIDKeys.joined(separator: ",")),
            ]
        )
        handle.cancel(using: sessionManager)
    }
}
