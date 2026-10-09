@testable import XcodeMCPProxyRuntimeTestSupport
import XcodeMCPProxyRuntimeContract
@testable import XcodeMCPCore
import Foundation
import NIO
import NIOEmbedded
import NIOConcurrencyHelpers
import NIOHTTP1
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyHTTP
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

private func seedCanonicalInitializeForTesting(
    on manager: RuntimeCoordinator,
    result: JSONValue,
    sourceUpstream: Int
) {
    let slotID = UpstreamSlotID(rawValue: sourceUpstream)
    guard let health = manager.upstreamHealthManager.state(for: slotID),
          health.isInitialized,
          case .healthy = health.healthState else {
        preconditionFailure("canonical initialize fixture requires a healthy initialized source")
    }
    let proof = manager.operationLeaseForTest(upstreamIndex: sourceUpstream).proof
    guard case .accepted(let participant) = manager.canonicalHandshakeState
        .offerInitializeResult(result, sourceProof: proof) else {
        preconditionFailure("canonical initialize fixture result is incompatible")
    }
    switch manager.canonicalHandshakeState.commitInitializeParticipant(participant) {
    case .published, .joined:
        return
    case .incompatible, .stale:
        preconditionFailure("canonical initialize fixture commit was rejected")
    }
}

@Suite(.serialized, .asyncTestCleanup)
struct HTTPConcurrencyTests {
    @Test(arguments: ["BuildProject", "FutureNativeTool"])
    func nativeToolCallsPreserveWorkspacePathsAndProviderErrors(toolName: String) async throws {
        let upstream = NativeWorkspaceUpstream()
        let server = try TestHTTPServer.start(upstream: upstream)
        do {
            let (initialized, _) = try await postJSON(url: server.url, sessionID: nil, payload: initializePayload(id: 1))
            let sessionID = try #require(initialized.value(forHTTPHeaderField: "Mcp-Session-Id"))
            let (_, catalog) = try await postJSON(url: server.url, sessionID: sessionID, payload: toolListPayload(id: 2))
            let tools = try #require((catalog["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            let schema = try #require(tools.first?["inputSchema"] as? [String: Any])
            #expect((schema["properties"] as? [String: Any])?.keys.sorted() == ["workspaceIdentifier"])
            #expect(schema["required"] as? [String] == ["workspaceIdentifier"])
            let workspace = "/Work/Project with spaces.xcodeproj"
            let (_, reply) = try await postJSON(url: server.url, sessionID: sessionID,
                payload: toolCallPayload(id: 3, name: toolName, arguments: ["workspaceIdentifier": workspace]))
            let result = try #require(reply["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == true)
            #expect((result["structuredContent"] as? [String: Any])?["workspaceIdentifier"] as? String == workspace)
            #expect(await upstream.recordedCalls() == [toolName])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }


    @Test func httpAndSwiftClientExposeCompletePaginatedCatalog() async throws {
        let upstream = PaginatedCatalogUpstream()
        let server = try TestHTTPServer.start(upstream: upstream)
        do {
            let client = try await XcodeMCP(configuration: .init(
                transport: .streamableHTTP(endpoint: server.url), requestTimeout: .seconds(5)
            ))
            do {
                let tools = try await client.listTools()
                #expect(Set(tools.map(\.name)) == Set(["FirstPage", "LastPage"]))
                let firstCursors = await upstream.cursors()
                #expect(Array(firstCursors.suffix(2)) == [nil, "opaque / token?=α"])
                let (response, _) = try await postJSON(url: server.url, sessionID: nil, payload: initializePayload(id: 100))
                let sessionID = try #require(response.value(forHTTPHeaderField: "Mcp-Session-Id"))
                let (toolsResponse, body) = try await postJSON(url: server.url, sessionID: sessionID, payload: toolListPayload(id: 101))
                #expect(toolsResponse.statusCode == 200)
                let result = try #require(body["result"] as? [String: Any])
                let descriptors = try #require(result["tools"] as? [[String: Any]])
                #expect(Set(descriptors.compactMap { $0["name"] as? String }) == Set(["FirstPage", "LastPage"]))
                #expect(result["nextCursor"] == nil)
                let refreshedCursors = await upstream.cursors()
                #expect(Array(refreshedCursors.suffix(2)) == [nil, "opaque / token?=α"])
                #expect(refreshedCursors.count == firstCursors.count + 2)
            } catch {
                await client.close()
                throw error
            }
            await client.close()
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test(arguments: ["ExecuteSnippet", "XcodeListWorkspaces"])
    func httpCancellationDoesNotWaitBehindTheRequest(toolName: String) async throws {
        let upstream = ControlledUpstreamClient()
        let server = try TestHTTPServer.start(upstream: upstream, requestTimeout: 60)
        do {
            let (initialized, _) = try await postJSON(url: server.url, sessionID: nil, payload: initializePayload(id: 1))
            let sessionID = try #require(initialized.value(forHTTPHeaderField: "Mcp-Session-Id"))
            await drainInitialToolsCatalogWarmupIfNeeded(server: server, upstream: upstream)
            await upstream.clearRecordedRequests()
            async let request = postStatusOnly(
                url: server.url, sessionID: sessionID,
                payload: toolCallPayload(id: 991, name: toolName, arguments: [:]), timeout: 2
            )
            _ = try await upstream.waitForNonInitializeRequest(label: "tools/call:\(toolName)")
            let cancellation = try await postStatusOnly(
                url: server.url, sessionID: sessionID,
                payload: cancellationPayload(id: 991), timeout: 2
            )
            #expect(cancellation.statusCode == 202)
            #expect(try await request.statusCode == 202)

        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test(arguments: [false, true])
    func cancelledLeaseCannotBeQueuedAfterCancellation(upstreamBusy: Bool) async throws {
        let (manager, _, loop, _) = try cancellationFixture(upstreamCount: 1)
        defer { manager.shutdownAndWait() }
        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "cancel-session", label: "tools/call:ExecuteSnippet",
            expectsResponse: true, isTopLevelClientRequest: true
        )
        let blocker = loop.makePromise(of: Void.self)
        let blockerLease = manager.createRequestLease(descriptor: descriptor)
        if upstreamBusy {
            let future: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
                leaseID: blockerLease, descriptor: descriptor, on: loop
            ) { _ in blocker.futureResult }
            future.whenFailure { _ in }
            await loop.run()
        }
        let cancelledLease = manager.createRequestLease(descriptor: descriptor)
        manager.abandonRequestLease(
            cancelledLease, sessionID: "cancel-session", requestIDKeys: [], operationLease: nil
        )
        let cancelled: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: cancelledLease, descriptor: descriptor, on: loop
        ) { _ in
            Issue.record("a settled lease must never acquire an upstream")
            return loop.makeSucceededFuture(())
        }
        await loop.run()
        await #expect(throws: CancellationError.self) { try await cancelled.get() }
        #expect(manager.debugSnapshot().queuedRequestCount == 0)
        manager.completeRequestLease(blockerLease)
        blocker.succeed(())
        await loop.run()
        let nextLease = manager.createRequestLease(descriptor: descriptor)
        let next: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: nextLease, descriptor: descriptor, on: loop
        ) { _ in loop.makeSucceededFuture(()) }
        await loop.run()
        try await next.get()
        manager.completeRequestLease(nextLease)
        #expect(manager.upstreamSlotScheduler.debugSnapshot().activeLeaseCountByUpstream.isEmpty)
    }

    @Test func cancellationDuringAdmissionPreventsDispatch() async throws {
        let onQueued = NIOLockedValueBox<(@Sendable () -> Void)?>(nil)
        let (manager, service, loop, upstreams) = try cancellationFixture(
            upstreamCount: 1,
            testHooks: RuntimeCoordinatorTestHooks(upstreamRequestQueued: { _, _, _ in
                let action = onQueued.withLockedValue { action in
                    defer { action = nil }
                    return action
                }
                action?()
            })
        )
        defer { manager.shutdownAndWait() }
        let cancellationData = try JSONSerialization.data(withJSONObject: cancellationPayload(id: 991))
        onQueued.withLockedValue { action in
            action = {
                _ = service.handle(
                    request: .init(data: cancellationData, headerSessionExists: true, prefersEventStream: false),
                    headerSessionID: "cancel-session", eventLoop: loop
                )
            }
        }
        let operation = try cancellationOperation(
            executeSnippetPayload(id: 991, workspaceIdentifier: "/Work/Cancel.xcodeproj"), service: service, loop: loop
        )
        await loop.run()
        await manager.drainRuntimeTasksForTesting()
        await loop.run()
        guard case .empty(.accepted, _) = try await operation.future.get() else {
            Issue.record("cancellation during admission must finish the original request")
            return
        }
        #expect(upstreams[0].recordedMessages().isEmpty)
        #expect(manager.debugSnapshot().queuedRequestCount == 0)
    }

    @Test func cancellationUsesTheOriginalUpstreamAndRewrittenID() async throws {
        let (manager, service, loop, upstreams) = try cancellationFixture(upstreamCount: 2)
        defer { manager.shutdownAndWait() }
        let operation = try cancellationOperation(
            executeSnippetPayload(id: 991, workspaceIdentifier: "/Work/Cancel.xcodeproj"),
            service: service, loop: loop
        )
        await loop.run()
        await manager.drainRuntimeTasksForTesting()
        let sendDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while upstreams.allSatisfy({ $0.recordedMessages().isEmpty }) {
            await loop.run()
            guard ContinuousClock.now < sendDeadline else { throw AsyncTestTimeoutError(description: "waiting for routed request") }
            await Task.yield()
        }
        let ownerIndex = try #require(upstreams.indices.first { !upstreams[$0].recordedMessages().isEmpty })
        let owner = upstreams[ownerIndex]
        _ = try await waitForUpstreamRequestCount(owner, count: 1)
        let original = try #require(owner.recordedMessages().first)
        let requestID = try #require(MCPJSONValue(original).objectValue?["id"])
        #expect(requestID != .integer(991))

        let cancellation = try cancellationOperation(cancellationPayload(id: 991), service: service, loop: loop)
        await loop.run()
        await manager.drainRuntimeTasksForTesting()
        _ = try await waitForUpstreamRequestCount(owner, count: 2)
        await loop.run()
        let message = try #require(owner.recordedMessages().last)
        let params = try #require(MCPJSONValue(message).objectValue?["params"]?.objectValue)
        #expect(params["requestId"] == requestID)
        #expect(upstreams[1 - ownerIndex].recordedMessages().isEmpty)
        guard case .empty(.accepted, _) = try await cancellation.future.get(),
              case .empty(.accepted, _) = try await operation.future.get() else {
            Issue.record("cancelled requests must finish without a JSON-RPC result")
            return
        }
        #expect(manager.debugSnapshot().queuedRequestCount == 0)
    }

    @Test func multiplexedCancellationPreservesOtherSessionsAndIDScalarTypes() async throws {
        let (manager, service, loop, upstreams) = try cancellationFixture(upstreamCount: 1)
        defer { manager.shutdownAndWait() }
        let upstream = upstreams[0]
        let active = try cancellationOperation(
            executeSnippetPayload(id: 1, workspaceIdentifier: "/Work/Active.xcodeproj"), service: service, loop: loop
        )
        await loop.run()
        await manager.drainRuntimeTasksForTesting()
        _ = try await waitForUpstreamRequestCount(upstream, count: 1)
        var stringIDBody = executeSnippetPayload(id: 2, workspaceIdentifier: "/Work/Queued.xcodeproj")
        stringIDBody["id"] = "1"
        let stringIDRequest = try cancellationOperation(stringIDBody, service: service, loop: loop)
        let sendDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while upstream.recordedMessages().filter({ MCPJSONValue($0).objectValue?["method"] == .string("tools/call") }).count < 2 {
            await loop.run()
            guard ContinuousClock.now < sendDeadline else { throw AsyncTestTimeoutError(description: "waiting for both multiplexed requests to be sent") }
            await Task.yield()
        }
        await manager.drainRuntimeTasksForTesting()
        #expect(manager.debugSnapshot().queuedRequestCount == 0)

        _ = try cancellationOperation(cancellationPayload(id: 1), service: service, loop: loop, sessionID: "other-session")
        _ = try cancellationOperation(cancellationPayload(id: true), service: service, loop: loop)
        _ = try cancellationOperation(cancellationPayload(id: 999), service: service, loop: loop)
        _ = try cancellationOperation(cancellationPayload(id: "1"), service: service, loop: loop)
        await loop.run()
        await manager.drainRuntimeTasksForTesting()
        await loop.run()
        guard case .empty(.accepted, _) = try await stringIDRequest.future.get() else {
            Issue.record("string ID request was not cancelled")
            return
        }
        #expect(upstream.recordedMessages().filter { MCPJSONValue($0).objectValue?["method"] == .string("tools/call") }.count == 2)
        #expect(manager.debugSnapshot().queuedRequestCount == 0)

        let response = try #require(upstream.takeNextResponse(label: "tools/call:ExecuteSnippet"))
        manager.routeUpstreamMessage(response, upstreamIndex: 0)
        await loop.run()
        guard case .responseData = try await active.future.get() else {
            Issue.record("cancellation affected the numeric ID or another session")
            return
        }
        _ = try cancellationOperation(cancellationPayload(id: 1), service: service, loop: loop)
        await loop.run()
        #expect(upstream.recordedMessages().filter { MCPJSONValue($0).objectValue?["method"] == .string("tools/call") }.count == 2)
    }

    private func cancellationPayload(id: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": id]]
    }

    private func cancellationOperation(
        _ payload: [String: Any], service: ClientMCPRequestExecutor, loop: NIOAsyncTestingEventLoop,
        sessionID: String = "cancel-session", requestTimeoutOverride: TimeAmount? = nil
    ) throws -> ClientMCPRequestExecutor.Operation {
        service.handle(
            request: .init(data: try JSONSerialization.data(withJSONObject: payload),
                headerSessionExists: true, prefersEventStream: false),
            headerSessionID: sessionID, eventLoop: loop,
            requestTimeoutOverride: requestTimeoutOverride
        )
    }

    private func cancellationFixture(
        upstreamCount: Int, testHooks: RuntimeCoordinatorTestHooks = .init(),
        requestTimeout: TimeInterval = 60, deadlineClock: ClockClient = .liveValue
    ) throws -> (
        RuntimeCoordinator, ClientMCPRequestExecutor, NIOAsyncTestingEventLoop, [EmbeddedControlledUpstreamClient]
    ) {
        let config = makeEmbeddedConfig(requestTimeout: requestTimeout)
        let loop = NIOAsyncTestingEventLoop()
        let upstreams = (0..<upstreamCount).map { _ in EmbeddedControlledUpstreamClient() }
        let manager = RuntimeCoordinator(
            config: config, eventLoop: loop, upstreams: upstreams,
            testHooks: testHooks, startImmediately: false
        )
        for sessionID in ["cancel-session", "other-session"] {
            _ = manager.session(id: sessionID)
            manager.sessionRegistry.markInitialized(id: sessionID, negotiatedProtocolVersion: MCP.ProtocolVersion.current)
        }
        for index in upstreams.indices { manager.markUpstreamInitialized(upstreamIndex: index) }
        seedCanonicalInitializeForTesting(
            on: manager,
            result: .object(["protocolVersion": .string(MCP.ProtocolVersion.current), "capabilities": .object([:])]),
            sourceUpstream: 0
        )
        manager.seedCanonicalToolsCatalog(executeSnippetToolsCatalog(), sourceUpstream: 0)
        let service = ClientMCPRequestExecutor(
            config: config, sessionManager: manager,
            deadlineClock: deadlineClock
        )
        return (manager, service, loop, upstreams)
    }

    @Test func httpConcurrentInitializeRequests() async throws {
        let server = try TestHTTPServer.start()
        let url = server.url

        do {
            let count = 20
            let results = try await runConcurrentInitialize(url: url, count: count)

            #expect(Set(results.0).count == count)
            #expect(Set(results.1).count == count)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpConcurrentInitializeStress() async throws {
        let count = 10
        let server = try TestHTTPServer.start()
        let url = server.url

        do {
            let results = try await runConcurrentInitialize(url: url, count: count)

            #expect(Set(results.0).count == count)
            #expect(Set(results.1).count == count)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpConcurrentRequestsShareSession() async throws {
        let upstream = ControlledUpstreamClient()
        let server = try TestHTTPServer.start(upstream: upstream)
        let url = server.url

        do {
            let (initializeResponse, initializeBody) = try await postJSON(
                url: url,
                sessionID: nil,
                payload: initializePayload(id: 1)
            )
            guard let sessionID = initializeResponse.value(forHTTPHeaderField: "Mcp-Session-Id")
            else {
                throw ConcurrencyTestError.missingSessionID
            }
            let initID = (initializeBody["id"] as? NSNumber)?.intValue ?? -1
            #expect(initID == 1)
            await drainInitialToolsCatalogWarmupIfNeeded(server: server, upstream: upstream)

            async let first = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolListPayload(id: 100)
            )
            async let second = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolListPayload(id: 101)
            )
            let labels = try await waitForUpstreamRequestCount(upstream, count: 1)
            #expect(labels == ["tools/list"])
            try await waitWithTimeout("both HTTP requests joined the catalog load", timeout: .seconds(2)) {
                while server.sessionManager.debugSnapshot().controlPlane?.waiterCounts.toolsCatalog != 2 {
                    await Task.yield()
                }
            }
            #expect(await upstream.respondNext(label: "tools/list"))
            let firstResult = try await first
            let secondResult = try await second
            #expect(firstResult.0.statusCode == 200)
            #expect(secondResult.0.statusCode == 200)
            #expect(firstResult.1["result"] != nil)
            #expect(secondResult.1["result"] != nil)
            #expect((firstResult.1["id"] as? NSNumber)?.intValue == 100)
            #expect((secondResult.1["id"] as? NSNumber)?.intValue == 101)
            #expect(await upstream.nonInitializeLabels() == ["tools/list"])
            #expect(server.sessionManager.cachedToolsListResult() != nil)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpConcurrentRequestsCanOverlapAcrossSessions() async throws {
        let upstream = ControlledUpstreamClient()
        let server = try TestHTTPServer.start(upstream: upstream)
        let url = server.url

        do {
            let (initializeResponseA, _) = try await postJSON(
                url: url,
                sessionID: nil,
                payload: initializePayload(id: 1)
            )
            let (initializeResponseB, _) = try await postJSON(
                url: url,
                sessionID: nil,
                payload: initializePayload(id: 2)
            )
            guard let sessionA = initializeResponseA.value(forHTTPHeaderField: "Mcp-Session-Id"),
                let sessionB = initializeResponseB.value(forHTTPHeaderField: "Mcp-Session-Id")
            else {
                throw ConcurrencyTestError.missingSessionID
            }
            await drainInitialToolsCatalogWarmupIfNeeded(server: server, upstream: upstream)

            async let first = postJSON(
                url: url,
                sessionID: sessionA,
                payload: toolListPayload(id: 200)
            )
            async let second = postJSON(
                url: url,
                sessionID: sessionB,
                payload: toolListPayload(id: 201)
            )
            let labels = try await waitForUpstreamRequestCount(upstream, count: 1)
            #expect(labels == ["tools/list"])
            try await waitWithTimeout("both HTTP requests joined the catalog load", timeout: .seconds(2)) {
                while server.sessionManager.debugSnapshot().controlPlane?.waiterCounts.toolsCatalog != 2 {
                    await Task.yield()
                }
            }
            #expect(await upstream.respondNext(label: "tools/list"))
            let firstResult = try await first
            let secondResult = try await second
            #expect(firstResult.0.statusCode == 200)
            #expect(secondResult.0.statusCode == 200)
            #expect(firstResult.1["result"] != nil)
            #expect(secondResult.1["result"] != nil)
            #expect(await upstream.nonInitializeLabels() == ["tools/list"])
            #expect(server.sessionManager.cachedToolsListResult() != nil)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func methodSpecificAdmissionDeadlineUsesMCPMethodCap() {
        let timeout = ClientMCPRequestExecutor.topLevelRequestTimeoutOverride(
            method: "resources/list", defaultSeconds: 60
        )
        #expect(timeout?.nanoseconds == 20_000_000_000)
        #expect(ClientMCPRequestExecutor.minimumRequestTimeout(.seconds(60), timeout)?.nanoseconds == 20_000_000_000)
    }

    @Test func httpRequestTimeoutDoesNotCancelAnotherRequestOnTheSameNativeConnection() async throws {
        let upstream = EmbeddedControlledUpstreamClient()
        let config = makeEmbeddedConfig(requestTimeout: 10)
        let firstChannel = await NIOAsyncTestingChannel(handlers: [])
        let secondChannel = await NIOAsyncTestingChannel(handlers: [])
        let sessionManager = RuntimeCoordinator(
            config: config,
            eventLoop: firstChannel.eventLoop,
            upstreams: [upstream],
            startImmediately: false
        )
        defer {
            sessionManager.shutdownAndWait()
            registerAsyncTestCleanup(description: "finishing first HTTP test channel") {
                _ = try await firstChannel.finish()
            }
            registerAsyncTestCleanup(description: "finishing second HTTP test channel") {
                _ = try await secondChannel.finish()
            }
        }

        ProxyLogging.bootstrap(environment: ["MCP_LOG_LEVEL": "critical"])
        try await addAsyncHTTPHandler(
            to: firstChannel,
            config: config,
            sessionManager: sessionManager
        )
        try await addAsyncHTTPHandler(
            to: secondChannel,
            config: config,
            sessionManager: sessionManager
        )

        let sessionID = "session-timeout-queue"
        _ = sessionManager.session(id: sessionID)
        sessionManager.sessionRegistry.markInitialized(
            id: sessionID,
            negotiatedProtocolVersion: MCP.ProtocolVersion.current
        )
        sessionManager.markUpstreamInitialized(upstreamIndex: 0)
        seedCanonicalInitializeForTesting(
            on: sessionManager,
            result: try #require(
                JSONValue(any: [
                    "protocolVersion": MCP.ProtocolVersion.current,
                    "capabilities": [String: Any](),
                ])
            ),
            sourceUpstream: 0
        )
        sessionManager.seedCanonicalToolsCatalog(executeSnippetToolsCatalog(), sourceUpstream: 0)
        upstream.clearRecordedRequests()

        try await postAsyncJSON(
            executeSnippetPayload(id: 700, workspaceIdentifier: "/Work/Timeout.xcodeproj"),
            sessionID: sessionID,
            to: firstChannel
        )
        await firstChannel.testingEventLoop.run()
        await sessionManager.drainRuntimeTasksForTesting()
        let firstRequestLabels = try await waitForUpstreamRequestCount(upstream, count: 1)
        #expect(firstRequestLabels == ["tools/call:ExecuteSnippet"])

        try await postAsyncJSON(
            executeSnippetPayload(id: 701, workspaceIdentifier: "/Work/Other.xcodeproj"),
            sessionID: sessionID,
            to: secondChannel
        )
        await secondChannel.testingEventLoop.run()
        await sessionManager.drainRuntimeTasksForTesting()
        _ = try await waitForUpstreamRequestCount(upstream, count: 2)
        #expect(sessionManager.debugSnapshot().queuedRequestCount == 0)

        await firstChannel.testingEventLoop.advanceTime(by: .seconds(10))
        await firstChannel.testingEventLoop.run()
        let firstResponse = try await collectAsyncResponse(from: firstChannel)
        #expect(firstResponse.head.status == .ok)
        let firstObject = try jsonObject(from: firstResponse.body)
        #expect((firstObject["error"] as? [String: Any])?["message"] as? String == "upstream timeout")

        await sessionManager.drainRuntimeTasksForTesting()
        await secondChannel.testingEventLoop.run()
        await sessionManager.drainRuntimeTasksForTesting()
        let secondRequestLabels = try await waitForUpstreamRequestCount(upstream, count: 3)
        #expect(secondRequestLabels == [
            "tools/call:ExecuteSnippet",
            "tools/call:ExecuteSnippet",
            "notifications/cancelled",
        ])

        #expect(upstream.discardNextResponse(label: "tools/call:ExecuteSnippet"))
        let secondResponseData = try #require(
            upstream.takeNextResponse(label: "tools/call:ExecuteSnippet")
        )
        sessionManager.routeUpstreamMessage(secondResponseData, upstreamIndex: 0)
        await secondChannel.testingEventLoop.run()

        let secondResponse = try await collectAsyncResponse(from: secondChannel)
        #expect(secondResponse.head.status == .ok)
        let secondObject = try jsonObject(from: secondResponse.body)
        #expect((secondObject["id"] as? NSNumber)?.intValue == 701)
        #expect(secondObject["error"] == nil)
        #expect(
            sessionManager.debugSnapshot().sessions
                .first(where: { $0.sessionID == sessionID })?
                .activeCorrelatedRequestCount == 0
        )
    }

    private func executeSnippetPayload(id: Int, workspaceIdentifier: String) -> [String: Any] {
        toolCallPayload(
            id: id,
            name: "ExecuteSnippet",
            arguments: [
                "workspaceIdentifier": workspaceIdentifier,
                "sourceFilePath": "App.swift",
                "codeSnippet": "print(\"\(id)\")",
                "timeout": 20,
            ]
        )
    }

    private func executeSnippetToolsCatalog() -> JSONValue {
        JSONValue(any: [
            "tools": [
                [
                    "name": "ExecuteSnippet",
                    "outputSchema": [
                        "type": "object",
                    ],
                ],
            ],
        ])!
    }

    @Test func httpNotificationPreservesSendOrderWithoutWaitingForAnotherRequestResult() async throws {
        let notificationQueued = TestSignal()
        let upstream = ControlledUpstreamClient()
        let server = try TestHTTPServer.start(
            upstream: upstream,
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamRequestQueued: { _, descriptor, _ in
                    if descriptor.label == "notifications/test-progress" {
                        notificationQueued.signal()
                    }
                }
            )
        )
        let url = server.url

        do {
            let (initializeResponse, _) = try await postJSON(
                url: url,
                sessionID: nil,
                payload: initializePayload(id: 1)
            )
            guard let sessionID = initializeResponse.value(forHTTPHeaderField: "Mcp-Session-Id")
            else {
                throw ConcurrencyTestError.missingSessionID
            }
            await drainInitialToolsCatalogWarmupIfNeeded(server: server, upstream: upstream)

            async let first = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolListPayload(id: 400),
                timeout: 10
            )
            let firstUpstreamLabels = try await waitForUpstreamRequestCount(upstream, count: 1)
            #expect(firstUpstreamLabels == ["tools/list"])
            async let notification = postStatusOnly(
                url: url,
                sessionID: sessionID,
                payload: notificationPayload(method: "notifications/test-progress"),
                timeout: 10
            )
            try await notificationQueued.wait(
                description: "waiting for notification to queue behind tools/list"
            )
            let sentBeforeReply = try await waitForUpstreamRequestCount(upstream, count: 2)
            #expect(sentBeforeReply == ["tools/list", "notifications/test-progress"])
            #expect(server.sessionManager.debugSnapshot().queuedRequestCount == 0)
            #expect(await upstream.respondNext(label: "tools/list"))
            let firstResult = try await first
            #expect(firstResult.0.statusCode == 200)
            #expect((firstResult.1["id"] as? NSNumber)?.intValue == 400)
            #expect(firstResult.1["error"] == nil)
            let upstreamLabels = try await waitForUpstreamRequestCount(upstream, count: 2)
            #expect(upstreamLabels == ["tools/list", "notifications/test-progress"])
            let notificationResponse = try await notification
            #expect(notificationResponse.statusCode == 202)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpDebugSnapshotReportsSessionPipelineState() async throws {
        let upstream = ControlledUpstreamClient()
        let server = try TestHTTPServer.start(upstream: upstream)
        let url = server.url

        do {
            let (initializeResponse, _) = try await postJSON(
                url: url,
                sessionID: nil,
                payload: initializePayload(id: 1)
            )
            guard let sessionID = initializeResponse.value(forHTTPHeaderField: "Mcp-Session-Id")
            else {
                throw ConcurrencyTestError.missingSessionID
            }
            await drainInitialToolsCatalogWarmupIfNeeded(server: server, upstream: upstream)

            async let first = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolListPayload(id: 600),
                timeout: 10
            )
            async let second = postJSON(
                url: url,
                sessionID: sessionID,
                payload: toolListPayload(id: 601),
                timeout: 10
            )

            _ = try await waitForUpstreamRequest(upstream, label: "tools/list")
            _ = try await waitWithTimeout(
                "waiting for tools catalog waiters",
                timeout: .seconds(2)
            ) {
                try await server.sessionManager.controlPlaneDebugMirror.waitForSnapshot {
                    $0.waiterCounts.toolsCatalog == 2
                }
            }

            #expect(await upstream.respondNext(label: "tools/list"))
            let firstResult = try await first
            let secondResult = try await second
            #expect(firstResult.0.statusCode == 200)
            #expect(secondResult.0.statusCode == 200)
            #expect(server.sessionManager.cachedToolsListResult() != nil)
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpRefreshCodeIssuesNotificationForwardsWithoutInvalidUpstreamOverride()
        async throws
    {
        let upstream = ControlledUpstreamClient()
        let server = try TestHTTPServer.start(upstream: upstream)
        let url = server.url

        do {
            let (initializeResponse, _) = try await postJSON(
                url: url,
                sessionID: nil,
                payload: initializePayload(id: 1)
            )
            guard let sessionID = initializeResponse.value(forHTTPHeaderField: "Mcp-Session-Id")
            else {
                throw ConcurrencyTestError.missingSessionID
            }
            await upstream.clearRecordedRequests()

            let response = try await postStatusOnly(
                url: url,
                sessionID: sessionID,
                payload: toolCallNotificationPayload(
                    name: "XcodeRefreshCodeIssuesInFile",
                    arguments: [
                        "workspaceIdentifier": "/Work/Refresh.xcodeproj",
                        "filePath": "App.swift",
                    ]
                )
            )

            #expect(response.statusCode == 202)
            let labels = try await waitForUpstreamRequestCount(upstream, count: 1)
            #expect(labels == ["tools/call:XcodeRefreshCodeIssuesInFile"])
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }

    @Test func httpServerNotificationsReachActiveSSESessions() async throws {
        let upstream = NotifyingUpstreamClient()
        let server = try TestHTTPServer.start(upstream: upstream)
        let url = server.url

        do {
            let (initializeResponse, _) = try await postJSON(
                url: url,
                sessionID: nil,
                payload: initializePayload(id: 1)
            )
            guard let sessionID = initializeResponse.value(forHTTPHeaderField: "Mcp-Session-Id")
            else {
                throw ConcurrencyTestError.missingSessionID
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            request.setValue(MCP.ProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")

            let sseTask = Task<(HTTPURLResponse, String), Error> {
                try await withTestURLSession { session in
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw ConcurrencyTestError.invalidResponse
                    }

                    var iterator = bytes.lines.makeAsyncIterator()
                    while let line = try await iterator.next() {
                        if line.hasPrefix("data: ") {
                            return (httpResponse, String(line.dropFirst(6)))
                        }
                    }

                    throw ConcurrencyTestError.invalidResponse
                }
            }
            defer { sseTask.cancel() }

            _ = try await waitWithTimeout(
                "waiting for SSE client registration",
                timeout: .seconds(2)
            ) {
                try await server.controlService.waitForSSEClient(
                    sessionID: ProxySessionID(rawValue: sessionID)
                )
            }

            let notificationData = try JSONSerialization.data(
                withJSONObject: [
                    "jsonrpc": "2.0",
                    "method": "notifications/test",
                    "params": ["value": 42],
                ],
                options: []
            )
            await upstream.pushNotification(notificationData)

            let (response, line) = try await waitWithTimeout(
                "waiting for SSE notification",
                timeout: .seconds(2)
            ) {
                try await sseTask.value
            }

            #expect(response.statusCode == 200)
            #expect(line == String(decoding: notificationData, as: UTF8.self))
        } catch {
            try? await server.shutdown()
            throw error
        }
        try await server.shutdown()
    }
}

private enum ConcurrencyTestError: Error {
    case invalidResponse
    case missingSessionID
}

private func runConcurrentInitialize(
    url: URL,
    count: Int
) async throws -> ([String], [Int]) {
    try await withThrowingTaskGroup(of: (String, Int).self) { group in
        for index in 0..<count {
            group.addTask {
                let payload = initializePayload(id: index + 1)
                let (response, body) = try await postJSON(
                    url: url, sessionID: nil, payload: payload)
                guard let sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id") else {
                    throw ConcurrencyTestError.missingSessionID
                }
                let responseID = (body["id"] as? NSNumber)?.intValue ?? -1
                return (sessionID, responseID)
            }
        }

        var sessionIDs: [String] = []
        var ids: [Int] = []
        for try await (sessionID, responseID) in group {
            sessionIDs.append(sessionID)
            ids.append(responseID)
        }
        return (sessionIDs, ids)
    }
}

