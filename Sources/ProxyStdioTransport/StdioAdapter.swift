import Foundation
import Logging
import ProxyCore
import ProxyMCP
import XcodeMCPBridgeRuntime

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

public actor StdioAdapter {
    private struct RequestEnvelope {
        let method: String?
        let ids: [JSONValue]

        var expectsResponse: Bool {
            !ids.isEmpty
        }
    }

    private enum AdapterError: Error {
        case invalidResponse
        case httpStatus(Int)
    }

    private let requestTimeout: TimeInterval
    private let inputHandle: FileHandle
    private let outputWriter: StdioWriter
    private let logger: Logger
    private let client: StreamableHTTPMCPClient
    private let shutdownPolicy: StdioAdapterShutdownPolicy
    private var framer = StdioFramer()
    private var requestTasks: [UUID: Task<Void, Never>] = [:]
    private var initializationTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var clientEventTask: Task<Void, Never>?
    private var started = false
    private var stopped = false

    public init(
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

    package init(
        upstreamURL: URL,
        requestTimeout: TimeInterval,
        input: FileHandle,
        output: FileHandle,
        shutdownPolicy: StdioAdapterShutdownPolicy
    ) {
        self.requestTimeout = requestTimeout
        self.inputHandle = input
        self.logger = ProxyLogging.make("stdio.adapter")
        self.outputWriter = StdioWriter(handle: output, logger: logger)
        self.shutdownPolicy = shutdownPolicy
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        self.client = StreamableHTTPMCPClient(
            endpoint: upstreamURL,
            urlSession: URLSession(configuration: configuration),
            requestTimeout: Self.duration(fromRequestTimeout: requestTimeout)
        )
    }

    public func start() async {
        guard !started else { return }
        started = true
        startClientEventTaskIfNeeded()
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    public func wait() async {
        _ = await readTask?.value
    }

    public func stop() async {
        await stop(cancelReadTask: true)
    }

    private func readLoop() async {
        do {
            for try await byte in inputHandle.bytes {
                if Task.isCancelled { break }
                handleInput(Data([byte]))
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("STDIO read failed", metadata: ["error": "\(error)"])
        }

        await drainRequestTasksAfterInputClosed()
        await stop(cancelReadTask: false)
    }

    private func handleInput(_ data: Data) {
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
        stopLocked(cancelReadTask: true)
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
            let messageCount = try await sendRequest(data)
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

    private func sendRequest(_ data: Data) async throws -> Int {
        do {
            let result = try await client.send(data) { payload in
                guard isValidJSONPayload(payload) else {
                    throw AdapterError.invalidResponse
                }
                await outputWriter.send(payload)
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
                throw AdapterError.invalidResponse
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
        client.cancelNetworkRequests()
        await drainRequestTasks()
    }

    private func stop(cancelReadTask: Bool) async {
        if !stopped {
            await closeClientSession()
        }
        stopLocked(cancelReadTask: cancelReadTask)
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

    private func stopLocked(cancelReadTask: Bool) {
        if cancelReadTask {
            readTask?.cancel()
        }
        clientEventTask?.cancel()
        readTask = nil
        clientEventTask = nil
        if !stopped {
            stopped = true
            client.cancelNetworkRequests()
        }
    }

    private func inspectRequest(_ data: Data) -> RequestEnvelope {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return RequestEnvelope(method: nil, ids: [])
        }
        if let object = json as? [String: Any] {
            let method = JSONRPC.Message.Inspector.method(from: object)
            let ids = JSONRPC.Message.Inspector.requestID(from: object).map { [$0.value] } ?? []
            return RequestEnvelope(method: method, ids: ids)
        }
        if let array = json as? [Any] {
            var ids: [JSONValue] = []
            for item in array {
                guard let object = item as? [String: Any] else { continue }
                if let id = JSONRPC.Message.Inspector.requestID(from: object) {
                    ids.append(id.value)
                }
            }
            return RequestEnvelope(method: nil, ids: ids)
        }
        return RequestEnvelope(method: nil, ids: [])
    }

    private func emitError(for envelope: RequestEnvelope, message: String) async {
        guard envelope.expectsResponse else { return }
        guard let payload = errorPayload(ids: envelope.ids, message: message) else { return }
        await outputWriter.send(payload)
    }

    private func errorPayload(ids: [JSONValue], message: String) -> Data? {
        let error: [String: Any] = [
            "code": -32000,
            "message": message,
        ]

        if ids.count == 1, let id = ids.first {
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id.foundationObject,
                "error": error,
            ]
            return try? JSONSerialization.data(withJSONObject: response, options: [])
        }

        let responses: [[String: Any]] = ids.map { id in
            [
                "jsonrpc": "2.0",
                "id": id.foundationObject,
                "error": error,
            ]
        }
        guard !responses.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: responses, options: [])
    }
}
