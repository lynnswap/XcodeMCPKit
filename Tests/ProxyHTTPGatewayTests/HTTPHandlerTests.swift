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
        let snapshot = try decoder.decode(ProxyDebug.Snapshot.self, from: Data(response.body.utf8))
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
        let snapshot = try decoder.decode(ProxyDebug.Snapshot.self, from: Data(response.body.utf8))
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
        sessionManager.setCachedToolsListResult(.object(["tools": .array([])]), sourceUpstream: 0)
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
            let snapshot = try decoder.decode(HTTPControlService.DebugSnapshot.self, from: data)
            #expect(snapshot.refreshCodeIssues == nil)

            let (sensitiveResponse, sensitiveData) = try await getHTTPData(
                url: makeDebugSnapshotURL(from: server.url, includeSensitive: true)
            )
            #expect(sensitiveResponse.statusCode == 200)
            let sensitiveSnapshot = try decoder.decode(HTTPControlService.DebugSnapshot.self, from: sensitiveData)
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
            let completedSnapshot = try decoder.decode(HTTPControlService.DebugSnapshot.self, from: completedData)
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

    @Test func httpPostRequiresJSONAndEventStreamAcceptTypes() async throws {
        let config = makeConfig()
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
        #expect(response.head.status == .notAcceptable)
        #expect(response.body == "client must accept application/json and text/event-stream")
    }

    @Test func httpPostAllowsRequiredAcceptTypesAcrossRepeatedHeaders() async throws {
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
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Accept", value: "text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Mcp-Session-Id")?.isEmpty == false)
    }

    @Test func httpPostRejectsNonJSONContentType() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "text/plain")
        var body = channel.allocator.buffer(capacity: 2)
        body.writeString("{}")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .unsupportedMediaType)
    }

    @Test func httpPostNonInitializeRequiresSessionHeader() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
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
        #expect(response.head.status == .badRequest)
        #expect(response.body == "session id required")
    }

    @Test func httpPostUnknownSessionReturnsNotFound() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "MCP-Session-Id", value: "missing-session")
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .notFound)
        #expect(response.body == "session not found")
    }

    @Test func httpPostRequiresNegotiatedProtocolVersionAfterInitialize() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)
        let sessionID = try initializeHTTPChannel(channel)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "MCP-Session-Id", value: sessionID)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .badRequest)
        #expect(response.body == "protocol version required")
    }

    @Test func httpPostRejectsMismatchedProtocolVersionAfterInitialize() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)
        let sessionID = try initializeHTTPChannel(channel)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "MCP-Session-Id", value: sessionID)
        head.headers.add(name: "MCP-Protocol-Version", value: "2025-11-25")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .badRequest)
        #expect(response.body == "protocol version mismatch")
    }

    @Test func httpDeleteTerminatesSession() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)
        let sessionID = try initializeHTTPChannel(channel)

        var deleteHead = HTTPRequestHead(version: .http1_1, method: .DELETE, uri: "/mcp")
        deleteHead.headers.add(name: "MCP-Session-Id", value: sessionID)
        deleteHead.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
        try channel.writeInbound(HTTPServerRequestPart.head(deleteHead))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let deleteResponse = try collectResponse(from: channel)
        #expect(deleteResponse.head.status == .ok)
        #expect(sessionManager.hasSession(id: sessionID) == false)

        var sseHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/mcp")
        sseHead.headers.add(name: "Accept", value: "text/event-stream")
        sseHead.headers.add(name: "MCP-Session-Id", value: sessionID)
        sseHead.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
        try channel.writeInbound(HTTPServerRequestPart.head(sseHead))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let afterDeleteResponse = try collectResponse(from: channel)
        #expect(afterDeleteResponse.head.status == .notFound)
        #expect(afterDeleteResponse.body == "session not found")
    }

    @Test func httpDeleteTerminatesUninitializedSession() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)
        _ = sessionManager.uninitializedSession(id: "uninitialized-session")

        var deleteHead = HTTPRequestHead(version: .http1_1, method: .DELETE, uri: "/mcp")
        deleteHead.headers.add(name: "MCP-Session-Id", value: "uninitialized-session")
        try channel.writeInbound(HTTPServerRequestPart.head(deleteHead))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let deleteResponse = try collectResponse(from: channel)
        #expect(deleteResponse.head.status == .ok)
        #expect(sessionManager.hasSession(id: "uninitialized-session") == false)
    }

    @Test func httpRejectsInvalidOrigin() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        try writeInitializePost(to: channel, origin: "https://example.invalid")

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .forbidden)
        #expect(response.body == "origin not allowed")
        #expect(sessionManager.isInitialized() == false)
    }

    @Test func httpRejectsOriginHostnameWithLoopbackPrefix() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        try writeInitializePost(to: channel, origin: "http://127.attacker.example:8765")

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .forbidden)
        #expect(response.body == "origin not allowed")
        #expect(sessionManager.isInitialized() == false)
    }

    @Test func httpRejectsOriginWithImplicitDefaultPortMismatch() async throws {
        var config = makeConfig()
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        try writeInitializePost(
            to: channel,
            host: "localhost:8765",
            origin: "http://localhost"
        )

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .forbidden)
        #expect(response.body == "origin not allowed")
        #expect(sessionManager.isInitialized() == false)
    }

    @Test func httpRejectsNonLoopbackOriginMatchingHostHeaderWhenBoundToWildcard() async throws {
        var config = makeConfig()
        config.listenHost = "0.0.0.0"
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        try writeInitializePost(
            to: channel,
            host: "192.0.2.10:8765",
            origin: "http://192.0.2.10:8765"
        )

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .forbidden)
        #expect(response.body == "origin not allowed")
        #expect(sessionManager.isInitialized() == false)
    }

    @Test func httpRejectsDNSOriginMatchingHostHeaderWhenBoundToWildcard() async throws {
        var config = makeConfig()
        config.listenHost = "0.0.0.0"
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        try writeInitializePost(
            to: channel,
            host: "attacker.example:8765",
            origin: "http://attacker.example:8765"
        )

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .forbidden)
        #expect(response.body == "origin not allowed")
        #expect(sessionManager.isInitialized() == false)
    }

    @Test func httpAllowsLoopbackOriginWhenBoundToWildcard() async throws {
        var config = makeConfig()
        config.listenHost = "0.0.0.0"
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        try writeInitializePost(
            to: channel,
            host: "localhost:8765",
            origin: "http://localhost:8765"
        )

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Mcp-Session-Id") != nil)
    }

    @Test func httpAllowsOriginMatchingExplicitListenHost() async throws {
        var config = makeConfig()
        config.listenHost = "192.0.2.10"
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        try writeInitializePost(
            to: channel,
            host: "192.0.2.10:8765",
            origin: "http://192.0.2.10:8765"
        )

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Mcp-Session-Id") != nil)
    }

    @Test func httpRejectsOriginMismatchingHostHeaderWhenBoundToWildcard() async throws {
        var config = makeConfig()
        config.listenHost = "0.0.0.0"
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        try writeInitializePost(
            to: channel,
            host: "192.0.2.10:8765",
            origin: "http://example.invalid:8765"
        )

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .forbidden)
        #expect(response.body == "origin not allowed")
        #expect(sessionManager.isInitialized() == false)
    }

    @Test func httpPostRejectsLargeBody() async throws {
        let config = makeConfig(maxBodyBytes: 1)
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
                "protocolVersion": "2025-06-18",
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
        #expect(response.head.headers.first(name: "Mcp-Session-Id")?.isEmpty == false)

        let responseObject =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let responseID = (responseObject?["id"] as? NSNumber)?.intValue
        #expect(responseID == 1)
        #expect(sessionManager.chooseUpstreamIndexCallCount() == 1)
        #expect(sessionManager.requestSuccessNotificationCount() == 0)
    }

    @Test func httpJSONRPCResponseIsForwardedAndAcceptedWithoutWaiting() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let sessionID = try initializeHTTPChannel(channel)
        let chooseCountBeforeResponse = sessionManager.chooseUpstreamIndexCallCount()
        let clientID = sessionManager.session(id: sessionID).serverRequestTracker.record(
            upstreamID: JSONRPC.ID(any: NSNumber(value: 99))!,
            upstreamIndex: 0
        )

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": clientID.value.foundationObject,
            "result": ["ok": true],
        ]
        try postJSON(payload, sessionID: sessionID, to: channel)

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .accepted)
        #expect(response.body.isEmpty)
        #expect(sessionManager.chooseUpstreamIndexCallCount() == chooseCountBeforeResponse)
        #expect(sessionManager.sentUpstreamCount() == 1)
        let sentPayload = try #require(sessionManager.sentUpstreamPayloads().last)
        let sentObject = try #require(
            JSONSerialization.jsonObject(with: sentPayload, options: []) as? [String: Any]
        )
        #expect((sentObject["id"] as? NSNumber)?.intValue == 99)
        #expect((sentObject["result"] as? [String: Any])?["ok"] as? Bool == true)
    }

    @Test func httpJSONRPCResponseForwardingFailureKeepsRouteForRetry() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let sessionID = try initializeHTTPChannel(channel)
        let session = sessionManager.session(id: sessionID)
        let clientID = session.serverRequestTracker.record(
            upstreamID: JSONRPC.ID(any: NSNumber(value: 99))!,
            upstreamIndex: 0
        )
        sessionManager.setServerRequestResponseSendResults([.backpressure, .accepted])

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": clientID.value.foundationObject,
            "result": ["ok": true],
        ]
        try postJSON(payload, sessionID: sessionID, to: channel)
        let rejected = try collectResponse(from: channel)
        #expect(rejected.head.status == .serviceUnavailable)
        #expect(rejected.body == "upstream unavailable")
        #expect(session.serverRequestTracker.lookup(clientID: clientID) != nil)

        try postJSON(payload, sessionID: sessionID, to: channel)
        let accepted = try collectResponse(from: channel)
        #expect(accepted.head.status == .accepted)
        #expect(accepted.body.isEmpty)
        #expect(session.serverRequestTracker.lookup(clientID: clientID) == nil)
        #expect(sessionManager.sentUpstreamCount() == 2)
    }

    @Test func httpUnknownJSONRPCResponseRouteIsAcknowledgedWithoutForwarding() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let sessionID = try initializeHTTPChannel(channel)
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "xcode-mcp-proxy.server-request.999",
            "result": ["ok": true],
        ]
        try postJSON(payload, sessionID: sessionID, to: channel)

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .accepted)
        #expect(response.body.isEmpty)
        #expect(sessionManager.sentUpstreamCount() == 0)
    }

    @Test func httpMalformedJSONRPCObjectWithIDReturnsInvalidRequestError() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let sessionID = try initializeHTTPChannel(channel)
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 123,
        ]
        try postJSON(payload, sessionID: sessionID, to: channel)

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let responseObject = try #require(
            JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
                as? [String: Any]
        )
        #expect((responseObject["id"] as? NSNumber)?.intValue == 123)
        let error = try #require(responseObject["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == -32600)
        #expect(sessionManager.sentUpstreamCount() == 0)
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
                "protocolVersion": "2025-06-18",
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
                "protocolVersion": "2025-06-18",
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
        #expect(response.head.headers.first(name: "Mcp-Session-Id") == nil)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32600)
        #expect((error?["message"] as? String) == "missing id")
        #expect(sessionManager.isInitialized() == false)
    }

    @Test func httpJSONArrayBodyIsRejectedBeforeInitializeRouting() async throws {
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
                    "protocolVersion": "2025-06-18",
                    "capabilities": [String: Any](),
                    "clientInfo": [
                        "name": "xcode-mcp-proxy-tests",
                        "version": "0.0",
                    ],
                ],
            ]
        ]
        try postJSONArray(payload, sessionID: nil, to: channel)

        let response = try collectResponse(from: channel)
        assertBatchRejected(response)
        #expect(sessionManager.isInitialized() == false)
    }

    @Test func httpJSONArrayBodyIsRejectedBeforeUpstreamRouting() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        _ = sessionManager.session(id: "session-batch")
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": 42,
                "method": "tools/list",
            ]
        ]
        try postJSONArray(payload, sessionID: "session-batch", to: channel)

        let response = try collectResponse(from: channel)
        assertBatchRejected(response)
        #expect(sessionManager.sentUpstreamCount() == 0)
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID)
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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

    @Test func httpForwardingReusesDeadlineAfterAsyncToolRouting() async throws {
        let config = makeConfig(requestTimeout: 0.02)
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamResponder: { _, originalID in
                try makeToolSuccessResponse(id: originalID, text: "{\"ok\":true}")
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setForceAsyncToolRoutingDecision(true)
        sessionManager.setToolRoutingDecision(.forward(preferredUpstreamIndex: nil))
        sessionManager.setToolRoutingDelayNanos(60_000_000)
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, object) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-routing-deadline",
                payload: toolsCallPayload(
                    id: 2002,
                    name: "BuildProject",
                    arguments: ["workspacePath": "/tmp/Project.xcworkspace"]
                )
            )

            #expect(response.statusCode == 200)
            let error = try #require(object["error"] as? [String: Any])
            #expect((error["code"] as? NSNumber)?.intValue == -32000)
            #expect(error["message"] as? String == "upstream timeout")
            #expect(sessionManager.sentUpstreamCount() == 0)
            let lease = try #require(sessionManager.leaseDebugSnapshots().first)
            #expect(lease.state == .timedOut)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func httpPostRequiresBothJSONAndEventStreamAcceptTypes() async throws {
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .notAcceptable)
        #expect(response.head.headers.first(name: "Content-Type") == "text/plain; charset=utf-8")
        #expect(response.body == "client must accept application/json and text/event-stream")
    }

    @Test func httpJSONArrayBodyDoesNotCreateTimeoutMappings() async throws {
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        try postJSONArray(payload, sessionID: sessionID, to: channel)

        #expect(sessionManager.mappedUpstreamRequestCount() == 0)
        advanceEventLoopTime(on: channel, by: .milliseconds(300))

        let response = try collectResponse(from: channel)
        assertBatchRejected(response)
        #expect(sessionManager.requestTimeoutNotificationCount() == 0)
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID)
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        malformedHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
        malformedHead.headers.add(name: "Content-Type", value: "application/json")
        malformedHead.headers.add(name: "Mcp-Session-Id", value: sessionID)
        malformedHead.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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

    @Test func httpToolRoutingRejectReturnsToolResultErrorWithoutForwarding() async throws {
        let config = makeConfig()
        let sessionManager = TestRuntimeCoordinator(config: config)
        sessionManager.setInitialized(true)
        let requestID = try #require(JSONRPC.ID(any: NSNumber(value: 3301)))
        sessionManager.setToolRoutingDecision(
            .reject(
                errors: [
                    ToolRoutingError(
                        id: requestID,
                        message: "unable to resolve Xcode window owner for tool 'BuildProject'"
                    ),
                ],
                forceBatchArray: false
            )
        )
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: "session-routing-reject",
                payload: toolsCallPayload(
                    id: 3301,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "missing-tab"]
                )
            )

            #expect(response.statusCode == 200)
            let result = try #require(body["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == true)
            let content = try #require(result["content"] as? [[String: Any]])
            #expect((content.first?["text"] as? String)?.contains("unable to resolve") == true)
            #expect(sessionManager.sentMethods().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpToolRoutingRejectReturnsErrorsForNonToolBatchItems() async throws {
        let config = makeConfig()
        let sessionManager = TestRuntimeCoordinator(config: config)
        sessionManager.setInitialized(true)
        let toolRequestID = try #require(JSONRPC.ID(any: NSNumber(value: 3301)))
        let resourceRequestID = try #require(JSONRPC.ID(any: NSNumber(value: 3302)))
        sessionManager.setToolRoutingDecision(
            .reject(
                errors: [
                    ToolRoutingError(
                        id: toolRequestID,
                        message: "unable to resolve Xcode window owner for one or more tools"
                    ),
                ],
                forceBatchArray: true
            )
        )
        let service = HTTPPostService(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: .makeDefault(),
            refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState(
                defaultRequestTimeoutSeconds: config.requestTimeout
            )
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let payload: [[String: Any]] = [
                toolsCallPayload(
                    id: 3301,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "missing-tab"]
                ),
                [
                    "jsonrpc": "2.0",
                    "id": 3302,
                    "method": "resources/list",
                ],
            ]
            let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [])
            let operation = service.makeForwardingOperation(
                filteredRequest: HTTPPostService.FilteredToolCallRequest(
                    bodyData: bodyData,
                    localResponseData: nil,
                    forwardedResponseIDs: [toolRequestID, resourceRequestID],
                    forceBatchArray: true
                ),
                sessionID: "session-routing-reject-batch",
                headerSessionID: "session-routing-reject-batch",
                requestIsBatch: true,
                prefersEventStream: false,
                eventLoop: group.next(),
                requestTimeoutOverride: nil,
                parentCancellationHandle: nil
            )

            let resolution = try await operation.future.get()
            let responseData: Data
            switch resolution {
            case .responseData(let data, _, _):
                responseData = data
            default:
                Issue.record("expected response data, got \(resolution)")
                return
            }
            let objects = try #require(
                JSONSerialization.jsonObject(with: responseData, options: []) as? [[String: Any]]
            )
            #expect(
                objects.compactMap { ($0["id"] as? NSNumber)?.intValue }.sorted()
                    == [3301, 3302]
            )
            let toolResponse = try #require(
                objects.first { ($0["id"] as? NSNumber)?.intValue == 3301 }
            )
            let toolResult = try #require(toolResponse["result"] as? [String: Any])
            #expect(toolResult["isError"] as? Bool == true)

            let resourceResponse = try #require(
                objects.first { ($0["id"] as? NSNumber)?.intValue == 3302 }
            )
            let resourceError = try #require(resourceResponse["error"] as? [String: Any])
            #expect((resourceError["code"] as? NSNumber)?.intValue == -32000)
            #expect(
                (resourceError["message"] as? String)?
                    .contains("tool routing rejected the batch") == true
            )
            #expect(sessionManager.sentMethods().isEmpty)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        try await group.shutdownGracefully()
    }

    @Test func httpToolRoutingLocalXcodeListWindowsReturnsAggregatedResult() async throws {
        let config = makeConfig()
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "XcodeListWindows")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "* tabIdentifier: tab-http, workspacePath: /Work/HTTP.xcworkspace"
                    )
                )
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setAvailableUpstreamIndices([1])
        sessionManager.setToolRoutingDecision(.localXcodeListWindows)
        let service = HTTPPostService(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: .makeDefault(),
            refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState(
                defaultRequestTimeoutSeconds: config.requestTimeout
            )
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let requestID = try #require(JSONRPC.ID(any: NSNumber(value: 3303)))
            let payload = toolsCallPayload(
                id: 3303,
                name: "XcodeListWindows",
                arguments: [:]
            )
            let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [])
            let operation = service.makeForwardingOperation(
                filteredRequest: HTTPPostService.FilteredToolCallRequest(
                    bodyData: bodyData,
                    localResponseData: nil,
                    forwardedResponseIDs: [requestID],
                    forceBatchArray: false
                ),
                sessionID: "session-routing-local-windows",
                headerSessionID: "session-routing-local-windows",
                requestIsBatch: false,
                prefersEventStream: false,
                eventLoop: group.next(),
                requestTimeoutOverride: nil,
                parentCancellationHandle: nil
            )

            let resolution = try await operation.future.get()
            let responseData: Data
            switch resolution {
            case .responseData(let data, _, _):
                responseData = data
            default:
                Issue.record("expected response data, got \(resolution)")
                return
            }
            let object = try #require(
                JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any]
            )
            #expect((object["id"] as? NSNumber)?.intValue == 3303)
            let result = try #require(object["result"] as? [String: Any])
            let content = try #require(result["content"] as? [[String: Any]])
            #expect((content.first?["text"] as? String)?.contains("tab-http") == true)
            #expect(sessionManager.sentToolRequests() == ["XcodeListWindows@1"])
            #expect(sessionManager.assignedUpstreamIDCount() == 0)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        try await group.shutdownGracefully()
    }

    @Test func httpLocalToolFilterExtractsXcodeListWindowsFromBatch() async throws {
        let config = makeConfig()
        let sessionManager = TestRuntimeCoordinator(
            config: config,
            upstreamRequestResponder: { method, toolName, originalID in
                #expect(method == "tools/call")
                #expect(toolName == "XcodeListWindows")
                return .immediate(
                    try makeToolSuccessResponse(
                        id: originalID,
                        text: "* tabIdentifier: tab-batch, workspacePath: /Work/Batch.xcworkspace"
                    )
                )
            }
        )
        sessionManager.setInitialized(true)
        sessionManager.setAvailableUpstreamIndices([1])
        let service = HTTPPostService(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: .makeDefault(),
            refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState(
                defaultRequestTimeoutSeconds: config.requestTimeout
            )
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let batch: [[String: Any]] = [
                toolsCallPayload(
                    id: 3304,
                    name: "XcodeListWindows",
                    arguments: [:]
                ),
                toolsCallPayload(
                    id: 3305,
                    name: "XcodeRead",
                    arguments: ["filePath": "App.swift"]
                ),
            ]
            let bodyData = try JSONSerialization.data(withJSONObject: batch, options: [])
            let routing = try service.routeToolCalls(
                bodyData: bodyData,
                sessionID: "session-routing-local-windows-batch",
                forceBatchArray: true,
                eventLoop: group.next(),
                requestTimeoutOverride: nil
            )
            let localOperation = try #require(routing.localOperation)
            let forwardedData = try #require(routing.forwardedRequest.bodyData)
            let forwardedObjects = try #require(
                JSONSerialization.jsonObject(with: forwardedData, options: []) as? [[String: Any]]
            )
            let forwardedObject = try #require(forwardedObjects.first)
            #expect(forwardedObjects.count == 1)
            #expect((forwardedObject["id"] as? NSNumber)?.intValue == 3305)

            let localResult = try await localOperation.localResponseFuture.get()
            let localData = try #require(localResult.responseData)
            let localObjects = try #require(
                JSONSerialization.jsonObject(with: localData, options: []) as? [[String: Any]]
            )
            #expect(localObjects.count == 1)
            #expect((localObjects.first?["id"] as? NSNumber)?.intValue == 3304)
            let result = try #require(localObjects.first?["result"] as? [String: Any])
            let content = try #require(result["content"] as? [[String: Any]])
            #expect((content.first?["text"] as? String)?.contains("tab-batch") == true)
            #expect(sessionManager.sentToolRequests() == ["XcodeListWindows@1"])
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        try await group.shutdownGracefully()
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID)
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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

    @Test func httpInitializeIgnoresCallerProvidedSessionHeader() async throws {
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
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: "missing-session")
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let returnedSessionID = try #require(response.head.headers.first(name: "Mcp-Session-Id"))
        #expect(returnedSessionID.isEmpty == false)
        #expect(returnedSessionID != "missing-session")
        #expect(sessionManager.hasSession(id: returnedSessionID))
        #expect(sessionManager.hasSession(id: "missing-session") == false)
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
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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
            JSONValue(any: ["tools": [Any]()])!,
            sourceUpstream: 0
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        toolsHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
        toolsHead.headers.add(name: "Content-Type", value: "application/json")
        toolsHead.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        toolsHead.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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
            JSONValue(any: ["tools": [Any]()])!,
            sourceUpstream: 0
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        toolsHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
        toolsHead.headers.add(name: "Content-Type", value: "application/json")
        toolsHead.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        toolsHead.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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

    @Test func httpSingleItemBatchToolsListIsRejectedBeforeCacheLookup() async throws {
        let config = makeConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        _ = sessionManager.session(id: "session-batch-tools-list")
        sessionManager.setInitialized(true)
        sessionManager.setCachedToolsListResult(
            JSONValue(any: ["tools": [Any]()])!,
            sourceUpstream: 0
        )
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [[String: Any]] = [[
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ]]
        try postJSONArray(payload, sessionID: "session-batch-tools-list", to: channel)

        let response = try collectResponse(from: channel)
        assertBatchRejected(response)
        #expect(sessionManager.sentUpstreamCount() == 0)
    }

    @Test func httpForwardedSingleItemBatchToolsListIsRejectedBeforeForwarding() async throws {
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
        _ = sessionManager.session(id: "session-forwarded-batch-tools-list")
        sessionManager.setInitialized(true)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [[String: Any]] = [[
            "jsonrpc": "2.0",
            "id": 22,
            "method": "tools/list",
        ]]
        try postJSONArray(payload, sessionID: "session-forwarded-batch-tools-list", to: channel)

        let response = try collectResponse(from: channel)
        assertBatchRejected(response)
        #expect(sessionManager.sentUpstreamCount() == 0)
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        toolsHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
        toolsHead.headers.add(name: "Content-Type", value: "application/json")
        toolsHead.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        toolsHead.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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
        toolsHead2.headers.add(name: "Accept", value: "application/json, text/event-stream")
        toolsHead2.headers.add(name: "Content-Type", value: "application/json")
        toolsHead2.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        toolsHead2.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        toolsHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
        toolsHead.headers.add(name: "Content-Type", value: "application/json")
        toolsHead.headers.add(name: "Mcp-Session-Id", value: sessionID)
        toolsHead.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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
            ])!,
            sourceUpstream: 0
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        toolsHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
        toolsHead.headers.add(name: "Content-Type", value: "application/json")
        toolsHead.headers.add(name: "Mcp-Session-Id", value: sessionID)
        toolsHead.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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
            ])!,
            sourceUpstream: 0
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
            JSONValue(any: ["tools": [Any]()])!,
            sourceUpstream: 0
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        toolsHead.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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
                let originalID = try #require(JSONRPC.ID(any: originalIDValue))
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

    @Test func httpForwardedSingleItemBatchResourcesListIsRejectedBeforeForwarding() async throws {
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
        _ = sessionManager.session(id: "session-forwarded-batch-resources-list")
        sessionManager.setInitialized(true)
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [[String: Any]] = [[
            "jsonrpc": "2.0",
            "id": 31,
            "method": "resources/list",
            "params": [String: Any](),
        ]]
        try postJSONArray(payload, sessionID: "session-forwarded-batch-resources-list", to: channel)

        let response = try collectResponse(from: channel)
        assertBatchRejected(response)
        #expect(sessionManager.sentUpstreamCount() == 0)
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
        _ = sessionManager.session(id: "session-1")
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/templates/list",
            "params": [String: Any](),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: "session-1")
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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
        initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
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
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID!)
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
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

    private func writeInitializePost(
        to channel: EmbeddedChannel,
        host: String? = nil,
        origin: String
    ) throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "capabilities": [String: Any](),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        if let host {
            head.headers.add(name: "Host", value: host)
        }
        head.headers.add(name: "Origin", value: origin)
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
    }

}
