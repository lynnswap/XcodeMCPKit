import Foundation
import Testing
@testable import XcodeMCPNativeRuntime
import XcodeMCPWire

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct NativeMCPSessionTests {
    @Test func initializationAdvertisesTheNativeToolCapability() async throws {
        try await withNativeSession { harness in
            let response = try await harness.initialize()
            #expect(try nativeTestField(response, "id") == .string("initialize"))
            #expect(try nativeTestField(response, "result", "protocolVersion") == .string(MCPProtocolVersion.current))
            #expect(try nativeTestField(response, "result", "capabilities") == .object(["tools": .object([:])]))
            #expect(try nativeTestField(response, "result", "serverInfo", "name") == .string("XcodeMCPKit Native Host"))
            #expect(harness.backend.executions.isEmpty)
        }
    }

    @Test func backendInitializationReceivesClientInfoAndTheToolConversation() async throws {
        try await withNativeSession { harness in
            let clientInfo: [String: JSONValue] = [
                "name": .string("Actual MCP Client"), "version": .string("2.3"),
                "extension": .object(["features": .array([.string("images"), .string("progress")])]),
            ]
            _ = try await harness.initialize(clientInfo: clientInfo)
            let context = try #require(harness.backend.initializationContexts.first)
            #expect(harness.backend.initializationContexts.count == 1)
            #expect(context.clientInfo == clientInfo)
            #expect(!context.conversationID.isEmpty)
            try harness.call("Action", id: "same-conversation")
            let execution = try await harness.backend.nextExecution()
            #expect(execution.context.conversationID == context.conversationID)
            try execution.complete(.object([:]))
            #expect(try nativeTestField(await harness.nextMessage(), "id") == .string("same-conversation"))
        }
    }

    @Test func failedBackendInitializationLeavesToolRequestsUnavailable() async throws {
        try await withNativeSession { harness in
            harness.backend.initializeError = .unavailable("GUI connection initialization failed")
            let failure = try await harness.initialize()
            #expect(try nativeTestField(failure, "error", "code") == .number(.int(-32603)))
            #expect(try nativeTestField(failure, "error", "message") == .string("GUI connection initialization failed"))
            #expect(try nativeTestObject(failure)["result"] == nil)
            #expect(harness.backend.initializationContexts.count == 1)
            try harness.request("tools/list", id: "catalog-after-failed-init")
            #expect(try nativeTestField(await harness.nextMessage(), "error", "code") == .number(.int(-32602)))
            try harness.call("Action", id: "call-after-failed-init")
            #expect(try nativeTestField(await harness.nextMessage(), "error", "code") == .number(.int(-32602)))
            #expect(harness.backend.listCalls == 0)
            #expect(harness.backend.executions.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: harness.artifactsRoot.path))
        }
    }

    @Test(arguments: [false, true])
    func nativeMCPResultsPreserveContentStructuredOutputAndErrorStatus(isError: Bool) async throws {
        try await withNativeSession { harness in
            harness.backend.resultFormat = .mcpResult
            _ = try await harness.initialize()
            try harness.call("GUIAction", id: "native-mcp-result")
            let execution = try await harness.backend.nextExecution()
            let nativeResult: JSONValue = .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string("Native output \n値")]),
                    .object([
                        "type": .string("image"), "mimeType": .string("image/png"), "data": .string("AAH/"),
                        "annotations": .object(["audience": .array([.string("user")])]),
                    ]),
                ]),
                "structuredContent": .object(["windows": .array([.object(["tabIdentifier": .string("window-4")])])]),
                "isError": .bool(isError),
                "_meta": .object(["native": .bool(true)]),
            ])
            try execution.complete(nativeResult)
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "id") == .string("native-mcp-result"))
            #expect(try nativeTestField(response, "result") == nativeResult)
        }
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":73,"method":"tools/call","params":{"name":"Mutation",}}"#,
        #"{"jsonrpc":"2.0","id":73,"method":"tools/call","params":{"name":"Mutation"},}"#,
        #"{"jsonrpc":"2.0","id":73,"method":"tools/call","params":{"name":"Mutation","arguments":{"values":[1,]}}}"#,
        #"{"jsonrpc":"2.0","id":73,"method":"tools/call","params":{"name":"Mutation","arguments":{"value":01}}}"#,
        #"{"jsonrpc":"2.0","id":73,"method":"tools/call","params":{"name":"Mutation"}} /* comment */"#,
    ])
    func invalidJSONNeverDispatchesAndTheNextRequestStillSucceeds(raw: String) async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.session.receive(Data(raw.utf8))
            let error = try await harness.nextMessage()
            #expect(try nativeTestField(error, "error", "code") == .number(.int(-32700)))
            #expect(harness.backend.executions.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: harness.artifactsRoot.path))
            try harness.request("ping", id: "after-invalid-json")
            #expect(try nativeTestField(await harness.nextMessage(), "result") == .object([:]))
        }
    }

    @Test(arguments: [
        "missing", "true", "[]", "null", "{}",
        #"{"capabilities":{},"clientInfo":{"name":"Test","version":"1"}}"#,
        #"{"protocolVersion":42,"capabilities":{},"clientInfo":{"name":"Test","version":"1"}}"#,
        #"{"protocolVersion":"2025-06-18","clientInfo":{"name":"Test","version":"1"}}"#,
        #"{"protocolVersion":"2025-06-18","capabilities":true,"clientInfo":{"name":"Test","version":"1"}}"#,
        #"{"protocolVersion":"2025-06-18","capabilities":{}}"#,
        #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":[]}"#,
        #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"version":"1"}}"#,
        #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":true,"version":"1"}}"#,
        #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Test"}}"#,
        #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Test","version":1}}"#,
    ])
    func invalidInitializeParametersDoNotInitializeTheSession(raw: String) async throws {
        try await withNativeSession { harness in
            let parameters = raw == "missing" ? nil : try nativeTestJSON(Data(raw.utf8))
            try harness.request("initialize", id: "invalid-initialize", params: parameters)
            let invalid = try await harness.nextMessage()
            #expect(try nativeTestField(invalid, "id") == .string("invalid-initialize"))
            #expect(try nativeTestField(invalid, "error", "code") == .number(.int(-32602)))
            try harness.request("tools/list", id: "uninitialized")
            #expect(try nativeTestField(await harness.nextMessage(), "error", "code") == .number(.int(-32602)))
            #expect(harness.backend.listCalls == 0)
            #expect(harness.backend.executions.isEmpty)
            #expect(harness.backend.initializationContexts.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: harness.artifactsRoot.path))

            _ = try await harness.initialize()
            #expect(harness.backend.initializationContexts.count == 1)
            try harness.request("tools/list", id: "valid-initialize")
            #expect(try nativeTestField(await harness.nextMessage(), "result", "tools") == .array([]))
            #expect(harness.backend.listCalls == 1)
        }
    }

    @Test func catalogReflectsTheBackendAtEachRequest() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            let first = NativeTool(name: "InstalledXcodeTool", descriptor: .object([
                "name": .string("InstalledXcodeTool"), "inputSchema": .object(["type": .string("object")]),
                "annotations": .object(["readOnlyHint": .bool(true)]),
            ]), workspaceScoped: false)
            harness.backend.tools = [first]
            try harness.request("tools/list", id: "catalog-1")
            #expect(try nativeTestField(await harness.nextMessage(), "result", "tools") == .array([first.descriptor]))

            let second = NativeTool(name: "ToolAddedByXcode", descriptor: .object([
                "name": .string("ToolAddedByXcode"), "inputSchema": .object(["properties": .object([:])]),
                "outputSchema": .object(["type": .string("object")]),
            ]), workspaceScoped: true)
            harness.backend.tools = [second]
            try harness.request("tools/list", id: "catalog-2")
            #expect(try nativeTestField(await harness.nextMessage(), "result", "tools") == .array([second.descriptor]))
            #expect(harness.backend.listCalls == 2)
        }
    }

    @Test func toolCallPreservesArgumentsProgressAndStructuredOutput() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            let arguments: [String: JSONValue] = [
                "workspaceIdentifier": .string("/tmp/Project.xcodeproj"),
                "nested": .object(["values": .array([.number(.int(4)), .bool(true), .null])]),
            ]
            try harness.call("DynamicNativeAction", id: "call", arguments: arguments, progressToken: .number(.int(73)))
            let execution = try await harness.backend.nextExecution()
            #expect(execution.name == "DynamicNativeAction")
            #expect(execution.arguments == arguments)
            #expect(FileManager.default.fileExists(atPath: execution.context.artifactsDirectory.path))
            #expect(!execution.context.conversationID.isEmpty)

            let progress: JSONValue = .object(["progress": .number(.int(1)), "total": .number(.int(2)), "message": .string("Building")])
            try execution.emit("update", data: progress)
            let notification = try await harness.nextMessage()
            #expect(try nativeTestField(notification, "method") == .string("notifications/progress"))
            #expect(try nativeTestField(notification, "params") == .object([
                "progress": .number(.int(1)), "total": .number(.int(2)), "message": .string("Building"),
                "progressToken": .number(.int(73)),
            ]))
            #expect(try nativeTestObject(notification)["id"] == nil)

            let output: JSONValue = .object(["built": .bool(true), "artifacts": .array([.string("App.app")])])
            try execution.complete(output)
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "id") == .string("call"))
            #expect(try nativeTestField(response, "result", "isError") == .bool(false))
            #expect(try nativeTestField(response, "result", "structuredContent") == output)
            let content = try #require(try nativeTestField(response, "result", "content").arrayValue?.first)
            guard case .string(let text) = try nativeTestField(content, "text") else {
                Issue.record("Tool content must contain text")
                return
            }
            #expect(try nativeTestJSON(Data(text.utf8)) == output)
            #expect(harness.backend.observations.map(\.event) == [
                .object(["type": .string("update"), "data": progress]),
                .object(["type": .string("completed"), "data": output]),
            ])
        }
    }

    @Test func progressWithoutATokenDoesNotEmitAnUncorrelatedNotification() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.call("Action", id: "call")
            let execution = try await harness.backend.nextExecution()
            try execution.emit("update", data: .object(["progress": .number(.int(1))]))
            try execution.complete(.string("Finished"))
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "id") == .string("call"))
            #expect(try nativeTestField(response, "result", "content") == .array([
                .object(["type": .string("text"), "text": .string("Finished")]),
            ]))
            #expect(try nativeTestObject(nativeTestField(response, "result"))["structuredContent"] == nil)
        }
    }

    @Test(arguments: [JSONValue.bool(true), .bool(false), .array([]), .object([:]), .null])
    func invalidProgressTokensDoNotEmitNotifications(token: JSONValue) async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.call("Action", id: "invalid-token", progressToken: token)
            let execution = try await harness.backend.nextExecution()
            try execution.emit("update", data: .object(["progress": .number(.int(1))]))
            try execution.complete(.string("Completed"))
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "id") == .string("invalid-token"))
            #expect(try nativeTestField(response, "result", "isError") == .bool(false))
            #expect(harness.backend.observations.count == 2)
        }
    }

    @Test(arguments: ["progress", "result", "error"])
    func outputFailureStopsDispatchAndNotifiesTheHostOnce(kind: String) async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.call("LongRunning", id: "pending")
            let pending = try await harness.backend.nextExecution()
            try harness.call("OutputProducer", id: "output-producer", progressToken: .string("progress"))
            let producer = try await harness.backend.nextExecution()
            let failure = NativeRuntimeError.invocation("Output pipe closed")
            harness.outputControl.failure = failure
            let failureEvents = AsyncStream<Void>.makeStream()
            var failures: [String] = []
            var shutdownTask: Task<Void, any Error>?
            harness.session.onOutputFailure = { [weak session = harness.session] error in
                failures.append(String(describing: error))
                failureEvents.continuation.yield(())
                if let session { shutdownTask = Task { try await session.shutdown() } }
            }

            switch kind {
            case "progress":
                try producer.emit("update", data: .object(["progress": .number(.int(1))]))
            case "result":
                try producer.complete(.string("Completed"))
            default:
                try producer.emit("unsupported", data: .object([:]))
                producer.finish()
            }

            var failureIterator = failureEvents.stream.makeAsyncIterator()
            #expect(await failureIterator.next(isolation: MainActor.shared) != nil)
            #expect(throws: NativeRuntimeError.self) { try harness.call("MustNotRun", id: "after-output-failure") }
            #expect(harness.backend.executions.map(\.name) == ["LongRunning", "OutputProducer"])
            let shutdown = try #require(shutdownTask)
            try await shutdown.value
            #expect(await pending.wasCancelled())
            #expect(harness.backend.shutdownCalls == 1)
            #expect(failures == [failure.description])
            harness.session.onOutputFailure = nil
        }
    }

    @Test func nativeToolErrorsRemainToolResultsWithStructuredDetails() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.call("Action", id: "failure")
            let execution = try await harness.backend.nextExecution()
            let detail: JSONValue = .object(["message": .string("Build failed"), "diagnostics": .array([.string("Missing import")])])
            try execution.emit("error", data: detail)
            execution.finish()
            let response = try await harness.nextMessage()
            #expect(try nativeTestObject(response)["error"] == nil)
            #expect(try nativeTestField(response, "result", "isError") == .bool(true))
            #expect(try nativeTestField(response, "result", "structuredContent") == detail)
        }
    }

    @Test func workspacePreparationFailureReturnsAToolErrorAndAllowsTheNextCall() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            harness.backend.executeError = NativeToolExecutionError(message: "The project does not exist")
            try harness.call("XcodeLS", id: "missing-project")
            let response = try await harness.nextMessage()
            #expect(try nativeTestObject(response)["error"] == nil)
            #expect(try nativeTestField(response, "result", "isError") == .bool(true))
            #expect(try nativeTestField(response, "result", "content") == .array([
                .object(["type": .string("text"), "text": .string("The project does not exist")]),
            ]))
            #expect(harness.backend.executions.isEmpty)

            harness.backend.executeError = nil
            try harness.call("XcodeLS", id: "existing-project")
            try await harness.backend.nextExecution().complete(.object(["items": .array([])]))
            #expect(try nativeTestField(await harness.nextMessage(), "result", "isError") == .bool(false))
        }
    }

    @Test func completedOutputDoesNotChangeTheMeaningOfAnErrorField() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.call("Action", id: "completed")
            let execution = try await harness.backend.nextExecution()
            let output: JSONValue = .object(["error": .string("A tool-specific value")])
            try execution.complete(output)
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "result", "isError") == .bool(false))
            #expect(try nativeTestField(response, "result", "structuredContent") == output)
        }
    }

    @Test(arguments: ["null", "true", "42", "[\"artifact\",2]"])
    func nonObjectNativeOutputRemainsValidMCPText(raw: String) async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.call("Action", id: "scalar")
            let execution = try await harness.backend.nextExecution()
            let output = try nativeTestJSON(Data(raw.utf8))
            try execution.complete(output)
            let response = try await harness.nextMessage()
            let result = try nativeTestField(response, "result")
            #expect(try nativeTestObject(result)["structuredContent"] == nil)
            let content = try #require(try nativeTestField(result, "content").arrayValue?.first)
            #expect(try nativeTestField(content, "text") == .string(raw))
            #expect(try nativeTestField(result, "isError") == .bool(false))
        }
    }

    @Test func eachCallGetsItsOwnArtifactsInTheSameConversation() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.call("Action", id: "first")
            let first = try await harness.backend.nextExecution()
            try first.complete(.object([:]))
            _ = try await harness.nextMessage()
            try harness.call("Action", id: "second")
            let second = try await harness.backend.nextExecution()
            try second.complete(.object([:]))
            _ = try await harness.nextMessage()
            #expect(first.context.artifactsDirectory != second.context.artifactsDirectory)
            #expect(first.context.artifactsDirectory.deletingLastPathComponent() == harness.artifactsRoot)
            #expect(second.context.artifactsDirectory.deletingLastPathComponent() == harness.artifactsRoot)
            #expect(first.context.conversationID == second.context.conversationID)
        }
    }

    @Test func invalidParametersAndUnknownToolsPreserveRequestErrors() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.request("tools/call", id: "missing-name", params: .object([:]))
            #expect(try nativeTestField(await harness.nextMessage(), "error", "code") == .number(.int(-32602)))
            try harness.request("tools/call", id: "bad-arguments", params: .object([
                "name": .string("Action"), "arguments": .array([]),
            ]))
            #expect(try nativeTestField(await harness.nextMessage(), "error", "code") == .number(.int(-32602)))
            #expect(harness.backend.executions.isEmpty)

            harness.backend.executeError = NativeRuntimeError.invalidRequest("Unknown native tool 'RemovedTool'")
            try harness.call("RemovedTool", id: "removed")
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "error", "code") == .number(.int(-32602)))
            #expect(try nativeTestField(response, "error", "message") == .string("Unknown native tool 'RemovedTool'"))
        }
    }

    @Test func unavailableNativeContractsAreProtocolErrors() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            harness.backend.listError = .unsupportedContract("Selected Xcode changed its native schema")
            try harness.request("tools/list", id: "catalog")
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "error", "code") == .number(.int(-32603)))
            #expect(try nativeTestField(response, "error", "message") == .string("Selected Xcode changed its native schema"))
        }
    }

    @Test(arguments: ["unknown-event", "missing-completion", "malformed-event"])
    func invalidNativeStreamsDoNotReportToolSuccess(scenario: String) async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.call("Action", id: scenario)
            let execution = try await harness.backend.nextExecution()
            switch scenario {
            case "unknown-event": try execution.emit("unexpected", data: .object([:]))
            case "malformed-event": execution.yield(Data(#"{"data":{}}"#.utf8))
            default: break
            }
            execution.finish()
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "id") == .string(scenario))
            #expect(try nativeTestField(response, "error", "code") == .number(.int(-32603)))
            #expect(try nativeTestObject(response)["result"] == nil)
        }
    }

    @Test func unknownMethodsUseTheJSONRPCMethodNotFoundError() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.request("unsupported/future-method", id: "unknown")
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "id") == .string("unknown"))
            #expect(try nativeTestField(response, "error", "code") == .number(.int(-32601)))
        }
    }

    @Test func requestsBeforeInitializeDoNotReachTheBackend() async throws {
        try await withNativeSession { harness in
            try harness.request("tools/list", id: "early")
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "error", "code") == .number(.int(-32602)))
            #expect(harness.backend.listCalls == 0)
            _ = try await harness.initialize()
            try harness.request("ping", id: "alive")
            #expect(try nativeTestField(await harness.nextMessage(), "result") == .object([:]))
        }
    }

    @Test func duplicateRequestIDsDoNotStartAnotherNativeOperation() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.call("Action", id: "in-use")
            let execution = try await harness.backend.nextExecution()
            try harness.call("OtherAction", id: "in-use")
            let duplicate = try await harness.nextMessage()
            #expect(try nativeTestField(duplicate, "error", "code") == .number(.int(-32600)))
            #expect(harness.backend.executions.count == 1)
            try execution.complete(.string("Original call completed"))
            #expect(try nativeTestField(await harness.nextMessage(), "result", "isError") == .bool(false))
        }
    }

    @Test func initializeAndCatalogExposeTheSameBackendOriginWithoutGuessingFakeVersions() async throws {
        try await withNativeSession { harness in
            harness.backend.origin = ["kind": .string("gui"), "processID": .number(.int(42)), "toolCancellation": .string("waitForNativeCompletion")]
            let initialized = try await harness.initialize()
            let origin = try nativeTestField(initialized, "result", "_meta", "com.lynnswap.xcode-mcpkit/origin")
            #expect(origin == .object(try #require(harness.backend.origin)))
            try harness.request("tools/list", id: "origin-catalog")
            #expect(try nativeTestField(await harness.nextMessage(), "result", "_meta", "com.lynnswap.xcode-mcpkit/origin") == origin)
            #expect(try nativeTestObject(origin)["xcodeVersion"] == nil)
        }
    }

    @Test func advisoryCancellationReturnsTheOriginalCompletionWhenNativeCancellationIsUnsupported() async throws {
        try await withNativeSession { harness in
            harness.backend.supportsToolCancellation = false
            _ = try await harness.initialize()
            try harness.call("Uncancellable", id: "wait-for-native")
            let execution = try await harness.backend.nextExecution()
            try harness.notification("notifications/cancelled", params: .object(["requestId": .string("wait-for-native")]))
            await Task.yield()
            try execution.complete(.string("Native completed"))
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "id") == .string("wait-for-native"))
            #expect(try nativeTestField(response, "result", "isError") == .bool(false))
            #expect(!(await execution.wasCancelled()))
        }
    }

    @Test(arguments: [false, true])
    func cancellationBeforeDispatchDoesNotStartTheToolOrCreateArtifacts(supportsCancellation: Bool) async throws {
        try await withNativeSession { harness in
            harness.backend.supportsToolCancellation = supportsCancellation
            _ = try await harness.initialize()
            // STDIO may deliver both messages in one chunk before the request Task runs.
            try harness.call("QueuedAction", id: "cancel-before-dispatch")
            try harness.notification("notifications/cancelled", params: .object([
                "requestId": .string("cancel-before-dispatch"),
            ]))
            let cancelled = try await harness.nextMessage()
            #expect(try nativeTestField(cancelled, "id") == .string("cancel-before-dispatch"))
            #expect(try nativeTestField(cancelled, "error", "code") == .number(.int(-32800)))
            #expect(harness.backend.executions.isEmpty)
            #expect(harness.backend.observations.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: harness.artifactsRoot.path))

            try harness.request("ping", id: "after-cancellation")
            #expect(try nativeTestField(await harness.nextMessage(), "result") == .object([:]))
            try harness.call("ReplacementAction", id: "cancel-before-dispatch")
            let replacement = try await harness.backend.nextExecution()
            #expect(replacement.name == "ReplacementAction")
            #expect(harness.backend.executions.count == 1)
            try replacement.complete(.string("Still usable"))
            let completed = try await harness.nextMessage()
            #expect(try nativeTestField(completed, "id") == .string("cancel-before-dispatch"))
            #expect(try nativeTestField(completed, "result", "isError") == .bool(false))
        }
    }

    @Test func cancellationOnlyEndsTheMatchingRequestAndAllowsIDReuse() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.call("First", id: "cancel-me")
            let cancelled = try await harness.backend.nextExecution()
            try harness.call("Second", id: "keep-me")
            let retained = try await harness.backend.nextExecution()
            try harness.notification("notifications/cancelled", params: .object(["requestId": .string("cancel-me")]))
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "id") == .string("cancel-me"))
            #expect(try nativeTestField(response, "error", "code") == .number(.int(-32800)))
            #expect(await cancelled.wasCancelled())
            try retained.complete(.string("Still running"))
            #expect(try nativeTestField(await harness.nextMessage(), "id") == .string("keep-me"))

            try harness.call("Replacement", id: "cancel-me")
            let replacement = try await harness.backend.nextExecution()
            try replacement.complete(.object([:]))
            #expect(try nativeTestField(await harness.nextMessage(), "result", "isError") == .bool(false))
        }
    }

    @Test func cancellationPreservesANativeCompletionThatAlreadyArrived() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.call("Open", id: "completed-before-cancellation")
            let execution = try await harness.backend.nextExecution()
            let output: JSONValue = .object(["workspaceIdentifier": .string("owned-workspace")])
            try execution.complete(output)
            try harness.notification("notifications/cancelled", params: .object([
                "requestId": .string("completed-before-cancellation"),
            ]))

            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "error", "code") == .number(.int(-32800)))
            #expect(harness.backend.observations.map(\.event) == [
                .object(["type": .string("completed"), "data": output]),
            ])
        }
    }

    @Test func stringAndNumericRequestIDsRemainIndependent() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.request("tools/call", id: 7, params: .object(["name": .string("Numeric")]))
            let numeric = try await harness.backend.nextExecution()
            try harness.call("String", id: "7")
            let string = try await harness.backend.nextExecution()
            try harness.notification("notifications/cancelled", params: .object(["requestId": .number(.int(7))]))
            #expect(try nativeTestField(await harness.nextMessage(), "id") == .number(.int(7)))
            #expect(await numeric.wasCancelled())
            try string.complete(.object([:]))
            #expect(try nativeTestField(await harness.nextMessage(), "id") == .string("7"))
        }
    }

    @Test func shutdownCancelsStreamsBeforeClosingTheBackend() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.call("LongRunning", id: "pending")
            let pending = try await harness.backend.nextExecution()
            try await harness.session.shutdown()
            #expect(await pending.wasCancelled())
            #expect(harness.backend.shutdownCalls == 1)
            #expect(try nativeTestField(await harness.nextMessage(), "error", "code") == .number(.int(-32800)))
            try harness.request("ping", id: "after-shutdown")
            #expect(try nativeTestField(await harness.nextMessage(), "error", "code") == .number(.int(-32000)))
        }
    }

    @Test func shutdownPropagatesBackendCleanupFailures() async throws {
        try await withNativeSession { harness in
            harness.backend.shutdownError = .invocation("Could not close owned workspace")
            await #expect(throws: NativeRuntimeError.self) { try await harness.session.shutdown() }
            harness.backend.shutdownError = nil
        }
    }

    @Test func malformedRequestObjectsReceiveAnInvalidRequestResponse() async throws {
        try await withNativeSession { harness in
            try harness.session.receive(Data(#"{"jsonrpc":"2.0","id":"bad","method":42}"#.utf8))
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "id") == .string("bad"))
            #expect(try nativeTestField(response, "error", "code") == .number(.int(-32600)))
            try harness.session.receive(Data("[]".utf8))
            let nonObject = try await harness.nextMessage()
            #expect(try nativeTestField(nonObject, "id") == .null)
            #expect(try nativeTestField(nonObject, "error", "code") == .number(.int(-32600)))
        }
    }

    @Test func malformedJSONReturnsAParseErrorAndKeepsTheSessionUsable() async throws {
        try await withNativeSession { harness in
            try harness.session.receive(Data(#"{"jsonrpc":"2.0","method":"initialize""#.utf8))
            let parseError = try await harness.nextMessage()
            #expect(try nativeTestField(parseError, "id") == .null)
            #expect(try nativeTestField(parseError, "error", "code") == .number(.int(-32700)))
            _ = try await harness.initialize()
            try harness.request("ping", id: "still-usable")
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "id") == .string("still-usable"))
            #expect(try nativeTestField(response, "result") == .object([:]))
        }
    }

    @Test(arguments: [
        #"{"id":"invalid","method":"tools/call","params":{"name":"Action"}}"#,
        #"{"jsonrpc":"1.0","id":"invalid","method":"tools/call","params":{"name":"Action"}}"#,
        #"{"jsonrpc":2,"id":"invalid","method":"tools/call","params":{"name":"Action"}}"#,
        #"{"jsonrpc":true,"id":"invalid","method":"tools/call","params":{"name":"Action"}}"#,
        #"{"jsonrpc":"2.0","id":true,"method":"tools/call","params":{"name":"Action"}}"#,
        #"{"jsonrpc":"2.0","id":false,"method":"tools/call","params":{"name":"Action"}}"#,
        #"{"jsonrpc":"2.0","id":[],"method":"tools/call","params":{"name":"Action"}}"#,
        #"{"jsonrpc":"2.0","id":{},"method":"tools/call","params":{"name":"Action"}}"#,
        #"{"jsonrpc":"2.0","id":null,"method":"tools/call","params":{"name":"Action"}}"#,
    ])
    func invalidEnvelopesCannotStartNativeOperations(raw: String) async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.session.receive(Data(raw.utf8))
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "error", "code") == .number(.int(-32600)))
            #expect(try nativeTestField(response, "id") == (raw.contains(#""id":"invalid""#) ? .string("invalid") : .null))
            #expect(harness.backend.executions.isEmpty)
            #expect(harness.backend.observations.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: harness.artifactsRoot.path))
            try harness.request("ping", id: "after-invalid-envelope")
            #expect(try nativeTestField(await harness.nextMessage(), "result") == .object([:]))
        }
    }

    @Test func invalidInitializeEnvelopeCannotInitializeTheSession() async throws {
        try await withNativeSession { harness in
            try harness.session.receive(Data(#"{"id":"invalid-initialize","method":"initialize"}"#.utf8))
            #expect(try nativeTestField(await harness.nextMessage(), "error", "code") == .number(.int(-32600)))
            try harness.request("tools/list", id: "still-uninitialized")
            #expect(try nativeTestField(await harness.nextMessage(), "error", "code") == .number(.int(-32602)))
            #expect(harness.backend.listCalls == 0)
            _ = try await harness.initialize()
            try harness.request("tools/list", id: "initialized-catalog")
            #expect(try nativeTestField(await harness.nextMessage(), "result", "tools") == .array([]))
            #expect(harness.backend.listCalls == 1)
        }
    }

    @Test(arguments: [false, true])
    func booleanCancellationIDsDoNotAliasNumericRequests(boolean: Bool) async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            let identifier: Int64 = boolean ? 1 : 0
            try harness.request("tools/call", id: identifier, params: .object(["name": .string("MustComplete")]))
            let execution = try await harness.backend.nextExecution()
            try harness.notification("notifications/cancelled", params: .object(["requestId": .bool(boolean)]))
            try execution.complete(.string("Completed"))
            let response = try await harness.nextMessage()
            #expect(try nativeTestField(response, "id") == .number(.int(identifier)))
            #expect(try nativeTestField(response, "result", "isError") == .bool(false))
        }
    }

    @Test func cancellationWithAnInvalidEnvelopeCannotCancelAnActiveRequest() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            try harness.call("MustComplete", id: "active")
            let execution = try await harness.backend.nextExecution()
            try harness.session.receive(Data(#"{"jsonrpc":"1.0","method":"notifications/cancelled","params":{"requestId":"active"}}"#.utf8))
            #expect(try nativeTestField(await harness.nextMessage(), "error", "code") == .number(.int(-32600)))
            try execution.complete(.string("Completed"))
            #expect(try nativeTestField(await harness.nextMessage(), "result", "isError") == .bool(false))
        }
    }

    @Test(arguments: [false, true], ["{malformed", "C", "Content-", "Content-Lengt", "[]", "true", "null", "42", #""scalar""#])
    func invalidFramesAndAValidRequestInTheSameChunkAreHandledSeparately(contentLength: Bool, raw: String) async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            let badFrame = contentLength ? "Content-Length: \(raw.utf8.count)\r\n\r\n\(raw)" : raw + "\n"
            let valid = #"{"jsonrpc":"2.0","id":"after-frame-error","method":"ping"}"#
            let framing = try harness.receiveChunk(Data((badFrame + valid + "\n").utf8))
            #expect(framing.messages == [Data(raw.utf8), Data(valid.utf8)])
            #expect(framing.bufferedByteCount == 0)
            let error = try await harness.nextMessage()
            #expect(try nativeTestField(error, "id") == .null)
            #expect(try nativeTestField(error, "error", "code") == .number(.int(["{malformed", "C", "Content-", "Content-Lengt"].contains(raw) ? -32700 : -32600)))
            let validResponse = try await harness.nextMessage()
            #expect(try nativeTestField(validResponse, "id") == .string("after-frame-error"))
            #expect(try nativeTestField(validResponse, "result") == .object([:]))
            #expect(harness.backend.executions.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: harness.artifactsRoot.path))
        }
    }

    @Test func aPartialInvalidLineCannotExecuteItsValidObjectPrefix() async throws {
        try await withNativeSession { harness in
            _ = try await harness.initialize()
            let raw = #"{"jsonrpc":"2.0","id":"never-execute","method":"tools/call","params":{"name":"DoNotExecute"}} trailing garbage"#
            let partial = try harness.receiveChunk(Data(raw.utf8))
            #expect(partial.messages.isEmpty)
            #expect(partial.bufferedByteCount == raw.utf8.count)
            #expect(harness.backend.executions.isEmpty)
            let valid = #"{"jsonrpc":"2.0","id":"after-delimiter","method":"ping"}"#
            let completed = try harness.receiveChunk(Data(("\n" + valid + "\n").utf8))
            #expect(completed.messages == [Data(raw.utf8), Data(valid.utf8)])
            #expect(try nativeTestField(await harness.nextMessage(), "error", "code") == .number(.int(-32700)))
            #expect(try nativeTestField(await harness.nextMessage(), "id") == .string("after-delimiter"))
            #expect(harness.backend.executions.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: harness.artifactsRoot.path))
        }
    }
}

