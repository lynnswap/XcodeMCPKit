import Foundation
import NIO
import NIOEmbedded
import NIOHTTP1
import Testing
import ProxyCore
import ProxySession
import XcodeMCPTestSupport
@testable import ProxyHTTPGateway

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
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
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
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpConcurrentRequestsShareSession() async throws {
        let upstream = ControlledUpstreamClient()
        let server = try TestHTTPServer.start(upstream: upstream)
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
            await upstream.clearRecordedRequests()

            async let first = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolListPayload(id: 100)
            )
            async let second = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolListPayload(id: 101)
            )

            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    await upstream.nonInitializeRequestCount() == 1
                }
            )
            await upstream.respondNext()
            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    await upstream.nonInitializeRequestCount() == 2
                }
            )
            await upstream.respondNext()

            let firstResult = try await first
            let secondResult = try await second
            #expect(firstResult.0.statusCode == 200)
            #expect(secondResult.0.statusCode == 200)
            #expect((firstResult.1["id"] as? NSNumber)?.intValue == 100)
            #expect((secondResult.1["id"] as? NSNumber)?.intValue == 101)
            #expect(await upstream.nonInitializeLabels() == ["tools/list", "tools/list"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpConcurrentRequestsCanOverlapAcrossSessions() async throws {
        let upstream = ControlledUpstreamClient()
        let server = try TestHTTPServer.start(upstream: upstream)
        let url = server.url

        do {
            let (initializeResponseA, _) = try await postJSON(
                url: url,
                sessionID: nil,
                payload: initializePayload(id: 1)
            )
            let (initializeResponseB, _) = try await postJSON(
                url: url,
                sessionID: nil,
                payload: initializePayload(id: 2)
            )
            guard let sessionA = initializeResponseA.value(forHTTPHeaderField: "Mcp-Session-Id"),
                let sessionB = initializeResponseB.value(forHTTPHeaderField: "Mcp-Session-Id")
            else {
                throw ConcurrencyTestError.missingSessionID
            }
            await upstream.clearRecordedRequests()

            async let first = postJSON(
                url: url,
                sessionID: sessionA,
                payload: toolListPayload(id: 200)
            )
            async let second = postJSON(
                url: url,
                sessionID: sessionB,
                payload: toolListPayload(id: 201)
            )

            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    await upstream.nonInitializeRequestCount() == 1
                }
            )

            await upstream.respondNext()
            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    await upstream.nonInitializeRequestCount() == 2
                }
            )
            await upstream.respondNext()

            let firstResult = try await first
            let secondResult = try await second
            #expect(firstResult.0.statusCode == 200)
            #expect(secondResult.0.statusCode == 200)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpQueuedWaitDoesNotConsumeRequestTimeout() async throws {
        let upstream = ControlledUpstreamClient()
        let server = try TestHTTPServer.start(
            upstream: upstream,
            requestTimeout: 0.15
        )
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
            await upstream.clearRecordedRequests()

            async let first = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolListPayload(id: 300)
            )
            async let second = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolListPayload(id: 301)
            )

            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    await upstream.nonInitializeRequestCount() == 1
                }
            )
            await upstream.respondNext()
            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    await upstream.nonInitializeRequestCount() == 2
                }
            )
            await upstream.respondNext()

            let firstResult = try await first
            let secondResult = try await second
            #expect(firstResult.0.statusCode == 200)
            #expect(secondResult.0.statusCode == 200)
            #expect((secondResult.1["id"] as? NSNumber)?.intValue == 301)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpTimedOutExecuteSnippetReleasesSessionAndStartsNextQueuedRequest() async throws {
        let upstream = ControlledUpstreamClient()
        let server = try TestHTTPServer.start(
            upstream: upstream,
            requestTimeout: 0.15
        )
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
            await upstream.clearRecordedRequests()

            async let first = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolCallPayload(
                    id: 700,
                    name: "ExecuteSnippet",
                    arguments: [
                        "tabIdentifier": "windowtab-timeout",
                        "sourceFilePath": "App.swift",
                        "codeSnippet": "print(\"first\")",
                        "timeout": 20,
                    ]
                )
            )
            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    await upstream.nonInitializeLabels() == ["tools/call:ExecuteSnippet"]
                }
            )

            async let second = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolListPayload(id: 701)
            )

            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    await upstream.nonInitializeLabels() == [
                        "tools/call:ExecuteSnippet",
                        "tools/list",
                    ]
                }
            )

            await upstream.discardNextResponse()
            await upstream.respondNext()

            let firstResult = try await first
            let secondResult = try await second
            #expect(firstResult.0.statusCode == 200)
            #expect((firstResult.1["error"] as? [String: Any])?["message"] as? String == "upstream timeout")
            #expect(secondResult.0.statusCode == 200)
            #expect((secondResult.1["id"] as? NSNumber)?.intValue == 701)
            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    if let snapshot = server.sessionManager.debugSnapshot().sessions.first(where: { $0.sessionID == sessionID }) {
                        return snapshot.activeCorrelatedRequestCount == 0
                    }
                    return false
                }
            )
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpQueuedNotificationDoesNotOvertakeEarlierSessionRequest() async throws {
        let upstream = ControlledUpstreamClient()
        let server = try TestHTTPServer.start(upstream: upstream)
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
            await upstream.clearRecordedRequests()

            async let first = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolListPayload(id: 400),
                timeout: 10
            )
            async let notification = postStatusOnly(
                url: url,
                sessionID: sessionID,
                payload: notificationPayload(method: "notifications/test-progress"),
                timeout: 10
            )

            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    await upstream.nonInitializeRequestCount() >= 1
                }
            )
            await upstream.respondNext()
            let notificationResponse = try await notification
            #expect(notificationResponse.statusCode == 202)
            let firstResult = try await first
            #expect(firstResult.0.statusCode == 200)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDebugSnapshotReportsSessionPipelineState() async throws {
        let upstream = ControlledUpstreamClient()
        let server = try TestHTTPServer.start(upstream: upstream)
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
            await upstream.clearRecordedRequests()

            async let first = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolListPayload(id: 600),
                timeout: 10
            )
            async let second = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolListPayload(id: 601),
                timeout: 10
            )

            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    if let snapshot = server.sessionManager.debugSnapshot().sessions.first(where: { $0.sessionID == sessionID }) {
                        return snapshot.activeCorrelatedRequestCount == 1
                    }
                    return false
                }
            )

            await upstream.respondNext()
            await upstream.respondNext()
            _ = try await first
            _ = try await second

            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    if let snapshot = server.sessionManager.debugSnapshot().sessions.first(where: { $0.sessionID == sessionID }) {
                        return snapshot.activeCorrelatedRequestCount == 0
                    }
                    return false
                }
            )
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDocumentationSearchRequestsSerializeWithinSession() async throws {
        let upstream = ControlledUpstreamClient()
        let server = try TestHTTPServer.start(upstream: upstream)
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
            await upstream.clearRecordedRequests()

            async let first = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolCallPayload(
                    id: 500,
                    name: "DocumentationSearch",
                    arguments: [
                        "query": "Transaction.updates",
                        "frameworks": ["StoreKit"],
                    ]
                )
            )
            async let second = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolCallPayload(
                    id: 501,
                    name: "DocumentationSearch",
                    arguments: [
                        "query": "currentEntitlements",
                        "frameworks": ["StoreKit"],
                    ]
                )
            )

            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    await upstream.nonInitializeLabels() == ["tools/call:DocumentationSearch"]
                }
            )
            await upstream.respondNext()
            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    await upstream.nonInitializeLabels() == [
                        "tools/call:DocumentationSearch",
                        "tools/call:DocumentationSearch",
                    ]
                }
            )
            await upstream.respondNext()

            let firstResult = try await first
            let secondResult = try await second
            #expect(firstResult.0.statusCode == 200)
            #expect(secondResult.0.statusCode == 200)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpConcurrentRefreshCodeIssuesRequestsDoNotSurfaceErrorFiveOrDeadlockInternalCalls() async throws {
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
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpConcurrentRefreshCodeIssuesRequestsRespectSingleFlightPerUpstream() async throws {
        let server = try TestHTTPServer.start(upstream: SingleFlightRefreshUpstreamClient())
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
                                id: index + 300,
                                name: "XcodeRefreshCodeIssuesInFile",
                                arguments: [
                                    "tabIdentifier": "windowtab-refresh-\(index)",
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
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesNotificationForwardsWithoutInvalidUpstreamOverride()
        async throws
    {
        let upstream = ControlledUpstreamClient()
        let server = try TestHTTPServer.start(upstream: upstream)
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
            await upstream.clearRecordedRequests()

            let response = try await postStatusOnly(
                url: url,
                sessionID: sessionID,
                payload: toolCallNotificationPayload(
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-refresh-notification",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 202)
            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    await upstream.nonInitializeLabels() == ["tools/call:XcodeRefreshCodeIssuesInFile"]
                }
            )
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpServerNotificationsReachActiveSSESessions() async throws {
        let upstream = NotifyingUpstreamClient()
        let server = try TestHTTPServer.start(upstream: upstream)
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

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")

            let sseTask = Task<(HTTPURLResponse, String), Error> {
                try await withTestURLSession { session in
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ConcurrencyTestError.invalidResponse
                    }

                    var iterator = bytes.lines.makeAsyncIterator()
                    while let line = try await iterator.next() {
                        if line.hasPrefix("data: ") {
                            return (httpResponse, String(line.dropFirst(6)))
                        }
                    }

                    throw ConcurrencyTestError.invalidResponse
                }
            }
            defer { sseTask.cancel() }

            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    server.sessionManager.session(id: sessionID).notificationHub.hasSseClients
                }
            )

            let notificationData = try JSONSerialization.data(
                withJSONObject: [
                    "jsonrpc": "2.0",
                    "method": "notifications/test",
                    "params": ["value": 42],
                ],
                options: []
            )
            await upstream.pushNotification(notificationData)

            let (response, line) = try await waitWithTimeout(
                "waiting for SSE notification",
                timeout: .seconds(2)
            ) {
                try await sseTask.value
            }

            #expect(response.statusCode == 200)
            #expect(line == String(decoding: notificationData, as: UTF8.self))
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
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
    let upstream: any UpstreamSlotControlling
    let childChannelTracker: HTTPTestServerChannelTracker

    static func start(
        upstream providedUpstream: (any UpstreamSlotControlling)? = nil,
        requestTimeout: TimeInterval = 5
    ) throws -> TestHTTPServer {
        ProxyLogging.bootstrap(environment: ["MCP_LOG_LEVEL": "critical"])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let childChannelTracker = HTTPTestServerChannelTracker()
        let config = ProxyConfig(
            listenHost: "127.0.0.1",
            listenPort: 0,
            upstreamCommand: "xcrun",
            upstreamArgs: ["mcpbridge"],
            upstreamSessionID: nil,
            maxBodyBytes: 1_048_576,
            requestTimeout: requestTimeout
        )
        let upstream = providedUpstream ?? EchoUpstreamClient()
        let sessionManager = RuntimeCoordinator(
            config: config, eventLoop: group.next(), upstreams: [upstream])

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
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
        return TestHTTPServer(
            group: group,
            channel: channel,
            url: url,
            sessionManager: sessionManager,
            upstream: upstream,
            childChannelTracker: childChannelTracker
        )
    }

    func shutdown() async throws {
        try await shutdownHTTPTestServer(
            listenChannel: channel,
            childChannelTracker: childChannelTracker,
            group: group,
            beforeClose: {
                sessionManager.shutdown()
            }
        )
    }
}

