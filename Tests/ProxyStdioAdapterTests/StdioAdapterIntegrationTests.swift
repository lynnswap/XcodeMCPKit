import Foundation
import Testing
import XcodeMCPKit
import XcodeMCPProxyTestSupport
@testable import XcodeMCPProxyKit

@Suite(.serialized)
struct StdioAdapterContractTests {
    @Test func eofWithInFlightStalledRequestClosesAndCancelsClientAfterDrainTimeout() async throws {
        // Avoid false 5s timeouts when nested swift build contract tests run concurrently.
        try await TestResourceGate.withProcessHeavyStdioAdapterAccess {
            try await runEOFWithInFlightStalledRequestClosesAndCancelsClientAfterDrainTimeout()
        }
    }

    private func runEOFWithInFlightStalledRequestClosesAndCancelsClientAfterDrainTimeout()
        async throws
    {
        let shutdownClocks = makeStdioAdapterShutdownClocks()
        let client = StalledStdioAdapterHTTPClient()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let adapter = StdioAdapter(
            requestTimeout: 0,
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting,
            client: client,
            shutdownPolicy: shutdownClocks.policy
        )

        await adapter.start()
        let waitCompleted = AsyncGate()
        let waitTask = Task {
            await adapter.wait()
            await waitCompleted.signal()
        }
        var inputClosed = false
        var outputClosed = false

        func closeInput() {
            guard !inputClosed else { return }
            inputPipe.fileHandleForWriting.closeFile()
            inputClosed = true
        }

        func closeOutput() {
            guard !outputClosed else { return }
            outputPipe.fileHandleForWriting.closeFile()
            outputClosed = true
        }

        do {
            inputPipe.fileHandleForWriting.write(Data(toolsListRequest.utf8) + Data("\n".utf8))
            let sentBody = try await client.sentBody()
            #expect(sentBody == Data(toolsListRequest.utf8))

            closeInput()
            try await waitUntilDrainSleepSuspended(shutdownClocks)
            #expect(await client.closeCallCount() == 0)
            #expect(await client.networkCancellationCallCount() == 0)

            advanceStdioAdapterShutdownClocks(shutdownClocks, by: .seconds(1))

            let closeCall = try await client.closeCall()
            #expect(closeCall.deleteTimeout == nil)
            #expect(closeCall.deleteSessionGrace == .milliseconds(250))

            try await client.networkCancellation()
            try await client.sendCancellation()
            try await waitWithTimeout("adapter wait completed after drain timeout") {
                try await waitCompleted.wait()
            }
        } catch {
            closeInput()
            await client.releaseStalledSends()
            await adapter.stop()
            waitTask.cancel()
            closeOutput()
            throw error
        }

        closeOutput()
        await waitTask.value
    }

    @Test func fatalInputProtocolViolationCancelsClientAndFinishesWaitWithoutSendingUpstream() async throws {
        // Avoid false 5s timeouts when nested swift build contract tests run concurrently.
        try await TestResourceGate.withProcessHeavyStdioAdapterAccess {
            try await runFatalInputProtocolViolationCancelsClientAndFinishesWaitWithoutSendingUpstream()
        }
    }

    private func runFatalInputProtocolViolationCancelsClientAndFinishesWaitWithoutSendingUpstream()
        async throws
    {
        let client = StalledStdioAdapterHTTPClient()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let adapter = StdioAdapter(
            requestTimeout: 0,
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting,
            client: client,
            shutdownPolicy: .live
        )

        await adapter.start()
        let waitCompleted = AsyncGate()
        let waitTask = Task {
            await adapter.wait()
            await waitCompleted.signal()
        }
        var inputClosed = false
        var outputClosed = false

        func closeInput() {
            guard !inputClosed else { return }
            inputPipe.fileHandleForWriting.closeFile()
            inputClosed = true
        }

        func closeOutput() {
            guard !outputClosed else { return }
            outputPipe.fileHandleForWriting.closeFile()
            outputClosed = true
        }

        do {
            inputPipe.fileHandleForWriting.write(Data("Content-Length: abc\r\n\r\n{}".utf8))

            try await client.networkCancellation()
            try await waitWithTimeout("adapter wait completed after fatal input violation") {
                try await waitCompleted.wait()
            }
            #expect(await client.sendCallCount() == 0)
            #expect(await client.closeCallCount() == 0)
        } catch {
            closeInput()
            await client.releaseStalledSends()
            await adapter.stop()
            waitTask.cancel()
            closeOutput()
            throw error
        }

        closeInput()
        closeOutput()
        await waitTask.value
    }
}

private let toolsListRequest = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#

private struct ControlledStdioAdapterShutdownClocks: Sendable {
    let policy: StdioAdapterShutdownPolicy
    let timeoutClock: TestClock
    let uptimeClock: TestUptimeClock
}

