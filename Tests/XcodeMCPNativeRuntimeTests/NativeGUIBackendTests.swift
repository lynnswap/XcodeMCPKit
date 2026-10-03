import Foundation
import Testing
import XcodeMCPNativeRuntime
import XcodeMCPWire

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct NativeGUIBackendTests {
    @Test func initializesTheGUIWithTheClientIdentityAndTheActualHostProcess() async throws {
        try await withGUIBackend { fixture in
            #expect(fixture.transport.connectorProcessIdentifiers == [fixture.processIdentifier])
            #expect(fixture.transport.connectorDeveloperDirectories == [fixture.installation.developerDirectory])
            #expect(fixture.transport.activationCount == 1)
            #expect(fixture.transport.oneWayMessages.count == 1)
            let message = try nativeTestJSON(#require(fixture.transport.oneWayMessages.first))
            let context = try nativeTestField(message, "initializeSession", "context")
            #expect(try nativeTestField(context, "sessionID") == .string("client-conversation"))
            #expect(try nativeTestField(context, "clientInfo", "name") == .string("Original MCP Client"))
            #expect(try nativeTestField(context, "clientInfo", "version") == .string("17.4"))
            #expect(try nativeTestField(context, "clientInfo", "binaryPath") == .string(#require(Bundle.main.executableURL).path))
            #expect(try nativeTestField(context, "clientInfo", "binaryPID") == .number(.int(Int64(getpid()))))
            #expect(fixture.backend.resultFormat == .mcpResult)
        }
    }

    @Test func detachedConsumersDoNotAbandonUncancellableNativeOperations() async throws {
        try await withGUIBackend { fixture in
            fixture.transport.supportsToolCancellation = false
            _ = try await fixture.listTools([Self.unscopedTool])
            #expect(!fixture.backend.supportsToolCancellation)
            #expect(fixture.backend.origin?["toolCancellation"] == .string("waitForNativeCompletion"))
            let stream = try await fixture.backend.execute("NativeSearch", arguments: [:], context: fixture.toolContext)
            let request = try await fixture.transport.nextRequest()
            let consumer = Task { @MainActor in for await _ in stream {} }
            consumer.cancel()
            await consumer.value
            #expect(fixture.transport.oneWayMessages.count == 1)
            #expect(fixture.transport.invalidationCount == 0)
            try request.respond(.object(["content": .array([]), "isError": .bool(false)]))
            await Task.yield()
            try await fixture.backend.shutdown()
            #expect(fixture.transport.invalidationCount == 1)
        }
    }

    @Test func shutdownReleasesUncancellableCallsWithoutSendingAnUnsupportedMessage() async throws {
        try await withGUIBackend { fixture in
            fixture.transport.supportsToolCancellation = false
            _ = try await fixture.listTools([Self.unscopedTool])
            let stream = try await fixture.backend.execute("NativeSearch", arguments: [:], context: fixture.toolContext)
            _ = try await fixture.transport.nextRequest()
            try await fixture.backend.shutdown()
            #expect(fixture.transport.oneWayMessages.count == 1)
            #expect(fixture.transport.invalidationCount == 1)
            var iterator = stream.makeAsyncIterator()
            #expect(await iterator.next(isolation: MainActor.shared) == nil)
        }
    }

    @Test(arguments: ["call", "catalog"])
    func sessionShutdownInterruptsPendingGUIRequestsWithoutNativeReplies(requestKind: String) async throws {
        try await withGUIBackend(initialize: false) { fixture in
            fixture.transport.supportsToolCancellation = false
            let output = AsyncStream<Data>.makeStream()
            var responses = output.stream.makeAsyncIterator()
            let session = NativeMCPSession(backend: fixture.backend,
                artifactsRoot: fixture.directory.appendingPathComponent("artifacts"),
                output: { output.continuation.yield($0) })
            try session.receive(guiBackendData(.object([
                "jsonrpc": .string("2.0"), "id": .string("initialize"), "method": .string("initialize"),
                "params": .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
                    "clientInfo": .object(fixture.sessionContext.clientInfo)]),
            ])))
            _ = try #require(await responses.next(isolation: MainActor.shared))
            _ = try await fixture.listTools([Self.unscopedTool])
            if requestKind == "call" {
                try session.receive(guiBackendData(.object([
                    "jsonrpc": .string("2.0"), "id": .string("pending-native-request"), "method": .string("tools/call"),
                    "params": .object(["name": .string("NativeSearch"), "arguments": .object(["query": .string("read")])]),
                ])))
            } else {
                try session.receive(guiBackendData(.object([
                    "jsonrpc": .string("2.0"), "id": .string("pending-native-request"), "method": .string("tools/list"),
                ])))
            }
            let call = try await fixture.transport.nextRequest()
            if requestKind == "call" {
                #expect(try nativeTestField(nativeTestJSON(call.message), "callTool", "name") == .string("NativeSearch"))
                #expect(fixture.backend.pendingInvocationCount == 1)
            } else {
                #expect(try nativeTestJSON(call.message) == .object(["listTools": .object([:])]))
            }
            try await session.shutdown()
            #expect(fixture.transport.invalidationCount == 1)
            #expect(fixture.transport.oneWayMessages.count == 1)
            #expect(fixture.backend.pendingInvocationCount == 0)
            #expect(!fixture.connection.isConnected)
            let cancelled = try nativeTestJSON(#require(await responses.next(isolation: MainActor.shared)))
            #expect(try nativeTestField(cancelled, "error", "code") == .number(.int(-32800)))
            try call.respond(requestKind == "call"
                ? .object(["content": .array([]), "isError": .bool(false)])
                : .object(["toolSchemas": .array([Self.unscopedTool])]))
            try await session.shutdown()
            #expect(fixture.transport.invalidationCount == 1)
        }
    }

    @Test func cancelledSessionInitializationPreservesItsTransportCleanupFailure() async throws {
        try await withGUIBackend(initialize: false, connectsImmediately: false) { fixture in
            fixture.transport.cleanupError = .cleanup
            let output = AsyncStream<Data>.makeStream()
            var responses = output.stream.makeAsyncIterator()
            let session = NativeMCPSession(backend: fixture.backend,
                artifactsRoot: fixture.directory.appendingPathComponent("artifacts"),
                output: { output.continuation.yield($0) })
            try session.receive(guiBackendData(.object([
                "jsonrpc": .string("2.0"), "id": .string("initialization-cleanup-failure"), "method": .string("initialize"),
                "params": .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
                    "clientInfo": .object(fixture.sessionContext.clientInfo)]),
            ])))
            try await fixture.transport.nextActivation()
            try session.receive(guiBackendData(.object([
                "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
                "params": .object(["requestId": .string("initialization-cleanup-failure")]),
            ])))
            let cancelled = try nativeTestJSON(#require(await responses.next(isolation: MainActor.shared)))
            #expect(try nativeTestField(cancelled, "error", "code") == .number(.int(-32800)))
            guard case .string(let message) = try nativeTestField(cancelled, "error", "message") else {
                Issue.record("The cancelled initialization must retain its cleanup diagnostic")
                return
            }
            #expect(message.contains("Request cancelled"))
            #expect(message.contains(GUIBackendTestError.cleanup.description))
            #expect(fixture.transport.invalidationCount == 1)
            #expect(fixture.transport.oneWayMessages.isEmpty)
            try await session.shutdown()
            #expect(fixture.transport.invalidationCount == 1)
        }
    }

    @Test func refreshesTheNativeCatalogAndPreservesSelectorOptionality() async throws {
        try await withGUIBackend { fixture in
            let first = try await fixture.listTools([
                Self.optionalWorkspaceTool, Self.requiredWorkspaceTool, Self.unscopedTool,
            ])
            #expect(first.map(\.name) == ["InspectWorkspace", "MutateWorkspace", "NativeSearch"])
            let optional = try #require(first.first { $0.name == "InspectWorkspace" })
            let required = try #require(first.first { $0.name == "MutateWorkspace" })
            let unscoped = try #require(first.first { $0.name == "NativeSearch" })
            #expect(optional.workspaceScoped)
            #expect(required.workspaceScoped)
            #expect(!unscoped.workspaceScoped)
            #expect(try nativeTestField(optional.descriptor, "inputSchema", "required") == .array([.string("query")]))
            #expect(try nativeTestField(required.descriptor, "inputSchema", "required") == .array([.string("query"), .string("workspaceIdentifier")]))
            let optionalProperties = try nativeTestObject(nativeTestField(optional.descriptor, "inputSchema", "properties"))
            #expect(optionalProperties["tabIdentifier"] == nil)
            #expect(try nativeTestField(optional.descriptor, "inputSchema", "properties", "workspaceIdentifier", "type") == .string("string"))
            #expect(try nativeTestObject(nativeTestField(unscoped.descriptor, "inputSchema", "properties"))["workspaceIdentifier"] == nil)

            let changedSchema = try nativeTestJSON(Data(#"{"name":"NewNativeTool","inputSchema":{"properties":[]}}"#.utf8))
            let refreshed = try await fixture.listTools([changedSchema])
            #expect(refreshed.map(\.name) == ["NewNativeTool"])
            let removed = Task { @MainActor in
                try await fixture.backend.execute("MutateWorkspace", arguments: ["query": .string("edit")], context: fixture.toolContext)
            }
            defer { removed.cancel() }
            let refresh = try await fixture.transport.nextRequest()
            #expect(try nativeTestJSON(refresh.message) == .object(["listTools": .object([:])]))
            try refresh.respond(.object(["toolSchemas": .array([changedSchema])]))
            await #expect(throws: NativeRuntimeError.self) { try await removed.value }
            #expect(fixture.transport.requestMessages.count == 3)
        }
    }

    @Test func correlatesNativeProgressAndPreservesTheCompleteNativeResult() async throws {
        try await withGUIBackend { fixture in
            _ = try await fixture.listTools([Self.unscopedTool])
            let arguments: [String: JSONValue] = ["query": .string("value"), "nativeExtra": .object(["enabled": .bool(true)])]
            let stream = try await fixture.backend.execute("NativeSearch", arguments: arguments, context: fixture.toolContext)
            let request = try await fixture.transport.nextRequest()
            let call = try nativeTestField(nativeTestJSON(request.message), "callTool")
            #expect(try nativeTestField(call, "name") == .string("NativeSearch"))
            #expect(try nativeTestField(call, "arguments") == .object(arguments))
            let token = try nativeTestField(call, "progressToken")
            let progress: [String: JSONValue] = ["progress": .number(.int(2)), "total": .number(.int(5)), "message": .string("Native progress")]
            try fixture.transport.receive(.object(["progressUpdate": .object(["_0": .object([
                "token": .string(UUID().uuidString), "message": .string("Foreign progress"),
            ])])]))
            try fixture.transport.receive(.object(["progressUpdate": .object(["_0": .object(progress.merging(["token": token]) { _, new in new })])]))
            var events = stream.makeAsyncIterator()
            let update = try nativeTestJSON(#require(await events.next(isolation: MainActor.shared)))
            #expect(update == .object(["type": .string("update"), "data": .object(progress)]))

            let result: JSONValue = .object([
                "content": .array([.object(["type": .string("text"), "text": .string("Opaque native failure")])]),
                "structuredContent": .object(["futureNativeField": .array([.null, .number(.int(7))])]),
                "isError": .bool(true), "_meta": .object(["owner": .string("Xcode")]),
            ])
            try request.respond(result)
            let completed = try nativeTestJSON(#require(await events.next(isolation: MainActor.shared)))
            #expect(completed == .object(["type": .string("completed"), "data": result]))
            #expect(await events.next(isolation: MainActor.shared) == nil)
        }
    }

    @Test func resolvesAnAbsoluteWorkspacePathBeforeDispatchingTheNativeMutation() async throws {
        try await withGUIBackend { fixture in
            _ = try await fixture.listTools([Self.requiredWorkspaceTool])
            let workspace = fixture.directory.appendingPathComponent("Project with spaces, name.xcworkspace").path
            let arguments: [String: JSONValue] = [
                "query": .string("edit"), "workspaceIdentifier": .string(workspace), "nativeExtra": .bool(true),
            ]
            let execution = Task { @MainActor in
                try await fixture.backend.execute("MutateWorkspace", arguments: arguments, context: fixture.toolContext)
            }
            defer { execution.cancel() }
            let windows = try await fixture.transport.nextRequest()
            #expect(try nativeTestField(nativeTestJSON(windows.message), "callTool", "name") == .string("XcodeListWindows"))
            #expect(try nativeTestField(nativeTestJSON(windows.message), "callTool", "arguments") == .object([:]))
            try windows.respond(.object(["structuredContent": .object([
                "message": .string("Available Windows:\n  * tabIdentifier: tab-native-7, workspacePath: \(workspace)\n"),
            ]), "isError": .bool(false)]))
            let stream = try await execution.value
            let mutation = try await fixture.transport.nextRequest()
            #expect(try nativeTestField(nativeTestJSON(mutation.message), "callTool", "name") == .string("MutateWorkspace"))
            #expect(try nativeTestField(nativeTestJSON(mutation.message), "callTool", "arguments") == .object([
                "query": .string("edit"), "tabIdentifier": .string("tab-native-7"), "nativeExtra": .bool(true),
            ]))
            try mutation.respond(.object(["content": .array([]), "isError": .bool(false)]))
            for await _ in stream {}
        }
    }

    @Test func forwardsOpaqueSelectorsAndAllowsAnOmittedOptionalSelector() async throws {
        try await withGUIBackend { fixture in
            _ = try await fixture.listTools([Self.optionalWorkspaceTool])
            for selector in ["native-tab-token", nil] as [String?] {
                var arguments: [String: JSONValue] = ["query": .string("inspect")]
                if let selector { arguments["workspaceIdentifier"] = .string(selector) }
                let stream = try await fixture.backend.execute("InspectWorkspace", arguments: arguments, context: fixture.toolContext)
                let request = try await fixture.transport.nextRequest()
                #expect(try nativeTestField(nativeTestJSON(request.message), "callTool", "name") == .string("InspectWorkspace"))
                let receivedArguments = try nativeTestObject(nativeTestField(nativeTestJSON(request.message), "callTool", "arguments"))
                #expect(receivedArguments["query"] == .string("inspect"))
                #expect(receivedArguments["workspaceIdentifier"] == nil)
                #expect(receivedArguments["tabIdentifier"] == selector.map(JSONValue.string))
                try request.respond(.object(["content": .array([]), "isError": .bool(false)]))
                for await _ in stream {}
            }
            #expect(fixture.transport.requestMessages.count == 3)
        }
    }

    @Test func refusesAnAmbiguousWorkspacePathBeforeSendingTheMutation() async throws {
        try await withGUIBackend { fixture in
            _ = try await fixture.listTools([Self.requiredWorkspaceTool])
            let workspace = fixture.directory.appendingPathComponent("Shared.xcodeproj").path
            let execution = Task { @MainActor in
                try await fixture.backend.execute("MutateWorkspace", arguments: [
                    "query": .string("edit"), "workspaceIdentifier": .string(workspace),
                ], context: fixture.toolContext)
            }
            defer { execution.cancel() }
            let windows = try await fixture.transport.nextRequest()
            #expect(try nativeTestField(nativeTestJSON(windows.message), "callTool", "name") == .string("XcodeListWindows"))
            let message: JSONValue = .object(["message": .string("* tabIdentifier: tab-one, workspacePath: \(workspace)\n* tabIdentifier: tab-two, workspacePath: \(workspace)")])
            let text = String(decoding: try guiBackendData(message), as: UTF8.self)
            try windows.respond(.object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])]))
            var events = try await execution.value.makeAsyncIterator()
            let failure = try nativeTestJSON(#require(await events.next(isolation: MainActor.shared)))
            #expect(try nativeTestField(failure, "type") == .string("error"))
            guard case .string(let message) = try nativeTestField(failure, "data") else {
                Issue.record("Expected the workspace-selection failure")
                return
            }
            #expect(message.contains("Multiple GUI tabs own"))
            #expect(message.contains("tab-one, tab-two"))
            #expect(fixture.transport.requestMessages.count == 2)
        }
    }

    @Test(arguments: [false, true])
    func cancelledStreamsSendTheMatchingNativeCancellation(untilDisconnect: Bool) async throws {
        try await withGUIBackend { fixture in
            _ = try await fixture.listTools([Self.unscopedTool])
            let stream = try await fixture.backend.execute("NativeSearch", arguments: ["query": .string("run")], context: fixture.toolContext)
            let consumer = Task { @MainActor in for await _ in stream {} }
            defer { consumer.cancel() }
            let request = try await fixture.transport.nextRequest()
            let call = try nativeTestField(nativeTestJSON(request.message), "callTool")
            let token = try nativeTestField(call, "progressToken")
            consumer.cancel()
            let cancellation = try nativeTestJSON(await fixture.transport.nextOneWay())
            #expect(cancellation == .object(["cancelToolCall": .object([
                "name": .string("NativeSearch"), "progressToken": token,
            ])]))
            #expect(fixture.connection.isConnected)
            #expect(fixture.transport.invalidationCount == 0)
            if untilDisconnect {
                fixture.transport.disconnect()
            } else {
                // A separate catalog request still completes while Xcode owns the cancelled action.
                _ = try await fixture.listTools([Self.unscopedTool])
                try request.respond(.object(["content": .array([]), "isError": .bool(false)]))
            }
            await consumer.value
            try await fixture.backend.shutdown()
            #expect(fixture.transport.invalidationCount == 1)
        }
    }

    @Test func cancellationAndCleanupFailuresSurviveShutdownAndRepeatedShutdown() async throws {
        try await withGUIBackend(expectedShutdownError: .cleanup) { fixture in
            _ = try await fixture.listTools([Self.unscopedTool])
            let stream = try await fixture.backend.execute("NativeSearch", arguments: ["query": .string("run")], context: fixture.toolContext)
            let consumer = Task { @MainActor in for await _ in stream {} }
            defer { consumer.cancel() }
            _ = try await fixture.transport.nextRequest()
            let catalog = Task { @MainActor in try await fixture.backend.listTools() }
            defer { catalog.cancel() }
            _ = try await fixture.transport.nextRequest()
            fixture.transport.oneWayError = .cancellation
            fixture.transport.cleanupError = .cleanup
            consumer.cancel()
            let cancellation = try nativeTestJSON(await fixture.transport.nextOneWay())
            #expect(try nativeTestField(cancellation, "cancelToolCall", "name") == .string("NativeSearch"))
            do {
                _ = try await catalog.value
                Issue.record("A pending catalog request succeeded after failed native cancellation")
            } catch let error as NativeRuntimeError {
                #expect(error.description.contains(GUIBackendTestError.cancellation.description))
                #expect(error.description.contains(GUIBackendTestError.cleanup.description))
            }
            let termination = try #require(fixture.connection.terminationError)
            #expect(String(describing: termination).contains(GUIBackendTestError.cancellation.description))
            #expect(String(describing: termination).contains(GUIBackendTestError.cleanup.description))
            await consumer.value
            await #expect(throws: GUIBackendTestError.cleanup) { try await fixture.backend.shutdown() }
            await #expect(throws: GUIBackendTestError.cleanup) { try await fixture.backend.shutdown() }
            #expect(fixture.transport.invalidationCount == 1)
        }
    }

    @Test func shutdownDuringConnectionStartupClosesOnceAndSendsNoInitialization() async throws {
        try await withGUIBackend(initialize: false, connectsImmediately: false) { fixture in
            let initialization = Task { @MainActor in try await fixture.backend.initialize(context: fixture.sessionContext) }
            defer { initialization.cancel() }
            try await fixture.transport.nextActivation()
            try await fixture.backend.shutdown()
            await #expect(throws: CancellationError.self) { try await initialization.value }
            #expect(!fixture.connection.isConnected)
            #expect(fixture.transport.invalidationCount == 1)
            #expect(fixture.transport.oneWayMessages.isEmpty)
            fixture.transport.connect()
            #expect(!fixture.connection.isConnected)
            try await fixture.backend.shutdown()
            #expect(fixture.transport.invalidationCount == 1)
        }
    }

    @Test func sessionShutdownInterruptsWindowLookupWithoutANativeReply() async throws {
        try await withGUIBackend(initialize: false) { fixture in
            let output = AsyncStream<Data>.makeStream()
            var responses = output.stream.makeAsyncIterator()
            let session = NativeMCPSession(backend: fixture.backend,
                artifactsRoot: fixture.directory.appendingPathComponent("artifacts"),
                output: { output.continuation.yield($0) })
            try session.receive(guiBackendData(.object([
                "jsonrpc": .string("2.0"), "id": .string("initialize"), "method": .string("initialize"),
                "params": .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
                    "clientInfo": .object(fixture.sessionContext.clientInfo)]),
            ])))
            let initialized = try nativeTestJSON(#require(await responses.next(isolation: MainActor.shared)))
            #expect(try nativeTestField(initialized, "result", "protocolVersion") == .string("2025-06-18"))
            _ = try await fixture.listTools([Self.requiredWorkspaceTool])
            try session.receive(guiBackendData(.object([
                "jsonrpc": .string("2.0"), "id": .string("window-lookup"), "method": .string("tools/call"),
                "params": .object(["name": .string("MutateWorkspace"), "arguments": .object([
                    "query": .string("edit"), "workspaceIdentifier": .string("/tmp/Project.xcodeproj"),
                ])]),
            ])))
            let windows = try await fixture.transport.nextRequest()
            #expect(try nativeTestField(nativeTestJSON(windows.message), "callTool", "name") == .string("XcodeListWindows"))

            try await session.shutdown()
            #expect(fixture.transport.invalidationCount == 1)
            #expect(!fixture.connection.isConnected)
            #expect(fixture.transport.requestMessages.count == 2)
            let cancelled = try nativeTestJSON(#require(await responses.next(isolation: MainActor.shared)))
            #expect(try nativeTestField(cancelled, "error", "code") == .number(.int(-32800)))
            try windows.respond(.object(["content": .array([]), "isError": .bool(false)]))
            #expect(fixture.transport.invalidationCount == 1)
        }
    }

    @Test func unsupportedNativeCancellationStillPreventsDispatchDuringWindowLookup() async throws {
        try await withGUIBackend(initialize: false) { fixture in
            fixture.transport.supportsToolCancellation = false
            let output = AsyncStream<Data>.makeStream()
            var responses = output.stream.makeAsyncIterator()
            let session = NativeMCPSession(backend: fixture.backend,
                artifactsRoot: fixture.directory.appendingPathComponent("artifacts"),
                output: { output.continuation.yield($0) })
            try session.receive(guiBackendData(.object([
                "jsonrpc": .string("2.0"), "id": .string("initialize"), "method": .string("initialize"),
                "params": .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
                    "clientInfo": .object(fixture.sessionContext.clientInfo)]),
            ])))
            _ = try #require(await responses.next(isolation: MainActor.shared))
            _ = try await fixture.listTools([Self.requiredWorkspaceTool])
            try session.receive(guiBackendData(.object([
                "jsonrpc": .string("2.0"), "id": .string("cancel-before-send"), "method": .string("tools/call"),
                "params": .object(["name": .string("MutateWorkspace"), "arguments": .object([
                    "query": .string("edit"), "workspaceIdentifier": .string("/tmp/Project.xcodeproj"),
                ])]),
            ])))
            let windows = try await fixture.transport.nextRequest()
            #expect(try nativeTestField(nativeTestJSON(windows.message), "callTool", "name") == .string("XcodeListWindows"))
            try session.receive(guiBackendData(.object([
                "jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
                "params": .object(["requestId": .string("cancel-before-send")]),
            ])))
            let cancelled = try nativeTestJSON(#require(await responses.next(isolation: MainActor.shared)))
            #expect(try nativeTestField(cancelled, "error", "code") == .number(.int(-32800)))
            try windows.respond(.object([
                "content": .array([]), "isError": .bool(false),
                "structuredContent": .object(["message": .string(
                    "* tabIdentifier: ready-tab, workspacePath: /tmp/Project.xcodeproj")]),
            ]))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while fixture.backend.pendingInvocationCount > 0, ContinuousClock.now < deadline {
                await Task.yield()
            }
            #expect(fixture.backend.pendingInvocationCount == 0)
            #expect(fixture.transport.requestMessages.count == 2)
            #expect(fixture.transport.oneWayMessages.count == 1)
            try await session.shutdown()
        }
    }

    private static var optionalWorkspaceTool: JSONValue {
        get throws {
            try nativeTestJSON(Data(#"{"name":"InspectWorkspace","inputSchema":{"properties":[{"name":"query","isRequired":true,"type":{"string":{}}},{"name":"tabIdentifier","isRequired":false,"type":{"string":{}}}]}}"#.utf8))
        }
    }

    private static var requiredWorkspaceTool: JSONValue {
        get throws {
            try nativeTestJSON(Data(#"{"name":"MutateWorkspace","inputSchema":{"properties":[{"name":"query","isRequired":true,"type":{"string":{}}},{"name":"tabIdentifier","isRequired":true,"type":{"string":{}}}]}}"#.utf8))
        }
    }

    private static var unscopedTool: JSONValue {
        get throws {
            try nativeTestJSON(Data(#"{"name":"NativeSearch","inputSchema":{"properties":[{"name":"query","isRequired":true,"type":{"string":{}}}]}}"#.utf8))
        }
    }
}

private func guiBackendData(_ value: JSONValue) throws -> Data {
    try JSONSerialization.data(withJSONObject: value.foundationObject, options: [.fragmentsAllowed])
}

@MainActor
private func withGUIBackend(initialize: Bool = true, connectsImmediately: Bool = true,
                            expectedShutdownError: GUIBackendTestError? = nil,
                            _ body: @MainActor (GUIBackendFixture) async throws -> Void) async throws {
    let fixture = try GUIBackendFixture(connectsImmediately: connectsImmediately)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    do {
        if initialize { try await fixture.backend.initialize(context: fixture.sessionContext) }
        try await body(fixture)
        if let expectedShutdownError {
            await #expect(throws: expectedShutdownError) { try await fixture.backend.shutdown() }
        } else {
            try await fixture.backend.shutdown()
        }
    } catch {
        try? await fixture.backend.shutdown()
        throw error
    }
}

@MainActor
private final class GUIBackendFixture {
    let directory: URL
    let processIdentifier: Int32 = 912
    let installation: NativeXcodeInstallation
    let transport: GUIBackendTransport
    let connection: NativeGUIConnection
    let backend: NativeGUIBackend
    let sessionContext = NativeSessionContext(conversationID: "client-conversation", clientInfo: [
        "name": .string("Original MCP Client"), "version": .string("17.4"),
        "binaryPath": .string("/client/supplied/path"), "binaryPID": .number(.int(-1)),
    ])
    var toolContext: NativeToolContext {
        NativeToolContext(artifactsDirectory: directory, conversationID: sessionContext.conversationID)
    }

    init(connectsImmediately: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-gui-backend-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        let contents = directory.appendingPathComponent("Xcode.app/Contents", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Frameworks/IDEFoundation.framework", isDirectory: true), withIntermediateDirectories: true)
            let developerDirectory = contents.appendingPathComponent("Developer", isDirectory: true)
            try FileManager.default.createDirectory(at: developerDirectory, withIntermediateDirectories: true)
            installation = try NativeXcodeInstallation(developerDirectory: developerDirectory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        let transport = GUIBackendTransport()
        transport.connectsImmediately = connectsImmediately
        self.transport = transport
        let connection = NativeGUIConnection(processIdentifier: processIdentifier, transport: transport)
        self.connection = connection
        backend = NativeGUIBackend(processIdentifier: processIdentifier, installation: installation) { processIdentifier, message, installation in
            transport.connectorProcessIdentifiers.append(processIdentifier)
            transport.connectorDeveloperDirectories.append(installation.developerDirectory)
            try await connection.start(initializingWith: message, timeout: .seconds(10))
            return connection
        }
    }

    func listTools(_ schemas: [JSONValue]) async throws -> [NativeTool] {
        let listing = Task { @MainActor in try await backend.listTools() }
        defer { listing.cancel() }
        let request = try await transport.nextRequest()
        #expect(try nativeTestJSON(request.message) == .object(["listTools": .object([:])]))
        try request.respond(.object(["toolSchemas": .array(schemas)]))
        return try await listing.value
    }
}

private enum GUIBackendTestError: Error, Equatable, CustomStringConvertible {
    case cancellation, cleanup

    var description: String {
        switch self {
        case .cancellation: "test-native-GUI-backend-cancellation-failure"
        case .cleanup: "test-native-GUI-backend-cleanup-failure"
        }
    }
}

@MainActor
private final class GUIBackendRequest {
    let message: Data
    private let reply: @MainActor @Sendable (Result<Data, any Error>) -> Void

    init(message: Data, reply: @escaping @MainActor @Sendable (Result<Data, any Error>) -> Void) {
        self.message = message
        self.reply = reply
    }

    func respond(_ value: JSONValue) throws { reply(.success(try guiBackendData(value))) }
}

@MainActor
private final class GUIBackendTransport: NativeGUIConnectionTransport {
    var supportsToolCancellation = true
    var connectsImmediately = true
    var oneWayError: GUIBackendTestError?
    var cleanupError: GUIBackendTestError?
    var connectorProcessIdentifiers: [Int32] = []
    var connectorDeveloperDirectories: [URL] = []
    private(set) var activationCount = 0
    private(set) var invalidationCount = 0
    private(set) var requestMessages: [Data] = []
    private(set) var oneWayMessages: [Data] = []
    private var connected: (@MainActor @Sendable () -> Void)?
    private var received: (@MainActor @Sendable (Data) -> Void)?
    private var invalidated: (@MainActor @Sendable ((any Error)?) -> Void)?
    private let activations = AsyncStream<Void>.makeStream()
    private let requests = AsyncStream<GUIBackendRequest>.makeStream()
    private let oneWays = AsyncStream<Data>.makeStream()
    private var activationIterator: AsyncStream<Void>.Iterator
    private var requestIterator: AsyncStream<GUIBackendRequest>.Iterator
    private var oneWayIterator: AsyncStream<Data>.Iterator

    init() {
        activationIterator = activations.stream.makeAsyncIterator()
        requestIterator = requests.stream.makeAsyncIterator()
        oneWayIterator = oneWays.stream.makeAsyncIterator()
    }

    func activate(connected: @escaping @MainActor @Sendable () -> Void,
                  receive: @escaping @MainActor @Sendable (Data) -> Void,
                  invalidated: @escaping @MainActor @Sendable ((any Error)?) -> Void) throws {
        activationCount += 1
        self.connected = connected
        received = receive
        self.invalidated = invalidated
        activations.continuation.yield(())
        if connectsImmediately { connected() }
    }

    func send(_ message: Data, reply: @escaping @MainActor @Sendable (Result<Data, any Error>) -> Void) throws {
        requestMessages.append(message)
        requests.continuation.yield(GUIBackendRequest(message: message, reply: reply))
    }

    func sendOneWay(_ message: Data) throws {
        oneWayMessages.append(message)
        // Record failed sends too, so cancellation-failure tests observe the attempted native message.
        oneWays.continuation.yield(message)
        if let oneWayError { throw oneWayError }
    }

    func invalidate() throws {
        invalidationCount += 1
        if let cleanupError { throw cleanupError }
    }

    func connect() { connected?() }
    func receive(_ value: JSONValue) throws { received?(try guiBackendData(value)) }
    func disconnect() { invalidated?(nil) }

    func nextActivation() async throws {
        var iterator = activationIterator
        let activation: Void? = await iterator.next(isolation: MainActor.shared)
        activationIterator = iterator
        _ = try #require(activation)
    }

    func nextRequest() async throws -> GUIBackendRequest {
        var iterator = requestIterator
        let request = await iterator.next(isolation: MainActor.shared)
        requestIterator = iterator
        return try #require(request)
    }

    func nextOneWay() async throws -> Data {
        var iterator = oneWayIterator
        while let message = await iterator.next(isolation: MainActor.shared) {
            oneWayIterator = iterator
            if try nativeTestObject(nativeTestJSON(message))["initializeSession"] == nil { return message }
        }
        throw NativeTestFailure.expectedObject
    }
}
