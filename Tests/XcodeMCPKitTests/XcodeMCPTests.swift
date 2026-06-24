import Foundation
import Testing

@testable import XcodeMCPKit

@Suite(.serialized)
struct XcodeMCPTests {
    @Test func asyncInitializerPerformsMCPHandshake() async throws {
        let transport = FakeXcodeMCPTransport()
        let xcode = try await XcodeMCP(
            config: .init(
                environment: [:],
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

    @Test func listToolsDecodesDescriptorAndPreservesDynamicFields() async throws {
        let transport = FakeXcodeMCPTransport()
        let xcode = try await XcodeMCP(config: .init(environment: [:]), transport: transport)
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
        let xcode = try await XcodeMCP(config: .init(environment: [:]), transport: transport)
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

    @Test func callToolAddsProgressTokenAndRoutesMatchingProgress() async throws {
        let transport = FakeXcodeMCPTransport()
        let progressValues = RecordedValues<MCPProgress>()
        let xcode = try await XcodeMCP(config: .init(environment: [:]), transport: transport)
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

    @Test func closeIsIdempotentAndRejectsFuturePublicCalls() async throws {
        let transport = FakeXcodeMCPTransport()
        let xcode = try await XcodeMCP(config: .init(environment: [:]), transport: transport)

        await xcode.close()
        await xcode.close()

        #expect(await transport.closeCount() == 1)
        await #expect(throws: XcodeMCPError.closed) {
            _ = try await xcode.listTools()
        }
    }

    @Test func unsupportedServerRequestGetsInternalErrorResponse() async throws {
        let transport = FakeXcodeMCPTransport()
        let xcode = try await XcodeMCP(config: .init(environment: [:]), transport: transport)
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
}

private struct SentMessage: Sendable, Equatable {
    var id: MCPJSONValue?
    var method: String?
    var params: MCPJSONValue?
    var result: MCPJSONValue?
    var error: MCPJSONValue?
}

private actor FakeXcodeMCPTransport: XcodeMCPTransport {
    nonisolated let events: AsyncStream<XcodeMCPTransportEvent>

    private let continuation: AsyncStream<XcodeMCPTransportEvent>.Continuation
    private let sentMessageValues = RecordedValues<SentMessage>()
    private var messages: [SentMessage] = []
    private var closed = false
    private var closes = 0

    init() {
        let stream = AsyncStream<XcodeMCPTransportEvent>.makeStream()
        self.events = stream.stream
        self.continuation = stream.continuation
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
            return .object([
                "protocolVersion": .string("2025-06-18"),
                "serverInfo": .object([
                    "name": .string("fake-mcpbridge"),
                    "version": .string("test"),
                ]),
                "capabilities": .object([:]),
            ])
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
        default:
            return .null
        }
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