private struct TestHTTPServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let url: URL
    let sessionManager: RuntimeCoordinator
    let upstream: any UpstreamSlotControlling
    let childChannelTracker: HTTPTestServerChannelTracker
    let controlService: HTTPControlService

    static func start(
        upstream providedUpstream: (any UpstreamSlotControlling)? = nil,
        requestTimeout: TimeInterval = 5,
        additionalUpstreams: [any UpstreamSlotControlling] = [],
        testHooks: RuntimeCoordinatorTestHooks = RuntimeCoordinatorTestHooks(),
) throws -> TestHTTPServer {
        ProxyLogging.bootstrap(environment: ["MCP_LOG_LEVEL": "critical"])
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let childChannelTracker = HTTPTestServerChannelTracker()
        let config: ProxyRuntimeConfiguration = {
            var config = ProxyRuntimeConfiguration(

                maxMessageBytes: 1_048_576,
                requestTimeout: requestTimeout
            )
            config.prewarmToolsList = false
            return config
        }()
        let upstream = providedUpstream ?? EchoUpstreamClient()
        let runtimeEventSource = ProxyRuntimeEventSource()
        let runtimeEventLoop = group.next()
        let sessionManager = RuntimeCoordinator(
            config: config,
            eventLoop: runtimeEventLoop,
            upstreams: [upstream] + additionalUpstreams,
            notificationSink: { sessionID, data in
                runtimeEventSource.emit(
                    .notification(
                        sessionID: ProxySessionID(rawValue: sessionID),
                        data: data
                    )
                )
            },
            testHooks: testHooks
        )
        let runtime = ProxyRuntime(
            config: config,
            coordinator: sessionManager,
            eventLoop: runtimeEventLoop,
            eventSource: runtimeEventSource
        )
        let controlService = HTTPControlService(runtime: runtime)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            config: ProxyHTTPConfiguration(
                                listenHost: "127.0.0.1",
                                listenPort: 0,
                                maxBodyBytes: config.maxMessageBytes
                            ),
                            controlService: controlService
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        try channel.pipeline.addHandler(
            HTTPTestServerAcceptedChannelHandler(tracker: childChannelTracker)
        ).wait()
        let port = channel.localAddress?.port ?? 0
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        return TestHTTPServer(
            group: group,
            channel: channel,
            url: url,
            sessionManager: sessionManager,
            upstream: upstream,
            childChannelTracker: childChannelTracker,
            controlService: controlService
        )
    }

    func shutdown() async throws {
        try await shutdownHTTPTestServer(
            listenChannel: channel,
            childChannelTracker: childChannelTracker,
            group: group,
            beforeClose: {
                await sessionManager.shutdown()
            }
        )
    }
}

