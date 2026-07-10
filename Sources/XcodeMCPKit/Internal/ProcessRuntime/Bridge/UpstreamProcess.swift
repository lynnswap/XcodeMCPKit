import Foundation
import Darwin
import Dispatch
import Logging
import Synchronization

private final class StdinWriter: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let maxQueuedWriteBytes: Int
    private let queue: DispatchQueue
    private let state = NSLock()
    private var queuedBytes = 0
    private var isClosed = false
    private let terminal = AsyncTerminalSignal()
    private let onComplete: @Sendable (_ bytes: Int, _ error: Error?) -> Void

    init(
        fileHandle: FileHandle,
        maxQueuedWriteBytes: Int,
        label: String,
        onComplete: @escaping @Sendable (_ bytes: Int, _ error: Error?) -> Void
    ) {
        self.fileHandle = fileHandle
        self.maxQueuedWriteBytes = maxQueuedWriteBytes
        self.queue = DispatchQueue(label: label)
        self.onComplete = onComplete
    }

    func send(_ payload: Data) -> Upstream.SendResult {
        state.lock()
        defer { state.unlock() }

        guard !isClosed else {
            return .unavailable(.terminated)
        }
        guard queuedBytes + payload.count <= maxQueuedWriteBytes else {
            return .backpressure
        }

        queuedBytes += payload.count
        queue.async { [fileHandle, onComplete] in
            var writeError: Error?
            do {
                try fileHandle.write(contentsOf: payload)
            } catch {
                writeError = error
            }
            onComplete(payload.count, writeError)
        }
        return .accepted
    }

    func completeWrite(bytes: Int) {
        state.lock()
        queuedBytes = max(0, queuedBytes - bytes)
        state.unlock()
    }

    func close() {
        state.lock()
        let shouldClose = !isClosed
        isClosed = true
        state.unlock()

        guard shouldClose else {
            return
        }

        let terminal = terminal
        queue.async { [fileHandle] in
            try? fileHandle.close()
            terminal.signal()
        }
    }

    func waitUntilClosed() async {
        await terminal.wait()
    }
}

package struct UpstreamProcessStartedIO: Sendable {
    package let stdoutChunks: AsyncStream<Data>
    package let stderrChunks: AsyncStream<Data>

    package init(
        stdoutChunks: AsyncStream<Data>,
        stderrChunks: AsyncStream<Data>
    ) {
        self.stdoutChunks = stdoutChunks
        self.stderrChunks = stderrChunks
    }
}

