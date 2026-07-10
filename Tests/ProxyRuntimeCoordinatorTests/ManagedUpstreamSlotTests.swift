import Foundation
import Testing
import XcodeMCPProxyTestSupport

@testable import XcodeMCPKit
@testable import XcodeMCPProxyKit

@Suite
struct ManagedUpstreamSlotTests {
    @Test func managedUpstreamSlotClearsPendingStartWhenStartFails() async throws {
        let slot = ManagedUpstreamSlot(factory: FailingUpstreamSessionFactory())
        await slot.start()

        let first = await slot.send(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
        let second = await slot.send(Data(#"{"jsonrpc":"2.0","id":2}"#.utf8))
        await slot.stop()

        switch first {
        case .unavailable(.startFailed), .unavailable(.notStarted):
            break
        case .accepted, .backpressure, .unavailable:
            Issue.record("send during a failed start should report unavailable")
        }
        #expect(second == .unavailable(.notStarted))
    }

    @Test func managedUpstreamSlotJoinsArrayViolationStopFromExternalStop() async throws {
        let session = RecordingUpstreamSession(delaysStopCompletion: true)
        let slot = ManagedUpstreamSlot(
            factory: RecordingUpstreamSessionFactory(session: session)
        )
        await slot.start()
        #expect(
            await slot.send(Data(#"{"jsonrpc":"2.0","method":"ping"}"#.utf8))
                == .accepted
        )

        let eventTask = Task {
            var iterator = slot.events.makeAsyncIterator()
            return await iterator.next()
        }
        await session.emit(
            .message(Data(#"[{"jsonrpc":"2.0","id":1,"result":{}}]"#.utf8))
        )

        guard case .stdoutProtocolViolation(let violation) = await eventTask.value else {
            Issue.record("expected top-level array protocol violation")
            return
        }
        #expect(violation.reason == .unexpectedTopLevelArray)

        await session.waitForStopToStart()
        let completions = RecordedValues<String>()
        let externalStop = Task {
            await slot.stop()
            await completions.append("completed")
        }
        while await slot.send(Data()) != .unavailable(.shuttingDown) {
            await Task.yield()
        }
        await Task.yield()
        #expect(await completions.count() == 0)
        #expect(await session.stopCount() == 1)

        await session.releaseStop()
        await externalStop.value

        #expect(await completions.snapshot() == ["completed"])
        #expect(await session.stopCount() == 1)
    }

    @Test func managedUpstreamSlotWaitsForCancelledStartSettlementAndLateSessionStop()
        async throws
    {
        let session = RecordingUpstreamSession()
        let startCalled = AsyncGate()
        let releaseStart = AsyncGate()
        let cancellations = LockedRecordedValues<String>()
        let slot = ManagedUpstreamSlot(
            factory: DelayedUpstreamSessionFactory(
                session: session,
                startCalled: startCalled,
                releaseStart: releaseStart,
                cancellations: cancellations
            )
        )
        await slot.start()
        try await startCalled.wait()

        let completions = RecordedValues<String>()
        let firstStop = Task {
            await slot.stop()
            await completions.append("first")
        }
        let secondStop = Task {
            await slot.stop()
            await completions.append("second")
        }
        #expect(try await cancellations.nextValue(at: 0) == "cancelled")
        await Task.yield()
        #expect(await completions.count() == 0)
        #expect(await session.stopCount() == 0)

        await releaseStart.signal()
        await firstStop.value
        await secondStop.value

        #expect(await completions.snapshot().sorted() == ["first", "second"])
        #expect(await session.stopCount() == 1)
    }
}

private struct FailingUpstreamSessionFactory: UpstreamSessionFactory {
    func startSession() async throws -> any UpstreamSession {
        throw StartFailure()
    }
}

private struct StartFailure: Error {}

private struct RecordingUpstreamSessionFactory: UpstreamSessionFactory {
    let session: RecordingUpstreamSession

    func startSession() async throws -> any UpstreamSession {
        session
    }
}

private struct DelayedUpstreamSessionFactory: UpstreamSessionFactory {
    let session: RecordingUpstreamSession
    let startCalled: AsyncGate
    let releaseStart: AsyncGate
    let cancellations: LockedRecordedValues<String>

    func startSession() async throws -> any UpstreamSession {
        await startCalled.signal()
        return await withTaskCancellationHandler {
            await releaseStart.waitIgnoringCancellation()
            return session
        } onCancel: {
            cancellations.append("cancelled")
        }
    }
}

private actor RecordingUpstreamSession: UpstreamSession {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private var recordedStopCount = 0
    private let delaysStopCompletion: Bool
    private var stopStarted = false
    private var stopReleased = false
    private var stopStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(delaysStopCompletion: Bool = false) {
        self.delaysStopCompletion = delaysStopCompletion
        var continuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        _ = data
        return .accepted
    }

    func stop() async {
        recordedStopCount += 1
        stopStarted = true
        let startedWaiters = stopStartedWaiters
        stopStartedWaiters.removeAll()
        for waiter in startedWaiters {
            waiter.resume()
        }
        if delaysStopCompletion, stopReleased == false {
            await withCheckedContinuation { continuation in
                stopReleaseWaiters.append(continuation)
            }
        }
        continuation.finish()
    }

    func emit(_ event: Upstream.Event) {
        continuation.yield(event)
    }

    func stopCount() -> Int {
        recordedStopCount
    }

    func waitForStopToStart() async {
        guard stopStarted == false else { return }
        await withCheckedContinuation { continuation in
            stopStartedWaiters.append(continuation)
        }
    }

    func releaseStop() {
        stopReleased = true
        let waiters = stopReleaseWaiters
        stopReleaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
