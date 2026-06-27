import Foundation
import ProxyCore

package struct StreamableHTTPMCPClientSendResult: Sendable {
    package let messageCount: Int
}

package enum StreamableHTTPMCPClientMessageDisposition: Sendable {
    case `continue`
    case stop
}

package enum StreamableHTTPMCPClientError: Error, Sendable {
    case httpStatus(Int, body: String, payloads: [Data])
}

package final class StreamableHTTPMCPClient: @unchecked Sendable {
    package nonisolated let events: AsyncStream<Data>

    private static let sessionHeader = "MCP-Session-Id"
    private static let protocolVersionHeader = "MCP-Protocol-Version"
    private static let postAcceptHeader = "application/json, text/event-stream"
    private static let eventStreamContentType = "text/event-stream"

    private let endpoint: URL
    private let urlSession: URLSession
    private let requestTimeout: Duration?
    private let automaticallyStartsEventStream: Bool
    private let eventStreamReconnectSleep: @Sendable (Duration) async throws -> Void
    private let eventContinuation: AsyncStream<Data>.Continuation
    private let state = StreamableHTTPMCPClientState()

    package init(
        endpoint: URL,
        urlSession: URLSession,
        requestTimeout: Duration? = nil,
        automaticallyStartsEventStream: Bool = true,
        eventStreamReconnectSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        let stream = AsyncStream<Data>.makeStream()
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.requestTimeout = requestTimeout
        self.automaticallyStartsEventStream = automaticallyStartsEventStream
        self.eventStreamReconnectSleep = eventStreamReconnectSleep
        self.events = stream.stream
        self.eventContinuation = stream.continuation
    }

    package static func validateEndpoint(_ endpoint: URL) throws {
        guard let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw MCPBridgeRuntimeError.invalidRequest(
                "Streamable HTTP endpoint must use http or https: \(endpoint.absoluteString)"
            )
        }
    }

    package func send(
        _ data: Data,
        onMessage: @Sendable (Data) async throws -> StreamableHTTPMCPClientMessageDisposition
    ) async throws -> StreamableHTTPMCPClientSendResult {
        try await state.ensureOpen()
        let requestInfo = try StreamableHTTPMCPRequestInfo(data: data)
        let request = await makePostRequest(body: data)
        let (responseBytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPBridgeRuntimeError.transportUnavailable("Streamable HTTP response was not HTTP")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw await httpStatusError(httpResponse, body: responseBytes)
        }

        await recordSessionHeader(from: httpResponse, requestInfo: requestInfo)

        if Self.isEventStream(httpResponse) {
            let messageCount = try await emitResponseEventStreamMessages(
                responseBytes,
                requestInfo: requestInfo,
                onMessage: onMessage
            )
            return StreamableHTTPMCPClientSendResult(messageCount: messageCount)
        }

        let responseData = try await Self.collect(responseBytes)
        guard responseData.isEmpty == false else {
            return StreamableHTTPMCPClientSendResult(messageCount: 0)
        }
        await recordInitializeResponseIfNeeded(responseData, requestInfo: requestInfo)
        _ = try await onMessage(responseData)
        return StreamableHTTPMCPClientSendResult(messageCount: 1)
    }

    package func startEventStreamIfReady() async {
        guard let session = await state.eventStreamSessionIfStartable() else {
            return
        }

        let reconnectSleep = eventStreamReconnectSleep
        let task = Task { [endpoint, urlSession, eventContinuation, state, reconnectSleep] in
            var attempt = 0
            while await state.isOpen {
                if attempt > 0 {
                    do {
                        try await reconnectSleep(Self.eventStreamReconnectDelay(attempt: attempt))
                    } catch {
                        return
                    }
                }

                do {
                    let request = Self.makeEventStreamRequest(
                        endpoint: endpoint,
                        sessionID: session.sessionID,
                        protocolVersion: session.protocolVersion
                    )
                    let (bytes, response) = try await urlSession.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw MCPBridgeRuntimeError.transportUnavailable("Streamable HTTP event stream response was not HTTP")
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        if Self.isTerminalEventStreamStatus(httpResponse.statusCode) {
                            return
                        }
                        let bodyData = (try? await Self.collect(bytes)) ?? Data()
                        let body = String(data: bodyData, encoding: .utf8) ?? ""
                        let suffix = body.isEmpty ? "" : ": \(body)"
                        throw MCPBridgeRuntimeError.transportUnavailable(
                            "Streamable HTTP event stream failed with status \(httpResponse.statusCode)\(suffix)"
                        )
                    }
                    guard Self.isEventStream(httpResponse) else {
                        return
                    }
                    try await Self.consumeEventStream(
                        bytes,
                        eventContinuation: eventContinuation
                    )
                    attempt += 1
                } catch is CancellationError {
                    return
                } catch {
                    attempt += 1
                }
            }
        }
        await state.setEventStreamTask(task)
    }

    package func close(
        deleteTimeout: Duration?,
        deleteSessionGrace: Duration? = nil,
        clock: ClockClient = .liveValue
    ) async {
        let closeState = await state.close()
        closeState.eventStreamTask?.cancel()

        guard let sessionID = closeState.sessionID else {
            eventContinuation.finish()
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = Self.urlTimeoutInterval(for: deleteTimeout)
        request.setValue(sessionID, forHTTPHeaderField: Self.sessionHeader)
        if let protocolVersion = closeState.protocolVersion {
            request.setValue(protocolVersion, forHTTPHeaderField: Self.protocolVersionHeader)
        }

        await performDelete(request, grace: deleteSessionGrace, clock: clock)
        eventContinuation.finish()
    }

    package func cancelNetworkRequests() {
        urlSession.invalidateAndCancel()
    }

    private func makePostRequest(body: Data) async -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.urlTimeoutInterval(for: requestTimeout)
        request.httpBody = body
        request.setValue(Self.postAcceptHeader, forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let session = await state.sessionHeaders()
        if let protocolVersion = session.protocolVersion {
            request.setValue(protocolVersion, forHTTPHeaderField: Self.protocolVersionHeader)
        }
        if let sessionID = session.sessionID {
            request.setValue(sessionID, forHTTPHeaderField: Self.sessionHeader)
        }
        return request
    }

    private func httpStatusError(
        _ response: HTTPURLResponse,
        body responseBytes: URLSession.AsyncBytes
    ) async -> StreamableHTTPMCPClientError {
        let responseData = (try? await Self.collect(responseBytes)) ?? Data()
        let body = String(data: responseData, encoding: .utf8) ?? ""
        let payloads = Self.responsePayloadsData(responseData, from: response)
        return .httpStatus(response.statusCode, body: body, payloads: payloads)
    }

    private func recordSessionHeader(
        from response: HTTPURLResponse,
        requestInfo: StreamableHTTPMCPRequestInfo
    ) async {
        guard requestInfo.method == "initialize",
              let sessionID = response.value(forHTTPHeaderField: Self.sessionHeader),
              sessionID.isEmpty == false
        else {
            return
        }
        await state.setSessionID(sessionID)
    }

    private func recordInitializeResponseIfNeeded(
        _ data: Data,
        requestInfo: StreamableHTTPMCPRequestInfo
    ) async {
        guard requestInfo.method == "initialize" else {
            return
        }
        guard let requestIDKey = Self.jsonRPCIDKey(requestInfo.id),
              let object = Self.jsonObject(from: data),
              Self.jsonRPCIDKey(object["id"]) == requestIDKey
        else {
            return
        }
        if object["error"] != nil {
            return
        }
        guard let protocolVersion = Self.initializeProtocolVersion(from: object) else {
            return
        }
        await state.completeInitialize(protocolVersion: protocolVersion)
        if automaticallyStartsEventStream {
            await startEventStreamIfReady()
        }
    }

    private func emitResponseEventStreamMessages(
        _ bytes: URLSession.AsyncBytes,
        requestInfo: StreamableHTTPMCPRequestInfo,
        onMessage: @Sendable (Data) async throws -> StreamableHTTPMCPClientMessageDisposition
    ) async throws -> Int {
        var decoder = SSEDecoder()
        var lineBuffer = Data()
        var messageCount = 0
        for try await byte in bytes {
            guard byte == 0x0A else {
                lineBuffer.append(byte)
                continue
            }
            let line = String(data: lineBuffer, encoding: .utf8) ?? ""
            lineBuffer.removeAll(keepingCapacity: true)
            guard let data = decoder.feed(line: line) else {
                continue
            }
            await recordInitializeResponseIfNeeded(data, requestInfo: requestInfo)
            messageCount += 1
            if try await onMessage(data) == .stop {
                return messageCount
            }
        }
        if lineBuffer.isEmpty == false {
            let line = String(data: lineBuffer, encoding: .utf8) ?? ""
            if let data = decoder.feed(line: line) {
                await recordInitializeResponseIfNeeded(data, requestInfo: requestInfo)
                messageCount += 1
                if try await onMessage(data) == .stop {
                    return messageCount
                }
            }
        }
        if let data = decoder.flushIfNeeded() {
            await recordInitializeResponseIfNeeded(data, requestInfo: requestInfo)
            messageCount += 1
            if try await onMessage(data) == .stop {
                return messageCount
            }
        }
        return messageCount
    }

    private func performDelete(
        _ request: URLRequest,
        grace: Duration?,
        clock: ClockClient
    ) async {
        guard let grace else {
            _ = try? await urlSession.data(for: request)
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [urlSession] in
                _ = try? await urlSession.data(for: request)
            }
            group.addTask {
                await clock.sleep(grace)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private static func makeEventStreamRequest(
        endpoint: URL,
        sessionID: String,
        protocolVersion: String
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = .infinity
        request.setValue(eventStreamContentType, forHTTPHeaderField: "Accept")
        request.setValue(sessionID, forHTTPHeaderField: sessionHeader)
        request.setValue(protocolVersion, forHTTPHeaderField: protocolVersionHeader)
        return request
    }

    private static func consumeEventStream(
        _ bytes: URLSession.AsyncBytes,
        eventContinuation: AsyncStream<Data>.Continuation
    ) async throws {
        var decoder = SSEDecoder()
        var lineBuffer = Data()
        for try await byte in bytes {
            guard byte == 0x0A else {
                lineBuffer.append(byte)
                continue
            }
            let line = String(data: lineBuffer, encoding: .utf8) ?? ""
            lineBuffer.removeAll(keepingCapacity: true)
            if let data = decoder.feed(line: line) {
                eventContinuation.yield(data)
            }
        }
        if lineBuffer.isEmpty == false {
            let line = String(data: lineBuffer, encoding: .utf8) ?? ""
            if let data = decoder.feed(line: line) {
                eventContinuation.yield(data)
            }
        }
        if let data = decoder.flushIfNeeded() {
            eventContinuation.yield(data)
        }
    }

    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private static func isEventStream(_ response: HTTPURLResponse) -> Bool {
        response
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .contains(eventStreamContentType) == true
    }

    private static func responsePayloadsData(_ data: Data, from response: HTTPURLResponse) -> [Data] {
        guard data.isEmpty == false else { return [] }
        guard isEventStream(response) else { return [data] }
        return ssePayloadsData(from: data)
    }

    private static func ssePayloadsData(from data: Data) -> [Data] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var decoder = SSEDecoder()
        var payloads: [Data] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : Substring(rawLine)
            if let payload = decoder.feed(line: String(line)) {
                payloads.append(payload)
            }
        }
        if let tail = decoder.flushIfNeeded() {
            payloads.append(tail)
        }
        return payloads
    }

    private static func eventStreamReconnectDelay(attempt: Int) -> Duration {
        switch attempt {
        case ..<2:
            return .milliseconds(100)
        case 2..<5:
            return .seconds(1)
        default:
            return .seconds(5)
        }
    }

    private static func isTerminalEventStreamStatus(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 404, 405, 406, 410, 501:
            return true
        default:
            return false
        }
    }

    private static func urlTimeoutInterval(for duration: Duration?) -> TimeInterval {
        guard let duration else {
            return .infinity
        }
        let components = duration.components
        let seconds = Double(max(0, components.seconds))
        let fractional = Double(max(0, components.attoseconds)) / 1_000_000_000_000_000_000
        return seconds + fractional
    }

    private static func jsonObject(from data: Data) -> [String: JSONValue]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let value = JSONValue(any: raw)
        else {
            return nil
        }
        guard case .object(let object) = value else {
            return nil
        }
        return object
    }

    private static func initializeProtocolVersion(from object: [String: JSONValue]) -> String? {
        guard case .object(let result)? = object["result"],
              case .string(let protocolVersion)? = result["protocolVersion"],
              protocolVersion.isEmpty == false
        else {
            return nil
        }
        return protocolVersion
    }

    private static func jsonRPCIDKey(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let value):
            return value
        case .number(let value):
            return value.stringValue
        case .object, .array, .bool, .null, .none:
            return nil
        }
    }
}

