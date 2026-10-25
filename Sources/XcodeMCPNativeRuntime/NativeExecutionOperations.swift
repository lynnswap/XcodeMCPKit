import ABIBridge
import Foundation
import Synchronization

@safe
final class NativeExecutionOperations {
    @TaskLocal static var scope: Scope?

    private let callback: Callback
    private let hook: NativeObjCMethodHook

    init() throws {
        guard let trackerClass = NSClassFromString("IDEExecutionOperationTracker") else {
            throw NativeRuntimeError.unsupportedContract("Xcode's execution-operation tracker is unavailable")
        }
        let runtime = ABIRuntime.shared
        let callback = Callback(operation: try runtime.resolveAndWait(.objc(.method("operation", as: (() -> AnyObject?).self)), on: trackerClass))
        self.callback = callback
        hook = try unsafe runtime.hookInitializer(
            .objc(.method("initWithOperation:serviceTier:", as: ((AnyObject, Int32) -> AnyObject?).self)), on: trackerClass,
            onFailure: { callback.recordFailure($0) },
            after: { tracker in
                guard let tracker else { return }
                guard let scope = Self.scope else { return }
                if let operation = try unsafe callback.operation.unsafeInvoke(on: tracker) as? Operation {
                    scope.register(operation)
                } else {
                    scope.recordFailure(NativeRuntimeError.unsupportedContract("Xcode's execution tracker does not contain an Operation"))
                }
            })
    }

    func checkFailure() throws {
        try callback.checkFailure()
    }

    // The native Objective-C initializer cannot await an actor. This scope only
    // associates its caller's native operations with the existing request owner.
    final class Scope: Sendable {
        private struct State {
            var operations: [ObjectIdentifier: Operation] = [:]
            var cancelled = false
            var failure: (any Error)?
        }

        private let state = Mutex(State())

        func register(_ operation: Operation) {
            let cancelled = state.withLock { state in
                state.operations[ObjectIdentifier(operation)] = operation
                return state.cancelled
            }
            if cancelled { operation.cancel() }
        }

        func cancel() {
            let operations = state.withLock { state -> [Operation] in
                guard !state.cancelled else { return [] }
                state.cancelled = true
                return Array(state.operations.values)
            }
            for operation in operations { operation.cancel() }
        }

        // Joining the observed operations does not expose or join private Swift
        // producer Tasks retained inside a native AsyncStream.
        nonisolated(nonsending) func finish() async throws {
            var finished: Set<ObjectIdentifier> = []
            while true {
                let pending = state.withLock { state in
                    state.operations.filter { !finished.contains($0.key) }
                }
                guard !pending.isEmpty else { break }
                for (identifier, operation) in pending {
                    await Self.waitForCompletion(of: operation)
                    finished.insert(identifier)
                }
            }
            try checkFailure()
        }

        func recordFailure(_ error: any Error) {
            state.withLock { if $0.failure == nil { $0.failure = error } }
        }

        private func checkFailure() throws {
            if let failure = state.withLock({ $0.failure }) { throw failure }
        }

        private static let completionQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "xcode.native.operation-completion"
            return queue
        }()

        private static func waitForCompletion(of operation: Operation) async {
            if operation.isFinished { return }
            await withCheckedContinuation { continuation in
                let completion = BlockOperation { continuation.resume() }
                completion.addDependency(operation)
                completionQueue.addOperation(completion)
            }
        }
    }

    // The prepared getter has immutable ABI/image data, keeps no receiver, and
    // uses separate argument storage for each synchronous native callback.
    private final class Callback: @unchecked Sendable {
        let operation: NativeObjCMethod<AnyObject?>
        private let failure = Mutex<(any Error)?>(nil)

        init(operation: NativeObjCMethod<AnyObject?>) {
            self.operation = operation
        }

        func recordFailure(_ error: any Error) {
            failure.withLock { if $0 == nil { $0 = error } }
        }

        func checkFailure() throws {
            if let error = failure.withLock({ $0 }) { throw error }
        }
    }
}
