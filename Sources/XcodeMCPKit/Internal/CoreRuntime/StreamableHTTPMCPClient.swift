import Foundation
import Synchronization

package struct StreamableHTTPMCPClientSendResult: Sendable {
    package let messageCount: Int
}

package enum StreamableHTTPMCPClientMessageDisposition: Sendable {
    case `continue`
    case stop
}

package enum StreamableHTTPMCPClientError: Error, Sendable {
    case httpStatus(Int, body: String, payloads: [Data])
    case sessionExpired(sessionID: String)
}

package enum StreamableHTTPURLSessionOwnership: Equatable, Sendable {
    case owned
    case injected
}

/// One connection-level Streamable HTTP client.
///
/// Session identity and negotiated protocol version are explicit inputs owned
/// by `MCPClientSessionAuthority`; this type owns only URLSession work and SSE
/// framing for one transport connection.
package final class StreamableHTTPMCPClient: Sendable {
    package nonisolated let events: AsyncStream<Data>
    package nonisolated let sessionExpirations: AsyncStream<String>

    private static let sessionHeader = "MCP-Session-Id"
    private static let protocolVersionHeader = "MCP-Protocol-Version"
    private static let postAcceptHeader = "application/json, text/event-stream"
    private static let eventStreamContentType = "text/event-stream"

    private let endpoint: URL
    private let urlSession: URLSession
    private let urlSessionOwnership: StreamableHTTPURLSessionOwnership
    private let eventStreamReconnectSleep: @Sendable (Duration) async throws -> Void
    private let eventContinuation: AsyncStream<Data>.Continuation
    private let expirationContinuation: AsyncStream<String>.Continuation
    private let state = StreamableHTTPMCPConnectionState()
    private let eventStreamCancellation = StreamableHTTPTaskCancellationBackstop()
    private let closeAuthority = StreamableHTTPCloseAuthority()
    private let urlSessionInvalidationAuthority: StreamableHTTPURLSessionInvalidationAuthority

    package init(
        endpoint: URL,
        urlSession: URLSession,
        urlSessionOwnership: StreamableHTTPURLSessionOwnership,
        eventStreamReconnectSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        let eventPair = AsyncStream.makeStream(of: Data.self)
        let expirationPair = AsyncStream.makeStream(of: String.self)
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.urlSessionOwnership = urlSessionOwnership
        self.urlSessionInvalidationAuthority = StreamableHTTPURLSessionInvalidationAuthority(
            ownership: urlSessionOwnership
        )
        self.eventStreamReconnectSleep = eventStreamReconnectSleep
        self.events = eventPair.stream
        self.eventContinuation = eventPair.continuation
        self.sessionExpirations = expirationPair.stream
        self.expirationContinuation = expirationPair.continuation
    }

    deinit {
        eventStreamCancellation.cancel()
        urlSessionInvalidationAuthority.invalidate(urlSession)
        eventContinuation.finish()
        expirationContinuation.finish()
    }

    package static func validateEndpoint(_ endpoint: URL) throws {
        guard let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw MCPBridgeRuntimeError.invalidRequest(
                "Streamable HTTP endpoint must use http or https: \(endpoint.absoluteString)"
            )
        }
    }

    package func send(
        _ data: Data,
        headers: MCPConnectionHeaders,
        timeout: Duration?,
        onMessage: @Sendable (
            _ data: Data,
            _ responseHeaders: MCPConnectionHeaders
        ) async throws -> StreamableHTTPMCPClientMessageDisposition
    ) async throws -> StreamableHTTPMCPClientSendResult {
        try await state.ensureOpen()
        let request = Self.makePostRequest(
            endpoint: endpoint,
            body: data,
            headers: headers,
            timeout: timeout
        )
        let (responseBytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPBridgeRuntimeError.transportUnavailable("Streamable HTTP response was not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 404, let sessionID = headers.sessionID {
                throw StreamableHTTPMCPClientError.sessionExpired(sessionID: sessionID)
            }
            throw await httpStatusError(httpResponse, body: responseBytes)
        }

        let responseHeaders = MCPConnectionHeaders(
            sessionID: httpResponse.value(forHTTPHeaderField: Self.sessionHeader),
            protocolVersion: httpResponse.value(forHTTPHeaderField: Self.protocolVersionHeader)
        )
        if Self.isEventStream(httpResponse) {
            let count = try await emitResponseEventStreamMessages(
                responseBytes,
                responseHeaders: responseHeaders,
                onMessage: onMessage
            )
            return StreamableHTTPMCPClientSendResult(messageCount: count)
        }

        let responseData = try await Self.collect(responseBytes)
        guard responseData.isEmpty == false else {
            return StreamableHTTPMCPClientSendResult(messageCount: 0)
        }
        _ = try await onMessage(responseData, responseHeaders)
        return StreamableHTTPMCPClientSendResult(messageCount: 1)
    }

    package func startEventStream(headers: MCPConnectionHeaders) async {
        guard let sessionID = headers.sessionID,
              let protocolVersion = headers.protocolVersion,
              await state.reserveEventStreamStart() else { return }

        let reconnectSleep = eventStreamReconnectSleep
        let eventContinuation = eventContinuation
        let expirationContinuation = expirationContinuation
        let task = Task { [endpoint, urlSession] in
            var attempt = 0
            while Task.isCancelled == false {
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
                        throw MCPBridgeRuntimeError.transportUnavailable(
                            "Streamable HTTP event stream response was not HTTP"
                        )
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        if httpResponse.statusCode == 404 {
                            expirationContinuation.yield(sessionID)
                            return
                        }
                        if Self.isTerminalEventStreamStatus(httpResponse.statusCode) { return }
                        _ = try? await Self.collect(bytes)
                        throw MCPBridgeRuntimeError.transportUnavailable(
                            "Streamable HTTP event stream failed with status \(httpResponse.statusCode)"
                        )
                    }
                    guard Self.isEventStream(httpResponse) else { return }
                    try await Self.consumeEventStream(bytes, continuation: eventContinuation)
                    attempt += 1
                } catch is CancellationError {
                    return
                } catch {
                    attempt += 1
                }
            }
        }
        eventStreamCancellation.install(task)
        await state.installEventStreamTask(task)
    }

    package func close(
        headers: MCPConnectionHeaders,
        deleteTimeout: Duration?,
        deleteSessionGrace: Duration? = nil,
        clock: ClockClient = .liveValue
    ) async {
        let endpoint = endpoint
        let urlSession = urlSession
        let urlSessionOwnership = urlSessionOwnership
        let state = state
        let eventStreamCancellation = eventStreamCancellation
        let eventContinuation = eventContinuation
        let expirationContinuation = expirationContinuation
        let urlSessionInvalidationAuthority = urlSessionInvalidationAuthority
        let task = closeAuthority.task {
            Task.detached {
                await Self.performClose(
                    endpoint: endpoint,
                    urlSession: urlSession,
                    urlSessionOwnership: urlSessionOwnership,
                    state: state,
                    eventStreamCancellation: eventStreamCancellation,
                    eventContinuation: eventContinuation,
                    expirationContinuation: expirationContinuation,
                    urlSessionInvalidationAuthority: urlSessionInvalidationAuthority,
                    headers: headers,
                    deleteTimeout: deleteTimeout,
                    deleteSessionGrace: deleteSessionGrace,
                    clock: clock
                )
            }
        }
        await task.value
    }
}

