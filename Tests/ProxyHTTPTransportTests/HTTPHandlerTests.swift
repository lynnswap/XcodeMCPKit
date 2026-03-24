import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOHTTP1
import Testing
import ProxyCore
import ProxyRuntime
import ProxyFeatureXcode
import XcodeMCPTestSupport

@testable import ProxyHTTPTransport

@Suite(.serialized)
struct HTTPHandlerTests {
    @Test func httpHealthCheck() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/health")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.body == "ok")
    }

    @Test func httpDebugUpstreamsReturnsSnapshot() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/debug/upstreams")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "application/json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ProxyDebugSnapshot.self, from: Data(response.body.utf8))
        #expect(snapshot.proxyInitialized == false)
        #expect(snapshot.upstreams.count == 1)
        #expect(snapshot.upstreams[0].upstreamIndex == 0)
        #expect(snapshot.upstreams[0].lastProtocolViolationPreview == nil)
        #expect(snapshot.upstreams[0].lastProtocolViolationPreviewHex == nil)
        #expect(snapshot.upstreams[0].lastProtocolViolationLeadingByteHex == nil)
    }

    @Test func httpDebugUpstreamsCanIncludeSensitivePayloadsOnExplicitOptIn() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/debug/upstreams?includeSensitive=1"
        )
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ProxyDebugSnapshot.self, from: Data(response.body.utf8))
        #expect(snapshot.upstreams[0].lastProtocolViolationPreview == "raw-preview")
        #expect(snapshot.upstreams[0].lastProtocolViolationPreviewHex == "61 62")
        #expect(snapshot.upstreams[0].lastProtocolViolationLeadingByteHex == "61")
    }

    @Test func httpDebugUpstreamsReturnsNotFoundWhenListenerIsNotLoopback() async throws {
        var config = makeConfig()
        config.listenHost = "0.0.0.0"

        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/debug/upstreams")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .notFound)
        #expect(response.body == "not found")
    }

    @Test func httpDebugResetResetsRuntimeOnLoopback() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        sessionManager.setCachedToolsListResult(.object(["tools": .array([])]))
        _ = sessionManager.session(id: "debug-reset-session")
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/debug/reset")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .accepted)
        #expect(response.body == "reset scheduled")
        #expect(sessionManager.hasSession(id: "debug-reset-session") == false)
        #expect(sessionManager.cachedToolsListResult() == nil)
    }

    @Test func httpDebugResetReturnsNotFoundWhenListenerIsNotLoopback() async throws {
        var config = makeConfig()
        config.listenHost = "0.0.0.0"

        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/debug/reset")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .notFound)
        #expect(response.body == "not found")
    }

    @Test func httpDebugUpstreamsIncludesActiveRefreshCodeIssuesState() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot).appendingPathComponent("A.swift")
        try "".write(to: target, atomically: true, encoding: .utf8)
        let firstSent = SyncSignal()

        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                switch toolName {
                case "XcodeListWindows":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text:
                                "{\"message\":\"* tabIdentifier: windowtab-debug-state, workspacePath: \(temporaryRoot)\"}"
                        )
                    )
                case "XcodeListNavigatorIssues":
                    firstSent.signal()
                    return .manual(
                        try makeToolResultResponse(
                            id: originalID,
                            result: [
                                "content": [[
                                    "type": "text",
                                    "text": "{\"issues\":[{\"path\":\"\(target.path)\",\"message\":\"warn\",\"line\":1,\"severity\":\"warning\"}],\"totalFound\":1,\"truncated\":false}"
                                ]],
                                "structuredContent": [
                                    "issues": [[
                                        "path": target.path,
                                        "message": "warn",
                                        "line": 1,
                                        "severity": "warning",
                                    ]],
                                    "totalFound": 1,
                                    "truncated": false,
                                ],
                            ]
                        )
                    )
                default:
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "unexpected tool"
                        )
                    )
                }
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let refreshTask = Task<Void, Error> {
                _ = try await postHTTPJSON(
                    url: server.url,
                    sessionID: "session-debug-state",
                    payload: toolsCallPayload(
                        id: 34,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-debug-state",
                            "filePath": "A.swift",
                        ]
                    )
                )
            }

            try await firstSent.wait(description: "waiting for navigator issues request to start")

            let (httpResponse, data) = try await getHTTPData(url: makeDebugSnapshotURL(from: server.url))
            #expect(httpResponse.statusCode == 200)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(HTTPDebugSnapshot.self, from: data)
            let refreshSnapshot = try #require(snapshot.refreshCodeIssues)
            #expect(refreshSnapshot.queue.activeRequestCount == 1)
            #expect(refreshSnapshot.activeRequests.count == 1)
            #expect(refreshSnapshot.activeRequests.first?.queueKey == "windowtab-debug-state")
            #expect(refreshSnapshot.activeRequests.first?.step == "proxy.list_navigator_issues")
            #expect(refreshSnapshot.activeRequests.first?.state == "running")

            sessionManager.deliverNextPendingResponse()
            _ = try await refreshTask.value

            let (completedResponse, completedData) = try await getHTTPData(
                url: makeDebugSnapshotURL(from: server.url)
            )
            #expect(completedResponse.statusCode == 200)
            let completedSnapshot = try decoder.decode(HTTPDebugSnapshot.self, from: completedData)
            let completedRefreshSnapshot = try #require(completedSnapshot.refreshCodeIssues)
            #expect(completedRefreshSnapshot.queue.activeRequestCount == 0)
            #expect(completedRefreshSnapshot.recentCompletedRequests.first?.finalState == "completed")
            #expect(completedRefreshSnapshot.recentCompletedRequests.first?.outcome == "success")
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpSSERequiresAcceptHeader() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/mcp")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .notAcceptable)
        #expect(response.body.contains("text/event-stream"))
    }

    @Test func httpPostRejectsUnknownAccept() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "text/plain")
        head.headers.add(name: "Content-Type", value: "application/json")
        var body = channel.allocator.buffer(capacity: 2)
        body.writeString("{}")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .notAcceptable)
    }

    @Test func httpPostRejectsNonJSONContentType() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "text/plain")
        var body = channel.allocator.buffer(capacity: 2)
        body.writeString("{}")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .unsupportedMediaType)
    }

    @Test func httpPostRejectsLargeBody() async throws {
        let config = makeConfig(maxBodyBytes: 1)
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        var body = channel.allocator.buffer(capacity: 2)
        body.writeString("{}")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .payloadTooLarge)
    }

    @Test func httpInitializeCreatesSessionAndReturnsResponse() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "xcode-mcp-proxy-tests",
                    "version": "0.0",
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Mcp-Session-Id")?.isEmpty == false)

        let responseObject =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let responseID = (responseObject?["id"] as? NSNumber)?.intValue
        #expect(responseID == 1)
        #expect(sessionManager.chooseUpstreamIndexCallCount() == 1)
        #expect(sessionManager.requestSuccessNotificationCount() == 0)
    }

    @Test func httpInitializePrefersJSONWhenClientAcceptsJSONAndEventStream() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "xcode-mcp-proxy-tests",
                    "version": "0.0",
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "application/json")
    }

    @Test func httpInitializeRequiresID() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "xcode-mcp-proxy-tests",
                    "version": "0.0",
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32600)
        #expect((error?["message"] as? String) == "missing id")
    }

    @Test func httpSingleElementBatchErrorReturnsArrayShape() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": 42,
                "method": "tools/list",
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "application/json")
        let array = try #require(
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
                as? [[String: Any]])
        #expect(array.count == 1)
        #expect((array[0]["id"] as? NSNumber)?.intValue == 42)
        let error = array[0]["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32000)
        #expect((error?["message"] as? String) == "expected initialize request")
    }

    @Test func httpTimeoutReturnsMCPErrorAndCleansMapping() async throws {
        let config = makeConfig(requestTimeout: 0.1)
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])
        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        let initResponse = try collectResponse(from: channel)
        let sessionID = try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2001,
            "method": "tools/list",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        #expect(sessionManager.mappedUpstreamRequestCount() == 1)
        advanceEventLoopTime(on: channel, by: .milliseconds(300))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "application/json")
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32000)
        #expect((error?["message"] as? String) == "upstream timeout")
        #expect(sessionManager.mappedUpstreamRequestCount() == 0)
    }

    @Test func httpTimeoutReturnsSSEErrorWhenEventStreamIsPreferred() async throws {
        let config = makeConfig(requestTimeout: 0.1)
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])
        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        let initResponse = try collectResponse(from: channel)
        let sessionID = try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2002,
            "method": "tools/list",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        advanceEventLoopTime(on: channel, by: .milliseconds(300))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "text/event-stream")
        #expect(response.body.contains("data:"))
        #expect(response.body.contains("\"code\":-32000"))
    }

    @Test func httpBatchTimeoutCountsHealthPenaltyOnceAndCleansAllMappings() async throws {
        let config = makeConfig(requestTimeout: 0.1)
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])
        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        let initResponse = try collectResponse(from: channel)
        let sessionID = try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))

        let payload: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": 2101,
                "method": "tools/list",
            ],
            [
                "jsonrpc": "2.0",
                "id": 2102,
                "method": "tools/list",
            ],
            [
                "jsonrpc": "2.0",
                "id": 2103,
                "method": "tools/list",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        #expect(sessionManager.mappedUpstreamRequestCount() == 3)
        advanceEventLoopTime(on: channel, by: .milliseconds(300))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let array = try #require(
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
                as? [[String: Any]])
        #expect(array.count == 3)
        for object in array {
            let error = object["error"] as? [String: Any]
            #expect((error?["code"] as? NSNumber)?.intValue == -32000)
            #expect((error?["message"] as? String) == "upstream timeout")
        }
        #expect(sessionManager.requestTimeoutNotificationCount() == 1)
        #expect(sessionManager.mappedUpstreamRequestCount() == 0)
    }

    @Test func httpReturnsUpstreamUnavailableWhenNoHealthyUpstreamExists() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])
        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        let initResponse = try collectResponse(from: channel)
        let sessionID = try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))

        sessionManager.setAvailableUpstreamIndex(nil)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3001,
            "method": "tools/list",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32001)
        #expect((error?["message"] as? String) == "upstream unavailable")
    }

    @Test func httpMalformedJSONReturnsParseErrorBeforeUpstreamUnavailable() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])
        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        let initResponse = try collectResponse(from: channel)
        let sessionID = try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))

        sessionManager.setAvailableUpstreamIndex(nil)
        let chooseCountBeforeMalformedRequest = sessionManager.chooseUpstreamIndexCallCount()

        var malformedHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        malformedHead.headers.add(name: "Accept", value: "application/json")
        malformedHead.headers.add(name: "Content-Type", value: "application/json")
        malformedHead.headers.add(name: "Mcp-Session-Id", value: sessionID)
        var malformedBody = channel.allocator.buffer(capacity: 20)
        malformedBody.writeString("{\"jsonrpc\":\"2.0\",")
        try channel.writeInbound(HTTPServerRequestPart.head(malformedHead))
        try channel.writeInbound(HTTPServerRequestPart.body(malformedBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32700)
        #expect((error?["message"] as? String) == "invalid json")
        #expect(sessionManager.chooseUpstreamIndexCallCount() == chooseCountBeforeMalformedRequest)
    }

    @Test func httpOverloadedErrorResponseDoesNotMarkRequestSuccess() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config) { method, originalID in
            #expect(method == "tools/list")
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalID.value.foundationObject,
                "error": [
                    "code": -32002,
                    "message": "upstream overloaded",
                ],
            ]
            return try JSONSerialization.data(withJSONObject: response, options: [])
        }
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])
        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        let initResponse = try collectResponse(from: channel)
        let sessionID = try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3101,
            "method": "tools/list",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32002)
        #expect((error?["message"] as? String) == "upstream overloaded")
        #expect(sessionManager.requestSuccessNotificationCount() == 0)
    }

    @Test func httpSessionHeaderAutoCreatesSession() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 99,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: "missing-session")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Mcp-Session-Id") == "missing-session")
        #expect(response.body.contains("\"result\""))
    }

    @Test func httpSSEHandshakeSucceedsWithSession() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        _ = sessionManager.session(id: "session-1")
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/mcp")
        head.headers.add(name: "Accept", value: "text/event-stream")
        head.headers.add(name: "Mcp-Session-Id", value: "session-1")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "text/event-stream")
        #expect(response.body.contains(": ok"))
    }

    @Test func httpToolsListUsesCachedResultWhenAvailable() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        sessionManager.setCachedToolsListResult(
            JSONValue(any: ["tools": [Any]()])!
        )
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        // Initialize to establish a session id.
        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let initResponse = try collectResponse(from: channel)
        let sessionID = initResponse.head.headers.first(name: "Mcp-Session-Id")
        #expect(sessionID?.isEmpty == false)

        // tools/list should be served from cache and not forwarded upstream.
        let toolsPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ]
        let toolsData = try JSONSerialization.data(withJSONObject: toolsPayload, options: [])

        var toolsHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        toolsHead.headers.add(name: "Accept", value: "application/json")
        toolsHead.headers.add(name: "Content-Type", value: "application/json")
        toolsHead.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        var toolsBody = channel.allocator.buffer(capacity: toolsData.count)
        toolsBody.writeBytes(toolsData)
        try channel.writeInbound(HTTPServerRequestPart.head(toolsHead))
        try channel.writeInbound(HTTPServerRequestPart.body(toolsBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let toolsResponse = try collectResponse(from: channel)
        #expect(toolsResponse.head.status == .ok)

        let responseObject =
            try JSONSerialization.jsonObject(with: Data(toolsResponse.body.utf8), options: [])
            as? [String: Any]
        let responseID = (responseObject?["id"] as? NSNumber)?.intValue
        #expect(responseID == 2)

        let result = responseObject?["result"] as? [String: Any]
        let tools = result?["tools"] as? [Any]
        #expect(tools?.count == 0)

        #expect(sessionManager.sentUpstreamCount() == 0)
        #expect(sessionManager.assignedUpstreamIDCount() == 0)
        #expect(sessionManager.chooseUpstreamIndexCallCount() == 1)
        #expect(sessionManager.refreshToolsListCallCount() == 0)
    }

    @Test func httpToolsListUsesCachedResultWhenParamsArePresent() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        sessionManager.setCachedToolsListResult(
            JSONValue(any: ["tools": [Any]()])!
        )
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        // Initialize to establish a session id.
        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let initResponse = try collectResponse(from: channel)
        let sessionID = initResponse.head.headers.first(name: "Mcp-Session-Id")
        #expect(sessionID?.isEmpty == false)

        // tools/list with params should still be served from cache (Codex startup stability).
        let toolsPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [
                "cursor": "cursor-1"
            ],
        ]
        let toolsData = try JSONSerialization.data(withJSONObject: toolsPayload, options: [])

        var toolsHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        toolsHead.headers.add(name: "Accept", value: "application/json")
        toolsHead.headers.add(name: "Content-Type", value: "application/json")
        toolsHead.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        var toolsBody = channel.allocator.buffer(capacity: toolsData.count)
        toolsBody.writeBytes(toolsData)
        try channel.writeInbound(HTTPServerRequestPart.head(toolsHead))
        try channel.writeInbound(HTTPServerRequestPart.body(toolsBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let toolsResponse = try collectResponse(from: channel)
        #expect(toolsResponse.head.status == .ok)

        let responseObject =
            try JSONSerialization.jsonObject(with: Data(toolsResponse.body.utf8), options: [])
            as? [String: Any]
        let responseID = (responseObject?["id"] as? NSNumber)?.intValue
        #expect(responseID == 2)

        let result = responseObject?["result"] as? [String: Any]
        let tools = result?["tools"] as? [Any]
        #expect(tools?.count == 0)

        #expect(sessionManager.sentUpstreamCount() == 0)
        #expect(sessionManager.assignedUpstreamIDCount() == 0)
        #expect(sessionManager.chooseUpstreamIndexCallCount() == 1)
        #expect(sessionManager.refreshToolsListCallCount() == 0)
    }

    @Test func httpToolsListCachesResultOnMissWhenParamsArePresent() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config) { method, originalID in
            #expect(method == "tools/list")
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalID.value.foundationObject,
                "result": [
                    "tools": [Any]()
                ],
            ]
            return try JSONSerialization.data(withJSONObject: response, options: [])
        }
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        // Initialize to establish a session id.
        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let initResponse = try collectResponse(from: channel)
        let sessionID = initResponse.head.headers.first(name: "Mcp-Session-Id")
        #expect(sessionID?.isEmpty == false)

        // tools/list should be forwarded on the first miss, then cached even with params.
        let toolsPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [
                "cursor": "cursor-1"
            ],
        ]
        let toolsData = try JSONSerialization.data(withJSONObject: toolsPayload, options: [])

        var toolsHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        toolsHead.headers.add(name: "Accept", value: "application/json")
        toolsHead.headers.add(name: "Content-Type", value: "application/json")
        toolsHead.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        var toolsBody = channel.allocator.buffer(capacity: toolsData.count)
        toolsBody.writeBytes(toolsData)
        try channel.writeInbound(HTTPServerRequestPart.head(toolsHead))
        try channel.writeInbound(HTTPServerRequestPart.body(toolsBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let toolsResponse = try collectResponse(from: channel)
        #expect(toolsResponse.head.status == .ok)
        #expect(sessionManager.cachedToolsListResult() != nil)
        #expect(sessionManager.sentUpstreamCount() == 1)

        // Second call should be served from cache (no upstream send).
        let toolsPayload2: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/list",
            "params": [
                "cursor": "cursor-2"
            ],
        ]
        let toolsData2 = try JSONSerialization.data(withJSONObject: toolsPayload2, options: [])
        var toolsHead2 = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        toolsHead2.headers.add(name: "Accept", value: "application/json")
        toolsHead2.headers.add(name: "Content-Type", value: "application/json")
        toolsHead2.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        var toolsBody2 = channel.allocator.buffer(capacity: toolsData2.count)
        toolsBody2.writeBytes(toolsData2)
        try channel.writeInbound(HTTPServerRequestPart.head(toolsHead2))
        try channel.writeInbound(HTTPServerRequestPart.body(toolsBody2))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let toolsResponse2 = try collectResponse(from: channel)
        #expect(toolsResponse2.head.status == .ok)
        #expect(sessionManager.sentUpstreamCount() == 1)
    }

    @Test func httpToolsListRewritesRefreshDescriptionOnForwardedMiss() async throws {
        var config = makeConfig()
        config.refreshCodeIssuesMode = .proxy
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config) { method, originalID in
            #expect(method == "tools/list")
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalID.value.foundationObject,
                "result": [
                    "tools": [
                        [
                            "name": "XcodeRefreshCodeIssuesInFile",
                            "description": "original description",
                            "outputSchema": [
                                "type": "object",
                                "required": ["filePath", "diagnosticsCount", "content", "success"],
                                "properties": [
                                    "filePath": ["type": "string"],
                                    "diagnosticsCount": ["type": "integer"],
                                    "content": ["type": "string"],
                                    "success": ["type": "boolean"],
                                ],
                            ],
                        ]
                    ]
                ],
            ]
            return try JSONSerialization.data(withJSONObject: response, options: [])
        }
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let initResponse = try collectResponse(from: channel)
        let sessionID = try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))

        let toolsPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ]
        let toolsData = try JSONSerialization.data(withJSONObject: toolsPayload, options: [])

        var toolsHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        toolsHead.headers.add(name: "Accept", value: "application/json")
        toolsHead.headers.add(name: "Content-Type", value: "application/json")
        toolsHead.headers.add(name: "Mcp-Session-Id", value: sessionID)
        var toolsBody = channel.allocator.buffer(capacity: toolsData.count)
        toolsBody.writeBytes(toolsData)
        try channel.writeInbound(HTTPServerRequestPart.head(toolsHead))
        try channel.writeInbound(HTTPServerRequestPart.body(toolsBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let result = object?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        let description = tools?.first?["description"] as? String
        let outputSchema = tools?.first?["outputSchema"] as? [String: Any]
        let required = outputSchema?["required"] as? [String]
        #expect(description?.contains("avoid switching Spaces") == true)
        #expect(description?.contains("--refresh-code-issues-mode upstream") == true)
        #expect(required == ["issues", "truncated", "totalFound"])
    }

    @Test func httpToolsListRewritesRefreshDescriptionOnCachedResponse() async throws {
        var config = makeConfig()
        config.refreshCodeIssuesMode = .upstream
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        sessionManager.setCachedToolsListResult(
            JSONValue(any: [
                "tools": [
                    [
                        "name": "XcodeRefreshCodeIssuesInFile",
                        "description": "original description",
                        "outputSchema": [
                            "type": "object",
                            "required": ["filePath", "diagnosticsCount", "content", "success"],
                            "properties": [
                                "filePath": ["type": "string"],
                                "diagnosticsCount": ["type": "integer"],
                                "content": ["type": "string"],
                                "success": ["type": "boolean"],
                            ],
                        ],
                    ]
                ]
            ])!
        )
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let initResponse = try collectResponse(from: channel)
        let sessionID = try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))

        let toolsPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ]
        let toolsData = try JSONSerialization.data(withJSONObject: toolsPayload, options: [])

        var toolsHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        toolsHead.headers.add(name: "Accept", value: "application/json")
        toolsHead.headers.add(name: "Content-Type", value: "application/json")
        toolsHead.headers.add(name: "Mcp-Session-Id", value: sessionID)
        var toolsBody = channel.allocator.buffer(capacity: toolsData.count)
        toolsBody.writeBytes(toolsData)
        try channel.writeInbound(HTTPServerRequestPart.head(toolsHead))
        try channel.writeInbound(HTTPServerRequestPart.body(toolsBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let result = object?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        let description = tools?.first?["description"] as? String
        let outputSchema = tools?.first?["outputSchema"] as? [String: Any]
        let required = outputSchema?["required"] as? [String]
        #expect(description?.contains("native live diagnostics path") == true)
        #expect(required == ["filePath", "diagnosticsCount", "content", "success"])
    }

    @Test func httpToolsListPrefersJSONWhenClientAcceptsJSONAndEventStream() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        sessionManager.setCachedToolsListResult(
            JSONValue(any: ["tools": [Any]()])!
        )
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        // Initialize to establish a session id.
        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let initResponse = try collectResponse(from: channel)
        let sessionID = initResponse.head.headers.first(name: "Mcp-Session-Id")
        #expect(sessionID?.isEmpty == false)

        let toolsPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ]
        let toolsData = try JSONSerialization.data(withJSONObject: toolsPayload, options: [])

        var toolsHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        toolsHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
        toolsHead.headers.add(name: "Content-Type", value: "application/json")
        toolsHead.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        var toolsBody = channel.allocator.buffer(capacity: toolsData.count)
        toolsBody.writeBytes(toolsData)
        try channel.writeInbound(HTTPServerRequestPart.head(toolsHead))
        try channel.writeInbound(HTTPServerRequestPart.body(toolsBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let toolsResponse = try collectResponse(from: channel)
        #expect(toolsResponse.head.status == .ok)
        #expect(toolsResponse.head.headers.first(name: "Content-Type") == "application/json")
    }

    @Test func httpResourcesListReturnsEmptyArray() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/list",
            "params": [String: Any](),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: "session-1")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "application/json")

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let responseID = (object?["id"] as? NSNumber)?.intValue
        #expect(responseID == 1)
        let result = object?["result"] as? [String: Any]
        let resources = result?["resources"] as? [Any]
        #expect(resources?.isEmpty == true)
    }

    @Test func httpResourceTemplatesListReturnsEmptyArray() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/templates/list",
            "params": [String: Any](),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: "session-1")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "application/json")

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let responseID = (object?["id"] as? NSNumber)?.intValue
        #expect(responseID == 1)
        let result = object?["result"] as? [String: Any]
        let templates = result?["resourceTemplates"] as? [Any]
        #expect(templates?.isEmpty == true)
    }

    @Test func httpResourcesListRewritesMethodNotFoundErrorToEmptyArrayAfterInit() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config) { method, originalID in
            #expect(method == "resources/list")
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalID.value.foundationObject,
                "error": [
                    "code": -32601,
                    "message": "Method not found",
                ],
            ]
            return try JSONSerialization.data(withJSONObject: response, options: [])
        }
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        // Initialize to establish a session id.
        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let initResponse = try collectResponse(from: channel)
        let sessionID = initResponse.head.headers.first(name: "Mcp-Session-Id")
        #expect(sessionID?.isEmpty == false)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 123,
            "method": "resources/list",
            "params": [String: Any](),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        #expect(object?["error"] == nil)
        let result = object?["result"] as? [String: Any]
        let resources = result?["resources"] as? [Any]
        #expect(resources?.isEmpty == true)
    }

    @Test func httpResourcesListRewritesNonStandardErrorResultToEmptyArrayAfterInit() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config) { method, originalID in
            #expect(method == "resources/list")
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalID.value.foundationObject,
                "result": [
                    "content": [
                        [
                            "type": "text",
                            "text": "The message contained an unknown method 'resources/list'",
                        ]
                    ],
                    "isError": true,
                ],
            ]
            return try JSONSerialization.data(withJSONObject: response, options: [])
        }
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        // Initialize to establish a session id.
        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let initResponse = try collectResponse(from: channel)
        let sessionID = initResponse.head.headers.first(name: "Mcp-Session-Id")
        #expect(sessionID?.isEmpty == false)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 456,
            "method": "resources/list",
            "params": [String: Any](),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        #expect(object?["error"] == nil)
        let result = object?["result"] as? [String: Any]
        let resources = result?["resources"] as? [Any]
        #expect(resources?.isEmpty == true)
    }

    @Test func httpResourcesListDoesNotMaskNonMethodNotFoundErrorsAfterInit() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config) { method, originalID in
            #expect(method == "resources/list")
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalID.value.foundationObject,
                "error": [
                    "code": -32000,
                    "message": "permission denied",
                ],
            ]
            return try JSONSerialization.data(withJSONObject: response, options: [])
        }
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        // Initialize to establish a session id.
        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let initResponse = try collectResponse(from: channel)
        let sessionID = initResponse.head.headers.first(name: "Mcp-Session-Id")
        #expect(sessionID?.isEmpty == false)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 123,
            "method": "resources/list",
            "params": [String: Any](),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32000)
        #expect(object?["result"] == nil)
    }

    @Test func httpResourcesListDoesNotMaskNonMethodNotFoundErrorsWhenNullResultIsPresentAfterInit()
        async throws
    {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config) { method, originalID in
            #expect(method == "resources/list")
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalID.value.foundationObject,
                "result": NSNull(),
                "error": [
                    "code": -32000,
                    "message": "permission denied",
                ],
            ]
            return try JSONSerialization.data(withJSONObject: response, options: [])
        }
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        // Initialize to establish a session id.
        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let initResponse = try collectResponse(from: channel)
        let sessionID = initResponse.head.headers.first(name: "Mcp-Session-Id")
        #expect(sessionID?.isEmpty == false)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 124,
            "method": "resources/list",
            "params": [String: Any](),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32000)
        #expect(object?["result"] is NSNull)
    }

    @Test func httpResourcesListDoesNotRewriteNonStandardErrorResultWithoutUnknownMethodAfterInit()
        async throws
    {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config) { method, originalID in
            #expect(method == "resources/list")
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalID.value.foundationObject,
                "result": [
                    "content": [
                        [
                            "type": "text",
                            "text": "permission denied",
                        ]
                    ],
                    "isError": true,
                ],
            ]
            return try JSONSerialization.data(withJSONObject: response, options: [])
        }
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        // Initialize to establish a session id.
        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any]()
            ],
        ]
        let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])

        var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        initHead.headers.add(name: "Accept", value: "application/json")
        initHead.headers.add(name: "Content-Type", value: "application/json")
        var initBody = channel.allocator.buffer(capacity: initData.count)
        initBody.writeBytes(initData)
        try channel.writeInbound(HTTPServerRequestPart.head(initHead))
        try channel.writeInbound(HTTPServerRequestPart.body(initBody))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let initResponse = try collectResponse(from: channel)
        let sessionID = initResponse.head.headers.first(name: "Mcp-Session-Id")
        #expect(sessionID?.isEmpty == false)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 457,
            "method": "resources/list",
            "params": [String: Any](),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)

        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        #expect(object?["error"] == nil)
        let result = object?["result"] as? [String: Any]
        #expect((result?["isError"] as? Bool) == true)
        #expect(result?["resources"] == nil)
    }

    @Test func httpRefreshCodeIssuesUsesNavigatorIssuesProxyByDefault() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("App/Sources/App.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let workspacePath = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("SampleProject.xcworkspace").path
        try FileManager.default.createDirectory(
            atPath: workspacePath,
            withIntermediateDirectories: true
        )

        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                switch toolName {
                case "XcodeListWindows":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text:
                                "{\"message\":\"* tabIdentifier: windowtab-proxy, workspacePath: \(workspacePath)\"}"
                        )
                    )
                case "XcodeListNavigatorIssues":
                    return .immediate(
                        try makeToolResultResponse(
                            id: originalID,
                            result: [
                                "content": [
                                    [
                                        "type": "text",
                                        "text": "{\"issues\":[{\"path\":\"\(target.path)\",\"message\":\"target warning\",\"line\":12,\"severity\":\"warning\"},{\"path\":\"\(temporaryRoot)/Other.swift\",\"message\":\"other warning\",\"line\":99,\"severity\":\"warning\"}],\"totalFound\":2,\"truncated\":false}"
                                    ]
                                ],
                                "structuredContent": [
                                    "issues": [
                                        [
                                            "path": target.path,
                                            "message": "target warning",
                                            "line": 12,
                                            "severity": "warning",
                                        ],
                                        [
                                            "path": "\(temporaryRoot)/Other.swift",
                                            "message": "other warning",
                                            "line": 99,
                                            "severity": "warning",
                                        ],
                                    ],
                                    "totalFound": 2,
                                    "truncated": false,
                                ],
                            ]
                        )
                    )
                default:
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "unexpected tool"
                        )
                    )
                }
            }
        )
        sessionManager.setAvailableUpstreamIndices([1, 0, 0])
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-proxy",
                payload: toolsCallPayload(
                    id: 30,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-proxy",
                        "filePath": "App/Sources/App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let structuredContent = result?["structuredContent"] as? [String: Any]
            let issues = structuredContent?["issues"] as? [[String: Any]]
            #expect((structuredContent?["totalFound"] as? NSNumber)?.intValue == 1)
            #expect(issues?.count == 1)
            #expect(issues?.first?["path"] as? String == target.path)
            #expect(issues?.first?["message"] as? String == "target warning")
            #expect(sessionManager.sentToolNames() == [
                "XcodeListWindows",
                "XcodeListNavigatorIssues",
            ])
            #expect(sessionManager.chooseUpstreamShouldPinValues().isEmpty)
            #expect(Set(sessionManager.sentToolRequests()) == Set([
                "XcodeListWindows@0",
                "XcodeListNavigatorIssues@0",
            ]) || Set(sessionManager.sentToolRequests()) == Set([
                "XcodeListWindows@1",
                "XcodeListNavigatorIssues@1",
            ]))
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesFallsBackToUpstreamWhenWindowLookupFailsAfterPreviousSuccess() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("App/Sources/App.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let workspacePath = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("SampleProject.xcworkspace").path
        try FileManager.default.createDirectory(
            atPath: workspacePath,
            withIntermediateDirectories: true
        )

        let windowLookups = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                switch toolName {
                case "XcodeListWindows":
                    let lookupCount = windowLookups.withLockedValue { value in
                        value += 1
                        return value
                    }
                    if lookupCount == 1 {
                        return .immediate(
                            try makeToolSuccessResponse(
                                id: originalID,
                                text:
                                    "{\"message\":\"* tabIdentifier: windowtab-window-lookup-fallback, workspacePath: \(workspacePath)\"}"
                            )
                        )
                    }
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "windows unavailable"
                        )
                    )
                case "XcodeListNavigatorIssues":
                    return .immediate(
                        try makeToolResultResponse(
                            id: originalID,
                            result: [
                                "content": [
                                    [
                                        "type": "text",
                                        "text": "{\"issues\":[{\"path\":\"\(target.path)\",\"message\":\"target warning\",\"line\":12,\"severity\":\"warning\"}],\"totalFound\":1,\"truncated\":false}"
                                    ]
                                ],
                                "structuredContent": [
                                    "issues": [
                                        [
                                            "path": target.path,
                                            "message": "target warning",
                                            "line": 12,
                                            "severity": "warning",
                                        ]
                                    ],
                                    "totalFound": 1,
                                    "truncated": false,
                                ],
                            ]
                        )
                    )
                case "XcodeRefreshCodeIssuesInFile":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text: "upstream-after-window-lookup-failure"
                        )
                    )
                default:
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "unexpected tool"
                        )
                    )
                }
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (firstResponse, firstBody) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-window-lookup-fallback",
                payload: toolsCallPayload(
                    id: 30,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-window-lookup-fallback",
                        "filePath": "App/Sources/App.swift",
                    ]
                )
            )

            #expect(firstResponse.statusCode == 200)
            let firstResult = firstBody["result"] as? [String: Any]
            let firstStructuredContent = firstResult?["structuredContent"] as? [String: Any]
            #expect((firstStructuredContent?["totalFound"] as? NSNumber)?.intValue == 1)

            let (secondResponse, secondBody) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-window-lookup-fallback",
                payload: toolsCallPayload(
                    id: 31,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-window-lookup-fallback",
                        "filePath": "App/Sources/App.swift",
                    ]
                )
            )

            #expect(secondResponse.statusCode == 200)
            let secondResult = secondBody["result"] as? [String: Any]
            let secondContent = secondResult?["content"] as? [[String: Any]]
            #expect(secondContent?.first?["text"] as? String == "upstream-after-window-lookup-failure")
            #expect(sessionManager.sentToolNames() == [
                "XcodeListWindows",
                "XcodeListNavigatorIssues",
                "XcodeListWindows",
                "XcodeRefreshCodeIssuesInFile",
            ])
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesFallsBackToUpstreamWhenResolverCannotFindTarget() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let workspacePath = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("SampleProject.xcworkspace").path
        try FileManager.default.createDirectory(
            atPath: workspacePath,
            withIntermediateDirectories: true
        )

        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                switch toolName {
                case "XcodeListWindows":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text:
                                "{\"message\":\"* tabIdentifier: windowtab-fallback, workspacePath: \(workspacePath)\"}"
                        )
                    )
                case "XcodeRefreshCodeIssuesInFile":
                    return .immediate(
                        try makeToolSuccessResponse(id: originalID, text: "upstream-result")
                    )
                default:
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "unexpected tool"
                        )
                    )
                }
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-fallback-resolver",
                payload: toolsCallPayload(
                    id: 31,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-fallback",
                        "filePath": "Missing.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "upstream-result")
            #expect(sessionManager.sentToolNames() == [
                "XcodeListWindows",
                "XcodeRefreshCodeIssuesInFile",
            ])
            #expect(sessionManager.chooseUpstreamShouldPinValues().isEmpty)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesFallsBackToUpstreamWhenNavigatorIssuesFails() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("App/Sources/App.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let workspacePath = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("SampleProject.xcworkspace").path
        try FileManager.default.createDirectory(
            atPath: workspacePath,
            withIntermediateDirectories: true
        )

        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                switch toolName {
                case "XcodeListWindows":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text:
                                "{\"message\":\"* tabIdentifier: windowtab-navigator-fallback, workspacePath: \(workspacePath)\"}"
                        )
                    )
                case "XcodeListNavigatorIssues":
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "navigator failed"
                        )
                    )
                case "XcodeRefreshCodeIssuesInFile":
                    return .immediate(
                        try makeToolSuccessResponse(id: originalID, text: "upstream-after-navigator-failure")
                    )
                default:
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "unexpected tool"
                        )
                    )
                }
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-navigator-fallback",
                payload: toolsCallPayload(
                    id: 32,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-navigator-fallback",
                        "filePath": "App/Sources/App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "upstream-after-navigator-failure")
            #expect(sessionManager.sentToolNames() == [
                "XcodeListWindows",
                "XcodeListNavigatorIssues",
                "XcodeRefreshCodeIssuesInFile",
            ])
            #expect(sessionManager.chooseUpstreamShouldPinValues().isEmpty)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func refreshWorkflowFallsBackToUpstreamWhenNavigatorIssuesTimesOut() async throws {
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("App/Sources/App.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: target, atomically: true, encoding: .utf8)

        let workspacePath = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("SampleProject.xcworkspace").path
        try FileManager.default.createDirectory(
            atPath: workspacePath,
            withIntermediateDirectories: true
        )

        let config = makeConfig(requestTimeout: 1)
        let coordinator = RefreshCodeIssuesCoordinator(queueWaitTimeout: 1)
        let debugState = RefreshCodeIssuesDebugState(
            maxPendingPerKey: coordinator.maxPendingPerKey,
            maxPendingTotal: coordinator.maxPendingTotal,
            queueWaitTimeoutSeconds: coordinator.queueWaitTimeoutSeconds
        )
        let workflow = RefreshCodeIssuesWorkflow(
            mode: .proxy,
            requestTimeout: config.requestTimeout,
            coordinator: coordinator,
            targetResolver: RefreshCodeIssuesTargetResolver(),
            debugState: debugState,
            windowLookupTimeout: 0.2,
            navigatorIssuesTimeout: 0.05,
            logger: ProxyLogging.make("test.refresh")
        )
        let observedTimeouts = NIOLockedValueBox<[Int64]>([])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let requestID = RPCID(any: NSNumber(value: 33))!
        let requestPayload = toolsCallPayload(
            id: 33,
            name: "XcodeRefreshCodeIssuesInFile",
            arguments: [
                "tabIdentifier": "windowtab-navigator-timeout",
                "filePath": "App/Sources/App.swift",
            ]
        )
        let requestData = try JSONSerialization.data(withJSONObject: requestPayload, options: [])
        let upstreamFallbackData = try makeToolSuccessResponse(
            id: requestID,
            text: "upstream-after-navigator-timeout"
        )

        let result = await workflow.run(
            refreshRequest: RefreshCodeIssuesRequest(
                tabIdentifier: "windowtab-navigator-timeout",
                filePath: "App/Sources/App.swift"
            ),
            bodyData: requestData,
            sessionID: "session-navigator-timeout",
            requestIDs: [requestID],
            requestIsBatch: false,
            eventLoop: group.next(),
            windowsProvider: { _, _, _, _ in
                [
                    XcodeWindowInfo(
                        tabIdentifier: "windowtab-navigator-timeout",
                        workspacePath: workspacePath
                    )
                ]
            },
            internalUpstreamChooser: { _ in 0 },
            internalToolCaller: { name, _, _, _, _, requestTimeoutOverride in
                guard name == "XcodeListNavigatorIssues" else {
                    return .unavailable
                }
                observedTimeouts.withLockedValue { values in
                    values.append(requestTimeoutOverride?.nanoseconds ?? -1)
                }
                return .timeout
            },
            forwarder: { _, _, _, _, _, _ in
                .success(upstreamFallbackData)
            }
        )

        switch result {
        case .success(let responseData):
            let object = try #require(
                JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any]
            )
            let responseResult: [String: Any]? = object["result"] as? [String: Any]
            let content: [[String: Any]]? = responseResult?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "upstream-after-navigator-timeout")
        default:
            Issue.record("expected workflow to fall back to upstream after navigator timeout")
        }

        #expect(observedTimeouts.withLockedValue { $0.first } == 50_000_000)
    }

    @Test func httpRefreshCodeIssuesFallsBackToUpstreamWithUnlimitedTimeout() async throws {
        var config = makeConfig(requestTimeout: 0)
        config.refreshCodeIssuesMode = .proxy
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot).appendingPathComponent("App.swift")
        try "".write(to: target, atomically: true, encoding: .utf8)
        let workspacePath = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("SampleProject.xcworkspace").path
        try FileManager.default.createDirectory(
            atPath: workspacePath,
            withIntermediateDirectories: true
        )

        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                switch toolName {
                case "XcodeListWindows":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text:
                                "{\"message\":\"* tabIdentifier: windowtab-unlimited-timeout, workspacePath: \(workspacePath)\"}"
                        )
                    )
                case "XcodeListNavigatorIssues":
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "navigator failed"
                        )
                    )
                case "XcodeRefreshCodeIssuesInFile":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text: "upstream-after-unlimited-timeout-fallback"
                        )
                    )
                default:
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "unexpected tool"
                        )
                    )
                }
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-unlimited-timeout",
                payload: toolsCallPayload(
                    id: 35,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-unlimited-timeout",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "upstream-after-unlimited-timeout-fallback")
            #expect(sessionManager.sentToolNames() == [
                "XcodeListWindows",
                "XcodeListNavigatorIssues",
                "XcodeRefreshCodeIssuesInFile",
            ])
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesRetriesSourceEditorErrorFive() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let attempts = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                let attempt = attempts.withLockedValue { value in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text:
                                "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditor.SourceEditorCallableDiagnosticError error 5.)"
                        )
                    )
                }
                return .immediate(try makeToolSuccessResponse(id: originalID, text: "ok"))
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-retry",
                payload: toolsCallPayload(
                    id: 10,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-retry",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) != true)
            #expect(sessionManager.sentUpstreamCount() == 2)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesRetriesShortSourceEditorErrorFiveText() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let attempts = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                let attempt = attempts.withLockedValue { value in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text:
                                "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditorCallableDiagnosticError error 5.)"
                        )
                    )
                }
                return .immediate(try makeToolSuccessResponse(id: originalID, text: "ok"))
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-retry-short",
                payload: toolsCallPayload(
                    id: 13,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-retry-short",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) != true)
            #expect(sessionManager.sentUpstreamCount() == 2)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesDoesNotRetryNonRetryableToolError() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                return .immediate(
                    try makeToolErrorResponse(
                        id: originalID,
                        text: "permission denied"
                    )
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-no-retry",
                payload: toolsCallPayload(
                    id: 11,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-no-retry",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) == true)
            #expect(sessionManager.sentUpstreamCount() == 1)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpNonTargetToolsCallDoesNotUseRefreshRetryPath() async throws {
        let config = makeConfig(requestTimeout: 2)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                return .immediate(
                    try makeToolErrorResponse(
                        id: originalID,
                        text:
                            "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditor.SourceEditorCallableDiagnosticError error 5.)"
                    )
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-other-tool",
                payload: toolsCallPayload(
                    id: 12,
                    name: "XcodeListWindows",
                    arguments: [:]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) == true)
            #expect(sessionManager.sentUpstreamCount() == 1)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpToolCallAddsStructuredContentFromJSONStringWhenToolHasOutputSchema() async throws {
        let config = makeConfig(requestTimeout: 2)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "XcodeListWindows")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text:
                            "{\"message\":\"* tabIdentifier: windowtab1, workspacePath: /tmp/Sample.xcodeproj\\n\"}"
                    )
                )
            }
        )
        sessionManager.setCachedToolsListResult(
            JSONValue(any: [
                "tools": [[
                    "name": "XcodeListWindows",
                    "outputSchema": ["type": "object"],
                ]]
            ])!
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-structured-tool-call",
                payload: toolsCallPayload(
                    id: 14,
                    name: "XcodeListWindows",
                    arguments: [:]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let structuredContent = result?["structuredContent"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(structuredContent?["message"] as? String == "* tabIdentifier: windowtab1, workspacePath: /tmp/Sample.xcodeproj\n")
            #expect(content?.first?["text"] as? String == "{\"message\":\"* tabIdentifier: windowtab1, workspacePath: /tmp/Sample.xcodeproj\\n\"}")
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpToolCallNormalizesGetBuildLogIssuesMissingLine() async throws {
        let config = makeConfig(requestTimeout: 2)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "GetBuildLog")
                return .immediate(
                    try makeToolResultResponse(
                        id: originalID,
                        result: [
                            "content": [[
                                "type": "text",
                                "text": "{\"buildResult\":\"The build succeeded\",\"buildIsRunning\":false,\"buildLogEntries\":[{\"buildTask\":\"Build target App\",\"emittedIssues\":[{\"message\":\"Using stub executor library with Swift entry point.\",\"severity\":\"remark\"}]}],\"fullLogPath\":\"/tmp/build.log\",\"totalFound\":1,\"truncated\":false}",
                            ]],
                            "structuredContent": [
                                "buildResult": "The build succeeded",
                                "buildIsRunning": false,
                                "buildLogEntries": [[
                                    "buildTask": "Build target App",
                                    "emittedIssues": [[
                                        "message": "Using stub executor library with Swift entry point.",
                                        "severity": "remark",
                                    ]],
                                ]],
                                "fullLogPath": "/tmp/build.log",
                                "totalFound": 1,
                                "truncated": false,
                            ],
                        ]
                    )
                )
            }
        )
        sessionManager.setCachedToolsListResult(
            JSONValue(any: [
                "tools": [[
                    "name": "GetBuildLog",
                    "outputSchema": ["type": "object"],
                ]]
            ])!
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-build-log-normalized",
                payload: toolsCallPayload(
                    id: 15,
                    name: "GetBuildLog",
                    arguments: [
                        "tabIdentifier": "windowtab1",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let structuredContent = result?["structuredContent"] as? [String: Any]
            let buildLogEntries = structuredContent?["buildLogEntries"] as? [[String: Any]]
            let emittedIssues = buildLogEntries?.first?["emittedIssues"] as? [[String: Any]]
            let content = result?["content"] as? [[String: Any]]

            #expect((emittedIssues?.first?["line"] as? NSNumber)?.intValue == 0)
            #expect(content?.first?["text"] as? String == "{\"buildResult\":\"The build succeeded\",\"buildIsRunning\":false,\"buildLogEntries\":[{\"buildTask\":\"Build target App\",\"emittedIssues\":[{\"message\":\"Using stub executor library with Swift entry point.\",\"severity\":\"remark\"}]}],\"fullLogPath\":\"/tmp/build.log\",\"totalFound\":1,\"truncated\":false}")
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesReturnsBackpressureErrorWhenQueueIsFull() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let coordinator = RefreshCodeIssuesCoordinator(
            maxPendingPerKey: 0,
            maxPendingTotal: 8,
            queueWaitTimeout: 5
        )
        let firstSent = SyncSignal()
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                firstSent.signal()
                return .manual(try makeToolSuccessResponse(id: originalID, text: "ok"))
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: coordinator
        )

        do {
            let firstTask = Task<Int, Error> {
                let (response, _) = try await postHTTPJSON(
                    url: server.url,
                    sessionID: "session-overload-1",
                    payload: toolsCallPayload(
                        id: 21,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-overload",
                            "filePath": "A.swift",
                        ]
                    )
                )
                return response.statusCode
            }

            try await firstSent.wait(description: "waiting for first upstream refresh request")

            let (secondResponse, secondBody) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-overload-2",
                payload: toolsCallPayload(
                    id: 22,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-overload",
                        "filePath": "B.swift",
                    ]
                )
            )

            #expect(secondResponse.statusCode == 200)
            let error = secondBody["error"] as? [String: Any]
            #expect((error?["code"] as? NSNumber)?.intValue == -32003)
            #expect((error?["message"] as? String) == "refresh queue overloaded")

            sessionManager.deliverNextPendingResponse()
            let firstStatusCode = try await firstTask.value
            #expect(firstStatusCode == 200)
            #expect(sessionManager.sentUpstreamCount() == 1)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshProxyReturnsBackpressureErrorWhenQueueIsFull() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
        let coordinator = RefreshCodeIssuesCoordinator(
            maxPendingPerKey: 0,
            maxPendingTotal: 8,
            queueWaitTimeout: 5
        )
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot).appendingPathComponent("A.swift")
        try "".write(to: target, atomically: true, encoding: .utf8)
        let firstSent = SyncSignal()

        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                switch toolName {
                case "XcodeListWindows":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text:
                                "{\"message\":\"* tabIdentifier: windowtab-proxy-overload, workspacePath: \(temporaryRoot)\"}"
                        )
                    )
                case "XcodeListNavigatorIssues":
                    firstSent.signal()
                    return .manual(
                        try makeToolResultResponse(
                            id: originalID,
                            result: [
                                "content": [[
                                    "type": "text",
                                    "text": "{\"issues\":[{\"path\":\"\(target.path)\",\"message\":\"warn\",\"line\":1,\"severity\":\"warning\"}],\"totalFound\":1,\"truncated\":false}"
                                ]],
                                "structuredContent": [
                                    "issues": [[
                                        "path": target.path,
                                        "message": "warn",
                                        "line": 1,
                                        "severity": "warning",
                                    ]],
                                    "totalFound": 1,
                                    "truncated": false,
                                ],
                            ]
                        )
                    )
                default:
                    return .immediate(try makeToolErrorResponse(id: originalID, text: "unexpected tool"))
                }
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: coordinator
        )

        do {
            let firstTask = Task<Int, Error> {
                let (response, _) = try await postHTTPJSON(
                    url: server.url,
                    sessionID: "session-proxy-overload-1",
                    payload: toolsCallPayload(
                        id: 26,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-proxy-overload",
                            "filePath": "A.swift",
                        ]
                    )
                )
                return response.statusCode
            }

            try await firstSent.wait(description: "waiting for first proxy refresh request")

            let (secondResponse, secondBody) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-proxy-overload-2",
                payload: toolsCallPayload(
                    id: 27,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-proxy-overload",
                        "filePath": "A.swift",
                    ]
                )
            )

            #expect(secondResponse.statusCode == 200)
            let error = secondBody["error"] as? [String: Any]
            #expect((error?["code"] as? NSNumber)?.intValue == -32003)
            #expect((error?["message"] as? String) == "refresh queue overloaded")

            sessionManager.deliverNextPendingResponse()
            let firstStatusCode = try await firstTask.value
            #expect(firstStatusCode == 200)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesReturnsBackpressureErrorAfterQueueWaitTimeout() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let coordinator = RefreshCodeIssuesCoordinator(
            maxPendingPerKey: 4,
            maxPendingTotal: 8,
            queueWaitTimeout: 0.05
        )
        let firstSent = SyncSignal()
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                firstSent.signal()
                return .manual(try makeToolSuccessResponse(id: originalID, text: "ok"))
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: coordinator
        )

        do {
            let firstTask = Task<Int, Error> {
                let (response, _) = try await postHTTPJSON(
                    url: server.url,
                    sessionID: "session-timeout-1",
                    payload: toolsCallPayload(
                        id: 24,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-timeout",
                            "filePath": "A.swift",
                        ]
                    )
                )
                return response.statusCode
            }

            try await firstSent.wait(description: "waiting for first upstream timeout refresh request")

            let (secondResponse, secondBody) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-timeout-2",
                payload: toolsCallPayload(
                    id: 25,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-timeout",
                        "filePath": "B.swift",
                    ]
                )
            )

            #expect(secondResponse.statusCode == 200)
            let error = secondBody["error"] as? [String: Any]
            #expect((error?["code"] as? NSNumber)?.intValue == -32003)
            #expect((error?["message"] as? String) == "refresh queue overloaded")

            sessionManager.deliverNextPendingResponse()
            let firstStatusCode = try await firstTask.value
            #expect(firstStatusCode == 200)
            #expect(sessionManager.sentUpstreamCount() == 1)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshProxyReturnsBackpressureErrorAfterQueueWaitTimeout() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
        let coordinator = RefreshCodeIssuesCoordinator(
            maxPendingPerKey: 4,
            maxPendingTotal: 8,
            queueWaitTimeout: 0.05
        )
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot).appendingPathComponent("A.swift")
        try "".write(to: target, atomically: true, encoding: .utf8)
        let firstSent = SyncSignal()

        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                switch toolName {
                case "XcodeListWindows":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text:
                                "{\"message\":\"* tabIdentifier: windowtab-proxy-timeout, workspacePath: \(temporaryRoot)\"}"
                        )
                    )
                case "XcodeListNavigatorIssues":
                    firstSent.signal()
                    return .manual(
                        try makeToolResultResponse(
                            id: originalID,
                            result: [
                                "content": [[
                                    "type": "text",
                                    "text": "{\"issues\":[{\"path\":\"\(target.path)\",\"message\":\"warn\",\"line\":1,\"severity\":\"warning\"}],\"totalFound\":1,\"truncated\":false}"
                                ]],
                                "structuredContent": [
                                    "issues": [[
                                        "path": target.path,
                                        "message": "warn",
                                        "line": 1,
                                        "severity": "warning",
                                    ]],
                                    "totalFound": 1,
                                    "truncated": false,
                                ],
                            ]
                        )
                    )
                default:
                    return .immediate(try makeToolErrorResponse(id: originalID, text: "unexpected tool"))
                }
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: coordinator
        )

        do {
            let firstTask = Task<Int, Error> {
                let (response, _) = try await postHTTPJSON(
                    url: server.url,
                    sessionID: "session-proxy-timeout-1",
                    payload: toolsCallPayload(
                        id: 28,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-proxy-timeout",
                            "filePath": "A.swift",
                        ]
                    )
                )
                return response.statusCode
            }

            try await firstSent.wait(description: "waiting for first proxy timeout refresh request")

            let (secondResponse, secondBody) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-proxy-timeout-2",
                payload: toolsCallPayload(
                    id: 29,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-proxy-timeout",
                        "filePath": "A.swift",
                    ]
                )
            )

            #expect(secondResponse.statusCode == 200)
            let error = secondBody["error"] as? [String: Any]
            #expect((error?["code"] as? NSNumber)?.intValue == -32003)
            #expect((error?["message"] as? String) == "refresh queue overloaded")

            sessionManager.deliverNextPendingResponse()
            let firstStatusCode = try await firstTask.value
            #expect(firstStatusCode == 200)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func httpRefreshProxyInternalToolCallsDoNotResetUpstreamSuccessState() async throws {
        var config = makeConfig(requestTimeout: 0.2)
        config.refreshCodeIssuesMode = .proxy
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("Missing.swift")
        try "".write(to: target, atomically: true, encoding: .utf8)

        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                switch toolName {
                case "XcodeListWindows":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text:
                                "{\"message\":\"* tabIdentifier: windowtab-timeout, workspacePath: \(temporaryRoot)\"}"
                        )
                    )
                case "XcodeListNavigatorIssues":
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "navigator failed"
                        )
                    )
                case "XcodeRefreshCodeIssuesInFile":
                    return .delayed(
                        try makeToolSuccessResponse(id: originalID, text: "late"),
                        delayNanos: 500_000_000
                    )
                default:
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text: "unexpected tool"
                        )
                    )
                }
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-internal-window-lookup",
                payload: toolsCallPayload(
                    id: 14,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-timeout",
                        "filePath": "Missing.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let error = body["error"] as? [String: Any]
            #expect(error != nil)
            #expect(sessionManager.sentToolNames() == [
                "XcodeListWindows",
                "XcodeListNavigatorIssues",
                "XcodeRefreshCodeIssuesInFile",
            ])
            #expect(sessionManager.requestSuccessNotificationCount() == 0)
            #expect(sessionManager.requestTimeoutNotificationCount() == 1)
            #expect(sessionManager.chooseUpstreamShouldPinValues().isEmpty)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }

    @Test func forwardingServiceInternalToolRespectsRequestedOverride()
        async throws
    {
        let config = makeConfig(requestTimeout: 0.2)
        let eventLoop = EmbeddedEventLoop()
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "XcodeListNavigatorIssues")
                return .immediate(
                    try makeToolSuccessResponse(id: originalID, text: "{\"issues\":[]}")
                )
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setAvailableUpstreamIndices([1])

        let forwardingService = MCPForwardingService(
            config: config,
            sessionManager: sessionManager
        )

        let result = await forwardingService.callInternalTool(
            name: "XcodeListNavigatorIssues",
            arguments: ["tabIdentifier": "windowtab-1"],
            sessionID: "session-mismatch",
            eventLoop: eventLoop,
            upstreamIndexOverride: 0
        )
        switch result {
        case .success:
            break
        case .timeout:
            Issue.record("expected the requested upstream dispatch to succeed")
        case .unavailable:
            Issue.record("expected the requested upstream to be usable")
        }
        #expect(sessionManager.sentToolRequests() == ["XcodeListNavigatorIssues@0"])
        #expect(sessionManager.chooseUpstreamIndexCallCount() == 0)
    }

    @Test func httpRefreshCodeIssuesRequeuesLeaseAcrossRetryAttempts() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let attempts = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                let attempt = attempts.withLockedValue { value in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    return .immediate(
                        try makeToolErrorResponse(
                            id: originalID,
                            text:
                                "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditor.SourceEditorCallableDiagnosticError error 5.)"
                        )
                    )
                }
                return .manual(try makeToolSuccessResponse(id: originalID, text: "ok"))
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )
        let requestTask = Task {
            try await postHTTPData(
                url: server.url,
                sessionID: "session-retry-lease",
                payload: toolsCallPayload(
                    id: 14,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-retry-lease",
                        "filePath": "App.swift",
                    ]
                )
            )
        }

        do {
            let deadline = ContinuousClock.now + .seconds(2)
            while sessionManager.sentUpstreamCount() != 2, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(sessionManager.sentUpstreamCount() == 2)
            #expect(sessionManager.requeuedLeaseCount() == 1)

            let inFlightLease = try #require(sessionManager.leaseDebugSnapshots().first)
            #expect(inFlightLease.state == .active)
            #expect(inFlightLease.releaseReason == nil)

            sessionManager.deliverNextPendingResponse()

            let response = try await requestTask.value
            #expect(response.statusCode == 200)
            let body =
                (try? JSONSerialization.jsonObject(with: response.bodyData, options: []))
                as? [String: Any]
            let result = body?["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) != true)

            let completedLease = try #require(sessionManager.leaseDebugSnapshots().first)
            #expect(completedLease.state == .completed)
        } catch {
            requestTask.cancel()
            await server.shutdown()
            throw error
        }

        await server.shutdown()
    }
}

