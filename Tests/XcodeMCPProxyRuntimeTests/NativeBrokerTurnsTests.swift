import NIOConcurrencyHelpers
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

@Suite(.timeLimit(.minutes(1)))
struct NativeBrokerTurnsTests {
    @Test func turnsRunInOrderAndWaitingRequestsBeyondTheLimitAreRefused() async throws {
        let turns = NativeBrokerTurns<String>(maximumWaitingBytes: 10)
        let entered = TestSignal()
        let release = TestSignal()
        let order = NIOLockedValueBox<[String]>([])
        // A running turn does not count against the limit.
        let first = Task {
            try await turns.run("w", bytes: 100) {
                entered.signal()
                try await release.wait(description: "release the first turn")
                order.withLockedValue { $0.append("first") }
            }
        }
        try await entered.wait(description: "first turn running")
        let second = Task { try await turns.run("w", bytes: 6) { order.withLockedValue { $0.append("second") } } }
        try await waitWithTimeout("second turn waiting", timeout: .seconds(5)) {
            while turns.waitingBytes != 6 { await Task.yield() }
        }

        await #expect(throws: NativeBrokerTurns<String>.Full.self) { try await turns.run("w", bytes: 6) {} }
        // Another key without a running turn starts at once.
        try await turns.run("other", bytes: 6) { order.withLockedValue { $0.append("other") } }

        release.signal()
        try await first.value
        try await second.value
        #expect(order.withLockedValue { $0 } == ["other", "first", "second"])
        #expect(turns.waitingBytes == 0)
    }

    @Test func aCancelledWaitingTurnLeavesTheQueue() async throws {
        let turns = NativeBrokerTurns<String>(maximumWaitingBytes: 10)
        let entered = TestSignal()
        let release = TestSignal()
        let first = Task {
            try await turns.run("w", bytes: 1) {
                entered.signal()
                try await release.wait(description: "release the first turn")
            }
        }
        try await entered.wait(description: "first turn running")
        let waiting = Task { try await turns.run("w", bytes: 6) {} }
        try await waitWithTimeout("turn waiting", timeout: .seconds(5)) {
            while turns.waitingBytes != 6 { await Task.yield() }
        }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(turns.waitingBytes == 0)
        release.signal()
        try await first.value
        try await turns.run("w", bytes: 6) {}
    }
}
