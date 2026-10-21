import XcodeMCPProxyRuntimeContract
@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Darwin
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

enum HTTPTestError: Error {
    case missingResponseHead
}

struct HTTPTestConfiguration: Sendable {
    var runtime: ProxyRuntimeConfiguration
    var listenHost: String
    var listenPort: Int
    var maxBodyBytes: Int
    var enablesDebugEndpoints = false

    var requestTimeout: TimeInterval {
        get { runtime.requestTimeout }
        set { runtime.requestTimeout = newValue }
    }

    var prewarmToolsList: Bool {
        get { runtime.prewarmToolsList }
        set { runtime.prewarmToolsList = newValue }
    }

}

private let embeddedCompletionExecutors = NIOLockedValueBox<
    [ObjectIdentifier: EmbeddedEventLoopCompletionExecutor]
>([:])

private final class EmbeddedEventLoopCompletionExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [() -> Void] = []

    func enqueue(_ operation: @escaping () -> Void) {
        lock.withLock {
            operations.append(operation)
        }
    }

    func drain() {
        let pending = lock.withLock { () -> [() -> Void] in
            let pending = operations
            operations.removeAll()
            return pending
        }
        for operation in pending {
            operation()
        }
    }
}

private func registerEmbeddedCompletionExecutor(
    _ executor: EmbeddedEventLoopCompletionExecutor,
    for channel: EmbeddedChannel
) {
    embeddedCompletionExecutors.withLockedValue { executors in
        executors[ObjectIdentifier(channel)] = executor
    }
}

private func embeddedCompletionExecutor(
    for channel: EmbeddedChannel
) -> EmbeddedEventLoopCompletionExecutor? {
    embeddedCompletionExecutors.withLockedValue { executors in
        executors[ObjectIdentifier(channel)]
    }
}

func drainEmbeddedCompletions(for channel: EmbeddedChannel) {
    embeddedCompletionExecutor(for: channel)?.drain()
}

/// The production runtime, `NativeHostBroker`, over scripted host processes.
///
/// Every start of the default host creates a `FakeHostSession` that answers `initialize` and
/// `tools/list` with `tools`, and asks `handle` for every other request, including `tools/call`.
/// The runtime shuts down when the test ends, so tests need an `AsyncTestCleanupTrait` scope.
final class HTTPTestRuntime: Sendable {
    static let defaultTools = JSONValue.object(["tools": .array([
        .object([
            "name": .string("DocumentationSearch"), "description": .string("Search documentation"),
            "inputSchema": .object(["type": .string("object"), "properties": .object([
                "query": .object(["type": .string("string")]),
            ])]),
        ]),
        .object([
            "name": .string("XcodeListTemplates"), "description": .string("List templates"),
            "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
        ]),
    ])])

    let broker: NativeHostBroker
    let hosts: FakeHostSessionFactory
    /// The gateway side that owns MCP sessions, shared by every handler of a test.
    let controlService: HTTPControlService

