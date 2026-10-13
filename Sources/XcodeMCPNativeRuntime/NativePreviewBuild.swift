import ABIBridge
import Foundation

@safe
@MainActor
final class NativePreviewBuild {
    struct Result {
        let targets: [Target]
        let destinationIdentifier: String
        let platformName: String?
        let deviceModelName: String?
        let systemVersion: String?

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

        var outputURL: URL? {
            guard let index = linkCommandLine.lastIndex(of: "-o"),
                  linkCommandLine.indices.contains(index + 1) else { return nil }
            let path = linkCommandLine[index + 1]
            if path.hasPrefix("/") { return URL(filePath: path) }
            guard let linkerWorkingDirectory else { return nil }
            return URL(filePath: path, relativeTo: URL(filePath: linkerWorkingDirectory, directoryHint: .isDirectory))
                .absoluteURL
        }
    }

    private let runtime = ABIRuntime.shared
    private let installation: NativeXcodeInstallation
    private var clients: [UUID: Cancellation] = [:]
    private var performMethod: NativeSwiftMethod<@concurrent (AnyObject, AnyObject) async throws -> AnyObject>?

    init(installation: NativeXcodeInstallation) {
        self.installation = installation
    }

    func selectDestination(workspace: AnyObject, preferred: [String: String] = [:]) throws -> AnyObject? {
        guard let manager = try object(workspace, selector: "runContextManager"),
              let scheme = try object(manager, selector: "activeRunContext") else {
            throw NativeRuntimeError.invalidRequest("The workspace has no active scheme")
        }
        if preferred.isEmpty {
            guard let active = try object(manager, selector: "activeRunDestination") else { return nil }
            let destination = try destinationInfo(active)
            return destination.platformIdentifier == "com.apple.platform.iphonesimulator"
                && UUID(uuidString: destination.identifier) != nil ? active : nil
        }
        let available = try runtime.object(scheme).resolveMethodAndWait(
            selector: "availableRunDestinations", as: (() -> NSArray).self)
        let candidates = try unsafe available.unsafeInvoke().compactMap { value -> Destination? in
            let destination = try destinationInfo(value as AnyObject)
            guard destination.platformIdentifier == "com.apple.platform.iphonesimulator",
                  UUID(uuidString: destination.identifier) != nil else { return nil }
            return destination
        }
        let matches = candidates.filter { destination in
            let fields = ["identifier": destination.identifier,
                          "platformName": destination.platformName,
                          "deviceModelName": destination.deviceModelName,
                          "systemVersion": destination.systemVersion]
            return preferred.allSatisfy { key, value in fields[key] == value }
        }
        guard !matches.isEmpty else { return nil }
        if let active = try object(manager, selector: "activeRunDestination"),
           let device = try object(active, selector: "targetDevice"),
           let identifier = try optionalString(device, selector: "identifier"),
           let match = matches.first(where: { $0.identifier == identifier }) {
            return match.value
        }
        return matches.enumerated().sorted { first, second in
            let order = (first.element.systemVersion ?? "").compare(second.element.systemVersion ?? "", options: .numeric)
            return order == .orderedSame ? first.offset < second.offset : order == .orderedDescending
        }[0].element.value
    }

    func prepare(workspace: AnyObject) async throws -> NativeSwiftMethod<@concurrent (AnyObject, AnyObject) async throws -> AnyObject> {
        if let performMethod { return performMethod }
        let bound = try await runtime.object(workspace).resolveMethod(
            named: "(extension in PreviewsIDEAPI):__C.IDEWorkspace.performTask(on: __C.IDEScheme, for: __C.IDESchemeOperationParameters) async throws -> __C.DVTOperation",
            as: (@concurrent (AnyObject, AnyObject) async throws -> AnyObject).self)
        performMethod = bound.method
        return bound.method
    }

    func build(workspace: AnyObject, destination requestedDestination: AnyObject? = nil) async throws -> Result {
        try Task.checkCancellation()
        guard let manager = try object(workspace, selector: "runContextManager"),
              let scheme = try object(manager, selector: "activeRunContext"),
              let destination = try requestedDestination ?? object(manager, selector: "activeRunDestination"),
              let environment = try object(workspace, selector: "executionEnvironment") else {
            throw NativeRuntimeError.invalidRequest("The workspace has no active scheme, run destination, or execution environment")
        }
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
        let records = try await targets(descriptions, image: image)
        let info = try destinationInfo(destination)
        return Result(targets: records, destinationIdentifier: info.identifier,
                      platformName: info.platformName, deviceModelName: info.deviceModelName, systemVersion: info.systemVersion)
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

    private func targets(_ descriptions: NativeSwiftValue, image: URL) async throws -> [Target] {
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
                guard let (_, records) = entry as? (AnyObject, [Any]) else {
                    throw NativeRuntimeError.unsupportedContract("Native built target description has an unsupported tuple")
                }
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
                        debugDylibEnabled: dylib.unsafeInvoke(on: record))
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

    private func destinationInfo(_ destination: AnyObject) throws -> Destination {
        let device = try object(destination, selector: "targetDevice")
        let sdk = try object(destination, selector: "targetSDK")
        let platform = try sdk.flatMap { try object($0, selector: "platform") }
        let identifier = try optionalString(device, selector: "identifier")
            ?? optionalString(destination, selector: "targetIdentifier")
        guard let identifier else {
            throw NativeRuntimeError.unsupportedContract("The native run destination has no identifier")
        }
        let version = try object(destination, selector: "effectiveOperatingSystemVersion")
        return Destination(value: destination, identifier: identifier,
                           platformIdentifier: try optionalString(platform, selector: "identifier"),
                           platformName: try optionalString(platform, selector: "userDescription"),
                           deviceModelName: try optionalString(device, selector: "modelName"),
                           systemVersion: try optionalString(version, selector: "description"))
    }

    private struct Destination {
        let value: AnyObject
        let identifier: String
        let platformIdentifier: String?
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

private struct NativePreviewBuildURL: ABIBridgeSwiftValue {
    let value: URL
    static let swiftABIType: NativeType = try! .opaque(named: "Foundation.URL")
}

private struct NativePreviewBuildSources: ABIBridgeSwiftValue {
    let value: Set<URL>
    static let swiftABIType: NativeType = .pointer
}
