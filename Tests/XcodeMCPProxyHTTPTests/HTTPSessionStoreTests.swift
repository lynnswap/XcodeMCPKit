import Foundation
import NIO
import NIOEmbedded
import Synchronization
import Testing

@testable import XcodeMCPProxyHTTP
import XcodeMCPProxyRuntimeContract

@Suite
struct HTTPSessionStoreTests {
    @Test func requestsAndStreamsKeepASessionUntilItsGraceEnds() throws {
        let runtime = SessionRecordingRuntime()
        let clock = ManualUptime()
        let store = HTTPSessionStore(runtime: runtime, delivery: HTTPEventDeliveryStore(),
                                     uptimeNanoseconds: { clock.now })
        let id = ProxySessionID(rawValue: "session")
        let grace = TimeAmount.seconds(10)
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }

        // The `initialize` request holds the session it creates.
        _ = try store.create(id)
        clock.now = 20_000_000_000
        store.expire(inactiveFor: grace)
        #expect(store.phase(of: id) != nil)

        store.release(id)
        #expect(store.openStream(id, channel: channel))
        clock.now = 40_000_000_000
        store.expire(inactiveFor: grace)
        #expect(store.phase(of: id) != nil)

        store.closeStream(id, channel: channel)
        clock.now = 45_000_000_000
        store.expire(inactiveFor: grace)
        #expect(store.phase(of: id) != nil)

        clock.now = 50_000_000_000
        store.expire(inactiveFor: grace)
        #expect(store.phase(of: id) == nil)
        #expect(store.acquire(id) == nil)
        #expect(runtime.closeCounts == [id: 1])
    }

    @Test func eachWayToEndASessionClosesItsRuntimeSessionOnce() throws {
        let runtime = SessionRecordingRuntime()
        let store = HTTPSessionStore(runtime: runtime, delivery: HTTPEventDeliveryStore())
        let deleted = ProxySessionID(rawValue: "deleted")
        let expired = ProxySessionID(rawValue: "expired")
        let remaining = ProxySessionID(rawValue: "remaining")
        for id in [deleted, expired, remaining] { _ = try store.create(id) }
        store.release(expired)

        #expect(store.delete(deleted))
        #expect(!store.delete(deleted))
        store.expire(inactiveFor: .nanoseconds(0))
        store.expire(inactiveFor: .nanoseconds(0))
        store.closeAll()
        store.closeAll()
        // A request that finishes after its session ended changes nothing.
        store.release(remaining)
        store.expire(inactiveFor: .nanoseconds(0))

        #expect(runtime.closeCounts == [deleted: 1, expired: 1, remaining: 1])
    }

    /// A session opened while the runtime resets would keep runtime state that the reset discards.
    @Test func noSessionStartsWhileTheRuntimeResets() async throws {
        let runtime = SessionRecordingRuntime()
        let store = HTTPSessionStore(runtime: runtime, delivery: HTTPEventDeliveryStore())
        let existing = ProxySessionID(rawValue: "existing")
        let duringReset = ProxySessionID(rawValue: "during-reset")
        _ = try store.create(existing)

        await store.closeAll {
            #expect(throws: ProxyRuntimeUnavailable.self) { try store.create(duringReset) }
        }
        #expect(store.phase(of: existing) == nil)
        #expect(store.phase(of: duringReset) == nil)
        #expect(runtime.closeCounts == [existing: 1])

        let afterReset = ProxySessionID(rawValue: "after-reset")
        _ = try store.create(afterReset)
        #expect(store.phase(of: afterReset) == .initializing)
    }

    /// A session opened just before a reset may be closed by it, even if the reset ends before the
    /// session is stored.
    @Test func aSessionOpenedBeforeAResetIsNotKeptAfterIt() throws {
        let runtime = SessionRecordingRuntime()
        let store = HTTPSessionStore(runtime: runtime, delivery: HTTPEventDeliveryStore())
        let id = ProxySessionID(rawValue: "overlapping")
        runtime.onOpen.withLock { onOpen in
            onOpen = {
                let reset = DispatchSemaphore(value: 0)
                Task {
                    await store.closeAll {}
                    reset.signal()
                }
                reset.wait()
            }
        }

        #expect(throws: ProxyRuntimeUnavailable.self) { try store.create(id) }
        #expect(store.phase(of: id) == nil)
        #expect(runtime.closeCounts == [id: 1])
    }
}

private final class ManualUptime: Sendable {
    private let value = Mutex<UInt64>(0)

    var now: UInt64 {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

private final class SessionRecordingRuntime: ProxyRuntimeServing {
    private let closes = Mutex<[ProxySessionID: Int]>([:])

    /// Runs inside `openSession`, before it returns.
    let onOpen = Mutex<(@Sendable () -> Void)?>(nil)

    var closeCounts: [ProxySessionID: Int] { closes.withLock { $0 } }

    func start() {}
    func cancelForDeinit() {}
    func shutdown() async {}

    func openSession(_ id: ProxySessionID,
                     notify _: @escaping @Sendable (Data) -> Void) throws -> any ProxyRuntimeSession {
        onOpen.withLock { $0 }?()
        return Session { self.closes.withLock { $0[id, default: 0] += 1 } }
    }

    func snapshot() -> ProxyRuntimeSnapshot {
        ProxyRuntimeSnapshot(generatedAt: Date(), hosts: [])
    }

    func debugSnapshotData(includeSensitivePayloads _: Bool) -> Data? { nil }

    func reset() async {}

    private struct Answered: ProxyRuntimeCall {
        var reply: ProxyRuntimeReply { .accepted }
        func cancel() {}
    }

    private struct Session: ProxyRuntimeSession {
        let onClose: @Sendable () -> Void

        func receive(_: ProxyRuntimeRequest) -> any ProxyRuntimeCall { Answered() }
        func close() { onClose() }
    }
}