private extension StreamableHTTPMCPClient {
    static func performClose(
        endpoint: URL,
        urlSession: URLSession,
        urlSessionOwnership: StreamableHTTPURLSessionOwnership,
        state: StreamableHTTPMCPConnectionState,
        eventStreamCancellation: StreamableHTTPTaskCancellationBackstop,
        eventContinuation: AsyncStream<Data>.Continuation,
        expirationContinuation: AsyncStream<String>.Continuation,
        urlSessionInvalidationAuthority: StreamableHTTPURLSessionInvalidationAuthority,
        headers: MCPConnectionHeaders,
        deleteTimeout: Duration?,
        deleteSessionGrace: Duration?,
        clock: ClockClient
    ) async {
        let eventTask = await state.close() ?? eventStreamCancellation.task
        eventStreamCancellation.cancel()
        let deleteTask: Task<Void, Never>?
        if let sessionID = headers.sessionID {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "DELETE"
            request.timeoutInterval = Self.urlTimeoutInterval(for: deleteTimeout)
            request.setValue(sessionID, forHTTPHeaderField: Self.sessionHeader)
            if let protocolVersion = headers.protocolVersion {
                request.setValue(protocolVersion, forHTTPHeaderField: Self.protocolVersionHeader)
            }
            deleteTask = await performDelete(
                request,
                urlSession: urlSession,
                urlSessionOwnership: urlSessionOwnership,
                grace: deleteSessionGrace,
                clock: clock
            )
        } else {
            deleteTask = nil
        }
        urlSessionInvalidationAuthority.invalidate(urlSession)
        await eventTask?.value
        await deleteTask?.value
        eventStreamCancellation.clear()
        eventContinuation.finish()
        expirationContinuation.finish()
    }

