import ABIBridge
import ABIBridgeCore
import ABIBridgeCore.Backend
import Foundation
import XcodeMCPWire

/// Resolves and selects a preview's render destination, and captures the planning context that a reused build must still match.
@safe
@MainActor
final class NativePreviewDestinations {
    private let runtime = ABIRuntime.shared
    private let installation: NativeXcodeInstallation

    init(installation: NativeXcodeInstallation) {
        self.installation = installation
    }

    private var destinationPreparation: DestinationPreparation?

    private var sourceSelections: [ObjectIdentifier: [SourceSelectionWaiter]] = [:]

    private struct SourceSelectionWaiter {
        let identifier: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    func planningContext(workspace: AnyObject, destination: Selection? = nil) throws -> PlanningContext {
        guard let manager = try NativeObjCGetters.object(workspace, selector: "runContextManager"),
              let scheme = try NativeObjCGetters.object(manager, selector: "activeRunContext"),
              let environment = try NativeObjCGetters.object(workspace, selector: "executionEnvironment") else {
            throw NativeRuntimeError.invalidRequest("The workspace has no active scheme, run destination, or execution environment")
        }
        return try PlanningContext(scheme: scheme, schemeIdentifier: NativeObjCGetters.object(scheme, selector: "schemeIdentifier") as? NSObject,
            environment: environment, activeDestination: destinationContext(NativeObjCGetters.object(manager, selector: "activeRunDestination")),
            destination: destinationContext(destination?.selected.value))
    }



