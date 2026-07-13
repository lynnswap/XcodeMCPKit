import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

private actor DocumentationSearchActionInvocationRecorder {
    private var values: [DocumentationSearchActionInvocation] = []

    func record(_ value: DocumentationSearchActionInvocation) {
        values.append(value)
    }

    func recordedValues() -> [DocumentationSearchActionInvocation] {
        values
    }
}

private struct StubDocumentationSearchActionInvoker: DocumentationSearchActionInvoking {
    let available: Bool
    let output: DocumentationSearchActionOutput
    let recorder: DocumentationSearchActionInvocationRecorder?

    init(
        available: Bool = true,
        output: DocumentationSearchActionOutput,
        recorder: DocumentationSearchActionInvocationRecorder? = nil
    ) {
        self.available = available
        self.output = output
        self.recorder = recorder
    }

    func isAvailable(for _: XcodeProcessTarget) async -> Bool {
        available
    }

    func invoke(
        _ invocation: DocumentationSearchActionInvocation,
        timeout _: TimeAmount?
    ) async throws -> DocumentationSearchActionOutput {
        await recorder?.record(invocation)
        return output
    }
}

private actor DocumentationSearchActionProcessRecorder: ProcessRunning {
    private var requests: [ProcessRequest] = []

    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        requests.append(request)
        switch request.label {
        case "DocumentationSearchAction.sdk":
            return ProcessOutput(
                terminationStatus: 0,
                stdout: "/tmp/MacOSX.sdk\n",
                stderr: ""
            )
        case "DocumentationSearchAction.bin-path":
            guard let scratchPath = processArgumentValue(after: "--scratch-path", in: request.arguments) else {
                return ProcessOutput(
                    terminationStatus: 1,
                    stdout: "",
                    stderr: "missing scratch path"
                )
            }
            return ProcessOutput(
                terminationStatus: 0,
                stdout: "\(scratchPath)/out/Products/Release\n",
                stderr: ""
            )
        case "DocumentationSearchAction.build":
            try createFakeDocumentationSearchActionHelperExecutable(for: request.arguments)
            return ProcessOutput(terminationStatus: 0, stdout: "", stderr: "")
        case "DocumentationSearchAction":
            return ProcessOutput(
                terminationStatus: 0,
                stdout: #"{"documents":[]}"#,
                stderr: ""
            )
        default:
            return ProcessOutput(
                terminationStatus: 1,
                stdout: "",
                stderr: "unexpected process request: \(request.label)"
            )
        }
    }

    func recordedRequests() -> [ProcessRequest] {
        requests
    }
}

private actor BlockingDocumentationSearchActionProcessRunner: ProcessRunning {
    private var requests: [ProcessRequest] = []
    private let buildStarted: TestSignal
    private let releaseBuild: TestSignal

    init(buildStarted: TestSignal, releaseBuild: TestSignal) {
        self.buildStarted = buildStarted
        self.releaseBuild = releaseBuild
    }

    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        requests.append(request)
        switch request.label {
        case "DocumentationSearchAction.sdk":
            return ProcessOutput(
                terminationStatus: 0,
                stdout: "/tmp/MacOSX.sdk\n",
                stderr: ""
            )
        case "DocumentationSearchAction.bin-path":
            guard let scratchPath = processArgumentValue(after: "--scratch-path", in: request.arguments) else {
                return ProcessOutput(
                    terminationStatus: 1,
                    stdout: "",
                    stderr: "missing scratch path"
                )
            }
            return ProcessOutput(
                terminationStatus: 0,
                stdout: "\(scratchPath)/out/Products/Release\n",
                stderr: ""
            )
        case "DocumentationSearchAction.build":
            buildStarted.signal()
            try await releaseBuild.wait(description: "waiting to release DocumentationSearchAction helper build")
            try createFakeDocumentationSearchActionHelperExecutable(for: request.arguments)
            return ProcessOutput(terminationStatus: 0, stdout: "", stderr: "")
        case "DocumentationSearchAction":
            return ProcessOutput(
                terminationStatus: 0,
                stdout: #"{"documents":[]}"#,
                stderr: ""
            )
        default:
            return ProcessOutput(
                terminationStatus: 1,
                stdout: "",
                stderr: "unexpected process request: \(request.label)"
            )
        }
    }

    func recordedRequests() -> [ProcessRequest] {
        requests
    }
}

private struct DocumentationSearchActionTimeoutProcessRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        throw ProcessTimeoutError(label: request.label)
    }
}

private func processArgumentValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag),
          arguments.indices.contains(arguments.index(after: index)) else {
        return nil
    }
    return arguments[arguments.index(after: index)]
}

private func createFakeDocumentationSearchActionHelperExecutable(for arguments: [String]) throws {
    guard let scratchPath = processArgumentValue(after: "--scratch-path", in: arguments) else {
        return
    }
    let helperURL = URL(fileURLWithPath: scratchPath, isDirectory: true)
        .appendingPathComponent("out", isDirectory: true)
        .appendingPathComponent("Products", isDirectory: true)
        .appendingPathComponent("Release", isDirectory: true)
        .appendingPathComponent("documentation-search-action-helper")
    try FileManager.default.createDirectory(
        at: helperURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data().write(to: helperURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: helperURL.path
    )
}

private func makeDocumentationSearchRequestWithArguments(
    id: Int64,
    query: String,
    frameworks: [String]? = nil,
    limit: Int? = nil
) throws -> Data {
    var arguments: [String: Any] = [
        "query": query,
    ]
    if let frameworks {
        arguments["frameworks"] = frameworks
    }
    if let limit {
        arguments["limit"] = limit
    }
    return try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": [
                "name": DocumentationProvider.ToolCatalog.toolName,
                "arguments": arguments,
            ],
        ],
        options: []
    )
}

private func makeFakeXcodeApp(root: URL) throws -> XcodeProcessTarget {
    let appURL = root.appendingPathComponent("Xcode.app", isDirectory: true)
    let swiftURL = appURL
        .appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
    let dvtFrameworkURL = appURL
        .appendingPathComponent("Contents/SharedFrameworks/DVTFoundation.framework/DVTFoundation")
    let chatFrameworkURL = appURL
        .appendingPathComponent("Contents/PlugIns/IDEIntelligenceChat.framework/IDEIntelligenceChat")
    let platformDeveloperLibraryURL = appURL
        .appendingPathComponent("Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib", isDirectory: true)
    for fileURL in [swiftURL, dvtFrameworkURL, chatFrameworkURL] {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: fileURL)
    }
    try FileManager.default.createDirectory(
        at: appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: platformDeveloperLibraryURL,
        withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: swiftURL.path
    )
    return XcodeProcessTarget(
        processID: 123,
        appPath: appURL.path,
        developerDir: appURL.appendingPathComponent("Contents/Developer").path,
        mcpbridgePath: appURL.appendingPathComponent("Contents/Developer/usr/bin/mcpbridge").path,
        xcodeVersion: "27.0"
    )
}

@Suite(.serialized, .asyncTestCleanup)
struct DocumentationProviderTests {
    @Test func documentationProviderConnectionCancelsEventReaderOnDeinit() async throws {
        let terminated = TestSignal()
        var connection: DocumentationProviderConnection? = DocumentationProviderConnection(
            session: HangingDocumentationEventSession(terminationSignal: terminated)
        )

        await connection?.start()
        connection = nil

        try await terminated.wait(
            description: "waiting for documentation provider event reader termination"
        )
    }

    @Test func sessionBackedDocumentationProviderCloseDoesNotWaitForSessionStopDrain()
        async throws
    {
        let target = xcodeProcessTarget(processID: 119, xcodeVersion: "27.0")
        let stopStarted = TestSignal()
        let stopGate = AsyncGate()
        let session = BlockingStopDocumentationSession(
            serverVersion: "27.0",
            stopStarted: stopStarted,
            stopGate: stopGate
        )
        let transport = SessionBackedDocumentationProviderTransport(
            sessionFactory: FixedDocumentationSessionFactory(session: session)
        )
        let route = try await transport.openRoute(
            for: target,
            requestTimeout: .seconds(1),
            initializeParams: [:]
        )

        let closeFinished = TestSignal()
        let closeTask = Task {
            await transport.close(route: route)
            closeFinished.signal()
        }
        try await stopStarted.wait(description: "waiting for provider session stop")

        try await closeFinished.wait(
            description: "documentation provider close should not wait for session stop drain"
        )

        #expect(await session.stopCount() == 1)
        await stopGate.signal()
        await closeTask.value
    }

    @Test func sessionBackedDocumentationProviderDetachedStopRetainsTransportUntilCompletion()
        async throws
    {
        let target = xcodeProcessTarget(processID: 121, xcodeVersion: "27.0")
        let stopStarted = TestSignal()
        let stopGate = AsyncGate()
        let session = BlockingStopDocumentationSession(
            serverVersion: "27.0",
            stopStarted: stopStarted,
            stopGate: stopGate
        )
        var transport: SessionBackedDocumentationProviderTransport? =
            SessionBackedDocumentationProviderTransport(
                sessionFactory: FixedDocumentationSessionFactory(session: session)
            )
        let retainedTransport = WeakDocumentationProviderTransportReference(transport)
        do {
            let transport = try #require(transport)
            let route = try await transport.openRoute(
                for: target,
                requestTimeout: .seconds(1),
                initializeParams: [:]
            )

            await transport.close(route: route)
        }
        try await stopStarted.wait(description: "waiting for detached provider session stop")
        transport = nil

        #expect(retainedTransport.value != nil)
        await stopGate.signal()
        try await waitWithTimeout("waiting for detached stop to release provider transport") {
            while retainedTransport.value != nil {
                await Task.yield()
            }
        }
    }

    @Test func sessionBackedDocumentationProviderShutdownWaitsForDetachedSessionStopDrain()
        async throws
    {
        let target = xcodeProcessTarget(processID: 120, xcodeVersion: "27.0")
        let stopStarted = TestSignal()
        let stopGate = AsyncGate()
        let session = BlockingStopDocumentationSession(
            serverVersion: "27.0",
            stopStarted: stopStarted,
            stopGate: stopGate
        )
        let shutdownAwaitingDetachedStops = TestSignal()
        let transport = SessionBackedDocumentationProviderTransport(
            sessionFactory: FixedDocumentationSessionFactory(session: session),
            testHooks: SessionBackedDocumentationProviderTransportTestHooks(
                shutdownWillAwaitDetachedSessionStops: { stopCount in
                    if stopCount == 1 {
                        shutdownAwaitingDetachedStops.signal()
                    }
                }
            )
        )
        let route = try await transport.openRoute(
            for: target,
            requestTimeout: .seconds(1),
            initializeParams: [:]
        )
        let closeFinished = TestSignal()
        let closeTask = Task {
            await transport.close(route: route)
            closeFinished.signal()
        }
        try await stopStarted.wait(description: "waiting for detached provider session stop")
        try await closeFinished.wait(
            description: "documentation provider close should detach session stop"
        )
        await closeTask.value

        let shutdownFinished = TestSignal()
        let shutdownStarted = TestSignal()
        let shutdownTask = Task {
            shutdownStarted.signal()
            await transport.shutdown()
            shutdownFinished.signal()
        }
        try await shutdownStarted.wait(description: "waiting for provider shutdown to start")
        try await shutdownAwaitingDetachedStops.wait(
            description: "waiting for shutdown to await detached provider session stop"
        )

        #expect(shutdownFinished.isSignaled() == false)
        #expect(await session.stopCount() == 1)
        await stopGate.signal()
        try await shutdownFinished.wait(description: "waiting for provider shutdown")
        await shutdownTask.value
    }

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

