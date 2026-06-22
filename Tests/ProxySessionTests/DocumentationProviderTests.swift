import ProxyXcodeSupport
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
import ProxyCore
import ProxyMCP
import XcodeMCPTestSupport
@testable import ProxySession

extension RuntimeCoordinatorTests {
    @Test func defaultDocumentationProviderIsEnabledOnlyForDefaultMCPBridgeInvocation() {
        var config = makeConfig(requestTimeout: 5)
        let transport = UnavailableDocumentationProviderTransport()
        #expect(RuntimeCoordinator.makeDefaultDocumentationProviderManager(
            config: config,
            discovery: StubXcodeTargetDiscovery(targets: []),
            transport: transport
        ) != nil)

        config.disabledToolNames = [DocumentationProvider.ToolCatalog.toolName]
        #expect(RuntimeCoordinator.makeDefaultDocumentationProviderManager(
            config: config,
            discovery: StubXcodeTargetDiscovery(targets: []),
            transport: transport
        ) == nil)

        config.disabledToolNames = []
        config.upstreamArgs = ["--sdk", "macosx", "swift"]
        #expect(RuntimeCoordinator.makeDefaultDocumentationProviderManager(
            config: config,
            discovery: StubXcodeTargetDiscovery(targets: []),
            transport: transport
        ) == nil)

        config.upstreamCommand = "/bin/echo"
        config.upstreamArgs = ["xcrun", "mcpbridge"]
        #expect(RuntimeCoordinator.makeDefaultDocumentationProviderManager(
            config: config,
            discovery: StubXcodeTargetDiscovery(targets: []),
            transport: transport
        ) == nil)
    }

    @Test func defaultUpstreamPlanReusesSingleXcodeProcessWithoutAddingProviderSlot() throws {
        let target = documentationProviderTarget(processID: 710, xcodeVersion: "27.0")
        var config = makeConfig(requestTimeout: 5)
        config.upstreamSessionID = "shared-docs-session"

        let plan = try withEnvironmentVariables(["MCP_XCODE_PID": ""]) {
            RuntimeCoordinator.makeDefaultUpstreamPlan(
                config: config,
                sharedSessionID: config.upstreamSessionID,
                count: 2,
                documentationTargets: [target]
            )
        }

        #expect(plan.upstreams.count == 2)
        #expect(plan.documentationRoutes.map(\.target.processID) == [target.processID])
        #expect(plan.documentationRoutes.first?.upstreamIndex == 0)
        for upstream in plan.upstreams {
            let environment = try upstreamEnvironment(from: upstream)
            #expect(try upstreamCommand(from: upstream) == config.upstreamCommand)
            #expect(try upstreamArgs(from: upstream) == config.upstreamArgs)
            #expect(environment["MCP_XCODE_PID"]?.isEmpty ?? true)
            #expect(environment["DEVELOPER_DIR"] == nil)
            #expect(environment["MCP_XCODE_SESSION_ID"] == "shared-docs-session")
        }
    }

    @Test func defaultUpstreamPlanDoesNotLimitDocumentationCandidatesToUpstreamCount()
        throws
    {
        let older = documentationProviderTarget(processID: 720, xcodeVersion: "26.6")
        let newer = documentationProviderTarget(processID: 721, xcodeVersion: "27.0")
        let config = makeConfig(requestTimeout: 5)

        let plan = try withEnvironmentVariables(["MCP_XCODE_PID": ""]) {
            RuntimeCoordinator.makeDefaultUpstreamPlan(
                config: config,
                sharedSessionID: config.upstreamSessionID,
                count: 1,
                documentationTargets: [older, newer]
            )
        }

        #expect(plan.upstreams.count == 1)
        #expect(plan.documentationRoutes.isEmpty)
        let upstream = try #require(plan.upstreams.first)
        #expect(try upstreamCommand(from: upstream) == config.upstreamCommand)
        #expect(try upstreamArgs(from: upstream) == config.upstreamArgs)
    }

    @Test func defaultUpstreamPlanHonorsPinnedDocumentationProcess() throws {
        let pinned = documentationProviderTarget(processID: 730, xcodeVersion: "26.6")
        let newer = documentationProviderTarget(processID: 731, xcodeVersion: "27.0")
        let config = makeConfig(requestTimeout: 5)

        let plan = try withEnvironmentVariables(["MCP_XCODE_PID": "\(pinned.processID)"]) {
            RuntimeCoordinator.makeDefaultUpstreamPlan(
                config: config,
                sharedSessionID: config.upstreamSessionID,
                count: 2,
                documentationTargets: [newer, pinned]
            )
        }

        #expect(plan.upstreams.count == 2)
        #expect(plan.documentationRoutes.map(\.target.processID) == [pinned.processID])
        #expect(plan.documentationRoutes.first?.upstreamIndex == 0)
        for upstream in plan.upstreams {
            let environment = try upstreamEnvironment(from: upstream)
            #expect(environment["MCP_XCODE_PID"] == "\(pinned.processID)")
            #expect(try upstreamCommand(from: upstream) == config.upstreamCommand)
            #expect(try upstreamArgs(from: upstream) == config.upstreamArgs)
        }
    }

    @Test func runtimeCoordinatorSkipsXcodeDiscoveryWhenDocumentationServiceIsDisabled()
        throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = documentationProviderTarget(processID: 735, xcodeVersion: "27.0")

        do {
            var config = makeConfig(requestTimeout: 5)
            config.disabledToolNames = [DocumentationProvider.ToolCatalog.toolName]
            let discovery = CountingXcodeTargetDiscovery(targets: [target])
            let manager = RuntimeCoordinator(
                config: config,
                eventLoop: eventLoop,
                xcodeTargetDiscovery: discovery,
                startImmediately: false
            )
            defer { manager.shutdownAndWait() }

            #expect(discovery.callCount() == 0)
            #expect(manager.hasDocumentationSearchService() == false)
        }

        do {
            var config = makeConfig(requestTimeout: 5)
            config.upstreamArgs = ["--sdk", "macosx", "swift"]
            let discovery = CountingXcodeTargetDiscovery(targets: [target])
            let manager = RuntimeCoordinator(
                config: config,
                eventLoop: eventLoop,
                xcodeTargetDiscovery: discovery,
                startImmediately: false
            )
            defer { manager.shutdownAndWait() }

            #expect(discovery.callCount() == 0)
            #expect(manager.hasDocumentationSearchService() == false)
        }
    }

    @Test func runtimeDocumentationTransportReusesPrewarmedUpstreamRouteForSearch()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = documentationProviderTarget(processID: 740, xcodeVersion: "27.0")
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let providerManager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            transport: RuntimeDocumentationProviderTransport(runtimeBox: runtimeBox),
            providerSelectionTimeout: .seconds(1)
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderRoutes: [
                DocumentationProviderRoute(
                    id: "upstream-0-pid-\(target.processID)",
                    target: target,
                    upstreamIndex: 0
                )
            ],
            documentationProviderManager: providerManager,
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)

        async let prewarmUpdate = providerManager.startBackgroundDiscovery(
            requestTimeout: .seconds(1)
        )
        let toolsRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: toolsRequest) == "tools/list")
        let toolsRequestID = try extractUpstreamID(from: toolsRequest)
        await yieldMessage(
            try makeDocumentationToolsListResponse(id: toolsRequestID, version: "27.0"),
            to: upstream
        )
        let update = await prewarmUpdate
        let result = DocumentationProvider.ToolCatalog.applying(
            update,
            to: try jsonValue(["tools": []])
        )
        #expect(documentationDescriptorDescription(in: result) == "docs-27.0")

        async let searchOutcome = providerManager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 91, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )
        let searchRequest = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))
        #expect(methodName(from: searchRequest) == "tools/call")
        #expect(try documentationSearchQuery(in: searchRequest) == "UIView")
        let searchRequestID = try extractUpstreamID(from: searchRequest)
        await yieldMessage(
            try makeDocumentationSearchResponse(
                id: searchRequestID,
                text: "{\"answer\":\"route\"}"
            ),
            to: upstream
        )

        let outcome = try await searchOutcome
        guard case .handled(let responseData, let invalidatedProvider) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(invalidatedProvider == false)
        #expect(try responseID(in: responseData) == 91)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"route\"}")
        #expect(await upstream.sentCount() == 2)
    }

    @Test func runtimeDocumentationTransportDoesNotOpenFallbackForReusedRouteToolsListFailure()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
        await upstream.overloadNextSend()
        let target = documentationProviderTarget(processID: 741, xcodeVersion: "27.0")
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let openStarted = TestSignal()
        let openGate = AsyncGate()
        let fallback = BlockingFallbackDocumentationProviderTransport(
            openStarted: openStarted,
            openGate: openGate
        )
        let providerManager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            transport: RuntimeDocumentationProviderTransport(
                runtimeBox: runtimeBox,
                fallback: fallback
            ),
            providerSelectionTimeout: .seconds(1)
        )
        let route = DocumentationProviderRoute(
            id: "upstream-0-pid-\(target.processID)",
            target: target,
            upstreamIndex: 0
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderRoutes: [route],
            documentationProviderManager: providerManager,
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let update = await providerManager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(
            update,
            to: try jsonValue(["tools": []])
        )

        #expect(DocumentationProvider.ToolCatalog.descriptor(in: result) == nil)
        #expect(await upstream.sentCount() == 1)
        #expect(await fallback.openCount() == 0)
    }

    @Test func runtimeDocumentationTransportFallsBackWhenReusedUpstreamRouteFails()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
        await upstream.overloadNextSend()
        let target = documentationProviderTarget(processID: 742, xcodeVersion: "27.0")
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"fallback\"}"),
                        userCallResponses: [.successText("{\"answer\":\"reused-fallback\"}")]
                    ),
                ],
            ]
        )
        let providerManager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            transport: RuntimeDocumentationProviderTransport(
                runtimeBox: runtimeBox,
                fallback: SessionBackedDocumentationProviderTransport(sessionFactory: factory)
            ),
            providerSelectionTimeout: .seconds(1)
        )
        let route = DocumentationProviderRoute(
            id: "upstream-0-pid-\(target.processID)",
            target: target,
            upstreamIndex: 0
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderRoutes: [route],
            documentationProviderManager: providerManager,
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let firstOutcome = try await providerManager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 94, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )
        let firstRuntimeRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: firstRuntimeRequest) == "tools/call")
        guard case .handled(let firstData, _) = firstOutcome else {
            Issue.record("expected handled fallback outcome, got \(firstOutcome)")
            return
        }
        #expect(try toolContentText(in: firstData) == "{\"answer\":\"fallback\"}")
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(await factory.documentationQueries(for: target.processID) == ["UIView"])
        guard case .degraded = manager.testStateSnapshot().upstreams[0].healthState else {
            Issue.record("proxy-generated upstream failure should not be marked successful")
            return
        }

        let secondOutcome = try await providerManager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 95, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .handled(let secondData, _) = secondOutcome else {
            Issue.record("expected handled fallback reuse outcome, got \(secondOutcome)")
            return
        }
        #expect(try toolContentText(in: secondData) == "{\"answer\":\"reused-fallback\"}")
        #expect(await upstream.sentCount() == 1)
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(await factory.documentationQueries(for: target.processID) == ["UIView", "SwiftUI"])
    }

    @Test func runtimeDocumentationTransportTimesOutQueuedPinnedRouteBeforeDispatch()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = documentationProviderTarget(processID: 746, xcodeVersion: "27.0")
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let providerManager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            transport: RuntimeDocumentationProviderTransport(runtimeBox: runtimeBox),
            providerSelectionTimeout: .seconds(1)
        )
        let route = DocumentationProviderRoute(
            id: "upstream-0-pid-\(target.processID)",
            target: target,
            upstreamIndex: 0
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderRoutes: [route],
            documentationProviderManager: providerManager,
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:LongRunning",
            isBatch: false,
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop,
            preferredUpstreamIndex: 0
        ) { selectedUpstreamIndex in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedUpstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture
        try await waitForCondition(timeoutSeconds: 2) {
            manager.debugSnapshot().leases.contains { lease in
                lease.leaseID == activeLeaseID.uuidString && lease.state == .active
            }
        }

        let started = Date()
        let outcome = try await providerManager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 96, query: "UIView"),
            requestTimeoutOverride: .milliseconds(10)
        )

        #expect(Date().timeIntervalSince(started) < 0.5)
        guard case .failed(let error, _) = outcome else {
            Issue.record("expected timed-out outcome, got \(outcome)")
            activePromise.fail(CancellationError())
            return
        }
        #expect(error is TimeoutError)
        #expect(await upstream.sentCount() == 0)
        try await waitForCondition(timeoutSeconds: 2) {
            manager.debugSnapshot().queuedRequestCount == 0
        }

        activePromise.fail(CancellationError())
    }

    @Test func runtimeDocumentationTransportClosesFallbackOpenedAfterRouteInvalidation()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = ToggleableOverloadUpstreamClient()
        await upstream.overloadNextSend()
        let target = documentationProviderTarget(processID: 743, xcodeVersion: "27.0")
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let openStarted = TestSignal()
        let openGate = AsyncGate()
        let fallback = BlockingFallbackDocumentationProviderTransport(
            openStarted: openStarted,
            openGate: openGate
        )
        let providerManager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            transport: RuntimeDocumentationProviderTransport(
                runtimeBox: runtimeBox,
                fallback: fallback
            ),
            providerSelectionTimeout: .seconds(1)
        )
        let route = DocumentationProviderRoute(
            id: "upstream-0-pid-\(target.processID)",
            target: target,
            upstreamIndex: 0
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderRoutes: [route],
            documentationProviderManager: providerManager,
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let searchTask = Task {
            try await providerManager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 96, query: "UIView"),
                requestTimeoutOverride: .seconds(1)
            )
        }
        _ = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        try await openStarted.wait(description: "waiting for fallback open")

        await providerManager.invalidate(reason: "test_invalidation")
        await openGate.signal()

        do {
            _ = try await waitWithTimeout(
                "waiting for invalidated documentation search",
                timeout: .seconds(2)
            ) {
                try await searchTask.value
            }
            Issue.record("expected invalidated documentation search to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for invalidated search, got \(error)")
        }
        #expect(await fallback.closeCount() == 1)
    }

    @Test func documentationProviderManagerClosesRouteOpenedAfterPreparationCancellation()
        async throws
    {
        let target = documentationProviderTarget(processID: 744, xcodeVersion: "27.0")
        let openStarted = TestSignal()
        let openGate = AsyncGate()
        let transport = BlockingFallbackDocumentationProviderTransport(
            openStarted: openStarted,
            openGate: openGate,
            ignoresOpenCancellation: true
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            transport: transport,
            providerSelectionTimeout: .seconds(5)
        )

        let searchTask = Task {
            try await manager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 97, query: "UIView"),
                requestTimeoutOverride: .seconds(5)
            )
        }
        try await openStarted.wait(description: "waiting for provider open")

        await manager.invalidate(reason: "test_invalidation")
        await openGate.signal()

        do {
            _ = try await waitWithTimeout(
                "waiting for cancelled provider preparation",
                timeout: .seconds(2)
            ) {
                try await searchTask.value
            }
            Issue.record("expected provider preparation to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for provider preparation, got \(error)")
        }
        #expect(await transport.closeCount() == 1)
    }

    @Test func runtimeDocumentationTransportCancellationReleasesControlPlaneLease()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let target = documentationProviderTarget(processID: 745, xcodeVersion: "27.0")
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let route = DocumentationProviderRoute(
            id: "upstream-0-pid-\(target.processID)",
            target: target,
            upstreamIndex: 0
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 30),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderRoutes: [route],
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let toolsListTask = Task {
            try await manager.documentationProviderToolsList(
                route: route,
                requestTimeout: .seconds(30)
            )
        }
        let toolsRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: toolsRequest) == "tools/list")

        toolsListTask.cancel()
        do {
            _ = try await waitWithTimeout(
                "waiting for cancelled documentation tools/list",
                timeout: .seconds(2)
            ) {
                try await toolsListTask.value
            }
            Issue.record("expected documentation tools/list to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for documentation tools/list, got \(error)")
        }
        #expect(await waitUntil(timeout: .seconds(2)) {
            let snapshot = manager.debugSnapshot()
            return snapshot.queuedRequestCount == 0
                && snapshot.upstreams[0].activeCorrelatedRequestCount == 0
        })

        let searchTask = Task {
            try await manager.documentationProviderCall(
                route: route,
                requestData: makeDocumentationSearchRequest(id: 93, query: "UIView"),
                requestTimeout: .seconds(30)
            )
        }
        let searchRequest = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))
        #expect(methodName(from: searchRequest) == "tools/call")
        #expect(try documentationSearchQuery(in: searchRequest) == "UIView")

        searchTask.cancel()
        do {
            _ = try await waitWithTimeout(
                "waiting for cancelled documentation search",
                timeout: .seconds(2)
            ) {
                try await searchTask.value
            }
            Issue.record("expected documentation search to be cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for documentation search, got \(error)")
        }
        #expect(await waitUntil(timeout: .seconds(2)) {
            let snapshot = manager.debugSnapshot()
            return snapshot.queuedRequestCount == 0
                && snapshot.upstreams[0].activeCorrelatedRequestCount == 0
        })
    }

    @Test func runtimeDocumentationTransportFallsBackToDirectCandidateWhenNoUpstreamRouteExists()
        async throws
    {
        let newer = documentationProviderTarget(processID: 750, xcodeVersion: "27.0")
        let older = documentationProviderTarget(processID: 751, xcodeVersion: "26.6")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                newer.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"newer\"}")
                    ),
                ],
                older.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"older\"}")
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [older, newer]),
            transport: RuntimeDocumentationProviderTransport(
                runtimeBox: WeakRuntimeCoordinatorBox(),
                fallback: SessionBackedDocumentationProviderTransport(sessionFactory: factory)
            ),
            providerSelectionTimeout: .seconds(1)
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 92, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"newer\"}")
        #expect(await factory.startedPIDs() == [newer.processID])
        #expect(await factory.documentationQueries(for: newer.processID) == ["UIView"])
        #expect(await factory.documentationQueries(for: older.processID).isEmpty)
    }

    @Test func sharedToolsListMergesDocumentationProviderDescriptor() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0"))
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderManager: documentationProvider
        )
        defer { manager.shutdownAndWait() }

        manager.setCachedToolsListResult(
            try jsonValue([
                "tools": [
                    [
                        "name": "XcodeRead",
                        "description": "read",
                    ],
                ],
            ]),
            sourceUpstream: 0
        )

        let result = try await manager.sharedToolsList(
            sessionID: "session-docs-tools",
            requestTimeoutOverride: nil
        )

        #expect(toolNames(in: result) == ["XcodeRead", "DocumentationSearch"])
        #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        let observedTimeout = try #require(await documentationProvider.lastToolListTimeout())
        #expect(observedTimeout.nanoseconds > 0)
    }

    @Test func sharedToolsListWaitsForStartupDocumentationPrewarm() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let prewarmStarted = TestSignal()
        let prewarmGate = AsyncGate()
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0")),
            prewarmStarted: prewarmStarted,
            prewarmBlocker: prewarmGate
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderManager: documentationProvider,
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.setCachedToolsListResult(
            try jsonValue([
                "tools": [
                    [
                        "name": "XcodeRead",
                        "description": "read",
                    ],
                ],
            ]),
            sourceUpstream: 0
        )

        manager.prewarmDocumentationProvider()
        try await prewarmStarted.wait(description: "documentation prewarm started")

        let resultTask = Task {
            try await manager.sharedToolsList(
                sessionID: "session-docs-tools-prewarm",
                requestTimeoutOverride: .seconds(1)
            )
        }
        #expect(
            await staysTrue(for: .milliseconds(100)) {
                await documentationProvider.toolListUpdateCount() == 0
            }
        )

        await prewarmGate.signal()
        let result = try await resultTask.value

        #expect(toolNames(in: result) == ["XcodeRead", "DocumentationSearch"])
        #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        #expect(await documentationProvider.prewarmCount() == 1)
        #expect(await documentationProvider.toolListUpdateCount() == 1)
    }

    @Test func sharedToolsListDoesNotWaitPastTimeoutForStartupDocumentationPrewarm()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let prewarmStarted = TestSignal()
        let prewarmGate = AsyncGate()
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0")),
            prewarmStarted: prewarmStarted,
            prewarmBlocker: prewarmGate
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderManager: documentationProvider,
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.setCachedToolsListResult(
            try jsonValue([
                "tools": [
                    [
                        "name": "XcodeRead",
                        "description": "read",
                    ],
                ],
            ]),
            sourceUpstream: 0
        )

        manager.prewarmDocumentationProvider()
        try await prewarmStarted.wait(description: "documentation prewarm started")

        let result = try await waitWithTimeout(
            "tools/list should not wait for the blocked documentation prewarm",
            timeout: .milliseconds(500)
        ) {
            try await manager.sharedToolsList(
                sessionID: "session-docs-tools-prewarm-timeout",
                requestTimeoutOverride: .milliseconds(20)
            )
        }

        #expect(toolNames(in: result) == ["XcodeRead"])
        #expect(await documentationProvider.toolListUpdateCount() == 0)
        await prewarmGate.signal()
        #expect(await waitUntil(timeout: .seconds(2)) {
            await documentationProvider.prewarmCount() == 1
        })
    }

    @Test func sharedToolsListRemovesStaleDocumentationSearchWhenProviderUnavailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let documentationProvider = StubDocumentationProviderManager(toolListUpdate: .unavailable)
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderManager: documentationProvider
        )
        defer { manager.shutdownAndWait() }

        manager.setCachedToolsListResult(
            try jsonValue([
                "tools": [
                    documentationDescriptor(version: "26.6").foundationObject,
                    [
                        "name": "XcodeRead",
                        "description": "read",
                    ],
                ],
            ]),
            sourceUpstream: 0
        )

        let result = try await manager.sharedToolsList(
            sessionID: "session-docs-unavailable",
            requestTimeoutOverride: nil
        )

        #expect(toolNames(in: result) == ["XcodeRead"])
        #expect(DocumentationProvider.ToolCatalog.descriptor(in: result) == nil)
        #expect(manager.cachedToolsListResult() != nil)
    }

    @Test func sharedToolsListTimeoutDoesNotInvalidateDocumentationProvider() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0")),
            toolListDelayNanoseconds: 50_000_000
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderManager: documentationProvider
        )
        defer { manager.shutdownAndWait() }

        manager.setCachedToolsListResult(
            try jsonValue([
                "tools": [
                    documentationDescriptor(version: "26.6").foundationObject,
                    [
                        "name": "XcodeRead",
                        "description": "read",
                    ],
                ],
            ]),
            sourceUpstream: 0
        )

        let result = try await manager.sharedToolsList(
            sessionID: "session-docs-timeout",
            requestTimeoutOverride: .milliseconds(1)
        )

        #expect(toolNames(in: result) == ["XcodeRead"])
        #expect(manager.cachedToolsListResult() != nil)
        #expect(await documentationProvider.recordedInvalidateReasons().isEmpty)
    }

    @Test func documentationSearchKeepsCanonicalToolsCatalogWhenProviderRecoversAfterInvalidation() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let providerResponse = try makeJSONRPCResponse(
            id: 41,
            result: [
                "content": [
                    [
                        "type": "text",
                        "text": "Tool 'DocumentationSearch' is not enabled.",
                    ],
                ],
                "isError": true,
            ]
        )
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0")),
            callOutcomes: [.handled(providerResponse, invalidatedProvider: true)]
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderManager: documentationProvider
        )
        defer { manager.shutdownAndWait() }

        manager.setCachedToolsListResult(
            try jsonValue([
                "tools": [
                    documentationDescriptor(version: "27.0").foundationObject,
                ],
            ]),
            sourceUpstream: 0
        )
        #expect(manager.cachedToolsListResult() != nil)

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 41, query: "UIView"),
            requestTimeoutOverride: nil
        )

        guard case .handled(let responseData) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(responseData == providerResponse)
        #expect(manager.cachedToolsListResult() != nil)
        #expect(await documentationProvider.callCount() == 1)
        let observedTimeout = try #require(await documentationProvider.lastCallTimeout())
        #expect(observedTimeout.nanoseconds == TimeAmount.seconds(5).nanoseconds)
    }

    @Test func documentationSearchDoesNotInvalidateWhenSuccessfulAnswerMentionsNotEnabled()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let providerResponse = try makeJSONRPCResponse(
            id: 43,
            result: [
                "content": [
                    [
                        "type": "text",
                        "text": "A user may see: Tool 'DocumentationSearch' is not enabled.",
                    ],
                ],
                "isError": false,
            ]
        )
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0")),
            callOutcomes: [.handled(providerResponse, invalidatedProvider: false)]
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderManager: documentationProvider
        )
        defer { manager.shutdownAndWait() }

        let cachedTools = try jsonValue([
            "tools": [
                documentationDescriptor(version: "27.0").foundationObject,
            ],
        ])
        manager.setCachedToolsListResult(cachedTools, sourceUpstream: 0)

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 43, query: "not enabled error"),
            requestTimeoutOverride: nil
        )

        guard case .handled(let responseData) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(DocumentationProvider.ToolCatalog.responseIsDocumentationNotEnabled(responseData) == false)
        #expect(responseData == providerResponse)
        let cachedResult = try #require(manager.cachedToolsListResult())
        #expect(DocumentationProvider.ToolCatalog.descriptor(in: cachedResult) != nil)
        #expect(await documentationProvider.callCount() == 1)
    }

    @Test func documentationSearchReportsUnavailableWhenNoProviderAvailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0")),
            callOutcomes: [.unavailable(.noAvailableProvider)]
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderManager: documentationProvider
        )
        defer { manager.shutdownAndWait() }

        manager.setCachedToolsListResult(
            try jsonValue([
                "tools": [
                    [
                        "name": "XcodeRead",
                        "description": "read",
                    ],
                ],
            ]),
            sourceUpstream: 0
        )
        _ = try await manager.sharedToolsList(
            sessionID: "session-docs-recovery-failed",
            requestTimeoutOverride: nil
        )
        #expect(manager.cachedToolsListResult() != nil)

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 43, query: "UIView"),
            requestTimeoutOverride: nil
        )
        guard case .unavailable(let reason) = outcome else {
            Issue.record("expected unavailable outcome, got \(outcome)")
            return
        }
        #expect(reason.message == DocumentationProvider.UnavailableReason.userFacingMessage)
        #expect(manager.cachedToolsListResult() != nil)
        #expect(await documentationProvider.callCount() == 1)
    }

    @Test func startupPrewarmsDocumentationProviderWhenEnabled() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0"))
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 300),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderManager: documentationProvider,
            prewarmDocumentationProviderOnStartup: true
        )
        defer { manager.shutdownAndWait() }

        try await spinUntil("waiting for documentation provider startup prewarm") {
            await documentationProvider.prewarmCount() == 1
        }

        let observedTimeout = try #require(await documentationProvider.lastPrewarmTimeout())
        #expect(observedTimeout.nanoseconds == TimeAmount.seconds(30).nanoseconds)
        #expect(await documentationProvider.toolListUpdateCount() == 1)
    }

    @Test func shutdownCancelsPendingDocumentationProviderStartupPrewarm() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let prewarmStarted = TestSignal()
        let prewarmBlocker = AsyncGate()
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0")),
            prewarmStarted: prewarmStarted,
            prewarmBlocker: prewarmBlocker
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 300),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderManager: documentationProvider,
            prewarmDocumentationProviderOnStartup: true
        )

        try await prewarmStarted.wait(description: "waiting for startup prewarm to begin")
        await manager.shutdown()

        #expect(await documentationProvider.prewarmCount() == 0)
        #expect(await documentationProvider.shutdownCount() == 1)
    }

    @Test func documentationProviderToolListUpdateDoesNotStartDiscoveryOrSearch() async throws {
        let target = documentationProviderTarget(processID: 101, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .success
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        let update = await manager.toolListUpdate(requestTimeout: nil)

        guard case .unchanged = update else {
            Issue.record("expected unchanged update, got \(update)")
            return
        }
        #expect(await factory.startedPIDs().isEmpty)
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 0)
    }

    @Test func documentationProviderBackgroundDiscoveryFetchesDescriptorWithoutSearch() async throws {
        let target = documentationProviderTarget(processID: 111, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .success
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        let update = await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/list") == 1)
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 0)

        let cachedUpdate = await manager.toolListUpdate(requestTimeout: .seconds(1))
        let cachedResult = DocumentationProvider.ToolCatalog.applying(
            cachedUpdate,
            to: try jsonValue(["tools": []])
        )
        #expect(documentationDescriptorDescription(in: cachedResult) == "docs-27.0")
    }

    @Test func documentationProviderBackgroundDiscoveryRetriesTransientDescriptorUnavailable()
        async throws
    {
        let target = documentationProviderTarget(processID: 116, xcodeVersion: "27.0")
        let transport = TransientUnavailableDescriptorTransport()
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            transport: transport
        )

        let update = await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-transient")
        #expect(await transport.toolsListCount() == 2)
    }

    @Test func documentationProviderBackgroundDiscoveryRepairsDescriptorMissingService()
        async throws
    {
        let target = documentationProviderTarget(processID: 117, xcodeVersion: "26.6")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 20,
                        includesDocumentationSearch: false,
                        firstDocumentationResponse: .success
                    ),
                    .init(
                        serverVersion: "26.6",
                        toolCount: 21,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .success
                    ),
                ],
            ]
        )
        let repairer = StubDocumentationSearchServiceRepairer(
            result: .repaired(
                DocumentationSearchServiceRepairReport(
                    configURL: "/docs/config.json",
                    xcodeVersion: "26.5",
                    osVersion: "26.2",
                    documentationRelease: 900339,
                    changedDefault: true
                )
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            serviceRepairer: repairer
        )

        let update = await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-26.6")
        #expect(await repairer.repairedPIDs() == [target.processID])
        #expect(await factory.startedPIDs() == [target.processID, target.processID])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/list") == 2)
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 0)
    }

    @Test func repairedDocumentationProviderKeepsReopenedRouteForSearch()
        async throws
    {
        let target = documentationProviderTarget(processID: 118, xcodeVersion: "26.6")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 20,
                        includesDocumentationSearch: false,
                        firstDocumentationResponse: .success
                    ),
                    .init(
                        serverVersion: "26.6",
                        toolCount: 21,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"repaired\"}")
                    ),
                ],
            ]
        )
        let repairer = StubDocumentationSearchServiceRepairer(
            result: .repaired(
                DocumentationSearchServiceRepairReport(
                    configURL: "/docs/config.json",
                    xcodeVersion: "26.5",
                    osVersion: "26.2",
                    documentationRelease: 900339,
                    changedDefault: true
                )
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            serviceRepairer: repairer
        )

        let update = await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))
        #expect(documentationDescriptorDescription(in: result) == "docs-26.6")

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 118, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"repaired\"}")
        #expect(await repairer.repairedPIDs() == [target.processID])
        #expect(await factory.startedPIDs() == [target.processID, target.processID])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/list") == 2)
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 1)
        #expect(await factory.documentationQueries(for: target.processID) == ["UIView"])
    }

    @Test func documentationProviderUsesInstalledAssetFallbackWhenRepairDoesNotRestoreDescriptor()
        async throws
    {
        let target = documentationProviderTarget(processID: 119, xcodeVersion: "26.6")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 20,
                        includesDocumentationSearch: false,
                        firstDocumentationResponse: .success
                    ),
                    .init(
                        serverVersion: "26.6",
                        toolCount: 20,
                        includesDocumentationSearch: false,
                        firstDocumentationResponse: .success
                    ),
                ],
            ]
        )
        let repairer = StubDocumentationSearchServiceRepairer(
            result: .repaired(
                DocumentationSearchServiceRepairReport(
                    configURL: "/docs/config.json",
                    xcodeVersion: "26.5",
                    osVersion: "26.2",
                    documentationRelease: 900339,
                    changedDefault: true
                )
            )
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-fallback"),
            responseData: try makeDocumentationSearchResponse(
                id: 120,
                text: "{\"answer\":\"asset\"}"
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            serviceRepairer: repairer,
            localSearchProvider: localProvider
        )

        let update = await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-asset-fallback")
        #expect(await repairer.repairedPIDs() == [target.processID])
        #expect(await factory.startedPIDs() == [target.processID, target.processID])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/list") == 2)

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 120, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"asset\"}")
        #expect(await localProvider.requestedCallPIDs() == [target.processID])
        #expect(await localProvider.requestedQueries() == ["UIView"])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 0)
    }

    @Test func documentationProviderFallsBackToInstalledAssetWhenXcodeReturnsNotEnabled()
        async throws
    {
        let target = documentationProviderTarget(processID: 121, xcodeVersion: "26.6")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 21,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .notEnabled
                    ),
                ],
            ]
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-fallback"),
            responseData: try makeDocumentationSearchResponse(
                id: 122,
                text: "{\"answer\":\"asset\"}"
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            localSearchProvider: localProvider
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 122, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, let invalidatedProvider) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(invalidatedProvider == false)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"asset\"}")
        #expect(await localProvider.requestedCallPIDs() == [target.processID])
        #expect(await localProvider.requestedQueries() == ["SwiftUI"])
        #expect(await factory.documentationQueries(for: target.processID) == ["SwiftUI"])
    }

    @Test func documentationProviderFallsBackToInstalledAssetWhenXcodeConfigIsBroken()
        async throws
    {
        let target = documentationProviderTarget(processID: 124, xcodeVersion: "26.6")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 21,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .toolErrorText(
                            "The file “config.json” couldn’t be opened because there is no such file."
                        ),
                        userCallResponses: [.successText("{\"answer\":\"after-error\"}")]
                    ),
                ],
            ]
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-fallback"),
            responseData: try makeDocumentationSearchResponse(
                id: 124,
                text: "{\"answer\":\"asset\"}"
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            localSearchProvider: localProvider
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 124, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, let invalidatedProvider) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(invalidatedProvider == false)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"asset\"}")
        #expect(await localProvider.requestedCallPIDs() == [target.processID])
        #expect(await localProvider.requestedQueries() == ["UIView"])
        #expect(await factory.documentationQueries(for: target.processID) == ["UIView"])
    }

    @Test func liveDocumentationSearchServiceRepairerSelectsClosestSameMajorAsset()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-27",
            xcodeVersion: "27.0",
            osVersion: "26.6",
            documentationRelease: 950001
        )
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-26-5",
            xcodeVersion: "26.5",
            osVersion: "26.2",
            documentationRelease: 900339
        )
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-26-3",
            xcodeVersion: "26.3",
            osVersion: "26.2",
            documentationRelease: 900124
        )
        let writtenValues = NIOLockedValueBox<[String]>([])
        let repairer = LiveDocumentationSearchServiceRepairer(
            assetRoot: root,
            currentOSVersion: { "26.5.1" },
            readConfigURLOverride: { nil },
            writeConfigURLOverride: { value in
                writtenValues.withLockedValue { $0.append(value) }
                return true
            }
        )

        let result = await repairer.repairDocumentationSearch(
            for: documentationProviderTarget(processID: 118, xcodeVersion: "26.6")
        )

        guard case .repaired(let report) = result else {
            Issue.record("expected repaired result, got \(result)")
            return
        }
        #expect(report.xcodeVersion == "26.5")
        #expect(report.osVersion == "26.2")
        #expect(report.documentationRelease == 900339)
        #expect(report.changedDefault)
        #expect(report.configURL.hasPrefix("/"))
        #expect(report.configURL.contains("xcode-26-5.asset/AssetData/config.json"))
        #expect(writtenValues.withLockedValue { $0 } == [report.configURL])
    }

    @Test func liveDocumentationAssetSearchProviderReturnsInstalledAssetResults()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-26-5",
            xcodeVersion: "26.5",
            osVersion: "26.2",
            documentationRelease: 900339
        )
        let runner = StubProcessRunner(output: ProcessOutput(
            terminationStatus: 0,
            stdout: """
                [{"asset_id":"/documentation/UIKit/UIView","type":"symbol","framework":"UIKit","title":"UIView","content":"UIView\\nClass of UIKit"}]
                """,
            stderr: ""
        ))
        let provider = LiveDocumentationAssetSearchProvider(
            assetRoot: root,
            currentOSVersion: { "26.5.1" },
            processRunner: runner
        )
        let target = documentationProviderTarget(processID: 123, xcodeVersion: "26.6")

        #expect(await provider.descriptor(for: target) != nil)
        let response = try await provider.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 123, query: "UIView"),
            for: target,
            timeout: .seconds(1)
        )

        let maybeText = try toolContentText(in: response)
        let text = try #require(maybeText)
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8), options: []) as? [String: Any]
        )
        #expect(payload["source"] as? String == "installed-documentation-asset")
        let documents = try #require(payload["documents"] as? [[String: Any]])
        let firstTitle = documents.first?["title"] as? String
        #expect(firstTitle == "UIView")
        let requests = await runner.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.arguments.first == "-json")
        #expect(requests.first?.arguments.joined(separator: " ").contains(
            "xcode-26-5.asset/AssetData/documentation-db/index.sql"
        ) == true)
    }

    @Test func liveDocumentationAssetSearchProviderHonorsSearchTimeout()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-26-5",
            xcodeVersion: "26.5",
            osVersion: "26.2",
            documentationRelease: 900339
        )
        let runner = StubProcessRunner(
            output: ProcessOutput(terminationStatus: 0, stdout: "[]", stderr: ""),
            delayNanoseconds: 300_000_000
        )
        let provider = LiveDocumentationAssetSearchProvider(
            assetRoot: root,
            currentOSVersion: { "26.5.1" },
            processRunner: runner
        )
        let target = documentationProviderTarget(processID: 125, xcodeVersion: "26.6")

        await #expect(throws: TimeoutError.self) {
            _ = try await waitWithTimeout(
                "local DocumentationSearch should honor the caller timeout",
                timeout: .milliseconds(500)
            ) {
                try await provider.callDocumentationSearch(
                    requestData: makeDocumentationSearchRequest(id: 125, query: "UIView"),
                    for: target,
                    timeout: .milliseconds(20)
                )
            }
        }
        let requests = await runner.recordedRequests()
        #expect(requests.count == 1)
        #expect(await waitUntil(timeout: .seconds(2)) {
            await runner.cancelledRunCount() == 1
        })
    }

    @Test func documentationProviderBackgroundDiscoveryKeepsBaseCatalogWhenDescriptorIsAbsent()
        async throws
    {
        let target = documentationProviderTarget(processID: 115, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 46,
                        includesDocumentationSearch: false,
                        firstDocumentationResponse: .success
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        let update = await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(
            update,
            to: try jsonValue([
                "tools": [
                    documentationDescriptor(version: "stale").foundationObject,
                ],
            ])
        )

        #expect(documentationDescriptorDescription(in: result) == "docs-stale")
        #expect(await factory.requestCount(processID: target.processID, method: "tools/list") == 1)
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 0)
    }

    @Test func documentationSearchDoesNotWaitForBackgroundDescriptorFetch() async throws {
        let target = documentationProviderTarget(processID: 114, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        hangsToolsList: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"direct\"}")
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        let discoveryTask = Task {
            await manager.startBackgroundDiscovery(requestTimeout: .seconds(2))
        }
        defer { discoveryTask.cancel() }
        try await waitWithTimeout("waiting for background descriptor fetch") {
            try await factory.waitForRequestCount(
                1,
                processID: target.processID,
                method: "tools/list"
            )
        }

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 70, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"direct\"}")
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(await factory.documentationQueries(for: target.processID) == ["UIView"])
    }

    @Test func documentationProviderManagerUsesNumericIDsForMCPBridgeStartup() async throws {
        let target = documentationProviderTarget(processID: 112, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .success,
                        requiresNumericRequestIDs: true
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        let update = await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        #expect(await factory.startedPIDs() == [target.processID])
    }

    @Test func documentationProviderManagerUsesConfiguredInitializeParamsForStartup() async throws {
        let target = documentationProviderTarget(processID: 113, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .success
                    ),
                ],
            ]
        )
        let initializeParams = try jsonValue([
            "protocolVersion": "2025-06-18",
            "capabilities": [
                "roots": [
                    "listChanged": true,
                ],
            ],
            "clientInfo": [
                "name": "ConfiguredAssistant",
                "version": "9.9.9",
            ],
        ])
        guard case .object(let initializeObject) = initializeParams else {
            Issue.record("expected initialize params object")
            return
        }
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            initializeParams: initializeObject
        )

        _ = await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))

        let observedParams = try #require(await factory.initializeParams(for: target.processID).first)
        guard case .object(let observedObject) = observedParams else {
            Issue.record("expected initialize params object")
            return
        }
        guard case .string("2025-06-18")? = observedObject["protocolVersion"] else {
            Issue.record("expected configured protocol version")
            return
        }
        guard case .object(let capabilities)? = observedObject["capabilities"],
              case .object(let roots)? = capabilities["roots"],
              case .bool(true)? = roots["listChanged"] else {
            Issue.record("expected configured capabilities")
            return
        }
        guard case .object(let clientInfo)? = observedObject["clientInfo"],
              case .string("ConfiguredAssistant")? = clientInfo["name"],
              case .string("9.9.9")? = clientInfo["version"] else {
            Issue.record("expected configured client info")
            return
        }
    }

    @Test func documentationProviderManagerPrefersNewerXcodeVersionOverToolCount() async throws {
        let xcode26 = documentationProviderTarget(processID: 399, xcodeVersion: "26.6")
        let xcode27 = documentationProviderTarget(processID: 401, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 100,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"old\"}")
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 1,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"new\"}")
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 71, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"new\"}")
        #expect(await factory.startedPIDs() == [xcode27.processID])
        #expect(await factory.documentationQueries(for: xcode27.processID) == ["SwiftUI"])
        #expect(await factory.documentationQueries(for: xcode26.processID).isEmpty)
    }

    @Test func documentationProviderManagerUsesDeterministicOrderWithinSameXcodeVersion() async throws {
        let first = documentationProviderTarget(processID: 501, xcodeVersion: "27.0")
        let second = documentationProviderTarget(processID: 502, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                first.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 1,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"first\"}")
                    ),
                ],
                second.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 1,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"second\"}")
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [second, first]),
            sessionFactory: factory
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 72, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"first\"}")
        #expect(await factory.startedPIDs() == [first.processID])
    }

    @Test func documentationProviderManagerSendsActualRequestsAndReusesSuccessfulSession() async throws {
        let target = documentationProviderTarget(processID: 601, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"first\"}"),
                        userCallResponses: [.successText("{\"answer\":\"second\"}")]
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        let firstOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 73, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )
        let secondOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 74, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let firstData, _) = firstOutcome,
              case .handled(let secondData, _) = secondOutcome else {
            Issue.record("expected handled outcomes, got \(firstOutcome) and \(secondOutcome)")
            return
        }
        #expect(try toolContentText(in: firstData) == "{\"answer\":\"first\"}")
        #expect(try toolContentText(in: secondData) == "{\"answer\":\"second\"}")
        #expect(try responseID(in: firstData) == 73)
        #expect(try responseID(in: secondData) == 74)
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(await factory.documentationQueries(for: target.processID) == ["UIView", "SwiftUI"])
    }

    @Test func documentationProviderManagerPreservesOrdinaryToolErrors() async throws {
        let target = documentationProviderTarget(processID: 602, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .toolErrorText("query-specific failure"),
                        userCallResponses: [.successText("{\"answer\":\"after-error\"}")]
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        let errorOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 82, query: "bad query"),
            requestTimeoutOverride: .seconds(1)
        )
        let followUpOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 83, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let errorData, let invalidatedProvider) = errorOutcome,
              case .handled(let followUpData, _) = followUpOutcome else {
            Issue.record("expected handled outcomes, got \(errorOutcome) and \(followUpOutcome)")
            return
        }
        #expect(invalidatedProvider == false)
        #expect(try toolResultIsError(in: errorData))
        #expect(try toolContentText(in: errorData) == "query-specific failure")
        #expect(try toolContentText(in: followUpData) == "{\"answer\":\"after-error\"}")
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(await factory.documentationQueries(for: target.processID) == ["bad query", "SwiftUI"])
    }

    @Test func documentationProviderManagerPreservesRequestScopedJSONRPCErrors()
        async throws
    {
        let target = documentationProviderTarget(processID: 603, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .jsonRPCError(
                            code: -32602,
                            message: "Invalid params"
                        ),
                        userCallResponses: [.successText("{\"answer\":\"after-jsonrpc-error\"}")]
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        let errorOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 84, query: "bad query"),
            requestTimeoutOverride: .seconds(1)
        )
        let followUpOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 85, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let errorData, let invalidatedProvider) = errorOutcome,
              case .handled(let followUpData, _) = followUpOutcome else {
            Issue.record("expected handled outcomes, got \(errorOutcome) and \(followUpOutcome)")
            return
        }
        #expect(invalidatedProvider == false)
        #expect(try responseID(in: errorData) == 84)
        #expect(try jsonRPCErrorMessage(in: errorData) == "Invalid params")
        #expect(try toolContentText(in: followUpData) == "{\"answer\":\"after-jsonrpc-error\"}")
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(await factory.documentationQueries(for: target.processID) == ["bad query", "SwiftUI"])
    }

    @Test func documentationProviderManagerDoesNotOverlayPreparedDescriptorForDifferentActiveProvider()
        async throws
    {
        let xcode26 = documentationProviderTarget(processID: 605, xcodeVersion: "26.6")
        let xcode27 = documentationProviderTarget(processID: 606, xcodeVersion: "27.0")
        let discovery = SequencedXcodeTargetDiscovery([
            [xcode26],
            [xcode27, xcode26],
            [xcode27, xcode26],
        ])
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .success
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"new\"}")
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: discovery,
            sessionFactory: factory
        )

        let prewarmUpdate = await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        let prewarmResult = DocumentationProvider.ToolCatalog.applying(
            prewarmUpdate,
            to: try jsonValue(["tools": []])
        )
        #expect(documentationDescriptorDescription(in: prewarmResult) == "docs-26.6")

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 87, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"new\"}")

        let activeUpdate = await manager.toolListUpdate(requestTimeout: .seconds(1))
        let activeResult = DocumentationProvider.ToolCatalog.applying(
            activeUpdate,
            to: try jsonValue(["tools": []])
        )
        #expect(DocumentationProvider.ToolCatalog.descriptor(in: activeResult) == nil)
        #expect(await factory.startedPIDs() == [xcode26.processID, xcode27.processID])
    }

    @Test func documentationProviderManagerSearchesDescriptorMissingPreparedTarget() async throws {
        let xcode26 = documentationProviderTarget(processID: 610, xcodeVersion: "26.6")
        let xcode27 = documentationProviderTarget(processID: 611, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"advertised\"}")
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 46,
                        includesDocumentationSearch: false,
                        firstDocumentationResponse: .successText("{\"answer\":\"actual\"}")
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory
        )

        let update = await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))
        #expect(documentationDescriptorDescription(in: result) == "docs-26.6")

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 84, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"actual\"}")
        #expect(await factory.startedPIDs() == [xcode27.processID, xcode26.processID])
        #expect(await factory.requestCount(processID: xcode27.processID, method: "tools/list") == 1)
        #expect(await factory.requestCount(processID: xcode26.processID, method: "tools/list") == 1)
        #expect(await factory.documentationQueries(for: xcode27.processID) == ["SwiftUI"])
        #expect(await factory.documentationQueries(for: xcode26.processID).isEmpty)
    }

    @Test func documentationProviderManagerRetriesActualRequestWhenNewestIsNotEnabled() async throws {
        let xcode26 = documentationProviderTarget(processID: 420, xcodeVersion: "26.6")
        let xcode27 = documentationProviderTarget(processID: 421, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"fallback\"}")
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .notEnabled
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 75, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, let invalidatedProvider) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(invalidatedProvider)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"fallback\"}")
        #expect(await factory.startedPIDs() == [xcode27.processID, xcode26.processID])
        #expect(await factory.documentationQueries(for: xcode27.processID) == ["UIView"])
        #expect(await factory.documentationQueries(for: xcode26.processID) == ["UIView"])
    }

    @Test func documentationProviderManagerContinuesFailoverWhenAssetFallbackFails()
        async throws
    {
        let xcode26 = documentationProviderTarget(processID: 422, xcodeVersion: "26.6")
        let xcode27 = documentationProviderTarget(processID: 423, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"fallback\"}")
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .notEnabled
                    ),
                ],
            ]
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-fallback"),
            responseData: try makeDocumentationSearchResponse(id: 423, text: "{\"unused\":true}"),
            failsCalls: true
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory,
            localSearchProvider: localProvider
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 75, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, let invalidatedProvider) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(invalidatedProvider)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"fallback\"}")
        #expect(await localProvider.requestedCallPIDs() == [xcode27.processID])
        #expect(await factory.startedPIDs() == [xcode27.processID, xcode26.processID])
        #expect(await factory.documentationQueries(for: xcode27.processID) == ["UIView"])
        #expect(await factory.documentationQueries(for: xcode26.processID) == ["UIView"])
    }

    @Test func documentationProviderManagerPreservesTimeForFallbackWhenNewestHangs() async throws {
        let xcode26 = documentationProviderTarget(processID: 425, xcodeVersion: "26.6")
        let xcode27 = documentationProviderTarget(processID: 426, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"fallback\"}")
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .hang
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 88, query: "UIView"),
            requestTimeoutOverride: .milliseconds(200)
        )

        guard case .handled(let responseData, let invalidatedProvider) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(invalidatedProvider)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"fallback\"}")
        #expect(await factory.startedPIDs() == [xcode27.processID, xcode26.processID])
        #expect(await factory.documentationQueries(for: xcode27.processID) == ["UIView"])
        #expect(await factory.documentationQueries(for: xcode26.processID) == ["UIView"])
    }

    @Test func documentationProviderManagerRetriesActiveNotEnabledOnNextCandidate() async throws {
        let xcode26 = documentationProviderTarget(processID: 430, xcodeVersion: "26.6")
        let xcode27 = documentationProviderTarget(processID: 431, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"fallback\"}")
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"first\"}"),
                        userCallResponses: [.notEnabled]
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory
        )

        _ = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 76, query: "First"),
            requestTimeoutOverride: .seconds(1)
        )
        let retryOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 77, query: "Retry"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, let invalidatedProvider) = retryOutcome else {
            Issue.record("expected handled outcome, got \(retryOutcome)")
            return
        }
        #expect(invalidatedProvider)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"fallback\"}")
        #expect(await factory.startedPIDs() == [xcode27.processID, xcode26.processID])
        #expect(await factory.documentationQueries(for: xcode27.processID) == ["First", "Retry"])
        #expect(await factory.documentationQueries(for: xcode26.processID) == ["Retry"])
    }

    @Test func documentationProviderManagerRetriesActiveTransportFailureOnNextCandidate() async throws {
        let xcode26 = documentationProviderTarget(processID: 440, xcodeVersion: "26.6")
        let xcode27 = documentationProviderTarget(processID: 441, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"fallback\"}")
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"first\"}"),
                        userCallResponses: [.exit]
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory
        )

        _ = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 78, query: "First"),
            requestTimeoutOverride: .seconds(1)
        )
        let retryOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 79, query: "Retry"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, let invalidatedProvider) = retryOutcome else {
            Issue.record("expected handled outcome, got \(retryOutcome)")
            return
        }
        #expect(invalidatedProvider)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"fallback\"}")
        #expect(await factory.startedPIDs() == [xcode27.processID, xcode26.processID])
        #expect(await factory.documentationQueries(for: xcode27.processID) == ["First", "Retry"])
        #expect(await factory.documentationQueries(for: xcode26.processID) == ["Retry"])
    }

    @Test func documentationProviderManagerRemovesToolOnlyWhenAllCandidatesAreUnusable() async throws {
        let xcode26 = documentationProviderTarget(processID: 450, xcodeVersion: "26.6")
        let xcode27 = documentationProviderTarget(processID: 451, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .notEnabled
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .notEnabled
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 80, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .unavailable(let reason) = outcome else {
            Issue.record("expected unavailable outcome, got \(outcome)")
            return
        }
        #expect(reason.message == DocumentationProvider.UnavailableReason.userFacingMessage)

        let followUpTools = DocumentationProvider.ToolCatalog.applying(
            await manager.toolListUpdate(requestTimeout: .seconds(1)),
            to: try jsonValue([
                "tools": [
                    documentationDescriptor(version: "stale").foundationObject,
                ],
            ])
        )
        #expect(DocumentationProvider.ToolCatalog.descriptor(in: followUpTools) == nil)
    }

    @Test func documentationProviderManagerHonorsPinnedProcessID() async throws {
        let pinned = documentationProviderTarget(processID: 460, xcodeVersion: "26.6")
        let other = documentationProviderTarget(processID: 461, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                pinned.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 20,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"pinned\"}")
                    ),
                ],
                other.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"other\"}")
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [pinned, other]),
            sessionFactory: factory,
            pinnedProcessID: pinned.processID
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 81, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"pinned\"}")
        #expect(await factory.startedPIDs() == [pinned.processID])
        #expect(await factory.documentationQueries(for: pinned.processID) == ["UIView"])
        #expect(await factory.documentationQueries(for: other.processID).isEmpty)
    }

    @Test func documentationProviderManagerCoalescesConcurrentBackgroundDiscovery() async throws {
        let target = documentationProviderTarget(processID: 470, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .success
                    ),
                ],
            ],
            startDelayNanoseconds: 100_000_000
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        async let firstUpdate = manager.startBackgroundDiscovery(requestTimeout: .seconds(2))
        async let secondUpdate = manager.startBackgroundDiscovery(requestTimeout: .seconds(2))
        let results = await [firstUpdate, secondUpdate]

        for update in results {
            let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))
            #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        }
        #expect(await factory.startAttempts() == [target.processID])
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 0)
    }

    @Test func documentationProviderManagerCoalescesConcurrentInitialDocumentationSearch() async throws {
        let target = documentationProviderTarget(processID: 480, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"first\"}"),
                        userCallResponses: [.successText("{\"answer\":\"second\"}")]
                    ),
                ],
            ],
            startDelayNanoseconds: 100_000_000
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        async let firstOutcome = manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 101, query: "UIView"),
            requestTimeoutOverride: .seconds(2)
        )
        async let secondOutcome = manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 102, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(2)
        )
        let outcomes = try await [firstOutcome, secondOutcome]

        var ids: [Int64] = []
        for outcome in outcomes {
            guard case .handled(let responseData, _) = outcome else {
                Issue.record("expected handled outcome, got \(outcome)")
                continue
            }
            ids.append(try responseID(in: responseData))
        }
        #expect(Set(ids) == Set([101, 102]))
        #expect(await factory.startAttempts() == [target.processID])
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(Set(await factory.documentationQueries(for: target.processID)) == Set(["UIView", "SwiftUI"]))
    }

    @Test func documentationProviderManagerBoundsSharedPreparationWaitByCallerTimeout()
        async throws
    {
        let target = documentationProviderTarget(processID: 485, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"after-timeout\"}")
                    ),
                ],
            ],
            startDelayNanoseconds: 500_000_000
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        let shortStart = Date()
        let shortOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 85, query: "too soon"),
            requestTimeoutOverride: .milliseconds(1)
        )
        #expect(Date().timeIntervalSince(shortStart) < 0.1)
        guard case .failed(let error, _) = shortOutcome else {
            Issue.record("expected timeout outcome, got \(shortOutcome)")
            return
        }
        #expect(error is TimeoutError)

        let followUpOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 86, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(2)
        )
        guard case .handled(let responseData, _) = followUpOutcome else {
            Issue.record("expected handled outcome, got \(followUpOutcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"after-timeout\"}")
        #expect(await factory.startAttempts() == [target.processID])
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(await factory.documentationQueries(for: target.processID) == ["SwiftUI"])
    }

    @Test func documentationProviderManagerDoesNotRetryAfterRequestTimeoutExpires() async throws {
        let xcode = documentationProviderTarget(processID: 490, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .hang
                    ),
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"late\"}")
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode]),
            sessionFactory: factory
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 91, query: "UIView"),
            requestTimeoutOverride: .milliseconds(1)
        )
        guard case .failed(let error, _) = outcome else {
            Issue.record("expected failed outcome, got \(outcome)")
            return
        }
        #expect(error is TimeoutError)
        #expect(await factory.startedPIDs() == [xcode.processID])
        #expect(await factory.documentationQueries(for: xcode.processID) == ["UIView"])
    }

    @Test func documentationProviderManagerKeepsPreparedConnectionWhenDocumentationCallIsCancelled()
        async throws
    {
        let xcode = documentationProviderTarget(processID: 491, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .hang,
                        userCallResponses: [.successText("{\"answer\":\"after-cancel\"}")]
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode]),
            sessionFactory: factory
        )
        let task = Task {
            try await manager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 92, query: "UIView"),
                requestTimeoutOverride: .seconds(2)
            )
        }
        try await waitWithTimeout("waiting for documentation request") {
            try await factory.waitForRequestCount(
                1,
                processID: xcode.processID,
                method: "tools/call"
            )
        }

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 93, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"after-cancel\"}")
        #expect(await factory.startedPIDs() == [xcode.processID])
        #expect(await factory.documentationQueries(for: xcode.processID) == ["UIView", "SwiftUI"])
    }
}
