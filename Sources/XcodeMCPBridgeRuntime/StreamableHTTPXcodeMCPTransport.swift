import Foundation
import ProxyCore
import ProxyMCP

package final class StreamableHTTPXcodeMCPTransport: XcodeMCPTransport, @unchecked Sendable {
    package nonisolated let events: AsyncStream<XcodeMCPTransportEvent>

    private static let sessionHeader = "MCP-Session-Id"
    private static let protocolVersionHeader = "MCP-Protocol-Version"
    private static let postAcceptHeader = "application/json, text/event-stream"
    private static let eventStreamContentType = "text/event-stream"

    private let endpoint: URL
    private let urlSession: URLSession
    private let requestTimeout: Duration?
    private let eventStreamReconnectSleep: @Sendable (Duration) async throws -> Void
    private let streamContinuation: AsyncStream<XcodeMCPTransportEvent>.Continuation
    private let state = StreamableHTTPTransportState()

    package static func start(
        endpoint: URL,
        requestTimeout: Duration?
    ) async throws -> StreamableHTTPXcodeMCPTransport {
        try validateEndpoint(endpoint)
        return StreamableHTTPXcodeMCPTransport(
            endpoint: endpoint,
            urlSession: .shared,
            requestTimeout: requestTimeout
        )
    }

    package static func start(
        discoveryFile: URL,
        requestTimeout: Duration?
    ) async throws -> StreamableHTTPXcodeMCPTransport {
        guard let record = Discovery.read(overrideURL: discoveryFile),
              let endpoint = URL(string: record.url)
        else {
            throw MCPBridgeRuntimeError.invalidRequest(
                "Streamable HTTP discovery file is missing, stale, or invalid: \(discoveryFile.path)"
            )
        }
        return try await start(endpoint: endpoint, requestTimeout: requestTimeout)
    }

    package init(
        endpoint: URL,
        urlSession: URLSession,
        requestTimeout: Duration? = nil,
        eventStreamReconnectSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        let stream = AsyncStream<XcodeMCPTransportEvent>.makeStream()
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.requestTimeout = requestTimeout
        self.eventStreamReconnectSleep = eventStreamReconnectSleep
        self.events = stream.stream
        self.streamContinuation = stream.continuation
    }

    package func send(_ data: Data) async throws {
        try await state.ensureOpen()
        let requestInfo = try OutgoingHTTPRequestInfo(data: data)
        let request = await makePostRequest(body: data)
        let (responseBytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPBridgeRuntimeError.transportUnavailable("Streamable HTTP response was not HTTP")
        }

        try await validateSuccess(httpResponse, body: responseBytes)
        await recordSessionHeader(from: httpResponse, requestInfo: requestInfo)

        if Self.isEventStream(httpResponse) {
            try await consumeEventStream(responseBytes, requestInfo: requestInfo)
        } else {
            let responseData = try await Self.collect(responseBytes)
            guard responseData.isEmpty == false else {
                return
            }
            try await recordInitializeResponseIfNeeded(responseData, requestInfo: requestInfo)
            streamContinuation.yield(.message(responseData))
        }
    }

    package func close() async {
        let closeState = await state.close()
        closeState.eventStreamTask?.cancel()

        guard let sessionID = closeState.sessionID else {
            streamContinuation.yield(.closed(nil))
            streamContinuation.finish()
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5
        request.setValue(sessionID, forHTTPHeaderField: Self.sessionHeader)
        if let protocolVersion = closeState.protocolVersion {
            request.setValue(protocolVersion, forHTTPHeaderField: Self.protocolVersionHeader)
        }
        _ = try? await urlSession.data(for: request)

        streamContinuation.yield(.closed(nil))
        streamContinuation.finish()
    }

    private static func validateEndpoint(_ endpoint: URL) throws {
        guard let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw MCPBridgeRuntimeError.invalidRequest(
                "Streamable HTTP endpoint must use http or https: \(endpoint.absoluteString)"
            )
        }
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

    private func validateSuccess(
        _ response: HTTPURLResponse,
        body responseBytes: URLSession.AsyncBytes
    ) async throws {
        guard (200..<300).contains(response.statusCode) else {
            let responseData = (try? await Self.collect(responseBytes)) ?? Data()
            let body = String(data: responseData, encoding: .utf8) ?? ""
            let suffix = body.isEmpty ? "" : ": \(body)"
            throw MCPBridgeRuntimeError.transportUnavailable(
                "Streamable HTTP request failed with status \(response.statusCode)\(suffix)"
            )
        }
    }

    private func recordSessionHeader(
        from response: HTTPURLResponse,
        requestInfo: OutgoingHTTPRequestInfo
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
        requestInfo: OutgoingHTTPRequestInfo
    ) async throws {
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
            throw MCPBridgeRuntimeError.invalidResponse(
                "initialize response is missing protocolVersion"
            )
        }
        let sessionID = await state.completeInitialize(protocolVersion: protocolVersion)
        if let sessionID {
            await startEventStream(sessionID: sessionID, protocolVersion: protocolVersion)
        }
    }

    private func startEventStream(sessionID: String, protocolVersion: String) async {
        let reconnectSleep = eventStreamReconnectSleep
        let task = Task { [endpoint, urlSession, streamContinuation, state, reconnectSleep] in
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
                        sessionID: sessionID,
                        protocolVersion: protocolVersion
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
                        streamContinuation: streamContinuation
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

    private func consumeEventStream(
        _ bytes: URLSession.AsyncBytes,
        requestInfo: OutgoingHTTPRequestInfo
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
            guard let data = decoder.feed(line: line) else {
                continue
            }
            try await recordInitializeResponseIfNeeded(data, requestInfo: requestInfo)
            streamContinuation.yield(.message(data))
        }
        if lineBuffer.isEmpty == false {
            let line = String(data: lineBuffer, encoding: .utf8) ?? ""
            if let data = decoder.feed(line: line) {
                try await recordInitializeResponseIfNeeded(data, requestInfo: requestInfo)
                streamContinuation.yield(.message(data))
            }
        }
        if let data = decoder.flushIfNeeded() {
            try await recordInitializeResponseIfNeeded(data, requestInfo: requestInfo)
            streamContinuation.yield(.message(data))
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
        streamContinuation: AsyncStream<XcodeMCPTransportEvent>.Continuation
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
                streamContinuation.yield(.message(data))
            }
        }
        if lineBuffer.isEmpty == false {
            let line = String(data: lineBuffer, encoding: .utf8) ?? ""
            if let data = decoder.feed(line: line) {
                streamContinuation.yield(.message(data))
            }
        }
        if let data = decoder.flushIfNeeded() {
            streamContinuation.yield(.message(data))
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

private actor StreamableHTTPTransportState {
    private var closed = false
    private var sessionID: String?
    private var protocolVersion: String?
    private var eventStreamTask: Task<Void, Never>?

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

    func completeInitialize(protocolVersion: String) -> String? {
        self.protocolVersion = protocolVersion
        return sessionID
    }

    func setEventStreamTask(_ task: Task<Void, Never>) {
        if closed {
            task.cancel()
            return
        }
        if eventStreamTask == nil {
            eventStreamTask = task
        } else {
            task.cancel()
        }
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
        let closeState = CloseState(
            sessionID: sessionID,
            protocolVersion: protocolVersion,
            eventStreamTask: eventStreamTask
        )
        eventStreamTask = nil
        return closeState
    }

    struct CloseState: Sendable {
        var sessionID: String?
        var protocolVersion: String?
        var eventStreamTask: Task<Void, Never>?
    }
}

private struct OutgoingHTTPRequestInfo: Sendable {
    var id: JSONValue?
    var method: String?

    init(data: Data) throws {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let value = JSONValue(any: raw),
              case .object(let object) = value
        else {
            throw MCPBridgeRuntimeError.invalidRequest("JSON-RPC message is not an object")
        }
        self.id = object["id"]
        if case .string(let method)? = object["method"] {
            self.method = method
        } else {
            self.method = nil
        }
    }
}