private actor NativeWorkspaceUpstream: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private var calls: [String] = []
    init() { (events, continuation) = AsyncStream.makeStream() }
    func start() async {}
    func stop() async { continuation.finish() }
    func recordedCalls() -> [String] { calls }
    func send(_ data: Data) async -> Upstream.SendResult {
        do {
            let object = try JSONRPC.Wire.object(fromData: data)
            guard let id = JSONRPC.Message.Inspector.requestID(from: object) else { return .accepted }
            let result: [String: Any]
            switch object["method"] as? String {
            case "initialize":
                result = ["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]
            case "tools/list":
                result = ["tools": [["name": "BuildProject", "inputSchema": [
                    "type": "object", "properties": ["workspaceIdentifier": ["type": "string"]],
                    "required": ["workspaceIdentifier"]]]]]
            default:
                let params = object["params"] as? [String: Any] ?? [:]
                calls.append(params["name"] as? String ?? "")
                result = ["isError": true, "content": [["type": "text", "text": "project unavailable"]],
                    "structuredContent": params["arguments"] as? [String: Any] ?? [:]]
            }
            continuation.yield(.message(try JSONRPC.Wire.resultResponseData(id: id, result: JSONValue(any: result)!)))
        } catch { Issue.record(error) }
        return .accepted
    }
}

