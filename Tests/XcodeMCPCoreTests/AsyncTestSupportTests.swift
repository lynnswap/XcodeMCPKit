import Testing
@testable import XcodeMCPCoreTestSupport

@Suite struct AsyncTestSupportTests {
    @Test func waitWithTimeoutFailsFastWhenOperationIgnoresCancellation() async throws {
        let releaseGate = CancellationIgnoringGate()

        await #expect(throws: AsyncTestTimeoutError.self) {
            _ = try await waitWithTimeout(
                "operation ignored cancellation",
                timeout: .milliseconds(10)
            ) {
                await releaseGate.wait()
                return true
            }
        }

        await releaseGate.signal()
    }

    @Test func testClockSuspensionWaitFailsFastWhenSleeperNeverRegisters() async {
        let clock = TestClock()

        await #expect(throws: AsyncTestTimeoutError.self) {
            try await clock.sleep(
                untilSuspendedBy: 1,
                timeout: .milliseconds(10),
                description: "sleeper never registered"
            )
        }
    }
}

private actor CancellationIgnoringGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func signal() {
        continuation?.resume()
        continuation = nil
    }
}
