import Foundation
import Logging
import XcodeMCPKit

package struct StdioAdapterShutdownPolicy: Sendable {
    package let requestDrainTimeout: Duration
    package let requestDrainPollInterval: Duration
    package let deleteSessionGrace: Duration
    package let clock: ClockClient

    package init(
        requestDrainTimeout: Duration = .seconds(1),
        requestDrainPollInterval: Duration = .milliseconds(10),
        deleteSessionGrace: Duration = .milliseconds(250),
        clock: ClockClient = .liveValue
    ) {
        self.requestDrainTimeout = requestDrainTimeout
        self.requestDrainPollInterval = requestDrainPollInterval
        self.deleteSessionGrace = deleteSessionGrace
        self.clock = clock
    }

    package static let live = Self()
}

actor StdioAdapter {
    private enum Lifecycle {
        case idle
        case running
        case closing
        case closed
    }

    private let requestTimeout: Duration?
    private let inputHandle: FileHandle
    private let outputWriter: StdioWriter
    private let logger: Logger
    private let authority: MCPClientSessionAuthority
    private let shutdownPolicy: StdioAdapterShutdownPolicy

    private var framer = StdioFramer()
    private var requestTasks: [UUID: Task<Void, Never>] = [:]
    private var readTask: Task<Void, Never>?
    private var authorityEventTask: Task<Void, Never>?
    private var lifecycle: Lifecycle = .idle
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        upstreamURL: URL,
        requestTimeout: TimeInterval,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        self.init(
            upstreamURL: upstreamURL,
            requestTimeout: requestTimeout,
            input: input,
            output: output,
            shutdownPolicy: .live
        )
    }

    init(
        upstreamURL: URL,
        requestTimeout: TimeInterval,
        input: FileHandle,
        output: FileHandle,
        shutdownPolicy: StdioAdapterShutdownPolicy
    ) {
        let timeout = Self.duration(fromRequestTimeout: requestTimeout)
        let recipe = MCPTransportRecipe {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            return StreamableHTTPXcodeMCPTransport(
                endpoint: upstreamURL,
                urlSession: URLSession(configuration: configuration),
                requestTimeout: timeout,
                deleteSessionGrace: shutdownPolicy.deleteSessionGrace,
                clock: shutdownPolicy.clock
            )
        }
        self.init(
            requestTimeout: timeout,
            input: input,
            output: output,
            recipe: recipe,
            shutdownPolicy: shutdownPolicy
        )
    }

    init(
        requestTimeout: Duration?,
        input: FileHandle,
        output: FileHandle,
        recipe: MCPTransportRecipe,
        shutdownPolicy: StdioAdapterShutdownPolicy
    ) {
        self.requestTimeout = requestTimeout
        self.inputHandle = input
        let logger = ProxyLogging.make("stdio.adapter")
        self.logger = logger
        self.outputWriter = StdioWriter(handle: output, logger: logger)
        self.shutdownPolicy = shutdownPolicy
        self.authority = MCPClientSessionAuthority.makeForwarded(
            recipe: recipe,
            defaultTimeout: requestTimeout,
            clock: shutdownPolicy.clock
        )
    }

    func start() {
        guard lifecycle == .idle else { return }
        lifecycle = .running
        startAuthorityEventTask()
        let input = inputHandle
        readTask = Task { [weak self] in
            var terminalError: (any Error)?
            do {
                for try await byte in input.bytes {
                    guard Task.isCancelled == false else { break }
                    await self?.handleInput(Data([byte]))
                }
            } catch is CancellationError {
                // Explicit stop owns completion.
            } catch {
                terminalError = error
            }
            await self?.inputDidEnd(error: terminalError)
        }
    }

    func wait() async {
        await readTask?.value
    }

    func stop() async {
        let task = readTask
        await close(cancelReadTask: true)
        await task?.value
    }

    isolated deinit {
        readTask?.cancel()
        authorityEventTask?.cancel()
        for task in requestTasks.values { task.cancel() }
        for waiter in closeWaiters { waiter.resume() }
    }
}

private extension StdioAdapter {
    func inputDidEnd(error: (any Error)?) async {
        if let error {
            logger.error("STDIO read failed", metadata: ["error": "\(error)"])
        }
        if lifecycle == .running {
            await drainRequestTasksAfterInputClosed()
            await close(cancelReadTask: false)
        }
    }

    func handleInput(_ data: Data) async {
        guard lifecycle == .running else { return }
        let result = framer.append(data)
        for message in result.messages {
            let requestID = UUID()
            let requestEnvelope = JSONRPC.Request.Envelope.inspect(message)
            let envelope: MCPClientEnvelope
            do {
                envelope = try MCPClientEnvelope(data: message)
            } catch {
                await emitError(for: requestEnvelope, message: "invalid upstream response")
                continue
            }
            let deadline = Deadline.fromNow(requestTimeout, clock: shutdownPolicy.clock)
            let replayPolicy = replayPolicy(for: envelope)
            let authority = authority
            let task = Task { [weak self] in
                do {
                    try await authority.send(MCPClientOperation(
                        envelope: envelope,
                        deadline: deadline,
                        replayPolicy: replayPolicy
                    ))
                    await self?.operationFinished(
                        id: requestID,
                        requestEnvelope: requestEnvelope,
                        error: nil
                    )
                } catch {
                    await self?.operationFinished(
                        id: requestID,
                        requestEnvelope: requestEnvelope,
                        error: error
                    )
                }
            }
            requestTasks[requestID] = task
        }

        guard let violation = result.protocolViolation else { return }
        logger.error(
            "Fatal STDIO input protocol violation",
            metadata: [
                "reason": "\(violation.reason.rawValue)",
                "buffered_bytes": "\(violation.bufferedByteCount)",
                "preview": "\(violation.preview)",
            ]
        )
        await close(cancelReadTask: true)
    }