private enum HTTPTestError: Error {
    case missingResponseHead
}

private struct UpstreamResponsePlan {
    let data: Data
    let delayNanos: UInt64?
    let deliverManually: Bool

    static func immediate(_ data: Data) -> UpstreamResponsePlan {
        UpstreamResponsePlan(data: data, delayNanos: nil, deliverManually: false)
    }

    static func delayed(
        _ data: Data,
        delayNanos: UInt64
    ) -> UpstreamResponsePlan {
        UpstreamResponsePlan(data: data, delayNanos: delayNanos, deliverManually: false)
    }

    static func manual(_ data: Data) -> UpstreamResponsePlan {
        UpstreamResponsePlan(data: data, delayNanos: nil, deliverManually: true)
    }
}

private final class TestRuntimeCoordinator: RuntimeCoordinating {
    private struct UpstreamMapping: Sendable {
        let sessionID: String
        let originalID: RPCID
    }

    private struct ChooseUpstreamCall: Sendable {
        let sessionID: String?
    }

    private struct SentRequest: Sendable {
        let method: String
        let toolName: String?
        let upstreamIndex: Int
    }

    private struct State: Sendable {
        struct PendingResponse: Sendable {
            let sessionID: String
            let data: Data
        }

        var sessions: [String: SessionContext] = [:]
        var nextUpstreamID: Int64 = 1
        var assignUpstreamIDCount = 0
        var initialized = false
        var cachedToolsList: JSONValue?
        var refreshToolsListCalls = 0
        var upstreamSendCount = 0
        var upstreamIDMapping: [Int64: UpstreamMapping] = [:]
        var chooseUpstreamCalls: [ChooseUpstreamCall] = []
        var availableUpstreamIndex: Int? = 0
        var requestTimeoutNotifications = 0
        var requestSuccessNotifications = 0
        var pendingResponses: [PendingResponse] = []
        var sentRequests: [SentRequest] = []
        var availableUpstreamIndices: [Int?] = []
        var requeuedLeaseCount = 0
    }

