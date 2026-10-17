import ABIBridge
import ABIBridgeCore
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
        var workspaceBuilder: AnyObject? = nil
        var declaredInputFiles: Set<URL>? = nil
        var missingInputFiles: Set<URL> = []
        var inputProducts: Set<URL> = []

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
    private var destinationPreparation: DestinationPreparation?
    private var clients: [UUID: Cancellation] = [:]
    private var performMethod: NativeSwiftMethod<@concurrent (AnyObject, AnyObject) async throws -> AnyObject>?
    private var sourceSelections: [ObjectIdentifier: [SourceSelectionWaiter]] = [:]

    private struct SourceSelectionWaiter {
        let identifier: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    init(installation: NativeXcodeInstallation) {
        self.installation = installation
    }

    func waitForSourcePackages(in workspace: AnyObject) async throws {
        try Task.checkCancellation()
        let wait = try await runtime.object(workspace).resolveMethod(
            named: "(extension in IDEFoundation):__C.IDEWorkspace.waitForFinishedResolvingSourcePackages() async throws -> ()",
            as: (@concurrent () async throws -> Void).self)
        do { try unsafe await wait.unsafeInvoke() }
        catch let error as NativeSwiftError {
            if error.withUnderlyingError({ $0 is CancellationError }) { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
    }

    func synchronizeProjectContainers(in workspace: AnyObject) async throws {
        try Task.checkCancellation()
        guard let containers = try object(workspace, selector: "referencedContainers") as? NSSet else {
            throw NativeRuntimeError.unsupportedContract("The native workspace has no referenced containers")
        }
        var updates: [(valid: NativeBoundObjCMethod<Bool>, edited: NativeBoundObjCMethod<Bool>,
                       invalidate: NativeBoundObjCMethod<Void, Bool>, queue: OperationQueue)] = []
        var inputFiles: [(invalidate: NativeBoundObjCMethod<Void>, modificationDate: NativeBoundObjCMethod<AnyObject?>)] = []
        func addInputFile(_ filePath: AnyObject) throws {
            let path = runtime.object(filePath)
            inputFiles.append((
                try path.resolveMethodAndWait(selector: "invalidateFilePath", as: (() -> Void).self),
                try path.resolveMethodAndWait(selector: "modificationDate", as: (() -> AnyObject?).self)))
        }
        for case let container as NSObject in containers.allObjects
            where container !== workspace && container.responds(to: NSSelectorFromString("pbxProject")) {
            let native = runtime.object(container)
            let valid = try native.resolveMethodAndWait(selector: "isValid", as: (() -> Bool).self)
            guard try unsafe valid.unsafeInvoke() else { continue }
            let edited = try native.resolveMethodAndWait(selector: "containerEditedByUserInUI", as: (() -> Bool).self)
            guard try unsafe !edited.unsafeInvoke() else { continue }
            let invalidate = try native.resolveMethodAndWait(selector: "_invalidateContainerToDiscardInMemoryRepresentation:",
                as: ((Bool) -> Void).self)
            guard let graph = try object(container, selector: "objectGraph"),
                  let queue = try object(graph, selector: "changeQueue") as? OperationQueue else {
                throw NativeRuntimeError.unsupportedContract("A native project container has no model change queue")
            }
            let dataFiles = try native.resolveMethodAndWait(selector: "_containerDataFilePaths", as: (() -> NSArray).self)
            for filePath in try unsafe dataFiles.unsafeInvoke() { try addInputFile(filePath as AnyObject) }
            updates.append((valid, edited, invalidate, queue))
        }
        guard !updates.isEmpty else { return }
        if let configurationPaths = try configurationFilePaths(in: containers) {
            let paths = configurationPaths.bases.merging(configurationPaths.watched) { existing, _ in existing }
            for filePath in paths.values { try addInputFile(filePath) }
        }
        guard let environment = try object(workspace, selector: "executionEnvironment") else {
            throw NativeRuntimeError.unsupportedContract("The native workspace has no execution environment")
        }
        let disable = try runtime.object(environment).resolveMethodAndWait(
            selector: "disableSubmissionOfBuildOperationsWithReason:", as: ((String) -> Void).self)
        let enable = try runtime.object(environment).resolveMethodAndWait(
            selector: "enableSubmissionOfBuildOperationsWithReason:", as: ((String) -> Void).self)
        typealias Completion = @convention(block) () -> Void
        let cancel = try runtime.object(workspace).resolveMethodAndWait(
            selector: "_cancelOngoingBuildWithCompletionBlockIfNeeded:",
            as: ((Completion?) -> Bool).self)
        let reason = "Synchronizing preview project inputs"
        try Task.checkCancellation()
        try unsafe disable.unsafeInvoke(reason)
        let outcome: Swift.Result<Void, any Error>
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let completed: Completion = { continuation.resume() }
                do {
                    // A false result means no build was queued and the callback will not run.
                    if try unsafe !cancel.unsafeInvoke(completed) { continuation.resume() }
                } catch { continuation.resume(throwing: error) }
            }
            try Task.checkCancellation()
            // Replacement containers use these dates; configuration parsers also reuse the vnode's derived cache.
            for file in inputFiles {
                try unsafe file.invalidate.unsafeInvoke()
                _ = try unsafe file.modificationDate.unsafeInvoke()
            }
            var queues: [OperationQueue] = []
            var seen: Set<ObjectIdentifier> = []
            for update in updates {
                if seen.insert(ObjectIdentifier(update.queue)).inserted { queues.append(update.queue) }
                // Invalidating one container can also replace another referenced container.
                guard try unsafe update.valid.unsafeInvoke(), try unsafe !update.edited.unsafeInvoke() else { continue }
                try unsafe update.invalidate.unsafeInvoke(true)
            }
            for queue in queues {
                await withCheckedContinuation { continuation in
                    queue.addBarrierBlock { continuation.resume() }
                }
            }
            try Task.checkCancellation()
            outcome = .success(())
        } catch { outcome = .failure(error) }
        do { try unsafe enable.unsafeInvoke(reason) }
        catch {
            let operation: String
            switch outcome {
            case .success: operation = "Native preview project synchronization completed"
            case .failure(let failure): operation = String(describing: failure)
            }
            throw NativeRuntimeError.invocation("\(operation); failed to resume native build submissions: \(error)")
        }
        try outcome.get()
    }

    func prepare(workspace: AnyObject) async throws -> NativeSwiftMethod<@concurrent (AnyObject, AnyObject) async throws -> AnyObject> {
        if let performMethod { return performMethod }
        let bound = try await runtime.object(workspace).resolveMethod(
            named: "(extension in PreviewsIDEAPI):__C.IDEWorkspace.performTask(on: __C.IDEScheme, for: __C.IDESchemeOperationParameters) async throws -> __C.DVTOperation",
            as: (@concurrent (AnyObject, AnyObject) async throws -> AnyObject).self)
        performMethod = bound.method
        return bound.method
    }

    func runnableBuildable(in scheme: AnyObject) throws -> AnyObject? {
        guard let action = try object(scheme, selector: "launchSchemeAction"),
              let runnable = try object(action, selector: "runnable") else { return nil }
        return try object(runnable, selector: "buildableProduct")
    }

    static func isRunnable(_ buildable: NSObject, runnable: AnyObject?) -> Bool {
        guard let runnable else { return false }
        return buildable.isEqual(runnable)
    }

    func planningContext(workspace: AnyObject, destination: DestinationSelection? = nil) throws -> PlanningContext {
        guard let manager = try object(workspace, selector: "runContextManager"),
              let scheme = try object(manager, selector: "activeRunContext"),
              let environment = try object(workspace, selector: "executionEnvironment") else {
            throw NativeRuntimeError.invalidRequest("The workspace has no active scheme, run destination, or execution environment")
        }
        return try PlanningContext(scheme: scheme, schemeIdentifier: object(scheme, selector: "schemeIdentifier") as? NSObject,
            environment: environment, activeDestination: destinationContext(object(manager, selector: "activeRunDestination")),
            destination: destinationContext(destination?.selected.value))
    }

    func workspaceBuilder(for destination: DestinationSelection) async throws -> AnyObject? {
        guard let field = Mirror(reflecting: destination.resolution.host).children.first(where: { $0.label == "lastWorkspaceBuilder" }) else {
            throw NativeRuntimeError.unsupportedContract("The native preview host has no cached workspace builder")
        }
        let mirror = Mirror(reflecting: field.value)
        let value: Any
        if mirror.displayStyle == .optional {
            guard let payload = mirror.children.first else { return nil }
            value = payload.value
        } else { value = field.value }
        guard Mirror(reflecting: value).displayStyle == .class else {
            throw NativeRuntimeError.unsupportedContract("The native preview workspace builder is not a class")
        }
        // Creating a builder after restoring the agentic source would invalidate this native cache.
        return value as AnyObject
    }

    private func configurationFilePaths(in containers: NSSet) throws -> (bases: [URL: AnyObject], watched: [URL: AnyObject])? {
        var baseFiles: [URL: AnyObject] = [:]
        var watchedFiles: [URL: AnyObject] = [:]
        for entry in containers.allObjects {
            guard let container = entry as? NSObject else { return nil }
            guard container.responds(to: NSSelectorFromString("pbxProject")) else { continue }
            guard let project = try object(container, selector: "pbxProject"),
                  let targets = try object(project, selector: "targets") as? NSArray else { return nil }
            for owner in [project] + targets.map({ $0 as AnyObject }) {
                guard let list = try object(owner, selector: "buildConfigurationList"),
                      let configurations = try object(list, selector: "buildConfigurations") as? NSArray else { return nil }
                for configuration in configurations {
                    let configuration = configuration as AnyObject
                    guard try object(configuration, selector: "baseConfigurationAnchoredReference") != nil else { continue }
                    guard let reference = try object(configuration, selector: "resolvedBaseConfigurationReference"),
                          let path = try object(reference, selector: "resolvedAbsolutePath") as? String,
                          path.hasPrefix("/"),
                          let filePath = try object(path as NSString, selector: "dvt_absoluteFilePath") else { return nil }
                    baseFiles[URL(filePath: path).standardizedFileURL] = filePath
                    let watched = try runtime.object(configuration).value(forIvar: "_watchedBaseConfigurationFilePaths", as: NSSet?.self)
                    for filePath in watched?.allObjects ?? [] {
                        guard let url = try object(filePath as AnyObject, selector: "fileURL") as? URL,
                              url.isFileURL, url.path.hasPrefix("/") else { return nil }
                        watchedFiles[url.standardizedFileURL] = filePath as AnyObject
                    }
                }
            }
        }
        return (baseFiles, watchedFiles)
    }

    func inputRoots(workspace: AnyObject, build: Result, source: URL) throws -> [URL]? {
        guard let declaredInputFiles = build.declaredInputFiles,
              let containers = try object(workspace, selector: "referencedContainers") as? NSSet,
              let configurationPaths = try configurationFilePaths(in: containers) else { return nil }
        let baseFiles = Set(configurationPaths.bases.keys)
        let watchedFiles = Set(configurationPaths.watched.keys)
        let configurationFiles = baseFiles.union(watchedFiles)
        for file in configurationFiles {
            // Optional includes can name paths absent from the native watched set.
            guard let text = try? String(contentsOf: file, encoding: .utf8), !text.utf8.contains(0x3f) else { return nil }
            if baseFiles.contains(file), text.utf8.contains(0x23), !watchedFiles.contains(file) { return nil }
        }
        guard let filePath = try object(workspace, selector: "representingFilePath"),
              let workspaceURL = try object(filePath, selector: "fileURL") as? URL else {
            throw NativeRuntimeError.unsupportedContract("The native workspace has no representing file URL")
        }
        // Native builder invalidation owns workspace configuration; these trees also detect disk edits synchronously.
        var roots: Set<URL> = [workspaceURL]
        roots.formUnion(configurationFiles)
        roots.formUnion(declaredInputFiles)
        var sources: Set<URL> = [source]
        var pending = build.targets + build.previewRoots
        while let target = pending.popLast() {
            if let directory = target.linkerWorkingDirectory, !directory.isEmpty {
                roots.insert(URL(filePath: directory, directoryHint: .isDirectory))
            }
            sources.formUnion(target.sourceFiles)
            pending += target.dependencies
        }
        let sourceDirectories = try Set(sources.map { source in
            guard source.isFileURL, source.path.hasPrefix("/") else {
                throw NativeRuntimeError.unsupportedContract("A native build source has no absolute file URL: \(source)")
            }
            return source.deletingLastPathComponent().standardizedFileURL
        })
        var packageSearches: Set<String> = []
        for sourceDirectory in sourceDirectories {
            roots.insert(sourceDirectory)
            var directory = sourceDirectory
            while packageSearches.insert(directory.path).inserted {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                    roots.insert(directory)
                    break
                }
                let parent = directory.deletingLastPathComponent().standardizedFileURL
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        let normalized = Set(roots.map(\.standardizedFileURL))
            .sorted { left, right in
                let leftCount = left.pathComponents.count
                let rightCount = right.pathComponents.count
                return leftCount == rightCount ? left.path < right.path : leftCount < rightCount
            }
        return normalized.reduce(into: [URL]()) { result, candidate in
            if !result.contains(where: { candidate.pathComponents.starts(with: $0.pathComponents) }) {
                result.append(candidate)
            }
        }
    }

    func build(workspace: AnyObject, destination selection: DestinationSelection, source: URL) async throws -> Result {
        try Task.checkCancellation()
        let info = selection.selected
        let destination = info.value
        let image = installation.framework("PreviewsIDEAPI", in: "PlugIns")
        let buildSystem = try await runtime.resolveSwiftType(named: "PreviewsIDEAPI.BuildSystem", in: .path(image))
        let buildables = try await buildSystem.resolveStaticMethod(
            named: "buildables(scheme: __C.IDEScheme, workspace: __C.IDEWorkspace, runContextManager: __C.IDERunContextManager, executionEnvironment: __C.IDEExecutionEnvironment) -> [__C.IDEBuildable]",
            as: ((AnyObject, AnyObject, AnyObject, AnyObject) -> NativeSwiftValue).self)
        let clientType = try await runtime.resolveSwiftType(named: "PreviewsIDEAPI.BuildOperationClient", in: .path(image))
        let initialize = try await clientType.resolveInitializer(named: "init() -> PreviewsIDEAPI.BuildOperationClient", as: (() -> AnyObject).self)
        let client = try unsafe initialize.unsafeInvoke()
        let cancel = try await runtime.object(client).resolveMethod(named: "cancelBuildOperation() -> ()", as: (() -> Void).self)
        let cancellation = Cancellation(cancel: { try unsafe cancel.unsafeInvoke() })
        let identifier = UUID()
        clients[identifier] = cancellation
        defer { clients[identifier] = nil }

        let perform = try await prepare(workspace: workspace)
        let workspaceBuilder = try? await self.workspaceBuilder(for: selection)
        try Task.checkCancellation()
        // Match BuildSystem.buildScheme: capture the selection before the task can update the model.
        guard let manager = try object(workspace, selector: "runContextManager"),
              let scheme = try object(manager, selector: "activeRunContext"),
              let environment = try object(workspace, selector: "executionEnvironment") else {
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
        let command = try runtime.object(commandClass as AnyObject).resolveMethodAndWait(
            selector: "launchSchemeCommand", as: (() -> AnyObject).self)
        let factory = try runtime.object(parametersClass as AnyObject).resolveMethodAndWait(
            selector: "operationParametersWithSchemeTask:buildCommand:executionEnvironment:runDestination:schemeCommand:commandName:invocationRecord:",
            as: ((Int64, Int64, AnyObject, AnyObject, AnyObject, String, AnyObject?) -> AnyObject).self)
        // BuildSystem.buildScheme uses these native scheme-task/build-command
        // values. Performing the task directly does not launch a preview agent.
        let parameters = try unsafe factory.unsafeInvoke(2, 8, environment, destination, command.unsafeInvoke(), "Build", nil)
        let setClient = try runtime.object(parameters).resolveMethodAndWait(
            selector: "setBuildOperationClientInfo:", as: ((AnyObject) -> Void).self)
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
        let suboperations = try runtime.object(operation).resolveMethodAndWait(selector: "suboperations", as: (() -> NSArray).self)
        return try unsafe suboperations.unsafeInvoke().flatMap { try buildOperations(in: $0 as AnyObject) }
    }

    private func checkBuildResults(_ operations: [AnyObject]) throws {
        for operation in operations {
            let result = try runtime.object(operation).resolveMethodAndWait(selector: "result", as: (() -> Int).self)
            let value = try unsafe result.unsafeInvoke()
            // performTask finishes the operation without throwing compiler failures.
            // Xcode's BuildOperationErrorDetector treats native result 1 as success.
            guard value == 1 else {
                let messages = try object(operation, selector: "buildLog").map { try buildErrors(in: $0) } ?? []
                let details = messages.joined(separator: "\n")
                throw NativeRuntimeError.invocation(details.isEmpty
                    ? "The native build failed with result \(value)"
                    : "The native build failed with result \(value):\n\(details)")
            }
        }
    }

    private func buildErrors(in section: AnyObject) throws -> [String] {
        if let text = try optionalString(section, selector: "text") {
            let errors = try runtime.object(section).resolveMethodAndWait(selector: "totalNumberOfErrors", as: (() -> UInt).self)
            let failures = try runtime.object(section).resolveMethodAndWait(selector: "totalNumberOfTestFailures", as: (() -> UInt).self)
            guard try unsafe errors.unsafeInvoke() > 0 || failures.unsafeInvoke() > 0 else { return [] }
            let title = try optionalString(section, selector: "title")
            return [title.map { "\($0)\n\(text)" } ?? text]
        }
        let subsections = try runtime.object(section).resolveMethodAndWait(selector: "subsections", as: (() -> NSArray).self)
        return try unsafe subsections.unsafeInvoke().flatMap { try buildErrors(in: $0 as AnyObject) }
    }

    private func targetDescriptions(for buildables: NativeSwiftValue, workspace: AnyObject, priorBuild: AnyObject,
                                    image: URL) async throws -> NativeSwiftValue {
        let buildSystem = try await runtime.resolveSwiftType(named: "PreviewsIDEAPI.BuildSystem", in: .path(image))
        let describe = try await buildSystem.resolveStaticMethod(
            named: "builtTargetDescriptions(workspace: __C.IDEWorkspace, priorBuild: __C.IDEBuildOperation, buildables: [__C.IDEBuildable]) async throws -> [(__C.IDEBuildable, [PreviewsIDEAPI.IDEBuiltTargetDescription])]",
            as: (@concurrent (AnyObject, AnyObject, NativeSwiftValue) async throws -> NativeSwiftValue).self)
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
            let selection = try NativePreviewCorrection.selectTarget(result, source: source, platform: platform)
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
                if let hostOutput = selection.host.outputURL, NativePreviewCorrection.productBundle(containing: hostOutput) == nil {
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
        let type = try await runtime.resolveSwiftType(named: "PreviewsIDEAPI.IDEBuiltTargetDescription", in: .path(image))
        let receiver = try NativeType.opaque(named: type.name)
        let module = try await type.resolveGetter(named: "productModuleName", as: (() -> String?).self, receiverABI: receiver)
        let name = try await type.resolveGetter(named: "buildableName", as: (() -> String).self, receiverABI: receiver)
        let sdk = try await type.resolveGetter(named: "sdkRoot", as: (() -> String).self, receiverABI: receiver)
        let variant = try await type.resolveGetter(named: "sdkVariant", as: (() -> String?).self, receiverABI: receiver)
        let architecture = try await type.resolveGetter(named: "architecture", as: (() -> String).self, receiverABI: receiver)
        let command = try await type.resolveGetter(named: "linkCommandLine", as: (() -> [String]).self, receiverABI: receiver)
        let directory = try await type.resolveGetter(named: "linkerWorkingDirectory", as: (() -> String?).self, receiverABI: receiver)
        let dylib = try await type.resolveGetter(named: "enableDebugDylib", as: (() -> Bool).self, receiverABI: receiver)
        let address = try await type.resolveGetter(named: "enableAddressSanitizer", as: (() -> Bool).self, receiverABI: receiver)
        let thread = try await type.resolveGetter(named: "enableThreadSanitizer", as: (() -> Bool).self, receiverABI: receiver)
        let undefined = try await type.resolveGetter(named: "enableUndefinedBehaviorSanitizer", as: (() -> Bool).self, receiverABI: receiver)
        let files = try await type.resolveGetter(named: "objectFiles", as: (() -> NativeSwiftValue).self, receiverABI: receiver)
        let fileType = try await runtime.resolveSwiftType(named: "PreviewsIDEAPI.IDEBuiltObjectFileDescription", in: .path(image))
        let path = try await fileType.resolveGetter(named: "builtPath.getter : Foundation.URL", as: (() -> NativePreviewBuildURL).self,
            receiverABI: .opaque(named: fileType.name))
        let sources = try await fileType.resolveGetter(named: "sourceFiles.getter : Swift.Set<Foundation.URL>", as: (() -> NativePreviewBuildSources).self,
            receiverABI: .opaque(named: fileType.name))
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
        guard let blueprint = try object(buildable, selector: "blueprint"),
              let canonical = try object(blueprint, selector: "primaryBuildable") as? NSObject else {
            throw NativeRuntimeError.unsupportedContract("A native dependency buildable has no primary buildable")
        }
        return canonical
    }

    private func declaredInputs(for buildables: NativeSwiftValue, workspace: AnyObject, priorBuild: AnyObject,
                                compilerCommands: [NativePreviewBuildInputs.CompilerCommand]) async throws ->
        (files: Set<URL>, missing: Set<URL>, products: Set<URL>)? {
        let (graph, roots) = try await dependencyGraph(for: buildables, workspace: workspace, priorBuild: priorBuild)
        defer { withExtendedLifetime(graph) {} }
        let dependencies = try await runtime.object(graph).resolveMethod(
            named: "dependencies(of: __C.IDEBuildable) -> [__C.IDEBuildable]",
            as: ((AnyObject) -> NativeSwiftValue).self)
        let parameters = try runtime.object(priorBuild).resolveMethodAndWait(selector: "_buildParametersForBuildable:",
            as: ((AnyObject) -> AnyObject).self)
        guard let service = try object(workspace, selector: "buildSystemService"),
              let levelClass = NSClassFromString("IDEMacroEvaluation_Level_Blueprint") else {
            throw NativeRuntimeError.unsupportedContract("The native build has no macro evaluation context")
        }
        let serviceType = try await runtime.resolveSwiftType(named: "IDEXCBuildSupportCore.IDEXCBuildSystemWorkspaceService",
            in: .path(installation.framework("IDEXCBuildSupportCore", in: "PlugIns")))
        let allocateLevel = try runtime.object(levelClass as AnyObject).resolveMethodAndWait(selector: "alloc",
            as: (() -> AnyObject).self)
        var files: Set<URL> = []
        var commands = compilerCommands
        var products: Set<URL> = []
        var pending = roots
        var seen: Set<ObjectIdentifier> = []
        while let buildable = pending.popLast() {
            try Task.checkCancellation()
            guard seen.insert(ObjectIdentifier(buildable)).inserted else { continue }
            let values = try unsafe dependencies.unsafeInvoke(buildable)
            guard let children = try values.withCopy({ $0 as? [NSObject] }),
                  let blueprint = try object(buildable, selector: "blueprint") as? NSObject else { return nil }
            pending.append(contentsOf: children)
            let buildParameters = try unsafe parameters.unsafeInvoke(buildable)
            let allocatedLevel = try unsafe allocateLevel.unsafeInvoke()
            let initializeLevel = try runtime.object(allocatedLevel).resolveMethodAndWait(selector: "initWithBlueprint:",
                as: ((AnyObject) -> AnyObject?).self)
            guard let level = try unsafe initializeLevel.unsafeInvoke(blueprint) else {
                throw NativeRuntimeError.invocation("IDEMacroEvaluation_Level_Blueprint.initWithBlueprint: returned nil")
            }
            let evaluateFlags = try await serviceType.resolveMethod(
                named: "evaluateMacroAsStringList(_: Swift.String, level: __C.IDEMacroEvaluation_Level, buildParameters: __C.IDEBuildParameters?, overrides: [Swift.String : Swift.String]?) async throws -> [Swift.String]",
                as: (@concurrent (String, AnyObject, AnyObject?, NativePreviewMacroOverrides) async throws -> [String]).self)
            let flags = try unsafe await evaluateFlags.unsafeInvoke(on: service, "OTHER_SWIFT_FLAGS", level,
                buildParameters, NativePreviewMacroOverrides(value: nil))
            if flags.contains(where: { $0.hasPrefix("@") }) {
                guard !flags.contains("-frontend"), !flags.contains("-disallow-use-new-driver") else { return nil }
                let evaluateRoot = try await serviceType.resolveMethod(
                    named: "evaluateMacroAsString(_: Swift.String, level: __C.IDEMacroEvaluation_Level, buildParameters: __C.IDEBuildParameters?, overrides: [Swift.String : Swift.String]?) async throws -> Swift.String",
                    as: (@concurrent (String, AnyObject, AnyObject?, NativePreviewMacroOverrides) async throws -> String).self)
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
            guard let target = try object(blueprint, selector: "pbxTarget") else { return nil }
            let phases: [NSObject] = try array(target, selector: "buildPhases")
            let groups: [NSObject] = try array(target, selector: "fileSystemSynchronizedGroupsArray")
            var references: Set<ObjectIdentifier> = []
            func addReference(_ reference: NSObject) throws -> Bool {
                guard references.insert(ObjectIdentifier(reference)).inserted else { return true }
                if reference.responds(to: NSSelectorFromString("children")) {
                    let children: [NSObject] = try array(reference, selector: "children")
                    if !children.isEmpty {
                        for child in children {
                            guard try addReference(child) else { return false }
                        }
                        return true
                    }
                }
                let absolutePath = try runtime.object(reference).resolveMethodAndWait(selector: "absolutePathForBuildParameters:",
                    as: ((AnyObject) -> AnyObject?).self)
                guard let path = try unsafe absolutePath.unsafeInvoke(buildParameters) as? String, path.hasPrefix("/") else { return false }
                let url = URL(filePath: path).standardizedFileURL
                if try boolean(reference, selector: "isProductReference")
                    || optionalString(reference, selector: "sourceTree") == "BUILT_PRODUCTS_DIR" {
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
                if try boolean(phase, selector: "runOnlyForDeploymentPostprocessing") {
                    let deployment = try await serviceType.resolveMethod(
                        named: "evaluateMacroAsBoolean(_: Swift.String, level: __C.IDEMacroEvaluation_Level, buildParameters: __C.IDEBuildParameters?, overrides: [Swift.String : Swift.String]?) async throws -> Swift.Bool",
                        as: (@concurrent (String, AnyObject, AnyObject?, NativePreviewMacroOverrides) async throws -> Bool).self)
                    let postprocessing = try unsafe await deployment.unsafeInvoke(on: service, "DEPLOYMENT_POSTPROCESSING", level,
                        buildParameters, NativePreviewMacroOverrides(value: nil))
                    if !postprocessing { continue }
                }
                if phase.responds(to: NSSelectorFromString("inputPaths")) {
                    let inputs: [String] = try array(phase, selector: "inputPaths")
                    let inputLists: [String] = try array(phase, selector: "inputFileListPaths")
                    let outputs: [String] = try array(phase, selector: "outputPaths")
                    let outputLists: [String] = try array(phase, selector: "outputFileListPaths")
                    guard inputLists.isEmpty, outputLists.isEmpty,
                          try !boolean(phase, selector: "alwaysOutOfDate") else { return nil }
                    let evaluate = try await serviceType.resolveMethod(
                        named: "evaluateMacroExpressionAsString(_: Swift.String, level: __C.IDEMacroEvaluation_Level, buildParameters: __C.IDEBuildParameters?, overrides: [Swift.String : Swift.String]?) async throws -> Swift.String",
                        as: (@concurrent (String, AnyObject, AnyObject?, NativePreviewMacroOverrides) async throws -> String).self)
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
                let buildFiles: [NSObject] = try array(phase, selector: "buildFiles")
                for file in buildFiles {
                    if let reference = try object(file, selector: "fileReference") as? NSObject {
                        guard try addReference(reference) else { return nil }
                    } else if try object(file, selector: "productReference") == nil {
                        return nil
                    }
                }
            }
        }
        guard let nativeFiles = try await completedBuildInputs(workspace: workspace, priorBuild: priorBuild,
            compilerCommands: commands) else { return nil }
        files.formUnion(nativeFiles.files)
        return (files, nativeFiles.missing.subtracting(files), products)
    }

    private func completedBuildInputs(workspace: AnyObject, priorBuild: AnyObject,
                                      compilerCommands: [NativePreviewBuildInputs.CompilerCommand]) async throws -> NativePreviewBuildInputs.Inputs? {
        guard let field = Mirror(reflecting: priorBuild).children.first(where: { $0.label == "buildDescriptionID" }),
              let identifier = Mirror(reflecting: field.value).children.first?.value as? String,
              !identifier.isEmpty, !identifier.contains("/") else { return nil }
        let getCache = try await runtime.object(workspace).resolveGetter(
            named: "(extension in IDEXCBuildSupportCore):__C.IDEWorkspace.xcbuildDataCachePath.getter : __C.DVTFilePath?",
            as: (() -> AnyObject?).self)
        guard let cachePath = try unsafe getCache.unsafeInvoke(),
              let cacheURL = try object(cachePath, selector: "fileURL") as? URL,
              cacheURL.isFileURL, cacheURL.path.hasPrefix("/") else { return nil }
        let manifest = cacheURL.appendingPathComponent(identifier + ".xcbuilddata", isDirectory: true)
            .appendingPathComponent("manifest.json")
        return NativePreviewBuildInputs.files(manifest: manifest, compilerCommands: compilerCommands,
            immutableRoots: [installation.contentsDirectory])
    }

    private func dependencyGraph(for buildables: NativeSwiftValue, workspace: AnyObject,
                                 priorBuild: AnyObject) async throws -> (AnyObject, [NSObject]) {
        guard let service = try object(workspace, selector: "buildSystemService"),
              let parameters = try object(priorBuild, selector: "buildParameters") else {
            throw NativeRuntimeError.unsupportedContract("The native build has no dependency query context")
        }
        guard let selectedBuildables = try buildables.withCopy({ $0 as? [NSObject] }) else {
            throw NativeRuntimeError.unsupportedContract("Native buildables are not an array of objects")
        }
        var selectedIdentities: Set<ObjectIdentifier> = []
        let canonicalBuildables = try selectedBuildables.map(canonicalBuildable).filter {
            selectedIdentities.insert(ObjectIdentifier($0)).inserted
        }
        let implicit = try runtime.object(priorBuild).resolveMethodAndWait(selector: "buildImplicitDependencies", as: (() -> Bool).self)
        let serviceType = try await runtime.resolveSwiftType(named: "IDEXCBuildSupportCore.IDEXCBuildSystemWorkspaceService",
            in: .path(installation.framework("IDEXCBuildSupportCore", in: "PlugIns")))
        let query = try await serviceType.resolveMethod(
            named: "computeDependencyGraph(for: [__C.IDEBuildable], buildParameters: __C.IDEBuildParameters, includeImplicitDependencies: Swift.Bool) async throws -> IDEFoundation.IDEBuildableDependencyGraph",
            as: (@concurrent (NativeSwiftValue, AnyObject, Bool) async throws -> AnyObject).self)
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
        let directDependencies = try await runtime.object(graph).resolveMethod(
            named: "dependencies(of: __C.IDEBuildable) -> [__C.IDEBuildable]",
            as: ((AnyObject) -> NativeSwiftValue).self)
        let directDependents = try await runtime.object(graph).resolveMethod(
            named: "dependents(of: __C.IDEBuildable) -> [__C.IDEBuildable]",
            as: ((AnyObject) -> NativeSwiftValue).self)
        try Task.checkCancellation()
        let resourceClass = NSClassFromString("IDESwiftPackageCore.IDESwiftPackageResourceBundleProductBlueprint")
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
            guard let blueprint = try object(buildable, selector: "blueprint") as? NSObject else {
                throw NativeRuntimeError.unsupportedContract("A native dependency buildable has no blueprint")
            }
            if let resourceClass, blueprint.isKind(of: resourceClass) {
                resourceBlueprints[identifier] = blueprint
            } else {
                let productType = try runtime.object(buildable).resolveMethodAndWait(selector: "productTypeIdentifier", as: (() -> String?).self)
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
                let name = try runtime.object(buildable).resolveMethodAndWait(selector: "displayName", as: (() -> String).self)
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
        let productType = try runtime.object(buildable).resolveMethodAndWait(selector: "productTypeIdentifier", as: (() -> String?).self)
        guard let identifier = try unsafe productType.unsafeInvoke(),
              identifier == "com.apple.product-type.framework" || identifier == "com.apple.product-type.library.dynamic" else { return false }
        guard let blueprint = try object(buildable, selector: "blueprint") as? NSObject,
              blueprint.responds(to: NSSelectorFromString("isValid")) else { return false }
        let valid = try runtime.object(blueprint).resolveMethodAndWait(selector: "isValid", as: (() -> Bool).self)
        guard try unsafe valid.unsafeInvoke(),
              let provider = try object(blueprint, selector: "blueprintProvider") as? NSObject else { return false }
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
        let parameters = try runtime.object(priorBuild).resolveMethodAndWait(selector: "_buildParametersForBuildable:",
            as: ((AnyObject) -> AnyObject).self)
        let evaluate = try await runtime.object(blueprint).resolveMethod(
            named: "evaluateMacroExpressionAsString(_: Swift.String, buildParameters: __C.IDEBuildParameters?, overrides: [Swift.String : Swift.String]?) async throws -> Swift.String",
            as: (@concurrent (String, AnyObject?, NativePreviewMacroOverrides) async throws -> String).self)
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
        let type = try await runtime.resolveSwiftType(named: "PreviewsIDEAPI.IDEBuiltTargetDescription", in: .path(image))
        let buildVariant = try await type.resolveGetter(named: "buildVariant", as: (() -> String).self, receiverABI: .opaque(named: type.name))
        return try await compileCommandLine(for: record.target, buildable: record.buildable,
            buildVariant: unsafe buildVariant.unsafeInvoke(on: record.native), priorBuild: priorBuild, workspace: workspace, source: source)
    }

    private func sanitizerEnvironment(for buildable: AnyObject, priorBuild: AnyObject, scheme: AnyObject,
                                      destination: AnyObject) throws -> [String: String] {
        guard let action = try object(scheme, selector: "launchSchemeAction") else { return [:] }
        let address = try runtime.object(action).resolveMethodAndWait(selector: "enableAddressSanitizer", as: (() -> Bool).self)
        let thread = try runtime.object(action).resolveMethodAndWait(selector: "enableThreadSanitizer", as: (() -> Bool).self)
        var sanitizers: [String] = []
        if try unsafe thread.unsafeInvoke() {
            let allowed = try runtime.object(action).resolveMethodAndWait(selector: "threadSanitizerAllowedForRunDestination:",
                as: ((AnyObject) -> Bool).self)
            if try unsafe allowed.unsafeInvoke(destination) { sanitizers.append("Thread") }
        }
        if try unsafe address.unsafeInvoke() { sanitizers.append("Address") }
        guard !sanitizers.isEmpty else { return [:] }
        guard let actionClass = NSClassFromString("IDESchemeAction") else {
            throw NativeRuntimeError.unavailable("Xcode scheme action class is unavailable")
        }
        let parameters = try runtime.object(priorBuild).resolveMethodAndWait(selector: "_buildParametersForBuildable:",
            as: ((AnyObject) -> AnyObject).self)
        let buildParameters = try unsafe parameters.unsafeInvoke(buildable)
        let environment = NSMutableDictionary()
        for sanitizer in sanitizers {
            let add = try unsafe runtime.object(actionClass as AnyObject).resolveMethodAndWait(
                selector: "add\(sanitizer)SanitizerEnvironmentVariables:buildParameters:buildable:debugAppExtensions:debugging:testingSpecifier:error:",
                as: ((NSMutableDictionary, AnyObject, AnyObject, Bool, Bool, AnyObject?, UnsafeMutableRawPointer?) -> Bool).self)
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
        guard let service = try object(workspace, selector: "buildSystemService"),
              let blueprint = try object(buildable, selector: "blueprint"),
              let parametersClass = NSClassFromString("IDEBuildParameters"),
              let pathClass = NSClassFromString("DVTFilePath") else {
            throw NativeRuntimeError.unsupportedContract("The native build has no preview compilation context")
        }
        let path = try runtime.object(pathClass as AnyObject).resolveMethodAndWait(
            selector: "filePathForPathString:", as: ((String) -> AnyObject).self)
        let sourcePath = try unsafe path.unsafeInvoke(source.path)
        let dictionary = try await runtime.resolveSwiftType(named: "Swift.Dictionary",
            genericArguments: [.type(String.self), .type(parametersClass)])
        // The concrete Dictionary parameter uses its frozen single-word ABI.
        let valueABIs: [NativeSwiftType: NativeType] = [dictionary: .pointer]
        let initialize = try await dictionary.resolveInitializer(
            named: "init(minimumCapacity: Swift.Int) -> [A : B]",
            as: ((Int) -> NativeSwiftValue).self, valueABIs: valueABIs)
        let overrides = try unsafe initialize.unsafeInvoke(0)
        let serviceType = try await runtime.resolveSwiftType(named: "IDEXCBuildSupportCore.IDEXCBuildSystemWorkspaceService",
            in: .path(installation.framework("IDEXCBuildSupportCore", in: "PlugIns")))
        let query = try await serviceType.resolveMethod(
            named: "generatePreviewInfo(forRecentBuild: __C.IDEBuildOperation, blueprint: __C.IDEBlueprint, sourceFilePath: __C.DVTFilePath, thunkVariantSuffix: Swift.String, perTargetOverridingBuildParameters: [Swift.String : __C.IDEBuildParameters]) async throws -> [IDEFoundation.IDEPreviewInfoOutput]",
            as: (@concurrent (AnyObject, AnyObject, AnyObject, String, NativeSwiftValue) async throws -> NativeSwiftValue).self,
            valueABIs: valueABIs)
        let outputType = try await runtime.resolveSwiftType(named: "IDEFoundation.IDEPreviewInfoOutput")
        let sdk = try await outputType.resolveGetter(named: "sdkRoot.getter : Swift.String", as: (() -> String).self)
        let variant = try await outputType.resolveGetter(named: "sdkVariant.getter : Swift.String?", as: (() -> String?).self)
        let architecture = try await outputType.resolveGetter(named: "architecture.getter : Swift.String", as: (() -> String).self)
        let build = try await outputType.resolveGetter(named: "buildVariant.getter : Swift.String", as: (() -> String).self)
        let command = try await outputType.resolveGetter(named: "compileCommandLine.getter : [Swift.String]", as: (() -> [String]).self)
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

    private func object(_ receiver: AnyObject, selector: String) throws -> AnyObject? {
        let get = try runtime.object(receiver).resolveMethodAndWait(selector: selector, as: (() -> AnyObject?).self)
        return try unsafe get.unsafeInvoke()
    }

    private func boolean(_ receiver: AnyObject, selector: String) throws -> Bool {
        let get = try runtime.object(receiver).resolveMethodAndWait(selector: selector, as: (() -> Bool).self)
        return try unsafe get.unsafeInvoke()
    }

    private func array<Value>(_ receiver: AnyObject, selector: String) throws -> [Value] {
        guard let value = try object(receiver, selector: selector) else { return [] }
        guard let values = value as? [Value] else {
            throw NativeRuntimeError.unsupportedContract("The native \(selector) value is not an array of \(Value.self)")
        }
        return values
    }

    private func optionalString(_ receiver: AnyObject?, selector: String) throws -> String? {
        guard let receiver, let object = receiver as? NSObject,
              object.responds(to: NSSelectorFromString(selector)) else { return nil }
        let get = try runtime.object(receiver).resolveMethodAndWait(selector: selector, as: (() -> String?).self)
        return try unsafe get.unsafeInvoke()
    }

    private func destinationContext(_ destination: AnyObject?) throws -> DestinationContext? {
        guard let destination else { return nil }
        let device = try object(destination, selector: "targetDevice")
        let sdk = try object(destination, selector: "targetSDK")
        let variant = try object(destination, selector: "targetSDKVariant")
        let hostPlatform = try object(destination, selector: "hostTargetedPlatform")
        let available: Bool?
        if let device {
            let get = try runtime.object(device).resolveMethodAndWait(selector: "isAvailable", as: (() -> Bool).self)
            available = try unsafe get.unsafeInvoke()
        } else { available = nil }
        return try DestinationContext(identifier: optionalString(device, selector: "identifier")
                ?? optionalString(destination, selector: "targetIdentifier"),
            architecture: optionalString(destination, selector: "targetArchitecture"),
            sdk: optionalString(sdk, selector: "canonicalName"), variant: optionalString(variant, selector: "name"),
            hostPlatform: optionalString(hostPlatform, selector: "identifier"),
            runtimeVersion: optionalString(device, selector: "operatingSystemVersion"), available: available)
    }

    @safe
    private struct DestinationPreparation {
        let properties: NativeSwiftMethod<() -> NativeSwiftValue>
        let platform: NativeSwiftMethod<() -> NativeSwiftValue>
        let identifier: NativeSwiftMethod<() -> NativeSwiftValue>
        let version: NativeSwiftMethod<() -> NativeSwiftValue>
        let platformName: NativeSwiftMethod<() -> String>
        let identifierString: NativeSwiftMethod<() -> String>
        let versionString: NativeSwiftMethod<() -> String>
        let model: NativeSwiftMethod<() -> String?>
        let name: NativeSwiftMethod<() -> String?>
        let specifier: NativeSwiftMethod<() -> String?>
    }

    private func prepareDestinationProperties() async throws -> DestinationPreparation {
        if let destinationPreparation { return destinationPreparation }
        let pipeline = ImageSelector.path(installation.framework("PreviewsPipeline", in: "SharedFrameworks"))
        let foundation = ImageSelector.path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks"))
        let recipeType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.AnyRunDestinationRecipe", in: pipeline)
        let propertiesType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.RunDestinationProperties", in: pipeline)
        let platformType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.Platform", in: pipeline)
        let identifierType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.DeviceIdentifier", in: pipeline)
        let versionType = try await runtime.resolveSwiftType(named: "PreviewsFoundationHost.VersionNumber", in: foundation)
        func getter<Value>(_ type: NativeSwiftType, _ declaration: String, _ value: Value.Type,
                           result: NativeSwiftType? = nil) async throws -> NativeSwiftMethod<() -> Value> {
            try await type.resolveGetter(named: declaration, as: (() -> Value).self,
                valueABIs: try result.map { [$0: try NativeType.opaque(named: $0.name)] } ?? [:],
                receiverABI: .opaque(named: type.name))
        }
        let preparation = try unsafe await DestinationPreparation(
            properties: getter(recipeType, "properties.getter : PreviewsPipeline.RunDestinationProperties", NativeSwiftValue.self, result: propertiesType),
            platform: getter(propertiesType, "platform.getter : PreviewsPipeline.Platform", NativeSwiftValue.self, result: platformType),
            identifier: getter(propertiesType, "deviceIdentifier.getter : PreviewsPipeline.DeviceIdentifier", NativeSwiftValue.self, result: identifierType),
            version: getter(propertiesType, "runtimeVersion.getter : PreviewsFoundationHost.VersionNumber", NativeSwiftValue.self, result: versionType),
            platformName: getter(platformType, "name.getter : Swift.String", String.self),
            identifierString: getter(identifierType, "stringValue.getter : Swift.String", String.self),
            versionString: getter(versionType, "description.getter : Swift.String", String.self),
            model: getter(propertiesType, "deviceModel.getter : Swift.String?", String?.self),
            name: getter(propertiesType, "deviceName.getter : Swift.String?", String?.self),
            specifier: getter(propertiesType, "deviceSpecifier.getter : Swift.String?", String?.self))
        destinationPreparation = preparation
        return preparation
    }

    private func destinationInfo(_ destination: AnyObject, recipe: NativeSwiftValue, prepared: DestinationPreparation) throws -> Destination {
        let device = try object(destination, selector: "targetDevice")
        let sdk = try object(destination, selector: "targetSDK")
        let platform = try sdk.flatMap { try object($0, selector: "platform") }
        let identifier = try optionalString(device, selector: "identifier")
            ?? optionalString(destination, selector: "targetIdentifier")
        guard let identifier else {
            throw NativeRuntimeError.unsupportedContract("The native run destination has no identifier")
        }
        let platformIdentifier = try optionalString(platform, selector: "identifier")
        let isMacCatalyst: Bool
        if platformIdentifier == "com.apple.platform.macosx" {
            let getter = try runtime.object(destination).resolveMethodAndWait(selector: "isMacCatalyst", as: (() -> Bool).self)
            isMacCatalyst = try unsafe getter.unsafeInvoke()
        } else { isMacCatalyst = false }
        let properties = try unsafe prepared.properties.unsafeInvoke(on: recipe)
        let nativePlatform = try unsafe prepared.platform.unsafeInvoke(on: properties)
        let nativeIdentifier = try unsafe prepared.identifier.unsafeInvoke(on: properties)
        let version = try unsafe prepared.version.unsafeInvoke(on: properties)
        let model = try unsafe prepared.model.unsafeInvoke(on: properties)
            ?? prepared.name.unsafeInvoke(on: properties) ?? prepared.specifier.unsafeInvoke(on: properties)
        let previewIdentifier = try unsafe prepared.identifierString.unsafeInvoke(on: nativeIdentifier)
        let platformName = try unsafe prepared.platformName.unsafeInvoke(on: nativePlatform)
        let systemVersion = try unsafe prepared.versionString.unsafeInvoke(on: version)
        return Destination(value: destination, recipe: recipe, identifier: identifier, previewIdentifier: previewIdentifier,
                           platformIdentifier: platformIdentifier,
                           previewPlatform: NativePreviewPlatform(platformIdentifier: platformIdentifier, isMacCatalyst: isMacCatalyst),
                           platformName: platformName,
                           deviceModelName: model, systemVersion: systemVersion)
    }

    struct PlanningContext {
        fileprivate let scheme: AnyObject
        fileprivate let schemeIdentifier: NSObject?
        fileprivate let environment: AnyObject
        fileprivate let activeDestination: DestinationContext?
        fileprivate let destination: DestinationContext?

        func matches(_ other: PlanningContext) -> Bool {
            let sameScheme: Bool
            switch (schemeIdentifier, other.schemeIdentifier) {
            case let (left?, right?): sameScheme = left.isEqual(right)
            case (nil, nil): sameScheme = scheme === other.scheme
            default: sameScheme = false
            }
            return sameScheme && environment === other.environment
                && activeDestination == other.activeDestination && destination == other.destination
        }
    }

    fileprivate struct DestinationContext: Equatable {
        let identifier: String?
        let architecture: String?
        let sdk: String?
        let variant: String?
        let hostPlatform: String?
        let runtimeVersion: String?
        let available: Bool?
    }

    struct DestinationResolution {
        fileprivate let host: AnyObject
        fileprivate let preferences: NativeSwiftValue
        let available: JSONValue?
        let errors: [String]
    }

    struct DestinationSelection {
        let selected: Destination
        let resolution: DestinationResolution

        var available: JSONValue? { resolution.available }
        var errors: [String] { resolution.errors }
    }

    struct Destination {
        let value: AnyObject
        let recipe: NativeSwiftValue
        let identifier: String
        let previewIdentifier: String
        let platformIdentifier: String?
        let previewPlatform: NativePreviewPlatform?
        let platformName: String?
        let deviceModelName: String?
        let systemVersion: String?
    }

    func frameworkAgent(for destination: DestinationSelection) async throws -> URL {
        try Task.checkCancellation()
        let recipe = destination.selected.recipe
        let bundleType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.PreviewAgentBundle",
            in: .path(installation.framework("PreviewsPipeline", in: "SharedFrameworks")))
        let make = try await recipe.type.resolveMethod(named: "makeFrameworkAgent() throws -> PreviewsPipeline.PreviewAgentBundle",
            as: (() throws -> NativeSwiftValue).self, valueABIs: [bundleType: .opaque(named: bundleType.name)],
            receiverABI: .opaque(named: recipe.type.name))
        let bundle = try unsafe make.unsafeInvoke(on: recipe)
        let url = try await bundleType.resolveGetter(named: "url.getter : Foundation.URL", as: (() -> NativePreviewBuildURL).self,
            receiverABI: .opaque(named: bundleType.name))
        try Task.checkCancellation()
        return try unsafe url.unsafeInvoke(on: bundle).value
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

private struct NativePreviewBuildURL: ABIBridgeSwiftValue {
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
extension NativePreviewBuild {
    struct Source {
        let translationUnit: NativeSwiftValue
        let definition: NativeSwiftValue
    }

    private struct SourcePlan {
        let value: NativeSwiftValue
        let recordType: NativeSwiftType
        let agentType: NativeSwiftType
        let packRecordType: NativeSwiftType
        let referenceType: NativeSwiftType
    }

    func withSourceSelection<Output>(workspace: AnyObject,
                                    operation: @MainActor () async throws -> Output) async throws -> Output {
        let workspaceID = ObjectIdentifier(workspace)
        try Task.checkCancellation()
        if sourceSelections[workspaceID] == nil {
            sourceSelections[workspaceID] = []
        } else {
            let identifier = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { sourceSelections[workspaceID, default: []].append(.init(identifier: identifier, continuation: continuation)) }
                }
            } onCancel: {
                Task { @MainActor in
                    guard let index = self.sourceSelections[workspaceID]?.firstIndex(where: { $0.identifier == identifier }) else { return }
                    let waiter = self.sourceSelections[workspaceID]!.remove(at: index)
                    waiter.continuation.resume(throwing: CancellationError())
                }
            }
        }
        defer {
            if let waiter = sourceSelections[workspaceID]?.first {
                sourceSelections[workspaceID]!.removeFirst()
                waiter.continuation.resume()
            } else { sourceSelections[workspaceID] = nil }
            withExtendedLifetime(workspace) {}
        }
        try Task.checkCancellation()
        return try await operation()
    }

    func resolveDestination(workspace: AnyObject, input: NativeSwiftValue) async throws -> DestinationResolution {
        try Task.checkCancellation()
        let previews = ImageSelector.path(installation.framework("PreviewsXcode", in: "PlugIns"))
        let createHost = try await runtime.object(workspace).resolveMethod(
            named: "(extension in PreviewsXcode):__C.IDEWorkspace.sceneHost(isNewProjectFromTemplate: Swift.Bool) -> PreviewsXcode.XcodeWorkspaceSceneHost",
            as: ((Bool) -> AnyObject).self)
        let host = try unsafe createHost.unsafeInvoke(false)
        let resolutionType = try await runtime.resolveSwiftType(named: "PreviewsXcode.RenderPreviewAction.DestinationResolution", in: previews)
        let actionType = try await runtime.resolveSwiftType(named: "PreviewsXcode.RenderPreviewAction", in: previews)
        let resolve = try await actionType.resolveStaticMethod(
            named: "static PreviewsXcode.RenderPreviewAction.resolveDestination(input: PreviewsXcode.RenderPreviewAction.Input, sceneHost: PreviewsXcode.XcodeWorkspaceSceneHost) async -> PreviewsXcode.RenderPreviewAction.DestinationResolution",
            as: (@concurrent (NativeSwiftValue, AnyObject) async -> NativeSwiftValue).self,
            valueABIs: [input.type: .opaque(named: input.type.name), resolutionType: .opaque(named: resolutionType.name)])
        let resolution = try unsafe await resolve.unsafeInvoke(input, host)
        try Task.checkCancellation()
        let fields = try resolution.withCopy { Dictionary(uniqueKeysWithValues: Mirror(reflecting: $0).children.compactMap {
            field in field.label.map { ($0, field.value) }
        }) }
        guard let rawPreferences = fields["preferences"] else {
            throw NativeRuntimeError.unsupportedContract("Native preview destination resolution has no preferences")
        }
        let preferences = try await _openExistential(rawPreferences, do: nativePreviewOwnedValue)
        let errors = (fields["errorMessage"] as? String? ?? nil).map { [$0] } ?? []
        guard let available = fields["availableRenderDestinations"] as? any Encodable else {
            throw NativeRuntimeError.unsupportedContract("Native preview destination resolution has no encodable destinations")
        }
        let encodedAvailable = try JSONEncoder().encode(available)
        guard let availableJSON = JSONValue(any: try JSONSerialization.jsonObject(with: encodedAvailable, options: .fragmentsAllowed)) else {
            throw NativeRuntimeError.unsupportedContract("Native preview destinations have an unsupported JSON representation")
        }
        return DestinationResolution(host: host, preferences: preferences,
            available: availableJSON == .null ? nil : availableJSON, errors: errors)
    }

    func destinationResolution(_ lhs: DestinationResolution, matches rhs: DestinationResolution) async throws -> Bool {
        guard lhs.available == rhs.available, lhs.errors == rhs.errors else { return false }
        let type = lhs.preferences.type
        let equals = try await type.resolveStaticMethod(
            named: "== infix(PreviewsPipeline.DestinationPreferences, PreviewsPipeline.DestinationPreferences) -> Swift.Bool",
            as: ((NativeSwiftValue, NativeSwiftValue) -> Bool).self, valueABIs: [type: .opaque(named: type.name)])
        return try unsafe equals.unsafeInvoke(lhs.preferences, rhs.preferences)
    }

    func selectDestination(workspace: AnyObject, source: Source, resolution: DestinationResolution,
                           metadata: Data? = nil, providerDescription: Data? = nil) async throws -> DestinationSelection {
        let evaluatedMetadata: NativeSwiftValue?
        if let metadata { evaluatedMetadata = try await decodePreviewValue(metadata, named: "PreviewMetadata") }
        else { evaluatedMetadata = nil }
        let evaluatedDescription: NativeSwiftValue?
        if let providerDescription { evaluatedDescription = try await decodePreviewValue(providerDescription, named: "PreviewDescription") }
        else { evaluatedDescription = nil }
        return try await withSourceSelection(workspace: workspace) {
            guard let pack = try await executionPointPack(source: source, preferences: resolution.preferences,
                metadata: evaluatedMetadata, providerDescription: evaluatedDescription) else { throw NativePipelineRequired() }
            let plan = try await sourcePlan(workspace: workspace, host: resolution.host, source: source, pack: pack)
            let record = try await sourcePlanRecord(plan, pack: pack)
            let prepared = try await prepareDestinationProperties()
            let recipeType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.AnyRunDestinationRecipe",
                in: .path(installation.framework("PreviewsPipeline", in: "SharedFrameworks")))
            let recipe = try await sourceGetter(record, "destination.getter : PreviewsPipeline.AnyRunDestinationRecipe", resultType: recipeType)
            let representation = try await sourceGetter(record, "destinationRepresentation.getter : C", resultType: plan.referenceType)
            guard let destination = try representation.withCopy({
                Mirror(reflecting: $0).children.first { $0.label == "runDestination" }?.value as? NSObject
            }) else { throw NativeRuntimeError.unsupportedContract("Native preview plan has no IDERunDestination representation") }
            let selected = try destinationInfo(destination, recipe: recipe, prepared: prepared)
            guard NativePreviewPlatform.supportsDestination(platformIdentifier: selected.platformIdentifier, identifier: selected.identifier) else {
                throw NativePipelineRequired()
            }
            return DestinationSelection(selected: selected, resolution: resolution)
        }
    }

    private func sourceGetter(_ value: NativeSwiftValue, _ name: String, resultType: NativeSwiftType,
                              resultABI: NativeType? = nil) async throws -> NativeSwiftValue {
        let getter = try await value.type.resolveGetter(named: name, as: (() -> NativeSwiftValue).self,
            valueABIs: [resultType: try resultABI ?? .opaque(named: resultType.name)], receiverABI: .opaque(named: value.type.name))
        return try unsafe getter.unsafeInvoke(on: value)
    }

    func isWidgetPreview(metadata: Data) async throws -> Bool {
        try await hasContentDomain("widget", metadata: metadata)
    }

    func isComplicationPreview(metadata: Data) async throws -> Bool {
        try await hasContentDomain("complication", metadata: metadata)
    }

    private func hasContentDomain(_ name: String, metadata: Data) async throws -> Bool {
        let metadata = try await decodePreviewValue(metadata, named: "PreviewMetadata")
        let domainType = try await runtime.resolveSwiftType(named: "PreviewsMessagingHost.PreviewContentDomain",
            in: .path(installation.framework("PreviewsMessagingHost", in: "SharedFrameworks")))
        let domain = try await sourceGetter(metadata,
            "contentDomain.getter : PreviewsMessagingHost.PreviewContentDomain", resultType: domainType)
        let expected = try domainType.makeEnumCase(named: name)
        return try domain.withCopy { value in
            guard let value = value as? any Equatable else {
                throw NativeRuntimeError.unsupportedContract("The native preview content domain is not Equatable")
            }
            func compare<Value: Equatable>(_ value: Value) throws -> Bool {
                try expected.withCopy { $0 as? Value == value }
            }
            return try _openExistential(value, do: compare)
        }
    }

    func decodePreviewValue(_ data: Data, named name: String) async throws -> NativeSwiftValue {
        guard let dictionary = try unsafe PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw NativeRuntimeError.invocation("The preview metadata is not a serializable dictionary")
        }
        let propertyListType = try await runtime.resolveSwiftType(named: "PreviewsFoundationHost.PropertyList",
            in: .path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks")))
        let nativeDictionary = try await nativePreviewOwnedValue(dictionary)
        let makePropertyList = try await propertyListType.resolveInitializer(named: "init(serializableDictionary:)",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [nativeDictionary.type: .pointer, propertyListType: .opaque(named: propertyListType.name)])
        let propertyList = try unsafe makePropertyList.unsafeInvoke(nativeDictionary)
        let metadataType = try await runtime.resolveSwiftType(named: "PreviewsMessagingHost.\(name)",
            in: .path(installation.framework("PreviewsMessagingHost", in: "SharedFrameworks")))
        let decode = try await metadataType.resolveInitializer(
            named: "init(propertyListValue: PreviewsFoundationHost.PropertyList) throws -> \(metadataType.name)",
            as: ((NativeSwiftValue) throws -> NativeSwiftValue).self,
            valueABIs: [propertyListType: .opaque(named: propertyListType.name), metadataType: .opaque(named: metadataType.name)])
        return try unsafe decode.unsafeInvoke(propertyList)
    }

    private func effectivePreferences(_ operation: NativeSwiftValue, instance: NativeSwiftValue) async throws -> NativeSwiftValue {
        let type = operation.type
        let emptyGetter = try await type.resolveStaticGetter(named: "empty.getter : PreviewsPipeline.DestinationPreferences",
            as: (() -> NativeSwiftValue).self, valueABIs: [type: .opaque(named: type.name)])
        let empty = try unsafe emptyGetter.unsafeInvoke()
        let equals = try await type.resolveStaticMethod(
            named: "== infix(PreviewsPipeline.DestinationPreferences, PreviewsPipeline.DestinationPreferences) -> Swift.Bool",
            as: ((NativeSwiftValue, NativeSwiftValue) -> Bool).self, valueABIs: [type: .opaque(named: type.name)])
        guard try unsafe equals.unsafeInvoke(operation, empty) else { return try operation.copy() }
        let getter = try await instance.type.resolveGetter(
            named: "PreviewsPipeline.PreviewInstanceProtocol.destinationPreferences.getter : PreviewsPipeline.DestinationPreferences",
            as: (() -> NativeSwiftValue).self, valueABIs: [type: .opaque(named: type.name)])
        return try unsafe getter.unsafeInvoke(on: instance)
    }

    private func executionPointPack(source: Source, preferences: NativeSwiftValue,
                                    metadata: NativeSwiftValue?, providerDescription: NativeSwiftValue?) async throws -> NativeSwiftValue? {
        let pipeline = ImageSelector.path(installation.framework("PreviewsPipeline", in: "SharedFrameworks"))
        let executionSource: NativeSwiftValue
        let role: NativeSwiftValue
        let effectivePreferences: NativeSwiftValue
        if let definition = try await source.definition.resolveEnumPayload(forCase: "registryPreview") {
            let instanceType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.PreviewInstance", in: pipeline)
            let makeInstance = try await instanceType.resolveStaticMethod(
                named: "registryPreview(definition: PreviewsModel.RegistryDefinition) -> PreviewsPipeline.PreviewInstance",
                as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                valueABIs: [definition.type: .opaque(named: definition.type.name), instanceType: .opaque(named: instanceType.name)])
            let instance = try unsafe makeInstance.unsafeInvoke(definition.copy())
            let registryType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.RegistryPreviewInstance", in: pipeline)
            let optionalType = try await runtime.resolveSwiftType(named: "Swift.Optional", genericArguments: [.type(registryType)])
            let registryGetter = try await instanceType.resolveGetter(named: "registryInstance.getter : PreviewsPipeline.RegistryPreviewInstance?",
                as: (() -> NativeSwiftValue).self, valueABIs: [optionalType: .opaque(named: optionalType.name)],
                receiverABI: .opaque(named: instanceType.name))
            let optional = try unsafe registryGetter.unsafeInvoke(on: instance)
            guard let registry = try await optional.resolveEnumPayload(forCase: "some") else {
                throw NativeRuntimeError.unsupportedContract("Native preview factory produced no registry instance")
            }
            func requirement(_ name: String, output: String) async throws -> NativeSwiftValue {
                let type = try await runtime.resolveSwiftType(named: output)
                let get = try await registry.type.resolveGetter(named: "PreviewsPipeline.PreviewInstanceProtocol.\(name).getter : \(output)",
                    as: (() -> NativeSwiftValue).self, valueABIs: [type: .opaque(named: type.name)])
                return try unsafe get.unsafeInvoke(on: registry)
            }
            executionSource = try await requirement("source", output: "PreviewsPipeline.ExecutionPointSource")
            role = try await requirement("agentRole", output: "PreviewsMessagingHost.PreviewAgentRole")
            if metadata != nil { effectivePreferences = try await self.effectivePreferences(preferences, instance: registry) }
            else { effectivePreferences = preferences }
        } else if let definition = try await source.definition.resolveEnumPayload(forCase: "previewProvider") {
            let identifierType = try await runtime.resolveSwiftType(named: "PreviewsModel.SourceIdentifier")
            let identifier = try await sourceGetter(definition, "sourceIdentifier.getter : PreviewsModel.SourceIdentifier", resultType: identifierType)
            let sourceType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.ExecutionPointSource", in: pipeline)
            executionSource = try await sourceType.makeEnumCase(named: "sourceFile", payload: identifier)
            let roleType = try await runtime.resolveSwiftType(named: "PreviewsMessagingHost.PreviewAgentRole")
            role = try roleType.makeEnumCase(named: "previews")
            if metadata != nil {
                guard let providerDescription else {
                    throw NativeRuntimeError.invocation("The evaluated provider returned no native preview description")
                }
                let providerSourceType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.ProviderSource", in: pipeline)
                let providerSource = try await providerSourceType.makeEnumCase(named: "provider", payload: definition.copy())
                let providerType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.ProviderPreviewInstance", in: pipeline)
                let initialize = try await providerType.resolveInitializer(
                    named: "init(providerSource: PreviewsPipeline.ProviderSource, previewDescription: PreviewsMessagingHost.PreviewDescription) -> PreviewsPipeline.ProviderPreviewInstance",
                    as: ((NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
                    valueABIs: [providerSourceType: .opaque(named: providerSourceType.name),
                        providerDescription.type: .opaque(named: providerDescription.type.name), providerType: .opaque(named: providerType.name)])
                let provider = try unsafe initialize.unsafeInvoke(providerSource, providerDescription.copy())
                effectivePreferences = try await self.effectivePreferences(preferences, instance: provider)
            } else { effectivePreferences = preferences }
        } else { return nil }
        let requirementsType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.DestinationRequirements", in: pipeline)
        // Native preflight and RenderPreview's evaluated Location use none.
        // The registry instance's requirements witness is unavailable.
        let none = try await requirementsType.resolveStaticGetter(named: "none.getter : PreviewsPipeline.DestinationRequirements",
            as: (() -> NativeSwiftValue).self, valueABIs: [requirementsType: .opaque(named: requirementsType.name)])
        let requirements = try unsafe none.unsafeInvoke()
        let domainType = try await runtime.resolveSwiftType(named: "PreviewsMessagingHost.PreviewContentDomain")
        let optionalDomainType = try await runtime.resolveSwiftType(named: "Swift.Optional", genericArguments: [.type(domainType)])
        let domain: NativeSwiftValue
        if let metadata {
            let contentDomain = try await sourceGetter(metadata, "contentDomain.getter : PreviewsMessagingHost.PreviewContentDomain", resultType: domainType)
            let some = try await runtime.resolveSwiftFunction(named: "XcodeMCPNativeRuntime.nativePreviewSome<A>(A) -> A?",
                as: ((NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: [.type(domainType)],
                valueABIs: [domainType: .opaque(named: domainType.name), optionalDomainType: .opaque(named: optionalDomainType.name)])
            domain = try unsafe some.unsafeInvoke(contentDomain)
        } else {
            let propertiesType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.ExecutionPointProperties", in: pipeline)
            let defaults = try await propertiesType.resolveStaticGetter(named: "default.getter : PreviewsPipeline.ExecutionPointProperties",
                as: (() -> NativeSwiftValue).self, valueABIs: [propertiesType: .opaque(named: propertiesType.name)])
            let properties = try unsafe defaults.unsafeInvoke()
            let domainGetter = try await propertiesType.resolveGetter(named: "previewContentDomain.getter : PreviewsMessagingHost.PreviewContentDomain?",
                as: (() -> NativeSwiftValue).self, valueABIs: [optionalDomainType: .opaque(named: optionalDomainType.name)],
                receiverABI: .opaque(named: propertiesType.name))
            domain = try unsafe domainGetter.unsafeInvoke(on: properties)
        }
        let packType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.ExecutionPointPack", in: pipeline)
        let create = try await packType.resolveInitializer(
            named: "init(executionPointSource: PreviewsPipeline.ExecutionPointSource, previewAgentRole: PreviewsMessagingHost.PreviewAgentRole, destinationPreferences: PreviewsPipeline.DestinationPreferences, destinationRequirements: PreviewsPipeline.DestinationRequirements, previewContentDomain: PreviewsMessagingHost.PreviewContentDomain?) -> PreviewsPipeline.ExecutionPointPack",
            as: ((NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [executionSource.type: .opaque(named: executionSource.type.name), role.type: .opaque(named: role.type.name),
                preferences.type: .opaque(named: preferences.type.name), requirementsType: .opaque(named: requirementsType.name),
                optionalDomainType: .opaque(named: optionalDomainType.name), packType: .opaque(named: packType.name)])
        return try unsafe create.unsafeInvoke(executionSource.copy(), role.copy(), effectivePreferences.copy(), requirements.copy(), domain.copy())
    }

    private func sourceArray(_ values: [NativeSwiftValue], elementType: NativeSwiftType) async throws -> NativeSwiftValue {
        let cast = try await runtime.resolveSwiftFunction(named: "XcodeMCPNativeRuntime.nativePreviewArray<A>([Any]) throws -> [A]",
            as: (([Any]) throws -> NativeSwiftValue).self, genericArguments: [.type(elementType)])
        let copies = try values.map { try $0.withCopy { $0 } }
        return try unsafe cast.unsafeInvoke(copies)
    }

    private func sourcePlan(workspace: AnyObject, host: AnyObject, source: Source, pack: NativeSwiftValue) async throws -> SourcePlan {
        let previews = ImageSelector.path(installation.framework("PreviewsXcode", in: "PlugIns"))
        let pipeline = ImageSelector.path(installation.framework("PreviewsPipeline", in: "SharedFrameworks"))
        let foundation = ImageSelector.path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks"))
        let hostType = try await runtime.resolveSwiftType(named: "PreviewsXcode.XcodeWorkspaceSceneHost", in: previews)
        let getScene = try await hostType.resolveGetter(named: "workspaceScene.getter : PreviewsScenes.WorkspaceScene<PreviewsPipeline.URLPreviewFileDescription>?", as: (() -> AnyObject?).self)
        guard let scene = try unsafe getScene.unsafeInvoke(on: host) else {
            throw NativeRuntimeError.unsupportedContract("Native preview scene host has no workspace scene")
        }
        let fileType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.URLPreviewFileDescription", in: pipeline)
        let sceneType = try await runtime.resolveSwiftType(named: "PreviewsScenes.WorkspaceScene",
            in: .path(installation.framework("PreviewsScenes", in: "SharedFrameworks")), genericArguments: [.type(fileType)])
        let optionalUnitType = try await runtime.resolveSwiftType(named: "Swift.Optional", genericArguments: [.type(source.translationUnit.type)])
        let originalGetter = try await sceneType.resolveGetter(named: "agenticTranslationUnit.getter : PreviewsPipeline.PreviewTranslationUnit?",
            as: (() -> NativeSwiftValue).self, valueABIs: [optionalUnitType: .opaque(named: optionalUnitType.name)])
        let setter = try await sceneType.resolveSetter(named: "agenticTranslationUnit.setter : PreviewsPipeline.PreviewTranslationUnit?",
            as: NativeSwiftValue.self, valueABIs: [optionalUnitType: .opaque(named: optionalUnitType.name)], mutating: false)
        let original = try unsafe originalGetter.unsafeInvoke(on: scene)
        let some = try await runtime.resolveSwiftFunction(named: "XcodeMCPNativeRuntime.nativePreviewSome<A>(A) -> A?",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: [.type(source.translationUnit.type)])
        let unit = try unsafe some.unsafeInvoke(source.translationUnit)
        guard let field = Mirror(reflecting: host).children.first(where: { $0.label == "environmentCoalescer" }),
              Mirror(reflecting: field.value).displayStyle == .class else {
            throw NativeRuntimeError.unsupportedContract("Native preview environment coalescer is unavailable")
        }
        let coalescer = field.value as AnyObject
        let coalescerType = try await runtime.resolveSwiftType(named: "PreviewsXcode.XcodeBuildEnvironmentCoalescer", in: previews)
        let invalidate = try await coalescerType.resolveMethod(named: "setNeedsUpdate() -> ()", as: (() -> Void).self)
        let updateType = try await runtime.resolveSwiftType(named: "PreviewsXcode.XcodeBuildEnvironmentCoalescer.UpdateResult", in: previews)
        let refresh = try await coalescerType.resolveMethod(named: "updated() -> PreviewsXcode.XcodeBuildEnvironmentCoalescer.UpdateResult",
            as: (() -> NativeSwiftValue).self, valueABIs: [updateType: .opaque(named: updateType.name)])
        let protocolSymbol = try await runtime.resolve(.init(name: "protocol descriptor for PreviewsIDEAPI.IDESchemeTaskExecutor", language: .swift, kind: .data),
            in: .path(installation.framework("PreviewsIDEAPI", in: "PlugIns")))
        let executorMetadata: Any.Type = try unsafe protocolSymbol.withUnsafeAddress {
            guard let metadata = unsafe ABISwiftProtocolTypeMetadata($0) else {
                throw NativeRuntimeError.unsupportedContract("Native scheme task executor protocol metadata is unavailable")
            }
            return unsafe unsafeBitCast(metadata, to: Any.Type.self)
        }
        let supplierFactory = try await runtime.resolveSwiftFunction(
            named: "XcodeMCPNativeRuntime.nativePreviewExecutorProvider<A>(Swift.AnyObject) throws -> @Swift.MainActor @Sendable () -> A?",
            as: ((AnyObject) throws -> NativeSwiftValue).self, genericArguments: [.type(executorMetadata)])
        let supplier = try unsafe supplierFactory.unsafeInvoke(workspace)
        let callback = try await supplier.resolveClosure(as: (@MainActor () -> NativeSwiftValue).self)
        let callsiteType = try await runtime.resolveSwiftType(named: "PreviewsFoundationHost.Callsite", in: foundation)
        let makeCallsite = try await callsiteType.resolveInitializer(named: "init(Swift.StaticString, Swift.UInt, Swift.UInt, Swift.StaticString) -> PreviewsFoundationHost.Callsite",
            as: ((NativePreviewStaticString, UInt, UInt, NativePreviewStaticString) -> NativeSwiftValue).self,
            valueABIs: [callsiteType: .opaque(named: callsiteType.name)])
        let callsite = try unsafe makeCallsite.unsafeInvoke(NativePreviewStaticString(value: #fileID), #line, #column, NativePreviewStaticString(value: #function))
        let tokenType = try await runtime.resolveSwiftType(named: "PreviewsFoundationHost.CancellationToken", in: foundation)
        let cancel = try await tokenType.resolveMethod(named: "cancel(callsite: PreviewsFoundationHost.Callsite) -> ()",
            as: ((NativeSwiftValue) -> Void).self, valueABIs: [callsiteType: .opaque(named: callsiteType.name)], receiverABI: .opaque(named: tokenType.name))
        let register = try await hostType.resolveMethod(
            named: "registerSchemeTaskExecutorProvider(@Swift.MainActor () -> PreviewsIDEAPI.IDESchemeTaskExecutor?) -> PreviewsFoundationHost.CancellationToken",
            as: ((NativeSwiftClosure<@MainActor () -> NativeSwiftValue>) -> NativeSwiftValue).self,
            valueABIs: [tokenType: .opaque(named: tokenType.name)])
        let token = try unsafe register.unsafeInvoke(on: host, callback)
        let outcome: Swift.Result<SourcePlan, any Error>
        do {
            try unsafe setter.unsafeInvoke(on: scene, unit)
            try unsafe invalidate.unsafeInvoke(on: coalescer)
            outcome = .success(try await makeSourcePlan(host: host, source: source, pack: pack))
        } catch { outcome = .failure(error) }
        var failures: [String] = []
        do {
            try unsafe setter.unsafeInvoke(on: scene, original.copy())
            try unsafe invalidate.unsafeInvoke(on: coalescer)
            _ = try unsafe refresh.unsafeInvoke(on: coalescer)
        } catch { failures.append("source input restoration failed: \(error)") }
        do { try unsafe cancel.unsafeInvoke(on: token, callsite.copy()) }
        catch { failures.append("scheme executor provider cancellation failed: \(error)") }
        withExtendedLifetime((protocolSymbol, supplier, callback)) {}
        if !failures.isEmpty {
            let operation = switch outcome {
            case .success: "Native preview source destination selected"
            case .failure(let error): String(describing: error)
            }
            throw NativeRuntimeError.invocation(([operation] + failures).joined(separator: "; "))
        }
        return try outcome.get()
    }

    private func makeSourcePlan(host: AnyObject, source: Source, pack: NativeSwiftValue) async throws -> SourcePlan {
        let pipeline = ImageSelector.path(installation.framework("PreviewsPipeline", in: "SharedFrameworks"))
        let foundation = ImageSelector.path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks"))
        let previews = ImageSelector.path(installation.framework("PreviewsXcode", in: "PlugIns"))
        let executionSourceType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.ExecutionPointSource", in: pipeline)
        let executionSource = try await pack.type.resolveGetter(named: "executionPointSource.getter : PreviewsPipeline.ExecutionPointSource",
            as: (() -> NativeSwiftValue).self, valueABIs: [executionSourceType: .opaque(named: executionSourceType.name)],
            receiverABI: .opaque(named: pack.type.name))
        let sourceValue = try unsafe executionSource.unsafeInvoke(on: pack)
        let sourceArray = try await sourceArray([sourceValue], elementType: sourceValue.type)
        let orderedType = try await runtime.resolveSwiftType(named: "PreviewsFoundationHost.OrderedSet", in: foundation, genericArguments: [.type(sourceValue.type)])
        let initialize = try await orderedType.resolveInitializer(named: "init<A where A == A1.Element, A1: Swift.Sequence>(A1) -> PreviewsFoundationHost.OrderedSet<A>",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: [.type(sourceArray.type)], valueABIs: [orderedType: .opaque(named: orderedType.name)])
        let sources = try unsafe initialize.unsafeInvoke(sourceArray.copy())
        let identifierType = try await runtime.resolveSwiftType(named: "PreviewsModel.SourceIdentifier", in: .path(installation.framework("PreviewsModel", in: "SharedFrameworks")))
        let identifierGetter = try await source.translationUnit.type.resolveGetter(named: "sourceIdentifier.getter : PreviewsModel.SourceIdentifier",
            as: (() -> NativeSwiftValue).self, valueABIs: [identifierType: .opaque(named: identifierType.name)], receiverABI: .opaque(named: source.translationUnit.type.name))
        let identifier = try unsafe identifierGetter.unsafeInvoke(on: source.translationUnit)
        let files = try await self.sourceArray([identifier], elementType: identifierType)
        let hostType = try await runtime.resolveSwiftType(named: "PreviewsXcode.XcodeWorkspaceSceneHost", in: previews)
        let makeBuilder = try await hostType.resolveMethod(named: "makeBuilder() throws -> PreviewsXcode.XcodeWorkspaceBuilder", as: (() throws -> AnyObject).self)
        let builder = try unsafe makeBuilder.unsafeInvoke(on: host)
        let builderType = try await runtime.resolveSwiftType(named: "PreviewsXcode.XcodeWorkspaceBuilder", in: previews)
        let makeGraph = try await builderType.resolveMethod(
            named: "makeBuildGraph(for: PreviewsFoundationHost.OrderedSet<PreviewsPipeline.ExecutionPointSource>, sourceFiles: [PreviewsModel.SourceIdentifier]) async throws -> PreviewsPipeline.WorkspaceGraph<PreviewsPipeline.BuildGraphItem<PreviewsXcode.XcodeGraphSource>>",
            as: (@concurrent (NativeSwiftValue, NativeSwiftValue) async throws -> AnyObject).self, valueABIs: [orderedType: .opaque(named: orderedType.name)])
        let graph = try unsafe await makeGraph.unsafeInvoke(on: builder, sources, files)
        let graphSource = try await runtime.resolveSwiftType(named: "PreviewsXcode.XcodeGraphSource", in: previews)
        let graphItem = try await runtime.resolveSwiftType(named: "PreviewsPipeline.BuildGraphItem", in: pipeline, genericArguments: [.type(graphSource)])
        let graphType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.WorkspaceGraph", in: pipeline, genericArguments: [.type(graphItem)])
        let packs = try await self.sourceArray([pack], elementType: pack.type)
        let update = try await graphType.resolveMethod(
            named: "makeUpdateGraph<A, B where A == PreviewsPipeline.BuildGraphItem<A1>, A1: PreviewsPipeline.WorkspaceGraphSource, B1: Swift.Collection, B1.Element == PreviewsPipeline.ExecutionPointPack>(for: B1) throws -> PreviewsPipeline.WorkspaceGraph<PreviewsPipeline.UpdateGraphItem<A1>>",
            as: ((NativeSwiftValue) throws -> AnyObject).self, genericArguments: [.type(graphSource), .type(packs.type)])
        let updateGraph = try unsafe update.unsafeInvoke(on: graph, packs)
        let platform = try await runtime.resolveSwiftType(named: "PreviewsPipeline.Platform", in: pipeline)
        let components = try await runtime.resolveSwiftType(named: "PreviewsXcode.RunDestinationBuildComponents", in: previews)
        guard let destinationClass = NSClassFromString("IDERunDestination") else {
            throw NativeRuntimeError.unsupportedContract("Native run destination class is unavailable")
        }
        let buildIdentifier = try await runtime.resolveSwiftType(named: "PreviewsXcode.XcodeWorkspaceBuilder.BuildIdentifier", in: previews,
            genericArguments: [.type(platform), .type(destinationClass), .type(components)])
        let reference = try await runtime.resolveSwiftType(named: "PreviewsXcode.XcodeRunDestinationReference", in: previews)
        let arguments: [NativeSwiftGenericArgument] = [.type(graphSource), .type(buildIdentifier), .type(reference)]
        let planType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.PreviewUpdatePlan", in: pipeline,
            genericArguments: arguments)
        let recordType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.PreviewUpdatePlan.UpdateRecord", in: pipeline,
            genericArguments: arguments)
        let agentType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.PreviewUpdatePlan.AgentRecord", in: pipeline,
            genericArguments: arguments)
        let packRecordType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.PreviewUpdatePlan.AgentRecord.PackRecord", in: pipeline,
            genericArguments: arguments)
        let futureType = try await runtime.resolveSwiftType(named: "PreviewsFoundationHost.Future", in: foundation, genericArguments: [.type(planType)])
        let queryGetter = try await hostType.resolveGetter(named: "queryManager.getter : PreviewsFoundationHost.QueryManager", as: (() -> AnyObject).self)
        let query = try unsafe queryGetter.unsafeInvoke(on: host)
        let graphValue = try await _openExistential(updateGraph as Any, do: nativePreviewOwnedValue)
        let queryValue = try await _openExistential(query as Any, do: nativePreviewOwnedValue)
        let builderValue = try await _openExistential(builder as Any, do: nativePreviewOwnedValue)
        let plan = try await planType.resolveStaticMethod(
            named: "static PreviewsPipeline.PreviewUpdatePlan.planForUpdating<A where A == A1.GraphSource, B == A1.WorkspaceBuildIdentifier, C == A1.DestinationRepresentation, A1: PreviewsPipeline.WorkspaceBuilder>(in: PreviewsPipeline.WorkspaceGraph<PreviewsPipeline.UpdateGraphItem<A>>, queryManager: PreviewsFoundationHost.QueryManager, workspaceBuilder: A1) throws -> PreviewsFoundationHost.Future<PreviewsPipeline.PreviewUpdatePlan<A, B, C>>",
            as: ((NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) throws -> NativeSwiftValue).self, genericArguments: [.type(builderType)])
        let future = try unsafe plan.unsafeInvoke(graphValue, queryValue, builderValue)
        let awaitValue = try await futureType.resolveGetter(named: "(extension in PreviewsFoundationHost):PreviewsFoundationHost.Future<A where A: Swift.Sendable>.value.getter : A",
            as: (@concurrent () async throws -> NativeSwiftValue).self, declaredAs: "() async throws -> A", valueABIs: [planType: .opaque(named: planType.name)])
        return try unsafe await SourcePlan(value: awaitValue.unsafeInvoke(on: future), recordType: recordType,
            agentType: agentType, packRecordType: packRecordType, referenceType: reference)
    }

    private func sourcePlanRecord(_ plan: SourcePlan, pack: NativeSwiftValue) async throws -> NativeSwiftValue {
        let foundation = ImageSelector.path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks"))
        let setType = try await runtime.resolveSwiftType(named: "PreviewsFoundationHost.OrderedIdentifiedSet", in: foundation,
            genericArguments: [.type(plan.packRecordType)])
        let inhabitedType = try await runtime.resolveSwiftType(named: "PreviewsFoundationHost.Inhabited", in: foundation,
            genericArguments: [.type(setType)])
        let optionalType = try await runtime.resolveSwiftType(named: "Swift.Optional", genericArguments: [.type(plan.packRecordType)])
        let lookup = try await setType.resolveMethod(
            named: "PreviewsFoundationHost.OrderedIdentifiedSet.subscript.getter : (A.ID) -> A?",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [pack.type: .opaque(named: pack.type.name), optionalType: .opaque(named: optionalType.name)],
            receiverABI: .opaque(named: setType.name))
        for record in try await sourcePlanRecords(plan) {
            let agent = try await sourceGetter(record, "agentRecord", resultType: plan.agentType)
            let packs = try await sourceGetter(agent, "executionPointPacks", resultType: inhabitedType)
            let values = try await sourceGetter(packs,
                "(extension in PreviewsFoundationHost):PreviewsFoundationHost.PredicatedWrapper.value.getter : A.Predicate.Value", resultType: setType)
            let match = try unsafe lookup.unsafeInvoke(on: values, pack.copy())
            if try await match.resolveEnumPayload(forCase: "some", valueABIs: [plan.packRecordType: .opaque(named: plan.packRecordType.name)]) != nil {
                return record
            }
        }
        throw NativeRuntimeError.invocation("Could not find update record in native update plan for the selected execution point pack")
    }

    private func sourcePlanRecords(_ plan: SourcePlan) async throws -> [NativeSwiftValue] {
        let foundation = ImageSelector.path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks"))
        let arrayType = try await runtime.resolveSwiftType(named: "Swift.Array", genericArguments: [.type(plan.recordType)])
        let inhabitedType = try await runtime.resolveSwiftType(named: "PreviewsFoundationHost.Inhabited", in: foundation,
            genericArguments: [.type(arrayType)])
        let headType = try await runtime.resolveSwiftType(named: "PreviewsFoundationHost.HasHead", in: foundation,
            genericArguments: [.type(arrayType)])
        let predicatedType = try await runtime.resolveSwiftType(named: "PreviewsFoundationHost.Predicated", in: foundation,
            genericArguments: [.type(headType)])
        let records = try await sourceGetter(plan.value, "updateRecords", resultType: inhabitedType)
        let predicated = try await sourceGetter(records, "predicated", resultType: predicatedType)
        let values = try await sourceGetter(predicated, "value", resultType: arrayType, resultABI: .pointer)
        guard let raw = try values.withCopy({ $0 as? [Any] }) else {
            throw NativeRuntimeError.unsupportedContract("Native preview update plan records are not an array")
        }
        var result: [NativeSwiftValue] = []
        for value in raw { result.append(try await _openExistential(value, do: nativePreviewOwnedValue)) }
        return result
    }
}

private struct NativePreviewStaticString: ABIBridgeSwiftValue {
    let value: StaticString
    static let swiftABIType: NativeType = try! .structure(named: "Swift.StaticString", fields: [.uint64, .uint64, .uint8])
}

@MainActor
private func nativePreviewOwnedValue<Value>(_ value: Value) async throws -> NativeSwiftValue {
    let identity = try await ABIRuntime.shared.resolveSwiftFunction(named: "XcodeMCPNativeRuntime.nativePreviewValue<A>(A) -> A",
        as: ((Value) -> NativeSwiftValue).self, genericArguments: [.type(Value.self)])
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