    static func makePostRequest(
        endpoint: URL,
        body: Data,
        headers: MCPConnectionHeaders,
        timeout: Duration?
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = urlTimeoutInterval(for: timeout)
        request.httpBody = body
        request.setValue(postAcceptHeader, forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let protocolVersion = headers.protocolVersion {
            request.setValue(protocolVersion, forHTTPHeaderField: protocolVersionHeader)
        }
        if let sessionID = headers.sessionID {
            request.setValue(sessionID, forHTTPHeaderField: sessionHeader)
        }
        return request
    }

    func httpStatusError(
        _ response: HTTPURLResponse,
        body responseBytes: URLSession.AsyncBytes
    ) async -> StreamableHTTPMCPClientError {
        let responseData = (try? await Self.collect(responseBytes)) ?? Data()
        let body = String(data: responseData, encoding: .utf8) ?? ""
        return .httpStatus(
            response.statusCode,
            body: body,
            payloads: Self.responsePayloadsData(responseData, from: response)
        )
    }

    func emitResponseEventStreamMessages(
        _ bytes: URLSession.AsyncBytes,
        responseHeaders: MCPConnectionHeaders,
        onMessage: @Sendable (Data, MCPConnectionHeaders) async throws
            -> StreamableHTTPMCPClientMessageDisposition
    ) async throws -> Int {
        var decoder = SSEDecoder()
        var lineBuffer = Data()
        var count = 0
        for try await byte in bytes {
            guard byte == 0x0A else {
                lineBuffer.append(byte)
                continue
            }
            let line = String(data: lineBuffer, encoding: .utf8) ?? ""
            lineBuffer.removeAll(keepingCapacity: true)
            if let payload = decoder.feed(line: line) {
                count += 1
                if try await onMessage(payload, responseHeaders) == .stop { return count }
            }
        }
        if lineBuffer.isEmpty == false,
           let payload = decoder.feed(line: String(data: lineBuffer, encoding: .utf8) ?? "") {
            count += 1
            if try await onMessage(payload, responseHeaders) == .stop { return count }
        }
        if let payload = decoder.flushIfNeeded() {
            count += 1
            _ = try await onMessage(payload, responseHeaders)
        }
        return count
    }

    static func performDelete(
        _ request: URLRequest,
        urlSession: URLSession,
        urlSessionOwnership: StreamableHTTPURLSessionOwnership,
        grace: Duration?,
        clock: ClockClient
    ) async -> Task<Void, Never> {
        let race = AsyncStream.makeStream(
            of: StreamableHTTPDeleteWinner.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let completion = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let dataTask = urlSession.dataTask(with: request) { _, _, _ in
            race.continuation.yield(.request)
            completion.continuation.yield(())
            completion.continuation.finish()
        }
        let task = Task {
            var iterator = completion.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        dataTask.resume()
        guard let grace else {
            await task.value
            race.continuation.finish()
            return task
        }
        precondition(urlSessionOwnership == .owned)
        let graceTask = Task {
            await clock.sleep(grace)
            guard Task.isCancelled == false else { return }
            race.continuation.yield(.grace)
        }
        var iterator = race.stream.makeAsyncIterator()
        let winner = await iterator.next() ?? .grace
        race.continuation.finish()
        if case .grace = winner {
            dataTask.cancel()
        }
        graceTask.cancel()
        await graceTask.value
        return task
    }

    static func makeEventStreamRequest(
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

    static func consumeEventStream(
        _ bytes: URLSession.AsyncBytes,
        continuation: AsyncStream<Data>.Continuation
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
            if let data = decoder.feed(line: line) { continuation.yield(data) }
        }
        if lineBuffer.isEmpty == false,
           let data = decoder.feed(line: String(data: lineBuffer, encoding: .utf8) ?? "") {
            continuation.yield(data)
        }
        if let data = decoder.flushIfNeeded() { continuation.yield(data) }
    }

    static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    static func isEventStream(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains(eventStreamContentType) == true
    }

    static func responsePayloadsData(_ data: Data, from response: HTTPURLResponse) -> [Data] {
        guard data.isEmpty == false else { return [] }
        guard isEventStream(response) else { return [data] }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var decoder = SSEDecoder()
        var payloads: [Data] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : Substring(rawLine)
            if let payload = decoder.feed(line: String(line)) { payloads.append(payload) }
        }
        if let payload = decoder.flushIfNeeded() { payloads.append(payload) }
        return payloads
    }

    static func eventStreamReconnectDelay(attempt: Int) -> Duration {
        switch attempt {
        case ..<2: .milliseconds(100)
        case 2..<5: .seconds(1)
        default: .seconds(5)
        }
    }

    static func isTerminalEventStreamStatus(_ status: Int) -> Bool {
        [405, 406, 410, 501].contains(status)
    }

    static func urlTimeoutInterval(for duration: Duration?) -> TimeInterval {
        guard let duration else { return .infinity }
        let components = duration.components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
        return Double(max(0, components.seconds))
            + Double(max(0, components.attoseconds)) / 1_000_000_000_000_000_000
    }
}

package actor StreamableHTTPMCPConnectionState {
    private var closed = false
    private var eventStreamTask: Task<Void, Never>?
    private var eventStreamStartReserved = false
    private var closeWaiters: [CheckedContinuation<Task<Void, Never>?, Never>] = []

    package func ensureOpen() throws {
        if closed { throw MCPBridgeRuntimeError.closed }
    }

    package func reserveEventStreamStart() -> Bool {
        guard closed == false, eventStreamTask == nil, eventStreamStartReserved == false else {
            return false
        }
        eventStreamStartReserved = true
        return true
    }

    package func installEventStreamTask(_ task: Task<Void, Never>) {
        guard closed == false, eventStreamStartReserved, eventStreamTask == nil else {
            task.cancel()
            eventStreamStartReserved = false
            let waiters = closeWaiters
            closeWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: task) }
            return
        }
        eventStreamStartReserved = false
        eventStreamTask = task
    }

