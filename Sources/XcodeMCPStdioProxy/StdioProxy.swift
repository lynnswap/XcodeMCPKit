import Foundation
import Logging
import XcodeMCPProxy

public final class StdioProxy {
    private let config: StdioProxyConfig
    private let logger: Logger
    private let framer = StdioFramer()
    private let writer: StdioWriter
    private let httpClient: HTTPClient
    private let state = SessionState()
    private var sseClient: SSEClient?

    public init(config: StdioProxyConfig, logger: Logger = ProxyLogging.make("stdio")) {
        self.config = config
        self.logger = logger
        self.writer = StdioWriter(framing: config.framing)
        self.httpClient = HTTPClient(proxyURL: config.proxyURL, logger: logger)
    }

    public func run() async {
        let input = stdinStream()
        for await chunk in input {
            if chunk.isEmpty {
                continue
            }
            let messages = framer.append(chunk)
            for message in messages {
                await handleMessage(message)
            }
        }
        await shutdown()
    }

    private func handleMessage(_ message: Data) async {
        do {
            let sessionId = await state.sessionId
            let response = try await httpClient.send(message, sessionId: sessionId)
            if let sessionId = response.sessionId {
                let wasEmpty = await state.setSessionIfNeeded(sessionId)
                if wasEmpty {
                    startSSE(sessionId: sessionId)
                }
            }
            await writer.send(response.data)
        } catch {
            logger.error("HTTP proxy request failed", metadata: ["error": "\(error)"])
        }
    }

    private func startSSE(sessionId: String) {
        var request = URLRequest(url: config.proxyURL)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")

        let writer = writer
        let logger = logger
        let client = SSEClient(
            request: request,
            onData: { data in
                Task {
                    await writer.send(data)
                }
            },
            onError: { error in
                logger.warning("SSE stream ended", metadata: ["error": "\(error)"])
            }
        )
        sseClient = client
        client.start()
        logger.info("SSE connected", metadata: ["session": "\(sessionId)"])
    }

    private func shutdown() async {
        sseClient?.stop()
        sseClient = nil
    }

    private func stdinStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let handle = FileHandle.standardInput
            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                if data.isEmpty {
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }
}

actor SessionState {
    private(set) var sessionId: String?

    func setSessionIfNeeded(_ value: String) -> Bool {
        if sessionId == nil {
            sessionId = value
            return true
        }
        return false
    }
}

struct HTTPResponsePayload: Sendable {
    let data: Data
    let sessionId: String?
}

final class HTTPClient {
    private let proxyURL: URL
    private let session: URLSession
    private let logger: Logger

    init(proxyURL: URL, logger: Logger) {
        self.proxyURL = proxyURL
        self.logger = logger
        self.session = URLSession(configuration: .default)
    }

    func send(_ data: Data, sessionId: String?) async throws -> HTTPResponsePayload {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = data

        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode >= 400 {
            logger.error("HTTP proxy returned error", metadata: ["status": "\(http.statusCode)"])
        }
        let headerSession = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        return HTTPResponsePayload(data: body, sessionId: headerSession)
    }
}
