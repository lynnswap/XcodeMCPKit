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
    package func resolveLocalHandling(
        _ handling: LocalPostHandling,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        forceBatchArray: Bool
    ) -> EventLoopFuture<HTTPPostResolution> {
        switch handling {
        case .pendingResponse(let future, let sessionID, let originalID):
            return future.map { buffer in
                var buffer = buffer
                guard let data = buffer.readData(length: buffer.readableBytes) else {
                    return .plain(
                        status: .badGateway,
                        body: "invalid upstream response",
                        sessionID: sessionID
                    )
                }
                let responseData = forceBatchArray
                    ? Self.forceBatchArrayResponseDataIfNeeded(data)
                    : data
                return .responseData(
                    data: responseData,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            }.flatMapError { _ in
                eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: originalID,
                        ids: [],
                        code: -32000,
                        message: "upstream timeout",
                        forceBatchArray: forceBatchArray,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }

        case .immediateResponse(let data, let sessionID):
            let responseData = forceBatchArray
                ? Self.forceBatchArrayResponseDataIfNeeded(data)
                : data
            return eventLoop.makeSucceededFuture(
                .responseData(
                    data: responseData,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )

        case .mcpError(let id, let code, let message, let sessionID):
            return eventLoop.makeSucceededFuture(
                .mcpError(
                    id: id,
                    ids: [],
                    code: code,
                    message: message,
                    forceBatchArray: forceBatchArray,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }
    }

    package static func localHandlingRequest(from parsedRequestJSON: Any?) -> (
        object: [String: Any], forceBatchArray: Bool
    )? {
        if let object = parsedRequestJSON as? [String: Any] {
            return (object, false)
        }
        guard let array = parsedRequestJSON as? [Any],
            array.count == 1,
            let object = array.first as? [String: Any]
        else {
            return nil
        }
        return (object, true)
    }

    package static func forceBatchArrayResponseDataIfNeeded(_ data: Data) -> Data {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return data
        }
        guard payload is [Any] == false,
            JSONSerialization.isValidJSONObject([payload])
        else {
            return data
        }
        return (try? JSONSerialization.data(withJSONObject: [payload], options: [])) ?? data
    }

    package func filterDisabledToolCalls(
        bodyData: Data,
        parsedRequestJSON: Any,
        forceBatchArray: Bool
    ) throws -> FilteredToolCallRequest {
        guard disabledToolNames.isEmpty == false else {
            return FilteredToolCallRequest(
                bodyData: bodyData,
                localResponseData: nil,
                forwardedResponseIDs: Self.extractResponseIDs(from: parsedRequestJSON),
                forceBatchArray: forceBatchArray
            )
        }

        if let object = parsedRequestJSON as? [String: Any] {
            guard let toolName = blockedToolName(from: object) else {
                return FilteredToolCallRequest(
                    bodyData: bodyData,
                    localResponseData: nil,
                    forwardedResponseIDs: Self.extractResponseIDs(from: parsedRequestJSON),
                    forceBatchArray: forceBatchArray
                )
            }

            return FilteredToolCallRequest(
                bodyData: nil,
                localResponseData: Self.makeToolResponseData(
                    from: Self.makeBlockedToolResponseObjects(
                        requestObject: object,
                        toolName: toolName
                    ),
                    forceBatchArray: forceBatchArray
                ),
                forwardedResponseIDs: [],
                forceBatchArray: forceBatchArray
            )
        }

        guard let array = parsedRequestJSON as? [Any] else {
            return FilteredToolCallRequest(
                bodyData: bodyData,
                localResponseData: nil,
                forwardedResponseIDs: [],
                forceBatchArray: forceBatchArray
            )
        }

        var forwardedObjects: [Any] = []
        forwardedObjects.reserveCapacity(array.count)
        var localResponseObjects: [[String: Any]] = []
        localResponseObjects.reserveCapacity(array.count)

        for item in array {
            guard let object = item as? [String: Any],
                let toolName = blockedToolName(from: object)
            else {
                forwardedObjects.append(item)
                continue
            }
            localResponseObjects.append(
                contentsOf: Self.makeBlockedToolResponseObjects(
                    requestObject: object,
                    toolName: toolName
                )
            )
        }

        let localResponseData = Self.makeToolResponseData(
            from: localResponseObjects,
            forceBatchArray: forceBatchArray
        )

        guard forwardedObjects.isEmpty == false else {
            return FilteredToolCallRequest(
                bodyData: nil,
                localResponseData: localResponseData,
                forwardedResponseIDs: [],
                forceBatchArray: forceBatchArray
            )
        }

        if localResponseData == nil {
            let filteredPayload: Any = (forceBatchArray || forwardedObjects.count > 1)
                ? forwardedObjects
                : forwardedObjects[0]
            let filteredBodyData = try JSONSerialization.data(
                withJSONObject: filteredPayload,
                options: []
            )
            return FilteredToolCallRequest(
                bodyData: filteredBodyData,
                localResponseData: nil,
                forwardedResponseIDs: Self.extractResponseIDs(from: filteredPayload),
                forceBatchArray: forceBatchArray
            )
        }

        let filteredBodyData = try JSONSerialization.data(
            withJSONObject: forwardedObjects,
            options: []
        )
        return FilteredToolCallRequest(
            bodyData: filteredBodyData,
            localResponseData: localResponseData,
            forwardedResponseIDs: Self.extractResponseIDs(from: forwardedObjects),
            forceBatchArray: forceBatchArray
        )
    }

    package func blockedToolName(from requestObject: [String: Any]) -> String? {
        guard let method = requestObject["method"] as? String,
            method == "tools/call",
            let params = requestObject["params"] as? [String: Any],
            let toolName = params["name"] as? String,
            disabledToolNames.contains(toolName)
        else {
            return nil
        }
        return toolName
    }

    package func refreshCodeIssuesRequest(from requestJSON: Any) -> RefreshCodeIssuesRequest? {
        if let object = requestJSON as? [String: Any] {
            return refreshCodeIssuesRequest(from: object)
        }

        guard let requests = requestJSON as? [Any],
            requests.count == 1,
            let object = requests.first as? [String: Any]
        else {
            return nil
        }
        return refreshCodeIssuesRequest(from: object)
    }

    package func refreshCodeIssuesRequest(from object: [String: Any]) -> RefreshCodeIssuesRequest? {
        guard
            let method = object["method"] as? String,
            method == "tools/call",
            let params = object["params"] as? [String: Any],
            let toolName = params["name"] as? String,
            toolName == RefreshCodeIssuesRequest.toolName
        else {
            return nil
        }

        let arguments = params["arguments"] as? [String: Any]
        let tabIdentifier = arguments?["tabIdentifier"] as? String
        let filePath = arguments?["filePath"] as? String
        return RefreshCodeIssuesRequest(tabIdentifier: tabIdentifier, filePath: filePath)
    }

    package func refreshRequestRouting(from requestJSON: Any) -> RefreshRequestRouting? {
        if let object = requestJSON as? [String: Any],
            let refreshRequest = refreshCodeIssuesRequest(from: object),
            let bodyData = try? JSONSerialization.data(withJSONObject: object, options: [])
        {
            return RefreshRequestRouting(
                refreshRoutes: [
                    RefreshRequestRoute(
                        request: refreshRequest,
                        bodyData: bodyData,
                        requestIDs: Self.extractResponseIDs(from: object),
                        requestIsBatch: false
                    )
                ],
                remainingBodyData: nil,
                remainingRequestIDs: [],
                remainingLocalResponseData: nil
            )
        }

        guard let requests = requestJSON as? [Any] else {
            return nil
        }
        var refreshRoutes: [RefreshRequestRoute] = []
        var remainingRequestObjects: [[String: Any]] = []
        var remainingInvalidResponseObjects: [[String: Any]] = []
        for item in requests {
            guard let object = item as? [String: Any] else {
                remainingInvalidResponseObjects.append(
                    Self.makeJSONRPCErrorResponseObject(
                        id: NSNull(),
                        code: -32600,
                        message: "invalid request"
                    )
                )
                continue
            }
            guard let candidate = refreshCodeIssuesRequest(from: object) else {
                remainingRequestObjects.append(object)
                continue
            }
            let payload: Any = requests.count == 1 ? requests : object
            guard let bodyData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                return nil
            }
            refreshRoutes.append(
                RefreshRequestRoute(
                    request: candidate,
                    bodyData: bodyData,
                    requestIDs: Self.extractResponseIDs(from: object),
                    requestIsBatch: requests.count == 1
                )
            )
        }
        guard !refreshRoutes.isEmpty else {
            return nil
        }

        let shouldKeepRemainingPayloadAsBatch = remainingInvalidResponseObjects.isEmpty == false
        let remainingPayload: Any? = {
            guard !remainingRequestObjects.isEmpty else { return nil }
            if remainingRequestObjects.count == 1,
                shouldKeepRemainingPayloadAsBatch == false
            {
                return remainingRequestObjects[0]
            }
            return remainingRequestObjects
        }()
        let remainingBodyData = remainingPayload.flatMap {
            try? JSONSerialization.data(withJSONObject: $0, options: [])
        }
        let remainingLocalResponseData = Self.makeToolResponseData(
            from: remainingInvalidResponseObjects,
            forceBatchArray: remainingInvalidResponseObjects.count > 1
        )
        return RefreshRequestRouting(
            refreshRoutes: refreshRoutes,
            remainingBodyData: remainingBodyData,
            remainingRequestIDs: Self.extractResponseIDs(from: remainingPayload as Any),
            remainingLocalResponseData: remainingLocalResponseData
        )
    }

}
