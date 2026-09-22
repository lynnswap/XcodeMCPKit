import Foundation
import NIOConcurrencyHelpers

package final class AsyncTaskSupervisor: @unchecked Sendable {
    package struct Drain: Sendable {
        fileprivate let tasks: [Task<Void, Never>]

        package func wait() async {
            for task in tasks {
                await task.value
            }
        }
    }

    private final class TaskRecord: @unchecked Sendable {
        let id = UUID()
        var task: Task<Void, Never>?
    }

    private struct IdleWaiter: Sendable {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var acceptsNewTasks = true
        var records: [UUID: TaskRecord] = [:]
        var idleWaiters: [UUID: IdleWaiter] = [:]
    }

    private let state = NIOLockedValueBox(State())

    package init() {}

    @discardableResult
    package func run(_ operation: @escaping @Sendable () async -> Void) -> Bool {
        let record = TaskRecord()
        let accepted = state.withLockedValue { state in
            guard state.acceptsNewTasks else {
                return false
            }
            state.records[record.id] = record
            record.task = Task { [weak self, record] in
                await operation()
                self?.finish(record.id)
            }
            return true
        }
        return accepted
    }

    package func cancelAll() {
        let tasks = state.withLockedValue { state -> [Task<Void, Never>] in
            state.records.values.compactMap(\.task)
        }
        for task in tasks {
            task.cancel()
        }
    }

    package func shutdown() async {
        let drain = beginShutdown()
        await drain.wait()
    }

    package func beginShutdown() -> Drain {
        let tasks = state.withLockedValue { state -> [Task<Void, Never>] in
            state.acceptsNewTasks = false
            return state.records.values.compactMap(\.task)
        }
        for task in tasks {
            task.cancel()
        }
        return Drain(tasks: tasks)
    }

    package func drainCurrentTasks() -> Drain {
        let tasks = state.withLockedValue { state -> [Task<Void, Never>] in
            state.records.values.compactMap(\.task)
        }
        return Drain(tasks: tasks)
    }

    package func waitUntilIdle() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = state.withLockedValue { state in
                    guard Task.isCancelled == false,
                          state.records.isEmpty == false else {
                        return true
                    }
                    state.idleWaiters[waiterID] = IdleWaiter(
                        id: waiterID,
                        continuation: continuation
                    )
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.cancelIdleWaiter(id: waiterID)
        }
    }

    private func finish(_ id: UUID) {
        let idleWaiters = state.withLockedValue { state -> [IdleWaiter] in
            state.records.removeValue(forKey: id)
            guard state.records.isEmpty else {
                return []
            }
            let waiters = Array(state.idleWaiters.values)
            state.idleWaiters.removeAll()
            return waiters
        }
        for waiter in idleWaiters {
            waiter.continuation.resume()
        }
    }

    private func cancelIdleWaiter(id: UUID) {
        let waiter = state.withLockedValue { state in
            state.idleWaiters.removeValue(forKey: id)
        }
        waiter?.continuation.resume()
    }
}