    private let state = NIOLockedValueBox(State())
    private let config: ProxyConfig
    private let upstreamRequestResponder:
        (@Sendable (_ method: String, _ toolName: String?, _ originalID: RPCID) throws -> UpstreamResponsePlan)?
    private let upstreamResponder:
        (@Sendable (_ method: String, _ originalID: RPCID) throws -> UpstreamResponsePlan)?
    private let legacyUpstreamResponder:
        (@Sendable (_ method: String, _ originalID: RPCID) throws -> Data)?
    private let requestLeaseRegistry = RequestLeaseRegistry()

    init(
        config: ProxyConfig,
        upstreamResponder: (@Sendable (_ method: String, _ originalID: RPCID) throws -> Data)? = nil
    ) {
        self.config = config
        self.upstreamRequestResponder = nil
        self.upstreamResponder = nil
        self.legacyUpstreamResponder = upstreamResponder
    }

    init(
        config: ProxyConfig,
        upstreamPlanResponder: (@Sendable (_ method: String, _ originalID: RPCID) throws -> UpstreamResponsePlan)?
    ) {
        self.config = config
        self.upstreamRequestResponder = nil
        self.upstreamResponder = upstreamPlanResponder
        self.legacyUpstreamResponder = nil
    }

    init(
        config: ProxyConfig,
        upstreamRequestResponder: (@Sendable (_ method: String, _ toolName: String?, _ originalID: RPCID) throws -> UpstreamResponsePlan)?
    ) {
        self.config = config
        self.upstreamRequestResponder = upstreamRequestResponder
        self.upstreamResponder = nil
        self.legacyUpstreamResponder = nil
    }

