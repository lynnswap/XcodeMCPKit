#if (os(iOS) || os(watchOS)) && targetEnvironment(simulator)
import ABIBridge
import Darwin
import Foundation
import Synchronization

@inline(never)
public func previewServiceEmptyArray<Element>() -> [Element] { [] }

@inline(never)
public func previewServiceEmptyOptionalArray<Element>() -> [Element]? { .some([]) }

@inline(never)
public func previewServiceNil<Value>() -> Value? { nil }

private typealias PreviewServiceSender = @convention(block) @Sendable (AnyObject) -> Void
private typealias PreviewServiceActivation = @convention(block) @Sendable (PreviewServiceSender?) -> Void
private typealias PreviewServiceReply = @convention(block) @Sendable (AnyObject?, NSError?) -> Void

private final class PreviewServiceContinuation<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Value, any Error>?
        var result: Result<Value, any Error>?
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        let completed: Result<Value, any Error>? = state.withLock { state in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let completed {
            continuation.resume(with: completed)
            return false
        }
        return true
    }

    func complete(_ result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = state.withLock { state in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}

@MainActor
private func awaitPreviewServiceReply<Value: Sendable>(
    _ reply: PreviewServiceContinuation<Value>,
    start: () throws -> Void
) async throws -> Value {
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard reply.install(continuation) else { return }
            do { try start() }
            catch { reply.complete(.failure(error)) }
        }
    } onCancel: {
        reply.complete(.failure(CancellationError()))
    }
}

@MainActor
final class NativePreviewService {
    let propertyListType: NativeSwiftType

    private let runtime = ABIRuntime.shared
    private let messagingImage = ImageSelector.path(URL(filePath: "/System/Library/PrivateFrameworks/PreviewsMessagingOS.framework/PreviewsMessagingOS"))
    private let service: AnyObject
    private let messageClass: AnyClass
    private let cancel: NativeBoundObjCMethod<Void>
    private var sender: PreviewServiceSender?
    // Cancellation can finish an await before native cancel invalidates its message.
    private var messages: [AnyObject] = []

    private init() async throws {
        let runtime = ABIRuntime.shared
        propertyListType = try await runtime.resolveSwiftType(named: "PreviewsFoundationOS.PropertyList",
            in: .path(URL(filePath: "/System/Library/PrivateFrameworks/PreviewsFoundationOS.framework/PreviewsFoundationOS")))
        guard unsafe dlopen("/System/Library/PrivateFrameworks/PreviewsOSSupport.framework/PreviewsOSSupport", RTLD_NOW | RTLD_GLOBAL) != nil,
              let factoryClass = NSClassFromString("_TtC17PreviewsOSSupport27_UVServiceHubServiceFactory"),
              let messageClass = NSClassFromString("UVServiceHubMessage") else {
            throw PreviewRendererError("Native ServiceHub client is unavailable")
        }
        let factory = try unsafe await runtime.object(factoryClass as AnyObject).resolveMethod(
            selector: "makePreviewServiceAndReturnError:", as: ((UnsafeMutablePointer<NSError?>) -> AnyObject?).self)
        let result = try withUnsafeTemporaryAllocation(of: NSError?.self, capacity: 1) { slot in
            unsafe slot.initialize(repeating: nil)
            defer { _ = unsafe slot.deinitialize() }
            let service = try unsafe factory.unsafeInvoke(slot.baseAddress!)
            return (service: service, error: slot.baseAddress!.pointee)
        }
        guard let service = result.service else {
            if let error = result.error { throw error }
            throw PreviewRendererError("Native ServiceHub factory returned nil")
        }
        let cancel = try runtime.object(service).resolveMethodAndWait(selector: "cancel", as: (() -> Void).self)
        if let error = result.error {
            do { try unsafe cancel.unsafeInvoke() }
            catch let cleanupError {
                throw PreviewRendererError("\(error); native preview service cleanup also failed: \(cleanupError)")
            }
            throw error
        }
        self.service = service
        self.messageClass = messageClass
        self.cancel = cancel
    }

