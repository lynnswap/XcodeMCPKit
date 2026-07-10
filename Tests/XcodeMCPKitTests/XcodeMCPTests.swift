import Foundation
import Testing

@testable import XcodeMCPKit

@Suite(.serialized)
struct XcodeMCPTests {
    @Test func asyncInitializerPerformsMCPHandshake() async throws {
        let transport = FakeXcodeMCPTransport()
        let xcode = try await XcodeMCP(
                configuration: .init(
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

    @Test func callToolAddsProgressTokenAndRoutesMatchingProgress() async throws {
        let transport = FakeXcodeMCPTransport()
        let progressValues = RecordedValues<MCPProgress>()
        let reentrantResults = RecordedValues<Bool>()
        let callFinished = RecordedValues<Void>()
        let handlerGate = ManualGate()
        let xcode = try await XcodeMCP(transport: transport)
        defer {
            Task { await xcode.close() }
        }

        let callTask = Task {
            let result = try await xcode.callTool(
                "DocumentationSearch",
                arguments: ["query": .string("Observation")]
            ) { progress in
                let reentrantTools = try? await xcode.listTools()
                await reentrantResults.append(reentrantTools?.isEmpty == false)
                await handlerGate.wait()
                await progressValues.append(progress)
            }
            await callFinished.append(())
            return result
        }

        #expect(try await reentrantResults.nextValue())
        #expect(await callFinished.count() == 0)
        await handlerGate.open()
        _ = try await callTask.value

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
        await Task.yield()
        #expect(await progressValues.count() == 1)
        #expect(await callFinished.count() == 1)
    }

    @Test func progressCallbackCanCloseClientWithQueuedSuccessorWithoutSelfDeadlock() async throws {
        let transport = FakeXcodeMCPTransport(
            progressBeforeResponseCount: 2,
            emitsProgressBarrierServerRequest: true
        )
        let callbackGate = ManualGate()
        let callbackTerminalGate = ManualGate()
        let callbackStarts = RecordedValues<Void>()
        let callbackCloseReturns = RecordedValues<Void>()
        let callbackCloseCounts = RecordedValues<Int>()
        let closeCompletions = RecordedValues<String>()
        let xcode = try await XcodeMCP(transport: transport)

        let callTask = Task {
            try await xcode.callTool("DocumentationSearch") { _ in
                await callbackStarts.append(())
                await callbackGate.wait()
                await xcode.close()
                await callbackCloseCounts.append(await transport.closeCount())
                await callbackCloseReturns.append(())
                await callbackTerminalGate.wait()
                await closeCompletions.append("callback")
            }
        }

        _ = try await callbackStarts.nextValue()
        _ = try await transport.nextSentMessage { message in
            message.method == nil && message.error != nil
        }
        await callbackGate.open()

        _ = try await callbackCloseReturns.nextValue()
        let secondCloseStarts = RecordedValues<Void>()
        let secondCloseTask = Task {
            await secondCloseStarts.append(())
            await xcode.close()
            await closeCompletions.append("second-close")
        }
        _ = try await secondCloseStarts.nextValue()
        for _ in 0..<100 {
            await Task.yield()
        }
        #expect(await closeCompletions.count() == 0)

        await callbackTerminalGate.open()
        _ = try await callTask.value
        await secondCloseTask.value
        #expect(try await callbackCloseCounts.nextValue() == 1)
        #expect(await callbackStarts.count() == 1)
        #expect(try await closeCompletions.nextValue() == "callback")
        #expect(try await closeCompletions.nextValue(startingAt: 1) == "second-close")
        #expect(await xcode.connectionState().phase == .closed(.requested))
    }

    @Test func runtimeSessionRoutesProgressAndAnswersUnsupportedServerRequests() async throws {
        let transport = FakeXcodeMCPTransport()
        let session = try await InitializedMCPClientSession.start(
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
            ]),
            deadline: Deadline.fromNow(.seconds(2))
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
        let session = try await InitializedMCPClientSession.start(
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
                _ = try await session.request(
                    "tools/call",
                    params: .string("invalid"),
                    deadline: Deadline.fromNow(.seconds(2))
                ) { _ in
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

    @Test func cancelledRequestCancelsInFlightTransportSend() async throws {
        let transport = HangingSendXcodeMCPTransport()
        let xcode = try await XcodeMCP(
                configuration: .init(requestTimeout: nil),
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
        _ = try await waitWithTimeout("caller cancellation notification was not sent") {
            try await transport.nextStarted(method: "notifications/cancelled")
        }
        #expect(try await transport.nextCancellationRequestID() == .integer(1))
        await xcode.close()
    }

    @Test func closeDrainsInFlightSendBeforeReturningAndRejectsPostCloseNetworkWork() async throws {
        let transport = HangingSendXcodeMCPTransport()
        let xcode = try await XcodeMCP(
                configuration: .init(requestTimeout: .seconds(60)),
            transport: transport
        )
        let requestTask = Task { try await xcode.listTools() }

        _ = try await transport.nextStarted(method: "tools/list")
        await xcode.close()

        _ = try await transport.nextCancelled(method: "tools/list")
        await #expect(throws: XcodeMCPError.closed) {
            _ = try await requestTask.value
        }
        let sendsAfterClose = await transport.startedCount()
        await #expect(throws: XcodeMCPError.closed) {
            _ = try await xcode.listTools()
        }
        #expect(await transport.startedCount() == sendsAfterClose)
    }

    @Test func expiredDeadlineDoesNotAdmitPendingOrNetworkWork() async throws {
        let transport = FakeXcodeMCPTransport()
        let session = try await InitializedMCPClientSession.start(
            transport: transport,
            configuration: .init(
                clientName: "RuntimeSessionTest",
                clientVersion: "1.0",
                capabilities: [:],
                requestTimeout: .seconds(2)
            )
        )
        let sendsBeforeRequest = await transport.sentMessages().count

        await #expect(throws: MCPBridgeRuntimeError.requestTimedOut(method: "tools/list")) {
            _ = try await session.request(
                "tools/list",
                deadline: Deadline(uptimeNanoseconds: 0)
            )
        }
        for _ in 0..<100 { await Task.yield() }

        #expect(await transport.sentMessages().count == sendsBeforeRequest)
        await session.close()
        #expect(await transport.closeCount() == 1)
    }

    @Test func runtimeSessionRequestTimeoutUsesInjectedClock() async throws {
        let transport = HangingSendXcodeMCPTransport()
        let timeoutClock = ManualSessionTimeoutClock()
        let session = try await InitializedMCPClientSession.start(
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
            try await session.request(
                "tools/list",
                deadline: Deadline.fromNow(.seconds(2), clock: await timeoutClock.client())
            )
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
        _ = try await transport.nextStarted(method: "notifications/cancelled")
        #expect(try await transport.nextCancellationRequestID() == .integer(1))
    }

    @Test func serverErrorDoesNotSendCancellationNotification() async throws {
        let transport = FakeXcodeMCPTransport(responseErrors: [
            "server/fails": .object([
                "code": .integer(-32001),
                "message": .string("denied"),
            ])
        ])
        let xcode = try await XcodeMCP(transport: transport)

        await #expect(throws: XcodeMCPError.serverError(
            code: -32001,
            message: "denied",
            data: nil
        )) {
            _ = try await xcode.request("server/fails")
        }
        #expect(
            await transport.sentMessages().contains {
                $0.method == "notifications/cancelled"
            } == false
        )
        await xcode.close()
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

        let encoded = try MCPJSONValue(Payload(
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
            _ = try MCPJSONValue(LargeUnsignedPayload(
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
        let explicitDiscovery = XcodeMCPConfiguration.Transport.streamableHTTPProxyDiscovery(
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

        let cacheRootDiscovery = XcodeMCPConfiguration.Transport.streamableHTTPProxyDiscovery(
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

    @Test func streamableHTTPDiscoveryTreatsRecordAsEndpointHint() throws {
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

        let resolver = StreamableHTTPDiscoveryResolver()

        #expect(resolver.endpoint(from: fileURL)?.absoluteString == record.url)
    }

    @Test func missingDiscoveryRecordIsTransportUnavailable() async throws {
        let fileURL = URL(fileURLWithPath: "/tmp/missing-xcode-mcp-endpoint.json")
        let resolver = StreamableHTTPDiscoveryResolver(readRecord: { _ in nil })
        await #expect(throws: XcodeMCPError.transportUnavailable(
            "Streamable HTTP discovery file is missing, stale, or invalid: \(fileURL.path)"
        )) {
            _ = try await XcodeMCP(
                configuration: .init(transport: .streamableHTTP(discoveryFile: fileURL)),
                streamableHTTPDiscoveryResolver: resolver
            )
        }
    }

    @Test func publicErrorsProvideLocalizedNextActions() {
        let cases: [(XcodeMCPError, String, String)] = [
            (
                .closed,
                "The Xcode MCP client is closed.",
                "Create a new XcodeMCP client."
            ),
            (
                .invalidRequest("bad config"),
                "The Xcode MCP request is invalid: bad config",
                "Correct the request or client configuration and try again."
            ),
            (
                .invalidResponse("bad shape"),
                "The MCP server returned an invalid response: bad shape",
                "Verify the MCP server version and response contract."
            ),
            (
                .requestTimedOut(method: "tools/list"),
                "The MCP request timed out: tools/list",
                "Retry with a longer request timeout if the operation is safe to repeat."
            ),
            (
                .serverError(code: -32000, message: "denied", data: nil),
                "The MCP server returned error -32000: denied",
                "Inspect the server error data and correct the request before retrying."
            ),
            (
                .transportUnavailable("proxy stopped"),
                "The Xcode MCP transport is unavailable: proxy stopped",
                "Start Xcode or the configured proxy, then reconnect."
            ),
            (
                .sessionRecoveryFailed("initialize failed"),
                "The Xcode MCP session could not be recovered: initialize failed",
                "Call reconnect() after confirming the MCP endpoint is available."
            ),
        ]

        for (error, description, suggestion) in cases {
            #expect(error.errorDescription == description)
            #expect(error.recoverySuggestion == suggestion)
        }
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
            urlSessionOwnership: .injected,
            requestTimeout: .seconds(2)
        )
        let xcode = try await XcodeMCP(
                configuration: .init(
                transport: .streamableHTTP(endpoint: endpoint),
                clientName: "HTTPContractClient",
                requestTimeout: .seconds(2)
            ),
            transport: transport
        )

        let get = try await waitWithTimeout("event stream GET was not opened") {
            try await server.nextRequest { $0.httpMethod == "GET" }
        }
        _ = try await xcode.listTools()
        await xcode.close()
        let delete = try await waitWithTimeout("session DELETE was not sent") {
            try await server.nextRequest { $0.httpMethod == "DELETE" }
        }

        let requests = await server.recordedRequests()
        let initialize = try #require(requests.firstJSONRPC(method: "initialize"))
        #expect(initialize.httpMethod == "POST")
        #expect(initialize.timeoutInterval > 0 && initialize.timeoutInterval <= 2)
        #expect(initialize.header("Accept") == "application/json, text/event-stream")
        #expect(initialize.header("Content-Type") == "application/json")
        #expect(initialize.header("MCP-Session-Id") == nil)
        #expect(initialize.header("MCP-Protocol-Version") == nil)

        let initialized = try #require(requests.firstJSONRPC(method: "notifications/initialized"))
        #expect(initialized.header("MCP-Session-Id") == "session-http-1")
        #expect(initialized.header("MCP-Protocol-Version") == "2025-06-18")

        let list = try #require(requests.firstJSONRPC(method: "tools/list"))
        #expect(list.timeoutInterval > 0 && list.timeoutInterval <= 2)
        #expect(list.header("MCP-Session-Id") == "session-http-1")
        #expect(list.header("MCP-Protocol-Version") == "2025-06-18")

        #expect(get.timeoutInterval.isInfinite)
        #expect(get.header("Accept") == "text/event-stream")
        #expect(get.header("MCP-Session-Id") == "session-http-1")
        #expect(get.header("MCP-Protocol-Version") == "2025-06-18")

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
            urlSessionOwnership: .injected,
            requestTimeout: .seconds(2)
        )
        let xcode = try await XcodeMCP(
                configuration: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
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
            urlSessionOwnership: .injected,
            requestTimeout: .seconds(2)
        )
        let xcode = try await XcodeMCP(
                configuration: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
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
            urlSessionOwnership: .injected,
            requestTimeout: .seconds(2)
        )
        let xcode = try await waitWithTimeout("SSE initialize response was not delivered") {
            try await XcodeMCP(
                    configuration: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
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
            urlSessionOwnership: .injected,
            requestTimeout: .seconds(2)
        )
        let xcode = try await XcodeMCP(
                configuration: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
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
            urlSessionOwnership: .injected,
            requestTimeout: .seconds(2)
        )
        let xcode = try await XcodeMCP(
                configuration: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
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
            urlSessionOwnership: .injected,
            requestTimeout: .seconds(2),
            eventStreamReconnectSleep: { duration in
                try await reconnectSleep.sleep(for: duration)
            }
        )
        let xcode = try await XcodeMCP(
                configuration: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
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

    @Test func streamableHTTPInjectedClientDeinitCancelsEventStreamTask() async throws {
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

        var client: StreamableHTTPMCPClient? = StreamableHTTPMCPClient(
            endpoint: endpoint,
            urlSession: session,
            urlSessionOwnership: .injected,
            eventStreamReconnectSleep: { duration in
                try await reconnectSleep.sleep(for: duration)
            }
        )
        weak let weakClient = client
        await client?.startEventStream(headers: MCPConnectionHeaders(
            sessionID: "session-http-1",
            protocolVersion: "2025-06-18"
        ))
        _ = try await server.nextRequest { $0.httpMethod == "GET" }
        _ = try await reconnectSleep.nextRequestedDuration()

        client = nil

        #expect(weakClient == nil)
        await reconnectSleep.waitForCancellation()
    }

    @Test func streamableHTTPOwnedClientDeinitInvalidatesOutstandingRequests() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
        let server = FakeStreamableHTTPServer(
            progressDelivery: .none,
            deleteClosesEventStream: false,
            deleteFinishesLoading: false
        )
        let session = makeFakeHTTPURLSession(server: server)
        let cancellationStart = await FakeStreamableHTTPURLProtocolRegistry.shared
            .cancellationCount()
        defer {
            session.invalidateAndCancel()
            FakeStreamableHTTPURLProtocolRegistry.shared.reset()
        }

        var client: StreamableHTTPMCPClient? = StreamableHTTPMCPClient(
            endpoint: endpoint,
            urlSession: session,
            urlSessionOwnership: .owned
        )
        weak let weakClient = client
        await client?.startEventStream(headers: MCPConnectionHeaders(
            sessionID: "session-http-1",
            protocolVersion: "2025-06-18"
        ))
        _ = try await server.nextRequest { $0.httpMethod == "GET" }

        var deleteRequest = URLRequest(url: endpoint)
        deleteRequest.httpMethod = "DELETE"
        let deleteTask = Task {
            _ = try? await session.data(for: deleteRequest)
        }
        _ = try await server.nextRequest { $0.httpMethod == "DELETE" }

        client = nil

        #expect(weakClient == nil)
        _ = try await waitWithTimeout("owned session did not cancel its outstanding GET") {
            try await FakeStreamableHTTPURLProtocolRegistry.shared.nextCancellation(
                startingAt: cancellationStart,
                method: "GET"
            )
        }
        _ = try await waitWithTimeout("owned session did not cancel its outstanding DELETE") {
            try await FakeStreamableHTTPURLProtocolRegistry.shared.nextCancellation(
                startingAt: cancellationStart,
                method: "DELETE"
            )
        }
        await deleteTask.value
    }

    @Test func streamableHTTPConcurrentCloseDeletesAndInvalidatesOnce() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
        let server = FakeStreamableHTTPServer(
            progressDelivery: .none,
            deleteClosesEventStream: false,
            deleteFinishesLoading: false
        )
        let invalidations = URLSessionInvalidationRecorder()
        let session = makeFakeHTTPURLSession(server: server, delegate: invalidations)
        defer {
            session.invalidateAndCancel()
            FakeStreamableHTTPURLProtocolRegistry.shared.reset()
        }

        let client = StreamableHTTPMCPClient(
            endpoint: endpoint,
            urlSession: session,
            urlSessionOwnership: .owned
        )
        let headers = MCPConnectionHeaders(
            sessionID: "session-http-1",
            protocolVersion: "2025-06-18"
        )
        await client.startEventStream(headers: headers)
        _ = try await server.nextRequest { $0.httpMethod == "GET" }

        let closeStarts = RecordedValues<Void>()
        let closeCompletions = RecordedValues<Int>()
        let firstClose = Task {
            await closeStarts.append(())
            await client.close(headers: headers, deleteTimeout: .seconds(2))
            await closeCompletions.append(1)
        }
        let secondClose = Task {
            await closeStarts.append(())
            await client.close(headers: headers, deleteTimeout: .seconds(2))
            await closeCompletions.append(2)
        }

        _ = try await closeStarts.nextValue()
        _ = try await closeStarts.nextValue(startingAt: 1)
        _ = try await server.nextRequest { $0.httpMethod == "DELETE" }
        for _ in 0..<100 { await Task.yield() }

        let requestsBeforeRelease = await server.recordedRequests()
        #expect(requestsBeforeRelease.filter { $0.httpMethod == "DELETE" }.count == 1)
        #expect(await closeCompletions.count() == 0)

        await server.finishDelete()
        try await waitWithTimeout("concurrent close callers did not share terminal completion") {
            await firstClose.value
            await secondClose.value
        }
        _ = try await invalidations.nextInvalidation()
        for _ in 0..<100 { await Task.yield() }

        #expect(await closeCompletions.count() == 2)
        #expect(await invalidations.count() == 1)
        let requests = await server.recordedRequests()
        #expect(requests.filter { $0.httpMethod == "DELETE" }.count == 1)
    }

    @Test func streamableHTTPCloseWaitsForReservedEventTaskInstallationAndTerminal() async throws {
        let state = StreamableHTTPMCPConnectionState()
        #expect(await state.reserveEventStreamStart())

        let lateTaskGate = ManualGate()
        let lateTask = Task {
            await lateTaskGate.wait()
        }
        let closeReturns = RecordedValues<Void>()
        let closeTerminals = RecordedValues<Void>()
        let closeTask = Task {
            let task = await state.close()
            await closeReturns.append(())
            await task?.value
            await closeTerminals.append(())
        }

        while true {
            do {
                try await state.ensureOpen()
                await Task.yield()
            } catch {
                break
            }
        }
        #expect(await closeReturns.count() == 0)

        await state.installEventStreamTask(lateTask)
        _ = try await closeReturns.nextValue()
        #expect(await closeTerminals.count() == 0)

        await lateTaskGate.open()
        await closeTask.value
        #expect(await closeTerminals.count() == 1)
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
            urlSessionOwnership: .injected,
            requestTimeout: .seconds(2)
        )
        await #expect(throws: XcodeMCPError.serverError(
            code: -32000,
            message: "initialize rejected",
            data: nil
        )) {
            _ = try await XcodeMCP(
                    configuration: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
                transport: transport
            )
        }
    }

    @Test func streamableHTTPPreservesInitializeServerErrorFromHTTPStatus() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
        let server = FakeStreamableHTTPServer(
            progressDelivery: .none,
            initializeError: true,
            initializeErrorStatusCode: 503
        )
        let session = makeFakeHTTPURLSession(server: server)
        defer {
            session.invalidateAndCancel()
            FakeStreamableHTTPURLProtocolRegistry.shared.reset()
        }

        let transport = StreamableHTTPXcodeMCPTransport(
            endpoint: endpoint,
            urlSession: session,
            urlSessionOwnership: .injected,
            requestTimeout: .seconds(2)
        )
        await #expect(throws: XcodeMCPError.serverError(
            code: -32000,
            message: "initialize rejected",
            data: nil
        )) {
            _ = try await XcodeMCP(
                    configuration: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
                transport: transport
            )
        }
    }

    @Test func rejectsNonPositivePublicTimeoutsWithoutTransportIO() async throws {
        for timeout in [Duration.zero, .seconds(-1)] {
            let transport = FakeXcodeMCPTransport()
            await #expect(throws: XcodeMCPError.invalidRequest(
                "requestTimeout must be greater than zero; use nil to disable timeouts"
            )) {
                _ = try await XcodeMCP(
                    configuration: .init(requestTimeout: timeout),
                    transport: transport
                )
            }
            #expect(await transport.sentMessages().isEmpty)
        }

        let transport = FakeXcodeMCPTransport()
        let xcode = try await XcodeMCP(transport: transport)
        for timeout in [Duration.zero, .seconds(-1)] {
            await #expect(throws: XcodeMCPError.invalidRequest(
                "request timeout must be greater than zero; use .disabled to disable it"
            )) {
                _ = try await xcode.listTools(options: .init(timeout: .after(timeout)))
            }
        }
        #expect(await transport.sentMessages().contains { $0.method == "tools/list" } == false)
        await xcode.close()
    }

    @Test func clientEnvelopeRejectsBatchInput() throws {
        #expect(throws: MCPBridgeRuntimeError.invalidRequest(
            "JSON-RPC message must be one object"
        )) {
            _ = try MCPClientEnvelope(data: Data(
                #"[{"jsonrpc":"2.0","id":1,"method":"tools/list"}]"#.utf8
            ))
        }
    }

    @Test func forwardedAuthorityRejectsPreInitializeIOAndSecondInitialize() async throws {
        let transport = LifecycleContractTransport(name: "forwarded")
        let factory = LifecycleTransportFactory([transport])
        let authority = MCPClientSessionAuthority.makeForwarded(
            recipe: MCPTransportRecipe { try await factory.make() }
        )

        await #expect(throws: MCPBridgeRuntimeError.invalidRequest(
            "forwarded MCP session requires initialize before other messages"
        )) {
            try await authority.send(try lifecycleOperation(method: "tools/list"))
        }
        #expect(await factory.makeCount() == 0)
        #expect(await transport.sentMessages().isEmpty)

        let initialize = try lifecycleOperation(method: "initialize", id: 9)
        try await authority.send(initialize)
        await #expect(throws: MCPBridgeRuntimeError.invalidRequest(
            "forwarded MCP session accepts initialize only once"
        )) {
            try await authority.send(initialize)
        }
        #expect(await transport.sentMessages().filter { $0.method == "initialize" }.count == 1)
        await authority.close()
        #expect(await transport.closeCount() == 1)
    }

    @Test func forwardedCloseJoinsGatedInitialConnectionAttemptBeforeClosing() async throws {
        let candidate = LifecycleContractTransport(name: "forwarded-close-first-candidate")
        let factory = GatedForwardedTransportFactory(candidate: candidate)
        let authority = MCPClientSessionAuthority.makeForwarded(
            recipe: MCPTransportRecipe { try await factory.make() }
        )
        let initialize = Task {
            try await authority.send(try lifecycleOperation(
                method: "initialize",
                id: 9,
                deadline: nil
            ))
        }
        try await factory.waitUntilStarted()

        let closeCompletions = RecordedValues<Void>()
        let close = Task {
            await authority.close()
            await closeCompletions.append(())
        }
        try await factory.waitUntilCancelled()
        #expect(await closeCompletions.count() == 0)
        #expect(await candidate.sentMessages().isEmpty)

        await factory.release()
        await close.value
        do {
            try await initialize.value
            Issue.record("expected cancelled forwarded initialize")
        } catch is CancellationError {
        }

        #expect(await closeCompletions.count() == 1)
        #expect(await candidate.closeCount() == 1)
        #expect(await candidate.sentMessages().isEmpty)
        #expect(await candidate.eventStreamStartCount() == 0)
        #expect(await authority.connectionState().phase == .closed(.requested))
    }

    @Test func cancelledForwardedInitialAttemptClosesCandidateAndAllowsRetry() async throws {
        let cancelledCandidate = LifecycleContractTransport(
            name: "forwarded-cancelled-candidate"
        )
        let retryCandidate = LifecycleContractTransport(name: "forwarded-retry-candidate")
        let factory = GatedForwardedTransportFactory(
            gatedCandidate: cancelledCandidate,
            retryCandidate: retryCandidate
        )
        let authority = MCPClientSessionAuthority.makeForwarded(
            recipe: MCPTransportRecipe { try await factory.make() }
        )
        let firstInitialize = Task {
            try await authority.send(try lifecycleOperation(
                method: "initialize",
                id: 9,
                deadline: nil
            ))
        }
        try await factory.waitUntilStarted()

        firstInitialize.cancel()
        try await factory.waitUntilCancelled()
        do {
            try await waitWithTimeout(
                "cancelled forwarded initialize did not leave its active attempt"
            ) {
                try await firstInitialize.value
            }
            Issue.record("expected cancelled forwarded initialize")
        } catch is CancellationError {
        }
        #expect(await cancelledCandidate.closeCount() == 0)
        #expect(await cancelledCandidate.sentMessages().isEmpty)
        #expect(await cancelledCandidate.eventStreamStartCount() == 0)

        try await authority.send(try lifecycleOperation(
            method: "initialize",
            id: 10,
            deadline: nil
        ))
        #expect(
            await retryCandidate.sentMessages().filter { $0.method == "initialize" }.count == 1
        )

        let closeCompletions = RecordedValues<Void>()
        let close = Task {
            await authority.close()
            await closeCompletions.append(())
        }
        _ = try await retryCandidate.nextCloseCount()
        #expect(await closeCompletions.count() == 0)

        await factory.release()
        await close.value
        #expect(await closeCompletions.count() == 1)
        #expect(await cancelledCandidate.closeCount() == 1)
        #expect(await cancelledCandidate.sentMessages().isEmpty)
        #expect(await cancelledCandidate.eventStreamStartCount() == 0)
        #expect(await retryCandidate.closeCount() == 1)
    }

    @Test func connectionStateSubscribersAreIndependentAndCloseIsTerminal() async throws {
        let transport = LifecycleContractTransport(name: "states")
        let xcode = try await XcodeMCP(transport: transport)
        var first = await xcode.connectionStates().makeAsyncIterator()
        var second = await xcode.connectionStates().makeAsyncIterator()

        let firstInitial = try #require(await first.next())
        let secondInitial = try #require(await second.next())
        #expect(firstInitial.phase == .ready)
        #expect(secondInitial == firstInitial)

        await xcode.close()
        let firstClosed = try #require(await first.next())
        let secondClosed = try #require(await second.next())
        #expect(firstClosed.phase == .closed(.requested))
        #expect(secondClosed == firstClosed)
        #expect(await first.next() == nil)
        #expect(await second.next() == nil)
        #expect(await xcode.connectionState() == firstClosed)

        var postClose = await xcode.connectionStates().makeAsyncIterator()
        #expect(await postClose.next() == firstClosed)
        #expect(await postClose.next() == nil)
    }

    @Test func recoveryIsSingleFlightForConcurrentExpiredOperations() async throws {
        let barrier = RequestBarrier(target: 2)
        let expired = LifecycleContractTransport(
            name: "expired",
            expirations: ["alpha": 1, "beta": 1],
            expirationBarrier: barrier
        )
        let replacement = LifecycleContractTransport(name: "replacement")
        let factory = LifecycleTransportFactory([expired, replacement])
        let authority = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { try await factory.make() },
            initialize: lifecycleInitializeContext,
            defaultTimeout: .seconds(2)
        )

        async let alpha: Void = authority.send(try lifecycleOperation(method: "alpha"))
        async let beta: Void = authority.send(try lifecycleOperation(method: "beta"))
        try await alpha
        try await beta

        #expect(await factory.makeCount() == 2)
        let replayed = await replacement.sentMessages().compactMap(\.method)
        #expect(replayed.filter { $0 == "initialize" }.count == 1)
        #expect(Set(replayed.filter { $0 == "alpha" || $0 == "beta" }) == Set(["alpha", "beta"]))
        await authority.close()
    }

    @Test func disabledRequestDeadlineOutlivesConfiguredRecoveryTimeout() async throws {
        let recoveryClock = ManualSessionTimeoutClock()
        let clock = await recoveryClock.client()
        let expired = LifecycleContractTransport(
            name: "expired-disabled-request",
            expirations: ["tools/list": 1]
        )
        let replacement = LifecycleContractTransport(name: "replacement-disabled-request")
        let factory = BlockingRecoveryTransportFactory(first: expired, blocked: replacement)
        let authority = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { try await factory.make() },
            initialize: lifecycleInitializeContext,
            defaultTimeout: .seconds(2),
            clock: clock
        )

        let request = Task {
            try await authority.send(try lifecycleOperation(
                method: "tools/list",
                deadline: nil
            ))
        }
        try await factory.waitUntilBlockedMakeStarts()
        await recoveryClock.advanceUptime(by: .seconds(3))
        await factory.releaseBlockedMake()
        try await request.value

        #expect(await replacement.sentMessages().contains { $0.method == "tools/list" })
        await authority.close()
    }

    @Test func longerOperationDeadlineOutlivesConfiguredRecoveryTimeout() async throws {
        let recoveryClock = ManualSessionTimeoutClock()
        let clock = await recoveryClock.client()
        let expired = LifecycleContractTransport(
            name: "expired-long-request",
            expirations: ["tools/list": 1]
        )
        let replacement = LifecycleContractTransport(name: "replacement-long-request")
        let factory = BlockingRecoveryTransportFactory(first: expired, blocked: replacement)
        let authority = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { try await factory.make() },
            initialize: lifecycleInitializeContext,
            defaultTimeout: .seconds(2),
            clock: clock
        )

        let request = Task {
            try await authority.send(try lifecycleOperation(
                method: "tools/list",
                deadline: Deadline.fromNow(.seconds(10), clock: clock)
            ))
        }
        try await factory.waitUntilBlockedMakeStarts()
        await recoveryClock.advanceUptime(by: .seconds(3))
        await factory.releaseBlockedMake()
        try await request.value

        #expect(await replacement.sentMessages().contains { $0.method == "tools/list" })
        await authority.close()
    }

    @Test func disabledReconnectOutlivesConfiguredRecoveryTimeout() async throws {
        let recoveryClock = ManualSessionTimeoutClock()
        let clock = await recoveryClock.client()
        let current = LifecycleContractTransport(name: "current-disabled-reconnect")
        let replacement = LifecycleContractTransport(name: "replacement-disabled-reconnect")
        let factory = BlockingRecoveryTransportFactory(first: current, blocked: replacement)
        let authority = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { try await factory.make() },
            initialize: lifecycleInitializeContext,
            defaultTimeout: .seconds(2),
            clock: clock
        )

        let reconnect = Task {
            try await authority.reconnect(deadline: nil)
        }
        try await factory.waitUntilBlockedMakeStarts()
        await recoveryClock.advanceUptime(by: .seconds(3))
        await factory.releaseBlockedMake()
        try await reconnect.value

        #expect(await authority.connectionState().phase == .ready)
        await authority.close()
    }

    @Test func lastRecoveryWaiterDeadlineClosesReplacementAfterSendCancellation() async throws {
        let recoveryClock = ManualSessionTimeoutClock()
        let clock = await recoveryClock.client()
        let expired = LifecycleContractTransport(
            name: "expired-last-waiter",
            expirations: ["tools/list": 1]
        )
        let replacement = HangingSendXcodeMCPTransport(stallsInitialize: true)
        let factory = MixedRecoveryTransportFactory(first: expired, replacement: replacement)
        let authority = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { try await factory.make() },
            initialize: lifecycleInitializeContext,
            defaultTimeout: .seconds(2),
            clock: clock
        )
        let sleepBaseline = await recoveryClock.requestedSleepCount()
        let request = Task {
            try await authority.send(try lifecycleOperation(
                method: "tools/list",
                deadline: Deadline.fromNow(.seconds(2), clock: clock)
            ))
        }

        _ = try await replacement.nextStarted(method: "initialize")
        _ = try await recoveryClock.nextRequestedSleep(at: sleepBaseline)
        await recoveryClock.advanceUptime(by: .seconds(3))
        await recoveryClock.resumeSleep(at: sleepBaseline)
        await #expect(throws: MCPBridgeRuntimeError.requestTimedOut(
            method: "session recovery"
        )) {
            try await request.value
        }

        _ = try await replacement.nextCancelled(method: "initialize")
        _ = try await replacement.nextCloseCount()
        await authority.close()
        #expect(await replacement.closeCount() == 1)
    }

    @Test func lastRecoveryOwnerLeavingDuringInitializedSendPreventsSSEAndReady() async throws {
        let recoveryClock = ManualSessionTimeoutClock()
        let clock = await recoveryClock.client()
        let expired = LifecycleContractTransport(
            name: "expired-gated-initialized",
            expirations: ["tools/list": 1]
        )
        let replacement = HangingSendXcodeMCPTransport(
            stallsInitializedUntilReleased: true
        )
        let factory = MixedRecoveryTransportFactory(first: expired, replacement: replacement)
        let authority = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { try await factory.make() },
            initialize: lifecycleInitializeContext,
            defaultTimeout: .seconds(2),
            clock: clock
        )
        let sleepBaseline = await recoveryClock.requestedSleepCount()
        let operation = try lifecycleOperation(
            method: "tools/list",
            deadline: Deadline.fromNow(.seconds(2), clock: clock)
        )
        let request = Task { try await authority.send(operation) }

        _ = try await replacement.nextStarted(method: "notifications/initialized")
        _ = try await recoveryClock.nextRequestedSleep(at: sleepBaseline)
        await recoveryClock.advanceUptime(by: .seconds(3))
        await recoveryClock.resumeSleep(at: sleepBaseline)
        await #expect(throws: MCPBridgeRuntimeError.requestTimedOut(
            method: "session recovery"
        )) {
            try await request.value
        }

        _ = try await replacement.nextCloseCount()
        guard case .unavailable(.sessionRecoveryFailed) = await authority.connectionState().phase
        else {
            Issue.record("expected abandoned recovery to become unavailable")
            return
        }
        let closeCompletions = RecordedValues<Void>()
        let close = Task {
            await authority.close()
            await closeCompletions.append(())
        }
        try await waitWithTimeout("authority close did not reach its retired recovery join") {
            try await waitUntilAuthorityCloseStarts(
                authority,
                expiredOperation: operation
            )
        }
        #expect(await closeCompletions.count() == 0)
        await replacement.releaseInitializedSend()
        await close.value

        #expect(await closeCompletions.count() == 1)
        #expect(await replacement.eventStreamStartCount() == 0)
        #expect(await replacement.closeCount() == 1)
    }

    @Test func abandonedRecoveryDoesNotSendFreshInitializeAfterFactoryReturns() async throws {
        let recoveryClock = ManualSessionTimeoutClock()
        let clock = await recoveryClock.client()
        let expired = LifecycleContractTransport(
            name: "expired-before-fresh-initialize",
            expirations: ["tools/list": 1]
        )
        let replacement = LifecycleContractTransport(name: "unused-after-abandonment")
        let factory = BlockingRecoveryTransportFactory(first: expired, blocked: replacement)
        let authority = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { try await factory.make() },
            initialize: lifecycleInitializeContext,
            defaultTimeout: .seconds(2),
            clock: clock
        )
        let sleepBaseline = await recoveryClock.requestedSleepCount()
        let request = Task {
            try await authority.send(try lifecycleOperation(
                method: "tools/list",
                deadline: Deadline.fromNow(.seconds(2), clock: clock)
            ))
        }

        try await factory.waitUntilBlockedMakeStarts()
        _ = try await recoveryClock.nextRequestedSleep(at: sleepBaseline)
        await recoveryClock.advanceUptime(by: .seconds(3))
        await recoveryClock.resumeSleep(at: sleepBaseline)
        await #expect(throws: MCPBridgeRuntimeError.requestTimedOut(
            method: "session recovery"
        )) {
            try await request.value
        }

        await factory.releaseBlockedMake()
        _ = try await replacement.nextCloseCount()
        #expect(await replacement.sentMessages().isEmpty)
        await authority.close()
        #expect(await replacement.closeCount() == 1)
    }

    @Test func recoverySSEOperationMakesCloseWaitForItsTerminal() async throws {
        let recoveryClock = ManualSessionTimeoutClock()
        let clock = await recoveryClock.client()
        let expired = LifecycleContractTransport(
            name: "expired-gated-sse",
            expirations: ["tools/list": 1]
        )
        let replacement = HangingSendXcodeMCPTransport(
            stallsEventStreamUntilReleased: true
        )
        let factory = MixedRecoveryTransportFactory(first: expired, replacement: replacement)
        let authority = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { try await factory.make() },
            initialize: lifecycleInitializeContext,
            defaultTimeout: .seconds(2),
            clock: clock
        )
        let sleepBaseline = await recoveryClock.requestedSleepCount()
        let operation = try lifecycleOperation(
            method: "tools/list",
            deadline: Deadline.fromNow(.seconds(2), clock: clock)
        )
        let request = Task { try await authority.send(operation) }

        _ = try await replacement.nextEventStreamStart()
        _ = try await recoveryClock.nextRequestedSleep(at: sleepBaseline)
        await recoveryClock.advanceUptime(by: .seconds(3))
        await recoveryClock.resumeSleep(at: sleepBaseline)
        await #expect(throws: MCPBridgeRuntimeError.requestTimedOut(
            method: "session recovery"
        )) {
            try await request.value
        }
        _ = try await replacement.nextCloseCount()
        guard case .unavailable(.sessionRecoveryFailed) = await authority.connectionState().phase
        else {
            Issue.record("expected abandoned SSE recovery to become unavailable")
            return
        }

        let reconnect = Task {
            try await authority.reconnect(
                deadline: Deadline.fromNow(.seconds(1), clock: clock)
            )
        }
        _ = try await recoveryClock.nextRequestedSleep(at: sleepBaseline + 1)
        await recoveryClock.advanceUptime(by: .seconds(2))
        await recoveryClock.resumeSleep(at: sleepBaseline + 1)
        await #expect(throws: MCPBridgeRuntimeError.requestTimedOut(
            method: "session recovery"
        )) {
            try await reconnect.value
        }

        let closeCompletions = RecordedValues<Void>()
        let close = Task {
            await authority.close()
            await closeCompletions.append(())
        }
        try await waitWithTimeout("authority close did not reach its retired recovery join") {
            try await waitUntilAuthorityCloseStarts(
                authority,
                expiredOperation: operation
            )
        }
        #expect(await closeCompletions.count() == 0)
        await replacement.releaseEventStreamStart()
        await close.value

        #expect(await closeCompletions.count() == 1)
        #expect(await replacement.eventStreamStartCount() == 1)
        #expect(await replacement.closeCount() == 1)
    }

    @Test func cancelledDisabledReconnectLeavesRetiredCleanupOwnedByClose() async throws {
        let recoveryClock = ManualSessionTimeoutClock()
        let clock = await recoveryClock.client()
        let expired = LifecycleContractTransport(
            name: "expired-cancelled-disabled-reconnect",
            expirations: ["tools/list": 1]
        )
        let replacement = HangingSendXcodeMCPTransport(
            stallsEventStreamUntilReleased: true
        )
        let factory = MixedRecoveryTransportFactory(first: expired, replacement: replacement)
        let authority = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { try await factory.make() },
            initialize: lifecycleInitializeContext,
            defaultTimeout: .seconds(2),
            clock: clock
        )
        let sleepBaseline = await recoveryClock.requestedSleepCount()
        let operation = try lifecycleOperation(
            method: "tools/list",
            deadline: Deadline.fromNow(.seconds(2), clock: clock)
        )
        let request = Task { try await authority.send(operation) }

        _ = try await replacement.nextEventStreamStart()
        _ = try await recoveryClock.nextRequestedSleep(at: sleepBaseline)
        await recoveryClock.advanceUptime(by: .seconds(3))
        await recoveryClock.resumeSleep(at: sleepBaseline)
        await #expect(throws: MCPBridgeRuntimeError.requestTimedOut(
            method: "session recovery"
        )) {
            try await request.value
        }
        _ = try await replacement.nextCloseCount()

        let reconnect = Task { try await authority.reconnect(deadline: nil) }
        reconnect.cancel()
        do {
            try await waitWithTimeout("cancelled reconnect did not leave cleanup wait") {
                try await reconnect.value
            }
            Issue.record("expected cancelled reconnect")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        let closeCompletions = RecordedValues<Void>()
        let close = Task {
            await authority.close()
            await closeCompletions.append(())
        }
        try await waitWithTimeout("authority close did not join retired cleanup") {
            try await waitUntilAuthorityCloseStarts(
                authority,
                expiredOperation: operation
            )
        }
        #expect(await closeCompletions.count() == 0)

        await replacement.releaseEventStreamStart()
        await close.value
        _ = try? await reconnect.value
        #expect(await closeCompletions.count() == 1)
        #expect(await replacement.eventStreamStartCount() == 1)
        #expect(await replacement.closeCount() == 1)
    }

    @Test func retiredNoncooperativeWorkerDoesNotBlockFreshReconnectButCloseJoinsIt()
        async throws
    {
        let recoveryClock = ManualSessionTimeoutClock()
        let clock = await recoveryClock.client()
        let expired = LifecycleContractTransport(
            name: "retired-worker-current",
            expirations: ["tools/list": 1]
        )
        let abandonedCandidate = LifecycleContractTransport(name: "retired-worker-candidate")
        let fresh = LifecycleContractTransport(name: "retired-worker-fresh")
        let factory = RetiringRecoveryTransportFactory(
            first: expired,
            abandonedCandidate: abandonedCandidate,
            fresh: fresh
        )
        let authority = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { try await factory.make() },
            initialize: lifecycleInitializeContext,
            defaultTimeout: .seconds(2),
            clock: clock
        )
        let sleepBaseline = await recoveryClock.requestedSleepCount()
        let request = Task {
            try await authority.send(try lifecycleOperation(
                method: "tools/list",
                deadline: Deadline.fromNow(.seconds(2), clock: clock)
            ))
        }

        try await factory.waitUntilAbandonedWorkerStarts()
        _ = try await recoveryClock.nextRequestedSleep(at: sleepBaseline)
        await recoveryClock.advanceUptime(by: .seconds(3))
        await recoveryClock.resumeSleep(at: sleepBaseline)
        await #expect(throws: MCPBridgeRuntimeError.requestTimedOut(
            method: "session recovery"
        )) {
            try await request.value
        }

        try await authority.reconnect(
            deadline: Deadline.fromNow(.seconds(1), clock: clock)
        )
        #expect(await authority.connectionState().phase == .ready)
        #expect(await factory.makeCount() == 3)
        #expect(await abandonedCandidate.sentMessages().isEmpty)

        let closeCompletions = RecordedValues<Void>()
        let close = Task {
            await authority.close()
            await closeCompletions.append(())
        }
        _ = try await fresh.nextCloseCount()
        #expect(await closeCompletions.count() == 0)

        await factory.releaseAbandonedWorker()
        await close.value
        #expect(await closeCompletions.count() == 1)
        #expect(await abandonedCandidate.sentMessages().isEmpty)
        #expect(await abandonedCandidate.closeCount() == 1)
    }

    @Test func backgroundRecoveryTimeoutClosesReplacementAndAllowsFreshReconnect() async throws {
        let recoveryClock = ManualSessionTimeoutClock()
        let clock = await recoveryClock.client()
        let current = LifecycleContractTransport(name: "background-expired")
        let stalled = HangingSendXcodeMCPTransport(stallsInitialize: true)
        let fresh = LifecycleContractTransport(name: "fresh-after-background-timeout")
        let factory = MixedRecoveryTransportFactory([current, stalled, fresh])
        let authority = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { try await factory.make() },
            initialize: lifecycleInitializeContext,
            defaultTimeout: .seconds(2),
            clock: clock
        )
        let sleepBaseline = await recoveryClock.requestedSleepCount()

        await current.emitSessionExpired()
        _ = try await stalled.nextStarted(method: "initialize")
        #expect(try await recoveryClock.nextRequestedSleep(at: sleepBaseline) == .seconds(2))
        #expect(await authority.connectionState().phase == .recovering)

        await recoveryClock.advanceUptime(by: .seconds(3))
        await recoveryClock.resumeSleep(at: sleepBaseline)
        _ = try await stalled.nextCancelled(method: "initialize")
        _ = try await stalled.nextCloseCount()
        guard case .unavailable(.sessionRecoveryFailed) = await authority.connectionState().phase
        else {
            Issue.record("expected bounded background recovery to become unavailable")
            return
        }

        try await authority.reconnect(deadline: nil)
        #expect(await authority.connectionState().phase == .ready)
        #expect(await factory.makeCount() == 3)
        await authority.close()
        #expect(await stalled.closeCount() == 1)
    }

    @Test func longExplicitWaiterOutlivesJoinedBackgroundRecoveryLease() async throws {
        let recoveryClock = ManualSessionTimeoutClock()
        let clock = await recoveryClock.client()
        let current = LifecycleContractTransport(name: "background-with-explicit-waiter")
        let replacement = LifecycleContractTransport(name: "long-explicit-replacement")
        let factory = BlockingRecoveryTransportFactory(first: current, blocked: replacement)
        let authority = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { try await factory.make() },
            initialize: lifecycleInitializeContext,
            defaultTimeout: .seconds(2),
            clock: clock
        )

        let sleepBaseline = await recoveryClock.requestedSleepCount()
        await current.emitSessionExpired()
        try await factory.waitUntilBlockedMakeStarts()
        #expect(try await recoveryClock.nextRequestedSleep(at: sleepBaseline) == .seconds(2))
        let reconnect = Task {
            try await authority.reconnect(
                deadline: Deadline.fromNow(.seconds(10), clock: clock)
            )
        }
        #expect(try await recoveryClock.nextRequestedSleep(at: sleepBaseline + 1) == .seconds(10))

        await recoveryClock.advanceUptime(by: .seconds(3))
        await recoveryClock.resumeSleep(at: sleepBaseline)
        for _ in 0..<100 { await Task.yield() }
        #expect(await authority.connectionState().phase == .recovering)
        await factory.releaseBlockedMake()
        try await reconnect.value

        #expect(await authority.connectionState().phase == .ready)
        #expect(await replacement.closeCount() == 0)
        await authority.close()
    }

    @Test func disabledDefaultUsesBoundedBackgroundLeaseAndCloseAwaitsItsTerminal() async throws {
        let recoveryClock = ManualSessionTimeoutClock()
        let clock = await recoveryClock.client()
        let current = LifecycleContractTransport(name: "disabled-background-cap")
        let stalled = HangingSendXcodeMCPTransport(stallsInitialize: true)
        let factory = MixedRecoveryTransportFactory(first: current, replacement: stalled)
        let authority = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { try await factory.make() },
            initialize: lifecycleInitializeContext,
            defaultTimeout: nil,
            clock: clock
        )
        let sleepBaseline = await recoveryClock.requestedSleepCount()

        await current.emitSessionExpired()
        _ = try await stalled.nextStarted(method: "initialize")
        #expect(try await recoveryClock.nextRequestedSleep(at: sleepBaseline) == .seconds(30))

        await authority.close()
        #expect(await authority.connectionState().phase == .closed(.requested))
        #expect(await stalled.closeCount() == 1)
    }

    @Test func secondSessionExpiryIsTypedAndRequiresExplicitReconnect() async throws {
        let first = LifecycleContractTransport(
            name: "first",
            expirations: ["tools/list": 1]
        )
        let second = LifecycleContractTransport(
            name: "second",
            expirations: ["tools/list": 1]
        )
        let third = LifecycleContractTransport(name: "third")
        let factory = LifecycleTransportFactory([first, second, third])
        let xcode = try await XcodeMCP(
            configuration: .init(requestTimeout: .seconds(2)),
            recipe: MCPTransportRecipe { try await factory.make() }
        )

        do {
            _ = try await xcode.listTools()
            Issue.record("expected typed recovery failure")
        } catch let error as XcodeMCPError {
            guard case .sessionRecoveryFailed = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }
        let unavailable = await xcode.connectionState()
        guard case .unavailable(.sessionRecoveryFailed) = unavailable.phase else {
            Issue.record("expected unavailable recovery state")
            return
        }
        #expect(await factory.makeCount() == 2)

        await #expect(throws: XcodeMCPError.sessionRecoveryFailed(
            "replacement session session-second expired before replay completed"
        )) {
            _ = try await xcode.listTools()
        }
        #expect(await factory.makeCount() == 2)

        try await xcode.reconnect()
        #expect(await factory.makeCount() == 3)
        #expect(await xcode.connectionState().phase == .ready)
        #expect(try await xcode.listTools().map(\.name) == ["Tool-third"])
        await xcode.close()
    }

    @Test func listToolsLoadsEveryPageAndFailsOnCursorCycle() async throws {
        let paged = LifecycleContractTransport(name: "paged") { cursor, _ in
            switch cursor {
            case nil:
                lifecycleToolsPage(names: ["First"], nextCursor: "page-2")
            case "page-2":
                lifecycleToolsPage(names: ["Second"], nextCursor: nil)
            default:
                lifecycleToolsPage(names: [], nextCursor: nil)
            }
        }
        let pagedClient = try await XcodeMCP(transport: paged)
        #expect(try await pagedClient.listTools().map(\.name) == ["First", "Second"])
        await pagedClient.close()

        let cycling = LifecycleContractTransport(name: "cycling") { cursor, _ in
            lifecycleToolsPage(
                names: [cursor == nil ? "First" : "Second"],
                nextCursor: "same-cursor"
            )
        }
        let cyclingClient = try await XcodeMCP(transport: cycling)
        await #expect(throws: XcodeMCPError.invalidResponse(
            "tools/list returned a cursor cycle"
        )) {
            _ = try await cyclingClient.listTools()
        }
        await cyclingClient.close()
    }

    @Test func listToolsRestartsPageOneAfterRecoveryWithinOneReplayBudget() async throws {
        let first = LifecycleContractTransport(
            name: "old",
            expirations: ["tools/list:page-2": 1]
        ) { cursor, _ in
            lifecycleToolsPage(
                names: [cursor == nil ? "Old-First" : "Old-Second"],
                nextCursor: cursor == nil ? "page-2" : nil
            )
        }
        let replacement = LifecycleContractTransport(name: "new") { cursor, requestNumber in
            if cursor == "page-2", requestNumber == 1 {
                return lifecycleToolsPage(names: ["Discarded-Replay"], nextCursor: nil)
            }
            return lifecycleToolsPage(
                names: [cursor == nil ? "New-First" : "New-Second"],
                nextCursor: cursor == nil ? "page-2" : nil
            )
        }
        let factory = LifecycleTransportFactory([first, replacement])
        let xcode = try await XcodeMCP(
            configuration: .init(requestTimeout: .seconds(2)),
            recipe: MCPTransportRecipe { try await factory.make() }
        )

        #expect(try await xcode.listTools().map(\.name) == ["New-First", "New-Second"])
        let replacementCursors = await replacement.sentMessages()
            .filter { $0.method == "tools/list" }
            .map { $0.params?.objectValue?["cursor"]?.stringValue }
        #expect(replacementCursors == ["page-2", nil, "page-2"])
        #expect(await factory.makeCount() == 2)
        await xcode.close()
    }

    @Test func cancelledLastRecoveryWaiterDoesNotInstallFactoryResultOrRetainAuthority()
        async throws
    {
        let expired = LifecycleContractTransport(
            name: "expired",
            expirations: ["tools/list": 1]
        )
        let unneeded = LifecycleContractTransport(name: "unneeded")
        let factory = BlockingRecoveryTransportFactory(first: expired, blocked: unneeded)
        var authority: MCPClientSessionAuthority? = try await MCPClientSessionAuthority.startManaged(
            recipe: MCPTransportRecipe { try await factory.make() },
            initialize: lifecycleInitializeContext,
            defaultTimeout: .seconds(2)
        )
        weak let weakAuthority = authority

        let requestTask = Task { [weak authority] in
            guard let authority else { throw CancellationError() }
            try await authority.send(try lifecycleOperation(method: "tools/list"))
        }
        try await factory.waitUntilBlockedMakeStarts()
        requestTask.cancel()
        do {
            try await requestTask.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
        }

        authority = nil
        for _ in 0..<100 where weakAuthority != nil {
            await Task.yield()
        }
        #expect(weakAuthority == nil)

        await factory.releaseBlockedMake()
        _ = try await unneeded.nextCloseCount()
        #expect(await unneeded.sentMessages().isEmpty)
    }
}

