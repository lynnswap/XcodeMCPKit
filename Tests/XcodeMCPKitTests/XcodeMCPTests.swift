import Foundation
import Testing

@testable import XcodeMCPKit

@Suite(.serialized)
struct XcodeMCPTests {
    @Test func asyncInitializerPerformsMCPHandshake() async throws {
        let transport = FakeXcodeMCPTransport()
        let xcode = try await XcodeMCP(
            config: .init(
                clientName: "UnitTestClient",
                clientVersion: "1.2.3",
                capabilities: [
                    "roots": .object([:]),
                    "experimental": .object(["x-test": .bool(true)]),
                ]
            ),
            transport: transport
        )
        defer {
            Task { await xcode.close() }
        }

        let sent = await transport.sentMessages()
        #expect(sent.compactMap(\.method) == ["initialize", "notifications/initialized"])

        let initializeParams = try #require(sent.first?.params?.objectValue)
        #expect(initializeParams["protocolVersion"] == .string("2025-06-18"))
        #expect(initializeParams["clientInfo"] == .object([
            "name": .string("UnitTestClient"),
            "version": .string("1.2.3"),
        ]))
        #expect(initializeParams["capabilities"] == .object([
            "experimental": .object(["x-test": .bool(true)])
        ]))
    }

    @Test func asyncInitializerRejectsMalformedInitializeResult() async throws {
        let transport = FakeXcodeMCPTransport(initializeResult: .object([
            "capabilities": .object([:])
        ]))

        await #expect(throws: XcodeMCPError.invalidResponse(
            "initialize result is missing protocolVersion"
        )) {
            _ = try await XcodeMCP(transport: transport)
        }

        let sent = await transport.sentMessages()
        #expect(sent.compactMap(\.method) == ["initialize"])
        #expect(await transport.closeCount() == 1)
    }

    @Test func asyncInitializerRejectsUnsupportedInitializeProtocolVersion() async throws {
        let transport = FakeXcodeMCPTransport(initializeResult: .object([
            "protocolVersion": .string("2099-01-01"),
            "serverInfo": .object([
                "name": .string("future-server"),
                "version": .string("test"),
            ]),
            "capabilities": .object([:]),
        ]))

        await #expect(throws: XcodeMCPError.invalidResponse(
            "initialize result has unsupported protocolVersion 2099-01-01"
        )) {
            _ = try await XcodeMCP(transport: transport)
        }

        let sent = await transport.sentMessages()
        #expect(sent.compactMap(\.method) == ["initialize"])
        #expect(await transport.closeCount() == 1)
    }

    @Test func asyncInitializerMapsRuntimeTransportErrorsToPublicError() async throws {
        let transport = RuntimeFailingXcodeMCPTransport(
            error: MCPBridgeRuntimeError.transportUnavailable("mcpbridge write queue is full")
        )

        await #expect(throws: XcodeMCPError.transportUnavailable(
            "mcpbridge write queue is full"
        )) {
            _ = try await XcodeMCP(transport: transport)
        }
    }

    @Test func asyncInitializerMapsRawTransportErrorsToPublicError() async throws {
        let transport = RuntimeFailingXcodeMCPTransport(error: RawTransportError())

        await #expect(throws: XcodeMCPError.transportUnavailable("socket closed")) {
            _ = try await XcodeMCP(transport: transport)
        }
    }

    @Test func listToolsDecodesDescriptorAndPreservesDynamicFields() async throws {
        let transport = FakeXcodeMCPTransport()
        let xcode = try await XcodeMCP(transport: transport)
        defer {
            Task { await xcode.close() }
        }

        let tools = try await xcode.listTools()
        let tool = try #require(tools.first)

        #expect(tool.name == "DocumentationSearch")
        #expect(tool.description == "Search Apple developer documentation")
        #expect(tool.inputSchema?.objectValue?["x-dynamic"] == .bool(true))
        #expect(tool.raw.objectValue?["x-provider"] == .string("fake"))
    }

    @Test func callToolSendsShapeAndDecodesFinalResult() async throws {
        let transport = FakeXcodeMCPTransport()
        let xcode = try await XcodeMCP(transport: transport)
        defer {
            Task { await xcode.close() }
        }

        let result = try await xcode.callTool(
            "DocumentationSearch",
            arguments: ["query": .string("SwiftData")]
        )

        #expect(result.isError)
        #expect(result.structuredContent == .object([
            "items": .array([
                .object(["title": .string("SwiftData")])
            ])
        ]))
        #expect(result.raw.objectValue?["x-result"] == .string("dynamic"))
        guard case .text(let text, let raw) = try #require(result.content.first) else {
            Issue.record("expected text content")
            return
        }
        #expect(text == "Result for SwiftData")
        #expect(raw.objectValue?["x-content"] == .string("kept"))

        let calls = await transport.sentMessages().filter { $0.method == "tools/call" }
        let params = try #require(calls.last?.params?.objectValue)
        #expect(params["name"] == .string("DocumentationSearch"))
        #expect(params["arguments"] == .object([
            "query": .string("SwiftData")
        ]))
    }

    @Test func rawRequestSendsDynamicMethodAndReturnsRawResult() async throws {
        let transport = FakeXcodeMCPTransport()
        let xcode = try await XcodeMCP(transport: transport)
        defer {
            Task { await xcode.close() }
        }

        let result = try await xcode.request(
            "workspace/symbols",
            params: [
                "query": "NavigationStack",
                "limit": 3,
            ]
        )

        #expect(result == [
            "method": "workspace/symbols",
            "echo": [
                "query": "NavigationStack",
                "limit": 3,
            ],
        ])

        let request = try #require(
            await transport.sentMessages().last { $0.method == "workspace/symbols" }
        )
        #expect(request.id != nil)
        #expect(request.params == [
            "query": "NavigationStack",
            "limit": 3,
        ])
    }

    @Test func rawNotifySendsDynamicNotificationWithoutRequestID() async throws {
        let transport = FakeXcodeMCPTransport()
        let xcode = try await XcodeMCP(transport: transport)
        defer {
            Task { await xcode.close() }
        }

        try await xcode.notify(
            "notifications/custom",
            params: [
                "enabled": true,
            ]
        )

        let notification = try #require(
            await transport.sentMessages().last { $0.method == "notifications/custom" }
        )
        #expect(notification.id == nil)
        #expect(notification.params == [
            "enabled": true,
        ])
    }

    @Test func callToolAddsProgressTokenAndRoutesMatchingProgress() async throws {
        let transport = FakeXcodeMCPTransport()
        let progressValues = RecordedValues<MCPProgress>()
        let xcode = try await XcodeMCP(transport: transport)
        defer {
            Task { await xcode.close() }
        }

        _ = try await xcode.callTool(
            "DocumentationSearch",
            arguments: ["query": .string("Observation")]
        ) { progress in
            _ = try? await xcode.listTools()
            await progressValues.append(progress)
        }

        let calls = await transport.sentMessages().filter { $0.method == "tools/call" }
        let meta = try #require(calls.last?.params?.objectValue?["_meta"]?.objectValue)
        let progressToken = try #require(meta["progressToken"]?.stringValue)
        #expect(progressToken.isEmpty == false)

        let progress = try await waitWithTimeout("progress callback was not invoked") {
            try await progressValues.nextValue()
        }
        #expect(progress.progressToken == progressToken)
        #expect(progress.progress == 0.5)
        #expect(progress.total == 1)
        #expect(progress.message == "halfway")
    }

    @Test func runtimeSessionRoutesProgressAndAnswersUnsupportedServerRequests() async throws {
        let transport = FakeXcodeMCPTransport()
        let session = try await InitializedMCPClientSession(
            transport: transport,
            configuration: .init(
                clientName: "RuntimeSessionTest",
                clientVersion: "1.0",
                capabilities: [:],
                requestTimeout: .seconds(2)
            )
        )
        defer {
            Task { await session.close() }
        }

        let progressValues = RecordedValues<JSONValue>()
        let result = try await session.request(
            "tools/call",
            params: .object([
                "name": .string("DocumentationSearch"),
                "arguments": .object([
                    "query": .string("Runtime"),
                ]),
            ])
        ) { progress in
            await progressValues.append(progress)
        }

        #expect(MCPJSONValue(result).objectValue?["x-result"] == .string("dynamic"))

        let call = try #require(await transport.sentMessages().last { $0.method == "tools/call" })
        let progressToken = try #require(
            call.params?.objectValue?["_meta"]?.objectValue?["progressToken"]?.stringValue
        )
        let progress = try await waitWithTimeout("runtime progress was not routed") {
            try await progressValues.nextValue()
        }
        #expect(MCPJSONValue(progress).objectValue?["progressToken"] == .string(progressToken))

        await transport.emitServerRequest(method: "sampling/createMessage", id: .integer(99))
        let response = try await waitWithTimeout("runtime unsupported response was not sent") {
            try await transport.nextSentMessage { message in
                message.method == nil && message.error != nil
            }
        }
        #expect(response.id == .integer(99))
        #expect(response.error?.objectValue?["code"] == .integer(-32601))
    }

    @Test func runtimeSessionDoesNotRetainProgressHandlerForInvalidParams() async throws {
        let transport = FakeXcodeMCPTransport()
        let session = try await InitializedMCPClientSession(
            transport: transport,
            configuration: .init(
                clientName: "RuntimeSessionTest",
                clientVersion: "1.0",
                capabilities: [:],
                requestTimeout: .seconds(2)
            )
        )
        defer {
            Task { await session.close() }
        }

        weak var weakProbe: DeinitProbe?
        do {
            var probe: DeinitProbe? = DeinitProbe()
            weakProbe = probe
            let capturedProbe = probe

            await #expect(throws: MCPBridgeRuntimeError.invalidRequest(
                "progress requests require object params"
            )) {
                _ = try await session.request("tools/call", params: .string("invalid")) { _ in
                    _ = capturedProbe
                }
            }
            probe = nil
        }

        #expect(weakProbe == nil)
    }

    @Test func closeIsIdempotentAndRejectsFuturePublicCalls() async throws {
        let transport = FakeXcodeMCPTransport()
        let xcode = try await XcodeMCP(transport: transport)

        await xcode.close()
        await xcode.close()

        #expect(await transport.closeCount() == 1)
        await #expect(throws: XcodeMCPError.closed) {
            _ = try await xcode.listTools()
        }
    }

    @Test func deinitClosesTransportWhenCloseWasNotCalled() async throws {
        let transport = FakeXcodeMCPTransport()
        do {
            let xcode = try await XcodeMCP(transport: transport)
            _ = try await xcode.listTools()
        }

        let closeCount = try await waitWithTimeout("transport was not closed from XcodeMCP deinit") {
            try await transport.nextCloseCount()
        }
        #expect(closeCount == 1)
        #expect(await transport.closeCount() == 1)
    }

    @Test func cancelledRequestCancelsInFlightTransportSend() async throws {
        let transport = HangingSendXcodeMCPTransport()
        let xcode = try await XcodeMCP(
            config: .init(requestTimeout: nil),
            transport: transport
        )

        let listTask = Task {
            try await xcode.listTools()
        }
        _ = try await waitWithTimeout("tools/list send did not start") {
            try await transport.nextStarted(method: "tools/list")
        }

        listTask.cancel()
        do {
            _ = try await listTask.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
        }

        _ = try await waitWithTimeout("tools/list send was not cancelled") {
            try await transport.nextCancelled(method: "tools/list")
        }
        await xcode.close()
    }

    @Test func runtimeSessionRequestTimeoutUsesInjectedClock() async throws {
        let transport = HangingSendXcodeMCPTransport()
        let timeoutClock = ManualSessionTimeoutClock()
        let session = try await InitializedMCPClientSession(
            transport: transport,
            configuration: .init(
                clientName: "RuntimeSessionTest",
                clientVersion: "1.0",
                capabilities: [:],
                requestTimeout: .seconds(2),
                clock: await timeoutClock.client()
            )
        )
        defer {
            Task { await session.close() }
        }

        let sleepBaseline = await timeoutClock.requestedSleepCount()
        let requestTask = Task {
            try await session.request("tools/list")
        }
        defer {
            requestTask.cancel()
        }

        _ = try await transport.nextStarted(method: "tools/list")
        let requestedTimeout = try await timeoutClock.nextRequestedSleep(at: sleepBaseline)
        #expect(requestedTimeout == .seconds(2))

        await timeoutClock.resumeSleep(at: sleepBaseline)
        await #expect(throws: MCPBridgeRuntimeError.requestTimedOut(method: "tools/list")) {
            _ = try await requestTask.value
        }
        _ = try await transport.nextCancelled(method: "tools/list")
    }

    @Test func unsupportedServerRequestGetsInternalErrorResponse() async throws {
        let transport = FakeXcodeMCPTransport()
        let xcode = try await XcodeMCP(transport: transport)
        defer {
            Task { await xcode.close() }
        }

        await transport.emitServerRequest(method: "sampling/createMessage", id: .integer(99))

        let response = try await waitWithTimeout(
            "unsupported server request response was not sent"
        ) {
            try await transport.nextSentMessage { message in
                message.method == nil && message.error != nil
            }
        }
        #expect(response.id == .integer(99))
        #expect(response.error?.objectValue?["code"] == .integer(-32601))

        let tools = try await xcode.listTools()
        #expect(tools.first?.name == "DocumentationSearch")
    }

    @Test func unsupportedServerRequestSendFailureMapsRuntimeErrorForPendingRequests()
        async throws
    {
        let transport = UnsupportedResponseFailingXcodeMCPTransport(
            error: .transportUnavailable("mcpbridge write queue is full")
        )
        let xcode = try await XcodeMCP(transport: transport)
        defer {
            Task { await xcode.close() }
        }

        let listTask = Task {
            try await xcode.listTools()
        }
        defer {
            listTask.cancel()
        }
        _ = try await waitWithTimeout("tools/list send did not start") {
            try await transport.nextSentMessage { message in
                message.method == "tools/list"
            }
        }

        await transport.emitServerRequest(method: "sampling/createMessage", id: .integer(99))

        await #expect(throws: XcodeMCPError.transportUnavailable(
            "mcpbridge write queue is full"
        )) {
            _ = try await waitWithTimeout("pending tools/list did not fail") {
                try await listTask.value
            }
        }
    }

    @Test func domainTypesCodeToProtocolShapeWithoutRawWrapper() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let tool = try decoder.decode(
            MCPTool.self,
            from: Data(
                #"""
                {
                  "name": "DynamicTool",
                  "description": "A dynamic tool",
                  "inputSchema": { "type": "object", "x-extra": true },
                  "x-tool": "kept"
                }
                """#.utf8
            )
        )
        #expect(tool.inputSchema?.objectValue?["x-extra"] == .bool(true))
        let encodedTool = try jsonObject(encoder.encode(tool))
        #expect(encodedTool["raw"] == nil)
        #expect(encodedTool["x-tool"] == .string("kept"))

        let result = try decoder.decode(
            MCPToolResult.self,
            from: Data(
                #"""
                {
                  "content": [{ "type": "text", "text": "done", "x-content": "kept" }],
                  "structuredContent": { "ok": true },
                  "isError": false,
                  "x-result": "kept"
                }
                """#.utf8
            )
        )
        let encodedResult = try jsonObject(encoder.encode(result))
        #expect(encodedResult["raw"] == nil)
        #expect(encodedResult["x-result"] == .string("kept"))

        let synthesizedResult = MCPToolResult(
            content: [
                .text(
                    "manual",
                    raw: .object([
                        "type": .string("text"),
                        "text": .string("manual"),
                    ])
                )
            ],
            structuredContent: .object(["ok": .bool(true)]),
            isError: true
        )
        let synthesizedRaw = try #require(synthesizedResult.raw.objectValue)
        #expect(synthesizedRaw["structuredContent"] == .object(["ok": .bool(true)]))
        #expect(synthesizedRaw["isError"] == .bool(true))

        let progress = try decoder.decode(
            MCPProgress.self,
            from: Data(
                #"""
                {
                  "progressToken": "token",
                  "progress": 0.25,
                  "total": 1,
                  "message": "working",
                  "x-progress": "kept"
                }
                """#.utf8
            )
        )
        let encodedProgress = try jsonObject(encoder.encode(progress))
        #expect(encodedProgress["raw"] == nil)
        #expect(encodedProgress["x-progress"] == .string("kept"))
    }

    @Test func jsonValueConvertsFoundationObjectsAndEncodableValues() throws {
        struct Payload: Encodable {
            var query: String
            var limit: Int
            var flags: [String: Bool]
        }
        struct LargeUnsignedPayload: Encodable {
            var value: UInt64
        }

        let foundationValue = try MCPJSONValue(jsonObject: [
            "query": "SwiftUI",
            "limit": NSNumber(value: 5),
            "tags": ["toolbar", "navigation"],
            "metadata": [
                "isBeta": true,
                "none": NSNull(),
            ],
        ])

        #expect(foundationValue == [
            "query": "SwiftUI",
            "limit": 5,
            "tags": ["toolbar", "navigation"],
            "metadata": [
                "isBeta": true,
                "none": .null,
            ],
        ])

        let object = try #require(foundationValue.jsonObject as? [String: Any])
        #expect(object["query"] as? String == "SwiftUI")
        #expect((object["limit"] as? NSNumber)?.intValue == 5)

        let encoded = try MCPJSONValue(encoding: Payload(
            query: "Observation",
            limit: 2,
            flags: ["exact": true]
        ))

        #expect(encoded.objectValue?["query"] == .string("Observation"))
        #expect(encoded.objectValue?["limit"] == .integer(2))
        #expect(encoded.objectValue?["flags"] == ["exact": true])

        let maxSigned = try MCPJSONValue(jsonObject: NSNumber(value: UInt64(Int64.max)))
        #expect(maxSigned == .integer(Int64.max))

        #expect(throws: XcodeMCPError.invalidRequest(
            "value is not a JSON-compatible Foundation object"
        )) {
            _ = try MCPJSONValue(jsonObject: NSNumber(value: UInt64(Int64.max) + 1))
        }

        #expect(throws: XcodeMCPError.invalidRequest(
            "value is not a JSON-compatible Foundation object"
        )) {
            _ = try MCPJSONValue(encoding: LargeUnsignedPayload(
                value: UInt64(Int64.max) + 1
            ))
        }

        #expect(throws: XcodeMCPError.invalidRequest(
            "value is not a JSON-compatible Foundation object"
        )) {
            _ = try MCPJSONValue(jsonObject: Date())
        }
    }

    @Test func streamableHTTPProxyDiscoveryUsesStandardProxyDiscoveryEnvironment() throws {
        let explicitDiscovery = XcodeMCP.Configuration.Transport.streamableHTTPProxyDiscovery(
            environment: [
                "XCODE_MCP_PROXY_DISCOVERY_FILE": "/tmp/public-contract/endpoint.json",
                "XCODE_MCP_PROXY_CACHE_ROOT": "/tmp/ignored-cache-root",
            ]
        )
        #expect(
            explicitDiscovery == .streamableHTTP(
                discoveryFile: URL(fileURLWithPath: "/tmp/public-contract/endpoint.json")
            )
        )

        let cacheRootDiscovery = XcodeMCP.Configuration.Transport.streamableHTTPProxyDiscovery(
            environment: [
                "XCODE_MCP_PROXY_CACHE_ROOT": "/tmp/public-contract-cache",
            ]
        )
        #expect(
            cacheRootDiscovery == .streamableHTTP(
                discoveryFile: URL(fileURLWithPath: "/tmp/public-contract-cache")
                    .appendingPathComponent("XcodeMCPProxy", isDirectory: true)
                    .appendingPathComponent("endpoint.json")
            )
        )
    }

    @Test func streamableHTTPDiscoveryRejectsStaleRecordBeforeConnecting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("endpoint.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let record = DiscoveryRecord(
            url: "http://127.0.0.1:8765/mcp",
            host: "127.0.0.1",
            port: 8765,
            pid: 12345,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        try Discovery.write(record: record, overrideURL: fileURL)

        let liveness = DiscoveryLivenessProbe(isAlive: false)
        let resolver = StreamableHTTPDiscoveryResolver(
            isProcessAlive: { pid in
                liveness.isProcessAlive(pid)
            }
        )

        await #expect(throws: XcodeMCPError.invalidRequest(
            "Streamable HTTP discovery file is missing, stale, or invalid: \(fileURL.path)"
        )) {
            _ = try await XcodeMCP(
                config: .init(
                    transport: .streamableHTTP(discoveryFile: fileURL),
                    requestTimeout: .seconds(2)
                ),
                streamableHTTPDiscoveryResolver: resolver
            )
        }
        #expect(liveness.checkedProcessIDs() == [record.pid])
    }

    @Test func streamableHTTPSendsSessionHeadersAndDeletesOnClose() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
        let server = FakeStreamableHTTPServer(progressDelivery: .none)
        let session = makeFakeHTTPURLSession(server: server)
        defer {
            session.invalidateAndCancel()
            FakeStreamableHTTPURLProtocolRegistry.shared.reset()
        }

        let transport = StreamableHTTPXcodeMCPTransport(
            endpoint: endpoint,
            urlSession: session,
            requestTimeout: .seconds(2)
        )
        let xcode = try await XcodeMCP(
            config: .init(
                transport: .streamableHTTP(endpoint: endpoint),
                clientName: "HTTPContractClient",
                requestTimeout: .seconds(2)
            ),
            transport: transport
        )

        _ = try await xcode.listTools()
        await xcode.close()

        let requests = await server.recordedRequests()
        let initialize = try #require(requests.firstJSONRPC(method: "initialize"))
        #expect(initialize.httpMethod == "POST")
        #expect(initialize.timeoutInterval == 2)
        #expect(initialize.header("Accept") == "application/json, text/event-stream")
        #expect(initialize.header("Content-Type") == "application/json")
        #expect(initialize.header("MCP-Session-Id") == nil)
        #expect(initialize.header("MCP-Protocol-Version") == nil)

        let initialized = try #require(requests.firstJSONRPC(method: "notifications/initialized"))
        #expect(initialized.header("MCP-Session-Id") == "session-http-1")
        #expect(initialized.header("MCP-Protocol-Version") == "2025-06-18")

        let list = try #require(requests.firstJSONRPC(method: "tools/list"))
        #expect(list.timeoutInterval == 2)
        #expect(list.header("MCP-Session-Id") == "session-http-1")
        #expect(list.header("MCP-Protocol-Version") == "2025-06-18")

        let get = try #require(requests.first(where: { $0.httpMethod == "GET" }))
        #expect(get.timeoutInterval.isInfinite)
        #expect(get.header("Accept") == "text/event-stream")
        #expect(get.header("MCP-Session-Id") == "session-http-1")
        #expect(get.header("MCP-Protocol-Version") == "2025-06-18")

        let delete = try #require(requests.first(where: { $0.httpMethod == "DELETE" }))
        #expect(delete.header("MCP-Session-Id") == "session-http-1")
        #expect(delete.header("MCP-Protocol-Version") == "2025-06-18")
    }

    @Test func streamableHTTPPostSSERoutesProgressAndFinalResult() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
        let server = FakeStreamableHTTPServer(progressDelivery: .postSSE)
        let session = makeFakeHTTPURLSession(server: server)
        defer {
            session.invalidateAndCancel()
            FakeStreamableHTTPURLProtocolRegistry.shared.reset()
        }

        let transport = StreamableHTTPXcodeMCPTransport(
            endpoint: endpoint,
            urlSession: session,
            requestTimeout: .seconds(2)
        )
        let xcode = try await XcodeMCP(
            config: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
            transport: transport
        )

        let progressValues = RecordedValues<MCPProgress>()
        let result = try await xcode.callTool(
            "DocumentationSearch",
            arguments: ["query": .string("POST SSE")]
        ) { progress in
            await progressValues.append(progress)
        }

        let progress = try await waitWithTimeout("POST SSE progress was not delivered") {
            try await progressValues.nextValue()
        }
        #expect(progress.message == "from POST SSE")
        #expect(result.structuredContent?.objectValue?["source"] == .string("post-sse"))
        guard case .text(let text, _) = try #require(result.content.first) else {
            Issue.record("expected text content")
            return
        }
        #expect(text == "Result for POST SSE")

        let call = try #require(await server.recordedRequests().firstJSONRPC(method: "tools/call"))
        #expect(call.header("Accept") == "application/json, text/event-stream")
        #expect(call.header("MCP-Session-Id") == "session-http-1")
        #expect(call.header("MCP-Protocol-Version") == "2025-06-18")
        await xcode.close()
    }

    @Test func streamableHTTPPostSSEResolvesBeforeConnectionEOF() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
        let server = FakeStreamableHTTPServer(
            progressDelivery: .postSSE,
            postSSEFinishesLoading: false
        )
        let session = makeFakeHTTPURLSession(server: server)
        defer {
            session.invalidateAndCancel()
            FakeStreamableHTTPURLProtocolRegistry.shared.reset()
        }

        let transport = StreamableHTTPXcodeMCPTransport(
            endpoint: endpoint,
            urlSession: session,
            requestTimeout: .seconds(2)
        )
        let xcode = try await XcodeMCP(
            config: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
            transport: transport
        )

        let result = try await waitWithTimeout("POST SSE final response was not delivered before EOF") {
            try await xcode.callTool(
                "DocumentationSearch",
                arguments: ["query": .string("Open POST SSE")]
            )
        }
        guard case .text(let text, _) = try #require(result.content.first) else {
            Issue.record("expected text content")
            await xcode.close()
            return
        }
        #expect(text == "Result for Open POST SSE")
        await xcode.close()
    }

    @Test func streamableHTTPInitializeSSEStartsGETBeforePOSTEOF() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
        let server = FakeStreamableHTTPServer(
            progressDelivery: .none,
            initializeUsesSSE: true,
            initializeFinishesLoading: false
        )
        let session = makeFakeHTTPURLSession(server: server)
        defer {
            session.invalidateAndCancel()
            FakeStreamableHTTPURLProtocolRegistry.shared.reset()
        }

        let transport = StreamableHTTPXcodeMCPTransport(
            endpoint: endpoint,
            urlSession: session,
            requestTimeout: .seconds(2)
        )
        let xcode = try await waitWithTimeout("SSE initialize response was not delivered") {
            try await XcodeMCP(
                config: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
                transport: transport
            )
        }

        _ = try await waitWithTimeout("event stream GET was not opened after SSE initialize") {
            try await server.nextRequest { $0.httpMethod == "GET" }
        }
        await xcode.close()
    }

    @Test func streamableHTTPGetSSERoutesProgressWhilePOSTReturnsJSONResult() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
        let server = FakeStreamableHTTPServer(progressDelivery: .getSSE)
        let session = makeFakeHTTPURLSession(server: server)
        defer {
            session.invalidateAndCancel()
            FakeStreamableHTTPURLProtocolRegistry.shared.reset()
        }

        let transport = StreamableHTTPXcodeMCPTransport(
            endpoint: endpoint,
            urlSession: session,
            requestTimeout: .seconds(2)
        )
        let xcode = try await XcodeMCP(
            config: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
            transport: transport
        )

        _ = try await waitWithTimeout("event stream GET was not opened") {
            try await server.nextRequest { $0.httpMethod == "GET" }
        }

        let progressValues = RecordedValues<MCPProgress>()
        let result = try await xcode.callTool(
            "DocumentationSearch",
            arguments: ["query": .string("GET SSE")]
        ) { progress in
            await progressValues.append(progress)
        }

        let progress = try await waitWithTimeout("GET SSE progress was not delivered") {
            try await progressValues.nextValue()
        }
        #expect(progress.message == "from GET SSE")
        #expect(result.structuredContent?.objectValue?["source"] == .string("get-sse"))
        guard case .text(let text, _) = try #require(result.content.first) else {
            Issue.record("expected text content")
            return
        }
        #expect(text == "Result for GET SSE")
        await xcode.close()
    }

    @Test func streamableHTTPAllowsStatelessEndpointWithoutSessionHeader() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
        let server = FakeStreamableHTTPServer(progressDelivery: .none, sessionID: nil)
        let session = makeFakeHTTPURLSession(server: server)
        defer {
            session.invalidateAndCancel()
            FakeStreamableHTTPURLProtocolRegistry.shared.reset()
        }

        let transport = StreamableHTTPXcodeMCPTransport(
            endpoint: endpoint,
            urlSession: session,
            requestTimeout: .seconds(2)
        )
        let xcode = try await XcodeMCP(
            config: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
            transport: transport
        )

        let tools = try await xcode.listTools()
        await xcode.close()

        #expect(tools.first?.name == "DocumentationSearch")
        let requests = await server.recordedRequests()
        let initialized = try #require(requests.firstJSONRPC(method: "notifications/initialized"))
        #expect(initialized.header("MCP-Session-Id") == nil)
        #expect(initialized.header("MCP-Protocol-Version") == "2025-06-18")
        let list = try #require(requests.firstJSONRPC(method: "tools/list"))
        #expect(list.header("MCP-Session-Id") == nil)
        #expect(list.header("MCP-Protocol-Version") == "2025-06-18")
        #expect(requests.contains(where: { $0.httpMethod == "GET" }) == false)
        #expect(requests.contains(where: { $0.httpMethod == "DELETE" }) == false)
    }

    @Test func streamableHTTPReconnectsGETSSEWithoutClosingPOSTs() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
        let server = FakeStreamableHTTPServer(
            progressDelivery: .none,
            eventStreamFinishesImmediately: true
        )
        let session = makeFakeHTTPURLSession(server: server)
        let reconnectSleep = ManualReconnectSleep()
        defer {
            session.invalidateAndCancel()
            FakeStreamableHTTPURLProtocolRegistry.shared.reset()
        }

        let transport = StreamableHTTPXcodeMCPTransport(
            endpoint: endpoint,
            urlSession: session,
            requestTimeout: .seconds(2),
            eventStreamReconnectSleep: { duration in
                try await reconnectSleep.sleep(for: duration)
            }
        )
        let xcode = try await XcodeMCP(
            config: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
            transport: transport
        )
        defer {
            Task { await xcode.close() }
        }

        let firstGET = try await waitWithTimeout("first event stream GET was not opened") {
            try await server.nextRequest { $0.httpMethod == "GET" }
        }
        let reconnectDelay = try await waitWithTimeout("event stream reconnect sleep was not requested") {
            try await reconnectSleep.nextRequestedDuration()
        }
        #expect(reconnectDelay == .milliseconds(100))

        let tools = try await xcode.listTools()
        #expect(tools.first?.name == "DocumentationSearch")
        await reconnectSleep.resumeNext()
        _ = try await waitWithTimeout("event stream GET was not reconnected") {
            try await server.nextRequest(startingAt: firstGET.sequence + 1) { $0.httpMethod == "GET" }
        }
        await xcode.close()
    }

    @Test func streamableHTTPPreservesInitializeServerError() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
        let server = FakeStreamableHTTPServer(
            progressDelivery: .none,
            initializeError: true
        )
        let session = makeFakeHTTPURLSession(server: server)
        defer {
            session.invalidateAndCancel()
            FakeStreamableHTTPURLProtocolRegistry.shared.reset()
        }

        let transport = StreamableHTTPXcodeMCPTransport(
            endpoint: endpoint,
            urlSession: session,
            requestTimeout: .seconds(2)
        )
        await #expect(throws: XcodeMCPError.serverError(
            code: -32000,
            message: "initialize rejected",
            data: nil
        )) {
            _ = try await XcodeMCP(
                config: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
                transport: transport
            )
        }
    }
}

private final class DeinitProbe: @unchecked Sendable {}

private final class DiscoveryLivenessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let isAlive: Bool
    private var processIDs: [Int] = []

    init(isAlive: Bool) {
        self.isAlive = isAlive
    }

    func isProcessAlive(_ processID: Int) -> Bool {
        lock.withLock {
            processIDs.append(processID)
        }
        return isAlive
    }

    func checkedProcessIDs() -> [Int] {
        lock.withLock {
            processIDs
        }
    }
}

private actor HangingSendXcodeMCPTransport: XcodeMCPTransport {
    nonisolated let events: AsyncStream<XcodeMCPTransportEvent>

    private let continuation: AsyncStream<XcodeMCPTransportEvent>.Continuation
    private let startedValues = RecordedValues<String>()
    private let cancelledValues = RecordedValues<String>()
    private let sendBlocker = NeverCompletingSendBlocker()

    init() {
        let stream = AsyncStream<XcodeMCPTransportEvent>.makeStream()
        self.events = stream.stream
        self.continuation = stream.continuation
    }

    func send(_ data: Data) async throws {
        let object = try parse(data)
        let method = object["method"]?.stringValue ?? ""
        if method == "initialize" {
            try yieldMessage([
                "jsonrpc": .string("2.0"),
                "id": object["id"] ?? .integer(1),
                "result": .object([
                    "protocolVersion": .string("2025-06-18"),
                    "serverInfo": .object([
                        "name": .string("hanging-transport"),
                        "version": .string("test"),
                    ]),
                    "capabilities": .object([:]),
                ]),
            ])
            return
        }
        if method == "notifications/initialized" {
            return
        }

        await startedValues.append(method)
        do {
            try await sendBlocker.wait()
        } catch {
            await cancelledValues.append(method)
            throw error
        }
    }

    func close() async {
        await sendBlocker.cancelAll()
        continuation.yield(.closed(nil))
        continuation.finish()
    }

    func nextStarted(method: String) async throws -> String {
        try await startedValues.nextValue { $0 == method }
    }

    func nextCancelled(method: String) async throws -> String {
        try await cancelledValues.nextValue { $0 == method }
    }

    private func yieldMessage(_ object: [String: MCPJSONValue]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: MCPJSONValue.object(object).foundationObject
        )
        continuation.yield(.message(data))
    }

    private func parse(_ data: Data) throws -> [String: MCPJSONValue] {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let value = MCPJSONValue(foundationObject: raw),
              let object = value.objectValue
        else {
            throw XcodeMCPError.invalidRequest("message is not an object")
        }
        return object
    }
}

private actor NeverCompletingSendBlocker {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []
    private var cancelledWaiterIDs: Set<UUID> = []

    func wait() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if cancelledWaiterIDs.remove(waiterID) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    func cancelAll() {
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            cancelledWaiterIDs.insert(id)
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private struct SentMessage: Sendable, Equatable {
    var id: MCPJSONValue?
    var method: String?
    var params: MCPJSONValue?
    var result: MCPJSONValue?
    var error: MCPJSONValue?
}

private actor RuntimeFailingXcodeMCPTransport: XcodeMCPTransport {
    nonisolated let events: AsyncStream<XcodeMCPTransportEvent>

    private let continuation: AsyncStream<XcodeMCPTransportEvent>.Continuation
    private let error: any Error

    init(error: any Error) {
        let stream = AsyncStream<XcodeMCPTransportEvent>.makeStream()
        self.events = stream.stream
        self.continuation = stream.continuation
        self.error = error
    }

    func send(_ data: Data) async throws {
        throw error
    }

    func close() async {
        continuation.yield(.closed(nil))
        continuation.finish()
    }
}

private struct RawTransportError: Error, LocalizedError {
    var errorDescription: String? {
        "socket closed"
    }
}

private actor UnsupportedResponseFailingXcodeMCPTransport: XcodeMCPTransport {
    nonisolated let events: AsyncStream<XcodeMCPTransportEvent>

    private let continuation: AsyncStream<XcodeMCPTransportEvent>.Continuation
    private let sentMessageValues = RecordedValues<SentMessage>()
    private let error: MCPBridgeRuntimeError
    private var closed = false

    init(error: MCPBridgeRuntimeError) {
        let stream = AsyncStream<XcodeMCPTransportEvent>.makeStream()
        self.events = stream.stream
        self.continuation = stream.continuation
        self.error = error
    }

    func send(_ data: Data) async throws {
        guard closed == false else {
            throw MCPBridgeRuntimeError.closed
        }
        let object = try parse(data)
        let sent = SentMessage(
            id: object["id"],
            method: object["method"]?.stringValue,
            params: object["params"],
            result: object["result"],
            error: object["error"]
        )
        await sentMessageValues.append(sent)

        if sent.method == nil, sent.error != nil {
            throw error
        }

        guard sent.method == "initialize",
              let id = sent.id
        else {
            return
        }
        try yieldMessage([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": .object([
                "protocolVersion": .string("2025-06-18"),
                "serverInfo": .object([
                    "name": .string("fake-mcpbridge"),
                    "version": .string("test"),
                ]),
                "capabilities": .object([:]),
            ]),
        ])
    }

    func close() async {
        guard closed == false else {
            return
        }
        closed = true
        continuation.yield(.closed(nil))
        continuation.finish()
    }

    func emitServerRequest(method: String, id: MCPJSONValue) {
        try? yieldMessage([
            "jsonrpc": .string("2.0"),
            "id": id,
            "method": .string(method),
            "params": .object([:]),
        ])
    }

    func nextSentMessage(
        matching predicate: @escaping @Sendable (SentMessage) -> Bool
    ) async throws -> SentMessage {
        try await sentMessageValues.nextValue(matching: predicate)
    }

    private func yieldMessage(_ object: [String: MCPJSONValue]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: MCPJSONValue.object(object).foundationObject
        )
        continuation.yield(.message(data))
    }

    private func parse(_ data: Data) throws -> [String: MCPJSONValue] {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let value = MCPJSONValue(foundationObject: raw),
              let object = value.objectValue
        else {
            throw XcodeMCPError.invalidRequest("message is not an object")
        }
        return object
    }
}

private actor FakeXcodeMCPTransport: XcodeMCPTransport {
    nonisolated let events: AsyncStream<XcodeMCPTransportEvent>

    private let continuation: AsyncStream<XcodeMCPTransportEvent>.Continuation
    private let initializeResult: MCPJSONValue
    private let sentMessageValues = RecordedValues<SentMessage>()
    private let closeValues = RecordedValues<Int>()
    private var messages: [SentMessage] = []
    private var closed = false
    private var closes = 0

    init(initializeResult: MCPJSONValue = .object([
        "protocolVersion": .string("2025-06-18"),
        "serverInfo": .object([
            "name": .string("fake-mcpbridge"),
            "version": .string("test"),
        ]),
        "capabilities": .object([:]),
    ])) {
        let stream = AsyncStream<XcodeMCPTransportEvent>.makeStream()
        self.events = stream.stream
        self.continuation = stream.continuation
        self.initializeResult = initializeResult
    }

    func send(_ data: Data) async throws {
        guard closed == false else {
            throw XcodeMCPError.closed
        }
        let object = try parse(data)
        let sent = SentMessage(
            id: object["id"],
            method: object["method"]?.stringValue,
            params: object["params"],
            result: object["result"],
            error: object["error"]
        )
        messages.append(sent)
        await sentMessageValues.append(sent)

        guard let method = sent.method,
              let id = sent.id
        else {
            return
        }

        if method == "tools/call",
           let progressToken = sent.params?.objectValue?["_meta"]?.objectValue?["progressToken"]
        {
            try yieldMessage([
                "jsonrpc": .string("2.0"),
                "method": .string("notifications/progress"),
                "params": .object([
                    "progressToken": progressToken,
                    "progress": .double(0.5),
                    "total": .integer(1),
                    "message": .string("halfway"),
                ]),
            ])
        }

        try yieldMessage([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": responseResult(method: method, params: sent.params),
        ])
    }

    func close() async {
        guard closed == false else {
            return
        }
        closed = true
        closes += 1
        let closeCount = closes
        await closeValues.append(closeCount)
        continuation.yield(.closed(nil))
        continuation.finish()
    }

    func emitServerRequest(method: String, id: MCPJSONValue) {
        try? yieldMessage([
            "jsonrpc": .string("2.0"),
            "id": id,
            "method": .string(method),
            "params": .object([:]),
        ])
    }

    func sentMessages() -> [SentMessage] {
        messages
    }

    func nextSentMessage(
        matching predicate: @escaping @Sendable (SentMessage) -> Bool
    ) async throws -> SentMessage {
        try await sentMessageValues.nextValue(matching: predicate)
    }

    func closeCount() -> Int {
        closes
    }

    func nextCloseCount() async throws -> Int {
        try await closeValues.nextValue()
    }

    private func yieldMessage(_ object: [String: MCPJSONValue]) throws {
        let responseData = try JSONSerialization.data(
            withJSONObject: MCPJSONValue.object(object).foundationObject
        )
        continuation.yield(.message(responseData))
    }

    private func parse(_ data: Data) throws -> [String: MCPJSONValue] {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let value = MCPJSONValue(foundationObject: raw),
              let object = value.objectValue
        else {
            throw XcodeMCPError.invalidRequest("message is not an object")
        }
        return object
    }

    private func responseResult(method: String, params: MCPJSONValue?) -> MCPJSONValue {
        switch method {
        case "initialize":
            return initializeResult
        case "tools/list":
            return .object([
                "tools": .array([
                    .object([
                        "name": .string("DocumentationSearch"),
                        "description": .string("Search Apple developer documentation"),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "x-dynamic": .bool(true),
                            "properties": .object([
                                "query": .object([
                                    "type": .string("string")
                                ])
                            ]),
                        ]),
                        "x-provider": .string("fake"),
                    ])
                ])
            ])
        case "tools/call":
            let query = params?.objectValue?["arguments"]?.objectValue?["query"]?.stringValue ?? ""
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Result for \(query)"),
                        "x-content": .string("kept"),
                    ])
                ]),
                "structuredContent": .object([
                    "items": .array([
                        .object(["title": .string(query)])
                    ])
                ]),
                "isError": .bool(true),
                "x-result": .string("dynamic"),
            ])
        case "workspace/symbols":
            return .object([
                "method": .string(method),
                "echo": params ?? .null,
            ])
        default:
            return .null
        }
    }
}

private struct RecordedHTTPRequest: Sendable, Equatable {
    var sequence: Int
    var httpMethod: String
    var url: URL
    var headers: [String: String]
    var timeoutInterval: TimeInterval
    var body: MCPJSONValue?

    init(request: URLRequest) {
        self.sequence = 0
        self.httpMethod = request.httpMethod ?? "GET"
        self.url = request.url ?? URL(string: "http://invalid.local/")!
        self.headers = request.allHTTPHeaderFields ?? [:]
        self.timeoutInterval = request.timeoutInterval
        if let bodyData = Self.bodyData(from: request),
           let raw = try? JSONSerialization.jsonObject(with: bodyData),
           let value = MCPJSONValue(foundationObject: raw)
        {
            self.body = value
        } else {
            self.body = nil
        }
    }

    var jsonRPCMethod: String? {
        body?.objectValue?["method"]?.stringValue
    }

    func header(_ name: String) -> String? {
        headers.first { key, _ in
            key.compare(name, options: .caseInsensitive) == .orderedSame
        }?.value
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer {
            stream.close()
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = unsafe buffer.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return 0
                }
                return unsafe stream.read(baseAddress, maxLength: buffer.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else {
                break
            }
        }
        return data
    }
}

private extension Array where Element == RecordedHTTPRequest {
    func firstJSONRPC(method: String) -> RecordedHTTPRequest? {
        first { $0.jsonRPCMethod == method }
    }
}

private actor FakeStreamableHTTPServer {
    enum ProgressDelivery: Sendable {
        case none
        case postSSE
        case getSSE
    }

    private let progressDelivery: ProgressDelivery
    private let sessionID: String?
    private let eventStreamFinishesImmediately: Bool
    private let initializeError: Bool
    private let postSSEFinishesLoading: Bool
    private let initializeUsesSSE: Bool
    private let initializeFinishesLoading: Bool
    private let requestValues = RecordedValues<RecordedHTTPRequest>()
    private var requests: [RecordedHTTPRequest] = []
    private var eventConnection: ActiveHTTPConnection?

    init(
        progressDelivery: ProgressDelivery,
        sessionID: String? = "session-http-1",
        eventStreamFinishesImmediately: Bool = false,
        initializeError: Bool = false,
        postSSEFinishesLoading: Bool = true,
        initializeUsesSSE: Bool = false,
        initializeFinishesLoading: Bool = true
    ) {
        self.progressDelivery = progressDelivery
        self.sessionID = sessionID
        self.eventStreamFinishesImmediately = eventStreamFinishesImmediately
        self.initializeError = initializeError
        self.postSSEFinishesLoading = postSSEFinishesLoading
        self.initializeUsesSSE = initializeUsesSSE
        self.initializeFinishesLoading = initializeFinishesLoading
    }

    func response(
        for request: URLRequest,
        connection: ActiveHTTPConnection
    ) async -> FakeURLProtocolResponse {
        var recorded = RecordedHTTPRequest(request: request)
        recorded.sequence = requests.count
        requests.append(recorded)
        await requestValues.append(recorded)

        switch recorded.httpMethod {
        case "GET":
            eventConnection = connection
            var headers = [
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
            ]
            if let sessionID {
                headers["Mcp-Session-Id"] = sessionID
            }
            return FakeURLProtocolResponse(
                headers: headers,
                chunks: [Data(": ok\n\n".utf8)],
                finishesLoading: eventStreamFinishesImmediately
            )
        case "DELETE":
            eventConnection?.finish()
            eventConnection = nil
            return FakeURLProtocolResponse(
                headers: sessionID.map { ["Mcp-Session-Id": $0] } ?? [:],
                chunks: []
            )
        case "POST":
            return postResponse(for: recorded)
        default:
            return FakeURLProtocolResponse(statusCode: 405, chunks: [Data("method not allowed".utf8)])
        }
    }

    func recordedRequests() -> [RecordedHTTPRequest] {
        requests
    }

    func nextRequest(
        startingAt startIndex: Int = 0,
        matching predicate: @escaping @Sendable (RecordedHTTPRequest) -> Bool
    ) async throws -> RecordedHTTPRequest {
        try await requestValues.nextValue(startingAt: startIndex, matching: predicate)
    }

    private func postResponse(for request: RecordedHTTPRequest) -> FakeURLProtocolResponse {
        guard let method = request.jsonRPCMethod else {
            return FakeURLProtocolResponse(statusCode: 400, chunks: [Data("missing method".utf8)])
        }

        switch method {
        case "initialize":
            if initializeError {
                return FakeURLProtocolResponse(
                    headers: ["Content-Type": "application/json"],
                    chunks: [jsonData([
                        "jsonrpc": "2.0",
                        "id": request.body?.objectValue?["id"] ?? .null,
                        "error": [
                            "code": -32000,
                            "message": "initialize rejected",
                        ],
                    ])]
                )
            }
            let headers = sessionID.map { ["Mcp-Session-Id": $0] } ?? [:]
            let result: MCPJSONValue = [
                "protocolVersion": "2025-06-18",
                "serverInfo": [
                    "name": "fake-http-proxy",
                    "version": "test",
                ],
                "capabilities": [:],
            ]
            if initializeUsesSSE {
                return FakeURLProtocolResponse(
                    headers: ["Content-Type": "text/event-stream"].merging(headers) { _, new in new },
                    chunks: [
                        sseEventData(jsonResponseData(
                            id: request.body?.objectValue?["id"],
                            result: result
                        ))
                    ],
                    finishesLoading: initializeFinishesLoading
                )
            }
            return jsonResponse(
                id: request.body?.objectValue?["id"],
                result: result,
                headers: headers
            )
        case "notifications/initialized":
            return FakeURLProtocolResponse(statusCode: 202, chunks: [])
        case "tools/list":
            return jsonResponse(
                id: request.body?.objectValue?["id"],
                result: [
                    "tools": [
                        [
                            "name": "DocumentationSearch",
                            "description": "Search Apple developer documentation",
                            "inputSchema": [
                                "type": "object",
                            ],
                        ],
                    ],
                ]
            )
        case "tools/call":
            return toolCallResponse(for: request)
        default:
            return jsonResponse(id: request.body?.objectValue?["id"], result: .null)
        }
    }

    private func toolCallResponse(for request: RecordedHTTPRequest) -> FakeURLProtocolResponse {
        let params = request.body?.objectValue?["params"]?.objectValue
        let progressToken = params?["_meta"]?.objectValue?["progressToken"]?.stringValue
        let query = params?["arguments"]?.objectValue?["query"]?.stringValue ?? ""

        switch progressDelivery {
        case .postSSE:
            return FakeURLProtocolResponse(
                headers: ["Content-Type": "text/event-stream"],
                chunks: [
                    sseEventData(progressNotificationData(
                        progressToken: progressToken,
                        message: "from POST SSE"
                    )),
                    sseEventData(toolResultResponseData(
                        id: request.body?.objectValue?["id"],
                        query: query,
                        source: "post-sse"
                    )),
                ],
                finishesLoading: postSSEFinishesLoading
            )
        case .getSSE:
            if let eventConnection {
                eventConnection.send(sseEventData(progressNotificationData(
                    progressToken: progressToken,
                    message: "from GET SSE"
                )))
            }
            return FakeURLProtocolResponse(
                headers: ["Content-Type": "application/json"],
                chunks: [
                    toolResultResponseData(
                        id: request.body?.objectValue?["id"],
                        query: query,
                        source: "get-sse"
                    )
                ]
            )
        case .none:
            return FakeURLProtocolResponse(
                headers: ["Content-Type": "application/json"],
                chunks: [
                    toolResultResponseData(
                        id: request.body?.objectValue?["id"],
                        query: query,
                        source: "json"
                    )
                ]
            )
        }
    }

    private func jsonResponse(
        id: MCPJSONValue?,
        result: MCPJSONValue,
        headers: [String: String] = [:]
    ) -> FakeURLProtocolResponse {
        FakeURLProtocolResponse(
            headers: ["Content-Type": "application/json"].merging(headers) { _, new in new },
            chunks: [jsonResponseData(id: id, result: result)]
        )
    }

    private func progressNotificationData(progressToken: String?, message: String) -> Data {
        jsonData([
            "jsonrpc": "2.0",
            "method": "notifications/progress",
            "params": [
                "progressToken": .string(progressToken ?? ""),
                "progress": 0.5,
                "total": 1,
                "message": .string(message),
            ],
        ])
    }

    private func toolResultResponseData(id: MCPJSONValue?, query: String, source: String) -> Data {
        jsonResponseData(
            id: id,
            result: [
                "content": [
                    [
                        "type": "text",
                        "text": .string("Result for \(query)"),
                    ],
                ],
                "structuredContent": [
                    "source": .string(source),
                ],
                "isError": false,
            ]
        )
    }

    private func jsonResponseData(id: MCPJSONValue?, result: MCPJSONValue) -> Data {
        jsonData([
            "jsonrpc": "2.0",
            "id": id ?? .null,
            "result": result,
        ])
    }

    private func jsonData(_ value: MCPJSONValue) -> Data {
        (try? JSONSerialization.data(withJSONObject: value.foundationObject)) ?? Data()
    }

    private func sseEventData(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            return Data()
        }
        return Data("data: \(text)\n\n".utf8)
    }
}

private struct FakeURLProtocolResponse: Sendable {
    var statusCode: Int = 200
    var headers: [String: String] = [:]
    var chunks: [Data]
    var finishesLoading: Bool = true
}

private final class ActiveHTTPConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var urlProtocol: URLProtocol?
    private var client: URLProtocolClient?

    init(urlProtocol: URLProtocol, client: URLProtocolClient?) {
        self.urlProtocol = urlProtocol
        self.client = client
    }

    func send(_ data: Data) {
        let snapshot = lock.withLock {
            (urlProtocol, client)
        }
        guard let urlProtocol = snapshot.0,
              let client = snapshot.1
        else {
            return
        }
        client.urlProtocol(urlProtocol, didLoad: data)
    }

    func receive(_ response: URLResponse) {
        let snapshot = lock.withLock {
            (urlProtocol, client)
        }
        guard let urlProtocol = snapshot.0,
              let client = snapshot.1
        else {
            return
        }
        client.urlProtocol(urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func fail(_ error: Error) {
        let snapshot = lock.withLock { () -> (URLProtocol?, URLProtocolClient?) in
            let snapshot = (urlProtocol, client)
            urlProtocol = nil
            client = nil
            return snapshot
        }
        guard let urlProtocol = snapshot.0,
              let client = snapshot.1
        else {
            return
        }
        client.urlProtocol(urlProtocol, didFailWithError: error)
    }

    func finish() {
        let snapshot = lock.withLock { () -> (URLProtocol?, URLProtocolClient?) in
            let snapshot = (urlProtocol, client)
            urlProtocol = nil
            client = nil
            return snapshot
        }
        guard let urlProtocol = snapshot.0,
              let client = snapshot.1
        else {
            return
        }
        client.urlProtocolDidFinishLoading(urlProtocol)
    }
}

private final class FakeStreamableHTTPURLProtocolRegistry: @unchecked Sendable {
    static let shared = FakeStreamableHTTPURLProtocolRegistry()

    private let lock = NSLock()
    private var server: FakeStreamableHTTPServer?

    func set(_ server: FakeStreamableHTTPServer) {
        lock.withLock {
            self.server = server
        }
    }

    func currentServer() -> FakeStreamableHTTPServer? {
        lock.withLock {
            server
        }
    }

    func reset() {
        lock.withLock {
            server = nil
        }
    }
}

private final class FakeStreamableHTTPURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let server = FakeStreamableHTTPURLProtocolRegistry.shared.currentServer() else {
            client?.urlProtocol(self, didFailWithError: XcodeMCPError.transportUnavailable("missing fake server"))
            return
        }

        let connection = ActiveHTTPConnection(urlProtocol: self, client: client)
        Task { [request, connection] in
            let response = await server.response(
                for: request,
                connection: connection
            )
            guard let url = request.url,
                  let httpResponse = HTTPURLResponse(
                    url: url,
                    statusCode: response.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: response.headers
                  )
            else {
                connection.fail(XcodeMCPError.invalidResponse("invalid fake response"))
                return
            }

            connection.receive(httpResponse)
            for chunk in response.chunks {
                connection.send(chunk)
            }
            if response.finishesLoading {
                connection.finish()
            }
        }
    }

    override func stopLoading() {}
}

private func makeFakeHTTPURLSession(server: FakeStreamableHTTPServer) -> URLSession {
    FakeStreamableHTTPURLProtocolRegistry.shared.set(server)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeStreamableHTTPURLProtocol.self]
    return URLSession(configuration: config)
}

private actor RecordedValues<Value: Sendable> {
    private struct Waiter {
        let id: UUID
        let startingAt: Int
        let predicate: @Sendable (Value) -> Bool
        let continuation: CheckedContinuation<Value, Error>
    }

    private var values: [Value] = []
    private var waiters: [Waiter] = []

    func append(_ value: Value) {
        let index = values.count
        values.append(value)

        var remaining: [Waiter] = []
        for waiter in waiters {
            if index >= waiter.startingAt, waiter.predicate(value) {
                waiter.continuation.resume(returning: value)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    func nextValue(
        startingAt startIndex: Int = 0,
        matching predicate: @escaping @Sendable (Value) -> Bool = { _ in true }
    ) async throws -> Value {
        let startIndex = max(startIndex, 0)
        if let existing = firstValue(startingAt: startIndex, matching: predicate) {
            return existing
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let existing = firstValue(startingAt: startIndex, matching: predicate) {
                    continuation.resume(returning: existing)
                    return
                }
                waiters.append(
                    Waiter(
                        id: waiterID,
                        startingAt: startIndex,
                        predicate: predicate,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func firstValue(
        startingAt startIndex: Int,
        matching predicate: @Sendable (Value) -> Bool
    ) -> Value? {
        guard startIndex < values.count else {
            return nil
        }
        for index in startIndex..<values.count where predicate(values[index]) {
            return values[index]
        }
        return nil
    }
}

private actor ManualSessionTimeoutClock {
    private struct SleepRequest {
        let id: UUID
        let index: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct DurationWaiter {
        let id: UUID
        let index: Int
        let continuation: CheckedContinuation<Duration, Error>
    }

    private var requestedDurations: [Duration] = []
    private var sleepRequests: [SleepRequest] = []
    private var cancelledSleepRequestIDs: Set<UUID> = []
    private var durationWaiters: [DurationWaiter] = []

    func client() -> ClockClient {
        ClockClient(
            now: { Date(timeIntervalSince1970: 0) },
            uptimeNanoseconds: { 0 },
            sleep: { duration in
                await self.sleep(for: duration)
            },
            sleepForTimeInterval: { _ in }
        )
    }

    func requestedSleepCount() -> Int {
        requestedDurations.count
    }

    func nextRequestedSleep(at index: Int) async throws -> Duration {
        if requestedDurations.indices.contains(index) {
            return requestedDurations[index]
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if requestedDurations.indices.contains(index) {
                    continuation.resume(returning: requestedDurations[index])
                    return
                }
                durationWaiters.append(
                    DurationWaiter(id: waiterID, index: index, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancelDurationWaiter(id: waiterID) }
        }
    }

    func resumeSleep(at index: Int) {
        guard let requestIndex = sleepRequests.firstIndex(where: { $0.index == index }) else {
            return
        }
        let request = sleepRequests.remove(at: requestIndex)
        request.continuation.resume()
    }

    private func sleep(for duration: Duration) async {
        let requestID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledSleepRequestIDs.remove(requestID) != nil {
                    continuation.resume()
                    return
                }
                let index = requestedDurations.count
                requestedDurations.append(duration)
                sleepRequests.append(
                    SleepRequest(
                        id: requestID,
                        index: index,
                        continuation: continuation
                    )
                )
                resumeReadyDurationWaiters()
            }
        } onCancel: {
            Task { await self.cancelSleepRequest(id: requestID) }
        }
    }

    private func cancelSleepRequest(id: UUID) {
        guard let index = sleepRequests.firstIndex(where: { $0.id == id }) else {
            cancelledSleepRequestIDs.insert(id)
            return
        }
        let request = sleepRequests.remove(at: index)
        request.continuation.resume()
    }

    private func cancelDurationWaiter(id: UUID) {
        guard let index = durationWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = durationWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeReadyDurationWaiters() {
        var remaining: [DurationWaiter] = []
        for waiter in durationWaiters {
            if requestedDurations.indices.contains(waiter.index) {
                waiter.continuation.resume(returning: requestedDurations[waiter.index])
            } else {
                remaining.append(waiter)
            }
        }
        durationWaiters = remaining
    }
}

private actor ManualReconnectSleep {
    private struct SleepWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct DurationWaiter {
        let id: UUID
        let index: Int
        let continuation: CheckedContinuation<Duration, Error>
    }

    private var requestedDurations: [Duration] = []
    private var sleepWaiters: [SleepWaiter] = []
    private var durationWaiters: [DurationWaiter] = []

    func sleep(for duration: Duration) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requestedDurations.append(duration)
                sleepWaiters.append(SleepWaiter(id: waiterID, continuation: continuation))
                resumeReadyDurationWaiters()
            }
        } onCancel: {
            Task { await self.cancelSleepWaiter(id: waiterID) }
        }
    }

    func nextRequestedDuration(at index: Int = 0) async throws -> Duration {
        if requestedDurations.indices.contains(index) {
            return requestedDurations[index]
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if requestedDurations.indices.contains(index) {
                    continuation.resume(returning: requestedDurations[index])
                    return
                }
                durationWaiters.append(
                    DurationWaiter(id: waiterID, index: index, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancelDurationWaiter(id: waiterID) }
        }
    }

    func resumeNext() {
        guard sleepWaiters.isEmpty == false else {
            return
        }
        let waiter = sleepWaiters.removeFirst()
        waiter.continuation.resume()
    }

    private func cancelSleepWaiter(id: UUID) {
        guard let index = sleepWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = sleepWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelDurationWaiter(id: UUID) {
        guard let index = durationWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = durationWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeReadyDurationWaiters() {
        var remaining: [DurationWaiter] = []
        for waiter in durationWaiters {
            if requestedDurations.indices.contains(waiter.index) {
                waiter.continuation.resume(returning: requestedDurations[waiter.index])
            } else {
                remaining.append(waiter)
            }
        }
        durationWaiters = remaining
    }
}

private func waitWithTimeout<T: Sendable>(
    _ description: String,
    timeout: Duration = .seconds(2),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let clock = ContinuousClock()

    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await clock.sleep(until: clock.now.advanced(by: timeout))
            throw XcodeMCPError.invalidResponse(description)
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private func jsonObject(_ data: Data) throws -> [String: MCPJSONValue] {
    let raw = try JSONSerialization.jsonObject(with: data)
    guard let value = MCPJSONValue(foundationObject: raw),
          let object = value.objectValue
    else {
        throw XcodeMCPError.invalidResponse("encoded JSON is not an object")
    }
    return object
}
