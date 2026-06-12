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

        config.disabledToolNames = [DocumentationToolCatalog.toolName]
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
        #expect(DocumentationToolCatalog.descriptor(in: result) == nil)
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
        #expect(await documentationProvider.recordedInvalidateReasons().isEmpty)
    }

    @Test func documentationSearchKeepsCanonicalToolsCatalogWhenProviderStales() async throws {
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
            callOutcomes: [.handled(providerResponse)]
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
            callOutcomes: [.handled(providerResponse)]
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
        #expect(DocumentationToolCatalog.responseIsDocumentationNotEnabled(responseData) == false)
        #expect(responseData == providerResponse)
        let cachedResult = try #require(manager.cachedToolsListResult())
        #expect(DocumentationToolCatalog.descriptor(in: cachedResult) != nil)
        #expect(await documentationProvider.callCount() == 1)
    }

    @Test func documentationSearchFallsBackToUpstreamWhenNoProviderAvailable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let upstream = TestUpstreamClient()
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0")),
            callOutcomes: [.noProvider]
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
        guard case .fallbackToUpstream = outcome else {
            Issue.record("expected fallbackToUpstream outcome, got \(outcome)")
            return
        }
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
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0")),
            prewarmDelayNanoseconds: 300_000_000
        )
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 300),
            eventLoop: eventLoop,
            upstreams: [upstream],
            documentationProviderManager: documentationProvider,
            prewarmDocumentationProviderOnStartup: true
        )

        await manager.shutdown()
        try? await Task.sleep(nanoseconds: 400_000_000)

        #expect(await documentationProvider.prewarmCount() == 0)
        #expect(await documentationProvider.shutdownCount() == 1)
    }

    @Test func documentationProviderManagerRejectsDescriptorWhenProbeCallIsNotEnabled() async throws {
        let target = documentationProviderTarget(processID: 101)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .notEnabled
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        let update = await manager.toolListUpdate(requestTimeout: nil)
        let result = DocumentationToolCatalog.applying(
            update,
            to: try jsonValue([
                "tools": [
                    documentationDescriptor(version: "stale").foundationObject,
                ],
            ])
        )

        #expect(DocumentationToolCatalog.descriptor(in: result) == nil)
        #expect(await factory.startedPIDs() == [target.processID])
    }

    @Test func documentationProviderManagerUsesNumericIDsForMCPBridgeProbe() async throws {
        let target = documentationProviderTarget(processID: 111)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success,
                        requiresNumericRequestIDs: true
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        let update = await manager.toolListUpdate(requestTimeout: .seconds(1))
        let result = DocumentationToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        #expect(await factory.startedPIDs() == [target.processID])
    }

    @Test func documentationProviderManagerUsesConfiguredInitializeParamsForProbe() async throws {
        let target = documentationProviderTarget(processID: 112)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                ],
            ]
        )
        let initializeParams = try jsonValue([
            "protocolVersion": "2025-03-26",
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

        let update = await manager.toolListUpdate(requestTimeout: .seconds(1))
        let result = DocumentationToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        let observedParams = try #require(await factory.initializeParams(for: target.processID).first)
        guard case .object(let observedObject) = observedParams else {
            Issue.record("expected initialize params object")
            return
        }
        guard case .string("2025-03-26")? = observedObject["protocolVersion"] else {
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

    @Test func documentationProviderManagerCoalescesConcurrentProviderSelection() async throws {
        let target = documentationProviderTarget(processID: 121)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                ],
            ],
            startDelayNanoseconds: 100_000_000
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        async let firstUpdate = manager.toolListUpdate(requestTimeout: .seconds(2))
        async let secondUpdate = manager.toolListUpdate(requestTimeout: .seconds(2))
        let results = await [firstUpdate, secondUpdate]

        for update in results {
            let result = DocumentationToolCatalog.applying(update, to: try jsonValue(["tools": []]))
            #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        }
        #expect(await factory.startAttempts() == [target.processID])
        #expect(await factory.startedPIDs() == [target.processID])
    }

    @Test func documentationProviderManagerBoundsReusedProviderSelectionByCallerTimeout() async throws {
        let target = documentationProviderTarget(processID: 122)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                ],
            ],
            startDelayNanoseconds: 500_000_000
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        async let longUpdate = manager.toolListUpdate(requestTimeout: .seconds(2))
        try await spinUntil("waiting for provider selection to start") {
            await factory.startAttempts() == [target.processID]
        }

        let shortStart = Date()
        let shortUpdate = await manager.toolListUpdate(requestTimeout: .milliseconds(1))
        #expect(Date().timeIntervalSince(shortStart) < 0.1)
        if case .unavailable = shortUpdate {
        } else {
            Issue.record("short tools/list should time out while reusing provider selection")
        }

        let finalUpdate = await longUpdate
        let result = DocumentationToolCatalog.applying(finalUpdate, to: try jsonValue(["tools": []]))
        #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        #expect(await factory.startedPIDs() == [target.processID])
    }

    @Test func documentationProviderManagerKeepsSelectionAfterStartingCallerTimesOut() async throws {
        let target = documentationProviderTarget(processID: 123)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                ],
            ],
            startDelayNanoseconds: 100_000_000
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        async let shortUpdate = manager.toolListUpdate(requestTimeout: .milliseconds(1))
        try await spinUntil("waiting for provider selection to start") {
            await factory.startAttempts() == [target.processID]
        }

        let longUpdate = await manager.toolListUpdate(requestTimeout: .seconds(2))
        if case .unavailable = await shortUpdate {
        } else {
            Issue.record("short tools/list should time out without cancelling provider selection")
        }

        let result = DocumentationToolCatalog.applying(longUpdate, to: try jsonValue(["tools": []]))
        #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        #expect(await factory.startedPIDs() == [target.processID])
    }

    @Test func documentationProviderManagerCancelsSelectionWaitForCancelledCaller() async throws {
        let target = documentationProviderTarget(processID: 124)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                ],
            ],
            startDelayNanoseconds: 500_000_000
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        let task = Task {
            try await manager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 74, query: "UIView"),
                requestTimeoutOverride: .seconds(2)
            )
        }
        try await spinUntil("waiting for provider selection to start") {
            await factory.startAttempts() == [target.processID]
        }

        let cancelStart = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(Date().timeIntervalSince(cancelStart) < 0.25)

        let longUpdate = await manager.toolListUpdate(requestTimeout: .seconds(2))
        let result = DocumentationToolCatalog.applying(longUpdate, to: try jsonValue(["tools": []]))
        #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        #expect(await factory.startedPIDs() == [target.processID])
    }

    @Test func documentationProviderManagerChecksAllRunningXcodeTargetsBeforePublishingDescriptor() async throws {
        let xcode26 = documentationProviderTarget(processID: 201)
        let xcode27 = documentationProviderTarget(processID: 202)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 20,
                        includesDocumentationSearch: true,
                        probeResponse: .notEnabled
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory
        )

        let update = await manager.toolListUpdate(requestTimeout: .seconds(1))
        let result = DocumentationToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        #expect(await factory.startedPIDs() == [xcode26.processID, xcode27.processID])
    }

    @Test func documentationProviderManagerContinuesAfterCandidateProbeTimesOut() async throws {
        let hung = documentationProviderTarget(processID: 205)
        let working = documentationProviderTarget(processID: 206)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                hung.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 50,
                        includesDocumentationSearch: true,
                        probeResponse: .hang
                    ),
                ],
                working.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [hung, working]),
            sessionFactory: factory,
            providerSelectionTimeout: .milliseconds(50)
        )

        let update = await manager.toolListUpdate(requestTimeout: .seconds(1))
        let result = DocumentationToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        #expect(await factory.startedPIDs() == [hung.processID, working.processID])
    }

    @Test func documentationProviderManagerHonorsPinnedProcessID() async throws {
        let pinned = documentationProviderTarget(processID: 203)
        let other = documentationProviderTarget(processID: 204)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                pinned.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 20,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                ],
                other.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [pinned, other]),
            sessionFactory: factory,
            pinnedProcessID: pinned.processID
        )

        let update = await manager.toolListUpdate(requestTimeout: .seconds(1))
        let result = DocumentationToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-26.6")
        #expect(await factory.startedPIDs() == [pinned.processID])
    }

    @Test func documentationProviderManagerPrefersNewerServerVersionWhenToolCountsTie() async throws {
        let xcode26 = documentationProviderTarget(processID: 211)
        let xcode27 = documentationProviderTarget(processID: 212)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory
        )

        let update = await manager.toolListUpdate(requestTimeout: .seconds(1))
        let result = DocumentationToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        #expect(await factory.startedPIDs() == [xcode26.processID, xcode27.processID])
    }

    @Test func documentationProviderManagerRetriesDocumentationSearchOnAlternateCandidate() async throws {
        let xcode26 = documentationProviderTarget(processID: 201)
        let xcode27 = documentationProviderTarget(processID: 202)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 50,
                        includesDocumentationSearch: true,
                        probeResponse: .success,
                        userCallResponses: [.notEnabled]
                    ),
                    .init(
                        serverVersion: "26.6",
                        toolCount: 50,
                        includesDocumentationSearch: true,
                        probeResponse: .notEnabled
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success,
                        userCallResponses: [.successText("{\"answer\":\"retry\"}")]
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory
        )

        let initialTools = DocumentationToolCatalog.applying(
            await manager.toolListUpdate(requestTimeout: nil),
            to: try jsonValue(["tools": []])
        )
        #expect(documentationDescriptorDescription(in: initialTools) == "docs-26.6")

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 73, query: "UIView"),
            requestTimeoutOverride: nil
        )

        guard case .handled(let responseData) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(DocumentationToolCatalog.responseIsDocumentationNotEnabled(responseData) == false)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"retry\"}")
        #expect(await factory.startedPIDs() == [
            xcode26.processID,
            xcode27.processID,
            xcode26.processID,
            xcode27.processID,
        ])
    }

    @Test func documentationProviderManagerInvalidatesReplacementWhenRetryReturnsNotEnabled() async throws {
        let xcode26 = documentationProviderTarget(processID: 221)
        let xcode27 = documentationProviderTarget(processID: 222)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 50,
                        includesDocumentationSearch: true,
                        probeResponse: .success,
                        userCallResponses: [.exit]
                    ),
                    .init(
                        serverVersion: "26.6",
                        toolCount: 50,
                        includesDocumentationSearch: true,
                        probeResponse: .notEnabled
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success,
                        userCallResponses: [.notEnabled]
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory
        )

        let initialTools = DocumentationToolCatalog.applying(
            await manager.toolListUpdate(requestTimeout: nil),
            to: try jsonValue(["tools": []])
        )
        #expect(documentationDescriptorDescription(in: initialTools) == "docs-26.6")

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 75, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(DocumentationToolCatalog.responseIsDocumentationNotEnabled(responseData))
        let followUpTools = DocumentationToolCatalog.applying(
            await manager.toolListUpdate(requestTimeout: .seconds(1)),
            to: try jsonValue(["tools": []])
        )
        #expect(DocumentationToolCatalog.descriptor(in: followUpTools) == nil)
        #expect(await factory.startAttempts() == [
            xcode26.processID,
            xcode27.processID,
            xcode26.processID,
            xcode27.processID,
            xcode26.processID,
            xcode27.processID,
        ])
    }

    @Test func documentationProviderManagerInvalidatesReplacementWhenRetryTransportFails() async throws {
        let xcode26 = documentationProviderTarget(processID: 225)
        let xcode27 = documentationProviderTarget(processID: 226)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 50,
                        includesDocumentationSearch: true,
                        probeResponse: .success,
                        userCallResponses: [.exit]
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success,
                        userCallResponses: [.exit]
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory
        )

        let initialTools = DocumentationToolCatalog.applying(
            await manager.toolListUpdate(requestTimeout: nil),
            to: try jsonValue(["tools": []])
        )
        #expect(documentationDescriptorDescription(in: initialTools) == "docs-26.6")

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 77, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .noProvider = outcome else {
            Issue.record("expected noProvider outcome, got \(outcome)")
            return
        }

        let followUpTools = DocumentationToolCatalog.applying(
            await manager.toolListUpdate(requestTimeout: .seconds(1)),
            to: try jsonValue(["tools": []])
        )
        #expect(DocumentationToolCatalog.descriptor(in: followUpTools) == nil)
        #expect(await factory.startedPIDs() == [
            xcode26.processID,
            xcode27.processID,
            xcode27.processID,
        ])
    }

    @Test func documentationProviderManagerInvalidatesReplacementWhenNotEnabledRetryTransportFails()
        async throws
    {
        let xcode26 = documentationProviderTarget(processID: 227)
        let xcode27 = documentationProviderTarget(processID: 228)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 50,
                        includesDocumentationSearch: true,
                        probeResponse: .success,
                        userCallResponses: [.notEnabled]
                    ),
                    .init(
                        serverVersion: "26.6",
                        toolCount: 50,
                        includesDocumentationSearch: true,
                        probeResponse: .notEnabled
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success
                    ),
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success,
                        userCallResponses: [.exit]
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory
        )

        let initialTools = DocumentationToolCatalog.applying(
            await manager.toolListUpdate(requestTimeout: nil),
            to: try jsonValue(["tools": []])
        )
        #expect(documentationDescriptorDescription(in: initialTools) == "docs-26.6")

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 78, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .noProvider = outcome else {
            Issue.record("expected noProvider outcome, got \(outcome)")
            return
        }

        let followUpTools = DocumentationToolCatalog.applying(
            await manager.toolListUpdate(requestTimeout: .seconds(1)),
            to: try jsonValue(["tools": []])
        )
        #expect(DocumentationToolCatalog.descriptor(in: followUpTools) == nil)
        #expect(await factory.startedPIDs() == [
            xcode26.processID,
            xcode27.processID,
            xcode26.processID,
            xcode27.processID,
        ])
        #expect(await factory.startAttempts() == [
            xcode26.processID,
            xcode27.processID,
            xcode26.processID,
            xcode27.processID,
            xcode26.processID,
            xcode27.processID,
        ])
    }

    @Test func documentationProviderManagerReportsInactiveProviderWhenRecoveryFindsNoReplacement() async throws {
        let xcode = documentationProviderTarget(processID: 231)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success,
                        userCallResponses: [.exit]
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode]),
            sessionFactory: factory
        )

        let initialTools = DocumentationToolCatalog.applying(
            await manager.toolListUpdate(requestTimeout: nil),
            to: try jsonValue(["tools": []])
        )
        #expect(documentationDescriptorDescription(in: initialTools) == "docs-27.0")

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 76, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .noProvider = outcome else {
            Issue.record("expected noProvider outcome, got \(outcome)")
            return
        }

        let followUpTools = DocumentationToolCatalog.applying(
            await manager.toolListUpdate(requestTimeout: .seconds(1)),
            to: try jsonValue(["tools": []])
        )
        #expect(DocumentationToolCatalog.descriptor(in: followUpTools) == nil)
    }

    @Test func documentationProviderManagerDoesNotRetryAfterRequestTimeoutExpires() async throws {
        let xcode = documentationProviderTarget(processID: 301)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success,
                        userCallResponses: [.hang]
                    ),
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success,
                        userCallResponses: [.successText("{\"answer\":\"late\"}")]
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
        guard case .failed(let error) = outcome else {
            Issue.record("expected failed outcome, got \(outcome)")
            return
        }
        #expect(error is TimeoutError)

        #expect(await factory.startedPIDs() == [xcode.processID])
    }

    @Test func documentationProviderManagerKeepsProviderWhenDocumentationCallIsCancelled() async throws {
        let xcode = documentationProviderTarget(processID: 302)
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        probeResponse: .success,
                        userCallResponses: [.hang]
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
        let didStart = await waitUntil(timeout: .seconds(1)) {
            await factory.startedPIDs() == [xcode.processID]
        }
        #expect(didStart)

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        let update = await manager.toolListUpdate(requestTimeout: .seconds(1))
        let result = DocumentationToolCatalog.applying(update, to: try jsonValue(["tools": []]))
        #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        #expect(await factory.startedPIDs() == [xcode.processID])
    }
}