private let lifecycleInitializeContext = MCPManagedInitializeContext(
    clientName: "LifecycleContractTests",
    clientVersion: "1",
    capabilities: [:]
)

private func lifecycleToolsPage(
    names: [String],
    nextCursor: String?
) -> MCPJSONValue {
    var object: [String: MCPJSONValue] = [
        "tools": .array(names.map { name in
            .object([
                "name": .string(name),
                "description": .string("test tool"),
                "inputSchema": .object(["type": .string("object")]),
            ])
        })
    ]
    if let nextCursor {
        object["nextCursor"] = .string(nextCursor)
    }
    return .object(object)
}

private func lifecycleOperation(
    method: String,
    id: Int = 1,
    replayPolicy: MCPReplayPolicy = .onceWhenRejectedBeforeProcessing,
    deadline: Deadline? = Deadline.fromNow(.seconds(2))
) throws -> MCPClientOperation {
    let data = try JSONRPC.Wire.data(from: JSONRPC.Wire.requestObject(
        id: Int64(id),
        method: method
    ))
    return MCPClientOperation(
        envelope: try MCPClientEnvelope(data: data),
        deadline: deadline,
        replayPolicy: replayPolicy
    )
}

private func waitUntilAuthorityCloseStarts(
    _ authority: MCPClientSessionAuthority,
    expiredOperation: MCPClientOperation
) async throws {
    while true {
        try Task.checkCancellation()
        do {
            try await authority.send(expiredOperation)
            throw XcodeMCPError.invalidResponse(
                "expired close probe unexpectedly reached the transport"
            )
        } catch MCPBridgeRuntimeError.closed {
            return
        } catch MCPBridgeRuntimeError.requestTimedOut {
            await Task.yield()
        } catch MCPClientSessionFailure.sessionRecoveryFailed {
            await Task.yield()
        }
    }
}