private actor StreamableHTTPMCPClientState {
    private var closed = false
    private var sessionID: String?
    private var protocolVersion: String?
    private var eventStreamTask: Task<Void, Never>?
    private var eventStreamStartReserved = false

    var isOpen: Bool {
        closed == false
    }

    func ensureOpen() throws {
        if closed {
            throw MCPBridgeRuntimeError.closed
        }
    }

    func sessionHeaders() -> (sessionID: String?, protocolVersion: String?) {
        (sessionID, protocolVersion)
    }

    func setSessionID(_ sessionID: String) {
        self.sessionID = sessionID
    }

    func completeInitialize(protocolVersion: String) {
        self.protocolVersion = protocolVersion
    }

    func eventStreamSessionIfStartable() -> EventStreamSession? {
        guard closed == false,
              eventStreamTask == nil,
              eventStreamStartReserved == false,
              let sessionID,
              let protocolVersion
        else {
            return nil
        }
        eventStreamStartReserved = true
        return EventStreamSession(sessionID: sessionID, protocolVersion: protocolVersion)
    }

    func setEventStreamTask(_ task: Task<Void, Never>) {
        if closed {
            eventStreamStartReserved = false
            task.cancel()
            return
        }
        guard eventStreamStartReserved, eventStreamTask == nil else {
            task.cancel()
            return
        }
        eventStreamStartReserved = false
        eventStreamTask = task
    }

    func close() -> CloseState {
        guard closed == false else {
            return CloseState(
                sessionID: nil,
                protocolVersion: nil,
                eventStreamTask: nil
            )
        }
        closed = true
        eventStreamStartReserved = false
        let closeState = CloseState(
            sessionID: sessionID,
            protocolVersion: protocolVersion,
            eventStreamTask: eventStreamTask
        )
        eventStreamTask = nil
        return closeState
    }

    struct EventStreamSession: Sendable {
        var sessionID: String
        var protocolVersion: String
    }

    struct CloseState: Sendable {
        var sessionID: String?
        var protocolVersion: String?
        var eventStreamTask: Task<Void, Never>?
    }
}

private struct StreamableHTTPMCPRequestInfo: Sendable {
    var id: JSONValue?
    var method: String?

    init(data: Data) throws {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let value = JSONValue(any: raw) else {
            throw MCPBridgeRuntimeError.invalidRequest("JSON-RPC message is not valid JSON")
        }
        guard case .object(let object) = value else {
            self.id = nil
            self.method = nil
            return
        }
        self.id = object["id"]
        if case .string(let method)? = object["method"] {
            self.method = method
        } else {
            self.method = nil
        }
    }
}