    @Test func documentationProviderPrefersInstalledAssetWhenConfigured()
        async throws
    {
        let target = xcodeProcessTarget(processID: 117, xcodeVersion: "26.6")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 21,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"xcode\"}")
                    ),
                ],
            ]
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-primary"),
            responseData: try makeDocumentationSearchResponse(
                id: 117,
                text: "{\"answer\":\"asset\"}"
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            localSearchProvider: localProvider,
            documentationSearchActionPolicy: .preferAlways
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 117, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, let invalidatedProvider) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(invalidatedProvider == false)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"asset\"}")
        #expect(await factory.startedPIDs().isEmpty)
        #expect(await localProvider.requestedDescriptorPIDs() == [target.processID])
        #expect(await localProvider.requestedCallPIDs() == [target.processID])
        #expect(await localProvider.requestedQueries() == ["SwiftUI"])

        let update = await manager.toolListUpdate(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))
        #expect(documentationDescriptorDescription(in: result) == "docs-asset-primary")
    }

    @Test func documentationProviderUsesMCPBridgeBeforeInstalledAssetByDefault()
        async throws
    {
        let target = xcodeProcessTarget(processID: 124, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"xcode\"}")
                    ),
                ],
            ]
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-primary"),
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
            requestData: makeDocumentationSearchRequest(id: 124, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, let invalidatedProvider) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(invalidatedProvider == false)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"xcode\"}")
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(await factory.documentationQueries(for: target.processID) == ["SwiftUI"])
        #expect(await localProvider.requestedCallPIDs().isEmpty)
    }

    @Test func documentationProviderPrefersInstalledAssetWhenRunningXcodeIsNewerThanDefault()
        async throws
    {
        let defaultTarget = xcodeProcessTarget(processID: 125, xcodeVersion: "26.6")
        let newerTarget = xcodeProcessTarget(processID: 126, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                defaultTarget.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"default\"}")
                    ),
                ],
                newerTarget.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"newer\"}")
                    ),
                ],
            ]
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-primary"),
            responseData: try makeDocumentationSearchResponse(
                id: 126,
                text: "{\"answer\":\"asset\"}"
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [defaultTarget, newerTarget]),
            sessionFactory: factory,
            localSearchProvider: localProvider,
            documentationSearchActionPolicy: .preferWhenMultipleRunningAndDefaultXcodeIsOlder,
            defaultXcodeTargetResolver: { defaultTarget }
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 126, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, let invalidatedProvider) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(invalidatedProvider == false)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"asset\"}")
        #expect(await localProvider.requestedCallPIDs() == [newerTarget.processID])
        #expect(await factory.startedPIDs().isEmpty)
        #expect(await factory.documentationQueries(for: defaultTarget.processID).isEmpty)
        #expect(await factory.documentationQueries(for: newerTarget.processID).isEmpty)
    }

    @Test func documentationProviderUsesMCPBridgeWhenOnlyRunningXcodeIsNewerThanDefault()
        async throws
    {
        let defaultTarget = xcodeProcessTarget(processID: 127, xcodeVersion: "26.6")
        let newerTarget = xcodeProcessTarget(processID: 128, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                newerTarget.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"mcpbridge\"}")
                    ),
                ],
            ]
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-primary"),
            responseData: try makeDocumentationSearchResponse(
                id: 127,
                text: "{\"answer\":\"asset\"}"
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [newerTarget]),
            sessionFactory: factory,
            localSearchProvider: localProvider,
            documentationSearchActionPolicy: .preferWhenMultipleRunningAndDefaultXcodeIsOlder,
            defaultXcodeTargetResolver: { defaultTarget }
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 127, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, let invalidatedProvider) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(invalidatedProvider == false)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"mcpbridge\"}")
        #expect(await factory.startedPIDs() == [newerTarget.processID])
        #expect(await factory.documentationQueries(for: newerTarget.processID) == ["SwiftUI"])
        #expect(await localProvider.requestedCallPIDs().isEmpty)
    }

    @Test func documentationProviderUsesPrimaryInstalledAssetWithoutRunningXcodeWhenConfigured()
        async throws
    {
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-primary"),
            responseData: try makeDocumentationSearchResponse(
                id: 119,
                text: "{\"answer\":\"asset\"}"
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: []),
            sessionFactory: ScriptedDocumentationSessionFactory(plansByPID: [:]),
            localSearchProvider: localProvider,
            documentationSearchActionPolicy: .preferAlways
        )

        let update = await manager.toolListUpdate(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))
        #expect(documentationDescriptorDescription(in: result) == "docs-asset-primary")

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 119, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, let invalidatedProvider) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(invalidatedProvider == false)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"asset\"}")
        #expect(await localProvider.requestedDescriptorPIDs() == [0, 0])
        #expect(await localProvider.requestedCallPIDs() == [0])
        #expect(await localProvider.requestedQueries() == ["SwiftUI"])
    }

    @Test func documentationProviderToolListUsesNextInstalledAssetRuntimeWhenPrimaryDescriptorUnavailable()
        async throws
    {
        let xcode26 = xcodeProcessTarget(processID: 120, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 121, xcodeVersion: "27.0")
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-primary"),
            responseData: Data(),
            unavailableDescriptorProcessIDs: [xcode27.processID]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: ScriptedDocumentationSessionFactory(plansByPID: [:]),
            localSearchProvider: localProvider,
            documentationSearchActionPolicy: .preferAlways
        )

        let update = await manager.toolListUpdate(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-asset-primary")
        #expect(await localProvider.requestedDescriptorPIDs() == [
            xcode27.processID,
            xcode26.processID,
        ])
    }

    @Test func documentationProviderToolListUsesDefaultActionRuntimeAfterRunningRuntimesUnavailable()
        async throws
    {
        let xcode26 = xcodeProcessTarget(processID: 122, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 123, xcodeVersion: "27.0")
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-primary"),
            responseData: Data(),
            unavailableDescriptorProcessIDs: [xcode26.processID, xcode27.processID]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: ScriptedDocumentationSessionFactory(plansByPID: [:]),
            localSearchProvider: localProvider,
            documentationSearchActionPolicy: .preferAlways
        )

        let update = await manager.toolListUpdate(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-asset-primary")
        #expect(await localProvider.requestedDescriptorPIDs() == [
            xcode27.processID,
            xcode26.processID,
            0,
        ])
    }

    @Test func documentationProviderCallUsesNextInstalledAssetRuntimeWhenPrimaryCallUnavailable()
        async throws
    {
        let xcode26 = xcodeProcessTarget(processID: 124, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 125, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                xcode26.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"xcode26\"}")
                    ),
                ],
                xcode27.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"xcode27\"}")
                    ),
                ],
            ]
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-primary"),
            responseData: try makeDocumentationSearchResponse(
                id: 123,
                text: "{\"answer\":\"asset\"}"
            ),
            failingCallProcessIDs: [xcode27.processID]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory,
            localSearchProvider: localProvider,
            documentationSearchActionPolicy: .preferAlways
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 123, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, let invalidatedProvider) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(invalidatedProvider == false)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"asset\"}")
        #expect(await localProvider.requestedDescriptorPIDs() == [
            xcode27.processID,
            xcode26.processID,
        ])
        #expect(await localProvider.requestedCallPIDs() == [
            xcode27.processID,
            xcode26.processID,
        ])
        #expect(await localProvider.requestedQueries() == ["SwiftUI", "SwiftUI"])
        #expect(await factory.startedPIDs().isEmpty)
        #expect(await factory.documentationQueries(for: xcode27.processID).isEmpty)
        #expect(await factory.documentationQueries(for: xcode26.processID).isEmpty)
    }

    @Test func documentationProviderCallUsesDefaultActionRuntimeAfterRunningRuntimesUnavailable()
        async throws
    {
        let xcode26 = xcodeProcessTarget(processID: 122, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 123, xcodeVersion: "27.0")
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-primary"),
            responseData: try makeDocumentationSearchResponse(
                id: 122,
                text: "{\"answer\":\"asset\"}"
            ),
            failingCallProcessIDs: [xcode26.processID, xcode27.processID]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: ScriptedDocumentationSessionFactory(plansByPID: [:]),
            localSearchProvider: localProvider,
            documentationSearchActionPolicy: .preferAlways
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
        #expect(await localProvider.requestedCallPIDs() == [
            xcode27.processID,
            xcode26.processID,
            0,
        ])
        #expect(await localProvider.requestedQueries() == ["SwiftUI", "SwiftUI", "SwiftUI"])
    }

    @Test func documentationProviderBackgroundDiscoveryUsesPrimaryInstalledAssetWithoutRunningXcodeWhenConfigured()
        async throws
    {
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-primary"),
            responseData: Data()
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: []),
            sessionFactory: ScriptedDocumentationSessionFactory(plansByPID: [:]),
            localSearchProvider: localProvider,
            documentationSearchActionPolicy: .preferAlways
        )

        let update = await manager.startBackgroundDiscovery(requestTimeout: TimeAmount.seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-asset-primary")
        #expect(await localProvider.requestedDescriptorPIDs() == [0])
    }

    @Test func documentationProviderReservesFallbackTimeForPreferredInstalledAsset()
        async throws
    {
        let xcode26 = xcodeProcessTarget(processID: 126, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 127, xcodeVersion: "27.0")
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-primary"),
            responseData: try makeDocumentationSearchResponse(
                id: 127,
                text: "{\"answer\":\"asset\"}"
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: ScriptedDocumentationSessionFactory(plansByPID: [:]),
            localSearchProvider: localProvider,
            documentationSearchActionPolicy: .preferWhenMultipleRunningAndDefaultXcodeIsOlder,
            defaultXcodeTargetResolver: { xcode26 }
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 127, query: "Observation"),
            requestTimeoutOverride: .seconds(5)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"asset\"}")
        let timeout = try #require(await localProvider.requestedCallTimeouts().first)
        #expect((timeout?.nanoseconds ?? 0) <= 2_000_000_000)
        #expect(await localProvider.requestedCallPIDs() == [xcode27.processID])
    }

    @Test func documentationProviderReturnsPrimaryInstalledAssetTimeoutFailure()
        async throws
    {
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-primary"),
            responseData: try makeDocumentationSearchResponse(
                id: 128,
                text: "{\"answer\":\"asset\"}"
            ),
            timeoutOnceAfterSuccessfulCallCount: 0
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: []),
            sessionFactory: ScriptedDocumentationSessionFactory(plansByPID: [:]),
            localSearchProvider: localProvider,
            documentationSearchActionPolicy: .preferAlways
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 128, query: "Observation"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .failed(let error, let invalidatedProvider) = outcome else {
            Issue.record("expected failed timeout outcome, got \(outcome)")
            return
        }
        #expect(error is TimeoutError)
        #expect(invalidatedProvider == false)
        #expect(await localProvider.requestedCallPIDs() == [0])
    }

    @Test func documentationProviderDoesNotFallbackToMCPBridgeWhenPrimaryAssetSearchFails()
        async throws
    {
        let target = xcodeProcessTarget(processID: 118, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"xcode\"}")
                    ),
                ],
            ]
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-primary"),
            responseData: try makeDocumentationSearchResponse(
                id: 118,
                text: "{\"answer\":\"asset\"}"
            ),
            failsCalls: true
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            localSearchProvider: localProvider,
            documentationSearchActionPolicy: .preferAlways
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 118, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .unavailable = outcome else {
            Issue.record("expected unavailable outcome, got \(outcome)")
            return
        }
        #expect(await localProvider.requestedDescriptorPIDs() == [target.processID, 0])
        #expect(await localProvider.requestedCallPIDs() == [target.processID, 0])
        #expect(await localProvider.requestedQueries() == ["SwiftUI", "SwiftUI"])
        #expect(await factory.startedPIDs().isEmpty)
        #expect(await factory.documentationQueries(for: target.processID).isEmpty)
    }

    @Test func xcodeVersionKeyDistinguishesDeveloperDirAndMCPBridgePath() {
        let base = XcodeVersionKey(
            xcodeVersion: "27.0",
            developerDir: "/Applications/Xcode.app/Contents/Developer",
            mcpbridgePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge"
        )
        let differentDeveloperDir = XcodeVersionKey(
            xcodeVersion: "27.0",
            developerDir: "/Applications/Xcode-Beta.app/Contents/Developer",
            mcpbridgePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge"
        )
        let differentMCPBridgePath = XcodeVersionKey(
            xcodeVersion: "27.0",
            developerDir: "/Applications/Xcode.app/Contents/Developer",
            mcpbridgePath: "/Applications/Xcode-Beta.app/Contents/Developer/usr/bin/mcpbridge"
        )

        #expect(base != differentDeveloperDir)
        #expect(base != differentMCPBridgePath)
    }

    @Test func upstreamTopologyResolvesSelectionScopes() {
        let sharedDeveloperDir = "/Applications/Xcode.app/Contents/Developer"
        let sharedMCPBridgePath = "\(sharedDeveloperDir)/usr/bin/mcpbridge"
        let firstSharedVersionTarget = XcodeProcessTarget(
            processID: 700,
            appPath: "/Applications/Xcode.app",
            developerDir: sharedDeveloperDir,
            mcpbridgePath: sharedMCPBridgePath,
            xcodeVersion: "27.0"
        )
        let secondSharedVersionTarget = XcodeProcessTarget(
            processID: 701,
            appPath: "/Applications/Xcode.app",
            developerDir: sharedDeveloperDir,
            mcpbridgePath: sharedMCPBridgePath,
            xcodeVersion: "27.0"
        )
        let otherVersionTarget = xcodeProcessTarget(processID: 702, xcodeVersion: "26.6")
        let topology = UpstreamTopologySnapshot(
            slotIDs: [
                UpstreamSlotID(rawValue: 0),
                UpstreamSlotID(rawValue: 1),
                UpstreamSlotID(rawValue: 2),
                UpstreamSlotID(rawValue: 3),
            ],
            xcodeProcessBindings: [
                XcodeProcessBinding(
                    target: secondSharedVersionTarget,
                    slotIDs: [
                        UpstreamSlotID(rawValue: 2),
                        UpstreamSlotID(rawValue: 1),
                    ]
                ),
                XcodeProcessBinding(
                    target: firstSharedVersionTarget,
                    slotIDs: [
                        UpstreamSlotID(rawValue: 2),
                        UpstreamSlotID(rawValue: 99),
                        UpstreamSlotID(rawValue: 0),
                        UpstreamSlotID(rawValue: 2),
                    ]
                ),
                XcodeProcessBinding(
                    target: otherVersionTarget,
                    slotIDs: [
                        UpstreamSlotID(rawValue: 3),
                    ]
                ),
            ]
        )

        #expect(topology.slotIDs(matching: .any) == [
            UpstreamSlotID(rawValue: 0),
            UpstreamSlotID(rawValue: 1),
            UpstreamSlotID(rawValue: 2),
            UpstreamSlotID(rawValue: 3),
        ])
        #expect(topology.slotIDs(matching: .slots([
            UpstreamSlotID(rawValue: 2),
            UpstreamSlotID(rawValue: 99),
            UpstreamSlotID(rawValue: 2),
            UpstreamSlotID(rawValue: 0),
        ])) == [
            UpstreamSlotID(rawValue: 2),
            UpstreamSlotID(rawValue: 0),
        ])
        #expect(topology.slotIDs(
            matching: .xcodeProcess(XcodeProcessID(rawValue: firstSharedVersionTarget.processID))
        ) == [
            UpstreamSlotID(rawValue: 0),
            UpstreamSlotID(rawValue: 2),
        ])
        #expect(topology.slotIDs(matching: .xcodeVersion(XcodeVersionKey(
            firstSharedVersionTarget
        ))) == [
            UpstreamSlotID(rawValue: 0),
            UpstreamSlotID(rawValue: 1),
            UpstreamSlotID(rawValue: 2),
        ])
    }

    @Test func defaultUpstreamPlanBindsEachSlotToSingleXcodeProcess() throws {
        let target = xcodeProcessTarget(processID: 710, xcodeVersion: "27.0")
        var config = makeConfig(requestTimeout: 5)
        config.upstreamSessionID = "shared-docs-session"
        config.upstreamProcessCount = 2

        let plan = try withEnvironmentVariables(["MCP_XCODE_PID": ""]) {
            MCPBridgeRuntime.makeUpstreamPlan(
                config: makeBridgeRuntimeConfig(config),
                xcodeTargets: [target]
            )
        }

        #expect(plan.upstreams.count == 2)
        #expect(plan.xcodeProcessRoutes.count == 1)
        #expect(plan.xcodeProcessRoutes.first?.target.processID == target.processID)
        #expect(plan.xcodeProcessRoutes.first?.upstreamIndices == [0, 1])
        #expect(plan.topology.slotIDs == [
            UpstreamSlotID(rawValue: 0),
            UpstreamSlotID(rawValue: 1),
        ])
        #expect(plan.topology.xcodeProcessRoutes() == plan.xcodeProcessRoutes)
        let binding = try #require(plan.topology.xcodeProcessBindings.first)
        #expect(binding.processID == XcodeProcessID(rawValue: target.processID))
        #expect(binding.versionKey == XcodeVersionKey(target))
        #expect(binding.slotIDs == [
            UpstreamSlotID(rawValue: 0),
            UpstreamSlotID(rawValue: 1),
        ])
        #expect(plan.topology.binding(forUpstreamIndex: 1)?.processID == binding.processID)
        for upstream in plan.upstreams {
            let environment = try upstreamEnvironment(from: upstream)
            #expect(try upstreamCommand(from: upstream) == target.mcpbridgePath)
            #expect(try upstreamArgs(from: upstream).isEmpty)
            #expect(environment["MCP_XCODE_PID"] == "\(target.processID)")
            #expect(environment["DEVELOPER_DIR"] == target.developerDir)
            #expect(environment["MCP_XCODE_SESSION_ID"] == "shared-docs-session")
        }
    }

    @Test func processBoundSessionFactoryShapesBridgeEnvironment() throws {
        let target = xcodeProcessTarget(processID: 715, xcodeVersion: "27.0")
        var config = makeConfig(requestTimeout: 5)
        config.maxMessageBytes = 2_000_000
        config.upstreamSessionID = "shared-docs-session"

        let factory = MCPBridgeRuntime.makeProcessBoundSessionFactory(
            config: makeBridgeRuntimeConfig(config),
            xcodeTarget: target,
            baseEnvironment: [
                "KEEP": "value",
                "XCODE_PID": "legacy",
                "MCP_XCODE_PID": "inherited-pid",
                "MCP_XCODE_SESSION_ID": "inherited-session",
            ]
        )

        let environment = try upstreamEnvironment(from: factory)
        #expect(try upstreamCommand(from: factory) == target.mcpbridgePath)
        #expect(try upstreamArgs(from: factory).isEmpty)
        #expect(environment["KEEP"] == "value")
        #expect(environment["XCODE_PID"] == nil)
        #expect(environment["MCP_XCODE_PID"] == "\(target.processID)")
        #expect(environment["DEVELOPER_DIR"] == target.developerDir)
        #expect(environment["MCP_XCODE_SESSION_ID"] == "shared-docs-session")
        #expect(try upstreamMaxQueuedWriteBytes(from: factory) == 8_000_000)
    }

    @Test func processBoundSessionFactoryRemovesInheritedSessionIDWithoutSharedSession()
        throws
    {
        let target = xcodeProcessTarget(processID: 716, xcodeVersion: "27.0")
        let config = makeConfig(requestTimeout: 5)

        let factory = MCPBridgeRuntime.makeProcessBoundSessionFactory(
            config: makeBridgeRuntimeConfig(config),
            xcodeTarget: target,
            baseEnvironment: [
                "MCP_XCODE_SESSION_ID": "inherited-session",
            ]
        )

        let environment = try upstreamEnvironment(from: factory)
        #expect(environment["MCP_XCODE_SESSION_ID"] == nil)
        #expect(environment["MCP_XCODE_PID"] == "\(target.processID)")
        #expect(environment["DEVELOPER_DIR"] == target.developerDir)
    }

    @Test func defaultUpstreamPlanScalesWithXcodeProcessCount()
        throws
    {
        let older = xcodeProcessTarget(processID: 720, xcodeVersion: "26.6")
        let newer = xcodeProcessTarget(processID: 721, xcodeVersion: "27.0")
        let config = makeConfig(requestTimeout: 5)

        let plan = try withEnvironmentVariables(["MCP_XCODE_PID": ""]) {
            MCPBridgeRuntime.makeUpstreamPlan(
                config: makeBridgeRuntimeConfig(config),
                xcodeTargets: [older, newer]
            )
        }

        #expect(plan.upstreams.count == 2)
        #expect(plan.xcodeProcessRoutes.map(\.target.processID) == [
            newer.processID,
            older.processID,
        ])
        #expect(plan.xcodeProcessRoutes.map(\.upstreamIndices) == [[0], [1]])
        #expect(plan.topology.xcodeProcessRoutes() == plan.xcodeProcessRoutes)
        #expect(plan.topology.xcodeProcessBindings.map(\.processID) == [
            XcodeProcessID(rawValue: newer.processID),
            XcodeProcessID(rawValue: older.processID),
        ])
        let firstEnvironment = try upstreamEnvironment(from: try #require(plan.upstreams.first))
        let secondEnvironment = try upstreamEnvironment(from: try #require(plan.upstreams.dropFirst().first))
        #expect(firstEnvironment["MCP_XCODE_PID"] == "\(newer.processID)")
        #expect(firstEnvironment["DEVELOPER_DIR"] == newer.developerDir)
        #expect(secondEnvironment["MCP_XCODE_PID"] == "\(older.processID)")
        #expect(secondEnvironment["DEVELOPER_DIR"] == older.developerDir)
    }

    @Test func defaultUpstreamPlanIgnoresInheritedMCPXcodePIDForProcessRouting() throws {
        let pinned = xcodeProcessTarget(processID: 730, xcodeVersion: "26.6")
        let newer = xcodeProcessTarget(processID: 731, xcodeVersion: "27.0")
        var config = makeConfig(requestTimeout: 5)
        config.upstreamProcessCount = 2

        let plan = try withEnvironmentVariables(["MCP_XCODE_PID": "\(pinned.processID)"]) {
            MCPBridgeRuntime.makeUpstreamPlan(
                config: makeBridgeRuntimeConfig(config),
                xcodeTargets: [newer, pinned]
            )
        }

        #expect(plan.upstreams.count == 4)
        #expect(plan.xcodeProcessRoutes.map(\.target.processID) == [
            newer.processID,
            pinned.processID,
        ])
        #expect(plan.xcodeProcessRoutes.map(\.upstreamIndices) == [[0, 1], [2, 3]])
        let environments = try plan.upstreams.map { try upstreamEnvironment(from: $0) }
        #expect(environments[0]["MCP_XCODE_PID"] == "\(newer.processID)")
        #expect(environments[1]["MCP_XCODE_PID"] == "\(newer.processID)")
        #expect(environments[2]["MCP_XCODE_PID"] == "\(pinned.processID)")
        #expect(environments[3]["MCP_XCODE_PID"] == "\(pinned.processID)")
    }

    @Test func runtimeCoordinatorUsesXcodeDiscoveryWhenProcessRoutingIsEnabled()
        throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let target = xcodeProcessTarget(processID: 735, xcodeVersion: "27.0")

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

            #expect(discovery.callCount() == 1)
            #expect(manager.hasDocumentationSearchService() == false)
            #expect(manager.xcodeProcessRoutes.map(\.target.processID) == [target.processID])
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
            #expect(manager.xcodeProcessRoutes.isEmpty)
        }
    }

    @Test func runtimeDocumentationTransportReusesPrewarmedUpstreamRouteForSearch()
        async throws
    {
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 740, xcodeVersion: "27.0")
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let providerManager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            transport: RuntimeDocumentationProviderTransport(runtimeBox: runtimeBox),
            providerSelectionTimeout: .seconds(1)
        )
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            xcodeProcessRoutes: [xcodeProcessRoute(target: target)],
            documentationProviderManager: providerManager,
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
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

    @Test func runtimeDocumentationTransportDoesNotFallbackWhileUpstreamRouteIsInitializing()
        async throws
    {
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 739, xcodeVersion: "27.0")
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let openStarted = TestSignal()
        let openGate = AsyncGate()
        await openGate.signal()
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
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            xcodeProcessRoutes: [xcodeProcessRoute(target: target)],
            documentationProviderManager: providerManager,
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { fixture.shutdownAndWait() }

        let update = await providerManager.startBackgroundDiscovery(requestTimeout: .seconds(1))

        guard case .unavailable = update else {
            Issue.record("expected unavailable update while the upstream route initializes")
            return
        }
        #expect(await fallback.openCount() == 0)
        #expect(await upstream.startCount() == 0)
    }

    @Test func runtimeDocumentationTransportFallsBackForReusedRouteToolsListFailure()
        async throws
    {
        let upstream = ToggleableOverloadUpstreamClient()
        await upstream.overloadNextSend()
        let target = xcodeProcessTarget(processID: 741, xcodeVersion: "27.0")
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
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            xcodeProcessRoutes: [xcodeProcessRoute(target: target)],
            documentationProviderManager: providerManager,
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let discoveryTask = Task {
            await providerManager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        }
        try await openStarted.wait(description: "waiting for fallback open")
        await openGate.signal()

        let update = await discoveryTask.value
        let result = DocumentationProvider.ToolCatalog.applying(
            update,
            to: try jsonValue(["tools": []])
        )

        #expect(documentationDescriptorDescription(in: result) == "docs-fallback")
        #expect(await upstream.sentCount() == 1)
        #expect(await fallback.openCount() == 1)
    }

    @Test func runtimeDocumentationTransportFallsBackWhenReusedUpstreamRouteFails()
        async throws
    {
        let upstream = ToggleableOverloadUpstreamClient()
        await upstream.overloadNextSend()
        let target = xcodeProcessTarget(processID: 742, xcodeVersion: "27.0")
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
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            xcodeProcessRoutes: [xcodeProcessRoute(target: target)],
            documentationProviderManager: providerManager,
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let firstOutcome = try await providerManager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 94, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )
        let firstRuntimeRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: firstRuntimeRequest) == "tools/list")
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

    @Test func runtimeDocumentationTransportCachesInstalledAssetFallbackWithoutOwningBorrowedRoute()
        async throws
    {
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 747, xcodeVersion: "26.6")
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-fallback"),
            responseData: try makeDocumentationSearchResponse(
                id: 147,
                text: "{\"answer\":\"asset\"}"
            )
        )
        let providerManager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            transport: RuntimeDocumentationProviderTransport(runtimeBox: runtimeBox),
            providerSelectionTimeout: .seconds(1),
            localSearchProvider: localProvider
        )
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            xcodeProcessRoutes: [xcodeProcessRoute(target: target)],
            documentationProviderManager: providerManager,
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let firstTask = Task {
            try await providerManager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 147, query: "SwiftUI"),
                requestTimeoutOverride: .seconds(1)
            )
        }
        let runtimeRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: runtimeRequest) == "tools/list")
        let runtimeRequestID = try extractUpstreamID(from: runtimeRequest)
        await yieldMessage(
            try makeDocumentationToolsListResponse(
                id: runtimeRequestID,
                tools: []
            ),
            to: upstream
        )

        let firstOutcome = try await firstTask.value
        guard case .handled(let firstData, let firstInvalidatedProvider) = firstOutcome else {
            Issue.record("expected handled fallback outcome, got \(firstOutcome)")
            return
        }
        #expect(firstInvalidatedProvider == false)
        #expect(try toolContentText(in: firstData) == "{\"answer\":\"asset\"}")
        #expect(await upstream.stopCount() == 0)

        let secondOutcome = try await providerManager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 148, query: "UIKit"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .handled(let secondData, let secondInvalidatedProvider) = secondOutcome else {
            Issue.record("expected cached asset fallback outcome, got \(secondOutcome)")
            return
        }
        #expect(secondInvalidatedProvider == false)
        #expect(try toolContentText(in: secondData) == "{\"answer\":\"asset\"}")
        #expect(await upstream.sentCount() == 1)
        #expect(await upstream.stopCount() == 0)
        #expect(await localProvider.requestedCallPIDs() == [
            target.processID,
            target.processID,
        ])
        #expect(await localProvider.requestedQueries() == ["SwiftUI", "UIKit"])
    }

    @Test func runtimeDocumentationTransportKeepsBorrowedRouteAfterInitialAssetFallbackTimeout()
        async throws
    {
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 748, xcodeVersion: "26.6")
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-fallback"),
            responseData: try makeDocumentationSearchResponse(
                id: 148,
                text: "{\"answer\":\"asset\"}"
            ),
            timeoutOnceAfterSuccessfulCallCount: 0
        )
        let providerManager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            transport: RuntimeDocumentationProviderTransport(runtimeBox: runtimeBox),
            providerSelectionTimeout: .seconds(1),
            localSearchProvider: localProvider
        )
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            xcodeProcessRoutes: [xcodeProcessRoute(target: target)],
            documentationProviderManager: providerManager,
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let timeoutTask = Task {
            try await providerManager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 149, query: "SwiftUI"),
                requestTimeoutOverride: .seconds(1)
            )
        }
        let firstRuntimeRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: firstRuntimeRequest) == "tools/list")
        let firstRuntimeRequestID = try extractUpstreamID(from: firstRuntimeRequest)
        await yieldMessage(
            try makeDocumentationToolsListResponse(
                id: firstRuntimeRequestID,
                tools: []
            ),
            to: upstream
        )
        let timeoutOutcome = try await timeoutTask.value
        guard case .failed(let error, let timeoutInvalidatedProvider) = timeoutOutcome else {
            Issue.record("expected failed timeout outcome, got \(timeoutOutcome)")
            return
        }
        #expect(error is TimeoutError)
        #expect(timeoutInvalidatedProvider == false)
        #expect(await upstream.stopCount() == 0)

        let retryTask = Task {
            try await providerManager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 150, query: "UIKit"),
                requestTimeoutOverride: .seconds(1)
            )
        }
        let retryOutcome = try await retryTask.value
        guard case .handled(let retryData, let retryInvalidatedProvider) = retryOutcome else {
            Issue.record("expected retry fallback outcome, got \(retryOutcome)")
            return
        }
        #expect(retryInvalidatedProvider == false)
        #expect(try toolContentText(in: retryData) == "{\"answer\":\"asset\"}")
        #expect(await upstream.sentCount() == 1)
        #expect(await upstream.stopCount() == 0)
        #expect(await localProvider.requestedCallPIDs() == [
            target.processID,
            target.processID,
        ])
        #expect(await localProvider.requestedQueries() == ["SwiftUI", "UIKit"])
    }

    @Test func runtimeDocumentationTransportUsesInstalledAssetFallbackWhenBorrowedRouteRepairDoesNotRestoreDescriptor()
        async throws
    {
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 749, xcodeVersion: "26.6")
        let runtimeBox = WeakRuntimeCoordinatorBox()
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
                id: 151,
                text: "{\"answer\":\"asset\"}"
            )
        )
        let providerManager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            transport: RuntimeDocumentationProviderTransport(runtimeBox: runtimeBox),
            providerSelectionTimeout: .seconds(1),
            serviceRepairer: repairer,
            localSearchProvider: localProvider
        )
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            xcodeProcessRoutes: [xcodeProcessRoute(target: target)],
            documentationProviderManager: providerManager,
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let prewarmTask = Task {
            await providerManager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        }
        let firstToolsRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        #expect(methodName(from: firstToolsRequest) == "tools/list")
        await yieldMessage(
            try makeDocumentationToolsListResponse(
                id: try extractUpstreamID(from: firstToolsRequest),
                tools: []
            ),
            to: upstream
        )
        let secondToolsRequest = try await sentValue(from: upstream, at: 1, timeout: .seconds(2))
        #expect(methodName(from: secondToolsRequest) == "tools/list")
        await yieldMessage(
            try makeDocumentationToolsListResponse(
                id: try extractUpstreamID(from: secondToolsRequest),
                tools: []
            ),
            to: upstream
        )

        let update = await prewarmTask.value
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))
        #expect(documentationDescriptorDescription(in: result) == "docs-asset-fallback")
        #expect(await repairer.repairedPIDs() == [target.processID])
        #expect(await upstream.sentCount() == 2)
        #expect(await upstream.stopCount() == 0)

        let searchOutcome = try await providerManager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 151, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .handled(let responseData, let invalidatedProvider) = searchOutcome else {
            Issue.record("expected cached asset fallback search, got \(searchOutcome)")
            return
        }
        #expect(invalidatedProvider == false)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"asset\"}")
        #expect(await upstream.sentCount() == 2)
        #expect(await upstream.stopCount() == 0)
        #expect(await localProvider.requestedCallPIDs() == [target.processID])
        #expect(await localProvider.requestedQueries() == ["SwiftUI"])
    }

    @Test func runtimeDocumentationTransportTimesOutQueuedPinnedRouteBeforeDispatch()
        async throws
    {
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 746, xcodeVersion: "27.0")
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let (clock, timeoutClock, uptimeClock) = makeRuntimeCoordinatorDeterministicClocks()
        let providerManager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            transport: RuntimeDocumentationProviderTransport(
                runtimeBox: runtimeBox,
                clock: clock
            ),
            providerSelectionTimeout: .seconds(1),
            clock: clock
        )
        let queuedRequestLabels = LockedRecordedValues<String>()
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            clock: clock,
            xcodeProcessRoutes: [xcodeProcessRoute(target: target)],
            documentationProviderManager: providerManager,
            testHooks: RuntimeCoordinatorTestHooks(
                upstreamRequestQueued: { _, descriptor, queuedRequestCount in
                    if descriptor.label == "tools/list:DocumentationProvider",
                       queuedRequestCount > 0
                    {
                        queuedRequestLabels.append(descriptor.label)
                    }
                }
            ),
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { fixture.shutdownAndWait() }
        let eventLoop = fixture.eventLoop
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)

        let activeDescriptor = SessionRequestPipeline.Descriptor(
            sessionID: "session-active",
            label: "tools/call:LongRunning",
            expectsResponse: true,
            isTopLevelClientRequest: true
        )
        let activeLeaseID = manager.createRequestLease(descriptor: activeDescriptor)
        let activePromise = eventLoop.makePromise(of: Void.self)
        defer { activePromise.fail(CancellationError()) }
        let activeFuture: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
            leaseID: activeLeaseID,
            descriptor: activeDescriptor,
            on: eventLoop,
            preferredUpstreamIndex: 0
        ) { selectedOperationLease in
            manager.activateRequestLease(
                activeLeaseID,
                requestIDKey: nil,
                upstreamIndex: selectedOperationLease.upstreamIndex,
                timeout: nil
            )
            return activePromise.futureResult
        }
        _ = activeFuture
        try await waitWithTimeout(
            "waiting for active lease registration",
            timeout: .seconds(2)
        ) {
            try await eventLoop.submit { () }.get()
        }
        #expect(
            manager.debugSnapshot().leases.contains { lease in
                lease.leaseID == activeLeaseID.uuidString && lease.state == .active
            }
        )

        let outcomeTask = Task {
            try await providerManager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 96, query: "UIView"),
                requestTimeoutOverride: .milliseconds(10)
            )
        }
        try await waitWithTimeout("waiting for queued documentation provider route") {
            try await queuedRequestLabels.nextValue(at: 0)
        }
        try await advanceRuntimeCoordinatorTimeout(
            timeoutClock: timeoutClock,
            uptimeClock: uptimeClock,
            by: .milliseconds(10)
        )
        let outcome = try await waitWithTimeout(
            "documentation search should honor caller timeout while upstream slot is busy",
            timeout: .milliseconds(500)
        ) {
            try await outcomeTask.value
        }

        guard case .failed(let error, _) = outcome else {
            Issue.record("expected timed-out outcome, got \(outcome)")
            return
        }
        #expect(error is TimeoutError)
        #expect(await upstream.sentCount() == 0)
        #expect(manager.debugSnapshot().queuedRequestCount == 0)
    }

    @Test func runtimeDocumentationTransportClosesFallbackOpenedAfterRouteInvalidation()
        async throws
    {
        let upstream = ToggleableOverloadUpstreamClient()
        await upstream.overloadNextSend()
        let target = xcodeProcessTarget(processID: 743, xcodeVersion: "27.0")
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
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            xcodeProcessRoutes: [xcodeProcessRoute(target: target)],
            documentationProviderManager: providerManager,
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
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
            let outcome = try await waitWithTimeout(
                "waiting for invalidated documentation search",
                timeout: .seconds(2)
            ) {
                try await searchTask.value
            }
            guard case .unavailable = outcome else {
                Issue.record("expected unavailable outcome for invalidated search, got \(outcome)")
                return
            }
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError for invalidated search, got \(error)")
        }
        #expect(await fallback.closeCount() == 1)
    }

    @Test func documentationProviderManagerClosesRouteOpenedAfterPreparationCancellation()
        async throws
    {
        let target = xcodeProcessTarget(processID: 744, xcodeVersion: "27.0")
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
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 745, xcodeVersion: "27.0")
        let runtimeBox = WeakRuntimeCoordinatorBox()
        let route = DocumentationProviderRoute(
            id: "upstream-0-pid-\(target.processID)",
            target: target,
            upstreamIndex: 0
        )
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 30),
            upstreams: [upstream],
            xcodeProcessRoutes: [xcodeProcessRoute(target: target)],
            startImmediately: false,
            runtimeBox: runtimeBox
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
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
        let toolsListSnapshot = manager.debugSnapshot()
        #expect(toolsListSnapshot.queuedRequestCount == 0)
        #expect(toolsListSnapshot.upstreams[0].activeCorrelatedRequestCount == 0)

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
        let searchSnapshot = manager.debugSnapshot()
        #expect(searchSnapshot.queuedRequestCount == 0)
        #expect(searchSnapshot.upstreams[0].activeCorrelatedRequestCount == 0)
    }

    @Test func runtimeDocumentationTransportFallsBackToDirectCandidateWhenNoUpstreamRouteExists()
        async throws
    {
        let newer = xcodeProcessTarget(processID: 750, xcodeVersion: "27.0")
        let older = xcodeProcessTarget(processID: 751, xcodeVersion: "26.6")
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

    @Test func documentationProviderIgnoresPriorityDiscoveryOrderWhenNewerXcodeIsAvailable()
        async throws
    {
        let workspaceOwner = xcodeProcessTarget(processID: 752, xcodeVersion: "26.6")
        let documentationProvider = xcodeProcessTarget(processID: 753, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                workspaceOwner.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"owner\"}")
                    ),
                ],
                documentationProvider.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"provider\"}")
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [workspaceOwner, documentationProvider]),
            sessionFactory: factory
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 94, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"provider\"}")
        #expect(await factory.startedPIDs() == [documentationProvider.processID])
        #expect(await factory.documentationQueries(for: workspaceOwner.processID).isEmpty)
        #expect(await factory.documentationQueries(for: documentationProvider.processID) == ["UIView"])
        #expect(await factory.stoppedPIDs().isEmpty)
    }

    @Test func documentationProviderUsesStableSameVersionOrderInsteadOfRuntimeOwnerOrder()
        async throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let ownerTarget = XcodeProcessTarget(
            processID: 761,
            appPath: "/Applications/Xcode-Z.app",
            developerDir: "/Applications/Xcode-Z.app/Contents/Developer",
            mcpbridgePath: "/Applications/Xcode-Z.app/Contents/Developer/usr/bin/mcpbridge",
            xcodeVersion: "27.0"
        )
        let stableTarget = XcodeProcessTarget(
            processID: 762,
            appPath: "/Applications/Xcode-A.app",
            developerDir: "/Applications/Xcode-A.app/Contents/Developer",
            mcpbridgePath: "/Applications/Xcode-A.app/Contents/Developer/usr/bin/mcpbridge",
            xcodeVersion: "27.0"
        )
        let runtime = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 5),
            eventLoop: eventLoop,
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: ownerTarget, upstreamIndices: [0]),
                XcodeProcessRoute(target: stableTarget, upstreamIndices: [1]),
            ],
            startImmediately: false
        )
        defer { runtime.shutdownAndWait() }
        runtime.markUpstreamInitialized(upstreamIndex: 0)
        runtime.markUpstreamInitialized(upstreamIndex: 1)
        #expect(
            runtime.recordXcodeWindowOwners(
                from: try jsonValue([
                    "structuredContent": [
                        "message": "* tabIdentifier: tab-owner, workspacePath: /tmp/Owner.xcworkspace",
                    ],
                ]),
                upstreamIndex: 0
            )
        )
        let runtimeBox = WeakRuntimeCoordinatorBox()
        runtimeBox.value = runtime
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                ownerTarget.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"owner\"}")
                    ),
                ],
                stableTarget.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"stable\"}")
                    ),
                ],
            ]
        )
        let discovery = RuntimeDocumentationTargetDiscovery(
            base: StubXcodeTargetDiscovery(targets: [ownerTarget, stableTarget]),
            runtimeBox: runtimeBox
        )
        #expect(discovery.runningXcodeTargets().map(\.processID) == [
            ownerTarget.processID,
            stableTarget.processID,
        ])
        let manager = DocumentationProviderManager(
            discovery: discovery,
            sessionFactory: factory
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 98, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"stable\"}")
        #expect(await factory.startedPIDs() == [stableTarget.processID])
        #expect(await factory.documentationQueries(for: ownerTarget.processID).isEmpty)
        #expect(await factory.documentationQueries(for: stableTarget.processID) == ["SwiftUI"])
    }

    @Test func documentationProviderUsesNewestAssetFallbackBeforeOlderCandidateWhenRouteUnavailable()
        async throws
    {
        let older = xcodeProcessTarget(processID: 754, xcodeVersion: "26.6")
        let newest = xcodeProcessTarget(processID: 755, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
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
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-newest"),
            responseData: try makeDocumentationSearchResponse(
                id: 95,
                text: "{\"answer\":\"asset-newest\"}"
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [older, newest]),
            sessionFactory: factory,
            localSearchProvider: localProvider
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 95, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"asset-newest\"}")
        #expect(await factory.startAttempts() == [newest.processID])
        #expect(await factory.startedPIDs().isEmpty)
        #expect(await factory.documentationQueries(for: older.processID).isEmpty)
        #expect(await localProvider.requestedDescriptorPIDs() == [newest.processID])
        #expect(await localProvider.requestedCallPIDs() == [newest.processID])
        #expect(await localProvider.requestedQueries() == ["SwiftUI"])
    }

    @Test func documentationProviderUsesNewestAssetFallbackBeforeOlderCandidateWhenCallFails()
        async throws
    {
        let older = xcodeProcessTarget(processID: 756, xcodeVersion: "26.6")
        let newest = xcodeProcessTarget(processID: 757, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                older.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"older\"}")
                    ),
                ],
                newest.processID: [
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
            descriptor: documentationDescriptor(version: "asset-newest"),
            responseData: try makeDocumentationSearchResponse(
                id: 96,
                text: "{\"answer\":\"asset-newest\"}"
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [older, newest]),
            sessionFactory: factory,
            localSearchProvider: localProvider
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 96, query: "SwiftData"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"asset-newest\"}")
        #expect(await factory.startedPIDs() == [newest.processID])
        #expect(await factory.documentationQueries(for: newest.processID) == ["SwiftData"])
        #expect(await factory.documentationQueries(for: older.processID).isEmpty)
        #expect(await localProvider.requestedCallPIDs() == [newest.processID])
        #expect(await localProvider.requestedQueries() == ["SwiftData"])
    }

    @Test func documentationProviderUsesNewestAssetFallbackBeforeOlderCandidateWhenTransportThrows()
        async throws
    {
        let older = xcodeProcessTarget(processID: 760, xcodeVersion: "26.6")
        let newest = xcodeProcessTarget(processID: 761, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                older.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"older\"}")
                    ),
                ],
                newest.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .exit
                    ),
                ],
            ]
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-newest"),
            responseData: try makeDocumentationSearchResponse(
                id: 98,
                text: "{\"answer\":\"asset-newest\"}"
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [older, newest]),
            sessionFactory: factory,
            localSearchProvider: localProvider
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 98, query: "ModelActor"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, let invalidatedProvider) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(invalidatedProvider)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"asset-newest\"}")
        #expect(await factory.startedPIDs() == [newest.processID])
        #expect(await factory.documentationQueries(for: newest.processID) == ["ModelActor"])
        #expect(await factory.documentationQueries(for: older.processID).isEmpty)
        #expect(await localProvider.requestedCallPIDs() == [newest.processID])
        #expect(await localProvider.requestedQueries() == ["ModelActor"])
    }

    @Test func documentationProviderUsesNewestAssetFallbackBeforeOlderCandidateWhenDescriptorMissing()
        async throws
    {
        let older = xcodeProcessTarget(processID: 758, xcodeVersion: "26.6")
        let newest = xcodeProcessTarget(processID: 759, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                older.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"older\"}")
                    ),
                ],
                newest.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: false,
                        firstDocumentationResponse: .successText("{\"answer\":\"unused\"}")
                    ),
                ],
            ]
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-newest"),
            responseData: try makeDocumentationSearchResponse(
                id: 97,
                text: "{\"answer\":\"asset-newest\"}"
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [older, newest]),
            sessionFactory: factory,
            localSearchProvider: localProvider
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 97, query: "Observation"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"asset-newest\"}")
        #expect(await factory.startedPIDs() == [newest.processID])
        #expect(await factory.documentationQueries(for: newest.processID).isEmpty)
        #expect(await factory.documentationQueries(for: older.processID).isEmpty)
        #expect(await localProvider.requestedDescriptorPIDs() == [newest.processID])
        #expect(await localProvider.requestedCallPIDs() == [newest.processID])
        #expect(await localProvider.requestedQueries() == ["Observation"])
    }

    @Test func sharedToolsListAdvertisesProxyOwnedDocumentationSearchDescriptor() async throws {
        let upstream = TestUpstreamClient()
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0"))
        )
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            documentationProviderManager: documentationProvider
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        manager.seedCanonicalToolsCatalog(
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
        #expect(
            documentationDescriptorDescription(in: result)
                == "Search Apple developer documentation."
        )
        #expect(await documentationProvider.toolListUpdateCount() == 0)
    }

    @Test func sharedToolsListDoesNotWaitForStartupDocumentationPrewarm() async throws {
        let upstream = TestUpstreamClient()
        let prewarmStarted = TestSignal()
        let prewarmGate = AsyncGate()
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0")),
            prewarmStarted: prewarmStarted,
            prewarmBlocker: prewarmGate
        )
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            documentationProviderManager: documentationProvider,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.seedCanonicalToolsCatalog(
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
            "tools/list should not wait for documentation provider prewarm"
        ) {
            try await manager.sharedToolsList(
                sessionID: "session-docs-tools-prewarm",
                requestTimeoutOverride: .seconds(1)
            )
        }
        #expect(await documentationProvider.toolListUpdateCount() == 0)

        #expect(toolNames(in: result) == ["XcodeRead", "DocumentationSearch"])
        #expect(
            documentationDescriptorDescription(in: result)
                == "Search Apple developer documentation."
        )
        #expect(await documentationProvider.prewarmCount() == 0)

        await prewarmGate.signal()
        try await waitWithTimeout("waiting for documentation prewarm to finish") {
            try await documentationProvider.waitForPrewarmCount(1)
        }
    }

    @Test func sharedToolsListSurfaceDoesNotDependOnProviderInvalidation() async throws {
        let upstream = TestUpstreamClient()
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0"))
        )
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            documentationProviderManager: documentationProvider,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.seedCanonicalToolsCatalog(
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
        try await waitWithTimeout("waiting for documentation prewarm") {
            try await documentationProvider.waitForPrewarmCount(1)
        }

        let prewarmedResult = try await manager.sharedToolsList(
            sessionID: "session-docs-tools-prewarm-once",
            requestTimeoutOverride: .seconds(1)
        )
        #expect(toolNames(in: prewarmedResult) == ["XcodeRead", "DocumentationSearch"])
        #expect(
            documentationDescriptorDescription(in: prewarmedResult)
                == "Search Apple developer documentation."
        )

        await documentationProvider.invalidate(reason: "test")
        let refreshedResult = try await manager.sharedToolsList(
            sessionID: "session-docs-tools-after-prewarm",
            requestTimeoutOverride: .seconds(1)
        )

        #expect(toolNames(in: refreshedResult) == ["XcodeRead", "DocumentationSearch"])
        #expect(
            documentationDescriptorDescription(in: refreshedResult)
                == "Search Apple developer documentation."
        )
        #expect(await documentationProvider.toolListUpdateCount() == 0)
    }

    @Test func sharedToolsListReplacesStaleDocumentationSearchWhenProviderUnavailable() async throws {
        let upstream = TestUpstreamClient()
        let documentationProvider = StubDocumentationProviderManager(toolListUpdate: .unavailable)
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            documentationProviderManager: documentationProvider
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        manager.seedCanonicalToolsCatalog(
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

        #expect(toolNames(in: result) == ["DocumentationSearch", "XcodeRead"])
        #expect(
            documentationDescriptorDescription(in: result)
                == "Search Apple developer documentation."
        )
        #expect(manager.cachedToolsListResult() != nil)
        #expect(await documentationProvider.toolListUpdateCount() == 0)
    }

    @Test func sharedToolsListDoesNotProbeDocumentationProvider() async throws {
        let upstream = TestUpstreamClient()
        let toolListGate = AsyncGate()
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0")),
            toolListBlocker: toolListGate
        )
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            documentationProviderManager: documentationProvider
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        manager.seedCanonicalToolsCatalog(
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

        let result = try await waitWithTimeout(
            "tools/list should not call the documentation provider"
        ) {
            try await manager.sharedToolsList(
                sessionID: "session-docs-timeout",
                requestTimeoutOverride: .milliseconds(1)
            )
        }

        #expect(toolNames(in: result) == ["DocumentationSearch", "XcodeRead"])
        #expect(
            documentationDescriptorDescription(in: result)
                == "Search Apple developer documentation."
        )
        #expect(manager.cachedToolsListResult() != nil)
        #expect(await documentationProvider.recordedInvalidateReasons().isEmpty)
        #expect(await documentationProvider.toolListUpdateCount() == 0)
        await toolListGate.signal()
    }

    @Test func documentationSearchKeepsCanonicalToolsCatalogWhenProviderRecoversAfterInvalidation() async throws {
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
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            documentationProviderManager: documentationProvider
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        manager.seedCanonicalToolsCatalog(
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
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            documentationProviderManager: documentationProvider
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        let cachedTools = try jsonValue([
            "tools": [
                documentationDescriptor(version: "27.0").foundationObject,
            ],
        ])
        manager.seedCanonicalToolsCatalog(cachedTools, sourceUpstream: 0)

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
        let upstream = TestUpstreamClient()
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0")),
            callOutcomes: [.unavailable(.noAvailableProvider)]
        )
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            documentationProviderManager: documentationProvider
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager

        manager.seedCanonicalToolsCatalog(
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
        let upstream = TestUpstreamClient()
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0"))
        )
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 300),
            upstreams: [upstream],
            documentationProviderManager: documentationProvider,
            prewarmDocumentationProviderOnStartup: true
        )
        defer { fixture.shutdownAndWait() }

        try await waitWithTimeout("waiting for documentation provider startup prewarm") {
            try await documentationProvider.waitForPrewarmCount(1)
        }

        let observedTimeout = try #require(await documentationProvider.lastPrewarmTimeout())
        #expect(observedTimeout.nanoseconds == TimeAmount.seconds(10).nanoseconds)
        #expect(await documentationProvider.toolListUpdateCount() == 0)
    }

    @Test func processRoutingDefersStartupDocumentationPrewarmUntilUpstreamIsInitialized()
        async throws
    {
        let upstream = TestUpstreamClient()
        let target = xcodeProcessTarget(processID: 752, xcodeVersion: "27.0")
        let documentationProvider = StubDocumentationProviderManager(
            toolListUpdate: .available(documentationDescriptor(version: "27.0"))
        )
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 300),
            upstreams: [upstream],
            xcodeProcessRoutes: [xcodeProcessRoute(target: target)],
            documentationProviderManager: documentationProvider,
            prewarmDocumentationProviderOnStartup: true
        )
        defer { fixture.shutdownAndWait() }

        #expect(fixture.manager.documentationProviderDiscoveryState.withLockedValue { state in
            state.task == nil && state.retryTimeout == nil
        })
        #expect(await documentationProvider.prewarmCount() == 0)

        try await fixture.completeInitialize(on: upstream)

        try await waitWithTimeout("waiting for initialized-route documentation prewarm") {
            try await documentationProvider.waitForPrewarmCount(1)
        }
        #expect(await documentationProvider.prewarmCount() == 1)
    }

    @Test func unavailableDocumentationProviderRetriesWithoutProcessRescan() async throws {
        let upstream = TestUpstreamClient()
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let documentationProvider = StubDocumentationProviderManager(toolListUpdate: .unavailable)
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 300),
            upstreams: [upstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            documentationProviderManager: documentationProvider,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }

        fixture.manager.prewarmDocumentationProvider()
        try await waitWithTimeout("waiting for documentation provider retry") {
            while fixture.manager.documentationProviderDiscoveryState.withLockedValue({ state in
                state.task != nil || state.retryTimeout == nil
            }) {
                await Task.yield()
            }
        }

        #expect(timeoutScheduler.scheduledCount() == 1)
        #expect(
            timeoutScheduler.delay(at: 0)?.nanoseconds
                == TimeAmount.seconds(2).nanoseconds
        )

        await documentationProvider.setToolListUpdate(
            .available(documentationDescriptor(version: "27.0"))
        )
        #expect(timeoutScheduler.fire(at: 0))
        try await waitWithTimeout("waiting for documentation provider retry recovery") {
            while fixture.manager.documentationProviderDiscoveryState.withLockedValue({ state in
                state.task != nil || state.retryTimeout != nil
            }) {
                await Task.yield()
            }
        }

        #expect(await documentationProvider.prewarmCount() == 2)
        #expect(timeoutScheduler.scheduledCount() == 1)
    }

    @Test func staleDocumentationProviderRetryCannotReplaceNewerSuccess() async throws {
        let upstream = TestUpstreamClient()
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let documentationProvider = StubDocumentationProviderManager(toolListUpdate: .unavailable)
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            documentationProviderManager: documentationProvider,
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }

        fixture.manager.prewarmDocumentationProvider()
        try await waitWithTimeout("waiting for stale documentation provider retry") {
            while fixture.manager.documentationProviderDiscoveryState.withLockedValue({ state in
                state.task != nil || state.retryTimeout == nil
            }) {
                await Task.yield()
            }
        }

        await documentationProvider.setToolListUpdate(
            .available(documentationDescriptor(version: "27.0"))
        )
        fixture.manager.prewarmDocumentationProvider()
        try await waitWithTimeout("waiting for newer documentation provider success") {
            while fixture.manager.documentationProviderDiscoveryState.withLockedValue({ state in
                state.task != nil || state.retryTimeout != nil
            }) {
                await Task.yield()
            }
        }

        #expect(timeoutScheduler.isCancelled(at: 0))
        #expect(timeoutScheduler.fireIgnoringCancellation(at: 0))
        #expect(await documentationProvider.prewarmCount() == 2)
        #expect(timeoutScheduler.scheduledCount() == 1)
        #expect(fixture.manager.documentationProviderDiscoveryState.withLockedValue { state in
            state.task == nil && state.retryTimeout == nil
        })
    }

    @Test func shutdownRejectsDeliveredDocumentationProviderRetry() async throws {
        let upstream = TestUpstreamClient()
        let timeoutScheduler = RecordingRuntimeTimeoutScheduler()
        let documentationProvider = StubDocumentationProviderManager(toolListUpdate: .unavailable)
        let fixture = RuntimeCoordinatorFixture(
            upstreams: [upstream],
            scheduleRuntimeTimeout: timeoutScheduler.scheduler(),
            documentationProviderManager: documentationProvider,
            startImmediately: false
        )

        fixture.manager.prewarmDocumentationProvider()
        try await waitWithTimeout("waiting for documentation provider retry before shutdown") {
            while fixture.manager.documentationProviderDiscoveryState.withLockedValue({ state in
                state.task != nil || state.retryTimeout == nil
            }) {
                await Task.yield()
            }
        }

        await fixture.manager.shutdown()

        #expect(timeoutScheduler.isCancelled(at: 0))
        #expect(timeoutScheduler.fireIgnoringCancellation(at: 0))
        #expect(await documentationProvider.prewarmCount() == 1)
        #expect(timeoutScheduler.scheduledCount() == 1)
        #expect(fixture.manager.documentationProviderDiscoveryState.withLockedValue { state in
            state.isClosed && state.task == nil && state.retryTimeout == nil
        })
    }

    @Test func xcodeInventoryChangePrewarmsUnavailableDocumentationProviderAgain() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownAndWait(group) }
        let upstream = TestUpstreamClient()
        let documentationProvider = StubDocumentationProviderManager(toolListUpdate: .unavailable)
        let processEventMonitor = StubDocumentationProcessEventMonitor()
        let target = xcodeProcessTarget(processID: 753, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 300),
            eventLoop: group.next(),
            upstreams: [upstream],
            xcodeProcessRoutes: [xcodeProcessRoute(target: target)],
            processRoutingEnabled: true,
            xcodeProcessEventMonitor: processEventMonitor,
            documentationProviderManager: documentationProvider,
            prewarmDocumentationProviderOnStartup: true
        )
        defer { manager.shutdownAndWait() }

        #expect(manager.documentationProviderDiscoveryState.withLockedValue { state in
            state.task == nil && state.retryTimeout == nil
        })
        #expect(await documentationProvider.prewarmCount() == 0)

        let initializeRequest = try await sentValue(from: upstream, at: 0, timeout: .seconds(2))
        let initializeRequestID = try extractUpstreamID(from: initializeRequest)
        await yieldMessage(
            try makeInitializeResponse(id: initializeRequestID),
            to: upstream
        )
        try await waitWithTimeout("waiting for initialized-route documentation prewarm") {
            try await documentationProvider.waitForPrewarmCount(1)
        }
        await documentationProvider.setToolListUpdate(
            .available(documentationDescriptor(version: "27.0"))
        )
        processEventMonitor.emitInventoryChange()
        try await waitWithTimeout("waiting for inventory-change documentation prewarm") {
            try await documentationProvider.waitForPrewarmCount(2)
        }

        let observedTimeout = try #require(await documentationProvider.lastPrewarmTimeout())
        #expect(observedTimeout.nanoseconds == TimeAmount.seconds(10).nanoseconds)
        #expect(await documentationProvider.toolListUpdateCount() == 0)
    }

    @Test func upstreamInitializationPrewarmsUnavailableDocumentationProviderAgain() async throws {
        let upstream = TestUpstreamClient()
        let documentationProvider = StubDocumentationProviderManager(toolListUpdate: .unavailable)
        let fixture = RuntimeCoordinatorFixture(
            config: makeConfig(requestTimeout: 300),
            upstreams: [upstream],
            documentationProviderManager: documentationProvider,
            prewarmDocumentationProviderOnStartup: true
        )
        defer { fixture.shutdownAndWait() }

        try await waitWithTimeout("waiting for initial documentation provider prewarm") {
            try await documentationProvider.waitForPrewarmCount(1)
        }
        await documentationProvider.setToolListUpdate(
            .available(documentationDescriptor(version: "27.0"))
        )

        fixture.manager.noteUpstreamInitializationSucceeded()

        try await waitWithTimeout("waiting for initialized-upstream documentation prewarm") {
            try await documentationProvider.waitForPrewarmCount(2)
        }
        let observedTimeout = try #require(await documentationProvider.lastPrewarmTimeout())
        #expect(observedTimeout.nanoseconds == TimeAmount.seconds(10).nanoseconds)
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

    @Test func documentationProviderToolListUpdateStartsDiscoveryWithoutSearch() async throws {
        let target = xcodeProcessTarget(processID: 101, xcodeVersion: "27.0")
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

        guard case .available = update else {
            Issue.record("expected available update, got \(update)")
            return
        }
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/list") == 1)
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 0)
    }

    @Test func documentationProviderBackgroundDiscoveryFetchesDescriptorWithoutSearch() async throws {
        let target = xcodeProcessTarget(processID: 111, xcodeVersion: "27.0")
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
        let target = xcodeProcessTarget(processID: 116, xcodeVersion: "27.0")
        let transport = TransientUnavailableDescriptorTransport()
        let (clock, timeoutClock, uptimeClock) = makeRuntimeCoordinatorDeterministicClocks()
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            transport: transport,
            clock: clock
        )

        let updateTask = Task {
            await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        }
        try await waitWithTimeout("waiting for first transient descriptor refresh") {
            try await transport.waitForToolsListCount(1)
        }
        try await advanceRuntimeCoordinatorTimeout(
            timeoutClock: timeoutClock,
            uptimeClock: uptimeClock,
            by: .milliseconds(250)
        )
        let update = try await waitWithTimeout("waiting for descriptor refresh retry") {
            await updateTask.value
        }
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))

        #expect(documentationDescriptorDescription(in: result) == "docs-transient")
        #expect(await transport.toolsListCount() == 2)
    }

    @Test func documentationProviderBackgroundDiscoveryRepairsDescriptorMissingService()
        async throws
    {
        let target = xcodeProcessTarget(processID: 117, xcodeVersion: "26.6")
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
        let target = xcodeProcessTarget(processID: 118, xcodeVersion: "26.6")
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

    @Test func repairedDocumentationProviderDoesNotCloseReusedRuntimeRoute()
        async throws
    {
        let target = xcodeProcessTarget(processID: 123, xcodeVersion: "26.6")
        let transport = ReusedRouteRepairTransport()
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
            transport: transport,
            serviceRepairer: repairer
        )

        let update = await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))
        #expect(documentationDescriptorDescription(in: result) == "docs-reused")

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 123, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"reused\"}")
        #expect(await repairer.repairedPIDs() == [target.processID])
        #expect(await transport.openCount() == 2)
        #expect(await transport.toolsListCount() == 2)
        #expect(await transport.closedRoutes().isEmpty)
    }

    @Test func documentationProviderRepairDoesNotWaitPastRequestTimeout()
        async throws
    {
        let target = xcodeProcessTarget(processID: 120, xcodeVersion: "26.6")
        let repairGate = OperationGate<pid_t>()
        let (clock, timeoutClock, uptimeClock) = makeRuntimeCoordinatorDeterministicClocks()
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
            ),
            gate: repairGate
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            serviceRepairer: repairer,
            clock: clock
        )

        let updateTask = Task {
            await manager.startBackgroundDiscovery(requestTimeout: .milliseconds(20))
        }
        try await waitWithTimeout("waiting for documentation repair to suspend") {
            try await repairGate.waitUntilWaiting(for: target.processID, count: 1)
        }
        try await advanceRuntimeCoordinatorTimeout(
            timeoutClock: timeoutClock,
            uptimeClock: uptimeClock,
            by: .milliseconds(20)
        )
        let update = try await waitWithTimeout(
            "documentation repair should not exceed the caller timeout",
            timeout: .milliseconds(500)
        ) {
            await updateTask.value
        }
        if case .available = update {
            Issue.record("expected repair timeout to avoid advertising DocumentationSearch")
        }
        #expect(await repairer.repairedPIDs() == [target.processID])
        _ = try await waitWithTimeout("waiting for repair cancellation") {
            try await repairer.nextCancelledPID(at: 0)
        }
        #expect(await repairer.cancelledPIDs() == [target.processID])
        #expect(await factory.startedPIDs() == [target.processID])
    }

    @Test func documentationProviderUsesInstalledAssetFallbackWhenRepairDoesNotRestoreDescriptor()
        async throws
    {
        let target = xcodeProcessTarget(processID: 119, xcodeVersion: "26.6")
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
        try await waitWithTimeout("waiting for unrepaired documentation provider stops") {
            try await factory.waitForStopCount(2)
        }
        #expect(await factory.stoppedPIDs() == [target.processID, target.processID])
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

    @Test func documentationProviderUsesSameTargetAssetFallbackWhenRepairReopenIsUnavailable()
        async throws
    {
        let older = xcodeProcessTarget(processID: 120, xcodeVersion: "26.6")
        let newest = xcodeProcessTarget(processID: 121, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                older.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 20,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"older\"}")
                    ),
                ],
                newest.processID: [
                    .init(
                        serverVersion: "27.0",
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
                    xcodeVersion: "27.0",
                    osVersion: "26.2",
                    documentationRelease: 900340,
                    changedDefault: true
                )
            )
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-fallback"),
            responseData: try makeDocumentationSearchResponse(
                id: 121,
                text: "{\"answer\":\"asset-newest\"}"
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [older, newest]),
            sessionFactory: factory,
            serviceRepairer: repairer,
            localSearchProvider: localProvider
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 121, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"asset-newest\"}")
        #expect(await repairer.repairedPIDs() == [newest.processID])
        #expect(await factory.startAttempts() == [newest.processID, newest.processID])
        #expect(await factory.startedPIDs() == [newest.processID])
        #expect(await factory.documentationQueries(for: older.processID).isEmpty)
        #expect(await localProvider.requestedDescriptorPIDs() == [newest.processID])
        #expect(await localProvider.requestedCallPIDs() == [newest.processID])
        #expect(await localProvider.requestedQueries() == ["SwiftUI"])
    }

    @Test func documentationProviderRejectsRepairedRouteWhenDescriptorIsStillMissing()
        async throws
    {
        let target = xcodeProcessTarget(processID: 122, xcodeVersion: "26.6")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 20,
                        includesDocumentationSearch: false,
                        firstDocumentationResponse: .successText("{\"answer\":\"first\"}")
                    ),
                    .init(
                        serverVersion: "26.6",
                        toolCount: 20,
                        includesDocumentationSearch: false,
                        firstDocumentationResponse: .successText("{\"answer\":\"second\"}")
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

        let firstOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 122, query: "First"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .unavailable = firstOutcome else {
            Issue.record("expected unavailable outcome, got \(firstOutcome)")
            return
        }

        _ = await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))

        let secondOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 123, query: "Second"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .unavailable = secondOutcome else {
            Issue.record("expected second unavailable outcome, got \(secondOutcome)")
            return
        }
        #expect(await repairer.repairedPIDs() == [target.processID])
        #expect(await factory.startedPIDs() == [target.processID, target.processID])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/list") == 2)
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 0)
        #expect(await factory.documentationQueries(for: target.processID).isEmpty)
    }

    @Test func backgroundDiscoveryRejectsRepairedRouteWhenDescriptorIsStillMissing()
        async throws
    {
        let target = xcodeProcessTarget(processID: 125, xcodeVersion: "26.6")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 20,
                        includesDocumentationSearch: false,
                        firstDocumentationResponse: .successText("{\"answer\":\"closed\"}")
                    ),
                    .init(
                        serverVersion: "26.6",
                        toolCount: 20,
                        includesDocumentationSearch: false,
                        firstDocumentationResponse: .successText("{\"answer\":\"reopened\"}")
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
        #expect(update.debugLabel == "unavailable")

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 125, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .unavailable = outcome else {
            Issue.record("expected unavailable outcome, got \(outcome)")
            return
        }
        #expect(await repairer.repairedPIDs() == [target.processID])
        #expect(await factory.startedPIDs() == [target.processID, target.processID])
        try await waitWithTimeout("waiting for rejected documentation provider stop") {
            try await factory.waitForStopCount(2)
        }
        #expect(await factory.stoppedPIDs() == [target.processID, target.processID])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/list") == 2)
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 0)
        #expect(await factory.documentationQueries(for: target.processID).isEmpty)
    }

    @Test func documentationProviderFallsBackToInstalledAssetWhenXcodeReturnsNotEnabled()
        async throws
    {
        let target = xcodeProcessTarget(processID: 121, xcodeVersion: "26.6")
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

        let firstOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 122, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let firstData, let firstInvalidatedProvider) = firstOutcome else {
            Issue.record("expected handled outcome, got \(firstOutcome)")
            return
        }
        #expect(firstInvalidatedProvider)
        #expect(try toolContentText(in: firstData) == "{\"answer\":\"asset\"}")

        let secondOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 123, query: "UIKit"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let secondData, let secondInvalidatedProvider) = secondOutcome else {
            Issue.record("expected second handled outcome, got \(secondOutcome)")
            return
        }
        #expect(secondInvalidatedProvider == false)
        #expect(try toolContentText(in: secondData) == "{\"answer\":\"asset\"}")
        #expect(await localProvider.requestedCallPIDs() == [target.processID, target.processID])
        #expect(await localProvider.requestedQueries() == ["SwiftUI", "UIKit"])
        #expect(await factory.documentationQueries(for: target.processID) == ["SwiftUI"])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 1)
    }

    @Test func documentationProviderInvalidatesCachedAssetFallbackWhenLocalSearchFails()
        async throws
    {
        let target = xcodeProcessTarget(processID: 126, xcodeVersion: "26.6")
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
                id: 126,
                text: "{\"answer\":\"asset\"}"
            ),
            failAfterSuccessfulCallCount: 1
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            localSearchProvider: localProvider
        )

        let firstOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 126, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .handled(let firstData, let firstInvalidatedProvider) = firstOutcome else {
            Issue.record("expected first handled outcome, got \(firstOutcome)")
            return
        }
        #expect(firstInvalidatedProvider)
        #expect(try toolContentText(in: firstData) == "{\"answer\":\"asset\"}")

        let secondOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 127, query: "UIKit"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .unavailable(let reason) = secondOutcome else {
            Issue.record("expected unavailable outcome, got \(secondOutcome)")
            return
        }
        #expect(reason.message == DocumentationProvider.UnavailableReason.userFacingMessage)

        let update = await manager.toolListUpdate(requestTimeout: .seconds(1))
        let result = DocumentationProvider.ToolCatalog.applying(
            update,
            to: try jsonValue([
                "tools": [
                    documentationDescriptor(version: "asset-fallback").foundationObject,
                    [
                        "name": "XcodeRead",
                        "description": "read",
                    ],
                ],
            ])
        )

        #expect(toolNames(in: result) == ["XcodeRead"])
        #expect(DocumentationProvider.ToolCatalog.descriptor(in: result) == nil)
        #expect(await localProvider.requestedCallPIDs() == [target.processID, target.processID])
        #expect(await localProvider.requestedQueries() == ["SwiftUI", "UIKit"])
        #expect(await factory.documentationQueries(for: target.processID) == ["SwiftUI"])
    }

    @Test func documentationProviderKeepsCachedAssetFallbackAfterRequestTimeout()
        async throws
    {
        let target = xcodeProcessTarget(processID: 128, xcodeVersion: "26.6")
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
                id: 128,
                text: "{\"answer\":\"asset\"}"
            ),
            timeoutOnceAfterSuccessfulCallCount: 1
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            localSearchProvider: localProvider
        )

        let firstOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 128, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .handled(let firstData, let firstInvalidatedProvider) = firstOutcome else {
            Issue.record("expected first handled outcome, got \(firstOutcome)")
            return
        }
        #expect(firstInvalidatedProvider)
        #expect(try toolContentText(in: firstData) == "{\"answer\":\"asset\"}")

        let timeoutOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 129, query: "UIKit"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .failed(let error, let timeoutInvalidatedProvider) = timeoutOutcome else {
            Issue.record("expected failed timeout outcome, got \(timeoutOutcome)")
            return
        }
        #expect(error is TimeoutError)
        #expect(timeoutInvalidatedProvider == false)

        let retryOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 130, query: "AppKit"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .handled(let retryData, let retryInvalidatedProvider) = retryOutcome else {
            Issue.record("expected retry handled outcome, got \(retryOutcome)")
            return
        }
        #expect(retryInvalidatedProvider == false)
        #expect(try toolContentText(in: retryData) == "{\"answer\":\"asset\"}")
        #expect(await localProvider.requestedCallPIDs() == [
            target.processID,
            target.processID,
            target.processID,
        ])
        #expect(await localProvider.requestedQueries() == ["SwiftUI", "UIKit", "AppKit"])
        #expect(await factory.documentationQueries(for: target.processID) == ["SwiftUI"])
    }

    @Test func documentationProviderKeepsLiveProviderAfterInitialAssetFallbackRequestTimeout()
        async throws
    {
        let target = xcodeProcessTarget(processID: 129, xcodeVersion: "26.6")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 21,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .notEnabled,
                        userCallResponses: [.notEnabled]
                    ),
                ],
            ]
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-fallback"),
            responseData: try makeDocumentationSearchResponse(
                id: 131,
                text: "{\"answer\":\"asset\"}"
            ),
            timeoutOnceAfterSuccessfulCallCount: 0
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            localSearchProvider: localProvider
        )

        let timeoutOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 131, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .failed(let error, let timeoutInvalidatedProvider) = timeoutOutcome else {
            Issue.record("expected failed timeout outcome, got \(timeoutOutcome)")
            return
        }
        #expect(error is TimeoutError)
        #expect(timeoutInvalidatedProvider == false)
        #expect(await factory.stoppedPIDs().isEmpty)

        let retryOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 132, query: "UIKit"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .handled(let retryData, let retryInvalidatedProvider) = retryOutcome else {
            Issue.record("expected retry handled outcome, got \(retryOutcome)")
            return
        }
        #expect(retryInvalidatedProvider)
        #expect(try toolContentText(in: retryData) == "{\"answer\":\"asset\"}")
        #expect(await localProvider.requestedCallPIDs() == [target.processID, target.processID])
        #expect(await localProvider.requestedQueries() == ["SwiftUI", "UIKit"])
        #expect(await factory.documentationQueries(for: target.processID) == ["SwiftUI", "UIKit"])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 2)
        try await waitWithTimeout("waiting for invalidated documentation provider stop") {
            try await factory.waitForStopCount(1)
        }
        #expect(await factory.stoppedPIDs() == [target.processID])
    }

    @Test func documentationProviderTriesNextCandidateAfterInitialAssetFallbackTimeout()
        async throws
    {
        let newer = xcodeProcessTarget(processID: 130, xcodeVersion: "26.6")
        let older = xcodeProcessTarget(processID: 131, xcodeVersion: "26.5")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                newer.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 21,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .notEnabled
                    ),
                ],
                older.processID: [
                    .init(
                        serverVersion: "26.5",
                        toolCount: 21,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"older\"}")
                    ),
                ],
            ]
        )
        let localProvider = StubDocumentationSearchProvider(
            descriptor: documentationDescriptor(version: "asset-fallback"),
            responseData: try makeDocumentationSearchResponse(
                id: 133,
                text: "{\"answer\":\"asset\"}"
            ),
            timeoutOnceAfterSuccessfulCallCount: 0
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [newer, older]),
            sessionFactory: factory,
            localSearchProvider: localProvider
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 133, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, let invalidatedProvider) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(invalidatedProvider == false)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"older\"}")
        #expect(await localProvider.requestedCallPIDs() == [newer.processID])
        #expect(await localProvider.requestedQueries() == ["SwiftUI"])
        #expect(await factory.documentationQueries(for: newer.processID) == ["SwiftUI"])
        #expect(await factory.documentationQueries(for: older.processID) == ["SwiftUI"])
        try await waitWithTimeout("waiting for failed newest documentation provider stop") {
            try await factory.waitForStopCount(1)
        }
        #expect(await factory.stoppedPIDs() == [newer.processID])
    }

    @Test func documentationProviderFallsBackToInstalledAssetWhenXcodeConfigIsBroken()
        async throws
    {
        let target = xcodeProcessTarget(processID: 124, xcodeVersion: "26.6")
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

        let firstOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 124, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let firstData, let firstInvalidatedProvider) = firstOutcome else {
            Issue.record("expected handled outcome, got \(firstOutcome)")
            return
        }
        #expect(firstInvalidatedProvider)
        #expect(try toolContentText(in: firstData) == "{\"answer\":\"asset\"}")

        let secondOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 125, query: "SwiftData"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let secondData, let secondInvalidatedProvider) = secondOutcome else {
            Issue.record("expected second handled outcome, got \(secondOutcome)")
            return
        }
        #expect(secondInvalidatedProvider == false)
        #expect(try toolContentText(in: secondData) == "{\"answer\":\"asset\"}")
        #expect(await localProvider.requestedCallPIDs() == [target.processID, target.processID])
        #expect(await localProvider.requestedQueries() == ["UIView", "SwiftData"])
        #expect(await factory.documentationQueries(for: target.processID) == ["UIView"])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 1)
    }

    @Test func documentationAssetLocatorTreatsTrailingZeroXcodeVersionsAsExactMatch()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-26",
            xcodeVersion: "26",
            osVersion: "26.0",
            documentationRelease: 900100
        )
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-26-0-0",
            xcodeVersion: "26.0.0",
            osVersion: "26.0",
            documentationRelease: 900200
        )
        let scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: root)

        let asset = try #require(
            DocumentationSearchAssetLocator.bestAsset(
                for: "26.0",
                currentOSVersion: "26.0",
                from: scan.assets
            )
        )

        #expect(asset.xcodeVersion == "26.0.0")
        #expect(asset.documentationRelease == 900200)
    }

    @Test func documentationAssetLocatorSelectsLatestInstalledAsset()
        throws
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
            documentationRelease: 999999
        )
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-27-old-release",
            xcodeVersion: "27.0",
            osVersion: "27.0",
            documentationRelease: 950000
        )
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-27-new-release",
            xcodeVersion: "27.0",
            osVersion: "27.0",
            documentationRelease: 950001
        )
        let scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: root)

        let asset = try #require(DocumentationSearchAssetLocator.latestAsset(from: scan.assets))

        #expect(asset.xcodeVersion == "27.0")
        #expect(asset.documentationRelease == 950001)
        #expect(asset.assetURL.path.contains("xcode-27-new-release.asset"))
    }

    @Test func documentationSearchActionProviderReturnsHelperOutput()
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
        try makeInstalledDocumentationAsset(
            root: root,
            name: "xcode-27",
            xcodeVersion: "27.0",
            osVersion: "27.0",
            documentationRelease: 950001
        )
        let recorder = DocumentationSearchActionInvocationRecorder()
        let target = xcodeProcessTarget(processID: 123, xcodeVersion: "26.6")
        let provider = DocumentationSearchActionProvider(
            assetRoot: root,
            invoker: StubDocumentationSearchActionInvoker(
                output: DocumentationSearchActionOutput(documents: [
                    .init(
                        title: "UIView",
                        contents: "UIView\nClass of UIKit",
                        uri: "/documentation/UIKit/UIView",
                        score: 0.92,
                        kind: "symbol"
                    ),
                ]),
                recorder: recorder
            )
        )

        #expect(await provider.descriptor(for: target) != nil)
        let response = try await provider.callDocumentationSearch(
            requestData: makeDocumentationSearchRequestWithArguments(
                id: 123,
                query: " UIView ",
                frameworks: ["UIKit"],
                limit: 2
            ),
            for: target,
            timeout: .seconds(1)
        )

        let maybeText = try toolContentText(in: response)
        let text = try #require(maybeText)
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8), options: []) as? [String: Any]
        )
        let responseObject = try #require(
            JSONSerialization.jsonObject(with: response, options: []) as? [String: Any]
        )
        let result = try #require(responseObject["result"] as? [String: Any])
        let structuredContent = try #require(result["structuredContent"] as? [String: Any])
        #expect(JSONValue(any: structuredContent) == JSONValue(any: payload))

        #expect(Set(payload.keys) == ["documents"])
        let documents = try #require(payload["documents"] as? [[String: Any]])
        let firstDocument = try #require(documents.first)
        let firstTitle = firstDocument["title"] as? String
        #expect(firstTitle == "UIView")
        #expect(Set(firstDocument.keys) == ["contents", "kind", "score", "title", "uri"])
        #expect(firstDocument["kind"] as? String == "symbol")
        #expect(firstDocument["contents"] as? String == "UIView\nClass of UIKit")
        #expect(firstDocument["uri"] as? String == "/documentation/UIKit/UIView")
        #expect(firstDocument["score"] as? Double == 0.92)

        let invocation = try #require(await recorder.recordedValues().first)
        #expect(invocation.target == target)
        #expect(invocation.asset.xcodeVersion == "27.0")
        #expect(invocation.asset.documentationRelease == 950001)
        #expect(invocation.query == "UIView")
        #expect(invocation.frameworks == ["UIKit"])
        #expect(invocation.limit == 2)
    }

    @Test func documentationSearchActionInvokerPassesLatestAssetWithActionDefaults()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-action-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assetRoot = root.appendingPathComponent("assets", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let xcodeRoot = root.appendingPathComponent("xcode", isDirectory: true)
        try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: assetRoot,
            name: "xcode-26-5",
            xcodeVersion: "26.5",
            osVersion: "26.2",
            documentationRelease: 900339
        )
        try makeInstalledDocumentationAsset(
            root: assetRoot,
            name: "xcode-27",
            xcodeVersion: "27.0",
            osVersion: "26.2",
            documentationRelease: 950001
        )
        let target = try makeFakeXcodeApp(root: xcodeRoot)
        let scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: assetRoot)
        let asset = try #require(DocumentationSearchAssetLocator.latestAsset(from: scan.assets))
        let processRunner = DocumentationSearchActionProcessRecorder()
        let invoker = LiveDocumentationSearchActionInvoker(
            cacheRoot: cacheRoot,
            processRunner: processRunner
        )

        _ = try await invoker.invoke(
            DocumentationSearchActionInvocation(
                target: target,
                asset: asset,
                query: "NavigationSplitView",
                frameworks: ["SwiftUI"],
                limit: nil
            ),
            timeout: .seconds(1)
        )
        _ = try await invoker.invoke(
            DocumentationSearchActionInvocation(
                target: target,
                asset: asset,
                query: "NavigationSplitView",
                frameworks: ["SwiftUI"],
                limit: nil
            ),
            timeout: .seconds(1)
        )

        let requests = await processRunner.recordedRequests()
        let binPathRequests = requests.filter { $0.label == "DocumentationSearchAction.bin-path" }
        #expect(binPathRequests.count == 1)
        let binPathRequest = try #require(binPathRequests.first)
        #expect(binPathRequest.arguments.contains("--show-bin-path"))
        #expect(binPathRequest.arguments.contains("DEVELOPER_DIR=\(target.developerDir)"))
        let buildRequests = requests.filter { $0.label == "DocumentationSearchAction.build" }
        #expect(buildRequests.count == 1)
        let buildRequest = try #require(buildRequests.first)
        #expect(buildRequest.arguments.contains("DEVELOPER_DIR=\(target.developerDir)"))
        #expect(buildRequest.arguments.contains(
            URL(fileURLWithPath: target.appPath)
                .appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
                .path
        ))
        #expect(buildRequest.arguments.contains("build"))
        #expect(processArgumentValue(after: "--configuration", in: buildRequest.arguments) == "release")
        #expect(
            processArgumentValue(after: "--product", in: buildRequest.arguments)
                == "documentation-search-action-helper"
        )
        #expect(processArgumentValue(after: "--sdk", in: buildRequest.arguments) == "/tmp/MacOSX.sdk")
        let packagePath = try #require(processArgumentValue(after: "--package-path", in: buildRequest.arguments))
        #expect(processArgumentValue(after: "--package-path", in: binPathRequest.arguments) == packagePath)
        let packageRoot = URL(fileURLWithPath: packagePath, isDirectory: true)
        #expect(packageRoot.deletingLastPathComponent().path == cacheRoot.path)
        #expect(packageRoot.lastPathComponent.hasPrefix("runtime-"))
        #expect(packageRoot.lastPathComponent.contains("-sources-"))
        #expect(
            processArgumentValue(after: "--scratch-path", in: buildRequest.arguments)
                == packageRoot.appendingPathComponent(".build", isDirectory: true).path
        )
        let manifest = try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(manifest.contains("documentation-search-action-helper"))
        #expect(FileManager.default.fileExists(
            atPath: packageRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("DocumentationSearchActionHelper", isDirectory: true)
                .appendingPathComponent("main.swift")
                .path
        ))

        let helperRequest = try #require(
            requests.last { $0.label == "DocumentationSearchAction" }
        )
        let input = try #require(helperRequest.input)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(input.utf8), options: []) as? [String: Any]
        )
        #expect(object["query"] as? String == "NavigationSplitView")
        #expect(object["frameworks"] as? [String] == ["SwiftUI"])
        #expect(object["configURL"] as? String == asset.configURL.path)
        #expect(object["maxResults"] as? Int == 20)
        #expect(object["scoreThreshold"] as? Double == 0.4)

        let oneSecond = Int64(1_000_000_000)
        let sdkRequest = try #require(requests.first { $0.label == "DocumentationSearchAction.sdk" })
        let sdkTimeout = try #require(sdkRequest.timeoutNanoseconds)
        #expect(sdkTimeout > 0 && sdkTimeout <= oneSecond)
        let binPathTimeout = try #require(binPathRequest.timeoutNanoseconds)
        let buildTimeout = try #require(buildRequest.timeoutNanoseconds)
        #expect(binPathTimeout > oneSecond)
        #expect(buildTimeout > oneSecond)
        #expect(buildTimeout <= binPathTimeout)
        let helperTimeout = try #require(helperRequest.timeoutNanoseconds)
        #expect(helperTimeout > 0 && helperTimeout <= oneSecond)
    }

    @Test func documentationSearchActionInvokerCoalescesConcurrentHelperPreparation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-action-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assetRoot = root.appendingPathComponent("assets", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let xcodeRoot = root.appendingPathComponent("xcode", isDirectory: true)
        try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: assetRoot,
            name: "xcode-27",
            xcodeVersion: "27.0",
            osVersion: "26.2",
            documentationRelease: 950001
        )
        let target = try makeFakeXcodeApp(root: xcodeRoot)
        let scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: assetRoot)
        let asset = try #require(DocumentationSearchAssetLocator.latestAsset(from: scan.assets))
        let buildStarted = TestSignal()
        let releaseBuild = TestSignal()
        let processRunner = BlockingDocumentationSearchActionProcessRunner(
            buildStarted: buildStarted,
            releaseBuild: releaseBuild
        )
        let invoker = LiveDocumentationSearchActionInvoker(
            cacheRoot: cacheRoot,
            processRunner: processRunner
        )
        let invocation = DocumentationSearchActionInvocation(
            target: target,
            asset: asset,
            query: "NavigationSplitView",
            frameworks: ["SwiftUI"],
            limit: nil
        )

        let first = Task {
            try await invoker.invoke(invocation, timeout: .seconds(5))
        }
        defer {
            releaseBuild.signal()
            first.cancel()
        }
        try await buildStarted.wait(description: "waiting for first DocumentationSearchAction helper build")

        let second = Task {
            try await invoker.invoke(invocation, timeout: .seconds(5))
        }
        defer {
            second.cancel()
        }
        try await waitWithTimeout("waiting for second DocumentationSearchAction sdk lookup") {
            while await processRunner.recordedRequests().filter({ $0.label == "DocumentationSearchAction.sdk" }).count < 2 {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        releaseBuild.signal()
        _ = try await first.value
        _ = try await second.value

        let requests = await processRunner.recordedRequests()
        #expect(requests.filter { $0.label == "DocumentationSearchAction.bin-path" }.count == 1)
        #expect(requests.filter { $0.label == "DocumentationSearchAction.build" }.count == 1)
        #expect(requests.filter { $0.label == "DocumentationSearchAction" }.count == 2)
    }

    @Test func documentationSearchActionInvokerKeepsSharedHelperPreparationAfterShortWaiterTimeout()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-action-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assetRoot = root.appendingPathComponent("assets", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let xcodeRoot = root.appendingPathComponent("xcode", isDirectory: true)
        try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: assetRoot,
            name: "xcode-27",
            xcodeVersion: "27.0",
            osVersion: "26.2",
            documentationRelease: 950001
        )
        let target = try makeFakeXcodeApp(root: xcodeRoot)
        let scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: assetRoot)
        let asset = try #require(DocumentationSearchAssetLocator.latestAsset(from: scan.assets))
        let buildStarted = TestSignal()
        let releaseBuild = TestSignal()
        let processRunner = BlockingDocumentationSearchActionProcessRunner(
            buildStarted: buildStarted,
            releaseBuild: releaseBuild
        )
        let invoker = LiveDocumentationSearchActionInvoker(
            cacheRoot: cacheRoot,
            processRunner: processRunner
        )
        let invocation = DocumentationSearchActionInvocation(
            target: target,
            asset: asset,
            query: "NavigationSplitView",
            frameworks: ["SwiftUI"],
            limit: nil
        )

        let shortWaiter = Task {
            try await invoker.invoke(invocation, timeout: .milliseconds(50))
        }
        defer {
            releaseBuild.signal()
            shortWaiter.cancel()
        }
        try await buildStarted.wait(description: "waiting for DocumentationSearchAction helper build")
        await #expect(throws: TimeoutError.self) {
            try await shortWaiter.value
        }

        let longWaiter = Task {
            try await invoker.invoke(invocation, timeout: .seconds(5))
        }
        defer {
            longWaiter.cancel()
        }
        try await waitWithTimeout("waiting for second DocumentationSearchAction sdk lookup") {
            while await processRunner.recordedRequests().filter({ $0.label == "DocumentationSearchAction.sdk" }).count < 2 {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        releaseBuild.signal()
        _ = try await longWaiter.value

        let requests = await processRunner.recordedRequests()
        #expect(requests.filter { $0.label == "DocumentationSearchAction.bin-path" }.count == 1)
        let buildRequests = requests.filter { $0.label == "DocumentationSearchAction.build" }
        #expect(buildRequests.count == 1)
        let buildRequest = try #require(buildRequests.first)
        let buildTimeout = try #require(buildRequest.timeoutNanoseconds)
        #expect(buildTimeout > 1_000_000_000)
        #expect(requests.filter { $0.label == "DocumentationSearchAction" }.count == 1)
    }

    @Test func documentationSearchActionInvokerMapsProcessTimeoutToRequestTimeout()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-action-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assetRoot = root.appendingPathComponent("assets", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let xcodeRoot = root.appendingPathComponent("xcode", isDirectory: true)
        try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: assetRoot,
            name: "xcode-27",
            xcodeVersion: "27.0",
            osVersion: "26.2",
            documentationRelease: 950001
        )
        let target = try makeFakeXcodeApp(root: xcodeRoot)
        let scan = try DocumentationSearchAssetLocator.scanInstalledAssets(in: assetRoot)
        let asset = try #require(DocumentationSearchAssetLocator.latestAsset(from: scan.assets))
        let invoker = LiveDocumentationSearchActionInvoker(
            cacheRoot: cacheRoot,
            processRunner: DocumentationSearchActionTimeoutProcessRunner()
        )

        await #expect(throws: TimeoutError.self) {
            try await invoker.invoke(
                DocumentationSearchActionInvocation(
                    target: target,
                    asset: asset,
                    query: "NavigationSplitView",
                    frameworks: ["SwiftUI"],
                    limit: nil
                ),
                timeout: .seconds(1)
            )
        }
    }

    @Test func documentationSearchActionProviderUsesStandaloneResolverOnlyWithoutRunningXcode()
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
        let recorder = DocumentationSearchActionInvocationRecorder()
        let resolvedTarget = xcodeProcessTarget(processID: 777, xcodeVersion: "27.0")
        let provider = DocumentationSearchActionProvider(
            assetRoot: root,
            invoker: StubDocumentationSearchActionInvoker(
                output: DocumentationSearchActionOutput(documents: []),
                recorder: recorder
            ),
            defaultTargetResolver: { resolvedTarget }
        )

        #expect(await provider.descriptor(for: DocumentationSearchActionProvider.standaloneTarget) != nil)
        let response = try await provider.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 126, query: "UIView"),
            for: DocumentationSearchActionProvider.standaloneTarget,
            timeout: .seconds(1)
        )

        #expect(try responseID(in: response) == 126)
        let invocation = try #require(await recorder.recordedValues().first)
        #expect(invocation.target == resolvedTarget)
    }

    @Test func documentationSearchActionProviderIsUnavailableWithoutAssetOrInvoker()
        async throws
    {
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let target = xcodeProcessTarget(processID: 125, xcodeVersion: "26.6")
        let noAssetProvider = DocumentationSearchActionProvider(
            assetRoot: emptyRoot,
            invoker: StubDocumentationSearchActionInvoker(
                output: DocumentationSearchActionOutput(documents: [])
            )
        )
        #expect(await noAssetProvider.descriptor(for: target) == nil)

        let assetRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-doc-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: assetRoot) }
        try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
        try makeInstalledDocumentationAsset(
            root: assetRoot,
            name: "xcode-26-5",
            xcodeVersion: "26.5",
            osVersion: "26.2",
            documentationRelease: 900339
        )
        let unavailableInvokerProvider = DocumentationSearchActionProvider(
            assetRoot: assetRoot,
            invoker: StubDocumentationSearchActionInvoker(
                available: false,
                output: DocumentationSearchActionOutput(documents: [])
            )
        )

        #expect(await unavailableInvokerProvider.descriptor(for: target) == nil)
    }

    @Test func documentationSearchActionProviderHonorsSearchTimeout()
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
        let provider = DocumentationSearchActionProvider(
            assetRoot: root,
            invoker: StubDocumentationSearchActionInvoker(
                output: DocumentationSearchActionOutput(documents: [
                    .init(
                        title: "UIView",
                        contents: "UIView",
                        uri: "/documentation/UIKit/UIView",
                        score: 0.92,
                        kind: "symbol"
                    ),
                ])
            )
        )
        let target = xcodeProcessTarget(processID: 125, xcodeVersion: "26.6")

        await #expect(throws: TimeoutError.self) {
            try await provider.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 125, query: "UIView"),
                for: target,
                timeout: .nanoseconds(0)
            )
        }
    }

    @Test func documentationProviderBackgroundDiscoveryRemovesStaleDescriptorWhenAbsent()
        async throws
    {
        let target = xcodeProcessTarget(processID: 115, xcodeVersion: "27.0")
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

    @Test func documentationProviderBackgroundDiscoveryRetriesDescriptorMissOnLaterPoll()
        async throws
    {
        let target = xcodeProcessTarget(processID: 115, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 46,
                        includesDocumentationSearch: false,
                        firstDocumentationResponse: .success
                    ),
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

        let firstUpdate = await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        let firstResult = DocumentationProvider.ToolCatalog.applying(
            firstUpdate,
            to: try jsonValue([
                "tools": [
                    documentationDescriptor(version: "stale").foundationObject,
                ],
            ])
        )
        let secondUpdate = await manager.startBackgroundDiscovery(requestTimeout: .seconds(1))
        let secondResult = DocumentationProvider.ToolCatalog.applying(
            secondUpdate,
            to: try jsonValue(["tools": []])
        )

        #expect(DocumentationProvider.ToolCatalog.descriptor(in: firstResult) == nil)
        #expect(documentationDescriptorDescription(in: secondResult) == "docs-27.0")
        #expect(await factory.startedPIDs() == [target.processID, target.processID])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/list") == 2)
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 0)
    }

    @Test func documentationSearchDoesNotCallCandidateWhileDescriptorFetchIsHanging() async throws {
        let target = xcodeProcessTarget(processID: 114, xcodeVersion: "27.0")
        let clocks = makeRuntimeCoordinatorDeterministicClocks()
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
            sessionFactory: factory,
            clock: clocks.clock
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

        let outcomeTask = Task {
            try await manager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 70, query: "UIView"),
                requestTimeoutOverride: .seconds(1)
            )
        }
        try await advanceRuntimeCoordinatorTimeout(
            timeoutClock: clocks.timeoutClock,
            uptimeClock: clocks.uptimeClock,
            by: .seconds(1),
            suspendedSleepers: 2
        )
        let outcome = try await outcomeTask.value

        guard case .failed(let error, _) = outcome, error is TimeoutError else {
            Issue.record("expected timeout outcome, got \(outcome)")
            return
        }
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 0)
        #expect(await factory.documentationQueries(for: target.processID).isEmpty)

        discoveryTask.cancel()
        _ = await discoveryTask.value
    }

    @Test func documentationProviderManagerUsesNumericIDsForMCPBridgeStartup() async throws {
        let target = xcodeProcessTarget(processID: 112, xcodeVersion: "27.0")
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
        let target = xcodeProcessTarget(processID: 113, xcodeVersion: "27.0")
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
        let xcode26 = xcodeProcessTarget(processID: 399, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 401, xcodeVersion: "27.0")
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
        let first = xcodeProcessTarget(processID: 501, xcodeVersion: "27.0")
        let second = xcodeProcessTarget(processID: 502, xcodeVersion: "27.0")
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
        let target = xcodeProcessTarget(processID: 601, xcodeVersion: "27.0")
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
        let target = xcodeProcessTarget(processID: 602, xcodeVersion: "27.0")
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
        let target = xcodeProcessTarget(processID: 603, xcodeVersion: "27.0")
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
        let xcode26 = xcodeProcessTarget(processID: 605, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 606, xcodeVersion: "27.0")
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
        #expect(documentationDescriptorDescription(in: activeResult) == "docs-27.0")
        #expect(await factory.startedPIDs() == [xcode26.processID, xcode27.processID])
    }

    @Test func documentationProviderManagerSearchesDescriptorMissingPreparedTarget() async throws {
        let xcode26 = xcodeProcessTarget(processID: 610, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 611, xcodeVersion: "27.0")
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
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"advertised\"}")
        #expect(await factory.startedPIDs() == [xcode27.processID, xcode26.processID])
        #expect(await factory.requestCount(processID: xcode27.processID, method: "tools/list") == 1)
        #expect(await factory.requestCount(processID: xcode26.processID, method: "tools/list") == 1)
        #expect(await factory.documentationQueries(for: xcode27.processID).isEmpty)
        #expect(await factory.documentationQueries(for: xcode26.processID) == ["SwiftUI"])
    }

    @Test func documentationProviderManagerRetriesDescriptorMissOnLaterCall() async throws {
        let target = xcodeProcessTarget(processID: 612, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 46,
                        includesDocumentationSearch: false,
                        firstDocumentationResponse: .success
                    ),
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"recovered\"}")
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory
        )

        let firstOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 85, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .unavailable(let reason) = firstOutcome else {
            Issue.record("expected unavailable outcome, got \(firstOutcome)")
            return
        }

        let secondOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 86, query: "Observation"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .handled(let responseData, _) = secondOutcome else {
            Issue.record("expected handled outcome, got \(secondOutcome)")
            return
        }

        #expect(reason.message == DocumentationProvider.UnavailableReason.userFacingMessage)
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"recovered\"}")
        #expect(await factory.startedPIDs() == [target.processID, target.processID])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/list") == 2)
        #expect(await factory.documentationQueries(for: target.processID) == ["Observation"])
    }

    @Test func documentationProviderManagerRetriesActualRequestWhenNewestIsNotEnabled() async throws {
        let xcode26 = xcodeProcessTarget(processID: 420, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 421, xcodeVersion: "27.0")
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
        let xcode26 = xcodeProcessTarget(processID: 422, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 423, xcodeVersion: "27.0")
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

    @Test func documentationProviderManagerRetriesProviderFailureOnNextCandidate()
        async throws
    {
        let xcode26 = xcodeProcessTarget(processID: 424, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 427, xcodeVersion: "27.0")
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
                        firstDocumentationResponse: .toolErrorText(
                            "The file “config.json” couldn’t be opened because there is no such file."
                        )
                    ),
                ],
            ]
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [xcode26, xcode27]),
            sessionFactory: factory
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 77, query: "UIView"),
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
        let xcode26 = xcodeProcessTarget(processID: 425, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 426, xcodeVersion: "27.0")
        let (clock, timeoutClock, uptimeClock) = makeRuntimeCoordinatorDeterministicClocks()
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
            sessionFactory: factory,
            clock: clock
        )

        let outcomeTask = Task {
            try await manager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 88, query: "UIView"),
                requestTimeoutOverride: .milliseconds(200)
            )
        }
        try await waitWithTimeout("waiting for newest candidate documentation search") {
            try await factory.waitForRequestCount(
                1,
                processID: xcode27.processID,
                method: "tools/call"
            )
        }
        try await advanceRuntimeCoordinatorTimeout(
            timeoutClock: timeoutClock,
            uptimeClock: uptimeClock,
            by: .milliseconds(100)
        )
        let outcome = try await waitWithTimeout("waiting for fallback candidate response") {
            try await outcomeTask.value
        }

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
        let xcode26 = xcodeProcessTarget(processID: 430, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 431, xcodeVersion: "27.0")
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
        let xcode26 = xcodeProcessTarget(processID: 440, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 441, xcodeVersion: "27.0")
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
        let xcode26 = xcodeProcessTarget(processID: 450, xcodeVersion: "26.6")
        let xcode27 = xcodeProcessTarget(processID: 451, xcodeVersion: "27.0")
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
        let firstStartAttempts = await factory.startAttempts()

        let followUpTools = DocumentationProvider.ToolCatalog.applying(
            await manager.toolListUpdate(requestTimeout: .seconds(1)),
            to: try jsonValue([
                "tools": [
                    documentationDescriptor(version: "stale").foundationObject,
                ],
            ])
        )
        #expect(DocumentationProvider.ToolCatalog.descriptor(in: followUpTools) == nil)

        let secondOutcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 81, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(1)
        )
        guard case .unavailable(let secondReason) = secondOutcome else {
            Issue.record("expected second unavailable outcome, got \(secondOutcome)")
            return
        }
        #expect(secondReason.message == DocumentationProvider.UnavailableReason.userFacingMessage)
        #expect(await factory.startAttempts() == firstStartAttempts)
        #expect(await factory.documentationQueries(for: xcode27.processID) == ["UIView"])
        #expect(await factory.documentationQueries(for: xcode26.processID) == ["UIView"])
    }

    @Test func documentationProviderManagerDoesNotUseInheritedProcessPin() async throws {
        let older = xcodeProcessTarget(processID: 460, xcodeVersion: "26.6")
        let other = xcodeProcessTarget(processID: 461, xcodeVersion: "27.0")
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                older.processID: [
                    .init(
                        serverVersion: "26.6",
                        toolCount: 20,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"older\"}")
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
            discovery: StubXcodeTargetDiscovery(targets: [older, other]),
            sessionFactory: factory
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 81, query: "UIView"),
            requestTimeoutOverride: .seconds(1)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"other\"}")
        #expect(await factory.startedPIDs() == [other.processID])
        #expect(await factory.documentationQueries(for: other.processID) == ["UIView"])
        #expect(await factory.documentationQueries(for: older.processID).isEmpty)
    }

    @Test func documentationProviderManagerCoalescesConcurrentBackgroundDiscovery() async throws {
        let target = xcodeProcessTarget(processID: 470, xcodeVersion: "27.0")
        let startGate = OperationGate<pid_t>()
        let preparationReused = TestSignal()
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
            startGate: startGate
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            testHooks: DocumentationProviderManagerTestHooks(
                providerPreparationReused: { processID in
                    if processID == target.processID {
                        preparationReused.signal()
                    }
                }
            )
        )

        let firstUpdate = Task {
            await manager.startBackgroundDiscovery(requestTimeout: .seconds(2))
        }
        try await waitWithTimeout("waiting for first documentation provider preparation") {
            try await startGate.waitUntilWaiting(for: target.processID, count: 1)
        }
        let secondUpdate = Task {
            await manager.startBackgroundDiscovery(requestTimeout: .seconds(2))
        }
        try await preparationReused.wait(
            description: "waiting for second discovery to reuse the in-flight preparation"
        )
        #expect(await factory.startAttempts() == [target.processID])
        await startGate.release(target.processID)

        let results = try await waitWithTimeout("waiting for coalesced background discovery") {
            await [firstUpdate.value, secondUpdate.value]
        }

        for update in results {
            let result = DocumentationProvider.ToolCatalog.applying(update, to: try jsonValue(["tools": []]))
            #expect(documentationDescriptorDescription(in: result) == "docs-27.0")
        }
        #expect(await factory.startAttempts() == [target.processID])
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(await factory.requestCount(processID: target.processID, method: "tools/call") == 0)
    }

    @Test func documentationProviderManagerCoalescesConcurrentInitialDocumentationSearch() async throws {
        let target = xcodeProcessTarget(processID: 480, xcodeVersion: "27.0")
        let startGate = OperationGate<pid_t>()
        let preparationReused = TestSignal()
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
            startGate: startGate
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            testHooks: DocumentationProviderManagerTestHooks(
                providerPreparationReused: { processID in
                    if processID == target.processID {
                        preparationReused.signal()
                    }
                }
            )
        )

        let firstOutcome = Task {
            try await manager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 101, query: "UIView"),
                requestTimeoutOverride: .seconds(2)
            )
        }
        try await waitWithTimeout("waiting for first documentation search preparation") {
            try await startGate.waitUntilWaiting(for: target.processID, count: 1)
        }
        let secondOutcome = Task {
            try await manager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 102, query: "SwiftUI"),
                requestTimeoutOverride: .seconds(2)
            )
        }
        try await preparationReused.wait(
            description: "waiting for second search to reuse the in-flight preparation"
        )
        #expect(await factory.startAttempts() == [target.processID])
        await startGate.release(target.processID)

        let outcomes = try await waitWithTimeout("waiting for coalesced documentation searches") {
            try await [firstOutcome.value, secondOutcome.value]
        }

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
        let target = xcodeProcessTarget(processID: 485, xcodeVersion: "27.0")
        let startGate = OperationGate<pid_t>()
        let preparationReused = TestSignal()
        let preparationTimedOut = TestSignal()
        let (clock, timeoutClock, uptimeClock) = makeRuntimeCoordinatorDeterministicClocks()
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
            startGate: startGate
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            sessionFactory: factory,
            clock: clock,
            testHooks: DocumentationProviderManagerTestHooks(
                providerPreparationReused: { processID in
                    if processID == target.processID {
                        preparationReused.signal()
                    }
                },
                providerPreparationWaitTimedOut: { processID in
                    if processID == target.processID {
                        preparationTimedOut.signal()
                    }
                }
            )
        )

        let shortRequest = Task {
            try await manager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 85, query: "too soon"),
                requestTimeoutOverride: .milliseconds(1)
            )
        }
        try await waitWithTimeout("waiting for shared preparation to suspend") {
            try await startGate.waitUntilWaiting(for: target.processID, count: 1)
        }
        try await advanceRuntimeCoordinatorTimeout(
            timeoutClock: timeoutClock,
            uptimeClock: uptimeClock,
            by: .milliseconds(1)
        )
        try await preparationTimedOut.wait(
            description: "waiting for short preparation wait timeout"
        )
        let shortOutcome = try await waitWithTimeout("waiting for short request outcome") {
            try await shortRequest.value
        }
        guard case .failed(let error, _) = shortOutcome else {
            Issue.record("expected timeout outcome, got \(shortOutcome)")
            return
        }
        #expect(error is TimeoutError)

        let followUpRequest = Task {
            try await manager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 86, query: "SwiftUI"),
                requestTimeoutOverride: .seconds(2)
            )
        }
        try await preparationReused.wait(
            description: "waiting for follow-up request to reuse the in-flight preparation"
        )
        #expect(await factory.startAttempts() == [target.processID])
        await startGate.release(target.processID)
        let followUpOutcome = try await waitWithTimeout("waiting for follow-up request outcome") {
            try await followUpRequest.value
        }
        guard case .handled(let responseData, _) = followUpOutcome else {
            Issue.record("expected handled outcome, got \(followUpOutcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"after-timeout\"}")
        #expect(await factory.startAttempts() == [target.processID])
        #expect(await factory.startedPIDs() == [target.processID])
        #expect(await factory.documentationQueries(for: target.processID) == ["SwiftUI"])
    }

    @Test func documentationProviderManagerReleasesAfterTimedOutSharedPreparation()
        async throws
    {
        let target = xcodeProcessTarget(processID: 487, xcodeVersion: "27.0")
        let startGate = OperationGate<pid_t>()
        let preparationTimedOut = TestSignal()
        let managerDeinitialized = TestSignal()
        let (clock, timeoutClock, uptimeClock) = makeRuntimeCoordinatorDeterministicClocks()
        let factory = ScriptedDocumentationSessionFactory(
            plansByPID: [
                target.processID: [
                    .init(
                        serverVersion: "27.0",
                        toolCount: 47,
                        includesDocumentationSearch: true,
                        firstDocumentationResponse: .successText("{\"answer\":\"late\"}")
                    ),
                ],
            ],
            startGate: startGate
        )

        do {
            let manager = DocumentationProviderManager(
                discovery: StubXcodeTargetDiscovery(targets: [target]),
                sessionFactory: factory,
                clock: clock,
                testHooks: DocumentationProviderManagerTestHooks(
                    providerPreparationWaitTimedOut: { processID in
                        if processID == target.processID {
                            preparationTimedOut.signal()
                        }
                    },
                    managerDeinitialized: {
                        managerDeinitialized.signal()
                    }
                )
            )

            let request = Task {
                try await manager.callDocumentationSearch(
                    requestData: makeDocumentationSearchRequest(id: 88, query: "too soon"),
                    requestTimeoutOverride: .milliseconds(1)
                )
            }
            try await waitWithTimeout("waiting for shared preparation to suspend") {
                try await startGate.waitUntilWaiting(for: target.processID, count: 1)
            }
            try await advanceRuntimeCoordinatorTimeout(
                timeoutClock: timeoutClock,
                uptimeClock: uptimeClock,
                by: .milliseconds(1)
            )
            try await preparationTimedOut.wait(
                description: "waiting for preparation wait timeout"
            )
            let outcome = try await waitWithTimeout("waiting for timed out request") {
                try await request.value
            }
            guard case .failed(let error, _) = outcome else {
                Issue.record("expected timeout outcome, got \(outcome)")
                return
            }
            #expect(error is TimeoutError)
        }

        try await managerDeinitialized.wait(
            description: "waiting for documentation provider manager release"
        )
    }

    @Test func documentationProviderManagerPreservesCallerTimeoutForFinalProvider() async throws {
        let target = xcodeProcessTarget(processID: 486, xcodeVersion: "27.0")
        let (clock, _, _) = makeRuntimeCoordinatorDeterministicClocks()
        let transport = RecordingDocumentationProviderTransport(
            responseData: try makeDocumentationSearchResponse(
                id: 87,
                text: "{\"answer\":\"final\"}"
            )
        )
        let manager = DocumentationProviderManager(
            discovery: StubXcodeTargetDiscovery(targets: [target]),
            transport: transport,
            clock: clock
        )

        let outcome = try await manager.callDocumentationSearch(
            requestData: makeDocumentationSearchRequest(id: 87, query: "SwiftUI"),
            requestTimeoutOverride: .seconds(5)
        )

        guard case .handled(let responseData, _) = outcome else {
            Issue.record("expected handled outcome, got \(outcome)")
            return
        }
        #expect(try toolContentText(in: responseData) == "{\"answer\":\"final\"}")
        let callTimeout = try #require(await transport.documentationSearchTimeouts().first)
        #expect((callTimeout?.nanoseconds ?? 0) > 4_000_000_000)
    }

    @Test func documentationProviderManagerDoesNotRetryAfterRequestTimeoutExpires() async throws {
        let xcode = xcodeProcessTarget(processID: 490, xcodeVersion: "27.0")
        let (clock, timeoutClock, uptimeClock) = makeRuntimeCoordinatorDeterministicClocks()
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
            sessionFactory: factory,
            clock: clock
        )

        let outcomeTask = Task {
            try await manager.callDocumentationSearch(
                requestData: makeDocumentationSearchRequest(id: 91, query: "UIView"),
                requestTimeoutOverride: .milliseconds(1)
            )
        }
        try await waitWithTimeout("waiting for hanging documentation search request") {
            try await factory.waitForRequestCount(
                1,
                processID: xcode.processID,
                method: "tools/call"
            )
        }
        try await advanceRuntimeCoordinatorTimeout(
            timeoutClock: timeoutClock,
            uptimeClock: uptimeClock,
            by: .milliseconds(1)
        )
        let outcome = try await waitWithTimeout(
            "documentation search should fail when its deterministic timeout expires"
        ) {
            try await outcomeTask.value
        }
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
        let xcode = xcodeProcessTarget(processID: 491, xcodeVersion: "27.0")
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