@MainActor
private func withNativeSession(_ body: @MainActor (NativeSessionHarness) async throws -> Void) async throws {
    let harness = NativeSessionHarness()
    defer { try? FileManager.default.removeItem(at: harness.artifactsRoot) }
    do {
        try await body(harness)
        try await harness.session.shutdown()
    } catch {
        try? await harness.session.shutdown()
        throw error
    }
}

@MainActor
private final class NativeSessionHarness {
    let backend = NativeSessionBackendProbe()
    let artifactsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("NativeMCPSessionTests-\(UUID().uuidString)", isDirectory: true)
    let session: NativeMCPSession
    let outputControl: NativeSessionOutputControl
    private let framer = StdioFramer(mode: .delimitedMessages)
    private var outputIterator: AsyncStream<Data>.Iterator

    init() {
        let output = AsyncStream<Data>.makeStream()
        let control = NativeSessionOutputControl()
        outputControl = control
        outputIterator = output.stream.makeAsyncIterator()
        session = NativeMCPSession(backend: backend, artifactsRoot: artifactsRoot) { data in
            if let failure = control.failure { throw failure }
            output.continuation.yield(data)
        }
    }

    func initialize(clientInfo: [String: JSONValue] = ["name": .string("Native Runtime Tests"), "version": .string("1")]) async throws -> JSONValue {
        try request("initialize", id: "initialize", params: .object([
            "protocolVersion": .string(MCPProtocolVersion.current),
            "capabilities": .object([:]), "clientInfo": .object(clientInfo),
        ]))
        return try await nextMessage()
    }

