import ABIBridge
import Darwin
import Dispatch
import Foundation
import XcodeMCPWire

@MainActor
final class NativePreviewTool {
    private static let defaultTimeout: Int64 = 300
    private let installation: NativeXcodeInstallation
    private let builder: NativePreviewBuild
    private let definitions: NativePreviewDefinitions
    private var operations: [UUID: (request: URL?, task: Task<Void, Never>)] = [:]
    private var sessions: [String: NativePreviewSession] = [:]
    private let renderQueue = NativePreviewRenderQueue()
    let snapshotImages = SnapshotImages()
    private var renders: [UUID: (workspace: String, task: Task<JSONValue, any Error>)] = [:]

    init(installation: NativeXcodeInstallation) {
        self.installation = installation
        builder = NativePreviewBuild(installation: installation)
        definitions = NativePreviewDefinitions(installation: installation)
    }

    static func handles(_ action: NativeActionClass) -> Bool {
        let type = unsafe unsafeBitCast(action.metadata, to: Any.Type.self)
        return String(reflecting: type) == "PreviewsXcode.RenderPreviewAction"
    }

    static func describe(_ tool: NativeTool) -> NativeTool {
        guard case .object(var fields) = tool.descriptor else { return tool }
        if case .object(var input) = fields["inputSchema"],
           case .object(var properties) = input["properties"],
           case .object(var timeout) = properties["timeout"] {
            timeout["default"] = .number(.int(defaultTimeout))
            timeout["description"] = .string("The time in seconds to wait for the preview, including building and preparing its render destination. Defaults to \(defaultTimeout) seconds.")
            properties["timeout"] = .object(timeout)
            input["properties"] = .object(properties)
            fields["inputSchema"] = .object(input)
        }
        guard case .object(var output) = fields["outputSchema"],
              case .object(var properties) = output["properties"],
              case .object(var snapshot) = properties["previewSnapshotPath"] else {
            return NativeTool(name: tool.name, descriptor: .object(fields), workspaceScoped: tool.workspaceScoped)
        }
        snapshot["description"] = .string("The full path to the preview snapshot. Direct previews make areas outside the selected device's display transparent for device layouts. Fixed-size previews retain their rectangular layout; WidgetKit previews use the widget's size and rounded corners. Direct snapshots are downsampled to at most 1500 pixels per dimension. Other previews use Xcode's native snapshot format.")
        properties["previewSnapshotPath"] = .object(snapshot)
        if case .object(var controls) = properties["supportedCanvasControlOverrides"],
           case .object(var controlProperties) = controls["properties"],
           case .object(var groups) = controlProperties["groupItems"],
           case .object(let item) = groups["items"], item["type"] == .string("integer") {
            // Xcode 27.1 declares integer items but returns index/title objects.
            groups["items"] = .object([
                "type": .string("object"),
                "properties": .object([
                    "index": .object(["type": .string("integer")]),
                    "title": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("index")]),
            ])
            controlProperties["groupItems"] = .object(groups)
            controls["properties"] = .object(controlProperties)
            properties["supportedCanvasControlOverrides"] = .object(controls)
        }
        output["properties"] = .object(properties)
        fields["outputSchema"] = .object(output)
        return NativeTool(name: tool.name, descriptor: .object(fields), workspaceScoped: tool.workspaceScoped)
    }

    static func prepareArguments(_ arguments: [String: JSONValue]) -> [String: JSONValue] {
        var arguments = arguments
        if arguments["timeout"] == nil { arguments["timeout"] = .number(.int(defaultTimeout)) }
        return arguments
    }

    static func formatResult(_ result: JSONValue, outputSchema: JSONValue?) -> JSONValue {
        guard case .object(let schema) = outputSchema,
              case .object(let properties) = schema["properties"], properties["snapshot"] != nil,
              case .object(var fields) = result else { return result }
        if let path = fields.removeValue(forKey: "previewSnapshotPath") {
            fields["snapshot"] = .object(["path": path])
        }
        var overrides: [String: JSONValue] = [:]
        for (legacy, current) in [
            ("availableRenderDestinations", "renderDestinations"),
            ("supportedLocalizations", "localizations"),
            ("supportedPreviewVariantOverrides", "previewVariants"),
            ("supportedCanvasControlOverrides", "canvasControls"),
        ] {
            overrides[current] = fields.removeValue(forKey: legacy)
        }
        fields["supportedOverrides"] = .object(overrides)
        return .object(fields)
    }

    func execute(inputType: Any.Type, input: Data, artifactsRoot: URL, request: URL? = nil,
                 outputSchema: JSONValue? = nil,
                 native: @escaping @MainActor @Sendable () async throws -> AsyncStream<Data>) async throws -> AsyncStream<Data> {
        guard let inputType = inputType as? any Decodable.Type else {
            return try await native()
        }
        let parameters: Input
        do { parameters = try decode(inputType, data: input) }
        catch let error as DecodingError { throw NativeRuntimeError.invalidRequest(String(describing: error)) }
        // Some Xcode versions inline these getters. Keep their native action
        // available when the direct renderer cannot bind its input contract.
        catch is ABIResolutionError { return try await native() }
        catch NativeRuntimeError.unsupportedContract { return try await native() }
        let identifier = UUID()
        let stream = AsyncStream<Data>.makeStream()
        let task = Task { @MainActor in
            defer {
                operations[identifier] = nil
                stream.continuation.finish()
            }
            do {
                stream.continuation.yield(try event("update", .object([
                    "message": .string("Building the preview target..."), "progress": .number(.int(10)), "total": .number(.int(100)),
                ])))
                try await produce(parameters, artifactsRoot: artifactsRoot, outputSchema: outputSchema,
                    continuation: stream.continuation, native: native)
            } catch {
                if !Task.isCancelled {
                    stream.continuation.yield(errorEvent(error))
                } else if !(error is CancellationError) {
                    NativeHostDiagnostic.report("Native preview cancellation failed: \(error)")
                }
            }
        }
        operations[identifier] = (request, task)
        stream.continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream.stream
    }

    func cancelPendingOperations() {
        for operation in operations.values { operation.task.cancel() }
        builder.cancelPendingOperations()
    }

    func shutdown() async throws {
        cancelPendingOperations()
        for operation in Array(operations.values) { await operation.task.value }
        try await retainWorkspaces([])
    }

    func finishExecution(request: URL) async {
        let pending = operations.values.filter { $0.request == request }.map(\.task)
        if Task.isCancelled { for task in pending { task.cancel() } }
        for task in pending { await task.value }
    }

    func retainWorkspaces(_ identifiers: Set<String>) async throws {
        var failures: [String] = []
        let pending = renders.values.filter { !identifiers.contains($0.workspace) }.map(\.task)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
        for identifier in sessions.keys.sorted() where !identifiers.contains(identifier) {
            let cleanup = Task { @MainActor in
                try await self.renderQueue.withAccess(to: identifier) {
                    guard let session = self.sessions[identifier] else { return }
                    try await session.close(installation: self.installation)
                    self.sessions[identifier] = nil
                }
            }
            do {
                try await cleanup.value
            } catch { failures.append("\(identifier): \(error)") }
        }
        if !failures.isEmpty { throw NativeRuntimeError.invocation("Preview cleanup failed: " + failures.joined(separator: "; ")) }
    }

    func invalidateReusableBuild(workspaceIdentifier: String?) {
        let selected: [NativePreviewSession]
        if let workspaceIdentifier { selected = sessions[workspaceIdentifier].map { [$0] } ?? [] }
        else { selected = Array(sessions.values) }
        for session in selected {
            session.inputRevision &+= 1
            session.plan?.certificate = nil
        }
    }