private actor EchoUpstreamClient: UpstreamSlotControlling {
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

private actor ControlledUpstreamClient: UpstreamSlotControlling {
    struct SentRequest: Sendable {
        let label: String
        let responseData: Data?
    }

    nonisolated let events: AsyncStream<UpstreamEvent>
    private let continuation: AsyncStream<UpstreamEvent>.Continuation
    private var sentRequests: [SentRequest] = []
    private var requestHistory: [String] = []

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
        } else if let array = json as? [Any] {
            for item in array {
                guard let object = item as? [String: Any] else { continue }
                await handle(object)
            }
        }
        return .accepted
    }

    func nonInitializeRequestCount() -> Int {
        requestHistory.count
    }

    func nonInitializeLabels() -> [String] {
        requestHistory
    }

    func clearRecordedRequests() {
        sentRequests.removeAll()
        requestHistory.removeAll()
    }

    func respondNext() {
        guard !sentRequests.isEmpty else { return }
        let request = sentRequests.removeFirst()
        guard let responseData = request.responseData else { return }
        continuation.yield(.message(responseData))
    }

    func discardNextResponse() {
        guard !sentRequests.isEmpty else { return }
        _ = sentRequests.removeFirst()
    }

    private func handle(_ object: [String: Any]) async {
        let method = (object["method"] as? String) ?? "unknown"
        guard method != "initialize" else {
            if let id = object["id"] {
                continuation.yield(.message(makeInitializeResponse(id: id)))
            }
            return
        }

        let label = requestLabel(from: object)
        let responseData = makeSuccessResponse(id: object["id"])
        sentRequests.append(SentRequest(label: label, responseData: responseData))
        requestHistory.append(label)
    }

    private func requestLabel(from object: [String: Any]) -> String {
        let method = (object["method"] as? String) ?? "unknown"
        if method == "tools/call",
            let params = object["params"] as? [String: Any],
            let name = params["name"] as? String
        {
            return "\(method):\(name)"
        }
        return method
    }

    private func makeInitializeResponse(id: Any) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["capabilities": [String: Any]()],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func makeSuccessResponse(id: Any?) -> Data? {
        guard let id else { return nil }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [:],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }
}