    func request(_ method: String, id: String, params: JSONValue? = nil) throws {
        try session.receive(JSONRPC.Wire.data(from: JSONRPC.Wire.requestObject(id: id, method: method, params: params)))
    }

    func request(_ method: String, id: Int64, params: JSONValue? = nil) throws {
        try session.receive(JSONRPC.Wire.data(from: JSONRPC.Wire.requestObject(id: id, method: method, params: params)))
    }

    func notification(_ method: String, params: JSONValue? = nil) throws {
        try session.receive(JSONRPC.Wire.data(from: JSONRPC.Wire.notificationObject(method: method, params: params)))
    }

    func receiveChunk(_ data: Data) throws -> StdioFramer.AppendResult {
        let result = framer.append(data)
        #expect(result.protocolViolation == nil)
        for message in result.messages { try session.receive(message) }
        return result
    }

    func call(_ name: String, id: String, arguments: [String: JSONValue] = [:], progressToken: JSONValue? = nil) throws {
        var params: [String: JSONValue] = ["name": .string(name), "arguments": .object(arguments)]
        if let progressToken { params["_meta"] = .object(["progressToken": progressToken]) }
        try request("tools/call", id: id, params: .object(params))
    }

    func nextMessage() async throws -> JSONValue {
        var iterator = outputIterator
        let data = await iterator.next(isolation: MainActor.shared)
        outputIterator = iterator
        return try nativeTestJSON(#require(data))
    }
}

@MainActor
private final class NativeSessionOutputControl {
    var failure: NativeRuntimeError?
}

@MainActor
private final class NativeSessionBackendProbe: NativeToolBackend {
    struct Observation {
        let toolName: String
        let arguments: [String: JSONValue]
        let event: JSONValue
    }

