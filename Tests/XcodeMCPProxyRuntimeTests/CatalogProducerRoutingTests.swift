@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Foundation
import NIO
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

@Suite(.serialized, .timeLimit(.minutes(1)), .asyncTestCleanup)
struct CatalogProducerRoutingTests {
    @Test(arguments: ["rawTab", "proxyTab", "workspaceIdentifier", "path", "unscoped"])
    func aGUIRouteUsesTheConnectionThatActuallyProducedItsCatalog(selector: String) async throws {
        let fixture = try CatalogProducerFixture()
        defer { fixture.runtime.shutdownAndWait() }
        try await fixture.refreshCatalogViaSecondConnection()
        try await fixture.loadActualWindowInventory()
        let manager = fixture.runtime.manager
        let producerProof = manager.operationLeaseForTest(upstreamIndex: 1).proof
        let scoped = selector != "unscoped"
        let toolName = scoped ? "ProducerScopedTool" : "ProducerUnscopedTool"
        let descriptor = scoped ? fixture.scopedDescriptor : fixture.unscopedDescriptor
        var arguments: [String: Any] = ["query": "producer-query"]
        switch selector {
        case "rawTab": arguments["tabIdentifier"] = fixture.rawTabIdentifier
        case "proxyTab":
            arguments["tabIdentifier"] = try #require(manager.windowOwnershipAuthority.snapshot().identities.first?.proxyTabIdentifier)
        case "workspaceIdentifier": arguments["workspaceIdentifier"] = fixture.rawTabIdentifier
        case "path": arguments["workspaceIdentifier"] = fixture.workspacePath
        default: break
        }
        let request = toolsCallObject(id: 221, name: toolName, arguments: arguments)
        let decision = await manager.toolRoutingDecision(for: request, requestTimeoutOverride: .seconds(5))
        guard case .forwardAdmitted(let preferred, let admission) = decision else {
            Issue.record("The refreshed GUI tool must have an admitted catalog producer")
            return
        }
        #expect(preferred == [1])
        #expect(admission.upstreamProofs == [producerProof])
        #expect(admission.toolDefinition?.sourceProof == producerProof)
        #expect(admission.toolDefinition?.descriptor == (try jsonValue(descriptor)))
        if scoped { #expect(admission.window?.rewritePlan.tabIdentifier == fixture.rawTabIdentifier) }

        let sessionID = "catalog-producer-\(selector)"
        _ = manager.session(id: sessionID)
        manager.sessionRegistry.markInitialized(id: sessionID, negotiatedProtocolVersion: MCP.ProtocolVersion.current)
        let executor = ClientMCPRequestExecutor(
            config: fixture.config,
            sessionManager: manager
        )
        let operation = executor.handle(
            bodyData: try JSONRPC.Wire.data(from: request),
            headerSessionID: sessionID, headerSessionExists: true,
            prefersEventStream: false, eventLoop: fixture.runtime.eventLoop
        )
        let sent = try await sentMessage(from: fixture.producer, matching: {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == toolName
        }, timeout: .seconds(2))
        let sentObject = try JSONRPC.Wire.object(fromData: sent)
        let params = try #require(sentObject["params"] as? [String: Any])
        let sentArguments = try #require(params["arguments"] as? [String: Any])
        var expected: [String: JSONValue] = ["query": .string("producer-query")]
        if scoped { expected["tabIdentifier"] = .string(fixture.rawTabIdentifier) }
        #expect(JSONValue(any: sentArguments) == .object(expected))

        let content: JSONValue = .array([.object([
            "type": .string("text"), "text": .string("{\"producerAnswer\":\"connection-one\"}"),
        ])])
        await fixture.producer.yield(.message(try JSONRPC.Wire.resultResponseData(
            id: try #require(JSONRPC.ID(any: extractUpstreamID(from: sent))),
            result: .object(["content": content, "isError": .bool(false)])
        )))
        let resolution = try await waitWithTimeout("waiting for the catalog producer's actual tool response", timeout: .seconds(2)) {
            try await operation.future.get()
        }
        guard case .responseData(let data, _, _) = resolution else {
            Issue.record("Expected the admitted producer's MCP tool result")
            return
        }
        let response = try JSONRPC.Wire.object(fromData: data)
        #expect((response["id"] as? NSNumber)?.int64Value == 221)
        let result = try #require(response["result"] as? [String: Any])
        #expect(JSONValue(any: try #require(result["content"])) == content)
        #expect(JSONValue(any: try #require(result["structuredContent"])) == .object([
            "producerAnswer": .string("connection-one"),
        ]))
        #expect(result["isError"] as? Bool == false)
        await manager.drainRuntimeTasksForTesting()
        #expect(await fixture.first.sent().filter { methodName(from: $0) == "tools/list" }.count == 1)
        #expect(await fixture.first.sent().filter { methodName(from: $0) == "tools/call" }.isEmpty)
        #expect(await fixture.producer.sent().filter { toolCallName(from: $0) == toolName }.count == 1)
    }
}

