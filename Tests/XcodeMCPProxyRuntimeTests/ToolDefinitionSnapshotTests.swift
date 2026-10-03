@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Foundation
import NIO
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

@Suite(.serialized, .timeLimit(.minutes(1)), .asyncTestCleanup)
struct ToolDefinitionSnapshotTests {
    @Test(arguments: [false, true])
    func admittedRequestKeepsItsProviderDefinitionAcrossCatalogRefresh(
        hadOutputSchema: Bool
    ) async throws {
        let native = TestUpstreamClient()
        let gui = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let target = xcodeProcessTarget(processID: 7027, xcodeVersion: "27.0")
        let fixture = RuntimeCoordinatorFixture(
            config: config,
            upstreams: [native, gui],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [1])],
            startImmediately: false
        )
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        for index in 0...1 { manager.markUpstreamInitialized(upstreamIndex: index) }
        seedCoordinatorSuiteInitialize(
            on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]),
            sourceUpstream: 0
        )
        let original = snapshotToolDescriptor(
            guiProvider: true, revision: "original", hasOutputSchema: hadOutputSchema
        )
        let other = snapshotToolDescriptor(
            guiProvider: false,
            revision: "other-provider", hasOutputSchema: !hadOutputSchema
        )
        try seedUnboundToolCatalog(on: manager, upstreamIndex: 0, tools: [other])
        try seedProcessToolCatalogs(on: manager, entries: [
            (target, 1, [original, toolDescriptor(name: "XcodeListWindows")]),
        ])
        #expect(manager.recordXcodeWindowOwners(from: try jsonValue([
            "structuredContent": ["message": "* tabIdentifier: snapshot-tab, workspacePath: /Work/Snapshot.xcworkspace"],
        ]), upstreamIndex: 1))

        let sessionID = "definition-snapshot-\(hadOutputSchema)"
        let arguments: [String: Any] = ["originalInput": "client-value", "tabIdentifier": "snapshot-tab"]
        let request = toolsCallObject(id: 77, name: "DynamicSnapshotTool", arguments: arguments)
        let body = try JSONRPC.Wire.data(from: request)
        let decision = await manager.toolRoutingDecision(for: request, requestTimeoutOverride: .seconds(5))
        guard case .forwardAdmitted(let preferred, let admission) = decision else {
            Issue.record("Expected an admitted provider for the dynamic tool")
            return
        }
        #expect(preferred == [1])
        let operationLease = manager.operationLeaseForTest(upstreamIndex: 1)
        let originalValue = try jsonValue(original)
        #expect(admission.toolDefinition?.sourceProof == operationLease.proof)
        #expect(admission.toolDefinition?.descriptor == originalValue)

        // The admitted request waits while an actual tools/list replaces its provider's descriptor.
        let beforePreparation = snapshotToolDescriptor(
            guiProvider: true, revision: "beforePreparation", hasOutputSchema: !hadOutputSchema
        )
        try await refreshSnapshotCatalog(
            fixture: fixture, native: native, gui: gui, sessionID: sessionID,
            nativeDescriptor: other, guiDescriptor: beforePreparation
        )
        #expect(manager.toolDefinition(named: "DynamicSnapshotTool", sourceProof: operationLease.proof)?.descriptor == (try jsonValue(beforePreparation)))

        let service = MCPForwardingService(configuration: config, sessionManager: manager)
        let prepared = try #require(try service.prepareRequest(
            bodyData: body, parsedRequestJSON: request, sessionID: sessionID,
            operationLeaseOverride: operationLease, admission: admission
        ))
        #expect(prepared.toolDefinition?.sourceProof == operationLease.proof)
        #expect(prepared.toolDefinition?.descriptor == originalValue)
        let session = manager.session(id: sessionID)
        let started = try service.startRequest(
            prepared, session: session, on: fixture.eventLoop, requestTimeoutOverride: .seconds(5)
        )
        #expect(started.toolDefinition?.descriptor == originalValue)
        let sent = try await sentMessage(from: gui, matching: {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "DynamicSnapshotTool"
        }, timeout: .seconds(2))
        let sentObject = try JSONRPC.Wire.object(fromData: sent)
        let sentParams = try #require(sentObject["params"] as? [String: Any])
        let sentArguments = try #require(sentParams["arguments"] as? [String: Any])
        #expect(sentArguments["originalInput"] as? String == "client-value")
        #expect(sentArguments["beforePreparationInput"] == nil)
        #expect(sentArguments["tabIdentifier"] as? String == "snapshot-tab")

        let awaitingResponse = snapshotToolDescriptor(
            guiProvider: true, revision: "awaitingResponse", hasOutputSchema: !hadOutputSchema
        )
        try await refreshSnapshotCatalog(
            fixture: fixture, native: native, gui: gui, sessionID: sessionID,
            nativeDescriptor: other, guiDescriptor: awaitingResponse
        )
        #expect(manager.toolDefinition(named: "DynamicSnapshotTool", sourceProof: operationLease.proof)?.descriptor == (try jsonValue(awaitingResponse)))
        #expect(started.toolDefinition?.descriptor == originalValue)

        let text = "{\"answer\":\"original-provider-result\"}"
        let content: JSONValue = .array([.object(["type": .string("text"), "text": .string(text)])])
        let nativeResult: JSONValue = .object([
            "content": content,
            "isError": .bool(false),
        ])
        await gui.yield(.message(try JSONRPC.Wire.resultResponseData(
            id: try #require(JSONRPC.ID(any: extractUpstreamID(from: sent))), result: nativeResult
        )))
        let response = try await waitWithTimeout("waiting for the original provider response", timeout: .seconds(2)) {
            try await started.future.get()
        }
        let resolution = service.resolveResponse(.success(response), started: started, sessionID: sessionID)
        guard case .success(let data) = resolution else {
            Issue.record("Expected the original provider response to succeed")
            return
        }
        let responseObject = try JSONRPC.Wire.object(fromData: data)
        #expect((responseObject["id"] as? NSNumber)?.int64Value == 77)
        let result = try #require(responseObject["result"] as? [String: Any])
        let receivedContent = try #require(result["content"])
        #expect(JSONValue(any: receivedContent) == content)
        #expect(result["isError"] as? Bool == false)
        if hadOutputSchema {
            let structured = try #require(result["structuredContent"] as? [String: Any])
            #expect(structured["answer"] as? String == "original-provider-result")
        } else {
            #expect(result["structuredContent"] == nil)
        }
    }
}

