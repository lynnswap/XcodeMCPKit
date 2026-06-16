import Foundation
import Logging
import ProxyCore
import ProxyMCP

public actor StdioAdapter {
    private struct RequestEnvelope {
        let method: String?
        let ids: [JSONValue]

        var expectsResponse: Bool {
            !ids.isEmpty
        }
    }

    private struct RequestResult {
        let payloads: [Data]
        let shouldStartSSEAfterOutput: Bool
    }

    private enum AdapterError: Error {
        case invalidResponse
        case httpStatus(Int)
    }

    private let upstreamURL: URL
    private let requestTimeout: TimeInterval
    private let inputHandle: FileHandle
    private let outputWriter: StdioWriter
    private let logger: Logger
    private let session: URLSession
    private var sessionID: String?
    private var negotiatedProtocolVersion: String?
    private var framer = StdioFramer()
    private var requestTasks: [UUID: Task<Void, Never>] = [:]
    private var initializationTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var sseTask: Task<Void, Never>?
    private var started = false
    private var stopped = false

    public init(
        upstreamURL: URL,
        requestTimeout: TimeInterval,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        self.upstreamURL = upstreamURL
        self.requestTimeout = requestTimeout
        self.inputHandle = input
        self.logger = ProxyLogging.make("stdio.adapter")
        self.outputWriter = StdioWriter(handle: output, logger: logger)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    public func start() async {
        guard !started else { return }
        started = true
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
            let result = try await sendRequest(data)
            if result.payloads.isEmpty == false {
                for payload in result.payloads {
                    await outputWriter.send(payload)
                }
                if result.shouldStartSSEAfterOutput {
                    startSSEIfNeeded()
                }
            } else if envelope.expectsResponse {
                await emitError(for: envelope, message: "upstream returned empty response")
            } else if result.shouldStartSSEAfterOutput {
                startSSEIfNeeded()
            }
        } catch let error as AdapterError {
            if stopped || Task.isCancelled { return }
            logger.error("STDIO upstream request failed", metadata: ["error": "\(error)"])
            switch error {
            case .httpStatus(let status):
                await emitError(for: envelope, message: "upstream HTTP \(status)")
            case .invalidResponse:
                await emitError(for: envelope, message: "invalid upstream response")
            }
        } catch {
            if stopped || Task.isCancelled { return }
            logger.error("STDIO upstream request failed", metadata: ["error": "\(error)"])
            await emitError(for: envelope, message: "upstream unavailable")
        }
    }

    private func sendRequest(_ data: Data) async throws -> RequestResult {
        let envelope = inspectRequest(data)
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if envelope.method != "initialize", let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        }
        if envelope.method != "initialize", let negotiatedProtocolVersion {
            request.setValue(negotiatedProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        applyTimeout(to: &request)
        request.httpBody = data

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AdapterError.invalidResponse
        }
        if (200...299).contains(http.statusCode) {
            let payloads = responsePayloadsData(responseData, from: http)
            if payloads.isEmpty {
                return RequestResult(payloads: [], shouldStartSSEAfterOutput: false)
            }
            if envelope.method == "initialize" {
                updateSessionState(from: http, payloads: payloads)
            }
            guard payloads.allSatisfy({ isValidJSONPayload($0) }) else {
                throw AdapterError.invalidResponse
            }
            return RequestResult(
                payloads: payloads,
                shouldStartSSEAfterOutput: envelope.method == "initialize"
            )
        }
        let payloads = responsePayloadsData(responseData, from: http)
        if payloads.isEmpty == false,
            payloads.allSatisfy({ isValidJSONPayload($0) })
        {
            return RequestResult(payloads: payloads, shouldStartSSEAfterOutput: false)
        }
        throw AdapterError.httpStatus(http.statusCode)
    }

    private func updateSessionState(from response: HTTPURLResponse, payloads: [Data]) {
        if let returnedSessionID = response.value(forHTTPHeaderField: "MCP-Session-Id"),
            returnedSessionID.isEmpty == false
        {
            sessionID = returnedSessionID
        }
        if let version = payloads.lazy.compactMap({ self.initializeProtocolVersion(from: $0) }).first {
            negotiatedProtocolVersion = version
        }
    }

    private func responsePayloadsData(_ data: Data, from response: HTTPURLResponse) -> [Data] {
        guard !data.isEmpty else { return [] }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.hasPrefix("text/event-stream") else { return [data] }
        return ssePayloadsData(from: data)
    }

    private func ssePayloadsData(from data: Data) -> [Data] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var decoder = SSEDecoder()
        var payloads: [Data] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : Substring(rawLine)
            if let eventPayload = decoder.feed(line: String(line)) {
                payloads.append(eventPayload)
            }
        }
        if let tail = decoder.flushIfNeeded() {
            payloads.append(tail)
        }
        return payloads
    }

    private func initializeProtocolVersion(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let result = object["result"] as? [String: Any],
            let protocolVersion = result["protocolVersion"] as? String,
            MCPProtocolVersion.isSupported(protocolVersion)
        else {
            return nil
        }
        return protocolVersion
    }

    private func startSSEIfNeeded() {
        guard sessionID != nil, negotiatedProtocolVersion != nil, sseTask == nil, !stopped else {
            return
        }
        sseTask = Task { [weak self] in
            await self?.sseLoop()
        }
    }

    private func sseLoop() async {
        var attempt = 0
        while !stopped {
            do {
                try await consumeSSE()
                attempt = 0
            } catch is CancellationError {
                return
            } catch {
                if stopped || Task.isCancelled { return }
                logger.warning("SSE disconnected", metadata: ["error": "\(error)"])
            }

            if stopped || Task.isCancelled { break }
            let delay = backoffDelay(for: attempt)
            attempt += 1
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func consumeSSE() async throws {
        guard let sessionID, let negotiatedProtocolVersion else {
            throw AdapterError.invalidResponse
        }
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        request.setValue(negotiatedProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        applyTimeout(to: &request, allowLongRunning: true)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AdapterError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw AdapterError.httpStatus(http.statusCode)
        }

        var decoder = SSEDecoder()
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard let payload = decoder.feed(line: line) else { continue }
            guard isValidJSONPayload(payload) else {
                logger.warning("Dropping invalid SSE payload", metadata: ["bytes": "\(payload.count)"])
                continue
            }
            await outputWriter.send(payload)
        }

        // If the stream ends without a terminating blank line, flush any buffered event.
        if let tail = decoder.flushIfNeeded(), isValidJSONPayload(tail) {
            await outputWriter.send(tail)
        }
    }

    private func applyTimeout(to request: inout URLRequest, allowLongRunning: Bool = false) {
        if allowLongRunning {
            request.timeoutInterval = .infinity
            return
        }
        if requestTimeout > 0 {
            request.timeoutInterval = requestTimeout
        } else {
            request.timeoutInterval = .infinity
        }
    }

    private func backoffDelay(for attempt: Int) -> UInt64 {
        let capped = min(attempt, 4)
        let seconds = min(5.0, 0.5 * Double(1 << capped))
        return UInt64(seconds * 1_000_000_000)
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
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !requestTasks.isEmpty, clock.now < deadline {
            try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(10)))
        }

        guard !requestTasks.isEmpty else { return }
        sseTask?.cancel()
        await deleteSessionIfNeeded()
        for task in requestTasks.values {
            task.cancel()
        }
        stopped = true
        session.invalidateAndCancel()
        await drainRequestTasks()
    }

    private func stop(cancelReadTask: Bool) async {
        if !stopped {
            await deleteSessionIfNeeded()
        }
        stopLocked(cancelReadTask: cancelReadTask)
    }

    private func deleteSessionIfNeeded() async {
        guard let sessionID else { return }
        let negotiatedProtocolVersion = self.negotiatedProtocolVersion
        defer {
            self.sessionID = nil
            self.negotiatedProtocolVersion = nil
        }
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = "DELETE"
        request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        if let negotiatedProtocolVersion {
            request.setValue(negotiatedProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        applyTimeout(to: &request)
        let urlSession = session
        let deleteRequest = request
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try? await urlSession.data(for: deleteRequest)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func stopLocked(cancelReadTask: Bool) {
        if cancelReadTask {
            readTask?.cancel()
        }
        sseTask?.cancel()
        readTask = nil
        sseTask = nil
        if !stopped {
            stopped = true
            session.invalidateAndCancel()
        }
    }

    private func inspectRequest(_ data: Data) -> RequestEnvelope {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return RequestEnvelope(method: nil, ids: [])
        }
        if let object = json as? [String: Any] {
            let method = JSONRPCMessageInspector.method(from: object)
            let ids = JSONRPCMessageInspector.requestID(from: object).map { [$0.value] } ?? []
            return RequestEnvelope(method: method, ids: ids)
        }
        if let array = json as? [Any] {
            var ids: [JSONValue] = []
            for item in array {
                guard let object = item as? [String: Any] else { continue }
                if let id = JSONRPCMessageInspector.requestID(from: object) {
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
