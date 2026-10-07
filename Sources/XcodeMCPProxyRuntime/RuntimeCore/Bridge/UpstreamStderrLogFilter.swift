import XcodeMCPCore
import Foundation
import Logging
import NIOConcurrencyHelpers

enum UpstreamStderrLogFilter {
    static func level(for message: String) -> Logger.Level {
        guard message.hasPrefix("["),
              let frameEnd = message.range(of: "] "),
              let separator = message[frameEnd.upperBound...].firstIndex(of: ":")
        else { return .error }
        let severity = message[frameEnd.upperBound..<separator]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return Logger.Level(rawValue: severity) ?? .error
    }
}

struct UpstreamStderrLogDecision: Sendable {
    let shouldLog: Bool
    let suppressedDuplicateCount: Int
}

final class UpstreamStderrLogLimiter: Sendable {
    private struct Record: Sendable {
        var lastLoggedUptimeNs: UInt64
        var suppressedDuplicateCount: Int
    }

    private struct State: Sendable {
        var recordsByKey: [String: Record] = [:]
    }

    private let state = NIOLockedValueBox(State())
    private let duplicateLogIntervalNanoseconds: UInt64

    init(duplicateLogIntervalNanoseconds: UInt64 = 5_000_000_000) {
        self.duplicateLogIntervalNanoseconds = duplicateLogIntervalNanoseconds
    }

    func decision(
        upstreamIndex: Int,
        message: String,
        nowUptimeNs: UInt64
    ) -> UpstreamStderrLogDecision {
        let key = "\(upstreamIndex)|\(message)"
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

    func reset() {
        state.withLockedValue { state in
            state.recordsByKey.removeAll()
        }
    }
}
