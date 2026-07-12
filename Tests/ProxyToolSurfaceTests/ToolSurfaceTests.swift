import Foundation
import NIO
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyKit


@Suite(.serialized)
struct ToolSurfaceTests {
    @Test func toolSurfaceNormalizesStructuredContentFromTextJSON() throws {
        let sessionManager = ToolSurfaceRuntimeCoordinator(configuration: makeToolSurfaceConfig())
        sessionManager.setCachedToolsListResult(
            try #require(
                JSONValue(any: [
                    "tools": [
                        [
                            "name": "DocumentationSearch",
                            "outputSchema": [
                                "type": "object",
                            ],
                        ],
                    ],
                ])
            ),
            sourceUpstream: 0
        )
        let surface = ToolSurface(
            config: makeToolSurfaceConfig(),
            sessionManager: sessionManager
        )

        let upstreamData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "result": [
                    "content": [
                        [
                            "type": "text",
                            "text": "{\"answer\":\"ok\"}",
                        ],
                    ],
                ],
            ],
            options: []
        )
        let rewritten = surface.rewriteForwardedResponse(
            method: "tools/call",
            toolName: "DocumentationSearch",
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            upstreamData: upstreamData
        )

        let payload = try #require(
            JSONSerialization.jsonObject(with: rewritten.responseData, options: []) as? [String: Any]
        )
        let result = try #require(payload["result"] as? [String: Any])
        let structuredContent = try #require(result["structuredContent"] as? [String: Any])
        #expect(structuredContent["answer"] as? String == "ok")
    }

    @Test func toolSurfaceIgnoresNonTextContentDuringNormalization() throws {
        let sessionManager = ToolSurfaceRuntimeCoordinator(configuration: makeToolSurfaceConfig())
        sessionManager.setCachedToolsListResult(
            try #require(
                JSONValue(any: [
                    "tools": [
                        [
                            "name": "DocumentationSearch",
                            "outputSchema": [
                                "type": "object",
                            ],
                        ],
                    ],
                ])
            ),
            sourceUpstream: 0
        )
        let surface = ToolSurface(
            config: makeToolSurfaceConfig(),
            sessionManager: sessionManager
        )

        let upstreamData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "result": [
                    "content": [
                        [
                            "type": "image",
                            "text": "{\"answer\":\"bad\"}",
                        ],
                    ],
                ],
            ],
            options: []
        )
        let rewritten = surface.rewriteForwardedResponse(
            method: "tools/call",
            toolName: "DocumentationSearch",
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            upstreamData: upstreamData
        )

        let payload = try #require(
            JSONSerialization.jsonObject(with: rewritten.responseData, options: []) as? [String: Any]
        )
        let result = try #require(payload["result"] as? [String: Any])
        #expect(result["structuredContent"] == nil)
    }

    @Test func toolSurfaceNormalizesMissingGetBuildLogLines() throws {
        let sessionManager = ToolSurfaceRuntimeCoordinator(configuration: makeToolSurfaceConfig())
        sessionManager.setCachedToolsListResult(
            try #require(
                JSONValue(any: [
                    "tools": [
                        [
                            "name": "GetBuildLog",
                            "outputSchema": [
                                "type": "object",
                            ],
                        ],
                    ],
                ])
            ),
            sourceUpstream: 0
        )
        let surface = ToolSurface(
            config: makeToolSurfaceConfig(),
            sessionManager: sessionManager
        )

        let upstreamData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "result": [
                    "structuredContent": [
                        "emittedIssues": [
                            [
                                "message": "missing line",
                            ],
                            [
                                "message": "null line",
                                "line": NSNull(),
                            ],
                        ],
                    ],
                ],
            ],
            options: []
        )
        let rewritten = surface.rewriteForwardedResponse(
            method: "tools/call",
            toolName: "GetBuildLog",
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            upstreamData: upstreamData
        )

        let payload = try #require(
            JSONSerialization.jsonObject(with: rewritten.responseData, options: []) as? [String: Any]
        )
        let result = try #require(payload["result"] as? [String: Any])
        let structuredContent = try #require(result["structuredContent"] as? [String: Any])
        let issues = try #require(structuredContent["emittedIssues"] as? [[String: Any]])
        #expect((issues[0]["line"] as? NSNumber)?.intValue == 0)
        #expect((issues[1]["line"] as? NSNumber)?.intValue == 0)
    }

    @Test func toolSurfaceRewritesToolsList() throws {
        var config = makeToolSurfaceConfig()
        config.disabledToolNames = ["RunAllTests"]
        let sessionManager = ToolSurfaceRuntimeCoordinator(configuration: config)
        let surface = ToolSurface(config: config, sessionManager: sessionManager)

        let upstreamData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "result": [
                    "tools": [
                        [
                            "name": RefreshCodeIssues.Request.toolName,
                            "description": "old",
                        ],
                        [
                            "name": "RunAllTests",
                            "description": "hidden",
                        ],
                    ],
                ],
            ],
            options: []
        )
        let rewritten = surface.rewriteForwardedResponse(
            method: "tools/list",
            toolName: nil,
            originalID: JSONRPC.ID(any: NSNumber(value: 1)),
            cachesToolsListResult: true,
            upstreamData: upstreamData
        )

        let payload = try #require(
            JSONSerialization.jsonObject(with: rewritten.responseData, options: []) as? [String: Any]
        )
        let result = try #require(payload["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == RefreshCodeIssues.Request.toolName)
        #expect((tools[0]["description"] as? String)?.contains("navigator issues") == true)
    }

    @Test func toolSurfaceAllowsDisabledToolsFilterToExposeEmptyToolsList() throws {
        var config = makeToolSurfaceConfig()
        config.refreshCodeIssuesMode = .upstream
        config.disabledToolNames = ["RunAllTests"]
        let sessionManager = ToolSurfaceRuntimeCoordinator(configuration: config)
        let surface = ToolSurface(config: config, sessionManager: sessionManager)

        let upstreamData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "result": [
                    "tools": [
                        [
                            "name": "RunAllTests",
                            "description": "hidden",
                        ],
                    ],
                ],
            ],
            options: []
        )
        let rewritten = surface.rewriteForwardedResponse(
            method: "tools/list",
            toolName: nil,
            originalID: JSONRPC.ID(any: NSNumber(value: 1)),
            cachesToolsListResult: true,
            upstreamData: upstreamData
        )

        let payload = try #require(
            JSONSerialization.jsonObject(with: rewritten.responseData, options: []) as? [String: Any]
        )
        let result = try #require(payload["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.isEmpty)
    }

    @Test func toolSurfaceNormalizesUsingSourceProcessCatalog() throws {
        let sessionManager = ToolSurfaceRuntimeCoordinator(configuration: makeToolSurfaceConfig())
        sessionManager.setCachedToolsListResult(
            try #require(
                JSONValue(any: [
                    "tools": [
                        [
                            "name": "NewStructuredTool",
                        ],
                    ],
                ])
            ),
            sourceUpstream: 0
        )
        sessionManager.setCachedToolsListResult(
            try #require(
                JSONValue(any: [
                    "tools": [
                        [
                            "name": "NewStructuredTool",
                            "outputSchema": [
                                "type": "object",
                            ],
                        ],
                    ],
                ])
            ),
            upstreamIndex: 1
        )
        let surface = ToolSurface(
            config: makeToolSurfaceConfig(),
            sessionManager: sessionManager
        )

        let upstreamData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "result": [
                    "content": [
                        [
                            "type": "text",
                            "text": "{\"answer\":\"source\"}",
                        ],
                    ],
                ],
            ],
            options: []
        )

        let withoutSource = surface.rewriteForwardedResponse(
            method: "tools/call",
            toolName: "NewStructuredTool",
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            upstreamData: upstreamData
        )
        let withoutSourcePayload = try #require(
            JSONSerialization.jsonObject(with: withoutSource.responseData, options: [])
                as? [String: Any]
        )
        let withoutSourceResult = try #require(withoutSourcePayload["result"] as? [String: Any])
        #expect(withoutSourceResult["structuredContent"] == nil)

        let withSource = surface.rewriteForwardedResponse(
            method: "tools/call",
            toolName: "NewStructuredTool",
            originalID: JSONRPC.ID(any: NSNumber(value: 1))!,
            upstreamIndex: 1,
            upstreamData: upstreamData
        )
        let withSourcePayload = try #require(
            JSONSerialization.jsonObject(with: withSource.responseData, options: [])
                as? [String: Any]
        )
        let withSourceResult = try #require(withSourcePayload["result"] as? [String: Any])
        let structuredContent = try #require(
            withSourceResult["structuredContent"] as? [String: Any]
        )
        #expect(structuredContent["answer"] as? String == "source")
    }

    @Test func toolSurfaceTreatsOnlySyntheticOverloadErrorAsBackpressure() throws {
        let sessionManager = ToolSurfaceRuntimeCoordinator(configuration: makeToolSurfaceConfig())
        let surface = ToolSurface(
            config: makeToolSurfaceConfig(),
            sessionManager: sessionManager
        )

        let exactOverload = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "error": [
                    "code": -32002,
                    "message": "upstream overloaded",
                ],
            ],
            options: []
        )
        let differentMessage = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "error": [
                    "code": -32002,
                    "message": "other failure",
                ],
            ],
            options: []
        )

        #expect(surface.shouldNotifyUpstreamSuccess(for: exactOverload) == false)
        #expect(surface.shouldNotifyUpstreamSuccess(for: differentMessage) == true)
    }
}