private actor RequestBarrier {
    private let target: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(target: Int) {
        self.target = target
    }

    func arrive() async {
        arrivals += 1
        if arrivals >= target {
            let waiters = waiters
            self.waiters.removeAll()
            for waiter in waiters { waiter.resume() }
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor ManualGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard isOpen == false else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard isOpen == false else { return }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor LifecycleTransportFactory {
    private let transports: [LifecycleContractTransport]
    private var index = 0

    init(_ transports: [LifecycleContractTransport]) {
        self.transports = transports
    }

    func make() throws -> any XcodeMCPTransport {
        guard index < transports.count else {
            throw MCPBridgeRuntimeError.transportUnavailable("test factory exhausted")
        }
        defer { index += 1 }
        return transports[index]
    }

    func makeCount() -> Int {
        index
    }
}

private actor GatedForwardedTransportFactory {
    private let candidates: [LifecycleContractTransport]
    private let gate = NonCooperativeSendGate()
    private let starts = RecordedValues<Void>()
    private let cancellations = RecordedValues<Void>()
    private var callCount = 0

    init(candidate: LifecycleContractTransport) {
        self.candidates = [candidate]
    }

    init(
        gatedCandidate: LifecycleContractTransport,
        retryCandidate: LifecycleContractTransport
    ) {
        self.candidates = [gatedCandidate, retryCandidate]
    }

    func make() async throws -> any XcodeMCPTransport {
        guard candidates.indices.contains(callCount) else {
            throw MCPBridgeRuntimeError.transportUnavailable("test factory exhausted")
        }
        let index = callCount
        callCount += 1
        guard index == 0 else { return candidates[index] }
        await starts.append(())
        let cancellations = cancellations
        await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            Task { await cancellations.append(()) }
        }
        return candidates[index]
    }

    func waitUntilStarted() async throws {
        _ = try await starts.nextValue()
    }

    func waitUntilCancelled() async throws {
        _ = try await cancellations.nextValue()
    }

    func release() async {
        await gate.release()
    }
}

private actor BlockingRecoveryTransportFactory {
    private let first: LifecycleContractTransport
    private let blocked: LifecycleContractTransport
    private let blockedStarts = RecordedValues<Void>()
    private var callCount = 0
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    init(first: LifecycleContractTransport, blocked: LifecycleContractTransport) {
        self.first = first
        self.blocked = blocked
    }

    func make() async throws -> any XcodeMCPTransport {
        callCount += 1
        if callCount == 1 { return first }
        await blockedStarts.append(())
        await withCheckedContinuation { blockedContinuation = $0 }
        return blocked
    }

    func waitUntilBlockedMakeStarts() async throws {
        _ = try await blockedStarts.nextValue()
    }

    func releaseBlockedMake() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private actor MixedRecoveryTransportFactory {
    private let transports: [any XcodeMCPTransport]
    private var count = 0

    init(first: any XcodeMCPTransport, replacement: any XcodeMCPTransport) {
        self.transports = [first, replacement]
    }

    init(_ transports: [any XcodeMCPTransport]) {
        self.transports = transports
    }

    func make() throws -> any XcodeMCPTransport {
        guard transports.indices.contains(count) else {
            throw MCPBridgeRuntimeError.transportUnavailable("test factory exhausted")
        }
        defer { count += 1 }
        return transports[count]
    }

    func makeCount() -> Int {
        count
    }
}

private actor RetiringRecoveryTransportFactory {
    private let first: any XcodeMCPTransport
    private let abandonedCandidate: any XcodeMCPTransport
    private let fresh: any XcodeMCPTransport
    private let abandonedWorkerStarts = RecordedValues<Void>()
    private let abandonedWorkerGate = NonCooperativeSendGate()
    private var count = 0

    init(
        first: any XcodeMCPTransport,
        abandonedCandidate: any XcodeMCPTransport,
        fresh: any XcodeMCPTransport
    ) {
        self.first = first
        self.abandonedCandidate = abandonedCandidate
        self.fresh = fresh
    }

    func make() async throws -> any XcodeMCPTransport {
        count += 1
        switch count {
        case 1:
            return first
        case 2:
            await abandonedWorkerStarts.append(())
            await abandonedWorkerGate.wait()
            return abandonedCandidate
        case 3:
            return fresh
        default:
            throw MCPBridgeRuntimeError.transportUnavailable("test factory exhausted")
        }
    }

    func waitUntilAbandonedWorkerStarts() async throws {
        _ = try await abandonedWorkerStarts.nextValue()
    }

    func releaseAbandonedWorker() async {
        await abandonedWorkerGate.release()
    }

    func makeCount() -> Int {
        count
    }
}

private actor LifecycleContractTransport: XcodeMCPTransport {
    nonisolated let events: AsyncStream<XcodeMCPTransportEvent>

    private let continuation: AsyncStream<XcodeMCPTransportEvent>.Continuation
    private let name: String
    private let expirationBarrier: RequestBarrier?
    private let listPage: @Sendable (_ cursor: String?, _ requestNumber: Int) -> MCPJSONValue
    private let sentValues = RecordedValues<SentMessage>()
    private let closeValues = RecordedValues<Int>()
    private var expirations: [String: Int]
    private var messages: [SentMessage] = []
    private var closes = 0
    private var closed = false
    private var eventStreamStarts = 0
    private var listRequestCounts: [String: Int] = [:]

    init(
        name: String,
        expirations: [String: Int] = [:],
        expirationBarrier: RequestBarrier? = nil,
        listPage: (@Sendable (_ cursor: String?, _ requestNumber: Int) -> MCPJSONValue)? = nil
    ) {
        let pair = AsyncStream.makeStream(of: XcodeMCPTransportEvent.self)
        self.events = pair.stream
        self.continuation = pair.continuation
        self.name = name
        self.expirations = expirations
        self.expirationBarrier = expirationBarrier
        self.listPage = listPage ?? { _, _ in
            .object([
                "tools": .array([
                    .object([
                        "name": .string("Tool-\(name)"),
                        "description": .string("test tool"),
                        "inputSchema": .object(["type": .string("object")]),
                    ])
                ]),
            ])
        }
    }

    func send(
        _ data: Data,
        headers: MCPConnectionHeaders,
        deadline: Deadline?
    ) async throws {
        _ = headers
        _ = deadline
        guard closed == false else { throw MCPBridgeRuntimeError.closed }
        let object = try lifecycleObject(data)
        let message = SentMessage(
            id: object["id"],
            method: object["method"]?.stringValue,
            params: object["params"],
            result: object["result"],
            error: object["error"]
        )
        messages.append(message)
        await sentValues.append(message)
        guard let method = message.method else { return }

        if method == "initialize", let id = message.id {
            try emit(
                id: id,
                result: .object([
                    "protocolVersion": .string("2025-06-18"),
                    "serverInfo": .object([
                        "name": .string("server-\(name)"),
                        "version": .string("1"),
                    ]),
                    "capabilities": .object([:]),
                ]),
                headers: MCPConnectionHeaders(sessionID: "session-\(name)")
            )
            return
        }
        if method.hasPrefix("notifications/") { return }

        let cursor = message.params?.objectValue?["cursor"]?.stringValue
        let specificExpirationKey = cursor.map { "\(method):\($0)" }
        let expirationKey = specificExpirationKey.flatMap {
            expirations[$0] == nil ? nil : $0
        } ?? method
        if let remaining = expirations[expirationKey], remaining > 0 {
            expirations[expirationKey] = remaining - 1
            await expirationBarrier?.arrive()
            throw MCPTransportFailure.sessionExpired(
                sessionID: "session-\(name)",
                delivery: .rejectedBeforeProcessing
            )
        }
        guard let id = message.id else { return }
        if method == "tools/list" {
            let key = cursor ?? "<first>"
            let requestNumber = listRequestCounts[key, default: 0] + 1
            listRequestCounts[key] = requestNumber
            try emit(id: id, result: listPage(cursor, requestNumber))
        } else {
            try emit(id: id, result: .object([
                "ok": .bool(true),
                "transport": .string(name),
            ]))
        }
    }

    func startEventStream(headers: MCPConnectionHeaders) async {
        _ = headers
        eventStreamStarts += 1
    }

    func close(headers: MCPConnectionHeaders) async {
        _ = headers
        guard closed == false else { return }
        closed = true
        closes += 1
        await closeValues.append(closes)
        continuation.yield(.closed(nil))
        continuation.finish()
    }

    func sentMessages() -> [SentMessage] {
        messages
    }

    func nextCloseCount() async throws -> Int {
        try await closeValues.nextValue()
    }

    func closeCount() -> Int {
        closes
    }

    func eventStreamStartCount() -> Int {
        eventStreamStarts
    }

    func emitSessionExpired() {
        continuation.yield(.sessionExpired(sessionID: "session-\(name)"))
    }

    private func emit(
        id: MCPJSONValue,
        result: MCPJSONValue,
        headers: MCPConnectionHeaders = MCPConnectionHeaders()
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: MCPJSONValue.object([
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]).foundationObject)
        continuation.yield(.messageWithHeaders(data, headers))
    }

    private func lifecycleObject(_ data: Data) throws -> [String: MCPJSONValue] {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let value = MCPJSONValue(foundationObject: raw),
              let object = value.objectValue else {
            throw MCPBridgeRuntimeError.invalidRequest("test message is not an object")
        }
        return object
    }
}

private final class DeinitProbe: @unchecked Sendable {}

private actor HangingSendXcodeMCPTransport: XcodeMCPTransport {
    nonisolated let events: AsyncStream<XcodeMCPTransportEvent>

    private let continuation: AsyncStream<XcodeMCPTransportEvent>.Continuation
    private let startedValues = RecordedValues<String>()
    private let cancelledValues = RecordedValues<String>()
    private let cancellationRequestIDs = RecordedValues<MCPJSONValue>()
    private let closeValues = RecordedValues<Int>()
    private let sendBlocker = NeverCompletingSendBlocker()
    private let initializedSendGate = NonCooperativeSendGate()
    private let eventStreamGate = NonCooperativeSendGate()
    private let stallsInitialize: Bool
    private let stallsInitializedUntilReleased: Bool
    private let stallsEventStreamUntilReleased: Bool
    private let eventStreamStartValues = RecordedValues<Int>()
    private var closes = 0
    private var eventStreamStarts = 0

    init(
        stallsInitialize: Bool = false,
        stallsInitializedUntilReleased: Bool = false,
        stallsEventStreamUntilReleased: Bool = false
    ) {
        let stream = AsyncStream<XcodeMCPTransportEvent>.makeStream()
        self.events = stream.stream
        self.continuation = stream.continuation
        self.stallsInitialize = stallsInitialize
        self.stallsInitializedUntilReleased = stallsInitializedUntilReleased
        self.stallsEventStreamUntilReleased = stallsEventStreamUntilReleased
    }

    func send(
        _ data: Data,
        headers: MCPConnectionHeaders,
        deadline: Deadline?
    ) async throws {
        _ = headers
        _ = deadline
        let object = try parse(data)
        let method = object["method"]?.stringValue ?? ""
        if method == "initialize", stallsInitialize == false {
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
            if stallsInitializedUntilReleased {
                await startedValues.append(method)
                await initializedSendGate.wait()
            }
            return
        }

        if method == "notifications/cancelled",
           let requestID = object["params"]?.objectValue?["requestId"]
        {
            await cancellationRequestIDs.append(requestID)
        }

        await startedValues.append(method)
        do {
            try await sendBlocker.wait()
        } catch {
            await cancelledValues.append(method)
            throw error
        }
    }

    func startEventStream(headers: MCPConnectionHeaders) async {
        _ = headers
        eventStreamStarts += 1
        await eventStreamStartValues.append(eventStreamStarts)
        if stallsEventStreamUntilReleased {
            await eventStreamGate.wait()
        }
    }

    func close(headers: MCPConnectionHeaders) async {
        _ = headers
        closes += 1
        await closeValues.append(closes)
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

    func nextCancellationRequestID() async throws -> MCPJSONValue {
        try await cancellationRequestIDs.nextValue()
    }

    func startedCount() async -> Int {
        await startedValues.count()
    }

    func nextCloseCount() async throws -> Int {
        try await closeValues.nextValue()
    }

    func closeCount() -> Int {
        closes
    }

    func releaseInitializedSend() async {
        await initializedSendGate.release()
    }

    func eventStreamStartCount() -> Int {
        eventStreamStarts
    }

    func nextEventStreamStart() async throws -> Int {
        try await eventStreamStartValues.nextValue()
    }

    func releaseEventStreamStart() async {
        await eventStreamGate.release()
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

private actor NonCooperativeSendGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard isReleased == false else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard isReleased == false else { return }
        isReleased = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
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

    func send(
        _ data: Data,
        headers: MCPConnectionHeaders,
        deadline: Deadline?
    ) async throws {
        _ = headers
        _ = deadline
        throw error
    }

    func startEventStream(headers: MCPConnectionHeaders) async {
        _ = headers
    }

    func close(headers: MCPConnectionHeaders) async {
        _ = headers
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

    func send(
        _ data: Data,
        headers: MCPConnectionHeaders,
        deadline: Deadline?
    ) async throws {
        _ = headers
        _ = deadline
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

    func startEventStream(headers: MCPConnectionHeaders) async {
        _ = headers
    }

    func close(headers: MCPConnectionHeaders) async {
        _ = headers
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
    private let responseErrors: [String: MCPJSONValue]
    private let progressBeforeResponseCount: Int
    private let emitsProgressBarrierServerRequest: Bool
    private let sentMessageValues = RecordedValues<SentMessage>()
    private let closeValues = RecordedValues<Int>()
    private var messages: [SentMessage] = []
    private var closed = false
    private var closes = 0

    init(
        initializeResult: MCPJSONValue = .object([
            "protocolVersion": .string("2025-06-18"),
            "serverInfo": .object([
                "name": .string("fake-mcpbridge"),
                "version": .string("test"),
            ]),
            "capabilities": .object([:]),
        ]),
        responseErrors: [String: MCPJSONValue] = [:],
        progressBeforeResponseCount: Int = 1,
        emitsProgressBarrierServerRequest: Bool = false
    ) {
        let stream = AsyncStream<XcodeMCPTransportEvent>.makeStream()
        self.events = stream.stream
        self.continuation = stream.continuation
        self.initializeResult = initializeResult
        self.responseErrors = responseErrors
        self.progressBeforeResponseCount = progressBeforeResponseCount
        self.emitsProgressBarrierServerRequest = emitsProgressBarrierServerRequest
    }

    func send(
        _ data: Data,
        headers: MCPConnectionHeaders,
        deadline: Deadline?
    ) async throws {
        _ = headers
        _ = deadline
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
            for index in 0..<progressBeforeResponseCount {
                try yieldMessage([
                    "jsonrpc": .string("2.0"),
                    "method": .string("notifications/progress"),
                    "params": .object([
                        "progressToken": progressToken,
                        "progress": .double(Double(index + 1) / Double(progressBeforeResponseCount + 1)),
                        "total": .integer(1),
                        "message": .string(index == 0 ? "halfway" : "queued"),
                    ]),
                ])
            }
            if emitsProgressBarrierServerRequest {
                try yieldMessage([
                    "jsonrpc": .string("2.0"),
                    "id": .string("progress-barrier"),
                    "method": .string("sampling/createMessage"),
                    "params": .object([:]),
                ])
            }
        }

        if let error = responseErrors[method] {
            try yieldMessage([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": error,
            ])
        } else {
            try yieldMessage([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": responseResult(method: method, params: sent.params),
            ])
        }
        if method == "tools/call",
           let progressToken = sent.params?.objectValue?["_meta"]?.objectValue?["progressToken"]
        {
            try yieldMessage([
                "jsonrpc": .string("2.0"),
                "method": .string("notifications/progress"),
                "params": .object([
                    "progressToken": progressToken,
                    "progress": .integer(1),
                    "total": .integer(1),
                    "message": .string("late"),
                ]),
            ])
        }
    }

    func startEventStream(headers: MCPConnectionHeaders) async {
        _ = headers
    }

    func close(headers: MCPConnectionHeaders) async {
        _ = headers
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
    private let initializeErrorStatusCode: Int
    private let postSSEFinishesLoading: Bool
    private let initializeUsesSSE: Bool
    private let initializeFinishesLoading: Bool
    private let deleteClosesEventStream: Bool
    private let deleteFinishesLoading: Bool
    private let requestValues = RecordedValues<RecordedHTTPRequest>()
    private var requests: [RecordedHTTPRequest] = []
    private var eventConnection: ActiveHTTPConnection?
    private var deleteConnection: ActiveHTTPConnection?

    init(
        progressDelivery: ProgressDelivery,
        sessionID: String? = "session-http-1",
        eventStreamFinishesImmediately: Bool = false,
        initializeError: Bool = false,
        initializeErrorStatusCode: Int = 200,
        postSSEFinishesLoading: Bool = true,
        initializeUsesSSE: Bool = false,
        initializeFinishesLoading: Bool = true,
        deleteClosesEventStream: Bool = true,
        deleteFinishesLoading: Bool = true
    ) {
        self.progressDelivery = progressDelivery
        self.sessionID = sessionID
        self.eventStreamFinishesImmediately = eventStreamFinishesImmediately
        self.initializeError = initializeError
        self.initializeErrorStatusCode = initializeErrorStatusCode
        self.postSSEFinishesLoading = postSSEFinishesLoading
        self.initializeUsesSSE = initializeUsesSSE
        self.initializeFinishesLoading = initializeFinishesLoading
        self.deleteClosesEventStream = deleteClosesEventStream
        self.deleteFinishesLoading = deleteFinishesLoading
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
            if deleteClosesEventStream {
                eventConnection?.finish()
                eventConnection = nil
            }
            if deleteFinishesLoading == false {
                deleteConnection = connection
            }
            return FakeURLProtocolResponse(
                headers: sessionID.map { ["Mcp-Session-Id": $0] } ?? [:],
                chunks: [],
                finishesLoading: deleteFinishesLoading
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

    func finishDelete() {
        deleteConnection?.finish()
        deleteConnection = nil
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
                    statusCode: initializeErrorStatusCode,
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
    private let cancellationValues = RecordedValues<String>()
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

    func recordCancellation(method: String) {
        Task { [cancellationValues] in
            await cancellationValues.append(method)
        }
    }

    func cancellationCount() async -> Int {
        await cancellationValues.count()
    }

    func nextCancellation(startingAt startIndex: Int, method: String) async throws -> String {
        try await cancellationValues.nextValue(startingAt: startIndex) { $0 == method }
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

    override func stopLoading() {
        FakeStreamableHTTPURLProtocolRegistry.shared.recordCancellation(
            method: request.httpMethod ?? ""
        )
    }
}

private func makeFakeHTTPURLSession(
    server: FakeStreamableHTTPServer,
    delegate: (any URLSessionDelegate)? = nil
) -> URLSession {
    FakeStreamableHTTPURLProtocolRegistry.shared.set(server)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeStreamableHTTPURLProtocol.self]
    return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
}

private final class URLSessionInvalidationRecorder: NSObject, URLSessionDelegate,
    @unchecked Sendable
{
    private let values = RecordedValues<Int>()

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        _ = session
        _ = error
        Task { [values] in
            await values.append(1)
        }
    }

    func nextInvalidation() async throws -> Int {
        try await values.nextValue()
    }

    func count() async -> Int {
        await values.count()
    }
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

    func count() -> Int {
        values.count
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
    private nonisolated let uptime = ManualUptimeState()

    func client() -> ClockClient {
        let uptime = uptime
        return ClockClient(
            now: { Date(timeIntervalSince1970: 0) },
            uptimeNanoseconds: { uptime.now() },
            sleep: { duration in
                await self.sleep(for: duration)
            },
            sleepForTimeInterval: { _ in }
        )
    }

    func advanceUptime(by duration: Duration) {
        uptime.advance(by: duration)
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

private final class ManualUptimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func now() -> UInt64 {
        lock.withLock { value }
    }

    func advance(by duration: Duration) {
        let components = duration.components
        let seconds = UInt64(max(0, components.seconds))
        let nanos = UInt64(max(0, components.attoseconds) / 1_000_000_000)
        let secondsResult = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let amount: UInt64
        if secondsResult.overflow {
            amount = .max
        } else {
            let sum = secondsResult.partialValue.addingReportingOverflow(nanos)
            amount = sum.overflow ? .max : sum.partialValue
        }
        lock.withLock {
            value = value &+ min(amount, UInt64.max &- value)
        }
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
    private var cancellationCount = 0
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

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

    func waitForCancellation() async {
        guard cancellationCount == 0 else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    private func cancelSleepWaiter(id: UUID) {
        guard let index = sleepWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = sleepWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        cancellationCount += 1
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
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
    let race = XcodeMCPTestTimeoutRace<T>()
    let clock = ContinuousClock()
    let operationTask = Task {
        do {
            race.complete(.success(try await operation()))
        } catch {
            race.complete(.failure(error))
        }
    }
    let timeoutTask = Task {
        do {
            try await clock.sleep(until: clock.now.advanced(by: timeout))
            race.complete(.failure(XcodeMCPError.invalidResponse(description)))
        } catch {
            return
        }
    }

    return try await withTaskCancellationHandler {
        defer {
            operationTask.cancel()
            timeoutTask.cancel()
        }
        return try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
        }
    } onCancel: {
        operationTask.cancel()
        timeoutTask.cancel()
        race.complete(.failure(CancellationError()))
    }
}

private final class XcodeMCPTestTimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let result: Result<T, Error>? = withLock {
            guard let storedResult = self.result else {
                self.continuation = continuation
                return nil
            }
            return storedResult
        }
        if let result {
            continuation.resume(with: result)
        }
    }

    func complete(_ result: Result<T, Error>) {
        let continuation = withLock {
            guard self.result == nil else {
                return nil as CheckedContinuation<T, Error>?
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
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
