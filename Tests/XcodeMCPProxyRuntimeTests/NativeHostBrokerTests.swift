import Foundation
import NIO
import NIOConcurrencyHelpers
import Testing
@testable import XcodeMCPCore
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyRuntimeContract
import XcodeMCPProxyTestSupport

@Suite(.serialized, .timeLimit(.minutes(1)), .asyncTestCleanup)
struct NativeHostBrokerTests {
    @Test func selectionAndCatalogsAreScopedToTheClientSession() async throws {
        let fixture = try BrokerFixture()
        let a = try await fixture.initialize("client-a")
        let b = try await fixture.initialize("client-b")
        _ = try await fixture.echo(b)
        let eventStart = fixture.events.withLockedValue { $0.count }
        let available = try await fixture.list(a)
        let other = try #require(available.first { $0["isDefault"] == .bool(false) })
        let otherID = try #require(other["hostIdentifier"])
        _ = try await fixture.call(a, name: NativeHostBroker.selectTool,
                                 arguments: ["hostIdentifier": otherID])
        let aCatalog = try await fixture.request(a, method: "tools/list")
        let bCatalog = try await fixture.request(b, method: "tools/list")
        #expect(aCatalog != bCatalog)
        let aHosts = try await fixture.list(a)
        let bHosts = try await fixture.list(b)
        #expect(aHosts.first { $0["isSelected"] == .bool(true) }?["hostIdentifier"] == otherID)
        #expect(bHosts.first { $0["isSelected"] == .bool(true) }?["hostIdentifier"] == .string(NativeHostBroker.defaultHostIdentifier))
        let changeSessions = fixture.events.withLockedValue { values in
            values.dropFirst(eventStart).compactMap { event -> ProxySessionID? in
                guard case .notification(let id, let data) = event,
                      (try? JSONRPC.Wire.object(fromData: data)["method"] as? String)
                        == "notifications/tools/list_changed" else { return nil }
                return id
            }
        }
        #expect(changeSessions.contains(a))
        #expect(!changeSessions.contains(b))
    }

    @Test func sameInstallationCanHaveIndependentHosts() async throws {
        let fixture = try BrokerFixture()
        let a = try await fixture.initialize("client-a")
        let b = try await fixture.initialize("client-b")
        let selection = try await fixture.call(a, name: NativeHostBroker.selectTool, arguments: [
            "hostIdentifier": .string(NativeHostBroker.defaultHostIdentifier),
            "createsNewHost": .bool(true),
        ])
        guard case .object(let value) = selection,
              case .object(let host)? = value["host"] else { Issue.record("missing selected host"); return }
        #expect(host["hostIdentifier"] != .string(NativeHostBroker.defaultHostIdentifier))
        #expect(host["developerDirectory"] == .string(fixture.defaultInstallation.developerDirectory.path))
        let left = try await fixture.echo(a)
        let right = try await fixture.echo(b)
        #expect(left != right)
        #expect(fixture.factory.transports.withLockedValue { $0.count } == 2)
    }

    @Test func admittedRequestsFinishOnTheirOriginalHostAfterSelectionChanges() async throws {
        let fixture = try BrokerFixture()
        let a = try await fixture.initialize("client-a")
        _ = try await fixture.echo(a)
        let original = try #require(fixture.factory.transports.withLockedValue { $0.first })
        let pending = Task { try await fixture.request(a, method: "tools/call", parameters: .object([
            "name": .string("Wait"), "arguments": .object([:]),
        ]), id: 71) }
        try await original.waiting.wait(description: "wait request admitted to original host")
        let available = try await fixture.list(a)
        let other = try #require(available.first { $0["isDefault"] == .bool(false) }?["hostIdentifier"])
        _ = try await fixture.call(a, name: NativeHostBroker.selectTool, arguments: ["hostIdentifier": other])
        await original.releaseWait()
        let result = try await pending.value
        guard case .object(let value) = result,
              case .object(let content)? = value["structuredContent"] else {
            Issue.record("missing wait result"); return
        }
        #expect(content["host"] == .number(.int(1)))
        #expect(try await fixture.echo(a) != .number(.int(1)))
    }