    static func withService<Output>(
        _ operation: @MainActor (NativePreviewService) async throws -> Output
    ) async throws -> Output {
        let service = try await NativePreviewService()
        let result: Result<Output, any Error>
        do {
            try await service.activate()
            result = .success(try await operation(service))
        } catch {
            result = .failure(error)
        }
        do { try service.close() }
        catch {
            if case .failure(let original) = result {
                throw PreviewRendererError("\(original); native preview service cleanup also failed: \(error)")
            }
            throw error
        }
        return try result.get()
    }

    private func activate() async throws {
        let result = PreviewServiceContinuation<PreviewServiceSender>()
        let completion: PreviewServiceActivation = { sender in
            if let sender { result.complete(.success(sender)) }
            else { result.complete(.failure(PreviewRendererError("Native ServiceHub activation returned nil sender"))) }
        }
        let activate = try await runtime.object(service).resolveMethod(selector: "activateWithCompletion:",
            as: ((@escaping PreviewServiceActivation) -> Void).self)
        defer { withExtendedLifetime(completion) {} }
        sender = try await awaitPreviewServiceReply(result) {
            try unsafe activate.unsafeInvoke(completion)
        }
    }

    private func close() throws {
        defer {
            sender = nil
            messages.removeAll()
        }
        try unsafe cancel.unsafeInvoke()
    }

    func messagingType(_ name: String) async throws -> NativeSwiftType {
        try await runtime.resolveSwiftType(named: "PreviewsMessagingOS." + name, in: messagingImage)
    }

    func emptyArray(element: NativeSwiftType) async throws -> NativeSwiftValue {
        let array = try await runtime.resolveSwiftType(named: "Swift.Array", genericArguments: [.type(element)])
        let factory = try await runtime.resolveSwiftFunction(
            named: "XcodeMCPPreviewRenderer.previewServiceEmptyArray<A>() -> Swift.Array<A>",
            as: (() -> NativeSwiftValue).self, genericArguments: [.type(element)], valueABIs: [array: .pointer])
        return try unsafe factory.unsafeInvoke()
    }

    func none(of wrapped: NativeSwiftType) async throws -> NativeSwiftValue {
        let factory = try await runtime.resolveSwiftFunction(
            named: "XcodeMCPPreviewRenderer.previewServiceNil<A>() -> A?",
            as: (() -> NativeSwiftValue).self, genericArguments: [.type(wrapped)])
        return try unsafe factory.unsafeInvoke()
    }

    func encode(_ value: NativeSwiftValue) async throws -> NativeSwiftValue {
        let getter = try await value.type.resolveGetter(named: "propertyListValue", as: (() -> NativeSwiftValue).self,
            valueABIs: [propertyListType: .opaque(named: propertyListType.name)], receiverABI: .opaque(named: value.type.name))
        return try unsafe getter.unsafeInvoke(on: value)
    }

    func dictionary(_ value: NativeSwiftValue) async throws -> [String: Any] {
        let dictionaryType = try await runtime.resolveSwiftType(named: "Swift.Dictionary",
            genericArguments: [.type(String.self), .type(Any.self)])
        let getter = try await propertyListType.resolveGetter(named: "serializableDictionary", as: (() -> NativeSwiftValue).self,
            valueABIs: [dictionaryType: .pointer], receiverABI: .opaque(named: propertyListType.name))
        let result = try unsafe getter.unsafeInvoke(on: value)
        return try result.withCopy { value in
            guard let dictionary = value as? [String: Any] else {
                throw PreviewRendererError("Native serializableDictionary is not [String: Any]")
            }
            return dictionary
        }
    }

