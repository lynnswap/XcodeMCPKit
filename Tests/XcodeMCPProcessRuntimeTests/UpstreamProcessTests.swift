import Foundation
import Testing
import XcodeMCPKit
import XcodeMCPCoreTestSupport

@testable import XcodeMCPKit

@Suite
struct UpstreamProcessTests {
    @Test func upstreamSessionReassemblesStdoutMessagesAndPreservesOrder() async throws {
        let fakeDriver = FakeUpstreamProcessDriver()
        let session = try await makeFakeUpstreamSession(fakeDriver)
        let events = UpstreamEventRecorder(session.events)
        defer {
            events.cancel()
            Task {
                await session.stop()
            }
        }

        let first = try makeJSONRPCResponse(id: 1, text: String(repeating: "a", count: 16 * 1024))
        let second = try makeJSONRPCResponse(id: 2, text: String(repeating: "b", count: 16 * 1024))
        let splitIndex = first.utf8.index(first.utf8.startIndex, offsetBy: 4096)
        fakeDriver.emitStdout(Data(first.utf8[..<splitIndex]))

        let buffered = try await events.nextEvent {
            if case .stdoutBufferSize(let size) = $0 {
                return size > 0
            }
            return false
        }
        if case .stdoutBufferSize(let size) = buffered {
            #expect(size > 0)
        }

        fakeDriver.emitStdout(Data(first.utf8[splitIndex...]))
        fakeDriver.emitStdout(Data(second.utf8))
        fakeDriver.emitTermination(status: 0)
        fakeDriver.finishStdout()
        fakeDriver.finishStderr()

        let allEvents = await events.finishedEvents()
        let messages = allEvents.compactMap { event -> String? in
            guard case .message(let data) = event else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        }
        #expect(try messages.map(canonicalJSONString) == [canonicalJSONString(first), canonicalJSONString(second)])
        #expect(allEvents.last.map(isExitEvent) == true)
    }