    init(
        config: HTTPTestConfiguration,
        tools: JSONValue = HTTPTestRuntime.defaultTools,
        clock: ClockClient = .liveValue,
        handle: @escaping @Sendable (_ method: String, _ params: [String: JSONValue]) -> FakeHostSession.Reply = { _, _ in
            .result(.object(["content": .array([])]))
        }
    ) throws {
        let hosts = FakeHostSessionFactory { _ in FakeHostSession(tools: tools, handle: handle) }
        self.hosts = hosts
        let installation = XcodeHostInstallation(developerDirectory: URL(filePath: "/Fixture/Default.app"))
        let broker = try NativeHostBroker(
            configuration: config.runtime,
            inventory: XcodeHostInventory(defaultInstallation: installation) { [installation] },
            clock: clock,
            sessionFactory: { _ in hosts })
        self.broker = broker
        let controlService = HTTPControlService(runtime: broker)
        self.controlService = controlService
        #expect(registerAsyncTestCleanup(description: "HTTP test runtime shutdown") {
            await controlService.shutdown()
            await broker.shutdown()
        })
    }

    /// The most recently started host process.
    var host: FakeHostSession? { hosts.sessions.withLockedValue { $0.last } }

    var startedHostCount: Int { hosts.sessions.withLockedValue { $0.count } }

    func hasSession(_ id: String) -> Bool {
        controlService.sessions.phase(of: ProxySessionID(rawValue: id)) != nil
    }

    /// Waits until the hosts have received `count` tool calls.
    func waitForToolCalls(_ count: Int) async throws {
        try await waitWithTimeout("\(count) tool call(s) reached the host", timeout: .seconds(5)) { [self] in
            while toolCalls().count < count { await Task.yield() }
        }
    }

    /// Waits until the latest host has received `method`, and returns those messages.
    @discardableResult
    func waitForHostMessages(_ method: String, count: Int = 1) async throws -> [[String: JSONValue]] {
        try await waitWithTimeout("\(method) reached the host", timeout: .seconds(5)) { [self] in
            while (host?.requests(method).count ?? 0) < count { await Task.yield() }
            return host?.requests(method) ?? []
        }
    }

    /// Tool calls the hosts received, in order.
    func toolCalls() -> [(name: String, arguments: [String: JSONValue])] {
        hosts.sessions.withLockedValue { $0 }.flatMap { $0.requests("tools/call") }.compactMap { request in
            guard case .object(let params)? = request["params"], case .string(let name)? = params["name"] else {
                return nil
            }
            var arguments: [String: JSONValue] = [:]
            if case .object(let values)? = params["arguments"] { arguments = values }
            return (name, arguments)
        }
    }

    func shutdown() async { await broker.shutdown() }
}

func makeHTTPConfig(
    maxBodyBytes: Int = 1024,
    requestTimeout: TimeInterval = 1
) -> HTTPTestConfiguration {
    HTTPTestConfiguration(
        runtime: ProxyRuntimeConfiguration(
            maxMessageBytes: maxBodyBytes,
            requestTimeout: requestTimeout
        ),
        listenHost: "127.0.0.1",
        listenPort: 0,
        maxBodyBytes: maxBodyBytes
    )
}

/// A runtime clock whose sleeps end only when `clock` advances past them, so request deadlines
/// fire when a test advances the clock.
func makeHTTPTestClock(_ clock: TestClock) -> ClockClient {
    ClockClient(
        now: { Date(timeIntervalSince1970: 0) },
        uptimeNanoseconds: { 0 },
        sleep: { duration in try? await clock.sleep(for: duration) },
        sleepForTimeInterval: { _ in }
    )
}

func addHTTPHandler(
    to channel: EmbeddedChannel,
    config: HTTPTestConfiguration,
    runtime: HTTPTestRuntime,
    scheduleResponseCompletion:
        (@Sendable (EventLoop, @escaping @Sendable () -> Void) -> Void)? = nil
) throws {
    let completionExecutor = EmbeddedEventLoopCompletionExecutor()
    registerEmbeddedCompletionExecutor(completionExecutor, for: channel)
    let handler = HTTPHandler(
        config: ProxyHTTPConfiguration(
            listenHost: config.listenHost,
            listenPort: config.listenPort,
            maxBodyBytes: config.maxBodyBytes,
            enablesDebugEndpoints: config.enablesDebugEndpoints
        ),
        controlService: runtime.controlService,
        scheduleResponseCompletion: scheduleResponseCompletion ?? { _, operation in
            completionExecutor.enqueue(operation)
        }
    )
    try channel.pipeline.addHandler(handler).wait()
}

func collectResponse(
    from channel: EmbeddedChannel,
    timeout: Duration = .seconds(2)
) async throws -> (
    head: HTTPResponseHead, body: String
) {
    var responseHead: HTTPResponseHead?
    var bodyBuffer = channel.allocator.buffer(capacity: 0)
    var sawEnd = false
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while true {
        drainEmbeddedCompletions(for: channel)
        channel.embeddedEventLoop.run()
        drainEmbeddedCompletions(for: channel)
        channel.embeddedEventLoop.run()

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
                sawEnd = true
            }
        }

        if let responseHead,
            sawEnd || SelfContainedHTTPResponse.isOpenSSE(responseHead, bodyBuffer: bodyBuffer)
        {
            let body = bodyBuffer.readString(length: bodyBuffer.readableBytes) ?? ""
            return (responseHead, body)
        }
        guard clock.now < deadline else {
            throw AsyncTestTimeoutError(description: "timed out waiting for embedded HTTP response")
        }
        sched_yield()
    }
}