private func makeStdioAdapterShutdownClocks() -> ControlledStdioAdapterShutdownClocks {
    let timeoutClock = TestClock()
    let uptimeClock = TestUptimeClock()
    let clock = ClockClient(
        now: {
            Date(timeIntervalSince1970: Double(uptimeClock.now()) / 1_000_000_000)
        },
        uptimeNanoseconds: uptimeClock.now,
        sleep: { duration in
            try? await timeoutClock.sleep(for: duration)
        },
        sleepForTimeInterval: { _ in }
    )
    return ControlledStdioAdapterShutdownClocks(
        policy: StdioAdapterShutdownPolicy(clock: clock),
        timeoutClock: timeoutClock,
        uptimeClock: uptimeClock
    )
}

private func waitUntilDrainSleepSuspended(
    _ clocks: ControlledStdioAdapterShutdownClocks
) async throws {
    try await waitWithTimeout("waiting for adapter drain timeout sleep") {
        try await clocks.timeoutClock.sleep(untilSuspendedBy: 1)
    }
}

private func advanceStdioAdapterShutdownClocks(
    _ clocks: ControlledStdioAdapterShutdownClocks,
    by duration: Duration
) {
    clocks.uptimeClock.advance(by: duration)
    clocks.timeoutClock.advance(by: duration)
}

private struct StdioAdapterCloseCall: Sendable {
    let deleteTimeout: Duration?
    let deleteSessionGrace: Duration?
}

private final class StalledStdioAdapterHTTPClient: StdioAdapterHTTPClient {
    let events = AsyncStream<Data> { continuation in
        continuation.finish()
    }

    private let sendBodies = RecordedValues<Data>()
    private let closeCalls = RecordedValues<StdioAdapterCloseCall>()
    private let networkCancellationCalls = RecordedValues<Void>()
    private let sendCancellationCalls = RecordedValues<Void>()
    private let stalledSends = StalledSendContinuations()

    func send(
        _ data: Data,
        onMessage: @Sendable (Data) async throws -> StreamableHTTPMCPClientMessageDisposition
    ) async throws -> StreamableHTTPMCPClientSendResult {
        _ = onMessage
        await sendBodies.append(data)
        do {
            return try await stalledSends.wait()
        } catch is CancellationError {
            await sendCancellationCalls.append(())
            throw CancellationError()
        }
    }

    func startEventStreamIfReady() async {}

    func close(
        deleteTimeout: Duration?,
        deleteSessionGrace: Duration?,
        clock: ClockClient
    ) async {
        _ = clock
        await closeCalls.append(
            StdioAdapterCloseCall(
                deleteTimeout: deleteTimeout,
                deleteSessionGrace: deleteSessionGrace
            )
        )
    }

    func cancelNetworkRequests() async {
        await networkCancellationCalls.append(())
    }

    func sentBody(at index: Int = 0) async throws -> Data {
        try await waitWithTimeout("waiting for fake client send") {
            try await self.sendBodies.nextValue(at: index)
        }
    }

    func closeCall(at index: Int = 0) async throws -> StdioAdapterCloseCall {
        try await waitWithTimeout("waiting for fake client close") {
            try await self.closeCalls.nextValue(at: index)
        }
    }

    func networkCancellation(at index: Int = 0) async throws {
        _ = try await waitWithTimeout("waiting for fake client cancellation") {
            try await self.networkCancellationCalls.nextValue(at: index)
        }
    }

    func sendCancellation(at index: Int = 0) async throws {
        _ = try await waitWithTimeout("waiting for stalled send cancellation") {
            try await self.sendCancellationCalls.nextValue(at: index)
        }
    }

    func sendCallCount() async -> Int {
        await sendBodies.count()
    }

    func closeCallCount() async -> Int {
        await closeCalls.count()
    }

    func networkCancellationCallCount() async -> Int {
        await networkCancellationCalls.count()
    }

    func releaseStalledSends() async {
        await stalledSends.releaseAll()
    }
}

private actor StalledSendContinuations {
    private typealias Continuation = CheckedContinuation<StreamableHTTPMCPClientSendResult, Error>

    private var waiters: [UUID: Continuation] = [:]
    private var released = false

    func wait() async throws -> StreamableHTTPMCPClientSendResult {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if released {
                    continuation.resume(throwing: StalledSendReleaseError())
                    return
                }
                waiters[id] = continuation
            }
        } onCancel: {
            Task {
                await self.cancel(id: id)
            }
        }
    }

    func releaseAll() {
        released = true
        let waiters = Array(waiters.values)
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: StalledSendReleaseError())
        }
    }

    private func cancel(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else {
            return
        }
        waiter.resume(throwing: CancellationError())
    }
}

private struct StalledSendReleaseError: Error {}
