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

    @Test func streamableHTTPSendsSessionHeadersAndDeletesOnClose() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
        let server = FakeStreamableHTTPServer(progressDelivery: .none)
        let session = makeFakeHTTPURLSession(server: server)
        defer {
            session.invalidateAndCancel()
            FakeStreamableHTTPURLProtocolRegistry.shared.reset()
        }

        let transport = StreamableHTTPXcodeMCPTransport(endpoint: endpoint, urlSession: session)
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
        #expect(initialize.header("Accept") == "application/json, text/event-stream")
        #expect(initialize.header("Content-Type") == "application/json")
        #expect(initialize.header("MCP-Session-Id") == nil)
        #expect(initialize.header("MCP-Protocol-Version") == nil)

        let initialized = try #require(requests.firstJSONRPC(method: "notifications/initialized"))
        #expect(initialized.header("MCP-Session-Id") == "session-http-1")
        #expect(initialized.header("MCP-Protocol-Version") == "2025-06-18")

        let list = try #require(requests.firstJSONRPC(method: "tools/list"))
        #expect(list.header("MCP-Session-Id") == "session-http-1")
        #expect(list.header("MCP-Protocol-Version") == "2025-06-18")

        let get = try #require(requests.first(where: { $0.httpMethod == "GET" }))
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

        let transport = StreamableHTTPXcodeMCPTransport(endpoint: endpoint, urlSession: session)
        let xcode = try await XcodeMCP(
            config: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
            transport: transport
        )
        defer {
            Task { await xcode.close() }
        }

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
    }

    @Test func streamableHTTPGetSSERoutesProgressWhilePOSTReturnsJSONResult() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8765/mcp")!
        let server = FakeStreamableHTTPServer(progressDelivery: .getSSE)
        let session = makeFakeHTTPURLSession(server: server)
        defer {
            session.invalidateAndCancel()
            FakeStreamableHTTPURLProtocolRegistry.shared.reset()
        }

        let transport = StreamableHTTPXcodeMCPTransport(endpoint: endpoint, urlSession: session)
        let xcode = try await XcodeMCP(
            config: .init(transport: .streamableHTTP(endpoint: endpoint), requestTimeout: .seconds(2)),
            transport: transport
        )
        defer {
            Task { await xcode.close() }
        }

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

private struct RecordedHTTPRequest: Sendable, Equatable {
    var httpMethod: String
    var url: URL
    var headers: [String: String]
    var body: MCPJSONValue?

    init(request: URLRequest) {
        self.httpMethod = request.httpMethod ?? "GET"
        self.url = request.url ?? URL(string: "http://invalid.local/")!
        self.headers = request.allHTTPHeaderFields ?? [:]
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
    private let requestValues = RecordedValues<RecordedHTTPRequest>()
    private var requests: [RecordedHTTPRequest] = []
    private var eventConnection: ActiveHTTPConnection?

    init(progressDelivery: ProgressDelivery) {
        self.progressDelivery = progressDelivery
    }

    func response(
        for request: URLRequest,
        connection: ActiveHTTPConnection
    ) async -> FakeURLProtocolResponse {
        let recorded = RecordedHTTPRequest(request: request)
        requests.append(recorded)
        await requestValues.append(recorded)

        switch recorded.httpMethod {
        case "GET":
            eventConnection = connection
            return FakeURLProtocolResponse(
                headers: [
                    "Content-Type": "text/event-stream",
                    "Cache-Control": "no-cache",
                    "Mcp-Session-Id": "session-http-1",
                ],
                chunks: [Data(": ok\n\n".utf8)],
                finishesLoading: false
            )
        case "DELETE":
            eventConnection?.finish()
            eventConnection = nil
            return FakeURLProtocolResponse(
                headers: ["Mcp-Session-Id": "session-http-1"],
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
        matching predicate: @escaping @Sendable (RecordedHTTPRequest) -> Bool
    ) async throws -> RecordedHTTPRequest {
        try await requestValues.nextValue(matching: predicate)
    }

    private func postResponse(for request: RecordedHTTPRequest) -> FakeURLProtocolResponse {
        guard let method = request.jsonRPCMethod else {
            return FakeURLProtocolResponse(statusCode: 400, chunks: [Data("missing method".utf8)])
        }

        switch method {
        case "initialize":
            return jsonResponse(
                id: request.body?.objectValue?["id"],
                result: [
                    "protocolVersion": "2025-06-18",
                    "serverInfo": [
                        "name": "fake-http-proxy",
                        "version": "test",
                    ],
                    "capabilities": [:],
                ],
                headers: ["Mcp-Session-Id": "session-http-1"]
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
                ]
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
