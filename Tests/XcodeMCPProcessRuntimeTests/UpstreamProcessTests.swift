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
        try await waitForSuspendedSleepers(on: drainClock)

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

    @Test func concurrentStopsShareOutputDrainCompletion() async throws {
        let fakeDriver = FakeUpstreamProcessDriver(finishesOutputOnStop: false)
        let session = try await makeFakeUpstreamSession(fakeDriver)
        let completedStops = RecordedValues<Int>()

        let first = Task {
            await session.stop()
            await completedStops.append(1)
        }
        _ = try await fakeDriver.nextStopOutput()
        let second = Task {
            await session.stop()
            await completedStops.append(2)
        }

        await Task.yield()
        #expect(await completedStops.count() == 0)
        fakeDriver.finishStdout()
        fakeDriver.finishStderr()
        await first.value
        await second.value
        #expect(Set(await completedStops.snapshot()) == Set([1, 2]))
    }

    @Test func stopCancelsEscalationDelayAfterDelayedTerminationAcknowledgement() async throws {
        let scheduler = ControlledTerminationDelayScheduler()
        let fakeDriver = FakeUpstreamProcessDriver(terminatesOnTerminate: false)
        let session = try await makeFakeUpstreamSession(
            fakeDriver,
            terminationSignalGrace: .seconds(30),
            terminationDelayScheduler: scheduler
        )
        let completedStops = RecordedValues<Void>()
        let stop = Task {
            await session.stop()
            await completedStops.append(())
        }

        let delay = try await scheduler.nextScheduledDelay()
        #expect(fakeDriver.snapshot().terminateCount == 1)
        #expect(fakeDriver.snapshot().forceTerminateCount == 0)
        #expect(await completedStops.count() == 0)

        fakeDriver.emitTermination(status: 0)
        await stop.value

        #expect(delay.isCancelled())
        #expect(fakeDriver.snapshot().forceTerminateCount == 0)
        #expect(await completedStops.count() == 1)
    }

    @Test func stopEscalatesIgnoredTerminationAndDrainsQueuedStdinCallbacks() async throws {
        let scheduler = ControlledTerminationDelayScheduler()
        let fakeDriver = FakeUpstreamProcessDriver(terminatesOnTerminate: false)
        let session = try await makeFakeUpstreamSession(
            fakeDriver,
            terminationSignalGrace: .seconds(30),
            terminationDelayScheduler: scheduler
        )
        #expect(await session.send(Data("queued-write".utf8)) == .accepted)
        let completedStops = RecordedValues<Void>()
        let stop = Task {
            await session.stop()
            await completedStops.append(())
        }

        let delay = try await scheduler.nextScheduledDelay()
        var snapshot = fakeDriver.snapshot()
        #expect(snapshot.queuedStdinBytes > 0)
        #expect(snapshot.stdinWriteCompletionCount == 0)
        #expect(snapshot.forceTerminateCount == 0)
        #expect(await completedStops.count() == 0)

        delay.fire()
        await stop.value

        snapshot = fakeDriver.snapshot()
        #expect(snapshot.terminateCount == 1)
        #expect(snapshot.forceTerminateCount == 1)
        #expect(snapshot.queuedStdinBytes == 0)
        #expect(snapshot.stdinWriteCompletionCount == 1)
        #expect(await completedStops.count() == 1)
        for _ in 0..<100 { await Task.yield() }
        #expect(fakeDriver.snapshot().stdinWriteCompletionCount == 1)
    }

    @Test func processTransportDeinitSynchronouslySignalsOwnedProcess() async throws {
        let fakeDriver = FakeUpstreamProcessDriver()
        let config = UpstreamProcess.Config(
            command: "/fake/upstream",
            args: [],
            environment: [:],
            maxQueuedWriteBytes: 1024,
            driverFactory: StaticUpstreamProcessDriverFactory(fakeDriver)
        )
        var transport: UpstreamProcessXcodeMCPTransport? = try await .start(config: config)
        weak let weakTransport = transport

        transport = nil

        #expect(weakTransport == nil)
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
    terminationSignalGrace: Duration = .seconds(1),
    terminationDelayScheduler: any UpstreamTerminationDelayScheduling =
        LiveUpstreamTerminationDelayScheduler(),
    clock: ClockClient = .liveValue
) async throws -> any UpstreamSession {
    let config = UpstreamProcess.Config(
        command: "/fake/upstream",
        args: [],
        environment: [:],
        maxQueuedWriteBytes: maxQueuedWriteBytes,
        terminationDrainGrace: terminationDrainGrace,
        terminationSignalGrace: terminationSignalGrace,
        terminationDelayScheduler: terminationDelayScheduler,
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

private final class ControlledTerminationDelay: @unchecked Sendable {
    private struct State {
        var isCancelled = false
        var hasFired = false
    }

    private let lock = NSLock()
    private let terminal = AsyncTerminalSignal()
    private let operation: @Sendable () -> Void

    init(operation: @escaping @Sendable () -> Void) {
        self.operation = operation
    }

    func makeDelay() -> UpstreamTerminationDelay {
        UpstreamTerminationDelay(terminal: terminal) { [weak self] in
            self?.cancel()
        }
    }

    func fire() {
        let shouldFire = lock.withLock { () -> Bool in
            guard state.isCancelled == false, state.hasFired == false else { return false }
            state.hasFired = true
            return true
        }
        guard shouldFire else { return }
        operation()
        terminal.signal()
    }

    func isCancelled() -> Bool {
        lock.withLock { state.isCancelled }
    }

    private var state = State()

    private func cancel() {
        lock.withLock { state.isCancelled = true }
        terminal.signal()
    }
}

private final class ControlledTerminationDelayScheduler:
    UpstreamTerminationDelayScheduling,
    @unchecked Sendable
{
    private let scheduled = DeterministicRecorder<ControlledTerminationDelay>()

    func schedule(
        after delay: Duration,
        operation: @escaping @Sendable () -> Void
    ) -> UpstreamTerminationDelay {
        _ = delay
        let controlled = ControlledTerminationDelay(operation: operation)
        scheduled.record(controlled)
        return controlled.makeDelay()
    }

    func nextScheduledDelay() async throws -> ControlledTerminationDelay {
        try await scheduled.nextValue(at: 0)
    }
}

private final class FakeUpstreamProcessDriver: UpstreamProcessDriving, @unchecked Sendable {
    struct Snapshot: Sendable {
        let closeStdinCount: Int
        let terminateCount: Int
        let forceTerminateCount: Int
        let stopOutputCount: Int
        let queuedStdinBytes: Int
        let stdinWriteCompletionCount: Int
    }

    private struct State {
        var isRunning = false
        var maxQueuedWriteBytes = 0
        var queuedStdinBytes = 0
        var closeStdinCount = 0
        var terminateCount = 0
        var forceTerminateCount = 0
        var stopOutputCount = 0
        var onTermination: (@Sendable (Int32) -> Void)?
        var stdinWrites: [Data] = []
        var queuedWriteSizes: [Int] = []
        var isStdinClosing = false
        var stdinWriteCompletionCount = 0
    }

    private let lock = NSLock()
    private var state = State()
    private let finishesOutputOnStop: Bool
    private let terminatesOnTerminate: Bool
    private let terminatesOnForceTerminate: Bool
    private let stopOutputRecorder = DeterministicRecorder<Void>()
    private let stdinTerminal = AsyncTerminalSignal()
    private let stdoutTerminal = AsyncTerminalSignal()
    private let stderrTerminal = AsyncTerminalSignal()
    private let stdoutContinuation: AsyncStream<Data>.Continuation
    private let stderrContinuation: AsyncStream<Data>.Continuation
    private let stdoutChunks: AsyncStream<Data>
    private let stderrChunks: AsyncStream<Data>

    init(
        finishesOutputOnStop: Bool = true,
        terminatesOnTerminate: Bool = true,
        terminatesOnForceTerminate: Bool = true
    ) {
        self.finishesOutputOnStop = finishesOutputOnStop
        self.terminatesOnTerminate = terminatesOnTerminate
        self.terminatesOnForceTerminate = terminatesOnForceTerminate
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
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> UpstreamProcessStartedIO {
        _ = command
        _ = args
        _ = environment
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
            state.queuedWriteSizes.append(payload.count)
            return .accepted
        }
    }

    func closeStdin() {
        let shouldSignal = lock.withLock {
            state.closeStdinCount += 1
            state.isStdinClosing = true
            return state.queuedStdinBytes == 0
        }
        if shouldSignal { stdinTerminal.signal() }
    }

    func terminate() -> Bool {
        let result = lock.withLock { () -> ProcessExitCallbacks? in
            state.terminateCount += 1
            guard state.isRunning else {
                return nil
            }
            guard terminatesOnTerminate else {
                return ProcessExitCallbacks(signalAccepted: true)
            }
            state.isRunning = false
            return takeExitCallbacksLocked(status: 143)
        }
        perform(result)
        return result?.signalAccepted == true
    }

    func forceTerminate() -> Bool {
        let result = lock.withLock { () -> ProcessExitCallbacks? in
            state.forceTerminateCount += 1
            guard state.isRunning else {
                return nil
            }
            guard terminatesOnForceTerminate else {
                return ProcessExitCallbacks(signalAccepted: true)
            }
            state.isRunning = false
            return takeExitCallbacksLocked(status: 137)
        }
        perform(result)
        return result?.signalAccepted == true
    }

    func stopOutput() {
        lock.withLock {
            state.stopOutputCount += 1
        }
        stopOutputRecorder.record(())
        if finishesOutputOnStop {
            finishStdout()
            finishStderr()
        }
    }

    func waitForStdinClosed() async {
        await stdinTerminal.wait()
    }

    func waitForOutputStopped() async {
        await stdoutTerminal.wait()
        await stderrTerminal.wait()
    }

    func nextStopOutput() async throws {
        _ = try await stopOutputRecorder.nextValue(at: 0)
    }

    func emitStdout(_ data: Data) {
        stdoutContinuation.yield(data)
    }

    func emitStderr(_ data: Data) {
        stderrContinuation.yield(data)
    }

    func emitTermination(status: Int32) {
        let result = lock.withLock { () -> ProcessExitCallbacks in
            state.isRunning = false
            return takeExitCallbacksLocked(status: status)
        }
        perform(result)
    }

    func finishStdout() {
        stdoutContinuation.finish()
        stdoutTerminal.signal()
    }

    func finishStderr() {
        stderrContinuation.finish()
        stderrTerminal.signal()
    }

    func completeQueuedStdinWrite(bytes: Int) {
        let shouldSignal = lock.withLock { () -> Bool in
            state.queuedStdinBytes = max(0, state.queuedStdinBytes - bytes)
            if state.queuedWriteSizes.first == bytes {
                state.queuedWriteSizes.removeFirst()
            }
            state.stdinWriteCompletionCount += 1
            return state.isStdinClosing && state.queuedStdinBytes == 0
        }
        if shouldSignal { stdinTerminal.signal() }
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
                forceTerminateCount: state.forceTerminateCount,
                stopOutputCount: state.stopOutputCount,
                queuedStdinBytes: state.queuedStdinBytes,
                stdinWriteCompletionCount: state.stdinWriteCompletionCount
            )
        }
    }

    private struct ProcessExitCallbacks {
        let signalAccepted: Bool
        let status: Int32?
        let onTermination: (@Sendable (Int32) -> Void)?
        let shouldSignalStdin: Bool

        init(
            signalAccepted: Bool,
            status: Int32? = nil,
            onTermination: (@Sendable (Int32) -> Void)? = nil,
            shouldSignalStdin: Bool = false
        ) {
            self.signalAccepted = signalAccepted
            self.status = status
            self.onTermination = onTermination
            self.shouldSignalStdin = shouldSignalStdin
        }
    }

    private func takeExitCallbacksLocked(status: Int32) -> ProcessExitCallbacks {
        let queuedWriteSizes = state.queuedWriteSizes
        state.queuedWriteSizes.removeAll()
        state.queuedStdinBytes = 0
        state.stdinWriteCompletionCount += queuedWriteSizes.count
        return ProcessExitCallbacks(
            signalAccepted: true,
            status: status,
            onTermination: state.onTermination,
            shouldSignalStdin: state.isStdinClosing
        )
    }

    private func perform(_ callbacks: ProcessExitCallbacks?) {
        guard let callbacks else { return }
        if callbacks.shouldSignalStdin { stdinTerminal.signal() }
        if let status = callbacks.status {
            callbacks.onTermination?(status)
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
