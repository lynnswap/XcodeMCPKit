import Foundation
import NIO
import NIOHTTP1
import Testing
import ProxyCore
import ProxyRuntime
@testable import ProxyHTTPTransport
import ProxyFeatureXcode

@Suite(.serialized)
struct HTTPConcurrencyTests {
    @Test func httpConcurrentInitializeRequests() async throws {
        let server = try TestHTTPServer.start()
        let url = server.url

        do {
            let count = 20
            let results = try await runConcurrentInitialize(url: url, count: count)

            #expect(Set(results.0).count == count)
            #expect(Set(results.1).count == count)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpConcurrentInitializeStress() async throws {
        let count = 10
        let server = try TestHTTPServer.start()
        let url = server.url

        do {
            let results = try await runConcurrentInitialize(url: url, count: count)

            #expect(Set(results.0).count == count)
            #expect(Set(results.1).count == count)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpConcurrentRequestsShareSession() async throws {
        let server = try TestHTTPServer.start()
        let url = server.url

        do {
            let (initializeResponse, initializeBody) = try await postJSON(
                url: url,
                sessionID: nil,
                payload: initializePayload(id: 1)
            )
            guard let sessionID = initializeResponse.value(forHTTPHeaderField: "Mcp-Session-Id")
            else {
                throw ConcurrencyTestError.missingSessionID
            }
            let initID = (initializeBody["id"] as? NSNumber)?.intValue ?? -1
            #expect(initID == 1)

            let count = 20
            let responseIDs = try await withThrowingTaskGroup(of: Int.self) { group in
                for index in 0..<count {
                    group.addTask {
                        let payload: [String: Any] = [
                            "jsonrpc": "2.0",
                            "id": index + 100,
                            "method": "tools/list",
                        ]
                        let (response, body) = try await postJSON(
                            url: url,
                            sessionID: sessionID,
                            payload: payload
                        )
                        guard response.statusCode == 200 else {
                            throw ConcurrencyTestError.invalidResponse
                        }
                        return (body["id"] as? NSNumber)?.intValue ?? -1
                    }
                }

                var ids: [Int] = []
                for try await responseID in group {
                    ids.append(responseID)
                }
                return ids
            }

            #expect(Set(responseIDs).count == count)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpConcurrentRefreshCodeIssuesRequestsDoNotSurfaceErrorFive() async throws {
        let server = try TestHTTPServer.start(upstream: RefreshSensitiveUpstreamClient())
        let url = server.url

        do {
            let (initializeResponse, _) = try await postJSON(
                url: url,
                sessionID: nil,
                payload: initializePayload(id: 1)
            )
            guard let sessionID = initializeResponse.value(forHTTPHeaderField: "Mcp-Session-Id")
            else {
                throw ConcurrencyTestError.missingSessionID
            }

            let responses = try await withThrowingTaskGroup(
                of: (Int, Bool).self
            ) { group in
                for index in 0..<3 {
                    group.addTask {
                        let (response, body) = try await postJSON(
                            url: url,
                            sessionID: sessionID,
                            payload: toolCallPayload(
                                id: index + 200,
                                name: "XcodeRefreshCodeIssuesInFile",
                                arguments: [
                                    "tabIdentifier": "windowtab-refresh",
                                    "filePath": "App\(index).swift",
                                ]
                            )
                        )
                        let result = body["result"] as? [String: Any]
                        return (response.statusCode, (result?["isError"] as? Bool) == true)
                    }
                }

                var responses: [(Int, Bool)] = []
                for try await response in group {
                    responses.append(response)
                }
                return responses
            }

            #expect(responses.count == 3)
            for (statusCode, isError) in responses {
                #expect(statusCode == 200)
                #expect(isError == false)
            }
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }
}

private enum ConcurrencyTestError: Error {
    case invalidResponse
    case missingSessionID
}

private func runConcurrentInitialize(
    url: URL,
    count: Int
) async throws -> ([String], [Int]) {
    try await withThrowingTaskGroup(of: (String, Int).self) { group in
        for index in 0..<count {
            group.addTask {
                let payload = initializePayload(id: index + 1)
                let (response, body) = try await postJSON(
                    url: url, sessionID: nil, payload: payload)
                guard let sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id") else {
                    throw ConcurrencyTestError.missingSessionID
                }
                let responseID = (body["id"] as? NSNumber)?.intValue ?? -1
                return (sessionID, responseID)
            }
        }

        var sessionIDs: [String] = []
        var ids: [Int] = []
        for try await (sessionID, responseID) in group {
            sessionIDs.append(sessionID)
            ids.append(responseID)
        }
        return (sessionIDs, ids)
    }
}

private struct TestHTTPServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let url: URL
    let sessionManager: RuntimeCoordinator
    let upstream: any UpstreamClient

    static func start(
        upstream providedUpstream: (any UpstreamClient)? = nil
    ) throws -> TestHTTPServer {
        ProxyLogging.bootstrap(environment: ["MCP_LOG_LEVEL": "critical"])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let config = ProxyConfig(
            listenHost: "127.0.0.1",
            listenPort: 0,
            upstreamCommand: "xcrun",
            upstreamArgs: ["mcpbridge"],
            upstreamSessionID: nil,
            maxBodyBytes: 1_048_576,
            requestTimeout: 5,
            refreshCodeIssuesMode: .upstream
        )
        let upstream = providedUpstream ?? EchoUpstreamClient()
        let sessionManager = RuntimeCoordinator(
            config: config, eventLoop: group.next(), upstreams: [upstream])
        let refreshCodeIssuesCoordinator = RefreshCodeIssuesCoordinator.makeDefault(
            requestTimeout: config.requestTimeout
        )
        let refreshCodeIssuesTargetResolver = RefreshCodeIssuesTargetResolver()

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            config: config,
                            sessionManager: sessionManager,
                            refreshCodeIssuesCoordinator: refreshCodeIssuesCoordinator,
                            refreshCodeIssuesTargetResolver: refreshCodeIssuesTargetResolver
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: config.listenHost, port: config.listenPort).wait()
        let port = channel.localAddress?.port ?? config.listenPort
        let url = URL(string: "http://\(config.listenHost):\(port)/mcp")!
        return TestHTTPServer(
            group: group,
            channel: channel,
            url: url,
            sessionManager: sessionManager,
            upstream: upstream
        )
    }

    func shutdown() async {
        sessionManager.shutdown()
        channel.close(promise: nil)
        await withCheckedContinuation { continuation in
            group.shutdownGracefully { _ in
                continuation.resume()
            }
        }
    }
}

private actor EchoUpstreamClient: UpstreamClient {
    nonisolated let events: AsyncStream<UpstreamEvent>
    private let continuation: AsyncStream<UpstreamEvent>.Continuation

    init() {
        var streamContinuation: AsyncStream<UpstreamEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func send(_ data: Data) async -> UpstreamSendResult {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .accepted
        }
        var responses: [Data] = []
        if let object = json as? [String: Any] {
            if let response = makeResponse(from: object) {
                responses.append(response)
            }
        } else if let array = json as? [Any] {
            for item in array {
                guard let object = item as? [String: Any] else { continue }
                if let response = makeResponse(from: object) {
                    responses.append(response)
                }
            }
        }

        for response in responses {
            continuation.yield(.message(response))
        }
        return .accepted
    }

    private func makeResponse(from object: [String: Any]) -> Data? {
        guard let id = object["id"] else {
            return nil
        }
        let method = object["method"] as? String
        let result: [String: Any]
        if method == "initialize" {
            result = ["capabilities": [String: Any]()]
        } else {
            result = [:]
        }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        return try? JSONSerialization.data(withJSONObject: response, options: [])
    }
}

private actor RefreshSensitiveUpstreamClient: UpstreamClient {
    nonisolated let events: AsyncStream<UpstreamEvent>
    private let continuation: AsyncStream<UpstreamEvent>.Continuation
    private var activeTabs: Set<String> = []

    init() {
        var streamContinuation: AsyncStream<UpstreamEvent>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func send(_ data: Data) async -> UpstreamSendResult {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .accepted
        }

        if let object = json as? [String: Any] {
            await handle(object)
            return .accepted
        }

        if let array = json as? [Any] {
            for item in array {
                guard let object = item as? [String: Any] else { continue }
                await handle(object)
            }
        }
        return .accepted
    }

    private func handle(_ object: [String: Any]) async {
        guard let id = object["id"] else { return }
        let method = object["method"] as? String

        if method == "initialize" {
            continuation.yield(.message(makeInitializeResponse(id: id)))
            return
        }

        guard
            method == "tools/call",
            let params = object["params"] as? [String: Any],
            let name = params["name"] as? String,
            name == "XcodeRefreshCodeIssuesInFile"
        else {
            continuation.yield(.message(makeSuccessResponse(id: id)))
            return
        }

        let arguments = params["arguments"] as? [String: Any]
        let tabIdentifier =
            (arguments?["tabIdentifier"] as? String) ?? "__global__"
        if activeTabs.contains(tabIdentifier) {
            continuation.yield(.message(makeErrorFiveResponse(id: id)))
            return
        }

        activeTabs.insert(tabIdentifier)
        let responseData = makeSuccessResponse(id: id)
        Task { [tabIdentifier, responseData] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            completeRefresh(
                tabIdentifier: tabIdentifier,
                responseData: responseData
            )
        }
    }

    private func completeRefresh(tabIdentifier: String, responseData: Data) {
        activeTabs.remove(tabIdentifier)
        continuation.yield(.message(responseData))
    }

    private func makeInitializeResponse(id: Any) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "capabilities": [String: Any]()
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func makeSuccessResponse(id: Any) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": "ok",
                    ]
                ]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func makeErrorFiveResponse(id: Any) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text":
                            "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditor.SourceEditorCallableDiagnosticError error 5.)",
                    ]
                ],
                "isError": true,
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
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "xcode-mcp-proxy-concurrency-tests",
                "version": "0.0",
            ],
        ],
    ]
}

private func toolCallPayload(
    id: Int,
    name: String,
    arguments: [String: Any]
) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": [
            "name": name,
            "arguments": arguments,
        ],
    ]
}

private func postJSON(
    url: URL,
    sessionID: String?,
    payload: [String: Any]
) async throws -> (HTTPURLResponse, [String: Any]) {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let sessionID {
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    }

    let (responseData, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw ConcurrencyTestError.invalidResponse
    }
    let object =
        (try? JSONSerialization.jsonObject(with: responseData, options: [])) as? [String: Any]
        ?? [:]
    return (httpResponse, object)
}
