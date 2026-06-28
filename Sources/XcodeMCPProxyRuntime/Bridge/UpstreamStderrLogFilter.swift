import XcodeMCPCore
import XcodeMCPProcessRuntime
import Foundation
import NIOConcurrencyHelpers

package enum UpstreamStderrClassification: Sendable, Equatable {
    case xcodeUnavailable
    case unknown
}

package enum UpstreamStderrClassifier {
    package static func classify(_ message: String) -> UpstreamStderrClassification {
        let normalized = message.lowercased()
        if normalized.contains("mcp_xcode_pid environment variable not set")
            && normalized.contains("no running xcode processes found")
        {
            return .xcodeUnavailable
        }
        if normalized.contains("no running xcode processes found") {
            return .xcodeUnavailable
        }
        return .unknown
    }
}

package struct UpstreamStderrLogDecision: Sendable {
    package let shouldLog: Bool
    package let suppressedDuplicateCount: Int
}

package final class UpstreamStderrLogLimiter: Sendable {
    private struct Record: Sendable {
        var lastLoggedUptimeNs: UInt64
        var suppressedDuplicateCount: Int
    }

    private struct State: Sendable {
        var recordsByKey: [String: Record] = [:]
    }

    private let state = NIOLockedValueBox(State())
    private let duplicateLogIntervalNanoseconds: UInt64

    package init(duplicateLogIntervalNanoseconds: UInt64 = 5_000_000_000) {
        self.duplicateLogIntervalNanoseconds = duplicateLogIntervalNanoseconds
    }

    package func decision(
        upstreamIndex: Int,
        message: String,
        classification: UpstreamStderrClassification,
        nowUptimeNs: UInt64
    ) -> UpstreamStderrLogDecision {
        let key = "\(upstreamIndex)|\(classification)|\(message)"
        return state.withLockedValue { state in
            guard var record = state.recordsByKey[key] else {
                state.recordsByKey[key] = Record(
                    lastLoggedUptimeNs: nowUptimeNs,
                    suppressedDuplicateCount: 0
                )
                return UpstreamStderrLogDecision(
                    shouldLog: true,
                    suppressedDuplicateCount: 0
                )
            }

            guard nowUptimeNs &- record.lastLoggedUptimeNs >= duplicateLogIntervalNanoseconds else {
                record.suppressedDuplicateCount += 1
                state.recordsByKey[key] = record
                return UpstreamStderrLogDecision(
                    shouldLog: false,
                    suppressedDuplicateCount: record.suppressedDuplicateCount
                )
            }

            let suppressedCount = record.suppressedDuplicateCount
            record.lastLoggedUptimeNs = nowUptimeNs
            record.suppressedDuplicateCount = 0
            state.recordsByKey[key] = record
            return UpstreamStderrLogDecision(
                shouldLog: true,
                suppressedDuplicateCount: suppressedCount
            )
        }
    }

    package func reset() {
        state.withLockedValue { state in
            state.recordsByKey.removeAll()
        }
    }
}
