import Foundation
import NIO
import NIOHTTP1
import XcodeMCPKit
@testable import XcodeMCPProxyKit
import Testing
import XcodeMCPProxyTestSupport


@Suite(.serialized, .enabled(if: StressTestEnvironment.isEnabled))
struct DocumentationSearchStressTests {
    @Test func documentationSearchHandlesFourSessionsWithOneThousandParallelRequestsEach() async throws {
        let sessionCount = 4
        let requestsPerSession = 1_000
        let upstream = DocumentationSearchStressUpstreamClient(sessionCount: sessionCount)
        let server = try StressHTTPServer.start(upstream: upstream)
        let urlSession = makeStressURLSession()
        defer {
            urlSession.invalidateAndCancel()
        }

        do {
            let sessionIDs = try await initializeSessions(
                url: server.url,
                count: sessionCount,
                urlSession: urlSession
            )
            #expect(Set(sessionIDs).count == sessionCount)

            try await runDocumentationSearchRequests(
                url: server.url,
                sessionIDs: sessionIDs,
                requestsPerSession: requestsPerSession,
                urlSession: urlSession
            )

            let counts = await upstream.documentationSearchCountsBySessionIndex()
            #expect(counts == Array(repeating: requestsPerSession, count: sessionCount))
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }
}

private enum StressTestError: Error {
    case invalidResponse
    case missingSessionID
}

private struct DocumentationSearchStressRequest: Sendable {
    let sessionIndex: Int
    let requestIndex: Int
}

private func initializeSessions(
    url: URL,
    count: Int,
    urlSession: URLSession
) async throws -> [String] {
    try await withThrowingTaskGroup(of: (Int, String).self) { group in
        for index in 0..<count {
            group.addTask {
                let (response, body) = try await postJSON(
                    url: url,
                    sessionID: nil,
                    payload: initializePayload(id: index + 1),
                    urlSession: urlSession
                )
                guard let sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id") else {
                    throw StressTestError.missingSessionID
                }
                #expect((body["id"] as? NSNumber)?.intValue == index + 1)
                return (index, sessionID)
            }
        }

        var sessionIDs = Array(repeating: "", count: count)
        for try await (index, sessionID) in group {
            sessionIDs[index] = sessionID
        }
        return sessionIDs
    }
}

private func runDocumentationSearchRequests(
    url: URL,
    sessionIDs: [String],
    requestsPerSession: Int,
    urlSession: URLSession
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        for (sessionIndex, sessionID) in sessionIDs.enumerated() {
            for requestIndex in 0..<requestsPerSession {
                group.addTask {
                    let requestID = documentationSearchRequestID(
                        sessionIndex: sessionIndex,
                        requestIndex: requestIndex
                    )
                    let (response, body) = try await postJSON(
                        url: url,
                        sessionID: sessionID,
                        payload: documentationSearchPayload(
                            id: requestID,
                            sessionIndex: sessionIndex,
                            requestIndex: requestIndex
                        ),
                        urlSession: urlSession
                    )
                    #expect(response.statusCode == 200)
                    #expect((body["id"] as? NSNumber)?.intValue == requestID)
                    let result = body["result"] as? [String: Any]
                    let structuredContent = result?["structuredContent"] as? [String: Any]
                    #expect((structuredContent?["sessionIndex"] as? NSNumber)?.intValue == sessionIndex)
                    #expect((structuredContent?["requestIndex"] as? NSNumber)?.intValue == requestIndex)
                    #expect(structuredContent?["answer"] as? String == "ok")
                }
            }
        }
        try await group.waitForAll()
    }
}

private func documentationSearchRequestID(sessionIndex: Int, requestIndex: Int) -> Int {
    (sessionIndex + 1) * 1_000_000 + requestIndex
}

private func makeStressURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpMaximumConnectionsPerHost = 128
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 120
    return URLSession(configuration: configuration)
}