private actor PaginatedCatalogUpstream: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private var requestedCursors: [String?] = []

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func start() async {}
    func stop() async { continuation.finish() }
    func cursors() -> [String?] { requestedCursors }

    func send(_ data: Data) async -> Upstream.SendResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] else { return .accepted }
        let result: [String: Any]
        switch object["method"] as? String {
        case "initialize":
            result = [
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": "paginated-test", "version": "1"],
            ]
        case "tools/list":
            let cursor = (object["params"] as? [String: Any])?["cursor"] as? String
            requestedCursors.append(cursor)
            var page: [String: Any] = ["tools": [[
                "name": cursor == nil ? "FirstPage" : "LastPage",
                "inputSchema": ["type": "object"],
            ]]]
            if cursor == nil { page["nextCursor"] = "opaque / token?=α" }
            result = page
        default:
            result = [:]
        }
        if let response = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]) {
            continuation.yield(.message(response))
        }
        return .accepted
    }
}

private actor EchoUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation

    init() {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .accepted
        }
        var responses: [Data] = []
        if let object = json as? [String: Any] {
            if let response = makeResponse(from: object) {
                responses.append(response)
            }
        } else if let array = json as? [Any] {
            for item in array {
                guard let object = item as? [String: Any] else { continue }
                if let response = makeResponse(from: object) {
                    responses.append(response)
                }
            }
        }

        for response in responses {
            continuation.yield(.message(response))
        }
        return .accepted
    }

    private func makeResponse(from object: [String: Any]) -> Data? {
        guard let id = object["id"] else {
            return nil
        }
        let method = object["method"] as? String
        let result: [String: Any]
        if method == "initialize" {
            result = [
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
            ]
        } else {
            result = [:]
        }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        return try? JSONSerialization.data(withJSONObject: response, options: [])
    }
}

