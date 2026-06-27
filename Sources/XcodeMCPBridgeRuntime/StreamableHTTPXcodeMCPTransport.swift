import Foundation
import ProxyCore

package final class StreamableHTTPXcodeMCPTransport: XcodeMCPTransport, @unchecked Sendable {
    package nonisolated let events: AsyncStream<XcodeMCPTransportEvent>

    private let client: StreamableHTTPMCPClient
    private let streamContinuation: AsyncStream<XcodeMCPTransportEvent>.Continuation
    private let clientEventsTask: Task<Void, Never>

    package static func start(
        endpoint: URL,
        requestTimeout: Duration?
    ) async throws -> StreamableHTTPXcodeMCPTransport {
        try StreamableHTTPMCPClient.validateEndpoint(endpoint)
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
        let client = StreamableHTTPMCPClient(
            endpoint: endpoint,
            urlSession: urlSession,
            requestTimeout: requestTimeout,
            eventStreamReconnectSleep: eventStreamReconnectSleep
        )

        self.client = client
        self.events = stream.stream
        self.streamContinuation = stream.continuation
        self.clientEventsTask = Task {
            for await data in client.events {
                stream.continuation.yield(.message(data))
            }
        }
    }

    deinit {
        clientEventsTask.cancel()
    }

    package func send(_ data: Data) async throws {
        let messages = try await client.send(data)
        for message in messages {
            streamContinuation.yield(.message(message))
        }
        await client.startEventStreamIfReady()
    }

    package func close() async {
        await client.close(deleteTimeout: .seconds(5))
        clientEventsTask.cancel()
        streamContinuation.yield(.closed(nil))
        streamContinuation.finish()
    }
}
