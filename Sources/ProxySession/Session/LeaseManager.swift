import Foundation
import NIOConcurrencyHelpers

package typealias RequestLeaseID = UUID

package enum RequestLeaseState: String, Codable, Sendable {
    case queued
    case active
    case completed
    case timedOut
    case failed
    case abandoned
}

package enum RequestLeaseReleaseReason: String, Codable, Sendable {
    case completed
    case timedOut
    case invalidUpstreamResponse
    case upstreamUnavailable
    case upstreamExit
    case upstreamOverloaded
    case stdoutProtocolViolation
    case clientDisconnected
    case lateResponse
}

package struct RequestLeaseDebugSnapshot: Codable, Sendable {
    package let leaseID: String
    package let sessionID: String
    package let requestIDKey: String?
    package let upstreamIndex: Int?
    package let label: String
    package let state: RequestLeaseState
    package let startedAt: Date?
    package let timeoutAt: Date?
    package let releasedAt: Date?
    package let releaseReason: String?
    package let lateResponseCount: Int

    package init(
        leaseID: String,
        sessionID: String,
        requestIDKey: String?,
        upstreamIndex: Int?,
        label: String,
        state: RequestLeaseState,
        startedAt: Date?,
        timeoutAt: Date?,
        releasedAt: Date?,
        releaseReason: String?,
        lateResponseCount: Int
    ) {
        self.leaseID = leaseID
        self.sessionID = sessionID
        self.requestIDKey = requestIDKey
        self.upstreamIndex = upstreamIndex
        self.label = label
        self.state = state
        self.startedAt = startedAt
        self.timeoutAt = timeoutAt
        self.releasedAt = releasedAt
        self.releaseReason = releaseReason
        self.lateResponseCount = lateResponseCount
    }
}

package struct RequestLeaseReleaseAction: Sendable {
    package let leaseID: RequestLeaseID
    package let sessionID: String
    package let upstreamIndex: Int?

    package init(leaseID: RequestLeaseID, sessionID: String, upstreamIndex: Int?) {
        self.leaseID = leaseID
        self.sessionID = sessionID
        self.upstreamIndex = upstreamIndex
    }
}