    func session(id: String) -> SessionContext {
        state.withLockedValue { state in
            if let existing = state.sessions[id] {
                return existing
            }
            let context = SessionContext(id: id, config: config)
            state.sessions[id] = context
            return context
        }
    }

    func hasSession(id: String) -> Bool {
        state.withLockedValue { state in
            state.sessions[id] != nil
        }
    }

    func removeSession(id: String) {
        let context = state.withLockedValue { state in
            state.sessions.removeValue(forKey: id)
        }
        context?.notificationHub.closeAll()
    }

    func debugReset() {
        state.withLockedValue { state in
            state.sessions.removeAll()
            state.cachedToolsList = nil
            state.pendingResponses.removeAll()
            state.sentRequests.removeAll()
            state.upstreamIDMapping.removeAll()
        }
    }

    func shutdown() {}

    func isInitialized() -> Bool {
        state.withLockedValue { state in
            state.initialized
        }
    }

    func cachedToolsListResult() -> JSONValue? {
        state.withLockedValue { $0.cachedToolsList }
    }

    func setCachedToolsListResult(_ result: JSONValue) {
        state.withLockedValue { state in
            state.cachedToolsList = result
        }
    }

    func refreshToolsListIfNeeded() {
        state.withLockedValue { state in
            state.refreshToolsListCalls += 1
        }
    }

