import Foundation
import XcodeMCPWire

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
    var origin: [String: JSONValue]? { get }
    func listTools() async throws -> [NativeTool]
    func execute(_ name: String, arguments: [String: JSONValue], context: NativeToolContext) async throws -> AsyncStream<Data>
    func finishExecution(context: NativeToolContext) async throws
    /// Prepares pending requests to drain before shutdown performs final cleanup.
    func beginShutdown()
    func shutdown() async throws
}

extension NativeToolBackend {
    package var origin: [String: JSONValue]? { nil }
    package func beginShutdown() {}
    package func finishExecution(context: NativeToolContext) async throws {}
}

@safe
@MainActor
package final class NativeXcodeBackend: NativeToolBackend {
    private let installation: NativeXcodeInstallation
    private let testableStateCorrection: NativeTestableStateCorrection
    private let bridge: NativeActionBridge
    private let selection: NativeToolSelection
    private let scope: NativeWorkspaceScope
    private let workspaces: NativeWorkspaceRegistry
    private let crashCorrection: NativeCrashToolCorrection
    private let previewCorrection: NativePreviewCorrection
    private var actions: [String: NativeActionClass] = unsafe [:]
    private var tools: [String: NativeTool] = [:]
    private var previewBuildInvalidations: [URL: String?] = [:]

    package init(installation: NativeXcodeInstallation) async throws {
        testableStateCorrection = try NativeTestableStateCorrection()
        self.installation = installation
        bridge = NativeActionBridge(installation: installation)
        selection = try await NativeToolSelection(installation: installation)
        scope = try await NativeWorkspaceScope(installation: installation)
        workspaces = try await NativeWorkspaceRegistry(installation: installation)
        crashCorrection = NativeCrashToolCorrection(installation: installation)
        previewCorrection = NativePreviewCorrection(installation: installation)
        try testableStateCorrection.checkFailure()
    }

    package var origin: [String: JSONValue]? {
        installation.origin(kind: "nativeHost", processID: getpid(), toolCancellation: "task")
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
            let tool = try NativeSchemaConverter.tool(from: schema, workspaceScoped: workspaceScoped)
            nextTools[name] = unsafe NativePreviewCorrection.handles(action) ? NativePreviewCorrection.describe(tool) : tool
        }
        unsafe (actions = nextActions)
        tools = nextTools
        return nextTools.values.sorted { $0.name < $1.name }
    }

    package func execute(_ name: String, arguments: [String: JSONValue], context: NativeToolContext) async throws -> AsyncStream<Data> {
        try testableStateCorrection.checkFailure()
        if tools[name] == nil { _ = try await listTools() }
        try Task.checkCancellation()
        guard let tool = tools[name], let action = unsafe actions[name] else {
            throw NativeRuntimeError.invalidRequest("Unknown native tool '\(name)'")
        }
        try await NativeErrorPresentation.$capture.withValue(nil) {
            do {
                try await workspaces.closeRemovedWorkspaces()
                try await previewCorrection.retainWorkspaces(workspaces.registeredIdentifiers())
            }
            catch { NativeErrorPresentation.reportBackground("Native workspace cleanup failed: \(error)") }
            try Task.checkCancellation()
        }
        var arguments = arguments
        let isPreview = unsafe NativePreviewCorrection.handles(action)
        let invalidatesPreviewBuild = !isPreview && !tool.isReadOnly
        if invalidatesPreviewBuild, !tool.workspaceScoped {
            previewBuildInvalidations.updateValue(nil, forKey: context.artifactsDirectory)
            previewCorrection.invalidateReusableBuild(workspaceIdentifier: nil)
        }
        if name == "XcodeOpenWorkspace", case .string(let path) = arguments["path"] {
            try await workspaces.prepareOpen(path: path, request: context.artifactsDirectory)
        }
        if tool.acceptsWorkspaceIdentifier, case .string(let selector) = arguments["workspaceIdentifier"] {
            arguments["workspaceIdentifier"] = .string(try await workspaces.resolve(
                selector, opensIfMissing: name != "XcodeCloseWorkspace", request: context.artifactsDirectory))
            try Task.checkCancellation()
        }
        if invalidatesPreviewBuild, tool.workspaceScoped {
            let identifier: String?
            if case .string(let value) = arguments["workspaceIdentifier"] { identifier = value }
            else { identifier = nil }
            previewBuildInvalidations.updateValue(identifier, forKey: context.artifactsDirectory)
            previewCorrection.invalidateReusableBuild(workspaceIdentifier: identifier)
        }
        if tool.workspaceScoped, case .string(let identifier) = arguments["workspaceIdentifier"] {
            try await workspaces.prepareDebugger(for: identifier)
        }
        try Task.checkCancellation()
        arguments["temporaryArtifactsPath"] = .string(context.artifactsDirectory.path)
        arguments["conversationID"] = .string(context.conversationID)
        let input = try JSONSerialization.data(withJSONObject: arguments.mapValues(\.foundationObject))
        if let kind = unsafe NativeCrashToolCorrection.Kind.forAction(action) {
            return try unsafe crashCorrection.execute(kind, inputType: scope.inputType(for: action), input: input)
        }
        if isPreview {
            return try unsafe await previewCorrection.execute(inputType: scope.inputType(for: action), input: input) { [self] in
                guard let action = unsafe actions[name] else {
                    throw NativeRuntimeError.invalidRequest("Unknown native tool '\(name)'")
                }
                return try unsafe await bridge.execute(action: action, input: input)
            }
        }
        let stream = try unsafe await bridge.execute(action: action, input: input)
        // Preserve native stream cancellation: the caller consumes this stream
        // directly rather than creating an unowned forwarding producer Task.
        return stream
    }

    package func beginShutdown() {
        crashCorrection.cancelPendingOperations()
        previewCorrection.cancelPendingOperations()
    }

    package func finishExecution(context: NativeToolContext) async throws {
        if let identifier = previewBuildInvalidations.removeValue(forKey: context.artifactsDirectory) {
            // A native action's stream can overlap rendering before its mutation finishes.
            previewCorrection.invalidateReusableBuild(workspaceIdentifier: identifier)
        }
        do {
            try workspaces.finishOpen(request: context.artifactsDirectory)
            try await previewCorrection.retainWorkspaces(workspaces.registeredIdentifiers())
        } catch {
            let original = error
            do { try testableStateCorrection.checkFailure() }
            catch {
                throw NativeRuntimeError.invocation("\(error); workspace cleanup failed: \(original)")
            }
            throw original
        }
        try testableStateCorrection.checkFailure()
    }

    package func shutdown() async throws {
        await crashCorrection.shutdown()
        var failures: [String] = []
        do { try await previewCorrection.shutdown() } catch { failures.append(String(describing: error)) }
        do { try await workspaces.closeAllWorkspaces() } catch { failures.append(String(describing: error)) }
        do { try testableStateCorrection.checkFailure() } catch { failures.append(String(describing: error)) }
        if !failures.isEmpty { throw NativeRuntimeError.invocation(failures.joined(separator: "; ")) }
    }
}

private extension NativeTool {
    var isReadOnly: Bool {
        guard case .object(let fields) = descriptor,
              case .object(let annotations) = fields["annotations"] else { return false }
        return annotations["readOnlyHint"] == .bool(true)
    }
}