    var origin: [String: JSONValue]?
    var supportsToolCancellation = true
    var tools: [NativeTool] = []
    var resultFormat = NativeToolResultFormat.actionValue
    var initializeError: NativeRuntimeError?
    var listError: NativeRuntimeError?
    var executeError: (any Error)?
    var shutdownError: NativeRuntimeError?
    private(set) var executions: [NativeSessionExecution] = []
    private(set) var observations: [Observation] = []
    private(set) var initializationContexts: [NativeSessionContext] = []
    private(set) var listCalls = 0
    private(set) var shutdownCalls = 0
    private let executionEvents = AsyncStream<NativeSessionExecution>.makeStream()
    private var executionIterator: AsyncStream<NativeSessionExecution>.Iterator

    init() { executionIterator = executionEvents.stream.makeAsyncIterator() }

    func initialize(context: NativeSessionContext) async throws {
        initializationContexts.append(context)
        if let initializeError { throw initializeError }
    }

    func listTools() async throws -> [NativeTool] {
        listCalls += 1
        if let listError { throw listError }
        return tools
    }

    func execute(_ name: String, arguments: [String: JSONValue], context: NativeToolContext) async throws -> AsyncStream<Data> {
        if let executeError { throw executeError }
        context.didDispatch()
        let stream = AsyncStream<Data>.makeStream()
        let termination = AsyncStream<Bool>.makeStream()
        stream.continuation.onTermination = { reason in
            switch reason {
            case .cancelled: termination.continuation.yield(true)
            case .finished: termination.continuation.yield(false)
            @unknown default: termination.continuation.yield(false)
            }
            termination.continuation.finish()
        }
        let execution = NativeSessionExecution(name: name, arguments: arguments, context: context,
                                              continuation: stream.continuation, termination: termination.stream)
        executions.append(execution)
        executionEvents.continuation.yield(execution)
        return stream.stream
    }

