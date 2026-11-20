import ABIBridge
import Foundation

/// Reads preview definitions from a source file and builds the specifications that native preview services expect.
@MainActor
struct NativePreviewDefinitions {
    let installation: NativeXcodeInstallation

    /// A parsed preview definition and the translation unit it came from.
    struct Source {
        let translationUnit: NativeSwiftValue
        let definition: NativeSwiftValue
    }

    func sourceURL(_ path: String, workspace: AnyObject) async throws -> URL {
        do {
            let action = try await ABIRuntime.shared.resolve(
                .swift(.type("PreviewsXcode.AgenticAction")), in: .path(installation.framework("PreviewsXcode", in: "PlugIns")))
            let resolve = try await action.resolve(.swift(.staticMethod(
                "projectRelativeSourceFileURL(at: Swift.String, in: __C.IDEWorkspace) async throws -> Foundation.URL",
                as: (@concurrent (String, AnyObject) async throws -> PreviewURL).self)))
            return try unsafe await resolve.unsafeInvoke(path, workspace).value
        } catch is ABIResolutionError {
            return try await legacySourceURL(path, workspace: workspace)
        }
    }

    private func legacySourceURL(_ path: String, workspace: AnyObject) async throws -> URL {
        let type = try await ABIRuntime.shared.resolve(
            .swift(.type("PreviewsXcode.RenderPreviewAction")), in: .path(installation.framework("PreviewsXcode", in: "PlugIns")))
        let resolve = try await type.resolve(
            .swift(
                .staticMethod(
                    "(resolveSourceFileURL in _FEA7E13ECD12FBA8521281D73C9764CE)(at: Swift.String, in: __C.IDEWorkspace) async throws -> Foundation.URL",
                    as: (@concurrent (String, AnyObject) async throws -> PreviewURL).self)))
        return try unsafe await resolve.unsafeInvoke(path, workspace).value
    }

    struct Definition {
        let line: Int
        let column: Int
        let displayName: String
        let providerPath: NativeSwiftValue?
        let registry: NativeSwiftValue?
        let source: NativePreviewDefinitions.Source
    }