    func operationFinished(
        id: UUID,
        requestEnvelope: JSONRPC.Request.Envelope,
        error: (any Error)?
    ) async {
        requestTasks.removeValue(forKey: id)
        guard let error, error is CancellationError == false, lifecycle == .running else { return }
        logger.error("STDIO upstream request failed", metadata: ["error": "\(error)"])
        await emitError(for: requestEnvelope, message: adapterErrorMessage(error))
    }

    func replayPolicy(for envelope: MCPClientEnvelope) -> MCPReplayPolicy {
        switch envelope.kind {
        case .response:
            .never
        case .notification(let method) where method == "notifications/cancelled":
            .never
        case .notification:
            .never
        case .request:
            .onceWhenRejectedBeforeProcessing
        }
    }

    func startAuthorityEventTask() {
        guard authorityEventTask == nil else { return }
        let events = authority.events
        let writer = outputWriter
        let logger = logger
        authorityEventTask = Task {
            for await event in events {
                guard Task.isCancelled == false else { return }
                switch event {
                case .message(_, let envelope):
                    await writer.send(envelope.data)
                case .connectionState(let snapshot):
                    if case .unavailable(let failure) = snapshot.phase {
                        logger.warning(
                            "STDIO upstream connection unavailable",
                            metadata: ["failure": "\(failure)"]
                        )
                    }
                }
            }
        }
    }

    func close(cancelReadTask: Bool) async {
        switch lifecycle {
        case .closed:
            return
        case .closing:
            await withCheckedContinuation { closeWaiters.append($0) }
            return
        case .idle, .running:
            lifecycle = .closing
        }

        if cancelReadTask { readTask?.cancel() }
        for task in requestTasks.values { task.cancel() }
        await authority.close()
        await drainRequestTasks()
        authorityEventTask?.cancel()
        let eventTask = authorityEventTask
        authorityEventTask = nil
        await eventTask?.value
        lifecycle = .closed
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func drainRequestTasks() async {
        while requestTasks.isEmpty == false {
            let tasks = Array(requestTasks.values)
            for task in tasks { await task.value }
        }
    }

    func drainRequestTasksAfterInputClosed() async {
        guard requestTasks.isEmpty == false else { return }
        let deadline = requestDrainDeadline()
        while requestTasks.isEmpty == false, requestDrainDeadlineHasTimeRemaining(deadline) {
            await shutdownPolicy.clock.sleep(requestDrainPollDuration(until: deadline))
        }
    }

    func requestDrainDeadline() -> UInt64? {
        let timeoutNanoseconds = Self.nanoseconds(in: shutdownPolicy.requestDrainTimeout)
        guard timeoutNanoseconds > 0 else { return nil }
        let now = shutdownPolicy.clock.uptimeNanoseconds()
        return now &+ min(timeoutNanoseconds, UInt64.max &- now)
    }

    func requestDrainDeadlineHasTimeRemaining(_ deadline: UInt64?) -> Bool {
        guard let deadline else { return false }
        return shutdownPolicy.clock.uptimeNanoseconds() < deadline
    }

    func requestDrainPollDuration(until deadline: UInt64?) -> Duration {
        guard let deadline else { return .zero }
        let now = shutdownPolicy.clock.uptimeNanoseconds()
        guard deadline > now else { return .zero }
        let poll = max(1, Self.nanoseconds(in: shutdownPolicy.requestDrainPollInterval))
        return .nanoseconds(Int64(min(poll, deadline - now, UInt64(Int64.max))))
    }

    func adapterErrorMessage(_ error: any Error) -> String {
        if let failure = error as? MCPTransportFailure {
            switch failure {
            case .sessionExpired:
                return "upstream session expired"
            case .deliveryUnknown:
                return "upstream delivery status is unknown"
            case .unavailable:
                return "upstream unavailable"
            }
        }
        if let runtime = error as? MCPBridgeRuntimeError {
            switch runtime {
            case .invalidRequest, .invalidResponse:
                return "invalid upstream response"
            case .requestTimedOut:
                return "upstream request timed out"
            case .closed, .serverError, .transportUnavailable:
                return "upstream unavailable"
            }
        }
        return "upstream unavailable"
    }

    func emitError(for envelope: JSONRPC.Request.Envelope, message: String) async {
        guard envelope.expectsResponse else { return }
        guard let payload = try? JSONRPC.Wire.errorResponseData(
            idValues: envelope.ids,
            code: -32000,
            message: message
        ) else { return }
        await outputWriter.send(payload)
    }

    static func nanoseconds(in duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = UInt64(max(0, components.seconds))
        let nanos = UInt64(max(0, components.attoseconds) / 1_000_000_000)
        let product = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard product.overflow == false else { return .max }
        let total = product.partialValue.addingReportingOverflow(nanos)
        return total.overflow ? .max : total.partialValue
    }

    static func duration(fromRequestTimeout requestTimeout: TimeInterval) -> Duration? {
        guard requestTimeout > 0, requestTimeout.isFinite else { return nil }
        let nanoseconds = (requestTimeout * 1_000_000_000).rounded(.up)
        return .nanoseconds(nanoseconds >= Double(Int64.max) ? .max : Int64(nanoseconds))
    }
}
