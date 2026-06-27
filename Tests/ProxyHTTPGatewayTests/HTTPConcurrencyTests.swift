import Foundation
import Dispatch
import NIO
import NIOEmbedded
import NIOHTTP1
import Testing
import ProxyCore
import ProxyMCP
import XcodeMCPBridgeRuntime
import ProxyXcodeFeatures
import XcodeMCPTestSupport
@testable import ProxySession
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
            await drainInitialToolsCatalogWarmupIfNeeded(server: server, upstream: upstream)

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
            let labels = try await waitForUpstreamRequestCount(upstream, count: 1)
            #expect(labels == ["tools/list"])
            #expect(await upstream.respondNext(label: "tools/list"))
            let firstResult = try await first
            let secondResult = try await second
            #expect(firstResult.0.statusCode == 200)
            #expect(secondResult.0.statusCode == 200)
            #expect((firstResult.1["id"] as? NSNumber)?.intValue == 100)
            #expect((secondResult.1["id"] as? NSNumber)?.intValue == 101)
            #expect(await upstream.nonInitializeLabels() == ["tools/list"])
            #expect(server.sessionManager.cachedToolsListResult() != nil)
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
            await drainInitialToolsCatalogWarmupIfNeeded(server: server, upstream: upstream)

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
            let labels = try await waitForUpstreamRequestCount(upstream, count: 1)
            #expect(labels == ["tools/list"])
            #expect(await upstream.respondNext(label: "tools/list"))
            let firstResult = try await first
            let secondResult = try await second
            #expect(firstResult.0.statusCode == 200)
            #expect(secondResult.0.statusCode == 200)
            #expect(await upstream.nonInitializeLabels() == ["tools/list"])
            #expect(server.sessionManager.cachedToolsListResult() != nil)
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
            await drainInitialToolsCatalogWarmupIfNeeded(server: server, upstream: upstream)

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

            let labels = try await waitForUpstreamRequestCount(upstream, count: 1)
            #expect(labels == ["tools/list"])
            #expect(await upstream.respondNext(label: "tools/list"))

            let firstResult = try await first
            let secondResult = try await second
            #expect(firstResult.0.statusCode == 200)
            #expect(secondResult.0.statusCode == 200)
            #expect((firstResult.1["id"] as? NSNumber)?.intValue == 300)
            #expect((secondResult.1["id"] as? NSNumber)?.intValue == 301)
            #expect(firstResult.1["error"] == nil)
            #expect(secondResult.1["error"] == nil)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRequestLeaseTimeoutReleasesSessionAndStartsNextQueuedRequest() throws {
        let upstream = EmbeddedControlledUpstreamClient()
        let config = makeEmbeddedConfig(requestTimeout: 0.15)
        let firstChannel = EmbeddedChannel()
        let secondChannel = EmbeddedChannel()
        let sessionManager = RuntimeCoordinator(
            config: config,
            eventLoop: firstChannel.eventLoop,
            upstreams: [upstream],
            startImmediately: false
        )
        defer {
            sessionManager.shutdownAndWait()
            _ = try? firstChannel.finish()
            _ = try? secondChannel.finish()
        }

        ProxyLogging.bootstrap(environment: ["MCP_LOG_LEVEL": "critical"])
        try addEmbeddedHTTPHandler(
            to: firstChannel,
            config: config,
            sessionManager: sessionManager
        )
        try addEmbeddedHTTPHandler(
            to: secondChannel,
            config: config,
            sessionManager: sessionManager
        )

        let sessionID = "session-timeout-queue"
        _ = sessionManager.session(id: sessionID)
        sessionManager.sessionRegistry.markInitialized(
            id: sessionID,
            negotiatedProtocolVersion: MCP.ProtocolVersion.current
        )
        sessionManager.markUpstreamInitialized(upstreamIndex: 0)
        sessionManager.canonicalBrokerState.syncCanonicalInitialize(
            try #require(
                JSONValue(any: [
                    "protocolVersion": MCP.ProtocolVersion.current,
                    "capabilities": [String: Any](),
                ])
            ),
            sourceUpstream: 0
        )
        sessionManager.setCachedToolsListResult(executeSnippetToolsCatalog(), sourceUpstream: 0)
        upstream.clearRecordedRequests()

        try postEmbeddedJSON(
            executeSnippetPayload(id: 700, tabIdentifier: "windowtab-timeout"),
            sessionID: sessionID,
            to: firstChannel
        )
        firstChannel.embeddedEventLoop.run()
        #expect(try upstream.waitForRequestCount(1) == ["tools/call:ExecuteSnippet"])

        try postEmbeddedJSON(
            executeSnippetPayload(id: 701, tabIdentifier: "windowtab-timeout-2"),
            sessionID: sessionID,
            to: secondChannel
        )
        secondChannel.embeddedEventLoop.run()
        #expect(sessionManager.debugSnapshot().queuedRequestCount == 1)

        firstChannel.embeddedEventLoop.advanceTime(by: .milliseconds(150))
        firstChannel.embeddedEventLoop.run()
        let firstResponse = try collectEmbeddedResponse(from: firstChannel)
        #expect(firstResponse.head.status == .ok)
        let firstObject = try jsonObject(from: firstResponse.body)
        #expect((firstObject["error"] as? [String: Any])?["message"] as? String == "upstream timeout")

        secondChannel.embeddedEventLoop.run()
        #expect(try upstream.waitForRequestCount(2) == [
            "tools/call:ExecuteSnippet",
            "tools/call:ExecuteSnippet",
        ])

        #expect(upstream.discardNextResponse(label: "tools/call:ExecuteSnippet"))
        let secondResponseData = try #require(
            upstream.takeNextResponse(label: "tools/call:ExecuteSnippet")
        )
        sessionManager.routeUpstreamMessage(secondResponseData, upstreamIndex: 0)
        secondChannel.embeddedEventLoop.run()

        let secondResponse = try collectEmbeddedResponse(from: secondChannel)
        #expect(secondResponse.head.status == .ok)
        let secondObject = try jsonObject(from: secondResponse.body)
        #expect((secondObject["id"] as? NSNumber)?.intValue == 701)
        #expect(secondObject["error"] == nil)
        #expect(
            sessionManager.debugSnapshot().sessions
                .first(where: { $0.sessionID == sessionID })?
                .activeCorrelatedRequestCount == 0
        )
    }

    private func executeSnippetPayload(id: Int, tabIdentifier: String) -> [String: Any] {
        toolCallPayload(
            id: id,
            name: "ExecuteSnippet",
            arguments: [
                "tabIdentifier": tabIdentifier,
                "sourceFilePath": "App.swift",
                "codeSnippet": "print(\"\(id)\")",
                "timeout": 20,
            ]
        )
    }

    private func executeSnippetToolsCatalog() -> JSONValue {
        JSONValue(any: [
            "tools": [
                [
                    "name": "ExecuteSnippet",
                    "outputSchema": [
                        "type": "object",
                    ],
                ],
            ],
        ])!
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
            await drainInitialToolsCatalogWarmupIfNeeded(server: server, upstream: upstream)

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

            _ = try await waitForUpstreamRequest(upstream, label: "tools/list")
            #expect(await upstream.respondNext(label: "tools/list"))
            let firstResult = try await first
            #expect(firstResult.0.statusCode == 200)
            #expect((firstResult.1["id"] as? NSNumber)?.intValue == 400)
            #expect(firstResult.1["error"] == nil)
            _ = try await waitForUpstreamRequest(upstream, label: "notifications/test-progress")
            let notificationResponse = try await notification
            #expect(notificationResponse.statusCode == 202)
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
            await drainInitialToolsCatalogWarmupIfNeeded(server: server, upstream: upstream)

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

            _ = try await waitForUpstreamRequest(upstream, label: "tools/list")
            _ = try await waitWithTimeout(
                "waiting for tools catalog waiters",
                timeout: .seconds(2)
            ) {
                try await server.sessionManager.controlPlaneDebugMirror.waitForSnapshot {
                    $0.waiterCounts.toolsCatalog == 2
                }
            }

            #expect(await upstream.respondNext(label: "tools/list"))
            let firstResult = try await first
            let secondResult = try await second
            #expect(firstResult.0.statusCode == 200)
            #expect(secondResult.0.statusCode == 200)
            #expect(server.sessionManager.cachedToolsListResult() != nil)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpConcurrentRefreshCodeIssuesRequestsDoNotSurfaceErrorFiveOrDeadlockInternalCalls() async throws {
        let upstream = RefreshSensitiveUpstreamClient()
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

            let tasks = (0..<3).map { index in
                Task {
                    _ = try await postJSON(
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
                }
            }

            try await upstream.waitForRefreshStartCount(1)
            #expect(server.refreshDebugState.snapshot().queue.activeRequestCount >= 1)
            #expect(await upstream.didEmitErrorFive() == false)
            await upstream.releaseRefreshResponses()
            for task in tasks {
                _ = try await task.value
            }
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpConcurrentRefreshCodeIssuesRequestsRespectSingleFlightPerUpstream() async throws {
        let upstream = SingleFlightRefreshUpstreamClient()
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

            let tasks = (0..<3).map { index in
                Task {
                    _ = try await postJSON(
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
                }
            }

            try await upstream.waitForRefreshStartCount(1)
            try await waitWithTimeout(
                "waiting for concurrent refresh requests to enter the debug queue",
                timeout: .seconds(2)
            ) {
                try await server.refreshDebugState.waitForActiveRequestCount(3)
            }
            #expect(server.refreshDebugState.snapshot().queue.activeRequestCount == 3)
            #expect(await upstream.didEmitConcurrentRefreshError() == false)
            await upstream.releaseRefreshResponses()
            for task in tasks {
                _ = try await task.value
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
            let labels = try await waitForUpstreamRequestCount(upstream, count: 1)
            #expect(labels == ["tools/call:XcodeRefreshCodeIssuesInFile"])
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
            request.setValue(MCP.ProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")

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

            _ = try await waitWithTimeout(
                "waiting for SSE client registration",
                timeout: .seconds(2)
            ) {
                try await server.sessionManager.session(id: sessionID)
                    .notificationHub.waitForSSEClient()
            }

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
    let refreshDebugState: RefreshCodeIssues.DebugState

    static func start(
        upstream providedUpstream: (any UpstreamSlotControlling)? = nil,
        requestTimeout: TimeInterval = 5
    ) throws -> TestHTTPServer {
        ProxyLogging.bootstrap(environment: ["MCP_LOG_LEVEL": "critical"])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let childChannelTracker = HTTPTestServerChannelTracker()
        let config: ProxyConfig = {
            var config = ProxyConfig(
                listenHost: "127.0.0.1",
                listenPort: 0,
                upstreamCommand: "xcrun",
                upstreamArgs: ["mcpbridge"],
                upstreamSessionID: nil,
                maxBodyBytes: 1_048_576,
                requestTimeout: requestTimeout
            )
            config.prewarmToolsList = false
            return config
        }()
        let upstream = providedUpstream ?? EchoUpstreamClient()
        let sessionManager = RuntimeCoordinator(
            config: config, eventLoop: group.next(), upstreams: [upstream])
        let refreshDebugState = RefreshCodeIssues.DebugState(
            defaultRequestTimeoutSeconds: config.requestTimeout
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            config: config,
                            sessionManager: sessionManager,
                            refreshCodeIssuesDebugState: refreshDebugState
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
            childChannelTracker: childChannelTracker,
            refreshDebugState: refreshDebugState
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

private actor EchoUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation

    init() {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func send(_ data: Data) async -> Upstream.SendResult {
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
            result = [
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
            ]
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

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    description: String
) throws {
    guard semaphore.wait(timeout: .now() + .seconds(2)) == .success else {
        throw AsyncTestTimeoutError(description: description)
    }
}

private func waitForUpstreamRequest(
    _ upstream: ControlledUpstreamClient,
    label: String
) async throws -> String {
    try await waitWithTimeout("waiting for upstream \(label) request", timeout: .seconds(2)) {
        try await upstream.waitForNonInitializeRequest(label: label)
    }
}

private func waitForUpstreamRequestCount(
    _ upstream: ControlledUpstreamClient,
    count: Int
) async throws -> [String] {
    try await waitWithTimeout("waiting for \(count) upstream request(s)", timeout: .seconds(2)) {
        try await upstream.waitForNonInitializeRequestCount(count)
    }
}

private final class EmbeddedControlledUpstreamClient: UpstreamSlotControlling, @unchecked Sendable {
    private struct SentRequest: Sendable {
        let label: String
        let responseData: Data?
    }

    private struct State {
        var sentRequests: [SentRequest] = []
        var requestHistory: [String] = []
    }

    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let lock = NSLock()
    private let requestSemaphore = DispatchSemaphore(value: 0)
    private var state = State()

    init() {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
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

    func clearRecordedRequests() {
        withLock {
            $0.sentRequests.removeAll()
            $0.requestHistory.removeAll()
        }
    }

    func waitForRequestCount(_ count: Int) throws -> [String] {
        guard count > 0 else { return [] }
        while true {
            let labels = withLock { $0.requestHistory }
            if labels.count >= count {
                return Array(labels.prefix(count))
            }
            try waitForSemaphore(
                requestSemaphore,
                description: "waiting for \(count) embedded upstream request(s)"
            )
        }
    }

    @discardableResult
    func respondNext(label expectedLabel: String? = nil) -> Bool {
        guard let responseData = takeNextResponse(label: expectedLabel) else { return false }
        continuation.yield(.message(responseData))
        return true
    }

    func takeNextResponse(label expectedLabel: String? = nil) -> Data? {
        removeNextRequest(label: expectedLabel)?.responseData
    }

    @discardableResult
    func discardNextResponse(label expectedLabel: String? = nil) -> Bool {
        removeNextRequest(label: expectedLabel) != nil
    }

    private func removeNextRequest(label expectedLabel: String?) -> SentRequest? {
        withLock { state in
            let requestIndex: Array<SentRequest>.Index?
            if let expectedLabel {
                requestIndex = state.sentRequests.firstIndex { $0.label == expectedLabel }
            } else {
                requestIndex = state.sentRequests.indices.first
            }
            guard let requestIndex else { return nil }
            return state.sentRequests.remove(at: requestIndex)
        }
    }

    private func handle(_ object: [String: Any]) {
        let method = (object["method"] as? String) ?? "unknown"
        guard method != "initialize" else {
            if let id = object["id"] {
                continuation.yield(.message(makeInitializeResponse(id: id)))
            }
            return
        }

        let label = requestLabel(from: object)
        let responseData = makeDefaultResponse(id: object["id"], method: method)
        withLock {
            $0.sentRequests.append(SentRequest(label: label, responseData: responseData))
            $0.requestHistory.append(label)
        }
        requestSemaphore.signal()
    }

    private func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
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
            "result": ["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [String: Any]()],
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

    private func makeToolsListResponse(id: Any?) -> Data? {
        guard let id else { return nil }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "tools": [[
                    "name": "XcodeListWindows",
                    "description": "List Xcode windows",
                    "inputSchema": [
                        "type": "object",
                        "properties": [String: Any](),
                    ],
                ]]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func makeDefaultResponse(id: Any?, method: String) -> Data? {
        if method == "tools/list" {
            return makeToolsListResponse(id: id)
        }
        return makeSuccessResponse(id: id)
    }
}

private actor ControlledUpstreamClient: UpstreamSlotControlling {
    struct SentRequest: Sendable {
        let label: String
        let responseData: Data?
    }

    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private var sentRequests: [SentRequest] = []
    private var requestHistory: [String] = []
    private let requestLabels = RecordedValues<String>()
    private var requestLabelBaseline = 0
    private var requestLabelCount = 0

    init() {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
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

    func pendingNonInitializeRequestCount() -> Int {
        sentRequests.count
    }

    func nonInitializeLabels() -> [String] {
        requestHistory
    }

    @discardableResult
    func waitForNonInitializeRequestCount(_ count: Int) async throws -> [String] {
        guard count > 0 else { return [] }
        _ = try await requestLabels.nextValue(at: requestLabelBaseline + count - 1)
        let labels = await requestLabels.snapshot()
        return Array(labels.dropFirst(requestLabelBaseline).prefix(count))
    }

    @discardableResult
    func waitForNonInitializeRequest(label expectedLabel: String) async throws -> String {
        try await requestLabels.nextValue(startingAt: requestLabelBaseline) { label in
            label == expectedLabel
        }
    }

    func clearRecordedRequests() {
        sentRequests.removeAll()
        requestHistory.removeAll()
        requestLabelBaseline = requestLabelCount
    }

    @discardableResult
    func respondNext(label expectedLabel: String? = nil) -> Bool {
        let requestIndex: Array<SentRequest>.Index?
        if let expectedLabel {
            requestIndex = sentRequests.firstIndex { $0.label == expectedLabel }
        } else {
            requestIndex = sentRequests.indices.first
        }
        guard let requestIndex else { return false }
        let request = sentRequests.remove(at: requestIndex)
        guard let responseData = request.responseData else { return false }
        continuation.yield(.message(responseData))
        return true
    }

    @discardableResult
    func discardNextResponse(label expectedLabel: String? = nil) -> Bool {
        let requestIndex: Array<SentRequest>.Index?
        if let expectedLabel {
            requestIndex = sentRequests.firstIndex { $0.label == expectedLabel }
        } else {
            requestIndex = sentRequests.indices.first
        }
        guard let requestIndex else { return false }
        _ = sentRequests.remove(at: requestIndex)
        return true
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
        let responseData = makeDefaultResponse(id: object["id"], method: method)
        sentRequests.append(SentRequest(label: label, responseData: responseData))
        requestHistory.append(label)
        requestLabelCount += 1
        await requestLabels.append(label)
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
            "result": ["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [String: Any]()],
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

    private func makeToolsListResponse(id: Any?) -> Data? {
        guard let id else { return nil }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "tools": [[
                    "name": "XcodeListWindows",
                    "description": "List Xcode windows",
                    "inputSchema": [
                        "type": "object",
                        "properties": [String: Any](),
                    ],
                ]]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func makeDefaultResponse(id: Any?, method: String) -> Data? {
        if method == "tools/list" {
            return makeToolsListResponse(id: id)
        }
        return makeSuccessResponse(id: id)
    }
}

private actor RefreshSensitiveUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let refreshStarts = RecordedValues<String>()
    private let releaseResponses = AsyncGate()
    private var activeTabs: Set<String> = []
    private var emittedErrorFive = false

    init() {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func didEmitErrorFive() -> Bool {
        emittedErrorFive
    }

    func waitForRefreshStartCount(_ count: Int) async throws {
        guard count > 0 else { return }
        _ = try await refreshStarts.nextValue(at: count - 1)
    }

    func releaseRefreshResponses() async {
        await releaseResponses.signal()
    }

    func send(_ data: Data) async -> Upstream.SendResult {
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
            continuation.yield(.message(makeDefaultResponse(id: id, method: method)))
            return
        }

        let arguments = params["arguments"] as? [String: Any]
        let tabIdentifier =
            (arguments?["tabIdentifier"] as? String) ?? "__global__"
        if activeTabs.contains(tabIdentifier) {
            emittedErrorFive = true
            continuation.yield(.message(makeErrorFiveResponse(id: id)))
            return
        }

        activeTabs.insert(tabIdentifier)
        await refreshStarts.append(tabIdentifier)
        let responseData = makeDefaultResponse(id: id, method: method)
        Task { [tabIdentifier, responseData] in
            do {
                try await releaseResponses.wait()
            } catch {
                return
            }
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
                "protocolVersion": MCP.ProtocolVersion.current,
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

    private func makeToolsListResponse(id: Any) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "tools": [[
                    "name": "XcodeRefreshCodeIssuesInFile",
                    "description": "Refresh issues",
                    "inputSchema": [
                        "type": "object",
                        "properties": [String: Any](),
                    ],
                ]]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func makeDefaultResponse(id: Any, method: String?) -> Data {
        if method == "tools/list" {
            return makeToolsListResponse(id: id)
        }
        return makeSuccessResponse(id: id)
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
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let refreshStarts = RecordedValues<Int>()
    private let releaseResponses = AsyncGate()
    private var hasActiveRefresh = false
    private var emittedConcurrentRefreshError = false

    init() {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func didEmitConcurrentRefreshError() -> Bool {
        emittedConcurrentRefreshError
    }

    func waitForRefreshStartCount(_ count: Int) async throws {
        guard count > 0 else { return }
        _ = try await refreshStarts.nextValue(at: count - 1)
    }

    func releaseRefreshResponses() async {
        await releaseResponses.signal()
    }

    func send(_ data: Data) async -> Upstream.SendResult {
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
            continuation.yield(.message(makeDefaultResponse(id: id, method: method)))
            return
        }

        if hasActiveRefresh {
            emittedConcurrentRefreshError = true
            continuation.yield(.message(makeConcurrentRefreshErrorResponse(id: id)))
            return
        }

        hasActiveRefresh = true
        let startIndex = await refreshStarts.count()
        await refreshStarts.append(startIndex + 1)
        let responseData = makeDefaultResponse(id: id, method: method)
        Task { [responseData] in
            do {
                try await releaseResponses.wait()
            } catch {
                return
            }
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
                "protocolVersion": MCP.ProtocolVersion.current,
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

    private func makeToolsListResponse(id: Any) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "tools": [[
                    "name": "XcodeRefreshCodeIssuesInFile",
                    "description": "Refresh issues",
                    "inputSchema": [
                        "type": "object",
                        "properties": [String: Any](),
                    ],
                ]]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func makeDefaultResponse(id: Any, method: String?) -> Data {
        if method == "tools/list" {
            return makeToolsListResponse(id: id)
        }
        return makeSuccessResponse(id: id)
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
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation

    init() {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func send(_ data: Data) async -> Upstream.SendResult {
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
                "protocolVersion": MCP.ProtocolVersion.current,
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
            "protocolVersion": "2025-06-18",
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
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let timeout {
        request.timeoutInterval = timeout
    }
    if let sessionID {
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue(MCP.ProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")
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
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let timeout {
        request.timeoutInterval = timeout
    }
    if let sessionID {
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue(MCP.ProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")
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
    var config = ProxyConfig(
        listenHost: "127.0.0.1",
        listenPort: 0,
        upstreamCommand: "xcrun",
        upstreamArgs: ["mcpbridge"],
        upstreamSessionID: nil,
        maxBodyBytes: 1_048_576,
        requestTimeout: requestTimeout
    )
    config.prewarmToolsList = false
    return config
}

private func addEmbeddedHTTPHandler(
    to channel: EmbeddedChannel,
    config: ProxyConfig,
    sessionManager: any RuntimeCoordinating
) throws {
    let handler = HTTPHandler(
        config: config,
        sessionManager: sessionManager,
        usesSynchronousLocalResolution: true
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
    head.headers.add(name: "Accept", value: "application/json, text/event-stream")
    head.headers.add(name: "Content-Type", value: "application/json")
    if let sessionID {
        head.headers.add(name: "Mcp-Session-Id", value: sessionID)
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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

private func jsonObject(from string: String) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: Data(string.utf8), options: []) as? [String: Any]
    )
}

private func drainInitialToolsCatalogWarmupIfNeeded(
    server: TestHTTPServer,
    upstream: ControlledUpstreamClient
) async {
    _ = server
    await upstream.clearRecordedRequests()
}
