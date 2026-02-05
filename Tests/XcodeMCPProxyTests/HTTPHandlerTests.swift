import Foundation
import NIO
import NIOEmbedded
import NIOHTTP1
import Testing
@testable import XcodeMCPProxy

@Test func httpHealthCheck() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/health")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)
    #expect(response.body == "ok")
}

@Test func httpSSERequiresAcceptHeader() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
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
    let sessionManager = TestSessionManager(config: config)
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

@Test func httpPostRejectsNonJSONContentType() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "text/plain")
    var body = channel.allocator.buffer(capacity: 2)
    body.writeString("{}")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .unsupportedMediaType)
}

@Test func httpPostRejectsLargeBody() async throws {
    let config = makeConfig(maxBodyBytes: 1)
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
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
    #expect(response.head.status == .payloadTooLarge)
}

@Test func httpInitializeCreatesSessionAndReturnsResponse() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "xcode-mcp-proxy-tests",
                "version": "0.0",
            ],
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)
    #expect(response.head.headers.first(name: "Mcp-Session-Id")?.isEmpty == false)

    let responseObject = try JSONSerialization.jsonObject(with: Data(response.body.utf8), options: []) as? [String: Any]
    let responseId = (responseObject?["id"] as? NSNumber)?.intValue
    #expect(responseId == 1)
}

@Test func httpInitializeRequiresId() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "xcode-mcp-proxy-tests",
                "version": "0.0",
            ],
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .badRequest)
    #expect(response.body.contains("missing id"))
}

@Test func httpSessionHeaderAutoCreatesSession() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    let sessionId = "missing-session"
    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json")
    head.headers.add(name: "Content-Type", value: "application/json")
    head.headers.add(name: "Mcp-Session-Id", value: sessionId)
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .accepted)
    #expect(sessionManager.hasSession(id: sessionId))
}

@Test func httpSSEHandshakeSucceedsWithSession() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    _ = sessionManager.session(id: "session-1")
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/mcp")
    head.headers.add(name: "Accept", value: "text/event-stream")
    head.headers.add(name: "Mcp-Session-Id", value: "session-1")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)
    #expect(response.head.headers.first(name: "Content-Type") == "text/event-stream")
    #expect(response.body.contains(": ok"))
}

@Test func httpSSEHandshakeAutoCreatesSession() async throws {
    let config = makeConfig()
    let channel = EmbeddedChannel()
    defer { _ = try? channel.finish() }
    let sessionManager = TestSessionManager(config: config)
    try addHTTPHandler(to: channel, config: config, sessionManager: sessionManager)

    let sessionId = "session-auto"
    var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/mcp")
    head.headers.add(name: "Accept", value: "text/event-stream")
    head.headers.add(name: "Mcp-Session-Id", value: sessionId)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let response = try collectResponse(from: channel)
    #expect(response.head.status == .ok)
    #expect(sessionManager.hasSession(id: sessionId))
}

private enum HTTPTestError: Error {
    case missingResponseHead
}

private final class TestSessionManager: SessionManaging, @unchecked Sendable {
    private var sessions: [String: SessionContext] = [:]
    private var nextUpstreamId: Int64 = 1
    private var initialized = false
    private let config: ProxyConfig

    init(config: ProxyConfig) {
        self.config = config
    }

    func session(id: String) -> SessionContext {
        if let existing = sessions[id] {
            return existing
        }
        let context = SessionContext(id: id, config: config)
        sessions[id] = context
        return context
    }

    func hasSession(id: String) -> Bool {
        sessions[id] != nil
    }

    func removeSession(id: String) {
        let context = sessions.removeValue(forKey: id)
        context?.sseHub.closeAll()
    }

    func shutdown() {}

    func isInitialized() -> Bool {
        initialized
    }

    func registerInitialize(
        originalId: RPCId,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        initialized = true
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalId.value.foundationObject,
            "result": [
                "capabilities": [String: Any](),
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: response, options: [])) ?? Data()
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return eventLoop.makeSucceededFuture(buffer)
    }

    func assignUpstreamId(sessionId: String, originalId: RPCId) -> Int64 {
        let id = nextUpstreamId
        nextUpstreamId += 1
        return id
    }

    func sendUpstream(_ data: Data) {}
}

private func makeConfig(maxBodyBytes: Int = 1024, requestTimeout: TimeInterval = 1) -> ProxyConfig {
    ProxyConfig(
        listenHost: "127.0.0.1",
        listenPort: 0,
        upstreamCommand: "xcrun",
        upstreamArgs: ["mcpbridge"],
        xcodePID: nil,
        upstreamSessionID: nil,
        maxBodyBytes: maxBodyBytes,
        requestTimeout: requestTimeout,
        eagerInitialize: false
    )
}

private func addHTTPHandler(
    to channel: EmbeddedChannel,
    config: ProxyConfig,
    sessionManager: any SessionManaging
) throws {
    let handler = HTTPHandler(config: config, sessionManager: sessionManager)
    try channel.pipeline.addHandler(handler).wait()
}

private func collectResponse(from channel: EmbeddedChannel) throws -> (head: HTTPResponseHead, body: String) {
    var responseHead: HTTPResponseHead?
    var bodyBuffer = channel.allocator.buffer(capacity: 0)

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
            break
        }
    }

    guard let responseHead else {
        throw HTTPTestError.missingResponseHead
    }
    let body = bodyBuffer.readString(length: bodyBuffer.readableBytes) ?? ""
    return (responseHead, body)
}