private func waitForUpstreamRequest(
    _ upstream: ControlledUpstreamClient,
    label: String
) async throws -> String {
    try await waitWithTimeout("waiting for upstream \(label) request", timeout: .seconds(2)) {
        try await upstream.waitForNonInitializeRequest(label: label)
    }
}

private func waitForUpstreamRequestCount(
    _ upstream: ControlledUpstreamClient,
    count: Int
) async throws -> [String] {
    try await waitWithTimeout("waiting for \(count) upstream request(s)", timeout: .seconds(2)) {
        try await upstream.waitForNonInitializeRequestCount(count)
    }
}

private func waitForUpstreamRequestCount(
    _ upstream: EmbeddedControlledUpstreamClient,
    count: Int
) async throws -> [String] {
    try await waitWithTimeout("waiting for \(count) upstream request(s)", timeout: .seconds(2)) {
        try await upstream.waitForNonInitializeRequestCount(count)
    }
}

private final class EmbeddedControlledUpstreamClient: UpstreamSlotControlling, @unchecked Sendable {
    private struct SentRequest: Sendable {
        let label: String
        let responseData: Data?
    }

    private struct State {
        var sentRequests: [SentRequest] = []
        var requestHistory: [String] = []
        var messages: [JSONValue] = []
        var requestLabelBaseline = 0
        var requestLabelCount = 0
    }

    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let requestLabels = LockedRecordedValues<String>()
    private let lock = NSLock()
    private var state = State()