private struct StressHTTPServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let url: URL
    let sessionManager: RuntimeCoordinator
    let childChannelTracker: HTTPTestServerChannelTracker

    static func start(upstream: any UpstreamSlotControlling) throws -> StressHTTPServer {
        ProxyLogging.bootstrap(environment: ["MCP_LOG_LEVEL": "critical"])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        let childChannelTracker = HTTPTestServerChannelTracker()
        let config: ProxyConfig = {
            var config = ProxyConfig(
                listenHost: "127.0.0.1",
                listenPort: 0,
                upstreamCommand: MCPBridgeInvocation.defaultMCPBridge.command,
                upstreamArgs: MCPBridgeInvocation.defaultMCPBridge.arguments,
                upstreamSessionID: nil,
                maxBodyBytes: 1_048_576,
                requestTimeout: 60
            )
            config.prewarmToolsList = false
            return config
        }()
        let sessionManager = RuntimeCoordinator(
            config: config,
            eventLoop: group.next(),
            upstreams: [upstream]
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 1024)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            config: config,
                            sessionManager: sessionManager
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: config.listenHost, port: config.listenPort).wait()
        try channel.pipeline.addHandler(
            HTTPTestServerAcceptedChannelHandler(tracker: childChannelTracker)
        ).wait()
        let port = channel.localAddress?.port ?? config.listenPort
        let url = URL(string: "http://\(config.listenHost):\(port)/mcp")!
        return StressHTTPServer(
            group: group,
            channel: channel,
            url: url,
            sessionManager: sessionManager,
            childChannelTracker: childChannelTracker
        )
    }

    func shutdown() async throws {
        try await shutdownHTTPTestServer(
            listenChannel: channel,
            childChannelTracker: childChannelTracker,
            group: group,
            beforeClose: {
                await sessionManager.shutdown()
            }
        )
    }
}

private actor DocumentationSearchStressUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private var countsBySessionIndex: [Int]

    init(sessionCount: Int) {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
        self.countsBySessionIndex = Array(repeating: 0, count: sessionCount)
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .accepted
        }

        if let object = json as? [String: Any] {
            handle(object)
        } else if let array = json as? [Any] {
            for item in array {
                guard let object = item as? [String: Any] else { continue }
                handle(object)
            }
        }
        return .accepted
    }

    func documentationSearchCountsBySessionIndex() -> [Int] {
        countsBySessionIndex
    }

    private func handle(_ object: [String: Any]) {
        guard let id = object["id"] else { return }
        let method = object["method"] as? String
        if method == "initialize" {
            continuation.yield(.message(makeInitializeResponse(id: id)))
            return
        }

        guard method == "tools/call",
              let params = object["params"] as? [String: Any],
              params["name"] as? String == "DocumentationSearch",
              let metadata = documentationSearchMetadata(from: params)
        else {
            continuation.yield(.message(makeSuccessResponse(id: id, metadata: nil)))
            return
        }

        if countsBySessionIndex.indices.contains(metadata.sessionIndex) {
            countsBySessionIndex[metadata.sessionIndex] += 1
        }
        continuation.yield(.message(makeSuccessResponse(id: id, metadata: metadata)))
    }

    private func documentationSearchMetadata(from params: [String: Any]) -> DocumentationSearchStressRequest? {
        guard let arguments = params["arguments"] as? [String: Any],
              let sessionIndex = (arguments["sessionIndex"] as? NSNumber)?.intValue,
              let requestIndex = (arguments["requestIndex"] as? NSNumber)?.intValue
        else {
            return nil
        }
        return DocumentationSearchStressRequest(
            sessionIndex: sessionIndex,
            requestIndex: requestIndex
        )
    }

    private func makeInitializeResponse(id: Any) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [String: Any]()],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func makeSuccessResponse(id: Any, metadata: DocumentationSearchStressRequest?) -> Data {
        let structuredText: String
        if let metadata {
            structuredText =
                #"{"sessionIndex":\#(metadata.sessionIndex),"requestIndex":\#(metadata.requestIndex),"answer":"ok"}"#
        } else {
            structuredText = #"{"answer":"ok"}"#
        }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": structuredText,
                    ]
                ]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }
}

private func initializePayload(id: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-06-18",
            "clientInfo": [
                "name": "XcodeMCPKitStressTest",
                "version": "dev",
            ],
            "capabilities": [String: Any](),
        ],
    ]
}

private func documentationSearchPayload(
    id: Int,
    sessionIndex: Int,
    requestIndex: Int
) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": [
            "name": "DocumentationSearch",
            "arguments": [
                "query": "Swift concurrency stress session \(sessionIndex) request \(requestIndex)",
                "sessionIndex": sessionIndex,
                "requestIndex": requestIndex,
            ],
        ],
    ]
}

private func postJSON(
    url: URL,
    sessionID: String?,
    payload: [String: Any],
    urlSession: URLSession
) async throws -> (HTTPURLResponse, [String: Any]) {
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let sessionID {
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue(MCP.ProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
          let body = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    else {
        throw StressTestError.invalidResponse
    }
    return (httpResponse, body)
}