    func propertyList(_ data: Data) async throws -> NativeSwiftValue {
        guard let dictionary = try unsafe PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw PreviewRendererError("The native preview reply is not a serializable dictionary")
        }
        let value = try await ownedPreviewValue(dictionary)
        let initialize = try await propertyListType.resolveInitializer(named: "init(serializableDictionary:)",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [value.type: .pointer, propertyListType: .opaque(named: propertyListType.name)])
        return try unsafe initialize.unsafeInvoke(value)
    }

    // The payload is an encoded native PropertyList; ServiceMessage validates its content.
    func send(_ kind: String, payload: NativeSwiftValue) async throws -> NativeSwiftValue {
        guard let sender else { throw PreviewRendererError("Native ServiceHub client is not active") }
        let messageType = try await messagingType("ServiceMessage.MessageType")
        let optionalMessageType = try await runtime.resolveSwiftType(named: "Swift.Optional", genericArguments: [.type(messageType)])
        let message = try await messagingType("ServiceMessage")
        let makeType = try await messageType.resolveInitializer(named: "init(rawValue:)", as: ((String) -> NativeSwiftValue).self,
            valueABIs: [optionalMessageType: .uint8])
        let optionalType = try unsafe makeType.unsafeInvoke(kind)
        guard let type = try await optionalType.resolveEnumPayload(forCase: "some") else {
            throw PreviewRendererError("Native message type rejected \(kind)")
        }
        let makeMessage = try await message.resolveInitializer(named: "init(messageType:payload:)",
            as: ((NativeSwiftValue, NativeSwiftValue) throws -> NativeSwiftValue).self,
            valueABIs: [messageType: .uint8, propertyListType: .opaque(named: propertyListType.name), message: .opaque(named: message.name)])
        let nativeMessage = try unsafe makeMessage.unsafeInvoke(type, payload)
        let getType = try await message.resolveGetter(named: "messageType", as: (() -> NativeSwiftValue).self,
            valueABIs: [messageType: .uint8], receiverABI: .opaque(named: message.name))
        let getRawType = try await messageType.resolveGetter(named: "rawValue", as: (() -> String).self, receiverABI: .uint8)
        let actualType = try unsafe getType.unsafeInvoke(on: nativeMessage)
        let rawType = try unsafe getRawType.unsafeInvoke(on: actualType)
        let getPayload = try await message.resolveGetter(named: "payload", as: (() -> NativeSwiftValue).self,
            valueABIs: [propertyListType: .opaque(named: propertyListType.name)], receiverABI: .opaque(named: message.name))
        let canonicalPayload = try unsafe getPayload.unsafeInvoke(on: nativeMessage)
        let payloadDictionary = try await dictionary(canonicalPayload) as NSDictionary
        let result = PreviewServiceContinuation<Data>()
        let reply: PreviewServiceReply = { payload, error in
            if let error {
                result.complete(.failure(error))
                return
            }
            do {
                guard let payload else { throw PreviewRendererError("Native \(kind) reply returned nil payload") }
                let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
                result.complete(.success(data))
            } catch {
                result.complete(.failure(error))
            }
        }
        let allocate = try await runtime.object(messageClass as AnyObject).resolveMethod(selector: "alloc", as: (() -> AnyObject).self)
        let allocated = try unsafe allocate.unsafeInvoke()
        let initialize = try await runtime.object(allocated).resolveMethod(selector: "initWithMessageType:payload:replyHandler:",
            as: ((String, AnyObject, PreviewServiceReply?) -> AnyObject).self)
        let wrapped = try unsafe initialize.unsafeInvoke(rawType, payloadDictionary, reply)
        messages.append(wrapped)
        defer { withExtendedLifetime((sender, reply, wrapped, nativeMessage)) {} }
        let data = try await awaitPreviewServiceReply(result) { sender(wrapped) }
        return try await propertyList(data)
    }

    func archivingParameter() async throws -> (declaration: String, value: NativeSwiftValue) {
        let type: NativeSwiftType
        do {
            type = try await messagingType("ArchivingStrategy")
        } catch ABIResolutionError.declarationNotFound {
            // Older messaging images expose the same payloads with a native
            // optional ContentOverride instead of ArchivingStrategy.
            let type = try await messagingType("ContentOverride")
            return ("contentOverride: PreviewsMessagingOS.ContentOverride?", try await none(of: type))
        }
        let getter = try await type.resolveStaticGetter(named: "default", as: (() -> NativeSwiftValue).self,
            valueABIs: [type: .opaque(named: type.name)])
        return ("archivingStrategy: PreviewsMessagingOS.ArchivingStrategy", try unsafe getter.unsafeInvoke())
    }

    func makeUpdate(pid: Int32, identifier: NativeSwiftValue, category: NativeSwiftValue,
                        content: NativeSwiftValue, controls: NativeSwiftValue?) async throws -> NativeSwiftValue {
        let dynamicType = try await messagingType("DynamicLoadablePreviewProduct")
        let staticType = try await messagingType("StaticLinkablePreviewProduct")
        let incrementalType = try await messagingType("PreviewIncrementalUpdate")
        let setupType = try await messagingType("UpdateSetupPayload")
        let dynamic = try await emptyArray(element: dynamicType)
        let products = try await emptyArray(element: staticType)
        let increments = try await emptyArray(element: incrementalType)
        let setupInitializer = try await setupType.resolveInitializer(
            named: "init(dynamicProducts: [PreviewsMessagingOS.DynamicLoadablePreviewProduct], staticProducts: [PreviewsMessagingOS.StaticLinkablePreviewProduct], shellDidLoadStaticProducts: Swift.Bool, updates: [PreviewsMessagingOS.PreviewIncrementalUpdate], loggingOutputPath: Swift.String?) -> PreviewsMessagingOS.UpdateSetupPayload",
            as: ((NativeSwiftValue, NativeSwiftValue, Bool, NativeSwiftValue, String?) -> NativeSwiftValue).self,
            valueABIs: [dynamic.type: .pointer, products.type: .pointer, increments.type: .pointer,
                        setupType: .opaque(named: setupType.name)])
        let setup = try unsafe setupInitializer.unsafeInvoke(dynamic, products.copy(), false, increments, nil)
        let seedType = try await messagingType("HostUpdateSeed")
        let seed = try await none(of: seedType)
        let previewType = try await messagingType("PreviewType")
        let preview: NativeSwiftValue
        do {
            preview = try previewType.makeEnumCase(named: "static")
        } catch NativeSwiftValueError.enumCaseRequiresPayload(name: "static") {
            // The native backward-compatible decoder supplies the formal display payload.
            let data = try PropertyListSerialization.data(fromPropertyList: ["discriminant": "static"], format: .binary, options: 0)
            let encoded = try await propertyList(data)
            let decode = try await previewType.resolveInitializer(
                named: "init(propertyListValue: PreviewsFoundationOS.PropertyList) throws -> PreviewsMessagingOS.PreviewType",
                as: ((NativeSwiftValue) throws -> NativeSwiftValue).self,
                valueABIs: [propertyListType: .opaque(named: propertyListType.name), previewType: .opaque(named: previewType.name)])
            preview = try unsafe decode.unsafeInvoke(encoded)
        }
        let box = try await messagingType("PlistValueBox")
        let boxes = try await runtime.resolveSwiftType(named: "Swift.Array", genericArguments: [.type(box)])
        let states: NativeSwiftValue
        if let controls { states = controls } else {
            // The native first static update carries some([]) before the canvas
            // discovers its control configuration.
            let optionalBoxes = try await runtime.resolveSwiftType(named: "Swift.Optional", genericArguments: [.type(boxes)])
            let factory = try await runtime.resolveSwiftFunction(
                named: "XcodeMCPPreviewRenderer.previewServiceEmptyOptionalArray<A>() -> Swift.Array<A>?",
                as: (() -> NativeSwiftValue).self, genericArguments: [.type(box)], valueABIs: [optionalBoxes: .pointer])
            states = try unsafe factory.unsafeInvoke()
        }
        let parameter = try await archivingParameter()
        let type = try await messagingType("ShellUpdatePayload")
        let suffix = "previewType: PreviewsMessagingOS.PreviewType, contentIdentifier: PreviewsMessagingOS.ContentIdentifier, contentCategory: PreviewsMessagingOS.ContentCategory, \(parameter.declaration), contentPayload: PreviewsFoundationOS.PropertyList, staticProducts: [PreviewsMessagingOS.StaticLinkablePreviewProduct], setupPayload: PreviewsMessagingOS.UpdateSetupPayload, controlStates: [PreviewsMessagingOS.PlistValueBox]?) -> PreviewsMessagingOS.ShellUpdatePayload"
        let groupedInitializer = "init(pid: Swift.Int32, hostUpdateSeed: PreviewsMessagingOS.HostUpdateSeed?, hostUpdateGroupSeed: PreviewsMessagingOS.HostUpdateGroupSeed?, " + suffix
        let hasGroupSeed: Bool
        do {
            _ = try await runtime.resolve(.init(name: type.name + "." + groupedInitializer, language: .swift), in: messagingImage)
            hasGroupSeed = true
        } catch ABIResolutionError.declarationNotFound {
            hasGroupSeed = false
        }
        var valueABIs: [NativeSwiftType: NativeType] = try [seed.type: .opaque(named: seed.type.name),
            preview.type: .opaque(named: preview.type.name), identifier.type: .opaque(named: identifier.type.name),
            category.type: .opaque(named: category.type.name), parameter.value.type: .opaque(named: parameter.value.type.name),
            propertyListType: .opaque(named: propertyListType.name), products.type: .pointer,
            setupType: .opaque(named: setupType.name), states.type: .pointer, type: .opaque(named: type.name)]
        let value: NativeSwiftValue
        if hasGroupSeed {
            let groupSeedType = try await messagingType("HostUpdateGroupSeed")
            let groupSeed = try await none(of: groupSeedType)
            valueABIs[groupSeed.type] = try .opaque(named: groupSeed.type.name)
            let make = try await type.resolveInitializer(named: groupedInitializer,
                as: ((Int32, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue,
                      NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
                valueABIs: valueABIs)
            value = try unsafe make.unsafeInvoke(pid, seed, groupSeed, preview, identifier.copy(), category.copy(),
                parameter.value, content, products, setup, states)
        } else {
            let make = try await type.resolveInitializer(
                named: "init(pid: Swift.Int32, hostUpdateSeed: PreviewsMessagingOS.HostUpdateSeed?, " + suffix,
                as: ((Int32, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue,
                      NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
                valueABIs: valueABIs)
            value = try unsafe make.unsafeInvoke(pid, seed, preview, identifier.copy(), category.copy(),
                parameter.value, content, products, setup, states)
        }
        return try await encode(value)
    }

    func sendUpdate(_ payload: NativeSwiftValue) async throws -> NativeSwiftValue {
        try await send("update", payload: payload)
    }

    func providerMetadata(named name: String, pid: Int32) async throws -> (metadata: Data, providerDescription: Data?) {
        let payloadType = try await messagingType("ProviderPayload")
        let makePayload = try await payloadType.resolveInitializer(
            named: "init(providerName: Swift.String) -> PreviewsMessagingOS.ProviderPayload",
            as: ((String) -> NativeSwiftValue).self, valueABIs: [payloadType: .opaque(named: payloadType.name)])
        let payload = try unsafe makePayload.unsafeInvoke(name)
        let categoryType = try await messagingType("ContentCategory")
        let getCategory = try await categoryType.resolveStaticGetter(named: "previewProvider", as: (() -> NativeSwiftValue).self,
            valueABIs: [categoryType: .opaque(named: categoryType.name)])
        let category = try unsafe getCategory.unsafeInvoke()
        let identifierType = try await messagingType("ContentIdentifier")
        let makeIdentifier = try await identifierType.resolveInitializer(named: "init(rawValue: Swift.String) -> PreviewsMessagingOS.ContentIdentifier",
            as: ((String) -> NativeSwiftValue).self, valueABIs: [identifierType: .opaque(named: identifierType.name)])
        let identifier = try unsafe makeIdentifier.unsafeInvoke(UUID().uuidString)
        let update = try await makeUpdate(pid: pid, identifier: identifier, category: category,
            content: encode(payload), controls: nil)
        let reply = try await sendUpdate(update)
        let responseType = try await messagingType("PreviewInstancesPayload")
        let decode = try await responseType.resolveInitializer(
            named: "init(propertyListValue: PreviewsFoundationOS.PropertyList) throws -> PreviewsMessagingOS.PreviewInstancesPayload",
            as: ((NativeSwiftValue) throws -> NativeSwiftValue).self,
            valueABIs: [propertyListType: .opaque(named: propertyListType.name), responseType: .opaque(named: responseType.name)])
        let response = try unsafe decode.unsafeInvoke(reply)
        let descriptionType = try await messagingType("PreviewDescription")
        let descriptionsType = try await runtime.resolveSwiftType(named: "Swift.Array", genericArguments: [.type(descriptionType)])
        let getter = try await responseType.resolveGetter(named: "previewDescriptions", as: (() -> NativeSwiftValue).self,
            valueABIs: [descriptionsType: .pointer], receiverABI: .opaque(named: responseType.name))
        let descriptions = try unsafe getter.unsafeInvoke(on: response)
        let first = try descriptions.withCopy { value -> Any in
            guard let values = value as? any Collection, let first = values.first else {
                throw PreviewRendererError("The native preview provider returned no descriptions")
            }
            return first
        }
        func own<Value>(_ value: Value) async throws -> NativeSwiftValue { try await ownedPreviewValue(value) }
        let description = try await _openExistential(first, do: own)
        return try await nativeLegacyPreviewMetadata(description: description)
    }

    func relaunch(extensionIdentifier: String, localization: String?) async throws -> Int32 {
        let bundleType = try await messagingType("AgentDescriptor.Bundle")
        let descriptorType = try await messagingType("AgentDescriptor")
        let roleType = try await messagingType("PreviewAgentRole")
        let modeType = try await messagingType("PreviewAgentBootstrapMode")
        let processType = try await messagingType("ProcessType")
        let binaryType = try await messagingType("BinaryType")
        let targetType = try await messagingType("BuiltTargetDescription")
        let launchType = try await messagingType("LaunchPayload")
        let deviceType = try await messagingType("DeviceType")
        let optionalRole = try await runtime.resolveSwiftType(named: "Swift.Optional", genericArguments: [.type(roleType)])
        let optionalMode = try await runtime.resolveSwiftType(named: "Swift.Optional", genericArguments: [.type(modeType)])
        let targetsType = try await runtime.resolveSwiftType(named: "Swift.Array", genericArguments: [.type(targetType)])
        let makeBundle = try await bundleType.resolveInitializer(
            named: "init(bundleID: Swift.String, path: Swift.String?) -> PreviewsMessagingOS.AgentDescriptor.Bundle",
            as: ((String, String?) -> NativeSwiftValue).self, valueABIs: [bundleType: .opaque(named: bundleType.name)])
        let bundle = try unsafe makeBundle.unsafeInvoke(extensionIdentifier, nil)
        let makeDescriptor = try await descriptorType.resolveInitializer(
            named: "init(idAcrossRelaunches: Swift.String, bundle: PreviewsMessagingOS.AgentDescriptor.Bundle) -> PreviewsMessagingOS.AgentDescriptor",
            as: ((String, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [bundleType: .opaque(named: bundleType.name), descriptorType: .opaque(named: descriptorType.name)])
        let descriptor = try unsafe makeDescriptor.unsafeInvoke(UUID().uuidString, bundle)
        let makeRole = try await roleType.resolveInitializer(
            named: "init(rawValue: Swift.String) -> PreviewsMessagingOS.PreviewAgentRole?",
            as: ((String) -> NativeSwiftValue).self, valueABIs: [optionalRole: .opaque(named: optionalRole.name)])
        let optionalPreviews = try unsafe makeRole.unsafeInvoke("previews")
        guard let role = try await optionalPreviews.resolveEnumPayload(forCase: "some") else {
            throw PreviewRendererError("Native role rejected previews")
        }
        let makeMode = try await modeType.resolveInitializer(
            named: "init(rawValue: Swift.String) -> PreviewsMessagingOS.PreviewAgentBootstrapMode?",
            as: ((String) -> NativeSwiftValue).self, valueABIs: [optionalMode: .uint8])
        let optionalFullBinary = try unsafe makeMode.unsafeInvoke("fullBinary")
        guard let mode = try await optionalFullBinary.resolveEnumPayload(forCase: "some") else {
            throw PreviewRendererError("Native bootstrap mode rejected fullBinary")
        }
        let getProcess = try await processType.resolveStaticGetter(named: "homeScreenExtension", as: (() -> NativeSwiftValue).self,
            valueABIs: [processType: .opaque(named: processType.name)])
        let process = try unsafe getProcess.unsafeInvoke()
        let getBinary = try await binaryType.resolveStaticGetter(named: "unspecified", as: (() -> NativeSwiftValue).self,
            valueABIs: [binaryType: .opaque(named: binaryType.name)])
        let binary = try unsafe getBinary.unsafeInvoke()
        let targets = try await emptyArray(element: targetType)
        let token = try await ownedPreviewValue(Optional<audit_token_t>.none)
        let environment = try await ownedPreviewValue(["XCODE_RUNNING_FOR_PREVIEWS": "1"])
        let arguments = try await ownedPreviewValue(Self.launchArguments(localization: localization))
        let makeLaunch = try await launchType.resolveInitializer(
            named: "init(workspaceID: Swift.String, agentDescriptor: PreviewsMessagingOS.AgentDescriptor, agentRole: PreviewsMessagingOS.PreviewAgentRole, agentBootstrapMode: PreviewsMessagingOS.PreviewAgentBootstrapMode, environment: [Swift.String : Swift.String], arguments: [Swift.String], processType: PreviewsMessagingOS.ProcessType, binaryType: PreviewsMessagingOS.BinaryType, targetDescriptions: [PreviewsMessagingOS.BuiltTargetDescription], hostAuditToken: __C.audit_token_t?) -> PreviewsMessagingOS.LaunchPayload",
            as: ((String, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [descriptorType: .opaque(named: descriptorType.name), roleType: .opaque(named: roleType.name),
                modeType: .uint8, processType: .opaque(named: processType.name), binaryType: .opaque(named: binaryType.name),
                environment.type: .pointer, arguments.type: .pointer, targetsType: .pointer,
                token.type: .opaque(named: token.type.name), launchType: .opaque(named: launchType.name)])
        let launch = try unsafe makeLaunch.unsafeInvoke("XcodeMCPPreviewRenderer-" + UUID().uuidString,
            descriptor, role, mode, environment, arguments, process, binary, targets, token)
        let device = try deviceType.makeEnumCase(named: "default")
        let encodedLaunch = try await encode(launch)
        let encodedDevice = try await encode(device)
        let merge = try await propertyListType.resolveMethod(
            named: "confidentlyMerging(PreviewsFoundationOS.PropertyList) -> PreviewsFoundationOS.PropertyList",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: [propertyListType: .opaque(named: propertyListType.name)],
            receiverABI: .opaque(named: propertyListType.name))
        let payload = try unsafe merge.unsafeInvoke(on: encodedLaunch, encodedDevice)
        let reply = try await send("relaunch", payload: payload)
        let processID = try await messagingType("ProcessID")
        let decode = try await processID.resolveInitializer(
            named: "init(propertyListValue: PreviewsFoundationOS.PropertyList) throws -> PreviewsMessagingOS.ProcessID",
            as: ((NativeSwiftValue) throws -> NativeSwiftValue).self,
            valueABIs: [propertyListType: .opaque(named: propertyListType.name), processID: .opaque(named: processID.name)])
        let decoded = try unsafe decode.unsafeInvoke(reply)
        let getPID = try await processID.resolveGetter(named: "pid.getter : Swift.Int32", as: (() -> Int32).self,
            receiverABI: .opaque(named: processID.name))
        return try unsafe getPID.unsafeInvoke(on: decoded)
    }

    private static func launchArguments(localization: String?) throws -> [String] {
        guard let localization else { return [] }
        let languages = try PropertyListSerialization.data(fromPropertyList: [localization], format: .xml, options: 0)
        return ["-AppleLanguages", String(decoding: languages, as: UTF8.self), "-AppleLocale", localization]
    }
}
#endif
