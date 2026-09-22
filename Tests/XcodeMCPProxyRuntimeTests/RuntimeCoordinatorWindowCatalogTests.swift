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
struct RuntimeCoordinatorWindowCatalogTests {
    @Test func sessionManagerKeepsWindowlessProcessRouteAvailable() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 600, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 601, xcodeVersion: "26.6")
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

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
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
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )
        _ = try await task.value

        let processIDs = Set(manager.debugSnapshot().processToolCatalogs.map(\.processID))
        #expect(processIDs == Set([Int32(target0.processID), Int32(target1.processID)]))
        #expect(
            manager.documentationCandidateProcessIDs()
                == Set([
                    target0.processID,
                    target1.processID,
                ])
        )
        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 1001,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "stale-tab"]
                )
            ) == nil
        )
    }

    @Test func ownerBoundRefreshSkipsUnavailableProcessRoutes() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 602, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 603, xcodeVersion: "26.6")
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
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_unavailable"
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 1002,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-b"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

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

    @Test func ownerBoundRefreshUsesUsableSiblingWhenPrimaryUnavailable() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let primaryUpstream = TestUpstreamClient()
        let siblingUpstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 604, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [primaryUpstream, siblingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (
                    target,
                    1,
                    [
                        ownerBoundToolDescriptor(name: "BuildProject"),
                        toolDescriptor(name: "XcodeListWindows"),
                    ]
                )
            ]
        )

        let task = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 1003,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "tab-sibling"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }

        let request = try await siblingUpstream.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        #expect(await primaryUpstream.sentCount() == 0)
        await siblingUpstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request),
                    message: "* tabIdentifier: tab-sibling, workspacePath: /Work/S.xcworkspace"
                )
            )
        )

        let decision = await task.value
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundToolWithoutOwnerHintRoutesWhenSingleProcess() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 605, xcodeVersion: "27.0")
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
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")])
            ]
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 1004,
                name: "BuildProject",
                arguments: [:]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [0])
        #expect(await upstream.sentCount() == 0)
    }

    @Test func ownerBoundToolWithoutOwnerHintRoutesWhenSingleCatalogCandidate() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 606, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 607, xcodeVersion: "26.6")
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
                (target1, 1, [toolDescriptor(name: "XcodeRead")]),
            ]
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 1005,
                name: "BuildProject",
                arguments: [:]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [0])
        #expect(await upstream0.sentCount() == 0)
        #expect(await upstream1.sentCount() == 0)
    }

    @Test func ownerBoundToolRoutesToCachedWindowOwner() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 610, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 611, xcodeVersion: "26.6")
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
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                    ]
                ]),
                upstreamIndex: 0
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 101,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-a"]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [0])
    }

    @Test func rawTabCollisionRequiresWorkspaceDisambiguation() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 612, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 613, xcodeVersion: "26.6")
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
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: windowtab1, workspacePath: /Work/A.xcworkspace"
                    ]
                ]),
                upstreamIndex: 0
            )
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: windowtab1, workspacePath: /Work/B.xcworkspace"
                    ]
                ]),
                upstreamIndex: 1
            )
        )

        let ambiguousTask = Task {
            await manager.toolRoutingDecision(
                for: toolsCallObject(
                    id: 9301,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "windowtab1"]
                ),
                requestTimeoutOverride: .seconds(2)
            )
        }
        let refresh0 = try await upstream0.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: refresh0),
                    message: "* tabIdentifier: windowtab1, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        let refresh1 = try await upstream1.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream1.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: refresh1),
                    message: "* tabIdentifier: windowtab1, workspacePath: /Work/B.xcworkspace"
                )
            )
        )
        let ambiguousDecision = await ambiguousTask.value
        guard case .reject(let errors) = ambiguousDecision else {
            Issue.record("expected raw tab-only request to reject")
            return
        }
        #expect(errors.map(\.id.key) == ["9301"])
        #expect(errors.first?.message.contains("ambiguous raw Xcode tabIdentifier") == true)

        let disambiguatedDecision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 9302,
                name: "BuildProject",
                arguments: [
                    "tabIdentifier": "windowtab1",
                    "workspacePath": "/Work/B.xcworkspace",
                ]
            ),
            requestTimeoutOverride: .seconds(2)
        )
        let preferredUpstreamIndices = try #require(disambiguatedDecision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func workspacePathTakesPrecedenceOverRawTabFallback() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 615, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient()],
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
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")])
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: windowtab1, workspacePath: /Work/A.xcworkspace"
                    ]
                ]),
                upstreamIndex: 0
            )
        )

        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 9401,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": "windowtab1"]
                )
            ) == 0
        )
        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 9402,
                    name: "BuildProject",
                    arguments: [
                        "tabIdentifier": "windowtab1",
                        "workspacePath": "/Work/Other.xcworkspace",
                    ]
                )
            ) == nil
        )
    }

    @Test func proxyTabIdentifierIsRewrittenBeforeForwarding() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 614, xcodeVersion: "27.0")
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
                        toolDescriptor(name: "XcodeListWindows"),
                        toolDescriptor(
                            name: "BuildProject",
                            inputProperties: [
                                "tabIdentifier": ["type": "string"],
                                "workspacePath": ["type": "string"],
                            ],
                            required: ["tabIdentifier"]
                        ),
                    ]
                )
            ]
        )

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(2)
            )
        }
        let listRequest = try await upstream.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: listRequest),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )
        let result = try await task.value
        guard case .object(let resultObject) = result,
            case .object(let structuredContent)? = resultObject["structuredContent"],
            case .string(let message)? = structuredContent["message"],
            let proxyTab = firstTabIdentifier(in: message)
        else {
            Issue.record("expected proxied XcodeListWindows tab")
            return
        }
        #expect(proxyTab.hasPrefix("xcode-mcpkit:"))
        #expect(proxyTab != "tab-a")

        let proxyTabRequest = toolsCallObject(
            id: 9303,
            name: "BuildProject",
            arguments: ["tabIdentifier": proxyTab]
        )
        let proxyTabData = try JSONSerialization.data(withJSONObject: proxyTabRequest, options: [])
        let rewrittenProxyTab = manager.rewriteOwnerBoundRequest(
            bodyData: proxyTabData,
            parsedRequestJSON: proxyTabRequest,
            upstreamIndex: 0
        )
        #expect(tabIdentifier(in: rewrittenProxyTab.bodyData) == "tab-a")

        let workspaceOnlyRequest = toolsCallObject(
            id: 9304,
            name: "BuildProject",
            arguments: ["workspacePath": "/Work/A.xcworkspace"]
        )
        let workspaceOnlyData = try JSONSerialization.data(
            withJSONObject: workspaceOnlyRequest,
            options: []
        )
        let rewrittenWorkspaceOnly = manager.rewriteOwnerBoundRequest(
            bodyData: workspaceOnlyData,
            parsedRequestJSON: workspaceOnlyRequest,
            upstreamIndex: 0
        )
        #expect(tabIdentifier(in: rewrittenWorkspaceOnly.bodyData) == "tab-a")

        let emptyTabWorkspaceRequest = toolsCallObject(
            id: 9305,
            name: "BuildProject",
            arguments: [
                "tabIdentifier": "",
                "workspacePath": "/Work/A.xcworkspace",
            ]
        )
        let emptyTabWorkspaceData = try JSONSerialization.data(
            withJSONObject: emptyTabWorkspaceRequest,
            options: []
        )
        let rewrittenEmptyTabWorkspace = manager.rewriteOwnerBoundRequest(
            bodyData: emptyTabWorkspaceData,
            parsedRequestJSON: emptyTabWorkspaceRequest,
            upstreamIndex: 0
        )
        #expect(tabIdentifier(in: rewrittenEmptyTabWorkspace.bodyData) == "tab-a")

        let decision = await manager.toolRoutingDecision(
            for: proxyTabRequest,
            requestTimeoutOverride: .seconds(2)
        )
        guard case .forwardAdmitted(_, let admission) = decision else {
            Issue.record("expected exact window-route admission")
            return
        }
        _ = manager.windowOwnershipAuthority.record(
            processID: target.processID,
            entries: [
                XcodeListWindowsEntry(
                    tabIdentifier: "tab-after-admission",
                    workspacePath: "/Work/A.xcworkspace"
                )
            ]
        )
        let admittedRewrite = manager.rewriteOwnerBoundRequest(
            bodyData: proxyTabData,
            parsedRequestJSON: proxyTabRequest,
            operationLease: try #require(
                manager.upstreamTopology.operationLease(for: UpstreamSlotID(rawValue: 0))
            ),
            admission: admission
        )
        #expect(tabIdentifier(in: admittedRewrite.bodyData) == "tab-a")
    }

    @Test func ownerRoutingReResolvesWindowAndRouteSnapshotsWhenProofRouteChanges() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let target = xcodeProcessTarget(processID: 615, xcodeVersion: "27.0")
        let managerBox = WeakRuntimeCoordinatorBox()
        let hookCount = NIOLockedValueBox(0)
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0])
            ],
            testHooks: RuntimeCoordinatorTestHooks(ownerRouteProofsResolved: {
                let shouldReplace = hookCount.withLockedValue { count in
                    defer { count += 1 }
                    return count == 0
                }
                guard shouldReplace, let manager = managerBox.value else { return }
                _ = manager.processControlPlane.reconcileRoutes(
                    [XcodeProcessRoute(target: target, upstreamIndices: [1])],
                    reason: "route_change_after_window_proof",
                    nowUptimeNs: manager.nowUptimeNanoseconds(),
                    usability: .init(
                        snapshotUsableUpstreamIDs: [UpstreamSlotID(rawValue: 1)],
                        recoveryAwareUsableUpstreamIDs: [UpstreamSlotID(rawValue: 1)]
                    )
                )
            }),
            startImmediately: false
        )
        managerBox.value = manager
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [(target, 0, [ownerBoundToolDescriptor(name: "BuildProject")])]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: route-race-tab, workspacePath: /Work/Race.xcworkspace"
                    ]
                ]),
                upstreamIndex: 0
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 9306,
                name: "BuildProject",
                arguments: ["tabIdentifier": "route-race-tab"]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        guard case .forwardAdmitted(let preferred, let admission) = decision else {
            Issue.record("expected routing to re-resolve against the replacement route")
            return
        }
        #expect(preferred == [1])
        let routeAdmission = try #require(admission.route)
        #expect(manager.processControlPlane.validate(routeAdmission))
        #expect(admission.window?.proof.route.routeID == routeAdmission.routeID)
    }

    @Test func ownerHintRoutesBeforeProcessToolCatalogIsAvailable() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 628, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 629, xcodeVersion: "26.6")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target0, upstreamIndices: [0]),
                XcodeProcessRoute(target: target1, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        manager.seedCanonicalToolsCatalog(
            try jsonValue([
                "tools": [
                    ownerBoundToolDescriptor(name: "BuildProject")
                ]
            ]),
            sourceUpstream: 2
        )
        #expect(manager.debugSnapshot().processToolCatalogs.isEmpty)
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-before-catalog, "
                            + "workspacePath: /Work/BeforeCatalog.xcworkspace"
                    ]
                ]),
                upstreamIndex: 1
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 102,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-before-catalog"]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundToolRoutesToUsableSlotInOwningProcess() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 612, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")])
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                    ]
                ]),
                upstreamIndex: 0
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 109,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-a"]
            ),
            requestTimeoutOverride: .seconds(2)
        )

        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func ownerBoundProcessRouteUsesIdleSiblingWhenPrimaryIsBusy() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 614, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")])
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                    ]
                ]),
                upstreamIndex: 0
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 112,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-a"]
            ),
            requestTimeoutOverride: .seconds(2)
        )
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [0, 1])

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:LongRunningBuild",
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeStarted = TestSignal()
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop,
            preferredUpstreamIndex: 0
        ) { selectedUpstreamIndex in
            #expect(selectedUpstreamIndex.upstreamIndex == 0)
            activeStarted.signal()
            return activePromise.futureResult
        }
        try await activeStarted.wait(
            timeout: .seconds(5),
            description: "waiting for primary upstream slot occupation"
        )

        let routedDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-routed",
            label: "tools/call:BuildProject",
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let routedLeaseID = manager.createRequestLease(descriptor: routedDescriptor)
        let selectedUpstream = NIOLockedValueBox<Int?>(nil)
        let routedFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: routedLeaseID,
            descriptor: routedDescriptor,
            on: eventLoop,
            preferredUpstreamIndices: preferredUpstreamIndices
        ) { selectedUpstreamIndex in
            selectedUpstream.withLockedValue { $0 = selectedUpstreamIndex.upstreamIndex }
            return eventLoop.makeSucceededFuture(())
        }

        _ = try await routedFuture.get()
        #expect(selectedUpstream.withLockedValue { $0 } == 1)
        manager.completeRequestLease(routedLeaseID)

        manager.completeRequestLease(activeLeaseID)
        activePromise.succeed(())
        _ = try await activeFuture.get()
    }

    @Test func ownerBoundToolKeepsProcessRouteWhenSiblingSlotExits() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 615, xcodeVersion: "27.0")
        let sourceUpstream = TestUpstreamClient()
        let siblingUpstream = TestUpstreamClient()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [sourceUpstream, siblingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [ownerBoundToolDescriptor(name: "BuildProject")])
            ]
        )
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                    ]
                ]),
                upstreamIndex: 0
            )
        )

        manager.handleUpstreamExit(1, upstreamIndex: 0)

        #expect(manager.cachedToolsListResult() == nil)
        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) == nil)
        let freshCatalogTask = Task {
            try await manager.sharedToolsList(
                sessionID: "session-owner-bound-sibling-catalog",
                requestTimeoutOverride: .seconds(5)
            )
        }
        let freshRequest = try await sentValue(
            from: siblingUpstream,
            at: 0,
            timeout: .seconds(2)
        )
        await siblingUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: freshRequest),
                    tools: [ownerBoundToolDescriptor(name: "BuildProject")]
                ))
        )
        _ = try await waitWithTimeout("waiting for sibling owner-bound catalog") {
            try await freshCatalogTask.value
        }
        let freshCatalog = try #require(
            manager.processControlPlane.catalog(forProcessID: target.processID)
        )
        #expect(freshCatalog.upstreamProof.slotID == UpstreamSlotID(rawValue: 1))
        #expect(
            manager.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                    ]
                ]),
                upstreamIndex: 1
            )
        )

        let decision = await manager.toolRoutingDecision(
            for: toolsCallObject(
                id: 111,
                name: "BuildProject",
                arguments: ["tabIdentifier": "tab-a"]
            ),
            requestTimeoutOverride: .seconds(2)
        )
        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [1])
    }

    @Test func sessionManagerProcessCatalogReloadsSourceAndInvalidatesAfterLastSlotExit()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 615, xcodeVersion: "27.0")
        let sourceUpstream = TestUpstreamClient()
        let siblingUpstream = TestUpstreamClient()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [sourceUpstream, siblingUpstream],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1])
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        try seedProcessToolCatalogs(
            on: manager,
            entries: [
                (target, 0, [toolDescriptor(name: "SharedTool")])
            ]
        )

        #expect(manager.clearUpstreamState(upstreamIndex: 0))

        var snapshot = manager.debugSnapshot()
        #expect(manager.cachedToolsListResult() == nil)
        #expect(snapshot.processToolCatalogs.isEmpty)

        let freshCatalogTask = Task {
            try await manager.sharedToolsList(
                sessionID: "session-process-catalog-reload-source",
                requestTimeoutOverride: .seconds(5)
            )
        }
        let freshRequest = try await sentValue(
            from: siblingUpstream,
            at: 0,
            timeout: .seconds(2)
        )
        await siblingUpstream.yield(
            .message(
                try makeDocumentationToolsListResponse(
                    id: try extractUpstreamID(from: freshRequest),
                    tools: [toolDescriptor(name: "SharedTool")]
                ))
        )
        _ = try await waitWithTimeout("waiting for sibling catalog reload") {
            try await freshCatalogTask.value
        }

        snapshot = manager.debugSnapshot()
        let catalog = try #require(snapshot.processToolCatalogs.first)
        #expect(catalog.upstreamIndex == 1)
        #expect(catalog.isCanonicalSource)
        #expect(toolNames(in: manager.cachedToolsListResult() ?? .null) == ["SharedTool"])

        #expect(manager.clearUpstreamState(upstreamIndex: 1))

        snapshot = manager.debugSnapshot()
        #expect(manager.cachedToolsListResult() == nil)
        #expect(snapshot.processToolCatalogs.isEmpty)
    }

    @Test func nonOwnerUnionToolRoutesToCatalogOwnerProcess() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target0 = xcodeProcessTarget(processID: 613, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 614, xcodeVersion: "26.6")
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
                (target0, 0, [toolDescriptor(name: "Xcode27OnlyTool")]),
                (target1, 1, [toolDescriptor(name: "SharedTool")]),
            ]
        )

        let decision = try #require(
            manager.immediateToolRoutingDecision(
                for: [
                    "jsonrpc": "2.0",
                    "id": 110,
                    "method": "tools/call",
                    "params": [
                        "name": "Xcode27OnlyTool"
                    ],
                ]
            )
        )

        let preferredUpstreamIndices = try #require(decision.preferredUpstreamIndices)
        #expect(preferredUpstreamIndices == [0])
    }

    @Test func publicXcodeListWindowsRoutesToLocalAggregation() async throws {
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
                (target0, 0, [toolDescriptor(name: "XcodeListWindows")]),
                (target1, 1, [toolDescriptor(name: "XcodeListWindows")]),
            ]
        )

        let decision = try #require(
            manager.immediateToolRoutingDecision(
                for: toolsCallObject(
                    id: 118,
                    name: "XcodeListWindows",
                    arguments: [:]
                )
            )
        )

        guard case .localXcodeListWindows = decision else {
            Issue.record("expected XcodeListWindows to resolve through local aggregation")
            return
        }
    }

    @Test func liveXcodeListWindowsAggregatesOnlyCatalogAdvertisedRoutes() async throws {
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
                (target0, 0, [toolDescriptor(name: "XcodeListWindows")])
            ]
        )

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .anyHealthy,
                requestTimeoutOverride: .seconds(5)
            )
        }

        let request = try await upstream0.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        #expect(await upstream1.sentCount() == 0)

        await upstream0.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request),
                    message: "* tabIdentifier: tab-a, workspacePath: /Work/A.xcworkspace"
                )
            )
        )

        let result = try await task.value
        #expect(await upstream1.sentCount() == 0)
        guard case .object(let object) = result,
            case .object(let structuredContent)? = object["structuredContent"],
            case .string(let message)? = structuredContent["message"]
        else {
            Issue.record("expected structured XcodeListWindows message")
            return
        }
        #expect(message.contains("xcode-mcpkit:"))
        #expect(message.contains("/Work/A.xcworkspace"))
    }

    @Test func pinnedLiveXcodeListWindowsReturnsClientProxyTabIdentifiers()
        async throws
    {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 634, xcodeVersion: "27.0")
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

        let task = Task {
            try await manager.liveXcodeListWindowsResult(
                route: .pinnedUpstream(0),
                requestTimeoutOverride: .seconds(5)
            )
        }
        let request = try await upstream.nextSent {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }
        await upstream.yield(
            .message(
                try makeXcodeListWindowsResponse(
                    id: try extractUpstreamID(from: request),
                    message: "* tabIdentifier: raw-pinned-tab, "
                        + "workspacePath: /Work/Pinned.xcworkspace"
                )
            )
        )

        let result = try await task.value
        guard case .object(let object) = result,
            case .object(let structuredContent)? = object["structuredContent"],
            case .string(let message)? = structuredContent["message"],
            let proxyTabIdentifier = firstTabIdentifier(in: message)
        else {
            Issue.record("expected pinned XcodeListWindows to return a proxied tab")
            return
        }
        #expect(proxyTabIdentifier.hasPrefix("xcode-mcpkit:"))
        #expect(proxyTabIdentifier != "raw-pinned-tab")
        #expect(message.contains("/Work/Pinned.xcworkspace"))

        #expect(
            manager.preferredUpstreamIndex(
                for: toolsCallObject(
                    id: 8707,
                    name: "BuildProject",
                    arguments: ["tabIdentifier": proxyTabIdentifier]
                )
            ) == 0
        )
    }

    @Test func liveXcodeListWindowsIgnoresCatalogsFromUnavailableRoutes() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream0 = TestUpstreamClient()
        let upstream1 = TestUpstreamClient()
        let target0 = xcodeProcessTarget(processID: 624, xcodeVersion: "27.0")
        let target1 = xcodeProcessTarget(processID: 625, xcodeVersion: "26.6")
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
                (target0, 0, [toolDescriptor(name: "DocumentationSearch")])
            ]
        )
        manager.markXcodeProcessRouteUnavailable(
            upstreamIndex: 0,
            reason: "test_unavailable"
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
                    message: "* tabIdentifier: tab-b, workspacePath: /Work/B.xcworkspace"
                )
            )
        )

        let result = try await task.value
        #expect(await upstream0.sentCount() == 0)
        guard case .object(let object) = result,
            case .object(let structuredContent)? = object["structuredContent"],
            case .string(let message)? = structuredContent["message"]
        else {
            Issue.record("expected structured XcodeListWindows message")
            return
        }
        #expect(message.contains("xcode-mcpkit:"))
        #expect(message.contains("/Work/B.xcworkspace"))
    }

}
