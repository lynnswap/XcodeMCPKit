import Foundation
import XcodeMCPWire

package struct NativeSessionContext: Sendable {
    package let conversationID: String
    package let clientInfo: [String: JSONValue]

    package init(conversationID: String, clientInfo: [String: JSONValue]) {
        self.conversationID = conversationID
        self.clientInfo = clientInfo
    }
}

package enum NativeToolResultFormat {
    case actionValue
    case mcpResult
}

package struct NativeToolContext: Sendable {
    package let artifactsDirectory: URL
    package let conversationID: String

    package init(artifactsDirectory: URL, conversationID: String) {
        self.artifactsDirectory = artifactsDirectory
        self.conversationID = conversationID
    }
}

@MainActor
package protocol NativeToolBackend: AnyObject {
    var resultFormat: NativeToolResultFormat { get }
    func initialize(context: NativeSessionContext) async throws
    func listTools() async throws -> [NativeTool]
    func execute(_ name: String, arguments: [String: JSONValue], context: NativeToolContext) async throws -> AsyncStream<Data>
    func observe(toolName: String, arguments: [String: JSONValue], event: JSONValue)
    func shutdown() async throws
}

extension NativeToolBackend {
    package var resultFormat: NativeToolResultFormat { .actionValue }
    package func initialize(context: NativeSessionContext) async throws {}
    package func observe(toolName: String, arguments: [String: JSONValue], event: JSONValue) {}
}

@safe
@MainActor
package final class NativeXcodeBackend: NativeToolBackend {
    private let bridge: NativeActionBridge
    private let selection: NativeToolSelection
    private let scope: NativeWorkspaceScope
    private let workspaces: NativeWorkspaceRegistry
    private let crashCorrection: NativeCrashToolCorrection
    private var actions: [String: NativeActionClass] = unsafe [:]
    private var tools: [String: NativeTool] = [:]

    package init(installation: NativeXcodeInstallation) async throws {
        bridge = NativeActionBridge(installation: installation)
        selection = try await NativeToolSelection(installation: installation)
        scope = try await NativeWorkspaceScope(installation: installation)
        workspaces = try await NativeWorkspaceRegistry(installation: installation)
        crashCorrection = NativeCrashToolCorrection(installation: installation)
    }

    package func listTools() async throws -> [NativeTool] {
        let names = try await selection.publicToolNames()
        let registered = try bridge.registeredActions()
        var nextActions: [String: NativeActionClass] = unsafe [:]
        var nextTools: [String: NativeTool] = [:]
        for name in names.sorted() {
            guard let metadata = registered[name] else {
                throw NativeRuntimeError.unsupportedContract("Public native tool '\(name)' is not registered")
            }
            let action = try unsafe await bridge.actionClass(for: metadata)
            let workspaceScoped = try unsafe await scope.isWorkspaceScoped(action)
            let schema = try unsafe await bridge.schema(action: action)
            unsafe (nextActions[name] = action)
            nextTools[name] = try NativeSchemaConverter.tool(from: schema, workspaceScoped: workspaceScoped)
        }
        unsafe (actions = nextActions)
        tools = nextTools
        return nextTools.values.sorted { $0.name < $1.name }
    }

    package func execute(_ name: String, arguments: [String: JSONValue], context: NativeToolContext) async throws -> AsyncStream<Data> {
        if tools[name] == nil { _ = try await listTools() }
        try Task.checkCancellation()
        guard let tool = tools[name], let action = unsafe actions[name] else {
            throw NativeRuntimeError.invalidRequest("Unknown native tool '\(name)'")
        }
        var arguments = arguments
        if tool.acceptsWorkspaceIdentifier, case .string(let selector) = arguments["workspaceIdentifier"] {
            arguments["workspaceIdentifier"] = .string(try await workspaces.resolve(selector, opensIfMissing: name != "XcodeCloseWorkspace"))
            try Task.checkCancellation()
            if tool.workspaceScoped, case .string(let identifier) = arguments["workspaceIdentifier"] {
                try await workspaces.prepareDebugger(for: identifier)
            }
        }
        arguments["temporaryArtifactsPath"] = .string(context.artifactsDirectory.path)
        arguments["conversationID"] = .string(context.conversationID)
        let input = try JSONSerialization.data(withJSONObject: arguments.mapValues(\.foundationObject))
        if let kind = unsafe NativeCrashToolCorrection.Kind.forAction(action) {
            return try unsafe crashCorrection.execute(kind, inputType: scope.inputType(for: action), input: input)
        }
        let stream = try unsafe await bridge.execute(action: action, input: input)
        // Preserve native stream cancellation: the caller consumes this stream
        // directly rather than creating an unowned forwarding producer Task.
        return stream
    }

    package func shutdown() async throws {
        await crashCorrection.shutdown()
        try await workspaces.closeAllWorkspaces()
    }
}
