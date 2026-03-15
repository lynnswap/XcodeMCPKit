import Foundation

package actor RefreshCodeIssuesCoordinator {
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
    }

    package nonisolated let maxPendingPerKey: Int
    package nonisolated let maxPendingTotal: Int
    package nonisolated let queueWaitTimeoutNanoseconds: UInt64
    private var nextWaiterID: UInt64 = 0
    private var busyKeys: Set<String> = []
    private var pendingWaiterCount = 0
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
        self.maxPendingPerKey = max(0, maxPendingPerKey)
        self.maxPendingTotal = max(0, maxPendingTotal)
        self.queueWaitTimeoutNanoseconds = Self.nanoseconds(from: queueWaitTimeout)
    }

    package nonisolated var queueWaitTimeoutSeconds: Double {
        Double(queueWaitTimeoutNanoseconds) / 1_000_000_000
    }

    package func withPermit<T: Sendable>(
        key: String,
        body: @Sendable (_ permit: Permit) async throws -> T
    ) async throws -> T {
        let permit = try await acquire(key: key)
        do {
            let result = try await body(permit)
            release(key: key)
            return result
        } catch {
            release(key: key)
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

        let timeoutTask = Task { [queueWaitTimeoutNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: queueWaitTimeoutNanoseconds)
                self.timeoutWaiter(key: key, waiterID: waiterID)
            } catch {
                return
            }
        }

        return try await withTaskCancellationHandler(
            operation: {
                defer { timeoutTask.cancel() }

                return try await withCheckedThrowingContinuation { continuation in
                    waitersByKey[key, default: []].append(
                        Waiter(
                            id: waiterID,
                            permit: permit,
                            continuation: continuation
                        )
                    )
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
                timeoutTask.cancel()
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

    private func failWaiter(key: String, waiterID: UInt64, error: Error) {
        guard var waiters = waitersByKey[key],
            let index = waiters.firstIndex(where: { $0.id == waiterID })
        else {
            return
        }

        let waiter = waiters.remove(at: index)
        pendingWaiterCount -= 1
        if waiters.isEmpty {
            waitersByKey.removeValue(forKey: key)
        } else {
            waitersByKey[key] = waiters
        }
        waiter.continuation.resume(throwing: error)
    }

    private func release(key: String) {
        guard var waiters = waitersByKey[key], waiters.isEmpty == false else {
            busyKeys.remove(key)
            waitersByKey.removeValue(forKey: key)
            return
        }

        let next = waiters.removeFirst()
        pendingWaiterCount -= 1
        if waiters.isEmpty {
            waitersByKey.removeValue(forKey: key)
        } else {
            waitersByKey[key] = waiters
        }
        next.continuation.resume(returning: next.permit)
    }

    private static func nanoseconds(from interval: TimeInterval) -> UInt64 {
        let clamped = max(0, interval)
        let nanoseconds = clamped * 1_000_000_000
        if nanoseconds >= Double(UInt64.max) {
            return UInt64.max
        }
        return UInt64(nanoseconds.rounded(.up))
    }
}
