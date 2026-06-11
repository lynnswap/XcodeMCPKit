import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOHTTP1
import ProxyCore
import ProxyMCP
import ProxyXcodeFeatures
import ProxyXcodeSupport
import ProxySession

extension HTTPPostService {
    package static func topLevelRequestTimeoutOverride(
        method: String?,
        defaultSeconds: TimeInterval
    ) -> TimeAmount? {
        MCPMethodDispatcher.timeoutForMethod(method, defaultSeconds: defaultSeconds)
    }

    package static func minimumRequestTimeout(
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

    package static func timeoutDeadline(for timeout: TimeAmount?) -> Date? {
        guard let timeout else { return nil }
        let seconds = Double(timeout.nanoseconds) / 1_000_000_000
        return Date().addingTimeInterval(seconds)
    }

    package static func remainingRequestTimeout(until deadline: Date?) -> TimeAmount? {
        guard let deadline else { return nil }
        let remainingSeconds = deadline.timeIntervalSinceNow
        guard remainingSeconds > 0 else { return nil }
        let remainingNanoseconds = Int64((remainingSeconds * 1_000_000_000).rounded(.up))
        return .nanoseconds(remainingNanoseconds)
    }

    package static func makeRequestTimeoutResponseData(
        requestIDs: [RPCID],
        forceBatchArray: Bool
    ) -> Data? {
        makeJSONRPCErrorResponseData(
            ids: requestIDs,
            code: -32000,
            message: "upstream timeout",
            forceBatchArray: forceBatchArray
        )
    }

    package static func makeMissingInitializeResolution(
        parsedRequestJSON: Any,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        sessionID: String,
        prefersEventStream: Bool
    ) -> HTTPPostResolution? {
        guard requestRequiresInitialize(parsedRequestJSON) else {
            return nil
        }

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

    package static func requestRequiresInitialize(_ parsedRequestJSON: Any) -> Bool {
        if let object = parsedRequestJSON as? [String: Any] {
            let method = object["method"] as? String
            let expectsResponse = object["id"] != nil
            return method != "initialize" || !expectsResponse
        }
        if parsedRequestJSON is [Any] {
            return true
        }
        return false
    }

    package static func makeLocalResponseResolution(
        responseData: Data?,
        sessionID: String,
        prefersEventStream: Bool,
        emptyStatus: HTTPResponseStatus
    ) -> HTTPPostResolution {
        guard let responseData else {
            return .empty(status: emptyStatus, sessionID: sessionID)
        }
        return .responseData(
            data: responseData,
            sessionID: sessionID,
            prefersEventStream: prefersEventStream
        )
    }

    package static func makePartialBatchErrorResolution(
        localResponseData: Data?,
        responseIDs: [RPCID],
        code: Int,
        message: String,
        sessionID: String,
        prefersEventStream: Bool,
        forceBatchArray: Bool,
        fallbackStatus: HTTPResponseStatus,
        fallbackBody: String
    ) -> HTTPPostResolution {
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
            + responseIDs.map { makeJSONRPCErrorResponseObject(id: $0, code: code, message: message) }
        guard JSONSerialization.isValidJSONObject(mergedObjects),
            let responseData = try? JSONSerialization.data(
                withJSONObject: mergedObjects,
                options: []
            )
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

    package static func mergeLocalBatchResponses(
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

        return (try? JSONSerialization.data(withJSONObject: mergedObjects, options: []))
            ?? responseData
    }

    package static func mergeBatchResponsePayloads(
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
        guard JSONSerialization.isValidJSONObject(payload) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    package static func responseDataForBatchResolution(
        _ resolution: HTTPPostResolution?,
        fallbackRequestIDs: [RPCID],
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

    package static func makeBlockedToolResponseObjects(
        requestObject: [String: Any],
        toolName: String
    ) -> [[String: Any]] {
        guard let requestID = requestObject["id"], let rpcID = RPCID(any: requestID) else {
            return []
        }
        return [makeToolResultErrorResponseObject(id: rpcID, toolName: toolName)]
    }

    package static func makeToolResultErrorResponseObject(
        id: RPCID,
        toolName: String
    ) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id.value.foundationObject,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": "tool '\(toolName)' is disabled by proxy config",
                    ]
                ],
                "isError": true,
            ],
        ]
    }

    package static func makeJSONRPCErrorResponseObject(
        id: RPCID,
        code: Int,
        message: String
    ) -> [String: Any] {
        makeJSONRPCErrorResponseObject(
            id: id.value.foundationObject,
            code: code,
            message: message
        )
    }

    package static func makeJSONRPCErrorResponseObject(
        id: Any,
        code: Int,
        message: String
    ) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message,
            ],
        ]
    }

    package static func makeJSONRPCErrorResponseData(
        ids: [RPCID],
        code: Int,
        message: String,
        forceBatchArray: Bool
    ) -> Data? {
        let objects = ids.map { makeJSONRPCErrorResponseObject(id: $0, code: code, message: message) }
        guard !objects.isEmpty else {
            return nil
        }
        let payload: Any = (forceBatchArray || objects.count > 1) ? objects : objects[0]
        guard JSONSerialization.isValidJSONObject(payload) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    package static func makeToolResponseData(
        from responseObjects: [[String: Any]],
        forceBatchArray: Bool
    ) -> Data? {
        guard responseObjects.isEmpty == false else {
            return nil
        }
        let payload: Any = (forceBatchArray || responseObjects.count > 1)
            ? responseObjects
            : responseObjects[0]
        guard JSONSerialization.isValidJSONObject(payload) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    package static func responseObjects(from responseData: Data) -> [[String: Any]] {
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

    package static func mapDocumentationSearchError(_ error: Error) -> (code: Int, message: String) {
        if error is UpstreamSlotAcquisitionError {
            return (-32001, "upstream unavailable")
        }
        if let error = error as? ControlPlaneRequestError {
            return mapDocumentationSearchError(error.underlying)
        }
        if let error = error as? ControlPlaneError {
            switch error {
            case .invalidResponse:
                return (-32000, "upstream timeout")
            case .upstreamRPC(let code, let message):
                return (code, message)
            }
        }
        return (-32000, "upstream timeout")
    }

    package static func extractResponseIDs(from requestJSON: Any) -> [RPCID] {
        if let object = requestJSON as? [String: Any] {
            guard let rawID = object["id"], let rpcID = RPCID(any: rawID) else {
                return []
            }
            return [rpcID]
        }

        guard let array = requestJSON as? [Any] else {
            return []
        }
        return array.compactMap { item in
            guard let object = item as? [String: Any],
                let rawID = object["id"]
            else {
                return nil
            }
            return RPCID(any: rawID)
        }
    }
}