    init() {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .accepted
        }

        if let object = json as? [String: Any] {
            handle(object)
        } else if let array = json as? [Any] {
            for item in array {
                guard let object = item as? [String: Any] else { continue }
                handle(object)
            }
        }
        return .accepted
    }

    func recordedMessages() -> [JSONValue] { withLock { $0.messages } }

    func clearRecordedRequests() {
        withLock {
            $0.messages.removeAll()
            $0.sentRequests.removeAll()
            $0.requestHistory.removeAll()
            $0.requestLabelBaseline = $0.requestLabelCount
        }
    }

    func waitForNonInitializeRequestCount(_ count: Int) async throws -> [String] {
        guard count > 0 else { return [] }

        let baseline = withLock { $0.requestLabelBaseline }
        _ = try await requestLabels.nextValue(at: baseline + count - 1)
        return withLock { Array($0.requestHistory.prefix(count)) }
    }

    @discardableResult
    func respondNext(label expectedLabel: String? = nil) -> Bool {
        guard let responseData = takeNextResponse(label: expectedLabel) else { return false }
        continuation.yield(.message(responseData))
        return true
    }

    func takeNextResponse(label expectedLabel: String? = nil) -> Data? {
        removeNextRequest(label: expectedLabel)?.responseData
    }

    @discardableResult
    func discardNextResponse(label expectedLabel: String? = nil) -> Bool {
        removeNextRequest(label: expectedLabel) != nil
    }

    private func removeNextRequest(label expectedLabel: String?) -> SentRequest? {
        withLock { state in
            let requestIndex: Array<SentRequest>.Index?
            if let expectedLabel {
                requestIndex = state.sentRequests.firstIndex { $0.label == expectedLabel }
            } else {
                requestIndex = state.sentRequests.indices.first
            }
            guard let requestIndex else { return nil }
            return state.sentRequests.remove(at: requestIndex)
        }
    }

    private func handle(_ object: [String: Any]) {
        let method = (object["method"] as? String) ?? "unknown"
        guard method != "initialize" else {
            if let id = object["id"] {
                continuation.yield(.message(makeInitializeResponse(id: id)))
            }
            return
        }

        let label = requestLabel(from: object)
        let responseData = makeDefaultResponse(id: object["id"], method: method)
        withLock {
            $0.messages.append(JSONValue(any: object)!)
            $0.sentRequests.append(SentRequest(label: label, responseData: responseData))
            $0.requestHistory.append(label)
            $0.requestLabelCount += 1
        }
        requestLabels.append(label)
    }

    private func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    private func requestLabel(from object: [String: Any]) -> String {
        let method = (object["method"] as? String) ?? "unknown"
        if method == "tools/call",
            let params = object["params"] as? [String: Any],
            let name = params["name"] as? String
        {
            return "\(method):\(name)"
        }
        return method
    }

    private func makeInitializeResponse(id: Any) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [String: Any]()],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func makeSuccessResponse(id: Any?) -> Data? {
        guard let id else { return nil }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [:],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func makeToolsListResponse(id: Any?) -> Data? {
        guard let id else { return nil }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "tools": [[
                    "name": "XcodeListWindows",
                    "description": "List Xcode windows",
                    "inputSchema": [
                        "type": "object",
                        "properties": [String: Any](),
                    ],
                ]]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func makeDefaultResponse(id: Any?, method: String) -> Data? {
        if method == "tools/list" {
            return makeToolsListResponse(id: id)
        }
        return makeSuccessResponse(id: id)
    }
}

private actor ControlledUpstreamClient: UpstreamSlotControlling {
    struct SentRequest: Sendable {
        let label: String
        let responseData: Data?
    }

    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private var sentRequests: [SentRequest] = []
    private var requestHistory: [String] = []
    private let requestLabels = RecordedValues<String>()
    private var requestLabelBaseline = 0
    private var requestLabelCount = 0

    init() {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .accepted
        }

        if let object = json as? [String: Any] {
            await handle(object)
        } else if let array = json as? [Any] {
            for item in array {
                guard let object = item as? [String: Any] else { continue }
                await handle(object)
            }
        }
        return .accepted
    }

    func nonInitializeRequestCount() -> Int {
        requestHistory.count
    }

    func pendingNonInitializeRequestCount() -> Int {
        sentRequests.count
    }

    func nonInitializeLabels() -> [String] {
        requestHistory
    }

    @discardableResult
    func waitForNonInitializeRequestCount(_ count: Int) async throws -> [String] {
        guard count > 0 else { return [] }
        _ = try await requestLabels.nextValue(at: requestLabelBaseline + count - 1)
        let labels = await requestLabels.snapshot()
        return Array(labels.dropFirst(requestLabelBaseline).prefix(count))
    }

    @discardableResult
    func waitForNonInitializeRequest(label expectedLabel: String) async throws -> String {
        try await requestLabels.nextValue(startingAt: requestLabelBaseline) { label in
            label == expectedLabel
        }
    }

    func clearRecordedRequests() {
        sentRequests.removeAll()
        requestHistory.removeAll()
        requestLabelBaseline = requestLabelCount
    }

    @discardableResult
    func respondNext(label expectedLabel: String? = nil) -> Bool {
        let requestIndex: Array<SentRequest>.Index?
        if let expectedLabel {
            requestIndex = sentRequests.firstIndex { $0.label == expectedLabel }
        } else {
            requestIndex = sentRequests.indices.first
        }
        guard let requestIndex else { return false }
        let request = sentRequests.remove(at: requestIndex)
        guard let responseData = request.responseData else { return false }
        continuation.yield(.message(responseData))
        return true
    }

    @discardableResult
    func discardNextResponse(label expectedLabel: String? = nil) -> Bool {
        let requestIndex: Array<SentRequest>.Index?
        if let expectedLabel {
            requestIndex = sentRequests.firstIndex { $0.label == expectedLabel }
        } else {
            requestIndex = sentRequests.indices.first
        }
        guard let requestIndex else { return false }
        _ = sentRequests.remove(at: requestIndex)
        return true
    }

    private func handle(_ object: [String: Any]) async {
        let method = (object["method"] as? String) ?? "unknown"
        guard method != "initialize" else {
            if let id = object["id"] {
                continuation.yield(.message(makeInitializeResponse(id: id)))
            }
            return
        }

        let label = requestLabel(from: object)
        let responseData = makeDefaultResponse(id: object["id"], method: method)
        sentRequests.append(SentRequest(label: label, responseData: responseData))
        requestHistory.append(label)
        requestLabelCount += 1
        await requestLabels.append(label)
    }

    private func requestLabel(from object: [String: Any]) -> String {
        let method = (object["method"] as? String) ?? "unknown"
        if method == "tools/call",
            let params = object["params"] as? [String: Any],
            let name = params["name"] as? String
        {
            return "\(method):\(name)"
        }
        return method
    }

    private func makeInitializeResponse(id: Any) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [String: Any]()],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func makeSuccessResponse(id: Any?) -> Data? {
        guard let id else { return nil }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [:],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func makeToolsListResponse(id: Any?) -> Data? {
        guard let id else { return nil }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "tools": [[
                    "name": "XcodeListWindows",
                    "description": "List Xcode windows",
                    "inputSchema": [
                        "type": "object",
                        "properties": [String: Any](),
                    ],
                ]]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func makeDefaultResponse(id: Any?, method: String) -> Data? {
        if method == "tools/list" {
            return makeToolsListResponse(id: id)
        }
        return makeSuccessResponse(id: id)
    }
}

private actor NotifyingUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation

    init() {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let method = object["method"] as? String
        else {
            return .accepted
        }

        if method == "initialize", let id = object["id"] {
            continuation.yield(.message(makeInitializeResponse(id: id)))
        }

        return .accepted
    }

    func pushNotification(_ data: Data) {
        continuation.yield(.message(data))
    }

    private func makeInitializeResponse(id: Any) -> Data {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any]()
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: response, options: [])
    }
}

