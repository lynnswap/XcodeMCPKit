import Foundation
import Testing
import XcodeMCPKit
import XcodeMCPProxyTestSupport
@testable import XcodeMCPProxyKit

@Suite(.serialized)
struct StdioAdapterContractTests {
    @Test func deinitCancelsReadAndEventTasksWithoutAStopTask() async {
        let transport = StalledStdioAdapterTransport()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        var adapter: StdioAdapter? = StdioAdapter(
            requestTimeout: nil,
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting,
            recipe: MCPTransportRecipe { transport },
            shutdownPolicy: .live
        )
        weak let weakAdapter = adapter

        await adapter?.start()
        adapter = nil
        for _ in 0..<100 where weakAdapter != nil {
            await Task.yield()
        }

        #expect(weakAdapter == nil)
        inputPipe.fileHandleForWriting.closeFile()
        outputPipe.fileHandleForWriting.closeFile()
    }

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
        let client = StalledStdioAdapterTransport()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let adapter = StdioAdapter(
            requestTimeout: nil,
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting,
            recipe: MCPTransportRecipe { client },
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
            inputPipe.fileHandleForWriting.write(Data(initializeRequest.utf8) + Data("\n".utf8))
            _ = try await client.sentBody(at: 0)
            inputPipe.fileHandleForWriting.write(Data(initializedNotification.utf8) + Data("\n".utf8))
            _ = try await client.sentBody(at: 1)
            inputPipe.fileHandleForWriting.write(Data(toolsListRequest.utf8) + Data("\n".utf8))
            let sentBody = try await client.sentBody(at: 2)
            #expect(sentBody == Data(toolsListRequest.utf8))

            closeInput()
            try await waitUntilDrainSleepSuspended(shutdownClocks)
            #expect(await client.closeCallCount() == 0)

            advanceStdioAdapterShutdownClocks(shutdownClocks, by: .seconds(1))

            try await client.closeCall()
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
        let client = StalledStdioAdapterTransport()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let adapter = StdioAdapter(
            requestTimeout: nil,
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting,
            recipe: MCPTransportRecipe { client },
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
private let initializeRequest = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"test","version":"1"},"capabilities":{}}}"#
private let initializedNotification = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#

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
    try await waitForSuspendedSleepers(on: clocks.timeoutClock)
}

private func advanceStdioAdapterShutdownClocks(
    _ clocks: ControlledStdioAdapterShutdownClocks,
    by duration: Duration
) {
    clocks.uptimeClock.advance(by: duration)
    clocks.timeoutClock.advance(by: duration)
}

private actor StalledStdioAdapterTransport: XcodeMCPTransport {
    nonisolated let events: AsyncStream<XcodeMCPTransportEvent>
    private let eventContinuation: AsyncStream<XcodeMCPTransportEvent>.Continuation

    private let sendBodies = RecordedValues<Data>()
    private let closeCalls = RecordedValues<Void>()
    private let sendCancellationCalls = RecordedValues<Void>()
    private let stalledSends = StalledSendContinuations()

    init() {
        let pair = AsyncStream.makeStream(of: XcodeMCPTransportEvent.self)
        self.events = pair.stream
        self.eventContinuation = pair.continuation
    }

    func send(_ data: Data) async throws {
        await sendBodies.append(data)
        let object = try JSONRPC.Wire.object(fromData: data)
        switch object["method"] as? String {
        case "initialize":
            let response = try JSONRPC.Wire.data(from: [
                "jsonrpc": "2.0",
                "id": object["id"] ?? NSNull(),
                "result": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [:],
                    "serverInfo": ["name": "test", "version": "1"],
                ],
            ])
            eventContinuation.yield(.messageWithHeaders(
                response,
                MCPConnectionHeaders(sessionID: "test-session")
            ))
            return
        case "notifications/initialized":
            return
        default:
            break
        }
        do {
            try await stalledSends.wait()
        } catch is CancellationError {
            await sendCancellationCalls.append(())
            throw CancellationError()
        }
    }

    func close() async {
        await closeCalls.append(())
        eventContinuation.yield(.closed(nil))
        eventContinuation.finish()
    }

    func sentBody(at index: Int = 0) async throws -> Data {
        try await waitWithTimeout("waiting for fake client send") {
            try await self.sendBodies.nextValue(at: index)
        }
    }

    func closeCall(at index: Int = 0) async throws {
        try await waitWithTimeout("waiting for fake client close") {
            _ = try await self.closeCalls.nextValue(at: index)
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

    func releaseStalledSends() async {
        await stalledSends.releaseAll()
    }
}

private actor StalledSendContinuations {
    private typealias Continuation = CheckedContinuation<Void, Error>

    private var waiters: [UUID: Continuation] = [:]
    private var released = false

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: Continuation) in
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
