import Foundation

package struct RefreshCodeIssuesQueueDebugSnapshot: Codable, Sendable {
    package let maxPendingPerKey: Int
    package let maxPendingTotal: Int
    package let queueWaitTimeoutSeconds: Double
    package let activeByQueueKey: [String: Int]
    package let waitingByQueueKey: [String: Int]
    package let activeRequestCount: Int
    package let waitingRequestCount: Int

    package init(
        maxPendingPerKey: Int,
        maxPendingTotal: Int,
        queueWaitTimeoutSeconds: Double,
        activeByQueueKey: [String: Int],
        waitingByQueueKey: [String: Int],
        activeRequestCount: Int,
        waitingRequestCount: Int
    ) {
        self.maxPendingPerKey = maxPendingPerKey
        self.maxPendingTotal = maxPendingTotal
        self.queueWaitTimeoutSeconds = queueWaitTimeoutSeconds
        self.activeByQueueKey = activeByQueueKey
        self.waitingByQueueKey = waitingByQueueKey
        self.activeRequestCount = activeRequestCount
        self.waitingRequestCount = waitingRequestCount
    }
}

package struct RefreshCodeIssuesRequestDebugSnapshot: Codable, Sendable {
    package let id: String
    package let sessionID: String
    package let queueKey: String
    package let tabIdentifier: String?
    package let filePath: String?
    package let mode: String
    package let state: String
    package let step: String
    package let startedAt: Date
    package let lastUpdatedAt: Date
    package let lastQueuePosition: Int?
    package let metadata: [String: String]

    package init(
        id: String,
        sessionID: String,
        queueKey: String,
        tabIdentifier: String?,
        filePath: String?,
        mode: String,
        state: String,
        step: String,
        startedAt: Date,
        lastUpdatedAt: Date,
        lastQueuePosition: Int?,
        metadata: [String: String]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.queueKey = queueKey
        self.tabIdentifier = tabIdentifier
        self.filePath = filePath
        self.mode = mode
        self.state = state
        self.step = step
        self.startedAt = startedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.lastQueuePosition = lastQueuePosition
        self.metadata = metadata
    }
}

package struct RefreshCodeIssuesCompletedRequestDebugSnapshot: Codable, Sendable {
    package let id: String
    package let sessionID: String
    package let queueKey: String
    package let tabIdentifier: String?
    package let filePath: String?
    package let mode: String
    package let finalState: String
    package let finalStep: String
    package let startedAt: Date
    package let completedAt: Date
    package let lastQueuePosition: Int?
    package let outcome: String
    package let metadata: [String: String]

    package init(
        id: String,
        sessionID: String,
        queueKey: String,
        tabIdentifier: String?,
        filePath: String?,
        mode: String,
        finalState: String,
        finalStep: String,
        startedAt: Date,
        completedAt: Date,
        lastQueuePosition: Int?,
        outcome: String,
        metadata: [String: String]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.queueKey = queueKey
        self.tabIdentifier = tabIdentifier
        self.filePath = filePath
        self.mode = mode
        self.finalState = finalState
        self.finalStep = finalStep
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.lastQueuePosition = lastQueuePosition
        self.outcome = outcome
        self.metadata = metadata
    }
}

package struct RefreshCodeIssuesDebugSnapshot: Codable, Sendable {
    package let queue: RefreshCodeIssuesQueueDebugSnapshot
    package let activeRequests: [RefreshCodeIssuesRequestDebugSnapshot]
    package let recentCompletedRequests: [RefreshCodeIssuesCompletedRequestDebugSnapshot]

    package init(
        queue: RefreshCodeIssuesQueueDebugSnapshot,
        activeRequests: [RefreshCodeIssuesRequestDebugSnapshot],
        recentCompletedRequests: [RefreshCodeIssuesCompletedRequestDebugSnapshot]
    ) {
        self.queue = queue
        self.activeRequests = activeRequests
        self.recentCompletedRequests = recentCompletedRequests
    }
}

