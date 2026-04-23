import Foundation
import NIOConcurrencyHelpers

package actor RefreshCodeIssuesCoordinator {
    private enum WaiterState: Sendable {
        case active
        case cancelled
        case timedOut
        case resumed
        case removed
    }

    package struct Permit: Sendable {
        package let queuePosition: Int
        package let pendingForKey: Int
        package let pendingTotal: Int
    }

    package enum AcquireError: Error {
        case queueLimitExceeded
        case queueWaitTimedOut
    }

    private struct Waiter {
        let id: UInt64
        let permit: Permit
        let continuation: CheckedContinuation<Permit, Error>
        let state: NIOLockedValueBox<WaiterState>
    }

    private struct ActiveExecution: Sendable {
        let id: UInt64
        let cancel: @Sendable () -> Void
        let waitUntilFinished: @Sendable () async -> Void
    }

    package nonisolated let maxPendingPerKey: Int
    package nonisolated let maxPendingTotal: Int
    package nonisolated let queueWaitTimeout: Duration
    package nonisolated let queueWaitClock: any Clock<Duration> & Sendable
    private var nextWaiterID: UInt64 = 0
    private var nextExecutionID: UInt64 = 0
    private var busyKeys: Set<String> = []
    private var pendingWaiterCount = 0
    private var activeExecutionsByKey: [String: ActiveExecution] = [:]
    private var waitersByKey: [String: [Waiter]] = [:]

    package static func defaultQueueWaitTimeout(for requestTimeout: TimeInterval) -> TimeInterval {
        requestTimeout > 0 ? min(requestTimeout, 30) : 30
    }

    package static func makeDefault(requestTimeout: TimeInterval) -> RefreshCodeIssuesCoordinator {
        RefreshCodeIssuesCoordinator(
            queueWaitTimeout: defaultQueueWaitTimeout(for: requestTimeout)
        )
    }

    package init(
        maxPendingPerKey: Int = 4,
        maxPendingTotal: Int = 32,
        queueWaitTimeout: TimeInterval = 30
    ) {
        self.init(
            maxPendingPerKey: maxPendingPerKey,
            maxPendingTotal: maxPendingTotal,
            queueWaitTimeout: Self.duration(from: queueWaitTimeout),
            queueWaitClock: ContinuousClock()
        )
    }

    package init(
        maxPendingPerKey: Int = 4,
        maxPendingTotal: Int = 32,
        queueWaitTimeout: Duration,
        queueWaitClock: any Clock<Duration> & Sendable = ContinuousClock()
    ) {
        self.maxPendingPerKey = max(0, maxPendingPerKey)
        self.maxPendingTotal = max(0, maxPendingTotal)
        self.queueWaitTimeout = queueWaitTimeout
        self.queueWaitClock = queueWaitClock
    }

    package nonisolated var queueWaitTimeoutSeconds: Double {
        Self.seconds(from: queueWaitTimeout)
    }

    package nonisolated func scheduleReset() {
        Task {
            await self.reset()
        }
    }

    package func reset() async {
        let waiters = waitersByKey.values.flatMap { $0 }
        let activeExecutions = Array(activeExecutionsByKey.values)
        pendingWaiterCount = 0
        waitersByKey.removeAll()

        for execution in activeExecutions {
            execution.cancel()
        }
        for waiter in waiters {
            let shouldResume = waiter.state.withLockedValue { state -> Bool in
                switch state {
                case .active, .cancelled, .timedOut:
                    state = .removed
                    return true
                case .resumed, .removed:
                    return false
                }
            }
            if shouldResume {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
        for execution in activeExecutions {
            await execution.waitUntilFinished()
        }
        cleanupAfterReset()
    }

    package func withPermit<T: Sendable>(
        key: String,
        body: @escaping @Sendable (_ permit: Permit) async throws -> T
    ) async throws -> T {
        let permit = try await acquire(key: key)
        let executionID = nextExecutionID
        nextExecutionID &+= 1
        let bodyTask = Task {
            try await body(permit)
        }
        activeExecutionsByKey[key] = ActiveExecution(
            id: executionID,
            cancel: {
                bodyTask.cancel()
            },
            waitUntilFinished: {
                _ = try? await bodyTask.value
            }
        )
        do {
            let result = try await withTaskCancellationHandler(
                operation: {
                    try await bodyTask.value
                },
                onCancel: {
                    bodyTask.cancel()
                }
            )
            release(key: key, executionID: executionID)
            return result
        } catch {
            bodyTask.cancel()
            release(key: key, executionID: executionID)
            throw error
        }
    }

    private func acquire(key: String) async throws -> Permit {
        if busyKeys.contains(key) == false {
            busyKeys.insert(key)
            return Permit(
                queuePosition: 0,
                pendingForKey: 0,
                pendingTotal: pendingWaiterCount
            )
        }

        let waiterCountForKey = waitersByKey[key]?.count ?? 0
        guard waiterCountForKey < maxPendingPerKey, pendingWaiterCount < maxPendingTotal else {
            throw AcquireError.queueLimitExceeded
        }

        let waiterID = nextWaiterID
        nextWaiterID &+= 1
        let permit = Permit(
            queuePosition: waiterCountForKey + 1,
            pendingForKey: waiterCountForKey + 1,
            pendingTotal: pendingWaiterCount + 1
        )
        let waiterState = NIOLockedValueBox(WaiterState.active)

        let timeoutTaskBox = NIOLockedValueBox<Task<Void, Never>?>(nil)

        return try await withTaskCancellationHandler(
            operation: {
                defer {
                    timeoutTaskBox.withLockedValue { task in
                        task?.cancel()
                        task = nil
                    }
                }

                return try await withCheckedThrowingContinuation { continuation in
                    waitersByKey[key, default: []].append(
                        Waiter(
                            id: waiterID,
                            permit: permit,
                            continuation: continuation,
                            state: waiterState
                        )
                    )
                    pendingWaiterCount += 1

                    let timeoutTask = Task { [queueWaitClock, queueWaitTimeout, waiterState] in
                        do {
                            try await queueWaitClock.sleep(for: queueWaitTimeout)
                            let shouldRemove = waiterState.withLockedValue { state -> Bool in
                                guard state == .active else { return false }
                                state = .timedOut
                                return true
                            }
                            guard shouldRemove else { return }
                            self.timeoutWaiter(key: key, waiterID: waiterID)
                        } catch {
                            return
                        }
                    }
                    timeoutTaskBox.withLockedValue { task in
                        task = timeoutTask
                    }

                    if Task.isCancelled {
                        let shouldFail = waiterState.withLockedValue { state -> Bool in
                            guard state == .active else { return false }
                            state = .cancelled
                            return true
                        }
                        guard shouldFail else { return }
                        failWaiter(
                            key: key,
                            waiterID: waiterID,
                            error: CancellationError()
                        )
                    }
                }
            },
            onCancel: {
                timeoutTaskBox.withLockedValue { task in
                    task?.cancel()
                    task = nil
                }
                let shouldRemove = waiterState.withLockedValue { state -> Bool in
                    guard state == .active else { return false }
                    state = .cancelled
                    return true
                }
                guard shouldRemove else { return }
                Task {
                    await self.cancelWaiter(key: key, waiterID: waiterID)
                }
            }
        )
    }

    private func cancelWaiter(key: String, waiterID: UInt64) {
        failWaiter(key: key, waiterID: waiterID, error: CancellationError())
    }

    private func timeoutWaiter(key: String, waiterID: UInt64) {
        failWaiter(
            key: key,
            waiterID: waiterID,
            error: AcquireError.queueWaitTimedOut
        )
    }

    private func cleanupAfterReset() {
        waitersByKey = waitersByKey.filter { _, waiters in
            waiters.isEmpty == false
        }
        pendingWaiterCount = waitersByKey.values.reduce(into: 0) { count, waiters in
            count += waiters.count
        }
        busyKeys = busyKeys.filter { key in
            activeExecutionsByKey[key] != nil || (waitersByKey[key]?.isEmpty == false)
        }
    }

    private func failWaiter(key: String, waiterID: UInt64, error: Error) {
        guard var waiters = waitersByKey[key],
            let index = waiters.firstIndex(where: { $0.id == waiterID })
        else {
            return
        }

        let waiter = waiters.remove(at: index)
        let shouldResume = waiter.state.withLockedValue { state -> Bool in
            switch state {
            case .active, .cancelled, .timedOut:
                state = .removed
                return true
            case .resumed, .removed:
                return false
            }
        }
        guard shouldResume else {
            if waiters.isEmpty {
                waitersByKey.removeValue(forKey: key)
            } else {
                waitersByKey[key] = waiters
            }
            return
        }
        pendingWaiterCount -= 1
        if waiters.isEmpty {
            waitersByKey.removeValue(forKey: key)
        } else {
            waitersByKey[key] = waiters
        }
        waiter.continuation.resume(throwing: error)
    }

    private func release(key: String, executionID: UInt64) {
        guard activeExecutionsByKey[key]?.id == executionID else {
            return
        }
        activeExecutionsByKey.removeValue(forKey: key)
        guard var waiters = waitersByKey[key], waiters.isEmpty == false else {
            busyKeys.remove(key)
            waitersByKey.removeValue(forKey: key)
            return
        }

        while let next = waiters.first {
            waiters.removeFirst()
            let shouldResume = next.state.withLockedValue { state -> Bool in
                guard state == .active else {
                    state = .removed
                    return false
                }
                state = .resumed
                return true
            }
            pendingWaiterCount -= 1
            if shouldResume {
                if waiters.isEmpty {
                    waitersByKey.removeValue(forKey: key)
                } else {
                    waitersByKey[key] = waiters
                }
                next.continuation.resume(returning: next.permit)
                return
            }
        }

        busyKeys.remove(key)
        waitersByKey.removeValue(forKey: key)
    }

    private static func nanoseconds(from interval: TimeInterval) -> UInt64 {
        let clamped = max(0, interval)
        let nanoseconds = clamped * 1_000_000_000
        if nanoseconds >= Double(UInt64.max) {
            return UInt64.max
        }
        return UInt64(nanoseconds.rounded(.up))
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
    }

    private static func duration(from interval: TimeInterval) -> Duration {
        let clampedNanoseconds = min(nanoseconds(from: interval), UInt64(Int64.max))
        return .nanoseconds(Int64(clampedNanoseconds))
    }
}