package protocol UpstreamProcessDriving: AnyObject, Sendable {
    func start(
        command: String,
        args: [String],
        environment: [String: String],
        maxQueuedWriteBytes: Int,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> UpstreamProcessStartedIO
    func sendStdin(_ payload: Data) -> Upstream.SendResult
    func closeStdin()
    func terminate() -> Bool
    func forceTerminate() -> Bool
    func stopOutput()
    func waitForStdinClosed() async
    func waitForOutputStopped() async
}

package protocol UpstreamProcessDriverMaking: Sendable {
    func makeDriver() -> any UpstreamProcessDriving
}

package struct LiveUpstreamProcessDriverFactory: UpstreamProcessDriverMaking {
    package init() {}

    package func makeDriver() -> any UpstreamProcessDriving {
        LiveUpstreamProcessDriver()
    }
}

private final class LiveUpstreamProcessDriver: UpstreamProcessDriving, @unchecked Sendable {
    private struct State {
        var process: Process?
        var stdinPipe: Pipe?
        var stdoutPipe: Pipe?
        var stderrPipe: Pipe?
        var stdinWriter: StdinWriter?
        var stdoutReader: OrderedPipeReader?
        var stderrReader: OrderedPipeReader?
    }

    private let logger: Logger = XcodeMCPRuntimeLogging.make("upstream")
    private let lock = NSLock()
    private var state = State()

    func start(
        command: String,
        args: [String],
        environment: [String: String],
        maxQueuedWriteBytes: Int,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> UpstreamProcessStartedIO {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        configureNoSigPipe(on: stdinPipe.fileHandleForWriting)

        let (executableURL, resolvedArgs) = resolveCommand(command: command, args: args)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = resolvedArgs
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] process in
            self?.clearProcess()
            onTermination(process.terminationStatus)
        }

        let stdoutReader = OrderedPipeReader(
            fileHandle: stdoutPipe.fileHandleForReading,
            label: "XcodeMCPProxy.UpstreamSession.stdout"
        )
        let stderrReader = OrderedPipeReader(
            fileHandle: stderrPipe.fileHandleForReading,
            label: "XcodeMCPProxy.UpstreamSession.stderr"
        )

        do {
            try process.run()
        } catch {
            stdoutReader.stop()
            stderrReader.stop()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? stdinPipe.fileHandleForWriting.close()
            throw error
        }

        let stdinWriter = StdinWriter(
            fileHandle: stdinPipe.fileHandleForWriting,
            maxQueuedWriteBytes: maxQueuedWriteBytes,
            label: "XcodeMCPProxy.UpstreamSession.stdin",
            onComplete: { [weak self] bytes, error in
                self?.completeStdinWrite(bytes: bytes, error: error)
            }
        )

        lock.withLock {
            state.process = process
            state.stdinPipe = stdinPipe
            state.stdoutPipe = stdoutPipe
            state.stderrPipe = stderrPipe
            state.stdinWriter = stdinWriter
            state.stdoutReader = stdoutReader
            state.stderrReader = stderrReader
        }

        stdoutReader.start()
        stderrReader.start()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        return UpstreamProcessStartedIO(
            stdoutChunks: stdoutReader.chunks,
            stderrChunks: stderrReader.chunks
        )
    }

    func sendStdin(_ payload: Data) -> Upstream.SendResult {
        guard let stdinWriter = lock.withLock({ state.stdinWriter }) else {
            return .unavailable(.notStarted)
        }
        return stdinWriter.send(payload)
    }

    func closeStdin() {
        let stdinWriter = lock.withLock { state.stdinWriter }
        stdinWriter?.close()
    }

    func terminate() -> Bool {
        guard let process = lock.withLock({ state.process }) else {
            return false
        }
        guard process.isRunning else {
            return false
        }
        process.terminate()
        return true
    }

    func forceTerminate() -> Bool {
        guard let process = lock.withLock({ state.process }) else {
            return false
        }
        guard process.isRunning else {
            return false
        }
        let result = kill(process.processIdentifier, SIGKILL)
        if result != 0, errno != ESRCH {
            logger.error(
                "Failed to force-terminate upstream process",
                metadata: [
                    "pid": "\(process.processIdentifier)",
                    "errno": "\(errno)",
                ]
            )
        }
        return result == 0
    }

    func stopOutput() {
        let snapshot = lock.withLock {
            (
                stdoutReader: state.stdoutReader,
                stderrReader: state.stderrReader,
                stdoutPipe: state.stdoutPipe,
                stderrPipe: state.stderrPipe
            )
        }
        snapshot.stdoutReader?.stop()
        snapshot.stderrReader?.stop()
        try? snapshot.stdoutPipe?.fileHandleForWriting.close()
        try? snapshot.stderrPipe?.fileHandleForWriting.close()
    }

    func waitForStdinClosed() async {
        let writer = lock.withLock { state.stdinWriter }
        await writer?.waitUntilClosed()
    }

    func waitForOutputStopped() async {
        let readers = lock.withLock { (state.stdoutReader, state.stderrReader) }
        await readers.0?.waitUntilStopped()
        await readers.1?.waitUntilStopped()
    }

    private func completeStdinWrite(bytes: Int, error: Error?) {
        let stdinWriter = lock.withLock { state.stdinWriter }
        stdinWriter?.completeWrite(bytes: bytes)
        if let error {
            logger.warning("Upstream async write failed", metadata: ["error": "\(error)"])
        }
    }

    private func clearProcess() {
        lock.withLock {
            state.process = nil
        }
    }

    private func resolveCommand(command: String, args: [String]) -> (URL, [String]) {
        if command.contains("/") {
            return (URL(fileURLWithPath: command), args)
        }
        let env = "/usr/bin/env"
        return (URL(fileURLWithPath: env), [command] + args)
    }

    private func configureNoSigPipe(on handle: FileHandle) {
        let fd = handle.fileDescriptor
        let result = fcntl(fd, F_SETNOSIGPIPE, 1)
        if result == -1 {
            logger.warning(
                "Failed to disable SIGPIPE on upstream stdin pipe",
                metadata: ["errno": "\(errno)"]
            )
        }
    }
}