private func snapshotToolDescriptor(
    guiProvider: Bool, revision: String, hasOutputSchema: Bool
) -> [String: Any] {
    var properties: [String: Any] = ["\(revision)Input": ["type": "string"]]
    if guiProvider { properties["tabIdentifier"] = ["type": "string"] }
    return toolDescriptor(
        name: "DynamicSnapshotTool", description: "\(guiProvider ? "gui" : "nativeHost")-\(revision)",
        inputProperties: properties, required: ["\(revision)Input"],
        outputSchema: hasOutputSchema ? ["type": "object", "properties": ["answer": ["type": "string"]]] : nil
    )
}

private func refreshSnapshotCatalog(
    fixture: RuntimeCoordinatorFixture, native: TestUpstreamClient, gui: TestUpstreamClient,
    sessionID: String, nativeDescriptor: [String: Any], guiDescriptor: [String: Any]
) async throws {
    let manager = fixture.manager
    let nativeOffset = await native.sentCount()
    let guiOffset = await gui.sentCount()
    let refresh = Task {
        try await manager.sharedToolsList(sessionID: sessionID, requestTimeoutOverride: .seconds(5))
    }
    defer { refresh.cancel() }
    let nativeRequest = try await sentValue(from: native, at: nativeOffset, timeout: .seconds(2))
    #expect(methodName(from: nativeRequest) == "tools/list")
    await native.yield(.message(try JSONRPC.Wire.resultResponseData(
        id: try #require(JSONRPC.ID(any: extractUpstreamID(from: nativeRequest))),
        result: try jsonValue(["tools": [nativeDescriptor]])
    )))
    let guiRequest = try await sentValue(from: gui, at: guiOffset, timeout: .seconds(2))
    #expect(methodName(from: guiRequest) == "tools/list")
    await gui.yield(.message(try JSONRPC.Wire.resultResponseData(
        id: try #require(JSONRPC.ID(any: extractUpstreamID(from: guiRequest))),
        result: try jsonValue(["tools": [guiDescriptor, toolDescriptor(name: "XcodeListWindows")]])
    )))
    _ = try await waitWithTimeout("waiting for refreshed provider catalogs", timeout: .seconds(2)) {
        try await refresh.value
    }
    await manager.drainRuntimeTasksForTesting()
}
