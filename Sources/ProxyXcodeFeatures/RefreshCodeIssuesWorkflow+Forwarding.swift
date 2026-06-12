import Foundation
import Logging
import NIO
import ProxyCore
import ProxyMCP
import ProxyXcodeSupport

extension RefreshCodeIssuesWorkflow {
    /// Every proxy-mode bail-out funnels through here: record the debug
    /// step, log the reason, and return nil so the caller falls back to a
    /// plain upstream refresh.
    private func fallBackToUpstream(
        reason: String,
        state: String? = nil,
        extraMetadata: [String: String] = [:],
        debugRequestID: String,
        logMetadata: Logger.Metadata
    ) -> Data? {
        var debugMetadata = extraMetadata
        debugMetadata["fallback_reason"] = reason
        debugState.updateStep(
            requestID: debugRequestID,
            step: "proxy.fallback_to_upstream",
            state: state,
            metadata: debugMetadata
        )
        var mergedLogMetadata = logMetadata
        mergedLogMetadata["fallback_reason"] = .string(reason)
        for (key, value) in extraMetadata {
            mergedLogMetadata[key] = .string(value)
        }
        logger.debug(
            "Refresh code issues proxy mode fell back to upstream refresh",
            metadata: mergedLogMetadata
        )
        return nil
    }

