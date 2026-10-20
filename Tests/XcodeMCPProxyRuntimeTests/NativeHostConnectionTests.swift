import Foundation
import Logging
import NIOConcurrencyHelpers
import Testing
import XcodeMCPCore
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyRuntimeContract
@testable import XcodeMCPProxyRuntimeTestSupport
import XcodeMCPProxyTestSupport

@Suite(.serialized, .timeLimit(.minutes(1)), .asyncTestCleanup)
struct NativeHostConnectionTests {
    private final class Fixture: Sendable {
        let factory: FakeHostSessionFactory
        let events = LockedRecordedValues<NativeHostConnection.Event>()
        let connection: NativeHostConnection

        init(factory: FakeHostSessionFactory = FakeHostSessionFactory(), handshakeTimeout: Duration? = nil,
             clock: ClockClient = .liveValue) {
            self.factory = factory
            let events = events
            connection = NativeHostConnection(
                factory: factory, handshake: .object(["protocolVersion": .string(MCPProtocolVersion.current),
                    "capabilities": .object([:]), "clientInfo": .object(["name": .string("test"), "version": .string("1")])]),
                handshakeTimeout: handshakeTimeout, catalogTimeout: nil, prewarmsCatalog: false, clock: clock,
                logger: Logger(label: "NativeHostConnectionTests")) { events.append($0) }
            let connection = connection
            #expect(registerAsyncTestCleanup(description: "connection shutdown") { await connection.shutdown() })
        }

        var session: FakeHostSession {
            get throws { try #require(factory.sessions.withLockedValue { $0.last }) }
        }

        func call(_ name: String, id: JSONValue = .number(.int(1)), owner: String = "client",
                  progressToken: JSONValue? = nil, generation: UInt64? = nil) async throws -> [String: JSONValue] {
            var params: [String: JSONValue] = ["name": .string(name), "arguments": .object([:])]
            if let progressToken { params["_meta"] = .object(["progressToken": progressToken]) }
            let data = try await connection.send(.object([
                "jsonrpc": .string("2.0"), "id": id, "method": .string("tools/call"), "params": .object(params),
            ]), owner: ProxySessionID(rawValue: owner), generation: generation)
            guard case .object(let object)? = (try? JSONSerialization.jsonObject(with: data)).flatMap(JSONValue.init(any:)) else {
                throw NativeHostBrokerError("The connection returned a non-object response")
            }
            return object
        }
    }

