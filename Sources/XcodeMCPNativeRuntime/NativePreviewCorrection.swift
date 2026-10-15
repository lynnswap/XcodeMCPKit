import ABIBridge
import Foundation
import XcodeMCPWire

@MainActor
final class NativePreviewCorrection {
    private let installation: NativeXcodeInstallation
    private let builder: NativePreviewBuild
    private var operations: [UUID: Task<Void, Never>] = [:]

    init(installation: NativeXcodeInstallation) {
        self.installation = installation
        builder = NativePreviewBuild(installation: installation)
    }

    static func handles(_ action: NativeActionClass) -> Bool {
        let type = unsafe unsafeBitCast(action.metadata, to: Any.Type.self)
        return String(reflecting: type) == "PreviewsXcode.RenderPreviewAction"
    }

    static func describe(_ tool: NativeTool) -> NativeTool {
        guard case .object(var fields) = tool.descriptor,
              case .object(var output) = fields["outputSchema"],
              case .object(var properties) = output["properties"],
              case .object(var snapshot) = properties["previewSnapshotPath"] else { return tool }
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

    func execute(inputType: Any.Type, input: Data,
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
                try await produce(parameters, continuation: stream.continuation, native: native)
            } catch {
                if !Task.isCancelled {
                    stream.continuation.yield(errorEvent(error))
                } else if !(error is CancellationError) {
                    try? FileHandle.standardError.write(contentsOf: Data("Native preview cancellation failed: \(error)\n".utf8))
                }
            }
        }
        operations[identifier] = task
        stream.continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream.stream
    }

    func cancelPendingOperations() {
        for task in operations.values { task.cancel() }
        builder.cancelPendingOperations()
    }

    func shutdown() async {
        cancelPendingOperations()
        for task in Array(operations.values) { await task.value }
    }

    private func produce(_ input: Input, continuation: AsyncStream<Data>.Continuation,
                         native: @escaping @MainActor @Sendable () async throws -> AsyncStream<Data>) async throws {
        let prepared: Prepared
        do {
            guard !input.requiresNativePipeline else { throw NativePipelineRequired() }
            prepared = try await prepare(input)
        } catch is NativePipelineRequired {
            try await relayNative(native, continuation: continuation)
            return
        }
        let result: JSONValue? = try await Self.withTimeout(seconds: input.timeout) {
            do {
                return try await self.render(input, prepared: prepared)
            } catch is NativePipelineRequired {
                try await self.relayNative(native, continuation: continuation)
                return nil
            }
        }
        try Task.checkCancellation()
        if let result { continuation.yield(try event("completed", result)) }
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
        let location: Definition
        let destination: NativePreviewBuild.DestinationSelection
    }

    private func prepare(_ input: Input) async throws -> Prepared {
        try Task.checkCancellation()
        let workspace = try await workspace(input.workspaceIdentifier)
        let source = try await sourceURL(input.sourcePath, workspace: workspace)
        let location = try await previewDefinition(source: source, index: input.index)
        guard let destination = try await builder.selectDestination(workspace: workspace, source: location.source, input: input.nativeValue) else {
            throw NativePipelineRequired()
        }
        // Native rendering starts its timeout after resolving the source and
        // destination. Binding the adapter must not consume the build budget.
        _ = try await builder.prepare(workspace: workspace)
        try Task.checkCancellation()
        return Prepared(workspace: workspace, source: source, location: location, destination: destination)
    }

    private func render(_ input: Input, prepared: Prepared) async throws -> JSONValue {
        try await Self.withStagedApp(in: URL(filePath: input.artifacts, directoryHint: .isDirectory)) { app in
            try await renderApp(input, prepared: prepared, app: app)
        }
    }

    static func withStagedApp<Output>(in artifacts: URL, operation: @MainActor (URL) async throws -> Output) async throws -> Output {
        let directory = artifacts.appendingPathComponent("Preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let app = directory.appendingPathComponent("Preview.app", isDirectory: true)
        let result: Result<Output, any Error>
        do { result = .success(try await operation(app)) }
        catch { result = .failure(error) }
        // FileManager cleanup is synchronous and still runs in a cancelled task.
        do { try FileManager.default.removeItem(at: directory) }
        catch {
            let outcome: String
            switch result {
            case .success: outcome = "Preview rendered"
            case .failure(let failure): outcome = String(describing: failure)
            }
            throw NativeRuntimeError.invocation("\(outcome); failed to remove staged preview app \(app.path): \(error)")
        }
        return try result.get()
    }

    static func removeStagedApp(_ app: URL) throws {
        try FileManager.default.removeItem(at: app)
        let products = app.deletingLastPathComponent().appendingPathComponent("Products", isDirectory: true)
        if FileManager.default.fileExists(atPath: products.path) { try FileManager.default.removeItem(at: products) }
    }

    private func prepareRenderer(_ input: Input, prepared: Prepared, app: URL, build: NativePreviewBuild.Result,
                                 platform: NativePreviewPlatform, process: NativePreviewProcess,
                                 metadataOnly: Bool? = nil, isLegacyComplication: Bool? = nil) async throws ->
        (request: PreviewRendererRequest, signing: [String], product: URL, containingApp: URL?, environment: [String: String]) {
        let source = prepared.source
        let location = prepared.location
        let selection = try Self.selectTarget(build.targets, source: source, platform: platform)
        let target = selection.host
        guard let version = build.systemVersion, version.compare(platform.minimumVersion, options: .numeric) != .orderedAscending else {
            throw NativePipelineRequired()
        }
        guard let output = target.outputURL else {
            throw NativeRuntimeError.unsupportedContract("The preview target has no linked product")
        }
        let appProduct = Self.productBundle(containing: output)
        let standaloneFramework = appProduct == nil ? Self.frameworkBundle(containing: output) : nil
        let product: URL
        if let appProduct {
            guard target.debugDylibEnabled else { throw NativePipelineRequired() }
            product = appProduct
        } else if let standaloneFramework { product = standaloneFramework }
        else { throw NativePipelineRequired() }
        let staticFramework = try standaloneFramework != nil && NativePreviewBinary.isStaticArchive(at: output)
        // A static archive has no executable signature or Simulator entitlement section.
        let entitlements = staticFramework ? NativePreviewEntitlements(signed: nil, simulator: nil)
            : try NativePreviewEntitlements.read(from: product)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/PreviewRenderer/\(platform.helperDirectory)")
        let containingApp = try Self.containingApp(for: output, targets: build.targets)
        let nativeProviderIdentifier = metadataOnly == true && location.providerPath != nil
            && (platform == .iOS || platform == .watchOS) && containingApp != nil
            ? try Self.widgetExtensionIdentifier(product) : nil
        let products = try Self.prepareApp(product: product, helper: helper, app: app, containingApp: containingApp, platform: platform,
            clientIdentifier: nativeProviderIdentifier.map { _ in "dev.xcodemcp.PreviewClient." + UUID().uuidString }, staticFramework: staticFramework)
        let linkedImage: LinkedPreviewImage?
        if staticFramework {
            linkedImage = try await Self.linkStaticFramework(target, in: products, platform: platform, process: process)
        } else { linkedImage = nil }
        let primaryImage = linkedImage?.url
        let dependencies = standaloneFramework == nil ? FrameworkDependencies()
            : try Self.frameworkDependencies(for: target, targets: build.targets, platform: platform, primaryImage: linkedImage)
        try Self.copyFrameworkDependencies(dependencies, into: products)
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
        let libraries = try primaryImage.map { [$0] }
            ?? (standaloneFramework == nil ? previewLibraries(in: app, platform: platform) : [])
        let registryLibraries = try Self.registryLibraries(in: app, previewLibraries: libraries, products: products)
        let libraryPaths = try Self.libraryPaths(in: app, previewLibraries: libraries,
            registryLibraries: registryLibraries, sourceOutput: primaryImage ?? selection.source.outputURL, products: products)
        let symbols = try await process.xcrun(["nm", "-j"] + registryLibraries.map(\.path))
        let names = Self.registryNames(in: symbols)
        let providerName: String?
        if let path = location.providerPath {
            guard let moduleName = selection.source.moduleName else { throw NativePipelineRequired() }
            providerName = try await providerTypeName(path: path, moduleName: moduleName)
        } else { providerName = nil }
        let programRootNames: [String]?
        if providerName != nil {
            let programLibraries = try Self.programLibraries(previewLibraries: registryLibraries, output: primaryImage ?? output)
            if programLibraries.isEmpty {
                programRootNames = []
            } else {
                let symbols = try await process.xcrun(["nm", "-j", "-U"] + programLibraries.map(\.path))
                programRootNames = Self.programRootNames(in: symbols)
            }
        } else { programRootNames = nil }
        var request = PreviewRendererRequest(libraryNames: libraryPaths, registryNames: names,
            fileName: source.lastPathComponent, moduleName: selection.source.moduleName, lineNumber: location.line, columnNumber: location.column,
            definitionIndex: input.index, localization: input.localization, widgetFamily: input.widgetFamily,
            widgetPresentation: input.widgetPresentation,
            timelineIndex: input.timelineIndex, groupItemIndex: input.groupItemIndex,
            providerTypeName: providerName, programRootNames: programRootNames,
            displayVariantOverrides: input.displayVariants,
            activityViewStyle: input.activityViewStyle, activityViewContext: input.activityViewContext,
            activityToggleState: input.activityToggleState,
            appName: try Self.appName(product: product, containingApp: containingApp, localization: input.localization),
            nativeEnvironment: target.rendererEnvironment.isEmpty ? nil : target.rendererEnvironment,
            metadataOnly: metadataOnly, isLegacyComplication: isLegacyComplication)
        if let nativeProviderIdentifier, let providerName {
            request.libraryNames = []
            request.registryNames = []
            request.nativeSource = .providerMetadata(extensionIdentifier: nativeProviderIdentifier, providerName: providerName)
        }
        // UUID-less source identity relies on unchanged bytes; relocate copies only after resolving their library paths.
        try await Self.relocateFrameworkDependencies(dependencies, in: products, process: process)
        var signing = ["--force", "--sign", "-"]
        if let signedEntitlements = entitlements.signed {
            let plist = app.deletingLastPathComponent().appendingPathComponent("signed-entitlements.plist")
            try signedEntitlements.write(to: plist)
            signing += ["--entitlements", plist.path]
        }
        try await writeRendererRequest(request, app: app, platform: platform, signing: signing, process: process)
        return (request, signing, product, containingApp, target.rendererEnvironment)
    }

    private func writeRendererRequest(_ request: PreviewRendererRequest, app: URL, platform: NativePreviewPlatform,
                                      signing: [String], process: NativePreviewProcess) async throws {
        try JSONEncoder().encode(request).write(to: platform.resourcesDirectory(in: app).appendingPathComponent("PreviewRequest.json"))
        _ = try await process.run("/usr/bin/codesign", signing + [app.path])
        try Task.checkCancellation()
    }

    private func desktopPreview(app: URL, platform: NativePreviewPlatform, process: NativePreviewProcess,
                                localization: String?, environment: [String: String]) async throws -> PreviewRendererResult {
        let text = try await process.run(platform.executableDirectory(in: app).appendingPathComponent("XcodeMCPPreviewRenderer").path,
            Self.rendererArguments(localization: localization), environment: environment)
        guard let record = text.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("XcodeMCPPreviewResult:") }) else {
            throw NativeRuntimeError.invocation("The preview process returned no result; see its process log")
        }
        let result = try JSONDecoder().decode(PreviewRendererResult.self, from: Data(record.dropFirst("XcodeMCPPreviewResult:".count).utf8))
        if result.requiresNativePipeline == true { throw NativePipelineRequired() }
        if let error = result.error { throw NativeRuntimeError.invocation(error) }
        return result
    }

    private func renderApp(_ input: Input, prepared: Prepared, app: URL) async throws -> JSONValue {
        let artifacts = URL(filePath: input.artifacts, directoryHint: .isDirectory)
        let process = NativePreviewProcess(installation: installation, artifacts: artifacts)
        let workspace = prepared.workspace
        let location = prepared.location
        var destination = prepared.destination
        var build = try await builder.build(workspace: workspace, destination: destination, source: prepared.source)
        guard var platform = build.previewPlatform else { throw NativePipelineRequired() }
        var renderer = try await prepareRenderer(input, prepared: prepared, app: app, build: build,
            platform: platform, process: process, metadataOnly: true)
        let metadataResponse: PreviewRendererResult
        if platform.isSimulator {
            metadataResponse = try await renderSimulator(app: app, build: build, process: process,
                localization: input.localization, environment: renderer.environment,
                containingApp: renderer.request.nativeSource == nil ? nil : renderer.containingApp).response
        } else {
            metadataResponse = try await desktopPreview(app: app, platform: platform, process: process,
                localization: input.localization, environment: renderer.environment)
        }
        guard let metadata = metadataResponse.nativeMetadata else {
            throw NativeRuntimeError.invocation("The preview process returned no native metadata")
        }
        guard let evaluated = try await builder.selectDestination(workspace: workspace, source: location.source,
            input: input.nativeValue, metadata: metadata,
            providerDescription: metadataResponse.nativeProviderPreviewDescription) else { throw NativePipelineRequired() }
        let unchanged = (destination.selected.value as? NSObject)?.isEqual(evaluated.selected.value) == true
        destination = evaluated
        if !unchanged {
            build = try await builder.build(workspace: workspace, destination: destination, source: prepared.source)
            guard let selectedPlatform = build.previewPlatform else { throw NativePipelineRequired() }
            platform = selectedPlatform
        }
        let isLegacyComplication: Bool?
        if platform == .watchOS, location.providerPath != nil {
            isLegacyComplication = try await builder.isComplicationPreview(metadata: metadata) ? true : nil
        } else { isLegacyComplication = nil }
        if unchanged && renderer.request.nativeSource == nil {
            renderer.request.metadataOnly = nil
            renderer.request.isLegacyComplication = isLegacyComplication
            try await writeRendererRequest(renderer.request, app: app, platform: platform, signing: renderer.signing, process: process)
        } else {
            try Self.removeStagedApp(app)
            renderer = try await prepareRenderer(input, prepared: prepared, app: app, build: build,
                platform: platform, process: process, isLegacyComplication: isLegacyComplication)
        }
        let nativeContainingApp: URL?
        if (platform == .iOS || platform == .watchOS), try await builder.isWidgetPreview(metadata: metadata),
           let containingApp = renderer.containingApp,
           let extensionIdentifier = try Self.widgetExtensionIdentifier(renderer.product) {
            let specification: Data
            if let registry = location.registry, let moduleName = renderer.request.moduleName {
                specification = try await registrySpecification(registry: registry, moduleName: moduleName)
            } else if let providerName = renderer.request.providerTypeName, let description = metadataResponse.nativeProviderPreviewDescription {
                specification = try await providerSpecification(name: providerName, description: description)
            } else { throw NativePipelineRequired() }
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/PreviewRenderer/\(platform.helperDirectory)")
            try Self.removeStagedApp(app)
            try Self.prepareApp(product: renderer.product, helper: helper, app: app, containingApp: containingApp, platform: platform,
                clientIdentifier: "dev.xcodemcp.PreviewClient." + UUID().uuidString)
            renderer.request.libraryNames = []
            renderer.request.registryNames = []
            renderer.request.nativeSource = .preview(extensionIdentifier: extensionIdentifier,
                specification: specification,
                metadata: metadata, variantOverrides: input.variantOverrides)
            try await writeRendererRequest(renderer.request, app: app, platform: platform, signing: ["--force", "--sign", "-"], process: process)
            nativeContainingApp = containingApp
        } else {
            nativeContainingApp = nil
        }
        let response: PreviewRendererResult
        let snapshotData: Data
        let exclusionData: Data?
        let deviceType: URL?
        let destinationFields: [String: JSONValue]
        if platform.isSimulator {
            let rendered = try await renderSimulator(app: app, build: build, process: process,
                localization: input.localization, environment: renderer.environment,
                containingApp: nativeContainingApp)
            response = rendered.response
            guard let snapshot = rendered.snapshot else { throw NativeRuntimeError.unsupportedContract("The preview renderer returned no snapshot") }
            snapshotData = snapshot
            exclusionData = rendered.exclusion
            deviceType = rendered.deviceType
            destinationFields = rendered.destination
        } else {
            response = try await desktopPreview(app: app, platform: platform, process: process,
                localization: input.localization, environment: renderer.environment)
            guard let data = response.snapshotData else { throw NativeRuntimeError.invocation("The preview process returned no snapshot") }
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
        return .object(fields)
    }

    private func renderSimulator(app: URL, build: NativePreviewBuild.Result, process: NativePreviewProcess,
                                 localization: String?, environment: [String: String],
                                 containingApp: URL? = nil) async throws ->
        (response: PreviewRendererResult, snapshot: Data?, destination: [String: JSONValue], deviceType: URL, exclusion: Data?) {
        // Keep allocation alive through cancellation so its created identifier
        // is always available to the cleanup owner below.
        let allocation = Task { @MainActor in
            try await createSimulator(app: app, build: build, process: process)
        }
        let simulator = try await allocation.value
        var rendered: (PreviewRendererResult, Data?, Data?)?
        var failure: (any Error)?
        do {
            _ = try await process.xcrun(["simctl", "boot", simulator.identifier])
            _ = try await process.xcrun(["simctl", "bootstatus", simulator.identifier, "-b"])
            if let containingApp {
                _ = try await process.xcrun(["simctl", "install", simulator.identifier, containingApp.path])
                _ = try await process.xcrun(["simctl", "launch", simulator.identifier, "com.apple.PreviewShell"])
            }
            _ = try await process.xcrun(["simctl", "install", simulator.identifier, app.path])
            let products = app.deletingLastPathComponent().appendingPathComponent("Products", isDirectory: true)
            if FileManager.default.fileExists(atPath: products.path) {
                let path = try await process.xcrun(["simctl", "get_app_container", simulator.identifier, simulator.bundleIdentifier, "app"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let installedApp = URL(filePath: path, directoryHint: .isDirectory)
                try FileManager.default.copyItem(at: products,
                    to: installedApp.deletingLastPathComponent().appendingPathComponent("Products", isDirectory: true))
            }
            let container = try await process.xcrun(["simctl", "get_app_container", simulator.identifier, simulator.bundleIdentifier, "data"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let documents = URL(filePath: container, directoryHint: .isDirectory).appendingPathComponent("Documents")
            let arguments = try Self.rendererArguments(localization: localization)
            let childEnvironment = Dictionary(uniqueKeysWithValues: environment.map { ("SIMCTL_CHILD_" + $0.key, $0.value) })
            if containingApp != nil {
                let installedApp = try await process.xcrun(["simctl", "get_app_container", simulator.identifier, simulator.bundleIdentifier, "app"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let executable = URL(filePath: installedApp, directoryHint: .isDirectory).appendingPathComponent("XcodeMCPPreviewRenderer")
                // PreviewShell owns the UI and the extension's active-preview assertion.
                // A foreground helper app suspends that assertion when it takes focus.
                _ = try await process.xcrun(["simctl", "spawn", simulator.identifier, executable.path,
                    "--native-preview-result-directory", documents.path] + arguments, environment: childEnvironment)
            } else {
                _ = try await process.xcrun(["simctl", "launch", simulator.identifier, simulator.bundleIdentifier] + arguments, environment: childEnvironment)
            }
            let responseURL = documents.appendingPathComponent("PreviewResult.json")
            while !FileManager.default.fileExists(atPath: responseURL.path) {
                try await Task.sleep(for: .milliseconds(100))
            }
            let response = try JSONDecoder().decode(PreviewRendererResult.self, from: Data(contentsOf: responseURL))
            if response.requiresNativePipeline == true { throw NativePipelineRequired() }
            if let error = response.error { throw NativeRuntimeError.invocation(error) }
            let snapshot = try response.snapshotName.map { try Data(contentsOf: documents.appendingPathComponent($0)) }
            let exclusion = try response.exclusionSnapshotName.map { try Data(contentsOf: documents.appendingPathComponent($0)) }
            rendered = (response, snapshot, exclusion)
        } catch { failure = error }
        // Cleanup is outside the cancelled task so it can delete the device even
        // when the caller has cancelled rendering or the request timed out.
        let cleanup = Task { @MainActor in
            _ = try await process.xcrun(["simctl", "delete", simulator.identifier])
        }
        do { try await cleanup.value }
        catch {
            throw NativeRuntimeError.invocation("\(failure.map(String.init(describing:)) ?? "Preview rendered"); failed to delete preview Simulator \(simulator.identifier): \(error)")
        }
        if let failure { throw failure }
        guard let rendered else { throw NativeRuntimeError.invocation("The preview renderer returned no result") }
        return (rendered.0, rendered.1, simulator.destination, simulator.deviceType, rendered.2)
    }

    private func supportedLocalizations(in workspace: AnyObject) async throws -> [String] {
        let runtime = ABIRuntime.shared
        let getLocalizations = try await runtime.object(workspace).resolveGetter(
            named: "(extension in PreviewsXcode):__C.IDEWorkspace.supportedLocalizations.getter : [PreviewsXcode.Locale]",
            as: (() -> NativeSwiftValue).self)
        let localizations = try unsafe getLocalizations.unsafeInvoke()
        let type = try await runtime.resolveSwiftType(named: "PreviewsXcode.Locale",
            in: .path(installation.framework("PreviewsXcode", in: "PlugIns")))
        let getLocale = try await type.resolveGetter(named: "locale.getter : __C.DVTLocale", as: (() -> AnyObject).self,
            receiverABI: .opaque(named: type.name))
        return try localizations.withCopy { value in
            guard let values = value as? [Any] else {
                throw NativeRuntimeError.unsupportedContract("Native supported localizations are not an array")
            }
            return try values.map { value in
                let locale = try unsafe getLocale.unsafeInvoke(on: value)
                let identifier = try runtime.object(locale).resolveMethodAndWait(selector: "localeIdentifier", as: (() -> String).self)
                return try unsafe identifier.unsafeInvoke()
            }
        }
    }

    private func workspace(_ identifier: String?) async throws -> AnyObject {
        let type = try await ABIRuntime.shared.resolveSwiftType(named: "IDEFoundation.IDEWorkspaceRegistry",
            in: .path(installation.framework("IDEFoundation")))
        let shared = try await type.resolveStaticGetter(named: "shared.getter : IDEFoundation.IDEWorkspaceRegistry", as: (() -> AnyObject).self)
        let registry = try unsafe shared.unsafeInvoke()
        guard let identifier else { throw NativeRuntimeError.invalidRequest("A workspaceIdentifier is required") }
        let lookup = try await type.resolveMethod(
            named: "workspace(withIdentifier: Swift.String) -> Swift.Optional<__C.IDEWorkspace>", as: ((String) -> AnyObject?).self)
        guard let workspace = try unsafe lookup.unsafeInvoke(on: registry, identifier) else {
            throw NativeRuntimeError.invalidRequest("Workspace '\(identifier)' is not open")
        }
        return workspace
    }

    private func sourceURL(_ path: String, workspace: AnyObject) async throws -> URL {
        let type = try await ABIRuntime.shared.resolveSwiftType(named: "PreviewsXcode.RenderPreviewAction",
            in: .path(installation.framework("PreviewsXcode", in: "PlugIns")))
        let resolve = try await type.resolveStaticMethod(
            named: "(resolveSourceFileURL in _FEA7E13ECD12FBA8521281D73C9764CE)(at: Swift.String, in: __C.IDEWorkspace) async throws -> Foundation.URL",
            as: (@concurrent (String, AnyObject) async throws -> PreviewURL).self)
        return try unsafe await resolve.unsafeInvoke(path, workspace).value
    }

    struct Selection {
        let source: NativePreviewBuild.Target
        let host: NativePreviewBuild.Target
    }

    static func rendererArguments(localization: String?) throws -> [String] {
        guard let localization else { return [] }
        let languages = try PropertyListSerialization.data(fromPropertyList: [localization], format: .xml, options: 0)
        return ["-AppleLanguages", String(decoding: languages, as: UTF8.self), "-AppleLocale", localization]
    }

    static func selectTarget(_ targets: [NativePreviewBuild.Target], source: URL, platform: NativePreviewPlatform) throws -> Selection {
        let sourcePath = source.resolvingSymlinksInPath().path
        guard targets.contains(where: { $0.sourceFiles.contains { $0.resolvingSymlinksInPath().path == sourcePath } }) else {
            throw NativeRuntimeError.invalidRequest("The active scheme did not build \(source.path)")
        }
        let platformTargets = targets.filter {
            NativePreviewPlatform(sdkRoot: $0.sdkRoot, sdkVariant: $0.sdkVariant) == platform
        }
        let sources = platformTargets.filter {
            $0.architecture == "arm64" && $0.sourceFiles.contains { $0.resolvingSymlinksInPath().path == sourcePath }
        }
        guard !sources.isEmpty else { throw NativePipelineRequired() }
        var selections: [Selection] = []
        for target in sources {
            if let output = target.outputURL, productBundle(containing: output) != nil {
                selections.append(Selection(source: target, host: target))
                continue
            }
            let objectPaths = Set(target.objectFiles.map { $0.resolvingSymlinksInPath().path })
            let sourceOutput = target.outputURL
            let frameworkName = sourceOutput?.pathComponents.last(where: { $0.hasSuffix(".framework") })
            let hosts = try platformTargets.filter { candidate in
                guard candidate.architecture == "arm64",
                      let output = candidate.outputURL, let app = productBundle(containing: output) else { return false }
                if candidate.objectFiles.contains(where: { objectPaths.contains($0.resolvingSymlinksInPath().path) }) {
                    return true
                }
                guard let sourceOutput else { return false }
                if try (["a", "o", "dylib"].contains(sourceOutput.pathExtension)
                    || (frameworkName != nil && NativePreviewBinary.isStaticArchive(at: sourceOutput)))
                    && candidate.linksProduct(at: sourceOutput) { return true }
                guard frameworkName != nil || sourceOutput.pathExtension == "dylib" else { return false }
                let rootLibrary = app.appendingPathComponent(sourceOutput.lastPathComponent)
                if frameworkName == nil, FileManager.default.fileExists(atPath: rootLibrary.path),
                   try NativePreviewBinary.matches(sourceOutput, rootLibrary) {
                    return true
                }
                let frameworks = Bundle(url: app)?.privateFrameworksURL ?? app.appendingPathComponent("Frameworks", isDirectory: true)
                guard FileManager.default.fileExists(atPath: frameworks.path) else { return false }
                return try FileManager.default.subpathsOfDirectory(atPath: frameworks.path).contains { subpath in
                    let library = frameworks.appendingPathComponent(subpath)
                    guard library.lastPathComponent == sourceOutput.lastPathComponent,
                          frameworkName.map({ library.pathComponents.contains($0) }) ?? true else { return false }
                    return try NativePreviewBinary.matches(sourceOutput, library)
                }
            }
            selections += hosts.map { Selection(source: target, host: $0) }
            if hosts.isEmpty, let sourceOutput,
               frameworkBundle(containing: sourceOutput) != nil,
               try NativePreviewBinary.isDynamicLibrary(at: sourceOutput) || NativePreviewBinary.isStaticArchive(at: sourceOutput) {
                selections.append(Selection(source: target, host: target))
            }
        }
        var candidates = selections
        let runnable = candidates.filter { $0.host.isRunnable }
        if !runnable.isEmpty { candidates = runnable }
        guard candidates.count == 1 else { throw NativePipelineRequired() }
        return candidates[0]
    }

    private struct Definition {
        let line: Int
        let column: Int
        let displayName: String
        let providerPath: NativeSwiftValue?
        let registry: NativeSwiftValue?
        let source: NativePreviewBuild.Source
    }

    private func previewDefinition(source: URL, index: Int) async throws -> Definition {
        let runtime = ABIRuntime.shared
        let action = try await runtime.resolveSwiftType(named: "PreviewsXcode.RenderPreviewAction",
            in: .path(installation.framework("PreviewsXcode", in: "PlugIns")))
        let unit = try await runtime.resolveSwiftType(named: "PreviewsPipeline.PreviewTranslationUnit",
            in: .path(installation.framework("PreviewsPipeline", in: "SharedFrameworks")))
        let parse = try await action.resolveStaticMethod(
            named: "(parseTranslationUnit in _FEA7E13ECD12FBA8521281D73C9764CE)(sourceFileURL: Foundation.URL) throws -> (translationUnit: PreviewsPipeline.PreviewTranslationUnit, previews: [PreviewsXcode.RenderPreviewAction.(RenderPreviewType in _FEA7E13ECD12FBA8521281D73C9764CE)])",
            as: ((PreviewURL) throws -> NativeSwiftValue).self, valueABIs: [unit: .opaque(named: unit.name)])
        let parsed = try unsafe parse.unsafeInvoke(PreviewURL(value: source))
        let translationUnit = try parsed.copyTupleElement(at: 0)
        let array = try parsed.copyTupleElement(at: 1)
        let previews = try array.withCopy { value -> [Any] in
            guard let values = value as? [Any] else {
                throw NativeRuntimeError.unsupportedContract("Native preview definitions are not an array")
            }
            return values
        }
        guard previews.indices.contains(index) else {
            throw NativeRuntimeError.invalidRequest("Preview index \(index) is outside the \(previews.count) definitions in \(source.lastPathComponent)")
        }
        func own<T>(_ value: T) async throws -> NativeSwiftValue {
            let identity = try await runtime.resolveSwiftFunction(named: "XcodeMCPNativeRuntime.nativePreviewValue<A>(A) -> A",
                as: ((T) -> NativeSwiftValue).self, genericArguments: [.type(T.self)])
            return try unsafe identity.unsafeInvoke(value)
        }
        let model = ImageSelector.path(installation.framework("PreviewsModel", in: "SharedFrameworks"))
        let locationType = try await runtime.resolveSwiftType(named: "PreviewsModel.SourceLocation", in: model)
        let boundType = try await runtime.resolveSwiftType(named: "PreviewsModel.SourceLocation.Bound", in: model)
        let pathType = try await runtime.resolveSwiftType(named: "PreviewsModel.MangleableTypePath", in: model)
        let syntaxType = try await runtime.resolveSwiftType(named: "PreviewsModel.SyntaxLocation", in: model)
        let contents = try String(contentsOf: source, encoding: .utf8)
        var definitions: [Definition] = []
        for value in previews {
            let definition = try await _openExistential(value, do: own)
            let record: NativeSwiftValue
            let location: NativeSwiftValue
            let displayName: String
            let providerPath: NativeSwiftValue?
            let registryRecord: NativeSwiftValue?
            if let provider = try await definition.resolveEnumPayload(forCase: "previewProvider") {
                record = provider
                registryRecord = nil
                let getPath = try await provider.type.resolveGetter(named: "path", as: (() -> NativeSwiftValue).self,
                    valueABIs: [pathType: .opaque(named: pathType.name)], receiverABI: .opaque(named: provider.type.name))
                providerPath = try unsafe getPath.unsafeInvoke(on: provider)
                let getSyntax = try await provider.type.resolveGetter(named: "location", as: (() -> NativeSwiftValue).self,
                    valueABIs: [syntaxType: .opaque(named: syntaxType.name)], receiverABI: .opaque(named: provider.type.name))
                let syntax = try unsafe getSyntax.unsafeInvoke(on: provider)
                let getLocation = try await syntax.type.resolveGetter(named: "locationExcludingTrivia", as: (() -> NativeSwiftValue).self,
                    valueABIs: [locationType: .opaque(named: locationType.name)], receiverABI: .opaque(named: syntax.type.name))
                location = try unsafe getLocation.unsafeInvoke(on: syntax)
                let getName = try await provider.type.resolveGetter(named: "displayName", as: (() -> String).self,
                    receiverABI: .opaque(named: provider.type.name))
                displayName = try unsafe getName.unsafeInvoke(on: provider)
            } else if let registry = try await definition.resolveEnumPayload(forCase: "registryPreview") {
                record = registry
                registryRecord = registry
                providerPath = nil
                let getName = try await registry.type.resolveGetter(
                    named: "(extension in PreviewsPipeline):PreviewsModel.RegistryDefinition.defaultDisplayName.getter : Swift.String",
                    as: (() -> String).self, receiverABI: .opaque(named: registry.type.name))
                displayName = try unsafe getName.unsafeInvoke(on: registry)
                let getLocation = try await registry.type.resolveGetter(named: "fullSourceLocation", as: (() -> NativeSwiftValue).self,
                    valueABIs: [locationType: .opaque(named: locationType.name)], receiverABI: .opaque(named: registry.type.name))
                location = try unsafe getLocation.unsafeInvoke(on: registry)
            } else { throw NativePipelineRequired() }
            let getLine = try await record.type.resolveGetter(named: "lineNumber", as: (() -> Int).self,
                receiverABI: .opaque(named: record.type.name))
            let line = try unsafe getLine.unsafeInvoke(on: record)
            let getBound = try await location.type.resolveGetter(named: "lowerBound", as: (() -> NativeSwiftValue).self,
                valueABIs: [boundType: .opaque(named: boundType.name)], receiverABI: .opaque(named: location.type.name))
            let bound = try unsafe getBound.unsafeInvoke(on: location)
            let getColumn = try await bound.type.resolveGetter(named: "column", as: (() -> Int).self,
                receiverABI: .opaque(named: bound.type.name))
            let column = try unsafe getColumn.unsafeInvoke(on: bound)
            definitions.append(Definition(line: line, column: try Self.registryColumn(in: contents, line: line, utf16Column: column),
                displayName: displayName, providerPath: providerPath, registry: registryRecord,
                source: .init(translationUnit: translationUnit, definition: definition)))
        }
        // The parser returns providers and registries in separate batches. The
        // native tool selects definitions in source order, including mixed files.
        return definitions.sorted { ($0.line, $0.column) < ($1.line, $1.column) }[index]
    }

    private func registrySpecification(registry: NativeSwiftValue, moduleName: String) async throws -> Data {
        let runtime = ABIRuntime.shared
        let model = ImageSelector.path(installation.framework("PreviewsModel", in: "SharedFrameworks"))
        let messaging = ImageSelector.path(installation.framework("PreviewsMessagingHost", in: "SharedFrameworks"))
        let optionalUUID = try await runtime.resolveSwiftType(named: "Swift.Optional", genericArguments: [.type(UUID.self)])
        let getSidecar = try await registry.type.resolveGetter(
            named: "sidecarIdentifier.getter : Swift.Optional<Foundation.UUID>", as: (() -> NativeSwiftValue).self,
            valueABIs: [optionalUUID: .opaque(named: optionalUUID.name)], receiverABI: .opaque(named: registry.type.name))
        let sidecar = try unsafe getSidecar.unsafeInvoke(on: registry)
        guard try await sidecar.resolveEnumPayload(forCase: "some") == nil else { throw NativePipelineRequired() }
        let idType = try await runtime.resolveSwiftType(named: "PreviewsMessagingHost.RegistryID", in: messaging)
        let getID = try await registry.type.resolveGetter(named: "id.getter : PreviewsMessagingHost.RegistryID",
            as: (() -> NativeSwiftValue).self, valueABIs: [idType: .opaque(named: idType.name)],
            receiverABI: .opaque(named: registry.type.name))
        let id = try unsafe getID.unsafeInvoke(on: registry)
        let moduleType = try await runtime.resolveSwiftType(named: "PreviewsModel.Module", in: model)
        let initializeModule = try await moduleType.resolveInitializer(named: "init(name: Swift.String) -> PreviewsModel.Module",
            as: ((String) -> NativeSwiftValue).self, valueABIs: [moduleType: .opaque(named: moduleType.name)])
        let module = try unsafe initializeModule.unsafeInvoke(moduleName)
        let locationType = try await runtime.resolveSwiftType(named: "PreviewsMessagingHost.RuntimeRegistryLocation", in: messaging)
        let locate = try await registry.type.resolveMethod(
            named: "runtimeLocation(in: PreviewsModel.Module) -> PreviewsMessagingHost.RuntimeRegistryLocation",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [moduleType: .opaque(named: moduleType.name), locationType: .opaque(named: locationType.name)],
            receiverABI: .opaque(named: registry.type.name))
        let location = try unsafe locate.unsafeInvoke(on: registry, module)
        let specificationType = try await runtime.resolveSwiftType(named: "PreviewsMessagingHost.PreviewSpecification", in: messaging)
        let makeSpecification = try await specificationType.resolveStaticMethod(
            named: "registryPreview(stableID: PreviewsMessagingHost.RegistryID, location: PreviewsMessagingHost.RuntimeRegistryLocation) -> PreviewsMessagingHost.PreviewSpecification",
            as: ((NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [idType: .opaque(named: idType.name), locationType: .opaque(named: locationType.name),
                        specificationType: .opaque(named: specificationType.name)])
        let specification = try unsafe makeSpecification.unsafeInvoke(id, location)
        return try await previewSpecificationData(specification)
    }

    private func providerSpecification(name: String, description: Data) async throws -> Data {
        let runtime = ABIRuntime.shared
        let messaging = ImageSelector.path(installation.framework("PreviewsMessagingHost", in: "SharedFrameworks"))
        let providerType = try await runtime.resolveSwiftType(named: "PreviewsMessagingHost.ProviderPayload", in: messaging)
        let makeProvider = try await providerType.resolveInitializer(
            named: "init(providerName: Swift.String) -> PreviewsMessagingHost.ProviderPayload",
            as: ((String) -> NativeSwiftValue).self, valueABIs: [providerType: .opaque(named: providerType.name)])
        let provider = try unsafe makeProvider.unsafeInvoke(name)
        let description = try await builder.decodePreviewValue(description, named: "PreviewDescription")
        let getIndex = try await description.type.resolveGetter(named: "index.getter : Swift.Int",
            as: (() -> Int).self, receiverABI: .opaque(named: description.type.name))
        let index = try unsafe getIndex.unsafeInvoke(on: description)
        let specificationType = try await runtime.resolveSwiftType(named: "PreviewsMessagingHost.PreviewSpecification", in: messaging)
        let makeSpecification = try await specificationType.resolveStaticMethod(
            named: "providerPreview(provider: PreviewsMessagingHost.ProviderPayload, indexInProvider: Swift.Int) -> PreviewsMessagingHost.PreviewSpecification",
            as: ((NativeSwiftValue, Int) -> NativeSwiftValue).self,
            valueABIs: [providerType: .opaque(named: providerType.name), specificationType: .opaque(named: specificationType.name)])
        let specification = try unsafe makeSpecification.unsafeInvoke(provider, index)
        return try await previewSpecificationData(specification)
    }

    private func previewSpecificationData(_ specification: NativeSwiftValue) async throws -> Data {
        let runtime = ABIRuntime.shared
        let foundation = ImageSelector.path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks"))
        let propertyListType = try await runtime.resolveSwiftType(named: "PreviewsFoundationHost.PropertyList", in: foundation)
        let encode = try await specification.type.resolveGetter(
            named: "propertyListValue.getter : PreviewsFoundationHost.PropertyList", as: (() -> NativeSwiftValue).self,
            valueABIs: [propertyListType: .opaque(named: propertyListType.name)],
            receiverABI: .opaque(named: specification.type.name))
        let propertyList = try unsafe encode.unsafeInvoke(on: specification)
        let dictionaryType = try await runtime.resolveSwiftType(named: "Swift.Dictionary",
            genericArguments: [.type(String.self), .type(Any.self)])
        let serialize = try await propertyListType.resolveGetter(named: "serializableDictionary.getter : [Swift.String : Any]",
            as: (() -> NativeSwiftValue).self, valueABIs: [dictionaryType: .pointer],
            receiverABI: .opaque(named: propertyListType.name))
        let dictionary = try unsafe serialize.unsafeInvoke(on: propertyList)
        return try dictionary.withCopy { value in
            guard let dictionary = value as? [String: Any] else {
                throw NativeRuntimeError.unsupportedContract("Native preview specification is not a property list dictionary")
            }
            return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        }
    }

    private func providerTypeName(path: NativeSwiftValue, moduleName: String) async throws -> String {
        let model = ImageSelector.path(installation.framework("PreviewsModel", in: "SharedFrameworks"))
        let type = try await ABIRuntime.shared.resolveSwiftType(named: "PreviewsModel.Module", in: model)
        let initialize = try await type.resolveInitializer(named: "init(name: Swift.String) -> PreviewsModel.Module",
            as: ((String) -> NativeSwiftValue).self, valueABIs: [type: .opaque(named: type.name)])
        let module = try unsafe initialize.unsafeInvoke(moduleName)
        let mangle = try await path.type.resolveMethod(named: "mangledName(in: PreviewsModel.Module) -> Swift.String",
            as: ((NativeSwiftValue) -> String).self, valueABIs: [type: .opaque(named: type.name)],
            receiverABI: .opaque(named: path.type.name))
        return try unsafe mangle.unsafeInvoke(on: path, module)
    }

    static func registryColumn(in source: String, line: Int, utf16Column: Int) throws -> Int {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard line > 0, lines.indices.contains(line - 1), utf16Column >= 0 else {
            throw NativeRuntimeError.invocation("The preview source changed while resolving its location")
        }
        let text = lines[line - 1]
        // The native parser reports UTF-16 offsets; macro metadata reports
        // one-based UTF-8 byte columns. Unicode prefixes must retain that mapping.
        guard let position = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Column, limitedBy: text.utf16.endIndex),
              let index = String.Index(position, within: text) else {
            throw NativeRuntimeError.invocation("The preview source changed while resolving its location")
        }
        return text[..<index].utf8.count + 1
    }

    private static func productBundle(containing output: URL) -> URL? {
        var url = output.deletingLastPathComponent()
        while url.path != "/" {
            if ["app", "appex"].contains(url.pathExtension) { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func frameworkBundle(containing output: URL) -> URL? {
        var url = output.deletingLastPathComponent()
        while url.path != "/" {
            if url.pathExtension == "framework" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func containingApp(for extensionOutput: URL, targets: [NativePreviewBuild.Target]) throws -> URL? {
        guard let product = productBundle(containing: extensionOutput), product.pathExtension == "appex" else { return nil }
        let relativeBinary = String(extensionOutput.path.dropFirst(product.path.count + 1))
        let candidates = try targets.compactMap { target -> (app: URL, isRunnable: Bool)? in
            guard target.architecture == "arm64", NativePreviewPlatform(sdkRoot: target.sdkRoot, sdkVariant: target.sdkVariant) != nil,
                  let output = target.outputURL, let app = productBundle(containing: output),
                  app.pathExtension == "app" else { return nil }
            let embedded = (Bundle(url: app)?.builtInPlugInsURL ?? app.appendingPathComponent("PlugIns", isDirectory: true))
                .appendingPathComponent(product.lastPathComponent, isDirectory: true)
                .appendingPathComponent(relativeBinary)
            guard FileManager.default.fileExists(atPath: embedded.path),
                  try NativePreviewBinary.matches(extensionOutput, embedded) else { return nil }
            return (app, target.isRunnable)
        }
        guard !candidates.isEmpty else { return nil }
        let runnable = candidates.filter(\.isRunnable)
        let matches = runnable.isEmpty ? candidates : runnable
        guard matches.count == 1 else { throw NativePipelineRequired() }
        return matches[0].app
    }

    private static func widgetExtensionIdentifier(_ product: URL) throws -> String? {
        guard product.pathExtension == "appex" else { return nil }
        let info = try bundleInfo(at: product)
        guard (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension" else {
            return nil
        }
        return info["CFBundleIdentifier"] as? String
    }

    struct LinkedPreviewImage {
        let url: URL
        let searchPaths: [(framework: Bool, url: URL)]
    }

    struct FrameworkDependencies {
        struct Relocation {
            let library: String
            let name: String
            let replacement: String
        }
        var products: [URL: String] = [:]
        var relocations: [Relocation] = []
    }

    static func frameworkDependencies(for source: NativePreviewBuild.Target, targets: [NativePreviewBuild.Target],
                                      platform: NativePreviewPlatform, primaryImage: LinkedPreviewImage? = nil) throws -> FrameworkDependencies {
        typealias SearchPath = (framework: Bool, url: URL)
        typealias Library = (output: URL, product: URL, identifier: String, dependencies: [String], rpaths: [String], target: NativePreviewBuild.Target?)
        func library(at output: URL, target: NativePreviewBuild.Target? = nil) throws -> Library? {
            let output = output.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let image = try NativePreviewBinary.dynamicLibrary(at: output) else { return nil }
            return (output, frameworkBundle(containing: output) ?? output, image.identifier, image.dependencies, image.rpaths, target)
        }
        func runtimeURL(_ path: String, importer: URL) -> URL? {
            if path == "@loader_path" { return importer.deletingLastPathComponent() }
            if path.hasPrefix("@loader_path/") {
                return importer.deletingLastPathComponent().appendingPathComponent(String(path.dropFirst("@loader_path/".count)))
            }
            return path.hasPrefix("/") ? URL(filePath: path) : nil
        }
        // Native-preloaded runtimes must keep their original image identity when their clients are relocated.
        let preloaded = Set(source.rendererEnvironment["DYLD_INSERT_LIBRARIES", default: ""].split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { URL(filePath: String($0)).resolvingSymlinksInPath() })
        let libraries = try targets.compactMap { target -> Library? in
            guard target.architecture == "arm64",
                  NativePreviewPlatform(sdkRoot: target.sdkRoot, sdkVariant: target.sdkVariant) == platform,
                  let output = target.outputURL, productBundle(containing: output) == nil else { return nil }
            return try library(at: output, target: target)
        }
        guard let output = (primaryImage?.url ?? source.outputURL)?.resolvingSymlinksInPath(),
              let sourceLibrary = try primaryImage.flatMap({ try library(at: $0.url, target: source) })
                ?? libraries.first(where: { $0.output == output }) else { return FrameworkDependencies() }
        var pending = [(library: sourceLibrary, inheritedPaths: [URL](), inheritedLinkPaths: [SearchPath]())]
        var visited: Set<URL> = [output.resolvingSymlinksInPath()]
        var result = FrameworkDependencies()
        func stagedPath(_ library: Library) -> String {
            let product = library.product.resolvingSymlinksInPath()
            let relativeProduct: String
            if product == sourceLibrary.product.resolvingSymlinksInPath() {
                relativeProduct = product.lastPathComponent
            } else if let path = result.products[product] {
                relativeProduct = path
            } else {
                relativeProduct = "Dependencies/\(result.products.count)/" + product.lastPathComponent
                result.products[product] = relativeProduct
            }
            return relativeProduct + library.output.path.dropFirst(product.path.count)
        }
        while let current = pending.popLast() {
            let runtimePaths = current.library.rpaths.compactMap { runtimeURL($0, importer: current.library.output) }
                + current.inheritedPaths
            let inputs = try current.library.target?.linkedInputs()
            let linkedPaths = current.library.output == output ? primaryImage?.searchPaths : nil
            let searchPaths = (linkedPaths ?? inputs?.searchPaths ?? []) + current.inheritedLinkPaths
            let linkedLibraries = try (inputs?.files ?? []).compactMap { candidate in
                try libraries.first { $0.output.resolvingSymlinksInPath() == candidate.resolvingSymlinksInPath() }
                    ?? library(at: candidate)
            }
            for name in current.library.dependencies {
                let matches = libraries.filter { $0.identifier == name || $0.output.path == name }
                var dependency = matches.first { $0.output.path == name }
                if dependency == nil {
                    let linked = linkedLibraries.filter { $0.identifier == name || $0.output.path == name }
                    if linked.count == 1 { dependency = linked[0] }
                }
                if dependency == nil {
                    let candidates: [URL]
                    if name.hasPrefix("@rpath/") {
                        let relative = String(name.dropFirst("@rpath/".count))
                        let paths = searchPaths.filter { $0.framework == relative.contains(".framework/") }.map(\.url)
                        candidates = (runtimePaths + paths).map { $0.appendingPathComponent(relative) }
                    } else {
                        candidates = runtimeURL(name, importer: current.library.output).map { [$0] } ?? []
                    }
                    // Prebuilt inputs have no native target record; their real load commands and linker paths locate them.
                    for candidate in candidates {
                        if let built = libraries.first(where: { $0.output.resolvingSymlinksInPath() == candidate.resolvingSymlinksInPath() }) {
                            dependency = built
                            break
                        }
                        if let resolved = try library(at: candidate) {
                            dependency = resolved
                            break
                        }
                    }
                }
                if dependency == nil, matches.count == 1 { dependency = matches[0] }
                guard let dependency, !preloaded.contains(dependency.output) else { continue }
                let importer = stagedPath(current.library)
                let target = stagedPath(dependency)
                let parentDepth = importer.split(separator: "/").count - 1
                let replacement = "@loader_path/" + String(repeating: "../", count: parentDepth) + target
                let internalRelative = name.hasPrefix("@loader_path/")
                    && current.library.product.resolvingSymlinksInPath() == dependency.product.resolvingSymlinksInPath()
                if name != replacement && !internalRelative {
                    result.relocations.append(.init(library: importer, name: name,
                        replacement: replacement))
                }
                if visited.insert(dependency.output.resolvingSymlinksInPath()).inserted {
                    pending.append((dependency, runtimePaths, searchPaths))
                }
            }
        }
        return result
    }

    static func linkStaticFramework(_ source: NativePreviewBuild.Target, in products: URL, platform: NativePreviewPlatform,
                                    process: NativePreviewProcess) async throws -> LinkedPreviewImage {
        guard let output = source.outputURL, let framework = frameworkBundle(containing: output) else {
            throw NativeRuntimeError.unsupportedContract("The static preview target has no linked archive")
        }
        // A separate image keeps the static source's entry symbol away from the renderer's entry point.
        // Keeping the products outside the helper app preserves ordinary Foundation image ownership.
        let copiedFramework = products.appendingPathComponent(framework.lastPathComponent)
        let archive = products.appendingPathComponent("PreviewSource.a")
        try copyReplacingItem(output, to: archive)
        let image = products.appendingPathComponent("XcodeMCPPreviewSource.dylib")
        let sdk = try await process.xcrun(["--sdk", platform.sdk, "--show-sdk-path"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A Swift input lets the driver link while only this archive is force-loaded.
        let linkSource = products.appendingPathComponent("PreviewSource.swift")
        try Data().write(to: linkSource)
        var arguments = ["--sdk", platform.sdk, "swiftc", "-emit-library", "-parse-as-library", "-target", platform.triple, "-sdk", sdk,
            linkSource.path, "-lc++", "-Xlinker", "-force_load", "-Xlinker", archive.path,
            "-Xlinker", "-headerpad_max_install_names", "-Xlinker", "-install_name", "-Xlinker",
            "@rpath/" + image.lastPathComponent, "-o", image.path]
        let sanitizers = [(source.enableAddressSanitizer, "address"), (source.enableThreadSanitizer, "thread"),
                          (source.enableUndefinedBehaviorSanitizer, "undefined")].filter(\.0).map(\.1)
        if !sanitizers.isEmpty { arguments.append("-sanitize=" + sanitizers.joined(separator: ",")) }
        let inputs = try source.linkedInputs()
        let searchPaths = source.searchPaths(in: source.compileCommandLine) + source.searchPaths(in: source.linkCommandLine)
        for path in searchPaths { arguments += [path.argument, path.url.path] }
        for input in inputs.files {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: input.path, isDirectory: &directory), !directory.boolValue,
               try NativePreviewBinary.isDynamicLibrary(at: input) {
                arguments += ["-Xlinker", input.path]
            }
        }
        _ = try await process.xcrun(arguments)
        _ = try await process.run("/usr/bin/codesign", ["--force", "--sign", "-", image.path])
        _ = try await process.run("/usr/bin/codesign", ["--force", "--sign", "-", copiedFramework.path])
        return LinkedPreviewImage(url: image, searchPaths: searchPaths.map { ($0.argument != "-L", $0.url) })
    }

    static func copyFrameworkDependencies(_ dependencies: FrameworkDependencies, into products: URL) throws {
        for (source, path) in dependencies.products {
            let destination = products.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    static func relocateFrameworkDependencies(_ dependencies: FrameworkDependencies, in products: URL,
                                             process: NativePreviewProcess) async throws {
        var changedFrameworks: Set<URL> = []
        for path in Set(dependencies.relocations.map(\.library)).sorted() {
            let library = products.appendingPathComponent(path)
            let arguments = dependencies.relocations.filter { $0.library == path }.flatMap { ["-change", $0.name, $0.replacement] }
            _ = try await process.xcrun(["install_name_tool"] + arguments + [library.path])
            _ = try await process.run("/usr/bin/codesign", ["--force", "--sign", "-", library.path])
            if let framework = frameworkBundle(containing: library) { changedFrameworks.insert(framework) }
        }
        // Nested dylibs can be sealed framework resources; refresh their owning bundle after re-signing the changed code.
        for framework in changedFrameworks.sorted(by: { $0.path.count > $1.path.count }) {
            _ = try await process.run("/usr/bin/codesign", ["--force", "--sign", "-", framework.path])
        }
    }

    @discardableResult
    static func prepareApp(product: URL, helper: URL, app: URL, containingApp: URL? = nil, platform: NativePreviewPlatform = .iOS,
                           clientIdentifier: String? = nil, staticFramework: Bool = false) throws -> URL {
        let standaloneFramework = product.pathExtension == "framework"
        let frameworks = platform.frameworksDirectory(in: app)
        let products = staticFramework
            ? app.deletingLastPathComponent().appendingPathComponent("Products", isDirectory: true)
                .appendingPathComponent(product.deletingLastPathComponent().lastPathComponent, isDirectory: true)
            : frameworks
        var original: [String: Any]
        if standaloneFramework {
            try FileManager.default.createDirectory(at: platform.executableDirectory(in: app), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: product, to: products.appendingPathComponent(product.lastPathComponent))
            // The framework remains its own bundle; the renderer is only its executable host.
            original = ["CFBundleIdentifier": "dev.xcodemcp.PreviewClient." + UUID().uuidString, "CFBundleName": "Preview"]
            switch platform {
            case .iOS: original["UIDeviceFamily"] = [1, 2]
            case .tvOS: original["UIDeviceFamily"] = [3]
            case .watchOS: original["UIDeviceFamily"] = [4]
            case .visionOS: original["UIDeviceFamily"] = [7]
            case .catalyst: original["UIDeviceFamily"] = [2]
            case .macOS: break
            }
        } else {
            try FileManager.default.copyItem(at: product, to: app)
            original = try bundleInfo(at: app)
        }
        let executable = helper.appendingPathComponent("XcodeMCPPreviewRenderer")
        try copyReplacingItem(executable, to: platform.executableDirectory(in: app).appendingPathComponent("XcodeMCPPreviewRenderer"))
        var info = Self.rendererInfo(original, platform: platform)
        // The client coexists with the original extension registration.
        if let clientIdentifier { info["CFBundleIdentifier"] = clientIdentifier }
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: platform.infoURL(in: app))
        try FileManager.default.createDirectory(at: platform.resourcesDirectory(in: app), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        if let shared = containingApp.map({ platform.frameworksDirectory(in: $0) }),
           FileManager.default.fileExists(atPath: shared.path) {
            // Extensions search their own Frameworks before their containing app's.
            for item in try FileManager.default.contentsOfDirectory(at: shared, includingPropertiesForKeys: nil) {
                let destination = frameworks.appendingPathComponent(item.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: item, to: destination)
                }
            }
        }
        try copyContents(helper.appendingPathComponent("Frameworks"), to: frameworks)
        return products
    }

    static func appName(product: URL, containingApp: URL?, localization: String?) throws -> String {
        let owner = containingApp ?? product
        guard let bundle = Bundle(url: owner) else { throw NativePipelineRequired() }
        if let localization {
            let info = bundle.infoDictionary ?? [:]
            let key = info["CFBundleDisplayName"] is String ? "CFBundleDisplayName" : "CFBundleName"
            guard let name = info[key] as? String else { return "" }
            return bundle.localizedString(forKey: key, value: name, table: "InfoPlist",
                localizations: [Locale.Language(identifier: localization)])
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
    }

    static func rendererInfo(_ original: [String: Any], platform: NativePreviewPlatform = .iOS) -> [String: Any] {
        let startupKeys = ["CFBundleExecutable", "CFBundlePackageType", "NSPrincipalClass", "UIMainStoryboardFile",
                           "UIApplicationSceneManifest", "NSExtension", "NSMainNibFile", "NSMainStoryboardFile",
                           "UISupportedInterfaceOrientations"]
        // Bundle lookup gives platform/device-qualified keys precedence over base keys.
        var info = original.filter { key, _ in
            !startupKeys.contains { key == $0 || key.hasPrefix($0 + "-") || key.hasPrefix($0 + "~") }
        }
        info["CFBundleExecutable"] = "XcodeMCPPreviewRenderer"
        info["CFBundlePackageType"] = "APPL"
        let minimumKey = platform.isSimulator ? "MinimumOSVersion" : "LSMinimumSystemVersion"
        if (info[minimumKey] as? String ?? "").compare(platform.minimumVersion, options: .numeric) == .orderedAscending {
            info[minimumKey] = platform.minimumVersion
        }
        if platform != .macOS && platform != .watchOS {
            info["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                                                        "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
            info["UIApplicationSceneManifest"] = ["UIApplicationSupportsMultipleScenes": false,
            "UISceneConfigurations": ["UIWindowSceneSessionRoleApplication": [["UISceneConfigurationName": "Preview", "UISceneDelegateClassName": "XcodeMCPPreviewRenderer.PreviewRendererScene"]]]]
        }
        if platform == .macOS { info["NSPrincipalClass"] = "NSApplication" }
        if platform == .watchOS {
            info["WKApplication"] = true
            info["WKWatchOnly"] = true
            info["WKRunsIndependentlyOfCompanionApp"] = nil
            info["WKCompanionAppBundleIdentifier"] = nil
        }
        return info
    }

    private static func copyContents(_ source: URL, to destination: URL) throws {
        for item in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try copyReplacingItem(item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
    }

    private static func copyReplacingItem(_ source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func previewLibraries(in app: URL, platform: NativePreviewPlatform) throws -> [URL] {
        let libraries = try FileManager.default.contentsOfDirectory(at: platform.executableDirectory(in: app), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".debug.dylib") }
        guard !libraries.isEmpty else { throw NativePipelineRequired() }
        return libraries
    }

    static func programLibraries(previewLibraries: [URL], output: URL) throws -> [URL] {
        try previewLibraries.filter { try NativePreviewBinary.matches(output, $0) }
    }

    static func registryLibraries(in app: URL, previewLibraries: [URL], products: URL? = nil) throws -> [URL] {
        var libraries = previewLibraries
        libraries += try FileManager.default.contentsOfDirectory(at: Bundle(url: app)?.executableURL?.deletingLastPathComponent() ?? app, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "dylib" }
        let frameworks = Bundle(url: app)?.privateFrameworksURL ?? app.appendingPathComponent("Frameworks", isDirectory: true)
        for directory in Set([frameworks] + (products.map { [$0] } ?? [])) {
            for subpath in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
                let item = directory.appendingPathComponent(subpath)
                if item.pathExtension == "framework" {
                    if let executable = Bundle(url: item)?.executableURL { libraries.append(executable) }
                } else if item.pathExtension == "dylib" {
                    libraries.append(item)
                }
            }
        }
        return Array(Set(libraries.map { $0.resolvingSymlinksInPath() })).sorted { $0.path < $1.path }
    }

    static func libraryPaths(in app: URL, previewLibraries: [URL], registryLibraries: [URL], sourceOutput: URL?,
                             products: URL? = nil) throws -> [String] {
        var libraries = previewLibraries
        if let sourceOutput, Self.productBundle(containing: sourceOutput) == nil {
            let frameworkName = sourceOutput.pathComponents.last(where: { $0.hasSuffix(".framework") })
            if frameworkName != nil || sourceOutput.pathExtension == "dylib",
               try !NativePreviewBinary.isStaticArchive(at: sourceOutput) {
                guard let sourceLibrary = try registryLibraries.first(where: { library in
                    guard library.lastPathComponent == sourceOutput.lastPathComponent,
                          frameworkName.map({ library.pathComponents.contains($0) }) ?? true else { return false }
                    return try NativePreviewBinary.matches(sourceOutput, library)
                }) else { throw NativePipelineRequired() }
                libraries.append(sourceLibrary)
            }
        }
        let root = app.resolvingSymlinksInPath()
        let products = products?.resolvingSymlinksInPath()
        var paths: [String] = []
        for library in libraries {
            let library = library.resolvingSymlinksInPath()
            var relationship: FileManager.URLRelationship = .other
            try FileManager.default.getRelationship(&relationship, ofDirectoryAt: root, toItemAt: library)
            let relative: String
            if relationship == .contains {
                relative = String(library.path.dropFirst(root.path.count + 1))
            } else if let products {
                try FileManager.default.getRelationship(&relationship, ofDirectoryAt: products, toItemAt: library)
                guard relationship == .contains else { throw NativePipelineRequired() }
                let operation = root.deletingLastPathComponent()
                try FileManager.default.getRelationship(&relationship, ofDirectoryAt: operation, toItemAt: library)
                guard relationship == .contains else { throw NativePipelineRequired() }
                relative = "../" + library.path.dropFirst(operation.path.count + 1)
            } else { throw NativePipelineRequired() }
            if !paths.contains(relative) { paths.append(relative) }
        }
        return paths
    }

    static func registryNames(in symbols: String) -> [String] {
        Set(symbols.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let symbol = String(line)
            // Names may use mangling substitutions. The renderer checks PreviewRegistry conformance.
            guard symbol.hasPrefix("_$s"), symbol.hasSuffix("VMn"), symbol.contains("fMu_") else { return nil }
            return String(symbol.dropFirst(3).dropLast(2))
        }).sorted()
    }

    static func programRootNames(in symbols: String) -> [String] {
        let suffix = "5$mainyyFZ"
        return Set(symbols.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let symbol = String(line)
            // The renderer checks Widget/WidgetBundle conformance before initializing the program root.
            guard symbol.hasPrefix("_$s"), symbol.hasSuffix(suffix) else { return nil }
            return String(symbol.dropFirst(3).dropLast(suffix.count))
        }).sorted()
    }

    private struct Simulator {
        let identifier: String
        let bundleIdentifier: String
        let destination: [String: JSONValue]
        let deviceType: URL
    }

    private func createSimulator(app: URL, build: NativePreviewBuild.Result, process: NativePreviewProcess) async throws -> Simulator {
        let inventoryData = Data(try await process.xcrun(["simctl", "list", "--json"]).utf8)
        guard let inventory = try JSONSerialization.jsonObject(with: inventoryData) as? [String: Any] else {
            throw NativeRuntimeError.unsupportedContract("Simulator inventory is not a JSON object")
        }
        let destinations = inventory["devices"] as? [String: [[String: Any]]] ?? [:]
        guard let selected = destinations.compactMap({ runtime, devices -> (String, [String: Any])? in
            devices.first(where: { $0["udid"] as? String == build.destinationIdentifier }).map { (runtime, $0) }
        }).first, let deviceID = selected.1["deviceTypeIdentifier"] as? String else {
            throw NativeRuntimeError.unavailable("The selected Simulator \(build.destinationIdentifier) is no longer installed")
        }
        let runtimeID = selected.0
        let type = (inventory["devicetypes"] as? [[String: Any]])?.first { $0["identifier"] as? String == deviceID }
        guard let path = type?["bundlePath"] as? String else { throw NativePipelineRequired() }
        let deviceType = URL(filePath: path, directoryHint: .isDirectory)
        let info = try Self.bundleInfo(at: app)
        guard let bundleIdentifier = info["CFBundleIdentifier"] as? String else {
            throw NativeRuntimeError.unsupportedContract("The built preview product has no bundle identifier")
        }
        let identifier = try await process.xcrun(["simctl", "create", "XcodeMCPPreview-\(UUID().uuidString)", deviceID, runtimeID])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Simulator(identifier: identifier, bundleIdentifier: bundleIdentifier,
            destination: ["identifier": .string(build.destinationIdentifier),
                "platformName": .string(build.platformName ?? "iOS"),
                "deviceModelName": .string(build.deviceModelName ?? selected.1["name"] as? String ?? deviceID),
                "systemVersion": .string(build.systemVersion ?? runtimeID)], deviceType: deviceType)
    }

    private static func bundleInfo(at bundle: URL) throws -> [String: Any] {
        let rootInfo = bundle.appendingPathComponent("Info.plist")
        let infoURL = FileManager.default.fileExists(atPath: rootInfo.path) ? rootInfo : bundle.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let info = try unsafe PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NativeRuntimeError.unsupportedContract("The built preview product has an unsupported Info.plist")
        }
        return info
    }

    @MainActor
    private struct Input {
        let nativeValue: NativeSwiftValue
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
        let identity = try ABIRuntime.shared.resolveSwiftFunctionAndWait(named: "XcodeMCPNativeRuntime.nativePreviewValue<A>(A) -> A",
            as: ((T) -> NativeSwiftValue).self, genericArguments: [.type(type)])
        let nativeValue = try unsafe identity.unsafeInvoke(value)
        let fields = Dictionary(uniqueKeysWithValues: Mirror(reflecting: value).children.compactMap { field in field.label.map { ($0, field.value) } })
        guard let artifacts = fields["temporaryArtifactsPath"] as? String,
              let path = fields["sourceFilePath"] as? String else {
            throw NativeRuntimeError.unsupportedContract("Native preview input fields have changed")
        }
        // These native properties use Default wrappers. Call their getters so
        // the action's decoded defaults are preserved without unwrapping storage.
        let nativeType = try ABIRuntime.shared.resolveSwiftTypeAndWait(named: "PreviewsXcode.RenderPreviewAction.Input", as: type,
            in: .path(installation.framework("PreviewsXcode", in: "PlugIns")))
        let receiverABI = try NativeType.opaque(named: nativeType.name)
        let indexGetter = try nativeType.resolveGetterAndWait(named: "previewDefinitionIndexInFile", as: (() -> Int).self, receiverABI: receiverABI)
        let variantsGetter = try nativeType.resolveGetterAndWait(named: "previewVariantOverrides.getter : [Swift.String : Swift.String]",
            as: (() -> PreviewVariants).self, receiverABI: receiverABI)
        let timeoutGetter = try nativeType.resolveGetterAndWait(named: "timeout", as: (() -> Int).self, receiverABI: receiverABI)
        let index = try unsafe indexGetter.unsafeInvoke(on: value)
        let variants = try unsafe variantsGetter.unsafeInvoke(on: value).value
        let timeout = try unsafe timeoutGetter.unsafeInvoke(on: value)
        let controls = fields["previewCanvasControlOverrides"].flatMap { Mirror(reflecting: $0).children.first?.value }
        let controlFields = controls.map { Dictionary(uniqueKeysWithValues: Mirror(reflecting: $0).children.compactMap { field in field.label.map { ($0, field.value) } }) } ?? [:]
        let options = Self.directOptions(variants: variants, controls: controlFields)
        return Input(nativeValue: nativeValue, workspaceIdentifier: fields["workspaceIdentifier"] as? String? ?? nil, artifacts: artifacts, sourcePath: path,
            index: index, localization: fields["previewLocalizationOverride"] as? String? ?? nil,
            timeout: timeout,
            widgetFamily: options.widgetFamily, widgetPresentation: options.widgetPresentation,
            timelineIndex: options.timelineIndex, groupItemIndex: options.groupItemIndex,
            displayVariants: options.displayVariants, activityViewStyle: options.activityViewStyle,
            activityViewContext: options.activityViewContext, activityToggleState: options.activityToggleState,
            requiresNativePipeline: options.requiresNativePipeline, variantOverrides: variants)
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
            try? FileHandle.standardError.write(contentsOf: Data("Native preview failed: \(error); error encoding also failed: \(encodingError)\n".utf8))
            return Data(#"{"type":"error","data":"Could not encode the native preview failure; see host diagnostics"}"#.utf8)
        }
    }
}

struct NativePipelineRequired: Error {}

// Generic calls supply the native enum's indirect ABI and retained ownership.
@inline(never)
package func nativePreviewValue<T>(_ value: T) -> T { value }

private struct PreviewURL: ABIBridgeSwiftValue {
    let value: URL
    static let swiftABIType: NativeType = try! .opaque(named: "Foundation.URL")
}

private struct PreviewVariants: ABIBridgeSwiftValue {
    let value: [String: String]
    static let swiftABIType: NativeType = .pointer
}