    @Test func upstreamSessionFlushesStderrLinesAndLargeChunksDeterministically() async throws {
        let fakeDriver = FakeUpstreamProcessDriver()
        let session = try await makeFakeUpstreamSession(fakeDriver)
        let events = UpstreamEventRecorder(session.events)
        defer {
            events.cancel()
            Task {
                await session.stop()
            }
        }

        fakeDriver.emitStderr(Data("warning one\nfatal".utf8))
        let first = try await events.nextStderr()
        #expect(first == "warning one")

        fakeDriver.emitStderr(Data(String(repeating: "x", count: 20_000).utf8))
        let large = try await events.nextStderr(startingAt: 1)
        #expect(large.contains("[truncated]"))

        fakeDriver.emitTermination(status: 0)
        fakeDriver.finishStdout()
        fakeDriver.finishStderr()
        let allEvents = await events.finishedEvents()
        #expect(allEvents.contains { event in
            if case .stderr(let value) = event {
                return value.hasPrefix("fatal")
            }
            return false
        })
    }

    @Test func upstreamSessionWritesStdinInOrderAndReportsBackpressure() async throws {
        let fakeDriver = FakeUpstreamProcessDriver()
        let session = try await makeFakeUpstreamSession(fakeDriver, maxQueuedWriteBytes: 12)
        defer {
            Task {
                await session.stop()
            }
        }

        #expect(await session.send(Data("one".utf8)) == .accepted)
        #expect(await session.send(Data("two\n".utf8)) == .accepted)
        #expect(await session.send(Data("overflow".utf8)) == .backpressure)
        #expect(fakeDriver.stdinWrites().map { String(decoding: $0, as: UTF8.self) } == ["one\n", "two\n"])

        fakeDriver.completeQueuedStdinWrite(bytes: 4)
        #expect(await session.send(Data("tri".utf8)) == .accepted)
        #expect(fakeDriver.stdinWrites().map { String(decoding: $0, as: UTF8.self) } == ["one\n", "two\n", "tri\n"])
    }

    @Test func upstreamSessionDrainsLateStdoutBeforeExitAfterTermination() async throws {
        let fakeDriver = FakeUpstreamProcessDriver()
        let session = try await makeFakeUpstreamSession(fakeDriver)
        let events = UpstreamEventRecorder(session.events)
        defer {
            events.cancel()
            Task {
                await session.stop()
            }
        }

        let first = try makeJSONRPCResponse(id: 10, text: "before termination")
        let second = try makeJSONRPCResponse(id: 11, text: "after termination")
        fakeDriver.emitStdout(Data(first.utf8))
        fakeDriver.emitTermination(status: 4)
        fakeDriver.emitStdout(Data(second.utf8))
        fakeDriver.finishStdout()
        fakeDriver.finishStderr()

        let allEvents = await events.finishedEvents()
        let messageIndexes = allEvents.enumerated().compactMap { index, event -> Int? in
            if case .message = event {
                return index
            }
            return nil
        }
        let exitIndex = allEvents.firstIndex(where: isExitEvent)
        #expect(messageIndexes.count == 2)
        #expect(exitIndex != nil)
        if let exitIndex {
            #expect(messageIndexes.allSatisfy { $0 < exitIndex })
        }
        #expect(await session.send(Data("after-exit".utf8)) == .unavailable(.terminated))
    }

    @Test func upstreamSessionForcesExitAfterDeterministicDrainGrace() async throws {
        let drainClock = TestClock()
        let fakeDriver = FakeUpstreamProcessDriver()
        let session = try await makeFakeUpstreamSession(
            fakeDriver,
            terminationDrainGrace: .seconds(10),
            clock: makeTestClockClient(drainClock)
        )
        let events = UpstreamEventRecorder(session.events)
        defer {
            events.cancel()
            Task {
                await session.stop()
            }
        }

        fakeDriver.emitStdout(Data(try makeJSONRPCResponse(id: 20, text: "parent").utf8))
        _ = try await events.nextMessage()
        fakeDriver.emitTermination(status: 0)
        try await drainClock.sleep(untilSuspendedBy: 1)

        #expect(!events.snapshot().contains(where: isExitEvent))
        drainClock.advance(by: .seconds(10))

        let exit = try await events.nextEvent(matching: isExitEvent)
        #expect(isExitEvent(exit))
        let allEvents = await events.finishedEvents()
        #expect(allEvents.last.map(isExitEvent) == true)
        #expect(fakeDriver.snapshot().stopOutputCount == 1)
    }

    @Test func upstreamSessionTreatsInvalidStdoutAsFatalProtocolViolation() async throws {
        let fakeDriver = FakeUpstreamProcessDriver()
        let session = try await makeFakeUpstreamSession(fakeDriver)
        let events = UpstreamEventRecorder(session.events)
        defer {
            events.cancel()
            Task {
                await session.stop()
            }
        }

        fakeDriver.emitStdout(Data("Content-Length: nope\r\n\r\n{}".utf8))
        let violation = try await events.nextEvent {
            if case .stdoutProtocolViolation = $0 {
                return true
            }
            return false
        }
        if case .stdoutProtocolViolation(let details) = violation {
            #expect(details.reason == .invalidContentLengthHeader)
        }
        let allEvents = await events.finishedEvents()
        #expect(!allEvents.contains(where: isExitEvent))
        #expect(fakeDriver.snapshot().terminateCount == 1)
        #expect(fakeDriver.snapshot().stopOutputCount == 1)
    }

    @Test func upstreamSessionStopIsIdempotentAndSuppressesExit() async throws {
        let fakeDriver = FakeUpstreamProcessDriver()
        let session = try await makeFakeUpstreamSession(fakeDriver)
        let events = UpstreamEventRecorder(session.events)
        defer {
            events.cancel()
        }

        await session.stop()
        await session.stop()

        let allEvents = await events.finishedEvents()
        #expect(allEvents.isEmpty)
        let snapshot = fakeDriver.snapshot()
        #expect(snapshot.closeStdinCount == 1)
        #expect(snapshot.stopOutputCount == 1)
        #expect(snapshot.terminateCount == 1)
    }
}