private func makeToolSurfaceConfig() -> ProxyConfig {
    ProxyConfig(
        listenHost: "localhost",
        listenPort: 8765,
        upstreamCommand: MCPBridgeInvocation.defaultMCPBridge.command,
        upstreamArgs: MCPBridgeInvocation.defaultMCPBridge.arguments,
        maxBodyBytes: 1_048_576,
        requestTimeout: 300
    )
}

private final class ToolSurfaceRuntimeCoordinator: @unchecked Sendable, RuntimeCoordinating {
    private let config: ProxyConfig
    private var cachedToolsList: JSONValue?
    private var cachedToolsListsByUpstream: [Int: JSONValue] = [:]

    init(configuration: ProxyConfig) {
        self.config = configuration
    }

    func session(id: String) -> SessionContext { SessionContext(id: id, config: config) }
    func hasSession(id: String) -> Bool { false }
    func removeSession(id: String) {}
    func debugReset() {}
    func shutdown() async {}
    func isInitialized() -> Bool { true }
    func cachedToolsListResult() -> JSONValue? { cachedToolsList }
    func cachedToolsListResult(forUpstreamIndex upstreamIndex: Int) -> JSONValue? {
        cachedToolsListsByUpstream[upstreamIndex] ?? cachedToolsList
    }
    func setCachedToolsListResult(_ result: JSONValue, sourceUpstream _: Int) { cachedToolsList = result }
    func setCachedToolsListResult(_ result: JSONValue, upstreamIndex: Int) {
        cachedToolsListsByUpstream[upstreamIndex] = result
    }