    func definition(in source: URL, at index: Int) async throws -> Definition {
        let runtime = ABIRuntime.shared
        let action = try await runtime.resolve(
            .swift(.type("PreviewsXcode.RenderPreviewAction")), in: .path(installation.framework("PreviewsXcode", in: "PlugIns")))
        let unit = try await runtime.resolve(
            .swift(.type("PreviewsPipeline.PreviewTranslationUnit")), in: .path(installation.framework("PreviewsPipeline", in: "SharedFrameworks")))
        let parsed: NativeSwiftValue
        do {
            let parse = try await action.resolve(.swift(.staticMethod(
                "parseTranslationUnit(sourceFileURL: Foundation.URL) async throws -> (translationUnit: PreviewsPipeline.PreviewTranslationUnit, previews: [PreviewsXcode.RenderPreviewAction.RenderPreviewType])",
                as: (@concurrent (PreviewURL) async throws -> NativeSwiftValue).self, valueABIs: [unit: .opaque(named: unit.name)])))
            parsed = try unsafe await parse.unsafeInvoke(PreviewURL(value: source))
        } catch is ABIResolutionError {
            do {
                let parse = try await action.resolve(.swift(.staticMethod(
                    "parseTranslationUnit(sourceFileURL: Foundation.URL) throws -> (translationUnit: PreviewsPipeline.PreviewTranslationUnit, previews: [PreviewsXcode.RenderPreviewAction.RenderPreviewType])",
                    as: ((PreviewURL) throws -> NativeSwiftValue).self, valueABIs: [unit: .opaque(named: unit.name)])))
                parsed = try unsafe parse.unsafeInvoke(PreviewURL(value: source))
            } catch is ABIResolutionError {
                let parse = try await action.resolve(.swift(.staticMethod(
                    "(parseTranslationUnit in _FEA7E13ECD12FBA8521281D73C9764CE)(sourceFileURL: Foundation.URL) throws -> (translationUnit: PreviewsPipeline.PreviewTranslationUnit, previews: [PreviewsXcode.RenderPreviewAction.(RenderPreviewType in _FEA7E13ECD12FBA8521281D73C9764CE)])",
                    as: ((PreviewURL) throws -> NativeSwiftValue).self, valueABIs: [unit: .opaque(named: unit.name)])))
                parsed = try unsafe parse.unsafeInvoke(PreviewURL(value: source))
            }
        }
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
            let identity = try await runtime.resolve(
                .swift(.function("XcodeMCPNativeRuntime.nativePreviewValue<A>(A) -> A", as: ((T) -> NativeSwiftValue).self, genericArguments: [.type(T.self)])))
            return try unsafe identity.unsafeInvoke(value)
        }
        let model = ImageSelector.path(installation.framework("PreviewsModel", in: "SharedFrameworks"))
        let locationType = try await runtime.resolve(.swift(.type("PreviewsModel.SourceLocation")), in: model)
        let boundType = try await runtime.resolve(.swift(.type("PreviewsModel.SourceLocation.Bound")), in: model)
        let pathType = try await runtime.resolve(.swift(.type("PreviewsModel.MangleableTypePath")), in: model)
        let syntaxType = try await runtime.resolve(.swift(.type("PreviewsModel.SyntaxLocation")), in: model)
        let contents = try String(contentsOf: source, encoding: .utf8)
        var definitions: [Definition] = []
        for value in previews {
            let definition = try await _openExistential(value, do: own)
            let record: NativeSwiftValue
            let location: NativeSwiftValue
            let displayName: String
            let providerPath: NativeSwiftValue?
            let registryRecord: NativeSwiftValue?
            if let provider = try await definition.copyEnumPayload(forCase: "previewProvider") {
                record = provider
                registryRecord = nil
                let getPath = try await provider.type.resolve(
                    .swift(
                        .getter(
                            "path", as: (() -> NativeSwiftValue).self, valueABIs: [pathType: .opaque(named: pathType.name)],
                            receiverABI: .opaque(named: provider.type.name))))
                providerPath = try unsafe getPath.unsafeInvoke(on: provider)
                let getSyntax = try await provider.type.resolve(
                    .swift(
                        .getter(
                            "location", as: (() -> NativeSwiftValue).self, valueABIs: [syntaxType: .opaque(named: syntaxType.name)],
                            receiverABI: .opaque(named: provider.type.name))))
                let syntax = try unsafe getSyntax.unsafeInvoke(on: provider)
                let getLocation = try await syntax.type.resolve(
                    .swift(
                        .getter(
                            "locationExcludingTrivia", as: (() -> NativeSwiftValue).self, valueABIs: [locationType: .opaque(named: locationType.name)],
                            receiverABI: .opaque(named: syntax.type.name))))
                location = try unsafe getLocation.unsafeInvoke(on: syntax)
                let getName = try await provider.type.resolve(
                    .swift(.getter("displayName", as: (() -> String).self, receiverABI: .opaque(named: provider.type.name))))
                displayName = try unsafe getName.unsafeInvoke(on: provider)
            } else if let registry = try await definition.copyEnumPayload(forCase: "registryPreview") {
                record = registry
                registryRecord = registry
                providerPath = nil
                let getName = try await registry.type.resolve(
                    .swift(
                        .getter(
                            "(extension in PreviewsPipeline):PreviewsModel.RegistryDefinition.defaultDisplayName.getter : Swift.String",
                            as: (() -> String).self, receiverABI: .opaque(named: registry.type.name))))
                displayName = try unsafe getName.unsafeInvoke(on: registry)
                let getLocation = try await registry.type.resolve(
                    .swift(
                        .getter(
                            "fullSourceLocation", as: (() -> NativeSwiftValue).self, valueABIs: [locationType: .opaque(named: locationType.name)],
                            receiverABI: .opaque(named: registry.type.name))))
                location = try unsafe getLocation.unsafeInvoke(on: registry)
            } else { throw NativePipelineRequired() }
            let getLine = try await record.type.resolve(.swift(.getter("lineNumber", as: (() -> Int).self, receiverABI: .opaque(named: record.type.name))))
            let line = try unsafe getLine.unsafeInvoke(on: record)
            let getBound = try await location.type.resolve(
                .swift(
                    .getter(
                        "lowerBound", as: (() -> NativeSwiftValue).self, valueABIs: [boundType: .opaque(named: boundType.name)],
                        receiverABI: .opaque(named: location.type.name))))
            let bound = try unsafe getBound.unsafeInvoke(on: location)
            let getColumn = try await bound.type.resolve(.swift(.getter("column", as: (() -> Int).self, receiverABI: .opaque(named: bound.type.name))))
            let column = try unsafe getColumn.unsafeInvoke(on: bound)
            definitions.append(Definition(line: line, column: try Self.registryColumn(in: contents, line: line, utf16Column: column),
                displayName: displayName, providerPath: providerPath, registry: registryRecord,
                source: .init(translationUnit: translationUnit, definition: definition)))
        }
        // The parser returns providers and registries in separate batches. The
        // native tool selects definitions in source order, including mixed files.
        return definitions.sorted { ($0.line, $0.column) < ($1.line, $1.column) }[index]
    }

    func registrySpecification(registry: NativeSwiftValue, moduleName: String) async throws -> Data {
        let runtime = ABIRuntime.shared
        let model = ImageSelector.path(installation.framework("PreviewsModel", in: "SharedFrameworks"))
        let messaging = ImageSelector.path(installation.framework("PreviewsMessagingHost", in: "SharedFrameworks"))
        let optionalUUID = try await runtime.resolve(.swift(.type("Swift.Optional", genericArguments: [.type(UUID.self)])))
        let getSidecar = try await registry.type.resolve(
            .swift(
                .getter(
                    "sidecarIdentifier.getter : Swift.Optional<Foundation.UUID>", as: (() -> NativeSwiftValue).self,
                    valueABIs: [optionalUUID: .opaque(named: optionalUUID.name)], receiverABI: .opaque(named: registry.type.name))))
        let sidecar = try unsafe getSidecar.unsafeInvoke(on: registry)
        guard try await sidecar.copyEnumPayload(forCase: "some") == nil else { throw NativePipelineRequired() }
        let idType = try await runtime.resolve(.swift(.type("PreviewsMessagingHost.RegistryID")), in: messaging)
        let getID = try await registry.type.resolve(
            .swift(
                .getter(
                    "id.getter : PreviewsMessagingHost.RegistryID", as: (() -> NativeSwiftValue).self, valueABIs: [idType: .opaque(named: idType.name)],
                    receiverABI: .opaque(named: registry.type.name))))
        let id = try unsafe getID.unsafeInvoke(on: registry)
        let moduleType = try await runtime.resolve(.swift(.type("PreviewsModel.Module")), in: model)
        let initializeModule = try await moduleType.resolve(
            .swift(
                .initializer(
                    "init(name: Swift.String) -> PreviewsModel.Module", as: ((String) -> NativeSwiftValue).self,
                    valueABIs: [moduleType: .opaque(named: moduleType.name)])))
        let module = try unsafe initializeModule.unsafeInvoke(moduleName)
        let locationType = try await runtime.resolve(.swift(.type("PreviewsMessagingHost.RuntimeRegistryLocation")), in: messaging)
        let locate = try await registry.type.resolve(
            .swift(
                .method(
                    "runtimeLocation(in: PreviewsModel.Module) -> PreviewsMessagingHost.RuntimeRegistryLocation",
                    as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                    valueABIs: [moduleType: .opaque(named: moduleType.name), locationType: .opaque(named: locationType.name)],
                    receiverABI: .opaque(named: registry.type.name))))
        let location = try unsafe locate.unsafeInvoke(on: registry, module)
        let specificationType = try await runtime.resolve(.swift(.type("PreviewsMessagingHost.PreviewSpecification")), in: messaging)
        let makeSpecification = try await specificationType.resolve(
            .swift(
                .staticMethod(
                    "registryPreview(stableID: PreviewsMessagingHost.RegistryID, location: PreviewsMessagingHost.RuntimeRegistryLocation) -> PreviewsMessagingHost.PreviewSpecification",
                    as: ((NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
                    valueABIs: [
                        idType: .opaque(named: idType.name), locationType: .opaque(named: locationType.name),
                        specificationType: .opaque(named: specificationType.name),
                    ])))
        let specification = try unsafe makeSpecification.unsafeInvoke(id, location)
        return try await previewSpecificationData(specification)
    }

    func providerSpecification(name: String, description: NativeSwiftValue) async throws -> Data {
        let runtime = ABIRuntime.shared
        let messaging = ImageSelector.path(installation.framework("PreviewsMessagingHost", in: "SharedFrameworks"))
        let providerType = try await runtime.resolve(.swift(.type("PreviewsMessagingHost.ProviderPayload")), in: messaging)
        let makeProvider = try await providerType.resolve(
            .swift(
                .initializer(
                    "init(providerName: Swift.String) -> PreviewsMessagingHost.ProviderPayload", as: ((String) -> NativeSwiftValue).self,
                    valueABIs: [providerType: .opaque(named: providerType.name)])))
        let provider = try unsafe makeProvider.unsafeInvoke(name)
        let getIndex = try await description.type.resolve(
            .swift(.getter("index.getter : Swift.Int", as: (() -> Int).self, receiverABI: .opaque(named: description.type.name))))
        let index = try unsafe getIndex.unsafeInvoke(on: description)
        let specificationType = try await runtime.resolve(.swift(.type("PreviewsMessagingHost.PreviewSpecification")), in: messaging)
        let makeSpecification = try await specificationType.resolve(
            .swift(
                .staticMethod(
                    "providerPreview(provider: PreviewsMessagingHost.ProviderPayload, indexInProvider: Swift.Int) -> PreviewsMessagingHost.PreviewSpecification",
                    as: ((NativeSwiftValue, Int) -> NativeSwiftValue).self,
                    valueABIs: [providerType: .opaque(named: providerType.name), specificationType: .opaque(named: specificationType.name)])))
        let specification = try unsafe makeSpecification.unsafeInvoke(provider, index)
        return try await previewSpecificationData(specification)
    }

    private func previewSpecificationData(_ specification: NativeSwiftValue) async throws -> Data {
        let runtime = ABIRuntime.shared
        let foundation = ImageSelector.path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks"))
        let propertyListType = try await runtime.resolve(.swift(.type("PreviewsFoundationHost.PropertyList")), in: foundation)
        let encode = try await specification.type.resolve(
            .swift(
                .getter(
                    "propertyListValue.getter : PreviewsFoundationHost.PropertyList", as: (() -> NativeSwiftValue).self,
                    valueABIs: [propertyListType: .opaque(named: propertyListType.name)], receiverABI: .opaque(named: specification.type.name))))
        let propertyList = try unsafe encode.unsafeInvoke(on: specification)
        let dictionaryType = try await runtime.resolve(.swift(.type("Swift.Dictionary", genericArguments: [.type(String.self), .type(Any.self)])))
        let serialize = try await propertyListType.resolve(
            .swift(
                .getter(
                    "serializableDictionary.getter : [Swift.String : Any]", as: (() -> NativeSwiftValue).self, valueABIs: [dictionaryType: .pointer],
                    receiverABI: .opaque(named: propertyListType.name))))
        let dictionary = try unsafe serialize.unsafeInvoke(on: propertyList)
        return try dictionary.withCopy { value in
            guard let dictionary = value as? [String: Any] else {
                throw NativeRuntimeError.unsupportedContract("Native preview specification is not a property list dictionary")
            }
            return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        }
    }

    func providerTypeName(path: NativeSwiftValue, moduleName: String) async throws -> String {
        let model = ImageSelector.path(installation.framework("PreviewsModel", in: "SharedFrameworks"))
        let type = try await ABIRuntime.shared.resolve(.swift(.type("PreviewsModel.Module")), in: model)
        let initialize = try await type.resolve(
            .swift(
                .initializer(
                    "init(name: Swift.String) -> PreviewsModel.Module", as: ((String) -> NativeSwiftValue).self, valueABIs: [type: .opaque(named: type.name)])))
        let module = try unsafe initialize.unsafeInvoke(moduleName)
        let mangle = try await path.type.resolve(
            .swift(
                .method(
                    "mangledName(in: PreviewsModel.Module) -> Swift.String", as: ((NativeSwiftValue) -> String).self,
                    valueABIs: [type: .opaque(named: type.name)], receiverABI: .opaque(named: path.type.name))))
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
}

private struct PreviewURL: ABIBridgeSwiftValue {
    let value: URL
    static let swiftABIType: NativeType = try! .opaque(named: "Foundation.URL")
}
