import Foundation
import NIO
import ProxyCore
import ProxyFeatureXcode
import ProxyRuntime

package struct MCPForwardingService: Sendable {
    package struct PreparedRequest: Sendable {
        package let transform: RequestTransform
        package let upstreamIndex: Int
    }

    package struct StartedRequest: Sendable {
        package let transform: RequestTransform
        package let upstreamIndex: Int
        package let future: EventLoopFuture<ByteBuffer>
    }

    package enum ResponseResolution: Sendable {
        case success(Data)
        case timeout
        case invalidUpstreamResponse
    }

    private let config: ProxyConfig
    private let sessionManager: any RuntimeCoordinating

    package init(config: ProxyConfig, sessionManager: any RuntimeCoordinating) {
        self.config = config
        self.sessionManager = sessionManager
    }

    package func prepareRequest(
        bodyData: Data,
        parsedRequestJSON: Any,
        sessionID: String,
        shouldPinUpstreamOverride: Bool? = nil,
        upstreamIndexOverride: Int? = nil
    ) throws -> PreparedRequest? {
        let upstreamIndex: Int
        if let upstreamIndexOverride {
            upstreamIndex = upstreamIndexOverride
        } else {
            let shouldPinUpstream =
                shouldPinUpstreamOverride ?? MCPMethodDispatcher.shouldPinUpstream(for: parsedRequestJSON)
            guard let chosen = sessionManager.chooseUpstreamIndex(
                sessionID: sessionID,
                shouldPin: shouldPinUpstream
            ) else {
                return nil
            }
            upstreamIndex = chosen
        }

        let transform = try RequestInspector.transform(
            bodyData,
            sessionID: sessionID,
            mapID: { sessionID, originalID in
                sessionManager.assignUpstreamID(
                    sessionID: sessionID,
                    originalID: originalID,
                    upstreamIndex: upstreamIndex
                )
            }
        )
        return PreparedRequest(transform: transform, upstreamIndex: upstreamIndex)
    }

    package func startRequest(
        _ prepared: PreparedRequest,
        session: SessionContext,
        on eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount? = nil
    ) throws -> StartedRequest {
        let requestTimeout =
            requestTimeoutOverride
            ?? MCPMethodDispatcher.timeoutForMethod(
                prepared.transform.method,
                defaultSeconds: config.requestTimeout
            )
        let future: EventLoopFuture<ByteBuffer>
        if prepared.transform.isBatch {
            future = session.router.registerBatch(on: eventLoop, timeout: requestTimeout)
        } else if let idKey = prepared.transform.idKey {
            future = session.router.registerRequest(
                idKey: idKey,
                on: eventLoop,
                timeout: requestTimeout
            )
        } else {
            struct MissingRequestIDError: Error {}
            throw MissingRequestIDError()
        }

        sessionManager.sendUpstream(
            prepared.transform.upstreamData,
            upstreamIndex: prepared.upstreamIndex
        )
        return StartedRequest(
            transform: prepared.transform,
            upstreamIndex: prepared.upstreamIndex,
            future: future
        )
    }

    package func resolveResponse(
        _ result: Result<ByteBuffer, Error>,
        started: StartedRequest,
        sessionID: String,
        accountSuccess: Bool = true,
        accountTimeout: Bool = true
    ) -> ResponseResolution {
        switch result {
        case .success(let buffer):
            var buffer = buffer
            guard let data = buffer.readData(length: buffer.readableBytes) else {
                return .invalidUpstreamResponse
            }
            let rewrittenResourcesData = Self.rewriteUnsupportedResourcesListResponseIfNeeded(
                method: started.transform.method,
                originalID: started.transform.originalID,
                upstreamData: data
            )
            let responseData = Self.rewriteToolsListResponseIfNeeded(
                method: started.transform.method,
                upstreamData: rewrittenResourcesData,
                mode: config.refreshCodeIssuesMode
            )
            if started.transform.isCacheableToolsListRequest,
                let object = try? JSONSerialization.jsonObject(with: responseData, options: [])
                    as? [String: Any],
                let resultAny = object["result"],
                let result = JSONValue(any: resultAny)
            {
                sessionManager.setCachedToolsListResult(result)
            }
            if accountSuccess, Self.shouldNotifyUpstreamSuccess(for: responseData) {
                for responseID in started.transform.responseIDs {
                    sessionManager.onRequestSucceeded(
                        sessionID: sessionID,
                        requestIDKey: responseID.key,
                        upstreamIndex: started.upstreamIndex
                    )
                }
            }
            return .success(responseData)

        case .failure:
            if let firstResponseID = started.transform.responseIDs.first {
                if accountTimeout {
                    sessionManager.onRequestTimeout(
                        sessionID: sessionID,
                        requestIDKey: firstResponseID.key,
                        upstreamIndex: started.upstreamIndex
                    )
                } else {
                    sessionManager.removeUpstreamIDMapping(
                        sessionID: sessionID,
                        requestIDKey: firstResponseID.key,
                        upstreamIndex: started.upstreamIndex
                    )
                }
                for responseID in started.transform.responseIDs.dropFirst() {
                    sessionManager.removeUpstreamIDMapping(
                        sessionID: sessionID,
                        requestIDKey: responseID.key,
                        upstreamIndex: started.upstreamIndex
                    )
                }
            }
            return .timeout
        }
    }

    package func callInternalTool(
        name: String,
        arguments: [String: Any],
        sessionID: String,
        eventLoop: EventLoop,
        upstreamIndexOverride: Int? = nil,
        requestTimeoutOverride: TimeAmount? = nil
    ) async -> RefreshInternalToolResult {
        let requestObject: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "__internal-\(UUID().uuidString)",
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments,
            ],
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestObject, options: [])
        else {
            return .unavailable
        }

        let prepared: PreparedRequest
        do {
            guard let candidate = try prepareRequest(
                bodyData: bodyData,
                parsedRequestJSON: requestObject,
                sessionID: sessionID,
                shouldPinUpstreamOverride: false,
                upstreamIndexOverride: upstreamIndexOverride
            ) else {
                return .unavailable
            }
            prepared = candidate
        } catch {
            return .unavailable
        }

        let session = sessionManager.session(id: sessionID)
        let started: StartedRequest
        do {
            started = try startRequest(
                prepared,
                session: session,
                on: eventLoop,
                requestTimeoutOverride: requestTimeoutOverride
            )
        } catch {
            return .unavailable
        }

        let resolution: ResponseResolution
        do {
            resolution = resolveResponse(
                .success(try await started.future.get()),
                started: started,
                sessionID: sessionID,
                accountSuccess: false,
                accountTimeout: false
            )
        } catch {
            resolution = resolveResponse(
                .failure(error),
                started: started,
                sessionID: sessionID,
                accountSuccess: false,
                accountTimeout: false
            )
        }

        switch resolution {
        case .success(let responseData):
            guard let object = try? JSONSerialization.jsonObject(with: responseData, options: [])
                as? [String: Any],
                let result = object["result"] as? [String: Any]
            else {
                return .unavailable
            }
            if let isError = result["isError"] as? Bool, isError {
                return .unavailable
            }
            return .success(result)
        case .timeout:
            return .timeout
        case .invalidUpstreamResponse:
            return .unavailable
        }
    }

    private static func rewriteUnsupportedResourcesListResponseIfNeeded(
        method: String?,
        originalID: RPCID?,
        upstreamData: Data
    ) -> Data {
        guard let method,
            method == "resources/list" || method == "resources/templates/list"
        else {
            return upstreamData
        }
        guard let originalID else { return upstreamData }

        let expectedKey = method == "resources/list" ? "resources" : "resourceTemplates"

        guard let object = try? JSONSerialization.jsonObject(with: upstreamData, options: [])
            as? [String: Any]
        else {
            return upstreamData
        }

        let result = object["result"]

        if let resultObject = result as? [String: Any], resultObject[expectedKey] is [Any] {
            return upstreamData
        }

        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? (error["code"] as? Int)
            guard code == -32601 else {
                return upstreamData
            }
            if let result,
                isNonStandardUnsupportedResourcesResult(result, method: method),
                let empty = emptyResourcesListResponseData(method: method, originalID: originalID)
            {
                return empty
            }
            return emptyResourcesListResponseData(method: method, originalID: originalID)
                ?? upstreamData
        }

        if let result,
            isNonStandardUnsupportedResourcesResult(result, method: method),
            let empty = emptyResourcesListResponseData(method: method, originalID: originalID)
        {
            return empty
        }

        return upstreamData
    }

    private static func isNonStandardUnsupportedResourcesResult(_ result: Any, method: String)
        -> Bool
    {
        guard let resultObject = result as? [String: Any] else {
            return false
        }
        guard let isError = resultObject["isError"] as? Bool, isError else {
            return false
        }
        guard let content = resultObject["content"] as? [Any], !content.isEmpty else {
            return false
        }

        let methodToken = method.lowercased()
        for item in content {
            guard let contentObject = item as? [String: Any],
                let text = contentObject["text"] as? String
            else {
                continue
            }
            let normalized = text.lowercased()
            if normalized.contains("unknown method"), normalized.contains(methodToken) {
                return true
            }
        }
        return false
    }

    private static func emptyResourcesListResponseData(method: String, originalID: RPCID)
        -> Data?
    {
        let result: [String: Any] = method == "resources/list"
            ? ["resources": [Any]()]
            : ["resourceTemplates": [Any]()]
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalID.value.foundationObject,
            "result": result,
        ]
        guard JSONSerialization.isValidJSONObject(response) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: response, options: [])
    }

    private static func rewriteToolsListResponseIfNeeded(
        method: String?,
        upstreamData: Data,
        mode: RefreshCodeIssuesMode
    ) -> Data {
        guard method == "tools/list" else {
            return upstreamData
        }
        return XcodeToolsListRewriter.rewriteResponseDataIfNeeded(
            upstreamData,
            mode: mode
        )
    }

    private static func shouldNotifyUpstreamSuccess(for responseData: Data) -> Bool {
        guard let any = try? JSONSerialization.jsonObject(with: responseData, options: []) else {
            return true
        }

        if let object = any as? [String: Any] {
            return isUpstreamOverloadedErrorResponse(object) == false
        }

        if let array = any as? [Any] {
            let objects = array.compactMap { $0 as? [String: Any] }
            guard objects.isEmpty == false else {
                return true
            }
            return objects.allSatisfy(isUpstreamOverloadedErrorResponse) == false
        }

        return true
    }

    private static func isUpstreamOverloadedErrorResponse(_ object: [String: Any]) -> Bool {
        guard let error = object["error"] as? [String: Any] else {
            return false
        }

        let code: Int?
        if let number = error["code"] as? NSNumber {
            code = number.intValue
        } else {
            code = error["code"] as? Int
        }
        guard code == -32002 else {
            return false
        }

        return (error["message"] as? String) == "upstream overloaded"
    }
}
