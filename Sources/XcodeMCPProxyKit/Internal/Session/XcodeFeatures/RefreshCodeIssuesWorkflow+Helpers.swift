import Foundation
import Logging
import NIO
import XcodeMCPCore
import XcodeMCPProcessRuntime

extension RefreshCodeIssues.Workflow {
    static func makeToolResponseData(
        id: JSONRPC.ID,
        result: [String: Any],
        forceBatchArray: Bool
    ) -> Data? {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.value.foundationObject,
            "result": result,
        ]
        let payload: Any = forceBatchArray ? [response] : response
        guard JSONSerialization.isValidJSONObject(payload) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    static func filterNavigatorIssuesResult(
        _ navigatorResult: [String: Any],
        matchingResolvedFilePath resolvedFilePath: String
    ) -> [String: Any]? {
        guard
            let structuredContent = navigatorResult["structuredContent"] as? [String: Any],
            let issues = structuredContent["issues"] as? [[String: Any]]
        else {
            return nil
        }
        if (structuredContent["truncated"] as? Bool) == true {
            return nil
        }

        let filteredIssues = issues.filter { issue in
            guard let path = issue["path"] as? String else { return false }
            return RefreshCodeIssues.PathMatcher.matches(
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

    static func navigatorIssuesText(from structuredContent: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(structuredContent),
            let data = try? JSONSerialization.data(withJSONObject: structuredContent, options: []),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{\"issues\":[],\"totalFound\":0,\"truncated\":false}"
        }
        return text
    }

    static func escapeGlobLiteralPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "[", with: "[[]")
            .replacingOccurrences(of: "]", with: "[]]")
            .replacingOccurrences(of: "*", with: "[*]")
            .replacingOccurrences(of: "?", with: "[?]")
    }

    static func isRetryableRefreshCodeIssuesFailure(_ responseData: Data) -> Bool {
        let retryableErrorText = "SourceEditorCallableDiagnosticError error 5"
        guard let payload = try? JSONSerialization.jsonObject(with: responseData, options: []) else {
            return false
        }
        if let object = payload as? [String: Any] {
            return containsRetryableRefreshCodeIssuesFailure(
                in: object,
                retryableErrorText: retryableErrorText
            )
        }
        guard let array = payload as? [[String: Any]] else {
            return false
        }
        return array.contains {
            containsRetryableRefreshCodeIssuesFailure(
                in: $0,
                retryableErrorText: retryableErrorText
            )
        }
    }

    static func timeoutDescription(_ timeout: TimeAmount?) -> String {
        guard let timeout else { return "none" }
        return "\(timeout.nanoseconds / 1_000_000)"
    }

    static func debugOutcome(
        for result: RefreshCodeIssues.Workflow.ForwardAttemptResult
    ) -> RefreshCodeIssues.Outcome {
        switch result {
        case .success:
            return .success
        case .timeout:
            return .timeout
        case .upstreamUnavailable:
            return .upstreamUnavailable
        case .cancelled:
            return .cancelled
        case .invalidRequest:
            return .invalidRequest
        case .invalidUpstreamResponse:
            return .invalidUpstreamResponse
        }
    }

    static func containsRetryableRefreshCodeIssuesFailure(
        in responseObject: [String: Any],
        retryableErrorText: String
    ) -> Bool {
        guard let result = responseObject["result"] as? [String: Any],
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

    static func throwIfCancelled(
        debugState: RefreshCodeIssues.DebugState,
        requestID: String
    ) throws {
        guard !Task.isCancelled else {
            debugState.updateStep(
                requestID: requestID,
                step: .cancelled,
                state: .cancelled
            )
            throw CancellationError()
        }
    }
}