private actor RefreshSensitiveUpstreamClient: UpstreamSlotControlling {
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

private actor SingleFlightRefreshUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<UpstreamEvent>
    private let continuation: AsyncStream<UpstreamEvent>.Continuation
    private var hasActiveRefresh = false

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

        if hasActiveRefresh {
            continuation.yield(.message(makeConcurrentRefreshErrorResponse(id: id)))
            return
        }

        hasActiveRefresh = true
        let responseData = makeSuccessResponse(id: id)
        Task { [responseData] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            completeRefresh(responseData: responseData)
        }
    }

    private func completeRefresh(responseData: Data) {
        hasActiveRefresh = false
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

    private func makeConcurrentRefreshErrorResponse(id: Any) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": "concurrent refresh not allowed",
                    ]
                ],
                "isError": true,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }
}

private actor NotifyingUpstreamClient: UpstreamSlotControlling {
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
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let method = object["method"] as? String
        else {
            return .accepted
        }

        if method == "initialize", let id = object["id"] {
            continuation.yield(.message(makeInitializeResponse(id: id)))
        }

        return .accepted
    }

    func pushNotification(_ data: Data) {
        continuation.yield(.message(data))
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

private func toolCallNotificationPayload(
    name: String,
    arguments: [String: Any]
) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": [
            "name": name,
            "arguments": arguments,
        ],
    ]
}

