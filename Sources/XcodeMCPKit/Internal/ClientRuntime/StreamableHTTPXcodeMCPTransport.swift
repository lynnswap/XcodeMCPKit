import XcodeMCPCore
import XcodeMCPProcessRuntime
import Foundation

package struct StreamableHTTPDiscoveryResolver: Sendable {
    private let readRecord: @Sendable (_ discoveryFile: URL) -> DiscoveryRecord?
    private let isProcessAlive: @Sendable (_ processID: Int) -> Bool

    package static let liveValue = Self(processControl: .liveValue)

    package init(
        processControl: ProcessControlClient,
        readRecord: @escaping @Sendable (_ discoveryFile: URL) -> DiscoveryRecord? = {
            Discovery.read(overrideURL: $0)
        }
    ) {
        self.readRecord = readRecord
        self.isProcessAlive = { processControl.isProcessAlive($0) }
    }

    package init(
        readRecord: @escaping @Sendable (_ discoveryFile: URL) -> DiscoveryRecord? = {
            Discovery.read(overrideURL: $0)
        },
        isProcessAlive: @escaping @Sendable (_ processID: Int) -> Bool
    ) {
        self.readRecord = readRecord
        self.isProcessAlive = isProcessAlive
    }

    package func endpoint(from discoveryFile: URL) -> URL? {
        guard let record = readRecord(discoveryFile),
              isProcessAlive(record.pid),
              let endpoint = URL(string: record.url)
        else {
            return nil
        }
        return endpoint
    }
}

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
        requestTimeout: Duration?,
        discoveryResolver: StreamableHTTPDiscoveryResolver = .liveValue
    ) async throws -> StreamableHTTPXcodeMCPTransport {
        guard let endpoint = discoveryResolver.endpoint(from: discoveryFile) else {
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
            await ClockClient.liveValue.sleep(duration)
            try Task.checkCancellation()
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
        do {
            _ = try await client.send(data) { [streamContinuation] message in
                streamContinuation.yield(.message(message))
                return .continue
            }
        } catch let error as StreamableHTTPMCPClientError {
            throw Self.runtimeError(from: error)
        }
        await client.startEventStreamIfReady()
    }

    package func close() async {
        await client.close(deleteTimeout: .seconds(5))
        clientEventsTask.cancel()
        streamContinuation.yield(.closed(nil))
        streamContinuation.finish()
    }

    private static func runtimeError(from error: StreamableHTTPMCPClientError) -> MCPBridgeRuntimeError {
        switch error {
        case .httpStatus(let statusCode, let body, _):
            let suffix = body.isEmpty ? "" : ": \(body)"
            return .transportUnavailable(
                "Streamable HTTP request failed with status \(statusCode)\(suffix)"
            )
        }
    }
}