private final class StubDocumentationProcessEventMonitor:
    XcodeProcessEventMonitoring,
    @unchecked Sendable
{
    private let changeHandler =
        NIOLockedValueBox<(@Sendable (_ reason: String) -> Void)?>(nil)

    func start() {}

    func setChangeHandler(
        _ handler: @escaping @Sendable (_ reason: String) -> Void
    ) {
        changeHandler.withLockedValue { $0 = handler }
    }

    func runningXcodeTargets() -> [XcodeProcessTarget] {
        []
    }

    func permissionDialogProcessIDs() -> [pid_t] {
        []
    }

    func readinessSnapshot() -> UpstreamReadinessSnapshot {
        UpstreamReadinessSnapshot(isReady: false, generation: 0)
    }

    func waitForReadinessChange(after _: UInt64) async {}

    func stop() {
        changeHandler.withLockedValue { $0 = nil }
    }

    func emitInventoryChange() {
        let handler = changeHandler.withLockedValue { $0 }
        handler?("test_inventory_changed")
    }
}

private actor RecordingDocumentationProviderTransport: DocumentationProviderRouting {
    private let responseData: Data
    private var documentationSearchTimeoutValues: [TimeAmount?] = []

    init(responseData: Data) {
        self.responseData = responseData
    }

    func openRoute(
        for target: XcodeProcessTarget,
        requestTimeout _: TimeAmount?,
        initializeParams _: [String: JSONValue]
    ) async throws -> DocumentationProviderRoute {
        DocumentationProviderRoute(
            id: "recording-\(target.processID)",
            target: target,
            upstreamIndex: nil,
            serverVersion: target.xcodeVersion
        )
    }

    func toolsList(
        route: DocumentationProviderRoute,
        timeout _: TimeAmount?
    ) async throws -> JSONValue {
        try jsonValue([
            "tools": [
                documentationDescriptor(version: route.serverVersion).foundationObject,
            ],
        ])
    }

    func callDocumentationSearch(
        route _: DocumentationProviderRoute,
        requestData _: Data,
        timeout: TimeAmount?
    ) async throws -> Data {
        documentationSearchTimeoutValues.append(timeout)
        return responseData
    }

    func documentationSearchTimeouts() -> [TimeAmount?] {
        documentationSearchTimeoutValues
    }
}

