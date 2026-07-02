import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPKit

final class XcodeProcessRouteActivationTracker: Sendable {
    enum Phase: Sendable, Equatable {
        case pending
        case attaching(upstreamIndex: Int, attempt: Int, startedAtUptimeNs: UInt64)
        case initialized(upstreamIndex: Int, attempt: Int, startedAtUptimeNs: UInt64)
        case cataloged(upstreamIndex: Int)
        case abandoned(reason: String)
    }

    struct Start: Sendable {
        let attempt: Int
        let startedAtUptimeNs: UInt64
    }

    struct Retry: Sendable {
        let attempt: Int
        let delay: TimeAmount
        let delayMilliseconds: Int64
    }

    private struct Record: Sendable {
        var phase: Phase
        var attempt: Int
        var retryTimeout: RuntimeScheduledTimeout?

        init(phase: Phase, attempt: Int = 0, retryTimeout: RuntimeScheduledTimeout? = nil) {
            self.phase = phase
            self.attempt = attempt
            self.retryTimeout = retryTimeout
        }
    }

    private let state = NIOLockedValueBox<[pid_t: Record]>([:])

    func prepare(processID: pid_t) {
        state.withLockedValue { records in
            if let record = records[processID] {
                switch record.phase {
                case .cataloged:
                    records[processID] = Record(phase: .pending, attempt: record.attempt)
                case .abandoned:
                    records[processID] = Record(phase: .pending, attempt: 0)
                case .pending, .attaching, .initialized:
                    break
                }
            } else {
                records[processID] = Record(phase: .pending)
            }
        }
    }

    func beginAttaching(
        processID: pid_t,
        upstreamIndex: Int,
        nowUptimeNs: UInt64
    ) -> Start? {
        state.withLockedValue { records in
            var record = records[processID] ?? Record(phase: .pending)
            switch record.phase {
            case .pending:
                guard record.retryTimeout == nil else {
                    records[processID] = record
                    return nil
                }
            case .abandoned:
                break
            case .attaching, .initialized, .cataloged:
                return nil
            }

            record.retryTimeout?.cancel()
            record.retryTimeout = nil
            record.attempt += 1
            record.phase = .attaching(
                upstreamIndex: upstreamIndex,
                attempt: record.attempt,
                startedAtUptimeNs: nowUptimeNs
            )
            records[processID] = record
            return Start(attempt: record.attempt, startedAtUptimeNs: nowUptimeNs)
        }
    }

    func markInitialized(
        processID: pid_t,
        upstreamIndex: Int,
        nowUptimeNs _: UInt64
    ) -> Bool {
        state.withLockedValue { records -> Bool in
            guard var record = records[processID] else { return false }
            guard case .attaching(let currentUpstreamIndex, let attempt, let startedAt) = record.phase,
                  currentUpstreamIndex == upstreamIndex
            else {
                return false
            }
            record.phase = .initialized(
                upstreamIndex: upstreamIndex,
                attempt: attempt,
                startedAtUptimeNs: startedAt
            )
            records[processID] = record
            return true
        }
    }

    func markCataloged(
        processID: pid_t,
        upstreamIndex: Int,
        nowUptimeNs: UInt64
    ) -> UInt64? {
        state.withLockedValue { records -> UInt64? in
            guard var record = records[processID] else { return nil }
            let duration: UInt64
            switch record.phase {
            case .initialized(let currentUpstreamIndex, _, let startedAt)
                where currentUpstreamIndex == upstreamIndex:
                duration = nowUptimeNs &- startedAt
            case .attaching(let currentUpstreamIndex, _, let startedAt)
                where currentUpstreamIndex == upstreamIndex:
                duration = nowUptimeNs &- startedAt
            case .cataloged(let currentUpstreamIndex) where currentUpstreamIndex == upstreamIndex:
                return nil
            case .pending, .abandoned, .attaching, .initialized, .cataloged:
                return nil
            }
            record.retryTimeout?.cancel()
            record.retryTimeout = nil
            record.phase = .cataloged(upstreamIndex: upstreamIndex)
            records[processID] = record
            return duration
        }
    }

    func handleTimeout(
        processID: pid_t,
        upstreamIndex: Int,
        attempt: Int
    ) -> Retry? {
        state.withLockedValue { records in
            guard var record = records[processID] else { return nil }
            guard case .attaching(let currentUpstreamIndex, let currentAttempt, _) = record.phase,
                  currentUpstreamIndex == upstreamIndex,
                  currentAttempt == attempt
            else {
                return nil
            }
            record.phase = .pending
            records[processID] = record
            return Self.retry(forAttempt: currentAttempt)
        }
    }

    func handleRetryFired(processID: pid_t) -> Bool {
        state.withLockedValue { records in
            guard var record = records[processID] else { return false }
            record.retryTimeout = nil
            switch record.phase {
            case .pending:
                records[processID] = record
                return true
            case .attaching, .initialized, .cataloged, .abandoned:
                records[processID] = record
                return false
            }
        }
    }

    func storeRetry(
        processID: pid_t,
        timeout: RuntimeScheduledTimeout
    ) {
        state.withLockedValue { records in
            var record = records[processID] ?? Record(phase: .pending)
            record.retryTimeout?.cancel()
            record.retryTimeout = timeout
            records[processID] = record
        }
    }

    func abandon(processID: pid_t, reason: String) {
        state.withLockedValue { records in
            var record = records[processID] ?? Record(phase: .pending)
            record.retryTimeout?.cancel()
            record.retryTimeout = nil
            record.phase = .abandoned(reason: reason)
            records[processID] = record
        }
    }

    @discardableResult
    func reset(processID: pid_t) -> Bool {
        state.withLockedValue { records in
            guard let record = records.removeValue(forKey: processID) else {
                return false
            }
            record.retryTimeout?.cancel()
            return true
        }
    }

    func resetAll() -> [pid_t] {
        state.withLockedValue { records in
            let processIDs = Array(records.keys)
            for record in records.values {
                record.retryTimeout?.cancel()
            }
            records.removeAll()
            return processIDs
        }
    }

    func phase(processID: pid_t) -> Phase? {
        state.withLockedValue { $0[processID]?.phase }
    }

    private static func retry(forAttempt attempt: Int) -> Retry {
        let delayMilliseconds: Int64
        switch attempt {
        case ...1:
            delayMilliseconds = 250
        case 2:
            delayMilliseconds = 500
        case 3:
            delayMilliseconds = 1_000
        default:
            delayMilliseconds = 2_000
        }
        return Retry(
            attempt: attempt,
            delay: .milliseconds(delayMilliseconds),
            delayMilliseconds: delayMilliseconds
        )
    }
}
