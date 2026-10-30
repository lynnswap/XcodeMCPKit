import Foundation
import Synchronization
import Testing
@testable import XcodeMCPNativeRuntime

@Suite(.timeLimit(.minutes(1)))
struct NativeExecutionOperationsTests {
    @Test @MainActor func completedTrackersDoNotReceiveLateNativeCancellation() async throws {
        let scope = NativeExecutionOperations.Scope()
        let cancelled = Mutex(false)
        let operation = BlockOperation {}
        scope.register(operation, cancel: { cancelled.withLock { $0 = true } })
        let queue = OperationQueue()
        queue.addOperation(operation)
        try await scope.finish()

        scope.cancel()
        await scope.finishCancellation()

        #expect(!cancelled.withLock { $0 })
    }

    @Test @MainActor func cancellationStopsTheNativeWorkBeforeFinishing() async throws {
        let scope = NativeExecutionOperations.Scope()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let started = AsyncStream<Void>.makeStream()
        let operation = BlockOperation { started.continuation.yield(()); gate.wait() }
        scope.register(operation, cancel: { gate.signal() })
        let queue = OperationQueue()
        queue.addOperation(operation)
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next(isolation: MainActor.shared)

        scope.cancel()
        try await scope.finish()

        #expect(operation.isFinished)
    }

    @Test @MainActor func cancellationAlsoReachesATrackerRegisteredLater() async throws {
        let scope = NativeExecutionOperations.Scope()
        let cancelled = Mutex(false)
        scope.cancel()
        let operation = BlockOperation {}
        scope.register(operation, cancel: { cancelled.withLock { $0 = true } })
        let queue = OperationQueue()
        queue.addOperation(operation)

        try await scope.finish()

        #expect(cancelled.withLock { $0 })
        #expect(operation.isFinished)
    }

    @Test @MainActor func nativeCancellationFailureIsReportedAfterDraining() async {
        let scope = NativeExecutionOperations.Scope()
        let operation = BlockOperation {}
        scope.register(operation, cancel: { throw NativeRuntimeError.invocation("native cancellation failed") })
        scope.cancel()
        let queue = OperationQueue()
        queue.addOperation(operation)

        await #expect(throws: (any Error).self) { try await scope.finish() }
        #expect(operation.isFinished)
    }

    @Test @MainActor func onlyTheCompletedLaunchMayOutliveTheRequest() async throws {
        let scope = NativeExecutionOperations.Scope()
        let launchGate = DispatchSemaphore(value: 0)
        let workGate = DispatchSemaphore(value: 0)
        defer { launchGate.signal(); workGate.signal() }
        let started = AsyncStream<Void>.makeStream()
        let launch = BlockOperation { started.continuation.yield(()); launchGate.wait() }
        let work = BlockOperation { started.continuation.yield(()); workGate.wait() }
        scope.register(launch, launch: { NativeApplicationLaunch(processIdentifier: 42) })
        scope.register(work)
        let queue = OperationQueue()
        queue.addOperation(launch)
        queue.addOperation(work)
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next(isolation: MainActor.shared)
        _ = await iterator.next(isolation: MainActor.shared)

        let drain = Task { try await scope.finish(continuingLaunchPID: 42) }
        workGate.signal()
        try await drain.value

        #expect(work.isFinished)
        #expect(!launch.isFinished)
    }

    @Test @MainActor func aDifferentLaunchStillFinishesBeforeTheRequest() async throws {
        let scope = NativeExecutionOperations.Scope()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let started = AsyncStream<Void>.makeStream()
        let operation = BlockOperation { started.continuation.yield(()); gate.wait() }
        let resolving = AsyncStream<Void>.makeStream()
        let returned = Mutex(false)
        scope.register(operation, launch: {
            resolving.continuation.yield(())
            return NativeApplicationLaunch(processIdentifier: 7)
        })
        let queue = OperationQueue()
        queue.addOperation(operation)
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next(isolation: MainActor.shared)
        let drain = Task {
            try await scope.finish(continuingLaunchPID: 42)
            returned.withLock { $0 = true }
            #expect(operation.isFinished)
        }
        var resolution = resolving.stream.makeAsyncIterator()
        _ = await resolution.next(isolation: MainActor.shared)
        #expect(!returned.withLock { $0 })
        gate.signal()
        try await drain.value
    }