    @Test func numericCancellationStillReachesTheOldHostAfterSwitching() async throws {
        let fixture = try BrokerFixture()
        let a = try await fixture.initialize("client-a")
        _ = try await fixture.echo(a)
        let original = try #require(fixture.factory.transports.withLockedValue { $0.first })
        let pending = Task { try await fixture.reply(a, method: "tools/call", parameters: .object([
            "name": .string("Wait"), "arguments": .object([:]),
        ]), id: 73) }
        try await original.waiting.wait(description: "cancellable request admitted")
        _ = try await fixture.call(a, name: NativeHostBroker.selectTool, arguments: [
            "hostIdentifier": .string(NativeHostBroker.defaultHostIdentifier), "createsNewHost": .bool(true),
        ])
        _ = try await fixture.reply(a, method: "notifications/cancelled",
                                   parameters: .object(["requestId": .number(.int(73))]), id: nil)
        guard case .mcpError(_, -32800, _, _, _) = try await pending.value else {
            Issue.record("request was not cancelled"); return
        }
        try await original.cancelled.wait(description: "cancellation delivered to original host")
        let replacement = try #require(fixture.factory.transports.withLockedValue { $0.last })
        #expect(!replacement.cancelled.isSignaled())
    }

    @Test func serverRequestsKeepTheirOriginalChannelAfterSwitchingHosts() async throws {
        let fixture = try BrokerFixture()
        let a = try await fixture.initialize("client-a")
        let b = try await fixture.initialize("client-b")
        _ = try await fixture.echo(a)
        _ = try await fixture.echo(b)
        let original = try #require(fixture.factory.transports.withLockedValue { $0.first })
        let pending = Task { try await fixture.request(a, method: "tools/call", parameters: .object([
            "name": .string("Wait"), "arguments": .object([:]),
        ]), id: 77) }
        try await original.waiting.wait(description: "request owns original channel")
        _ = try await fixture.call(a, name: NativeHostBroker.selectTool, arguments: [
            "hostIdentifier": .string(NativeHostBroker.defaultHostIdentifier), "createsNewHost": .bool(true),
        ])
        try original.emitServerRequest()
        try await fixture.serverRequestDelivered.wait(description: "server request delivered after host switch")
        let requests = fixture.events.withLockedValue { values in
            values.compactMap { event -> (ProxySessionID, JSONRPC.ID)? in
                guard case .notification(let session, let data) = event,
                      let object = try? JSONRPC.Wire.object(fromData: data),
                      case .request("sampling/createMessage", let id) = JSONRPC.Message.Inspector.kind(of: object)
                else { return nil }
                return (session, id)
            }
        }
        #expect(requests.count == 1)
        let routed = try #require(requests.first)
        #expect(routed.0 == a)
        let response = try ProxyRuntimeRequest(json: .object([
            "jsonrpc": .string("2.0"), "id": routed.1.value, "result": .object([:]),
        ]), headerSessionExists: true, prefersEventStream: false)
        let operation = try #require(fixture.broker.beginRequest(response, in: a))
        _ = try await withCheckedThrowingContinuation { continuation in
            operation.whenComplete { continuation.resume(with: $0) }
        }
        fixture.broker.clientRequestFinished(a)
        try await original.serverResponseReceived.wait(description: "response returned to original host")
        #expect(original.serverResponseIDs.withLockedValue { $0 } == [.string("native-server-request")])
        let replacement = try #require(fixture.factory.transports.withLockedValue { $0.last })
        #expect(replacement.serverResponseIDs.withLockedValue { $0.isEmpty })
        await original.releaseWait()
        _ = try await pending.value
    }