    func registerInitialize(
        sessionID: String,
        originalID: JSONRPC.ID,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        fatalError("unused in ToolSurfaceTests")
    }

    func sharedToolsList(
        sessionID: String,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue {
        fatalError("unused in ToolSurfaceTests")
    }


    func liveXcodeListWindowsResult(
        route: ControlPlane.Route,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue {
        fatalError("unused in ToolSurfaceTests")
    }

    func hasDocumentationSearchService() -> Bool { false }

    func chooseUpstreamOperationLease() -> UpstreamOperationLease? { nil }

    func enqueueOnUpstreamSlot<Output>(
        leaseID: LeaseManager.ID,
        descriptor: SessionRequestPipeline.Descriptor,
        on eventLoop: EventLoop,
        preferredUpstreamIndices: [Int]?,
        starter: @escaping @Sendable (UpstreamOperationLease) -> EventLoopFuture<Output>
    ) -> EventLoopFuture<Output> where Output : Sendable {
        fatalError("unused in ToolSurfaceTests")
    }

    func assignUpstreamID(
        sessionID: String,
        originalID: JSONRPC.ID,
        operationLease: UpstreamOperationLease
    ) -> Int64? {
        fatalError("unused in ToolSurfaceTests")
    }

    func removeUpstreamIDMapping(
        sessionID: String,
        requestIDKey: String,
        operationLease: UpstreamOperationLease
    ) {}
    func onRequestTimeout(
        sessionID: String,
        requestIDKey: String,
        operationLease: UpstreamOperationLease
    ) {}
    func onRequestSucceeded(
        sessionID: String,
        requestIDKey: String,
        operationLease: UpstreamOperationLease
    ) {}
    func sendUpstream(
        _ data: Data,
        operationLease: UpstreamOperationLease,
        ensureRunning: Bool,
        admission: RouteForwardingAdmission?,
        onRejected: @escaping @Sendable () -> Void
    ) -> Bool { false }
    func debugSnapshot() -> ProxyDebug.Snapshot { fatalError("unused in ToolSurfaceTests") }
    func debugSnapshot(includeSensitiveDebugPayloads: Bool) -> ProxyDebug.Snapshot {
        fatalError("unused in ToolSurfaceTests")
    }

    func createRequestLease(descriptor: SessionRequestPipeline.Descriptor) -> LeaseManager.ID {
        fatalError("unused in ToolSurfaceTests")
    }

    func activateRequestLease(
        _ leaseID: LeaseManager.ID,
        requestIDKey: String?,
        upstreamIndex: Int?,
        timeout: TimeAmount?
    ) {}

    func completeRequestLease(_ leaseID: LeaseManager.ID) {}
    func requeueRequestLease(_ leaseID: LeaseManager.ID) {}

    func failRequestLease(
        _ leaseID: LeaseManager.ID,
        terminalState: LeaseManager.State,
        reason: LeaseManager.ReleaseReason
    ) {}

    func handleRequestLeaseTimeout(
        _ leaseID: LeaseManager.ID,
        sessionID: String,
        requestIDKeys: [String],
        operationLease: UpstreamOperationLease
    ) {}

    func abandonRequestLease(
        _ leaseID: LeaseManager.ID,
        sessionID: String,
        requestIDKeys: [String],
        operationLease: UpstreamOperationLease?
    ) {}
}