    func registerInitialize(
        sessionID: String,
        originalID: RPCID,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        state.withLockedValue { state in
            state.initialized = true
        }
        _ = chooseUpstreamIndex()
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalID.value.foundationObject,
            "result": [
                "capabilities": [String: Any]()
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: response, options: [])) ?? Data()
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return eventLoop.makeSucceededFuture(buffer)
    }

    func chooseUpstreamIndex() -> Int? {
        state.withLockedValue { state in
            state.chooseUpstreamCalls.append(
                ChooseUpstreamCall(sessionID: nil)
            )
            if state.availableUpstreamIndices.isEmpty == false {
                return state.availableUpstreamIndices.removeFirst()
            }
            return state.availableUpstreamIndex
        }
    }

    func enqueueOnUpstreamSlot<Output: Sendable>(
        leaseID _: RequestLeaseID,
        descriptor _: SessionPipelineRequestDescriptor,
        on eventLoop: EventLoop,
        preferredUpstreamIndex: Int?,
        starter: @escaping @Sendable (Int) -> EventLoopFuture<Output>
    ) -> EventLoopFuture<Output> {
        let upstreamIndex = preferredUpstreamIndex ?? chooseUpstreamIndex()
        guard let upstreamIndex else {
            return eventLoop.makeFailedFuture(
                NSError(domain: "TestRuntimeCoordinator", code: 1)
            )
        }
        return starter(upstreamIndex)
    }

    func assignUpstreamID(sessionID: String, originalID: RPCID, upstreamIndex _: Int) -> Int64 {
        state.withLockedValue { state in
            state.assignUpstreamIDCount += 1
            let id = state.nextUpstreamID
            state.nextUpstreamID += 1
            state.upstreamIDMapping[id] = UpstreamMapping(
                sessionID: sessionID, originalID: originalID)
            return id
        }
    }

    func removeUpstreamIDMapping(sessionID: String, requestIDKey: String, upstreamIndex _: Int) {
        state.withLockedValue { state in
            let removed = state.upstreamIDMapping.first { _, mapping in
                mapping.sessionID == sessionID && mapping.originalID.key == requestIDKey
            }?.key
            if let removed {
                state.upstreamIDMapping.removeValue(forKey: removed)
            }
        }
    }

    func onRequestTimeout(sessionID: String, requestIDKey: String, upstreamIndex: Int) {
        state.withLockedValue { state in
            state.requestTimeoutNotifications += 1
        }
        removeUpstreamIDMapping(
            sessionID: sessionID, requestIDKey: requestIDKey, upstreamIndex: upstreamIndex)
    }

    func onRequestSucceeded(sessionID _: String, requestIDKey _: String, upstreamIndex _: Int) {
        state.withLockedValue { state in
            state.requestSuccessNotifications += 1
        }
    }

    func sendUpstream(_ data: Data, upstreamIndex: Int, ensureRunning: Bool) {
        _ = ensureRunning
        state.withLockedValue { state in
            state.upstreamSendCount += 1
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: [])
                as? [String: Any],
            let method = object["method"] as? String,
            let upstreamIDValue = object["id"]
        else {
            return
        }
        let toolName = ((object["params"] as? [String: Any])?["name"] as? String)
        state.withLockedValue { state in
            state.sentRequests.append(
                SentRequest(
                    method: method,
                    toolName: toolName,
                    upstreamIndex: upstreamIndex
                )
            )
        }
        let upstreamID = (upstreamIDValue as? NSNumber)?.int64Value ?? (upstreamIDValue as? Int64)
        guard let upstreamID,
            let mapping = state.withLockedValue({ $0.upstreamIDMapping[upstreamID] })
        else {
            return
        }

        let responsePlan: UpstreamResponsePlan
        if let upstreamRequestResponder,
            let planned = try? upstreamRequestResponder(method, toolName, mapping.originalID)
        {
            responsePlan = planned
        } else if let upstreamResponder,
            let planned = try? upstreamResponder(method, mapping.originalID)
        {
            responsePlan = planned
        } else if let legacyUpstreamResponder,
            let responseData = try? legacyUpstreamResponder(method, mapping.originalID)
        {
            responsePlan = .immediate(responseData)
        } else {
            return
        }

        let deliverResponse = { [self] in
            let session = self.session(id: mapping.sessionID)
            session.router.handleIncoming(responsePlan.data)
        }
        if responsePlan.deliverManually {
            state.withLockedValue { state in
                state.pendingResponses.append(
                    State.PendingResponse(
                        sessionID: mapping.sessionID,
                        data: responsePlan.data
                    )
                )
            }
        } else if let delayNanos = responsePlan.delayNanos {
            Task {
                try? await Task.sleep(nanoseconds: delayNanos)
                deliverResponse()
            }
        } else {
            deliverResponse()
        }
    }

    func debugSnapshot() -> ProxyDebugSnapshot {
        debugSnapshot(includeSensitiveDebugPayloads: false)
    }

    func createRequestLease(descriptor: SessionPipelineRequestDescriptor) -> RequestLeaseID {
        requestLeaseRegistry.createLease(descriptor: descriptor)
    }

    func activateRequestLease(
        _ leaseID: RequestLeaseID,
        requestIDKey: String?,
        upstreamIndex: Int?,
        timeout: TimeAmount?
    ) {
        requestLeaseRegistry.activateLease(
            leaseID,
            requestIDKey: requestIDKey,
            upstreamIndex: upstreamIndex,
            timeoutAt: timeout.map {
                Date().addingTimeInterval(Double($0.nanoseconds) / 1_000_000_000)
            }
        )
    }

    func completeRequestLease(_ leaseID: RequestLeaseID) {
        _ = requestLeaseRegistry.completeLease(leaseID)
    }

    func requeueRequestLease(_ leaseID: RequestLeaseID) {
        state.withLockedValue { state in
            state.requeuedLeaseCount += 1
        }
        _ = requestLeaseRegistry.requeueLease(leaseID)
    }

    func failRequestLease(
        _ leaseID: RequestLeaseID,
        terminalState: RequestLeaseState,
        reason: RequestLeaseReleaseReason
    ) {
        _ = requestLeaseRegistry.failLease(
            leaseID,
            terminalState: terminalState,
            reason: reason
        )
    }

    func handleRequestLeaseTimeout(
        _ leaseID: RequestLeaseID,
        sessionID: String,
        requestIDKeys: [String],
        upstreamIndex: Int
    ) {
        _ = leaseID
        if let first = requestIDKeys.first {
            onRequestTimeout(
                sessionID: sessionID,
                requestIDKey: first,
                upstreamIndex: upstreamIndex
            )
            for requestIDKey in requestIDKeys.dropFirst() {
                removeUpstreamIDMapping(
                    sessionID: sessionID,
                    requestIDKey: requestIDKey,
                    upstreamIndex: upstreamIndex
                )
            }
        }
        _ = requestLeaseRegistry.timeoutLease(leaseID)
    }

    func abandonRequestLease(
        _ leaseID: RequestLeaseID,
        sessionID: String,
        requestIDKeys: [String],
        upstreamIndex: Int?
    ) {
        if let upstreamIndex {
            for requestIDKey in requestIDKeys {
                removeUpstreamIDMapping(
                    sessionID: sessionID,
                    requestIDKey: requestIDKey,
                    upstreamIndex: upstreamIndex
                )
            }
        }
        _ = requestLeaseRegistry.failLease(
            leaseID,
            terminalState: .abandoned,
            reason: .clientDisconnected
        )
    }

    func debugSnapshot(includeSensitiveDebugPayloads: Bool) -> ProxyDebugSnapshot {
        ProxyDebugSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            proxyInitialized: isInitialized(),
            cachedToolsListAvailable: cachedToolsListResult() != nil,
            warmupInFlight: false,
            upstreams: [
                ProxyUpstreamDebugSnapshot(
                    upstreamIndex: 0,
                    isInitialized: isInitialized(),
                    initInFlight: false,
                    didSendInitialized: false,
                    healthState: "healthy",
                    consecutiveRequestTimeouts: 0,
                    consecutiveToolsListFailures: 0,
                    lastToolsListSuccessUptimeNs: nil,
                    recentStderr: [],
                    lastDecodeError: nil,
                    lastBridgeError: nil,
                    protocolViolationCount: 0,
                    lastProtocolViolationAt: nil,
                    lastProtocolViolationReason: nil,
                    lastProtocolViolationBufferedBytes: nil,
                    lastProtocolViolationPreview: includeSensitiveDebugPayloads ? "raw-preview" : nil,
                    lastProtocolViolationPreviewHex: includeSensitiveDebugPayloads ? "61 62" : nil,
                    lastProtocolViolationLeadingByteHex: includeSensitiveDebugPayloads ? "61" : nil,
                    bufferedStdoutBytes: 0
                )
            ],
            recentTraffic: [],
            sessions: [],
            leases: requestLeaseRegistry.debugSnapshots(),
            queuedRequestCount: 0
        )
    }

    func leaseDebugSnapshots() -> [RequestLeaseDebugSnapshot] {
        requestLeaseRegistry.debugSnapshots()
    }

    func sentUpstreamCount() -> Int {
        state.withLockedValue { $0.upstreamSendCount }
    }

    func sentToolNames() -> [String] {
        state.withLockedValue { state in
            state.sentRequests.compactMap(\.toolName)
        }
    }

    func sentToolRequests() -> [String] {
        state.withLockedValue { state in
            state.sentRequests.compactMap { request in
                guard let toolName = request.toolName else { return nil }
                return "\(toolName)@\(request.upstreamIndex)"
            }
        }
    }

    func assignedUpstreamIDCount() -> Int {
        state.withLockedValue { $0.assignUpstreamIDCount }
    }

    func chooseUpstreamIndexCallCount() -> Int {
        state.withLockedValue { $0.chooseUpstreamCalls.count }
    }

    func lastChooseUpstreamShouldPin() -> Bool {
        false
    }

    func chooseUpstreamShouldPinValues() -> [Bool] {
        []
    }

    func refreshToolsListCallCount() -> Int {
        state.withLockedValue { $0.refreshToolsListCalls }
    }

    func mappedUpstreamRequestCount() -> Int {
        state.withLockedValue { $0.upstreamIDMapping.count }
    }

    func setAvailableUpstreamIndex(_ value: Int?) {
        state.withLockedValue { $0.availableUpstreamIndex = value }
    }

    func setAvailableUpstreamIndices(_ values: [Int?]) {
        state.withLockedValue { $0.availableUpstreamIndices = values }
    }

    func requestTimeoutNotificationCount() -> Int {
        state.withLockedValue { $0.requestTimeoutNotifications }
    }

    func requestSuccessNotificationCount() -> Int {
        state.withLockedValue { $0.requestSuccessNotifications }
    }

    func requeuedLeaseCount() -> Int {
        state.withLockedValue { $0.requeuedLeaseCount }
    }

    func setInitialized(_ value: Bool) {
        state.withLockedValue { $0.initialized = value }
    }

    func deliverNextPendingResponse() {
        let pending = state.withLockedValue { state -> State.PendingResponse? in
            guard state.pendingResponses.isEmpty == false else { return nil }
            return state.pendingResponses.removeFirst()
        }
        guard let pending else { return }
        let session = session(id: pending.sessionID)
        session.router.handleIncoming(pending.data)
    }
}

