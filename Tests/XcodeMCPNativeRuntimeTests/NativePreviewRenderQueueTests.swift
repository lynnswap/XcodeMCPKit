import Foundation
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewRenderQueueTests {
    @Test func queuedCancellationReturnsBeforeTheActiveRenderFinishes() async throws {
        let queue = NativePreviewRenderQueue()
        let gate = NativePreviewQueueGate()
        let events = NativePreviewQueueEvents()
        let first = Task {
            try await queue.withAccess(to: "workspace") {
                await gate.wait()
                events.values.append("first")
            }
        }
        await gate.waitUntilEntered()
        let attempted = AsyncStream<Void>.makeStream()
        let cancelled = Task {
            attempted.continuation.yield(())
            try await queue.withAccess(to: "workspace") { events.values.append("cancelled") }
        }
        var iterator = attempted.stream.makeAsyncIterator()
        _ = await iterator.next(isolation: MainActor.shared)
        cancelled.cancel()
        let result = await cancelled.result

        if case .failure(let error) = result { #expect(error is CancellationError) }
        else { Issue.record("The queued render completed after cancellation") }
        #expect(events.values.isEmpty)

        let next = Task {
            try await queue.withAccess(to: "workspace") { events.values.append("next") }
        }
        gate.release()
        try await first.value
        try await next.value
        #expect(events.values == ["first", "next"])
    }

    @Test(arguments: [false, true])
    func serialAccessReleasesAfterFailureAndLeavesOtherWorkspacesIndependent(cancelOwner: Bool) async throws {
        let queue = NativePreviewRenderQueue()
        let gate = NativePreviewQueueGate()
        let events = NativePreviewQueueEvents()
        let first = Task {
            try await queue.withAccess(to: "first-workspace") {
                await gate.wait()
                events.values.append("first")
                try Task.checkCancellation()
                throw NativePreviewQueueFailure()
            }
        }
        await gate.waitUntilEntered()
        let attempted = AsyncStream<Void>.makeStream()
        let second = Task {
            attempted.continuation.yield(())
            try await queue.withAccess(to: "first-workspace") { events.values.append("second") }
        }
        var iterator = attempted.stream.makeAsyncIterator()
        _ = await iterator.next(isolation: MainActor.shared)

        try await queue.withAccess(to: "other-workspace") { events.values.append("other") }
        #expect(events.values == ["other"])
        if cancelOwner { first.cancel() }
        gate.release()
        let result = await first.result
        if case .failure(let error) = result {
            #expect(cancelOwner ? error is CancellationError : error is NativePreviewQueueFailure)
        } else { Issue.record("The active render unexpectedly succeeded") }
        try await second.value
        #expect(events.values == ["other", "first", "second"])
    }
}

private struct NativePreviewQueueFailure: Error {}

@MainActor
private final class NativePreviewQueueEvents {
    var values: [String] = []
}

@MainActor
private final class NativePreviewQueueGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private let entered = AsyncStream<Void>.makeStream()

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.continuation.yield(())
        }
    }

    func waitUntilEntered() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next(isolation: MainActor.shared)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
