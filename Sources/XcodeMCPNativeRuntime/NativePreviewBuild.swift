import ABIBridge
import ABIBridgeCore
import Foundation
import XcodeMCPWire

@safe
@MainActor
final class NativePreviewBuild {
    struct Result {
        let targets: [Target]
        let destinationIdentifier: String
        let previewDestinationIdentifier: String
        let platformIdentifier: String?
        let previewPlatform: NativePreviewPlatform?
        let platformName: String?
        let deviceModelName: String?
        let systemVersion: String?
        let availableRenderDestinations: JSONValue?

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
            func url(for path: String) -> URL? {
                if path.hasPrefix("/") { return URL(filePath: path) }
                guard let linkerWorkingDirectory else { return nil }
                return URL(filePath: path, relativeTo: URL(filePath: linkerWorkingDirectory, directoryHint: .isDirectory))
                    .absoluteURL
            }
            let productPath = product.resolvingSymlinksInPath().path
            if linkCommandLine.contains(where: { url(for: $0)?.resolvingSymlinksInPath().path == productPath }) {
                return true
            }
            for index in linkCommandLine.indices where linkCommandLine[index] == "-filelist" {
                guard linkCommandLine.indices.contains(index + 1), let fileList = url(for: linkCommandLine[index + 1]) else { continue }
                let paths = try String(contentsOf: fileList, encoding: .utf8).split(whereSeparator: \.isNewline)
                if paths.contains(where: { url(for: String($0))?.resolvingSymlinksInPath().path == productPath }) { return true }
            }
            return false
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

