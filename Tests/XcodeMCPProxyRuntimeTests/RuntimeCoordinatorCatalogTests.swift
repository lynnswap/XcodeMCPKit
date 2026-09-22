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
        #expect(await second.sentCount() == 0)
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
        #expect(await upstream.sentCount() == 4)
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

    @Test func paginatedCatalogCancelsTheCurrentPage() async throws {
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
        let delivery = try #require(handle.cancel())
        _ = await delivery.wait()
        await #expect(throws: CancellationError.self) { _ = try await load.value }
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
        #expect(await upstream.sentCount() == 3)
    }

    @Test func sessionManagerToolsListResyncsRemainingCatalogWhenUncatalogedProcessRouteRetires()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let uncatalogedUpstream = TestUpstreamClient()
        let remainingUpstream = TestUpstreamClient()
        let uncatalogedTarget = xcodeProcessTarget(processID: 80435, xcodeVersion: "27.0")
        let remainingTarget = xcodeProcessTarget(processID: 66339, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [uncatalogedUpstream, remainingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: uncatalogedTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: remainingTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (remainingTarget, 1, [toolDescriptor(name: "RemainingOnlyTool")])
            ]
        )
        #expect(manager.cachedToolsListResult() == nil)

        manager.reconcileXcodeProcessTargets(
            [remainingTarget],
            reason: "test_uncataloged_process_route_retired"
        )
        #expect(try await uncatalogedUpstream.nextStopCount() == 1)

        #expect(
            toolNames(in: manager.cachedToolsListResult() ?? .null) == [
                "RemainingOnlyTool"
            ])
        #expect(
            manager.debugSnapshot().processToolCatalogs.map(\.processID)
                == [remainingTarget.processID]
        )
        #expect(manager.processControlPlane.canonicalSourceUpstream() == 1)
    }

    @Test func sessionManagerToolsListResyncsSurfaceAndInvalidatesCatalogWhenSourceClears()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let clearedTarget = xcodeProcessTarget(processID: 80434, xcodeVersion: "27.0")
        let remainingTarget = xcodeProcessTarget(processID: 66338, xcodeVersion: "26.6")
        let clearedSource = TestUpstreamClient()
        let remainingUpstream = TestUpstreamClient()
        let clearedSibling = TestUpstreamClient()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [clearedSource, remainingUpstream, clearedSibling],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: clearedTarget, upstreamIndices: [0, 2]),
                XcodeProcessRoute(target: remainingTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        manager.markUpstreamInitialized(upstreamIndex: 2)
        let initializeResult = try jsonValue([
            "protocolVersion": MCP.ProtocolVersion.current,
            "capabilities": [String: Any](),
            "serverInfo": ["name": "catalog-source"],
        ])
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: initializeResult,
            sourceUpstream: 0
        )
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: initializeResult,
            sourceUpstream: 1
        )
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (clearedTarget, 0, [toolDescriptor(name: "ClearedOnlyTool")]),
                (remainingTarget, 1, [toolDescriptor(name: "RemainingOnlyTool")]),
            ]
        )
        #expect(manager.cachedToolsListResult() != nil)

        #expect(manager.clearUpstreamState(upstreamIndex: 0))

        #expect(manager.cachedToolsListResult() == nil)
        #expect(manager.processControlPlane.catalog(forProcessID: clearedTarget.processID) == nil)
        #expect(
            manager.debugSnapshot().processToolCatalogs.map(\.processID)
                == [remainingTarget.processID]
        )
        #expect(manager.processControlPlane.canonicalSourceUpstream() == nil)
        manager.refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "test_cleared_source_background_refresh",
            processIDs: [clearedTarget.processID]
        )
        let freshRequest = try await sentValue(
            from: clearedSibling,
            at: 0,
            timeout: .seconds(2)
        )
        let available = try await manager.sharedToolsList(
            sessionID: "session-resync-cleared-process-catalog",
            requestTimeoutOverride: nil
        )
        #expect(toolNames(in: available) == ["RemainingOnlyTool"])
        await clearedSibling.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: freshRequest),
                    tools: [toolDescriptor(name: "ClearedFreshTool")]
                ))
        )
        _ = try await waitWithTimeout("waiting for exact-source catalog reload") {
            await manager.drainRuntimeTasksForTesting()
        }
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set([
                    "ClearedFreshTool",
                    "RemainingOnlyTool",
                ]))
        let reloaded = try #require(
            manager.processControlPlane.catalog(forProcessID: clearedTarget.processID)
        )
        #expect(reloaded.upstreamProof.slotID == UpstreamSlotID(rawValue: 2))
    }

    @Test func sessionManagerToolsListDoesNotFallbackWhenAllProcessRoutesUnavailable()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 80426, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 66335, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_unavailable"
        )
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 1,
            reason: "test_unavailable"
        )

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            _ = try await manager.sharedToolsList(
                sessionID: "session-process-catalog-all-unavailable",
                requestTimeoutOverride: .seconds(5)
            )
        }
        #expect(await upstream0.sentCount() == 0)
        #expect(await upstream1.sentCount() == 0)
        #expect(manager.cachedToolsListResult() == nil)
    }

    @Test func sessionManagerToolsListSkipsColdProcessRouteCatalog() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let coldUpstream = TestUpstreamClient()
        let warmUpstream = TestUpstreamClient()
        let coldTarget = xcodeProcessTarget(processID: 80423, xcodeVersion: "27.0")
        let warmTarget = xcodeProcessTarget(processID: 66334, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [coldUpstream, warmUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: coldTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: warmTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 1)
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "warm-route"],
            ]),
            sourceUpstream: 1
        )

        let task = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-skip-cold",
                requestTimeoutOverride: .seconds(5)
            )
        }

        let warmRequest = try await warmUpstream.nextSent {
            methodName(from: $0) == "tools/list"
        }
        await warmUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: warmRequest),
                    tools: [
                        toolDescriptor(name: "WarmOnlyTool")
                    ]
                )
            )
        )

        let result = try await waitWithTimeout("waiting for warm process tools/list") {
            try await task.value
        }
        #expect(toolNames(in: result) == ["WarmOnlyTool"])
        #expect(await coldUpstream.sentCount() == 0)
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["WarmOnlyTool"])
        #expect(manager.debugSnapshot().controlPlane?.canonicalToolsSourceUpstream == 1)
        #expect(manager.debugSnapshot().processToolCatalogs.map(\.processID) == [warmTarget.processID])

        manager.markUpstreamInitialized(upstreamIndex: 0)
        #expect(manager.cachedToolsListResult() == nil)
        manager.refreshMissingProcessToolsCatalogsIfNeeded(
            reason: "test_cold_route_background_refresh",
            processIDs: [coldTarget.processID]
        )
        let coldRequest = try await sentValue(from: coldUpstream, at: 0, timeout: .seconds(2))
        let stillAvailable = try await manager.sharedToolsList(
            sessionID: "session-process-catalog-after-cold-warms",
            requestTimeoutOverride: nil
        )
        #expect(toolNames(in: stillAvailable) == ["WarmOnlyTool"])
        await coldUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: coldRequest),
                    tools: [toolDescriptor(name: "ColdOnlyTool")]
                )
            )
        )
        _ = try await waitWithTimeout("waiting for newly warm process catalog") {
            await manager.drainRuntimeTasksForTesting()
        }
        #expect(
            Set(toolNames(in: manager.cachedToolsListResult() ?? .null))
                == Set(["ColdOnlyTool", "WarmOnlyTool"])
        )
        #expect(await coldUpstream.sentCount() == 1)
        #expect(await warmUpstream.sentCount() == 1)
    }

    @Test func documentationCandidatesIgnoreWorkspaceOwnersAndKeepUsableProcesses()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let badTarget = xcodeProcessTarget(processID: 80422, xcodeVersion: "27.0")
        let goodTarget = xcodeProcessTarget(processID: 66333, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: badTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: goodTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let result = try jsonValue([
            "structuredContent": [
                "message": "* tabIdentifier: tab-good, workspacePath: /tmp/Good.xcworkspace"
            ]
        ])
        #expect(manager.recordXcodeWindowOwners(from: result, upstreamIndex: 1))

        #expect(
            manager.documentationCandidateProcessIDs()
                == Set([
                    badTarget.processID,
                    goodTarget.processID,
                ])
        )
    }

    @Test func runtimeDocumentationDiscoveryPreservesDiscoveryOrderExceptUnavailableProcessIDs()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let routeFirst = xcodeProcessTarget(processID: 80430, xcodeVersion: "26.6")
        let unavailable = xcodeProcessTarget(processID: 80431, xcodeVersion: "27.0")
        let routeLast = xcodeProcessTarget(processID: 80432, xcodeVersion: "25.4")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: routeFirst, upstreamIndices: [0]),
                XcodeProcessRoute(target: unavailable, upstreamIndices: [1]),
                XcodeProcessRoute(target: routeLast, upstreamIndices: [2]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        manager.markUpstreamInitialized(upstreamIndex: 2)
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-route-last, workspacePath: /tmp/RouteLast.xcworkspace"
                    ]
                ]),
                upstreamIndex: 2
            )
        )
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 1,
            reason: "test_discovery_filter"
        )

        let runtimeBox = WeakRuntimeCoordinatorBox()
        runtimeBox.value = manager
        let discovery = RuntimeDocumentationTargetDiscovery(
            base: StubXcodeTargetDiscovery(targets: [routeLast, unavailable, routeFirst]),
            runtimeBox: runtimeBox
        )

        #expect(
            discovery.runningXcodeTargets().map(\.processID) == [
                routeLast.processID,
                routeFirst.processID,
            ])
    }

    @Test func documentationCandidatesSkipUnavailableWorkspaceOwner() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let badTarget = xcodeProcessTarget(processID: 80422, xcodeVersion: "27.0")
        let goodTarget = xcodeProcessTarget(processID: 66333, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: badTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: goodTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let result = try jsonValue([
            "structuredContent": [
                "message": "* tabIdentifier: tab-good, workspacePath: /tmp/Good.xcworkspace"
            ]
        ])
        #expect(manager.recordXcodeWindowOwners(from: result, upstreamIndex: 1))
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 1,
            reason: "test_owner_terminated"
        )

        #expect(manager.documentationCandidateProcessIDs() == Set([badTarget.processID]))
    }

    @Test func runtimeDocumentationDiscoveryKeepsLiveTargetsOutsideUsableRouteCandidates()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let ownerTarget = xcodeProcessTarget(processID: 80428, xcodeVersion: "27.0")
        let fallbackTarget = xcodeProcessTarget(processID: 80429, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: ownerTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: fallbackTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let result = try jsonValue([
            "structuredContent": [
                "message": "* tabIdentifier: tab-owner, workspacePath: /tmp/Owner.xcworkspace"
            ]
        ])
        #expect(manager.recordXcodeWindowOwners(from: result, upstreamIndex: 0))

        let runtimeBox = WeakRuntimeCoordinatorBox()
        runtimeBox.value = manager
        let discovery = RuntimeDocumentationTargetDiscovery(
            base: StubXcodeTargetDiscovery(targets: [fallbackTarget, ownerTarget]),
            runtimeBox: runtimeBox
        )

        #expect(
            discovery.runningXcodeTargets().map(\.processID) == [
                fallbackTarget.processID,
                ownerTarget.processID,
            ])

        manager.markUpstreamInitialized(upstreamIndex: 1)

        #expect(
            discovery.runningXcodeTargets().map(\.processID) == [
                fallbackTarget.processID,
                ownerTarget.processID,
            ])
    }

    @Test func runtimeDocumentationDiscoveryKeepsLiveTargetsOutsideRuntimeRoutes()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let staleTarget = xcodeProcessTarget(processID: 80424, xcodeVersion: "27.0")
        let relaunchedTarget = xcodeProcessTarget(processID: 80425, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: staleTarget, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_relaunch"
        )

        let runtimeBox = WeakRuntimeCoordinatorBox()
        runtimeBox.value = manager
        let discovery = RuntimeDocumentationTargetDiscovery(
            base: StubXcodeTargetDiscovery(targets: [relaunchedTarget]),
            runtimeBox: runtimeBox
        )

        #expect(
            discovery.runningXcodeTargets().map(\.processID) == [
                relaunchedTarget.processID
            ])
    }

    @Test func runtimeDocumentationDiscoveryDoesNotReaddUnavailableRuntimeRouteTargets()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let unavailableTarget = xcodeProcessTarget(processID: 80426, xcodeVersion: "27.0")
        let outsideTarget = xcodeProcessTarget(processID: 80427, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: unavailableTarget, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_route_unavailable"
        )

        let runtimeBox = WeakRuntimeCoordinatorBox()
        runtimeBox.value = manager
        let discovery = RuntimeDocumentationTargetDiscovery(
            base: StubXcodeTargetDiscovery(targets: [unavailableTarget, outsideTarget]),
            runtimeBox: runtimeBox
        )

        #expect(
            discovery.runningXcodeTargets().map(\.processID) == [
                outsideTarget.processID
            ])
    }

    @Test func sessionManagerFansOutXcodeListWindowsAcrossProcessRoutesAndCachesOwners()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 510, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 511, xcodeVersion: "26.6")
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        func nextWindowsRequest(
            from upstream: TestUpstreamClient,
            startingAt startIndex: Int
        ) async throws -> Data {
            for index in startIndex..<(startIndex + 3) {
                let request = try await sentValue(
                    from: upstream,
                    at: index,
                    timeout: .seconds(2)
                )
                if methodName(from: request) == "tools/list" {
                    await upstream.yield(
                        .message(
                            try makeDocumentationToolsListResponse(
                                id: try extractUpstreamID(from: request),
                                tools: [toolDescriptor(name: "XcodeRead")]
                            )
                        )
                    )
                    continue
                }
                return request
            }
            throw TimeoutError()
        }

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await nextWindowsRequest(from: upstream0, startingAt: 0)
        #expect(methodName(from: request0) == "tools/call")
        #expect(toolCallName(from: request0) == "XcodeListWindows")
        let message0 = "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"

        let request1 = try await nextWindowsRequest(from: upstream1, startingAt: 0)
        #expect(methodName(from: request1) == "tools/call")
        #expect(toolCallName(from: request1) == "XcodeListWindows")
        let message1 = "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: message0
                )
            )
        )
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: message1
                )
            )
        )

        let result = try await task.value
        guard case .object(let resultObject) = result,
            case .object(let structuredContent)? = resultObject["structuredContent"],
            case .string(let mergedMessage)? = structuredContent["message"]
        else {
            Issue.record("expected merged XcodeListWindows structuredContent")
            return
        }
        #expect(mergedMessage.components(separatedBy: "xcode-mcpkit:").count == 3)
        #expect(mergedMessage.contains("/Work/A.xcworkspace"))
        #expect(mergedMessage.contains("/Work/B.xcworkspace"))

        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target0,
                    0,
                    [
                        ownerBoundToolDescriptor(name: "XcodeListNavigatorIssues"),
                        ownerBoundToolDescriptor(name: "XcodeSomeWorkspaceScopedTool"),
                        toolDescriptor(name: "XcodeRead"),
                    ]
                ),
                (
                    target1,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "XcodeListNavigatorIssues"),
                        ownerBoundToolDescriptor(name: "XcodeSomeWorkspaceScopedTool"),
                        toolDescriptor(name: "XcodeRead"),
                    ]
                ),
            ]
        )

        let tabARequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeListNavigatorIssues",
                "arguments": [
                    "tabIdentifier": "tab-a"
                ],
            ],
        ]
        let tabBRequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeListNavigatorIssues",
                "arguments": [
                    "tabIdentifier": "tab-b"
                ],
            ],
        ]
        let workspaceBRequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeSomeWorkspaceScopedTool",
                "arguments": [
                    "workspacePath": "/Work/B.xcworkspace"
                ],
            ],
        ]
        let genericTabARequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeRead",
                "arguments": [
                    "tabIdentifier": "tab-a"
                ],
            ],
        ]
        let genericWorkspaceBRequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeRead",
                "arguments": [
                    "workspacePath": "/Work/B.xcworkspace"
                ],
            ],
        ]
        #expect(manager.preferredUpstreamIndex(for: tabARequest) == 0)
        #expect(manager.preferredUpstreamIndex(for: tabBRequest) == 1)
        #expect(manager.preferredUpstreamIndex(for: workspaceBRequest) == 1)
        #expect(manager.preferredUpstreamIndex(for: genericTabARequest) == nil)
        #expect(manager.preferredUpstreamIndex(for: genericWorkspaceBRequest) == nil)
        await manager.shutdown()
    }

    @Test func sessionManagerXcodeListWindowsRetriesSiblingBeforeDroppingProcessRoute()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let unavailableUpstream = AlwaysUnavailableUpstreamClient(reason: .startFailed)
        let siblingUpstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 515, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [unavailableUpstream, siblingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }

        try await waitForSentCount(unavailableUpstream, count: 1, timeoutSeconds: 2)
        let siblingRequest = try await sentValue(from: siblingUpstream, at: 0, timeout: .seconds(2))
        #expect(toolCallName(from: siblingRequest) == "XcodeListWindows")
        let message = "* tabIdentifier: tab-sibling, workspacePath: /Work/S.xcworkspace"
        await siblingUpstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: siblingRequest),
                    message: message
                )
            )
        )

        let result = try await task.value
        guard case .object(let resultObject) = result,
            case .object(let structuredContent)? = resultObject["structuredContent"],
            case .string(let resultMessage)? = structuredContent["message"]
        else {
            Issue.record("expected XcodeListWindows structuredContent")
            return
        }
        #expect(resultMessage.contains("xcode-mcpkit:"))
        #expect(resultMessage.contains("/Work/S.xcworkspace"))
        #expect(manager.documentationCandidateProcessIDs() == Set([target.processID]))
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 1, [ownerBoundToolDescriptor(name: "XcodeListNavigatorIssues")])
            ]
        )
        #expect(
            manager.preferredUpstreamIndex(for: [
                "method": "tools/call",
                "params": [
                    "name": "XcodeListNavigatorIssues",
                    "arguments": [
                        "tabIdentifier": "tab-sibling"
                    ],
                ],
            ]) == 1)
    }

    @Test func sessionManagerXcodeListWindowsRetriesSiblingAfterToolError()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let firstUpstream = TestUpstreamClient()
        let siblingUpstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 516, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [firstUpstream, siblingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }

        let firstRequest = try await sentValue(from: firstUpstream, at: 0, timeout: .seconds(2))
        #expect(toolCallName(from: firstRequest) == "XcodeListWindows")
        await firstUpstream.yield(
            .message(
                try makeXcodeListWindowsToolErrorResponse(
                    id: try extractUpstreamID(from: firstRequest),
                    message: "XcodeListWindows failed"
                )
            )
        )

        let siblingRequest = try await sentValue(from: siblingUpstream, at: 0, timeout: .seconds(2))
        #expect(toolCallName(from: siblingRequest) == "XcodeListWindows")
        let message = "* tabIdentifier: tab-tool-error, workspacePath: /Work/T.xcworkspace"
        await siblingUpstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: siblingRequest),
                    message: message
                )
            )
        )

        let result = try await task.value
        guard case .object(let resultObject) = result,
            case .object(let structuredContent)? = resultObject["structuredContent"],
            case .string(let resultMessage)? = structuredContent["message"]
        else {
            Issue.record("expected XcodeListWindows structuredContent")
            return
        }
        #expect(resultMessage.contains("xcode-mcpkit:"))
        #expect(resultMessage.contains("/Work/T.xcworkspace"))
        #expect(manager.documentationCandidateProcessIDs() == Set([target.processID]))
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 1, [ownerBoundToolDescriptor(name: "XcodeListNavigatorIssues")])
            ]
        )
        #expect(
            manager.preferredUpstreamIndex(for: [
                "method": "tools/call",
                "params": [
                    "name": "XcodeListNavigatorIssues",
                    "arguments": [
                        "tabIdentifier": "tab-tool-error"
                    ],
                ],
            ]) != nil)
    }

    @Test func sessionManagerRejectsDuplicateWorkspaceOwnersAcrossProcesses() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 512, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 513, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target0,
                    0,
                    [
                        ownerBoundToolDescriptor(name: "XcodeSomeWorkspaceScopedTool"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
                (
                    target1,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "XcodeSomeWorkspaceScopedTool"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await upstream0.nextSent(
            startingAt: 0,
            matching: {
                methodName(from: $0) == "tools/call"
                    && toolCallName(from: $0) == "XcodeListWindows"
            }
        )
        let request1 = try await upstream1.nextSent(
            startingAt: 0,
            matching: {
                methodName(from: $0) == "tools/call"
                    && toolCallName(from: $0) == "XcodeListWindows"
            }
        )
        let workspacePath = "/Work/Shared.xcworkspace"
        let message0 = "* tabIdentifier: tab-a, workspacePath: \(workspacePath)"
        let message1 = "* tabIdentifier: tab-b, workspacePath: \(workspacePath)"
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: message0
                )
            )
        )
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: message1
                )
            )
        )

        let result = try await task.value
        guard case .object(let resultObject) = result,
            case .object(let structuredContent)? = resultObject["structuredContent"],
            case .string(let mergedMessage)? = structuredContent["message"]
        else {
            Issue.record("expected merged XcodeListWindows structuredContent")
            return
        }
        #expect(mergedMessage.components(separatedBy: "xcode-mcpkit:").count == 3)
        #expect(mergedMessage.contains(workspacePath))

        let workspaceRequest: [String: Any] = [
            "method": "tools/call",
            "params": [
                "name": "XcodeSomeWorkspaceScopedTool",
                "arguments": [
                    "workspacePath": workspacePath
                ],
            ],
        ]
        #expect(manager.preferredUpstreamIndex(for: workspaceRequest) == nil)
        let refreshStart0 = await upstream0.sentCount()
        let refreshStart1 = await upstream1.sentCount()
        let decisionTask = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 8701,
                    name: "XcodeSomeWorkspaceScopedTool",
                    arguments: ["workspacePath": workspacePath]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }
        let refreshRequest0 = try await upstream0.nextSent(
            startingAt: refreshStart0,
            matching: {
                methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
            }
        )
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: refreshRequest0),
                    message: message0
                )
            )
        )
        let refreshRequest1 = try await upstream1.nextSent(
            startingAt: refreshStart1,
            matching: {
                methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
            }
        )
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: refreshRequest1),
                    message: message1
                )
            )
        )
        let decision = await decisionTask.value
        guard case .reject(let errors) = decision else {
            Issue.record("expected duplicate workspace owner to reject")
            return
        }
        #expect(errors.map(\.id.key) == ["8701"])
        #expect(errors.first?.message.contains("conflicting Xcode window owners") == true)
    }

    @Test func unavailableCachedWorkspaceOwnerDoesNotConflictWithAvailableOwner()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let unavailableTarget = xcodeProcessTarget(processID: 616, xcodeVersion: "27.0")
        let availableTarget = xcodeProcessTarget(processID: 617, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: unavailableTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: availableTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (unavailableTarget, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (availableTarget, 1, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_unavailable_stale_owner"
        )
        #expect(manager.unavailableXcodeProcessIDs().contains(unavailableTarget.processID))

        let workspacePath = "/Work/SharedAfterUnavailable.xcworkspace"
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: stale-tab, workspacePath: \(workspacePath)"
                    ]
                ]),
                upstreamIndex: 0
            )
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: live-tab, workspacePath: \(workspacePath)"
                    ]
                ]),
                upstreamIndex: 1
            )
        )

        let request = toolsCallObject(
            id: 8702,
            name: "BuildProject",
            arguments: ["workspacePath": workspacePath]
        )
        #expect(manager.preferredUpstreamIndex(for: request) == 1)
        let decision = await manager.toolRoutingDecision(
            for: request,
            requestTimeoutOverride: .seconds(2)
        )
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func unusableCachedWorkspaceOwnerDoesNotConflictWithUsableOwner()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let unusableTarget = xcodeProcessTarget(processID: 636, xcodeVersion: "27.0")
        let usableTarget = xcodeProcessTarget(processID: 637, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: unusableTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: usableTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (unusableTarget, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (usableTarget, 1, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )

        let workspacePath = "/Work/SharedAfterUnusable.xcworkspace"
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: stale-tab, workspacePath: \(workspacePath)"
                    ]
                ]),
                upstreamIndex: 0
            )
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: live-tab, workspacePath: \(workspacePath)"
                    ]
                ]),
                upstreamIndex: 1
            )
        )

        let request = toolsCallObject(
            id: 8708,
            name: "BuildProject",
            arguments: ["workspacePath": workspacePath]
        )
        #expect(manager.preferredUpstreamIndex(for: request) == 1)
        let decision = await manager.toolRoutingDecision(
            for: request,
            requestTimeoutOverride: .seconds(2)
        )
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func proxyTabIdentifierDisambiguatesDuplicateWorkspaceOwners() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 618, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 619, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [ownerBoundToolDescriptor(name: "BuildProject")]),
            ]
        )

        let workspacePath = "/Work/SharedWithProxyTab.xcworkspace"
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: \(workspacePath)"
                    ]
                ]),
                upstreamIndex: 0
            )
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-b, workspacePath: \(workspacePath)"
                    ]
                ]),
                upstreamIndex: 1
            )
        )

        let proxyTabIdentifier = WindowOwnershipIdentity.makeProxyTabIdentifier(
            processID: target1.processID,
            rawTabIdentifier: "tab-b",
            workspacePath: workspacePath
        )
        let request = toolsCallObject(
            id: 8703,
            name: "BuildProject",
            arguments: [
                "tabIdentifier": proxyTabIdentifier,
                "workspacePath": workspacePath,
            ]
        )
        #expect(manager.preferredUpstreamIndex(for: request) == 1)
        let decision = await manager.toolRoutingDecision(
            for: request,
            requestTimeoutOverride: .seconds(2)
        )
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func proxyTabIdentifierDisambiguatesRawTabCollisionWithinProcess() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 620, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target,
                    0,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                )
            ]
        )

        let workspaceA = "/Work/RawCollisionA.xcworkspace"
        let workspaceB = "/Work/RawCollisionB.xcworkspace"
        let windowsMessage =
            "* tabIdentifier: reused-tab, workspacePath: \(workspaceA)\n"
            + "* tabIdentifier: reused-tab, workspacePath: \(workspaceB)"
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": windowsMessage
                    ]
                ]),
                upstreamIndex: 0
            )
        )

        let ambiguousTask = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 8705,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "reused-tab"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }
        let refreshRequest = try await upstream.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: refreshRequest),
                    message: windowsMessage
                )
            )
        )
        let ambiguousDecision = await ambiguousTask.value
        guard case .reject(let errors) = ambiguousDecision else {
            Issue.record("expected raw tab collision within one process to reject")
            return
        }
        #expect(errors.map(\.id.key) == ["8705"])
        #expect(errors.first?.message.contains("ambiguous raw Xcode tabIdentifier") == true)

        let proxyTabA = WindowOwnershipIdentity.makeProxyTabIdentifier(
            processID: target.processID,
            rawTabIdentifier: "reused-tab",
            workspacePath: workspaceA
        )
        let proxyTabB = WindowOwnershipIdentity.makeProxyTabIdentifier(
            processID: target.processID,
            rawTabIdentifier: "reused-tab",
            workspacePath: workspaceB
        )
        #expect(proxyTabA != proxyTabB)
        let request = toolsCallObject(
            id: 8704,
            name: "BuildProject",
            arguments: [
                "tabIdentifier": proxyTabB,
                "workspacePath": workspaceB,
            ]
        )
        #expect(manager.preferredUpstreamIndex(for: request) == 0)
        let decision = await manager.toolRoutingDecision(
            for: request,
            requestTimeoutOverride: .seconds(2)
        )
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [0])
    }

    @Test func sessionManagerSkipsUninitializedProcessRoutesDuringWindowFanout()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 514, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 515, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let firstUpstream0StartIndex = await upstream0.sentCount()
        let firstUpstream1StartIndex = await upstream1.sentCount()
        let firstTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }
        let firstRequest = try await sentValue(
            from: upstream0,
            startingAt: firstUpstream0StartIndex,
            matching: {
                methodName(from: $0) == "tools/call"
                    && toolCallName(from: $0) == "XcodeListWindows"
            },
            timeout: .seconds(2),
            description: "waiting for first XcodeListWindows fanout request"
        )
        #expect(await upstream1.sentCount() == firstUpstream1StartIndex)
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: firstRequest),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        _ = try await firstTask.value
        #expect(await upstream1.sentCount() == firstUpstream1StartIndex)

        manager.markUpstreamInitialized(upstreamIndex: 1)
        let secondUpstream0StartIndex = await upstream0.sentCount()
        let secondUpstream1StartIndex = await upstream1.sentCount()
        let secondTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }
        let secondRequest0 = try await sentValue(
            from: upstream0,
            startingAt: secondUpstream0StartIndex,
            matching: {
                methodName(from: $0) == "tools/call"
                    && toolCallName(from: $0) == "XcodeListWindows"
            },
            timeout: .seconds(2),
            description: "waiting for second XcodeListWindows fanout request on upstream 0"
        )
        let secondRequest1 = try await sentValue(
            from: upstream1,
            startingAt: secondUpstream1StartIndex,
            matching: {
                methodName(from: $0) == "tools/call"
                    && toolCallName(from: $0) == "XcodeListWindows"
            },
            timeout: .seconds(2),
            description: "waiting for second XcodeListWindows fanout request on upstream 1"
        )
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: secondRequest0),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: secondRequest1),
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )
        _ = try await secondTask.value
    }

    @Test func mergedXcodeListWindowsPreservesToolErrors() throws {
        let successMessage = "* tabIdentifier: tab-ok, workspacePath: /Work/OK.xcworkspace"
        let success = try jsonValue([
            "content": [
                [
                    "type": "text",
                    "text": "{\"message\":\"\(successMessage)\"}",
                ]
            ],
            "structuredContent": [
                "message": successMessage
            ],
        ])
        let error = try jsonValue([
            "content": [
                [
                    "type": "text",
                    "text": "XcodeListWindows failed",
                ]
            ],
            "isError": true,
        ])

        let partialMerge = try #require(
            RuntimeCoordinator.mergedXcodeListWindowsResult([error, success])
        )
        guard case .object(let partialObject) = partialMerge,
            case .object(let structuredContent)? = partialObject["structuredContent"],
            case .string(let mergedMessage)? = structuredContent["message"]
        else {
            Issue.record("expected merged success result")
            return
        }
        #expect(mergedMessage == successMessage)

        let failedMerge = try #require(
            RuntimeCoordinator.mergedXcodeListWindowsResult([error])
        )
        guard case .object(let failedObject) = failedMerge else {
            Issue.record("expected tool error result")
            return
        }
        guard case .bool(true)? = failedObject["isError"] else {
            Issue.record("expected merged failure to preserve isError")
            return
        }
    }

}