    private func produce(_ input: Input, artifactsRoot: URL, outputSchema: JSONValue?, continuation: AsyncStream<Data>.Continuation,
                         native: @escaping @MainActor @Sendable () async throws -> AsyncStream<Data>) async throws {
        if input.requiresNativePipeline {
            try await relayNative(native, continuation: continuation)
            return
        }
        let result: JSONValue? = try await Self.withTimeout(seconds: input.timeout) {
            do {
                return try await self.render(input, artifactsRoot: artifactsRoot)
            } catch is NativePipelineRequired {
                try await self.relayNative(native, continuation: continuation)
                return nil
            }
        }
        try Task.checkCancellation()
        if let result { continuation.yield(try event("completed", Self.formatResult(result, outputSchema: outputSchema))) }
    }

    private func relayNative(_ native: @MainActor @Sendable () async throws -> AsyncStream<Data>,
                             continuation: AsyncStream<Data>.Continuation) async throws {
        try Task.checkCancellation()
        let stream = try await native()
        for await event in stream {
            try Task.checkCancellation()
            continuation.yield(event)
        }
    }

    private enum TimedResult<Output: Sendable>: Sendable {
        case operation(Result<Output, any Error>)
        case timer(any Error)
    }

    static func withTimeout<Output: Sendable>(seconds: Int, operation: @escaping @MainActor @Sendable () async throws -> Output) async throws -> Output {
        let result = await withTaskGroup(of: TimedResult<Output>.self, returning: Result<Output, any Error>.self) { group in
            group.addTask {
                do {
                    return .operation(.success(try await operation()))
                } catch { return .operation(.failure(error)) }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                    return .timer(NativeRuntimeError.invocation("Preview rendering exceeded \(seconds) seconds"))
                } catch { return .timer(error) }
            }
            defer { group.cancelAll() }
            switch await group.next()! {
            case .operation(let result):
                return result
            case .timer(let error):
                group.cancelAll()
                // Drain rendering explicitly: TaskGroup otherwise discards a
                // cleanup failure raised after the timer won the race.
                for await outcome in group {
                    if case .operation(.failure(let failure)) = outcome, !(failure is CancellationError) {
                        return .failure(NativeRuntimeError.invocation("\(error); \(failure)"))
                    }
                }
                return .failure(error)
            }
        }
        return try result.get()
    }

    @MainActor
    private struct Prepared {
        let workspace: AnyObject
        let source: URL
        let location: NativePreviewDefinitions.Definition
        let destination: NativePreviewBuild.DestinationSelection
        let context: NativePreviewBuild.PlanningContext
        let retainedBuild: (build: NativePreviewBuild.Result, signature: NativePreviewProductSignature)?
        let reusesDestination: Bool
        let inputRevision: UInt64
        let reusedCertificate: NativePreviewSession.BuildCertificate?
    }

    private func prepare(_ input: Input, session: NativePreviewSession) async throws -> Prepared {
        try Task.checkCancellation()
        let inputRevision = session.inputRevision
        let workspace = try await workspace(input.workspaceIdentifier)
        try await NativeWorkspaceRegistry.waitForSourcePackages(in: workspace)
        let currentContext = try builder.planningContext(workspace: workspace)
        var inputsAreCurrent = false
        if let plan = session.plan, let certificate = plan.certificate,
           plan.context.matches(try builder.planningContext(workspace: workspace, destination: plan.destination)) {
            do {
                let currentBuilder = try await builder.workspaceBuilder(for: plan.destination)
                if currentBuilder === certificate.workspaceBuilder,
                   try await NativePreviewInputSnapshot.matchesCurrentFiles(
                       source: certificate.inputs, generated: certificate.generatedInputs),
                   inputRevision == session.inputRevision {
                    inputsAreCurrent = true
                    if plan.requestKey == input.requestKey, plan.sourcePath == input.sourcePath,
                       certificate.build.previewPlatform != nil, let signature = session.signature {
                        let resolution = try await builder.resolveDestination(workspace: workspace, input: input.nativeValue)
                        if try await builder.destinationResolution(resolution, matches: plan.destination.resolution),
                           try await signature.matchesCurrentFiles(digestCache: session.productDigests), inputRevision == session.inputRevision,
                           plan.context.matches(try builder.planningContext(workspace: workspace, destination: plan.destination)) {
                            let destination = NativePreviewBuild.DestinationSelection(selected: plan.destination.selected, resolution: resolution)
                            return Prepared(workspace: workspace, source: plan.source, location: plan.location,
                                destination: destination, context: currentContext,
                                retainedBuild: (certificate.build, signature), reusesDestination: true,
                                inputRevision: inputRevision, reusedCertificate: certificate)
                        }
                    }
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
            }
        }
        if !inputsAreCurrent {
            session.plan = nil
            try await builder.synchronizeProjectContainers(in: workspace)
            try await NativeWorkspaceRegistry.waitForSourcePackages(in: workspace)
        }
        session.plan?.certificate = nil
        let source = try await definitions.sourceURL(input.sourcePath, workspace: workspace)
        let location = try await definitions.definition(in: source, at: input.index)
        let context = try builder.planningContext(workspace: workspace)
        let resolution = try await builder.resolveDestination(workspace: workspace, input: input.nativeValue)
        if let plan = session.plan, plan.source == source, plan.index == input.index,
           plan.localization == input.localization,
           plan.context.matches(try builder.planningContext(workspace: workspace, destination: plan.destination)),
           try await builder.destinationResolution(resolution, matches: plan.destination.resolution) {
            do {
                // The current build certifies a retained plan; stale plans return to native selection below.
                let destination = NativePreviewBuild.DestinationSelection(selected: plan.destination.selected, resolution: resolution)
                let build = try await builder.build(workspace: workspace, destination: destination, source: source)
                if let platform = build.previewPlatform {
                    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/PreviewRenderer/\(platform.helperDirectory)")
                    let signature = try await NativePreviewProductSignature.make(build: build, source: source, helper: helper,
                        digestCache: session.productDigests,
                        additionalProducts: session.additionalProducts)
                    if signature == session.signature,
                       plan.context.matches(try builder.planningContext(workspace: workspace, destination: plan.destination)) {
                        return Prepared(workspace: workspace, source: source, location: location, destination: destination,
                            context: context, retainedBuild: (build, signature), reusesDestination: true,
                            inputRevision: inputRevision, reusedCertificate: nil)
                    }
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
            }
        }
        session.plan = nil
        let destination = try await builder.selectDestination(workspace: workspace, source: location.source, resolution: resolution)
        _ = try await builder.prepare(workspace: workspace)
        try Task.checkCancellation()
        return Prepared(workspace: workspace, source: source, location: location, destination: destination,
            context: context, retainedBuild: nil, reusesDestination: false,
            inputRevision: inputRevision, reusedCertificate: nil)
    }

    private func certifyBuild(_ build: NativePreviewBuild.Result, workspace: AnyObject,
                             destination: NativePreviewBuild.DestinationSelection, source: URL,
                             session: NativePreviewSession, inputRevision: UInt64) async throws -> NativePreviewSession.BuildCertificate? {
        guard let buildStartedAt = build.buildStartedAt, let buildCompletedAt = build.buildCompletedAt,
              let workspaceBuilder = build.workspaceBuilder else { return nil }
        let outputPaths = build.inputCaptureExclusions.union([session.artifactsRoot])
        guard let inputsToCapture = try builder.inputRoots(workspace: workspace, build: build, source: source, excluding: outputPaths) else { return nil }
        let exclusions = NativePreviewInputSnapshot.coalescedExclusions(outputPaths, roots: inputsToCapture.roots)
        let inputs = try await NativePreviewInputSnapshot.capture(roots: inputsToCapture.roots, excluding: exclusions,
            missingInputs: build.missingInputFiles.union(inputsToCapture.missing))
        // A post-build snapshot must not certify source edits that arrived during the build.
        guard inputs.predates(buildStartedAt) else { return nil }
        let generatedInputs = try await NativePreviewInputSnapshot.capture(
            roots: Array(build.generatedInputFiles),
            excluding: build.generatedInputExclusions, missingInputs: build.generatedMissingInputFiles)
        // Generated inputs may be written by this build, but never after its native operation completed.
        guard generatedInputs.predates(buildCompletedAt) else { return nil }
        let currentBuilder = try await builder.workspaceBuilder(for: destination)
        guard currentBuilder === workspaceBuilder, inputRevision == session.inputRevision else { return nil }
        return NativePreviewSession.BuildCertificate(build: build, workspaceBuilder: workspaceBuilder,
            inputs: inputs, generatedInputs: generatedInputs)
    }

    private func render(_ input: Input, artifactsRoot: URL) async throws -> JSONValue {
        guard let workspace = input.workspaceIdentifier else { throw NativeRuntimeError.invalidRequest("A workspaceIdentifier is required") }
        let identifier = UUID()
        let task = Task { @MainActor in
            try await self.renderQueue.withAccess(to: workspace) {
                try Task.checkCancellation()
                let session: NativePreviewSession
                if let existing = self.sessions[workspace] { session = existing }
                else {
                    let directory = URL(filePath: input.artifacts, directoryHint: .isDirectory)
                        .appendingPathComponent("PreviewSession-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    session = NativePreviewSession(directory: directory, artifactsRoot: artifactsRoot)
                    self.sessions[workspace] = session
                }
                do {
                    let prepared = try await self.prepare(input, session: session)
                    return try await self.renderApp(input, prepared: prepared, session: session)
                }
                catch {
                    let original = error
                    let cleanup = Task { @MainActor in try await session.close(installation: self.installation) }
                    do {
                        try await cleanup.value
                        if self.sessions[workspace] === session { self.sessions[workspace] = nil }
                    } catch { throw NativeRuntimeError.invocation("\(original); preview cleanup failed: \(error)") }
                    throw original
                }
            }
        }
        renders[identifier] = (workspace, task)
        defer { renders[identifier] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func withStagedDirectory<Output>(in artifacts: URL, operation: @MainActor (URL) async throws -> Output) async throws -> Output {
        let directory = artifacts.appendingPathComponent("Preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let result: Result<Output, any Error>
        do { result = .success(try await operation(directory)) }
        catch { result = .failure(error) }
        // FileManager cleanup is synchronous and still runs in a cancelled task.
        do { try FileManager.default.removeItem(at: directory) }
        catch {
            let outcome: String
            switch result {
            case .success: outcome = "Preview rendered"
            case .failure(let failure): outcome = String(describing: failure)
            }
            throw NativeRuntimeError.invocation("\(outcome); failed to remove staged preview directory \(directory.path): \(error)")
        }
        return try result.get()
    }

    struct RendererPreparation {
        var request: PreviewRendererRequest
        let app: URL
        let product: URL
        let containingApp: URL?
        let environment: [String: String]
        let selection: NativePreviewStaging.Selection
        let staticProduct: Bool
        let additionalProducts: [URL]
        let productSignature: NativePreviewProductSignature
    }

    private func prepareStage(_ input: Input, prepared: Prepared, session: NativePreviewSession,
                              build: NativePreviewBuild.Result, destination: NativePreviewBuild.DestinationSelection,
                              platform: NativePreviewPlatform, process: NativePreviewProcess,
                              metadataOnly: Bool? = nil, isLegacyComplication: Bool? = nil,
                              nativeWidget: Bool = false) async throws -> NativePreviewSession.RendererStage {
        let kind = nativeWidget ? "widget" : metadataOnly == true && prepared.location.providerPath != nil ? "provider" : "direct"
        let key = kind
        let stage: NativePreviewSession.RendererStage
        if let existing = session.stages[key] { stage = existing }
        else {
            let directory = session.stagesDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let renderer = try await prepareRenderer(input, prepared: prepared, directory: directory, build: build,
                destination: destination, platform: platform, process: process, digestCache: session.productDigests,
                metadataOnly: metadataOnly,
                isLegacyComplication: isLegacyComplication, nativeWidget: nativeWidget,
                additionalProducts: session.additionalProducts)
            stage = NativePreviewSession.RendererStage(renderer)
            session.stages[key] = stage
            session.additionalProducts = renderer.additionalProducts
            session.signature = renderer.productSignature
        }
        var request = stage.preparation.request
        request.fileName = prepared.source.lastPathComponent
        request.lineNumber = prepared.location.line
        request.columnNumber = prepared.location.column
        request.definitionIndex = input.index
        if let path = prepared.location.providerPath, let module = request.moduleName {
            request.providerTypeName = try await definitions.providerTypeName(path: path, moduleName: module)
        } else { request.providerTypeName = nil }
        if metadataOnly == true, let source = request.nativeSource, let provider = request.providerTypeName {
            request.nativeSource = .providerMetadata(extensionIdentifier: source.extensionIdentifier, providerName: provider)
        }
        request.localization = input.localization
        request.widgetFamily = input.widgetFamily
        request.widgetPresentation = input.widgetPresentation
        request.timelineIndex = input.timelineIndex
        request.groupItemIndex = input.groupItemIndex
        request.displayVariantOverrides = input.displayVariants
        request.activityViewStyle = input.activityViewStyle
        request.activityViewContext = input.activityViewContext
        request.activityToggleState = input.activityToggleState
        request.appName = try NativePreviewStaging.appName(product: stage.preparation.product,
            containingApp: stage.preparation.containingApp, localization: input.localization)
        request.metadataOnly = metadataOnly
        request.isLegacyComplication = isLegacyComplication
        stage.preparation.request = request
        return stage
    }

    private func prepareRenderer(_ input: Input, prepared: Prepared, directory: URL, build: NativePreviewBuild.Result,
                                 destination: NativePreviewBuild.DestinationSelection,
                                 platform: NativePreviewPlatform, process: NativePreviewProcess,
                                 digestCache: NativePreviewProductSignature.DigestCache,
                                 metadataOnly: Bool? = nil, isLegacyComplication: Bool? = nil,
                                 nativeWidget: Bool = false, additionalProducts: [URL] = []) async throws -> RendererPreparation {
        let source = prepared.source
        let location = prepared.location
        let selection = try NativePreviewStaging.selectTarget(build.targets, source: source, platform: platform)
        let target = selection.host
        guard let version = build.systemVersion, version.compare(platform.minimumVersion, options: .numeric) != .orderedAscending else {
            throw NativePipelineRequired()
        }
        guard let output = target.outputURL else {
            throw NativeRuntimeError.unsupportedContract("The preview target has no linked product")
        }
        let appProduct = NativePreviewStaging.productBundle(containing: output)
        let product: URL
        let sourceProduct: URL?
        if let appProduct {
            guard target.debugDylibEnabled else { throw NativePipelineRequired() }
            product = appProduct
            sourceProduct = nil
        } else {
            product = try await builder.frameworkAgent(for: destination)
            sourceProduct = NativePreviewStaging.frameworkBundle(containing: output) ?? output
        }
        let app = directory.appendingPathComponent(sourceProduct == nil ? "Preview.app" : product.lastPathComponent, isDirectory: true)
        let staticProduct = try selection.source.outputURL.map { try NativePreviewBinary.isStaticLibrary(at: $0) } ?? false
        let entitlements = try NativePreviewEntitlements.read(from: product)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/PreviewRenderer/\(platform.helperDirectory)")
        let containingApp = try NativePreviewStaging.containingApp(for: output, targets: build.targets)
        let originalProducts = additionalProducts + [product] + (sourceProduct.map { [$0] } ?? []) + (containingApp.map { [$0] } ?? [])
        let originalSignature = try await NativePreviewProductSignature.make(build: build, source: source, helper: helper,
            digestCache: digestCache,
            additionalProducts: originalProducts)
        let nativeExtensionIdentifier = ((metadataOnly == true && location.providerPath != nil) || nativeWidget)
            && (platform == .iOS || platform == .watchOS) && containingApp != nil
            ? try NativePreviewStaging.widgetExtensionIdentifier(product) : nil
        let clientIdentifier = (platform == .iOS || platform == .watchOS) && containingApp != nil
            ? "dev.xcodemcp.PreviewClient." + UUID().uuidString : nil
        let roots = sourceProduct == nil ? [selection.source] : build.previewRoots
        let copiedSourceProduct = sourceProduct.flatMap { product in
            roots.contains { $0.isDynamicPackageProduct && $0.outputURL.flatMap(NativePreviewStaging.frameworkBundle(containing:)) == product }
                ? nil : product
        }
        let products = try NativePreviewStaging.prepareApp(product: product, sourceProduct: copiedSourceProduct, helper: helper, app: app,
            containingApp: containingApp, platform: platform,
            clientIdentifier: clientIdentifier, staticProduct: staticProduct,
            resourceURLs: selection.source.resourceURLs)
        let linkedImages = try await nativeExtensionIdentifier == nil
            ? NativePreviewStaging.linkStaticProducts(for: roots, host: sourceProduct == nil ? selection.host : nil, in: app,
                products: products, platform: platform, process: process) : [:]
        let primaryImage = selection.source.outputURL.flatMap { linkedImages[$0.resolvingSymlinksInPath()]?.url }
        let dependencies = sourceProduct == nil && linkedImages.isEmpty ? NativePreviewStaging.FrameworkDependencies()
            : try NativePreviewStaging.frameworkDependencies(for: roots, targets: build.targets, platform: platform,
                in: products, agentApp: sourceProduct == nil ? nil : app,
                sourceProduct: copiedSourceProduct, linkedImages: linkedImages, environment: target.rendererEnvironment)
        let copiedProducts = Array(Set(originalProducts + Array(dependencies.products.keys)))
        let productSignature = try await NativePreviewProductSignature.make(build: build, source: source, helper: helper,
            digestCache: digestCache,
            additionalProducts: copiedProducts)
        try NativePreviewStaging.copyFrameworkDependencies(dependencies, into: products)
        if let simulatorEntitlements = entitlements.simulator {
            let section = app.deletingLastPathComponent().appendingPathComponent("simulator-entitlements.plist")
            try simulatorEntitlements.write(to: section)
            let archive = helper.appendingPathComponent("libXcodeMCPPreviewRenderer.a").path
            let sdk = try await process.xcrun(["--sdk", platform.sdk, "--show-sdk-path"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await process.xcrun(["--sdk", platform.sdk, "swiftc", "-target", platform.triple,
                "-sdk", sdk, archive, "-lc++", "-Xlinker", "-force_load", "-Xlinker", archive,
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements", "-Xlinker", section.path,
                "-o", platform.executableDirectory(in: app).appendingPathComponent("XcodeMCPPreviewRenderer").path])
        }
        let libraries: [URL]
        if nativeExtensionIdentifier != nil {
            libraries = []
        } else if sourceProduct != nil {
            libraries = dependencies.rootLibraries.map { products.appendingPathComponent($0) }
        } else {
            libraries = try primaryImage.map { [$0] } ?? NativePreviewStaging.previewLibraries(in: app, platform: platform)
        }
        let registryLibraries = try nativeExtensionIdentifier == nil
            ? NativePreviewStaging.registryLibraries(in: app, previewLibraries: libraries, products: products) : []
        let libraryPaths = try nativeExtensionIdentifier == nil ? NativePreviewStaging.libraryPaths(in: app, previewLibraries: libraries,
            registryLibraries: registryLibraries, sourceOutput: sourceProduct == nil ? primaryImage ?? selection.source.outputURL : nil,
            products: products) : []
        let names = try NativePreviewBinary.previewSymbols(in: registryLibraries).registryNames
        let providerName: String?
        if let path = location.providerPath {
            guard let moduleName = selection.source.moduleName else { throw NativePipelineRequired() }
            providerName = try await definitions.providerTypeName(path: path, moduleName: moduleName)
        } else { providerName = nil }
        let programRootNames: [String]
        do {
            let programOutputs: [URL]
            if sourceProduct != nil {
                programOutputs = roots.filter(\.containsPreviewSource).compactMap { root in
                    root.outputURL.map { linkedImages[$0.resolvingSymlinksInPath()]?.url ?? $0 }
                }
            } else { programOutputs = [primaryImage ?? output] }
            let programLibraries = try programOutputs.flatMap {
                try NativePreviewStaging.programLibraries(previewLibraries: registryLibraries, output: $0)
            }
            if programLibraries.isEmpty {
                programRootNames = []
            } else {
                programRootNames = try NativePreviewBinary.previewSymbols(in: programLibraries).programRootNames
            }
        }
        var request = PreviewRendererRequest(libraryNames: libraryPaths, registryNames: names,
            fileName: source.lastPathComponent, moduleName: selection.source.moduleName, lineNumber: location.line, columnNumber: location.column,
            definitionIndex: input.index, localization: input.localization, widgetFamily: input.widgetFamily,
            widgetPresentation: input.widgetPresentation,
            timelineIndex: input.timelineIndex, groupItemIndex: input.groupItemIndex,
            providerTypeName: providerName, programRootNames: programRootNames,
            displayVariantOverrides: input.displayVariants,
            activityViewStyle: input.activityViewStyle, activityViewContext: input.activityViewContext,
            activityToggleState: input.activityToggleState,
            appName: try NativePreviewStaging.appName(product: product, containingApp: containingApp, localization: input.localization),
            nativeEnvironment: target.rendererEnvironment.isEmpty ? nil : target.rendererEnvironment,
            metadataOnly: metadataOnly, isLegacyComplication: isLegacyComplication)
        if !selection.source.resourceURLs.isEmpty {
            request.packageResourceDirectory = "../" + products.pathComponents
                .dropFirst(app.deletingLastPathComponent().pathComponents.count).joined(separator: "/")
        }
        if metadataOnly == true, let nativeExtensionIdentifier, let providerName {
            request.libraryNames = []
            request.registryNames = []
            request.nativeSource = .providerMetadata(extensionIdentifier: nativeExtensionIdentifier, providerName: providerName)
        }
        // UUID-less source identity relies on unchanged bytes; relocate copies only after resolving their library paths.
        try await NativePreviewStaging.relocateFrameworkDependencies(dependencies, in: products, process: process)
        var signing = ["--force", "--sign", "-"]
        if let signedEntitlements = entitlements.signed {
            let plist = app.deletingLastPathComponent().appendingPathComponent("signed-entitlements.plist")
            try signedEntitlements.write(to: plist)
            signing += ["--entitlements", plist.path]
        }
        try await writeRendererRequest(request, app: app, platform: platform, signing: signing, process: process)
        guard try await originalSignature.matchesCurrentFiles(digestCache: digestCache),
              try await productSignature.matchesCurrentFiles(digestCache: digestCache) else {
            throw NativeRuntimeError.invocation("Build products changed while preparing the preview; render again")
        }
        return RendererPreparation(request: request, app: app, product: product, containingApp: containingApp,
            environment: target.rendererEnvironment, selection: selection, staticProduct: staticProduct,
            additionalProducts: copiedProducts, productSignature: productSignature)
    }

    private func nativeContainingApp(for renderer: RendererPreparation, build: NativePreviewBuild.Result,
                                     platform: NativePreviewPlatform, process: NativePreviewProcess) async throws -> URL? {
        guard let containingApp = renderer.containingApp, renderer.staticProduct else { return renderer.containingApp }
        return try await NativePreviewStaging.prepareNativeExtension(source: renderer.selection.source, host: renderer.selection.host,
            containingApp: containingApp, in: renderer.app.deletingLastPathComponent().appendingPathComponent("NativeHost", isDirectory: true),
            targets: build.targets, platform: platform, process: process)
    }

    private func nativeContainingApp(for stage: NativePreviewSession.RendererStage, build: NativePreviewBuild.Result,
                                     platform: NativePreviewPlatform, process: NativePreviewProcess) async throws -> URL? {
        if !stage.nativeHostPrepared {
            stage.containingApp = try await nativeContainingApp(for: stage.preparation, build: build, platform: platform, process: process)
            stage.nativeHostPrepared = true
        }
        return stage.containingApp
    }

    private func writeRendererRequest(_ request: PreviewRendererRequest, app: URL, platform: NativePreviewPlatform,
                                      signing: [String], process: NativePreviewProcess) async throws {
        try JSONEncoder().encode(request).write(to: platform.resourcesDirectory(in: app).appendingPathComponent("PreviewRequest.json"))
        _ = try await process.run("/usr/bin/codesign", signing + [app.path])
        try Task.checkCancellation()
    }

    private func renderApp(_ input: Input, prepared: Prepared, session: NativePreviewSession) async throws -> JSONValue {
        let artifacts = URL(filePath: input.artifacts, directoryHint: .isDirectory)
        let process = NativePreviewProcess(installation: installation, artifacts: artifacts)
        let workspace = prepared.workspace
        let location = prepared.location
        var destination = prepared.destination
        async let simulatorPreparation: Void = { @MainActor in
            try await session.prepareSimulator(destination: prepared.destination.selected, process: process)
        }()
        var build: NativePreviewBuild.Result
        if let retained = prepared.retainedBuild { build = retained.build }
        else { build = try await builder.build(workspace: workspace, destination: destination, source: prepared.source) }
        try await simulatorPreparation
        guard var platform = build.previewPlatform else { throw NativePipelineRequired() }
        try await session.update(build: build, source: prepared.source, platform: platform,
                         signature: prepared.retainedBuild?.signature, process: process)
        var stage = try await prepareStage(input, prepared: prepared, session: session, build: build,
            destination: destination, platform: platform, process: process, metadataOnly: true)
        var renderer = stage.preparation
        let metadataKey = NativePreviewSession.MetadataKey(index: input.index, localization: input.localization)
        let metadataEntry: NativePreviewSession.MetadataEntry
        if let cached = session.metadata[metadataKey] {
            metadataEntry = cached
        } else if platform.isSimulator {
            let containingApp = renderer.request.nativeSource == nil ? nil
                : try await nativeContainingApp(for: stage, build: build, platform: platform, process: process)
            metadataEntry = NativePreviewSession.MetadataEntry(response: try await renderSimulator(stage: stage, session: session, build: build, process: process,
                localization: input.localization,
                containingApp: containingApp).response)
        } else {
            metadataEntry = NativePreviewSession.MetadataEntry(response: try await desktopPreview(stage: stage, session: session, platform: platform, process: process,
                localization: input.localization).response)
        }
        session.metadata[metadataKey] = metadataEntry
        let metadataResponse = metadataEntry.response
        guard let metadata = metadataResponse.nativeMetadata else {
            throw NativeRuntimeError.invocation("The preview process returned no native metadata")
        }
        let evaluated: NativePreviewBuild.DestinationSelection
        if prepared.reusesDestination, session.plan != nil {
            evaluated = destination
        } else {
            let resolution = try await builder.resolveDestination(workspace: workspace, input: input.nativeValue)
            evaluated = try await builder.selectDestination(workspace: workspace, source: location.source,
                resolution: resolution, metadata: metadata,
                providerDescription: metadataResponse.nativeProviderPreviewDescription)
        }
        let unchanged = (destination.selected.value as? NSObject)?.isEqual(evaluated.selected.value) == true
        destination = evaluated
        if !unchanged {
            build = try await builder.build(workspace: workspace, destination: destination, source: prepared.source)
            guard let selectedPlatform = build.previewPlatform else { throw NativePipelineRequired() }
            platform = selectedPlatform
            try await session.update(build: build, source: prepared.source, platform: platform, process: process)
        }
        let planContext = try builder.planningContext(workspace: workspace, destination: destination)
        let isLegacyComplication: Bool?
        if platform == .watchOS, location.providerPath != nil {
            let complication: Bool
            if let cached = metadataEntry.isComplicationPreview { complication = cached }
            else {
                complication = try await builder.isComplicationPreview(metadata: metadata)
                metadataEntry.isComplicationPreview = complication
            }
            isLegacyComplication = complication ? true : nil
        } else { isLegacyComplication = nil }
        let nativeWidget: Bool
        if platform == .iOS || platform == .watchOS {
            if let cached = metadataEntry.isWidgetPreview { nativeWidget = cached }
            else {
                nativeWidget = try await builder.isWidgetPreview(metadata: metadata)
                metadataEntry.isWidgetPreview = nativeWidget
            }
        } else { nativeWidget = false }
        if unchanged && renderer.request.nativeSource == nil && !nativeWidget {
            renderer.request.metadataOnly = nil
            renderer.request.isLegacyComplication = isLegacyComplication
            stage.preparation = renderer
        } else {
            stage = try await prepareStage(input, prepared: prepared, session: session, build: build,
                destination: destination, platform: platform, process: process, isLegacyComplication: isLegacyComplication, nativeWidget: nativeWidget)
            renderer = stage.preparation
        }
        let nativeContainingApp: URL?
        if nativeWidget,
           let containingApp = renderer.containingApp,
           let extensionIdentifier = try NativePreviewStaging.widgetExtensionIdentifier(renderer.product) {
            let specification: Data
            if let registry = location.registry, let moduleName = renderer.request.moduleName {
                specification = try await definitions.registrySpecification(registry: registry, moduleName: moduleName)
            } else if let providerName = renderer.request.providerTypeName, let description = metadataResponse.nativeProviderPreviewDescription {
                specification = try await definitions.providerSpecification(name: providerName,
                    description: builder.decodePreviewValue(description, named: "PreviewDescription"))
            } else { throw NativePipelineRequired() }
            if !stage.nativeWidgetPrepared {
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/PreviewRenderer/\(platform.helperDirectory)")
                try NativePreviewStaging.removeStagedApp(renderer.app)
                try NativePreviewStaging.prepareApp(product: renderer.product, helper: helper, app: renderer.app, containingApp: containingApp, platform: platform,
                    clientIdentifier: "dev.xcodemcp.PreviewClient." + UUID().uuidString)
            }
            renderer.request.libraryNames = []
            renderer.request.registryNames = []
            renderer.request.nativeSource = .preview(extensionIdentifier: extensionIdentifier,
                specification: specification,
                metadata: metadata, variantOverrides: input.variantOverrides)
            if !stage.nativeWidgetPrepared {
                try await writeRendererRequest(renderer.request, app: renderer.app, platform: platform, signing: ["--force", "--sign", "-"], process: process)
                stage.nativeWidgetPrepared = true
            }
            stage.preparation = renderer
            nativeContainingApp = try await self.nativeContainingApp(for: stage, build: build,
                platform: platform, process: process)
        } else {
            nativeContainingApp = nil
        }
        let response: PreviewRendererResult
        let snapshotData: Data
        let exclusionData: Data?
        let deviceType: URL?
        let destinationFields: [String: JSONValue]
        if platform.isSimulator {
            let rendered = try await renderSimulator(stage: stage, session: session, build: build, process: process,
                localization: input.localization,
                containingApp: nativeContainingApp)
            response = rendered.response
            guard let snapshot = rendered.snapshot else { throw NativeRuntimeError.unsupportedContract("The preview renderer returned no snapshot") }
            snapshotData = snapshot
            exclusionData = rendered.exclusion
            deviceType = rendered.deviceType
            destinationFields = rendered.destination
        } else {
            let rendered = try await desktopPreview(stage: stage, session: session, platform: platform, process: process,
                localization: input.localization)
            response = rendered.response
            guard let data = rendered.snapshot else { throw NativeRuntimeError.invocation("The preview process returned no snapshot") }
            snapshotData = data
            exclusionData = nil
            deviceType = nil
            destinationFields = ["identifier": .string(build.previewDestinationIdentifier), "platformName": .string(build.platformName ?? "macOS")]
                .merging(build.deviceModelName.map { ["deviceModelName": .string($0)] } ?? [:], uniquingKeysWith: { _, new in new })
                .merging(build.systemVersion.map { ["systemVersion": .string($0)] } ?? [:], uniquingKeysWith: { _, new in new })
        }
        let snapshotURL = artifacts.appendingPathComponent("preview.png")
        try await writeSnapshot(from: snapshotData, to: snapshotURL, deviceType: deviceType,
            usesDeviceLayout: response.usesDeviceLayout == true, orientation: response.interfaceOrientation, exclusion: exclusionData)
        var fields: [String: JSONValue] = [
            "previewSnapshotPath": .string(snapshotURL.path),
            "errors": .array((destination.errors + (response.errors ?? [])).map { .object(["message": .string($0)]) }),
            "renderedDestination": .object(destinationFields),
            "supportedLocalizations": .array(try await supportedLocalizations(in: workspace).map(JSONValue.string)),
        ]
        fields["availableRenderDestinations"] = destination.available
        fields["displayName"] = .string(response.displayName ?? location.displayName)
        if let line = response.sourceLineNumber { fields["sourceLineNumber"] = .number(.int(Int64(line))) }
        if let indexes = response.timelineIndexes {
            var controls: [String: JSONValue] = [
                "timelineIndexes": .array(indexes.map { .number(.int(Int64($0))) }),
            ]
            if let states = response.toggleStates { controls["toggleStates"] = .array(states.map(JSONValue.bool)) }
            fields["supportedCanvasControlOverrides"] = .object(controls)
        }
        if let items = response.groupItems {
            fields["supportedCanvasControlOverrides"] = .object([
                "groupItems": .array(items.enumerated().map { index, title in
                    var item: [String: JSONValue] = ["index": .number(.int(Int64(index)))]
                    if let title { item["title"] = .string(title) }
                    return .object(item)
                }),
            ])
        }
        if let variants = response.supportedDisplayVariants {
            fields["supportedPreviewVariantOverrides"] = .object(variants.mapValues { .array($0.map(JSONValue.string)) })
        }
        if let styles = response.activityViewStyles, let contexts = response.activityViewContexts {
            fields["supportedPreviewVariantOverrides"] = .object([
                "View Style": .array(styles.map(JSONValue.string)),
                "Activity View Context": .array(contexts.map(JSONValue.string)),
                "Color Scheme": .array(PreviewRendererRequest.displayVariantValues["Color Scheme", default: []].map(JSONValue.string)),
                "Dynamic Type": .array(PreviewRendererRequest.displayVariantValues["Dynamic Type", default: []].map(JSONValue.string)),
            ])
        }
        var certificate: NativePreviewSession.BuildCertificate?
        if prepared.inputRevision == session.inputRevision {
            if unchanged, let reused = prepared.reusedCertificate {
                certificate = reused
            } else {
                do {
                    certificate = try await certifyBuild(build, workspace: workspace, destination: destination,
                        source: prepared.source, session: session, inputRevision: prepared.inputRevision)
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                }
            }
        }
        if prepared.context.matches(try builder.planningContext(workspace: workspace)),
           planContext.matches(try builder.planningContext(workspace: workspace, destination: destination)) {
            session.plan = NativePreviewSession.RetainedPlan(requestKey: input.requestKey, sourcePath: input.sourcePath,
                source: prepared.source, location: prepared.location, index: input.index, localization: input.localization,
                context: planContext, destination: destination, certificate: certificate)
        } else { session.plan = nil }
        return .object(fields)
    }

    private typealias RendererOutput = (response: PreviewRendererResult, snapshot: Data?, exclusion: Data?)

    private func startProcess(_ stage: NativePreviewSession.RendererStage, executable: String, arguments: [String],
                              environment: [String: String], log: URL, process: NativePreviewProcess) {
        stage.processLog = log
        stage.task = Task { @MainActor in
            do {
                _ = try await process.run(executable, arguments, environment: environment, outputLog: log)
                if !Task.isCancelled {
                    stage.processFailure = NativeRuntimeError.invocation("The preview renderer exited before the session ended; see \(log.path)")
                }
            } catch is CancellationError {
            } catch {
                stage.processFailure = error
                if Task.isCancelled { throw error }
            }
        }
    }

    private func waitForProcess(_ stage: NativePreviewSession.RendererStage, log: URL) async throws -> URL {
        while true {
            try Task.checkCancellation()
            if let error = stage.processFailure { throw error }
            if let data = try? Data(contentsOf: log) {
                let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                if let directory = lines.first(where: { $0.hasPrefix("XcodeMCPPreviewSession:") }),
                   let process = lines.first(where: { $0.hasPrefix("XcodeMCPPreviewProcess:") }),
                   let identifier = Int32(process.dropFirst("XcodeMCPPreviewProcess:".count)) {
                    stage.processIdentifier = identifier
                    return URL(filePath: String(directory.dropFirst("XcodeMCPPreviewSession:".count)), directoryHint: .isDirectory)
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func rendererCommand(_ stage: NativePreviewSession.RendererStage) async throws -> RendererOutput {
        guard let directory = stage.requestDirectory else {
            throw NativeRuntimeError.invocation("The preview renderer has no request directory")
        }
        return try await Self.withStagedDirectory(in: directory) { output in
            try await PreviewRendererFileEvents.withEvents(in: output) { changes, wake in
                stage.processFailureWake = { wake.yield(.changed) }
                defer { stage.processFailureWake = nil }
                let exitSource = stage.processIdentifier.map { identifier in
                    let source = DispatchSource.makeProcessSource(identifier: identifier, eventMask: .exit,
                        queue: .global(qos: .userInitiated))
                    source.setEventHandler { @Sendable in wake.yield(.changed) }
                    source.setRegistrationHandler { @Sendable in wake.yield(.changed) }
                    source.activate()
                    return source
                }
                defer { exitSource?.cancel() }
                let command = PreviewRendererCommand(identifier: output.lastPathComponent, request: stage.preparation.request)
                var events = changes.makeAsyncIterator()
                try JSONEncoder().encode(command).write(to: directory.appendingPathComponent("PreviewRequest.json"), options: .atomic)
                let resultURL = output.appendingPathComponent("PreviewResult.json")
                while !FileManager.default.fileExists(atPath: resultURL.path) {
                    try Task.checkCancellation()
                    if let error = stage.processFailure { throw error }
                    if let identifier = stage.processIdentifier, let executable = stage.executable,
                       try !NativePreviewSession.rendererIsRunning(identifier, executable: executable) {
                        throw NativeRuntimeError.invocation("The preview renderer process \(identifier) exited before returning a result")
                    }
                    guard let event = await events.next() else {
                        try Task.checkCancellation()
                        throw NativeRuntimeError.invocation("The preview result directory event stream ended")
                    }
                    if case .invalidated = event {
                        throw NativeRuntimeError.invocation("The preview result directory is no longer available")
                    }
                }
                let result = try JSONDecoder().decode(PreviewRendererResult.self, from: Data(contentsOf: resultURL))
                if result.requiresNativePipeline == true { throw NativePipelineRequired() }
                if let error = result.error { throw NativeRuntimeError.invocation(error) }
                let snapshot = try result.snapshotName.map { try Data(contentsOf: output.appendingPathComponent($0)) } ?? result.snapshotData
                let exclusion = try result.exclusionSnapshotName.map { try Data(contentsOf: output.appendingPathComponent($0)) }
                return (result, snapshot, exclusion)
            }
        }
    }

    private func desktopPreview(stage: NativePreviewSession.RendererStage, session: NativePreviewSession, platform: NativePreviewPlatform,
                                process: NativePreviewProcess, localization: String?) async throws -> RendererOutput {
        if stage.launched && stage.localization != localization { try await session.stop(stage, process: process) }
        if !stage.launched {
            let executable = platform.executableDirectory(in: stage.preparation.app).appendingPathComponent("XcodeMCPPreviewRenderer")
            let log = session.directory.deletingLastPathComponent().appendingPathComponent("process-renderer-\(UUID().uuidString).log")
            startProcess(stage, executable: executable.path,
                arguments: try Self.rendererArguments(localization: localization) + ["--preview-session-directory", "automatic:" + UUID().uuidString],
                environment: stage.preparation.environment, log: log, process: process)
            stage.executable = executable
            stage.requestDirectory = try await waitForProcess(stage, log: log)
            stage.localization = localization
            stage.launched = true
        }
        return try await rendererCommand(stage)
    }

    private func renderSimulator(stage: NativePreviewSession.RendererStage, session: NativePreviewSession, build: NativePreviewBuild.Result,
                                 process: NativePreviewProcess, localization: String?, containingApp: URL? = nil) async throws ->
        (response: PreviewRendererResult, snapshot: Data?, destination: [String: JSONValue], deviceType: URL, exclusion: Data?) {
        let app = stage.preparation.app
        let info = try NativePreviewStaging.bundleInfo(at: app)
        guard let bundle = info["CFBundleIdentifier"] as? String else {
            throw NativeRuntimeError.unsupportedContract("The preview product has no bundle identifier")
        }
        let simctl = session.simctlArguments
        try await session.prepareSimulator(destination: NativePreviewSession.SimulatorDestination(build),
            platformName: build.platformName, deviceModelName: build.deviceModelName, process: process)
        guard let simulator = session.simulator else { throw NativeRuntimeError.invocation("The preview Simulator was not created") }
        if !stage.installed {
            if stage.processIdentifier != nil { try await session.stop(stage, process: process) }
            for other in session.stages.values where other !== stage && other.installed {
                if try NativePreviewStaging.bundleInfo(at: other.preparation.app)["CFBundleIdentifier"] as? String == bundle {
                    try await session.stop(other, process: process)
                    other.installed = false
                }
            }
            if let containingApp {
                guard let containingIdentifier = try NativePreviewStaging.bundleInfo(at: containingApp)["CFBundleIdentifier"] as? String else {
                    throw NativeRuntimeError.unsupportedContract("The preview containing app has no bundle identifier")
                }
                _ = try await process.xcrun(simctl + ["install", simulator.identifier, containingApp.path])
                session.installedApplications.insert(containingIdentifier)
            }
            _ = try await process.xcrun(simctl + ["install", simulator.identifier, app.path])
            session.installedApplications.insert(bundle)
            let installed = try await process.xcrun(simctl + ["get_app_container", simulator.identifier, bundle, "app"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let installedApp = URL(filePath: installed, directoryHint: .isDirectory)
            stage.executable = installedApp.appendingPathComponent("XcodeMCPPreviewRenderer")
            let container = try await process.xcrun(simctl + ["get_app_container", simulator.identifier, bundle, "data"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            stage.documents = URL(filePath: container, directoryHint: .isDirectory).appendingPathComponent("Documents")
            let products = app.deletingLastPathComponent().appendingPathComponent("Products", isDirectory: true)
            if FileManager.default.fileExists(atPath: products.path) {
                let destination = installedApp.deletingLastPathComponent().appendingPathComponent("Products", isDirectory: true)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: products, to: destination)
            }
            stage.installed = true
        }
        if containingApp != nil {
            // Metadata capture can foreground another helper between native service requests.
            _ = try await process.xcrun(simctl + ["launch", simulator.identifier, "com.apple.PreviewShell"])
            session.activeUIStage = nil
        }
        if stage.launched && stage.localization != localization { try await session.stop(stage, process: process) }
        guard let documents = stage.documents else { throw NativeRuntimeError.invocation("The installed renderer has no data container") }
        let arguments = try Self.rendererArguments(localization: localization)
        let environment = Dictionary(uniqueKeysWithValues: stage.preparation.environment.map { ("SIMCTL_CHILD_" + $0.key, $0.value) })
        let rendered: RendererOutput
        if stage.preparation.request.isLegacyComplication == true {
            try await session.stop(stage, process: process)
            let requestURL = documents.appendingPathComponent("PreviewRequest.json")
            try JSONEncoder().encode(stage.preparation.request).write(to: requestURL, options: .atomic)
            let resultURL = documents.appendingPathComponent("PreviewResult.json")
            if FileManager.default.fileExists(atPath: resultURL.path) { try FileManager.default.removeItem(at: resultURL) }
            let launch = try await process.xcrun(simctl + ["launch", "--terminate-running-process", simulator.identifier, bundle,
                "--preview-request-file", requestURL.path] + arguments, environment: environment)
            stage.processIdentifier = launch.split(separator: ":").last.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            session.activeUIStage = stage
            while !FileManager.default.fileExists(atPath: resultURL.path) { try await Task.sleep(for: .milliseconds(25)) }
            let response = try JSONDecoder().decode(PreviewRendererResult.self, from: Data(contentsOf: resultURL))
            if response.requiresNativePipeline == true { throw NativePipelineRequired() }
            if let error = response.error { throw NativeRuntimeError.invocation(error) }
            let snapshot = try response.snapshotName.map { try Data(contentsOf: documents.appendingPathComponent($0)) }
            let exclusion = try response.exclusionSnapshotName.map { try Data(contentsOf: documents.appendingPathComponent($0)) }
            rendered = (response, snapshot, exclusion)
        } else {
            if !stage.launched {
                let directory = documents.appendingPathComponent("XcodeMCPPreviewSession-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                stage.requestDirectory = directory
                if containingApp != nil {
                    guard let executable = stage.executable else { throw NativeRuntimeError.invocation("The installed renderer has no executable") }
                    let log = session.directory.deletingLastPathComponent().appendingPathComponent("process-renderer-\(UUID().uuidString).log")
                    startProcess(stage, executable: "/usr/bin/xcrun", arguments: simctl + ["spawn", simulator.identifier, executable.path,
                        "--native-preview-result-directory", documents.path, "--preview-session-directory", directory.path] + arguments,
                        environment: environment, log: log, process: process)
                    stage.requestDirectory = try await waitForProcess(stage, log: log)
                } else {
                    let output = try await process.xcrun(simctl + ["launch", "--terminate-running-process", simulator.identifier, bundle,
                        "--preview-session-directory", directory.path] + arguments, environment: environment)
                    stage.processIdentifier = output.split(separator: ":").last.flatMap {
                        Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                stage.localization = localization
                stage.launched = true
                if containingApp == nil { session.activeUIStage = stage }
            }
            if containingApp == nil, session.activeUIStage !== stage {
                _ = try await process.xcrun(simctl + ["launch", simulator.identifier, bundle,
                    "--preview-session-directory", stage.requestDirectory!.path] + arguments, environment: environment)
                session.activeUIStage = stage
            }
            rendered = try await rendererCommand(stage)
        }
        return (rendered.response, rendered.snapshot, simulator.destination, simulator.deviceType, rendered.exclusion)
    }

    private func supportedLocalizations(in workspace: AnyObject) async throws -> [String] {
        let runtime = ABIRuntime.shared
        let getLocalizations = try await runtime.object(workspace).resolve(
            .swift(
                .getter(
                    "(extension in PreviewsXcode):__C.IDEWorkspace.supportedLocalizations.getter : [PreviewsXcode.Locale]", as: (() -> NativeSwiftValue).self)))
        let localizations = try unsafe getLocalizations.unsafeInvoke()
        let type = try await runtime.resolve(.swift(.type("PreviewsXcode.Locale")), in: .path(installation.framework("PreviewsXcode", in: "PlugIns")))
        let getLocale = try await type.resolve(
            .swift(.getter("locale.getter : __C.DVTLocale", as: (() -> AnyObject).self, receiverABI: .opaque(named: type.name))))
        return try localizations.withCopy { value in
            guard let values = value as? [Any] else {
                throw NativeRuntimeError.unsupportedContract("Native supported localizations are not an array")
            }
            return try values.map { value in
                let locale = try unsafe getLocale.unsafeInvoke(on: value)
                let identifier = try runtime.object(locale).resolveAndWait(.objc(.method("localeIdentifier", as: (() -> String).self)))
                return try unsafe identifier.unsafeInvoke()
            }
        }
    }

    private func workspace(_ identifier: String?) async throws -> AnyObject {
        let type = try await ABIRuntime.shared.resolve(.swift(.type("IDEFoundation.IDEWorkspaceRegistry")), in: .path(installation.framework("IDEFoundation")))
        let shared = try await type.resolve(.swift(.staticGetter("shared.getter : IDEFoundation.IDEWorkspaceRegistry", as: (() -> AnyObject).self)))
        let registry = try unsafe shared.unsafeInvoke()
        guard let identifier else { throw NativeRuntimeError.invalidRequest("A workspaceIdentifier is required") }
        let lookup = try await type.resolve(
            .swift(.method("workspace(withIdentifier: Swift.String) -> Swift.Optional<__C.IDEWorkspace>", as: ((String) -> AnyObject?).self)))
        guard let workspace = try unsafe lookup.unsafeInvoke(on: registry, identifier) else {
            throw NativeRuntimeError.invalidRequest("Workspace '\(identifier)' is not open")
        }
        return workspace
    }

    static func rendererArguments(localization: String?) throws -> [String] {
        guard let localization else { return [] }
        let languages = try PropertyListSerialization.data(fromPropertyList: [localization], format: .xml, options: 0)
        return ["-AppleLanguages", String(decoding: languages, as: UTF8.self), "-AppleLocale", localization]
    }

    @MainActor
    private struct Input {
        let nativeValue: NativeSwiftValue
        let requestKey: [String: JSONValue]
        let workspaceIdentifier: String?
        let artifacts: String
        let sourcePath: String
        let index: Int
        let localization: String?
        let timeout: Int
        let widgetFamily: String?
        let widgetPresentation: String?
        let timelineIndex: Int?
        let groupItemIndex: Int?
        let displayVariants: [String: String]
        let activityViewStyle: String?
        let activityViewContext: String?
        let activityToggleState: Bool?
        let requiresNativePipeline: Bool
        let variantOverrides: [String: String]
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> Input {
        let value = try JSONDecoder().decode(type, from: data)
        guard let json = JSONValue(any: try JSONSerialization.jsonObject(with: data)),
              case .object(let arguments) = json else {
            throw NativeRuntimeError.invalidRequest("Native preview input must be an object")
        }
        let requestKey = arguments.filter {
            !["temporaryArtifactsPath", "conversationID", "workspaceIdentifier", "timeout"].contains($0.key)
        }
        let identity = try ABIRuntime.shared.resolveAndWait(
            .swift(.function("XcodeMCPNativeRuntime.nativePreviewValue<A>(A) -> A", as: ((T) -> NativeSwiftValue).self, genericArguments: [.type(type)])))
        let nativeValue = try unsafe identity.unsafeInvoke(value)
        let fields = Dictionary(uniqueKeysWithValues: Mirror(reflecting: value).children.compactMap { field in field.label.map { ($0, field.value) } })
        guard let artifacts = fields["temporaryArtifactsPath"] as? String,
              let path = fields["sourceFilePath"] as? String else {
            throw NativeRuntimeError.unsupportedContract("Native preview input fields have changed")
        }
        let index: Int = try Self.decodedProperty("previewDefinitionIndexInFile", in: fields)
        let variants: [String: String] = try Self.decodedProperty("previewVariantOverrides", in: fields)
        let timeout: Int = try Self.decodedProperty("timeout", in: fields)
        let controls = fields["previewCanvasControlOverrides"].flatMap { Mirror(reflecting: $0).children.first?.value }
        let controlFields = controls.map { Dictionary(uniqueKeysWithValues: Mirror(reflecting: $0).children.compactMap { field in field.label.map { ($0, field.value) } }) } ?? [:]
        let options = Self.directOptions(variants: variants, controls: controlFields)
        return Input(nativeValue: nativeValue, requestKey: requestKey,
            workspaceIdentifier: fields["workspaceIdentifier"] as? String? ?? nil, artifacts: artifacts, sourcePath: path,
            index: index, localization: fields["previewLocalizationOverride"] as? String? ?? nil,
            timeout: timeout,
            widgetFamily: options.widgetFamily, widgetPresentation: options.widgetPresentation,
            timelineIndex: options.timelineIndex, groupItemIndex: options.groupItemIndex,
            displayVariants: options.displayVariants, activityViewStyle: options.activityViewStyle,
            activityViewContext: options.activityViewContext, activityToggleState: options.activityToggleState,
            requiresNativePipeline: options.requiresNativePipeline, variantOverrides: variants)
    }

    static func decodedProperty<Value>(_ name: String, in fields: [String: Any]) throws -> Value {
        if let value = fields[name] as? Value { return value }
        // Xcode can inline Default's accessors. Its decoded storage still contains
        // the provider's defaults, which the request JSON need not include.
        if let wrapper = fields["_" + name],
           let value = Mirror(reflecting: wrapper).children.first(where: { $0.label == "wrappedValue" })?.value as? Value {
            return value
        }
        throw NativeRuntimeError.unsupportedContract("Native preview input field '\(name)' has changed")
    }

    static func directOptions(variants: [String: String], controls: [String: Any]) ->
        (widgetFamily: String?, widgetPresentation: String?, timelineIndex: Int?, groupItemIndex: Int?,
         displayVariants: [String: String], activityViewStyle: String?, activityViewContext: String?,
         activityToggleState: Bool?, requiresNativePipeline: Bool) {
        let family = variants["Widget Family"]
        let presentation = variants["Presentation"]
        let timeline = controls["timelineIndex"].flatMap { Mirror(reflecting: $0).children.first?.value as? Int }
        let groupItem = controls["groupItemIndex"].flatMap { Mirror(reflecting: $0).children.first?.value as? Int }
        let toggle = controls["toggleState"].flatMap { Mirror(reflecting: $0).children.first?.value as? Bool }
        // The selected renderer owns the catalog. Preserve unknown groups so it
        // can return the native warning alongside the valid overrides' image.
        let displayVariants = variants.filter {
            !["Widget Family", "Presentation", "View Style", "Activity View Context"].contains($0.key)
        }
        let unsupportedControl = controls.contains { key, value in
            key != "timelineIndex" && key != "groupItemIndex" && key != "toggleState" && Mirror(reflecting: value).children.first != nil
        }
        return (family, presentation, timeline, groupItem, displayVariants, variants["View Style"], variants["Activity View Context"], toggle,
                unsupportedControl)
    }

    private func event(_ type: String, _ value: JSONValue) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "data": value.foundationObject])
    }

    private func errorEvent(_ error: any Error) -> Data {
        do { return try event("error", .string(String(describing: error))) }
        catch let encodingError {
            NativeHostDiagnostic.report("Native preview failed: \(error); error encoding also failed: \(encodingError)")
            return Data(#"{"type":"error","data":"Could not encode the native preview failure; see host diagnostics"}"#.utf8)
        }
    }
}

struct NativePipelineRequired: Error {}

// Generic calls supply the native enum's indirect ABI and retained ownership.
@inline(never)
package func nativePreviewValue<T>(_ value: T) -> T { value }
