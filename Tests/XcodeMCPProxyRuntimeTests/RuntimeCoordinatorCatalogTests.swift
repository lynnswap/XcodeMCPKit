@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

@Suite(.serialized, .asyncTestCleanup)
struct RuntimeCoordinatorCatalogTests {
    @Test func catalogRPCErrorPreservesConnectionForAnotherRequest() async throws {
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let fixture = RuntimeCoordinatorFixture(
            config: config, upstreams: [upstream],
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        seedCoordinatorSuiteInitialize(
            on: manager, result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]),
            sourceUpstream: 0
        )
        let operationLease = manager.operationLeaseForTest(upstreamIndex: 0)
        manager.markRequestTimedOut(operationLease)
        let first = Task { try await manager.sharedToolsList(sessionID: "catalog-rpc-error", requestTimeoutOverride: .seconds(2)) }
        let failedRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        await upstream.yield(.message(try JSONRPC.Wire.errorResponseData(
            id: JSONRPC.ID(any: extractUpstreamID(from: failedRequest)), code: -32603, message: "catalog is warming"
        )))
        do {
            _ = try await first.value
            Issue.record("catalog error must reach the caller")
        } catch {
            let mapped = ControlPlane.ErrorMapper.jsonRPCError(for: error)
            #expect(mapped.code == -32603)
            #expect(mapped.message == "catalog is warming")
        }
        #expect(manager.isInitialized())
        manager.markRequestTimedOut(operationLease)
        manager.markRequestTimedOut(operationLease)
        let offset = await upstream.sentCount()
        let second = Task { try await manager.sharedToolsList(sessionID: "catalog-rpc-error", requestTimeoutOverride: .seconds(2)) }
        let retry = try await sentValue(from: upstream, at: offset, timeout: .seconds(1))
        #expect(methodName(from: retry) == "tools/list")
        await upstream.yield(.message(try paginatedToolsResponse(request: retry, names: ["DocumentationSearch"])))
        #expect(toolNames(in: try await second.value) == ["DocumentationSearch"])
    }

    @Test(arguments: ["malformed", "both", "missing-code", "invalid-method", "missing-payload", "unavailable", "overloaded"])
    func catalogInvalidAndProxyFailureRepliesStillInvalidateConnection(kind: String) async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        seedCoordinatorSuiteInitialize(
            on: manager, result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]), sourceUpstream: 0
        )
        let load = Task { try await manager.sharedToolsList(sessionID: "invalid-catalog", requestTimeoutOverride: .seconds(2)) }
        let request = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        var object: [String: Any] = ["jsonrpc": "2.0", "id": try extractUpstreamID(from: request)]
        switch kind {
        case "malformed": object["error"] = "garbage"
        case "both":
            object["result"] = ["tools": []]
            object["error"] = ["code": -32603, "message": "invalid envelope"]
        case "missing-code": object["error"] = ["message": "missing code"]
        case "invalid-method": object["method"] = 1
        case "missing-payload": break
        case "unavailable": object["error"] = ["code": -32001, "message": "upstream unavailable"]
        default: object["error"] = ["code": -32002, "message": "upstream overloaded"]
        }
        await upstream.yield(.message(try JSONRPC.Wire.data(from: object)))
        do {
            _ = try await load.value
            Issue.record("invalid or unavailable catalog must fail")
        } catch {
            let mapped = ControlPlane.ErrorMapper.jsonRPCError(for: error)
            #expect(mapped.code == (kind == "unavailable" ? -32001 : kind == "overloaded" ? -32002 : -32603))
        }
        let health = try #require(manager.upstreamHealthManager.state(for: UpstreamSlotID(rawValue: 0)))
        guard case .quarantined = health.healthState else {
            Issue.record("invalid protocol and proxy availability failures must retain quarantine")
            return
        }
    }

    @Test func explicitCatalogRequestDiscoversToolsWithoutChangeNotification() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        _ = try await fixture.initializePrimary(on: upstream, sessionID: "refresh")

        for names in [["BuildProject"], ["BuildProject", "DocumentationSearch"], ["BuildProject"]] {
            let offset = await upstream.sentCount()
            let load = Task {
                try await fixture.manager.sharedToolsList(
                    sessionID: "refresh",
                    requestTimeoutOverride: .seconds(5)
                )
            }
            let request = try await sentValue(from: upstream, at: offset, timeout: .seconds(2))
            await upstream.yield(.message(try paginatedToolsResponse(request: request, names: names)))
            #expect(Set(toolNames(in: try await load.value)) == Set(names))
            #expect(Set(toolNames(in: try #require(fixture.manager.cachedToolsListResult()))) == Set(names))
        }
    }

    @Test func paginatedCatalogKeepsCursorOnTheFirstUpstream() async throws {
        let first = TestUpstreamClient()
        let second = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [first, second], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]),
            sourceUpstream: 0
        )
        let load = Task {
            try await manager.loadCanonicalToolsCatalog(requestTimeout: .seconds(5), rpcHandle: .init())
        }
        let firstPage = try await sentValue(from: first, at: 0, timeout: .seconds(2))
        await first.yield(.message(try paginatedToolsResponse(request: firstPage, names: ["First"], nextCursor: .string("second"))))
        let lastPage = try await sentValue(from: first, at: 1, timeout: .seconds(2))
        #expect(await second.sent().filter { methodName(from: $0) != "notifications/cancelled" }.count == 0)
        await first.yield(.message(try paginatedToolsResponse(request: lastPage, names: ["Last"])))
        let catalog = try await load.value
        #expect(Set(toolNames(in: catalog.rawResult)) == Set(["First", "Last"]))
        #expect(catalog.sourceProof?.slotID.rawValue == 0)
    }

    @Test func paginatedCatalogCollectsEveryPageAndReloadsAfterChange() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        _ = try await fixture.initializePrimary(on: upstream, sessionID: "pagination")
        let manager = fixture.manager

        for iteration in 0..<2 {
            let load = Task {
                try await manager.sharedToolsList(sessionID: "pagination", requestTimeoutOverride: .seconds(5))
            }
            let offset = 2 + iteration * 2
            let first = try await sentValue(from: upstream, at: offset, timeout: .seconds(2))
            let firstObject = try #require(try JSONSerialization.jsonObject(with: first) as? [String: Any])
            #expect(firstObject["params"] == nil)
            await upstream.yield(.message(try paginatedToolsResponse(
                request: first, names: ["First\(iteration)"], nextCursor: .string("opaque / token?=α")
            )))
            let second = try await sentValue(from: upstream, at: offset + 1, timeout: .seconds(2))
            let object = try #require(try JSONSerialization.jsonObject(with: second) as? [String: Any])
            #expect((object["params"] as? [String: Any])?["cursor"] as? String == "opaque / token?=α")
            #expect(manager.cachedToolsListResult() == nil)
            await upstream.yield(.message(try paginatedToolsResponse(request: second, names: ["Last\(iteration)"])))
            let result = try await load.value
            #expect(Set(toolNames(in: result)) == Set(["First\(iteration)", "Last\(iteration)"]))
            if case .object(let object) = result { #expect(object["nextCursor"] == nil) }
            #expect(manager.cachedToolsListResult() != nil)
            if iteration == 0 {
                manager.routeUpstreamMessage(
                    try JSONRPC.Wire.data(from: JSONRPC.Wire.notificationObject(method: "notifications/tools/list_changed")),
                    upstreamIndex: 0
                )
                #expect(manager.cachedToolsListResult() == nil)
            }
        }
    }

    @Test(arguments: [JSONValue.string("again"), .number(.int(7)), .null])
    func paginatedCatalogRejectsInvalidContinuationWithoutPublishingPartialCatalog(nextCursor: JSONValue) async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        _ = try await fixture.initializePrimary(on: upstream)
        let load = Task {
            try await fixture.manager.loadCanonicalToolsCatalog(requestTimeout: .seconds(5), rpcHandle: .init())
        }
        let first = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        await upstream.yield(.message(try paginatedToolsResponse(request: first, names: ["First"], nextCursor: .string("again"))))
        let second = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        await upstream.yield(.message(try paginatedToolsResponse(request: second, names: ["Second"], nextCursor: nextCursor)))
        await #expect(throws: ControlPlane.Error.self) { _ = try await load.value }
        #expect(fixture.manager.cachedToolsListResult() == nil)
        #expect(await upstream.sent().filter { methodName(from: $0) != "notifications/cancelled" }.count == 4)
    }

    @Test func paginatedCatalogPreservesPageError() async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        _ = try await fixture.initializePrimary(on: upstream)
        let load = Task {
            try await fixture.manager.loadCanonicalToolsCatalog(requestTimeout: .seconds(5), rpcHandle: .init())
        }
        let first = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        await upstream.yield(.message(try paginatedToolsResponse(request: first, names: ["First"], nextCursor: .string(""))))
        let second = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        await upstream.yield(.message(try JSONRPC.Wire.data(from: JSONRPC.Wire.errorResponseObject(
            id: JSONRPC.ID(any: try extractUpstreamID(from: second)), code: -32602, message: "expired cursor"
        ))))
        do {
            _ = try await load.value
            Issue.record("page error must fail the catalog load")
        } catch ControlPlane.Error.upstreamRPC(let code, let message) {
            #expect(code == -32602)
            #expect(message == "expired cursor")
        }
        #expect(fixture.manager.cachedToolsListResult() == nil)
    }

    @Test(arguments: [false, true])
    func paginatedCatalogDistinguishesProviderAndCallerCancellation(cancelCaller: Bool) async throws {
        let upstream = TestUpstreamClient()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream])
        defer { fixture.shutdownAndWait() }
        _ = try await fixture.initializePrimary(on: upstream)
        let handle = ControlPlane.RPCHandle()
        let load = Task {
            try await fixture.manager.loadCanonicalToolsCatalog(requestTimeout: .seconds(5), rpcHandle: handle)
        }
        let first = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        await upstream.yield(.message(try paginatedToolsResponse(request: first, names: ["First"], nextCursor: .string("second"))))
        let second = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        if cancelCaller { load.cancel() }
        let delivery = try #require(handle.cancel())
        _ = await delivery.wait()
        if cancelCaller {
            await #expect(throws: CancellationError.self) { _ = try await load.value }
        } else {
            await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) { _ = try await load.value }
        }
        let cancellation = try await sentValue(from: upstream, at: 4, timeout: .seconds(2))
        #expect(try extractCancellationRequestID(from: cancellation) == extractUpstreamID(from: second))
        #expect(fixture.manager.cachedToolsListResult() == nil)
        #expect(fixture.manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func paginatedCatalogDoesNotResetDeadlineForNextPage() async throws {
        let upstream = TestUpstreamClient()
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let fixture = RuntimeCoordinatorFixture(upstreams: [upstream], clock: clocks.clock)
        defer { fixture.shutdownAndWait() }
        _ = try await fixture.initializePrimary(on: upstream)
        let load = Task {
            try await fixture.manager.loadCanonicalToolsCatalog(requestTimeout: .seconds(5), rpcHandle: .init())
        }
        let first = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        clocks.uptimeClock.advance(by: .seconds(6))
        await upstream.yield(.message(try paginatedToolsResponse(request: first, names: ["First"], nextCursor: .string("second"))))
        await #expect(throws: TimeoutError.self) { _ = try await load.value }
        #expect(fixture.manager.cachedToolsListResult() == nil)
        #expect(await upstream.sent().filter { methodName(from: $0) != "notifications/cancelled" }.count == 3)
    }


}