@Suite(.serialized, .enabled(if: ProcessTestEnvironment.isEnabled))
struct LiveUpstreamProcessSmokeTests {
    @Test func upstreamProcessLiveSmokeDrainsMessageStderrAndExit() async throws {
        let config = UpstreamProcess.Config(
            command: "/bin/sh",
            args: [
                "-c",
                "printf '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}'; printf 'smoke stderr\\n' >&2",
            ],
            environment: ProcessInfo.processInfo.environment,
            maxQueuedWriteBytes: 1024
        )

        try await withLiveUpstreamSession(config: config) { session in
            let events = try await waitWithTimeout(
                "live UpstreamProcess smoke should finish",
                timeout: .seconds(5)
            ) {
                var observed: [Upstream.Event] = []
                for await event in session.events {
                    observed.append(event)
                    if isExitEvent(event) {
                        return observed
                    }
                }
                return observed
            }

            #expect(events.contains { event in
                if case .message = event {
                    return true
                }
                return false
            })
            #expect(events.contains { event in
                if case .stderr("smoke stderr") = event {
                    return true
                }
                return false
            })
            #expect(events.contains { event in
                if case .exit(0) = event {
                    return true
                }
                return false
            })
        }
    }
}

private func makeFakeUpstreamSession(
    _ fakeDriver: FakeUpstreamProcessDriver,
    maxQueuedWriteBytes: Int = 1024,
    terminationDrainGrace: Duration = .milliseconds(250),
    clock: ClockClient = .liveValue
) async throws -> any UpstreamSession {
    let config = UpstreamProcess.Config(
        command: "/fake/upstream",
        args: [],
        environment: [:],
        maxQueuedWriteBytes: maxQueuedWriteBytes,
        terminationDrainGrace: terminationDrainGrace,
        clock: clock,
        driverFactory: StaticUpstreamProcessDriverFactory(fakeDriver)
    )
    return try await UpstreamProcess(configuration: config).startSession()
}

private func withLiveUpstreamSession<T: Sendable>(
    config: UpstreamProcess.Config,
    _ body: @escaping @Sendable (any UpstreamSession) async throws -> T
) async throws -> T {
    let session = try await UpstreamProcess(configuration: config).startSession()
    do {
        let result = try await body(session)
        await session.stop()
        return result
    } catch {
        await session.stop()
        throw error
    }
}

private struct StaticUpstreamProcessDriverFactory: UpstreamProcessDriverMaking {
    private let driver: FakeUpstreamProcessDriver

    init(_ driver: FakeUpstreamProcessDriver) {
        self.driver = driver
    }

    func makeDriver() -> any UpstreamProcessDriving {
        driver
    }
}

private final class FakeUpstreamProcessDriver: UpstreamProcessDriving, @unchecked Sendable {
    struct Snapshot: Sendable {
        let closeStdinCount: Int
        let terminateCount: Int
        let stopOutputCount: Int
    }

    private struct State {
        var isRunning = false
        var maxQueuedWriteBytes = 0
        var queuedStdinBytes = 0
        var closeStdinCount = 0
        var terminateCount = 0
        var stopOutputCount = 0
        var onTermination: (@Sendable (Int32) -> Void)?
        var stdinWrites: [Data] = []
    }

    private let lock = NSLock()
    private var state = State()
    private let stdoutContinuation: AsyncStream<Data>.Continuation
    private let stderrContinuation: AsyncStream<Data>.Continuation
    private let stdoutChunks: AsyncStream<Data>
    private let stderrChunks: AsyncStream<Data>

    init() {
        var stdoutContinuation: AsyncStream<Data>.Continuation!
        self.stdoutChunks = AsyncStream { continuation in
            stdoutContinuation = continuation
        }
        self.stdoutContinuation = stdoutContinuation

        var stderrContinuation: AsyncStream<Data>.Continuation!
        self.stderrChunks = AsyncStream { continuation in
            stderrContinuation = continuation
        }
        self.stderrContinuation = stderrContinuation
    }

    func start(
        command: String,
        args: [String],
        environment: [String: String],
        maxQueuedWriteBytes: Int,
        onTermination: @escaping @Sendable (Int32) -> Void,
        onStdinWriteComplete: @escaping @Sendable (Int, Error?) -> Void
    ) throws -> UpstreamProcessStartedIO {
        _ = command
        _ = args
        _ = environment
        _ = onStdinWriteComplete
        lock.withLock {
            state.isRunning = true
            state.maxQueuedWriteBytes = maxQueuedWriteBytes
            state.onTermination = onTermination
        }
        return UpstreamProcessStartedIO(
            stdoutChunks: stdoutChunks,
            stderrChunks: stderrChunks
        )
    }

