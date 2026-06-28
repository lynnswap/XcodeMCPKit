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

    private struct State: Sendable {
        var acceptsNewTasks = true
        var records: [UUID: TaskRecord] = [:]
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
            let tasks = state.records.values.compactMap(\.task)
            state.records.removeAll()
            return tasks
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
            let tasks = state.records.values.compactMap(\.task)
            state.records.removeAll()
            return tasks
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

    private func finish(_ id: UUID) {
        _ = state.withLockedValue { state in
            state.records.removeValue(forKey: id)
        }
    }
}