private final class WeakDocumentationProviderTransportReference: @unchecked Sendable {
    private weak var storage: SessionBackedDocumentationProviderTransport?

    init(_ value: SessionBackedDocumentationProviderTransport?) {
        storage = value
    }

    var value: SessionBackedDocumentationProviderTransport? {
        storage
    }
}

private actor FixedDocumentationSessionFactory: DocumentationProviderSessionMaking {
    private let session: any UpstreamSession

    init(session: any UpstreamSession) {
        self.session = session
    }

    func startSession(for _: XcodeProcessTarget) async throws -> any UpstreamSession {
        session
    }
}

private actor BlockingStopDocumentationSession: UpstreamSession {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let serverVersion: String
    private let stopStarted: TestSignal
    private let stopGate: AsyncGate
    private var stopCountValue = 0

    init(
        serverVersion: String,
        stopStarted: TestSignal,
        stopGate: AsyncGate
    ) {
        self.serverVersion = serverVersion
        self.stopStarted = stopStarted
        self.stopGate = stopGate
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    nonisolated func cancel() {}

    func send(_ data: Data) async -> Upstream.SendResult {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [])
                as? [String: Any],
              let method = object["method"] as? String else {
            return .accepted
        }
        guard let requestID = object["id"] else {
            return .accepted
        }
        switch method {
        case "initialize":
            yieldResponse(
                id: requestID,
                result: [
                    "serverInfo": [
                        "name": "mcpbridge",
                        "version": serverVersion,
                    ],
                ]
            )
        case "tools/list":
            yieldResponse(
                id: requestID,
                result: [
                    "tools": [
                        documentationDescriptor(version: serverVersion).foundationObject,
                    ],
                ]
            )
        case "tools/call":
            yieldResponse(
                id: requestID,
                result: [
                    "content": [
                        [
                            "type": "text",
                            "text": "{\"ok\":true}",
                        ],
                    ],
                    "isError": false,
                ]
            )
        default:
            break
        }
        return .accepted
    }

    func stop() async {
        stopCountValue += 1
        stopStarted.signal()
        try? await stopGate.wait()
        continuation.finish()
    }

    func stopCount() -> Int {
        stopCountValue
    }

    private func yieldResponse(id: Any, result: [String: Any]) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        guard JSONSerialization.isValidJSONObject(response),
              let data = try? JSONSerialization.data(withJSONObject: response, options: []) else {
            return
        }
        continuation.yield(.message(data))
    }
}

private actor HangingDocumentationEventSession: UpstreamSession {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation

    init(terminationSignal: TestSignal) {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            continuation.onTermination = { @Sendable _ in
                terminationSignal.signal()
            }
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    nonisolated func cancel() {}

    func send(_: Data) async -> Upstream.SendResult {
        .accepted
    }

    func stop() async {
        continuation.finish()
    }
}