    func sendStdin(_ payload: Data) -> Upstream.SendResult {
        lock.withLock {
            guard state.isRunning else {
                return .unavailable(.terminated)
            }
            guard state.queuedStdinBytes + payload.count <= state.maxQueuedWriteBytes else {
                return .backpressure
            }
            state.queuedStdinBytes += payload.count
            state.stdinWrites.append(payload)
            return .accepted
        }
    }

    func closeStdin() {
        lock.withLock {
            state.closeStdinCount += 1
        }
    }

    func terminate() -> Bool {
        let onTermination = lock.withLock { () -> (@Sendable (Int32) -> Void)? in
            state.terminateCount += 1
            guard state.isRunning else {
                return nil
            }
            state.isRunning = false
            return state.onTermination
        }
        onTermination?(143)
        return onTermination != nil
    }

    func stopOutput() {
        lock.withLock {
            state.stopOutputCount += 1
        }
        finishStdout()
        finishStderr()
    }

    func emitStdout(_ data: Data) {
        stdoutContinuation.yield(data)
    }

    func emitStderr(_ data: Data) {
        stderrContinuation.yield(data)
    }

    func emitTermination(status: Int32) {
        let onTermination = lock.withLock { () -> (@Sendable (Int32) -> Void)? in
            state.isRunning = false
            return state.onTermination
        }
        onTermination?(status)
    }

    func finishStdout() {
        stdoutContinuation.finish()
    }

    func finishStderr() {
        stderrContinuation.finish()
    }

    func completeQueuedStdinWrite(bytes: Int) {
        lock.withLock {
            state.queuedStdinBytes = max(0, state.queuedStdinBytes - bytes)
        }
    }

    func stdinWrites() -> [Data] {
        lock.withLock {
            state.stdinWrites
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                closeStdinCount: state.closeStdinCount,
                terminateCount: state.terminateCount,
                stopOutputCount: state.stopOutputCount
            )
        }
    }
}

private final class UpstreamEventRecorder: @unchecked Sendable {
    private let recorder = DeterministicRecorder<Upstream.Event>()
    private let task: Task<[Upstream.Event], Never>

    init(_ events: AsyncStream<Upstream.Event>) {
        let recorder = recorder
        self.task = Task {
            var allEvents: [Upstream.Event] = []
            for await event in events {
                allEvents.append(event)
                recorder.record(event)
            }
            return allEvents
        }
    }

    func nextEvent(
        matching predicate: @escaping @Sendable (Upstream.Event) -> Bool
    ) async throws -> Upstream.Event {
        try await recorder.nextValue(matching: predicate)
    }

    func nextMessage(startingAt startIndex: Int = 0) async throws -> String {
        let event = try await recorder.nextValue(startingAt: startIndex) {
            if case .message = $0 {
                return true
            }
            return false
        }
        guard case .message(let data) = event else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    func nextStderr(startingAt startIndex: Int = 0) async throws -> String {
        let event = try await recorder.nextValue(startingAt: startIndex) {
            if case .stderr = $0 {
                return true
            }
            return false
        }
        guard case .stderr(let value) = event else {
            return ""
        }
        return value
    }

    func snapshot() -> [Upstream.Event] {
        recorder.snapshot()
    }

    func finishedEvents() async -> [Upstream.Event] {
        await task.value
    }

    func cancel() {
        task.cancel()
    }
}

private func isExitEvent(_ event: Upstream.Event) -> Bool {
    if case .exit = event {
        return true
    }
    return false
}

private func makeJSONRPCResponse(id: Int, text: String) throws -> String {
    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "result": [
            "text": text,
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    return String(decoding: data, as: UTF8.self)
}

private func canonicalJSONString(_ string: String) throws -> String {
    let object = try JSONSerialization.jsonObject(with: Data(string.utf8))
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