package final class LeaseManager: Sendable {
    private struct LeaseRecord: Sendable {
        let leaseID: RequestLeaseID
        let descriptor: SessionPipelineRequestDescriptor
        var requestIDKey: String?
        var upstreamIndex: Int?
        var startedAt: Date?
        var timeoutAt: Date?
        var state: RequestLeaseState
        var releasedAt: Date?
        var releaseReason: RequestLeaseReleaseReason?
        var lateResponseCount: Int
    }

    private struct State: Sendable {
        var leasesByID: [RequestLeaseID: LeaseRecord] = [:]
        var activeLeaseIDsByUpstream: [Int: Set<RequestLeaseID>] = [:]
        var releasedLeasesByID: [RequestLeaseID: LeaseRecord] = [:]
        var releasedLeaseIDsInOrder: [RequestLeaseID] = []
    }

    private let state = NIOLockedValueBox(State())
    private let releasedHistoryLimit: Int

    package init(releasedHistoryLimit: Int = 256) {
        self.releasedHistoryLimit = max(0, releasedHistoryLimit)
    }

    package func createLease(descriptor: SessionPipelineRequestDescriptor) -> RequestLeaseID {
        let leaseID = UUID()
        state.withLockedValue { state in
            state.leasesByID[leaseID] = LeaseRecord(
                leaseID: leaseID,
                descriptor: descriptor,
                requestIDKey: nil,
                upstreamIndex: nil,
                startedAt: nil,
                timeoutAt: nil,
                state: .queued,
                releasedAt: nil,
                releaseReason: nil,
                lateResponseCount: 0
            )
        }
        return leaseID
    }

    package func activateLease(
        _ leaseID: RequestLeaseID,
        requestIDKey: String?,
        upstreamIndex: Int?,
        timeoutAt: Date?
    ) {
        state.withLockedValue { state in
            guard var record = state.leasesByID[leaseID] else { return }
            switch record.state {
            case .queued, .active:
                break
            case .completed, .timedOut, .failed, .abandoned:
                return
            }
            record.requestIDKey = requestIDKey ?? record.requestIDKey
            record.upstreamIndex = upstreamIndex ?? record.upstreamIndex
            record.startedAt = record.startedAt ?? Date()
            record.timeoutAt = timeoutAt
            record.state = .active
            state.leasesByID[leaseID] = record
            if let upstreamIndex {
                state.activeLeaseIDsByUpstream[upstreamIndex, default: []].insert(leaseID)
            }
        }
    }

    package func completeLease(_ leaseID: RequestLeaseID) -> RequestLeaseReleaseAction? {
        finishLease(leaseID, terminalState: .completed, reason: .completed)
    }

    package func requeueLease(_ leaseID: RequestLeaseID) -> RequestLeaseReleaseAction? {
        state.withLockedValue { state in
            guard var record = state.leasesByID[leaseID] else { return nil }
            guard record.state == .active else { return nil }

            let upstreamIndex = record.upstreamIndex
            record.state = .queued
            record.requestIDKey = nil
            record.upstreamIndex = nil
            record.timeoutAt = nil
            state.leasesByID[leaseID] = record

            if let upstreamIndex {
                state.activeLeaseIDsByUpstream[upstreamIndex]?.remove(leaseID)
                if state.activeLeaseIDsByUpstream[upstreamIndex]?.isEmpty == true {
                    state.activeLeaseIDsByUpstream.removeValue(forKey: upstreamIndex)
                }
            }

            return RequestLeaseReleaseAction(
                leaseID: leaseID,
                sessionID: record.descriptor.sessionID,
                upstreamIndex: upstreamIndex
            )
        }
    }

    package func timeoutLease(_ leaseID: RequestLeaseID) -> RequestLeaseReleaseAction? {
        finishLease(leaseID, terminalState: .timedOut, reason: .timedOut)
    }

    package func failLease(
        _ leaseID: RequestLeaseID,
        terminalState: RequestLeaseState = .failed,
        reason: RequestLeaseReleaseReason
    ) -> RequestLeaseReleaseAction? {
        finishLease(leaseID, terminalState: terminalState, reason: reason)
    }

    package func abandonActiveLeases(
        upstreamIndex: Int,
        reason: RequestLeaseReleaseReason
    ) -> [RequestLeaseReleaseAction] {
        state.withLockedValue { state in
            let leaseIDs = state.activeLeaseIDsByUpstream.removeValue(forKey: upstreamIndex) ?? []
            var actions: [RequestLeaseReleaseAction] = []
            actions.reserveCapacity(leaseIDs.count)

            for leaseID in leaseIDs {
                guard var record = state.leasesByID[leaseID] else { continue }
                guard record.state == .active else { continue }
                record.state = .abandoned
                record.releasedAt = Date()
                record.releaseReason = reason
                state.leasesByID.removeValue(forKey: leaseID)
                storeReleasedLease(record, in: &state)
                actions.append(
                    RequestLeaseReleaseAction(
                        leaseID: leaseID,
                        sessionID: record.descriptor.sessionID,
                        upstreamIndex: record.upstreamIndex
                    )
                )
            }

            return actions
        }
    }

    package func debugSnapshots() -> [RequestLeaseDebugSnapshot] {
        state.withLockedValue { state in
            let records = Array(state.leasesByID.values) + state.releasedLeaseIDsInOrder.compactMap {
                state.releasedLeasesByID[$0]
            }
            return records
                .map { record in
                    RequestLeaseDebugSnapshot(
                        leaseID: record.leaseID.uuidString,
                        sessionID: record.descriptor.sessionID,
                        requestIDKey: record.requestIDKey,
                        upstreamIndex: record.upstreamIndex,
                        label: record.descriptor.label,
                        state: record.state,
                        startedAt: record.startedAt,
                        timeoutAt: record.timeoutAt,
                        releasedAt: record.releasedAt,
                        releaseReason: record.releaseReason?.rawValue,
                        lateResponseCount: record.lateResponseCount
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.sessionID == rhs.sessionID {
                        return lhs.leaseID < rhs.leaseID
                    }
                    return lhs.sessionID < rhs.sessionID
                }
        }
    }

    package func resetAll(reason: RequestLeaseReleaseReason) -> [RequestLeaseReleaseAction] {
        state.withLockedValue { state in
            let actions = state.leasesByID.values.compactMap { record -> RequestLeaseReleaseAction? in
                switch record.state {
                case .queued, .active:
                    return RequestLeaseReleaseAction(
                        leaseID: record.leaseID,
                        sessionID: record.descriptor.sessionID,
                        upstreamIndex: record.upstreamIndex
                    )
                case .completed, .timedOut, .failed, .abandoned:
                    return nil
                }
            }
            state.leasesByID.removeAll()
            state.activeLeaseIDsByUpstream.removeAll()
            state.releasedLeasesByID.removeAll()
            state.releasedLeaseIDsInOrder.removeAll()
            return actions
        }
    }

    package func sessionDebugSnapshots(allSessionIDs: [String]) -> [SessionDebugSnapshot] {
        state.withLockedValue { state in
            var counts: [String: Int] = [:]
            for record in state.leasesByID.values where record.state == .active {
                counts[record.descriptor.sessionID, default: 0] += 1
            }
            let sessionIDs = Set(allSessionIDs).union(counts.keys).sorted()
            return sessionIDs.map { sessionID in
                SessionDebugSnapshot(
                    sessionID: sessionID,
                    activeCorrelatedRequestCount: counts[sessionID] ?? 0
                )
            }
        }
    }

    package func activeCorrelatedRequestCountsByUpstream() -> [Int: Int] {
        state.withLockedValue { state in
            var counts: [Int: Int] = [:]
            for record in state.leasesByID.values where record.state == .active {
                if let upstreamIndex = record.upstreamIndex {
                    counts[upstreamIndex, default: 0] += 1
                }
            }
            return counts
        }
    }

    package func activeSessionID(upstreamIndex: Int) -> String? {
        state.withLockedValue { state in
            let leaseIDs = state.activeLeaseIDsByUpstream[upstreamIndex] ?? []
            let records = leaseIDs.compactMap { state.leasesByID[$0] }
                .filter { $0.state == .active }
            guard records.isEmpty == false else {
                return nil
            }
            return records.sorted { lhs, rhs in
                if lhs.descriptor.isTopLevelClientRequest
                    != rhs.descriptor.isTopLevelClientRequest
                {
                    return lhs.descriptor.isTopLevelClientRequest
                }
                return (lhs.startedAt ?? .distantPast) < (rhs.startedAt ?? .distantPast)
            }.first?.descriptor.sessionID
        }
    }

    private func finishLease(
        _ leaseID: RequestLeaseID,
        terminalState: RequestLeaseState,
        reason: RequestLeaseReleaseReason
    ) -> RequestLeaseReleaseAction? {
        state.withLockedValue { state in
            guard var record = state.leasesByID[leaseID] ?? state.releasedLeasesByID[leaseID] else {
                return nil
            }

            switch record.state {
            case .queued, .active:
                record.state = terminalState
                record.releasedAt = Date()
                record.releaseReason = reason
                state.leasesByID[leaseID] = record
                if let upstreamIndex = record.upstreamIndex {
                    state.activeLeaseIDsByUpstream[upstreamIndex]?.remove(leaseID)
                    if state.activeLeaseIDsByUpstream[upstreamIndex]?.isEmpty == true {
                        state.activeLeaseIDsByUpstream.removeValue(forKey: upstreamIndex)
                    }
                }
                state.leasesByID.removeValue(forKey: leaseID)
                storeReleasedLease(record, in: &state)
                return RequestLeaseReleaseAction(
                    leaseID: leaseID,
                    sessionID: record.descriptor.sessionID,
                    upstreamIndex: record.upstreamIndex
                )

            case .completed, .timedOut, .failed, .abandoned:
                if var released = state.releasedLeasesByID[leaseID] {
                    released.lateResponseCount += 1
                    state.releasedLeasesByID[leaseID] = released
                } else {
                    record.lateResponseCount += 1
                    storeReleasedLease(record, in: &state)
                }
                return nil
            }
        }
    }

    private func storeReleasedLease(_ record: LeaseRecord, in state: inout State) {
        if state.releasedLeasesByID[record.leaseID] == nil {
            state.releasedLeaseIDsInOrder.append(record.leaseID)
        }
        state.releasedLeasesByID[record.leaseID] = record

        while state.releasedLeaseIDsInOrder.count > releasedHistoryLimit {
            let removedLeaseID = state.releasedLeaseIDsInOrder.removeFirst()
            state.releasedLeasesByID.removeValue(forKey: removedLeaseID)
        }
    }
}