    @Test func requestsFromDifferentSessionsKeepTheirIDsAndProgress() async throws {
        let factory = FakeHostSessionFactory { _ in FakeHostSession { _, _ in .hold } }
        let fixture = Fixture(factory: factory)
        let first = Task { try await fixture.call("Build", owner: "a", progressToken: .string("token")) }
        try await factory.started.nextValue(at: 0).heldRequest.wait(description: "first request held")
        let second = Task { try await fixture.call("Build", owner: "b") }
        let host = try fixture.session
        try await waitWithTimeout("second request reached the host", timeout: .seconds(5)) {
            while host.requests("tools/call").count < 2 { await Task.yield() }
        }
        let upstreamIDs = host.requests("tools/call").compactMap { $0["id"] }
        #expect(Set(upstreamIDs.map { "\($0)" }).count == 2)
        guard case .object(let params)? = host.requests("tools/call").first?["params"],
              case .object(let meta)? = params["_meta"], let upstreamToken = meta["progressToken"] else {
            Issue.record("The progress token did not reach the host"); return
        }
        #expect(upstreamToken != .string("token"))
        host.emit(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/progress"),
                           "params": .object(["progressToken": upstreamToken, "progress": .number(.int(1))])]))
        host.release("tools/call", with: .result(.object(["content": .array([])])))
        #expect(try await first.value["id"] == .number(.int(1)))
        #expect(try await second.value["id"] == .number(.int(1)))
        guard case .notification(let owner, let data) = try await fixture.events.nextValue(at: 0) else {
            Issue.record("The progress notification was not routed"); return
        }
        #expect(owner == ProxySessionID(rawValue: "a"))
        let progress = try JSONRPC.Wire.object(fromData: data)
        #expect((progress["params"] as? [String: Any])?["progressToken"] as? String == "token")
    }

    @Test func cancellingARequestCancelsOnlyThatHostRequest() async throws {
        let factory = FakeHostSessionFactory { _ in
            FakeHostSession { _, params in params["name"] == .string("Build") ? .hold : .result(.object([:])) }
        }
        let fixture = Fixture(factory: factory)
        let cancelled = Task { try await fixture.call("Build", owner: "a") }
        let host = try await factory.started.nextValue(at: 0)
        try await host.heldRequest.wait(description: "request held")
        let upstreamID = try #require(host.requests("tools/call").first?["id"])
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await waitWithTimeout("cancellation reached the host", timeout: .seconds(5)) {
            while host.requests("notifications/cancelled").isEmpty { await Task.yield() }
        }
        guard case .object(let params)? = host.requests("notifications/cancelled").first?["params"] else {
            Issue.record("The cancellation has no parameters"); return
        }
        #expect(params["requestId"] == upstreamID)
        host.release("tools/call", with: .result(.object([:])))
        _ = try await fixture.call("Next")
    }

    @Test func processExitFailsInFlightRequestsAndTheNextRequestStartsANewProcess() async throws {
        let factory = FakeHostSessionFactory { start in
            FakeHostSession { _, _ in start == 0 ? .hold : .result(.object([:])) }
        }
        let fixture = Fixture(factory: factory)
        let pending = Task { try await fixture.call("Build") }
        let original = try await factory.started.nextValue(at: 0)
        try await original.heldRequest.wait(description: "request held")
        original.exit()
        await #expect(throws: NativeHostConnectionError.self) { try await pending.value }
        try await original.stopped.wait(description: "ended process stopped")
        guard case .processEnded(let generation) = try await fixture.events.nextValue(at: 0) else {
            Issue.record("The process end was not reported"); return
        }
        #expect(generation == 1)
        await #expect(throws: NativeHostConnectionError.self) { _ = try await fixture.call("Old", generation: 1) }
        #expect(try await fixture.connection.start() == 2)
        _ = try await fixture.call("New", generation: 2)
        #expect(factory.sessions.withLockedValue { $0.count } == 2)
    }

    @Test func inputBackpressureFailsOnlyThatRequest() async throws {
        let fixture = Fixture(factory: FakeHostSessionFactory { _ in
            FakeHostSession { _, params in params["name"] == .string("Refused") ? .backpressure : .result(.object([:])) }
        })
        await #expect(throws: NativeHostConnectionError.self) { _ = try await fixture.call("Refused") }
        #expect(fixture.connection.status.withLockedValue { $0.inFlightRequests } == 0)
        _ = try await fixture.call("Accepted")
        #expect(fixture.factory.sessions.withLockedValue { $0.count } == 1)
    }

    @Test func terminalCoreSimulatorDiagnosticEndsTheProcess() async throws {
        let factory = FakeHostSessionFactory { _ in FakeHostSession { _, _ in .hold } }
        let fixture = Fixture(factory: factory)
        let pending = Task { try await fixture.call("Build") }
        let host = try await factory.started.nextValue(at: 0)
        try await host.heldRequest.wait(description: "request held")
        host.emitStderr("2026-10-05 23:53:55.624 xcode-mcp-native-host[43311:36380528] CoreSimulatorService connection became invalid.  Simulator services will no longer be available.")
        await #expect(throws: NativeHostConnectionError.self) { try await pending.value }
        try await host.stopped.wait(description: "host stopped after the diagnostic")
    }

    @Test func failedInitializeReachesTheCallerAndALaterRequestRecovers() async throws {
        let factory = FakeHostSessionFactory { start in
            FakeHostSession(initializeReply: start == 0 ? .error(code: -32603, message: "no Xcode") : nil)
        }
        let fixture = Fixture(factory: factory)
        await #expect(throws: NativeHostConnectionError.self) { try await fixture.connection.start() }
        try await factory.started.nextValue(at: 0).stopped.wait(description: "failed process stopped")
        _ = try await fixture.call("Recovered")
        #expect(fixture.connection.status.withLockedValue { $0.phase } == .ready)
    }

    @Test func handshakeTimeoutFailsTheStartWithoutStrandingLaterCallers() async throws {
        let clocks = makeDeterministicClocks()
        let factory = FakeHostSessionFactory { start in
            FakeHostSession(initializeReply: start == 0 ? .hold : nil)
        }
        let fixture = Fixture(factory: factory, handshakeTimeout: .seconds(5), clock: clocks.clock)
        let starting = Task { try await fixture.connection.start() }
        try await factory.started.nextValue(at: 0).heldRequest.wait(description: "initialize held")
        try await waitForSuspendedSleepers(on: clocks.timeoutClock)
        clocks.timeoutClock.advance(by: .seconds(5))
        await #expect(throws: NativeHostConnectionError.self) { try await starting.value }
        #expect(try await fixture.connection.start() == 2)
    }

    @Test func catalogIsLoadedOncePerProcessAndReloadedAfterAChange() async throws {
        let catalog = JSONValue.object(["tools": .array([.object(["name": .string("First")])])])
        let factory = FakeHostSessionFactory { _ in FakeHostSession(tools: catalog) { _, _ in .result(.object([:])) } }
        let fixture = Fixture(factory: factory)
        async let first = fixture.connection.nativeCatalog()
        async let second = fixture.connection.nativeCatalog()
        #expect(try await first.result == catalog)
        #expect(try await second.result == catalog)
        let host = try fixture.session
        #expect(host.requests("tools/list").count == 1)
        let changed = JSONValue.object(["tools": .array([.object(["name": .string("Second")])])])
        host.setTools(changed)
        host.emit(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed")]))
        // A response emitted after the change is processed after it.
        _ = try await fixture.call("Barrier")
        #expect(try await fixture.connection.nativeCatalog().result == changed)
        #expect(host.requests("tools/list").count == 2)
    }

    @Test func hostPingIsAnsweredWithoutReachingClients() async throws {
        let fixture = Fixture()
        try await fixture.connection.start()
        let host = try fixture.session
        host.emit(.object(["jsonrpc": .string("2.0"), "id": .string("host-ping"), "method": .string("ping")]))
        try await waitWithTimeout("ping answered", timeout: .seconds(5)) {
            while !host.received.withLockedValue({ $0.contains { message in
                guard case .object(let object) = message else { return false }
                return object["id"] == .string("host-ping") && object["result"] != nil
            } }) { await Task.yield() }
        }
        #expect(fixture.events.count() == 0)
    }
}
