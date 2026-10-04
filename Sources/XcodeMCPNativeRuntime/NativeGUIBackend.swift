import Foundation
import XcodeMCPWire

@MainActor
package final class NativeGUIBackend: NativeToolBackend {
    package typealias Connector = @MainActor @Sendable
        (Int32, Data, NativeXcodeInstallation) async throws -> NativeGUIConnection

    package var resultFormat: NativeToolResultFormat { .mcpResult }
    package var supportsToolCancellation: Bool { connection?.supportsToolCancellation ?? true }
    package var origin: [String: JSONValue]? {
        installation.origin(kind: "gui", processID: processIdentifier,
                            toolCancellation: supportsToolCancellation ? "nativeMessage" : "waitForNativeCompletion")
    }

    private struct Invocation {
        let producer: Task<Void, Never>
        let continuation: AsyncStream<Data>.Continuation
        var wasDispatched = false
    }

    private let processIdentifier: Int32
    private let installation: NativeXcodeInstallation
    private let connector: Connector
    private let signingIdentity: NativeSigningIdentity?
    private var connection: NativeGUIConnection?
    private var initialization: Task<NativeGUIConnection, any Error>?
    private var progressListener: Task<Void, Never>?
    private var invocations: [UUID: Invocation] = [:]
    private var tools: [String: NativeTool] = [:]
    private var shutdownTask: Task<Void, any Error>?

    package var pendingInvocationCount: Int { invocations.count }

    package init(processIdentifier: Int32, installation: NativeXcodeInstallation,
                 signingIdentity: NativeSigningIdentity?,
                 connector: @escaping Connector = { processIdentifier, message, installation in
                     try await NativeGUIConnection.connect(to: processIdentifier,
                                                           initializingWith: message,
                                                           installation: installation)
                 }) {
        self.processIdentifier = processIdentifier
        self.installation = installation
        self.connector = connector
        self.signingIdentity = signingIdentity
    }

    package func initialize(context: NativeSessionContext) async throws {
        guard shutdownTask == nil else {
            throw NativeRuntimeError.unavailable("Native GUI backend is shutting down")
        }
        guard connection == nil, initialization == nil else {
            throw NativeRuntimeError.invalidRequest("The native GUI session is already initialized")
        }
        guard let executable = Bundle.main.executableURL else {
            throw NativeRuntimeError.unavailable("Native GUI host executable path is unavailable")
        }
        let clientName: String
        if case .string(let name) = context.clientInfo["name"] { clientName = name }
        else { clientName = "XcodeMCPKit" }
        let clientVersion: String
        if case .string(let version) = context.clientInfo["version"] { clientVersion = version }
        else { clientVersion = "dev" }
        let message = try NativeGUICodec.encode(.object([
            "initializeSession": .object(["context": .object([
                "sessionID": .string(context.conversationID),
                "clientInfo": .object([
                    "name": .string(clientName), "version": .string(clientVersion),
                    "signingIdentity": signingIdentity?.json ?? .null,
                    "binaryPath": .string(executable.path),
                    "binaryPID": .number(.int(Int64(getpid()))),
                ]),
            ])]),
        ]))
        let task = Task { @MainActor [connector, processIdentifier, installation] in
            try await connector(processIdentifier, message, installation)
        }
        initialization = task
        defer { initialization = nil }
        let connected = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        if shutdownTask != nil || Task.isCancelled {
            do { try connected.invalidate() }
            catch {
                throw NativeRuntimeError.invocation("Native GUI initialization was cancelled; connection cleanup also failed: \(error)")
            }
            throw CancellationError()
        }
        connection = connected
        progressListener = Task { @MainActor [weak self, messages = connected.messages] in
            for await message in messages {
                self?.receiveProgress(message)
            }
        }
    }

    package func listTools() async throws -> [NativeTool] {
        let connected = try activeConnection()
        let response = try NativeGUICodec.decode(await connected.request(
            NativeGUICodec.encode(.object(["listTools": .object([:])]))))
        guard case .object(let fields) = response, case .array(let schemas) = fields["toolSchemas"] else {
            throw NativeRuntimeError.unsupportedContract("Native GUI tool list has no tool schemas")
        }
        var catalog: [String: NativeTool] = [:]
        for schema in schemas {
            let tool = try NativeGUICodec.tool(from: schema)
            catalog[tool.name] = tool
        }
        tools = catalog
        return catalog.values.sorted { $0.name < $1.name }
    }

    package func execute(_ name: String, arguments: [String: JSONValue],
                         context: NativeToolContext) async throws -> AsyncStream<Data> {
        if tools[name] == nil { _ = try await listTools() }
        guard let tool = tools[name] else {
            throw NativeRuntimeError.invalidRequest("Unknown native GUI tool '\(name)'")
        }
        let connected = try activeConnection()
        try Task.checkCancellation()
        let token = UUID()
        let processIdentifier = self.processIdentifier
        let supportsCancellation = connected.supportsToolCancellation
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let producer = Task { @MainActor [weak self] in
            defer {
                continuation.finish()
                self?.invocations.removeValue(forKey: token)
            }
            do {
                let arguments = try await Self.nativeArguments(arguments, for: tool, connection: connected,
                                                               processIdentifier: processIdentifier)
                try Task.checkCancellation()
                let request = try NativeGUICodec.call(name, arguments: arguments, token: token)
                let cancellation: NativeGUIRequestCancellation = supportsCancellation
                    ? .nativeMessage(try NativeGUICodec.cancel(name, token: token)) : .waitForNativeCompletion
                let reply = try await connected.request(request, cancellation: cancellation,
                    didSend: { [weak self] in
                        context.didDispatch()
                        self?.invocations[token]?.wasDispatched = true
                    },
                    didReceiveReply: { [weak self] in self?.invocations[token]?.wasDispatched = false })
                context.didDispatch()
                continuation.yield(try NativeGUICodec.event("completed", data: NativeGUICodec.decode(reply)))
            } catch {
                if !Task.isCancelled {
                    do {
                        continuation.yield(try NativeGUICodec.event("error", data: .string(String(describing: error))))
                    } catch let encodingError {
                        FileHandle.standardError.write(Data(("Native GUI tool failed: \(error); error encoding also failed: \(encodingError)\n").utf8))
                    }
                }
            }
        }
        continuation.onTermination = { termination in
            if case .cancelled = termination { producer.cancel() }
        }
        invocations[token] = Invocation(producer: producer, continuation: continuation)
        return stream
    }

    private func activeConnection() throws -> NativeGUIConnection {
        guard shutdownTask == nil else {
            throw NativeRuntimeError.unavailable("Native GUI backend is shutting down")
        }
        guard let connection else {
            throw NativeRuntimeError.invalidRequest("Initialize the native GUI session first")
        }
        guard connection.isConnected else {
            throw connection.terminationError ?? NativeGUIConnectionError.disconnected(processIdentifier: processIdentifier)
        }
        return connection
    }

    private static func nativeArguments(_ arguments: [String: JSONValue], for tool: NativeTool,
                                        connection: NativeGUIConnection, processIdentifier: Int32) async throws -> [String: JSONValue] {
        guard tool.workspaceScoped else { return arguments }
        var arguments = arguments
        guard let value = arguments.removeValue(forKey: "workspaceIdentifier") else { return arguments }
        guard case .string(let selector) = value else {
            throw NativeRuntimeError.invalidRequest("workspaceIdentifier must be a string")
        }
        if selector.hasPrefix("/") {
            let token = UUID()
            let cancellation: NativeGUIRequestCancellation = connection.supportsToolCancellation
                ? .nativeMessage(try NativeGUICodec.cancel("XcodeListWindows", token: token)) : .waitForNativeCompletion
            let reply = try await connection.request(
                NativeGUICodec.call("XcodeListWindows", arguments: [:], token: token), cancellation: cancellation)
            let result = try NativeGUICodec.decode(reply)
            if case .object(let fields) = result, case .bool(true) = fields["isError"] {
                throw NativeRuntimeError.invocation(String(decoding: reply, as: UTF8.self))
            }
            guard let message = NativeGUICodec.toolMessage(result) else {
                throw NativeRuntimeError.unsupportedContract("Native XcodeListWindows result has no window message")
            }
            let path = NativeGUICodec.normalizedPath(selector)
            let identifiers = Set(NativeGUICodec.windows(message).filter {
                NativeGUICodec.normalizedPath($0.path) == path
            }.map(\.identifier)).sorted()
            guard let identifier = identifiers.first else {
                throw NativeRuntimeError.invalidRequest("No open GUI workspace matches '\(selector)' in Xcode process \(processIdentifier)")
            }
            guard identifiers.count == 1 else {
                throw NativeRuntimeError.invalidRequest("Multiple GUI tabs own '\(selector)'; select one tabIdentifier: \(identifiers.joined(separator: ", "))")
            }
            arguments["tabIdentifier"] = .string(identifier)
        } else {
            arguments["tabIdentifier"] = .string(selector)
        }
        return arguments
    }

    private func receiveProgress(_ message: Data) {
        guard let value = try? NativeGUICodec.decode(message), case .object(let fields) = value,
              case .object(let update) = fields["progressUpdate"],
              case .object(var progress) = update["_0"], case .string(let rawToken) = progress.removeValue(forKey: "token"),
              let token = UUID(uuidString: rawToken), let invocation = invocations[token] else { return }
        if let event = try? NativeGUICodec.event("update", data: .object(progress)) {
            invocation.continuation.yield(event)
        }
    }

    package func beginShutdown() {
        guard shutdownTask == nil else { return }
        let pending = Array(invocations.values)
        let connecting = initialization
        let listener = progressListener
        let unconfirmed = supportsToolCancellation ? 0 : pending.filter(\.wasDispatched).count
        connecting?.cancel()
        listener?.cancel()
        for invocation in pending { invocation.producer.cancel() }
        var errors: [any Error] = []
        if let connection {
            do { try connection.invalidate() } catch { errors.append(error) }
        }
        if unconfirmed > 0 {
            FileHandle.standardError.write(Data(("Native GUI shutdown disconnected from Xcode process \(processIdentifier) with \(unconfirmed) uncancellable tool call(s) still awaiting replies; native operations may continue.\n").utf8))
        }
        shutdownTask = Task { @MainActor in
            try await self.finishShutdown(pending: pending, connecting: connecting,
                                          listener: listener, preparationErrors: errors)
        }
    }

    package func shutdown() async throws {
        beginShutdown()
        if let shutdownTask { try await shutdownTask.value }
    }

    private func finishShutdown(pending: [Invocation], connecting: Task<NativeGUIConnection, any Error>?,
                                listener: Task<Void, Never>?, preparationErrors: [any Error]) async throws {
        var errors = preparationErrors
        if let connecting {
            do { try await connecting.value.invalidate() }
            catch is CancellationError {}
            catch { errors.append(error) }
        }
        for invocation in pending {
            invocation.continuation.finish()
            await invocation.producer.value
        }
        await listener?.value
        connection = nil
        progressListener = nil
        invocations.removeAll()
        if errors.count == 1, let error = errors.first { throw error }
        if !errors.isEmpty {
            throw NativeRuntimeError.invocation(errors.map { String(describing: $0) }.joined(separator: "; "))
        }
    }
}