    func observe(toolName: String, arguments: [String: JSONValue], event: JSONValue) {
        observations.append(Observation(toolName: toolName, arguments: arguments, event: event))
    }

    func shutdown() async throws {
        shutdownCalls += 1
        if let shutdownError { throw shutdownError }
    }

    func nextExecution() async throws -> NativeSessionExecution {
        var iterator = executionIterator
        let next = await iterator.next(isolation: MainActor.shared)
        executionIterator = iterator
        return try #require(next)
    }
}

@MainActor
private final class NativeSessionExecution {
    let name: String
    let arguments: [String: JSONValue]
    let context: NativeToolContext
    private let continuation: AsyncStream<Data>.Continuation
    private let termination: AsyncStream<Bool>

    init(name: String, arguments: [String: JSONValue], context: NativeToolContext,
         continuation: AsyncStream<Data>.Continuation, termination: AsyncStream<Bool>) {
        self.name = name
        self.arguments = arguments
        self.context = context
        self.continuation = continuation
        self.termination = termination
    }

    func emit(_ type: String, data: JSONValue) throws {
        yield(try JSONRPC.Wire.data(from: ["type": type, "data": data.foundationObject]))
    }

    func yield(_ data: Data) { continuation.yield(data) }
    func finish() { continuation.finish() }

    func complete(_ data: JSONValue) throws {
        try emit("completed", data: data)
        finish()
    }

    func wasCancelled() async -> Bool {
        var iterator = termination.makeAsyncIterator()
        return await iterator.next(isolation: MainActor.shared) == true
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case .array(let values) = self else { return nil }
        return values
    }
}
