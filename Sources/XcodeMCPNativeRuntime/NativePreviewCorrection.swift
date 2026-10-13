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
        snapshot["description"] = .string("The full path to the preview snapshot. Direct SwiftUI previews capture the rectangular hosting view without hardware display cutout masks. Other previews use Xcode's native snapshot format.")
        properties["previewSnapshotPath"] = .object(snapshot)
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
        let location: (line: Int, column: Int, displayName: String)
        let destination: AnyObject
    }

    private func prepare(_ input: Input) async throws -> Prepared {
        try Task.checkCancellation()
        let workspace = try await workspace(input.workspaceIdentifier)
        let source = try await sourceURL(input.sourcePath, workspace: workspace)
        let location = try await registryLocation(source: source, index: input.index)
        guard let destination = try builder.selectDestination(workspace: workspace, preferred: input.destination) else {
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

    private func renderApp(_ input: Input, prepared: Prepared, app: URL) async throws -> JSONValue {
        let artifacts = URL(filePath: input.artifacts, directoryHint: .isDirectory)
        let process = NativePreviewProcess(installation: installation, artifacts: artifacts)
        let workspace = prepared.workspace
        let source = prepared.source
        let location = prepared.location
        let destination = prepared.destination
        let build = try await builder.build(workspace: workspace, destination: destination)
        let selection = try Self.selectTarget(build.targets, source: source)
        let target = selection.host
        guard target.architecture == "arm64", target.sdkRoot.contains("iphonesimulator"), target.debugDylibEnabled else {
            throw NativePipelineRequired()
        }
        guard let version = build.systemVersion, version.compare("18.4", options: .numeric) != .orderedAscending else {
            throw NativePipelineRequired()
        }
        guard let output = target.outputURL else {
            throw NativeRuntimeError.unsupportedContract("The preview target has no linked product")
        }
        let product = try Self.productBundle(containing: output)
        let entitlements = try NativePreviewEntitlements.read(from: product)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/PreviewRenderer/iphonesimulator-arm64")
        try prepareApp(product: product, helper: helper, app: app)
        if let simulatorEntitlements = entitlements.simulator {
            let section = app.deletingLastPathComponent().appendingPathComponent("simulator-entitlements.plist")
            try simulatorEntitlements.write(to: section)
            let archive = helper.appendingPathComponent("libXcodeMCPPreviewRenderer.a").path
            let sdk = try await process.xcrun(["--sdk", "iphonesimulator", "--show-sdk-path"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await process.xcrun(["--sdk", "iphonesimulator", "swiftc", "-target", "arm64-apple-ios18.4-simulator",
                "-sdk", sdk, archive, "-lc++", "-Xlinker", "-force_load", "-Xlinker", archive,
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements", "-Xlinker", section.path,
                "-o", app.appendingPathComponent("XcodeMCPPreviewRenderer").path])
        }
        let libraries = try previewLibraries(in: app)
        let registryLibraries = try Self.registryLibraries(in: app, previewLibraries: libraries)
        let libraryPaths = try Self.libraryPaths(in: app, previewLibraries: libraries,
            registryLibraries: registryLibraries, sourceOutput: selection.source.outputURL)
        let symbols = try await process.xcrun(["nm", "-arch", "arm64", "-j"] + registryLibraries.map(\.path))
        let names = Self.registryNames(in: symbols)
        let request = PreviewRendererRequest(libraryNames: libraryPaths, registryNames: names,
            fileName: source.lastPathComponent, moduleName: selection.source.moduleName, lineNumber: location.line, columnNumber: location.column,
            definitionIndex: input.index, localization: input.localization)
        try JSONEncoder().encode(request).write(to: app.appendingPathComponent("PreviewRequest.json"))
        var signing = ["--force", "--sign", "-"]
        if let signedEntitlements = entitlements.signed {
            let plist = app.deletingLastPathComponent().appendingPathComponent("signed-entitlements.plist")
            try signedEntitlements.write(to: plist)
            signing += ["--entitlements", plist.path]
        }
        _ = try await process.run("/usr/bin/codesign", signing + [app.path])
        try Task.checkCancellation()
        // Keep allocation alive through cancellation so its created identifier
        // is always available to the cleanup owner below.
        let allocation = Task { @MainActor in
            try await createSimulator(app: app, build: build, process: process)
        }
        let simulator = try await allocation.value
        var result: JSONValue?
        var failure: (any Error)?
        do {
            _ = try await process.xcrun(["simctl", "boot", simulator.identifier])
            _ = try await process.xcrun(["simctl", "bootstatus", simulator.identifier, "-b"])
            _ = try await process.xcrun(["simctl", "install", simulator.identifier, app.path])
            var launch = ["simctl", "launch", simulator.identifier, simulator.bundleIdentifier]
            if let locale = input.localization {
                let languages = try PropertyListSerialization.data(fromPropertyList: [locale], format: .xml, options: 0)
                launch += ["-AppleLanguages", String(decoding: languages, as: UTF8.self), "-AppleLocale", locale]
            }
            _ = try await process.xcrun(launch)
            let container = try await process.xcrun(["simctl", "get_app_container", simulator.identifier, simulator.bundleIdentifier, "data"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let documents = URL(filePath: container, directoryHint: .isDirectory).appendingPathComponent("Documents")
            let responseURL = documents.appendingPathComponent("PreviewResult.json")
            while !FileManager.default.fileExists(atPath: responseURL.path) {
                try await Task.sleep(for: .milliseconds(100))
            }
            let response = try JSONDecoder().decode(PreviewRendererResult.self, from: Data(contentsOf: responseURL))
            if response.requiresNativePipeline == true { throw NativePipelineRequired() }
            if let error = response.error { throw NativeRuntimeError.invocation(error) }
            guard let snapshot = response.snapshotName else {
                throw NativeRuntimeError.unsupportedContract("The preview renderer returned no snapshot")
            }
            let snapshotURL = artifacts.appendingPathComponent("preview.png")
            try FileManager.default.copyItem(at: documents.appendingPathComponent(snapshot), to: snapshotURL)
            var fields: [String: JSONValue] = [
                "previewSnapshotPath": .string(snapshotURL.path), "errors": .array([]),
                "renderedDestination": .object(simulator.destination),
                "supportedLocalizations": .array(try await supportedLocalizations(in: workspace).map(JSONValue.string)),
            ]
            fields["displayName"] = .string(response.displayName ?? location.displayName)
            if let line = response.sourceLineNumber { fields["sourceLineNumber"] = .number(.int(Int64(line))) }
            result = .object(fields)
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
        return result!
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

    static func selectTarget(_ targets: [NativePreviewBuild.Target], source: URL) throws -> Selection {
        let sourcePath = source.resolvingSymlinksInPath().path
        let sources = targets.filter { $0.sourceFiles.contains { $0.resolvingSymlinksInPath().path == sourcePath } }
        guard !sources.isEmpty else {
            throw NativeRuntimeError.invalidRequest("The active scheme did not build \(source.path)")
        }
        var selections: [Selection] = []
        for target in sources {
            if target.outputURL.map({ $0.path.contains(".app/") || $0.path.contains(".appex/") }) == true {
                selections.append(Selection(source: target, host: target))
                continue
            }
            let objectPaths = Set(target.objectFiles.map { $0.resolvingSymlinksInPath().path })
            let sourceOutput = target.outputURL
            let frameworkName = sourceOutput?.pathComponents.last(where: { $0.hasSuffix(".framework") })
            let hosts = try targets.filter { candidate in
                guard let output = candidate.outputURL, output.path.contains(".app/") else { return false }
                if candidate.objectFiles.contains(where: { objectPaths.contains($0.resolvingSymlinksInPath().path) }) {
                    return true
                }
                guard let sourceOutput else { return false }
                if ["a", "o", "dylib"].contains(sourceOutput.pathExtension), try candidate.linksProduct(at: sourceOutput) { return true }
                guard frameworkName != nil || sourceOutput.pathExtension == "dylib" else { return false }
                let app = try productBundle(containing: output)
                let rootLibrary = app.appendingPathComponent(sourceOutput.lastPathComponent)
                if frameworkName == nil, FileManager.default.fileExists(atPath: rootLibrary.path),
                   try NativePreviewBinary.matches(sourceOutput, rootLibrary) {
                    return true
                }
                let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
                guard FileManager.default.fileExists(atPath: frameworks.path) else { return false }
                return try FileManager.default.subpathsOfDirectory(atPath: frameworks.path).contains { subpath in
                    let library = frameworks.appendingPathComponent(subpath)
                    guard library.lastPathComponent == sourceOutput.lastPathComponent,
                          frameworkName.map({ library.pathComponents.contains($0) }) ?? true else { return false }
                    return try NativePreviewBinary.matches(sourceOutput, library)
                }
            }
            selections += hosts.map { Selection(source: target, host: $0) }
        }
        let runnable = selections.filter { $0.host.isRunnable }
        let candidates = runnable.isEmpty ? selections : runnable
        guard candidates.count == 1 else { throw NativePipelineRequired() }
        return candidates[0]
    }

    private func registryLocation(source: URL, index: Int) async throws -> (line: Int, column: Int, displayName: String) {
        let runtime = ABIRuntime.shared
        let action = try await runtime.resolveSwiftType(named: "PreviewsXcode.RenderPreviewAction",
            in: .path(installation.framework("PreviewsXcode", in: "PlugIns")))
        let unit = try await runtime.resolveSwiftType(named: "PreviewsPipeline.PreviewTranslationUnit",
            in: .path(installation.framework("PreviewsPipeline", in: "SharedFrameworks")))
        let parse = try await action.resolveStaticMethod(
            named: "(parseTranslationUnit in _FEA7E13ECD12FBA8521281D73C9764CE)(sourceFileURL: Foundation.URL) throws -> (translationUnit: PreviewsPipeline.PreviewTranslationUnit, previews: [PreviewsXcode.RenderPreviewAction.(RenderPreviewType in _FEA7E13ECD12FBA8521281D73C9764CE)])",
            as: ((PreviewURL) throws -> NativeSwiftValue).self, valueABIs: [unit: .opaque(named: unit.name)])
        let parsed = try unsafe parse.unsafeInvoke(PreviewURL(value: source))
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
        // Native enumeration includes PreviewProvider definitions. Its ordering
        // must be retained when selecting a registry from the built dylib.
        func own<T>(_ value: T) async throws -> NativeSwiftValue {
            let identity = try await runtime.resolveSwiftFunction(named: "XcodeMCPNativeRuntime.nativePreviewValue<A>(A) -> A",
                as: ((T) -> NativeSwiftValue).self, genericArguments: [.type(T.self)])
            return try unsafe identity.unsafeInvoke(value)
        }
        let definition = try await _openExistential(previews[index], do: own)
        guard let registry = try await definition.resolveEnumPayload(forCase: "registryPreview") else {
            throw NativePipelineRequired()
        }
        let getLine = try await registry.type.resolveGetter(named: "lineNumber", as: (() -> Int).self,
            receiverABI: .opaque(named: registry.type.name))
        let line = try unsafe getLine.unsafeInvoke(on: registry)
        let getDisplayName = try await registry.type.resolveGetter(
            named: "(extension in PreviewsPipeline):PreviewsModel.RegistryDefinition.defaultDisplayName.getter : Swift.String",
            as: (() -> String).self, receiverABI: .opaque(named: registry.type.name))
        let displayName = try unsafe getDisplayName.unsafeInvoke(on: registry)
        let model = ImageSelector.path(installation.framework("PreviewsModel", in: "SharedFrameworks"))
        let locationType = try await runtime.resolveSwiftType(named: "PreviewsModel.SourceLocation", in: model)
        let boundType = try await runtime.resolveSwiftType(named: "PreviewsModel.SourceLocation.Bound", in: model)
        let getLocation = try await registry.type.resolveGetter(named: "fullSourceLocation", as: (() -> NativeSwiftValue).self,
            valueABIs: [locationType: .opaque(named: locationType.name)], receiverABI: .opaque(named: registry.type.name))
        let location = try unsafe getLocation.unsafeInvoke(on: registry)
        let getBound = try await location.type.resolveGetter(named: "lowerBound", as: (() -> NativeSwiftValue).self,
            valueABIs: [boundType: .opaque(named: boundType.name)], receiverABI: .opaque(named: location.type.name))
        let bound = try unsafe getBound.unsafeInvoke(on: location)
        let getColumn = try await bound.type.resolveGetter(named: "column", as: (() -> Int).self,
            receiverABI: .opaque(named: bound.type.name))
        let column = try unsafe getColumn.unsafeInvoke(on: bound)
        return try (line, Self.registryColumn(in: String(contentsOf: source, encoding: .utf8), line: line, utf16Column: column), displayName)
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

    private static func productBundle(containing output: URL) throws -> URL {
        var url = output.deletingLastPathComponent()
        while url.path != "/" {
            if ["app", "appex"].contains(url.pathExtension) { return url }
            url.deleteLastPathComponent()
        }
        throw NativeRuntimeError.unsupportedContract("The linked preview product is not an application or app extension")
    }

    private func prepareApp(product: URL, helper: URL, app: URL) throws {
        try FileManager.default.copyItem(at: product, to: app)
        let executable = helper.appendingPathComponent("XcodeMCPPreviewRenderer")
        try FileManager.default.copyItem(at: executable, to: app.appendingPathComponent("XcodeMCPPreviewRenderer"))
        var info = try bundleInfo(at: app)
        info["CFBundleExecutable"] = "XcodeMCPPreviewRenderer"
        info["CFBundlePackageType"] = "APPL"
        // The renderer owns UIKit startup before the original code is loaded.
        info["NSPrincipalClass"] = nil
        info["UIMainStoryboardFile"] = nil
        if (info["MinimumOSVersion"] as? String ?? "").compare("18.4", options: .numeric) == .orderedAscending {
            info["MinimumOSVersion"] = "18.4"
        }
        info["NSExtension"] = nil
        info["UIApplicationSceneManifest"] = ["UIApplicationSupportsMultipleScenes": false,
            "UISceneConfigurations": ["UIWindowSceneSessionRoleApplication": [["UISceneConfigurationName": "Preview", "UISceneDelegateClassName": "XcodeMCPPreviewRenderer.PreviewRendererScene"]]]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        if product.pathExtension == "appex" {
            let parentFrameworks = product.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Frameworks")
            if FileManager.default.fileExists(atPath: parentFrameworks.path) {
                try copyContents(parentFrameworks, to: frameworks)
            }
        }
        try copyContents(helper.appendingPathComponent("Frameworks"), to: frameworks)
    }

    private func copyContents(_ source: URL, to destination: URL) throws {
        for item in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let output = destination.appendingPathComponent(item.lastPathComponent)
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            try FileManager.default.copyItem(at: item, to: output)
        }
    }

    private func previewLibraries(in app: URL) throws -> [URL] {
        let libraries = try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".debug.dylib") }
        guard !libraries.isEmpty else { throw NativePipelineRequired() }
        return libraries
    }

    static func registryLibraries(in app: URL, previewLibraries: [URL]) throws -> [URL] {
        var libraries = previewLibraries
        libraries += try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "dylib" }
        let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
        for subpath in try FileManager.default.subpathsOfDirectory(atPath: frameworks.path) {
            let item = frameworks.appendingPathComponent(subpath)
            if item.pathExtension == "framework" {
                if let executable = Bundle(url: item)?.executableURL { libraries.append(executable) }
            } else if item.pathExtension == "dylib" {
                libraries.append(item)
            }
        }
        return Array(Set(libraries.map { $0.resolvingSymlinksInPath() })).sorted { $0.path < $1.path }
    }

    static func libraryPaths(in app: URL, previewLibraries: [URL], registryLibraries: [URL], sourceOutput: URL?) throws -> [String] {
        var libraries = previewLibraries
        if let sourceOutput, !sourceOutput.path.contains(".app/"), !sourceOutput.path.contains(".appex/") {
            let frameworkName = sourceOutput.pathComponents.last(where: { $0.hasSuffix(".framework") })
            if frameworkName != nil || sourceOutput.pathExtension == "dylib" {
                guard let sourceLibrary = try registryLibraries.first(where: { library in
                    guard library.lastPathComponent == sourceOutput.lastPathComponent,
                          frameworkName.map({ library.pathComponents.contains($0) }) ?? true else { return false }
                    return try NativePreviewBinary.matches(sourceOutput, library)
                }) else { throw NativePipelineRequired() }
                libraries.append(sourceLibrary)
            }
        }
        let root = app.resolvingSymlinksInPath().path + "/"
        var paths: [String] = []
        for library in libraries {
            let path = library.resolvingSymlinksInPath().path
            guard path.hasPrefix(root) else { throw NativePipelineRequired() }
            let relative = String(path.dropFirst(root.count))
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

    private struct Simulator {
        let identifier: String
        let bundleIdentifier: String
        let destination: [String: JSONValue]
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
        let info = try bundleInfo(at: app)
        guard let bundleIdentifier = info["CFBundleIdentifier"] as? String else {
            throw NativeRuntimeError.unsupportedContract("The built preview product has no bundle identifier")
        }
        let identifier = try await process.xcrun(["simctl", "create", "XcodeMCPPreview-\(UUID().uuidString)", deviceID, runtimeID])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Simulator(identifier: identifier, bundleIdentifier: bundleIdentifier,
            destination: ["identifier": .string(build.destinationIdentifier),
                "platformName": .string(build.platformName ?? "iOS"),
                "deviceModelName": .string(build.deviceModelName ?? selected.1["name"] as? String ?? deviceID),
                "systemVersion": .string(build.systemVersion ?? runtimeID)])
    }

    private func bundleInfo(at bundle: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: bundle.appendingPathComponent("Info.plist"))
        guard let info = try unsafe PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NativeRuntimeError.unsupportedContract("The built preview product has an unsupported Info.plist")
        }
        return info
    }

    private struct Input: Sendable {
        let workspaceIdentifier: String?
        let artifacts: String
        let sourcePath: String
        let index: Int
        let localization: String?
        let destination: [String: String]
        let timeout: Int
        let requiresNativePipeline: Bool
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> Input {
        let value = try JSONDecoder().decode(type, from: data)
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
        let requiresNativePipeline = !variants.isEmpty || controlFields.values.contains { Mirror(reflecting: $0).children.first != nil }
        let requestedDestination = fields["preferredRenderDestination"].flatMap { Mirror(reflecting: $0).children.first?.value }
        let destination = requestedDestination.map { Dictionary(uniqueKeysWithValues: Mirror(reflecting: $0).children.compactMap { field -> (String, String)? in
            guard let label = field.label, let value = field.value as? String? ?? nil else { return nil }
            return (label, value)
        }) } ?? [:]
        return Input(workspaceIdentifier: fields["workspaceIdentifier"] as? String? ?? nil, artifacts: artifacts, sourcePath: path,
            index: index, localization: fields["previewLocalizationOverride"] as? String? ?? nil,
            destination: destination, timeout: timeout,
            requiresNativePipeline: requiresNativePipeline)
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