    func build(workspace: AnyObject, destination selection: DestinationSelection) async throws -> Result {
        try Task.checkCancellation()
        let info = selection.selected
        let destination = info.value
        guard let manager = try object(workspace, selector: "runContextManager"),
              let scheme = try object(manager, selector: "activeRunContext"),
              let environment = try object(workspace, selector: "executionEnvironment") else {
            throw NativeRuntimeError.invalidRequest("The workspace has no active scheme, run destination, or execution environment")
        }
        let runnable = try runnableBuildable(in: scheme)
        let image = installation.framework("PreviewsIDEAPI", in: "PlugIns")
        let clientType = try await runtime.resolveSwiftType(named: "PreviewsIDEAPI.BuildOperationClient", in: .path(image))
        let initialize = try await clientType.resolveInitializer(named: "init() -> PreviewsIDEAPI.BuildOperationClient", as: (() -> AnyObject).self)
        let client = try unsafe initialize.unsafeInvoke()
        let cancel = try await runtime.object(client).resolveMethod(named: "cancelBuildOperation() -> ()", as: (() -> Void).self)
        let cancellation = Cancellation(cancel: { try unsafe cancel.unsafeInvoke() })
        let identifier = UUID()
        clients[identifier] = cancellation
        defer { clients[identifier] = nil }

        let parameters = try operationParameters(environment: environment, destination: destination, client: client)
        let perform = try await prepare(workspace: workspace)
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
        let buildSystem = try await runtime.resolveSwiftType(named: "PreviewsIDEAPI.BuildSystem", in: .path(image))
        let buildables = try await buildSystem.resolveStaticMethod(
            named: "buildables(scheme: __C.IDEScheme, workspace: __C.IDEWorkspace, runContextManager: __C.IDERunContextManager, executionEnvironment: __C.IDEExecutionEnvironment) -> [__C.IDEBuildable]",
            as: ((AnyObject, AnyObject, AnyObject, AnyObject) -> NativeSwiftValue).self)
        let selectedBuildables = try unsafe buildables.unsafeInvoke(scheme, workspace, manager, environment)
        let describe = try await buildSystem.resolveStaticMethod(
            named: "builtTargetDescriptions(workspace: __C.IDEWorkspace, priorBuild: __C.IDEBuildOperation, buildables: [__C.IDEBuildable]) async throws -> [(__C.IDEBuildable, [PreviewsIDEAPI.IDEBuiltTargetDescription])]",
            as: (@concurrent (AnyObject, AnyObject, NativeSwiftValue) async throws -> NativeSwiftValue).self)
        let descriptions = try unsafe await describe.unsafeInvoke(workspace, priorBuild, selectedBuildables)
        try Task.checkCancellation()
        let records = try await targets(descriptions, image: image, runnable: runnable)
        return Result(targets: records, destinationIdentifier: info.identifier, previewDestinationIdentifier: info.previewIdentifier,
                      platformIdentifier: info.platformIdentifier, previewPlatform: info.previewPlatform,
                      platformName: info.platformName, deviceModelName: info.deviceModelName, systemVersion: info.systemVersion,
                      availableRenderDestinations: selection.available)
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

    private func targets(_ descriptions: NativeSwiftValue, image: URL, runnable: AnyObject?) async throws -> [Target] {
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
        let files = try await type.resolveGetter(named: "objectFiles", as: (() -> NativeSwiftValue).self, receiverABI: receiver)
        let fileType = try await runtime.resolveSwiftType(named: "PreviewsIDEAPI.IDEBuiltObjectFileDescription", in: .path(image))
        let path = try await fileType.resolveGetter(named: "builtPath.getter : Foundation.URL", as: (() -> NativePreviewBuildURL).self,
            receiverABI: .opaque(named: fileType.name))
        let sources = try await fileType.resolveGetter(named: "sourceFiles.getter : Swift.Set<Foundation.URL>", as: (() -> NativePreviewBuildSources).self,
            receiverABI: .opaque(named: fileType.name))
        return try descriptions.withCopy { value in
            guard let entries = value as? [Any] else {
                throw NativeRuntimeError.unsupportedContract("Native built target descriptions are not an array")
            }
            return try entries.flatMap { entry -> [Target] in
                guard let (buildable, records) = entry as? (NSObject, [Any]) else {
                    throw NativeRuntimeError.unsupportedContract("Native built target description has an unsupported tuple")
                }
                // The native build service groups these variants by target PIF GUID.
                let isRunnable = Self.isRunnable(buildable, runnable: runnable)
                return try records.map { record in
                    let nativeFiles = try unsafe files.unsafeInvoke(on: record)
                    let objectFiles = try nativeFiles.withCopy { values -> [(URL, Set<URL>)] in
                        guard let values = values as? [Any] else {
                            throw NativeRuntimeError.unsupportedContract("Native object file descriptions are not an array")
                        }
                        return try values.map { try unsafe (path.unsafeInvoke(on: $0).value, sources.unsafeInvoke(on: $0).value) }
                    }
                    return try unsafe Target(moduleName: module.unsafeInvoke(on: record),
                        buildableName: name.unsafeInvoke(on: record), sdkRoot: sdk.unsafeInvoke(on: record),
                        sdkVariant: variant.unsafeInvoke(on: record), architecture: architecture.unsafeInvoke(on: record),
                        linkCommandLine: command.unsafeInvoke(on: record), linkerWorkingDirectory: directory.unsafeInvoke(on: record),
                        objectFiles: objectFiles.map(\.0), sourceFiles: Set(objectFiles.flatMap(\.1)),
                        debugDylibEnabled: dylib.unsafeInvoke(on: record), isRunnable: isRunnable)
                }
            }
        }
    }

    private func object(_ receiver: AnyObject, selector: String) throws -> AnyObject? {
        let get = try runtime.object(receiver).resolveMethodAndWait(selector: selector, as: (() -> AnyObject?).self)
        return try unsafe get.unsafeInvoke()
    }

    private func optionalString(_ receiver: AnyObject?, selector: String) throws -> String? {
        guard let receiver, let object = receiver as? NSObject,
              object.responds(to: NSSelectorFromString(selector)) else { return nil }
        let get = try runtime.object(receiver).resolveMethodAndWait(selector: selector, as: (() -> String?).self)
        return try unsafe get.unsafeInvoke()
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
        return Destination(value: destination, identifier: identifier, previewIdentifier: previewIdentifier,
                           platformIdentifier: platformIdentifier,
                           previewPlatform: NativePreviewPlatform(platformIdentifier: platformIdentifier, isMacCatalyst: isMacCatalyst),
                           platformName: platformName,
                           deviceModelName: model, systemVersion: systemVersion)
    }

    struct DestinationSelection {
        let selected: Destination
        let available: JSONValue?
        let errors: [String]

        init(selected: Destination, available: JSONValue?, errors: [String] = []) {
            self.selected = selected
            self.available = available
            self.errors = errors
        }
    }

    struct Destination {
        let value: AnyObject
        let identifier: String
        let previewIdentifier: String
        let platformIdentifier: String?
        let previewPlatform: NativePreviewPlatform?
        let platformName: String?
        let deviceModelName: String?
        let systemVersion: String?
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

    func selectDestination(workspace: AnyObject, source: Source, input: NativeSwiftValue) async throws -> DestinationSelection? {
        try await withSourceSelection(workspace: workspace) {
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
            guard let pack = try await preflightPack(source: source, preferences: preferences) else { return nil }
            let plan = try await sourcePlan(workspace: workspace, host: host, source: source, pack: pack)
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
            guard NativePreviewPlatform.supportsDestination(platformIdentifier: selected.platformIdentifier, identifier: selected.identifier) else { return nil }
            return DestinationSelection(selected: selected, available: availableJSON == .null ? nil : availableJSON, errors: errors)
        }
    }

    private func sourceGetter(_ value: NativeSwiftValue, _ name: String, resultType: NativeSwiftType,
                              resultABI: NativeType? = nil) async throws -> NativeSwiftValue {
        let getter = try await value.type.resolveGetter(named: name, as: (() -> NativeSwiftValue).self,
            valueABIs: [resultType: try resultABI ?? .opaque(named: resultType.name)], receiverABI: .opaque(named: value.type.name))
        return try unsafe getter.unsafeInvoke(on: value)
    }

    private func preflightPack(source: Source, preferences: NativeSwiftValue) async throws -> NativeSwiftValue? {
        let pipeline = ImageSelector.path(installation.framework("PreviewsPipeline", in: "SharedFrameworks"))
        let executionSource: NativeSwiftValue
        let role: NativeSwiftValue
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
        } else if let definition = try await source.definition.resolveEnumPayload(forCase: "previewProvider") {
            let identifierType = try await runtime.resolveSwiftType(named: "PreviewsModel.SourceIdentifier")
            let identifier = try await sourceGetter(definition, "sourceIdentifier.getter : PreviewsModel.SourceIdentifier", resultType: identifierType)
            let sourceType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.ExecutionPointSource", in: pipeline)
            executionSource = try await sourceType.makeEnumCase(named: "sourceFile", payload: identifier)
            let roleType = try await runtime.resolveSwiftType(named: "PreviewsMessagingHost.PreviewAgentRole")
            role = try roleType.makeEnumCase(named: "previews")
        } else { return nil }
        let requirementsType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.DestinationRequirements", in: pipeline)
        // Native preflight uses none rather than the registry instance's
        // unavailable requirements witness. Evaluated requests own later requirements.
        let none = try await requirementsType.resolveStaticGetter(named: "none.getter : PreviewsPipeline.DestinationRequirements",
            as: (() -> NativeSwiftValue).self, valueABIs: [requirementsType: .opaque(named: requirementsType.name)])
        let requirements = try unsafe none.unsafeInvoke()
        let propertiesType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.ExecutionPointProperties", in: pipeline)
        let defaults = try await propertiesType.resolveStaticGetter(named: "default.getter : PreviewsPipeline.ExecutionPointProperties",
            as: (() -> NativeSwiftValue).self, valueABIs: [propertiesType: .opaque(named: propertiesType.name)])
        let properties = try unsafe defaults.unsafeInvoke()
        let domainType = try await runtime.resolveSwiftType(named: "PreviewsMessagingHost.PreviewContentDomain")
        let optionalDomainType = try await runtime.resolveSwiftType(named: "Swift.Optional", genericArguments: [.type(domainType)])
        let domainGetter = try await propertiesType.resolveGetter(named: "previewContentDomain.getter : PreviewsMessagingHost.PreviewContentDomain?",
            as: (() -> NativeSwiftValue).self, valueABIs: [optionalDomainType: .opaque(named: optionalDomainType.name)],
            receiverABI: .opaque(named: propertiesType.name))
        let domain = try unsafe domainGetter.unsafeInvoke(on: properties)
        let packType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.ExecutionPointPack", in: pipeline)
        let create = try await packType.resolveInitializer(
            named: "init(executionPointSource: PreviewsPipeline.ExecutionPointSource, previewAgentRole: PreviewsMessagingHost.PreviewAgentRole, destinationPreferences: PreviewsPipeline.DestinationPreferences, destinationRequirements: PreviewsPipeline.DestinationRequirements, previewContentDomain: PreviewsMessagingHost.PreviewContentDomain?) -> PreviewsPipeline.ExecutionPointPack",
            as: ((NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [executionSource.type: .opaque(named: executionSource.type.name), role.type: .opaque(named: role.type.name),
                preferences.type: .opaque(named: preferences.type.name), requirementsType: .opaque(named: requirementsType.name),
                optionalDomainType: .opaque(named: optionalDomainType.name), packType: .opaque(named: packType.name)])
        return try unsafe create.unsafeInvoke(executionSource.copy(), role.copy(), preferences.copy(), requirements.copy(), domain.copy())
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
