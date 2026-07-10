import Foundation
import Testing

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

    @Test func managedUpstreamSlotStopsSessionOnTopLevelArray() async throws {
        let session = RecordingUpstreamSession()
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

        await slot.stop()
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

private actor RecordingUpstreamSession: UpstreamSession {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private var recordedStopCount = 0

    init() {
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
        continuation.finish()
    }

    func emit(_ event: Upstream.Event) {
        continuation.yield(event)
    }

    func stopCount() -> Int {
        recordedStopCount
    }
}
