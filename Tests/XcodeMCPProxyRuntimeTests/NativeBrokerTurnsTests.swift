import NIOConcurrencyHelpers
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

@Suite(.timeLimit(.minutes(1)))
struct NativeBrokerTurnsTests {
    @Test func turnsRunInOrderAndWaitingRequestsBeyondTheirBudgetAreRefused() async throws {
        let budget = NativeBrokerByteBudget(limit: 10)
        let turns = NativeBrokerTurns<String>()
        let otherSessionTurns = NativeBrokerTurns<String>()
        let entered = TestSignal()
        let release = TestSignal()
        let order = NIOLockedValueBox<[String]>([])
        // A running turn does not count against the budget.
        let first = Task {
            try await turns.run("w", bytes: 100, budget: budget) {
                entered.signal()
                try await release.wait(description: "release the first turn")
                order.withLockedValue { $0.append("first") }
            }
        }
        try await entered.wait(description: "first turn running")
        let second = Task { try await turns.run("w", bytes: 6, budget: budget) { order.withLockedValue { $0.append("second") } } }
        try await waitWithTimeout("second turn waiting", timeout: .seconds(5)) {
            while budget.reservedBytes != 6 { await Task.yield() }
        }

        await #expect(throws: NativeBrokerTurns<String>.Full.self) { try await turns.run("w", bytes: 6, budget: budget) {} }
        // Another key without a running turn starts at once.
        try await turns.run("other", bytes: 6, budget: budget) { order.withLockedValue { $0.append("other") } }

        // Another session's waiting request shares the budget.
        let entered2 = TestSignal()
        let release2 = TestSignal()
        let holder = Task {
            try await otherSessionTurns.run("w", bytes: 1, budget: budget) {
                entered2.signal()
                try await release2.wait(description: "release the other session's turn")
            }
        }
        try await entered2.wait(description: "other session's turn running")
        await #expect(throws: NativeBrokerTurns<String>.Full.self) {
            try await otherSessionTurns.run("w", bytes: 6, budget: budget) {}
        }
        release2.signal()
        try await holder.value

        release.signal()
        try await first.value
        try await second.value
        #expect(order.withLockedValue { $0 } == ["other", "first", "second"])
        #expect(budget.reservedBytes == 0)
    }

    @Test func aCancelledWaitingTurnLeavesTheQueue() async throws {
        let budget = NativeBrokerByteBudget(limit: 10)
        let turns = NativeBrokerTurns<String>()
        let entered = TestSignal()
        let release = TestSignal()
        let first = Task {
            try await turns.run("w", bytes: 1, budget: budget) {
                entered.signal()
                try await release.wait(description: "release the first turn")
            }
        }
        try await entered.wait(description: "first turn running")
        let waiting = Task { try await turns.run("w", bytes: 6, budget: budget) {} }
        try await waitWithTimeout("turn waiting", timeout: .seconds(5)) {
            while budget.reservedBytes != 6 { await Task.yield() }
        }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(budget.reservedBytes == 0)
        release.signal()
        try await first.value
        try await turns.run("w", bytes: 6, budget: budget) {}
    }
}
