import XcodeMCPCore
import Foundation
import Darwin
import Logging

private final class StdinWriter: @unchecked Sendable {
    private struct State: Sendable {
        var queuedBytes = 0
        var isClosed = false
    }

    private let fileHandle: FileHandle
    private let maxQueuedWriteBytes: Int
    private let queue: DispatchQueue
    private let state = NSLock()
    private var queuedBytes = 0
    private var isClosed = false
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

        queue.async { [fileHandle] in
            try? fileHandle.close()
        }
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
        onTermination: @escaping @Sendable (Int32) -> Void,
        onStdinWriteComplete: @escaping @Sendable (Int, Error?) -> Void
    ) throws -> UpstreamProcessStartedIO
    func sendStdin(_ payload: Data) -> Upstream.SendResult
    func closeStdin()
    func terminate() -> Bool
    func stopOutput()
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
        onTermination: @escaping @Sendable (Int32) -> Void,
        onStdinWriteComplete: @escaping @Sendable (Int, Error?) -> Void
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
                self?.completeQueuedWrite(bytes: bytes)
                onStdinWriteComplete(bytes, error)
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

    private func completeQueuedWrite(bytes: Int) {
        let stdinWriter = lock.withLock { state.stdinWriter }
        stdinWriter?.completeWrite(bytes: bytes)
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

package struct UpstreamProcess: UpstreamSessionFactory {
    package struct Config: Sendable {
        package var command: String
        package var args: [String]
        package var environment: [String: String]
        package var maxQueuedWriteBytes: Int
        package var terminationDrainGrace: Duration
        package var clock: ClockClient
        package var driverFactory: any UpstreamProcessDriverMaking

        package init(
            command: String,
            args: [String],
            environment: [String: String],
            maxQueuedWriteBytes: Int,
            terminationDrainGrace: Duration = .milliseconds(250),
            clock: ClockClient = .liveValue,
            driverFactory: any UpstreamProcessDriverMaking = LiveUpstreamProcessDriverFactory()
        ) {
            self.command = command
            self.args = args
            self.environment = environment
            self.maxQueuedWriteBytes = maxQueuedWriteBytes
            self.terminationDrainGrace = terminationDrainGrace
            self.clock = clock
            self.driverFactory = driverFactory
        }
    }

    private let config: Config

    package init(config: Config) {
        self.config = config
    }

    package func startSession() async throws -> any UpstreamSession {
        try await ProcessBackedUpstreamSession.start(config: config)
    }
}

package actor ProcessBackedUpstreamSession: UpstreamSession {
    package nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation

    private let config: UpstreamProcess.Config
    private let logger: Logger = XcodeMCPRuntimeLogging.make("upstream")
    private let maxBufferedStderrBytes = 16 * 1024

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
    private var didFinishEvents = false
    private var isStopping = false

    package static func start(config: UpstreamProcess.Config) async throws -> ProcessBackedUpstreamSession {
        let session = ProcessBackedUpstreamSession(config: config)
        try await session.runProcess()
        return session
    }

    private init(config: UpstreamProcess.Config) {
        self.config = config

        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
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
        guard !isStopping else {
            return
        }

        isStopping = true
        suppressExitEvent = true
        terminationDrainTimeoutTask?.cancel()
        terminationDrainTimeoutTask = nil
        driver?.closeStdin()
        driver?.stopOutput()

        if driver?.terminate() != true {
            terminationObserved = true
        }

        await stdoutTask?.value
        await stderrTask?.value
        finishEventsIfNeeded(force: true)
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
        didFinishEvents = false
        isStopping = false

        let driver = config.driverFactory.makeDriver()
        self.driver = driver
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
            } onStdinWriteComplete: { [weak self] bytes, error in
                Task {
                    await self?.completeQueuedWrite(bytes: bytes, error: error)
                }
            }
        } catch {
            driver.stopOutput()
            driver.closeStdin()
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
        await terminateSession(suppressExitEvent: true)
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
        if !suppressExitEvent {
            pendingExitStatus = status
            scheduleTerminationDrainTimeoutIfNeeded()
        }
        // Let pipe readers drain any bytes the kernel still holds after process exit.
        finishEventsIfNeeded()
    }

    func terminateSession(suppressExitEvent: Bool) async {
        guard !isStopping else {
            return
        }

        isStopping = true
        if suppressExitEvent {
            self.suppressExitEvent = true
        }
        terminationDrainTimeoutTask?.cancel()
        terminationDrainTimeoutTask = nil
        driver?.closeStdin()
        driver?.stopOutput()

        if driver?.terminate() != true {
            terminationObserved = true
            finishEventsIfNeeded()
        }
    }

    func completeQueuedWrite(bytes: Int, error: Error?) {
        guard let error else {
            return
        }
        logger.warning("Upstream async write failed", metadata: ["error": "\(error)"])
    }

    func finishEventsIfNeeded(force: Bool = false) {
        guard !didFinishEvents else {
            return
        }
        guard force || (terminationObserved && stdoutDrained && stderrDrained) else {
            return
        }

        didFinishEvents = true
        driver = nil
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

        driver?.stopOutput()
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