package final class RefreshCodeIssuesDebugState: @unchecked Sendable {
    private struct RequestRecord: Sendable {
        let id: String
        let sessionID: String
        let queueKey: String
        let tabIdentifier: String?
        let filePath: String?
        let mode: String
        let startedAt: Date
        var lastUpdatedAt: Date
        var state: String
        var step: String
        var lastQueuePosition: Int?
        var metadata: [String: String]
    }

    private struct State {
        var activeRequests: [String: RequestRecord] = [:]
        var recentCompletedRequests: [RefreshCodeIssuesCompletedRequestDebugSnapshot] = []
    }

    private let lock = NSLock()
    private var state = State()
    private let maxPendingPerKey: Int
    private let maxPendingTotal: Int
    private let queueWaitTimeoutSeconds: Double
    private let recentCompletedLimit: Int

    package init(
        maxPendingPerKey: Int,
        maxPendingTotal: Int,
        queueWaitTimeoutSeconds: Double,
        recentCompletedLimit: Int = 20
    ) {
        self.maxPendingPerKey = maxPendingPerKey
        self.maxPendingTotal = maxPendingTotal
        self.queueWaitTimeoutSeconds = queueWaitTimeoutSeconds
        self.recentCompletedLimit = recentCompletedLimit
    }

    package func beginRequest(
        sessionID: String,
        queueKey: String,
        tabIdentifier: String?,
        filePath: String?,
        mode: String
    ) -> String {
        let now = Date()
        let requestID = UUID().uuidString
        let record = RequestRecord(
            id: requestID,
            sessionID: sessionID,
            queueKey: queueKey,
            tabIdentifier: tabIdentifier,
            filePath: filePath,
            mode: mode,
            startedAt: now,
            lastUpdatedAt: now,
            state: "waiting_for_permit",
            step: "waiting_for_permit",
            lastQueuePosition: nil,
            metadata: [:]
        )
        lock.lock()
        state.activeRequests[requestID] = record
        lock.unlock()
        return requestID
    }

    package func markPermitAcquired(
        requestID: String,
        queuePosition: Int,
        pendingForKey: Int,
        pendingTotal: Int
    ) {
        updateRequest(requestID: requestID) { record, now in
            record.state = "running"
            record.step = "permit_acquired"
            record.lastQueuePosition = queuePosition
            record.lastUpdatedAt = now
            record.metadata["pending_for_key"] = "\(pendingForKey)"
            record.metadata["pending_total"] = "\(pendingTotal)"
        }
    }

    package func updateStep(
        requestID: String,
        step: String,
        state overrideState: String? = nil,
        metadata: [String: String] = [:]
    ) {
        updateRequest(requestID: requestID) { record, now in
            if let overrideState {
                record.state = overrideState
            }
            record.step = step
            record.lastUpdatedAt = now
            for (key, value) in metadata {
                record.metadata[key] = value
            }
        }
    }

    package func finishRequest(
        requestID: String,
        outcome: String,
        metadata: [String: String] = [:]
    ) {
        let now = Date()
        lock.lock()
        guard var record = state.activeRequests.removeValue(forKey: requestID) else {
            lock.unlock()
            return
        }
        record.lastUpdatedAt = now
        record.state = Self.finalState(for: outcome)
        for (key, value) in metadata {
            record.metadata[key] = value
        }
        let completed = RefreshCodeIssuesCompletedRequestDebugSnapshot(
            id: record.id,
            sessionID: record.sessionID,
            queueKey: record.queueKey,
            tabIdentifier: record.tabIdentifier,
            filePath: record.filePath,
            mode: record.mode,
            finalState: record.state,
            finalStep: record.step,
            startedAt: record.startedAt,
            completedAt: now,
            lastQueuePosition: record.lastQueuePosition,
            outcome: outcome,
            metadata: record.metadata
        )
        state.recentCompletedRequests.append(completed)
        if state.recentCompletedRequests.count > recentCompletedLimit {
            state.recentCompletedRequests.removeFirst(
                state.recentCompletedRequests.count - recentCompletedLimit
            )
        }
        lock.unlock()
    }

    private static func finalState(for outcome: String) -> String {
        switch outcome {
        case "success":
            return "completed"
        case "timeout", "queue_wait_timed_out":
            return "timed_out"
        case "cancelled":
            return "cancelled"
        case "queue_limit_exceeded", "overloaded":
            return "rejected"
        default:
            return "failed"
        }
    }

    package func snapshot() -> RefreshCodeIssuesDebugSnapshot {
        lock.lock()
        let activeRecords = Array(state.activeRequests.values)
        let recentCompleted = state.recentCompletedRequests
        lock.unlock()

        var activeByQueueKey: [String: Int] = [:]
        var waitingByQueueKey: [String: Int] = [:]
        for record in activeRecords {
            if record.state == "running" {
                activeByQueueKey[record.queueKey, default: 0] += 1
            } else {
                waitingByQueueKey[record.queueKey, default: 0] += 1
            }
        }

        let activeRequests = activeRecords
            .sorted { lhs, rhs in
                if lhs.startedAt == rhs.startedAt {
                    return lhs.id < rhs.id
                }
                return lhs.startedAt < rhs.startedAt
            }
            .map { record in
                RefreshCodeIssuesRequestDebugSnapshot(
                    id: record.id,
                    sessionID: record.sessionID,
                    queueKey: record.queueKey,
                    tabIdentifier: record.tabIdentifier,
                    filePath: record.filePath,
                    mode: record.mode,
                    state: record.state,
                    step: record.step,
                    startedAt: record.startedAt,
                    lastUpdatedAt: record.lastUpdatedAt,
                    lastQueuePosition: record.lastQueuePosition,
                    metadata: record.metadata
                )
            }
        let queue = RefreshCodeIssuesQueueDebugSnapshot(
            maxPendingPerKey: maxPendingPerKey,
            maxPendingTotal: maxPendingTotal,
            queueWaitTimeoutSeconds: queueWaitTimeoutSeconds,
            activeByQueueKey: activeByQueueKey,
            waitingByQueueKey: waitingByQueueKey,
            activeRequestCount: activeRequests.filter { $0.state == "running" }.count,
            waitingRequestCount: activeRequests.filter { $0.state != "running" }.count
        )
        return RefreshCodeIssuesDebugSnapshot(
            queue: queue,
            activeRequests: activeRequests,
            recentCompletedRequests: recentCompleted
        )
    }

    private func updateRequest(
        requestID: String,
        mutate: (inout RequestRecord, Date) -> Void
    ) {
        let now = Date()
        lock.lock()
        guard var record = state.activeRequests[requestID] else {
            lock.unlock()
            return
        }
        mutate(&record, now)
        state.activeRequests[requestID] = record
        lock.unlock()
    }
}
