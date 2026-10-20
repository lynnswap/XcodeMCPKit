import Foundation
import XcodeMCPWire

package struct NativeToolContext: Sendable {
    package let artifactsDirectory: URL
    package let artifactsRoot: URL
    package let conversationID: String
    package let executionResource: NativeExecutionResource
    let executionScope: NativeExecutionOperations.Scope

    package init(artifactsDirectory: URL, artifactsRoot: URL, conversationID: String,
                 executionResource: NativeExecutionResource = NativeExecutionResource()) {
        self.artifactsDirectory = artifactsDirectory
        self.artifactsRoot = artifactsRoot
        self.conversationID = conversationID
        self.executionResource = executionResource
        executionScope = NativeExecutionOperations.Scope()
    }

}

@MainActor
package protocol NativeToolBackend: AnyObject, Sendable {
    var origin: [String: JSONValue]? { get }
    func listTools() async throws -> [NativeTool]
    func execute(_ name: String, arguments: [String: JSONValue], context: NativeToolContext) async throws -> AsyncStream<Data>
    func executionResource(for name: String, arguments: [String: JSONValue]) async throws -> NativeExecutionResource
    func finishExecution(context: NativeToolContext) async throws
    /// A failure that leaves this process unable to serve further requests.
    var processFailure: (any Error)? { get }
    /// Prepares pending requests to drain before shutdown performs final cleanup.
    func beginShutdown()
    func shutdown() async throws
}

extension NativeToolBackend {
    package var origin: [String: JSONValue]? { nil }
    package var processFailure: (any Error)? { nil }
    package func beginShutdown() {}
    package func executionResource(for name: String, arguments: [String: JSONValue]) async throws -> NativeExecutionResource {
        NativeExecutionResource()
    }
    package func finishExecution(context: NativeToolContext) async throws {}
}

