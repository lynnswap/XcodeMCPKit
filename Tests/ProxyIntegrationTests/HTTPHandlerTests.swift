@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOHTTP1
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyHTTP
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyRuntimeContract
import XcodeMCPProxyTestSupport

@Suite(.serialized, .asyncTestCleanup)
struct HTTPHandlerTests {
    @Test func httpHealthCheck() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/health")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.body == "ok")
    }

    @Test func httpDebugUpstreamsReturnsSnapshot() async throws {
        var config = makeHTTPConfig()
        config.enablesDebugEndpoints = true
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/debug/upstreams")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "application/json")

        let snapshot = try #require(
            JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any]
        )
        let hosts = try #require(snapshot["hosts"] as? [[String: Any]])
        #expect(hosts.count == 1)
        #expect(hosts.first?["hostIdentifier"] as? String == NativeHostBroker.defaultHostIdentifier)
        #expect(hosts.first?["kind"] as? String == "headless")
        #expect(hosts.first?["phase"] as? String == "idle")
        #expect((hosts.first?["inFlightRequests"] as? NSNumber)?.intValue == 0)
    }

    @Test func httpDebugUpstreamsReturnsNotFoundWhenListenerIsNotLoopback() async throws {
        var config = makeHTTPConfig()
        config.listenHost = "0.0.0.0"
        config.enablesDebugEndpoints = true

        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/debug/upstreams")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .notFound)
        #expect(response.body == "not found")
    }

    @Test func httpDebugResetResetsRuntimeOnLoopback() async throws {
        var config = makeHTTPConfig()
        config.prewarmToolsList = false
        config.enablesDebugEndpoints = true
        let runtime = try HTTPTestRuntime(config: config)
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)

        do {
            let sessionID = try await initializeHTTPSession(url: server.url)
            let (listed, _) = try await postHTTPJSON(
                url: server.url, sessionID: sessionID, payload: toolsListPayload(id: 2)
            )
            #expect(listed.statusCode == 200)
            #expect(runtime.host?.requests("tools/list").count == 1)

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
            #expect(runtime.hasSession(sessionID) == false)

            // The reset dropped the published catalog, so the restarted host supplies it again.
            let nextSessionID = try await initializeHTTPSession(url: server.url)
            let (relisted, _) = try await postHTTPJSON(
                url: server.url, sessionID: nextSessionID, payload: toolsListPayload(id: 3)
            )
            #expect(relisted.statusCode == 200)
            #expect(runtime.startedHostCount == 2)
            #expect(runtime.host?.requests("tools/list").count == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func httpDebugResetReturnsNotFoundWhenListenerIsNotLoopback() async throws {
        var config = makeHTTPConfig()
        config.listenHost = "0.0.0.0"
        config.enablesDebugEndpoints = true

        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/debug/reset")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .notFound)
        #expect(response.body == "not found")
    }

    @Test(arguments: [(HTTPMethod.GET, "/debug/upstreams?includeSensitive=1"), (.POST, "/debug/reset")])
    func httpDebugEndpointsRequireTheOptIn(method: HTTPMethod, uri: String) async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        try channel.writeInbound(HTTPServerRequestPart.head(HTTPRequestHead(version: .http1_1, method: method, uri: uri)))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .notFound)
    }

    @Test func httpSSERequiresAcceptHeader() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/mcp")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .notAcceptable)
        #expect(response.body.contains("text/event-stream"))
    }

    @Test func httpPostRejectsUnknownAccept() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "text/plain")
        head.headers.add(name: "Content-Type", value: "application/json")
        var body = channel.allocator.buffer(capacity: 2)
        body.writeString("{}")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .notAcceptable)
    }

    @Test func httpPostRequiresJSONAndEventStreamAcceptTypes() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json")
        head.headers.add(name: "Content-Type", value: "application/json")
        var body = channel.allocator.buffer(capacity: 2)
        body.writeString("{}")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .notAcceptable)
        #expect(response.body == "client must accept application/json and text/event-stream")
    }

    @Test func httpPostAllowsRequiredAcceptTypesAcrossRepeatedHeaders() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

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

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Mcp-Session-Id")?.isEmpty == false)
    }

    @Test func httpPostKeepsRequestActiveUntilResponseWriteCompletes() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        let responseCompletions = NIOLockedValueBox<[@Sendable () -> Void]>([])
        try addHTTPHandler(
            to: channel,
            config: config,
            runtime: runtime,
            scheduleResponseCompletion: { _, completion in
                responseCompletions.withLockedValue { $0.append(completion) }
            }
        )

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
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        try await waitWithTimeout("the initialize response was scheduled", timeout: .seconds(5)) {
            while responseCompletions.withLockedValue({ $0.isEmpty }) { await Task.yield() }
        }
        #expect(responseCompletions.withLockedValue { $0.count } == 1)

        // Expiry closes only sessions without active requests; the unwritten response keeps it.
        runtime.controlService.sessions.expire(inactiveFor: .nanoseconds(0))

        let completions = responseCompletions.withLockedValue { completions in
            let pending = completions
            completions.removeAll()
            return pending
        }
        for completion in completions {
            completion()
        }
        channel.embeddedEventLoop.run()

        let response = try await collectResponse(from: channel)
        channel.embeddedEventLoop.run()
        #expect(response.head.status == .ok)
        let sessionID = try #require(response.head.headers.first(name: "Mcp-Session-Id"))
        #expect(runtime.hasSession(sessionID))

        runtime.controlService.sessions.expire(inactiveFor: .nanoseconds(0))
        #expect(runtime.hasSession(sessionID) == false)
    }

    /// A 404 asks a client to initialize again, which cannot help while the runtime stops.
    @Test func httpInitializeIsRefusedWhileTheRuntimeIsUnavailable() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        await runtime.shutdown()

        try writeInitializePost(to: channel)

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .serviceUnavailable)
        #expect(response.body == "server unavailable")
        #expect(runtime.startedHostCount == 0)
    }

    @Test func httpPostRejectsNonJSONContentType() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "text/plain")
        var body = channel.allocator.buffer(capacity: 2)
        body.writeString("{}")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .unsupportedMediaType)
    }

    @Test func httpPostNonInitializeRequiresSessionHeader() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        let data = try JSONSerialization.data(withJSONObject: toolsListPayload(id: 2), options: [])
        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .badRequest)
        #expect(response.body == "session id required")
    }

    @Test func httpPostUnknownSessionReturnsNotFound() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        try postJSON(toolsListPayload(id: 2), sessionID: "missing-session", to: channel)

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .notFound)
        #expect(response.body == "session not found")
    }

    @Test func httpResolvesProtocolVersionConsistentlyAcrossSessionRoutes() async throws {
        for route in ProtocolVersionRoute.allCases {
            for headerCase in ProtocolVersionHeaderCase.allCases {
                let config = makeHTTPConfig()
                let channel = EmbeddedChannel()
                let runtime = try HTTPTestRuntime(config: config)
                try addHTTPHandler(to: channel, config: config, runtime: runtime)
                let sessionID = try await initializeHTTPChannel(channel)

                try writeProtocolVersionRequest(
                    route,
                    headerCase: headerCase,
                    sessionID: sessionID,
                    to: channel
                )
                let response = try await collectResponse(from: channel)

                #expect(
                    response.head.status == (headerCase.isAccepted ? .ok : .badRequest),
                    "route=\(route) header=\(headerCase)"
                )
                if headerCase.isAccepted == false {
                    #expect(response.body == "protocol version mismatch")
                }
                if route == .delete {
                    #expect(
                        runtime.hasSession(sessionID) == !headerCase.isAccepted,
                        "header=\(headerCase)"
                    )
                } else {
                    #expect(runtime.hasSession(sessionID))
                }

                _ = try? channel.finish()
            }
        }
    }

    @Test func protocolVersionResolverRejectsUnsupportedSpecificationDefaultWithoutNegotiatedVersion() {
        #expect(HTTPRequestProtocolVersionResolver.specificationDefault == "2025-03-26")
        #expect(
            HTTPRequestProtocolVersionResolver.resolve(headers: HTTPHeaders(), negotiatedVersion: nil)
                == .rejected
        )
    }

    @Test func httpDeleteTerminatesSession() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        var deleteHead = HTTPRequestHead(version: .http1_1, method: .DELETE, uri: "/mcp")
        deleteHead.headers.add(name: "MCP-Session-Id", value: sessionID)
        deleteHead.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
        try channel.writeInbound(HTTPServerRequestPart.head(deleteHead))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let deleteResponse = try await collectResponse(from: channel)
        #expect(deleteResponse.head.status == .ok)
        #expect(runtime.hasSession(sessionID) == false)

        var sseHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/mcp")
        sseHead.headers.add(name: "Accept", value: "text/event-stream")
        sseHead.headers.add(name: "MCP-Session-Id", value: sessionID)
        sseHead.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
        try channel.writeInbound(HTTPServerRequestPart.head(sseHead))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let afterDeleteResponse = try await collectResponse(from: channel)
        #expect(afterDeleteResponse.head.status == .notFound)
        #expect(afterDeleteResponse.body == "session not found")
    }

    /// A client that disconnects gives up its request: the host learns of it, and the session can expire.
    @Test func aClientDisconnectCancelsItsRequestAndReleasesTheSession() async throws {
        let config = makeHTTPConfig(requestTimeout: 60)
        let channel = EmbeddedChannel()
        let runtime = try HTTPTestRuntime(config: config) { _, _ in .hold }
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)
        try postJSON(toolsCallPayload(id: 2, name: "DocumentationSearch", arguments: ["query": "held"]),
                     sessionID: sessionID, to: channel)
        let held = try await runtime.waitForHostMessages("tools/call")
        let hostRequestID = try #require(held.first?["id"])
        runtime.controlService.sessions.expire(inactiveFor: .nanoseconds(0))
        #expect(runtime.hasSession(sessionID))

        _ = try? channel.finish()
        let cancellations = try await runtime.waitForHostMessages("notifications/cancelled")
        guard case .object(let params)? = cancellations.first?["params"] else {
            Issue.record("the host cancellation has no parameters")
            return
        }
        #expect(params["requestId"] == hostRequestID)
        runtime.controlService.sessions.expire(inactiveFor: .nanoseconds(0))
        #expect(!runtime.hasSession(sessionID))
    }

    /// A cancellation sent right after a request, on another connection, finds that request.
    @Test func aCancellationFindsTheRequestSentBeforeIt() async throws {
        let config = makeHTTPConfig(requestTimeout: 60)
        let requestChannel = EmbeddedChannel()
        let cancelChannel = EmbeddedChannel()
        defer {
            _ = try? requestChannel.finish()
            _ = try? cancelChannel.finish()
        }
        let runtime = try HTTPTestRuntime(config: config) { _, _ in .hold }
        try addHTTPHandler(to: requestChannel, config: config, runtime: runtime)
        try addHTTPHandler(to: cancelChannel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(requestChannel)

        try postJSON(toolsCallPayload(id: 2, name: "DocumentationSearch", arguments: ["query": "held"]),
                     sessionID: sessionID, to: requestChannel)
        try postJSON(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 2]],
                     sessionID: sessionID, to: cancelChannel)
        #expect(try await collectResponse(from: cancelChannel).head.status == .accepted)

        let cancelled = try await collectResponse(from: requestChannel)
        let body = try #require(
            JSONSerialization.jsonObject(with: Data(cancelled.body.utf8)) as? [String: Any])
        #expect(((body["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue == -32800)
    }

    /// A request that started is answered when its session is deleted; only later requests get a 404.
    @Test func deletingASessionAnswersItsRunningRequestAndRefusesLaterOnes() async throws {
        let config = makeHTTPConfig(requestTimeout: 60)
        let requestChannel = EmbeddedChannel()
        let deleteChannel = EmbeddedChannel()
        defer {
            _ = try? requestChannel.finish()
            _ = try? deleteChannel.finish()
        }
        let runtime = try HTTPTestRuntime(config: config) { _, _ in .hold }
        try addHTTPHandler(to: requestChannel, config: config, runtime: runtime)
        try addHTTPHandler(to: deleteChannel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(requestChannel)
        try postJSON(toolsCallPayload(id: 2, name: "DocumentationSearch", arguments: ["query": "held"]),
                     sessionID: sessionID, to: requestChannel)
        try await runtime.waitForToolCalls(1)

        var deleteHead = HTTPRequestHead(version: .http1_1, method: .DELETE, uri: "/mcp")
        deleteHead.headers.add(name: "MCP-Session-Id", value: sessionID)
        deleteHead.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
        try deleteChannel.writeInbound(HTTPServerRequestPart.head(deleteHead))
        try deleteChannel.writeInbound(HTTPServerRequestPart.end(nil))
        #expect(try await collectResponse(from: deleteChannel).head.status == .ok)

        let running = try await collectResponse(from: requestChannel)
        #expect(running.head.status == .ok)
        let body = try #require(
            JSONSerialization.jsonObject(with: Data(running.body.utf8)) as? [String: Any])
        let error = try #require(body["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == -32800)

        try postJSON(toolsCallPayload(id: 3, name: "DocumentationSearch", arguments: ["query": "late"]),
                     sessionID: sessionID, to: requestChannel)
        let late = try await collectResponse(from: requestChannel)
        #expect(late.head.status == .notFound)
        #expect(late.body == "session not found")
        #expect(runtime.toolCalls().count == 1)
    }

    @Test func httpAppliesOriginPolicyBeforeEveryRoute() async throws {
        for route in OriginPolicyRoute.allCases {
            for originCase in OriginPolicyHeaderCase.allCases {
                var config = makeHTTPConfig()
                config.listenPort = 8765
                config.enablesDebugEndpoints = true
                if route == .debugReset, originCase.isRejected == false {
                    // The live loopback reset path is covered separately. A non-loopback
                    // listener keeps this Cartesian header test synchronous.
                    config.listenHost = "0.0.0.0"
                }
                let channel = EmbeddedChannel()
                let runtime = try HTTPTestRuntime(config: config)
                try addHTTPHandler(to: channel, config: config, runtime: runtime)
                let sentinelSessionID = try await initializeHTTPChannel(channel)

                try writeOriginPolicyRequest(
                    route,
                    originCase: originCase,
                    to: channel
                )
                let response = try await collectResponse(from: channel)

                let expectedStatus =
                    originCase.isRejected
                    ? HTTPResponseStatus.forbidden
                    : route.statusWithoutOriginRejection
                #expect(
                    response.head.status == expectedStatus,
                    "route=\(route) origin=\(originCase)"
                )
                if originCase.isRejected {
                    #expect(response.body == "origin not allowed")
                    #expect(runtime.hasSession(sentinelSessionID))
                    #expect(runtime.startedHostCount == 0)
                }

                _ = try? channel.finish()
            }
        }
    }

    @Test func httpRejectsNonOriginURLShapes() async throws {
        let rejectedOrigins = [
            "https://localhost:8765",
            "ftp://localhost:8765",
            "http://user@localhost:8765",
            "http://user:password@localhost:8765",
            "http://localhost:8765/",
            "http://localhost:8765/path",
            "http://localhost:8765?query=1",
            "http://localhost:8765#fragment",
            "http://localhost:8766",
            "http://127.attacker.example:8765",
            "http://localhost:8765,http://localhost:8765",
        ]

        for origin in rejectedOrigins {
            var config = makeHTTPConfig()
            config.listenPort = 8765
            let channel = EmbeddedChannel()
            let runtime = try HTTPTestRuntime(config: config)
            try addHTTPHandler(to: channel, config: config, runtime: runtime)

            var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/health")
            head.headers.add(name: "Origin", value: origin)
            try channel.writeInbound(HTTPServerRequestPart.head(head))
            try channel.writeInbound(HTTPServerRequestPart.end(nil))

            let response = try await collectResponse(from: channel)
            #expect(response.head.status == .forbidden, "origin=\(origin)")
            _ = try? channel.finish()
        }
    }

    @Test func httpAllowsExactLoopbackOrigins() async throws {
        let allowedOrigins = [
            "http://localhost:8765",
            "http://127.0.0.1:8765",
            "http://127.42.0.1:8765",
            "http://[::1]:8765",
            "http://[0:0:0:0:0:0:0:1]:8765",
        ]

        for origin in allowedOrigins {
            var config = makeHTTPConfig()
            config.listenPort = 8765
            let channel = EmbeddedChannel()
            let runtime = try HTTPTestRuntime(config: config)
            try addHTTPHandler(to: channel, config: config, runtime: runtime)

            var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/health")
            head.headers.add(name: "Origin", value: origin)
            try channel.writeInbound(HTTPServerRequestPart.head(head))
            try channel.writeInbound(HTTPServerRequestPart.end(nil))

            let response = try await collectResponse(from: channel)
            #expect(response.head.status == .ok, "origin=\(origin)")
            _ = try? channel.finish()
        }
    }

    /// A page that rebinds its own domain to the listener sends its domain in `Host` and no `Origin`.
    @Test func httpRejectsRebindingHostsBeforeEveryRoute() async throws {
        for route in OriginPolicyRoute.allCases {
            var config = makeHTTPConfig()
            config.listenPort = 8765
            config.enablesDebugEndpoints = true
            let channel = EmbeddedChannel()
            let runtime = try HTTPTestRuntime(config: config)
            try addHTTPHandler(to: channel, config: config, runtime: runtime)
            let sentinelSessionID = try await initializeHTTPChannel(channel)

            try writeOriginPolicyRequest(route, originCase: .missing, host: "attacker.example:8765", to: channel)
            let response = try await collectResponse(from: channel)

            #expect(response.head.status == .forbidden, "route=\(route)")
            #expect(response.body == "host not allowed", "route=\(route)")
            #expect(runtime.hasSession(sentinelSessionID))
            #expect(runtime.startedHostCount == 0)
            _ = try? channel.finish()
        }
    }

    @Test func httpHostMustNameTheListener() async throws {
        let cases: [(listenHost: String, hosts: [String], allowed: Bool)] = [
            ("127.0.0.1", ["localhost:8765", "LOCALHOST:8765", "127.0.0.1:8765", "[::1]:8765"], true),
            ("127.0.0.1", ["attacker.example:8765", "localhost.attacker.example:8765", "localhost:8766",
                           "localhost", "user@localhost:8765", "localhost:8765/path", ""], false),
            ("0.0.0.0", ["192.168.1.10:8765", "localhost:8765"], true),
            ("0.0.0.0", ["attacker.example:8765"], false),
            ("mac.example", ["mac.example:8765", "192.168.1.10:8765"], true),
            ("mac.example", ["other.example:8765"], false),
        ]
        for testCase in cases {
            for host in testCase.hosts {
                var config = makeHTTPConfig()
                config.listenHost = testCase.listenHost
                config.listenPort = 8765
                let channel = EmbeddedChannel()
                let runtime = try HTTPTestRuntime(config: config)
                try addHTTPHandler(to: channel, config: config, runtime: runtime)

                var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/health")
                head.headers.add(name: "Host", value: host)
                try channel.writeInbound(HTTPServerRequestPart.head(head))
                try channel.writeInbound(HTTPServerRequestPart.end(nil))

                let response = try await collectResponse(from: channel)
                #expect(response.head.status == (testCase.allowed ? .ok : .forbidden),
                        "listen=\(testCase.listenHost) host=\(host)")
                _ = try? channel.finish()
            }
        }
    }

    @Test func httpRejectsMultipleHostHeaders() async throws {
        var config = makeHTTPConfig()
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/health")
        head.headers.add(name: "Host", value: "localhost:8765")
        head.headers.add(name: "Host", value: "attacker.example:8765")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .forbidden)
        #expect(response.body == "host not allowed")
    }

    @Test func httpAllowsOriginMatchingEphemeralListenerPort() async throws {
        let config = makeHTTPConfig()
        let runtime = try HTTPTestRuntime(config: config)
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)

        do {
            var components = URLComponents(url: server.url, resolvingAgainstBaseURL: false)!
            components.path = "/health"
            let requestURL = try #require(components.url)
            let port = try #require(server.url.port)
            var request = URLRequest(url: requestURL)
            request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")

            let (responseData, response) = try await withTestURLSession { session in
                try await session.data(for: request)
            }
            let httpResponse = try #require(response as? HTTPURLResponse)
            #expect(httpResponse.statusCode == HTTPResponseStatus.ok.code)
            #expect(String(data: responseData, encoding: .utf8) == "ok")
        } catch {
            try? await server.shutdown()
            throw error
        }

        try await server.shutdown()
    }

    @Test func httpRejectsOriginBeforeApplyingBodyLimit() async throws {
        var config = makeHTTPConfig(maxBodyBytes: 1)
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Origin", value: "http://example.invalid:8765")
        var body = channel.allocator.buffer(capacity: 2)
        body.writeString("{}")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .forbidden)
        #expect(response.body == "origin not allowed")
        #expect(runtime.startedHostCount == 0)
    }

    @Test func httpRejectsInvalidOrigin() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        try writeInitializePost(to: channel, origin: "https://example.invalid")

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .forbidden)
        #expect(response.body == "origin not allowed")
        #expect(response.head.headers.first(name: "Mcp-Session-Id") == nil)
    }

    @Test func httpRejectsOriginHostnameWithLoopbackPrefix() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        try writeInitializePost(to: channel, origin: "http://127.attacker.example:8765")

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .forbidden)
        #expect(response.body == "origin not allowed")
        #expect(response.head.headers.first(name: "Mcp-Session-Id") == nil)
    }

    @Test func httpRejectsOriginWithImplicitDefaultPortMismatch() async throws {
        var config = makeHTTPConfig()
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        try writeInitializePost(
            to: channel,
            host: "localhost:8765",
            origin: "http://localhost"
        )

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .forbidden)
        #expect(response.body == "origin not allowed")
        #expect(response.head.headers.first(name: "Mcp-Session-Id") == nil)
    }

    @Test func httpRejectsNonLoopbackOriginMatchingHostHeaderWhenBoundToWildcard() async throws {
        var config = makeHTTPConfig()
        config.listenHost = "0.0.0.0"
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        try writeInitializePost(
            to: channel,
            host: "192.0.2.10:8765",
            origin: "http://192.0.2.10:8765"
        )

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .forbidden)
        #expect(response.body == "origin not allowed")
        #expect(response.head.headers.first(name: "Mcp-Session-Id") == nil)
    }

    @Test func httpRejectsDNSOriginMatchingHostHeaderWhenBoundToWildcard() async throws {
        var config = makeHTTPConfig()
        config.listenHost = "0.0.0.0"
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        try writeInitializePost(
            to: channel,
            host: "attacker.example:8765",
            origin: "http://attacker.example:8765"
        )

        let response = try await collectResponse(from: channel)
        // The Host check rejects the rebound name before the Origin check runs.
        #expect(response.head.status == .forbidden)
        #expect(response.body == "host not allowed")
        #expect(response.head.headers.first(name: "Mcp-Session-Id") == nil)
    }

    @Test func httpAllowsLoopbackOriginWhenBoundToWildcard() async throws {
        var config = makeHTTPConfig()
        config.listenHost = "0.0.0.0"
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        try writeInitializePost(
            to: channel,
            host: "localhost:8765",
            origin: "http://localhost:8765"
        )

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Mcp-Session-Id") != nil)
    }

    @Test func httpAllowsOriginMatchingExplicitListenHost() async throws {
        var config = makeHTTPConfig()
        config.listenHost = "192.0.2.10"
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        try writeInitializePost(
            to: channel,
            host: "192.0.2.10:8765",
            origin: "http://192.0.2.10:8765"
        )

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Mcp-Session-Id") != nil)
    }

    @Test func httpRejectsLoopbackOriginForExplicitNonLoopbackListener() async throws {
        var config = makeHTTPConfig()
        config.listenHost = "192.0.2.10"
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        try writeInitializePost(
            to: channel,
            origin: "http://localhost:8765"
        )

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .forbidden)
        #expect(response.body == "origin not allowed")
        #expect(response.head.headers.first(name: "Mcp-Session-Id") == nil)
    }

    @Test func httpRejectsOriginMismatchingHostHeaderWhenBoundToWildcard() async throws {
        var config = makeHTTPConfig()
        config.listenHost = "0.0.0.0"
        config.listenPort = 8765
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        try writeInitializePost(
            to: channel,
            host: "192.0.2.10:8765",
            origin: "http://example.invalid:8765"
        )

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .forbidden)
        #expect(response.body == "origin not allowed")
        #expect(response.head.headers.first(name: "Mcp-Session-Id") == nil)
    }

    @Test func httpPostRejectsLargeBody() async throws {
        let config = makeHTTPConfig(maxBodyBytes: 1)
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
        head.headers.add(name: "Accept", value: "application/json, text/event-stream")
        head.headers.add(name: "Content-Type", value: "application/json")
        var body = channel.allocator.buffer(capacity: 2)
        body.writeString("{}")
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .payloadTooLarge)
    }

    @Test func httpInitializeCreatesSessionAndReturnsResponse() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

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

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let sessionID = try #require(response.head.headers.first(name: "Mcp-Session-Id"))
        #expect(sessionID.isEmpty == false)

        let responseObject =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let responseID = (responseObject?["id"] as? NSNumber)?.intValue
        #expect(responseID == 1)
        let result = responseObject?["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == MCP.ProtocolVersion.current)
        #expect(
            runtime.controlService.sessions.phase(of: ProxySessionID(rawValue: sessionID))
                == .initialized(protocolVersion: MCP.ProtocolVersion.current)
        )
        // The broker answers initialize itself; no host process starts for it.
        #expect(runtime.startedHostCount == 0)
    }

    @Test func httpInitializedSessionSurvivesHostProcessLoss() async throws {
        let config = makeHTTPConfig(requestTimeout: 5)
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let toolCalls = NIOLockedValueBox(0)
        let runtime = try HTTPTestRuntime(config: config) { _, _ in
            let call = toolCalls.withLockedValue { count in
                count += 1
                return count
            }
            return call == 1 ? .hold : .result(.object(["content": .array([])]))
        }
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        try postJSON(
            toolsCallPayload(id: 2, name: "XcodeListTemplates", arguments: [:]),
            sessionID: sessionID,
            to: channel
        )
        let original = try await runtime.hosts.started.nextValue(at: 0)
        try await original.heldRequest.wait(description: "the first tool call reached the host")
        original.exit()

        let unavailable = try await collectResponse(from: channel)
        let errorObject = try #require(
            JSONSerialization.jsonObject(with: Data(unavailable.body.utf8)) as? [String: Any]
        )
        let error = try #require(errorObject["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == -32001)
        #expect(error["message"] as? String == "upstream unavailable")
        #expect(
            runtime.controlService.sessions.phase(of: ProxySessionID(rawValue: sessionID))
                == .initialized(protocolVersion: MCP.ProtocolVersion.current)
        )

        try postJSON(
            toolsCallPayload(id: 3, name: "XcodeListTemplates", arguments: [:]),
            sessionID: sessionID,
            to: channel
        )
        let recovered = try await collectResponse(from: channel)
        let resultObject = try #require(
            JSONSerialization.jsonObject(with: Data(recovered.body.utf8)) as? [String: Any]
        )
        #expect(recovered.head.status == .ok)
        #expect(resultObject["result"] != nil)
        #expect(resultObject["error"] == nil)
        #expect(runtime.startedHostCount == 2)
    }

    @Test func httpUnknownJSONRPCResponseRouteIsAcknowledgedWithoutForwarding() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        let sessionID = try await initializeHTTPChannel(channel)
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "xcode-mcp-proxy.server-request.999",
            "result": ["ok": true],
        ]
        try postJSON(payload, sessionID: sessionID, to: channel)

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .accepted)
        #expect(response.body.isEmpty)
        #expect(runtime.startedHostCount == 0)
    }

    @Test func httpMalformedJSONRPCObjectWithIDReturnsInvalidRequestError() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

        let sessionID = try await initializeHTTPChannel(channel)
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 123,
        ]
        try postJSON(payload, sessionID: sessionID, to: channel)

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let responseObject = try #require(
            JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
                as? [String: Any]
        )
        #expect((responseObject["id"] as? NSNumber)?.intValue == 123)
        let error = try #require(responseObject["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == -32600)
        #expect(runtime.startedHostCount == 0)
    }

    @Test func httpInitializePrefersJSONWhenClientAcceptsJSONAndEventStream() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

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

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "application/json")
    }

    @Test func httpInitializeRequiresID() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

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

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Mcp-Session-Id") == nil)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32600)
        #expect((error?["message"] as? String) == "invalid request")
    }

    @Test func httpJSONArrayBodyIsRejectedBeforeInitializeRouting() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

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

        let response = try await collectResponse(from: channel)
        assertBatchRejected(response)
        #expect(response.head.headers.first(name: "Mcp-Session-Id") == nil)
    }

    @Test func httpBatchShapeMatrixIsRejectedWithoutDownstreamSideEffects() async throws {
        let request = toolsListPayload(id: 42)
        let payloads: [[Any]] = [
            [],
            [request],
            [request, "invalid batch member"],
        ]

        for payload in payloads {
            let config = makeHTTPConfig()
            let channel = EmbeddedChannel()
            let runtime = try HTTPTestRuntime(config: config)
            try addHTTPHandler(to: channel, config: config, runtime: runtime)

            try postJSONArray(payload, sessionID: nil, to: channel)
            let response = try await collectResponse(from: channel)
            assertBatchRejected(response)

            #expect(response.head.headers.first(name: "Mcp-Session-Id") == nil)
            #expect(runtime.startedHostCount == 0)
            _ = try channel.finish()
        }
    }

    @Test func httpJSONArrayBodyIsRejectedBeforeUpstreamRouting() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        try postJSONArray([toolsListPayload(id: 42)], sessionID: sessionID, to: channel)

        let response = try await collectResponse(from: channel)
        assertBatchRejected(response)
        #expect(runtime.startedHostCount == 0)
    }

    @Test func httpTimeoutReturnsMCPErrorAndCancelsTheHostRequest() async throws {
        let config = makeHTTPConfig(requestTimeout: 1)
        let clock = TestClock()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config, clock: makeHTTPTestClock(clock)) { _, _ in .hold }
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        try postJSON(
            toolsCallPayload(id: 2001, name: "DocumentationSearch", arguments: ["query": "timeout"]),
            sessionID: sessionID,
            to: channel
        )
        let host = try await runtime.hosts.started.nextValue(at: 0)
        try await host.heldRequest.wait(description: "the tool call reached the host")
        try await waitForSuspendedSleepers(on: clock)
        clock.advance(by: .seconds(1))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "application/json")
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        #expect((object?["id"] as? NSNumber)?.intValue == 2001)
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32000)
        #expect((error?["message"] as? String) == "upstream timeout")

        let heldID = try #require(host.requests("tools/call").first?["id"])
        let cancellations = try await runtime.waitForHostMessages("notifications/cancelled")
        guard case .object(let params)? = cancellations.first?["params"] else {
            Issue.record("the host cancellation has no parameters")
            return
        }
        #expect(params["requestId"] == heldID)
    }

    @Test func httpPostRequiresBothJSONAndEventStreamAcceptTypes() async throws {
        let config = makeHTTPConfig(requestTimeout: 0.1)
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        let data = try JSONSerialization.data(withJSONObject: toolsListPayload(id: 2002), options: [])
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

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .notAcceptable)
        #expect(response.head.headers.first(name: "Content-Type") == "text/plain; charset=utf-8")
        #expect(response.body == "client must accept application/json and text/event-stream")
    }

    @Test func httpMalformedJSONReturnsParseErrorBeforeUpstreamUnavailable() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

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

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32700)
        #expect((error?["message"] as? String) == "invalid json")
        #expect(runtime.startedHostCount == 0)
    }

    @Test func httpOverloadedErrorResponseReachesTheClient() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config) { method, _ in
            #expect(method == "tools/call")
            return .error(code: -32002, message: "upstream overloaded")
        }
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        try postJSON(
            toolsCallPayload(id: 3101, name: "DocumentationSearch", arguments: ["query": "busy"]),
            sessionID: sessionID,
            to: channel
        )

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        #expect((object?["id"] as? NSNumber)?.intValue == 3101)
        let error = object?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32002)
        #expect((error?["message"] as? String) == "upstream overloaded")
    }

    @Test func httpInitializeIgnoresCallerProvidedSessionHeader() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)

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

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let returnedSessionID = try #require(response.head.headers.first(name: "Mcp-Session-Id"))
        #expect(returnedSessionID.isEmpty == false)
        #expect(returnedSessionID != "missing-session")
        #expect(runtime.hasSession(returnedSessionID))
        #expect(runtime.hasSession("missing-session") == false)
        #expect(response.body.contains("\"result\""))
    }

    @Test func httpSSEHandshakeSucceedsWithSession() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/mcp")
        head.headers.add(name: "Accept", value: "text/event-stream")
        head.headers.add(name: "Mcp-Session-Id", value: sessionID)
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        #expect(response.head.headers.first(name: "Content-Type") == "text/event-stream")
        #expect(response.body.contains(": ok"))
    }

    @Test func httpToolsListReturnsThePublicCatalog() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        try postJSON(toolsListPayload(id: 2), sessionID: sessionID, to: channel)

        let toolsResponse = try await collectResponse(from: channel)
        #expect(toolsResponse.head.status == .ok)

        let responseObject =
            try JSONSerialization.jsonObject(with: Data(toolsResponse.body.utf8), options: [])
            as? [String: Any]
        let responseID = (responseObject?["id"] as? NSNumber)?.intValue
        #expect(responseID == 2)

        let result = try #require(responseObject?["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let expected = try XcodeToolCatalog.publicResult(
            from: HTTPTestRuntime.defaultTools,
            managementTools: NativeHostBroker.managementTools
        )
        #expect(tools.compactMap { $0["name"] as? String } == Self.toolNames(in: expected))
        #expect(result["nextCursor"] == nil)
    }

    @Test func httpToolsListRejectsUnissuedCursorWithoutCacheLookup() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        // The public catalog never issues a downstream cursor.
        let toolsPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [
                "cursor": "cursor-1"
            ],
        ]
        try postJSON(toolsPayload, sessionID: sessionID, to: channel)

        let toolsResponse = try await collectResponse(from: channel)
        #expect(toolsResponse.head.status == .ok)

        let responseObject =
            try JSONSerialization.jsonObject(with: Data(toolsResponse.body.utf8), options: [])
            as? [String: Any]
        let responseID = (responseObject?["id"] as? NSNumber)?.intValue
        #expect(responseID == 2)

        let error = responseObject?["error"] as? [String: Any]
        #expect((error?["code"] as? NSNumber)?.intValue == -32602)
        #expect(responseObject?["result"] == nil)
        #expect(runtime.startedHostCount == 0)
    }

    @Test func httpSingleItemBatchToolsListIsRejectedBeforeCacheLookup() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        try postJSONArray([toolsListPayload(id: 2)], sessionID: sessionID, to: channel)

        let response = try await collectResponse(from: channel)
        assertBatchRejected(response)
        #expect(runtime.startedHostCount == 0)
    }

    @Test func httpToolsListCachesResultOnMissWhenParamsArePresent() async throws {
        var config = makeHTTPConfig()
        config.prewarmToolsList = false
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        // The first listing loads the host catalog once; later listings reuse it even with params.
        let toolsPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [
                "_meta": ["trace": "first"]
            ],
        ]
        try postJSON(toolsPayload, sessionID: sessionID, to: channel)

        let toolsResponse = try await collectResponse(from: channel)
        #expect(toolsResponse.head.status == .ok)
        #expect(runtime.host?.requests("tools/list").count == 1)

        let toolsPayload2: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/list",
            "params": [
                "_meta": ["trace": "second"]
            ],
        ]
        try postJSON(toolsPayload2, sessionID: sessionID, to: channel)

        let toolsResponse2 = try await collectResponse(from: channel)
        #expect(toolsResponse2.head.status == .ok)
        #expect(toolsResponse2.body.contains("\"tools\""))
        #expect(runtime.startedHostCount == 1)
        #expect(runtime.host?.requests("tools/list").count == 1)
    }

    @Test func httpToolsListPublishesTheProxyDescriptionOfNativeTools() async throws {
        let nativeTools = JSONValue.object(["tools": .array([
            .object([
                "name": .string("XcodeRefreshCodeIssuesInFile"),
                "description": .string("original description"),
                "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
            ]),
        ])])
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config, tools: nativeTools)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        try postJSON(toolsListPayload(id: 2), sessionID: sessionID, to: channel)

        let response = try await collectResponse(from: channel)
        let object =
            try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: [])
            as? [String: Any]
        let result = object?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        let description = tools?.first { $0["name"] as? String == "XcodeRefreshCodeIssuesInFile" }?[
            "description"
        ] as? String
        let expected = try XcodeToolCatalog.publicResult(
            from: nativeTools,
            managementTools: NativeHostBroker.managementTools
        )
        #expect(description == Self.description(of: "XcodeRefreshCodeIssuesInFile", in: expected))
        #expect(description != "original description")
    }

    @Test func httpToolsListPrefersJSONWhenClientAcceptsJSONAndEventStream() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        try postJSON(toolsListPayload(id: 2), sessionID: sessionID, to: channel)

        let toolsResponse = try await collectResponse(from: channel)
        #expect(toolsResponse.head.status == .ok)
        #expect(toolsResponse.head.headers.first(name: "Content-Type") == "application/json")
    }

    @Test(arguments: HostFailureCase.allCases)
    func httpToolCallFailuresKeepTheirClassification(failure: HostFailureCase) async throws {
        let config = makeHTTPConfig(requestTimeout: 1)
        let clock = TestClock()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config, clock: makeHTTPTestClock(clock)) { _, _ in
            failure.hostReply
        }
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        try postJSON(
            toolsCallPayload(id: 501, name: "DocumentationSearch", arguments: ["query": "failure"]),
            sessionID: sessionID,
            to: channel
        )
        if case .hold = failure.hostReply {
            let host = try await runtime.hosts.started.nextValue(at: 0)
            try await host.heldRequest.wait(description: "the tool call reached the host")
            switch failure {
            case .timeout:
                try await waitForSuspendedSleepers(on: clock)
                clock.advance(by: .seconds(1))
            case .processExit:
                host.exit()
            case .invalidResponse:
                let id = try #require(host.requests("tools/call").first?["id"])
                host.emit(.object(["jsonrpc": .string("2.0"), "id": id]))
            case .backpressure, .rpcError:
                break
            }
        }

        let response = try await collectResponse(from: channel)
        #expect(response.head.status == .ok)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any]
        )
        #expect((object["id"] as? NSNumber)?.intValue == 501)
        let error = try #require(object["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == failure.code)
        #expect(error["message"] as? String == failure.message)
    }

    @Test func httpResourceTemplatesListReturnsEmptyArray() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/templates/list",
            "params": [String: Any](),
        ]
        try postJSON(payload, sessionID: sessionID, to: channel)

        let response = try await collectResponse(from: channel)
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
        #expect(runtime.startedHostCount == 0)
    }

    private func toolsListPayload(id: Int) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/list"]
    }

    private static func toolNames(in catalog: JSONValue) -> [String] {
        guard case .object(let result) = catalog, case .array(let tools)? = result["tools"] else { return [] }
        return tools.compactMap { tool in
            guard case .object(let fields) = tool, case .string(let name)? = fields["name"] else { return nil }
            return name
        }
    }

    private static func description(of name: String, in catalog: JSONValue) -> String? {
        guard case .object(let result) = catalog, case .array(let tools)? = result["tools"] else { return nil }
        for tool in tools {
            guard case .object(let fields) = tool, fields["name"] == .string(name) else { continue }
            if case .string(let description)? = fields["description"] { return description }
        }
        return nil
    }

    private func writeInitializePost(
        to channel: EmbeddedChannel,
        host: String? = nil,
        origin: String? = nil
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
        if let origin {
            head.headers.add(name: "Origin", value: origin)
        }
        var body = channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        try channel.writeInbound(HTTPServerRequestPart.body(body))
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
    }

    private enum ProtocolVersionRoute: CaseIterable {
        case post
        case sse
        case delete
    }

    private enum ProtocolVersionHeaderCase: CaseIterable {
        case missing
        case match
        case mismatch
        case unsupported
        case invalid
        case multiple

        var isAccepted: Bool {
            switch self {
            case .missing, .match:
                return true
            case .mismatch, .unsupported, .invalid, .multiple:
                return false
            }
        }

        func apply(to headers: inout HTTPHeaders) {
            switch self {
            case .missing:
                break
            case .match:
                headers.add(
                    name: HTTPRequestValidator.protocolVersionHeader,
                    value: MCP.ProtocolVersion.current
                )
            case .mismatch:
                headers.add(
                    name: HTTPRequestValidator.protocolVersionHeader,
                    value: "2025-11-25"
                )
            case .unsupported:
                headers.add(
                    name: HTTPRequestValidator.protocolVersionHeader,
                    value: "2024-11-05"
                )
            case .invalid:
                headers.add(name: HTTPRequestValidator.protocolVersionHeader, value: "")
            case .multiple:
                headers.add(
                    name: HTTPRequestValidator.protocolVersionHeader,
                    value: MCP.ProtocolVersion.current
                )
                headers.add(
                    name: HTTPRequestValidator.protocolVersionHeader,
                    value: MCP.ProtocolVersion.current
                )
            }
        }
    }

    private func writeProtocolVersionRequest(
        _ route: ProtocolVersionRoute,
        headerCase: ProtocolVersionHeaderCase,
        sessionID: String,
        to channel: EmbeddedChannel
    ) throws {
        let method: HTTPMethod =
            switch route {
            case .post: .POST
            case .sse: .GET
            case .delete: .DELETE
            }
        var head = HTTPRequestHead(version: .http1_1, method: method, uri: "/mcp")
        head.headers.add(name: HTTPRequestValidator.sessionHeader, value: sessionID)
        switch route {
        case .post:
            head.headers.add(name: "Accept", value: "application/json, text/event-stream")
            head.headers.add(name: "Content-Type", value: "application/json")
        case .sse:
            head.headers.add(name: "Accept", value: "text/event-stream")
        case .delete:
            break
        }
        headerCase.apply(to: &head.headers)
        try channel.writeInbound(HTTPServerRequestPart.head(head))

        if route == .post {
            let data = try JSONSerialization.data(withJSONObject: toolsListPayload(id: 2), options: [])
            var body = channel.allocator.buffer(capacity: data.count)
            body.writeBytes(data)
            try channel.writeInbound(HTTPServerRequestPart.body(body))
        }
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
    }

    private enum OriginPolicyRoute: CaseIterable {
        case health
        case debugSnapshot
        case debugReset
        case sse
        case deleteSession
        case post
        case notFound

        var method: HTTPMethod {
            switch self {
            case .health, .debugSnapshot, .sse, .notFound:
                return .GET
            case .debugReset, .post:
                return .POST
            case .deleteSession:
                return .DELETE
            }
        }

        var uri: String {
            switch self {
            case .health:
                return "/health"
            case .debugSnapshot:
                return "/debug/upstreams?includeSensitive=1"
            case .debugReset:
                return "/debug/reset"
            case .sse, .deleteSession, .post:
                return "/mcp"
            case .notFound:
                return "/not-found"
            }
        }

        var statusWithoutOriginRejection: HTTPResponseStatus {
            switch self {
            case .health, .debugSnapshot, .post:
                return .ok
            case .debugReset:
                return .notFound
            case .sse, .deleteSession:
                return .badRequest
            case .notFound:
                return .notFound
            }
        }
    }

    private enum OriginPolicyHeaderCase: CaseIterable {
        case missing
        case allowed
        case disallowed
        case empty
        case multiple
        case null
        case malformed

        var isRejected: Bool {
            switch self {
            case .missing, .allowed:
                return false
            case .disallowed, .empty, .multiple, .null, .malformed:
                return true
            }
        }

        func apply(to headers: inout HTTPHeaders) {
            switch self {
            case .missing:
                break
            case .allowed:
                headers.add(name: "Origin", value: "http://localhost:8765")
            case .disallowed:
                headers.add(name: "Origin", value: "http://example.invalid:8765")
            case .empty:
                headers.add(name: "Origin", value: "")
            case .multiple:
                headers.add(name: "Origin", value: "http://localhost:8765")
                headers.add(name: "Origin", value: "http://127.0.0.1:8765")
            case .null:
                headers.add(name: "Origin", value: "null")
            case .malformed:
                headers.add(name: "Origin", value: "http://[::1")
            }
        }
    }

    private func writeOriginPolicyRequest(
        _ route: OriginPolicyRoute,
        originCase: OriginPolicyHeaderCase,
        host: String? = nil,
        to channel: EmbeddedChannel
    ) throws {
        var head = HTTPRequestHead(version: .http1_1, method: route.method, uri: route.uri)
        if let host { head.headers.add(name: "Host", value: host) }
        if route == .sse {
            head.headers.add(name: "Accept", value: "text/event-stream")
        } else if route == .post {
            head.headers.add(name: "Accept", value: "application/json, text/event-stream")
            head.headers.add(name: "Content-Type", value: "application/json")
        }
        originCase.apply(to: &head.headers)
        try channel.writeInbound(HTTPServerRequestPart.head(head))

        if route == .post {
            let payload: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": ["capabilities": [String: Any]()],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            var body = channel.allocator.buffer(capacity: data.count)
            body.writeBytes(data)
            try channel.writeInbound(HTTPServerRequestPart.body(body))
        }
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
    }

}

/// How a host fails a tool call, and the reply the client receives for it.
enum HostFailureCase: CaseIterable, Sendable {
    case timeout, processExit, backpressure, rpcError, invalidResponse

    var hostReply: FakeHostSession.Reply {
        switch self {
        case .backpressure: .backpressure
        case .rpcError: .error(code: -32602, message: "Invalid params")
        case .timeout, .processExit, .invalidResponse: .hold
        }
    }

    /// The JSON-RPC error code the client receives.
    var code: Int {
        switch self {
        case .timeout: -32000
        case .processExit: -32001
        case .backpressure: -32002
        case .rpcError: -32602
        case .invalidResponse: -32603
        }
    }

    var message: String {
        switch self {
        case .timeout: "upstream timeout"
        case .processExit: "upstream unavailable"
        case .backpressure: "upstream overloaded"
        case .rpcError: "Invalid params"
        case .invalidResponse: "invalid upstream response"
        }
    }
}