private struct CatalogProducerFixture {
    let config: ProxyRuntimeConfiguration
    let runtime: RuntimeCoordinatorFixture
    let first: TestUpstreamClient
    let producer: TestUpstreamClient
    let target: XcodeProcessTarget
    let scopedDescriptor: [String: Any]
    let unscopedDescriptor: [String: Any]
    let rawTabIdentifier = "producer-tab"
    let workspacePath = "/Work/Producer.xcworkspace"

    init() throws {
        let config = makeConfig(requestTimeout: 5)
        self.config = config
        let first = TestUpstreamClient()
        let producer = TestUpstreamClient()
        self.first = first
        self.producer = producer
        let target = xcodeProcessTarget(processID: 7701, xcodeVersion: "27.0")
        self.target = target
        let runtime = RuntimeCoordinatorFixture(
            config: config, upstreams: [first, producer],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [0, 1])],
            startImmediately: false
        )
        self.runtime = runtime
        scopedDescriptor = producerRoutingDescriptor(name: "ProducerScopedTool", scoped: true, hasOutput: true)
        unscopedDescriptor = producerRoutingDescriptor(name: "ProducerUnscopedTool", scoped: false, hasOutput: true)
        let manager = runtime.manager
        for index in 0...1 { manager.markUpstreamInitialized(upstreamIndex: index) }
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]),
            sourceUpstream: 0)
        try seedProcessToolCatalogs(on: manager, entries: [(target, 0, [
            producerRoutingDescriptor(name: "ProducerScopedTool", scoped: true, hasOutput: false),
            producerRoutingDescriptor(name: "ProducerUnscopedTool", scoped: false, hasOutput: false),
            toolDescriptor(name: "XcodeListWindows"),
        ])])
    }

    func refreshCatalogViaSecondConnection() async throws {
        let manager = runtime.manager
        let refresh = Task { try await manager.sharedToolsList(sessionID: "producer-catalog", requestTimeoutOverride: .seconds(5)) }
        defer { refresh.cancel() }
        let failed = try await sentMessage(from: first, matching: { methodName(from: $0) == "tools/list" }, timeout: .seconds(2))
        await first.yield(.message(try JSONRPC.Wire.errorResponseData(
            id: JSONRPC.ID(any: try extractUpstreamID(from: failed)), code: -32603, message: "First connection catalog is warming"
        )))
        let fallback = try await sentMessage(from: producer, matching: { methodName(from: $0) == "tools/list" }, timeout: .seconds(2))
        await producer.yield(.message(try JSONRPC.Wire.resultResponseData(
            id: try #require(JSONRPC.ID(any: extractUpstreamID(from: fallback))),
            result: try jsonValue(["tools": [scopedDescriptor, unscopedDescriptor, toolDescriptor(name: "XcodeListWindows")]])
        )))
        _ = try await waitWithTimeout("waiting for the public catalog fallback to finish", timeout: .seconds(2)) {
            try await refresh.value
        }
        let producerProof = manager.operationLeaseForTest(upstreamIndex: 1).proof
        #expect(manager.processControlPlane.catalog(forProcessID: target.processID)?.upstreamProof == producerProof)
        #expect(manager.toolDefinition(named: "ProducerScopedTool", sourceProof: producerProof)?.descriptor == (try jsonValue(scopedDescriptor)))
        #expect(manager.toolDefinition(named: "ProducerUnscopedTool", sourceProof: producerProof)?.descriptor == (try jsonValue(unscopedDescriptor)))
        #expect(manager.toolDefinition(named: "ProducerScopedTool", sourceProof: manager.operationLeaseForTest(upstreamIndex: 0).proof) == nil)
    }

    func loadActualWindowInventory() async throws {
        let manager = runtime.manager
        let inventory = Task {
            try await manager.liveXcodeListWindowsResult(route: .pinnedUpstream(1), requestTimeoutOverride: .seconds(5))
        }
        defer { inventory.cancel() }
        let request = try await sentMessage(from: producer, matching: {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "XcodeListWindows"
        }, timeout: .seconds(2))
        await producer.yield(.message(try makeXcodeListWindowsResponse(
            id: extractUpstreamID(from: request),
            message: "* tabIdentifier: \(rawTabIdentifier), workspacePath: \(workspacePath)"
        )))
        _ = try await waitWithTimeout("waiting for the actual producer window inventory", timeout: .seconds(2)) {
            try await inventory.value
        }
    }
}

private func producerRoutingDescriptor(name: String, scoped: Bool, hasOutput: Bool) -> [String: Any] {
    var properties: [String: Any] = ["query": ["type": "string"]]
    var required = ["query"]
    if scoped {
        properties["tabIdentifier"] = ["type": "string"]
        required.append("tabIdentifier")
    }
    return toolDescriptor(
        name: name, description: hasOutput ? "Actual connection-one definition" : "Previous connection-zero definition",
        inputProperties: properties, required: required,
        outputSchema: hasOutput ? ["type": "object", "properties": ["producerAnswer": ["type": "string"]]] : nil
    )
}
