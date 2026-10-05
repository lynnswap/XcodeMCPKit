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
    func preparedRequestKeepsItsDefinitionAcrossCatalogRefresh(
        hadOutputSchema: Bool
    ) async throws {
        let native = TestUpstreamClient()
        let config = makeConfig(requestTimeout: 5)
        let fixture = RuntimeCoordinatorFixture(config: config, upstreams: [native], startImmediately: false)
        defer { fixture.shutdownAndWait() }
        let manager = fixture.manager
        manager.markUpstreamInitialized(upstreamIndex: 0)
        seedCoordinatorSuiteInitialize(on: manager,
            result: try jsonValue(["protocolVersion": MCP.ProtocolVersion.current, "capabilities": [:]]),
            sourceUpstream: 0)
        let original = snapshotToolDescriptor(revision: "original", hasOutputSchema: hadOutputSchema)
        try seedNativeToolCatalog(on: manager, upstreamIndex: 0, tools: [original])
        let sessionID = "definition-snapshot-\(hadOutputSchema)"
        let arguments: [String: Any] = ["originalInput": "client-value", "workspaceIdentifier": "/Work/Snapshot.xcworkspace"]
        let request = toolsCallObject(id: 77, name: "DynamicSnapshotTool", arguments: arguments)
        let body = try JSONRPC.Wire.data(from: request)
        let operationLease = manager.operationLeaseForTest(upstreamIndex: 0)
        let originalValue = try jsonValue(original)
        let service = MCPForwardingService(configuration: config, sessionManager: manager)
        let prepared = try #require(try service.prepareRequest(
            bodyData: body, parsedRequestJSON: request, sessionID: sessionID,
            operationLeaseOverride: operationLease
        ))
        #expect(prepared.toolDefinition?.sourceProof == operationLease.proof)
        #expect(prepared.toolDefinition?.descriptor == originalValue)
        let session = manager.session(id: sessionID)
        let started = try service.startRequest(
            prepared, session: session, on: fixture.eventLoop, requestTimeoutOverride: .seconds(5)
        )
        #expect(started.toolDefinition?.descriptor == originalValue)
        let sent = try await sentMessage(from: native, matching: {
            methodName(from: $0) == "tools/call" && toolCallName(from: $0) == "DynamicSnapshotTool"
        }, timeout: .seconds(2))
        let sentObject = try JSONRPC.Wire.object(fromData: sent)
        let sentParams = try #require(sentObject["params"] as? [String: Any])
        let sentArguments = try #require(sentParams["arguments"] as? [String: Any])
        #expect(sentArguments["originalInput"] as? String == "client-value")
        #expect(sentArguments["beforePreparationInput"] == nil)
        #expect(sentArguments["workspaceIdentifier"] as? String == "/Work/Snapshot.xcworkspace")

        let awaitingResponse = snapshotToolDescriptor(
            revision: "awaitingResponse", hasOutputSchema: !hadOutputSchema
        )
        try await refreshSnapshotCatalog(
            fixture: fixture, native: native, sessionID: sessionID,
            descriptor: awaitingResponse
        )
        #expect(manager.toolDefinition(named: "DynamicSnapshotTool", sourceProof: operationLease.proof)?.descriptor == (try jsonValue(awaitingResponse)))
        #expect(started.toolDefinition?.descriptor == originalValue)

        let text = "{\"answer\":\"original-provider-result\"}"
        let content: JSONValue = .array([.object(["type": .string("text"), "text": .string(text)])])
        let nativeResult: JSONValue = .object([
            "content": content,
            "isError": .bool(false),
        ])
        await native.yield(.message(try JSONRPC.Wire.resultResponseData(
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
    revision: String, hasOutputSchema: Bool
) -> [String: Any] {
    let properties: [String: Any] = ["\(revision)Input": ["type": "string"]]
    return toolDescriptor(
        name: "DynamicSnapshotTool", description: "nativeHost-\(revision)",
        inputProperties: properties, required: ["\(revision)Input"],
        outputSchema: hasOutputSchema ? ["type": "object", "properties": ["answer": ["type": "string"]]] : nil
    )
}

private func refreshSnapshotCatalog(
    fixture: RuntimeCoordinatorFixture, native: TestUpstreamClient,
    sessionID: String, descriptor: [String: Any]
) async throws {
    let manager = fixture.manager
    let nativeOffset = await native.sentCount()
    let refresh = Task {
        try await manager.sharedToolsList(sessionID: sessionID, requestTimeoutOverride: .seconds(5))
    }
    defer { refresh.cancel() }
    let nativeRequest = try await sentValue(from: native, at: nativeOffset, timeout: .seconds(2))
    #expect(methodName(from: nativeRequest) == "tools/list")
    await native.yield(.message(try JSONRPC.Wire.resultResponseData(
        id: try #require(JSONRPC.ID(any: extractUpstreamID(from: nativeRequest))),
        result: try jsonValue(["tools": [descriptor]])
    )))
    _ = try await waitWithTimeout("waiting for refreshed provider catalogs", timeout: .seconds(2)) {
        try await refresh.value
    }
    await manager.drainRuntimeTasksForTesting()
}
