import ABIBridge
import ABIBridgeCore
import ABIBridgeCore.Backend
import Foundation
import XcodeMCPWire

@safe
@MainActor
final class NativePreviewBuild {
    struct Result {
        let targets: [Target]
        let previewRoots: [Target]
        let destinationIdentifier: String
        let previewDestinationIdentifier: String
        let platformIdentifier: String?
        let previewPlatform: NativePreviewPlatform?
        let platformName: String?
        let deviceModelName: String?
        let systemVersion: String?
        var buildStartedAt: Date? = nil
        var buildCompletedAt: Date? = nil
        var workspaceBuilder: AnyObject? = nil
        var declaredInputFiles: Set<URL>? = nil
        var missingInputFiles: Set<URL> = []
        var inputProducts: Set<URL> = []
        var generatedInputPaths: Set<URL> = []
        var generatedInputFiles: Set<URL> = []
        var generatedMissingInputFiles: Set<URL> = []
        var generatedInputExclusions: Set<URL> = []
        var inputCaptureExclusions: Set<URL> = []

        var productURLs: [URL] { targets.compactMap(\.outputURL) }
    }

    struct Target {
        let moduleName: String?
        let buildableName: String
        let sdkRoot: String
        let sdkVariant: String?
        let architecture: String
        let linkCommandLine: [String]
        let linkerWorkingDirectory: String?
        let objectFiles: [URL]
        let sourceFiles: Set<URL>
        let debugDylibEnabled: Bool
        let isRunnable: Bool
        var compileCommandLine: [String] = []
        var enableAddressSanitizer = false
        var enableThreadSanitizer = false
        var enableUndefinedBehaviorSanitizer = false
        var rendererEnvironment: [String: String] = [:]
        var isDynamicPackageProduct = false
        var containsPreviewSource = false
        var dependencies: [Target] = []
        var resourceURLs: [URL] = []

        var outputURL: URL? {
            guard let index = linkCommandLine.lastIndex(of: "-o"),
                  linkCommandLine.indices.contains(index + 1) else { return nil }
            let path = linkCommandLine[index + 1]
            if path.hasPrefix("/") { return URL(filePath: path) }
            guard let linkerWorkingDirectory else { return nil }
            return URL(filePath: path, relativeTo: URL(filePath: linkerWorkingDirectory, directoryHint: .isDirectory))
                .absoluteURL
        }

        func linksProduct(at product: URL) throws -> Bool {
            let productPath = product.resolvingSymlinksInPath().path
            return try linkedInputs().files.contains { $0.resolvingSymlinksInPath().path == productPath }
        }