private enum SelfContainedHTTPResponse {
    static func isOpenSSE(_ head: HTTPResponseHead, bodyBuffer: ByteBuffer) -> Bool {
        guard head.headers.first(name: "Content-Type") == "text/event-stream" else {
            return false
        }
        return bodyBuffer.readableBytes > 0
    }
}

func toolsCallPayload(
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

func postJSON(
    _ payload: [String: Any],
    sessionID: String,
    to channel: EmbeddedChannel
) throws {
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
}

func postJSONArray(
    _ payload: [Any],
    sessionID: String?,
    to channel: EmbeddedChannel
) throws {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json, text/event-stream")
    head.headers.add(name: "Content-Type", value: "application/json")
    if let sessionID {
        head.headers.add(name: "Mcp-Session-Id", value: sessionID)
        head.headers.add(name: "MCP-Protocol-Version", value: MCP.ProtocolVersion.current)
    }
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))
}

func assertBatchRejected(_ response: (head: HTTPResponseHead, body: String)) {
    #expect(response.head.status == .badRequest)
    #expect(response.head.headers.first(name: "Content-Type") == "text/plain; charset=utf-8")
    #expect(response.body == "JSON-RPC batching is not supported")
}

struct TestHTTPHandlerServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let url: URL
    let runtime: HTTPTestRuntime
    let controlService: HTTPControlService
    let childChannelTracker: HTTPTestServerChannelTracker

    static func start(config: HTTPTestConfiguration, runtime: HTTPTestRuntime) throws -> TestHTTPHandlerServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let childChannelTracker = HTTPTestServerChannelTracker()
        let controlService = runtime.controlService
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            config: ProxyHTTPConfiguration(
                                listenHost: config.listenHost,
                                listenPort: config.listenPort,
                                maxBodyBytes: config.maxBodyBytes,
                                enablesDebugEndpoints: config.enablesDebugEndpoints
                            ),
                            controlService: controlService
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
            runtime: runtime,
            controlService: controlService,
            childChannelTracker: childChannelTracker
        )
    }

    func shutdown() async throws {
        try await shutdownHTTPTestServer(
            listenChannel: channel,
            childChannelTracker: childChannelTracker,
            group: group,
            beforeClose: {
                await runtime.shutdown()
            }
        )
    }
}

struct RawHTTPResponse: Sendable {
    let statusCode: Int
    let bodyData: Data
}

func postHTTPJSON(
    url: URL,
    sessionID: String,
    payload: [String: Any]
) async throws -> (HTTPURLResponse, [String: Any]) {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    request.setValue(MCP.ProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")

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

func postHTTPAnyData(
    url: URL,
    sessionID: String,
    payload: [Any]
) async throws -> RawHTTPResponse {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    request.setValue(MCP.ProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")

    return try await withTestURLSession { session in
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPTestError.missingResponseHead
        }
        return RawHTTPResponse(statusCode: httpResponse.statusCode, bodyData: responseData)
    }
}

func assertHTTPBatchRejected(
    url: URL,
    sessionID: String,
    payload: [Any]
) async throws -> RawHTTPResponse {
    let response = try await postHTTPAnyData(
        url: url,
        sessionID: sessionID,
        payload: payload
    )
    #expect(response.statusCode == 400)
    #expect(String(data: response.bodyData, encoding: .utf8) == "JSON-RPC batching is not supported")
    return response
}

/// Initializes an MCP session over HTTP and returns its `MCP-Session-Id`.
func initializeHTTPSession(url: URL, clientName: String = "HTTPTests") async throws -> String {
    let data = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": [
            "protocolVersion": MCP.ProtocolVersion.current, "capabilities": [String: Any](),
            "clientInfo": ["name": clientName, "version": "1"],
        ],
    ] as [String: Any])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    return try await withTestURLSession { session in
        let (_, response) = try await session.data(for: request)
        guard let sessionID = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id") else {
            throw HTTPTestError.missingResponseHead
        }
        return sessionID
    }
}

func initializeHTTPChannel(_ channel: EmbeddedChannel) async throws -> String {
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

    let initResponse = try await collectResponse(from: channel)
    return try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))
}