    @Test func closingOneClientKeepsAnotherClientAndTheSharedHostAlive() async throws {
        let fixture = try BrokerFixture()
        let a = try await fixture.initialize("client-a")
        let b = try await fixture.initialize("client-b")
        _ = try await fixture.echo(a)
        _ = try await fixture.echo(b)
        let original = try #require(fixture.factory.transports.withLockedValue { $0.first })
        let pending = Task { try await fixture.reply(a, method: "tools/call", parameters: .object([
            "name": .string("Wait"), "arguments": .object([:]),
        ]), id: 79) }
        try await original.waiting.wait(description: "client request ready before close")
        fixture.broker.removeSession(a)
        guard case .mcpError(_, -32800, _, _, _) = try await pending.value else {
            Issue.record("closed client's request was not cancelled"); return
        }
        #expect(fixture.broker.sessionState(a) == .missing)
        #expect(try await fixture.echo(b) == .number(.int(1)))
    }

    @Test func malformedServerResponseDoesNotTrapOrCloseTheSession() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("client-a")
        let request = try ProxyRuntimeRequest(json: .object([
            "jsonrpc": .string("2.0"), "id": .string(":MA=="), "result": .object([:]),
        ]), headerSessionExists: true, prefersEventStream: false)
        let operation = try #require(fixture.broker.beginRequest(request, in: session))
        let reply = try await withCheckedThrowingContinuation { continuation in
            operation.whenComplete { continuation.resume(with: $0) }
        }
        fixture.broker.clientRequestFinished(session)
        guard case .mcpError = reply else { Issue.record("invalid channel identifier was accepted"); return }
        #expect(try await fixture.echo(session) == .number(.int(1)))
    }

    @Test func activeRequestsPreventSessionExpiry() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("client-a")
        _ = try await fixture.echo(session)
        let original = try #require(fixture.factory.transports.withLockedValue { $0.first })
        let pending = Task { try await fixture.request(session, method: "tools/call", parameters: .object([
            "name": .string("Wait"), "arguments": .object([:]),
        ]), id: 83) }
        try await original.waiting.wait(description: "request active during expiry")
        fixture.broker.expireInactiveSessions(inactiveFor: .nanoseconds(1))
        #expect(fixture.broker.sessionState(session) == .initialized(protocolVersion: MCPProtocolVersion.current))
        await original.releaseWait()
        _ = try await pending.value
    }

    @Test func eventStreamsKeepIdleSessionsAliveUntilTheyClose() async throws {
        let fixture = try BrokerFixture()
        let session = try await fixture.initialize("client-a")
        #expect(fixture.broker.clientEventStreamOpened(session))
        fixture.broker.expireInactiveSessions(inactiveFor: .nanoseconds(1))
        #expect(fixture.broker.sessionState(session) == .initialized(protocolVersion: MCPProtocolVersion.current))
        fixture.broker.clientEventStreamClosed(session)
        fixture.broker.expireInactiveSessions(inactiveFor: .nanoseconds(1))
        #expect(fixture.broker.sessionState(session) == .missing)
        #expect(!fixture.broker.clientEventStreamOpened(session))
    }

    @Test func failureKeepsThePreviousSelectionAndManagementToolsRemainAvailable() async throws {
        let fixture = try BrokerFixture()
        let a = try await fixture.initialize("client-a")
        fixture.factory.failNewHosts.withLockedValue { $0 = true }
        let available = try await fixture.list(a)
        let other = try #require(available.first { $0["isDefault"] == .bool(false) }?["hostIdentifier"])
        let result = try await fixture.request(a, method: "tools/call", parameters: .object([
            "name": .string(NativeHostBroker.selectTool), "arguments": .object(["hostIdentifier": other]),
        ]))
        guard case .object(let value) = result else { Issue.record("missing failed selection"); return }
        #expect(value["isError"] == .bool(true))
        let current = try await fixture.list(a)
        #expect(current.first { $0["isSelected"] == .bool(true) }?["hostIdentifier"] == .string(NativeHostBroker.defaultHostIdentifier))
        fixture.factory.failNewHosts.withLockedValue { $0 = false }
        _ = try await fixture.call(a, name: NativeHostBroker.selectTool, arguments: ["hostIdentifier": other])
        #expect(try await fixture.echo(a) == .number(.int(1)))
    }
}

