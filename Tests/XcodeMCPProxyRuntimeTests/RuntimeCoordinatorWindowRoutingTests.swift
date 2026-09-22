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
struct RuntimeCoordinatorWindowRoutingTests {
    @Test func liveXcodeListWindowsClearsOwnersForCatalogFilteredRoutes() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 626, xcodeVersion: "26.6")
        let target1 = xcodeProcessTarget(processID: 627, xcodeVersion: "27.0")
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
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")]),
                (target1, 1, [toolDescriptor(name: "XcodeListWindows")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: stale-tab, workspacePath: /Work/Stale.xcworkspace"
                    ]
                ]),
                upstreamIndex: 0
            )
        )
        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 1101,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "stale-tab"]
                )
            ) == 0
        )

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }

        let request = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        #expect(await upstream0.sentCount() == 0)

        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request),
                    message: "* tabIdentifier: live-tab, workspacePath: /Work/Live.xcworkspace"
                )
            )
        )

        _ = try await task.value
        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 1102,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "stale-tab"]
                )
            ) == nil
        )
    }

    @Test func liveXcodeListWindowsSkipsCatalogedRoutesWithoutTool() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 622, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 623, xcodeVersion: "26.6")
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
                (target0, 0, [toolDescriptor(name: "DocumentationSearch")]),
                (target1, 1, [toolDescriptor(name: "BuildProject")]),
            ]
        )

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.unavailable) {
            _ = try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        #expect(await upstream0.sentCount() == 0)
        #expect(await upstream1.sentCount() == 0)
    }

    @Test func ownerBoundToolRefreshesWindowsOnCacheMissBeforeRouting() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 620, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 621, xcodeVersion: "26.6")
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
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
                (
                    target1,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 102,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-b"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await upstream0.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )

        let decision = await task.value
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundToolRefreshesStaleWorkspaceConflictBeforeRejecting()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 632, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 633, xcodeVersion: "26.6")
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
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
                (
                    target1,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )

        let workspacePath = "/Work/StaleConflict.xcworkspace"
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
        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 8706,
                    name: "BuildProject",
                    arguments: ["workspacePath": workspacePath]
                )
            ) == nil
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 8706,
                    name: "BuildProject",
                    arguments: ["workspacePath": workspacePath]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await upstream0.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: ""
                )
            )
        )
        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: "* tabIdentifier: live-tab, workspacePath: \(workspacePath)"
                )
            )
        )

        let decision = await task.value
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundRefreshUsesUncatalogedRoutesForOwnerDiscovery() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 625, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 626, xcodeVersion: "26.6")
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
                (target0, 0, [ownerBoundToolDescriptor(name: "BuildProject")])
            ]
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 109,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-uncataloged"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        #expect(await upstream0.sentCount() == 0)
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: "* tabIdentifier: tab-uncataloged, "
                        + "workspacePath: /Work/Uncataloged.xcworkspace"
                )
            )
        )

        let decision = await task.value
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundToolRejectsWhenOwnerCannotBeResolvedAfterRefresh() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 630, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 631, xcodeVersion: "26.6")
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
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
                (
                    target1,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                ),
            ]
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 103,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "missing-tab"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request0 = try await upstream0.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request0),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        let request1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request1),
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )

        let decision = await task.value
        guard case .reject(let errors) = decision else {
            Issue.record("expected unresolved owner-bound request to reject")
            return
        }
        #expect(errors.map(\.id.key) == ["103"])
        #expect(errors.first?.message.contains("unable to resolve Xcode window owner") == true)
    }

    @Test func ownerBoundToolRejectsWhenOwnerProcessLacksTool() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 640, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 641, xcodeVersion: "26.6")
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
                (target1, 1, [ownerBoundToolDescriptor(name: "XcodeRead")]),
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                    ]
                ]),
                upstreamIndex: 1
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 104,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-b"]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        guard case .reject(let errors) = decision else {
            Issue.record("expected missing owner capability to reject")
            return
        }
        #expect(errors.map(\.id.key) == ["104"])
        #expect(errors.first?.message.contains("not available") == true)
    }

    @Test func sessionManagerLiveXcodeListWindowsCancellationCancelsLastWaiterLoad()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let request = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: request) == "tools/call")

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled XcodeListWindows waiter should not complete successfully")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError but received \(error)")
        }

        _ = try await waitWithTimeout("waiting for cancelled XcodeListWindows waiter cleanup") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.windows == 0 && $0.inFlightControlPlaneRequests.isEmpty
            }
        }
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func sessionManagerPromotedLiveXcodeListWindowsCancellationRemovesMigratedWaiter()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            clock: clocks.clock
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let firstTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        _ = try await waitWithTimeout(
            "waiting for first promoted XcodeListWindows waiter to attach"
        ) {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.windows == 1
            }
        }
        let firstLoad = try #require(
            await manager.controlPlaneCoordinator.windowLoadSnapshotForTesting(route: .anyHealthy)
        )

        clocks.uptimeClock.advance(by: .nanoseconds(120_000_001))

        let secondTask = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        _ = try await waitWithTimeout(
            "waiting for promoted XcodeListWindows waiters to attach"
        ) {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.windows == 2
            }
        }
        let promotedLoad = try #require(
            await manager.controlPlaneCoordinator.windowLoadSnapshotForTesting(route: .anyHealthy)
        )
        #expect(promotedLoad.loadID != firstLoad.loadID)
        #expect(promotedLoad.waiterCount == 2)
        #expect(firstLoad.rpcHandle.isCancelled())

        firstTask.cancel()
        do {
            _ = try await firstTask.value
            Issue.record("first promoted XcodeListWindows waiter should be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for promoted XcodeListWindows waiter but received \(error)")
        }

        _ = try await waitWithTimeout("waiting for first promoted XcodeListWindows waiter cleanup") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.windows == 1
            }
        }
        let remainingLoad = try #require(
            await manager.controlPlaneCoordinator.windowLoadSnapshotForTesting(route: .anyHealthy)
        )
        #expect(remainingLoad.loadID == promotedLoad.loadID)
        #expect(remainingLoad.waiterCount == 1)
        #expect(promotedLoad.rpcHandle.isCancelled() == false)

        secondTask.cancel()
        do {
            _ = try await secondTask.value
            Issue.record("second promoted XcodeListWindows waiter should be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for promoted XcodeListWindows waiter but received \(error)")
        }

        _ = try await waitWithTimeout("waiting for promoted XcodeListWindows waiter cleanup") {
            try await manager.controlPlaneDebugMirror.waitForSnapshot {
                $0.waiterCounts.windows == 0 && $0.inFlightControlPlaneRequests.isEmpty
            }
        }
        #expect(
            await manager.controlPlaneCoordinator.windowLoadSnapshotForTesting(route: .anyHealthy)?
                .loadID == nil
        )
        #expect(promotedLoad.rpcHandle.isCancelled())
        #expect(manager.debugSnapshot().upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func shutdownDrainsCancelledLiveXcodeListWindowsLoadWithoutUpstreamResponse()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        var didShutdown = false
        defer {
            if didShutdown == false {
                manager.shutdownAndWait()
            }
        }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }
        let request = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(methodName(from: request) == "tools/call")

        task.cancel()
        try await waitWithTimeout(
            "waiting for shutdown to drain cancelled XcodeListWindows load",
            timeout: .seconds(2)
        ) {
            await manager.shutdown()
        }
        didShutdown = true

        do {
            _ = try await waitWithTimeout(
                "waiting for cancelled XcodeListWindows task",
                timeout: .seconds(2)
            ) {
                try await task.value
            }
            Issue.record("cancelled XcodeListWindows waiter should not complete successfully")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError but received \(error)")
        }
    }

    @Test func controlPlaneRPCHandleCancelBeforeQueueStartCapturesQueuedState() {
        let handle = ControlPlane.RPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlane.RPCCancelSnapshot?>(nil)

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == nil)
        #expect(snapshot?.upstreamIndex == nil)
        #expect(snapshot?.requestIDKey == nil)
        #expect(handle.markRegistered(registrationToken: UUID(), operationLease: testOperationLease(0)) == false)
    }

    @Test func controlPlaneRPCHandleCancelBeforeHandlerInstallationTerminatesWithoutReplay() async {
        let handle = ControlPlane.RPCHandle()
        let callbackCount = NIOLockedValueBox(0)

        let firstDelivery = handle.cancel(cause: .timedOut)
        let repeatedDelivery = handle.cancel()

        #expect(firstDelivery === repeatedDelivery)
        #expect(await firstDelivery?.wait() == .noLongerApplicable)
        #expect(handle.installCancelWithDelivery { _, _ in
            callbackCount.withLockedValue { $0 += 1 }
        } == false)
        #expect(callbackCount.withLockedValue { $0 } == 0)
        #expect(
            handle.markRegistered(
                registrationToken: UUID(),
                operationLease: testOperationLease(0)
            ) == false
        )
    }

    @Test func controlPlaneRPCHandlePublishesSharedDeliveryBeforeInvokingCancellation() async {
        let handle = ControlPlane.RPCHandle()
        let callbackDelivery = NIOLockedValueBox<ControlPlane.RPCCancellationDelivery?>(nil)
        let callbackCause = NIOLockedValueBox<ControlPlane.RPCCancellationCause?>(nil)
        let callbackCount = NIOLockedValueBox(0)
        let reentrantDelivery = NIOLockedValueBox<ControlPlane.RPCCancellationDelivery?>(nil)

        #expect(handle.installCancelWithDelivery { snapshot, delivery in
            callbackCause.withLockedValue { $0 = snapshot.cause }
            callbackDelivery.withLockedValue { $0 = delivery }
            callbackCount.withLockedValue { $0 += 1 }
            reentrantDelivery.withLockedValue { $0 = handle.cancel() }
        })

        let firstDelivery = handle.cancel(cause: .timedOut)
        let repeatedDelivery = handle.cancel()
        let installedDelivery = callbackDelivery.withLockedValue { $0 }

        #expect(firstDelivery === repeatedDelivery)
        #expect(firstDelivery === installedDelivery)
        #expect(firstDelivery === reentrantDelivery.withLockedValue { $0 })
        #expect(callbackCause.withLockedValue { $0 } == .timedOut)
        #expect(callbackCount.withLockedValue { $0 } == 1)

        installedDelivery?.complete(.delivered)
        #expect(await firstDelivery?.wait() == .delivered)
    }

    @Test func controlPlaneRPCRejectsHandleCancelledBeforeInstallationWithoutLeakingLease()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let upstream = TestUpstreamClient()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: group.next(),
            upstreams: [upstream],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let handle = ControlPlane.RPCHandle()

        #expect(await handle.cancel()?.wait() == .noLongerApplicable)
        await #expect(throws: CancellationError.self) {
            try await manager.performControlPlaneRPC(
                route: .pinnedUpstream(0),
                purpose: "cancelled-before-handler-installation",
                label: "cancelled-before-handler-installation",
                requestObject: JSONRPC.Wire.requestObject(
                    id: "cancelled-before-handler-installation",
                    method: "tools/list"
                ),
                requestTimeout: .seconds(5),
                rpcHandle: handle
            )
        }

        await manager.drainRuntimeTasksForTesting()
        #expect(await upstream.sentCount() == 0)
        let schedulerSnapshot = manager.upstreamSlotScheduler.debugSnapshot()
        #expect(schedulerSnapshot.queuedRequestCount == 0)
        #expect(schedulerSnapshot.activeLeaseCountByUpstream.isEmpty)
    }

    @Test func controlPlaneRPCCancelBetweenPreflightAndEnqueueRemovesQueuedRequest()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let handle = ControlPlane.RPCHandle()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
            testHooks: RuntimeCoordinatorTestHooks(
                controlPlaneRPCWillEnqueue: {
                    handle.cancel()
                }
            ),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)

        await #expect(throws: CancellationError.self) {
            try await waitWithTimeout(
                "waiting for pre-enqueue control-plane RPC cancellation",
                timeout: .seconds(2)
            ) {
                try await manager.performControlPlaneRPC(
                    route: .pinnedUpstream(0),
                    purpose: "pre-enqueue-cancellation",
                    label: "tools/list",
                    requestObject: JSONRPC.Wire.requestObject(
                        id: "pre-enqueue-cancellation",
                        method: "tools/list"
                    ),
                    requestTimeout: .seconds(5),
                    rpcHandle: handle
                )
            }
        }
        let schedulerSnapshot = manager.upstreamSlotScheduler.debugSnapshot()
        #expect(schedulerSnapshot.queuedRequestCount == 0)
        #expect(schedulerSnapshot.activeLeaseCountByUpstream.isEmpty)
    }

    @Test func controlPlaneRPCCancelBeforeLeaseActivationReleasesReservedSlot()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let handle = ControlPlane.RPCHandle()
        let upstream = TestUpstreamClient()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamRequestWillStart: { _, descriptor in
                    guard descriptor.label == "cancel-before-lease-activation" else {
                        return
                    }
                    handle.cancel()
                }
            ),
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)

        await #expect(throws: CancellationError.self) {
            try await waitWithTimeout(
                "waiting for pre-activation control-plane RPC cancellation",
                timeout: .seconds(2)
            ) {
                try await manager.performControlPlaneRPC(
                    route: .pinnedUpstream(0),
                    purpose: "pre-activation-cancellation",
                    label: "cancel-before-lease-activation",
                    requestObject: JSONRPC.Wire.requestObject(
                        id: "pre-activation-cancellation",
                        method: "tools/list"
                    ),
                    requestTimeout: .seconds(5),
                    rpcHandle: handle
                )
            }
        }
        #expect(
            manager.upstreamSlotScheduler.debugSnapshot().activeLeaseCountByUpstream.isEmpty
        )

        let followUp = Task {
            try await manager.performControlPlaneRPC(
                route: .pinnedUpstream(0),
                purpose: "after-pre-activation-cancellation",
                label: "follow-up-tools-list",
                requestObject: JSONRPC.Wire.requestObject(
                    id: "after-pre-activation-cancellation",
                    method: "tools/list"
                ),
                requestTimeout: .seconds(5)
            )
        }
        let followUpRequest = try await sentValue(
            from: upstream,
            at: 0,
            timeout: .seconds(2)
        )
        await upstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: followUpRequest),
                    tools: []
                )
            )
        )
        _ = try await waitWithTimeout(
            "waiting for follow-up control-plane RPC",
            timeout: .seconds(2)
        ) {
            try await followUp.value
        }
    }

    @Test func controlPlaneRPCCancelBetweenIDAssignmentAndSendDoesNotCancelUpstream()
        async throws
    {
        let handle = ControlPlane.RPCHandle()
        let upstream = TestUpstreamClient()
        let replacements = NIOLockedValueBox<[TestUpstreamClient]>([])
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 5),
            upstreams: [upstream],
            unboundUpstreamFactory: {
                let replacement = TestUpstreamClient()
                replacements.withLockedValue { $0.append(replacement) }
                return replacement
            },
            testHooks: RuntimeCoordinatorTestHooks(
                controlPlaneRPCAssignedUpstreamID: {
                    handle.cancel()
                }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let originalLease = manager.operationLeaseForTest(upstreamIndex: 0)

        await #expect(throws: CancellationError.self) {
            try await waitWithTimeout(
                "waiting for assigned control-plane RPC cancellation",
                timeout: .seconds(2)
            ) {
                try await manager.performControlPlaneRPC(
                    route: .pinnedUpstream(0),
                    purpose: "assigned-cancellation",
                    label: "assigned-cancellation",
                    requestObject: JSONRPC.Wire.requestObject(
                        id: "assigned-cancellation",
                        method: "tools/list"
                    ),
                    requestTimeout: .seconds(5),
                    rpcHandle: handle
                )
            }
        }

        await manager.drainRuntimeTasksForTesting()
        #expect(await upstream.sentCount() == 0)
        #expect(replacements.withLockedValue(\.count) == 0)
        #expect(manager.upstreamTopology.validate(originalLease))
        #expect(
            manager.debugSnapshot().upstreams.first?.activeCorrelatedRequestCount == 0
        )
        #expect(
            manager.upstreamSlotScheduler.debugSnapshot()
                .activeLeaseCountByUpstream.isEmpty
        )
    }

    @Test
    func controlPlaneRPCTimeoutBeforeBarrieredSendDoesNotCancelUnsentRequestWithoutProvidedHandle()
        async throws
    {
        let initial = TestUpstreamClient()
        let replacement = TestUpstreamClient()
        let assignedUpstreamID = TestSignal()
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 5),
            upstreams: [initial],
            processRoutingEnabled: false,
            unboundUpstreamFactory: {
                replacement
            },
            testHooks: RuntimeCoordinatorTestHooks(
                controlPlaneRPCAssignedUpstreamID: {
                    assignedUpstreamID.signal()
                }
            ),
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        let initialLease = manager.operationLeaseForTest(upstreamIndex: 0)
        await initial.blockStop()
        defer {
            Task {
                await initial.releaseBlockedStop()
            }
        }

        let replacementResult = try #require(
            manager.replaceOrRetireInitializeChannel(
                initialLease.proof,
                expectedRouteID: nil,
                requestsBridgePoolRecovery: false
            )
        )
        try await initial.waitForBlockedStop()
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let request = Task {
            try await manager.performControlPlaneRPC(
                route: .pinnedUpstream(0),
                purpose: "barriered-timeout-without-provided-handle",
                label: "barriered-timeout-without-provided-handle",
                requestObject: JSONRPC.Wire.requestObject(
                    id: "barriered-timeout-without-provided-handle",
                    method: "tools/list"
                ),
                requestTimeout: .milliseconds(20)
            )
        }
        try await assignedUpstreamID.wait(
            description: "waiting for barriered control-plane RPC assignment"
        )

        do {
            _ = try await waitWithTimeout(
                "waiting for barriered control-plane RPC timeout",
                timeout: .seconds(2)
            ) {
                try await request.value
            }
            Issue.record("barriered control-plane RPC should time out")
        } catch is TimeoutError {
        } catch let error as ControlPlane.RequestError {
            #expect(error.underlying is TimeoutError)
        } catch {
            Issue.record("expected control-plane timeout but received \(error)")
        }
        #expect(await replacement.sentCount() == 0)
        #expect(manager.upstreamTopology.validate(replacementResult.operationLease))
        #expect(
            manager.upstreamSlotScheduler.debugSnapshot()
                .activeLeaseCountByUpstream[0] == 1
        )

        await initial.releaseBlockedStop()
        let originalRequest = try await sentValue(
            from: replacement,
            at: 0,
            timeout: .seconds(2)
        )
        #expect(methodName(from: originalRequest) == "tools/list")
        let cancellation = try await sentMessage(
            from: replacement,
            matching: { methodName(from: $0) == "notifications/cancelled" },
            timeout: .seconds(2)
        )
        #expect(
            try extractCancellationRequestID(from: cancellation)
                == extractUpstreamID(from: originalRequest)
        )
        await manager.drainRuntimeTasksForTesting()
        #expect(
            manager.upstreamSlotScheduler.debugSnapshot()
                .activeLeaseCountByUpstream.isEmpty
        )
    }

    @Test func topLevelRequestCancelBeforeLeaseActivationDoesNotSendUpstream()
        async throws
    {
        let config = makeConfig(requestTimeout: 5)
        let upstream = TestUpstreamClient()
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let sessionID = "session-top-level-pre-activation-cancel"
        let parentCancellationHandle = ClientMCPRequestExecutor.CancellationHandle(
            leaseID: UUID(),
            sessionID: sessionID,
            requestIDKeys: []
        )
        let fixture = RuntimeCoordinatorFixture(
            config: config,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamRequestWillStart: { _, descriptor in
                    guard descriptor.label == "resources/list" else { return }
                    guard let manager = runtimeBox.value else {
                        preconditionFailure("runtime unavailable during request start")
                    }
                    parentCancellationHandle.cancel(using: manager)
                }
            ),
            runtimeBox: runtimeBox
        )
        defer { fixture.shutdownAndWait() }
        _ = try await fixture.initializePrimary(on: upstream, sessionID: sessionID)

        let executor = ClientMCPRequestExecutor(
            config: config,
            sessionManager: fixture.manager,
            refreshCodeIssuesCoordinator: .makeDefault(),
            refreshCodeIssuesDebugState: RefreshCodeIssues.DebugState(
                defaultRequestTimeoutSeconds: config.requestTimeout
            )
        )
        let requestData = try JSONRPC.Wire.data(from: JSONRPC.Wire.requestObject(
            id: 2,
            method: "resources/list"
        ))
        let sentCountBeforeRequest = await upstream.sentCount()
        let operation = executor.handle(
            bodyData: requestData,
            headerSessionID: sessionID,
            headerSessionExists: true,
            prefersEventStream: false,
            eventLoop: fixture.eventLoop,
            parentCancellationHandle: parentCancellationHandle
        )

        await #expect(throws: CancellationError.self) {
            try await operation.future.get()
        }
        #expect(await upstream.sentCount() == sentCountBeforeRequest)
        #expect(
            fixture.manager.upstreamSlotScheduler.debugSnapshot()
                .activeLeaseCountByUpstream.isEmpty
        )

        let followUp = executor.handle(
            bodyData: requestData,
            headerSessionID: sessionID,
            headerSessionExists: true,
            prefersEventStream: false,
            eventLoop: fixture.eventLoop
        )
        let followUpRequest = try await sentValue(
            from: upstream,
            at: sentCountBeforeRequest,
            timeout: .seconds(2)
        )
        await upstream.yield(.message(try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": try extractUpstreamID(from: followUpRequest),
                "result": ["resources": []],
            ],
            options: []
        )))
        _ = try await waitWithTimeout(
            "waiting for request after pre-activation cancellation",
            timeout: .seconds(2)
        ) {
            try await followUp.future.get()
        }
    }

    @Test func controlPlaneRPCHandleCancelAfterRegisterCapturesRegistrationState() {
        let handle = ControlPlane.RPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlane.RPCCancelSnapshot?>(nil)
        let token = UUID()

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        #expect(handle.markRegistered(registrationToken: token, operationLease: testOperationLease(2)))

        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == token)
        #expect(snapshot?.upstreamIndex == nil)
        #expect(snapshot?.requestIDKey == nil)
        #expect(
            handle.markAssigned(registrationToken: token, operationLease: testOperationLease(2), requestIDKey: "req")
                == false)
    }

    @Test func controlPlaneRPCHandleCancelAfterAssignCapturesRequestMappingState() {
        let handle = ControlPlane.RPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlane.RPCCancelSnapshot?>(nil)
        let token = UUID()

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        #expect(handle.markRegistered(registrationToken: token, operationLease: testOperationLease(1)))
        #expect(
            handle.markAssigned(registrationToken: token, operationLease: testOperationLease(1), requestIDKey: "req-1"))

        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == token)
        #expect(snapshot?.upstreamIndex == 1)
        #expect(snapshot?.requestIDKey == "req-1")
    }

    @Test func controlPlaneRPCHandleCancelAfterSendUsesAssignedSnapshotUntilFinished() {
        let handle = ControlPlane.RPCHandle()
        let cancellation = NIOLockedValueBox<ControlPlane.RPCCancelSnapshot?>(nil)
        let token = UUID()

        handle.installCancel { snapshot in
            cancellation.withLockedValue { $0 = snapshot }
        }
        #expect(handle.markRegistered(registrationToken: token, operationLease: testOperationLease(0)))
        #expect(
            handle.markAssigned(
                registrationToken: token, operationLease: testOperationLease(0), requestIDKey: "req-after-send"))

        handle.cancel()

        let snapshot = cancellation.withLockedValue { $0 }
        #expect(snapshot?.registrationToken == token)
        #expect(snapshot?.upstreamIndex == 0)
        #expect(snapshot?.requestIDKey == "req-after-send")

        handle.markFinished()
        handle.cancel()
        let repeatedSnapshot = cancellation.withLockedValue { $0 }
        #expect(repeatedSnapshot?.requestIDKey == "req-after-send")
    }

    @Test func sessionManagerEagerInitializeRestartsAfterExit() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }
        #expect(manager.isInitialized() == false)

        _ = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))

        await upstream.yield(.exit(1))
        _ = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))
        _ = manager
    }

    @Test func initializeTimeoutRemainsBoundedWhenRequestTimeoutIsDisabled() throws {
        let timeout = MCP.MethodDispatcher.timeoutForInitialize(defaultSeconds: 0)
        #expect(timeout?.nanoseconds == TimeAmount.seconds(60).nanoseconds)
    }

    @Test func controlPlaneTimeoutStaysShortForSlowDiscoveryWork() throws {
        let disabledDefault = MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: 0)
        #expect(disabledDefault?.nanoseconds == TimeAmount.seconds(10).nanoseconds)

        let longDefault = MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: 300)
        #expect(longDefault?.nanoseconds == TimeAmount.seconds(10).nanoseconds)

        let shortDefault = MCP.MethodDispatcher.timeoutForControlPlane(defaultSeconds: 3)
        #expect(shortDefault?.nanoseconds == TimeAmount.seconds(3).nanoseconds)
    }

    @Test func sessionManagerStillAutoInitializesWhenRequestTimeoutIsDisabled() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 0)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        _ = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
    }

    @Test func xcodeChatClientVersionFallsBackToCodeAliasWhenExactStemMissing() {
        let version = InitializeHandshakeParams.xcodeChatClientVersion(
            for: "Claude",
            defaults: [
                "IDEChatClaudeCodeVersion": #"{"version":"9.9.9"}"#
            ]
        )

        #expect(version == "9.9.9")
    }

    @Test func xcodeChatClientVersionPrefersExactStemMatchOverGenericCodeAlias() {
        let version = InitializeHandshakeParams.xcodeChatClientVersion(
            for: "Claude",
            defaults: [
                "IDEChatClaudeVersion": #"{"version":"1.2.3"}"#,
                "IDEChatClaudeCodeVersion": #"{"version":"9.9.9"}"#,
            ]
        )

        #expect(version == "1.2.3")
    }

    @Test func sessionManagerSendsInitializedOnce() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let request = makeInitializeRequest(id: 1)
        let future = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: request,
            on: eventLoop
        )

        let sent = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID = try extractUpstreamID(from: sent)
        let response = try makeInitializeResponse(id: upstreamID)
        await upstream.yield(.message(response))

        _ = try await future.get()
        _ = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))

        let cached = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        let cachedResponse = try decodeJSON(from: try await cached.get())
        let cachedID = (cachedResponse["id"] as? NSNumber)?.intValue
        #expect(cachedID == 2)
        #expect((await upstream.sent()).count == 2)
    }

    @Test func sessionManagerSendsInitializedBeforeQueuedRequestAfterWarmInit() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1]
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        defer { activePromise.fail(CancellationError()) }
        try await occupyUpstreamSlot(
            on: manager,
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            eventLoop: eventLoop,
            completionPromise: activePromise
        )

        let queuedRequestData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": NSNumber(value: 99),
                "method": "tools/list",
            ],
            options: []
        )
        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/list",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let queuedLeaseID = manager.createRequestLease(descriptor: queuedDescriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: queuedDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                queuedLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex.upstreamIndex,
                timeout: nil
            )
            manager.sendUpstream(
                queuedRequestData,
                operationLease: selectedUpstreamIndex,
                ensureRunning: false,
                admission: nil,
                onRejected: {}
            )
            return eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))
        _ = try await queuedFuture.get()

        let initializedNotification = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))
        let queuedRequest = try await sentValue(from: upstream1, at: 2, timeout: .seconds(2))
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        #expect(methodName(from: queuedRequest) == "tools/list")

    }

    @Test func sessionManagerPrimaryExitClearsCachedInitializeResult() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // First init establishes the cached init result.
        let init1 = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let firstInit = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let upstreamID1 = try extractUpstreamID(from: firstInit)
        await upstream.yield(.message(try makeInitializeResponse(id: upstreamID1)))
        _ = try await init1.get()

        // Wait for notifications/initialized.
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        // Simulate primary upstream dying after init succeeded.
        let exitEventIndex = upstreamEvents.count()
        await upstream.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: exitEventIndex,
            description: "waiting for primary upstream exit"
        )
        #expect(manager.testStateSnapshot().hasInitResult == false)

        // A new downstream initialize must trigger a new upstream initialize (no cached response).
        let init2 = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        try await waitForSentCount(upstream, count: 3, timeoutSeconds: 2)
        let upstreamID2 = try extractUpstreamID(from: (await upstream.sent())[2])
        await upstream.yield(.message(try makeInitializeResponse(id: upstreamID2)))
        _ = try await init2.get()
    }

    @Test func sessionManagerPrimaryEagerRetryClearsCanonicalToolsCatalog() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        manager.seedCanonicalToolsCatalog(try #require(JSONValue(any: ["tools": []])), sourceUpstream: 0)
        #expect(manager.cachedToolsListResult() != nil)

        manager.startPrimaryEagerRetry()

        #expect(manager.cachedToolsListResult() == nil)
    }

    @Test func sessionManagerKeepsQueuedRequestsWaitingWhileReinitializeIsInFlight() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(config: config, eventLoop: eventLoop, upstreams: [upstream])
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let initRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        defer { activePromise.fail(CancellationError()) }
        try await occupyUpstreamSlot(
            on: manager,
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            eventLoop: eventLoop,
            completionPromise: activePromise
        )

        let queuedRequestData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": NSNumber(value: 199),
                "method": "tools/list",
            ],
            options: []
        )
        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/list",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let queuedLeaseID = manager.createRequestLease(descriptor: queuedDescriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: queuedDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                queuedLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex.upstreamIndex,
                timeout: nil
            )
            manager.sendUpstream(
                queuedRequestData,
                operationLease: selectedUpstreamIndex,
                ensureRunning: false,
                admission: nil,
                onRejected: {}
            )
            return eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        await upstream.yield(.exit(1))

        let reinitRequest = try await sentValue(from: upstream, at: 2, timeout: .seconds(2))
        #expect(manager.testStateSnapshot().upstream(id: 0)?.initInFlight == true)
        #expect(manager.debugSnapshot().queuedRequestCount == 1)
        let reinitUpstreamID = try extractUpstreamID(from: reinitRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: reinitUpstreamID)))
        _ = try await queuedFuture.get()

        let initializedNotification = try await sentValue(from: upstream, at: 3, timeout: .seconds(2))
        let queuedRequest = try await sentValue(from: upstream, at: 4, timeout: .seconds(2))
        #expect(methodName(from: initializedNotification) == "notifications/initialized")
        #expect(methodName(from: queuedRequest) == "tools/list")

    }

    @Test func sessionManagerRecoversWhenInitializeTimesOutDuringUpstreamExit() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let stateCleared = TestSignal()
        let resumeExit = DispatchSemaphore(value: 0)
        let recovered = TestSignal()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamExitStateCleared: { _ in
                    stateCleared.signal()
                    resumeExit.wait()
                },
                upstreamInitialized: { _ in recovered.signal() }
            )
        )
        defer { manager.shutdownAndWait() }
        defer { resumeExit.signal() }

        let initial = manager.registerInitialize(
            originalID: JSONRPC.ID(any: 1)!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        _ = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        await upstream.yield(.exit(1))
        try await stateCleared.wait(description: "waiting for exit before initialize settlement")
        manager.failInitPending(error: TimeoutError())
        do {
            _ = try await initial.get()
            Issue.record("the expired initialize request should fail")
        } catch {
            #expect(error is TimeoutError)
        }
        resumeExit.signal()

        let recovery = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))
        #expect(methodName(from: recovery) == "initialize")
        await upstream.yield(.message(try makeInitializeResponse(
            id: extractUpstreamID(from: recovery)
        )))
        try await recovered.wait(description: "waiting for recovery after initialize timeout")
        #expect(manager.isInitialized())
        #expect(manager.testStateSnapshot().upstream(id: 0)?.initInFlight == false)
    }

    @Test func sessionManagerConcurrentUpstreamExitsPreserveRecoveryInitialize() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let initializedUpstreams = LockedRecordedValues<Int>()
        let primaryStateCleared = TestSignal()
        let resumePrimaryExit = DispatchSemaphore(value: 0)
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamExitStateCleared: { index in
                    guard index == 0 else { return }
                    primaryStateCleared.signal()
                    resumePrimaryExit.wait()
                },
                upstreamInitialized: { initializedUpstreams.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }
        defer { resumePrimaryExit.signal() }

        let initial = manager.registerInitialize(
            originalID: JSONRPC.ID(any: 1)!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let firstPrimary = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        await upstream0.yield(.message(try makeInitializeResponse(
            id: extractUpstreamID(from: firstPrimary)
        )))
        _ = try await initial.get()
        let firstSecondary = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        await upstream1.yield(.message(try makeInitializeResponse(
            id: extractUpstreamID(from: firstSecondary)
        )))
        try await waitForInitializedUpstreams(initializedUpstreams, expected: [0, 1])

        await upstream0.yield(.exit(1))
        try await primaryStateCleared.wait(description: "waiting for primary exit detachment")
        await upstream1.yield(.exit(1))
        let recovery = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        #expect(methodName(from: recovery) == "initialize")
        resumePrimaryExit.signal()
        await upstream0.yield(.message(try makeInitializeResponse(
            id: extractUpstreamID(from: recovery)
        )))
        let recovered = try await waitForRecordedValue(
            initializedUpstreams,
            at: 2,
            description: "waiting for initialization after concurrent upstream exits"
        )
        #expect(recovered == 0)
        #expect(manager.isInitialized())
        #expect(manager.testStateSnapshot().upstream(id: 0)?.initInFlight == false)
        let initialized = try await sentValue(from: upstream0, at: 3, timeout: .seconds(2))
        #expect(methodName(from: initialized) == "notifications/initialized")
    }

    @Test func sessionManagerSecondaryExitClearsCachedInitializeResultWhenPrimaryAlreadyDown()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let initializedUpstreams = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) },
                upstreamInitialized: { initializedUpstreams.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // First init establishes the cached init result (primary only).
        let init1 = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        let firstInit = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let upstreamID0 = try extractUpstreamID(from: firstInit)
        await upstream0.yield(.message(try makeInitializeResponse(id: upstreamID0)))
        _ = try await init1.get()

        // Warm init -> upstream1
        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1Messages = await upstream1.sent()
        let upstreamID1 = try extractUpstreamID(from: init1Messages[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: upstreamID1)))

        // Wait for per-upstream notifications/initialized.
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)
        try await waitForInitializedUpstreams(initializedUpstreams, expected: [0, 1])

        // Simulate primary dying first (cached init result should remain because upstream1 is still initialized).
        let primaryExitEventIndex = upstreamEvents.count()
        await upstream0.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: primaryExitEventIndex,
            description: "waiting for primary upstream exit"
        )
        #expect(manager.testStateSnapshot().upstream(id: 0)?.isInitialized == false)
        let primaryRecoveryInitialize = try await sentValue(
            from: upstream0,
            at: 2,
            timeout: .seconds(2)
        )

        // Now simulate the last initialized upstream dying too.
        let secondaryExitEventIndex = upstreamEvents.count()
        await upstream1.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: secondaryExitEventIndex,
            description: "waiting for secondary upstream exit"
        )
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == false)

        // Ensure the cached init result is cleared before asserting that a new downstream initialize
        // triggers a fresh upstream initialize. This avoids race/flakiness where the exit event hasn't
        // been processed yet on the event loop.
        #expect(manager.testStateSnapshot().hasInitResult == false)

        // A new downstream initialize joins the already in-flight primary recovery initialize.
        let init2 = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 2))!,
            requestObject: makeInitializeRequest(id: 2),
            on: eventLoop
        )
        #expect(await upstream0.sentCount() == 3)
        let upstreamID2 = try extractUpstreamID(from: primaryRecoveryInitialize)
        await upstream0.yield(.message(try makeInitializeResponse(id: upstreamID2)))
        _ = try await init2.get()
    }

    @Test func sessionManagerInFlightWarmInitializeRepublishesAfterLastSupporterExits()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let upstream0Initialized = TestSignal()
        let upstream1Initialized = TestSignal()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) },
                upstreamInitialized: { upstreamIndex in
                    if upstreamIndex == 0 {
                        upstream0Initialized.signal()
                    } else if upstreamIndex == 1 {
                        upstream1Initialized.signal()
                    }
                }
            )
        )
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(
            .message(try makeInitializeResponse(id: init0ID, serverName: "cached-handshake"))
        )

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(
            .message(try makeInitializeResponse(id: init1ID, serverName: "cached-handshake"))
        )

        // Wait for per-upstream notifications/initialized.
        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))
        try await upstream0Initialized.wait(
            description: "waiting for primary upstream initialization"
        )
        try await upstream1Initialized.wait(
            description: "waiting for secondary upstream initialization"
        )

        // Simulate primary dying first (cached init result should remain because upstream1 is still initialized).
        await upstream0.yield(.exit(1))

        // Primary warm init remains in flight while the last initialized secondary exits.
        let warmInitialize = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let warmInitializeID = try extractUpstreamID(from: warmInitialize)
        #expect(manager.testStateSnapshot().upstream(id: 0)?.initInFlight == true)

        // The existing in-flight handshake owns recovery; a duplicate eager
        // initialize must not be sent when the last supporter exits.
        let secondaryExitEventIndex = upstreamEvents.count()
        await upstream1.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: secondaryExitEventIndex,
            description: "waiting for secondary upstream exit"
        )
        #expect(
            manager.testStateSnapshot()
                .shouldRetryEagerInitializePrimaryAfterWarmInitFailure
        )
        #expect(manager.canonicalHandshakeState.initializeResult() == nil)
        #expect(await upstream0.sentCount() == 3)

        await upstream0.yield(
            .message(
                try makeInitializeResponse(
                    id: warmInitializeID,
                    serverName: "cached-handshake"
                ))
        )
        let initialized = try await sentValue(from: upstream0, at: 3, timeout: .seconds(2))
        #expect(methodName(from: initialized) == "notifications/initialized")
        await manager.drainRuntimeTasksForTesting()
        #expect(manager.canonicalHandshakeState.initializeSourceUpstream() == 0)
        #expect(manager.canonicalHandshakeState.initializeResult() != nil)
        #expect(manager.testStateSnapshot().upstream(id: 0)?.isInitialized == true)
        #expect(
            manager.testStateSnapshot()
                .shouldRetryEagerInitializePrimaryAfterWarmInitFailure == false
        )
    }

    @Test
    func
        sessionManagerRetiresStaticUpstreamAfterPrimaryWarmInitErrorWhenLastInitializedUpstreamExited()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let upstream0Initialized = TestSignal()
        let upstream1Initialized = TestSignal()
        let config = makeConfig(requestTimeout: 0.3)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) },
                upstreamInitialized: { upstreamIndex in
                    if upstreamIndex == 0 {
                        upstream0Initialized.signal()
                    } else if upstreamIndex == 1 {
                        upstream1Initialized.signal()
                    }
                }
            )
        )
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        let init0 = try await sentValue(from: upstream0, at: 0, timeout: .seconds(2))
        let init0ID = try extractUpstreamID(from: init0)
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        let init1 = try await sentValue(from: upstream1, at: 0, timeout: .seconds(2))
        let init1ID = try extractUpstreamID(from: init1)
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        // Wait for per-upstream notifications/initialized.
        _ = try await sentValue(from: upstream0, at: 1, timeout: .seconds(2))
        _ = try await sentValue(from: upstream1, at: 1, timeout: .seconds(2))
        try await upstream0Initialized.wait(
            description: "waiting for primary upstream initialization"
        )
        try await upstream1Initialized.wait(
            description: "waiting for secondary upstream initialization"
        )

        // Primary exit triggers warm init on primary.
        await upstream0.yield(.exit(1))
        let retry = try await sentValue(from: upstream0, at: 2, timeout: .seconds(2))
        let retryID = try extractUpstreamID(from: retry)

        // While primary warm init is in flight, last initialized upstream exits.
        let secondaryExitEventIndex = upstreamEvents.count()
        await upstream1.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: secondaryExitEventIndex,
            description: "waiting for secondary upstream exit"
        )
        #expect(manager.testStateSnapshot().upstream(id: 1)?.isInitialized == false)

        // Warm init fails with JSON-RPC error.
        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": retryID,
            "error": [
                "code": -1,
                "message": "warm init failed",
            ],
        ]
        let errorEventIndex = upstreamEvents.count()
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: errorResponse, options: [])))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: errorEventIndex,
            description: "waiting for primary warm init failure"
        )

        // A static slot has no factory for a fresh channel generation, so recovery is terminal.
        #expect(await upstream0.sentCount() == 3)
        #expect(manager.testStateSnapshot().upstream(id: 0)?.isInitialized == nil)
        #expect(manager.testStateSnapshot().hasInitResult == false)
    }

    @Test func sessionManagerPinsSessionsRoundRobinAcrossUpstreams() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let initializedUpstreams = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamInitialized: { initializedUpstreams.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // Eager init -> upstream0
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        // Warm init -> upstream1
        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        // Wait for per-upstream notifications/initialized.
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)
        try await waitForInitializedUpstreams(initializedUpstreams, expected: [0, 1])

        let sessionIDA = "session-A"
        let sessionIDB = "session-B"
        let sessionA = manager.session(id: sessionIDA)
        let sessionB = manager.session(id: sessionIDB)

        let originalA = JSONRPC.ID(any: NSNumber(value: 100))!
        let originalB = JSONRPC.ID(any: NSNumber(value: 101))!

        let upstreamIndexA = try #require(
            manager.chooseUpstreamIndex())
        let upstreamIndexB = try #require(
            manager.chooseUpstreamIndex())
        #expect(upstreamIndexA != upstreamIndexB)

        let futureA = sessionA.router.registerRequest(idKey: originalA.key, on: eventLoop)
        let upstreamIDA = manager.assignUpstreamID(
            sessionID: sessionIDA,
            originalID: originalA,
            upstreamIndex: upstreamIndexA
        )
        manager.sendUpstream(
            try makeToolListRequest(id: upstreamIDA), upstreamIndex: upstreamIndexA)

        let futureB = sessionB.router.registerRequest(idKey: originalB.key, on: eventLoop)
        let upstreamIDB = manager.assignUpstreamID(
            sessionID: sessionIDB,
            originalID: originalB,
            upstreamIndex: upstreamIndexB
        )
        manager.sendUpstream(
            try makeToolListRequest(id: upstreamIDB), upstreamIndex: upstreamIndexB)

        await yieldMessage(
            try makeToolListResponse(id: upstreamIDA),
            to: upstreamIndexA == 0 ? upstream0 : upstream1
        )
        await yieldMessage(
            try makeToolListResponse(id: upstreamIDB),
            to: upstreamIndexB == 0 ? upstream0 : upstream1
        )

        _ = try await futureA.get()
        _ = try await futureB.get()

        let methods0 = await upstream0.sent().compactMap(methodName(from:))
        let methods1 = await upstream1.sent().compactMap(methodName(from:))
        #expect(methods0.filter { $0 == "tools/list" }.count == 1)
        #expect(methods1.filter { $0 == "tools/list" }.count == 1)
    }

    @Test func sessionManagerDropsUnmappedNotificationsAfterInitializeRoutingEnds() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        let sessionIDA = "session-A"
        let sessionIDB = "session-B"
        let sessionA = manager.session(id: sessionIDA)
        let sessionB = manager.session(id: sessionIDB)

        // Ensure we're starting from a clean buffer state.
        _ = sessionA.router.drainBufferedNotifications()
        _ = sessionB.router.drainBufferedNotifications()

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 1],
            ],
            options: []
        )

        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        #expect(
            sessionA.router.drainBufferedNotifications().isEmpty
                && sessionB.router.drainBufferedNotifications().isEmpty
        )
    }

    @Test func sessionManagerDropsUnmappedNotificationsWhenNoPinnedTargetsExist()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config, eventLoop: eventLoop, upstreams: [upstream0, upstream1])
        defer { manager.shutdownAndWait() }

        // Initialize both upstreams.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))

        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)

        // Create a session, but do not pin it yet.
        let sessionID = "session-A"
        let session = manager.session(id: sessionID)

        // Ensure we're starting from a clean buffer state.
        _ = session.router.drainBufferedNotifications()

        let notification = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/test",
                "params": ["value": 1],
            ],
            options: []
        )

        manager.routeUpstreamMessage(notification, upstreamIndex: 0)
        #expect(session.router.drainBufferedNotifications().isEmpty)
    }

    @Test func sessionManagerDropsUnmappedResponsesEvenWhenPinnedTargetsExist() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        let sessionID = "session-A"
        let session = manager.session(id: sessionID)
        _ = manager.chooseUpstreamIndex()

        _ = session.router.drainBufferedNotifications()

        // Unmapped JSON-RPC response (no `method`) must never be routed to sessions.
        manager.routeUpstreamMessage(try makeToolListResponse(id: 9_999_999), upstreamIndex: 0)
        #expect(session.router.drainBufferedNotifications().isEmpty)
    }

    @Test func sessionManagerDebugSnapshotCapturesTrafficAndStderr() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let upstreamInitialized = TestSignal()
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) },
                upstreamInitialized: { _ in upstreamInitialized.signal() }
            )
        )
        defer { manager.shutdownAndWait() }

        try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
        let initMessages = await upstream.sent()
        let initID = try extractUpstreamID(from: initMessages[0])
        await upstream.yield(.message(try makeInitializeResponse(id: initID)))
        try await waitForSentCount(upstream, count: 2, timeoutSeconds: 2)
        try await upstreamInitialized.wait(
            description: "waiting for upstream initialization commit"
        )

        let sessionID = "session-debug"
        let session = manager.session(id: sessionID)
        let upstreamIndex = try #require(
            manager.chooseUpstreamIndex())
        let original = JSONRPC.ID(any: NSNumber(value: 301))!
        let future = session.router.registerRequest(
            idKey: original.key, on: eventLoop, timeout: .seconds(1))
        let upstreamID = manager.assignUpstreamID(
            sessionID: sessionID,
            originalID: original,
            upstreamIndex: upstreamIndex
        )
        manager.sendUpstream(try makeToolListRequest(id: upstreamID), upstreamIndex: upstreamIndex)
        await upstream.yield(.message(try makeToolListResponse(id: upstreamID)))
        _ = try await future.get()

        let debugEventIndex = upstreamEvents.count()
        await upstream.yield(.message(try makeToolListResponse(id: 9_999_999)))
        await upstream.yield(
            .stderr("Could not decode agent message: Error Domain=mcpbridge.DecodeError Code=1"))
        await upstream.yield(
            .stderr(
                "callTool request for 'DocumentationSearch' failed: Error Domain=IDEIntelligenceMessaging.BridgeError Code=1"
            ))
        await upstream.yield(
            .stdoutProtocolViolation(
                StdioFramer.ProtocolViolation(
                    reason: .invalidJSON,
                    bufferedByteCount: 1024,
                    preview: "...broken"
                )
            )
        )
        await upstream.yield(.stdoutBufferSize(2048))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: debugEventIndex + 4,
            description: "waiting for upstream debug events"
        )

        let snapshot = manager.debugSnapshot()
        #expect(snapshot.upstreams.count == 1)
        #expect(snapshot.upstreams[0].lastDecodeError?.message == "<redacted>")
        #expect(snapshot.upstreams[0].lastBridgeError?.message == "<redacted>")
        #expect(snapshot.upstreams[0].protocolViolationCount == 1)
        #expect(snapshot.upstreams[0].lastProtocolViolationReason == "invalidJSON")
        #expect(snapshot.upstreams[0].lastProtocolViolationBufferedBytes == 1024)
        #expect(snapshot.upstreams[0].lastProtocolViolationPreview == "<redacted>")
        #expect(snapshot.upstreams[0].lastProtocolViolationPreviewHex == "<redacted>")
        #expect(snapshot.upstreams[0].lastProtocolViolationLeadingByteHex == nil)
        #expect(snapshot.upstreams[0].bufferedStdoutBytes == 2048)
        #expect(snapshot.recentTraffic.contains { $0.direction == "outbound" && $0.bytes > 0 })
        #expect(
            snapshot.recentTraffic.contains {
                $0.direction == "inbound" && $0.preview == "<redacted>"
            })
        #expect(
            snapshot.recentTraffic.contains {
                $0.direction == "inbound_unmapped" && $0.preview == "<redacted>"
            })
        #expect(snapshot.upstreams[0].recentStderr.allSatisfy { $0.message == "<redacted>" })

        let exitEventIndex = upstreamEvents.count()
        await upstream.yield(.exit(1))
        _ = try await waitForRecordedValue(
            upstreamEvents,
            at: exitEventIndex,
            description: "waiting for upstream exit debug reset"
        )

        let clearedSnapshot = manager.debugSnapshot()
        #expect(clearedSnapshot.upstreams[0].recentStderr.isEmpty)
        #expect(clearedSnapshot.upstreams[0].lastDecodeError == nil)
        #expect(clearedSnapshot.upstreams[0].lastBridgeError == nil)
        #expect(clearedSnapshot.upstreams[0].protocolViolationCount == 0)
        #expect(clearedSnapshot.upstreams[0].lastProtocolViolationPreview == nil)
        #expect(clearedSnapshot.upstreams[0].lastProtocolViolationPreviewHex == nil)
        #expect(clearedSnapshot.upstreams[0].lastProtocolViolationLeadingByteHex == nil)
        #expect(clearedSnapshot.upstreams[0].bufferedStdoutBytes == 0)
    }

    @Test func sessionManagerReturnsNilWhenAllUpstreamsAreQuarantined() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let upstreamEvents = LockedRecordedValues<Int>()
        let toolsListRefreshes = LockedRecordedValues<(Int, Bool)>()
        let toolsListPrewarmCompletions = LockedRecordedValues<Void>()
        let initializedUpstreams = LockedRecordedValues<Int>()
        var config = makeConfig(requestTimeout: 2)
        config.prewarmToolsList = true
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamEventHandled: { upstreamEvents.append($0) },
                toolsListRefreshCompleted: { toolsListRefreshes.append(($0, $1)) },
                toolsListPrewarmCompleted: { toolsListPrewarmCompletions.append(()) },
                upstreamInitialized: { initializedUpstreams.append($0) }
            )
        )
        defer { manager.shutdownAndWait() }

        // Initialize primary upstream0.
        try await waitForSentCount(upstream0, count: 1, timeoutSeconds: 2)
        let init0 = await upstream0.sent()
        let init0ID = try extractUpstreamID(from: init0[0])
        await upstream0.yield(.message(try makeInitializeResponse(id: init0ID)))

        // The primary commit starts the first tools/list prewarm and the secondary warm initialize.
        try await waitForSentCount(upstream0, count: 2, timeoutSeconds: 2)
        #expect(
            try await waitForRecordedValue(
                initializedUpstreams,
                at: 0,
                description: "waiting for primary upstream initialization commit"
            ) == 0
        )

        // Fail tools/list warmup on upstream0 to mark it unhealthy.
        let warmup0CompletionIndex = toolsListPrewarmCompletions.count()
        let warmup0 = try await sentMessage(
            from: upstream0,
            matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2)
        )
        let warmup0ID = try extractUpstreamID(from: warmup0)
        let warmup0Response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": warmup0ID,
            "result": [:],  // invalid (no `tools` array) -> marks upstream unhealthy
        ]
        let warmup0RefreshIndex = toolsListRefreshes.count()
        await upstream0.yield(
            .message(try JSONSerialization.data(withJSONObject: warmup0Response, options: [])))
        let firstRefresh = try await waitForRecordedValue(
            toolsListRefreshes,
            at: warmup0RefreshIndex,
            description: "waiting for first tools/list warmup failure"
        )
        #expect(firstRefresh == (0, false))
        _ = try await waitForRecordedValue(
            toolsListPrewarmCompletions,
            at: warmup0CompletionIndex,
            description: "waiting for first tools/list prewarm completion"
        )
        guard case .quarantined = manager.testStateSnapshot().upstream(id: 0)?.healthState else {
            Issue.record("upstream0 should be quarantined after invalid tools/list warmup")
            return
        }

        // Complete the secondary warm initialize before asking it to own the next prewarm.
        try await waitForSentCount(upstream1, count: 1, timeoutSeconds: 2)
        let init1 = await upstream1.sent()
        let init1ID = try extractUpstreamID(from: init1[0])
        await upstream1.yield(.message(try makeInitializeResponse(id: init1ID)))
        try await waitForSentCount(upstream1, count: 2, timeoutSeconds: 2)
        #expect(
            try await waitForRecordedValue(
                initializedUpstreams,
                at: 1,
                description: "waiting for secondary upstream initialization commit"
            ) == 1
        )

        // Trigger another warmup; it should prefer upstream1 and fail there too so no healthy upstream exists.
        let warmup1CompletionIndex = toolsListPrewarmCompletions.count()
        manager.refreshToolsListIfNeeded()
        let warmup1 = try await sentMessage(
            from: upstream1,
            matching: { methodName(from: $0) == "tools/list" },
            timeout: .seconds(2)
        )
        let warmup1ID = try extractUpstreamID(from: warmup1)
        let warmup1Response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": warmup1ID,
            "result": [:],
        ]
        let warmup1RefreshIndex = toolsListRefreshes.count()
        await upstream1.yield(
            .message(try JSONSerialization.data(withJSONObject: warmup1Response, options: [])))
        let secondRefresh = try await waitForRecordedValue(
            toolsListRefreshes,
            at: warmup1RefreshIndex,
            description: "waiting for second tools/list warmup failure"
        )
        #expect(secondRefresh == (1, false))
        _ = try await waitForRecordedValue(
            toolsListPrewarmCompletions,
            at: warmup1CompletionIndex,
            description: "waiting for second tools/list prewarm completion"
        )
        guard case .quarantined = manager.testStateSnapshot().upstream(id: 1)?.healthState else {
            Issue.record("upstream1 should be quarantined after invalid tools/list warmup")
            return
        }

        let chosen = manager.chooseUpstreamIndex()
        #expect(chosen == nil)
    }

    @Test func sessionManagerEnqueueOnUpstreamSlotStartsRecoveryProbeWhenAllUpstreamsAreQuarantined() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let uptimeClock = TestUptimeClock(nowUptimeNanoseconds: 20_000_000_000)
        let config = makeConfig(requestTimeout: 2)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream],
            nowUptimeNanoseconds: { uptimeClock.now() }
        )
        defer { manager.shutdownAndWait() }

        let initFuture = manager.registerInitialize(
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            requestObject: makeInitializeRequest(id: 1),
            on: eventLoop
        )
        try await spinUntilSentCount(
            upstream,
            count: 1,
            description: "waiting for eager initialize request"
        )
        let initRequest = try #require(await upstream.sentValue(at: 0))
        let initUpstreamID = try extractUpstreamID(from: initRequest)
        await upstream.yield(.message(try makeInitializeResponse(id: initUpstreamID)))
        _ = try await initFuture.get()
        try await spinUntilSentCount(
            upstream,
            count: 2,
            description: "waiting for initialized notification"
        )

        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 0, nowUptimeNs: 0)

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-quarantine-recovery",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let leaseID = manager.createRequestLease(descriptor: descriptor)
        let future: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop
        ) { _ in
            eventLoop.makeSucceededFuture(())
        }

        await #expect(throws: UpstreamSlotScheduler.AcquisitionError.self) {
            try await future.get()
        }

        try await spinUntilSentCount(
            upstream,
            count: 3,
            description: "waiting for recovery probe request"
        )
        let probe = try #require(await upstream.sentValue(at: 2))
        #expect(methodName(from: probe) == "tools/list")
    }

    @Test func sessionManagerQueuedRequestStartsProbeForExpiredQuarantinedUpstream() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let uptimeClock = TestUptimeClock(nowUptimeNanoseconds: 20_000_000_000)
        let config = makeConfig(requestTimeout: 5)
        let manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: [upstream0, upstream1],
            nowUptimeNanoseconds: { uptimeClock.now() }
        )
        defer { manager.shutdownAndWait() }

        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:DocumentationSearch",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        defer { activePromise.fail(CancellationError()) }
        try await occupyUpstreamSlot(
            on: manager,
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            eventLoop: eventLoop,
            completionPromise: activePromise
        )

        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        _ = manager.upstreamHealthManager.markRequestTimedOut(upstreamIndex: 1, nowUptimeNs: 0)
        guard let upstream = manager.testStateSnapshot().upstream(id: 1),
            case .quarantined = upstream.healthState
        else {
            Issue.record("expected upstream1 to be quarantined before queueing request")
            return
        }

        let queuedRequestData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": NSNumber(value: 99),
                "method": "tools/list",
            ],
            options: []
        )
        let queuedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-queued",
            label: "tools/list",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let queuedLeaseID = manager.createRequestLease(descriptor: queuedDescriptor)
        let queuedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: queuedLeaseID,
            descriptor: queuedDescriptor,
            on: eventLoop
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                queuedLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex.upstreamIndex,
                timeout: nil
            )
            manager.sendUpstream(
                queuedRequestData,
                operationLease: selectedUpstreamIndex,
                ensureRunning: false,
                admission: nil,
                onRejected: {}
            )
            return eventLoop.makeSucceededFuture(())
        }

        #expect(manager.debugSnapshot().queuedRequestCount == 1)

        try await spinUntilSentCount(
            upstream1,
            count: 1,
            description: "waiting for recovery probe request"
        )
        let probeRequest = try #require(await upstream1.sentValue(at: 0))
        #expect(methodName(from: probeRequest) == "tools/list")
        let probeID = try extractUpstreamID(from: probeRequest)
        #expect(probeID != 99)
        let probeResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNumber(value: probeID),
            "result": [
                "tools": [Any]()
            ],
        ]
        await upstream1.yield(
            .message(try JSONSerialization.data(withJSONObject: probeResponse, options: []))
        )

        _ = try await queuedFuture.get()
        try await spinUntilSentCount(
            upstream1,
            count: 2,
            description: "waiting for queued request dispatch after probe recovery"
        )
        let queuedRequest = try #require(await upstream1.sentValue(at: 1))
        #expect(methodName(from: queuedRequest) == "tools/list")
        #expect(try extractUpstreamID(from: queuedRequest) == 99)

    }

}
