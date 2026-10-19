import Foundation

package struct NativeExecutionResource: Sendable {
    package var workspace: String?
    package var processExclusive: Bool
    package var heavy: Bool

    package init(workspace: String? = nil, processExclusive: Bool = false, heavy: Bool = false) {
        self.workspace = workspace
        self.processExclusive = processExclusive
        self.heavy = heavy
    }
}

package actor NativeExecutionQueue {
    package struct Permit: Sendable {
        fileprivate let identifier: UUID
    }

    private struct Waiter {
        let identifier: UUID
        let resource: NativeExecutionResource
        let bytes: Int
        let continuation: CheckedContinuation<Permit, any Error>
    }

    private let maximumConcurrentOperations: Int
    private let maximumHeavyOperations: Int
    private let maximumQueuedBytes: Int
    private var active: [UUID: NativeExecutionResource] = [:]
    private var waiting: [Waiter] = []
    private var queuedBytes = 0
    private var stopped = false

    package init(maximumConcurrentOperations: Int = 4, maximumHeavyOperations: Int = 1,
                 maximumQueuedBytes: Int = 32 * 1024 * 1024) {
        precondition(maximumConcurrentOperations > 0 && maximumHeavyOperations > 0 && maximumQueuedBytes >= 0)
        self.maximumConcurrentOperations = maximumConcurrentOperations
        self.maximumHeavyOperations = maximumHeavyOperations
        self.maximumQueuedBytes = maximumQueuedBytes
    }

    package func acquire(_ resource: NativeExecutionResource, requestBytes: Int) async throws -> Permit {
        try Task.checkCancellation()
        let identifier = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !stopped, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if canRun(resource), !waiting.contains(where: { conflicts($0.resource, resource) }) {
                    active[identifier] = resource
                    continuation.resume(returning: Permit(identifier: identifier))
                    return
                }
                guard requestBytes <= maximumQueuedBytes - queuedBytes else {
                    continuation.resume(throwing: NativeRuntimeError.unavailable(
                        "Native execution queue exceeds its queued request limit (\(maximumQueuedBytes) bytes)"))
                    return
                }
                queuedBytes += requestBytes
                waiting.append(Waiter(identifier: identifier, resource: resource, bytes: requestBytes,
                                      continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(identifier) }
        }
    }

    package func release(_ permit: Permit) {
        active.removeValue(forKey: permit.identifier)
        drain()
    }

    package func shutdown() {
        stopped = true
        let pending = waiting
        waiting.removeAll()
        queuedBytes = 0
        for waiter in pending { waiter.continuation.resume(throwing: CancellationError()) }
    }

    private func cancel(_ identifier: UUID) {
        guard let index = waiting.firstIndex(where: { $0.identifier == identifier }) else { return }
        let waiter = waiting.remove(at: index)
        queuedBytes -= waiter.bytes
        waiter.continuation.resume(throwing: CancellationError())
        drain()
    }

    private func conflicts(_ left: NativeExecutionResource, _ right: NativeExecutionResource) -> Bool {
        left.processExclusive || right.processExclusive
            || (left.workspace != nil && left.workspace == right.workspace)
            || (left.heavy && right.heavy)
    }

    private func canRun(_ resource: NativeExecutionResource) -> Bool {
        guard active.count < maximumConcurrentOperations else { return false }
        if resource.heavy, active.values.filter(\.heavy).count >= maximumHeavyOperations { return false }
        return !active.values.contains {
            $0.processExclusive || resource.processExclusive
                || ($0.workspace != nil && $0.workspace == resource.workspace)
        }
    }

    private func drain() {
        guard !stopped else { return }
        var index = 0
        while index < waiting.count {
            let waiter = waiting[index]
            if canRun(waiter.resource),
               !waiting[..<index].contains(where: { conflicts($0.resource, waiter.resource) }) {
                waiting.remove(at: index)
                queuedBytes -= waiter.bytes
                active[waiter.identifier] = waiter.resource
                waiter.continuation.resume(returning: Permit(identifier: waiter.identifier))
            } else {
                index += 1
            }
        }
    }
}