@safe
@MainActor
package final class NativeXcodeBackend: NativeToolBackend {
    private let installation: NativeXcodeInstallation
    private let testableStateCorrection: NativeTestableStateCorrection
    private var executionOperations: NativeExecutionOperations?
    private let bridge: NativeActionBridge
    private let selection: NativeToolSelection
    private let scope: NativeWorkspaceScope
    private let workspaces: NativeWorkspaceRegistry
    private let crashCorrection: NativeCrashToolCorrection
    private let previewCorrection: NativePreviewCorrection
    private var actions: [String: NativeActionClass] = unsafe [:]
    private var tools: [String: NativeTool] = [:]
    private var previewBuildInvalidations: [URL: String?] = [:]
    private var catalogTask: Task<[NativeTool], any Error>?

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

    package var processFailure: (any Error)? { testableStateCorrection.failure }

    package func listTools() async throws -> [NativeTool] {
        if let catalogTask { return try await catalogTask.value }
        let task = Task { try await loadTools() }
        catalogTask = task
        defer { catalogTask = nil }
        return try await task.value
    }

    private func loadTools() async throws -> [NativeTool] {
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

    package func executionResource(for name: String, arguments: [String: JSONValue]) async throws -> NativeExecutionResource {
        if tools[name] == nil { _ = try await listTools() }
        guard let tool = tools[name] else {
            throw NativeRuntimeError.invalidRequest("Unknown native tool '\(name)'")
        }
        let heavy = ["BuildProject", "RunProject", "RunAllTests", "RunSomeTests", "RenderPreview"].contains(name)
        if name == "XcodeOpenWorkspace", case .string(let path) = arguments["path"] {
            return NativeExecutionResource(workspace: try workspaces.executionKey(for: path), heavy: heavy)
        }
        if tool.acceptsWorkspaceIdentifier, case .string(let selector) = arguments["workspaceIdentifier"] {
            return NativeExecutionResource(workspace: try workspaces.executionKey(for: selector), heavy: heavy)
        }
        return NativeExecutionResource(processExclusive: tool.requiresPreviewBuildInvalidation, heavy: heavy)
    }

    package func execute(_ name: String, arguments: [String: JSONValue], context: NativeToolContext) async throws -> AsyncStream<Data> {
        try workspaces.beginExecution(request: context.artifactsDirectory, workspace: context.executionResource.workspace)
        try testableStateCorrection.checkFailure()
        if tools[name] == nil { _ = try await listTools() }
        try Task.checkCancellation()
        guard let tool = tools[name], let action = unsafe actions[name] else {
            throw NativeRuntimeError.invalidRequest("Unknown native tool '\(name)'")
        }
        if ["BuildProject", "RunProject", "RunAllTests", "RunSomeTests"].contains(name), executionOperations == nil {
            executionOperations = try NativeExecutionOperations()
        }
        try await NativeErrorPresentation.$capture.withValue(nil) {
            do {
                try await workspaces.closeRemovedWorkspaces(request: context.artifactsDirectory)
                try await previewCorrection.retainWorkspaces(workspaces.registeredIdentifiers())
            }
            catch { NativeErrorPresentation.reportBackground("Native workspace cleanup failed: \(error)") }
            try Task.checkCancellation()
        }
        var arguments = arguments
        let isPreview = unsafe NativePreviewCorrection.handles(action)
        let invalidatesPreviewBuild = !isPreview && tool.requiresPreviewBuildInvalidation
        if invalidatesPreviewBuild, !tool.workspaceScoped {
            previewBuildInvalidations.updateValue(nil, forKey: context.artifactsDirectory)
            previewCorrection.invalidateReusableBuild(workspaceIdentifier: nil)
        }
        if name == "XcodeOpenWorkspace", case .string(let path) = arguments["path"] {
            arguments["path"] = .string(NativeWorkspaceRegistry.workspacePath(for: path))
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
        if isPreview { arguments = NativePreviewCorrection.prepareArguments(arguments) }
        let input = try JSONSerialization.data(withJSONObject: arguments.mapValues(\.foundationObject))
        if let kind = unsafe NativeCrashToolCorrection.Kind.forAction(action) {
            return try unsafe crashCorrection.execute(kind, inputType: scope.inputType(for: action), input: input,
                                                       request: context.artifactsDirectory)
        }
        if isPreview {
            return try unsafe await previewCorrection.execute(inputType: scope.inputType(for: action), input: input,
                artifactsRoot: context.artifactsRoot, request: context.artifactsDirectory) { [self] in
                guard let action = unsafe actions[name] else {
                    throw NativeRuntimeError.invalidRequest("Unknown native tool '\(name)'")
                }
                return try unsafe await bridge.execute(action: action, input: input, context: context)
            }
        }
        return try unsafe await bridge.execute(action: action, input: input, context: context)
    }

    package func beginShutdown() {
        catalogTask?.cancel()
        crashCorrection.cancelPendingOperations()
        previewCorrection.cancelPendingOperations()
    }

    package func finishExecution(context: NativeToolContext) async throws {
        defer { workspaces.endExecution(request: context.artifactsDirectory) }
        if Task.isCancelled { context.executionScope.cancel() }
        await previewCorrection.finishExecution(request: context.artifactsDirectory)
        await crashCorrection.finishExecution(request: context.artifactsDirectory)
        await bridge.finishExecution(request: context.artifactsDirectory)
        var failures: [String] = []
        do { try await context.executionScope.finish() }
        catch { failures.append(String(describing: error)) }
        do { try executionOperations?.checkFailure() }
        catch { failures.append(String(describing: error)) }
        if let identifier = previewBuildInvalidations.removeValue(forKey: context.artifactsDirectory) {
            // A native action's stream can overlap rendering before its mutation finishes.
            previewCorrection.invalidateReusableBuild(workspaceIdentifier: identifier)
        }
        do {
            try workspaces.finishOpen(request: context.artifactsDirectory)
            try await previewCorrection.retainWorkspaces(workspaces.registeredIdentifiers())
        } catch { failures.append(String(describing: error)) }
        do { try testableStateCorrection.checkFailure() }
        catch { failures.append(String(describing: error)) }
        if !failures.isEmpty { throw NativeRuntimeError.invocation(failures.joined(separator: "; ")) }
    }

    package func shutdown() async throws {
        catalogTask?.cancel()
        if let catalogTask { _ = try? await catalogTask.value }
        await crashCorrection.shutdown()
        var failures: [String] = []
        do { try await previewCorrection.shutdown() } catch { failures.append(String(describing: error)) }
        await bridge.shutdown()
        do { try await workspaces.closeAllWorkspaces() } catch { failures.append(String(describing: error)) }
        do { try testableStateCorrection.checkFailure() } catch { failures.append(String(describing: error)) }
        if !failures.isEmpty { throw NativeRuntimeError.invocation(failures.joined(separator: "; ")) }
    }
}
