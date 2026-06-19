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
        #expect(RuntimeCoordinator.makeDefaultDocumentationProviderManager(config: config, discovery: StubXcodeTargetDiscovery(targets: [])) != nil)

        config.disabledToolNames = [DocumentationProvider.ToolCatalog.toolName]
        #expect(RuntimeCoordinator.makeDefaultDocumentationProviderManager(config: config, discovery: StubXcodeTargetDiscovery(targets: [])) == nil)

        config.disabledToolNames = []
        config.upstreamArgs = ["--sdk", "macosx", "swift"]
        #expect(RuntimeCoordinator.makeDefaultDocumentationProviderManager(config: config, discovery: StubXcodeTargetDiscovery(targets: [])) == nil)

        config.upstreamCommand = "/bin/echo"
        config.upstreamArgs = ["xcrun", "mcpbridge"]
        #expect(RuntimeCoordinator.makeDefaultDocumentationProviderManager(config: config, discovery: StubXcodeTargetDiscovery(targets: [])) == nil)
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

    @Test func documentationProviderBackgroundDiscoveryRemovesStaleToolWhenDescriptorsAreAbsent()
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

        #expect(DocumentationProvider.ToolCatalog.descriptor(in: result) == nil)
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

    @Test func documentationProviderManagerSkipsDescriptorMissingTargetsForSearch() async throws {
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
                        firstDocumentationResponse: .toolErrorText("missing descriptor target")
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
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"advertised\"}")
        #expect(await factory.startedPIDs() == [xcode27.processID, xcode26.processID])
        #expect(await factory.documentationQueries(for: xcode27.processID).isEmpty)
        #expect(await factory.documentationQueries(for: xcode26.processID) == ["SwiftUI"])
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
