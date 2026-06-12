import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOHTTP1
import Testing
import ProxyCore
import ProxyMCP
import ProxySession
import ProxyXcodeFeatures
 import ProxyXcodeSupport
import XcodeMCPTestSupport

@testable import ProxyHTTPGateway

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
        let sessionManager = TestRuntimeCoordinator(config: config)
        sessionManager.setCachedToolsListResult(.object(["tools": .array([])]))
        _ = sessionManager.session(id: "debug-reset-session")
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            var components = URLComponents(url: server.url, resolvingAgainstBaseURL: false)!
            components.path = "/debug/reset"
            let requestURL = try #require(components.url)
            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"

            let (responseData, response) = try await withTestURLSession { session in
                try await session.data(for: request)
            }
            let httpResponse = try #require(response as? HTTPURLResponse)
            #expect(httpResponse.statusCode == 202)
            #expect(String(data: responseData, encoding: .utf8) == "reset scheduled")
            #expect(sessionManager.hasSession(id: "debug-reset-session") == false)
            #expect(sessionManager.cachedToolsListResult() == nil)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
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

        let target = URL(fileURLWithPath: temporaryRoot).appendingPathComponent("Missing.swift")
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
                            "filePath": "Missing.swift",
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
            #expect(snapshot.refreshCodeIssues == nil)

            let (sensitiveResponse, sensitiveData) = try await getHTTPData(
                url: makeDebugSnapshotURL(from: server.url, includeSensitive: true)
            )
            #expect(sensitiveResponse.statusCode == 200)
            let sensitiveSnapshot = try decoder.decode(HTTPDebugSnapshot.self, from: sensitiveData)
            let refreshSnapshot = try #require(sensitiveSnapshot.refreshCodeIssues)
            #expect(refreshSnapshot.queue.activeRequestCount == 1)
            #expect(refreshSnapshot.activeRequests.count == 1)
            #expect(refreshSnapshot.activeRequests.first?.queueKey == "windowtab-debug-state")
            #expect(refreshSnapshot.activeRequests.first?.step == "proxy.list_navigator_issues")
            #expect(refreshSnapshot.activeRequests.first?.state == "running")
            let activeLease = try #require(
                sensitiveSnapshot.leases.first(where: {
                    $0.state == .active && $0.requestIDKey == "34"
                })
            )
            #expect(activeLease.sessionID == "session-debug-state")
            #expect(activeLease.upstreamIndex == nil)

            sessionManager.deliverNextPendingResponse()
            _ = try await refreshTask.value

            let (completedResponse, completedData) = try await getHTTPData(
                url: makeDebugSnapshotURL(from: server.url, includeSensitive: true)
            )
            #expect(completedResponse.statusCode == 200)
            let completedSnapshot = try decoder.decode(HTTPDebugSnapshot.self, from: completedData)
            let completedRefreshSnapshot = try #require(completedSnapshot.refreshCodeIssues)
            #expect(completedRefreshSnapshot.queue.activeRequestCount == 0)
            #expect(completedRefreshSnapshot.recentCompletedRequests.first?.finalState == "completed")
            #expect(completedRefreshSnapshot.recentCompletedRequests.first?.outcome == "success")
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
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

    @Test func httpSingleElementBatchInitializeMissingIDReturnsArrayShape() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [[String: Any]] = [
            [
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
        #expect(array[0]["id"] is NSNull)
        let error = array[0]["error"] as? [String: Any]
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

        // tools/list now runs through the shared bootstrap owner, so the client session does
        // not hold a direct upstream mapping while it waits.
        #expect(sessionManager.mappedUpstreamRequestCount() == 0)
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

    @Test func httpSingleItemBatchToolsListUsesCachedResult() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        sessionManager.setInitialized(true)
        sessionManager.setCachedToolsListResult(
            JSONValue(any: ["tools": [Any]()])!
        )
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [[String: Any]] = [[
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: "session-batch-tools-list")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)

        let responseArray =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [[String: Any]]
        let responseObject = try #require(responseArray?.first)
        #expect((responseObject["id"] as? NSNumber)?.intValue == 2)
        let result = responseObject["result"] as? [String: Any]
        let tools = result?["tools"] as? [Any]
        #expect(tools?.isEmpty == true)
        #expect(sessionManager.sentUpstreamCount() == 0)
    }

    @Test func httpForwardedSingleItemBatchToolsListRewritesDescription() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/list")
                return .immediate(
                    try makeToolResultResponse(
                        id: originalID,
                        result: [
                            "tools": [
                                [
                                    "name": "XcodeRefreshCodeIssuesInFile",
                                    "description": "generic upstream description",
                                ],
                                [
                                    "name": "OtherTool",
                                    "description": "other",
                                ],
                            ]
                        ]
                    )
                )
            }
        )
        sessionManager.setInitialized(true)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [[String: Any]] = [[
            "jsonrpc": "2.0",
            "id": 22,
            "method": "tools/list",
        ]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: "session-forwarded-batch-tools-list")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)

        let responseArray =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [[String: Any]]
        let responseObject = try #require(responseArray?.first)
        let result = responseObject["result"] as? [String: Any]
        let tools = try #require(result?["tools"] as? [[String: Any]])
        let refreshTool = tools.first { $0["name"] as? String == "XcodeRefreshCodeIssuesInFile" }
        let description = refreshTool?["description"] as? String
        #expect(description?.contains("--refresh-code-issues-mode upstream") == true)
        #expect(sessionManager.sentUpstreamCount() == 1)
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
        #expect(description?.contains("avoid switching Spaces") == true)
        #expect(description?.contains("--refresh-code-issues-mode upstream") == true)
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
        #expect(description?.contains("native live diagnostics path") == true)
    }

    @Test func httpToolsListHidesDisabledToolsOnForwardedMiss() async throws {
        var config = makeConfig()
        config.refreshCodeIssuesMode = .proxy
        config.disabledToolNames = ["RunAllTests", "RunSomeTests"]
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
                            "name": "RunAllTests",
                            "description": "blocked",
                        ],
                        [
                            "name": "RunSomeTests",
                            "description": "blocked",
                        ],
                        [
                            "name": "XcodeRefreshCodeIssuesInFile",
                            "description": "original description",
                        ],
                    ]
                ],
            ]
            return try JSONSerialization.data(withJSONObject: response, options: [])
        }
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let sessionID = try initializeHTTPChannel(channel)
        try postJSON(
            [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
            ],
            sessionID: sessionID,
            to: channel
        )

        let response = try collectResponse(from: channel)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
                as? [String: Any]
        )
        let result = try #require(object["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["XcodeRefreshCodeIssuesInFile"])
        #expect((tools.first?["description"] as? String)?.contains("avoid switching Spaces") == true)

        let cachedResult = try #require(sessionManager.cachedToolsListResult())
        let cachedObject = try #require(cachedResult.foundationObject as? [String: Any])
        let cachedTools = try #require(cachedObject["tools"] as? [[String: Any]])
        #expect(cachedTools.count == 3)
    }

    @Test func httpToolsListHidesDisabledToolsOnCachedResponse() async throws {
        var config = makeConfig()
        config.refreshCodeIssuesMode = .upstream
        config.disabledToolNames = ["RunAllTests", "RunSomeTests"]
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        sessionManager.setCachedToolsListResult(
            JSONValue(any: [
                "tools": [
                    [
                        "name": "RunAllTests",
                        "description": "blocked",
                    ],
                    [
                        "name": "RunSomeTests",
                        "description": "blocked",
                    ],
                    [
                        "name": "XcodeRefreshCodeIssuesInFile",
                        "description": "original description",
                    ],
                ]
            ])!
        )
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let sessionID = try initializeHTTPChannel(channel)
        try postJSON(
            [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
            ],
            sessionID: sessionID,
            to: channel
        )

        let response = try collectResponse(from: channel)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
                as? [String: Any]
        )
        let result = try #require(object["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["XcodeRefreshCodeIssuesInFile"])
        #expect((tools.first?["description"] as? String)?.contains("native live diagnostics path") == true)
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

    @Test func httpToolCallNormalizesColdSchemaWithoutCatalogPrewarm() async throws {
        let config = makeConfig(requestTimeout: 2)
        let documentationRequests = NIOLockedValueBox<[String]>([])
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            documentationSearchResponder: { requestData in
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let params = try #require(object["params"] as? [String: Any])
                let arguments = try #require(params["arguments"] as? [String: Any])
                documentationRequests.withLockedValue { requests in
                    requests.append(arguments["query"] as? String ?? "")
                }
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(RPCID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"ok\"}"
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
                sessionID: "session-schema-cold",
                payload: toolsCallPayload(
                    id: 61,
                    name: "DocumentationSearch",
                    arguments: [
                        "query": "hello",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let structuredContent = result?["structuredContent"] as? [String: Any]
            #expect(structuredContent?["answer"] as? String == "ok")
            #expect(sessionManager.cachedToolsListResult() == nil)
            #expect(sessionManager.sentMethods() == [])
            #expect(sessionManager.sentToolNames() == [])
            #expect(documentationRequests.withLockedValue { $0 } == ["hello"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDocumentationSearchFallsThroughWhenNoDocumentationProviderExists() async throws {
        let config = makeConfig(requestTimeout: 2)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "DocumentationSearch")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "{\"answer\":\"upstream-docs\"}"
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
                sessionID: "session-docs-fallthrough",
                payload: toolsCallPayload(
                    id: 62,
                    name: "DocumentationSearch",
                    arguments: [
                        "query": "hello",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "{\"answer\":\"upstream-docs\"}")
            #expect(sessionManager.sentToolNames() == ["DocumentationSearch"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDocumentationSearchRoutesThroughInactiveDocumentationProvider() async throws {
        let config = makeConfig(requestTimeout: 2)
        let documentationRequests = NIOLockedValueBox<[String]>([])
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { _, _, originalID in
                Issue.record("DocumentationSearch should not be forwarded upstream")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "{\"answer\":\"upstream-docs\"}"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let params = try #require(object["params"] as? [String: Any])
                let arguments = try #require(params["arguments"] as? [String: Any])
                documentationRequests.withLockedValue { requests in
                    requests.append(arguments["query"] as? String ?? "")
                }
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(RPCID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"cold-docs\"}"
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
                sessionID: "session-docs-inactive-local",
                payload: toolsCallPayload(
                    id: 65,
                    name: "DocumentationSearch",
                    arguments: [
                        "query": "hello",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let structuredContent = result?["structuredContent"] as? [String: Any]
            #expect(structuredContent?["answer"] as? String == "cold-docs")
            #expect(sessionManager.sentToolNames() == [])
            #expect(documentationRequests.withLockedValue { $0 } == ["hello"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDocumentationSearchFallsBackWhenInactiveProviderIsUnavailable() async throws {
        let config = makeConfig(requestTimeout: 2)
        let localDocumentationRequests = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "DocumentationSearch")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "{\"answer\":\"upstream-docs\"}"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                _ = requestData
                localDocumentationRequests.withLockedValue { $0 += 1 }
                throw UpstreamSlotAcquisitionError.unavailable
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
                sessionID: "session-docs-inactive-fallback",
                payload: toolsCallPayload(
                    id: 66,
                    name: "DocumentationSearch",
                    arguments: [
                        "query": "hello",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "{\"answer\":\"upstream-docs\"}")
            #expect(sessionManager.sentToolNames() == ["DocumentationSearch"])
            #expect(localDocumentationRequests.withLockedValue { $0 } == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchDocumentationSearchFallsThroughWhenNoDocumentationProviderExists() async throws {
        let config = makeConfig(requestTimeout: 2)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: toolName == "DocumentationSearch"
                            ? "{\"answer\":\"upstream-docs\"}"
                            : "other-tool-result"
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
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-docs-batch-fallthrough",
                payload: [
                    toolsCallPayload(
                        id: 63,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "hello",
                        ]
                    ),
                    toolsCallPayload(
                        id: 64,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)
            let docs = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 63 }
            let docsResult = docs?["result"] as? [String: Any]
            let docsContent = docsResult?["content"] as? [[String: Any]]
            #expect(docsContent?.first?["text"] as? String == "{\"answer\":\"upstream-docs\"}")
            let other = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 64 }
            let otherResult = other?["result"] as? [String: Any]
            let otherContent = otherResult?["content"] as? [[String: Any]]
            #expect(otherContent?.first?["text"] as? String == "other-tool-result")
            #expect(sessionManager.sentToolNames() == ["DocumentationSearch", "OtherAllowedTool"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchRoutesDocumentationSearchThroughProviderAndForwardsOtherCalls() async throws {
        let config = makeConfig(requestTimeout: 2)
        let documentationRequests = NIOLockedValueBox<[String]>([])
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "OtherAllowedTool")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "other-tool-result"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let params = try #require(object["params"] as? [String: Any])
                let arguments = try #require(params["arguments"] as? [String: Any])
                documentationRequests.withLockedValue { requests in
                    requests.append(arguments["query"] as? String ?? "")
                }
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(RPCID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"docs\"}"
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-docs-batch",
                payload: [
                    toolsCallPayload(
                        id: 701,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "UIView animate",
                        ]
                    ),
                    toolsCallPayload(
                        id: 702,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)

            let docs = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 701 }
            let docsResult = docs?["result"] as? [String: Any]
            let structuredContent = docsResult?["structuredContent"] as? [String: Any]
            #expect(structuredContent?["answer"] as? String == "docs")

            let other = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 702 }
            let otherResult = other?["result"] as? [String: Any]
            let otherContent = otherResult?["content"] as? [[String: Any]]
            #expect(otherContent?.first?["text"] as? String == "other-tool-result")

            #expect(sessionManager.sentToolNames() == ["OtherAllowedTool"])
            #expect(documentationRequests.withLockedValue { $0 } == ["UIView animate"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchForwardsDocumentationSearchNotificationWithProvider() async throws {
        let config = makeConfig(requestTimeout: 2)
        let documentationRequests = NIOLockedValueBox<[String]>([])
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "OtherAllowedTool")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "other-tool-result"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let params = try #require(object["params"] as? [String: Any])
                let arguments = try #require(params["arguments"] as? [String: Any])
                documentationRequests.withLockedValue { requests in
                    requests.append(arguments["query"] as? String ?? "")
                }
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(RPCID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"docs\"}"
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-docs-batch-notification",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "method": "tools/call",
                        "params": [
                            "name": "DocumentationSearch",
                            "arguments": [
                                "query": "UIView notification",
                            ],
                        ],
                    ],
                    toolsCallPayload(
                        id: 703,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 1)

            let other = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 703 }
            let otherResult = other?["result"] as? [String: Any]
            let otherContent = otherResult?["content"] as? [[String: Any]]
            #expect(otherContent?.first?["text"] as? String == "other-tool-result")

            #expect(sessionManager.sentToolNames() == [
                "DocumentationSearch",
                "OtherAllowedTool",
            ])
            #expect(documentationRequests.withLockedValue { $0 }.isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchForwardsOtherCallsWhileDocumentationSearchIsStillResolving() async throws {
        let config = makeConfig(requestTimeout: 2)
        let documentationStarted = NIOLockedValueBox(false)
        let releaseDocumentation = DispatchSemaphore(value: 0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "OtherAllowedTool")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "other-tool-result"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                documentationStarted.withLockedValue { $0 = true }
                _ = releaseDocumentation.wait(timeout: .now() + 2)
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(RPCID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"docs\"}"
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )
        defer {
            releaseDocumentation.signal()
        }

        do {
            let postTask = Task {
                try await postHTTPAnyData(
                    url: server.url,
                    sessionID: "session-docs-batch-forwarding-not-blocked",
                    payload: [
                        toolsCallPayload(
                            id: 721,
                            name: "DocumentationSearch",
                            arguments: [
                                "query": "UIView animate",
                            ]
                        ),
                        toolsCallPayload(
                            id: 722,
                            name: "OtherAllowedTool",
                            arguments: [:]
                        ),
                    ]
                )
            }

            let didStartDocumentation = await waitUntil(timeout: .seconds(1)) {
                documentationStarted.withLockedValue { $0 }
            }
            #expect(didStartDocumentation)
            let didForwardOtherTool = await waitUntil(timeout: .seconds(1)) {
                sessionManager.sentToolNames() == ["OtherAllowedTool"]
            }
            #expect(didForwardOtherTool)
            releaseDocumentation.signal()

            let rawResponse = try await postTask.value
            #expect(rawResponse.statusCode == 200)
            let bodyData = try JSONSerialization.jsonObject(
                with: rawResponse.bodyData,
                options: []
            )
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)
            let docs = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 721 }
            let docsResult = docs?["result"] as? [String: Any]
            let structuredContent = docsResult?["structuredContent"] as? [String: Any]
            #expect(structuredContent?["answer"] as? String == "docs")
            let other = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 722 }
            let otherResult = other?["result"] as? [String: Any]
            let otherContent = otherResult?["content"] as? [[String: Any]]
            #expect(otherContent?.first?["text"] as? String == "other-tool-result")
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchToolsListUsesLocalToolSurfaceAndForwardsOtherCalls() async throws {
        let config = makeConfig(requestTimeout: 2)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "OtherAllowedTool")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "other-tool-result"
                    )
                )
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setCachedToolsListResult(
            JSONValue(any: [
                "tools": [
                    [
                        "name": "DocumentationSearch",
                        "description": "docs provider",
                    ],
                    [
                        "name": "XcodeRead",
                        "description": "read",
                    ],
                ],
            ])!
        )
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-tools-list-batch-local",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "id": 731,
                        "method": "tools/list",
                    ],
                    toolsCallPayload(
                        id: 732,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)

            let toolsList = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 731 }
            let toolsResult = toolsList?["result"] as? [String: Any]
            let tools = try #require(toolsResult?["tools"] as? [[String: Any]])
            #expect(tools.map { $0["name"] as? String }.contains("DocumentationSearch"))

            let other = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 732 }
            let otherResult = other?["result"] as? [String: Any]
            let otherContent = otherResult?["content"] as? [[String: Any]]
            #expect(otherContent?.first?["text"] as? String == "other-tool-result")

            #expect(sessionManager.sentMethods() == ["tools/call"])
            #expect(sessionManager.sentToolNames() == ["OtherAllowedTool"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchRoutesDocumentationSearchAfterSameBatchToolsListActivatesProvider() async throws {
        let config = makeConfig(requestTimeout: 2)
        let documentationRequests = NIOLockedValueBox<[String]>([])
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "OtherAllowedTool")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "other-tool-result"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let params = try #require(object["params"] as? [String: Any])
                let arguments = try #require(params["arguments"] as? [String: Any])
                documentationRequests.withLockedValue { requests in
                    requests.append(arguments["query"] as? String ?? "")
                }
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(RPCID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"docs\"}"
                )
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setCachedToolsListResult(
            JSONValue(any: [
                "tools": [
                    [
                        "name": "DocumentationSearch",
                        "description": "docs provider",
                    ],
                    [
                        "name": "XcodeRead",
                        "description": "read",
                    ],
                ],
            ])!
        )
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-tools-list-activates-docs-route",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "id": 741,
                        "method": "tools/list",
                    ],
                    toolsCallPayload(
                        id: 742,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "UIView same batch",
                        ]
                    ),
                    toolsCallPayload(
                        id: 743,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 3)

            let toolsList = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 741 }
            let toolsResult = toolsList?["result"] as? [String: Any]
            let tools = try #require(toolsResult?["tools"] as? [[String: Any]])
            #expect(tools.map { $0["name"] as? String }.contains("DocumentationSearch"))

            let docs = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 742 }
            let docsResult = docs?["result"] as? [String: Any]
            let structuredContent = docsResult?["structuredContent"] as? [String: Any]
            #expect(structuredContent?["answer"] as? String == "docs")

            let other = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 743 }
            let otherResult = other?["result"] as? [String: Any]
            let otherContent = otherResult?["content"] as? [[String: Any]]
            #expect(otherContent?.first?["text"] as? String == "other-tool-result")

            #expect(sessionManager.sentToolNames() == ["OtherAllowedTool"])
            #expect(documentationRequests.withLockedValue { $0 } == ["UIView same batch"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchFallsBackDocumentationSearchWhenSameBatchToolsListDoesNotActivateProvider()
        async throws
    {
        let config = makeConfig(requestTimeout: 2)
        let localDocumentationRequests = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "DocumentationSearch")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "{\"answer\":\"upstream-docs\"}"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                _ = requestData
                localDocumentationRequests.withLockedValue { $0 += 1 }
                throw UpstreamSlotAcquisitionError.unavailable
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setCachedToolsListResult(
            JSONValue(any: [
                "tools": [
                    [
                        "name": "XcodeRead",
                        "description": "read",
                    ],
                ],
            ])!
        )
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-tools-list-docs-fallback",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "id": 751,
                        "method": "tools/list",
                    ],
                    toolsCallPayload(
                        id: 752,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "UIView same batch fallback",
                        ]
                    ),
                ]
            )

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)

            let toolsList = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 751 }
            let toolsResult = toolsList?["result"] as? [String: Any]
            let tools = try #require(toolsResult?["tools"] as? [[String: Any]])
            #expect(tools.map { $0["name"] as? String }.contains("DocumentationSearch") == false)

            let docs = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 752 }
            let docsResult = docs?["result"] as? [String: Any]
            let docsContent = docsResult?["content"] as? [[String: Any]]
            #expect(docsContent?.first?["text"] as? String == "{\"answer\":\"upstream-docs\"}")

            #expect(sessionManager.sentToolNames() == ["DocumentationSearch"])
            #expect(localDocumentationRequests.withLockedValue { $0 } == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchStartsDocumentationFallbackBeforeOtherForwardedRequestTimesOut()
        async throws
    {
        let config = makeConfig(requestTimeout: 0.25)
        let localDocumentationRequests = NIOLockedValueBox(0)
        let fallbackDocumentationRequests = NIOLockedValueBox(0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                if toolName == "DocumentationSearch" {
                    fallbackDocumentationRequests.withLockedValue { $0 += 1 }
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text: "{\"answer\":\"upstream-docs\"}"
                        )
                    )
                }
                #expect(toolName == "OtherAllowedTool")
                return .manual(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "other-tool-result"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                _ = requestData
                localDocumentationRequests.withLockedValue { $0 += 1 }
                throw UpstreamSlotAcquisitionError.unavailable
            }
        )
        sessionManager.setAvailableUpstreamIndices([0, 1])
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-docs-fallback-before-other-timeout",
                payload: [
                    toolsCallPayload(
                        id: 761,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "UIView fallback before timeout",
                        ]
                    ),
                    toolsCallPayload(
                        id: 762,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)

            let docs = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 761 }
            let docsResult = docs?["result"] as? [String: Any]
            let docsContent = docsResult?["content"] as? [[String: Any]]
            #expect(docsContent?.first?["text"] as? String == "{\"answer\":\"upstream-docs\"}")

            let other = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 762 }
            let otherError = other?["error"] as? [String: Any]
            #expect(otherError?["message"] as? String == "upstream timeout")

            #expect(sessionManager.sentToolRequests() == [
                "OtherAllowedTool@0",
                "DocumentationSearch@1",
            ])
            #expect(localDocumentationRequests.withLockedValue { $0 } == 1)
            #expect(fallbackDocumentationRequests.withLockedValue { $0 } == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchDocumentationSearchSharesSingleDeadline() async throws {
        let config = makeConfig(requestTimeout: 0.1)
        let documentationRequests = NIOLockedValueBox<[String]>([])
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            documentationSearchResponder: { requestData in
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let params = try #require(object["params"] as? [String: Any])
                let arguments = try #require(params["arguments"] as? [String: Any])
                let query = arguments["query"] as? String ?? ""
                documentationRequests.withLockedValue { requests in
                    requests.append(query)
                }
                Thread.sleep(forTimeInterval: 0.2)
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(RPCID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"\(query)\"}"
                )
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-docs-batch-deadline",
                payload: [
                    toolsCallPayload(
                        id: 711,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "first",
                        ]
                    ),
                    toolsCallPayload(
                        id: 712,
                        name: "DocumentationSearch",
                        arguments: [
                            "query": "second",
                        ]
                    ),
                ]
            )

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)

            let first = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 711 }
            #expect(first?["result"] != nil)

            let second = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 712 }
            let secondError = try #require(second?["error"] as? [String: Any])
            #expect((secondError["code"] as? NSNumber)?.intValue == -32000)
            #expect(secondError["message"] as? String == "upstream timeout")
            #expect(documentationRequests.withLockedValue { $0 } == ["first"])
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func httpSingleDocumentationSearchCancellationAbandonsPrefilterLease() async throws {
        let config = makeConfig(requestTimeout: 2)
        let documentationStarted = DispatchSemaphore(value: 0)
        let documentationRelease = DispatchSemaphore(value: 0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            documentationSearchResponder: { requestData in
                documentationStarted.signal()
                _ = documentationRelease.wait(timeout: .now() + 2)
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(RPCID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"cancelled\"}"
                )
            }
        )
        sessionManager.setInitialized(true)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let service = HTTPPostService(
                config: config,
                sessionManager: sessionManager,
                refreshCodeIssuesCoordinator: .makeDefault(),
                refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState(
                    defaultRequestTimeoutSeconds: config.requestTimeout
                )
            )
            let payload = toolsCallPayload(
                id: 720,
                name: "DocumentationSearch",
                arguments: [
                    "query": "UIView",
                ]
            )
            let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [])
            let operation = service.handle(
                bodyData: bodyData,
                headerSessionID: "session-docs-single-cancel",
                headerSessionExists: true,
                prefersEventStream: false,
                eventLoop: group.next()
            )
            let cancellationHandle = try #require(operation.cancellationHandle)

            try #require(await waitForHTTPTestSemaphore(documentationStarted, timeoutSeconds: 1) == .success)
            service.cancel(cancellationHandle)
            documentationRelease.signal()

            do {
                _ = try await operation.future.get()
                Issue.record("cancelled documentation request should not complete successfully")
            } catch {
                #expect(error is CancellationError)
            }
            let abandonedLease = try #require(
                sessionManager.leaseDebugSnapshots().first { $0.state == .abandoned }
            )
            #expect(abandonedLease.releaseReason == "clientDisconnected")
            #expect(sessionManager.sentToolNames().isEmpty)
            try await group.shutdownGracefully()
        } catch {
            documentationRelease.signal()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test func httpBatchDocumentationSearchCancellationAbandonsPrefilterLease() async throws {
        let config = makeConfig(requestTimeout: 2)
        let documentationStarted = DispatchSemaphore(value: 0)
        let documentationRelease = DispatchSemaphore(value: 0)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "OtherAllowedTool")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "other-tool-result"
                    )
                )
            },
            documentationSearchResponder: { requestData in
                documentationStarted.signal()
                _ = documentationRelease.wait(timeout: .now() + 2)
                let object = try #require(
                    JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                )
                let originalIDValue = try #require(object["id"])
                let originalID = try #require(RPCID(any: originalIDValue))
                return try makeToolSuccessResponse(
                    id: originalID,
                    text: "{\"answer\":\"cancelled\"}"
                )
            }
        )
        sessionManager.setInitialized(true)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let service = HTTPPostService(
                config: config,
                sessionManager: sessionManager,
                refreshCodeIssuesCoordinator: .makeDefault(),
                refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState(
                    defaultRequestTimeoutSeconds: config.requestTimeout
                )
            )
            let payload: [[String: Any]] = [
                toolsCallPayload(
                    id: 721,
                    name: "DocumentationSearch",
                    arguments: [
                        "query": "UIView",
                    ]
                ),
                toolsCallPayload(
                    id: 722,
                    name: "OtherAllowedTool",
                    arguments: [:]
                ),
            ]
            let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [])
            let operation = service.handle(
                bodyData: bodyData,
                headerSessionID: "session-docs-batch-cancel",
                headerSessionExists: true,
                prefersEventStream: false,
                eventLoop: group.next()
            )
            let cancellationHandle = try #require(operation.cancellationHandle)

            try #require(await waitForHTTPTestSemaphore(documentationStarted, timeoutSeconds: 1) == .success)
            service.cancel(cancellationHandle)
            documentationRelease.signal()

            do {
                _ = try await operation.future.get()
                Issue.record("cancelled documentation batch should not complete successfully")
            } catch {
                #expect(error is CancellationError)
            }
            let abandonedLease = try #require(
                sessionManager.leaseDebugSnapshots().first { $0.state == .abandoned }
            )
            #expect(abandonedLease.releaseReason == "clientDisconnected")
            #expect(sessionManager.sentToolNames() == ["OtherAllowedTool"])
            try await group.shutdownGracefully()
        } catch {
            documentationRelease.signal()
            try? await group.shutdownGracefully()
            throw error
        }
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

    @Test func httpSingleItemBatchResourcesListReturnsEmptyArray() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [[String: Any]] = [[
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/list",
            "params": [String: Any](),
        ]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: "session-batch-resources")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)

        let responseArray =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [[String: Any]]
        let responseObject = try #require(responseArray?.first)
        #expect((responseObject["id"] as? NSNumber)?.intValue == 1)
        let result = responseObject["result"] as? [String: Any]
        let resources = result?["resources"] as? [Any]
        #expect(resources?.isEmpty == true)
    }

    @Test func httpForwardedSingleItemBatchResourcesListRewritesUnsupportedResponse() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "resources/list")
                let response: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": originalID.value.foundationObject,
                    "error": [
                        "code": -32601,
                        "message": "Method not found",
                    ],
                ]
                return .immediate(try JSONSerialization.data(withJSONObject: response, options: []))
            }
        )
        sessionManager.setInitialized(true)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [[String: Any]] = [[
            "jsonrpc": "2.0",
            "id": 31,
            "method": "resources/list",
            "params": [String: Any](),
        ]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: "session-forwarded-batch-resources-list")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)

        let responseArray =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [[String: Any]]
        let responseObject = try #require(responseArray?.first)
        let result = responseObject["result"] as? [String: Any]
        let resources = result?["resources"] as? [Any]
        #expect(resources?.isEmpty == true)
        #expect(sessionManager.sentUpstreamCount() == 1)
    }

    @Test func forwardingServiceSelectsMatchingObjectFromMultiItemBatchResponse() throws {
        let responseData = try JSONSerialization.data(
            withJSONObject: [
                [
                    "jsonrpc": "2.0",
                    "id": "other",
                    "result": [
                        "content": [
                            [
                                "type": "text",
                                "text": "other",
                            ]
                        ]
                    ],
                ],
                [
                    "jsonrpc": "2.0",
                    "id": "wanted",
                    "result": [
                        "content": [
                            [
                                "type": "text",
                                "text": "wanted",
                            ]
                        ]
                    ],
                ],
            ],
            options: []
        )

        let object = ToolSurface.responseObject(
            from: responseData,
            matching: "wanted"
        )

        #expect(object?["id"] as? String == "wanted")
    }

    @Test func forwardingServiceRewritesSingleObjectResourcesListResponseUsingResponseIDMap()
        throws
    {
        let config = makeConfig()
        let sessionManager = TestRuntimeCoordinator(config: config)
        let forwardingService = MCPForwardingService(
            config: config,
            sessionManager: sessionManager
        )

        let requestData = try JSONSerialization.data(
            withJSONObject: [[
                "jsonrpc": "2.0",
                "id": 91,
                "method": "resources/list",
                "params": [String: Any](),
            ]],
            options: []
        )
        let transform = try RequestInspector.transform(
            requestData,
            sessionID: "session-batch-object-rewrite",
            mapID: { _, _ in 4001 }
        )

        let responseData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": 91,
                "error": [
                    "code": -32601,
                    "message": "Method not found",
                ],
            ],
            options: []
        )
        var buffer = ByteBufferAllocator().buffer(capacity: responseData.count)
        buffer.writeBytes(responseData)
        let eventLoop = EmbeddedEventLoop()
        let started = MCPForwardingService.StartedRequest(
            transform: transform,
            upstreamIndex: 0,
            requestTimeout: nil,
            routerPendingToken: UUID(),
            future: eventLoop.makeSucceededFuture(buffer)
        )

        let resolution = forwardingService.resolveResponse(
            .success(buffer),
            started: started,
            sessionID: "session-batch-object-rewrite"
        )

        guard case .success(let rewrittenData) = resolution,
            let rewrittenObject = try JSONSerialization.jsonObject(
                with: rewrittenData,
                options: []
            ) as? [String: Any],
            let result = rewrittenObject["result"] as? [String: Any],
            let resources = result["resources"] as? [Any]
        else {
            Issue.record("expected resources/list response to be rewritten to an empty list")
            return
        }

        #expect(resources.isEmpty)
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
            let sentToolRequests = sessionManager.sentToolRequests()
            #expect(sentToolRequests.count == 2)
            #expect(sentToolRequests.contains { $0.hasPrefix("XcodeListWindows@") })
            #expect(sentToolRequests.contains { $0.hasPrefix("XcodeListNavigatorIssues@") })
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpSingleElementBatchRefreshCodeIssuesUsesNavigatorIssuesProxyByDefault() async throws {
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
                                "{\"message\":\"* tabIdentifier: windowtab-proxy-batch, workspacePath: \(workspacePath)\"}"
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
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-proxy-batch",
                payload: [
                    toolsCallPayload(
                        id: 130,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-proxy-batch",
                            "filePath": "App/Sources/App.swift",
                        ]
                    )
                ]
            )

            #expect(response.statusCode == 200)
            let body: [String: Any]
            if let object = bodyData as? [String: Any] {
                body = object
            } else if let array = bodyData as? [[String: Any]],
                let first = array.first
            {
                body = first
            } else {
                Issue.record("expected single refresh batch response payload")
                return
            }
            let result = body["result"] as? [String: Any]
            let structuredContent = result?["structuredContent"] as? [String: Any]
            let issues = structuredContent?["issues"] as? [[String: Any]]
            #expect((structuredContent?["totalFound"] as? NSNumber)?.intValue == 1)
            #expect(issues?.count == 1)
            #expect(issues?.first?["path"] as? String == target.path)
            #expect(sessionManager.sentToolNames() == [
                "XcodeListWindows",
                "XcodeListNavigatorIssues",
            ])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpMixedBatchKeepsRefreshProxyAndAllowedResponses() async throws {
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
                if method == "tools/call" {
                    switch toolName {
                    case "XcodeListWindows":
                        return .immediate(
                            try makeToolSuccessResponse(
                                id: originalID,
                                text:
                                    "{\"message\":\"* tabIdentifier: windowtab-proxy-mixed, workspacePath: \(workspacePath)\"}"
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
                    case "OtherAllowedTool":
                        return .immediate(
                            try makeToolSuccessResponse(
                                id: originalID,
                                text: "other-tool-result"
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
                return .immediate(Data())
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-proxy-mixed",
                payload: [
                    toolsCallPayload(
                        id: 230,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-proxy-mixed",
                            "filePath": "App/Sources/App.swift",
                        ]
                    ),
                    toolsCallPayload(
                        id: 231,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )

            #expect(response.statusCode == 200)
            let body = try #require(bodyData as? [[String: Any]])
            #expect(body.count == 2)
            let refreshResult = try #require(
                body.first(where: { ($0["id"] as? NSNumber)?.intValue == 230 })?["result"] as? [String: Any]
            )
            let structuredContent = refreshResult["structuredContent"] as? [String: Any]
            #expect((structuredContent?["totalFound"] as? NSNumber)?.intValue == 1)
            let otherResult = try #require(
                body.first(where: { ($0["id"] as? NSNumber)?.intValue == 231 })?["result"] as? [String: Any]
            )
            let otherContent = otherResult["content"] as? [[String: Any]]
            #expect(otherContent?.first?["text"] as? String == "other-tool-result")
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpMixedBatchReturnsInvalidRequestForScalarLeftoverAfterRefreshSplit() async throws {
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
                if method == "tools/call" {
                    switch toolName {
                    case "XcodeListWindows":
                        return .immediate(
                            try makeToolSuccessResponse(
                                id: originalID,
                                text:
                                    "{\"message\":\"* tabIdentifier: windowtab-proxy-scalar-leftover, workspacePath: \(workspacePath)\"}"
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
                    default:
                        return .immediate(
                            try makeToolErrorResponse(
                                id: originalID,
                                text: "unexpected tool"
                            )
                        )
                    }
                }
                return .immediate(Data())
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-proxy-scalar-leftover",
                payload: [
                    toolsCallPayload(
                        id: 330,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-proxy-scalar-leftover",
                            "filePath": "App/Sources/App.swift",
                        ]
                    ),
                    NSNull(),
                ]
            )

            #expect(response.statusCode == 200)
            let body = try #require(bodyData as? [[String: Any]])
            #expect(body.count == 2)

            let refreshResult = try #require(
                body.first(where: { ($0["id"] as? NSNumber)?.intValue == 330 })?["result"] as? [String: Any]
            )
            let structuredContent = refreshResult["structuredContent"] as? [String: Any]
            #expect((structuredContent?["totalFound"] as? NSNumber)?.intValue == 1)

            let invalidRequest = try #require(
                body.first(where: { $0["id"] is NSNull })
            )
            let error = try #require(invalidRequest["error"] as? [String: Any])
            #expect((error["code"] as? NSNumber)?.intValue == -32600)
            #expect(error["message"] as? String == "invalid request")
            #expect(sessionManager.sentToolNames() == [
                "XcodeListWindows",
                "XcodeListNavigatorIssues",
            ])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpMixedBatchPreservesNotificationLeftoverWhenScalarIsStripped() async throws {
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
                switch method {
                case "tools/call":
                    switch toolName {
                    case "XcodeListWindows":
                        return .immediate(
                            try makeToolSuccessResponse(
                                id: originalID,
                                text:
                                    "{\"message\":\"* tabIdentifier: windowtab-proxy-notification-leftover, workspacePath: \(workspacePath)\"}"
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
                    default:
                        return .immediate(
                            try makeToolErrorResponse(
                                id: originalID,
                                text: "unexpected tool"
                            )
                        )
                    }
                default:
                    return .immediate(Data())
                }
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-proxy-notification-leftover",
                payload: [
                    toolsCallPayload(
                        id: 340,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-proxy-notification-leftover",
                            "filePath": "App/Sources/App.swift",
                        ]
                    ),
                    [
                        "jsonrpc": "2.0",
                        "method": "notifications/progress",
                        "params": [
                            "value": "tick"
                        ],
                    ],
                    NSNull(),
                ]
            )

            #expect(response.statusCode == 200)
            let body = try #require(bodyData as? [[String: Any]])
            #expect(body.count == 2)
            #expect(sessionManager.sentMethods().contains("notifications/progress"))

            let refreshResult = try #require(
                body.first(where: { ($0["id"] as? NSNumber)?.intValue == 340 })?["result"] as? [String: Any]
            )
            let structuredContent = refreshResult["structuredContent"] as? [String: Any]
            #expect((structuredContent?["totalFound"] as? NSNumber)?.intValue == 1)

            let invalidRequest = try #require(
                body.first(where: { $0["id"] is NSNull })
            )
            let error = try #require(invalidRequest["error"] as? [String: Any])
            #expect((error["code"] as? NSNumber)?.intValue == -32600)
            #expect(error["message"] as? String == "invalid request")
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpMixedBatchRefreshRetryDoesNotReplayAllowedCalls() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let refreshAttempts = NIOLockedValueBox(0)
        let otherAttempts = NIOLockedValueBox(0)

        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                if method == "tools/list" {
                    return .immediate(
                        try makeToolResultResponse(
                            id: originalID,
                            result: [
                                "tools": [Any]()
                            ]
                        )
                    )
                }
                #expect(method == "tools/call")
                switch toolName {
                case "XcodeRefreshCodeIssuesInFile":
                    let attempt = refreshAttempts.withLockedValue { value in
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
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text: "refresh-ok"
                        )
                    )
                case "OtherAllowedTool":
                    otherAttempts.withLockedValue { value in
                        value += 1
                    }
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text: "other-tool-result"
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
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-upstream-mixed-retry",
                payload: [
                    toolsCallPayload(
                        id: 232,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-upstream-mixed-retry",
                            "filePath": "App.swift",
                        ]
                    ),
                    toolsCallPayload(
                        id: 233,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )

            #expect(response.statusCode == 200)
            let body = try #require(bodyData as? [[String: Any]])
            #expect(body.count == 2)
            let refreshResult = try #require(
                body.first(where: { ($0["id"] as? NSNumber)?.intValue == 232 })?["result"] as? [String: Any]
            )
            let refreshContent = refreshResult["content"] as? [[String: Any]]
            #expect(refreshContent?.first?["text"] as? String == "refresh-ok")
            let otherResult = try #require(
                body.first(where: { ($0["id"] as? NSNumber)?.intValue == 233 })?["result"] as? [String: Any]
            )
            let otherContent = otherResult["content"] as? [[String: Any]]
            #expect(otherContent?.first?["text"] as? String == "other-tool-result")
            #expect(refreshAttempts.withLockedValue { $0 } == 2)
            #expect(otherAttempts.withLockedValue { $0 } == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
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
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesFallsBackToUpstreamWhenNavigatorIssuesAreTruncated() async throws {
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
                                "{\"message\":\"* tabIdentifier: windowtab-truncated, workspacePath: \(workspacePath)\"}"
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
                                        "text": "{\"issues\":[],\"totalFound\":0,\"truncated\":true}"
                                    ]
                                ],
                                "structuredContent": [
                                    "issues": [],
                                    "totalFound": 0,
                                    "truncated": true,
                                ],
                            ]
                        )
                    )
                case "XcodeRefreshCodeIssuesInFile":
                    return .immediate(
                        try makeToolSuccessResponse(
                            id: originalID,
                            text: "upstream-after-truncated-navigator"
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
                sessionID: "session-truncated-navigator",
                payload: toolsCallPayload(
                    id: 19,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-truncated",
                        "filePath": "App/Sources/App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "upstream-after-truncated-navigator")
            #expect(sessionManager.sentToolNames() == [
                "XcodeListWindows",
                "XcodeListNavigatorIssues",
                "XcodeRefreshCodeIssuesInFile",
            ])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
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
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
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
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
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
        let coordinator = RefreshCodeIssuesCoordinator()
        let debugState = RefreshCodeIssuesDebugState(
            defaultRequestTimeoutSeconds: config.requestTimeout
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
            forwarder: { _, _, _, _, _, _, _ in
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

    @Test func refreshWorkflowDoesNotFabricateNavigatorTimeoutWhenRequestTimeoutIsDisabled() async throws {
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

        let config = makeConfig(requestTimeout: 0)
        let coordinator = RefreshCodeIssuesCoordinator()
        let debugState = RefreshCodeIssuesDebugState(
            defaultRequestTimeoutSeconds: config.requestTimeout
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
        let requestID = RPCID(any: NSNumber(value: 133))!
        let requestPayload = toolsCallPayload(
            id: 133,
            name: "XcodeRefreshCodeIssuesInFile",
            arguments: [
                "tabIdentifier": "windowtab-unbounded-timeout",
                "filePath": "App/Sources/App.swift",
            ]
        )
        let requestData = try JSONSerialization.data(withJSONObject: requestPayload, options: [])

        let result = await workflow.run(
            refreshRequest: RefreshCodeIssuesRequest(
                tabIdentifier: "windowtab-unbounded-timeout",
                filePath: "App/Sources/App.swift"
            ),
            bodyData: requestData,
            sessionID: "session-unbounded-timeout",
            requestIDs: [requestID],
            requestIsBatch: false,
            eventLoop: group.next(),
            windowsProvider: { _, _, _, _ in
                [
                    XcodeWindowInfo(
                        tabIdentifier: "windowtab-unbounded-timeout",
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
                return .success([
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
                ])
            },
            forwarder: { _, _, _, _, _, _, _ in
                Issue.record("unbounded timeout should not fall back to upstream")
                return .invalidRequest
            }
        )

        switch result {
        case .success(let responseData):
            let object = try #require(
                JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any]
            )
            let responseResult = object["result"] as? [String: Any]
            let structuredContent = responseResult?["structuredContent"] as? [String: Any]
            let issues = structuredContent?["issues"] as? [[String: Any]]
            #expect((structuredContent?["totalFound"] as? NSNumber)?.intValue == 1)
            #expect(issues?.first?["path"] as? String == target.path)
        default:
            Issue.record("expected workflow to keep proxy path when request timeout is disabled")
        }

        #expect(observedTimeouts.withLockedValue { $0.first } == -1)
    }

    @Test func refreshWorkflowPreservesCancellationWhenNavigatorIssuesCallIsCancelled()
        async throws
    {
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

        let coordinator = RefreshCodeIssuesCoordinator()
        let debugState = RefreshCodeIssuesDebugState(
            defaultRequestTimeoutSeconds: 2
        )
        let workflow = RefreshCodeIssuesWorkflow(
            mode: .proxy,
            requestTimeout: 2,
            coordinator: coordinator,
            targetResolver: RefreshCodeIssuesTargetResolver(),
            debugState: debugState,
            windowLookupTimeout: 0.2,
            navigatorIssuesTimeout: 0.05,
            logger: ProxyLogging.make("test.refresh")
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let requestID = RPCID(any: NSNumber(value: 144))!
        let requestPayload = toolsCallPayload(
            id: 144,
            name: "XcodeRefreshCodeIssuesInFile",
            arguments: [
                "tabIdentifier": "windowtab-cancelled-navigator",
                "filePath": "App/Sources/App.swift",
            ]
        )
        let requestData = try JSONSerialization.data(withJSONObject: requestPayload, options: [])

        let result = await workflow.run(
            refreshRequest: RefreshCodeIssuesRequest(
                tabIdentifier: "windowtab-cancelled-navigator",
                filePath: "App/Sources/App.swift"
            ),
            bodyData: requestData,
            sessionID: "session-cancelled-navigator",
            requestIDs: [requestID],
            requestIsBatch: false,
            eventLoop: group.next(),
            windowsProvider: { _, _, _, _ in
                [
                    XcodeWindowInfo(
                        tabIdentifier: "windowtab-cancelled-navigator",
                        workspacePath: workspacePath
                    )
                ]
            },
            internalUpstreamChooser: { _ in 0 },
            internalToolCaller: { name, _, _, _, _, _ in
                #expect(name == "XcodeListNavigatorIssues")
                return .cancelled
            },
            forwarder: { _, _, _, _, _, _, _ in
                Issue.record("cancelled navigator lookup should not fall back upstream")
                return .invalidRequest
            }
        )

        guard case .cancelled(let responseIDs, let isBatch) = result else {
            Issue.record("expected cancelled result")
            return
        }
        #expect(responseIDs.map(\.key) == [requestID.key])
        #expect(isBatch == false)
    }

    @Test func refreshWorkflowPreservesBackslashesInNavigatorGlob() async throws {
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("Group\\Folder/App.swift")
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
        let coordinator = RefreshCodeIssuesCoordinator()
        let debugState = RefreshCodeIssuesDebugState(
            defaultRequestTimeoutSeconds: config.requestTimeout
        )
        let workflow = RefreshCodeIssuesWorkflow(
            mode: .proxy,
            requestTimeout: config.requestTimeout,
            coordinator: coordinator,
            targetResolver: RefreshCodeIssuesTargetResolver(),
            debugState: debugState,
            logger: ProxyLogging.make("test.refresh")
        )
        let observedGlob = NIOLockedValueBox<String?>(nil)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let requestID = RPCID(any: NSNumber(value: 233))!
        let requestPayload = toolsCallPayload(
            id: 233,
            name: "XcodeRefreshCodeIssuesInFile",
            arguments: [
                "tabIdentifier": "windowtab-backslash",
                "filePath": "Group\\Folder/App.swift",
            ]
        )
        let requestData = try JSONSerialization.data(withJSONObject: requestPayload, options: [])

        let result = await workflow.run(
            refreshRequest: RefreshCodeIssuesRequest(
                tabIdentifier: "windowtab-backslash",
                filePath: "Group\\Folder/App.swift"
            ),
            bodyData: requestData,
            sessionID: "session-backslash",
            requestIDs: [requestID],
            requestIsBatch: false,
            eventLoop: group.next(),
            windowsProvider: { _, _, _, _ in
                [
                    XcodeWindowInfo(
                        tabIdentifier: "windowtab-backslash",
                        workspacePath: workspacePath
                    )
                ]
            },
            internalUpstreamChooser: { _ in 0 },
            internalToolCaller: { name, arguments, _, _, _, _ in
                guard name == "XcodeListNavigatorIssues" else {
                    return .unavailable
                }
                observedGlob.withLockedValue { $0 = arguments["glob"] as? String }
                return .success([
                    "content": [
                        [
                            "type": "text",
                            "text": "{\"issues\":[],\"totalFound\":0,\"truncated\":false}"
                        ]
                    ],
                    "structuredContent": [
                        "issues": [],
                        "totalFound": 0,
                        "truncated": false,
                    ],
                ])
            },
            forwarder: { _, _, _, _, _, _, _ in
                Issue.record("backslash-preserving proxy path should not fall back upstream")
                return .invalidRequest
            }
        )

        switch result {
        case .success:
            #expect(observedGlob.withLockedValue { $0 } == "**/Group\\Folder/App.swift")
        default:
            Issue.record("expected workflow to stay on proxy path for backslash-containing path")
        }
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
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
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
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpSingleElementBatchRefreshCodeIssuesRetriesSourceEditorErrorFive() async throws {
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
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-retry-batch",
                payload: [
                    toolsCallPayload(
                        id: 110,
                        name: "XcodeRefreshCodeIssuesInFile",
                        arguments: [
                            "tabIdentifier": "windowtab-retry-batch",
                            "filePath": "App.swift",
                        ]
                    )
                ]
            )

            #expect(response.statusCode == 200)
            let body: [String: Any]
            if let object = bodyData as? [String: Any] {
                body = object
            } else if let array = bodyData as? [[String: Any]],
                let first = array.first
            {
                body = first
            } else {
                Issue.record("expected single refresh batch response payload")
                return
            }
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) != true)
            #expect(sessionManager.sentUpstreamCount() == 2)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
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
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
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
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
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
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDisabledToolCallReturnsLocalToolErrorWithoutUpstream() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.disabledToolNames = ["RunAllTests"]
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { _, _ in
                Issue.record("disabled tool call should not reach upstream")
                return .immediate(Data())
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
                sessionID: "session-disabled-tool",
                payload: toolsCallPayload(
                    id: 101,
                    name: "RunAllTests",
                    arguments: [:]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) == true)
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "tool 'RunAllTests' is disabled by proxy config")
            #expect(sessionManager.sentToolNames().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDisabledToolCallReturnsLocalToolErrorWhenNoUpstreamIsAvailable() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.disabledToolNames = ["RunAllTests"]
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { _, _ in
                Issue.record("disabled tool call should not reach upstream")
                return .immediate(Data())
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setAvailableUpstreamIndex(nil)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-disabled-tool-no-upstream",
                payload: toolsCallPayload(
                    id: 111,
                    name: "RunAllTests",
                    arguments: [:]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) == true)
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "tool 'RunAllTests' is disabled by proxy config")
            #expect(sessionManager.sentToolNames().isEmpty)
            #expect(sessionManager.chooseUpstreamIndexCallCount() == 0)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDisabledToolNotificationReturnsAcceptedWithoutUpstream() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.disabledToolNames = ["RunAllTests"]
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { _, _ in
                Issue.record("disabled tool notification should not reach upstream")
                return .immediate(Data())
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let rawResponse = try await postHTTPData(
                url: server.url,
                sessionID: "session-disabled-notification",
                payload: [
                    "jsonrpc": "2.0",
                    "method": "tools/call",
                    "params": [
                        "name": "RunAllTests",
                        "arguments": [:],
                    ],
                ]
            )

            #expect(rawResponse.statusCode == 202)
            #expect(rawResponse.bodyData.isEmpty)
            #expect(sessionManager.sentToolNames().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpMixedBatchDropsDisabledNotificationBeforeForwardingAllowedCalls() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.disabledToolNames = ["RunAllTests"]
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                if method == "tools/list" {
                    return .immediate(
                        try makeToolResultResponse(
                            id: originalID,
                            result: [
                                "tools": [Any]()
                            ]
                        )
                    )
                }
                #expect(method == "tools/call")
                #expect(toolName == "OtherAllowedTool")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "other-tool-result"
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
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-disabled-notification-mixed",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "method": "tools/call",
                        "params": [
                            "name": "RunAllTests",
                            "arguments": [:],
                        ],
                    ],
                    toolsCallPayload(
                        id: 441,
                        name: "OtherAllowedTool",
                        arguments: [:]
                    ),
                ]
            )

            #expect(response.statusCode == 200)
            let body: [String: Any]
            if let object = bodyData as? [String: Any] {
                body = object
            } else if let array = bodyData as? [[String: Any]],
                let first = array.first
            {
                body = first
            } else {
                Issue.record("expected forwarded allowed tool response payload")
                return
            }
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "other-tool-result")
            #expect(sessionManager.sentToolNames() == ["OtherAllowedTool"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDisabledToolBatchReturnsLocalAndQueueErrorsWhenNoUpstreamIsAvailable() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.disabledToolNames = ["RunAllTests"]
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { _, _, _ in
                Issue.record("batch should fail before reaching upstream")
                return .immediate(Data())
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setAvailableUpstreamIndex(nil)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-disabled-batch-no-upstream",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "id": 211,
                        "method": "tools/call",
                        "params": [
                            "name": "RunAllTests",
                            "arguments": [:],
                        ],
                    ],
                    [
                        "jsonrpc": "2.0",
                        "id": 212,
                        "method": "tools/call",
                        "params": [
                            "name": "XcodeListWindows",
                            "arguments": [:],
                        ],
                    ],
                ]
            )

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)

            let blocked = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 211 }
            let blockedResult = blocked?["result"] as? [String: Any]
            let blockedContent = blockedResult?["content"] as? [[String: Any]]
            #expect((blockedResult?["isError"] as? Bool) == true)
            #expect(blockedContent?.first?["text"] as? String == "tool 'RunAllTests' is disabled by proxy config")

            let forwarded = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 212 }
            let forwardedError = forwarded?["error"] as? [String: Any]
            #expect((forwardedError?["code"] as? NSNumber)?.intValue == -32001)
            #expect(forwardedError?["message"] as? String == "upstream unavailable")

            #expect(sessionManager.sentToolNames().isEmpty)
            #expect(sessionManager.chooseUpstreamIndexCallCount() == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDisabledToolBatchReturnsLocalErrorsAndForwardsAllowedRequests() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.disabledToolNames = ["RunAllTests", "RunSomeTests"]
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                if method == "tools/list" {
                    return .immediate(
                        try makeToolResultResponse(
                            id: originalID,
                            result: [
                                "tools": [Any]()
                            ]
                        )
                    )
                }
                #expect(method == "tools/call")
                #expect(toolName == "XcodeListWindows")
                return .immediate(try makeToolSuccessResponse(id: originalID, text: "allowed"))
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-disabled-batch",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "id": 201,
                        "method": "tools/call",
                        "params": [
                            "name": "RunAllTests",
                            "arguments": [:],
                        ],
                    ],
                    [
                        "jsonrpc": "2.0",
                        "method": "tools/call",
                        "params": [
                            "name": "RunSomeTests",
                            "arguments": [:],
                        ],
                    ],
                    [
                        "jsonrpc": "2.0",
                        "id": 202,
                        "method": "tools/call",
                        "params": [
                            "name": "XcodeListWindows",
                            "arguments": [:],
                        ],
                    ],
                ]
            )

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 2)
            let blocked = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 201 }
            let blockedResult = blocked?["result"] as? [String: Any]
            let blockedContent = blockedResult?["content"] as? [[String: Any]]
            #expect((blockedResult?["isError"] as? Bool) == true)
            #expect(blockedContent?.first?["text"] as? String == "tool 'RunAllTests' is disabled by proxy config")
            let allowed = bodyArray.first { ($0["id"] as? NSNumber)?.intValue == 202 }
            let allowedResult = allowed?["result"] as? [String: Any]
            let allowedContent = allowedResult?["content"] as? [[String: Any]]
            #expect(allowedContent?.first?["text"] as? String == "allowed")
            #expect(sessionManager.sentToolNames() == ["XcodeListWindows"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDisabledToolBatchReturnsLocalOnlyResponseWhenAllRequestsAreBlocked() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.disabledToolNames = ["RunAllTests", "RunSomeTests"]
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { _, _ in
                Issue.record("all-blocked batch should not reach upstream")
                return .immediate(Data())
            }
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, bodyData) = try await postHTTPAnyJSON(
                url: server.url,
                sessionID: "session-disabled-all-blocked",
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "id": 301,
                        "method": "tools/call",
                        "params": [
                            "name": "RunAllTests",
                            "arguments": [:],
                        ],
                    ],
                    [
                        "jsonrpc": "2.0",
                        "method": "tools/call",
                        "params": [
                            "name": "RunSomeTests",
                            "arguments": [:],
                        ],
                    ],
                ]
            )

            #expect(response.statusCode == 200)
            let bodyArray = try #require(bodyData as? [[String: Any]])
            #expect(bodyArray.count == 1)
            let blocked = bodyArray.first
            let result = blocked?["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect((blocked?["id"] as? NSNumber)?.intValue == 301)
            #expect((result?["isError"] as? Bool) == true)
            #expect(content?.first?["text"] as? String == "tool 'RunAllTests' is disabled by proxy config")
            #expect(sessionManager.sentToolNames().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDisabledToolNamesDoNotBlockInternalRefreshWorkflowCalls() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
        config.disabledToolNames = ["XcodeListWindows"]
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
                                "{\"message\":\"* tabIdentifier: windowtab-disabled-internal, workspacePath: \(workspacePath)\"}"
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
                sessionID: "session-disabled-internal",
                payload: toolsCallPayload(
                    id: 401,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-disabled-internal",
                        "filePath": "App/Sources/App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let structuredContent = result?["structuredContent"] as? [String: Any]
            let issues = structuredContent?["issues"] as? [[String: Any]]
            #expect(issues?.count == 1)
            #expect(issues?.first?["path"] as? String == target.path)
            #expect(sessionManager.sentToolNames() == [
                "XcodeListWindows",
                "XcodeListNavigatorIssues",
            ])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesQueuesBurstForSameTabWithoutBackpressureError() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
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
            sessionManager: sessionManager
        )

        do {
            let requestCount = 6
            let tasks = (0..<requestCount).map { index in
                Task<(Int, Int?, String?), Error> {
                    let (response, body) = try await postHTTPJSON(
                        url: server.url,
                        sessionID: "session-overload-\(index)",
                        payload: toolsCallPayload(
                            id: 21 + index,
                            name: "XcodeRefreshCodeIssuesInFile",
                            arguments: [
                                "tabIdentifier": "windowtab-overload",
                                "filePath": "File\(index).swift",
                            ]
                        )
                    )
                    let error = body["error"] as? [String: Any]
                    let errorCode = (error?["code"] as? NSNumber)?.intValue
                    let errorMessage = error?["message"] as? String
                    return (response.statusCode, errorCode, errorMessage)
                }
            }

            try await firstSent.wait(description: "waiting for first upstream refresh request")
            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    sessionManager.sentUpstreamCount() == 1
                        && sessionManager.pendingResponseCount() == 1
                }
            )

            for expectedCount in 1...requestCount {
                #expect(sessionManager.sentUpstreamCount() == expectedCount)
                #expect(sessionManager.pendingResponseCount() == 1)
                sessionManager.deliverNextPendingResponse()
                if expectedCount < requestCount {
                    #expect(
                        await waitUntil(timeout: .seconds(2)) {
                            sessionManager.sentUpstreamCount() == expectedCount + 1
                                && sessionManager.pendingResponseCount() == 1
                        }
                    )
                }
            }

            for task in tasks {
                let (statusCode, errorCode, errorMessage) = try await task.value
                #expect(statusCode == 200)
                #expect(errorCode == nil)
                #expect(errorMessage == nil)
            }
            #expect(sessionManager.sentUpstreamCount() == requestCount)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRefreshProxyQueuesBurstForSameTabWithoutBackpressureError() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .proxy
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot).appendingPathComponent("Missing.swift")
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
            sessionManager: sessionManager
        )

        do {
            let requestCount = 6
            let tasks = (0..<requestCount).map { index in
                Task<(Int, Int?, String?), Error> {
                    let (response, body) = try await postHTTPJSON(
                        url: server.url,
                        sessionID: "session-proxy-overload-\(index)",
                        payload: toolsCallPayload(
                            id: 26 + index,
                            name: "XcodeRefreshCodeIssuesInFile",
                            arguments: [
                                "tabIdentifier": "windowtab-proxy-overload",
                                "filePath": "Missing.swift",
                            ]
                        )
                    )
                    let error = body["error"] as? [String: Any]
                    let errorCode = (error?["code"] as? NSNumber)?.intValue
                    let errorMessage = error?["message"] as? String
                    return (response.statusCode, errorCode, errorMessage)
                }
            }

            try await firstSent.wait(description: "waiting for first proxy refresh request")
            #expect(
                await waitUntil(timeout: .seconds(2)) {
                    sessionManager.sentUpstreamCount() == 2
                        && sessionManager.pendingResponseCount() == 1
                }
            )

            for expectedRequests in 1...requestCount {
                #expect(sessionManager.sentUpstreamCount() == expectedRequests * 2)
                #expect(sessionManager.pendingResponseCount() == 1)
                sessionManager.deliverNextPendingResponse()
                if expectedRequests < requestCount {
                    #expect(
                        await waitUntil(timeout: .seconds(2)) {
                            sessionManager.sentUpstreamCount() == (expectedRequests + 1) * 2
                                && sessionManager.pendingResponseCount() == 1
                        }
                    )
                }
            }

            for task in tasks {
                let (statusCode, errorCode, errorMessage) = try await task.value
                #expect(statusCode == 200)
                #expect(errorCode == nil)
                #expect(errorMessage == nil)
            }
            #expect(sessionManager.sentUpstreamCount() == requestCount * 2)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func refreshWorkflowReturnsStandardTimeoutWhenPermitWaitConsumesRequestDeadline()
        async throws
    {
        let clock = TestClock()
        let coordinator = RefreshCodeIssuesCoordinator(waitClock: clock)
        let debugState = RefreshCodeIssuesDebugState(defaultRequestTimeoutSeconds: 2)
        let workflow = RefreshCodeIssuesWorkflow(
            mode: .upstream,
            requestTimeout: 2,
            coordinator: coordinator,
            targetResolver: RefreshCodeIssuesTargetResolver(),
            debugState: debugState,
            logger: ProxyLogging.make("test.refresh")
        )
        let activeStarted = TestSignal()
        let releaseFirst = TestSignal()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }

        let activeTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(
                key: "windowtab-timeout",
                requestTimeout: nil
            ) { _ in
                activeStarted.signal()
                try await releaseFirst.wait(description: "waiting to release first request")
            }
        }
        try await activeStarted.wait(description: "waiting for active queued-timeout execution")

        let requestID = RPCID(any: NSNumber(value: 25))!
        let requestPayload = toolsCallPayload(
            id: 25,
            name: "XcodeRefreshCodeIssuesInFile",
            arguments: [
                "tabIdentifier": "windowtab-timeout",
                "filePath": "B.swift",
            ]
        )
        let requestData = try JSONSerialization.data(withJSONObject: requestPayload, options: [])

        let requestTask = Task {
            await workflow.run(
                refreshRequest: RefreshCodeIssuesRequest(
                    tabIdentifier: "windowtab-timeout",
                    filePath: "B.swift"
                ),
                bodyData: requestData,
                sessionID: "session-timeout-2",
                requestIDs: [requestID],
                requestIsBatch: false,
                requestTimeoutOverride: .milliseconds(50),
                eventLoop: group.next(),
                windowsProvider: { _, _, _, _ in
                    Issue.record("queued timeout should not resolve windows")
                    return nil
                },
                internalUpstreamChooser: { _ in
                    Issue.record("queued timeout should not choose an internal upstream")
                    return nil
                },
                internalToolCaller: { _, _, _, _, _, _ in
                    Issue.record("queued timeout should not call internal tools")
                    return .unavailable
                },
                forwarder: { _, _, _, _, _, _, _ in
                    Issue.record("queued timeout should not reach upstream forwarding")
                    return .invalidRequest
                }
            )
        }

        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(50))

        let result = await requestTask.value
        guard case .timeout(let responseIDs, let isBatch) = result else {
            Issue.record("expected queued refresh to return standard timeout")
            releaseFirst.signal()
            _ = await activeTask.value
            return
        }
        #expect(responseIDs.map(\.key) == [requestID.key])
        #expect(isBatch == false)

        releaseFirst.signal()
        _ = await activeTask.value
    }

    @Test func httpRefreshProxyInternalToolCallsUpdateUpstreamHealthState() async throws {
        var config = makeConfig(requestTimeout: 0.2)
        config.refreshCodeIssuesMode = .proxy
        let temporaryRoot = makeHTTPTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(atPath: temporaryRoot) }

        let target = URL(fileURLWithPath: temporaryRoot).appendingPathComponent("Missing.swift")
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
            #expect(sessionManager.requestSuccessNotificationCount() == 2)
            #expect(sessionManager.requestTimeoutNotificationCount() == 1)
            #expect(sessionManager.chooseUpstreamShouldPinValues().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
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
        case .cancelled:
            Issue.record("expected the requested upstream dispatch to succeed")
        case .timeout:
            Issue.record("expected the requested upstream dispatch to succeed")
        case .unavailable:
            Issue.record("expected the requested upstream to be usable")
        }
        #expect(sessionManager.sentToolRequests() == ["XcodeListNavigatorIssues@0"])
        #expect(sessionManager.chooseUpstreamIndexCallCount() == 0)
        #expect(sessionManager.requestSuccessNotificationCount() == 1)
        #expect(sessionManager.requestTimeoutNotificationCount() == 0)
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
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesCompletesLeaseWhenRetryBudgetExpires() async throws {
        var config = makeConfig(requestTimeout: 0.5)
        config.refreshCodeIssuesMode = .upstream
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: { method, originalID in
                #expect(method == "tools/call")
                return .delayed(
                    try makeToolErrorResponse(
                        id: originalID,
                        text:
                            "Failed to retrieve diagnostics for 'App.swift': The operation couldn’t be completed. (SourceEditor.SourceEditorCallableDiagnosticError error 5.)"
                    ),
                    delayNanos: 350_000_000
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
                sessionID: "session-retry-budget-exhausted",
                payload: toolsCallPayload(
                    id: 19,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-retry-budget-exhausted",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            #expect((result?["isError"] as? Bool) == true)
            #expect(sessionManager.sentUpstreamCount() == 1)
            #expect(sessionManager.requeuedLeaseCount() == 0)

            let lease = try #require(sessionManager.leaseDebugSnapshots().first)
            #expect(lease.state == .completed)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func httpDirectRefreshSuccessDoesNotRecordLateLeaseResponse() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "XcodeRefreshCodeIssuesInFile")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "refresh-ok"
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
                sessionID: "session-direct-refresh-success",
                payload: toolsCallPayload(
                    id: 42,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-direct-success",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "refresh-ok")

            let lease = try #require(sessionManager.leaseDebugSnapshots().first)
            #expect(lease.state == .completed)
            #expect(lease.lateResponseCount == 0)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func httpDirectRefreshCancellationAbandonsActiveLease() async throws {
        var config = makeConfig(requestTimeout: 2)
        config.refreshCodeIssuesMode = .upstream
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamPlanResponder: nil,
            cancelAfterStartingEnqueueRequest: true
        )
        sessionManager.setInitialized(true)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-direct-refresh-cancelled",
                payload: toolsCallPayload(
                    id: 43,
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "tabIdentifier": "windowtab-direct-cancelled",
                        "filePath": "App.swift",
                    ]
                )
            )
            #expect(response.statusCode == 202)
            #expect(body.isEmpty)
            #expect(sessionManager.sentUpstreamCount() == 1)

            let abandonedLease = try #require(sessionManager.leaseDebugSnapshots().first)
            #expect(abandonedLease.state == .abandoned)
            #expect(abandonedLease.releaseReason == "clientDisconnected")
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
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
    private let documentationSearchResponder:
        (@Sendable (_ requestData: Data) throws -> Data)?
    private let cancelAfterStartingEnqueueRequest: Bool
    private let requestLeaseRegistry = LeaseManager()

    init(
        config: ProxyConfig,
        upstreamResponder: (@Sendable (_ method: String, _ originalID: RPCID) throws -> Data)? = nil,
        documentationSearchResponder:
            (@Sendable (_ requestData: Data) throws -> Data)? = nil,
        cancelAfterStartingEnqueueRequest: Bool = false
    ) {
        self.config = config
        self.upstreamRequestResponder = nil
        self.upstreamResponder = nil
        self.legacyUpstreamResponder = upstreamResponder
        self.documentationSearchResponder = documentationSearchResponder
        self.cancelAfterStartingEnqueueRequest = cancelAfterStartingEnqueueRequest
    }

    init(
        config: ProxyConfig,
        upstreamPlanResponder: (@Sendable (_ method: String, _ originalID: RPCID) throws -> UpstreamResponsePlan)?,
        documentationSearchResponder:
            (@Sendable (_ requestData: Data) throws -> Data)? = nil,
        cancelAfterStartingEnqueueRequest: Bool = false
    ) {
        self.config = config
        self.upstreamRequestResponder = nil
        self.upstreamResponder = upstreamPlanResponder
        self.legacyUpstreamResponder = nil
        self.documentationSearchResponder = documentationSearchResponder
        self.cancelAfterStartingEnqueueRequest = cancelAfterStartingEnqueueRequest
    }

    init(
        config: ProxyConfig,
        upstreamRequestResponder: (@Sendable (_ method: String, _ toolName: String?, _ originalID: RPCID) throws -> UpstreamResponsePlan)?,
        documentationSearchResponder:
            (@Sendable (_ requestData: Data) throws -> Data)? = nil,
        cancelAfterStartingEnqueueRequest: Bool = false
    ) {
        self.config = config
        self.upstreamRequestResponder = upstreamRequestResponder
        self.upstreamResponder = nil
        self.legacyUpstreamResponder = nil
        self.documentationSearchResponder = documentationSearchResponder
        self.cancelAfterStartingEnqueueRequest = cancelAfterStartingEnqueueRequest
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

    func shutdown() async {}

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

    func sharedToolsList(
        sessionID: String,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue {
        _ = requestTimeoutOverride
        if let cached = state.withLockedValue({ $0.cachedToolsList }) {
            return cached
        }
        let responseData = try await performSharedControlPlaneRequest(
            method: "tools/list",
            toolName: nil,
            sessionID: sessionID
        )
        guard let object = try JSONSerialization.jsonObject(
            with: responseData,
            options: []
        ) as? [String: Any],
            let resultAny = object["result"],
            let result = JSONValue(any: resultAny)
        else {
            throw NSError(domain: "TestRuntimeCoordinator", code: 2)
        }
        state.withLockedValue { state in
            state.cachedToolsList = result
        }
        return result
    }


    func liveXcodeListWindowsResult(
        route _: ControlPlaneRoute,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue {
        _ = requestTimeoutOverride
        let responseData = try await performSharedControlPlaneRequest(
            method: "tools/call",
            toolName: "XcodeListWindows",
            sessionID: "__test-control-plane__"
        )
        guard let object = try JSONSerialization.jsonObject(
            with: responseData,
            options: []
        ) as? [String: Any],
            let resultAny = object["result"],
            let result = JSONValue(any: resultAny)
        else {
            throw NSError(domain: "TestRuntimeCoordinator", code: 3)
        }
        return result
    }

    func callDocumentationSearch(
        requestData: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationSearchOutcome {
        _ = requestTimeoutOverride
        guard let documentationSearchResponder else {
            return .fallbackToUpstream
        }
        do {
            return .handled(try documentationSearchResponder(requestData))
        } catch is UpstreamSlotAcquisitionError {
            return .fallbackToUpstream
        }
    }

    func hasDocumentationProvider() -> Bool {
        documentationSearchResponder != nil
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
        if cancelAfterStartingEnqueueRequest {
            _ = starter(upstreamIndex)
            return eventLoop.makeFailedFuture(CancellationError())
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

        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return
        }
        if let object = json as? [String: Any] {
            handleSingleUpstreamRequest(object, upstreamIndex: upstreamIndex)
            return
        }
        if let array = json as? [Any] {
            handleBatchUpstreamRequest(array, upstreamIndex: upstreamIndex)
        }
    }

    private func handleSingleUpstreamRequest(_ object: [String: Any], upstreamIndex: Int) {
        guard let method = object["method"] as? String,
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

        let responsePlan = responsePlan(
            method: method,
            toolName: toolName,
            originalID: mapping.originalID
        )
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

    private func handleBatchUpstreamRequest(_ array: [Any], upstreamIndex: Int) {
        var sessionID: String?
        var responseObjects: [Any] = []

        for item in array {
            guard let object = item as? [String: Any],
                let method = object["method"] as? String
            else {
                continue
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

            guard let upstreamIDValue = object["id"] else {
                continue
            }
            let upstreamID =
                (upstreamIDValue as? NSNumber)?.int64Value ?? (upstreamIDValue as? Int64)
            guard let upstreamID,
                let mapping = state.withLockedValue({ $0.upstreamIDMapping[upstreamID] })
            else {
                continue
            }
            sessionID = mapping.sessionID

            let planned = responsePlan(
                method: method,
                toolName: toolName,
                originalID: mapping.originalID
            )
            guard planned.deliverManually == false, planned.delayNanos == nil,
                let responseObject = try? JSONSerialization.jsonObject(
                    with: planned.data,
                    options: []
                )
            else {
                return
            }
            responseObjects.append(responseObject)
        }

        guard let sessionID,
            responseObjects.isEmpty == false,
            let responseData = try? JSONSerialization.data(
                withJSONObject: responseObjects,
                options: []
            )
        else {
            return
        }

        let session = self.session(id: sessionID)
        session.router.handleIncoming(responseData)
    }

    private func responsePlan(
        method: String,
        toolName: String?,
        originalID: RPCID
    ) -> UpstreamResponsePlan {
        if let upstreamRequestResponder,
            let planned = try? upstreamRequestResponder(method, toolName, originalID)
        {
            return planned
        }
        if let upstreamResponder,
            let planned = try? upstreamResponder(method, originalID)
        {
            return planned
        }
        if let legacyUpstreamResponder,
            let responseData = try? legacyUpstreamResponder(method, originalID)
        {
            return .immediate(responseData)
        }
        return .immediate(Data())
    }

    private func performSharedControlPlaneRequest(
        method: String,
        toolName: String?,
        sessionID: String
    ) async throws -> Data {
        _ = session(id: sessionID)
        guard let upstreamIndex = chooseUpstreamIndex() else {
            throw UpstreamSlotAcquisitionError.unavailable
        }
        state.withLockedValue { state in
            state.upstreamSendCount += 1
            state.sentRequests.append(
                SentRequest(
                    method: method,
                    toolName: toolName,
                    upstreamIndex: upstreamIndex
                )
            )
        }

        let originalID = RPCID(any: "__shared-\(method)-\(UUID().uuidString)")!
        let plan = responsePlan(
            method: method,
            toolName: toolName,
            originalID: originalID
        )
        if let delayNanos = plan.delayNanos {
            try await Task.sleep(nanoseconds: delayNanos)
        }
        guard plan.deliverManually == false else {
            throw ControlPlaneError.invalidResponse("timeout")
        }
        guard let object = try? JSONSerialization.jsonObject(
            with: plan.data,
            options: []
        ) as? [String: Any] else {
            throw ControlPlaneError.invalidResponse("invalid response")
        }
        if let errorObject = object["error"] as? [String: Any] {
            throw ControlPlaneError.upstreamRPC(
                code: (errorObject["code"] as? NSNumber)?.intValue ?? -32000,
                message: errorObject["message"] as? String ?? "upstream error"
            )
        }
        state.withLockedValue { state in
            state.requestSuccessNotifications += 1
        }
        return plan.data
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
            controlPlane: nil,
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

    func sentMethods() -> [String] {
        state.withLockedValue { state in
            state.sentRequests.map(\.method)
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

    func pendingResponseCount() -> Int {
        state.withLockedValue { $0.pendingResponses.count }
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

private func waitForHTTPTestSemaphore(
    _ semaphore: DispatchSemaphore,
    timeoutSeconds: TimeInterval
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let timeoutMilliseconds = Int((timeoutSeconds * 1000).rounded(.up))
            continuation.resume(
                returning: semaphore.wait(
                    timeout: .now() + .milliseconds(timeoutMilliseconds)
                )
            )
        }
    }
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
    let childChannelTracker: HTTPTestServerChannelTracker

    static func start(
        config: ProxyConfig,
        sessionManager: any RuntimeCoordinating,
        refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator? = nil,
        refreshCodeIssuesTargetResolver: RefreshCodeIssuesTargetResolver = RefreshCodeIssuesTargetResolver()
    ) throws -> TestHTTPHandlerServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let childChannelTracker = HTTPTestServerChannelTracker()
        let refreshCoordinator =
            refreshCodeIssuesCoordinator
            ?? RefreshCodeIssuesCoordinator.makeDefault()
        let refreshDebugState = RefreshCodeIssuesDebugState(
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
                            refreshCodeIssuesCoordinator: refreshCoordinator,
                            refreshCodeIssuesTargetResolver: refreshCodeIssuesTargetResolver,
                            refreshCodeIssuesDebugState: refreshDebugState
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: config.listenHost, port: 0).wait()
        try channel.pipeline.addHandler(
            HTTPTestServerAcceptedChannelHandler(tracker: childChannelTracker)
        ).wait()
        let port = channel.localAddress?.port ?? 0
        let url = URL(string: "http://\(config.listenHost):\(port)/mcp")!
        return TestHTTPHandlerServer(
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

private func postHTTPAnyJSON(
    url: URL,
    sessionID: String,
    payload: [Any]
) async throws -> (HTTPURLResponse, Any) {
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
        let object = try JSONSerialization.jsonObject(with: responseData, options: [])
        return (httpResponse, object)
    }
}

private func postHTTPAnyData(
    url: URL,
    sessionID: String,
    payload: [Any]
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

private func makeDebugSnapshotURL(from mcpURL: URL, includeSensitive: Bool = false) -> URL {
    var components = URLComponents(url: mcpURL, resolvingAgainstBaseURL: false)!
    components.path = "/debug/upstreams"
    components.queryItems = includeSensitive
        ? [URLQueryItem(name: "includeSensitive", value: "1")]
        : nil
    return components.url!
}

private typealias AsyncSignal = TestSignal
private typealias SyncSignal = TestSignal

private func initializeHTTPChannel(_ channel: EmbeddedChannel) throws -> String {
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
    return try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))
}

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
