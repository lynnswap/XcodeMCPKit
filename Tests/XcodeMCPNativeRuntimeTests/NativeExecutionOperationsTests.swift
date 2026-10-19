import Foundation
import Synchronization
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
struct NativeExecutionOperationsTests {
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
