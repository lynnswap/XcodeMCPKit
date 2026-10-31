import ABIBridge
import Foundation
import Synchronization

@safe
final class NativeExecutionOperations {
    @TaskLocal static var scope: Scope?

    private let callback: Callback
    private let hook: NativeObjCMethodHook
    private let launchSessionHook: NativeObjCMethodHook
    private let simulatorLaunchCorrection: NativeSimulatorLaunchCorrection

    @MainActor init() throws {
        let ownership = NativeLaunchOwnership()
        guard let trackerClass = NSClassFromString("IDEExecutionOperationTracker") else {
            throw NativeRuntimeError.unsupportedContract("Xcode's execution-operation tracker is unavailable")
        }
        let runtime = ABIRuntime.shared
        let callback = Callback(operation: try runtime.resolveAndWait(.objc(.method("operation", as: (() -> AnyObject?).self)), on: trackerClass))
        self.callback = callback
        simulatorLaunchCorrection = try NativeSimulatorLaunchCorrection(ownership: ownership,
            onFailure: { callback.recordFailure($0) })
        launchSessionHook = try unsafe runtime.hookCalls(
            .objc(.method("setLaunchSession:", as: ((AnyObject?) -> Void).self)), on: trackerClass,
            onFailure: { callback.recordFailure($0) }
        ) { call, session in
            let tracker = try call.receiver
            if let session, let scope = Self.scope ?? ownership.scope(for: tracker) {
                ownership.register(session, scope: scope)
            }
            try call.proceed(session)
        }
        hook = try unsafe runtime.hookInitializer(
            .objc(.method("initWithOperation:serviceTier:", as: ((AnyObject, Int32) -> AnyObject?).self)), on: trackerClass,
            onFailure: { callback.recordFailure($0) },
            after: { tracker in
                guard let tracker else { return }
                guard let scope = Self.scope else { return }
                ownership.register(tracker, scope: scope)
                if let operation = try unsafe callback.operation.unsafeInvoke(on: tracker) as? Operation {
                    let tracker = NativeExecutionTracker(tracker)
                    scope.register(operation, launch: { try tracker.launch() },
                        waitForLaunchReadiness: { try await tracker.waitForDebugger(processIdentifier: $0) },
                        cancel: { try tracker.cancel() })
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
        private struct TrackedOperation: Sendable {
            var operation: Operation
            var launch: @MainActor @Sendable () throws -> NativeApplicationLaunch?
            var waitForLaunchReadiness: @MainActor @Sendable (Int32) async throws -> Void
            var cancel: (@MainActor @Sendable () throws -> Void)?
        }

        private struct State {
            var operations: [ObjectIdentifier: TrackedOperation] = [:]
            var cancelled = false
            var failure: (any Error)?
            var cancellations: [Task<Void, Never>] = []
            var launches: [NativeApplicationLaunch.CapturedProcess] = []
            var launchesFinished = false
            var resumesTestHosts = false
        }

        private let state = Mutex(State())

        var launchesFinished: Bool { state.withLock { $0.launchesFinished } }

        func prepareTestHosts() {
            state.withLock { $0.resumesTestHosts = true }
        }

        func resumeTestHostIfNeeded(_ launch: NativeApplicationLaunch) throws {
            do {
                try state.withLock {
                    guard $0.resumesTestHosts, !$0.cancelled, !$0.launchesFinished else { return }
                    try launch.resumeIfStopped(allowTestAgent: true)
                }
            } catch {
                recordFailure(error)
                cancel()
                throw error
            }
        }

        func recordLaunch(_ launch: NativeApplicationLaunch) {
            let allowTestAgent = state.withLock { $0.resumesTestHosts }
            guard let captured = launch.captureSuspendedProcess(allowTestAgent: allowTestAgent) else { return }
            state.withLock { if !$0.launchesFinished { $0.launches.append(captured) } }
        }

        func register(_ operation: Operation, launch: @escaping @MainActor @Sendable () throws -> NativeApplicationLaunch? = { nil },
                      waitForLaunchReadiness: @escaping @MainActor @Sendable (Int32) async throws -> Void = { _ in },
                      cancel: (@MainActor @Sendable () throws -> Void)? = nil) {
            let tracked = TrackedOperation(operation: operation, launch: launch, waitForLaunchReadiness: waitForLaunchReadiness, cancel: cancel)
            let cancelled = state.withLock { state in
                state.operations[ObjectIdentifier(operation)] = tracked
                if state.cancelled { enqueueCancellation(tracked, in: &state) }
                return state.cancelled
            }
            if cancelled { operation.cancel() }
        }

        func cancel() {
            let operations = state.withLock { state -> [TrackedOperation] in
                guard !state.cancelled else { return [] }
                state.cancelled = true
                for tracked in state.operations.values { enqueueCancellation(tracked, in: &state) }
                return Array(state.operations.values)
            }
            for tracked in operations { tracked.operation.cancel() }
        }

        private func enqueueCancellation(_ tracked: TrackedOperation, in state: inout State) {
            guard !tracked.operation.isFinished, let cancel = tracked.cancel else { return }
            // The tracker also cancels Xcode's child trackers. Cancelling only
            // its Foundation Operation leaves the native producer waiting.
            let task = Task { @MainActor in
                do { try cancel() }
                catch { recordFailure(error) }
            }
            state.cancellations.append(task)
        }

        nonisolated(nonsending) func finishCancellation() async {
            var count = 0
            while true {
                let pending = state.withLock { Array($0.cancellations.dropFirst(count)) }
                guard !pending.isEmpty else { return }
                for task in pending { await task.value }
                count += pending.count
            }
        }

        // Joining the observed operations does not expose or join private Swift
        // producer Tasks retained inside a native AsyncStream.
        nonisolated(nonsending) func finish(continuingLaunchPID: Int32? = nil) async throws {
            await finishCancellation()
            var finished: Set<ObjectIdentifier> = []
            var continuing: [ObjectIdentifier: Operation] = [:]
            while true {
                let pending = state.withLock { state in
                    state.operations.filter { !finished.contains($0.key) }
                }
                guard !pending.isEmpty else { break }
                for (identifier, tracked) in pending {
                    let launch: NativeApplicationLaunch?
                    do { launch = continuingLaunchPID == nil ? nil : try await tracked.launch() }
                    catch {
                        cancel()
                        recordFailure(error)
                        launch = nil
                    }
                    if let continuingLaunchPID, let launch, launch.processIdentifier == continuingLaunchPID,
                       !state.withLock({ $0.cancelled }) {
                        do {
                            try await tracked.waitForLaunchReadiness(continuingLaunchPID)
                            try launch.resumeIfStopped()
                        }
                        catch {
                            cancel()
                            recordFailure(error)
                        }
                        continuing[identifier] = tracked.operation
                    } else {
                        await Self.waitForCompletion(of: tracked.operation)
                    }
                    finished.insert(identifier)
                }
            }
            let cancelled = state.withLock { state in
                guard !state.cancelled else { return true }
                // A completed launch belongs to the workspace. Later cancellation
                // of its finished request must not stop it without draining it.
                for identifier in continuing.keys { state.operations[identifier] = nil }
                return false
            }
            if cancelled {
                for operation in continuing.values { await Self.waitForCompletion(of: operation) }
            }
            await finishCancellation()
            let launches = state.withLock { state in
                let launches = state.cancelled ? state.launches : []
                state.launches = []
                state.launchesFinished = true
                return launches
            }
            if !launches.isEmpty {
                // Cleanup must finish even though the requesting Task is cancelled.
                let cleanup = Task { @concurrent in
                    for launch in launches {
                        do { try await launch.terminateIfStillSuspended() }
                        catch { recordFailure(error) }
                    }
                }
                await cleanup.value
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
