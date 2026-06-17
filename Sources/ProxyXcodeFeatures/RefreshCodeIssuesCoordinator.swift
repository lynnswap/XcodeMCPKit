import Foundation
import NIO

extension RefreshCodeIssues {
    package actor Coordinator {
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
        case queueWaitTimedOut
    }

    private struct Waiter {
        let id: UInt64
        let permit: Permit
        let continuation: CheckedContinuation<Permit, Error>
        var state: WaiterState
        var timeoutTask: Task<Void, Never>?
    }

    private struct ActiveExecution: Sendable {
        let id: UInt64
        let cancel: @Sendable () -> Void
        let waitUntilFinished: @Sendable () async -> Void
    }

    package nonisolated let waitClock: any Clock<Duration> & Sendable
    private var nextWaiterID: UInt64 = 0
    private var nextExecutionID: UInt64 = 0
    private var busyKeys: Set<String> = []
    private var pendingWaiterCount = 0
    private var activeExecutionsByKey: [String: ActiveExecution] = [:]
    private var waitersByKey: [String: [Waiter]] = [:]

    package static func makeDefault() -> RefreshCodeIssues.Coordinator {
        RefreshCodeIssues.Coordinator()
    }

    package init(
        waitClock: any Clock<Duration> & Sendable = ContinuousClock()
    ) {
        self.waitClock = waitClock
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
        for var waiter in waiters {
            waiter.timeoutTask?.cancel()
            switch waiter.state {
            case .active, .cancelled, .timedOut:
                waiter.state = .removed
                waiter.continuation.resume(throwing: CancellationError())
            case .resumed, .removed:
                break
            }
        }
        for execution in activeExecutions {
            await execution.waitUntilFinished()
        }
        cleanupAfterReset()
    }

    package func withPermit<T: Sendable>(
        key: String,
        requestTimeout: TimeAmount?,
        body: @escaping @Sendable (_ permit: Permit) async throws -> T
    ) async throws -> T {
        let permit = try await acquire(key: key, requestTimeout: requestTimeout)
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

    private func acquire(key: String, requestTimeout: TimeAmount?) async throws -> Permit {
        if busyKeys.contains(key) == false {
            busyKeys.insert(key)
            return Permit(
                queuePosition: 0,
                pendingForKey: 0,
                pendingTotal: pendingWaiterCount
            )
        }

        let waiterCountForKey = waitersByKey[key]?.count ?? 0
        let waiterID = nextWaiterID
        nextWaiterID &+= 1
        let permit = Permit(
            queuePosition: waiterCountForKey + 1,
            pendingForKey: waiterCountForKey + 1,
            pendingTotal: pendingWaiterCount + 1
        )

        do {
            let acquiredPermit = try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { continuation in
                        var waiter = Waiter(
                            id: waiterID,
                            permit: permit,
                            continuation: continuation,
                            state: .active,
                            timeoutTask: nil
                        )
                        if let timeoutDuration = Self.duration(from: requestTimeout) {
                            waiter.timeoutTask = Task { [waitClock] in
                                do {
                                    try await waitClock.sleep(for: timeoutDuration)
                                    self.timeoutWaiter(key: key, waiterID: waiterID)
                                } catch {
                                    return
                                }
                            }
                        }
                        waitersByKey[key, default: []].append(waiter)
                        pendingWaiterCount += 1

                        if Task.isCancelled {
                            failWaiter(
                                key: key,
                                waiterID: waiterID,
                                error: CancellationError()
                            )
                        }
                    }
                },
                onCancel: {
                    Task {
                        await self.cancelWaiter(key: key, waiterID: waiterID)
                    }
                }
            )
            cancelTimeoutTask(key: key, waiterID: waiterID)
            return acquiredPermit
        } catch {
            cancelTimeoutTask(key: key, waiterID: waiterID)
            throw error
        }
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

        var waiter = waiters.remove(at: index)
        let shouldResume: Bool
        switch waiter.state {
        case .active:
            waiter.state = error is CancellationError ? .cancelled : .timedOut
            shouldResume = true
        case .cancelled, .timedOut:
            shouldResume = true
        case .resumed, .removed:
            shouldResume = false
        }
        waiter.timeoutTask?.cancel()
        waiter.state = .removed
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
            var next = next
            guard next.state == .active else {
                next.state = .removed
                pendingWaiterCount -= 1
                next.timeoutTask?.cancel()
                continue
            }
            next.timeoutTask?.cancel()
            next.state = .resumed
            pendingWaiterCount -= 1
            if waiters.isEmpty {
                waitersByKey.removeValue(forKey: key)
            } else {
                waitersByKey[key] = waiters
            }
            next.continuation.resume(returning: next.permit)
            return
        }

        busyKeys.remove(key)
        waitersByKey.removeValue(forKey: key)
    }

    private func cancelTimeoutTask(key: String, waiterID: UInt64) {
        guard var waiters = waitersByKey[key],
              let index = waiters.firstIndex(where: { $0.id == waiterID })
        else {
            return
        }
        waiters[index].timeoutTask?.cancel()
        waiters[index].timeoutTask = nil
        waitersByKey[key] = waiters
    }

    private static func duration(from requestTimeout: TimeAmount?) -> Duration? {
        guard let requestTimeout else {
            return nil
        }
        let nanoseconds = requestTimeout.nanoseconds
        guard nanoseconds > 0 else {
            return .zero
        }
        return .nanoseconds(nanoseconds)
    }
    }
}