private final class UpstreamProcessCancellation: @unchecked Sendable {
    private struct State {
        var driver: (any UpstreamProcessDriving)?
        var isCancelled = false
    }

    private let lock = NSLock()
    private var state = State()

    func install(_ driver: any UpstreamProcessDriving) {
        let shouldCancel = lock.withLock { () -> Bool in
            precondition(state.driver == nil)
            state.driver = driver
            return state.isCancelled
        }
        if shouldCancel { cancelDriver(driver) }
    }

    func cancel() {
        let driver = lock.withLock { () -> (any UpstreamProcessDriving)? in
            guard state.isCancelled == false else { return nil }
            state.isCancelled = true
            return state.driver
        }
        guard let driver else { return }
        cancelDriver(driver)
    }

    private func cancelDriver(_ driver: any UpstreamProcessDriving) {
        driver.closeStdin()
        _ = driver.terminate()
        driver.stopOutput()
    }
}

package final class UpstreamTerminationDelay: Sendable {
    private let cancelImpl: @Sendable () -> Void
    private let terminal: AsyncTerminalSignal

    package init(
        terminal: AsyncTerminalSignal,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.terminal = terminal
        self.cancelImpl = cancel
    }

    package func cancel() {
        cancelImpl()
    }

    package func waitUntilTerminal() async {
        await terminal.wait()
    }
}

package protocol UpstreamTerminationDelayScheduling: Sendable {
    func schedule(
        after delay: Duration,
        operation: @escaping @Sendable () -> Void
    ) -> UpstreamTerminationDelay
}

package struct LiveUpstreamTerminationDelayScheduler: UpstreamTerminationDelayScheduling {
    package init() {}

    package func schedule(
        after delay: Duration,
        operation: @escaping @Sendable () -> Void
    ) -> UpstreamTerminationDelay {
        let terminal = AsyncTerminalSignal()
        let source = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler(handler: operation)
        source.setCancelHandler(handler: terminal.signal)
        source.schedule(deadline: .now() + Self.dispatchInterval(delay))
        source.resume()
        return UpstreamTerminationDelay(terminal: terminal) {
            source.cancel()
        }
    }

    private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        let seconds = UInt64(max(0, components.seconds))
        let nanos = UInt64(max(0, components.attoseconds) / 1_000_000_000)
        let product = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let total: UInt64
        if product.overflow {
            total = UInt64(Int.max)
        } else {
            let sum = product.partialValue.addingReportingOverflow(nanos)
            total = sum.overflow ? UInt64(Int.max) : min(sum.partialValue, UInt64(Int.max))
        }
        return .nanoseconds(Int(total))
    }
}

private final class UpstreamTerminationRace: Sendable {
    private struct State {
        var result: Bool?
        var waiters: [CheckedContinuation<Bool, Never>] = []
    }

    private let state = Mutex(State())

    func complete(_ result: Bool) {
        let waiters: [CheckedContinuation<Bool, Never>] = state.withLock { state in
            guard state.result == nil else { return [] }
            state.result = result
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: result) }
    }

    func value() async -> Bool {
        await withCheckedContinuation { continuation in
            let result = state.withLock { state -> Bool? in
                if let result = state.result { return result }
                state.waiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(returning: result) }
        }
    }
}

