import Foundation
import XcodeMCPCore
import XcodeMCPProcessRuntime
import XcodeMCPProxyRuntime

extension RefreshCodeIssues {
    package struct QueueSnapshot: Codable, Sendable {
        package let defaultRequestTimeoutSeconds: Double
        package let activeByQueueKey: [String: Int]
        package let waitingByQueueKey: [String: Int]
        package let activeRequestCount: Int
        package let waitingRequestCount: Int

        package init(
            defaultRequestTimeoutSeconds: Double,
            activeByQueueKey: [String: Int],
            waitingByQueueKey: [String: Int],
            activeRequestCount: Int,
            waitingRequestCount: Int
        ) {
            self.defaultRequestTimeoutSeconds = defaultRequestTimeoutSeconds
            self.activeByQueueKey = activeByQueueKey
            self.waitingByQueueKey = waitingByQueueKey
            self.activeRequestCount = activeRequestCount
            self.waitingRequestCount = waitingRequestCount
        }
    }

    /// A refresh request's terminal outcome. The diagnostic final state is
    /// derived here, so the outcome-to-state mapping cannot drift between the
    /// workflow and the debug snapshot.
    package enum Outcome: String, Sendable {
        case success
        case timeout
        case queueWaitTimedOut = "queue_wait_timed_out"
        case cancelled
        case invalidRequest = "invalid_request"
        case upstreamUnavailable = "upstream_unavailable"
        case invalidUpstreamResponse = "invalid_upstream_response"

        package var finalState: RefreshCodeIssues.RequestState {
            switch self {
            case .success:
                return .completed
            case .timeout, .queueWaitTimedOut:
                return .timedOut
            case .cancelled:
                return .cancelled
            case .invalidRequest, .upstreamUnavailable, .invalidUpstreamResponse:
                return .failed
            }
        }
    }

    package enum RequestState: String, Sendable {
        case waitingForPermit = "waiting_for_permit"
        case running
        case completed
        case timedOut = "timed_out"
        case cancelled
        case failed
    }

    package enum Step: Sendable, Equatable {
        case waitingForPermit
        case permitAcquired
        case requestTimeoutExhausted
        case queueWaitTimedOut
        case executionBudgetStarted
        case invalidRequest
        case cancelled
        case proxyFallbackToUpstream
        case proxySelectInternalUpstream
        case proxyExecutionBudgetExhausted
        case proxyReservedUpstreamBudget
        case proxyListWindows
        case proxyListNavigatorIssues
        case proxyFilterNavigatorIssues
        case proxyEncodeResponse
        case proxySuccess
        case proxyCompleted
        case upstreamExecutionBudgetExhausted
        case upstreamAttempt(Int)
        case upstreamRetryBudgetExhausted
        case upstreamRetryDelay
        case upstreamRetryExhausted
        case upstreamSuccess
        case upstreamTimeout
        case upstreamUnavailable
        case upstreamInvalidRequest
        case upstreamInvalidResponse

        package var rawValue: String {
            switch self {
            case .waitingForPermit:
                return "waiting_for_permit"
            case .permitAcquired:
                return "permit_acquired"
            case .requestTimeoutExhausted:
                return "request_timeout_exhausted"
            case .queueWaitTimedOut:
                return "queue_wait_timed_out"
            case .executionBudgetStarted:
                return "execution_budget_started"
            case .invalidRequest:
                return "invalid_request"
            case .cancelled:
                return "cancelled"
            case .proxyFallbackToUpstream:
                return "proxy.fallback_to_upstream"
            case .proxySelectInternalUpstream:
                return "proxy.select_internal_upstream"
            case .proxyExecutionBudgetExhausted:
                return "proxy.execution_budget_exhausted"
            case .proxyReservedUpstreamBudget:
                return "proxy.reserved_upstream_budget"
            case .proxyListWindows:
                return "proxy.list_windows"
            case .proxyListNavigatorIssues:
                return "proxy.list_navigator_issues"
            case .proxyFilterNavigatorIssues:
                return "proxy.filter_navigator_issues"
            case .proxyEncodeResponse:
                return "proxy.encode_response"
            case .proxySuccess:
                return "proxy.success"
            case .proxyCompleted:
                return "proxy.completed"
            case .upstreamExecutionBudgetExhausted:
                return "upstream.execution_budget_exhausted"
            case .upstreamAttempt(let attempt):
                return "upstream.attempt_\(attempt)"
            case .upstreamRetryBudgetExhausted:
                return "upstream.retry_budget_exhausted"
            case .upstreamRetryDelay:
                return "upstream.retry_delay"
            case .upstreamRetryExhausted:
                return "upstream.retry_exhausted"
            case .upstreamSuccess:
                return "upstream.success"
            case .upstreamTimeout:
                return "upstream.timeout"
            case .upstreamUnavailable:
                return "upstream.unavailable"
            case .upstreamInvalidRequest:
                return "upstream.invalid_request"
            case .upstreamInvalidResponse:
                return "upstream.invalid_response"
            }
        }
    }

