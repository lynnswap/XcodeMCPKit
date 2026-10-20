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
        let runtime = try HTTPTestRuntime(config: config) { method, params in
            #expect(method == "tools/call")
            #expect(params["name"] == .string("DocumentationSearch"))
            return .result(.object(["content": .array([
                .object(["type": .string("text"), "text": .string("{\"answer\":\"upstream-docs\"}")]),
            ])]))
        }
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)

        do {
            let sessionID = try await initializeHTTPSession(url: server.url)
            let (response, body) = try await postHTTPJSON(
                url: server.url,
                sessionID: sessionID,
                payload: toolsCallPayload(
                    id: 62,
                    name: "DocumentationSearch",
                    arguments: [
                        "query": "hello",
                    ]
                )
            )

            #expect(response.statusCode == 200)
            #expect((body["id"] as? NSNumber)?.intValue == 62)
            let result = body["result"] as? [String: Any]
            let content = result?["content"] as? [[String: Any]]
            #expect(content?.first?["text"] as? String == "{\"answer\":\"upstream-docs\"}")
            let calls = runtime.toolCalls()
            #expect(calls.map(\.name) == ["DocumentationSearch"])
            #expect(calls.first?.arguments["query"] == .string("hello"))
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchDocumentationSearchIsForwardedToNativeHost() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
        let runtime = try HTTPTestRuntime(config: config)
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)

        do {
            let sessionID = try await initializeHTTPSession(url: server.url)
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: sessionID,
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
                        name: "XcodeListTemplates",
                        arguments: [:]
                    ),
                ]
            )
            #expect(response.statusCode == 400)
            #expect(runtime.toolCalls().isEmpty)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpBatchToolsListUsesLocalToolSurfaceAndForwardsOtherCalls() async throws {
        let config = makeHTTPConfig(requestTimeout: 2)
        let runtime = try HTTPTestRuntime(config: config)
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)

        do {
            let sessionID = try await initializeHTTPSession(url: server.url)
            let response = try await assertHTTPBatchRejected(
                url: server.url,
                sessionID: sessionID,
                payload: [
                    [
                        "jsonrpc": "2.0",
                        "id": 731,
                        "method": "tools/list",
                    ],
                    toolsCallPayload(
                        id: 732,
                        name: "XcodeListTemplates",
                        arguments: [:]
                    ),
                ]
            )
            #expect(response.statusCode == 400)
            #expect(runtime.startedHostCount == 0)
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
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/list",
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
        let resources = result?["resources"] as? [Any]
        #expect(resources?.isEmpty == true)
        // The broker answers resources/list itself; no host process starts for it.
        #expect(runtime.startedHostCount == 0)
    }

    @Test func httpSingleItemBatchResourcesListIsRejected() async throws {
        let config = makeHTTPConfig()
        let channel = EmbeddedChannel()
        defer { _ = try? channel.finish() }
        let runtime = try HTTPTestRuntime(config: config)
        try addHTTPHandler(to: channel, config: config, runtime: runtime)
        let sessionID = try await initializeHTTPChannel(channel)

        let payload: [[String: Any]] = [[
            "jsonrpc": "2.0",
            "id": 1,
            "method": "resources/list",
            "params": [String: Any](),
        ]]
        try postJSONArray(payload, sessionID: sessionID, to: channel)

        let response = try await collectResponse(from: channel)
        assertBatchRejected(response)
        #expect(runtime.startedHostCount == 0)
    }
}
