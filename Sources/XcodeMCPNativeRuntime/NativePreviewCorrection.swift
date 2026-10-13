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
                         native: @MainActor @Sendable () async throws -> AsyncStream<Data>) async throws {
        do {
            guard !input.requiresNativePipeline else { throw NativePipelineRequired() }
            let prepared = try await prepare(input)
            let result = try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask { try await self.render(input, prepared: prepared) }
                group.addTask {
                    try await Task.sleep(for: .seconds(input.timeout))
                    throw NativeRuntimeError.invocation("Preview rendering exceeded \(input.timeout) seconds")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            continuation.yield(try event("completed", result))
        } catch is NativePipelineRequired {
            try Task.checkCancellation()
            let stream = try await native()
            for await event in stream {
                try Task.checkCancellation()
                continuation.yield(event)
            }
        }
    }

    @MainActor
    private struct Prepared {
        let workspace: AnyObject
        let source: URL
        let location: (line: Int, column: Int)
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
        let artifacts = URL(filePath: input.artifacts, directoryHint: .isDirectory)
        let process = NativePreviewProcess(installation: installation, artifacts: artifacts)
        let workspace = prepared.workspace
        let source = prepared.source
        let location = prepared.location
        let destination = prepared.destination
        let build = try await builder.build(workspace: workspace, destination: destination)
        let target = try selectTarget(build.targets, source: source)
        guard target.architecture == "arm64", target.sdkRoot.contains("iphonesimulator") else {
            throw NativePipelineRequired()
        }
        guard let version = build.systemVersion, version.compare("18.4", options: .numeric) != .orderedAscending else {
            throw NativePipelineRequired()
        }
        guard let output = target.outputURL else {
            throw NativeRuntimeError.unsupportedContract("The preview target has no linked product")
        }
        let product = try productBundle(containing: output)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/PreviewRenderer/iphonesimulator-arm64")
        let app = artifacts.appendingPathComponent("Preview.app", isDirectory: true)
        try prepareApp(product: product, helper: helper, app: app)
        let libraries = try previewLibraries(in: app)
        let symbols = try await process.xcrun(["nm", "-arch", "arm64", "-j"] + libraries.map(\.path))
        let names = registryNames(in: symbols)
        let request = PreviewRendererRequest(libraryNames: libraries.map(\.lastPathComponent), registryNames: names,
            fileName: source.lastPathComponent, moduleName: target.moduleName, lineNumber: location.line, columnNumber: location.column,
            definitionIndex: input.index, localization: input.localization)
        try JSONEncoder().encode(request).write(to: app.appendingPathComponent("PreviewRequest.json"))
        _ = try await process.run("/usr/bin/codesign", ["--force", "--sign", "-", "--deep", app.path])
        try Task.checkCancellation()
        // Keep allocation alive through cancellation so its created identifier
        // is always available to the cleanup owner below.
        let allocation = Task { @MainActor in
            try await createSimulator(input: input, build: build, process: process)
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
            if let name = response.displayName { fields["displayName"] = .string(name) }
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

    private func selectTarget(_ targets: [NativePreviewBuild.Target], source: URL) throws -> NativePreviewBuild.Target {
        let sourcePath = source.resolvingSymlinksInPath().path
        guard let target = targets.first(where: { $0.sourceFiles.contains { $0.resolvingSymlinksInPath().path == sourcePath } }) else {
            throw NativeRuntimeError.invalidRequest("The active scheme did not build \(source.path)")
        }
        if target.outputURL.map({ $0.path.contains(".app/") || $0.path.contains(".appex/") }) == true { return target }
        guard let host = targets.first(where: { $0.outputURL?.path.contains(".app/") == true }) else {
            throw NativeRuntimeError.unsupportedContract("The preview source requires a built application host")
        }
        return NativePreviewBuild.Target(moduleName: target.moduleName, buildableName: host.buildableName,
            sdkRoot: host.sdkRoot, sdkVariant: host.sdkVariant, architecture: host.architecture,
            linkCommandLine: host.linkCommandLine, linkerWorkingDirectory: host.linkerWorkingDirectory,
            objectFiles: host.objectFiles, sourceFiles: target.sourceFiles, debugDylibEnabled: host.debugDylibEnabled)
    }

    private func registryLocation(source: URL, index: Int) async throws -> (line: Int, column: Int) {
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
        return try (line, Self.registryColumn(in: String(contentsOf: source, encoding: .utf8), line: line, utf16Column: column))
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

    private func productBundle(containing output: URL) throws -> URL {
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

    func registryNames(in symbols: String) -> [String] {
        Set(symbols.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let symbol = String(line)
            guard symbol.hasPrefix("_$s"), symbol.hasSuffix("VMn"), symbol.contains("PreviewRegistry") else { return nil }
            return String(symbol.dropFirst(3).dropLast(2))
        }).sorted()
    }

    private struct Simulator {
        let identifier: String
        let bundleIdentifier: String
        let destination: [String: JSONValue]
    }

    private func createSimulator(input: Input, build: NativePreviewBuild.Result, process: NativePreviewProcess) async throws -> Simulator {
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
        let info = try bundleInfo(at: URL(filePath: input.artifacts).appendingPathComponent("Preview.app"))
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

private struct NativePipelineRequired: Error {}

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
