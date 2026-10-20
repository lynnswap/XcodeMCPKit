import Foundation
import NIOConcurrencyHelpers
import Testing
import XcodeMCPCore
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

/// A scripted host process. It answers `initialize` and `tools/list` itself and asks
/// `handle` for every other request.
final class FakeHostSession: UpstreamSession, Sendable {
    enum Reply: Sendable {
        case result(JSONValue)
        case error(code: Int, message: String)
        /// Kept until `release(_:with:)`.
        case hold
        /// Refuses the write, as a host whose input queue is full does.
        case backpressure
    }

    let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let handle: @Sendable (_ method: String, _ params: [String: JSONValue]) -> Reply
    private let tools: NIOLockedValueBox<JSONValue>
    private let initializeReply: Reply?
    /// Every message the proxy wrote, in order.
    let received = NIOLockedValueBox<[JSONValue]>([])
    private let held = NIOLockedValueBox<[(id: JSONValue, method: String)]>([])
    let heldRequest = TestSignal()
    let stopped = TestSignal()
    /// Signaled when the proxy requests termination without waiting for it.
    let cancelled = TestSignal()
    private let stops = NIOLockedValueBox(0)
    var stopCount: Int { stops.withLockedValue { $0 } }

    init(tools: JSONValue = .object(["tools": .array([])]), initializeReply: Reply? = nil,
         handle: @escaping @Sendable (_ method: String, _ params: [String: JSONValue]) -> Reply = { _, _ in
             .result(.object([:]))
         }) {
        (events, continuation) = AsyncStream<Upstream.Event>.makeStream()
        self.tools = NIOLockedValueBox(tools)
        self.initializeReply = initializeReply
        self.handle = handle
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        guard let value = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.init(any:)),
              case .object(let object) = value else {
            Issue.record("The host received a message that is not a JSON object")
            return .accepted
        }
        guard case .string(let method)? = object["method"], let id = object["id"] else {
            received.withLockedValue { $0.append(value) }
            return .accepted
        }
        var params: [String: JSONValue] = [:]
        if case .object(let fields)? = object["params"] { params = fields }
        let reply: Reply
        switch method {
        case "initialize":
            reply = initializeReply ?? .result(.object([
                "protocolVersion": .string(MCPProtocolVersion.current),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("FakeHost"), "version": .string("1")]),
            ]))
        case "tools/list":
            reply = .result(tools.withLockedValue { $0 })
        default:
            reply = handle(method, params)
        }
        if case .backpressure = reply { return .backpressure }
        received.withLockedValue { $0.append(value) }
        respond(to: id, method: method, with: reply)
        return .accepted
    }

    private func respond(to id: JSONValue, method: String, with reply: Reply) {
        switch reply {
        case .result(let result):
            emit(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
        case .error(let code, let message):
            emit(.object(["jsonrpc": .string("2.0"), "id": id,
                          "error": .object(["code": .number(.int(Int64(code))), "message": .string(message)])]))
        case .hold:
            held.withLockedValue { $0.append((id, method)) }
            heldRequest.signal()
        case .backpressure:
            Issue.record("An accepted request cannot be refused afterwards")
        }
    }

    /// Answers every held request for `method`.
    func release(_ method: String, with reply: Reply) {
        let requests = held.withLockedValue { held in
            let matching = held.filter { $0.method == method }
            held.removeAll { $0.method == method }
            return matching
        }
        for request in requests { respond(to: request.id, method: method, with: reply) }
    }

    func setTools(_ value: JSONValue) { tools.withLockedValue { $0 = value } }

    func emit(_ message: JSONValue) {
        do { continuation.yield(.message(try JSONSerialization.data(withJSONObject: message.foundationObject))) }
        catch { Issue.record(error) }
    }

    func emitStderr(_ line: String) { continuation.yield(.stderr(line)) }

    func exit() { continuation.yield(.exit(1)) }

    func requests(_ method: String) -> [[String: JSONValue]] {
        received.withLockedValue { messages in
            messages.compactMap { message in
                guard case .object(let object) = message, object["method"] == .string(method) else { return nil }
                return object
            }
        }
    }

    func cancel() {
        cancelled.signal()
        continuation.finish()
    }

    func stop() async {
        stops.withLockedValue { $0 += 1 }
        stopped.signal()
        continuation.finish()
    }
}

/// Starts a new `FakeHostSession` for every process start.
final class FakeHostSessionFactory: UpstreamSessionFactory, Sendable {
    let sessions = NIOLockedValueBox<[FakeHostSession]>([])
    let started = LockedRecordedValues<FakeHostSession>()
    private let make: @Sendable (_ start: Int) throws -> FakeHostSession

    init(make: @escaping @Sendable (_ start: Int) throws -> FakeHostSession = { _ in FakeHostSession() }) {
        self.make = make
    }

    func startSession() async throws -> any UpstreamSession {
        let session = try make(sessions.withLockedValue { $0.count })
        sessions.withLockedValue { $0.append(session) }
        started.append(session)
        return session
    }
}