private func initializePayload(id: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "xcode-mcp-proxy-concurrency-tests",
                "version": "0.0",
            ],
        ],
    ]
}

private func toolCallPayload(
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

private func toolCallNotificationPayload(
    name: String,
    arguments: [String: Any]
) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": [
            "name": name,
            "arguments": arguments,
        ],
    ]
}

private func toolListPayload(id: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/list",
    ]
}

private func notificationPayload(method: String) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "method": method,
        "params": [String: Any](),
    ]
}

private func postJSON(
    url: URL,
    sessionID: String?,
    payload: [String: Any]
) async throws -> (HTTPURLResponse, [String: Any]) {
    try await postJSON(
        url: url,
        sessionID: sessionID,
        payload: payload,
        timeout: nil
    )
}

private func postJSON(
    url: URL,
    sessionID: String?,
    payload: [String: Any],
    timeout: TimeInterval?
) async throws -> (HTTPURLResponse, [String: Any]) {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let timeout {
        request.timeoutInterval = timeout
    }
    if let sessionID {
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue(MCP.ProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")
    }

    return try await withTestURLSession(timeout: timeout ?? 5) { session in
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConcurrencyTestError.invalidResponse
        }
        let object =
            (try? JSONSerialization.jsonObject(with: responseData, options: [])) as? [String: Any]
            ?? [:]
        return (httpResponse, object)
    }
}