    package struct RequestSnapshot: Codable, Sendable {
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

    package struct CompletedRequestSnapshot: Codable, Sendable {
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

    package struct DebugSnapshot: Codable, Sendable {
        package let queue: RefreshCodeIssues.QueueSnapshot
        package let activeRequests: [RefreshCodeIssues.RequestSnapshot]
        package let recentCompletedRequests: [RefreshCodeIssues.CompletedRequestSnapshot]

        package init(
            queue: RefreshCodeIssues.QueueSnapshot,
            activeRequests: [RefreshCodeIssues.RequestSnapshot],
            recentCompletedRequests: [RefreshCodeIssues.CompletedRequestSnapshot]
        ) {
            self.queue = queue
            self.activeRequests = activeRequests
            self.recentCompletedRequests = recentCompletedRequests
        }
    }

    package final class DebugState: @unchecked Sendable {
        private struct RequestRecord: Sendable {
            let id: String
            let sessionID: String
            let queueKey: String
            let tabIdentifier: String?
            let filePath: String?
            let mode: String
            let startedAt: Date
            var lastUpdatedAt: Date
            var state: RefreshCodeIssues.RequestState
            var step: RefreshCodeIssues.Step
            var lastQueuePosition: Int?
            var metadata: [String: String]
        }

        private struct State {
            var activeRequests: [String: RequestRecord] = [:]
            var recentCompletedRequests: [RefreshCodeIssues.CompletedRequestSnapshot] = []
            var activeRequestCountWaiters: [ActiveRequestCountWaiter] = []
        }

        private struct ActiveRequestCountWaiter {
            let id: UUID
            let minimumCount: Int
            let continuation: CheckedContinuation<Void, any Error>
        }

        private let lock = NSLock()
        private var state = State()
        private let defaultRequestTimeoutSeconds: Double
        private let recentCompletedLimit: Int
        private let clock: ClockClient
        private var cancelledActiveRequestCountWaiterIDs: Set<UUID> = []

        package init(
            defaultRequestTimeoutSeconds: Double,
            recentCompletedLimit: Int = 20,
            clock: ClockClient = .liveValue
        ) {
            self.defaultRequestTimeoutSeconds = defaultRequestTimeoutSeconds
            self.recentCompletedLimit = recentCompletedLimit
            self.clock = clock
        }

        package func beginRequest(
            sessionID: String,
            queueKey: String,
            tabIdentifier: String?,
            filePath: String?,
            mode: String
        ) -> String {
            let now = clock.now()
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
                state: .waitingForPermit,
                step: .waitingForPermit,
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
                record.state = .running
                record.step = .permitAcquired
                record.lastQueuePosition = queuePosition
                record.lastUpdatedAt = now
                record.metadata["pending_for_key"] = "\(pendingForKey)"
                record.metadata["pending_total"] = "\(pendingTotal)"
            }
        }

        package func updateStep(
            requestID: String,
            step: RefreshCodeIssues.Step,
            state overrideState: RefreshCodeIssues.RequestState? = nil,
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
            outcome: RefreshCodeIssues.Outcome,
            metadata: [String: String] = [:]
        ) {
            let now = clock.now()
            lock.lock()
            guard var record = state.activeRequests.removeValue(forKey: requestID) else {
                lock.unlock()
                return
            }
            record.lastUpdatedAt = now
            record.state = outcome.finalState
            for (key, value) in metadata {
                record.metadata[key] = value
            }
            let completed = RefreshCodeIssues.CompletedRequestSnapshot(
                id: record.id,
                sessionID: record.sessionID,
                queueKey: record.queueKey,
                tabIdentifier: record.tabIdentifier,
                filePath: record.filePath,
                mode: record.mode,
                finalState: record.state.rawValue,
                finalStep: record.step.rawValue,
                startedAt: record.startedAt,
                completedAt: now,
                lastQueuePosition: record.lastQueuePosition,
                outcome: outcome.rawValue,
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

        package func snapshot() -> RefreshCodeIssues.DebugSnapshot {
            lock.lock()
            let activeRecords = Array(state.activeRequests.values)
            let recentCompleted = state.recentCompletedRequests
            lock.unlock()

            var activeByQueueKey: [String: Int] = [:]
            var waitingByQueueKey: [String: Int] = [:]
            for record in activeRecords {
                if record.state == .running {
                    activeByQueueKey[record.queueKey, default: 0] += 1
                } else {
                    waitingByQueueKey[record.queueKey, default: 0] += 1
                }
            }

            let activeRequests =
                activeRecords
                .sorted { lhs, rhs in
                    if lhs.startedAt == rhs.startedAt {
                        return lhs.id < rhs.id
                    }
                    return lhs.startedAt < rhs.startedAt
                }
                .map { record in
                    RefreshCodeIssues.RequestSnapshot(
                        id: record.id,
                        sessionID: record.sessionID,
                        queueKey: record.queueKey,
                        tabIdentifier: record.tabIdentifier,
                        filePath: record.filePath,
                        mode: record.mode,
                        state: record.state.rawValue,
                        step: record.step.rawValue,
                        startedAt: record.startedAt,
                        lastUpdatedAt: record.lastUpdatedAt,
                        lastQueuePosition: record.lastQueuePosition,
                        metadata: record.metadata
                    )
                }
            let queue = RefreshCodeIssues.QueueSnapshot(
                defaultRequestTimeoutSeconds: defaultRequestTimeoutSeconds,
                activeByQueueKey: activeByQueueKey,
                waitingByQueueKey: waitingByQueueKey,
                activeRequestCount: activeRequests.filter {
                    $0.state == RefreshCodeIssues.RequestState.running.rawValue
                }.count,
                waitingRequestCount: activeRequests.filter {
                    $0.state != RefreshCodeIssues.RequestState.running.rawValue
                }.count
            )
            return RefreshCodeIssues.DebugSnapshot(
                queue: queue,
                activeRequests: activeRequests,
                recentCompletedRequests: recentCompleted
            )
        }

        package func waitForActiveRequestCount(_ count: Int) async throws {
            guard count > 0 else {
                return
            }

            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    lock.lock()
                    if cancelledActiveRequestCountWaiterIDs.remove(waiterID) != nil {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    if activeRequestCountLocked >= count {
                        lock.unlock()
                        continuation.resume(returning: ())
                        return
                    }

                    state.activeRequestCountWaiters.append(
                        ActiveRequestCountWaiter(
                            id: waiterID,
                            minimumCount: count,
                            continuation: continuation
                        )
                    )
                    lock.unlock()
                }
            } onCancel: {
                cancelActiveRequestCountWaiter(id: waiterID)
            }
        }

        package func reset() {
            let waiters: [ActiveRequestCountWaiter]
            lock.lock()
            waiters = state.activeRequestCountWaiters
            state = State()
            lock.unlock()
            for waiter in waiters {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }

        private func updateRequest(
            requestID: String,
            mutate: (inout RequestRecord, Date) -> Void
        ) {
            let now = clock.now()
            let waiters: [ActiveRequestCountWaiter]
            lock.lock()
            guard var record = state.activeRequests[requestID] else {
                lock.unlock()
                return
            }
            mutate(&record, now)
            state.activeRequests[requestID] = record
            waiters = takeReadyActiveRequestCountWaitersLocked()
            lock.unlock()
            for waiter in waiters {
                waiter.continuation.resume(returning: ())
            }
        }

        private var activeRequestCountLocked: Int {
            state.activeRequests.values.filter { $0.state == .running }.count
        }

        private func takeReadyActiveRequestCountWaitersLocked() -> [ActiveRequestCountWaiter] {
            let activeRequestCount = activeRequestCountLocked
            var ready: [ActiveRequestCountWaiter] = []
            state.activeRequestCountWaiters.removeAll { waiter in
                if activeRequestCount >= waiter.minimumCount {
                    ready.append(waiter)
                    return true
                }
                return false
            }
            return ready
        }

        private func cancelActiveRequestCountWaiter(id: UUID) {
            let waiter: ActiveRequestCountWaiter?
            lock.lock()
            if let index = state.activeRequestCountWaiters.firstIndex(where: { $0.id == id }) {
                waiter = state.activeRequestCountWaiters.remove(at: index)
            } else {
                waiter = nil
                cancelledActiveRequestCountWaiterIDs.insert(id)
            }
            lock.unlock()

            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}