private func makeConfig(
    maxBodyBytes: Int = 1024,
    requestTimeout: TimeInterval = 1
) -> ProxyConfig {
    ProxyConfig(
        listenHost: "127.0.0.1",
        listenPort: 0,
        upstreamCommand: "xcrun",
        upstreamArgs: ["mcpbridge"],
        upstreamSessionID: nil,
        maxBodyBytes: maxBodyBytes,
        requestTimeout: requestTimeout
    )
}

private func makeHTTPTemporaryWorkspaceRoot() -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func addHTTPHandler(
    to channel: EmbeddedChannel,
    config: ProxyConfig,
    sessionManager: any RuntimeCoordinating,
    refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator? = nil,
    refreshCodeIssuesTargetResolver: RefreshCodeIssuesTargetResolver = RefreshCodeIssuesTargetResolver(),
    refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState? = nil
) throws {
    let handler = HTTPHandler(
        config: config,
        sessionManager: sessionManager,
        refreshCodeIssuesCoordinator: refreshCodeIssuesCoordinator,
        refreshCodeIssuesTargetResolver: refreshCodeIssuesTargetResolver,
        refreshCodeIssuesDebugState: refreshCodeIssuesDebugState
    )
    try channel.pipeline.addHandler(handler).wait()
}

