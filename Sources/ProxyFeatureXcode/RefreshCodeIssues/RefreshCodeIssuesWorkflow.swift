import Foundation
import Logging
import NIO
import ProxyCore

package struct RefreshCodeIssuesRequest: Sendable {
    package static let toolName = "XcodeRefreshCodeIssuesInFile"
    package static let globalQueueKey = "__global__"

    package let tabIdentifier: String?
    package let filePath: String?

    package init(tabIdentifier: String?, filePath: String?) {
        self.tabIdentifier = tabIdentifier
        self.filePath = filePath
    }

    package var queueKey: String {
        guard let tabIdentifier, tabIdentifier.isEmpty == false else {
            return Self.globalQueueKey
        }
        return tabIdentifier
    }
}

package enum RefreshForwardAttemptResult: Sendable {
    case success(Data)
    case timeout(responseIDs: [RPCID], isBatch: Bool)
    case upstreamUnavailable(responseIDs: [RPCID], isBatch: Bool)
    case overloaded(responseIDs: [RPCID], isBatch: Bool)
    case invalidRequest
    case invalidUpstreamResponse
}

package enum RefreshInternalToolResult {
    case success([String: Any])
    case timeout
    case unavailable
}

package struct RefreshCodeIssuesWorkflow {
    package typealias WindowsProvider =
        @Sendable (
            _ sessionID: String,
            _ eventLoop: EventLoop,
            _ upstreamIndexOverride: Int?,
            _ requestTimeoutOverride: TimeAmount?
        ) async -> [XcodeWindowInfo]?
    package typealias InternalUpstreamChooser = @Sendable (_ sessionID: String) async -> Int?
    package typealias InternalToolCaller =
        @Sendable (
            _ name: String,
            _ arguments: [String: Any],
            _ sessionID: String,
            _ eventLoop: EventLoop,
            _ upstreamIndexOverride: Int?,
            _ requestTimeoutOverride: TimeAmount?
        ) async -> RefreshInternalToolResult
    package typealias Forwarder =
        @Sendable (
            _ bodyData: Data,
            _ sessionID: String,
            _ requestIDs: [RPCID],
            _ requestIsBatch: Bool,
            _ eventLoop: EventLoop,
            _ requestTimeoutOverride: TimeAmount?
        ) async -> RefreshForwardAttemptResult

    package static let retryDelaysNanos: [UInt64] = [
        200_000_000,
        500_000_000,
    ]
    package static let minimumUpstreamFallbackBudgetSeconds: TimeInterval = 0.05

    private struct ExecutionBudget: Sendable {
        let deadlineUptimeNs: UInt64?

        init(requestTimeout: TimeInterval) {
            if requestTimeout > 0 {
                let timeoutNs = Self.nanoseconds(from: requestTimeout)
                self.deadlineUptimeNs = DispatchTime.now().uptimeNanoseconds &+ timeoutNs
            } else {
                self.deadlineUptimeNs = nil
            }
        }

        func remainingNanoseconds() -> UInt64? {
            guard let deadlineUptimeNs else {
                return nil
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadlineUptimeNs {
                return 0
            }
            return deadlineUptimeNs - now
        }

        func remainingTimeout(
            cappedAt capSeconds: TimeInterval? = nil,
            reserving reserveSeconds: TimeInterval = 0
        ) -> TimeAmount? {
            guard let remainingNs = remainingNanoseconds() else {
                if let capSeconds {
                    return makeRequestTimeout(capSeconds)
                }
                return nil
            }
            let reservedNs = Self.nanoseconds(from: reserveSeconds)
            guard remainingNs > reservedNs else { return nil }

            var cappedNs = remainingNs - reservedNs
            if let capSeconds {
                cappedNs = min(cappedNs, Self.nanoseconds(from: capSeconds))
            }
            guard cappedNs > 0 else { return nil }

            let maxTimeAmountNs = UInt64(Int64.max)
            return .nanoseconds(Int64(min(cappedNs, maxTimeAmountNs)))
        }

        func stepTimeout(
            cappedAt capSeconds: TimeInterval,
            reserving reserveSeconds: TimeInterval = 0
        ) -> TimeAmount? {
            remainingTimeout(cappedAt: capSeconds, reserving: reserveSeconds)
        }

        func canDelay(_ delayNanoseconds: UInt64) -> Bool {
            guard let remainingNanoseconds = remainingNanoseconds() else {
                return true
            }
            return remainingNanoseconds > delayNanoseconds
        }

        var isExhausted: Bool {
            guard let remainingNanoseconds = remainingNanoseconds() else {
                return false
            }
            return remainingNanoseconds == 0
        }

        private static func nanoseconds(from interval: TimeInterval) -> UInt64 {
            let clamped = max(0, interval)
            let nanoseconds = clamped * 1_000_000_000
            if nanoseconds >= Double(UInt64.max) {
                return UInt64.max
            }
            return UInt64(nanoseconds.rounded(.up))
        }
    }

    private let mode: RefreshCodeIssuesMode
    private let requestTimeout: TimeInterval
    private let coordinator: RefreshCodeIssuesCoordinator
    private let targetResolver: RefreshCodeIssuesTargetResolver
    private let debugState: RefreshCodeIssuesDebugState
    private let windowLookupTimeoutSeconds: TimeInterval
    private let navigatorIssuesTimeoutSeconds: TimeInterval
    private let logger: Logger

    package init(
        mode: RefreshCodeIssuesMode,
        requestTimeout: TimeInterval,
        coordinator: RefreshCodeIssuesCoordinator,
        targetResolver: RefreshCodeIssuesTargetResolver,
        debugState: RefreshCodeIssuesDebugState,
        windowLookupTimeout: TimeInterval = 5,
        navigatorIssuesTimeout: TimeInterval = 15,
        logger: Logger
    ) {
        self.mode = mode
        self.requestTimeout = requestTimeout
        self.coordinator = coordinator
        self.targetResolver = targetResolver
        self.debugState = debugState
        self.windowLookupTimeoutSeconds = windowLookupTimeout
        self.navigatorIssuesTimeoutSeconds = navigatorIssuesTimeout
        self.logger = logger
    }

    package func run(
        refreshRequest: RefreshCodeIssuesRequest,
        bodyData: Data,
        sessionID: String,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        eventLoop: EventLoop,
        windowsProvider: WindowsProvider,
        internalUpstreamChooser: InternalUpstreamChooser,
        internalToolCaller: InternalToolCaller,
        forwarder: Forwarder
    ) async -> RefreshForwardAttemptResult {
        let debugRequestID = debugState.beginRequest(
            sessionID: sessionID,
            queueKey: refreshRequest.queueKey,
            tabIdentifier: refreshRequest.tabIdentifier,
            filePath: refreshRequest.filePath,
            mode: mode.rawValue
        )
        let baseMetadata: Logger.Metadata = [
            "session": .string(sessionID),
            "mode": .string(mode.rawValue),
            "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
            "queue_key": .string(refreshRequest.queueKey),
        ]

        do {
            return try await coordinator.withPermit(key: refreshRequest.queueKey) { permit in
                let queueMetadata: Logger.Metadata = [
                    "pending_for_key": .string("\(permit.pendingForKey)"),
                    "pending_total": .string("\(permit.pendingTotal)"),
                ]
                if permit.queuePosition > 0 {
                    logger.debug(
                        "Queued refresh code issues request",
                        metadata: baseMetadata.merging(
                            queueMetadata.merging(
                                ["queued_ahead": .string("\(permit.queuePosition)")],
                                uniquingKeysWith: { _, new in new }
                            ),
                            uniquingKeysWith: { _, new in new }
                        )
                    )
                }
                logger.debug(
                    "Dequeued refresh code issues request",
                    metadata: baseMetadata.merging(
                        queueMetadata,
                        uniquingKeysWith: { _, new in new }
                    )
                )

                debugState.markPermitAcquired(
                    requestID: debugRequestID,
                    queuePosition: permit.queuePosition,
                    pendingForKey: permit.pendingForKey,
                    pendingTotal: permit.pendingTotal
                )

                let executionBudget = ExecutionBudget(requestTimeout: requestTimeout)
                debugState.updateStep(
                    requestID: debugRequestID,
                    step: "execution_budget_started",
                    metadata: [
                        "execution_timeout_ms": Self.timeoutDescription(
                            executionBudget.remainingTimeout()
                        )
                    ]
                )

                let result: RefreshForwardAttemptResult
                if mode == .proxy,
                    let proxyResponseData = await runProxyRefresh(
                        refreshRequest: refreshRequest,
                        sessionID: sessionID,
                        requestIDs: requestIDs,
                        eventLoop: eventLoop,
                        baseMetadata: baseMetadata,
                        executionBudget: executionBudget,
                        debugRequestID: debugRequestID,
                        windowsProvider: windowsProvider,
                        internalUpstreamChooser: internalUpstreamChooser,
                        internalToolCaller: internalToolCaller
                    )
                {
                    debugState.updateStep(
                        requestID: debugRequestID,
                        step: "proxy.completed"
                    )
                    result = .success(proxyResponseData)
                } else {
                    result = await runForwardAttempts(
                        bodyData: bodyData,
                        sessionID: sessionID,
                        requestIDs: requestIDs,
                        requestIsBatch: requestIsBatch,
                        eventLoop: eventLoop,
                        baseMetadata: baseMetadata,
                        executionBudget: executionBudget,
                        debugRequestID: debugRequestID,
                        forwarder: forwarder
                    )
                }

                debugState.finishRequest(
                    requestID: debugRequestID,
                    outcome: Self.debugOutcome(for: result)
                )
                return result
            }
        } catch RefreshCodeIssuesCoordinator.AcquireError.queueLimitExceeded {
            logger.warning(
                "Rejected refresh code issues request because queue is full",
                metadata: [
                    "session": .string(sessionID),
                    "mode": .string(mode.rawValue),
                    "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
                    "queue_key": .string(refreshRequest.queueKey),
                ]
            )
            debugState.updateStep(
                requestID: debugRequestID,
                step: "queue_limit_exceeded"
            )
            debugState.finishRequest(
                requestID: debugRequestID,
                outcome: "queue_limit_exceeded"
            )
            return .overloaded(responseIDs: requestIDs, isBatch: requestIsBatch)
        } catch RefreshCodeIssuesCoordinator.AcquireError.queueWaitTimedOut {
            logger.warning(
                "Rejected refresh code issues request after queue wait timeout",
                metadata: [
                    "session": .string(sessionID),
                    "mode": .string(mode.rawValue),
                    "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
                    "queue_key": .string(refreshRequest.queueKey),
                ]
            )
            debugState.updateStep(
                requestID: debugRequestID,
                step: "queue_wait_timed_out"
            )
            debugState.finishRequest(
                requestID: debugRequestID,
                outcome: "queue_wait_timed_out"
            )
            return .overloaded(responseIDs: requestIDs, isBatch: requestIsBatch)
        } catch is CancellationError {
            logger.debug(
                "Cancelled queued refresh code issues request",
                metadata: [
                    "session": .string(sessionID),
                    "mode": .string(mode.rawValue),
                    "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
                    "queue_key": .string(refreshRequest.queueKey),
                ]
            )
            debugState.updateStep(
                requestID: debugRequestID,
                step: "cancelled",
                state: "cancelled"
            )
            debugState.finishRequest(
                requestID: debugRequestID,
                outcome: "cancelled"
            )
            return .overloaded(responseIDs: requestIDs, isBatch: requestIsBatch)
        } catch {
            debugState.updateStep(
                requestID: debugRequestID,
                step: "invalid_request",
                state: "failed"
            )
            debugState.finishRequest(
                requestID: debugRequestID,
                outcome: "invalid_request"
            )
            return .invalidRequest
        }
    }

    private func runProxyRefresh(
        refreshRequest: RefreshCodeIssuesRequest,
        sessionID: String,
        requestIDs: [RPCID],
        eventLoop: EventLoop,
        baseMetadata: Logger.Metadata,
        executionBudget: ExecutionBudget,
        debugRequestID: String,
        windowsProvider: WindowsProvider,
        internalUpstreamChooser: InternalUpstreamChooser,
        internalToolCaller: InternalToolCaller
    ) async -> Data? {
        debugState.updateStep(
            requestID: debugRequestID,
            step: "proxy.select_internal_upstream"
        )

        guard let internalUpstreamIndex = await internalUpstreamChooser(sessionID) else {
            let fallbackReason = "internal upstream unavailable"
            debugState.updateStep(
                requestID: debugRequestID,
                step: "proxy.fallback_to_upstream",
                metadata: ["fallback_reason": fallbackReason]
            )
            logger.debug(
                "Refresh code issues proxy mode fell back to upstream refresh",
                metadata: baseMetadata.merging(
                    ["fallback_reason": .string(fallbackReason)],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return nil
        }

        let resolution = await targetResolver.resolve(
            tabIdentifier: refreshRequest.tabIdentifier,
            filePath: refreshRequest.filePath,
            sessionID: sessionID,
            eventLoop: eventLoop,
            windowsProvider: { sessionID, eventLoop in
                let timeout = executionBudget.stepTimeout(
                    cappedAt: windowLookupTimeoutSeconds,
                    reserving: Self.minimumUpstreamFallbackBudgetSeconds
                )
                if timeout == nil {
                    self.debugState.updateStep(
                        requestID: debugRequestID,
                        step: executionBudget.isExhausted
                            ? "proxy.execution_budget_exhausted"
                            : "proxy.reserved_upstream_budget",
                        state: executionBudget.isExhausted ? "timed_out" : nil
                    )
                    return nil
                }
                self.debugState.updateStep(
                    requestID: debugRequestID,
                    step: "proxy.list_windows",
                    metadata: [
                        "internal_upstream": "\(internalUpstreamIndex)",
                        "timeout_ms": Self.timeoutDescription(timeout),
                    ]
                )
                return await windowsProvider(
                    sessionID,
                    eventLoop,
                    internalUpstreamIndex,
                    timeout
                )
            }
        )
        let metadata = baseMetadata.merging(
            [
                "workspace_path": .string(resolution.workspacePath ?? "none"),
                "requested_file_path": .string(refreshRequest.filePath ?? "none"),
                "resolved_file_path": .string(resolution.resolvedFilePath ?? "none"),
                "internal_upstream": .string("\(internalUpstreamIndex)"),
            ],
            uniquingKeysWith: { _, new in new }
        )

        guard let target = resolution.target else {
            let fallbackReason = resolution.failureReason ?? "unknown"
            debugState.updateStep(
                requestID: debugRequestID,
                step: "proxy.fallback_to_upstream",
                metadata: [
                    "fallback_reason": fallbackReason,
                    "workspace_path": resolution.workspacePath ?? "none",
                    "resolved_file_path": resolution.resolvedFilePath ?? "none",
                ]
            )
            logger.debug(
                "Refresh code issues proxy mode fell back to upstream refresh",
                metadata: metadata.merging(
                    ["fallback_reason": .string(fallbackReason)],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return nil
        }

        let arguments: [String: Any] = [
            "tabIdentifier": refreshRequest.tabIdentifier ?? "",
            "severity": "remark",
            "glob": "**/" + Self.escapeGlobLiteralPath(target.workspaceRelativePath),
        ]
        let navigatorIssuesTimeout = executionBudget.stepTimeout(
            cappedAt: navigatorIssuesTimeoutSeconds,
            reserving: Self.minimumUpstreamFallbackBudgetSeconds
        )
        if navigatorIssuesTimeout == nil {
            let fallbackReason = executionBudget.isExhausted
                ? "execution budget exhausted before navigator issues"
                : "reserved upstream fallback budget before navigator issues"
            debugState.updateStep(
                requestID: debugRequestID,
                step: "proxy.fallback_to_upstream",
                state: executionBudget.isExhausted ? "timed_out" : nil,
                metadata: ["fallback_reason": fallbackReason]
            )
            logger.debug(
                "Refresh code issues proxy mode fell back to upstream refresh",
                metadata: metadata.merging(
                    ["fallback_reason": .string(fallbackReason)],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return nil
        }
        debugState.updateStep(
            requestID: debugRequestID,
            step: "proxy.list_navigator_issues",
            metadata: [
                "internal_upstream": "\(internalUpstreamIndex)",
                "resolved_target": target.resolvedFilePath,
                "timeout_ms": Self.timeoutDescription(navigatorIssuesTimeout),
            ]
        )
        let navigatorToolResult = await internalToolCaller(
            "XcodeListNavigatorIssues",
            arguments,
            sessionID,
            eventLoop,
            internalUpstreamIndex,
            navigatorIssuesTimeout
        )
        let navigatorResult: [String: Any]
        switch navigatorToolResult {
        case .success(let result):
            navigatorResult = result
        case .timeout:
            let fallbackReason = "navigator issues timed out"
            debugState.updateStep(
                requestID: debugRequestID,
                step: "proxy.fallback_to_upstream",
                state: "timed_out",
                metadata: [
                    "fallback_reason": fallbackReason,
                    "resolved_target": target.resolvedFilePath,
                ]
            )
            logger.debug(
                "Refresh code issues proxy mode fell back to upstream refresh",
                metadata: metadata.merging(
                    [
                        "fallback_reason": .string(fallbackReason),
                        "resolved_target": .string(target.resolvedFilePath),
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return nil
        case .unavailable:
            let fallbackReason = "navigator issues unavailable"
            debugState.updateStep(
                requestID: debugRequestID,
                step: "proxy.fallback_to_upstream",
                metadata: [
                    "fallback_reason": fallbackReason,
                    "resolved_target": target.resolvedFilePath,
                ]
            )
            logger.debug(
                "Refresh code issues proxy mode fell back to upstream refresh",
                metadata: metadata.merging(
                    [
                        "fallback_reason": .string(fallbackReason),
                        "resolved_target": .string(target.resolvedFilePath),
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return nil
        }

        debugState.updateStep(
            requestID: debugRequestID,
            step: "proxy.filter_navigator_issues",
            metadata: ["resolved_target": target.resolvedFilePath]
        )
        guard let filteredNavigatorResult = Self.filterNavigatorIssuesResult(
            navigatorResult,
            matchingResolvedFilePath: target.resolvedFilePath
        ) else {
            let fallbackReason = "navigator issues payload malformed"
            debugState.updateStep(
                requestID: debugRequestID,
                step: "proxy.fallback_to_upstream",
                metadata: [
                    "fallback_reason": fallbackReason,
                    "resolved_target": target.resolvedFilePath,
                ]
            )
            logger.debug(
                "Refresh code issues proxy mode fell back to upstream refresh",
                metadata: metadata.merging(
                    [
                        "fallback_reason": .string(fallbackReason),
                        "resolved_target": .string(target.resolvedFilePath),
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return nil
        }

        debugState.updateStep(
            requestID: debugRequestID,
            step: "proxy.encode_response",
            metadata: ["resolved_target": target.resolvedFilePath]
        )
        guard let responseID = requestIDs.first,
            let responseData = Self.makeToolResponseData(
                id: responseID,
                result: filteredNavigatorResult
            )
        else {
            let fallbackReason = "invalid proxy response encoding"
            debugState.updateStep(
                requestID: debugRequestID,
                step: "proxy.fallback_to_upstream",
                metadata: [
                    "fallback_reason": fallbackReason,
                    "resolved_target": target.resolvedFilePath,
                ]
            )
            logger.debug(
                "Refresh code issues proxy mode fell back to upstream refresh",
                metadata: metadata.merging(
                    [
                        "fallback_reason": .string(fallbackReason),
                        "resolved_target": .string(target.resolvedFilePath),
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return nil
        }

        debugState.updateStep(
            requestID: debugRequestID,
            step: "proxy.success",
            metadata: ["resolved_target": target.resolvedFilePath]
        )
        logger.debug(
            "Refresh code issues served via proxy navigator issues",
            metadata: metadata.merging(
                ["resolved_target": .string(target.resolvedFilePath)],
                uniquingKeysWith: { _, new in new }
            )
        )
        return responseData
    }

    private func runForwardAttempts(
        bodyData: Data,
        sessionID: String,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        eventLoop: EventLoop,
        baseMetadata: Logger.Metadata,
        executionBudget: ExecutionBudget,
        debugRequestID: String,
        forwarder: Forwarder
    ) async -> RefreshForwardAttemptResult {
        var finalResult: RefreshForwardAttemptResult = .invalidRequest

        resultLoop: for attemptIndex in 0...Self.retryDelaysNanos.count {
            let attempt = attemptIndex + 1
            let attemptTimeout = executionBudget.remainingTimeout()
            if executionBudget.isExhausted {
                debugState.updateStep(
                    requestID: debugRequestID,
                    step: "upstream.execution_budget_exhausted",
                    state: "timed_out"
                )
                finalResult = .timeout(responseIDs: requestIDs, isBatch: requestIsBatch)
                break resultLoop
            }

            debugState.updateStep(
                requestID: debugRequestID,
                step: "upstream.attempt_\(attempt)",
                metadata: ["timeout_ms": Self.timeoutDescription(attemptTimeout)]
            )
            let attemptMetadata = baseMetadata.merging(
                ["attempt": .string("\(attempt)")],
                uniquingKeysWith: { _, new in new }
            )
            let result = await forwarder(
                bodyData,
                sessionID,
                requestIDs,
                requestIsBatch,
                eventLoop,
                attemptTimeout
            )

            switch result {
            case .success(let responseData):
                let retryable = Self.isRetryableRefreshCodeIssuesFailure(responseData)
                if retryable, attemptIndex < Self.retryDelaysNanos.count {
                    let delayNanos = Self.retryDelaysNanos[attemptIndex]
                    if !executionBudget.canDelay(delayNanos) {
                        debugState.updateStep(
                            requestID: debugRequestID,
                            step: "upstream.retry_budget_exhausted",
                            state: "timed_out"
                        )
                        finalResult = .timeout(responseIDs: requestIDs, isBatch: requestIsBatch)
                        break resultLoop
                    }
                    debugState.updateStep(
                        requestID: debugRequestID,
                        step: "upstream.retry_delay",
                        metadata: ["delay_ms": "\(delayNanos / 1_000_000)"]
                    )
                    logger.debug(
                        "Retrying refresh code issues request after error 5",
                        metadata: attemptMetadata.merging(
                            ["delay_ms": .string("\(delayNanos / 1_000_000)")],
                            uniquingKeysWith: { _, new in new }
                        )
                    )
                    try? await Task.sleep(nanoseconds: delayNanos)
                    continue
                }
                if retryable {
                    logger.debug(
                        "Refresh code issues request still failing after retries",
                        metadata: attemptMetadata
                    )
                }
                debugState.updateStep(
                    requestID: debugRequestID,
                    step: retryable ? "upstream.retry_exhausted" : "upstream.success"
                )
                finalResult = .success(responseData)
                break resultLoop
            case .timeout:
                debugState.updateStep(
                    requestID: debugRequestID,
                    step: "upstream.timeout",
                    state: "timed_out"
                )
                finalResult = result
                break resultLoop
            case .upstreamUnavailable:
                debugState.updateStep(
                    requestID: debugRequestID,
                    step: "upstream.unavailable",
                    state: "failed"
                )
                finalResult = result
                break resultLoop
            case .overloaded:
                debugState.updateStep(
                    requestID: debugRequestID,
                    step: "upstream.overloaded",
                    state: "failed"
                )
                finalResult = result
                break resultLoop
            case .invalidRequest:
                debugState.updateStep(
                    requestID: debugRequestID,
                    step: "upstream.invalid_request",
                    state: "failed"
                )
                finalResult = result
                break resultLoop
            case .invalidUpstreamResponse:
                debugState.updateStep(
                    requestID: debugRequestID,
                    step: "upstream.invalid_response",
                    state: "failed"
                )
                finalResult = result
                break resultLoop
            }
        }

        return finalResult
    }

    private static func makeToolResponseData(id: RPCID, result: [String: Any]) -> Data? {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.value.foundationObject,
            "result": result,
        ]
        guard JSONSerialization.isValidJSONObject(response) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: response, options: [])
    }

    private static func filterNavigatorIssuesResult(
        _ navigatorResult: [String: Any],
        matchingResolvedFilePath resolvedFilePath: String
    ) -> [String: Any]? {
        guard
            let structuredContent = navigatorResult["structuredContent"] as? [String: Any],
            let issues = structuredContent["issues"] as? [[String: Any]]
        else {
            return nil
        }

        let filteredIssues = issues.filter { issue in
            guard let path = issue["path"] as? String else { return false }
            return RefreshCodeIssuesPathMatcher.matches(
                issuePath: path,
                resolvedFilePath: resolvedFilePath
            )
        }

        var filteredStructuredContent = structuredContent
        filteredStructuredContent["issues"] = filteredIssues
        filteredStructuredContent["totalFound"] = filteredIssues.count

        var filteredResult = navigatorResult
        filteredResult["structuredContent"] = filteredStructuredContent

        let contentItem: [String: Any] = [
            "type": "text",
            "text": navigatorIssuesText(from: filteredStructuredContent),
        ]
        filteredResult["content"] = [contentItem]
        return filteredResult
    }

    private static func navigatorIssuesText(from structuredContent: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(structuredContent),
            let data = try? JSONSerialization.data(withJSONObject: structuredContent, options: []),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{\"issues\":[],\"totalFound\":0,\"truncated\":false}"
        }
        return text
    }

    private static func escapeGlobLiteralPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "[", with: "[[]")
            .replacingOccurrences(of: "]", with: "[]]")
            .replacingOccurrences(of: "*", with: "[*]")
            .replacingOccurrences(of: "?", with: "[?]")
    }

    private static func isRetryableRefreshCodeIssuesFailure(_ responseData: Data) -> Bool {
        let retryableErrorText = "SourceEditorCallableDiagnosticError error 5"
        guard
            let object = try? JSONSerialization.jsonObject(with: responseData, options: [])
                as? [String: Any],
            let result = object["result"] as? [String: Any],
            let isError = result["isError"] as? Bool,
            isError,
            let content = result["content"] as? [Any]
        else {
            return false
        }

        for item in content {
            guard let contentObject = item as? [String: Any],
                let text = contentObject["text"] as? String
            else {
                continue
            }
            if text.contains("Failed to retrieve diagnostics for"),
                text.contains(retryableErrorText)
            {
                return true
            }
        }

        return false
    }

    private static func timeoutDescription(_ timeout: TimeAmount?) -> String {
        guard let timeout else { return "none" }
        return "\(timeout.nanoseconds / 1_000_000)"
    }

    private static func debugOutcome(for result: RefreshForwardAttemptResult) -> String {
        switch result {
        case .success:
            return "success"
        case .timeout:
            return "timeout"
        case .upstreamUnavailable:
            return "upstream_unavailable"
        case .overloaded:
            return "overloaded"
        case .invalidRequest:
            return "invalid_request"
        case .invalidUpstreamResponse:
            return "invalid_upstream_response"
        }
    }
}