package struct UpstreamProcess: UpstreamSessionFactory {
    package struct Config: Sendable {
        package var command: String
        package var args: [String]
        package var environment: [String: String]
        package var maxQueuedWriteBytes: Int
        package var terminationDrainGrace: Duration
        package var terminationSignalGrace: Duration
        package var terminationDelayScheduler: any UpstreamTerminationDelayScheduling
        package var clock: ClockClient
        package var driverFactory: any UpstreamProcessDriverMaking

        package init(
            command: String,
            args: [String],
            environment: [String: String],
            maxQueuedWriteBytes: Int,
            terminationDrainGrace: Duration = .milliseconds(250),
            terminationSignalGrace: Duration = .seconds(1),
            terminationDelayScheduler: any UpstreamTerminationDelayScheduling =
                LiveUpstreamTerminationDelayScheduler(),
            clock: ClockClient = .liveValue,
            driverFactory: any UpstreamProcessDriverMaking = LiveUpstreamProcessDriverFactory()
        ) {
            self.command = command
            self.args = args
            self.environment = environment
            self.maxQueuedWriteBytes = maxQueuedWriteBytes
            self.terminationDrainGrace = terminationDrainGrace
            self.terminationSignalGrace = terminationSignalGrace
            self.terminationDelayScheduler = terminationDelayScheduler
            self.clock = clock
            self.driverFactory = driverFactory
        }
    }

    private let config: Config

    package init(configuration: Config) {
        self.config = configuration
    }

    package func startSession() async throws -> any UpstreamSession {
        try await ProcessBackedUpstreamSession.start(configuration: config)
    }
}

