import Foundation
import Logging
import XcodeMCPCore
import XcodeMCPProcessRuntime

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

protocol StdioAdapterHTTPClient: Sendable {
    var events: AsyncStream<Data> { get }

    func send(
        _ data: Data,
        onMessage: @Sendable (Data) async throws -> StreamableHTTPMCPClientMessageDisposition
    ) async throws -> StreamableHTTPMCPClientSendResult

    func startEventStreamIfReady() async

    func close(
        deleteTimeout: Duration?,
        deleteSessionGrace: Duration?,
        clock: ClockClient
    ) async

    func cancelNetworkRequests() async
}

extension StreamableHTTPMCPClient: StdioAdapterHTTPClient {}

actor StdioAdapter {
    private enum AdapterError: Error {
        case invalidResponse
        case httpStatus(Int)
    }

    private let requestTimeout: TimeInterval
    private let inputHandle: FileHandle
    private let outputWriter: StdioWriter
    private let logger: Logger
    private let client: any StdioAdapterHTTPClient
    private let shutdownPolicy: StdioAdapterShutdownPolicy
    private var framer = StdioFramer()
    private var requestTasks: [UUID: Task<Void, Never>] = [:]
    private var initializationTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var clientEventTask: Task<Void, Never>?
    private var started = false
    private var stopped = false

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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        let client = StreamableHTTPMCPClient(
            endpoint: upstreamURL,
            urlSession: URLSession(configuration: configuration),
            requestTimeout: Self.duration(fromRequestTimeout: requestTimeout),
            automaticallyStartsEventStream: false
        )
        self.init(
            requestTimeout: requestTimeout,
            input: input,
            output: output,
            client: client,
            shutdownPolicy: shutdownPolicy
        )
    }

    init(
        requestTimeout: TimeInterval,
        input: FileHandle,
        output: FileHandle,
        client: any StdioAdapterHTTPClient,
        shutdownPolicy: StdioAdapterShutdownPolicy
    ) {
        self.requestTimeout = requestTimeout
        self.inputHandle = input
        let logger = ProxyLogging.make("stdio.adapter")
        self.logger = logger
        self.outputWriter = StdioWriter(handle: output, logger: logger)
        self.shutdownPolicy = shutdownPolicy
        self.client = client
    }

    func start() async {
        guard !started else { return }
        started = true
        startClientEventTaskIfNeeded()
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    func wait() async {
        _ = await readTask?.value
    }

    func stop() async {
        await stop(cancelReadTask: true)
    }

    private func readLoop() async {
        do {
            for try await byte in inputHandle.bytes {
                if Task.isCancelled { break }
                await handleInput(Data([byte]))
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("STDIO read failed", metadata: ["error": "\(error)"])
        }

        await drainRequestTasksAfterInputClosed()
        await stop(cancelReadTask: false)
    }

    private func handleInput(_ data: Data) async {
        if stopped { return }

        let result = framer.append(data)
        for message in result.messages {
            let requestID = UUID()
            let method = inspectRequest(message).method
            let pendingInitialization = initializationTask
            let task = Task { [weak self] in
                _ = await pendingInitialization?.value
                guard let self else { return }
                await self.runRequestTask(id: requestID, data: message)
            }
            if method == "initialize" {
                initializationTask = task
            }
            requestTasks[requestID] = task
        }

        guard let protocolViolation = result.protocolViolation else {
            return
        }

        logger.error(
            "Fatal STDIO input protocol violation",
            metadata: [
                "reason": "\(protocolViolation.reason.rawValue)",
                "buffered_bytes": "\(protocolViolation.bufferedByteCount)",
                "preview": "\(protocolViolation.preview)",
            ]
        )
        await stopLocked(cancelReadTask: true)
    }

    private func runRequestTask(id: UUID, data: Data) async {
        defer {
            requestTasks.removeValue(forKey: id)
        }
        await processMessage(data)
    }

    private func processMessage(_ data: Data) async {
        if stopped { return }
        let envelope = inspectRequest(data)
        do {
            let messageCount = try await sendRequest(data, envelope: envelope)
            if messageCount == 0, envelope.expectsResponse {
                await emitError(for: envelope, message: "upstream returned empty response")
            }
            await client.startEventStreamIfReady()
        } catch let error as AdapterError {
            if stopped || Task.isCancelled { return }
            logger.error("STDIO upstream request failed", metadata: ["error": "\(error)"])
            switch error {
            case .invalidResponse:
                await emitError(for: envelope, message: "invalid upstream response")
            case .httpStatus(let status):
                await emitError(for: envelope, message: "upstream HTTP \(status)")
            }
        } catch {
            if stopped || Task.isCancelled { return }
            logger.error("STDIO upstream request failed", metadata: ["error": "\(error)"])
            await emitError(for: envelope, message: "upstream unavailable")
        }
    }

    private func sendRequest(_ data: Data, envelope: JSONRPC.Request.Envelope) async throws -> Int {
        let responseCompletion = JSONRPC.ResponseCompletionTracker(ids: envelope.ids)
        do {
            let result = try await client.send(data) { payload in
                guard isValidJSONPayload(payload) else {
                    throw AdapterError.invalidResponse
                }
                await outputWriter.send(payload)
                if await responseCompletion.record(payload) {
                    return .stop
                }
                return .continue
            }
            return result.messageCount
        } catch let error as StreamableHTTPMCPClientError {
            return try await handleClientError(error)
        }
    }

    private func handleClientError(_ error: StreamableHTTPMCPClientError) async throws -> Int {
        switch error {
        case .httpStatus(let statusCode, _, let payloads):
            guard payloads.isEmpty == false else {
                throw AdapterError.httpStatus(statusCode)
            }
            guard payloads.allSatisfy({ isValidJSONPayload($0) }) else {
                throw AdapterError.httpStatus(statusCode)
            }
            for payload in payloads {
                await outputWriter.send(payload)
            }
            return payloads.count
        }
    }

    private func startClientEventTaskIfNeeded() {
        guard clientEventTask == nil else { return }
        let events = client.events
        let outputWriter = outputWriter
        let logger = logger
        clientEventTask = Task {
            for await payload in events {
                if Task.isCancelled { break }
                guard isValidJSONPayload(payload) else {
                    logger.warning("Dropping invalid SSE payload", metadata: ["bytes": "\(payload.count)"])
                    continue
                }
                await outputWriter.send(payload)
            }
        }
    }

    private func drainRequestTasks() async {
        while !requestTasks.isEmpty {
            let tasks = Array(requestTasks.values)
            for task in tasks {
                _ = await task.result
            }
        }
    }

    private func drainRequestTasksAfterInputClosed() async {
        guard !requestTasks.isEmpty else { return }

        // Allow in-flight requests to finish normally on clean EOF, but cap how long shutdown waits
        // before canceling the session to avoid hanging indefinitely on stalled requests.
        let deadline = requestDrainDeadline()
        while !requestTasks.isEmpty, requestDrainDeadlineHasTimeRemaining(deadline) {
            await shutdownPolicy.clock.sleep(requestDrainPollDuration(until: deadline))
        }

        guard !requestTasks.isEmpty else { return }
        clientEventTask?.cancel()
        await closeClientSession()
        for task in requestTasks.values {
            task.cancel()
        }
        stopped = true
        await client.cancelNetworkRequests()
        await drainRequestTasks()
    }

    private func stop(cancelReadTask: Bool) async {
        if !stopped {
            await closeClientSession()
        }
        await stopLocked(cancelReadTask: cancelReadTask)
    }

    private func closeClientSession() async {
        await client.close(
            deleteTimeout: Self.duration(fromRequestTimeout: requestTimeout),
            deleteSessionGrace: shutdownPolicy.deleteSessionGrace,
            clock: shutdownPolicy.clock
        )
    }

    private func requestDrainDeadline() -> UInt64? {
        let timeoutNanoseconds = Self.nanoseconds(in: shutdownPolicy.requestDrainTimeout)
        guard timeoutNanoseconds > 0 else { return nil }
        let now = shutdownPolicy.clock.uptimeNanoseconds()
        let clamped = min(timeoutNanoseconds, UInt64.max &- now)
        return now &+ clamped
    }

    private func requestDrainDeadlineHasTimeRemaining(_ deadline: UInt64?) -> Bool {
        guard let deadline else { return false }
        return shutdownPolicy.clock.uptimeNanoseconds() < deadline
    }

    private func requestDrainPollDuration(until deadline: UInt64?) -> Duration {
        guard let deadline else { return .zero }
        let now = shutdownPolicy.clock.uptimeNanoseconds()
        guard deadline > now else { return .zero }
        let pollNanoseconds = max(1, Self.nanoseconds(in: shutdownPolicy.requestDrainPollInterval))
        let remainingNanoseconds = deadline &- now
        let sleepNanoseconds = min(pollNanoseconds, remainingNanoseconds, UInt64(Int64.max))
        return .nanoseconds(Int64(sleepNanoseconds))
    }

    private static func nanoseconds(in duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        let secondsComponent = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        if secondsComponent.overflow {
            return UInt64.max
        }
        let nanosecondsComponent = UInt64(attoseconds / 1_000_000_000)
        let total = secondsComponent.partialValue.addingReportingOverflow(nanosecondsComponent)
        return total.overflow ? UInt64.max : total.partialValue
    }

    private static func duration(fromRequestTimeout requestTimeout: TimeInterval) -> Duration? {
        guard requestTimeout > 0, requestTimeout.isFinite else { return nil }
        let nanoseconds = (requestTimeout * 1_000_000_000).rounded(.up)
        if nanoseconds >= Double(Int64.max) {
            return .nanoseconds(Int64.max)
        }
        return .nanoseconds(Int64(nanoseconds))
    }

    private func stopLocked(cancelReadTask: Bool) async {
        if cancelReadTask {
            readTask?.cancel()
        }
        clientEventTask?.cancel()
        readTask = nil
        clientEventTask = nil
        if !stopped {
            stopped = true
            await client.cancelNetworkRequests()
        }
    }

    private func inspectRequest(_ data: Data) -> JSONRPC.Request.Envelope {
        JSONRPC.Request.Envelope.inspect(data)
    }

    private func emitError(for envelope: JSONRPC.Request.Envelope, message: String) async {
        guard envelope.expectsResponse else { return }
        guard let payload = try? JSONRPC.Wire.errorResponseData(
            idValues: envelope.ids,
            code: -32000,
            message: message
        ) else { return }
        await outputWriter.send(payload)
    }
}