private final class BrokerTransport: UpstreamSlotControlling, Sendable {
    let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    let waiting = TestSignal()
    let cancelled = TestSignal()
    let serverResponseReceived = TestSignal()
    let serverResponseIDs = NIOLockedValueBox<[JSONValue]>([])
    let index: Int64
    private let pending = NIOLockedValueBox<[JSONRPC.ID]>([])

    init(index: Int64) {
        self.index = index
        let pair = AsyncStream<Upstream.Event>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }
    func start() async {}
    func stop() async { continuation.finish() }

    func send(_ data: Data) async -> Upstream.SendResult {
        do {
            let object = try JSONRPC.Wire.object(fromData: data)
            if case .response(let id) = JSONRPC.Message.Inspector.kind(of: object) {
                serverResponseIDs.withLockedValue { $0.append(id.value) }
                serverResponseReceived.signal()
                return .accepted
            }
            let method = object["method"] as? String
            if method == "notifications/cancelled" { cancelled.signal(); return .accepted }
            guard let id = JSONRPC.Message.Inspector.requestID(from: object) else { return .accepted }
            let result: JSONValue
            switch method {
            case "initialize":
                result = .object(["protocolVersion": .string(MCPProtocolVersion.current),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object(["name": .string("Native-\(index)"), "version": .string("1")])])
            case "tools/list":
                result = .object(["tools": .array(["Echo-\(index)", "Wait"].map { name in
                    .object(["name": .string(name), "description": .string(name),
                        "inputSchema": .object(["type": .string("object"), "properties": .object([:])])])
                }), "_meta": .object(["com.lynnswap.xcode-mcpkit/origin": .object([
                    "kind": .string("nativeHost"), "processID": .number(.int(1000 + index)),
                ])])])
            case "tools/call":
                let parameters = object["params"] as? [String: Any]
                if parameters?["name"] as? String == "Wait" {
                    pending.withLockedValue { $0.append(id) }
                    waiting.signal()
                    return .accepted
                }
                result = echoResult
            default: result = .object([:])
            }
            continuation.yield(.message(try JSONRPC.Wire.resultResponseData(id: id, result: result)))
        } catch { Issue.record(error) }
        return .accepted
    }

    func emitServerRequest() throws {
        continuation.yield(.message(try JSONRPC.Wire.data(from: [
            "jsonrpc": "2.0", "id": "native-server-request",
            "method": "sampling/createMessage", "params": [String: Any](),
        ])))
    }

    private var echoResult: JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string("host \(index)")])]),
            "structuredContent": .object(["host": .number(.int(index))]), "isError": .bool(false)])
    }
    func releaseWait() async {
        for id in pending.withLockedValue({ values in let ids = values; values.removeAll(); return ids }) {
            do { continuation.yield(.message(try JSONRPC.Wire.resultResponseData(id: id, result: echoResult))) }
            catch { Issue.record(error) }
        }
    }
}

private final class BrokerRuntimeFactory: Sendable {
    let transports = NIOLockedValueBox<[BrokerTransport]>([])
    let failNewHosts = NIOLockedValueBox(false)
    func make(_ configuration: ProxyRuntimeConfiguration) throws -> any ProxyRuntimeServing {
        if failNewHosts.withLockedValue({ $0 }) { throw NativeHostBrokerError("fixture startup failed") }
        let upstream = transports.withLockedValue { values in
            let transport = BrokerTransport(index: Int64(values.count + 1))
            values.append(transport)
            return transport
        }
        return ProxyRuntime.testing(configuration: configuration) { eventLoop, notification, closed in
            RuntimeCoordinator(config: configuration, eventLoop: eventLoop, upstreams: [upstream],
                notificationSink: notification, sessionClosedSink: closed, startImmediately: false)
        }
    }
}