private func toolListPayload(id: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/list",
    ]
}

private func notificationPayload(method: String) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "method": method,
        "params": [String: Any](),
    ]
}

private func postJSON(
    url: URL,
    sessionID: String?,
    payload: [String: Any]
) async throws -> (HTTPURLResponse, [String: Any]) {
    try await postJSON(
        url: url,
        sessionID: sessionID,
        payload: payload,
        timeout: nil
    )
}

private func postJSON(
    url: URL,
    sessionID: String?,
    payload: [String: Any],
    timeout: TimeInterval?
) async throws -> (HTTPURLResponse, [String: Any]) {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let timeout {
        request.timeoutInterval = timeout
    }
    if let sessionID {
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    }

    return try await withTestURLSession(timeout: timeout ?? 5) { session in
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConcurrencyTestError.invalidResponse
        }
        let object =
            (try? JSONSerialization.jsonObject(with: responseData, options: [])) as? [String: Any]
            ?? [:]
        return (httpResponse, object)
    }
}

private func postStatusOnly(
    url: URL,
    sessionID: String?,
    payload: [String: Any],
    timeout: TimeInterval? = nil
) async throws -> HTTPURLResponse {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let timeout {
        request.timeoutInterval = timeout
    }
    if let sessionID {
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    }

    return try await withTestURLSession(timeout: timeout ?? 5) { session in
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConcurrencyTestError.invalidResponse
        }
        return httpResponse
    }
}

private func makeEmbeddedConfig(requestTimeout: TimeInterval) -> ProxyConfig {
    ProxyConfig(
        listenHost: "127.0.0.1",
        listenPort: 0,
        upstreamCommand: "xcrun",
        upstreamArgs: ["mcpbridge"],
        upstreamSessionID: nil,
        maxBodyBytes: 1_048_576,
        requestTimeout: requestTimeout
    )
}

private func addEmbeddedHTTPHandler(
    to channel: EmbeddedChannel,
    config: ProxyConfig,
    sessionManager: any RuntimeCoordinating
) throws {
    let handler = HTTPHandler(
        config: config,
        sessionManager: sessionManager
    )
    try channel.pipeline.addHandler(handler).wait()
}

private func postEmbeddedJSON(
    _ payload: [String: Any],
    sessionID: String?,
    to channel: EmbeddedChannel
) throws {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    if let sessionID {
        head.headers.add(name: "Mcp-Session-Id", value: sessionID)
    }
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))
}

private func collectEmbeddedResponse(
    from channel: EmbeddedChannel
) throws -> (head: HTTPResponseHead, body: String) {
    var responseHead: HTTPResponseHead?
    var bodyBuffer = channel.allocator.buffer(capacity: 0)

    while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
        switch part {
        case .head(let head):
            responseHead = head
        case .body(let body):
            switch body {
            case .byteBuffer(var buffer):
                bodyBuffer.writeBuffer(&buffer)
            case .fileRegion:
                break
            }
        case .end:
            break
        }
    }

    guard let responseHead else {
        throw ConcurrencyTestError.invalidResponse
    }
    let body = bodyBuffer.readString(length: bodyBuffer.readableBytes) ?? ""
    return (responseHead, body)
}

private func waitUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(20),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let intervalNanos = interval.components.seconds * 1_000_000_000
        + Int64(interval.components.attoseconds / 1_000_000_000)
    let deadline = ContinuousClock.now + timeout

    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: UInt64(max(intervalNanos, 1)))
    }

    return await condition()
}
