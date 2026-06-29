import XcodeMCPKit
import Foundation
import NIOConcurrencyHelpers

final class LeaseManager: Sendable {
    typealias ID = UUID

    enum State: String, Codable, Sendable {
        case queued
        case active
        case completed
        case timedOut
        case failed
        case abandoned
    }

    enum ReleaseReason: String, Codable, Sendable {
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

    struct DebugSnapshot: Codable, Sendable {
        let leaseID: String
        let sessionID: String
        let requestIDKey: String?
        let upstreamIndex: Int?
        let label: String
        let state: LeaseManager.State
        let startedAt: Date?
        let timeoutAt: Date?
        let releasedAt: Date?
        let releaseReason: String?
        let lateResponseCount: Int

        init(
            leaseID: String,
            sessionID: String,
            requestIDKey: String?,
            upstreamIndex: Int?,
            label: String,
            state: LeaseManager.State,
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

    struct ReleaseAction: Sendable {
        let leaseID: LeaseManager.ID
        let sessionID: String
        let requestIDKey: String?
        let upstreamIndex: Int?
        let terminalState: LeaseManager.State?
        let reason: LeaseManager.ReleaseReason?

        init(
            leaseID: LeaseManager.ID,
            sessionID: String,
            requestIDKey: String?,
            upstreamIndex: Int?,
            terminalState: LeaseManager.State?,
            reason: LeaseManager.ReleaseReason?
        ) {
            self.leaseID = leaseID
            self.sessionID = sessionID
            self.requestIDKey = requestIDKey
            self.upstreamIndex = upstreamIndex
            self.terminalState = terminalState
            self.reason = reason
        }

        var shouldFailPendingRequest: Bool {
            switch terminalState {
            case .timedOut, .failed, .abandoned:
                return true
            case .queued, .active, .completed, nil:
                return false
            }
        }
    }

    private struct LeaseRecord: Sendable {
        let leaseID: LeaseManager.ID
        let descriptor: SessionRequestPipeline.Descriptor
        var requestIDKey: String?
        var upstreamIndex: Int?
        var startedAt: Date?
        var timeoutAt: Date?
        var state: LeaseManager.State
        var releasedAt: Date?
        var releaseReason: LeaseManager.ReleaseReason?
        var lateResponseCount: Int
    }

    private struct Storage: Sendable {
        var leasesByID: [LeaseManager.ID: LeaseRecord] = [:]
        var activeLeaseIDsByUpstream: [Int: Set<LeaseManager.ID>] = [:]
        var releasedLeasesByID: [LeaseManager.ID: LeaseRecord] = [:]
        var releasedLeaseIDsInOrder: [LeaseManager.ID] = []
    }

    private let state = NIOLockedValueBox(Storage())
    private let releasedHistoryLimit: Int

    init(releasedHistoryLimit: Int = 256) {
        self.releasedHistoryLimit = max(0, releasedHistoryLimit)
    }

    func createLease(descriptor: SessionRequestPipeline.Descriptor) -> LeaseManager.ID {
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

    func activateLease(
        _ leaseID: LeaseManager.ID,
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

    func completeLease(_ leaseID: LeaseManager.ID) -> LeaseManager.ReleaseAction? {
        finishLease(leaseID, terminalState: .completed, reason: .completed)
    }

    func requeueLease(_ leaseID: LeaseManager.ID) -> LeaseManager.ReleaseAction? {
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

            return LeaseManager.ReleaseAction(
                leaseID: leaseID,
                sessionID: record.descriptor.sessionID,
                requestIDKey: record.requestIDKey,
                upstreamIndex: upstreamIndex,
                terminalState: nil,
                reason: nil
            )
        }
    }

    func timeoutLease(_ leaseID: LeaseManager.ID) -> LeaseManager.ReleaseAction? {
        finishLease(leaseID, terminalState: .timedOut, reason: .timedOut)
    }

    func failLease(
        _ leaseID: LeaseManager.ID,
        terminalState: LeaseManager.State = .failed,
        reason: LeaseManager.ReleaseReason
    ) -> LeaseManager.ReleaseAction? {
        finishLease(leaseID, terminalState: terminalState, reason: reason)
    }

    func abandonActiveLeases(
        upstreamIndex: Int,
        reason: LeaseManager.ReleaseReason
    ) -> [LeaseManager.ReleaseAction] {
        state.withLockedValue { state in
            let leaseIDs = state.activeLeaseIDsByUpstream.removeValue(forKey: upstreamIndex) ?? []
            var actions: [LeaseManager.ReleaseAction] = []
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
                    LeaseManager.ReleaseAction(
                        leaseID: leaseID,
                        sessionID: record.descriptor.sessionID,
                        requestIDKey: record.requestIDKey,
                        upstreamIndex: record.upstreamIndex,
                        terminalState: .abandoned,
                        reason: reason
                    )
                )
            }

            return actions
        }
    }

    func debugSnapshots() -> [LeaseManager.DebugSnapshot] {
        state.withLockedValue { state in
            let records = Array(state.leasesByID.values) + state.releasedLeaseIDsInOrder.compactMap {
                state.releasedLeasesByID[$0]
            }
            return records
                .map { record in
                    LeaseManager.DebugSnapshot(
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

    func resetAll(reason: LeaseManager.ReleaseReason) -> [LeaseManager.ReleaseAction] {
        state.withLockedValue { state in
            let actions = state.leasesByID.values.compactMap { record -> LeaseManager.ReleaseAction? in
                switch record.state {
                case .queued, .active:
                    return LeaseManager.ReleaseAction(
                        leaseID: record.leaseID,
                        sessionID: record.descriptor.sessionID,
                        requestIDKey: record.requestIDKey,
                        upstreamIndex: record.upstreamIndex,
                        terminalState: .failed,
                        reason: reason
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

    func sessionDebugSnapshots(allSessionIDs: [String]) -> [SessionRequestPipeline.DebugSnapshot] {
        state.withLockedValue { state in
            var counts: [String: Int] = [:]
            for record in state.leasesByID.values where record.state == .active {
                counts[record.descriptor.sessionID, default: 0] += 1
            }
            let sessionIDs = Set(allSessionIDs).union(counts.keys).sorted()
            return sessionIDs.map { sessionID in
                SessionRequestPipeline.DebugSnapshot(
                    sessionID: sessionID,
                    activeCorrelatedRequestCount: counts[sessionID] ?? 0
                )
            }
        }
    }

    func activeCorrelatedRequestCountsByUpstream() -> [Int: Int] {
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

    func activeSessionID(upstreamIndex: Int) -> String? {
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
        _ leaseID: LeaseManager.ID,
        terminalState: LeaseManager.State,
        reason: LeaseManager.ReleaseReason
    ) -> LeaseManager.ReleaseAction? {
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
                return LeaseManager.ReleaseAction(
                    leaseID: leaseID,
                    sessionID: record.descriptor.sessionID,
                    requestIDKey: record.requestIDKey,
                    upstreamIndex: record.upstreamIndex,
                    terminalState: terminalState,
                    reason: reason
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

    private func storeReleasedLease(_ record: LeaseRecord, in state: inout Storage) {
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
