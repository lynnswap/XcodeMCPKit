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
        let availableDestinations: [Destination]

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
    private let abi = NativeABI()
    private var destinationPreparation: DestinationPreparation?
    private var clients: [UUID: Cancellation] = [:]
    private var performMethod: NativeSwiftMethod<@concurrent (AnyObject, AnyObject) async throws -> AnyObject>?

    init(installation: NativeXcodeInstallation) {
        self.installation = installation
    }

    func selectDestination(workspace: AnyObject, preferred: [String: String] = [:]) async throws -> DestinationSelection? {
        guard let manager = try object(workspace, selector: "runContextManager"),
              let scheme = try object(manager, selector: "activeRunContext") else {
            throw NativeRuntimeError.invalidRequest("The workspace has no active scheme")
        }
        let available = try runtime.object(scheme).resolveMethodAndWait(
            selector: "availableRunDestinations", as: (() -> NSArray).self)
        let candidates = try await destinations(unsafe available.unsafeInvoke()).filter {
            NativePreviewPlatform.supportsDestination(platformIdentifier: $0.platformIdentifier, identifier: $0.identifier)
        }
        let active = try object(manager, selector: "activeRunDestination")
        guard let selected = Self.selectDestination(candidates: candidates, active: active, preferred: preferred) else { return nil }
        return DestinationSelection(selected: selected, available: candidates)
    }

    static func selectDestination(candidates: [Destination], active: AnyObject?, preferred: [String: String]) -> Destination? {
        if preferred.isEmpty {
            return candidates.first { ($0.value as? NSObject)?.isEqual(active) == true }
        }
        let matches = candidates.filter { destination in
            let fields = ["identifier": destination.previewIdentifier,
                          "platformName": destination.platformName,
                          "deviceModelName": destination.deviceModelName,
                          "systemVersion": destination.systemVersion]
            return preferred.allSatisfy { key, value in
                fields[key] == value || (key == "identifier" && destination.identifier == value)
            }
        }
        guard !matches.isEmpty else { return nil }
        if let active,
           let match = matches.first(where: { ($0.value as? NSObject)?.isEqual(active) == true }) {
            return match
        }
        return matches.first
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
                      availableDestinations: selection.available)
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
        let queryManager: AnyObject
        let retainedTypes: [NativeSwiftType]
        let arrayMetadata: Any.Type
        let cast: NativeSwiftFunction<([Any]) throws -> NativeSwiftValue>
        let supportedRecipes: ResolvedSymbol
        let interface: OpaquePointer
        let recipe: NativeSwiftMethod<() -> NativeSwiftValue>
        let representation: NativeSwiftMethod<() -> NativeSwiftValue>
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

    private func prepareDestinations() async throws -> DestinationPreparation {
        if let destinationPreparation { return destinationPreparation }
        let pipeline = ImageSelector.path(installation.framework("PreviewsPipeline", in: "SharedFrameworks"))
        let foundation = ImageSelector.path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks"))
        let previews = ImageSelector.path(installation.framework("PreviewsXcode", in: "PlugIns"))
        let builtIn = try await runtime.resolveSwiftType(named: "PreviewsDeveloperTools.BuiltInIntegrationManager",
            in: .path(installation.framework("PreviewsDeveloperTools", in: "SharedFrameworks")))
        let getDefault = try await builtIn.resolveStaticGetter(
            named: "default.getter : PreviewsDeveloperTools.BuiltInIntegrationManager", as: (() -> NativeSwiftValue).self,
            valueABIs: [builtIn: .void])
        let resolver = try unsafe getDefault.unsafeInvoke()
        let protocolSymbol = try await runtime.resolve(
            .init(name: "protocol descriptor for PreviewsFoundationHost.QueryResolver", language: .swift, kind: .data), in: foundation)
        let protocolMetadata: Any.Type = try unsafe protocolSymbol.withUnsafeAddress {
            guard let metadata = unsafe ABISwiftProtocolTypeMetadata($0) else {
                throw NativeRuntimeError.unsupportedContract("Native QueryResolver metadata is unavailable")
            }
            return unsafe unsafeBitCast(metadata, to: Any.Type.self)
        }
        let makeResolvers = try await runtime.resolveSwiftFunction(
            named: "XcodeMCPNativeRuntime.nativePreviewArray<A>([Any]) throws -> [A]",
            as: (([Any]) throws -> NativeSwiftValue).self, genericArguments: [.type(protocolMetadata)])
        var resolverValues = try await registeredDestinationResolvers(elementMetadata: protocolMetadata, in: previews)
        resolverValues.append(try resolver.withCopy { $0 })
        let resolvers = try unsafe makeResolvers.unsafeInvoke(resolverValues)
        let queryType = try await runtime.resolveSwiftType(named: "PreviewsFoundationHost.QueryManager", in: foundation)
        let initializeQuery = try await queryType.resolveInitializer(
            named: "init(delegateManager: PreviewsFoundationHost.QueryManager?, resolvers: [PreviewsFoundationHost.QueryResolver]) -> PreviewsFoundationHost.QueryManager",
            as: ((AnyObject?, NativeSwiftValue) -> AnyObject).self)
        let query = try unsafe initializeQuery.unsafeInvoke(nil, resolvers)
        guard let destinationClass = NSClassFromString("IDERunDestination") else {
            throw NativeRuntimeError.unsupportedContract("Native IDERunDestination is unavailable")
        }
        let cast = try await runtime.resolveSwiftFunction(
            named: "XcodeMCPNativeRuntime.nativePreviewArray<A>([Any]) throws -> [A]",
            as: (([Any]) throws -> NativeSwiftValue).self, genericArguments: [.type(destinationClass)])
        let reference = try await runtime.resolveSwiftType(named: "PreviewsXcode.XcodeRunDestinationReference", in: previews)
        let pairType = try await runtime.resolveSwiftType(named: "PreviewsPipeline.RunDestinationRecipePair", in: pipeline,
            genericArguments: [.type(reference)])
        let arrayType = try await runtime.resolveSwiftType(named: "Swift.Array", genericArguments: [.type(pairType)])
        let metatype = try await runtime.resolveSwiftFunction(named: "XcodeMCPNativeRuntime.nativePreviewType<A>() -> A.Type",
            as: (() -> NativeSwiftValue).self, genericArguments: [.type(arrayType)])
        let nativeMetatype = try unsafe metatype.unsafeInvoke()
        guard let arrayMetadata = try nativeMetatype.withCopy({ $0 as? Any.Type }) else {
            throw NativeRuntimeError.unsupportedContract("Native destination Pair array metadata is unavailable")
        }
        let supported = try await runtime.resolve(.init(machOName: "_$sSl13PreviewsXcodeSo17IDERunDestinationC7ElementRtzrlE16supportedRecipes5usingSay0A8Pipeline03RunD10RecipePairVyAA0bjD9ReferenceVGG0A14FoundationHost12QueryManagerC_tFSayACG_Tg5", language: .swift), in: previews)
        let pointer = try unsafe abi.scalar(Int32(ABIValuePointer))
        let interface = try unsafe abi.callInterface(result: pointer, parameters: [pointer, pointer])
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
        let preparation = try unsafe await DestinationPreparation(queryManager: query, retainedTypes: [builtIn, queryType, arrayType],
            arrayMetadata: arrayMetadata, cast: cast, supportedRecipes: supported, interface: interface,
            recipe: getter(pairType, "recipe.getter : PreviewsPipeline.AnyRunDestinationRecipe", NativeSwiftValue.self, result: recipeType),
            representation: getter(pairType, "representation.getter : A", NativeSwiftValue.self),
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

    private func registeredDestinationResolvers(elementMetadata: Any.Type, in previews: ImageSelector) async throws -> [Any] {
        guard let managerClass = NSClassFromString("DVTPlugInManager") else {
            throw NativeRuntimeError.unsupportedContract("Native plug-in manager is unavailable")
        }
        let shared = try runtime.object(managerClass as AnyObject).resolveMethodAndWait(
            selector: "defaultPlugInManager", as: (() -> AnyObject).self)
        let manager = try unsafe shared.unsafeInvoke()
        let extensionPoint = try runtime.object(manager).resolveMethodAndWait(
            selector: "extensionPointWithIdentifier:", as: ((String) -> AnyObject?).self)
        guard let point = try unsafe extensionPoint.unsafeInvoke("Xcode.PreviewsXcode.PreviewsExtension") else { return [] }
        let registered = try runtime.object(point).resolveMethodAndWait(selector: "extensions", as: (() -> NSSet).self)
        let extensions = try unsafe registered.unsafeInvoke()
        let descriptor = try await runtime.resolve(.init(machOName: "_$s13PreviewsXcode0aB9ExtensionMp",
            language: .swift, kind: .data), in: previews)
        let getter = try await runtime.resolve(.init(machOName:
            "_$s13PreviewsXcode0aB9ExtensionP14queryResolversSay0A14FoundationHost13QueryResolver_pGvgZTj",
            language: .swift), in: previews)
        let pointer = try unsafe abi.scalar(Int32(ABIValuePointer))
        let interface = try unsafe abi.callInterface(result: pointer, parameters: [pointer, pointer])
        var resolvers: [Any] = []
        for extensionValue in extensions.allObjects {
            let getClass = try runtime.object(extensionValue as AnyObject).resolveMethodAndWait(
                selector: "valueForKey:", as: ((String) -> AnyClass?).self)
            guard let type = try unsafe getClass.unsafeInvoke("extensionClass") else { continue }
            let metadata = unsafe unsafeBitCast(type as Any.Type, to: UnsafeRawPointer.self)
            guard let witness = unsafe descriptor.withUnsafeAddress({ unsafe ABISwiftConformance(metadata, $0) }) else { continue }
            @MainActor func collect<Element>(_ type: Element.Type) throws -> [Any] {
                var metadataArgument = unsafe metadata
                var witnessArgument = unsafe witness
                // The native static requirement passes Self metadata in x0/x20,
                // its existing witness in x1, and returns an owned Array in x0.
                let values: [Element] = try withUnsafeMutablePointer(to: &metadataArgument) { metadataArgument in
                    try withUnsafeMutablePointer(to: &witnessArgument) { witnessArgument in
                        try unsafe abi.invoke(symbol: getter, interface: interface,
                            arguments: [UnsafeMutableRawPointer(metadataArgument), UnsafeMutableRawPointer(witnessArgument)],
                            context: metadata, returning: [Element].self)
                    }
                }
                return values.map { $0 as Any }
            }
            resolvers += try _openExistential(elementMetadata, do: collect)
        }
        return resolvers
    }

    private func destinations(_ available: NSArray) async throws -> [Destination] {
        let prepared = try await prepareDestinations()
        let array = try unsafe prepared.cast.unsafeInvoke(available.map { $0 })
        var arrayWord = try unsafe array.withCopy(nativePreviewArrayBridgeWordFromAny)
        var queryAddress = unsafe UnsafeRawPointer(Unmanaged.passUnretained(prepared.queryManager).toOpaque())
        // This emitted Array specialization receives QueryManager in x0 and the
        // Array bridge word in x1; it applies native sorted(nativeArch:) itself.
        let values = try withExtendedLifetime(array) {
            try withUnsafeMutablePointer(to: &arrayWord) { arrayAddress in
                try withUnsafeMutablePointer(to: &queryAddress) { queryAddress in
                    try unsafe nativePreviewInvokeDestinations(prepared.arrayMetadata, abi: abi, symbol: prepared.supportedRecipes,
                        interface: prepared.interface, arguments: [UnsafeMutableRawPointer(queryAddress), UnsafeMutableRawPointer(arrayAddress)])
                }
            }
        }
        guard let pairs = values as? [Any] else {
            throw NativeRuntimeError.unsupportedContract("Native destination recipes are not a Pair array")
        }
        return try pairs.map { pair in
            let representation = try unsafe prepared.representation.unsafeInvoke(on: pair)
            let destination = try representation.withCopy { value in
                Mirror(reflecting: value).children.first { $0.label == "runDestination" }?.value as? NSObject
            }
            guard let destination else {
                throw NativeRuntimeError.unsupportedContract("Native recipe Pair has no IDERunDestination representation")
            }
            let recipe = try unsafe prepared.recipe.unsafeInvoke(on: pair)
            return try destinationInfo(destination, recipe: recipe, prepared: prepared)
        }
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
        let available: [Destination]
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

        var renderFields: [String: JSONValue] {
            var fields: [String: JSONValue] = ["identifier": .string(previewIdentifier)]
            for (key, value) in [("platformName", platformName), ("deviceModelName", deviceModelName), ("systemVersion", systemVersion)] {
                if let value { fields[key] = .string(value) }
            }
            return fields
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

@inline(never)
package func nativePreviewType<Value>() -> Value.Type { Value.self }

@unsafe
private func nativePreviewArrayBridgeWord<Value>(_ value: Value) -> UInt {
    withUnsafePointer(to: value) { unsafe UnsafeRawPointer($0).load(as: UInt.self) }
}

@unsafe
private func nativePreviewArrayBridgeWordFromAny(_ value: Any) -> UInt {
    unsafe _openExistential(value, do: nativePreviewArrayBridgeWord)
}

@MainActor @unsafe
private func nativePreviewInvokeDestinations(_ metadata: Any.Type, abi: NativeABI, symbol: ResolvedSymbol,
                                            interface: OpaquePointer, arguments: [UnsafeMutableRawPointer?]) throws -> Any {
    @MainActor func invoke<Result>(_ type: Result.Type) throws -> Any {
        try unsafe abi.invoke(symbol: symbol, interface: interface, arguments: arguments, returning: type)
    }
    return try _openExistential(metadata, do: invoke)
}

private struct NativePreviewBuildURL: ABIBridgeSwiftValue {
    let value: URL
    static let swiftABIType: NativeType = try! .opaque(named: "Foundation.URL")
}

private struct NativePreviewBuildSources: ABIBridgeSwiftValue {
    let value: Set<URL>
    static let swiftABIType: NativeType = .pointer
}