private func collectResponse(from channel: EmbeddedChannel) throws -> (
    head: HTTPResponseHead, body: String
) {
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
        throw HTTPTestError.missingResponseHead
    }
    let body = bodyBuffer.readString(length: bodyBuffer.readableBytes) ?? ""
    return (responseHead, body)
}

private func advanceEventLoopTime(on channel: EmbeddedChannel, by amount: TimeAmount) {
    channel.embeddedEventLoop.advanceTime(by: amount)
}

private func toolsCallPayload(
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
    _ payload: [String: Any],
    sessionID: String,
    to channel: EmbeddedChannel
) throws {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    head.headers.add(name: "Mcp-Session-Id", value: sessionID)
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))
}

private struct TestHTTPHandlerServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let url: URL
    let sessionManager: any RuntimeCoordinating

    static func start(
        config: ProxyConfig,
        sessionManager: any RuntimeCoordinating,
        refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator? = nil,
        refreshCodeIssuesTargetResolver: RefreshCodeIssuesTargetResolver = RefreshCodeIssuesTargetResolver()
    ) throws -> TestHTTPHandlerServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let refreshCoordinator =
            refreshCodeIssuesCoordinator
            ?? RefreshCodeIssuesCoordinator.makeDefault(
                requestTimeout: config.requestTimeout
            )
        let refreshDebugState = RefreshCodeIssuesDebugState(
            maxPendingPerKey: refreshCoordinator.maxPendingPerKey,
            maxPendingTotal: refreshCoordinator.maxPendingTotal,
            queueWaitTimeoutSeconds: refreshCoordinator.queueWaitTimeoutSeconds
        )
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            config: config,
                            sessionManager: sessionManager,
                            refreshCodeIssuesCoordinator: refreshCoordinator,
                            refreshCodeIssuesTargetResolver: refreshCodeIssuesTargetResolver,
                            refreshCodeIssuesDebugState: refreshDebugState
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: config.listenHost, port: 0).wait()
        let port = channel.localAddress?.port ?? 0
        let url = URL(string: "http://\(config.listenHost):\(port)/mcp")!
        return TestHTTPHandlerServer(
            group: group,
            channel: channel,
            url: url,
            sessionManager: sessionManager
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

private struct RawHTTPResponse: Sendable {
    let statusCode: Int
    let bodyData: Data
}

private func postHTTPJSON(
    url: URL,
    sessionID: String,
    payload: [String: Any]
) async throws -> (HTTPURLResponse, [String: Any]) {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")

    return try await withTestURLSession { session in
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPTestError.missingResponseHead
        }
        let object =
            (try? JSONSerialization.jsonObject(with: responseData, options: [])) as? [String: Any]
            ?? [:]
        return (httpResponse, object)
    }
}