    package func runProxyRefresh(
        refreshRequest: RefreshCodeIssuesRequest,
        sessionID: String,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        eventLoop: EventLoop,
        baseMetadata: Logger.Metadata,
        executionBudget: ExecutionBudget,
        debugRequestID: String,
        windowsProvider: WindowsProvider,
        internalUpstreamChooser: InternalUpstreamChooser,
        internalToolCaller: InternalToolCaller
    ) async throws -> Data? {
        debugState.updateStep(
            requestID: debugRequestID,
            step: "proxy.select_internal_upstream"
        )
        try Self.throwIfCancelled(
            debugState: debugState,
            requestID: debugRequestID
        )

        guard let internalUpstreamIndex = await internalUpstreamChooser(sessionID) else {
            return fallBackToUpstream(
                reason: "internal upstream unavailable",
                debugRequestID: debugRequestID,
                logMetadata: baseMetadata
            )
        }
        try Self.throwIfCancelled(
            debugState: debugState,
            requestID: debugRequestID
        )

        let resolution = try await targetResolver.resolve(
            tabIdentifier: refreshRequest.tabIdentifier,
            filePath: refreshRequest.filePath,
            sessionID: sessionID,
            eventLoop: eventLoop,
            windowsProvider: { sessionID, eventLoop in
                let timeout = executionBudget.stepTimeout(
                    cappedAt: windowLookupTimeoutSeconds,
                    reserving: Self.minimumUpstreamFallbackBudgetSeconds
                )
                if timeout == nil, executionBudget.hasDeadline {
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
                return try await windowsProvider(
                    sessionID,
                    eventLoop,
                    internalUpstreamIndex,
                    timeout
                )
            }
        )
        let metadata = baseMetadata.merging(
            [
                "workspace_path": Logger.MetadataValue.string(resolution.workspacePath ?? "none"),
                "requested_file_path": Logger.MetadataValue.string(refreshRequest.filePath ?? "none"),
                "resolved_file_path": Logger.MetadataValue.string(resolution.resolvedFilePath ?? "none"),
                "internal_upstream": Logger.MetadataValue.string("\(internalUpstreamIndex)"),
            ],
            uniquingKeysWith: { _, new in new }
        )

        guard let target = resolution.target else {
            return fallBackToUpstream(
                reason: resolution.failureReason ?? "unknown",
                extraMetadata: [
                    "workspace_path": resolution.workspacePath ?? "none",
                    "resolved_file_path": resolution.resolvedFilePath ?? "none",
                ],
                debugRequestID: debugRequestID,
                logMetadata: metadata
            )
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
        if navigatorIssuesTimeout == nil, executionBudget.hasDeadline {
            return fallBackToUpstream(
                reason: executionBudget.isExhausted
                    ? "execution budget exhausted before navigator issues"
                    : "reserved upstream fallback budget before navigator issues",
                state: executionBudget.isExhausted ? "timed_out" : nil,
                debugRequestID: debugRequestID,
                logMetadata: metadata
            )
        }
        try Self.throwIfCancelled(
            debugState: debugState,
            requestID: debugRequestID
        )
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
            return fallBackToUpstream(
                reason: "navigator issues timed out",
                state: "timed_out",
                extraMetadata: ["resolved_target": target.resolvedFilePath],
                debugRequestID: debugRequestID,
                logMetadata: metadata
            )
        case .cancelled:
            throw CancellationError()
        case .unavailable:
            return fallBackToUpstream(
                reason: "navigator issues unavailable",
                extraMetadata: ["resolved_target": target.resolvedFilePath],
                debugRequestID: debugRequestID,
                logMetadata: metadata
            )
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
            return fallBackToUpstream(
                reason: "navigator issues payload malformed",
                extraMetadata: ["resolved_target": target.resolvedFilePath],
                debugRequestID: debugRequestID,
                logMetadata: metadata
            )
        }

        debugState.updateStep(
            requestID: debugRequestID,
            step: "proxy.encode_response",
            metadata: ["resolved_target": target.resolvedFilePath]
        )
        guard let responseID = requestIDs.first,
            let responseData = Self.makeToolResponseData(
                id: responseID,
                result: filteredNavigatorResult,
                forceBatchArray: requestIsBatch
            )
        else {
            return fallBackToUpstream(
                reason: "invalid proxy response encoding",
                extraMetadata: ["resolved_target": target.resolvedFilePath],
                debugRequestID: debugRequestID,
                logMetadata: metadata
            )
        }

        debugState.updateStep(
            requestID: debugRequestID,
            step: "proxy.success",
            metadata: ["resolved_target": target.resolvedFilePath]
        )
        logger.debug(
            "Refresh code issues served via proxy navigator issues",
            metadata: metadata.merging(
                ["resolved_target": Logger.MetadataValue.string(target.resolvedFilePath)],
                uniquingKeysWith: { _, new in new }
            )
        )
        return responseData
    }

    package func runForwardAttempts(
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
                ["attempt": Logger.MetadataValue.string("\(attempt)")],
                uniquingKeysWith: { _, new in new }
            )
            let retryDelayNanos =
                attemptIndex < Self.retryDelaysNanos.count ? Self.retryDelaysNanos[attemptIndex] : nil
            let result = await forwarder(
                bodyData,
                sessionID,
                requestIDs,
                requestIsBatch,
                {
                    guard let retryDelayNanos else { return false }
                    return executionBudget.canDelay(retryDelayNanos)
                },
                eventLoop,
                attemptTimeout
            )

            switch result {
            case .success(let responseData):
                let retryable = Self.isRetryableRefreshCodeIssuesFailure(responseData)
                if retryable, let delayNanos = retryDelayNanos {
                    if !executionBudget.canDelay(delayNanos) {
                        debugState.updateStep(
                            requestID: debugRequestID,
                            step: "upstream.retry_budget_exhausted"
                        )
                        finalResult = .success(responseData)
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
                            ["delay_ms": Logger.MetadataValue.string("\(delayNanos / 1_000_000)")],
                            uniquingKeysWith: { _, new in new }
                        )
                    )
                    do {
                        try await Task.sleep(nanoseconds: delayNanos)
                    } catch is CancellationError {
                        debugState.updateStep(
                            requestID: debugRequestID,
                            step: "cancelled",
                            state: "cancelled"
                        )
                        finalResult = .cancelled(responseIDs: requestIDs, isBatch: requestIsBatch)
                        break resultLoop
                    } catch {
                        continue
                    }
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
            case .cancelled:
                finalResult = result
                break resultLoop
            }
        }

        return finalResult
    }

}
