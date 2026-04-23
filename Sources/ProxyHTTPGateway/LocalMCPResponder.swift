import Foundation
import Logging
import NIO
import ProxyCore
import ProxyMCP
import ProxyXcodeFeatures
import ProxySession

package enum LocalPostHandling {
    case initialize(
        future: EventLoopFuture<ByteBuffer>,
        sessionID: String,
        originalID: RPCID
    )
    case immediateResponse(data: Data, sessionID: String)
    case mcpError(id: RPCID?, code: Int, message: String, sessionID: String)
}

package struct LocalMCPResponder {
    private let sessionManager: any RuntimeCoordinating
    private let refreshCodeIssuesMode: RefreshCodeIssuesMode
    private let disabledToolNames: Set<String>
    private let logger: Logger

    package init(
        sessionManager: any RuntimeCoordinating,
        refreshCodeIssuesMode: RefreshCodeIssuesMode,
        disabledToolNames: Set<String>,
        logger: Logger
    ) {
        self.sessionManager = sessionManager
        self.refreshCodeIssuesMode = refreshCodeIssuesMode
        self.disabledToolNames = disabledToolNames
        self.logger = logger
    }

    package func handle(
        object: [String: Any],
        headerSessionID: String?,
        headerSessionExists: Bool,
        eventLoop: EventLoop
    ) -> LocalPostHandling? {
        guard let method = object["method"] as? String else {
            return nil
        }

        if method == "initialize" {
            guard let originalIDValue = object["id"], let originalID = RPCID(any: originalIDValue) else {
                return .mcpError(
                    id: nil,
                    code: -32600,
                    message: "missing id",
                    sessionID: headerSessionID ?? UUID().uuidString
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
            return .initialize(
                future: future,
                sessionID: sessionID,
                originalID: originalID
            )
        }

        if (method == "resources/list" || method == "resources/templates/list") && sessionManager.isInitialized() == false {
            guard let originalIDValue = object["id"], let originalID = RPCID(any: originalIDValue) else {
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
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalID.value.foundationObject,
                "result": result,
            ]
            guard JSONSerialization.isValidJSONObject(response),
                let data = try? JSONSerialization.data(withJSONObject: response, options: [])
            else {
                return nil
            }
            return .immediateResponse(data: data, sessionID: sessionID)
        }

        if method == "tools/list",
            let headerSessionID,
            sessionManager.isInitialized(),
            let cachedResult = sessionManager.cachedToolsListResult(),
            let originalIDValue = object["id"],
            let originalID = RPCID(any: originalIDValue)
        {
            if headerSessionExists == false {
                _ = sessionManager.session(id: headerSessionID)
            }
            let hasParams: Bool = {
                guard let params = object["params"] else { return false }
                return !(params is NSNull)
            }()
            logger.debug(
                "tools/list cache hit",
                metadata: [
                    "session": .string(headerSessionID),
                    "has_params": .string(hasParams ? "true" : "false"),
                ]
            )
            let rewrittenResult = RefreshCodeIssuesToolsListRewriter.rewriteResult(
                cachedResult,
                mode: refreshCodeIssuesMode,
                hiddenToolNames: disabledToolNames
            )
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalID.value.foundationObject,
                "result": rewrittenResult.foundationObject,
            ]
            guard JSONSerialization.isValidJSONObject(response),
                let data = try? JSONSerialization.data(withJSONObject: response, options: [])
            else {
                return nil
            }
            return .immediateResponse(data: data, sessionID: headerSessionID)
        }

        return nil
    }
}