        func linkedInputs(in rawCommand: [String]? = nil) throws -> (files: [URL], searchPaths: [(framework: Bool, url: URL)],
                                      libraries: [(framework: Bool, name: String, file: URL?)]) {
            let command = linkArguments(in: rawCommand ?? linkCommandLine).map(\.value)
            var inputs = command.compactMap { url(for: $0) }
            let searchPaths = searchPaths(in: command).map { (framework: $0.argument != "-L", url: $0.url) }
            var namedInputs: [(framework: Bool, name: String)] = []
            for index in command.indices {
                let argument = command[index]
                let next = command.indices.contains(index + 1) ? command[index + 1] : nil
                if argument == "-filelist", let fileList = next.flatMap({ url(for: $0) }) {
                    let paths = try String(contentsOf: fileList, encoding: .utf8).split(whereSeparator: \.isNewline)
                    inputs += paths.compactMap { url(for: String($0)) }
                } else if argument == "-framework", let next {
                    namedInputs.append((true, next))
                } else if argument.hasPrefix("-l") {
                    if let name = argument.count == 2 ? next : String(argument.dropFirst(2)) {
                        namedInputs.append((false, name))
                    }
                }
            }
            let libraries = namedInputs.map { input in
                let names = input.framework ? ["\(input.name).framework/\(input.name)"] : ["lib\(input.name).dylib", "lib\(input.name).a"]
                let candidates = searchPaths.filter { $0.framework == input.framework }.flatMap { path in
                    names.map { path.url.appendingPathComponent($0) }
                }
                return (framework: input.framework, name: input.name,
                    file: candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }))
            }
            inputs += libraries.compactMap(\.file)
            var seen: Set<URL> = []
            return (inputs.filter { seen.insert($0.resolvingSymlinksInPath()).inserted }, searchPaths, libraries)
        }

        func linkArguments(in command: [String]) -> [(value: String, forwarded: Bool)] {
            var result: [(value: String, forwarded: Bool)] = []
            var index = 0
            while index < command.count {
                let argument = command[index]
                if argument == "-Xlinker", command.indices.contains(index + 1) {
                    result.append((command[index + 1], true))
                    index += 2
                } else if argument.hasPrefix("-Wl,") {
                    result += argument.dropFirst(4).split(separator: ",", omittingEmptySubsequences: false).map { (String($0), true) }
                    index += 1
                } else {
                    result.append((argument, false))
                    index += 1
                }
            }
            return result
        }

        func searchPaths(in command: [String]) -> [(argument: String, url: URL)] {
            command.indices.compactMap { index in
                let argument = command[index]
                guard let option = ["-Fsystem", "-F", "-L"].first(where: { argument.hasPrefix($0) }) else { return nil }
                let path: String
                if argument == option {
                    guard command.indices.contains(index + 1) else { return nil }
                    path = command[index + 1]
                } else { path = String(argument.dropFirst(option.count)) }
                return url(for: path).map { (option, $0) }
            }
        }

        func url(for path: String) -> URL? {
            if path.hasPrefix("/") { return URL(filePath: path) }
            guard let linkerWorkingDirectory else { return nil }
            return URL(filePath: path, relativeTo: URL(filePath: linkerWorkingDirectory, directoryHint: .isDirectory)).absoluteURL
        }
    }

    private let runtime = ABIRuntime.shared
    private let installation: NativeXcodeInstallation
    private var clients: [UUID: Cancellation] = [:]
    private var performMethod: NativeSwiftMethod<@concurrent (AnyObject, AnyObject) async throws -> AnyObject>?

    init(installation: NativeXcodeInstallation) {
        self.installation = installation
    }

    func prepare(workspace: AnyObject) async throws -> NativeSwiftMethod<@concurrent (AnyObject, AnyObject) async throws -> AnyObject> {
        if let performMethod { return performMethod }
        let bound = try await runtime.object(workspace).resolve(
            .swift(
                .method(
                    "(extension in PreviewsIDEAPI):__C.IDEWorkspace.performTask(on: __C.IDEScheme, for: __C.IDESchemeOperationParameters) async throws -> __C.DVTOperation",
                    as: (@concurrent (AnyObject, AnyObject) async throws -> AnyObject).self)))
        performMethod = bound.method
        return bound.method
    }

    func runnableBuildable(in scheme: AnyObject) throws -> AnyObject? {
        guard let action = try NativeObjCGetters.object(scheme, selector: "launchSchemeAction"),
              let runnable = try NativeObjCGetters.object(action, selector: "runnable") else { return nil }
        return try NativeObjCGetters.object(runnable, selector: "buildableProduct")
    }

    static func isRunnable(_ buildable: NSObject, runnable: AnyObject?) -> Bool {
        guard let runnable else { return false }
        return buildable.isEqual(runnable)
    }

    func build(workspace: AnyObject, destination selection: NativePreviewDestinations.Selection, source: URL) async throws -> Result {
        try Task.checkCancellation()
        let info = selection.selected
        let destination = info.value
        let image = installation.framework("PreviewsIDEAPI", in: "PlugIns")
        let buildSystem = try await runtime.resolve(.swift(.type("PreviewsIDEAPI.BuildSystem")), in: .path(image))
        let buildables = try await buildSystem.resolve(
            .swift(
                .staticMethod(
                    "buildables(scheme: __C.IDEScheme, workspace: __C.IDEWorkspace, runContextManager: __C.IDERunContextManager, executionEnvironment: __C.IDEExecutionEnvironment) -> [__C.IDEBuildable]",
                    as: ((AnyObject, AnyObject, AnyObject, AnyObject) -> NativeSwiftValue).self)))
        let clientType = try await runtime.resolve(.swift(.type("PreviewsIDEAPI.BuildOperationClient")), in: .path(image))
        let initialize = try await clientType.resolve(.swift(.initializer("init() -> PreviewsIDEAPI.BuildOperationClient", as: (() -> AnyObject).self)))
        let client = try unsafe initialize.unsafeInvoke()
        let cancel = try await runtime.object(client).resolve(.swift(.method("cancelBuildOperation() -> ()", as: (() -> Void).self)))
        let cancellation = Cancellation(cancel: { try unsafe cancel.unsafeInvoke() })
        let identifier = UUID()
        clients[identifier] = cancellation
        defer { clients[identifier] = nil }

        let perform = try await prepare(workspace: workspace)
        let workspaceBuilder = try? selection.workspaceBuilder()
        try Task.checkCancellation()
        // Match BuildSystem.buildScheme: capture the selection before the task can update the model.
        guard let manager = try NativeObjCGetters.object(workspace, selector: "runContextManager"),
              let scheme = try NativeObjCGetters.object(manager, selector: "activeRunContext"),
              let environment = try NativeObjCGetters.object(workspace, selector: "executionEnvironment") else {
            throw NativeRuntimeError.invalidRequest("The workspace has no active scheme, run destination, or execution environment")
        }
        let runnable = try runnableBuildable(in: scheme)
        let selectedBuildables = try unsafe buildables.unsafeInvoke(scheme, workspace, manager, environment)
        let parameters = try operationParameters(environment: environment, destination: destination, client: client)
        let buildStartedAt = Date()
        let operation: AnyObject = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try unsafe await perform.unsafeInvoke(on: workspace, scheme, parameters)
        } onCancel: {
            Task { @MainActor in cancellation.cancel() }
        }
        let buildCompletedAt = Date()
        try Task.checkCancellation()
        try cancellation.checkFailure()
        let operations = try buildOperations(in: operation)
        guard let priorBuild = operations.last else {
            throw NativeRuntimeError.invocation("The native scheme task returned no IDEBuildOperation")
        }
        try checkBuildResults(operations)
        let descriptions = try await targetDescriptions(for: selectedBuildables, workspace: workspace, priorBuild: priorBuild, image: image)
        try Task.checkCancellation()
        let records = try await targets(descriptions, buildables: selectedBuildables, image: image, runnable: runnable, priorBuild: priorBuild,
            workspace: workspace, source: source, platform: info.previewPlatform, scheme: scheme, destination: destination)
        var result = Result(targets: records.targets, previewRoots: records.previewRoots, destinationIdentifier: info.identifier,
                      previewDestinationIdentifier: info.previewIdentifier,
                      platformIdentifier: info.platformIdentifier, previewPlatform: info.previewPlatform,
                      platformName: info.platformName, deviceModelName: info.deviceModelName, systemVersion: info.systemVersion)
        result.buildStartedAt = buildStartedAt
        result.buildCompletedAt = buildCompletedAt
        result.workspaceBuilder = workspaceBuilder
        do {
            var compilerCommands: [NativePreviewBuildInputs.CompilerCommand] = []
            var pendingInputs = result.targets + result.previewRoots
            while let target = pendingInputs.popLast() {
                if !target.compileCommandLine.isEmpty {
                    // The preview-info adapter exposes no compiler CWD; linker CWD is a separate contract.
                    compilerCommands.append(.init(arguments: target.compileCommandLine, workingDirectory: nil))
                }
                pendingInputs += target.dependencies
            }
            if let inputs = try await declaredInputs(for: selectedBuildables, workspace: workspace, priorBuild: priorBuild,
                compilerCommands: compilerCommands) {
                result.declaredInputFiles = inputs.files
                result.missingInputFiles = inputs.missing
                result.inputProducts = inputs.products
                result.generatedInputPaths = inputs.generated
                result.generatedInputFiles = inputs.generatedFiles
                result.generatedMissingInputFiles = inputs.generatedMissingFiles
                result.generatedInputExclusions = inputs.discovery
                result.inputCaptureExclusions = inputs.exclusions
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
        }
        return result
    }

    func cancelPendingOperations() {
        for client in Array(clients.values) { client.cancel() }
    }

    private func operationParameters(environment: AnyObject, destination: AnyObject, client: AnyObject) throws -> AnyObject {
        guard let commandClass = NSClassFromString("IDESchemeCommand"),
              let parametersClass = NSClassFromString("IDESchemeOperationParameters") else {
            throw NativeRuntimeError.unavailable("Xcode scheme operation classes are unavailable")
        }
        let command = try runtime.object(commandClass as AnyObject).resolveAndWait(.objc(.method("launchSchemeCommand", as: (() -> AnyObject).self)))
        let factory = try runtime.object(parametersClass as AnyObject).resolveAndWait(
            .objc(
                .method(
                    "operationParametersWithSchemeTask:buildCommand:executionEnvironment:runDestination:schemeCommand:commandName:invocationRecord:",
                    as: ((Int64, Int64, AnyObject, AnyObject, AnyObject, String, AnyObject?) -> AnyObject).self)))
        // BuildSystem.buildScheme uses these native scheme-task/build-command
        // values. Performing the task directly does not launch a preview agent.
        let parameters = try unsafe factory.unsafeInvoke(2, 8, environment, destination, command.unsafeInvoke(), "Build", nil)
        let setClient = try runtime.object(parameters).resolveAndWait(.objc(.method("setBuildOperationClientInfo:", as: ((AnyObject) -> Void).self)))
        try unsafe setClient.unsafeInvoke(client)
        return parameters
    }

    private func buildOperations(in operation: AnyObject) throws -> [AnyObject] {
        guard let buildClass = NSClassFromString("IDEBuildOperation"),
              let groupClass = NSClassFromString("DVTOperationGroup"),
              let object = operation as? NSObject else {
            throw NativeRuntimeError.unsupportedContract("The native scheme task returned an unsupported operation")
        }
        if object.isKind(of: buildClass) { return [operation] }
        guard object.isKind(of: groupClass) else { return [] }
        let suboperations = try runtime.object(operation).resolveAndWait(.objc(.method("suboperations", as: (() -> NSArray).self)))
        return try unsafe suboperations.unsafeInvoke().flatMap { try buildOperations(in: $0 as AnyObject) }
    }

    private func checkBuildResults(_ operations: [AnyObject]) throws {
        for operation in operations {
            let result = try runtime.object(operation).resolveAndWait(.objc(.method("result", as: (() -> Int).self)))
            let value = try unsafe result.unsafeInvoke()
            // performTask finishes the operation without throwing compiler failures.
            // Xcode's BuildOperationErrorDetector treats native result 1 as success.
            guard value == 1 else {
                let messages = try NativeObjCGetters.object(operation, selector: "buildLog").map { try buildErrors(in: $0) } ?? []
                let details = messages.joined(separator: "\n")
                throw NativeRuntimeError.invocation(details.isEmpty
                    ? "The native build failed with result \(value)"
                    : "The native build failed with result \(value):\n\(details)")
            }
        }
    }

    private func buildErrors(in section: AnyObject) throws -> [String] {
        if let text = try NativeObjCGetters.optionalString(section, selector: "text") {
            let errors = try runtime.object(section).resolveAndWait(.objc(.method("totalNumberOfErrors", as: (() -> UInt).self)))
            let failures = try runtime.object(section).resolveAndWait(.objc(.method("totalNumberOfTestFailures", as: (() -> UInt).self)))
            guard try unsafe errors.unsafeInvoke() > 0 || failures.unsafeInvoke() > 0 else { return [] }
            let title = try NativeObjCGetters.optionalString(section, selector: "title")
            return [title.map { "\($0)\n\(text)" } ?? text]
        }
        let subsections = try runtime.object(section).resolveAndWait(.objc(.method("subsections", as: (() -> NSArray).self)))
        return try unsafe subsections.unsafeInvoke().flatMap { try buildErrors(in: $0 as AnyObject) }
    }

    private func targetDescriptions(for buildables: NativeSwiftValue, workspace: AnyObject, priorBuild: AnyObject,
                                    image: URL) async throws -> NativeSwiftValue {
        let buildSystem = try await runtime.resolve(.swift(.type("PreviewsIDEAPI.BuildSystem")), in: .path(image))
        let describe = try await buildSystem.resolve(
            .swift(
                .staticMethod(
                    "builtTargetDescriptions(workspace: __C.IDEWorkspace, priorBuild: __C.IDEBuildOperation, buildables: [__C.IDEBuildable]) async throws -> [(__C.IDEBuildable, [PreviewsIDEAPI.IDEBuiltTargetDescription])]",
                    as: (@concurrent (AnyObject, AnyObject, NativeSwiftValue) async throws -> NativeSwiftValue).self)))
        return try unsafe await describe.unsafeInvoke(workspace, priorBuild, buildables)
    }

    private typealias TargetRecord = (buildable: NSObject, native: Any, target: Target)

    private func targets(_ descriptions: NativeSwiftValue, buildables: NativeSwiftValue, image: URL, runnable: AnyObject?, priorBuild: AnyObject,
                         workspace: AnyObject, source: URL, platform: NativePreviewPlatform?,
                         scheme: AnyObject, destination: AnyObject) async throws -> (targets: [Target], previewRoots: [Target]) {
        let records = try await targetRecords(descriptions, image: image, runnable: runnable)
        var result = records.map(\.target)
        var previewRoots: [Target] = []
        if let platform {
            let selection = try NativePreviewStaging.selectTarget(result, source: source, platform: platform)
            if let index = result.firstIndex(where: {
                $0.outputURL == selection.host.outputURL && $0.sdkRoot == selection.host.sdkRoot
                    && $0.sdkVariant == selection.host.sdkVariant && $0.architecture == selection.host.architecture
            }) {
                result[index].rendererEnvironment = try sanitizerEnvironment(for: records[index].buildable, priorBuild: priorBuild,
                    scheme: scheme, destination: destination)
            }
            if let output = selection.source.outputURL,
               let index = result.firstIndex(where: {
                   $0.outputURL == output && $0.sdkRoot == selection.source.sdkRoot
                       && $0.sdkVariant == selection.source.sdkVariant && $0.architecture == selection.source.architecture
               }) {
                if try NativePreviewBinary.isStaticLibrary(at: output) {
                    result[index].compileCommandLine = try await compileCommandLine(for: records[index], priorBuild: priorBuild,
                        workspace: workspace, source: source, image: image)
                }
                if let hostOutput = selection.host.outputURL, NativePreviewStaging.productBundle(containing: hostOutput) == nil {
                    let sourceRecord = (buildable: records[index].buildable, native: records[index].native, target: result[index])
                    let dependencies = try await dependencies(for: sourceRecord, records: records, buildables: buildables, image: image,
                        priorBuild: priorBuild, workspace: workspace, scheme: scheme, destination: destination)
                    previewRoots = dependencies.roots
                    result[index].dependencies = dependencies.linkDependencies
                    result[index].resourceURLs = dependencies.resources
                    for dependency in dependencies.targets {
                        if let existing = result.firstIndex(where: {
                            $0.outputURL == dependency.outputURL && $0.sdkRoot == dependency.sdkRoot
                                && $0.sdkVariant == dependency.sdkVariant && $0.architecture == dependency.architecture
                        }) {
                            result[existing].compileCommandLine = dependency.compileCommandLine
                            result[existing].rendererEnvironment = dependency.rendererEnvironment
                            result[existing].isDynamicPackageProduct = dependency.isDynamicPackageProduct
                        } else { result.append(dependency) }
                    }
                }
            }
        }
        return (result, previewRoots)
    }

    private func targetRecords(_ descriptions: NativeSwiftValue, image: URL, runnable: AnyObject?) async throws -> [TargetRecord] {
        let type = try await runtime.resolve(.swift(.type("PreviewsIDEAPI.IDEBuiltTargetDescription")), in: .path(image))
        let receiver = try NativeType.opaque(named: type.name)
        let module = try await type.resolve(.swift(.getter("productModuleName", as: (() -> String?).self, receiverABI: receiver)))
        let name = try await type.resolve(.swift(.getter("buildableName", as: (() -> String).self, receiverABI: receiver)))
        let sdk = try await type.resolve(.swift(.getter("sdkRoot", as: (() -> String).self, receiverABI: receiver)))
        let variant = try await type.resolve(.swift(.getter("sdkVariant", as: (() -> String?).self, receiverABI: receiver)))
        let architecture = try await type.resolve(.swift(.getter("architecture", as: (() -> String).self, receiverABI: receiver)))
        let command = try await type.resolve(.swift(.getter("linkCommandLine", as: (() -> [String]).self, receiverABI: receiver)))
        let directory = try await type.resolve(.swift(.getter("linkerWorkingDirectory", as: (() -> String?).self, receiverABI: receiver)))
        let dylib = try await type.resolve(.swift(.getter("enableDebugDylib", as: (() -> Bool).self, receiverABI: receiver)))
        let address = try await type.resolve(.swift(.getter("enableAddressSanitizer", as: (() -> Bool).self, receiverABI: receiver)))
        let thread = try await type.resolve(.swift(.getter("enableThreadSanitizer", as: (() -> Bool).self, receiverABI: receiver)))
        let undefined = try await type.resolve(.swift(.getter("enableUndefinedBehaviorSanitizer", as: (() -> Bool).self, receiverABI: receiver)))
        let files = try await type.resolve(.swift(.getter("objectFiles", as: (() -> NativeSwiftValue).self, receiverABI: receiver)))
        let fileType = try await runtime.resolve(.swift(.type("PreviewsIDEAPI.IDEBuiltObjectFileDescription")), in: .path(image))
        let path = try await fileType.resolve(
            .swift(.getter("builtPath.getter : Foundation.URL", as: (() -> NativePreviewBuildURL).self, receiverABI: .opaque(named: fileType.name))))
        let sources = try await fileType.resolve(
            .swift(
                .getter(
                    "sourceFiles.getter : Swift.Set<Foundation.URL>", as: (() -> NativePreviewBuildSources).self, receiverABI: .opaque(named: fileType.name))))
        defer { withExtendedLifetime(descriptions) {} }
        let entries = try descriptions.withCopy { value -> [(NSObject, [Any])] in
            guard let entries = value as? [(NSObject, [Any])] else {
                throw NativeRuntimeError.unsupportedContract("Native built target descriptions have an unsupported array or tuple")
            }
            return entries
        }
        var result: [TargetRecord] = []
        for (buildable, records) in entries {
            let isRunnable = Self.isRunnable(buildable, runnable: runnable)
            let isDynamicPackageProduct = try self.isDynamicPackageProduct(buildable)
            for record in records {
                let nativeFiles = try unsafe files.unsafeInvoke(on: record)
                let objectFiles = try nativeFiles.withCopy { values -> [(URL, Set<URL>)] in
                    guard let values = values as? [Any] else {
                        throw NativeRuntimeError.unsupportedContract("Native object file descriptions are not an array")
                    }
                    return try values.map { try unsafe (path.unsafeInvoke(on: $0).value, sources.unsafeInvoke(on: $0).value) }
                }
                let target = try unsafe Target(moduleName: module.unsafeInvoke(on: record),
                    buildableName: name.unsafeInvoke(on: record), sdkRoot: sdk.unsafeInvoke(on: record),
                    sdkVariant: variant.unsafeInvoke(on: record), architecture: architecture.unsafeInvoke(on: record),
                    linkCommandLine: command.unsafeInvoke(on: record), linkerWorkingDirectory: directory.unsafeInvoke(on: record),
                    objectFiles: objectFiles.map(\.0), sourceFiles: Set(objectFiles.flatMap(\.1)),
                    debugDylibEnabled: dylib.unsafeInvoke(on: record), isRunnable: isRunnable,
                    enableAddressSanitizer: address.unsafeInvoke(on: record), enableThreadSanitizer: thread.unsafeInvoke(on: record),
                    enableUndefinedBehaviorSanitizer: undefined.unsafeInvoke(on: record),
                    isDynamicPackageProduct: isDynamicPackageProduct)
                result.append((buildable, record, target))
            }
        }
        return result
    }

    private func canonicalBuildable(_ buildable: NSObject) throws -> NSObject {
        guard let blueprint = try NativeObjCGetters.object(buildable, selector: "blueprint"),
              let canonical = try NativeObjCGetters.object(blueprint, selector: "primaryBuildable") as? NSObject else {
            throw NativeRuntimeError.unsupportedContract("A native dependency buildable has no primary buildable")
        }
        return canonical
    }

    private func declaredInputs(for buildables: NativeSwiftValue, workspace: AnyObject, priorBuild: AnyObject,
                                compilerCommands: [NativePreviewBuildInputs.CompilerCommand]) async throws ->
        (files: Set<URL>, missing: Set<URL>, products: Set<URL>, generated: Set<URL>, exclusions: Set<URL>,
         generatedFiles: Set<URL>, generatedMissingFiles: Set<URL>, discovery: Set<URL>)? {
        let (graph, roots) = try await dependencyGraph(for: buildables, workspace: workspace, priorBuild: priorBuild)
        defer { withExtendedLifetime(graph) {} }
        let dependencies = try await runtime.object(graph).resolve(
            .swift(.method("dependencies(of: __C.IDEBuildable) -> [__C.IDEBuildable]", as: ((AnyObject) -> NativeSwiftValue).self)))
        let parameters = try runtime.object(priorBuild).resolveAndWait(.objc(.method("_buildParametersForBuildable:", as: ((AnyObject) -> AnyObject).self)))
        guard let service = try NativeObjCGetters.object(workspace, selector: "buildSystemService"),
              let levelClass = NSClassFromString("IDEMacroEvaluation_Level_Blueprint") else {
            throw NativeRuntimeError.unsupportedContract("The native build has no macro evaluation context")
        }
        let serviceType = try await runtime.resolve(
            .swift(.type("IDEXCBuildSupportCore.IDEXCBuildSystemWorkspaceService")), in: .path(installation.framework("IDEXCBuildSupportCore", in: "PlugIns")))
        let allocateLevel = try runtime.object(levelClass as AnyObject).resolveAndWait(.objc(.method("alloc", as: (() -> AnyObject).self)))
        let evaluateRoot = try await serviceType.resolve(
            .swift(
                .method(
                    "evaluateMacroAsString(_: Swift.String, level: __C.IDEMacroEvaluation_Level, buildParameters: __C.IDEBuildParameters?, overrides: [Swift.String : Swift.String]?) async throws -> Swift.String",
                    as: (@concurrent (String, AnyObject, AnyObject?, NativePreviewMacroOverrides) async throws -> String).self)))
        var files: Set<URL> = []
        var outputDirectories: Set<URL> = []
        var commands = compilerCommands
        var products: Set<URL> = []
        var pending = roots
        var seen: Set<ObjectIdentifier> = []
        while let buildable = pending.popLast() {
            try Task.checkCancellation()
            guard seen.insert(ObjectIdentifier(buildable)).inserted else { continue }
            let values = try unsafe dependencies.unsafeInvoke(buildable)
            guard let children = try values.withCopy({ $0 as? [NSObject] }),
                  let blueprint = try NativeObjCGetters.object(buildable, selector: "blueprint") as? NSObject else { return nil }
            pending.append(contentsOf: children)
            let buildParameters = try unsafe parameters.unsafeInvoke(buildable)
            let allocatedLevel = try unsafe allocateLevel.unsafeInvoke()
            let initializeLevel = try runtime.object(allocatedLevel).resolveAndWait(.objc(.method("initWithBlueprint:", as: ((AnyObject) -> AnyObject?).self)))
            guard let level = try unsafe initializeLevel.unsafeInvoke(blueprint) else {
                throw NativeRuntimeError.invocation("IDEMacroEvaluation_Level_Blueprint.initWithBlueprint: returned nil")
            }
            for macro in ["DERIVED_DATA_DIR", "SYMROOT", "OBJROOT", "SHARED_PRECOMPS_DIR"] {
                let path = try unsafe await evaluateRoot.unsafeInvoke(on: service, macro, level,
                    buildParameters, NativePreviewMacroOverrides(value: nil))
                if path.isEmpty { continue }
                guard path.hasPrefix("/") else { return nil }
                outputDirectories.insert(URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL)
            }
            let evaluateFlags = try await serviceType.resolve(
                .swift(
                    .method(
                        "evaluateMacroAsStringList(_: Swift.String, level: __C.IDEMacroEvaluation_Level, buildParameters: __C.IDEBuildParameters?, overrides: [Swift.String : Swift.String]?) async throws -> [Swift.String]",
                        as: (@concurrent (String, AnyObject, AnyObject?, NativePreviewMacroOverrides) async throws -> [String]).self)))
            let flags = try unsafe await evaluateFlags.unsafeInvoke(on: service, "OTHER_SWIFT_FLAGS", level,
                buildParameters, NativePreviewMacroOverrides(value: nil))
            if flags.contains(where: { $0.hasPrefix("@") }) {
                guard !flags.contains("-frontend"), !flags.contains("-disallow-use-new-driver") else { return nil }
                let workingDirectoryOverride = try unsafe await evaluateRoot.unsafeInvoke(on: service, "COMPILER_WORKING_DIRECTORY", level,
                    buildParameters, NativePreviewMacroOverrides(value: nil))
                let directory: String
                if workingDirectoryOverride.isEmpty {
                    directory = try unsafe await evaluateRoot.unsafeInvoke(on: service, "PROJECT_DIR", level,
                        buildParameters, NativePreviewMacroOverrides(value: nil))
                } else { directory = workingDirectoryOverride }
                guard directory.hasPrefix("/") else { return nil }
                // Relative @files use the compiler process CWD before -working-directory is parsed.
                commands.append(.init(arguments: flags,
                    workingDirectory: URL(filePath: directory, directoryHint: .isDirectory).standardizedFileURL,
                    responseFileSyntax: .swiftDriver))
            }
            guard blueprint.responds(to: NSSelectorFromString("pbxTarget")) else { continue }
            guard let target = try NativeObjCGetters.object(blueprint, selector: "pbxTarget") else { return nil }
            let phases: [NSObject] = try NativeObjCGetters.array(target, selector: "buildPhases")
            let groups: [NSObject] = try NativeObjCGetters.array(target, selector: "fileSystemSynchronizedGroupsArray")
            var references: Set<ObjectIdentifier> = []
            func addReference(_ reference: NSObject) throws -> Bool {
                guard references.insert(ObjectIdentifier(reference)).inserted else { return true }
                if reference.responds(to: NSSelectorFromString("children")) {
                    let children: [NSObject] = try NativeObjCGetters.array(reference, selector: "children")
                    if !children.isEmpty {
                        for child in children {
                            guard try addReference(child) else { return false }
                        }
                        return true
                    }
                }
                let absolutePath = try runtime.object(reference).resolveAndWait(
                    .objc(.method("absolutePathForBuildParameters:", as: ((AnyObject) -> AnyObject?).self)))
                guard let path = try unsafe absolutePath.unsafeInvoke(buildParameters) as? String, path.hasPrefix("/") else { return false }
                let url = URL(filePath: path).standardizedFileURL
                if try NativeObjCGetters.boolean(reference, selector: "isProductReference")
                    || NativeObjCGetters.optionalString(reference, selector: "sourceTree") == "BUILT_PRODUCTS_DIR" {
                    products.insert(url)
                } else {
                    files.insert(url)
                }
                return true
            }
            for group in groups {
                guard try addReference(group) else { return nil }
            }
            for phase in phases {
                if try NativeObjCGetters.boolean(phase, selector: "runOnlyForDeploymentPostprocessing") {
                    let deployment = try await serviceType.resolve(
                        .swift(
                            .method(
                                "evaluateMacroAsBoolean(_: Swift.String, level: __C.IDEMacroEvaluation_Level, buildParameters: __C.IDEBuildParameters?, overrides: [Swift.String : Swift.String]?) async throws -> Swift.Bool",
                                as: (@concurrent (String, AnyObject, AnyObject?, NativePreviewMacroOverrides) async throws -> Bool).self)))
                    let postprocessing = try unsafe await deployment.unsafeInvoke(on: service, "DEPLOYMENT_POSTPROCESSING", level,
                        buildParameters, NativePreviewMacroOverrides(value: nil))
                    if !postprocessing { continue }
                }
                if phase.responds(to: NSSelectorFromString("inputPaths")) {
                    let inputs: [String] = try NativeObjCGetters.array(phase, selector: "inputPaths")
                    let inputLists: [String] = try NativeObjCGetters.array(phase, selector: "inputFileListPaths")
                    let outputs: [String] = try NativeObjCGetters.array(phase, selector: "outputPaths")
                    let outputLists: [String] = try NativeObjCGetters.array(phase, selector: "outputFileListPaths")
                    guard inputLists.isEmpty, outputLists.isEmpty,
                          try !NativeObjCGetters.boolean(phase, selector: "alwaysOutOfDate") else { return nil }
                    let evaluate = try await serviceType.resolve(
                        .swift(
                            .method(
                                "evaluateMacroExpressionAsString(_: Swift.String, level: __C.IDEMacroEvaluation_Level, buildParameters: __C.IDEBuildParameters?, overrides: [Swift.String : Swift.String]?) async throws -> Swift.String",
                                as: (@concurrent (String, AnyObject, AnyObject?, NativePreviewMacroOverrides) async throws -> String).self)))
                    // File-list expansion belongs to the build service, as does each script's output-node analysis.
                    var hasOutput = false
                    for expression in outputs {
                        let path = try unsafe await evaluate.unsafeInvoke(on: service, expression, level, buildParameters, NativePreviewMacroOverrides(value: nil))
                        if path.isEmpty { continue }
                        guard path.hasPrefix("/") else { return nil }
                        hasOutput = true
                    }
                    guard hasOutput else { return nil }
                    for expression in inputs {
                        let path = try unsafe await evaluate.unsafeInvoke(on: service, expression, level, buildParameters, NativePreviewMacroOverrides(value: nil))
                        guard path.hasPrefix("/") else { return nil }
                        files.insert(URL(filePath: path).standardizedFileURL)
                    }
                }
                let buildFiles: [NSObject] = try NativeObjCGetters.array(phase, selector: "buildFiles")
                for file in buildFiles {
                    if let reference = try NativeObjCGetters.object(file, selector: "fileReference") as? NSObject {
                        guard try addReference(reference) else { return nil }
                    } else if try NativeObjCGetters.object(file, selector: "productReference") == nil {
                        return nil
                    }
                }
            }
        }
        guard let nativeFiles = try await completedBuildInputs(workspace: workspace, priorBuild: priorBuild,
            compilerCommands: commands) else { return nil }
        let inputs = NativePreviewBuildInputs.Inputs(files: files.union(nativeFiles.files), missing: nativeFiles.missing,
            generatedPaths: nativeFiles.generatedPaths, discoveryFiles: nativeFiles.discoveryFiles)
        let exclusions = outputDirectories.union(inputs.generatedPaths)
        return (inputs.files.subtracting(inputs.generatedFiles), inputs.missing.subtracting(inputs.generatedMissingFiles),
            products, inputs.generatedPaths, exclusions, inputs.generatedFiles, inputs.generatedMissingFiles, inputs.discoveryFiles)
    }

    private func completedBuildInputs(workspace: AnyObject, priorBuild: AnyObject,
                                      compilerCommands: [NativePreviewBuildInputs.CompilerCommand]) async throws -> NativePreviewBuildInputs.Inputs? {
        guard let field = Mirror(reflecting: priorBuild).children.first(where: { $0.label == "buildDescriptionID" }),
              let identifier = Mirror(reflecting: field.value).children.first?.value as? String,
              !identifier.isEmpty, !identifier.contains("/") else { return nil }
        let getCache = try await runtime.object(workspace).resolve(
            .swift(.getter("(extension in IDEXCBuildSupportCore):__C.IDEWorkspace.xcbuildDataCachePath.getter : __C.DVTFilePath?", as: (() -> AnyObject?).self))
        )
        guard let cachePath = try unsafe getCache.unsafeInvoke(),
              let cacheURL = try NativeObjCGetters.object(cachePath, selector: "fileURL") as? URL,
              cacheURL.isFileURL, cacheURL.path.hasPrefix("/") else { return nil }
        let manifest = cacheURL.appendingPathComponent(identifier + ".xcbuilddata", isDirectory: true)
            .appendingPathComponent("manifest.json")
        // System library install names can refer to immutable dyld-cache images without a standalone file.
        return NativePreviewBuildInputs.files(manifest: manifest, compilerCommands: compilerCommands,
            immutableRoots: [installation.contentsDirectory, URL(filePath: "/usr/lib"),
                URL(filePath: "/System/Library/Frameworks"), URL(filePath: "/System/Library/PrivateFrameworks"),
                URL(filePath: "/System/Library/SubFrameworks")])
    }

    private func dependencyGraph(for buildables: NativeSwiftValue, workspace: AnyObject,
                                 priorBuild: AnyObject) async throws -> (AnyObject, [NSObject]) {
        guard let service = try NativeObjCGetters.object(workspace, selector: "buildSystemService"),
              let parameters = try NativeObjCGetters.object(priorBuild, selector: "buildParameters") else {
            throw NativeRuntimeError.unsupportedContract("The native build has no dependency query context")
        }
        guard let selectedBuildables = try buildables.withCopy({ $0 as? [NSObject] }) else {
            throw NativeRuntimeError.unsupportedContract("Native buildables are not an array of objects")
        }
        var selectedIdentities: Set<ObjectIdentifier> = []
        let canonicalBuildables = try selectedBuildables.map(canonicalBuildable).filter {
            selectedIdentities.insert(ObjectIdentifier($0)).inserted
        }
        let implicit = try runtime.object(priorBuild).resolveAndWait(.objc(.method("buildImplicitDependencies", as: (() -> Bool).self)))
        let serviceType = try await runtime.resolve(
            .swift(.type("IDEXCBuildSupportCore.IDEXCBuildSystemWorkspaceService")), in: .path(installation.framework("IDEXCBuildSupportCore", in: "PlugIns")))
        let query = try await serviceType.resolve(
            .swift(
                .method(
                    "computeDependencyGraph(for: [__C.IDEBuildable], buildParameters: __C.IDEBuildParameters, includeImplicitDependencies: Swift.Bool) async throws -> IDEFoundation.IDEBuildableDependencyGraph",
                    as: (@concurrent (NativeSwiftValue, AnyObject, Bool) async throws -> AnyObject).self)))
        // Scheme products retain the incoming edges from a package's dynamic product to its source module.
        let selected = try await buildableArray(canonicalBuildables, matching: buildables)
        let graph = try unsafe await query.unsafeInvoke(on: service, selected, parameters, implicit.unsafeInvoke())
        return (graph, canonicalBuildables)
    }

    private func dependencies(for source: TargetRecord, records: [TargetRecord], buildables: NativeSwiftValue, image: URL, priorBuild: AnyObject,
                              workspace: AnyObject, scheme: AnyObject, destination: AnyObject) async throws ->
        (targets: [Target], roots: [Target], linkDependencies: [Target], resources: [URL]) {
        let (graph, canonicalBuildables) = try await dependencyGraph(for: buildables, workspace: workspace, priorBuild: priorBuild)
        let canonicalSource = try canonicalBuildable(source.buildable)
        let directDependencies = try await runtime.object(graph).resolve(
            .swift(.method("dependencies(of: __C.IDEBuildable) -> [__C.IDEBuildable]", as: ((AnyObject) -> NativeSwiftValue).self)))
        let directDependents = try await runtime.object(graph).resolve(
            .swift(.method("dependents(of: __C.IDEBuildable) -> [__C.IDEBuildable]", as: ((AnyObject) -> NativeSwiftValue).self)))
        try Task.checkCancellation()
        let resourceClass: AnyClass? = NSClassFromString("IDESwiftPackageCore.IDESwiftPackageResourceBundleProductBlueprint")
        // The build graph also contains build tools and aggregate targets.
        // Only native library products contribute code to the renderer image.
        let linkableProducts: Set<String> = ["com.apple.product-type.objfile", "com.apple.product-type.library.static",
            "com.apple.product-type.library.dynamic", "com.apple.product-type.framework", "com.apple.product-type.framework.static"]
        var seen: Set<ObjectIdentifier> = []
        var pending = Array(canonicalBuildables.reversed())
        var edges: [ObjectIdentifier: [NSObject]] = [:]
        var codeIdentities: Set<ObjectIdentifier> = []
        var jitBuildables: Set<ObjectIdentifier> = []
        var resourceBlueprints: [ObjectIdentifier: NSObject] = [:]
        while let buildable = pending.popLast() {
            try Task.checkCancellation()
            let identifier = ObjectIdentifier(buildable)
            guard seen.insert(identifier).inserted else { continue }
            let nativeDependencies = try unsafe directDependencies.unsafeInvoke(buildable)
            guard let dependencies = try nativeDependencies.withCopy({ $0 as? [NSObject] }) else {
                throw NativeRuntimeError.unsupportedContract("The native dependency graph edge is not an array of buildables")
            }
            edges[identifier] = dependencies
            pending.append(contentsOf: dependencies.reversed())
            guard let blueprint = try NativeObjCGetters.object(buildable, selector: "blueprint") as? NSObject else {
                throw NativeRuntimeError.unsupportedContract("A native dependency buildable has no blueprint")
            }
            if let resourceClass, blueprint.isKind(of: resourceClass) {
                resourceBlueprints[identifier] = blueprint
            } else {
                let productType = try runtime.object(buildable).resolveAndWait(.objc(.method("productTypeIdentifier", as: (() -> String?).self)))
                if let product = try unsafe productType.unsafeInvoke() {
                    if linkableProducts.contains(product) { codeIdentities.insert(identifier) }
                    if product == "com.apple.product-type.framework" || product == "com.apple.product-type.library.dynamic" {
                        jitBuildables.insert(identifier)
                    }
                }
            }
        }
        let codeEdges = edges.mapValues { $0.filter { codeIdentities.contains(ObjectIdentifier($0)) } }
        var dependents: [ObjectIdentifier: [NSObject]] = [:]
        seen = []
        pending = [canonicalSource]
        while let buildable = pending.popLast() {
            try Task.checkCancellation()
            let identifier = ObjectIdentifier(buildable)
            guard seen.insert(identifier).inserted else { continue }
            let nativeParents = try unsafe directDependents.unsafeInvoke(buildable)
            guard let parents = try nativeParents.withCopy({ $0 as? [NSObject] }) else {
                throw NativeRuntimeError.unsupportedContract("The native dependency graph parent edge is not an array of buildables")
            }
            dependents[identifier] = parents
            pending.append(contentsOf: parents.reversed())
        }
        var candidates: [ObjectIdentifier: [TargetRecord]] = [:]
        func addRecords(_ records: [TargetRecord]) throws {
            for record in records where record.target.sdkRoot == source.target.sdkRoot
                && record.target.sdkVariant == source.target.sdkVariant && record.target.architecture == source.target.architecture {
                let identifier = ObjectIdentifier(try canonicalBuildable(record.buildable))
                candidates[identifier, default: []].append(record)
            }
        }
        try addRecords(records)
        // Preserve the selected source's compile command and environment already collected by targets().
        candidates[ObjectIdentifier(canonicalSource)] = [source]
        var queriedDescriptions: [NativeSwiftValue] = []
        defer { withExtendedLifetime((graph, queriedDescriptions)) {} }
        // Native product types define JIT boundaries even when a framework contains a static archive.
        let ownerRoots = Self.previewRootBuildables(for: canonicalSource, dependencies: [:], dependents: dependents,
            jitBuildables: jitBuildables)
        func reachable(from roots: [NSObject], through dependencies: [ObjectIdentifier: [NSObject]],
                       excluding excludedRoots: Set<ObjectIdentifier> = []) -> [NSObject] {
            var pending = Array(roots.reversed())
            var seen: Set<ObjectIdentifier> = []
            var result: [NSObject] = []
            while let buildable = pending.popLast() {
                let identifier = ObjectIdentifier(buildable)
                guard !excludedRoots.contains(identifier), seen.insert(identifier).inserted else { continue }
                result.append(buildable)
                pending.append(contentsOf: dependencies[identifier, default: []].reversed())
            }
            return result
        }
        let missingCode = reachable(from: ownerRoots, through: codeEdges).filter { candidates[ObjectIdentifier($0)] == nil }
        if !missingCode.isEmpty {
            let nativeCode = try await buildableArray(missingCode, matching: buildables)
            let descriptions = try await targetDescriptions(for: nativeCode, workspace: workspace, priorBuild: priorBuild, image: image)
            queriedDescriptions.append(descriptions)
            try addRecords(await targetRecords(descriptions, image: image, runnable: nil))
        }
        let selectedRootBuildables = Self.previewRootBuildables(for: canonicalSource, dependencies: codeEdges, dependents: dependents,
            jitBuildables: jitBuildables)
        let unavailableRoots = Set(selectedRootBuildables.filter { candidates[ObjectIdentifier($0)] == nil }.map(ObjectIdentifier.init))
        var rootBuildables = selectedRootBuildables.filter { !unavailableRoots.contains(ObjectIdentifier($0)) }
        if ownerRoots.count > 1 {
            let namedOwners = try rootBuildables.map { buildable in
                let name = try runtime.object(buildable).resolveAndWait(.objc(.method("displayName", as: (() -> String).self)))
                return try unsafe (buildable: buildable, displayName: name.unsafeInvoke())
            }
            // Native library hosts have the same priority, then compare their cached buildable display names.
            rootBuildables = namedOwners.sorted { $0.displayName < $1.displayName }.map(\.buildable)
        }
        let reachableBuildables = reachable(from: rootBuildables, through: edges, excluding: unavailableRoots)
        let code = reachable(from: rootBuildables, through: codeEdges, excluding: unavailableRoots)
        var targets: [Target] = []
        var targetsByBuildable: [ObjectIdentifier: Target] = [:]
        for buildable in code {
            // A package product can contribute graph edges without producing its own linked artifact.
            guard let matches = candidates[ObjectIdentifier(buildable)] else { continue }
            guard matches.count == 1, let record = matches.first else {
                throw NativeRuntimeError.unsupportedContract("The native build returned \(matches.count) matching products for dependency \(buildable) of \(source.target.buildableName)")
            }
            guard let output = record.target.outputURL else {
                throw NativeRuntimeError.unsupportedContract("Native dependency \(record.target.buildableName) has no linked product")
            }
            var target = record.target
            if target.compileCommandLine.isEmpty, try NativePreviewBinary.isStaticArchive(at: output),
               let sourceFile = target.sourceFiles.filter({ $0.pathExtension == "swift" }).sorted(by: { $0.path < $1.path }).first {
                target.compileCommandLine = try await compileCommandLine(for: record, priorBuild: priorBuild,
                    workspace: workspace, source: sourceFile, image: image)
            }
            if ObjectIdentifier(buildable) != ObjectIdentifier(canonicalSource) {
                target.rendererEnvironment = try sanitizerEnvironment(for: buildable, priorBuild: priorBuild, scheme: scheme, destination: destination)
            }
            targets.append(target)
            targetsByBuildable[ObjectIdentifier(buildable)] = target
        }
        var resources: [URL] = []
        var resourcesByBuildable: [ObjectIdentifier: URL] = [:]
        for buildable in reachableBuildables {
            let identifier = ObjectIdentifier(buildable)
            if let blueprint = resourceBlueprints[identifier] {
                let resource = try await resourceURL(for: blueprint, buildable: buildable, priorBuild: priorBuild)
                resourcesByBuildable[identifier] = resource
                if !resources.contains(resource) { resources.append(resource) }
            }
        }
        let sourceOwnerIdentities = Set(ownerRoots.map(ObjectIdentifier.init))
        let roots = rootBuildables.compactMap { buildable -> Target? in
                guard var root = targetsByBuildable[ObjectIdentifier(buildable)] else { return nil }
                root.containsPreviewSource = sourceOwnerIdentities.contains(ObjectIdentifier(buildable))
                root.dependencies = Self.linkBuildables(for: buildable, dependencies: codeEdges, jitBuildables: jitBuildables)
                    .compactMap { targetsByBuildable[ObjectIdentifier($0)] }
                var seenResources: Set<URL> = []
                root.resourceURLs = reachable(from: [buildable], through: edges, excluding: unavailableRoots)
                    .compactMap { resourcesByBuildable[ObjectIdentifier($0)] }
                    .filter { seenResources.insert($0).inserted }
                return root
            }
        guard !roots.isEmpty else {
            throw NativeRuntimeError.unsupportedContract("The native preview graph has no available linked roots for \(source.target.buildableName)")
        }
        let linkDependencies = Self.linkBuildables(for: canonicalSource, dependencies: codeEdges, jitBuildables: jitBuildables)
            .compactMap { targetsByBuildable[ObjectIdentifier($0)] }
        return (targets, roots, linkDependencies, resources)
    }

    static func previewRootBuildables(for source: NSObject, dependencies: [ObjectIdentifier: [NSObject]],
                                     dependents: [ObjectIdentifier: [NSObject]], jitBuildables: Set<ObjectIdentifier>) -> [NSObject] {
        var pending = [source]
        var seen: Set<ObjectIdentifier> = []
        var ancestors: [NSObject] = []
        while let buildable = pending.popLast() {
            let identifier = ObjectIdentifier(buildable)
            guard seen.insert(identifier).inserted else { continue }
            if jitBuildables.contains(identifier) { ancestors.append(buildable) }
            else { pending.append(contentsOf: dependents[identifier, default: []].reversed()) }
        }
        if !ancestors.isEmpty { return ancestors }
        return [source] + linkBuildables(for: source, dependencies: dependencies, jitBuildables: jitBuildables)
            .filter { jitBuildables.contains(ObjectIdentifier($0)) }
    }

    static func linkBuildables(for source: NSObject, dependencies: [ObjectIdentifier: [NSObject]],
                              jitBuildables: Set<ObjectIdentifier>) -> [NSObject] {
        var pending = Array(dependencies[ObjectIdentifier(source), default: []].reversed())
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(source)]
        var result: [NSObject] = []
        while let buildable = pending.popLast() {
            let identifier = ObjectIdentifier(buildable)
            guard seen.insert(identifier).inserted else { continue }
            result.append(buildable)
            // A JIT root owns its static children; a direct source edge can still reach those children independently.
            if !jitBuildables.contains(identifier) {
                pending.append(contentsOf: dependencies[identifier, default: []].reversed())
            }
        }
        return result
    }

    private func isDynamicPackageProduct(_ buildable: NSObject) throws -> Bool {
        let productType = try runtime.object(buildable).resolveAndWait(.objc(.method("productTypeIdentifier", as: (() -> String?).self)))
        guard let identifier = try unsafe productType.unsafeInvoke(),
              identifier == "com.apple.product-type.framework" || identifier == "com.apple.product-type.library.dynamic" else { return false }
        guard let blueprint = try NativeObjCGetters.object(buildable, selector: "blueprint") as? NSObject,
              blueprint.responds(to: NSSelectorFromString("isValid")) else { return false }
        let valid = try runtime.object(blueprint).resolveAndWait(.objc(.method("isValid", as: (() -> Bool).self)))
        guard try unsafe valid.unsafeInvoke(),
              let provider = try NativeObjCGetters.object(blueprint, selector: "blueprintProvider") as? NSObject else { return false }
        guard let package = NSProtocolFromString("IDESourcePackage") else {
            throw NativeRuntimeError.unsupportedContract("The native source package protocol is unavailable")
        }
        return type(of: provider).conforms(to: package)
    }

    private func buildableArray(_ objects: [NSObject], matching nativeArray: NativeSwiftValue) async throws -> NativeSwiftValue {
        guard let collection = try nativeArray.withCopy({ $0 as? any Collection }) else {
            throw NativeRuntimeError.unsupportedContract("Native buildables are not a collection")
        }
        defer { withExtendedLifetime(nativeArray) {} }
        // Preserve the imported IDEBuildable element type at the Swift ABI boundary.
        func makeArray<Values: Collection>(_: Values) async throws -> NativeSwiftValue {
            let values: [Values.Element] = try objects.map {
                guard let value = $0 as? Values.Element else {
                    throw NativeRuntimeError.unsupportedContract("The native buildable array does not accept a dependency buildable")
                }
                return value
            }
            return try await nativePreviewOwnedValue(values)
        }
        return try await _openExistential(collection, do: makeArray)
    }

    private func resourceURL(for blueprint: NSObject, buildable: NSObject, priorBuild: AnyObject) async throws -> URL {
        let parameters = try runtime.object(priorBuild).resolveAndWait(.objc(.method("_buildParametersForBuildable:", as: ((AnyObject) -> AnyObject).self)))
        let evaluate = try await runtime.object(blueprint).resolve(
            .swift(
                .method(
                    "evaluateMacroExpressionAsString(_: Swift.String, buildParameters: __C.IDEBuildParameters?, overrides: [Swift.String : Swift.String]?) async throws -> Swift.String",
                    as: (@concurrent (String, AnyObject?, NativePreviewMacroOverrides) async throws -> String).self)))
        let path = try unsafe await evaluate.unsafeInvoke("$(TARGET_BUILD_DIR)/$(FULL_PRODUCT_NAME)", parameters.unsafeInvoke(buildable),
            NativePreviewMacroOverrides(value: nil))
        try Task.checkCancellation()
        guard path.hasPrefix("/") else {
            throw NativeRuntimeError.unsupportedContract("The native resource product path is not absolute: \(path)")
        }
        return URL(filePath: path).resolvingSymlinksInPath()
    }

    private func compileCommandLine(for record: TargetRecord, priorBuild: AnyObject, workspace: AnyObject,
                                    source: URL, image: URL) async throws -> [String] {
        let type = try await runtime.resolve(.swift(.type("PreviewsIDEAPI.IDEBuiltTargetDescription")), in: .path(image))
        let buildVariant = try await type.resolve(.swift(.getter("buildVariant", as: (() -> String).self, receiverABI: .opaque(named: type.name))))
        return try await compileCommandLine(for: record.target, buildable: record.buildable,
            buildVariant: unsafe buildVariant.unsafeInvoke(on: record.native), priorBuild: priorBuild, workspace: workspace, source: source)
    }

    private func sanitizerEnvironment(for buildable: AnyObject, priorBuild: AnyObject, scheme: AnyObject,
                                      destination: AnyObject) throws -> [String: String] {
        guard let action = try NativeObjCGetters.object(scheme, selector: "launchSchemeAction") else { return [:] }
        let address = try runtime.object(action).resolveAndWait(.objc(.method("enableAddressSanitizer", as: (() -> Bool).self)))
        let thread = try runtime.object(action).resolveAndWait(.objc(.method("enableThreadSanitizer", as: (() -> Bool).self)))
        var sanitizers: [String] = []
        if try unsafe thread.unsafeInvoke() {
            let allowed = try runtime.object(action).resolveAndWait(.objc(.method("threadSanitizerAllowedForRunDestination:", as: ((AnyObject) -> Bool).self)))
            if try unsafe allowed.unsafeInvoke(destination) { sanitizers.append("Thread") }
        }
        if try unsafe address.unsafeInvoke() { sanitizers.append("Address") }
        guard !sanitizers.isEmpty else { return [:] }
        guard let actionClass = NSClassFromString("IDESchemeAction") else {
            throw NativeRuntimeError.unavailable("Xcode scheme action class is unavailable")
        }
        let parameters = try runtime.object(priorBuild).resolveAndWait(.objc(.method("_buildParametersForBuildable:", as: ((AnyObject) -> AnyObject).self)))
        let buildParameters = try unsafe parameters.unsafeInvoke(buildable)
        let environment = NSMutableDictionary()
        for sanitizer in sanitizers {
            let add = try unsafe runtime.object(actionClass as AnyObject).resolveAndWait(
                .objc(
                    .method(
                        "add\(sanitizer)SanitizerEnvironmentVariables:buildParameters:buildable:debugAppExtensions:debugging:testingSpecifier:error:",
                        as: ((NSMutableDictionary, AnyObject, AnyObject, Bool, Bool, AnyObject?, UnsafeMutableRawPointer?) -> Bool).self)))
            var errorAddress: UnsafeRawPointer?
            let success = try withUnsafeMutablePointer(to: &errorAddress) {
                try unsafe add.unsafeInvoke(environment, buildParameters, buildable, false, false, nil, UnsafeMutableRawPointer($0))
            }
            guard success else {
                if let errorAddress = unsafe errorAddress { throw unsafe Unmanaged<NSError>.fromOpaque(errorAddress).takeUnretainedValue() }
                throw NativeRuntimeError.invocation("Xcode could not create the \(sanitizer) Sanitizer launch environment")
            }
        }
        guard let values = environment as NSDictionary as? [String: String] else {
            throw NativeRuntimeError.unsupportedContract("Xcode's sanitizer launch environment is not a string dictionary")
        }
        return values
    }

    private func compileCommandLine(for target: Target, buildable: AnyObject, buildVariant: String,
                                    priorBuild: AnyObject, workspace: AnyObject, source: URL) async throws -> [String] {
        guard let service = try NativeObjCGetters.object(workspace, selector: "buildSystemService"),
              let blueprint = try NativeObjCGetters.object(buildable, selector: "blueprint"),
              let parametersClass = NSClassFromString("IDEBuildParameters"),
              let pathClass = NSClassFromString("DVTFilePath") else {
            throw NativeRuntimeError.unsupportedContract("The native build has no preview compilation context")
        }
        let path = try runtime.object(pathClass as AnyObject).resolveAndWait(.objc(.method("filePathForPathString:", as: ((String) -> AnyObject).self)))
        let sourcePath = try unsafe path.unsafeInvoke(source.path)
        let dictionary = try await runtime.resolve(.swift(.type("Swift.Dictionary", genericArguments: [.type(String.self), .type(parametersClass)])))
        // The concrete Dictionary parameter uses its frozen single-word ABI.
        let valueABIs: [NativeSwiftType: NativeType] = [dictionary: .pointer]
        let initialize = try await dictionary.resolve(
            .swift(.initializer("init(minimumCapacity: Swift.Int) -> [A : B]", as: ((Int) -> NativeSwiftValue).self, valueABIs: valueABIs)))
        let overrides = try unsafe initialize.unsafeInvoke(0)
        let serviceType = try await runtime.resolve(
            .swift(.type("IDEXCBuildSupportCore.IDEXCBuildSystemWorkspaceService")), in: .path(installation.framework("IDEXCBuildSupportCore", in: "PlugIns")))
        let query = try await serviceType.resolve(
            .swift(
                .method(
                    "generatePreviewInfo(forRecentBuild: __C.IDEBuildOperation, blueprint: __C.IDEBlueprint, sourceFilePath: __C.DVTFilePath, thunkVariantSuffix: Swift.String, perTargetOverridingBuildParameters: [Swift.String : __C.IDEBuildParameters]) async throws -> [IDEFoundation.IDEPreviewInfoOutput]",
                    as: (@concurrent (AnyObject, AnyObject, AnyObject, String, NativeSwiftValue) async throws -> NativeSwiftValue).self, valueABIs: valueABIs)))
        let outputType = try await runtime.resolve(.swift(.type("IDEFoundation.IDEPreviewInfoOutput")))
        let sdk = try await outputType.resolve(.swift(.getter("sdkRoot.getter : Swift.String", as: (() -> String).self)))
        let variant = try await outputType.resolve(.swift(.getter("sdkVariant.getter : Swift.String?", as: (() -> String?).self)))
        let architecture = try await outputType.resolve(.swift(.getter("architecture.getter : Swift.String", as: (() -> String).self)))
        let build = try await outputType.resolve(.swift(.getter("buildVariant.getter : Swift.String", as: (() -> String).self)))
        let command = try await outputType.resolve(.swift(.getter("compileCommandLine.getter : [Swift.String]", as: (() -> [String]).self)))
        let suffix = "Preview_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let info = try unsafe await query.unsafeInvoke(on: service, priorBuild, blueprint, sourcePath, suffix, overrides)
        try Task.checkCancellation()
        return try info.withCopy { value in
            guard let outputs = value as? [AnyObject] else {
                throw NativeRuntimeError.unsupportedContract("Native preview compilation information is not an array")
            }
            for output in outputs {
                if try unsafe sdk.unsafeInvoke(on: output) == target.sdkRoot && variant.unsafeInvoke(on: output) == target.sdkVariant
                    && architecture.unsafeInvoke(on: output) == target.architecture && build.unsafeInvoke(on: output) == buildVariant {
                    return try unsafe command.unsafeInvoke(on: output)
                }
            }
            throw NativeRuntimeError.unsupportedContract("Native preview compilation information did not include the static source target")
        }
    }

    @MainActor
    private final class Cancellation {
        private let action: () throws -> Void
        private var failure: (any Error)?

        init(cancel: @escaping () throws -> Void) { action = cancel }

        func cancel() {
            do { try action() }
            catch { failure = error }
        }

        func checkFailure() throws {
            if let failure { throw failure }
        }
    }
}

