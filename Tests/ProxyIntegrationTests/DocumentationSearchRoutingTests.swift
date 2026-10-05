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
import XcodeMCPProxyTestSupport

extension HTTPHandlerTests {
    @Test func httpDocumentationSearchIsForwardedToNativeHost() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
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

    @Test func httpBatchDocumentationSearchIsForwardedToNativeHost() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
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
            let response = try await assertHTTPBatchRejected(
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
            #expect(response.statusCode == 400)
            #expect(sessionManager.sentToolNames().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchToolsListUsesLocalToolSurfaceAndForwardsOtherCalls() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
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
            ])!,
            sourceUpstream: 0
        )
        let server = try TestHTTPHandlerServer.start(
            config: config,
            sessionManager: sessionManager
        )

        do {
            let response = try await assertHTTPBatchRejected(
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
            #expect(response.statusCode == 400)
            #expect(sessionManager.sentMethods().isEmpty)
            #expect(sessionManager.sentToolNames().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpResourcesListReturnsEmptyArray() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        _ = sessionManager.session(id: "session-1")
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/list",
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

        let response = try await collectResponse(from: channel)
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

    @Test func httpSingleItemBatchResourcesListIsRejected() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let sessionManager = TestRuntimeCoordinator(config: config)
        _ = sessionManager.session(id: "session-batch-resources")
        try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

        let payload: [[String: Any]] = [[
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/list",
            "params": [String: Any](),
        ]]
        try postJSONArray(payload, sessionID: "session-batch-resources", to: channel)

        let response = try await collectResponse(from: channel)
        assertBatchRejected(response)
    }
}