    private func destinationContext(_ destination: AnyObject?) throws -> DestinationContext? {
        guard let destination else { return nil }
        let device = try NativeObjCGetters.object(destination, selector: "targetDevice")
        let sdk = try NativeObjCGetters.object(destination, selector: "targetSDK")
        let variant = try NativeObjCGetters.object(destination, selector: "targetSDKVariant")
        let hostPlatform = try NativeObjCGetters.object(destination, selector: "hostTargetedPlatform")
        let available: Bool?
        if let device {
            let get = try runtime.object(device).resolveAndWait(.objc(.method("isAvailable", as: (() -> Bool).self)))
            available = try unsafe get.unsafeInvoke()
        } else { available = nil }
        return try DestinationContext(identifier: NativeObjCGetters.optionalString(device, selector: "identifier")
                ?? NativeObjCGetters.optionalString(destination, selector: "targetIdentifier"),
            architecture: NativeObjCGetters.optionalString(destination, selector: "targetArchitecture"),
            sdk: NativeObjCGetters.optionalString(sdk, selector: "canonicalName"), variant: NativeObjCGetters.optionalString(variant, selector: "name"),
            hostPlatform: NativeObjCGetters.optionalString(hostPlatform, selector: "identifier"),
            runtimeVersion: NativeObjCGetters.optionalString(device, selector: "operatingSystemVersion"), available: available)
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
        let recipeType = try await runtime.resolve(.swift(.type("PreviewsPipeline.AnyRunDestinationRecipe")), in: pipeline)
        let propertiesType = try await runtime.resolve(.swift(.type("PreviewsPipeline.RunDestinationProperties")), in: pipeline)
        let platformType = try await runtime.resolve(.swift(.type("PreviewsPipeline.Platform")), in: pipeline)
        let identifierType = try await runtime.resolve(.swift(.type("PreviewsPipeline.DeviceIdentifier")), in: pipeline)
        let versionType = try await runtime.resolve(.swift(.type("PreviewsFoundationHost.VersionNumber")), in: foundation)
        func getter<Value>(_ type: NativeSwiftType, _ declaration: String, _ value: Value.Type,
                           result: NativeSwiftType? = nil) async throws -> NativeSwiftMethod<() -> Value> {
            try await type.resolve(
                .swift(
                    .getter(
                        declaration, as: (() -> Value).self, valueABIs: try result.map { [$0: try NativeType.opaque(named: $0.name)] } ?? [:],
                        receiverABI: .opaque(named: type.name))))
        }
        let preparation = try await DestinationPreparation(
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
        let device = try NativeObjCGetters.object(destination, selector: "targetDevice")
        let sdk = try NativeObjCGetters.object(destination, selector: "targetSDK")
        let platform = try sdk.flatMap { try NativeObjCGetters.object($0, selector: "platform") }
        let identifier = try NativeObjCGetters.optionalString(device, selector: "identifier")
            ?? NativeObjCGetters.optionalString(destination, selector: "targetIdentifier")
        guard let identifier else {
            throw NativeRuntimeError.unsupportedContract("The native run destination has no identifier")
        }
        let platformIdentifier = try NativeObjCGetters.optionalString(platform, selector: "identifier")
        let isMacCatalyst: Bool
        if platformIdentifier == "com.apple.platform.macosx" {
            let getter = try runtime.object(destination).resolveAndWait(.objc(.method("isMacCatalyst", as: (() -> Bool).self)))
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

    struct Resolution {
        fileprivate let host: AnyObject
        fileprivate let preferences: NativeSwiftValue
        let available: JSONValue?
        let errors: [String]
    }

    struct Selection {
        let selected: Destination
        let resolution: Resolution

        var available: JSONValue? { resolution.available }
        var errors: [String] { resolution.errors }

        /// The workspace builder that Xcode cached on the preview host for this selection.
        func workspaceBuilder() throws -> AnyObject? {
            guard let field = Mirror(reflecting: resolution.host).children.first(where: { $0.label == "lastWorkspaceBuilder" }) else {
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

    func frameworkAgent(for destination: Selection) async throws -> URL {
        try Task.checkCancellation()
        let recipe = destination.selected.recipe
        let bundleType = try await runtime.resolve(
            .swift(.type("PreviewsPipeline.PreviewAgentBundle")), in: .path(installation.framework("PreviewsPipeline", in: "SharedFrameworks")))
        let make = try await recipe.type.resolve(
            .swift(
                .method(
                    "makeFrameworkAgent() throws -> PreviewsPipeline.PreviewAgentBundle", as: (() throws -> NativeSwiftValue).self,
                    valueABIs: [bundleType: .opaque(named: bundleType.name)], receiverABI: .opaque(named: recipe.type.name))))
        let bundle = try unsafe make.unsafeInvoke(on: recipe)
        let url = try await bundleType.resolve(
            .swift(.getter("url.getter : Foundation.URL", as: (() -> NativePreviewBuildURL).self, receiverABI: .opaque(named: bundleType.name))))
        try Task.checkCancellation()
        return try unsafe url.unsafeInvoke(on: bundle).value
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

    func resolveDestination(workspace: AnyObject, input: NativeSwiftValue) async throws -> Resolution {
        try Task.checkCancellation()
        let previews = ImageSelector.path(installation.framework("PreviewsXcode", in: "PlugIns"))
        let createHost = try await runtime.object(workspace).resolve(
            .swift(
                .method(
                    "(extension in PreviewsXcode):__C.IDEWorkspace.sceneHost(isNewProjectFromTemplate: Swift.Bool) -> PreviewsXcode.XcodeWorkspaceSceneHost",
                    as: ((Bool) -> AnyObject).self)))
        let host = try unsafe createHost.unsafeInvoke(false)
        let resolutionType: NativeSwiftType
        do {
            resolutionType = try await runtime.resolve(.swift(.type("PreviewsXcode.RenderPreviewAction.DestinationResolution")), in: previews)
        } catch is ABIResolutionError {
            return try await currentDestinationResolution(host: host, input: input)
        }
        let actionType = try await runtime.resolve(.swift(.type("PreviewsXcode.RenderPreviewAction")), in: previews)
        let resolve = try await actionType.resolve(
            .swift(
                .staticMethod(
                    "static PreviewsXcode.RenderPreviewAction.resolveDestination(input: PreviewsXcode.RenderPreviewAction.Input, sceneHost: PreviewsXcode.XcodeWorkspaceSceneHost) async -> PreviewsXcode.RenderPreviewAction.DestinationResolution",
                    as: (@concurrent (NativeSwiftValue, AnyObject) async -> NativeSwiftValue).self,
                    valueABIs: [input.type: .opaque(named: input.type.name), resolutionType: .opaque(named: resolutionType.name)])))
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
        return Resolution(host: host, preferences: preferences,
            available: availableJSON == .null ? nil : availableJSON, errors: errors)
    }

    private func currentDestinationResolution(host: AnyObject, input: NativeSwiftValue) async throws -> Resolution {
        let image = ImageSelector.path(installation.framework("PreviewsXcode", in: "PlugIns"))
        let resolver = try await runtime.resolve(.swift(.type("PreviewsXcode.RenderPreviewAction.RenderDestinationResolver")), in: image)
        let recipe = try await runtime.resolve(.swift(.type("PreviewsPipeline.AnyRunDestinationRecipe")),
            in: .path(installation.framework("PreviewsPipeline", in: "SharedFrameworks")))
        let array = try await runtime.resolve(.swift(.type("Swift.Array", genericArguments: [.type(recipe)])))
        // The catalog wrappers have only optimizer-specialized entry points.
        // Keep their native feature gate and use the scene host's callable API.
        let offersChoice = UserDefaults.standard.object(forKey: "UVRenderPreviewOffersRenderDestinationChoice") as? Bool ?? true
        guard offersChoice else {
            let preferences = try await runtime.resolve(.swift(.type("PreviewsPipeline.DestinationPreferences")),
                in: .path(installation.framework("PreviewsPipeline", in: "SharedFrameworks")))
            let empty = try await preferences.resolve(.swift(.staticGetter("empty",
                as: (() -> NativeSwiftValue).self, valueABIs: [preferences: .opaque(named: preferences.name)])))
            return Resolution(host: host, preferences: try unsafe empty.unsafeInvoke(), available: nil, errors: [])
        }
        let timeoutType = try await runtime.resolve(.swift(.type("PreviewsFoundationHost.Timeout")),
            in: .path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks")))
        let makeTimeout = try await timeoutType.resolve(.swift(.staticMethod("seconds(_:)",
            as: ((Double) -> NativeSwiftValue).self, valueABIs: [timeoutType: .opaque(named: timeoutType.name)])))
        let timeout = try unsafe makeTimeout.unsafeInvoke(10)
        let catalog = try await runtime.object(host).resolve(.swift(.method(
            "(awaitAvailableRunDestinations in _8779CD8E26326606F5A569AC41E16EDA)(timeout: PreviewsFoundationHost.Timeout) async -> [PreviewsPipeline.AnyRunDestinationRecipe]",
            as: (@concurrent (NativeSwiftValue) async -> NativeSwiftValue).self,
            valueABIs: [timeoutType: .opaque(named: timeoutType.name), array: .pointer])))
        let nativeCatalog = try unsafe await catalog.unsafeInvoke(timeout)
        let prepared = try await prepareDestinationProperties()
        let platform = try await runtime.resolve(.swift(.type("PreviewsPipeline.Platform")),
            in: .path(installation.framework("PreviewsPipeline", in: "SharedFrameworks")))
        let canonicalIdentifier = try await platform.resolve(.swift(.getter("canonicalIdentifier",
            as: (() -> String).self, receiverABI: .opaque(named: platform.name))))
        func catalogValues<Recipes: Collection>(_ values: Recipes) async throws -> (NativeSwiftValue, JSONValue) {
            var filtered: [Recipes.Element] = []
            var external: [JSONValue] = []
            for value in values {
                let native = try await nativePreviewOwnedValue(value)
                let properties = try unsafe prepared.properties.unsafeInvoke(on: native)
                let nativePlatform = try unsafe prepared.platform.unsafeInvoke(on: properties)
                let identifier = try unsafe canonicalIdentifier.unsafeInvoke(on: nativePlatform)
                guard !["xros", "xrsimulator"].contains(identifier) else { continue }
                filtered.append(value)
                let nativeIdentifier = try unsafe prepared.identifier.unsafeInvoke(on: properties)
                let version = try unsafe prepared.version.unsafeInvoke(on: properties)
                var item: [String: JSONValue] = try unsafe [
                    "identifier": .string(prepared.identifierString.unsafeInvoke(on: nativeIdentifier)),
                    "platformName": .string(prepared.platformName.unsafeInvoke(on: nativePlatform)),
                    "systemVersion": .string(prepared.versionString.unsafeInvoke(on: version)),
                ]
                if let model = try unsafe prepared.model.unsafeInvoke(on: properties)
                    ?? prepared.name.unsafeInvoke(on: properties) ?? prepared.specifier.unsafeInvoke(on: properties) {
                    item["deviceModelName"] = .string(model)
                }
                external.append(.object(item))
            }
            return (try await nativePreviewOwnedValue(filtered), .array(external))
        }
        let values = try nativeCatalog.withCopy { value in
            guard let values = value as? any Collection else {
                throw NativeRuntimeError.unsupportedContract("Native preview destination catalog is not a collection")
            }
            return values
        }
        let (recipes, available) = try await _openExistential(values, do: catalogValues)
        let preferred = try input.withCopy { value in
            guard let field = Mirror(reflecting: value).children.first(where: { $0.label == "preferredRenderDestination" }) else {
                throw NativeRuntimeError.unsupportedContract("Native preview input has no render destination selection")
            }
            return field.value
        }
        let selection = try await _openExistential(preferred, do: nativePreviewOwnedValue)
        let resolutionType = try await runtime.resolve(.swift(.type("PreviewsXcode.RenderPreviewAction.RenderDestinationResolver.Resolution")), in: image)
        let resolve = try await resolver.resolve(.swift(.staticMethod("resolve(selection:catalog:)",
            as: ((NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [selection.type: .opaque(named: selection.type.name), recipes.type: .pointer,
                        resolutionType: .opaque(named: resolutionType.name)])))
        let resolution = try unsafe resolve.unsafeInvoke(selection, recipes)
        let fields = try resolution.withCopy { Dictionary(uniqueKeysWithValues: Mirror(reflecting: $0).children.compactMap {
            field in field.label.map { ($0, field.value) }
        }) }
        guard let rawPreferences = fields["selection"] else {
            throw NativeRuntimeError.unsupportedContract("Native preview destination resolution has no preferences")
        }
        let preferences = try await _openExistential(rawPreferences, do: nativePreviewOwnedValue)
        guard let nativeErrors = fields["errors"] as? any Encodable else {
            throw NativeRuntimeError.unsupportedContract("Native preview destination resolution has no encodable errors")
        }
        struct Message: Decodable { var message: String }
        let errors = try JSONDecoder().decode([Message].self, from: JSONEncoder().encode(nativeErrors)).map(\.message)
        return Resolution(host: host, preferences: preferences, available: available, errors: errors)
    }

    func destinationResolution(_ lhs: Resolution, matches rhs: Resolution) async throws -> Bool {
        guard lhs.available == rhs.available, lhs.errors == rhs.errors else { return false }
        let type = lhs.preferences.type
        let equals = try await type.resolve(
            .swift(
                .staticMethod(
                    "== infix(PreviewsPipeline.DestinationPreferences, PreviewsPipeline.DestinationPreferences) -> Swift.Bool",
                    as: ((NativeSwiftValue, NativeSwiftValue) -> Bool).self, valueABIs: [type: .opaque(named: type.name)])))
        return try unsafe equals.unsafeInvoke(lhs.preferences, rhs.preferences)
    }

    func selectDestination(workspace: AnyObject, source: NativePreviewDefinitions.Source, resolution: Resolution,
                           metadata: Data? = nil, providerDescription: Data? = nil) async throws -> Selection {
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
            let recipeType = try await runtime.resolve(
                .swift(.type("PreviewsPipeline.AnyRunDestinationRecipe")), in: .path(installation.framework("PreviewsPipeline", in: "SharedFrameworks")))
            let recipe = try await sourceGetter(record, "destination.getter : PreviewsPipeline.AnyRunDestinationRecipe", resultType: recipeType)
            let representation = try await sourceGetter(record, "destinationRepresentation.getter : C", resultType: plan.referenceType)
            guard let destination = try representation.withCopy({
                Mirror(reflecting: $0).children.first { $0.label == "runDestination" }?.value as? NSObject
            }) else { throw NativeRuntimeError.unsupportedContract("Native preview plan has no IDERunDestination representation") }
            let selected = try destinationInfo(destination, recipe: recipe, prepared: prepared)
            guard NativePreviewPlatform.supportsDestination(platformIdentifier: selected.platformIdentifier, identifier: selected.identifier) else {
                throw NativePipelineRequired()
            }
            return Selection(selected: selected, resolution: resolution)
        }
    }

    private func sourceGetter(_ value: NativeSwiftValue, _ name: String, resultType: NativeSwiftType,
                              resultABI: NativeType? = nil) async throws -> NativeSwiftValue {
        let getter = try await value.type.resolve(
            .swift(
                .getter(
                    name, as: (() -> NativeSwiftValue).self, valueABIs: [resultType: try resultABI ?? .opaque(named: resultType.name)],
                    receiverABI: .opaque(named: value.type.name))))
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
        let domainType = try await runtime.resolve(
            .swift(.type("PreviewsMessagingHost.PreviewContentDomain")), in: .path(installation.framework("PreviewsMessagingHost", in: "SharedFrameworks")))
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
        let propertyListType = try await runtime.resolve(
            .swift(.type("PreviewsFoundationHost.PropertyList")), in: .path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks")))
        let nativeDictionary = try await nativePreviewOwnedValue(dictionary)
        let makePropertyList = try await propertyListType.resolve(
            .swift(
                .initializer(
                    "init(serializableDictionary:)", as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                    valueABIs: [nativeDictionary.type: .pointer, propertyListType: .opaque(named: propertyListType.name)])))
        let propertyList = try unsafe makePropertyList.unsafeInvoke(nativeDictionary)
        let metadataType = try await runtime.resolve(
            .swift(.type("PreviewsMessagingHost.\(name)")), in: .path(installation.framework("PreviewsMessagingHost", in: "SharedFrameworks")))
        let decode = try await metadataType.resolve(
            .swift(
                .initializer(
                    "init(propertyListValue: PreviewsFoundationHost.PropertyList) throws -> \(metadataType.name)",
                    as: ((NativeSwiftValue) throws -> NativeSwiftValue).self,
                    valueABIs: [propertyListType: .opaque(named: propertyListType.name), metadataType: .opaque(named: metadataType.name)])))
        return try unsafe decode.unsafeInvoke(propertyList)
    }

    private func effectivePreferences(_ operation: NativeSwiftValue, instance: NativeSwiftValue) async throws -> NativeSwiftValue {
        let type = operation.type
        let emptyGetter = try await type.resolve(
            .swift(
                .staticGetter(
                    "empty.getter : PreviewsPipeline.DestinationPreferences", as: (() -> NativeSwiftValue).self, valueABIs: [type: .opaque(named: type.name)])))
        let empty = try unsafe emptyGetter.unsafeInvoke()
        let equals = try await type.resolve(
            .swift(
                .staticMethod(
                    "== infix(PreviewsPipeline.DestinationPreferences, PreviewsPipeline.DestinationPreferences) -> Swift.Bool",
                    as: ((NativeSwiftValue, NativeSwiftValue) -> Bool).self, valueABIs: [type: .opaque(named: type.name)])))
        guard try unsafe equals.unsafeInvoke(operation, empty) else { return try operation.copy() }
        let getter = try await instance.type.resolve(
            .swift(
                .getter(
                    "PreviewsPipeline.PreviewInstanceProtocol.destinationPreferences.getter : PreviewsPipeline.DestinationPreferences",
                    as: (() -> NativeSwiftValue).self, valueABIs: [type: .opaque(named: type.name)])))
        return try unsafe getter.unsafeInvoke(on: instance)
    }

    private func executionPointPack(source: NativePreviewDefinitions.Source, preferences: NativeSwiftValue,
                                    metadata: NativeSwiftValue?, providerDescription: NativeSwiftValue?) async throws -> NativeSwiftValue? {
        let pipeline = ImageSelector.path(installation.framework("PreviewsPipeline", in: "SharedFrameworks"))
        let executionSource: NativeSwiftValue
        let role: NativeSwiftValue
        let effectivePreferences: NativeSwiftValue
        if let definition = try await source.definition.copyEnumPayload(forCase: "registryPreview") {
            let instanceType = try await runtime.resolve(.swift(.type("PreviewsPipeline.PreviewInstance")), in: pipeline)
            let makeInstance = try await instanceType.resolve(
                .swift(
                    .staticMethod(
                        "registryPreview(definition: PreviewsModel.RegistryDefinition) -> PreviewsPipeline.PreviewInstance",
                        as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                        valueABIs: [definition.type: .opaque(named: definition.type.name), instanceType: .opaque(named: instanceType.name)])))
            let instance = try unsafe makeInstance.unsafeInvoke(definition.copy())
            let registryType = try await runtime.resolve(.swift(.type("PreviewsPipeline.RegistryPreviewInstance")), in: pipeline)
            let optionalType = try await runtime.resolve(.swift(.type("Swift.Optional", genericArguments: [.type(registryType)])))
            let registryGetter = try await instanceType.resolve(
                .swift(
                    .getter(
                        "registryInstance.getter : PreviewsPipeline.RegistryPreviewInstance?", as: (() -> NativeSwiftValue).self,
                        valueABIs: [optionalType: .opaque(named: optionalType.name)], receiverABI: .opaque(named: instanceType.name))))
            let optional = try unsafe registryGetter.unsafeInvoke(on: instance)
            guard let registry = try await optional.copyEnumPayload(forCase: "some") else {
                throw NativeRuntimeError.unsupportedContract("Native preview factory produced no registry instance")
            }
            func requirement(_ name: String, output: String) async throws -> NativeSwiftValue {
                let type = try await runtime.resolve(.swift(.type(output)))
                let get = try await registry.type.resolve(
                    .swift(
                        .getter(
                            "PreviewsPipeline.PreviewInstanceProtocol.\(name).getter : \(output)", as: (() -> NativeSwiftValue).self,
                            valueABIs: [type: .opaque(named: type.name)])))
                return try unsafe get.unsafeInvoke(on: registry)
            }
            executionSource = try await requirement("source", output: "PreviewsPipeline.ExecutionPointSource")
            role = try await requirement("agentRole", output: "PreviewsMessagingHost.PreviewAgentRole")
            if metadata != nil { effectivePreferences = try await self.effectivePreferences(preferences, instance: registry) }
            else { effectivePreferences = preferences }
        } else if let definition = try await source.definition.copyEnumPayload(forCase: "previewProvider") {
            let identifierType = try await runtime.resolve(.swift(.type("PreviewsModel.SourceIdentifier")))
            let identifier = try await sourceGetter(definition, "sourceIdentifier.getter : PreviewsModel.SourceIdentifier", resultType: identifierType)
            let sourceType = try await runtime.resolve(.swift(.type("PreviewsPipeline.ExecutionPointSource")), in: pipeline)
            executionSource = try await sourceType.makeEnumCase(named: "sourceFile", payload: identifier)
            let roleType = try await runtime.resolve(.swift(.type("PreviewsMessagingHost.PreviewAgentRole")))
            role = try roleType.makeEnumCase(named: "previews")
            if metadata != nil {
                guard let providerDescription else {
                    throw NativeRuntimeError.invocation("The evaluated provider returned no native preview description")
                }
                let providerSourceType = try await runtime.resolve(.swift(.type("PreviewsPipeline.ProviderSource")), in: pipeline)
                let providerSource = try await providerSourceType.makeEnumCase(named: "provider", payload: definition.copy())
                let providerType = try await runtime.resolve(.swift(.type("PreviewsPipeline.ProviderPreviewInstance")), in: pipeline)
                let initialize = try await providerType.resolve(
                    .swift(
                        .initializer(
                            "init(providerSource: PreviewsPipeline.ProviderSource, previewDescription: PreviewsMessagingHost.PreviewDescription) -> PreviewsPipeline.ProviderPreviewInstance",
                            as: ((NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
                            valueABIs: [
                                providerSourceType: .opaque(named: providerSourceType.name),
                                providerDescription.type: .opaque(named: providerDescription.type.name), providerType: .opaque(named: providerType.name),
                            ])))
                let provider = try unsafe initialize.unsafeInvoke(providerSource, providerDescription.copy())
                effectivePreferences = try await self.effectivePreferences(preferences, instance: provider)
            } else { effectivePreferences = preferences }
        } else { return nil }
        let requirementsType = try await runtime.resolve(.swift(.type("PreviewsPipeline.DestinationRequirements")), in: pipeline)
        // Native preflight and RenderPreview's evaluated Location use none.
        // The registry instance's requirements witness is unavailable.
        let none = try await requirementsType.resolve(
            .swift(
                .staticGetter(
                    "none.getter : PreviewsPipeline.DestinationRequirements", as: (() -> NativeSwiftValue).self,
                    valueABIs: [requirementsType: .opaque(named: requirementsType.name)])))
        let requirements = try unsafe none.unsafeInvoke()
        let domainType = try await runtime.resolve(.swift(.type("PreviewsMessagingHost.PreviewContentDomain")))
        let optionalDomainType = try await runtime.resolve(.swift(.type("Swift.Optional", genericArguments: [.type(domainType)])))
        let domain: NativeSwiftValue
        if let metadata {
            let contentDomain = try await sourceGetter(metadata, "contentDomain.getter : PreviewsMessagingHost.PreviewContentDomain", resultType: domainType)
            let some = try await runtime.resolve(
                .swift(
                    .function(
                        "XcodeMCPNativeRuntime.nativePreviewSome<A>(A) -> A?", as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                        genericArguments: [.type(domainType)],
                        valueABIs: [domainType: .opaque(named: domainType.name), optionalDomainType: .opaque(named: optionalDomainType.name)])))
            domain = try unsafe some.unsafeInvoke(contentDomain)
        } else {
            let propertiesType = try await runtime.resolve(.swift(.type("PreviewsPipeline.ExecutionPointProperties")), in: pipeline)
            let defaults = try await propertiesType.resolve(
                .swift(
                    .staticGetter(
                        "default.getter : PreviewsPipeline.ExecutionPointProperties", as: (() -> NativeSwiftValue).self,
                        valueABIs: [propertiesType: .opaque(named: propertiesType.name)])))
            let properties = try unsafe defaults.unsafeInvoke()
            let domainGetter = try await propertiesType.resolve(
                .swift(
                    .getter(
                        "previewContentDomain.getter : PreviewsMessagingHost.PreviewContentDomain?", as: (() -> NativeSwiftValue).self,
                        valueABIs: [optionalDomainType: .opaque(named: optionalDomainType.name)], receiverABI: .opaque(named: propertiesType.name))))
            domain = try unsafe domainGetter.unsafeInvoke(on: properties)
        }
        let packType = try await runtime.resolve(.swift(.type("PreviewsPipeline.ExecutionPointPack")), in: pipeline)
        let create = try await packType.resolve(
            .swift(
                .initializer(
                    "init(executionPointSource: PreviewsPipeline.ExecutionPointSource, previewAgentRole: PreviewsMessagingHost.PreviewAgentRole, destinationPreferences: PreviewsPipeline.DestinationPreferences, destinationRequirements: PreviewsPipeline.DestinationRequirements, previewContentDomain: PreviewsMessagingHost.PreviewContentDomain?) -> PreviewsPipeline.ExecutionPointPack",
                    as: ((NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
                    valueABIs: [
                        executionSource.type: .opaque(named: executionSource.type.name), role.type: .opaque(named: role.type.name),
                preferences.type: .opaque(named: preferences.type.name), requirementsType: .opaque(named: requirementsType.name),
                        optionalDomainType: .opaque(named: optionalDomainType.name), packType: .opaque(named: packType.name),
                    ])))
        return try unsafe create.unsafeInvoke(executionSource.copy(), role.copy(), effectivePreferences.copy(), requirements.copy(), domain.copy())
    }

    private func sourceArray(_ values: [NativeSwiftValue], elementType: NativeSwiftType) async throws -> NativeSwiftValue {
        let cast = try await runtime.resolve(
            .swift(
                .function(
                    "XcodeMCPNativeRuntime.nativePreviewArray<A>([Any]) throws -> [A]", as: (([Any]) throws -> NativeSwiftValue).self,
                    genericArguments: [.type(elementType)])))
        let copies = try values.map { try $0.withCopy { $0 } }
        return try unsafe cast.unsafeInvoke(copies)
    }

    private func sourcePlan(workspace: AnyObject, host: AnyObject, source: NativePreviewDefinitions.Source, pack: NativeSwiftValue) async throws -> SourcePlan {
        let previews = ImageSelector.path(installation.framework("PreviewsXcode", in: "PlugIns"))
        let pipeline = ImageSelector.path(installation.framework("PreviewsPipeline", in: "SharedFrameworks"))
        let foundation = ImageSelector.path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks"))
        let hostType = try await runtime.resolve(.swift(.type("PreviewsXcode.XcodeWorkspaceSceneHost")), in: previews)
        let getScene = try await hostType.resolve(
            .swift(.getter("workspaceScene.getter : PreviewsScenes.WorkspaceScene<PreviewsPipeline.URLPreviewFileDescription>?", as: (() -> AnyObject?).self)))
        guard let scene = try unsafe getScene.unsafeInvoke(on: host) else {
            throw NativeRuntimeError.unsupportedContract("Native preview scene host has no workspace scene")
        }
        let fileType = try await runtime.resolve(.swift(.type("PreviewsPipeline.URLPreviewFileDescription")), in: pipeline)
        let sceneType = try await runtime.resolve(
            .swift(.type("PreviewsScenes.WorkspaceScene", genericArguments: [.type(fileType)])),
            in: .path(installation.framework("PreviewsScenes", in: "SharedFrameworks")))
        let optionalUnitType = try await runtime.resolve(.swift(.type("Swift.Optional", genericArguments: [.type(source.translationUnit.type)])))
        let originalGetter = try await sceneType.resolve(
            .swift(
                .getter(
                    "agenticTranslationUnit.getter : PreviewsPipeline.PreviewTranslationUnit?", as: (() -> NativeSwiftValue).self,
                    valueABIs: [optionalUnitType: .opaque(named: optionalUnitType.name)])))
        let setter = try await sceneType.resolve(
            .swift(
                .setter(
                    "agenticTranslationUnit.setter : PreviewsPipeline.PreviewTranslationUnit?", as: ((NativeSwiftValue) -> Void).self,
                    valueABIs: [optionalUnitType: .opaque(named: optionalUnitType.name)], receiver: .borrowing)))
        let original = try unsafe originalGetter.unsafeInvoke(on: scene)
        let some = try await runtime.resolve(
            .swift(
                .function(
                    "XcodeMCPNativeRuntime.nativePreviewSome<A>(A) -> A?", as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                    genericArguments: [.type(source.translationUnit.type)])))
        let unit = try unsafe some.unsafeInvoke(source.translationUnit)
        guard let field = Mirror(reflecting: host).children.first(where: { $0.label == "environmentCoalescer" }),
              Mirror(reflecting: field.value).displayStyle == .class else {
            throw NativeRuntimeError.unsupportedContract("Native preview environment coalescer is unavailable")
        }
        let coalescer = field.value as AnyObject
        let coalescerType = try await runtime.resolve(.swift(.type("PreviewsXcode.XcodeBuildEnvironmentCoalescer")), in: previews)
        let invalidate = try await coalescerType.resolve(.swift(.method("setNeedsUpdate() -> ()", as: (() -> Void).self)))
        let updateType = try await runtime.resolve(.swift(.type("PreviewsXcode.XcodeBuildEnvironmentCoalescer.UpdateResult")), in: previews)
        let refresh = try await coalescerType.resolve(
            .swift(
                .method(
                    "updated() -> PreviewsXcode.XcodeBuildEnvironmentCoalescer.UpdateResult", as: (() -> NativeSwiftValue).self,
                    valueABIs: [updateType: .opaque(named: updateType.name)])))
        let protocolSymbol = try await runtime.resolve(
            .swift(.symbol("protocol descriptor for PreviewsIDEAPI.IDESchemeTaskExecutor", kind: .data)),
            in: .path(installation.framework("PreviewsIDEAPI", in: "PlugIns")))
        let executorMetadata: Any.Type = try unsafe protocolSymbol.withUnsafeAddress {
            guard let metadata = unsafe ABISwiftProtocolTypeMetadata($0) else {
                throw NativeRuntimeError.unsupportedContract("Native scheme task executor protocol metadata is unavailable")
            }
            return unsafe unsafeBitCast(metadata, to: Any.Type.self)
        }
        let supplierFactory = try await runtime.resolve(
            .swift(
                .function(
                    "XcodeMCPNativeRuntime.nativePreviewExecutorProvider<A>(Swift.AnyObject) throws -> @Swift.MainActor @Sendable () -> A?",
                    as: ((AnyObject) throws -> NativeSwiftValue).self, genericArguments: [.type(executorMetadata)])))
        let supplier = try unsafe supplierFactory.unsafeInvoke(workspace)
        let callback = try await supplier.copyClosure(as: (@MainActor () -> NativeSwiftValue).self)
        let callsiteType = try await runtime.resolve(.swift(.type("PreviewsFoundationHost.Callsite")), in: foundation)
        let makeCallsite = try await callsiteType.resolve(
            .swift(
                .initializer(
                    "init(Swift.StaticString, Swift.UInt, Swift.UInt, Swift.StaticString) -> PreviewsFoundationHost.Callsite",
                    as: ((NativePreviewStaticString, UInt, UInt, NativePreviewStaticString) -> NativeSwiftValue).self,
                    valueABIs: [callsiteType: .opaque(named: callsiteType.name)])))
        let callsite = try unsafe makeCallsite.unsafeInvoke(NativePreviewStaticString(value: #fileID), #line, #column, NativePreviewStaticString(value: #function))
        let tokenType = try await runtime.resolve(.swift(.type("PreviewsFoundationHost.CancellationToken")), in: foundation)
        let cancel = try await tokenType.resolve(
            .swift(
                .method(
                    "cancel(callsite: PreviewsFoundationHost.Callsite) -> ()", as: ((NativeSwiftValue) -> Void).self,
                    valueABIs: [callsiteType: .opaque(named: callsiteType.name)], receiverABI: .opaque(named: tokenType.name))))
        let register = try await hostType.resolve(
            .swift(
                .method(
                    "registerSchemeTaskExecutorProvider(@Swift.MainActor () -> PreviewsIDEAPI.IDESchemeTaskExecutor?) -> PreviewsFoundationHost.CancellationToken",
                    as: ((NativeSwiftClosure<@MainActor () -> NativeSwiftValue>) -> NativeSwiftValue).self,
                    valueABIs: [tokenType: .opaque(named: tokenType.name)])))
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

    private func makeSourcePlan(host: AnyObject, source: NativePreviewDefinitions.Source, pack: NativeSwiftValue) async throws -> SourcePlan {
        let pipeline = ImageSelector.path(installation.framework("PreviewsPipeline", in: "SharedFrameworks"))
        let foundation = ImageSelector.path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks"))
        let previews = ImageSelector.path(installation.framework("PreviewsXcode", in: "PlugIns"))
        let executionSourceType = try await runtime.resolve(.swift(.type("PreviewsPipeline.ExecutionPointSource")), in: pipeline)
        let executionSource = try await pack.type.resolve(
            .swift(
                .getter(
                    "executionPointSource.getter : PreviewsPipeline.ExecutionPointSource", as: (() -> NativeSwiftValue).self,
                    valueABIs: [executionSourceType: .opaque(named: executionSourceType.name)], receiverABI: .opaque(named: pack.type.name))))
        let sourceValue = try unsafe executionSource.unsafeInvoke(on: pack)
        let sourceArray = try await sourceArray([sourceValue], elementType: sourceValue.type)
        let orderedType = try await runtime.resolve(
            .swift(.type("PreviewsFoundationHost.OrderedSet", genericArguments: [.type(sourceValue.type)])), in: foundation)
        let initialize = try await orderedType.resolve(
            .swift(
                .initializer(
                    "init<A where A == A1.Element, A1: Swift.Sequence>(A1) -> PreviewsFoundationHost.OrderedSet<A>",
                    as: ((NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: [.type(sourceArray.type)],
                    valueABIs: [orderedType: .opaque(named: orderedType.name)])))
        let sources = try unsafe initialize.unsafeInvoke(sourceArray.copy())
        let identifierType = try await runtime.resolve(
            .swift(.type("PreviewsModel.SourceIdentifier")), in: .path(installation.framework("PreviewsModel", in: "SharedFrameworks")))
        let identifierGetter = try await source.translationUnit.type.resolve(
            .swift(
                .getter(
                    "sourceIdentifier.getter : PreviewsModel.SourceIdentifier", as: (() -> NativeSwiftValue).self,
                    valueABIs: [identifierType: .opaque(named: identifierType.name)], receiverABI: .opaque(named: source.translationUnit.type.name))))
        let identifier = try unsafe identifierGetter.unsafeInvoke(on: source.translationUnit)
        let files = try await self.sourceArray([identifier], elementType: identifierType)
        let hostType = try await runtime.resolve(.swift(.type("PreviewsXcode.XcodeWorkspaceSceneHost")), in: previews)
        let makeBuilder = try await hostType.resolve(
            .swift(.method("makeBuilder() throws -> PreviewsXcode.XcodeWorkspaceBuilder", as: (() throws -> AnyObject).self)))
        let builder = try unsafe makeBuilder.unsafeInvoke(on: host)
        let builderType = try await runtime.resolve(.swift(.type("PreviewsXcode.XcodeWorkspaceBuilder")), in: previews)
        let makeGraph = try await builderType.resolve(
            .swift(
                .method(
                    "makeBuildGraph(for: PreviewsFoundationHost.OrderedSet<PreviewsPipeline.ExecutionPointSource>, sourceFiles: [PreviewsModel.SourceIdentifier]) async throws -> PreviewsPipeline.WorkspaceGraph<PreviewsPipeline.BuildGraphItem<PreviewsXcode.XcodeGraphSource>>",
                    as: (@concurrent (NativeSwiftValue, NativeSwiftValue) async throws -> AnyObject).self,
                    valueABIs: [orderedType: .opaque(named: orderedType.name)])))
        let graph = try unsafe await makeGraph.unsafeInvoke(on: builder, sources, files)
        let graphSource = try await runtime.resolve(.swift(.type("PreviewsXcode.XcodeGraphSource")), in: previews)
        let graphItem = try await runtime.resolve(.swift(.type("PreviewsPipeline.BuildGraphItem", genericArguments: [.type(graphSource)])), in: pipeline)
        let graphType = try await runtime.resolve(.swift(.type("PreviewsPipeline.WorkspaceGraph", genericArguments: [.type(graphItem)])), in: pipeline)
        let packs = try await self.sourceArray([pack], elementType: pack.type)
        let update = try await graphType.resolve(
            .swift(
                .method(
                    "makeUpdateGraph<A, B where A == PreviewsPipeline.BuildGraphItem<A1>, A1: PreviewsPipeline.WorkspaceGraphSource, B1: Swift.Collection, B1.Element == PreviewsPipeline.ExecutionPointPack>(for: B1) throws -> PreviewsPipeline.WorkspaceGraph<PreviewsPipeline.UpdateGraphItem<A1>>",
                    as: ((NativeSwiftValue) throws -> AnyObject).self, genericArguments: [.type(graphSource), .type(packs.type)])))
        let updateGraph = try unsafe update.unsafeInvoke(on: graph, packs)
        let platform = try await runtime.resolve(.swift(.type("PreviewsPipeline.Platform")), in: pipeline)
        let components = try await runtime.resolve(.swift(.type("PreviewsXcode.RunDestinationBuildComponents")), in: previews)
        guard let destinationClass = NSClassFromString("IDERunDestination") else {
            throw NativeRuntimeError.unsupportedContract("Native run destination class is unavailable")
        }
        let buildIdentifier = try await runtime.resolve(
            .swift(
                .type("PreviewsXcode.XcodeWorkspaceBuilder.BuildIdentifier", genericArguments: [.type(platform), .type(destinationClass), .type(components)])),
            in: previews)
        let reference = try await runtime.resolve(.swift(.type("PreviewsXcode.XcodeRunDestinationReference")), in: previews)
        let arguments: [NativeSwiftGenericArgument] = [.type(graphSource), .type(buildIdentifier), .type(reference)]
        let planType = try await runtime.resolve(.swift(.type("PreviewsPipeline.PreviewUpdatePlan", genericArguments: arguments)), in: pipeline)
        let recordType = try await runtime.resolve(.swift(.type("PreviewsPipeline.PreviewUpdatePlan.UpdateRecord", genericArguments: arguments)), in: pipeline)
        let agentType = try await runtime.resolve(.swift(.type("PreviewsPipeline.PreviewUpdatePlan.AgentRecord", genericArguments: arguments)), in: pipeline)
        let packRecordType = try await runtime.resolve(
            .swift(.type("PreviewsPipeline.PreviewUpdatePlan.AgentRecord.PackRecord", genericArguments: arguments)), in: pipeline)
        let futureType = try await runtime.resolve(.swift(.type("PreviewsFoundationHost.Future", genericArguments: [.type(planType)])), in: foundation)
        let queryGetter = try await hostType.resolve(.swift(.getter("queryManager.getter : PreviewsFoundationHost.QueryManager", as: (() -> AnyObject).self)))
        let query = try unsafe queryGetter.unsafeInvoke(on: host)
        let graphValue = try await _openExistential(updateGraph as Any, do: nativePreviewOwnedValue)
        let queryValue = try await _openExistential(query as Any, do: nativePreviewOwnedValue)
        let builderValue = try await _openExistential(builder as Any, do: nativePreviewOwnedValue)
        let plan = try await planType.resolve(
            .swift(
                .staticMethod(
                    "static PreviewsPipeline.PreviewUpdatePlan.planForUpdating<A where A == A1.GraphSource, B == A1.WorkspaceBuildIdentifier, C == A1.DestinationRepresentation, A1: PreviewsPipeline.WorkspaceBuilder>(in: PreviewsPipeline.WorkspaceGraph<PreviewsPipeline.UpdateGraphItem<A>>, queryManager: PreviewsFoundationHost.QueryManager, workspaceBuilder: A1) throws -> PreviewsFoundationHost.Future<PreviewsPipeline.PreviewUpdatePlan<A, B, C>>",
                    as: ((NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) throws -> NativeSwiftValue).self, genericArguments: [.type(builderType)])))
        let future = try unsafe plan.unsafeInvoke(graphValue, queryValue, builderValue)
        let awaitValue = try await futureType.resolve(
            .swift(
                .getter(
                    "(extension in PreviewsFoundationHost):PreviewsFoundationHost.Future<A where A: Swift.Sendable>.value.getter : A",
                    as: (@concurrent () async throws -> NativeSwiftValue).self, declaredAs: "() async throws -> A",
                    valueABIs: [planType: .opaque(named: planType.name)])))
        return try unsafe await SourcePlan(value: awaitValue.unsafeInvoke(on: future), recordType: recordType,
            agentType: agentType, packRecordType: packRecordType, referenceType: reference)
    }

    private func sourcePlanRecord(_ plan: SourcePlan, pack: NativeSwiftValue) async throws -> NativeSwiftValue {
        let foundation = ImageSelector.path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks"))
        let setType = try await runtime.resolve(
            .swift(.type("PreviewsFoundationHost.OrderedIdentifiedSet", genericArguments: [.type(plan.packRecordType)])), in: foundation)
        let inhabitedType = try await runtime.resolve(.swift(.type("PreviewsFoundationHost.Inhabited", genericArguments: [.type(setType)])), in: foundation)
        let optionalType = try await runtime.resolve(.swift(.type("Swift.Optional", genericArguments: [.type(plan.packRecordType)])))
        let lookup = try await setType.resolve(
            .swift(
                .getter(
                    "PreviewsFoundationHost.OrderedIdentifiedSet.subscript.getter : (A.ID) -> A?", as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                    valueABIs: [pack.type: .opaque(named: pack.type.name), optionalType: .opaque(named: optionalType.name)],
                    receiverABI: .opaque(named: setType.name))))
        for record in try await sourcePlanRecords(plan) {
            let agent = try await sourceGetter(record, "agentRecord", resultType: plan.agentType)
            let packs = try await sourceGetter(agent, "executionPointPacks", resultType: inhabitedType)
            let values = try await sourceGetter(packs,
                "(extension in PreviewsFoundationHost):PreviewsFoundationHost.PredicatedWrapper.value.getter : A.Predicate.Value", resultType: setType)
            let match = try unsafe lookup.unsafeInvoke(on: values, pack.copy())
            if try await match.copyEnumPayload(forCase: "some", valueABIs: [plan.packRecordType: .opaque(named: plan.packRecordType.name)]) != nil {
                return record
            }
        }
        throw NativeRuntimeError.invocation("Could not find update record in native update plan for the selected execution point pack")
    }

    private func sourcePlanRecords(_ plan: SourcePlan) async throws -> [NativeSwiftValue] {
        let foundation = ImageSelector.path(installation.framework("PreviewsFoundationHost", in: "SharedFrameworks"))
        let arrayType = try await runtime.resolve(.swift(.type("Swift.Array", genericArguments: [.type(plan.recordType)])))
        let inhabitedType = try await runtime.resolve(.swift(.type("PreviewsFoundationHost.Inhabited", genericArguments: [.type(arrayType)])), in: foundation)
        let headType = try await runtime.resolve(.swift(.type("PreviewsFoundationHost.HasHead", genericArguments: [.type(arrayType)])), in: foundation)
        let predicatedType = try await runtime.resolve(.swift(.type("PreviewsFoundationHost.Predicated", genericArguments: [.type(headType)])), in: foundation)
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
