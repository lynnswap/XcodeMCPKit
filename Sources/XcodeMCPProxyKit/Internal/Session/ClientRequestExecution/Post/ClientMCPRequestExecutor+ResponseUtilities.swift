import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import XcodeMCPCore
import XcodeMCPProcessRuntime

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
        let remainingNanoseconds = Int64((remainingSeconds * 1_000_000_000).rounded(.up))
        return .nanoseconds(remainingNanoseconds)
    }

    static func makeRequestTimeoutResponseData(
        requestIDs: [JSONRPC.ID],
        forceBatchArray: Bool
    ) -> Data? {
        makeJSONRPCErrorResponseData(
            ids: requestIDs,
            code: -32000,
            message: "upstream timeout",
            forceBatchArray: forceBatchArray
        )
    }

    static func makeMissingInitializeResolution(
        parsedRequestJSON: Any,
        requestIDs: [JSONRPC.ID],
        requestIsBatch: Bool,
        sessionID: String,
        prefersEventStream: Bool
    ) -> ClientMCPRequestExecutor.Resolution? {
        guard requestRequiresInitialize(parsedRequestJSON) else {
            return nil
        }
        return makeExpectedInitializeResolution(
            requestIDs: requestIDs,
            requestIsBatch: requestIsBatch,
            sessionID: sessionID,
            prefersEventStream: prefersEventStream
        )
    }

    /// The one canonical "upstream unavailable" resolution: a partial batch
    /// keeps any locally-produced responses, a plain request degrades to 503.
    static func makeUpstreamUnavailableResolution(
        localResponseData: Data?,
        responseIDs: [JSONRPC.ID],
        forceBatchArray: Bool,
        requestIsBatch: Bool,
        sessionID: String,
        prefersEventStream: Bool
    ) -> ClientMCPRequestExecutor.Resolution {
        if localResponseData != nil {
            return makePartialBatchErrorResolution(
                localResponseData: localResponseData,
                responseIDs: responseIDs,
                code: -32001,
                message: "upstream unavailable",
                sessionID: sessionID,
                prefersEventStream: prefersEventStream,
                forceBatchArray: forceBatchArray,
                fallbackStatus: .serviceUnavailable,
                fallbackBody: "upstream unavailable"
            )
        }
        if responseIDs.isEmpty {
            return .plain(
                status: .serviceUnavailable,
                body: "upstream unavailable",
                sessionID: sessionID
            )
        }
        return .mcpError(
            id: nil,
            ids: responseIDs,
            code: -32001,
            message: "upstream unavailable",
            forceBatchArray: requestIsBatch,
            sessionID: sessionID,
            prefersEventStream: prefersEventStream
        )
    }

    /// The one canonical "expected initialize request" rejection shape.
    static func makeExpectedInitializeResolution(
        requestIDs: [JSONRPC.ID],
        requestIsBatch: Bool,
        sessionID: String,
        prefersEventStream: Bool
    ) -> ClientMCPRequestExecutor.Resolution {
        if requestIDs.isEmpty {
            return .plain(
                status: .unprocessableEntity,
                body: "expected initialize request",
                sessionID: sessionID
            )
        }
        return .mcpError(
            id: nil,
            ids: requestIDs,
            code: -32000,
            message: "expected initialize request",
            forceBatchArray: requestIsBatch,
            sessionID: sessionID,
            prefersEventStream: prefersEventStream
        )
    }

    static func requestRequiresInitialize(_ parsedRequestJSON: Any) -> Bool {
        if let object = parsedRequestJSON as? [String: Any] {
            if case .request("initialize", _) = JSONRPC.Message.Inspector.kind(of: object) {
                return false
            }
            return true
        }
        if parsedRequestJSON is [Any] {
            return true
        }
        return false
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

    static func makePartialBatchErrorResolution(
        localResponseData: Data?,
        responseIDs: [JSONRPC.ID],
        code: Int,
        message: String,
        sessionID: String,
        prefersEventStream: Bool,
        forceBatchArray: Bool,
        fallbackStatus: Status,
        fallbackBody: String
    ) -> ClientMCPRequestExecutor.Resolution {
        guard let localResponseData else {
            if responseIDs.isEmpty {
                return .plain(
                    status: fallbackStatus,
                    body: fallbackBody,
                    sessionID: sessionID
                )
            }
            return .mcpError(
                id: nil,
                ids: responseIDs,
                code: code,
                message: message,
                forceBatchArray: forceBatchArray,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        }

        guard let localPayload = try? JSONSerialization.jsonObject(
            with: localResponseData,
            options: []
        ) else {
            if responseIDs.isEmpty {
                return .plain(
                    status: fallbackStatus,
                    body: fallbackBody,
                    sessionID: sessionID
                )
            }
            return .mcpError(
                id: nil,
                ids: responseIDs,
                code: code,
                message: message,
                forceBatchArray: forceBatchArray,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        }

        let localResponseObjects: [Any]
        if let array = localPayload as? [Any] {
            localResponseObjects = array
        } else if let object = localPayload as? [String: Any] {
            localResponseObjects = [object]
        } else {
            localResponseObjects = []
        }

        let mergedObjects =
            localResponseObjects
            + responseIDs.map { JSONRPC.Wire.errorResponseObject(id: $0, code: code, message: message) }
        guard let responseData = try? JSONRPC.Wire.data(from: mergedObjects)
        else {
            if responseIDs.isEmpty {
                return .plain(
                    status: fallbackStatus,
                    body: fallbackBody,
                    sessionID: sessionID
                )
            }
            return .mcpError(
                id: nil,
                ids: responseIDs,
                code: code,
                message: message,
                forceBatchArray: forceBatchArray,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        }

        return .responseData(
            data: responseData,
            sessionID: sessionID,
            prefersEventStream: prefersEventStream
        )
    }

    static func mergeLocalBatchResponses(
        into responseData: Data,
        localResponseData: Data?
    ) -> Data {
        guard let localResponseData,
            let localPayload = try? JSONSerialization.jsonObject(
                with: localResponseData,
                options: []
            )
        else {
            return responseData
        }

        guard let any = try? JSONSerialization.jsonObject(with: responseData, options: []) else {
            return responseData
        }

        let mergedObjects: [Any]
        let localResponseObjects: [Any]
        if let array = localPayload as? [Any] {
            localResponseObjects = array
        } else if let object = localPayload as? [String: Any] {
            localResponseObjects = [object]
        } else {
            localResponseObjects = []
        }

        if let array = any as? [Any] {
            mergedObjects = array + localResponseObjects
        } else if let object = any as? [String: Any] {
            mergedObjects = [object] + localResponseObjects
        } else {
            return responseData
        }

        return (try? JSONRPC.Wire.data(from: mergedObjects)) ?? responseData
    }

    static func mergeLocalToolResponseData(
        _ localResponseData: Data?,
        into resolution: ClientMCPRequestExecutor.Resolution,
        fallbackRequestIDs: [JSONRPC.ID],
        forceBatchArray: Bool,
        sessionID: String,
        prefersEventStream: Bool
    ) -> ClientMCPRequestExecutor.Resolution {
        guard localResponseData != nil else {
            return resolution
        }
        let forwardedResponseData = responseDataForBatchResolution(
            resolution,
            fallbackRequestIDs: fallbackRequestIDs,
            forceBatchArray: forceBatchArray
        )
        let mergedData = mergeBatchResponsePayloads(
            [
                forwardedResponseData,
                localResponseData,
            ],
            forceBatchArray: forceBatchArray
        )
        return makeLocalResponseResolution(
            responseData: mergedData,
            sessionID: sessionID,
            prefersEventStream: prefersEventStream,
            emptyStatus: .accepted
        )
    }

    static func mergeBatchResponsePayloads(
        _ payloads: [Data?],
        forceBatchArray: Bool
    ) -> Data? {
        let objects = payloads.compactMap { $0 }.flatMap { data -> [Any] in
            guard let payload = try? JSONSerialization.jsonObject(with: data, options: []) else {
                return []
            }
            if let array = payload as? [Any] {
                return array
            }
            if let object = payload as? [String: Any] {
                return [object]
            }
            return []
        }
        guard !objects.isEmpty else {
            return nil
        }
        let payload: Any = (forceBatchArray || objects.count > 1) ? objects : objects[0]
        return try? JSONRPC.Wire.data(from: payload)
    }

    static func responseDataForBatchResolution(
        _ resolution: ClientMCPRequestExecutor.Resolution?,
        fallbackRequestIDs: [JSONRPC.ID],
        forceBatchArray: Bool
    ) -> Data? {
        guard let resolution else {
            return nil
        }
        switch resolution {
        case .responseData(let data, _, _):
            return data
        case .mcpError(_, let ids, let code, let message, let batch, _, _):
            return makeJSONRPCErrorResponseData(
                ids: ids.isEmpty ? fallbackRequestIDs : ids,
                code: code,
                message: message,
                forceBatchArray: batch || forceBatchArray
            )
        case .plain(_, let body, _):
            return makeJSONRPCErrorResponseData(
                ids: fallbackRequestIDs,
                code: -32000,
                message: body.isEmpty ? "request failed" : body,
                forceBatchArray: forceBatchArray
            )
        case .empty:
            return nil
        }
    }

    static func makeBlockedToolResponseObjects(
        requestObject: [String: Any],
        toolName: String
    ) -> [[String: Any]] {
        guard let rpcID = JSONRPC.Message.Inspector.requestID(from: requestObject) else {
            return []
        }
        return [makeToolResultErrorResponseObject(id: rpcID, toolName: toolName)]
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

    static func makeJSONRPCErrorResponseObject(
        id: JSONRPC.ID,
        code: Int,
        message: String
    ) -> [String: Any] {
        JSONRPC.Wire.errorResponseObject(id: id, code: code, message: message)
    }

    static func makeJSONRPCErrorResponseObject(
        id: Any,
        code: Int,
        message: String
    ) -> [String: Any] {
        JSONRPC.Wire.errorResponseObject(
            idValue: JSONValue(any: id),
            error: .init(code: code, message: message)
        )
    }

    static func makeJSONRPCErrorResponseData(
        ids: [JSONRPC.ID],
        code: Int,
        message: String,
        forceBatchArray: Bool
    ) -> Data? {
        try? JSONRPC.Wire.errorResponseData(
            ids: ids,
            code: code,
            message: message,
            forceBatchArray: forceBatchArray,
            includeNullIDWhenEmpty: false
        )
    }

    static func makeJSONRPCResultResponseObject(
        id: JSONRPC.ID,
        result: JSONValue
    ) -> [String: Any] {
        JSONRPC.Wire.resultResponseObject(id: id, result: result)
    }

    static func makeJSONRPCResultResponseData(
        ids: [JSONRPC.ID],
        result: JSONValue,
        forceBatchArray: Bool
    ) -> Data? {
        try? JSONRPC.Wire.resultResponseData(
            ids: ids,
            result: result,
            forceBatchArray: forceBatchArray
        )
    }

    static func makeToolResponseData(
        from responseObjects: [[String: Any]],
        forceBatchArray: Bool
    ) -> Data? {
        guard responseObjects.isEmpty == false else {
            return nil
        }
        return try? JSONRPC.Wire.responsePayloadData(
            objects: responseObjects,
            forceBatchArray: forceBatchArray
        )
    }

    static func makeToolRoutingErrorResponseData(
        errors: [ToolRoutingError],
        forceBatchArray: Bool
    ) -> Data? {
        makeToolResponseData(
            from: errors.map { error in
                makeToolResultErrorResponseObject(
                    id: error.id,
                    message: error.message
                )
            },
            forceBatchArray: forceBatchArray
        )
    }

    static func responseObjects(from responseData: Data) -> [[String: Any]] {
        guard let payload = try? JSONSerialization.jsonObject(with: responseData, options: []) else {
            return []
        }
        if let array = payload as? [[String: Any]] {
            return array
        }
        if let object = payload as? [String: Any] {
            return [object]
        }
        return []
    }

    static func extractResponseIDs(from requestJSON: Any) -> [JSONRPC.ID] {
        if let object = requestJSON as? [String: Any] {
            guard let rpcID = JSONRPC.Message.Inspector.requestID(from: object) else {
                return []
            }
            return [rpcID]
        }

        guard let array = requestJSON as? [Any] else {
            return []
        }
        return array.compactMap { item in
            guard let object = item as? [String: Any] else {
                return nil
            }
            return JSONRPC.Message.Inspector.requestID(from: object)
        }
    }
}
