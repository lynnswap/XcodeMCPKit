@testable import XcodeMCPProxyRuntimeTestSupport
import XcodeMCPProxyRuntimeContract
@testable import XcodeMCPCore
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyHTTP
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

@Suite(.serialized, .asyncTestCleanup)
struct HTTPConcurrencyTests {
    @Test(arguments: ["BuildProject", "FutureNativeTool"])
    func nativeToolCallsResolveWorkspacePathsAndPreserveProviderErrors(toolName: String) async throws {
        let config = makeHTTPConfig(requestTimeout: 5)
        let tools = JSONValue.object(["tools": .array([.object([
            "name": .string("BuildProject"),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(["workspaceIdentifier": .object(["type": .string("string")])]),
                "required": .array([.string("workspaceIdentifier")]),
            ]),
        ])])])
        let runtime = try HTTPTestRuntime(config: config, tools: tools) { _, params in
            var arguments: [String: JSONValue] = [:]
            if case .object(let values)? = params["arguments"] { arguments = values }
            if params["name"] == .string(NativeHostBroker.openWorkspaceTool), let path = arguments["path"] {
                return .result(.object(["structuredContent": .object([
                    "workspaceIdentifier": .string("native-workspace"), "workspacePath": path,
                ])]))
            }
            return .result(.object([
                "isError": .bool(true),
                "content": .array([.object(["type": .string("text"), "text": .string("project unavailable")])]),
                "structuredContent": .object(arguments),
            ]))
        }
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)
        do {
            let sessionID = try await initializeHTTPSession(url: server.url)
            let (_, catalog) = try await postJSON(url: server.url, sessionID: sessionID, payload: toolListPayload(id: 2))
            let descriptors = try #require((catalog["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            let build = try #require(descriptors.first { $0["name"] as? String == "BuildProject" })
            let schema = try #require(build["inputSchema"] as? [String: Any])
            #expect((schema["properties"] as? [String: Any])?.keys.sorted() == ["workspaceIdentifier"])
            #expect(schema["required"] as? [String] == ["workspaceIdentifier"])

            let workspace = "/Work/Project with spaces.xcodeproj"
            let (_, reply) = try await postJSON(url: server.url, sessionID: sessionID,
                payload: toolCallPayload(id: 3, name: toolName, arguments: ["workspaceIdentifier": workspace]))
            let result = try #require(reply["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == true)
            // The path opens the workspace on the host, which then receives its own handle.
            let calls = runtime.toolCalls()
            #expect(calls.first?.name == NativeHostBroker.openWorkspaceTool)
            #expect(calls.first?.arguments["path"] == .string(workspace))
            if toolName == "BuildProject" {
                #expect(calls.map(\.name) == [NativeHostBroker.openWorkspaceTool, "BuildProject"])
                #expect(calls.last?.arguments["workspaceIdentifier"] == .string("native-workspace"))
                let content = result["content"] as? [[String: Any]]
                #expect(content?.first?["text"] as? String == "project unavailable")
            } else {
                // A tool missing from the host catalog is refused before it reaches the host.
                #expect(calls.map(\.name) == [NativeHostBroker.openWorkspaceTool])
            }
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpAndSwiftClientExposeTheCompleteCatalog() async throws {
        var config = makeHTTPConfig(requestTimeout: 5)
        config.prewarmToolsList = false
        let runtime = try HTTPTestRuntime(config: config)
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)
        let expected = try Set(toolNames(in: XcodeToolCatalog.publicResult(
            from: HTTPTestRuntime.defaultTools, managementTools: NativeHostBroker.managementTools
        )))
        do {
            let client = try await XcodeMCP(configuration: .init(
                transport: .streamableHTTP(endpoint: server.url), requestTimeout: .seconds(5)
            ))
            do {
                let tools = try await client.listTools()
                #expect(Set(tools.map(\.name)) == expected)
                let sessionID = try await initializeHTTPSession(url: server.url)
                let (toolsResponse, body) = try await postJSON(url: server.url, sessionID: sessionID, payload: toolListPayload(id: 101))
                #expect(toolsResponse.statusCode == 200)
                let result = try #require(body["result"] as? [String: Any])
                let descriptors = try #require(result["tools"] as? [[String: Any]])
                #expect(Set(descriptors.compactMap { $0["name"] as? String }) == expected)
                #expect(result["nextCursor"] == nil)
                // Both sessions see the catalog the host supplied once.
                #expect(runtime.host?.requests("tools/list").count == 1)
            } catch {
                await client.close()
                throw error
            }
            await client.close()
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test(arguments: ["DocumentationSearch", "XcodeListWorkspaces"])
    func httpCancellationDoesNotWaitBehindTheRequest(toolName: String) async throws {
        let config = makeHTTPConfig(requestTimeout: 60)
        let runtime = try HTTPTestRuntime(config: config) { _, _ in .hold }
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)
        do {
            let sessionID = try await initializeHTTPSession(url: server.url)
            async let request = postJSON(
                url: server.url, sessionID: sessionID,
                payload: toolCallPayload(id: 991, name: toolName, arguments: [:]), timeout: 5
            )
            let held = try await runtime.waitForHostMessages("tools/call")
            let hostRequestID = try #require(held.first?["id"])
            #expect(hostRequestID != .number(.int(991)))

            let cancellation = try await postStatusOnly(
                url: server.url, sessionID: sessionID,
                payload: cancellationPayload(id: 991), timeout: 2
            )
            #expect(cancellation.statusCode == 202)
            let (response, body) = try await request
            #expect(response.statusCode == 200)
            #expect((body["id"] as? NSNumber)?.intValue == 991)
            let error = body["error"] as? [String: Any]
            #expect((error?["code"] as? NSNumber)?.intValue == -32800)
            #expect(error?["message"] as? String == "request cancelled")

            // The host receives the cancellation under the ID it was sent.
            let cancellations = try await runtime.waitForHostMessages("notifications/cancelled")
            guard case .object(let params)? = cancellations.first?["params"] else {
                Issue.record("the host cancellation has no parameters")
                return
            }
            #expect(params["requestId"] == hostRequestID)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func multiplexedCancellationPreservesOtherSessionsAndIDScalarTypes() async throws {
        let config = makeHTTPConfig(requestTimeout: 60)
        let runtime = try HTTPTestRuntime(config: config) { _, _ in .hold }
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)
        do {
            let sessionID = try await initializeHTTPSession(url: server.url)
            let otherSessionID = try await initializeHTTPSession(url: server.url)
            async let active = postJSON(
                url: server.url, sessionID: sessionID,
                payload: toolCallPayload(id: 1, name: "DocumentationSearch", arguments: ["query": "active"])
            )
            try await runtime.waitForToolCalls(1)
            async let stringIDRequest = postJSON(
                url: server.url, sessionID: sessionID,
                payload: toolCallPayload(id: "1", name: "DocumentationSearch", arguments: ["query": "string"])
            )
            try await runtime.waitForToolCalls(2)
            let host = try #require(runtime.host)
            let hostRequestIDs = host.requests("tools/call").compactMap { $0["id"] }
            #expect(hostRequestIDs.count == 2)

            // Only the string ID in its own session names the second request.
            let attempts: [(sessionID: String, requestID: Any)] = [
                (otherSessionID, 1), (sessionID, true), (sessionID, 999), (sessionID, "1"),
            ]
            for attempt in attempts {
                let cancellation = try await postStatusOnly(
                    url: server.url, sessionID: attempt.sessionID,
                    payload: cancellationPayload(id: attempt.requestID)
                )
                #expect(cancellation.statusCode == 202)
            }
            let (stringResponse, stringBody) = try await stringIDRequest
            #expect(stringResponse.statusCode == 200)
            #expect(stringBody["id"] as? String == "1")
            #expect(((stringBody["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue == -32800)
            let cancellations = try await runtime.waitForHostMessages("notifications/cancelled")
            guard case .object(let params)? = cancellations.first?["params"] else {
                Issue.record("the host cancellation has no parameters")
                return
            }
            #expect(params["requestId"] == hostRequestIDs.last)

            host.release("tools/call", with: .result(.object(["content": .array([])])))
            let (activeResponse, activeBody) = try await active
            #expect(activeResponse.statusCode == 200)
            #expect((activeBody["id"] as? NSNumber)?.intValue == 1)
            #expect(activeBody["result"] != nil)

            let late = try await postStatusOnly(url: server.url, sessionID: sessionID, payload: cancellationPayload(id: 1))
            #expect(late.statusCode == 202)
            #expect(host.requests("tools/call").count == 2)
            #expect(host.requests("notifications/cancelled").count == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpConcurrentInitializeRequests() async throws {
        let config = makeHTTPConfig(requestTimeout: 5)
        let runtime = try HTTPTestRuntime(config: config)
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)
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
        let config = makeHTTPConfig(requestTimeout: 5)
        let runtime = try HTTPTestRuntime(config: config)
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)
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
        var config = makeHTTPConfig(requestTimeout: 5)
        config.prewarmToolsList = false
        let runtime = try HTTPTestRuntime(config: config)
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)
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
            let firstResult = try await first
            let secondResult = try await second
            #expect(firstResult.0.statusCode == 200)
            #expect(secondResult.0.statusCode == 200)
            #expect(firstResult.1["result"] != nil)
            #expect(secondResult.1["result"] != nil)
            #expect((firstResult.1["id"] as? NSNumber)?.intValue == 100)
            #expect((secondResult.1["id"] as? NSNumber)?.intValue == 101)
            #expect(runtime.startedHostCount == 1)
            #expect(runtime.host?.requests("tools/list").count == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpConcurrentRequestsCanOverlapAcrossSessions() async throws {
        var config = makeHTTPConfig(requestTimeout: 5)
        config.prewarmToolsList = false
        let runtime = try HTTPTestRuntime(config: config)
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)
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
            let firstResult = try await first
            let secondResult = try await second
            #expect(firstResult.0.statusCode == 200)
            #expect(secondResult.0.statusCode == 200)
            #expect(firstResult.1["result"] != nil)
            #expect(secondResult.1["result"] != nil)
            #expect(runtime.startedHostCount == 1)
            #expect(runtime.host?.requests("tools/list").count == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRequestTimeoutDoesNotCancelAnotherRequestOnTheSameNativeConnection() async throws {
        let config = makeHTTPConfig(requestTimeout: 10)
        let clock = TestClock()
        let runtime = try HTTPTestRuntime(config: config, clock: makeHTTPTestClock(clock)) { _, _ in .hold }
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)
        do {
            let sessionID = try await initializeHTTPSession(url: server.url)
            async let first = postJSON(
                url: server.url, sessionID: sessionID,
                payload: toolCallPayload(id: 700, name: "DocumentationSearch", arguments: ["query": "first"])
            )
            try await runtime.waitForToolCalls(1)
            try await waitForSuspendedSleepers(on: clock)
            // The second request's deadline is one second later than the first one's.
            clock.advance(by: .seconds(1))
            async let second = postJSON(
                url: server.url, sessionID: sessionID,
                payload: toolCallPayload(id: 701, name: "DocumentationSearch", arguments: ["query": "second"])
            )
            try await runtime.waitForToolCalls(2)
            try await waitForSuspendedSleepers(on: clock, count: 2)
            clock.advance(by: .seconds(9))

            let (firstResponse, firstObject) = try await first
            #expect(firstResponse.statusCode == 200)
            #expect((firstObject["id"] as? NSNumber)?.intValue == 700)
            #expect((firstObject["error"] as? [String: Any])?["message"] as? String == "upstream timeout")

            let host = try #require(runtime.host)
            let hostRequestIDs = host.requests("tools/call").compactMap { $0["id"] }
            let cancellations = try await runtime.waitForHostMessages("notifications/cancelled")
            guard case .object(let params)? = cancellations.first?["params"] else {
                Issue.record("the host cancellation has no parameters")
                return
            }
            #expect(params["requestId"] == hostRequestIDs.first)

            host.release("tools/call", with: .result(.object(["content": .array([])])))
            let (secondResponse, secondObject) = try await second
            #expect(secondResponse.statusCode == 200)
            #expect((secondObject["id"] as? NSNumber)?.intValue == 701)
            #expect(secondObject["error"] == nil)
            #expect(host.requests("notifications/cancelled").count == 1)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpNotificationIsAcceptedWithoutWaitingForAnotherRequestResult() async throws {
        let config = makeHTTPConfig(requestTimeout: 10)
        let runtime = try HTTPTestRuntime(config: config) { _, _ in .hold }
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)
        let url = server.url

        do {
            let sessionID = try await initializeHTTPSession(url: url)
            async let first = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolCallPayload(id: 400, name: "DocumentationSearch", arguments: ["query": "pending"]),
                timeout: 10
            )
            try await runtime.waitForToolCalls(1)
            let notificationResponse = try await postStatusOnly(
                url: url,
                sessionID: sessionID,
                payload: notificationPayload(method: "notifications/test-progress"),
                timeout: 10
            )
            #expect(notificationResponse.statusCode == 202)
            // The broker handles client notifications itself; the host never receives them.
            let host = try #require(runtime.host)
            #expect(host.requests("notifications/test-progress").isEmpty)

            host.release("tools/call", with: .result(.object(["content": .array([])])))
            let firstResult = try await first
            #expect(firstResult.0.statusCode == 200)
            #expect((firstResult.1["id"] as? NSNumber)?.intValue == 400)
            #expect(firstResult.1["error"] == nil)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpToolCallNotificationIsAcceptedWithoutReachingTheHost() async throws {
        let config = makeHTTPConfig(requestTimeout: 5)
        let runtime = try HTTPTestRuntime(config: config)
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)
        let url = server.url

        do {
            let sessionID = try await initializeHTTPSession(url: url)
            let response = try await postStatusOnly(
                url: url,
                sessionID: sessionID,
                payload: toolCallNotificationPayload(
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "workspaceIdentifier": "/Work/Refresh.xcodeproj",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 202)
            #expect(runtime.startedHostCount == 0)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpServerNotificationsReachActiveSSESessions() async throws {
        let config = makeHTTPConfig(requestTimeout: 10)
        let runtime = try HTTPTestRuntime(config: config) { _, _ in .hold }
        let server = try TestHTTPHandlerServer.start(config: config, runtime: runtime)
        let url = server.url

        do {
            let sessionID = try await initializeHTTPSession(url: url)

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            request.setValue(MCP.ProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")

            let sseTask = Task<(HTTPURLResponse, [String]), Error> {
                try await withTestURLSession { session in
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ConcurrencyTestError.invalidResponse
                    }

                    var events: [String] = []
                    var iterator = bytes.lines.makeAsyncIterator()
                    while let line = try await iterator.next() {
                        if line.hasPrefix("data: ") {
                            events.append(String(line.dropFirst(6)))
                            if events.count == 2 { return (httpResponse, events) }
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
                try await server.controlService.waitForSSEClient(
                    sessionID: ProxySessionID(rawValue: sessionID)
                )
            }

            async let callResult = postJSON(
                url: url, sessionID: sessionID,
                payload: toolCallPayload(id: 5, name: "DocumentationSearch", arguments: ["query": "progress"],
                                         progressToken: "client-token"),
                timeout: 10
            )
            let held = try await runtime.waitForHostMessages("tools/call")
            guard case .object(let params)? = held.first?["params"],
                  case .object(let meta)? = params["_meta"], let hostToken = meta["progressToken"] else {
                Issue.record("the progress token did not reach the host")
                return
            }
            let host = try #require(runtime.host)
            // A host notification reaches the sessions using the host; progress reaches its requester.
            host.emit(.object([
                "jsonrpc": .string("2.0"), "method": .string("notifications/test"),
                "params": .object(["value": .number(.int(42))]),
            ]))
            host.emit(.object([
                "jsonrpc": .string("2.0"), "method": .string("notifications/progress"),
                "params": .object(["progressToken": hostToken, "progress": .number(.int(1))]),
            ]))

            let (response, events) = try await waitWithTimeout(
                "waiting for SSE notifications",
                timeout: .seconds(2)
            ) {
                try await sseTask.value
            }

            #expect(response.statusCode == 200)
            let broadcast = try jsonObject(from: try #require(events.first))
            #expect(broadcast["method"] as? String == "notifications/test")
            #expect(((broadcast["params"] as? [String: Any])?["value"] as? NSNumber)?.intValue == 42)
            let progress = try jsonObject(from: try #require(events.last))
            #expect(progress["method"] as? String == "notifications/progress")
            #expect((progress["params"] as? [String: Any])?["progressToken"] as? String == "client-token")

            host.release("tools/call", with: .result(.object(["content": .array([])])))
            let (callResponse, callBody) = try await callResult
            #expect(callResponse.statusCode == 200)
            #expect((callBody["id"] as? NSNumber)?.intValue == 5)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    private func cancellationPayload(id: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": id]]
    }

    private func toolNames(in catalog: JSONValue) -> [String] {
        guard case .object(let result) = catalog, case .array(let tools)? = result["tools"] else { return [] }
        return tools.compactMap { tool in
            guard case .object(let fields) = tool, case .string(let name)? = fields["name"] else { return nil }
            return name
        }
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
    id: Any,
    name: String,
    arguments: [String: Any],
    progressToken: String? = nil
) -> [String: Any] {
    var params: [String: Any] = ["name": name, "arguments": arguments]
    if let progressToken {
        params["_meta"] = ["progressToken": progressToken]
    }
    return [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": params,
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
    payload: [String: Any],
    timeout: TimeInterval? = nil
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

private func jsonObject(from string: String) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: Data(string.utf8), options: []) as? [String: Any]
    )
}