@inline(never)
package func nativePreviewArray<Element>(_ values: [Any]) throws -> [Element] {
    try values.map { value in
        guard let value = value as? Element else {
            throw NativeRuntimeError.unsupportedContract("Native preview array has an incompatible element")
        }
        return value
    }
}

struct NativePreviewBuildURL: ABIBridgeSwiftValue {
    let value: URL
    static let swiftABIType: NativeType = try! .opaque(named: "Foundation.URL")
}

private struct NativePreviewBuildSources: ABIBridgeSwiftValue {
    let value: Set<URL>
    static let swiftABIType: NativeType = .pointer
}

private struct NativePreviewMacroOverrides: ABIBridgeSwiftValue {
    let value: [String: String]?
    static let swiftABIType: NativeType = .pointer
}

@MainActor
func nativePreviewOwnedValue<Value>(_ value: Value) async throws -> NativeSwiftValue {
    let identity = try await ABIRuntime.shared.resolve(
        .swift(.function("XcodeMCPNativeRuntime.nativePreviewValue<A>(A) -> A", as: ((Value) -> NativeSwiftValue).self, genericArguments: [.type(Value.self)])))
    return try unsafe identity.unsafeInvoke(value)
}

@inline(never)
package func nativePreviewSome<Value>(_ value: Value) -> Value? { value }

@inline(never)
@MainActor
package func nativePreviewExecutorProvider<Executor>(_ object: AnyObject) throws -> (@MainActor () -> Executor?) {
    guard let executor = object as? Executor else {
        throw NativeRuntimeError.unsupportedContract("The native workspace does not conform to the scheme task executor protocol")
    }
    return { executor }
}