    package func close() async -> Task<Void, Never>? {
        if closed == false {
            closed = true
        }
        if eventStreamStartReserved {
            return await withCheckedContinuation { closeWaiters.append($0) }
        }
        eventStreamStartReserved = false
        let task = eventStreamTask
        eventStreamTask = nil
        return task
    }

    isolated deinit {
        eventStreamTask?.cancel()
        for waiter in closeWaiters { waiter.resume(returning: eventStreamTask) }
    }
}

private final class StreamableHTTPCloseAuthority: Sendable {
    private let taskState = Mutex<Task<Void, Never>?>(nil)

    func task(create: () -> Task<Void, Never>) -> Task<Void, Never> {
        taskState.withLock { task in
            if let task { return task }
            let created = create()
            task = created
            return created
        }
    }
}

private final class StreamableHTTPURLSessionInvalidationAuthority: Sendable {
    private let isOwned: Bool
    private let isInvalidated = Mutex(false)

    init(ownership: StreamableHTTPURLSessionOwnership) {
        self.isOwned = ownership == .owned
    }

    func invalidate(_ urlSession: URLSession) {
        guard isOwned else { return }
        let shouldInvalidate = isInvalidated.withLock { isInvalidated in
            guard isInvalidated == false else { return false }
            isInvalidated = true
            return true
        }
        if shouldInvalidate {
            urlSession.invalidateAndCancel()
        }
    }
}

private final class StreamableHTTPTaskCancellationBackstop: Sendable {
    private struct State {
        var isCancelled = false
        var task: Task<Void, Never>?
    }

    private let state = Mutex(State())

    var task: Task<Void, Never>? {
        state.withLock(\.task)
    }

    func install(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLock { state in
            guard state.isCancelled == false else { return true }
            precondition(state.task == nil)
            state.task = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state in
            state.isCancelled = true
            return state.task
        }
        task?.cancel()
    }

    func clear() {
        state.withLock { $0.task = nil }
    }

    deinit {
        cancel()
    }
}

private enum StreamableHTTPDeleteWinner: Sendable {
    case request
    case grace
}