package actor ProcessBackedUpstreamSession: UpstreamSession {
    package nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation

    private let config: UpstreamProcess.Config
    private let logger: Logger = XcodeMCPRuntimeLogging.make("upstream")
    private let maxBufferedStderrBytes = 16 * 1024
    private nonisolated let cancellation = UpstreamProcessCancellation()

    private var driver: (any UpstreamProcessDriving)?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var framer = StdioFramer()
    private var stderrBuffer = ""
    private var lastReportedBufferedStdoutBytes = 0
    private var terminationObserved = false
    private var stdoutDrained = false
    private var stderrDrained = false
    private var suppressExitEvent = false
    private var pendingExitStatus: Int32?
    private var terminationDrainTimeoutTask: Task<Void, Never>?
    private var terminationRaces: [UUID: UpstreamTerminationRace] = [:]
    private var didFinishEvents = false
    private var isStopping = false
    private var stopCompleted = false
    private var stopTask: Task<Void, Never>?

    package static func start(
        configuration: UpstreamProcess.Config
    ) async throws -> ProcessBackedUpstreamSession {
        let session = ProcessBackedUpstreamSession(configuration: configuration)
        try await session.runProcess()
        return session
    }

    private init(configuration: UpstreamProcess.Config) {
        self.config = configuration

        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    package nonisolated func cancel() {
        cancellation.cancel()
    }

    package func send(_ data: Data) async -> Upstream.SendResult {
        if isStopping {
            logger.warning("Upstream send skipped because session is stopping")
            return .unavailable(.shuttingDown)
        }
        if didFinishEvents || terminationObserved {
            logger.warning("Upstream send skipped because session has terminated")
            return .unavailable(.terminated)
        }
        guard let driver else {
            logger.warning("Upstream send skipped because session never started")
            return .unavailable(.notStarted)
        }

        var payload = data
        if payload.last != 0x0A {
            payload.append(0x0A)
        }

        let result = driver.sendStdin(payload)
        if result == .backpressure {
            logger.warning(
                "Upstream write queue overloaded",
                metadata: [
                    "payload_bytes": "\(payload.count)",
                    "limit_bytes": "\(config.maxQueuedWriteBytes)",
                ]
            )
        }
        return result
    }

    package func stop() async {
        let task = beginStop(suppressExitEvent: true)
        await task.value
    }

    isolated deinit {
        cancellation.cancel()
        stdoutTask?.cancel()
        stderrTask?.cancel()
        terminationDrainTimeoutTask?.cancel()
        stopTask?.cancel()
        for race in terminationRaces.values { race.complete(false) }
        continuation.finish()
    }
}

private extension ProcessBackedUpstreamSession {
    func runProcess() async throws {
        framer = StdioFramer()
        stderrBuffer = ""
        resetBufferedStdoutBytesIfNeeded()
        terminationObserved = false
        stdoutDrained = false
        stderrDrained = false
        suppressExitEvent = false
        pendingExitStatus = nil
        terminationDrainTimeoutTask?.cancel()
        terminationDrainTimeoutTask = nil
        for race in terminationRaces.values { race.complete(false) }
        terminationRaces.removeAll()
        didFinishEvents = false
        isStopping = false
        stopCompleted = false
        stopTask = nil

        let driver = config.driverFactory.makeDriver()
        self.driver = driver
        cancellation.install(driver)
        let io: UpstreamProcessStartedIO
        do {
            io = try driver.start(
                command: config.command,
                args: config.args,
                environment: config.environment,
                maxQueuedWriteBytes: config.maxQueuedWriteBytes
            ) { [weak self] status in
                Task {
                    await self?.handleTermination(status: status)
                }
            }
        } catch {
            cancellation.cancel()
            self.driver = nil
            continuation.finish()
            throw error
        }

        stdoutTask = Task { [weak self] in
            for await data in io.stdoutChunks {
                await self?.handleStdoutData(data)
            }
            await self?.handleStdoutEOF()
        }
        stderrTask = Task { [weak self] in
            for await data in io.stderrChunks {
                await self?.handleStderrData(data)
            }
            await self?.handleStderrEOF()
        }
    }

    func handleStdoutData(_ data: Data) async {
        guard !didFinishEvents else {
            return
        }

        let result = framer.append(data)
        for message in result.messages {
            guard isValidJSONPayload(message) else {
                if let text = String(data: message, encoding: .utf8) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let preview = String(trimmed.prefix(200))
                        logger.warning("Dropping non-JSON upstream stdout", metadata: ["preview": "\(preview)"])
                    }
                } else {
                    logger.warning("Dropping non-UTF8 upstream stdout", metadata: ["bytes": "\(message.count)"])
                }
                continue
            }
            continuation.yield(.message(message))
        }

        if lastReportedBufferedStdoutBytes != result.bufferedByteCount {
            lastReportedBufferedStdoutBytes = result.bufferedByteCount
            continuation.yield(.stdoutBufferSize(result.bufferedByteCount))
        }

        guard let protocolViolation = result.protocolViolation else {
            return
        }

        logger.error(
            "Fatal upstream stdout protocol violation",
            metadata: [
                "reason": .string(protocolViolation.reason.rawValue),
                "buffered_bytes": .string("\(protocolViolation.bufferedByteCount)"),
                "preview": .string(protocolViolation.preview),
                "preview_hex": .string(protocolViolation.previewHex),
                "leading_byte_hex": .string(protocolViolation.leadingByteHex ?? ""),
            ]
        )
        continuation.yield(.stdoutProtocolViolation(protocolViolation))
        framer = StdioFramer()
        resetBufferedStdoutBytesIfNeeded()
        _ = beginStop(suppressExitEvent: true)
    }

    func handleStdoutEOF() {
        stdoutDrained = true
        finishEventsIfNeeded()
    }

    func handleStderrData(_ data: Data) {
        guard !didFinishEvents else {
            return
        }

        if let message = String(data: data, encoding: .utf8) {
            stderrBuffer.append(message)
            let parts = stderrBuffer.split(separator: "\n", omittingEmptySubsequences: false)
            let completeLines = parts.dropLast()
            stderrBuffer = parts.last.map(String.init) ?? ""

            for line in completeLines {
                emitStderrLine(String(line))
            }
            flushBufferedStderrChunkIfNeeded()
        } else {
            logger.error("Upstream stderr (binary)", metadata: ["bytes": "\(data.count)"])
        }
    }

    func handleStderrEOF() {
        flushBufferedStderrIfNeeded()
        stderrDrained = true
        finishEventsIfNeeded()
    }

    func handleTermination(status: Int32) async {
        guard !terminationObserved else {
            return
        }

        terminationObserved = true
        let races = Array(terminationRaces.values)
        for race in races { race.complete(true) }
        if !suppressExitEvent {
            pendingExitStatus = status
            scheduleTerminationDrainTimeoutIfNeeded()
        }
        // Let pipe readers drain any bytes the kernel still holds after process exit.
        finishEventsIfNeeded()
    }

    func beginStop(suppressExitEvent: Bool) -> Task<Void, Never> {
        if let stopTask { return stopTask }
        if stopCompleted { return Task {} }

        isStopping = true
        if suppressExitEvent {
            self.suppressExitEvent = true
            pendingExitStatus = nil
        }
        terminationDrainTimeoutTask?.cancel()
        terminationDrainTimeoutTask = nil
        cancellation.cancel()

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performStop()
        }
        stopTask = task
        return task
    }

    func performStop() async {
        let currentDriver = driver
        if terminationObserved == false {
            let exited = await waitForTerminationWithinSignalGrace()
            if exited == false {
                _ = currentDriver?.forceTerminate()
                await waitUntilTerminationObserved()
            }
        }

        await currentDriver?.waitForStdinClosed()
        await currentDriver?.waitForOutputStopped()
        let stdoutTask = stdoutTask
        let stderrTask = stderrTask
        await stdoutTask?.value
        await stderrTask?.value
        finishEventsIfNeeded(force: true)

        driver = nil
        stopCompleted = true
    }

    func waitForTerminationWithinSignalGrace() async -> Bool {
        if terminationObserved { return true }
        let grace = config.terminationSignalGrace
        guard grace > .zero else { return false }
        let id = UUID()
        let race = UpstreamTerminationRace()
        terminationRaces[id] = race
        if terminationObserved { race.complete(true) }
        let delay = config.terminationDelayScheduler.schedule(after: grace) {
            race.complete(false)
        }
        let result = await race.value()
        delay.cancel()
        await delay.waitUntilTerminal()
        terminationRaces.removeValue(forKey: id)
        return result
    }

    func waitUntilTerminationObserved() async {
        if terminationObserved { return }
        let id = UUID()
        let race = UpstreamTerminationRace()
        terminationRaces[id] = race
        if terminationObserved { race.complete(true) }
        _ = await race.value()
        terminationRaces.removeValue(forKey: id)
    }

    func finishEventsIfNeeded(force: Bool = false) {
        guard !didFinishEvents else {
            return
        }
        guard force || (terminationObserved && stdoutDrained && stderrDrained) else {
            return
        }

        didFinishEvents = true
        terminationDrainTimeoutTask?.cancel()
        terminationDrainTimeoutTask = nil
        resetBufferedStdoutBytesIfNeeded()
        if let exitStatus = pendingExitStatus {
            pendingExitStatus = nil
            continuation.yield(.exit(exitStatus))
        }
        continuation.finish()
    }

    func scheduleTerminationDrainTimeoutIfNeeded() {
        guard pendingExitStatus != nil, !stdoutDrained || !stderrDrained else {
            return
        }

        let grace = config.terminationDrainGrace
        if grace <= .zero {
            forceTerminateDrainIfNeeded()
            return
        }

        let clock = config.clock
        terminationDrainTimeoutTask?.cancel()
        terminationDrainTimeoutTask = Task { [weak self] in
            await clock.sleep(grace)
            guard !Task.isCancelled else {
                return
            }
            await self?.forceTerminateDrainIfNeeded()
        }
    }

    func forceTerminateDrainIfNeeded() {
        guard terminationObserved, !didFinishEvents, pendingExitStatus != nil else {
            return
        }
        guard !stdoutDrained || !stderrDrained else {
            return
        }

        cancellation.cancel()
        finishEventsIfNeeded()
    }

    func resetBufferedStdoutBytesIfNeeded() {
        guard lastReportedBufferedStdoutBytes != 0 else {
            return
        }
        lastReportedBufferedStdoutBytes = 0
        continuation.yield(.stdoutBufferSize(0))
    }

    func flushBufferedStderrIfNeeded() {
        emitStderrLine(stderrBuffer)
        stderrBuffer = ""
    }

    func flushBufferedStderrChunkIfNeeded() {
        while stderrBuffer.utf8.count > maxBufferedStderrBytes {
            let prefixData = Data(stderrBuffer.utf8.prefix(maxBufferedStderrBytes))
            emitStderrLine(String(decoding: prefixData, as: UTF8.self), suffix: " [truncated]")
            stderrBuffer = String(decoding: stderrBuffer.utf8.dropFirst(maxBufferedStderrBytes), as: UTF8.self)
        }
    }

    func emitStderrLine(_ line: String, suffix: String = "") {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        let message = suffix.isEmpty ? trimmed : trimmed + suffix
        continuation.yield(.stderr(message))
    }

}