private func postStatusOnly(
    url: URL,
    sessionID: String?,
    payload: [String: Any],
    timeout: TimeInterval? = nil
) async throws -> HTTPURLResponse {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let timeout {
        request.timeoutInterval = timeout
    }
    if let sessionID {
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue(MCP.ProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")
    }

    return try await withTestURLSession(timeout: timeout ?? 5) { session in
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConcurrencyTestError.invalidResponse
        }
        return httpResponse
    }
}

private func makeEmbeddedConfig(requestTimeout: TimeInterval) -> ProxyRuntimeConfiguration {
    var config = ProxyRuntimeConfiguration(
        maxMessageBytes: 1_048_576,
        requestTimeout: requestTimeout
    )
    config.prewarmToolsList = false
    return config
}

private func addAsyncHTTPHandler(
    to channel: NIOAsyncTestingChannel,
    config: ProxyRuntimeConfiguration,
    sessionManager: any RuntimeCoordinating
) async throws {
    try await channel.testingEventLoop.executeInContext {
        let runtime = ProxyRuntime(
            config: config,
            coordinator: sessionManager,
            eventLoop: channel.eventLoop,
            eventSource: ProxyRuntimeEventSource()
        )
        let handler = HTTPHandler(
            config: ProxyHTTPConfiguration(
                listenHost: "127.0.0.1",
                listenPort: 0,
                maxBodyBytes: config.maxMessageBytes
            ),
            controlService: HTTPControlService(runtime: runtime)
        )
        try channel.pipeline.syncOperations.addHandler(handler)
    }
}

private func postAsyncJSON(
    _ payload: [String: Any],
    sessionID: String?,
    to channel: NIOAsyncTestingChannel
) async throws {
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
    try await channel.writeInbound(HTTPServerRequestPart.head(head))
    try await channel.writeInbound(HTTPServerRequestPart.body(body))
    try await channel.writeInbound(HTTPServerRequestPart.end(nil))
}

private func collectAsyncResponse(
    from channel: NIOAsyncTestingChannel
) async throws -> (head: HTTPResponseHead, body: String) {
    try await waitWithTimeout("waiting for HTTP test response") {
        var responseHead: HTTPResponseHead?
        var bodyBuffer = channel.allocator.buffer(capacity: 0)
        while true {
            switch try await channel.waitForOutboundWrite(as: HTTPServerResponsePart.self) {
            case .head(let head):
                responseHead = head
            case .body(let body):
                if case .byteBuffer(var buffer) = body {
                    bodyBuffer.writeBuffer(&buffer)
                }
            case .end:
                guard let responseHead else {
                    throw ConcurrencyTestError.invalidResponse
                }
                return (responseHead, bodyBuffer.readString(length: bodyBuffer.readableBytes) ?? "")
            }
        }
    }
}

private func jsonObject(from string: String) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: Data(string.utf8), options: []) as? [String: Any]
    )
}

private func drainInitialToolsCatalogWarmupIfNeeded(
    server: TestHTTPServer,
    upstream: ControlledUpstreamClient
) async {
    _ = server
    await upstream.clearRecordedRequests()
}