private final class BrokerFixture: Sendable {
    let broker: NativeHostBroker
    let factory = BrokerRuntimeFactory()
    let events = NIOLockedValueBox<[ProxyRuntimeEvent]>([])
    let serverRequestDelivered = TestSignal()
    let defaultInstallation = XcodeHostInstallation(developerDirectory: URL(fileURLWithPath: "/Fixture/Default.app"))

    init() throws {
        let factory = factory
        let events = events
        let defaultInstallation = defaultInstallation
        let inventory = XcodeHostInventory(defaultInstallation: defaultInstallation) {
            [defaultInstallation, XcodeHostInstallation(developerDirectory: URL(fileURLWithPath: "/Fixture/Other.app"))]
        }
        broker = try NativeHostBroker(configuration: makeConfig(requestTimeout: 5),
                                  inventory: inventory, factory: factory.make)
        let delivered = serverRequestDelivered
        let cancel = broker.subscribeToEvents { event in
            events.withLockedValue { $0.append(event) }
            if case .notification(_, let data) = event,
               let object = try? JSONRPC.Wire.object(fromData: data),
               case .request("sampling/createMessage", _) = JSONRPC.Message.Inspector.kind(of: object) {
                delivered.signal()
            }
        }
        let broker = broker
        #expect(registerAsyncTestCleanup(description: "broker shutdown") {
            await broker.shutdown()
            cancel()
        })
    }

    func initialize(_ name: String) async throws -> ProxySessionID {
        let id = ProxySessionID(rawValue: name)
        _ = try await request(id, method: "initialize", parameters: .object([
            "protocolVersion": .string(MCPProtocolVersion.current),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string(name), "version": .string("1")]),
        ]))
        return id
    }

    func reply(_ session: ProxySessionID, method: String, parameters: JSONValue? = nil,
               id: Int64? = 19) async throws -> ProxyRuntimeReply {
        var json: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let id { json["id"] = .number(.int(id)) }
        if let parameters { json["params"] = parameters }
        let request = try ProxyRuntimeRequest(json: .object(json),
            headerSessionExists: method != "initialize", prefersEventStream: false)
        let operation = try #require(broker.beginRequest(request, in: session))
        defer { broker.clientRequestFinished(session) }
        return try await waitWithTimeout("broker request", timeout: .seconds(10)) {
            try await withCheckedThrowingContinuation { continuation in
                operation.whenComplete { continuation.resume(with: $0) }
            }
        }
    }

    func request(_ session: ProxySessionID, method: String, parameters: JSONValue? = nil,
                 id: Int64? = 19) async throws -> JSONValue {
        try NativeHostBroker.result(in: await reply(session, method: method, parameters: parameters, id: id))
    }
    func call(_ session: ProxySessionID, name: String,
              arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let result = try await request(session, method: "tools/call", parameters: .object([
            "name": .string(name), "arguments": .object(arguments),
        ]))
        guard case .object(let object) = result, case .object(let content)? = object["structuredContent"] else {
            throw NativeHostBrokerError("missing tool result")
        }
        return .object(content)
    }
    func list(_ session: ProxySessionID) async throws -> [[String: JSONValue]] {
        let value = try await call(session, name: NativeHostBroker.listTool)
        guard case .object(let object) = value, case .array(let hosts)? = object["hosts"] else {
            throw NativeHostBrokerError("missing host list")
        }
        return hosts.compactMap { if case .object(let fields) = $0 { fields } else { nil } }
    }
    func echo(_ session: ProxySessionID) async throws -> JSONValue {
        let catalog = try await request(session, method: "tools/list")
        guard case .object(let object) = catalog, case .array(let tools)? = object["tools"],
              let name = tools.compactMap({ value -> String? in
                  guard case .object(let fields) = value, case .string(let name)? = fields["name"],
                        name.hasPrefix("Echo-") else { return nil }
                  return name
              }).first else { throw NativeHostBrokerError("missing echo tool") }
        let value = try await call(session, name: name)
        guard case .object(let fields) = value, let host = fields["host"] else {
            throw NativeHostBrokerError("missing host identity")
        }
        return host
    }
}