    @Test @MainActor func aCancelledLaunchCannotOutliveTheRequest() async throws {
        let scope = NativeExecutionOperations.Scope()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let started = AsyncStream<Void>.makeStream()
        let operation = BlockOperation { started.continuation.yield(()); gate.wait() }
        let resolving = AsyncStream<Void>.makeStream()
        let returned = Mutex(false)
        scope.register(operation, launch: {
            resolving.continuation.yield(())
            return NativeApplicationLaunch(processIdentifier: 42)
        })
        let queue = OperationQueue()
        queue.addOperation(operation)
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next(isolation: MainActor.shared)
        scope.cancel()
        let drain = Task {
            try await scope.finish(continuingLaunchPID: 42)
            returned.withLock { $0 = true }
            #expect(operation.isFinished)
        }
        var resolution = resolving.stream.makeAsyncIterator()
        _ = await resolution.next(isolation: MainActor.shared)
        #expect(!returned.withLock { $0 })
        gate.signal()
        try await drain.value
    }

    @Test @MainActor func aContinuingLaunchDoesNotHideRecordedFailures() async {
        let scope = NativeExecutionOperations.Scope()
        scope.register(BlockOperation {}, launch: { NativeApplicationLaunch(processIdentifier: 42) })
        scope.recordFailure(NativeRuntimeError.invocation("tracker failed"))
        await #expect(throws: (any Error).self) { try await scope.finish(continuingLaunchPID: 42) }
    }

    @Test @MainActor func cancellationAfterHandoffDoesNotStopTheWorkspaceLaunch() async throws {
        let scope = NativeExecutionOperations.Scope()
        let launch = BlockOperation {}
        scope.register(launch, launch: { NativeApplicationLaunch(processIdentifier: 42) })
        try await scope.finish(continuingLaunchPID: 42)

        scope.cancel()

        #expect(!launch.isCancelled)
    }

    @Test func cancellationOnlyAffectsOperationsFromTheMatchingRequest() {
        let first = NativeExecutionOperations.Scope()
        let second = NativeExecutionOperations.Scope()
        let cancelled = BlockOperation {}
        let retained = BlockOperation {}
        first.register(cancelled)
        second.register(retained)

        first.cancel()

        #expect(cancelled.isCancelled)
        #expect(!retained.isCancelled)
    }

    @Test func cancellationBeforeRegistrationCancelsALateNativeOperation() {
        let scope = NativeExecutionOperations.Scope()
        scope.cancel()
        let operation = BlockOperation {}

        scope.register(operation)

        #expect(operation.isCancelled)
    }

    @Test @MainActor func cancellationWaitsForTheObservedOperationToActuallyFinish() async throws {
        let scope = NativeExecutionOperations.Scope()
        let started = AsyncStream<Void>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        let completed = Mutex(false)
        let operation = BlockOperation {
            started.continuation.yield(())
            gate.wait()
            completed.withLock { $0 = true }
        }
        scope.register(operation)
        let queue = OperationQueue()
        queue.addOperation(operation)
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next(isolation: MainActor.shared)
        scope.cancel()
        let draining = AsyncStream<Void>.makeStream()
        let drain = Task { @MainActor in
            draining.continuation.yield(())
            try await scope.finish()
            #expect(operation.isFinished)
            #expect(completed.withLock { $0 })
        }
        var drainIterator = draining.stream.makeAsyncIterator()
        _ = await drainIterator.next(isolation: MainActor.shared)
        gate.signal()

        try await drain.value
    }
}