private enum NativeGUICodec {
    static func encode(_ value: JSONValue) throws -> Data {
        try JSONSerialization.data(withJSONObject: value.foundationObject, options: [.fragmentsAllowed])
    }

    static func decode(_ data: Data) throws -> JSONValue {
        guard let value = JSONValue(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) else {
            throw NativeRuntimeError.unsupportedContract("Native GUI message is not a JSON value")
        }
        return value
    }

    static func call(_ name: String, arguments: [String: JSONValue], token: UUID) throws -> Data {
        try encode(.object(["callTool": .object([
            "name": .string(name), "arguments": .object(arguments), "progressToken": .string(token.uuidString),
        ])]))
    }

    static func cancel(_ name: String, token: UUID) throws -> Data {
        try encode(.object(["cancelToolCall": .object([
            "name": .string(name), "progressToken": .string(token.uuidString),
        ])]))
    }

    static func event(_ type: String, data: JSONValue) throws -> Data {
        try encode(.object(["type": .string(type), "data": data]))
    }

    static func tool(from schema: JSONValue) throws -> NativeTool {
        guard case .object(let fields) = schema, case .object(let input) = fields["inputSchema"],
              case .array(let properties) = input["properties"] else {
            throw NativeRuntimeError.unsupportedContract("Native GUI tool schema has no input property list")
        }
        let selectors = properties.filter {
            guard case .object(let property) = $0, case .string(let name) = property["name"] else { return false }
            return name == "tabIdentifier" || name == "workspaceIdentifier"
        }
        let scoped = !selectors.isEmpty
        let tool = try NativeSchemaConverter.tool(from: encode(schema), workspaceScoped: scoped)
        guard scoped, case .object(var descriptor) = tool.descriptor,
              case .object(var inputSchema) = descriptor["inputSchema"],
              case .object(var convertedProperties) = inputSchema["properties"] else { return tool }
        convertedProperties["workspaceIdentifier"] = .object([
            "type": .string("string"),
            "description": .string("Native GUI tab identifier or absolute path to an open .xcworkspace or .xcodeproj. If multiple tabs own the path, select a tabIdentifier from XcodeListWindows."),
        ])
        inputSchema["properties"] = .object(convertedProperties)
        if selectors.contains(where: {
            guard case .object(let property) = $0 else { return false }
            return property["isRequired"] == .bool(true)
        }), case .array(var required) = inputSchema["required"], !required.contains(.string("workspaceIdentifier")) {
            required.append(.string("workspaceIdentifier"))
            inputSchema["required"] = .array(required)
        }
        descriptor["inputSchema"] = .object(inputSchema)
        return NativeTool(name: tool.name, descriptor: .object(descriptor), workspaceScoped: scoped)
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func windows(_ message: String) -> [(identifier: String, path: String)] {
        message.split(separator: "\n").compactMap { line in
            var line = String(line.drop { $0 == " " || $0 == "\t" })
            if line.hasSuffix("\r") { line.removeLast() }
            let prefix = "* tabIdentifier: "
            guard line.hasPrefix(prefix), let delimiter = line.range(of: ", workspacePath: ",
                    range: line.index(line.startIndex, offsetBy: prefix.count)..<line.endIndex) else { return nil }
            let identifier = String(line[line.index(line.startIndex, offsetBy: prefix.count)..<delimiter.lowerBound])
            let path = String(line[delimiter.upperBound...])
            guard !identifier.isEmpty, !path.isEmpty else { return nil }
            return (identifier, path)
        }
    }

    static func toolMessage(_ result: JSONValue) -> String? {
        guard case .object(let fields) = result else { return nil }
        if case .object(let content) = fields["structuredContent"], case .string(let message) = content["message"] {
            return message
        }
        guard case .array(let content) = fields["content"] else { return nil }
        var fallback: String?
        for item in content {
            guard case .object(let fields) = item, case .string(let text) = fields["text"], !text.isEmpty else { continue }
            if let value = try? decode(Data(text.utf8)), case .object(let fields) = value,
               case .string(let message) = fields["message"] { return message }
            if fallback == nil { fallback = text }
        }
        return fallback
    }
}
