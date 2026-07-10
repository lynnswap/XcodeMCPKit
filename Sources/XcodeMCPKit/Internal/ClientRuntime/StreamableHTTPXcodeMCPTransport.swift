import Foundation

package struct StreamableHTTPDiscoveryResolver: Sendable {
    private let readRecord: @Sendable (_ discoveryFile: URL) -> DiscoveryRecord?

    package static let liveValue = Self()

    package init(
        readRecord: @escaping @Sendable (_ discoveryFile: URL) -> DiscoveryRecord? = {
            Discovery.read(overrideURL: $0)
        }
    ) {
        self.readRecord = readRecord
    }

    package func endpoint(from discoveryFile: URL) -> URL? {
        guard let record = readRecord(discoveryFile),
              let endpoint = URL(string: record.url)
        else {
            return nil
        }
        return endpoint
    }
}

package final class StreamableHTTPXcodeMCPTransport: XcodeMCPTransport {
    package nonisolated let events: AsyncStream<XcodeMCPTransportEvent>

    private let client: StreamableHTTPMCPClient
    private let streamContinuation: AsyncStream<XcodeMCPTransportEvent>.Continuation
    private let clientEventsTask: Task<Void, Never>
    private let clientExpirationTask: Task<Void, Never>
    private let requestTimeout: Duration?
    private let deleteSessionGrace: Duration?
    private let clock: ClockClient

    package static func start(
        endpoint: URL,
        requestTimeout: Duration?
    ) async throws -> StreamableHTTPXcodeMCPTransport {
        try StreamableHTTPMCPClient.validateEndpoint(endpoint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        return StreamableHTTPXcodeMCPTransport(
            endpoint: endpoint,
            urlSession: URLSession(configuration: configuration),
            urlSessionOwnership: .owned,
            requestTimeout: requestTimeout
        )
    }

    package static func start(
        discoveryFile: URL,
        requestTimeout: Duration?,
        discoveryResolver: StreamableHTTPDiscoveryResolver = .liveValue
    ) async throws -> StreamableHTTPXcodeMCPTransport {
        guard let endpoint = discoveryResolver.endpoint(from: discoveryFile) else {
            throw MCPBridgeRuntimeError.transportUnavailable(
                "Streamable HTTP discovery file is missing, stale, or invalid: \(discoveryFile.path)"
            )
        }
        return try await start(endpoint: endpoint, requestTimeout: requestTimeout)
    }

    package init(
        endpoint: URL,
        urlSession: URLSession,
        urlSessionOwnership: StreamableHTTPURLSessionOwnership,
        requestTimeout: Duration? = nil,
        deleteSessionGrace: Duration? = nil,
        clock: ClockClient = .liveValue,
        eventStreamReconnectSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            await ClockClient.liveValue.sleep(duration)
            try Task.checkCancellation()
        }
    ) {
        let stream = AsyncStream<XcodeMCPTransportEvent>.makeStream()
        let client = StreamableHTTPMCPClient(
            endpoint: endpoint,
            urlSession: urlSession,
            urlSessionOwnership: urlSessionOwnership,
            eventStreamReconnectSleep: eventStreamReconnectSleep
        )

        self.client = client
        self.events = stream.stream
        self.streamContinuation = stream.continuation
        self.requestTimeout = requestTimeout
        self.deleteSessionGrace = deleteSessionGrace
        self.clock = clock
        self.clientEventsTask = Task {
            for await data in client.events {
                stream.continuation.yield(.message(data))
            }
        }
        self.clientExpirationTask = Task {
            for await sessionID in client.sessionExpirations {
                stream.continuation.yield(.sessionExpired(sessionID: sessionID))
            }
        }
    }

    deinit {
        clientEventsTask.cancel()
        clientExpirationTask.cancel()
    }

    package func send(
        _ data: Data,
        headers: MCPConnectionHeaders,
        deadline: Deadline?
    ) async throws {
        let expectedResponseID = Self.requestID(in: data)
        do {
            _ = try await client.send(
                data,
                headers: headers,
                timeout: deadline?.remainingDuration()
            ) { [streamContinuation] message, responseHeaders in
                streamContinuation.yield(.messageWithHeaders(message, responseHeaders))
                guard let expectedResponseID,
                      Self.responseID(in: message) == expectedResponseID else {
                    return .continue
                }
                return .stop
            }
        } catch let error as StreamableHTTPMCPClientError {
            if case .httpStatus(_, _, let payloads) = error,
               let expectedResponseID,
               payloads.isEmpty == false,
               payloads.allSatisfy({ Self.responseID(in: $0) == expectedResponseID })
            {
                for payload in payloads {
                    streamContinuation.yield(.messageWithHeaders(payload, MCPConnectionHeaders()))
                }
                return
            }
            if case .sessionExpired(let sessionID) = error {
                throw MCPTransportFailure.sessionExpired(
                    sessionID: sessionID,
                    delivery: .rejectedBeforeProcessing
                )
            }
            throw Self.runtimeError(from: error)
        }
    }

    package func startEventStream(headers: MCPConnectionHeaders) async {
        await client.startEventStream(headers: headers)
    }

    package func close(headers: MCPConnectionHeaders) async {
        clientEventsTask.cancel()
        clientExpirationTask.cancel()
        await client.close(
            headers: headers,
            deleteTimeout: requestTimeout ?? .seconds(5),
            deleteSessionGrace: deleteSessionGrace,
            clock: clock
        )
        await clientEventsTask.value
        await clientExpirationTask.value
        streamContinuation.yield(.closed(nil))
        streamContinuation.finish()
    }

    private static func runtimeError(from error: StreamableHTTPMCPClientError) -> MCPBridgeRuntimeError {
        switch error {
        case .httpStatus(let statusCode, let body, _):
            return .httpStatus(code: statusCode, body: body)
        case .sessionExpired(let sessionID):
            return .transportUnavailable("Streamable HTTP session expired: \(sessionID)")
        }
    }

    private static func requestID(in data: Data) -> String? {
        guard let envelope = try? MCPClientEnvelope(data: data),
              case .request(let id, _) = envelope.kind else { return nil }
        return id.key
    }

    private static func responseID(in data: Data) -> String? {
        guard let envelope = try? MCPClientEnvelope(data: data),
              case .response(let id) = envelope.kind else { return nil }
        return id.key
    }
}