private func postHTTPData(
    url: URL,
    sessionID: String,
    payload: [String: Any]
) async throws -> RawHTTPResponse {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")

    return try await withTestURLSession { session in
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPTestError.missingResponseHead
        }
        return RawHTTPResponse(statusCode: httpResponse.statusCode, bodyData: responseData)
    }
}

private func getHTTPData(url: URL) async throws -> (HTTPURLResponse, Data) {
    try await withTestURLSession { session in
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPTestError.missingResponseHead
        }
        return (httpResponse, data)
    }
}

private func makeDebugSnapshotURL(from mcpURL: URL) -> URL {
    var components = URLComponents(url: mcpURL, resolvingAgainstBaseURL: false)!
    components.path = "/debug/upstreams"
    components.query = nil
    return components.url!
}

private typealias AsyncSignal = TestSignal
private typealias SyncSignal = TestSignal

private func makeToolSuccessResponse(id: RPCID, text: String) throws -> Data {
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id.value.foundationObject,
        "result": [
            "content": [
                [
                    "type": "text",
                    "text": text,
                ]
            ]
        ],
    ]
    return try JSONSerialization.data(withJSONObject: response, options: [])
}

private func makeToolResultResponse(id: RPCID, result: [String: Any]) throws -> Data {
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id.value.foundationObject,
        "result": result,
    ]
    return try JSONSerialization.data(withJSONObject: response, options: [])
}

private func makeToolErrorResponse(id: RPCID, text: String) throws -> Data {
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id.value.foundationObject,
        "result": [
            "content": [
                [
                    "type": "text",
                    "text": text,
                ]
            ],
            "isError": true,
        ],
    ]
    return try JSONSerialization.data(withJSONObject: response, options: [])
}
