#if (os(iOS) || os(watchOS)) && targetEnvironment(simulator)
import ABIBridge
import ABIBridgeCore
import ABIBridgeCore.Backend
import Darwin
import Foundation
import SwiftUI
import WidgetKit

@MainActor
struct WidgetVariantCatalog {
    struct Variant {
        let name: String
        let effects: Any
    }
    struct Group {
        let title: String
        let variants: [Variant]
    }
    let groups: [Group]

    init(groups: [Group]) { self.groups = groups }

    init(nativeGroups: Any) throws {
        var groups: [Group] = []
        for child in Mirror(reflecting: nativeGroups).children {
            let stored = try widgetVariantField(child.value, "overridesConfiguration")
            guard let overrides = Mirror(reflecting: stored).children.first?.value else { continue }
            guard let title = try widgetVariantField(overrides, "title") as? String else { throw NativePreviewPipelineRequired() }
            let variants = try Mirror(reflecting: widgetVariantField(overrides, "variants")).children.map { child in
                guard let name = try widgetVariantField(child.value, "displayName") as? String else { throw NativePreviewPipelineRequired() }
                return Variant(name: name, effects: try widgetVariantField(child.value, "renderEffects"))
            }
            groups.append(.init(title: title, variants: variants))
        }
        self.groups = groups
    }

    var supported: [String: [String]] {
        groups.reduce(into: [:]) { $0[$1.title] = $1.variants.map(\.name) }
    }

    func effects(for selections: [String: String]) async throws -> NativeSwiftValue {
        var selected: [Any] = []
        for (title, name) in selections {
            guard let variant = groups.first(where: { $0.title == title })?.variants.first(where: { $0.name == name }) else {
                throw NativePreviewPipelineRequired()
            }
            selected += Mirror(reflecting: variant.effects).children.map(\.value)
        }
        guard let example = groups.lazy.flatMap(\.variants).first?.effects as? any Sequence else {
            throw NativePreviewPipelineRequired()
        }
        func array<Effects: Sequence>(_ example: Effects) throws -> Any {
            try selected.map { value -> Effects.Element in
                guard let value = value as? Effects.Element else { throw NativePreviewPipelineRequired() }
                return value
            }
        }
        let values = try _openExistential(example, do: array)
        return try await _openExistential(values, do: ownedPreviewValue)
    }
}

@MainActor
func widgetVariantCatalog(source: NativeSwiftValue) async throws -> WidgetVariantCatalog {
    guard unsafe dlopen("/System/Library/Previews/ShellPlugins/WidgetPreviewsShellPlugin.bundle/WidgetPreviewsShellPlugin",
                        RTLD_NOW | RTLD_GLOBAL) != nil,
          let provider = NSClassFromString("WidgetPreviewsShellPlugin.WidgetContentProvider") else {
        throw NativePreviewPipelineRequired()
    }
    let runtime = ABIRuntime.shared
    let shell = ImageSelector.framework(named: "PreviewShellKit")
    let messaging = ImageSelector.framework(named: "PreviewsMessagingOS")
    let sourceCategoryType = try await runtime.resolve(
        .swift(.type("DeveloperToolsSupport.PreviewSourceContentCategory")), in: .framework(named: "DeveloperToolsSupport"))
    let categoryGetter = try await source.type.resolve(
        .swift(
            .getter(
                "contentCategory", as: (() -> NativeSwiftValue).self, valueABIs: [sourceCategoryType: .opaque(named: sourceCategoryType.name)],
                receiverABI: .opaque(named: source.type.name))))
    let sourceCategory = try unsafe categoryGetter.unsafeInvoke(on: source)
    let categoryType = try await runtime.resolve(.swift(.type("PreviewsMessagingOS.ContentCategory")), in: messaging)
    let makeCategory = try await categoryType.resolve(
        .swift(
            .staticMethod(
                "(extension in PreviewShellKit):PreviewsMessagingOS.ContentCategory.source(DeveloperToolsSupport.PreviewSourceContentCategory) -> PreviewsMessagingOS.ContentCategory",
                as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                valueABIs: [sourceCategoryType: .opaque(named: sourceCategoryType.name), categoryType: .opaque(named: categoryType.name)])))
    let category = try unsafe makeCategory.unsafeInvoke(sourceCategory)
    let descriptor = try await runtime.resolve(.swift(.symbol(machOName: "_$s15PreviewShellKit15ContentProviderMp", kind: .data)), in: shell)
    let thunk = try await runtime.resolve(
        .swift(
            .symbol(
                machOName:
                    "_$s15PreviewShellKit15ContentProviderP22supportedVariantGroups3forSay19PreviewsMessagingOS0aG5GroupVGAF0D8CategoryV_tFZTj")), in: shell
    )
    let metadata = unsafe unsafeBitCast(provider as Any.Type, to: UnsafeRawPointer.self)
    guard let witness = unsafe descriptor.withUnsafeAddress({ unsafe ABISwiftConformance(metadata, $0) }) else {
        throw NativePreviewPipelineRequired()
    }
    let groupType = try await runtime.resolve(.swift(.type("PreviewsMessagingOS.PreviewVariantGroup")), in: messaging)
    let factory = try await runtime.resolve(
        .swift(
            .function("XcodeMCPPreviewRenderer.widgetVariantType<A>() -> A.Type", as: (() -> NativeSwiftValue).self, genericArguments: [.type(groupType)])))
    let nativeType = try unsafe factory.unsafeInvoke()
    guard let type = try nativeType.withCopy({ $0 as? Any.Type }) else { throw NativePreviewPipelineRequired() }
    let categoryCopy = try category.withCopy { $0 }
    @MainActor func openCategory<Category>(_ category: Category) throws -> WidgetVariantCatalog {
        @MainActor func openGroup<Group>(_ type: Group.Type) throws -> WidgetVariantCatalog {
            let abi = WidgetVariantABI()
            let call = try unsafe abi.makeCall()
            let result = UnsafeMutablePointer<[Group]>.allocate(capacity: 1)
            defer { unsafe result.deallocate() }
            var failure: OpaquePointer?
            // The exported requirement thunk accepts borrowed category storage,
            // Self metadata and its real witness; the metatype is SwiftSelf.
            // Array is an owned, one-word result in the arm64 Swift ABI.
            let success = unsafe thunk.withUnsafeAddress { function in
                withUnsafePointer(to: category) { category in
                    var categoryArgument = unsafe UnsafeRawPointer(category)
                    var metadataArgument = unsafe metadata
                    var witnessArgument = unsafe witness
                    let context = unsafe metadataArgument
                    return withUnsafePointer(to: &categoryArgument) { category in
                        withUnsafePointer(to: &metadataArgument) { metadata in
                            withUnsafePointer(to: &witnessArgument) { witness in
                                let arguments: [UnsafeMutableRawPointer?] = unsafe [UnsafeMutableRawPointer(mutating: category),
                                    UnsafeMutableRawPointer(mutating: metadata), UnsafeMutableRawPointer(mutating: witness)]
                                return arguments.withUnsafeBufferPointer {
                                    unsafe ABIUnsafeInvokeSwiftCallInterface(call, ABIUnsafeFunctionAtAddress(function), result,
                                        $0.baseAddress, context, &failure)
                                }
                            }
                        }
                    }
                }
            }
            guard success else { throw unsafe abi.error(&failure) }
            let values = unsafe result.move()
            return try WidgetVariantCatalog(nativeGroups: values)
        }
        return try _openExistential(type, do: openGroup)
    }
    return try _openExistential(categoryCopy, do: openCategory)
}

@inline(never)
public func widgetVariantType<Value>() -> Value.Type { Value.self }

private func widgetVariantField(_ value: Any, _ name: String) throws -> Any {
    guard let value = Mirror(reflecting: value).children.first(where: { $0.label == name })?.value else {
        throw NativePreviewPipelineRequired()
    }
    return value
}

#if os(iOS)
@MainActor
func applyWidgetEffects(_ effects: NativeSwiftValue, to environment: inout EnvironmentValues) async throws -> WidgetFamily? {
    let runtime = ABIRuntime.shared
    let familyType = try await runtime.resolve(.swift(.type("WidgetKit.WidgetFamily")), in: .framework(named: "WidgetKit"))
    let optionalFamily = try await widgetValue(Optional<WidgetFamily>.none)
    let familyConverter = try await familyType.resolve(
        .swift(
            .initializer(
                "init(Swift.Array<PreviewsMessagingOS.RenderEffect>) -> Swift.Optional<WidgetKit.WidgetFamily>",
                as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                valueABIs: [effects.type: .pointer, optionalFamily.type: .opaque(named: optionalFamily.type.name)])))
    let family = try unsafe familyConverter.unsafeInvoke(effects.copy()).take(as: WidgetFamily?.self)
    let redactionType = try await widgetValue(RedactionReasons()).type
    let optionalRedaction = try await widgetValue(Optional<RedactionReasons>.none)
    let redaction = try await redactionType.resolve(
        .swift(
            .initializer(
                "init(Swift.Array<PreviewsMessagingOS.RenderEffect>) -> Swift.Optional<SwiftUI.RedactionReasons>",
                as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                valueABIs: [effects.type: .pointer, optionalRedaction.type: .opaque(named: optionalRedaction.type.name)])))
    environment.redactionReasons = try unsafe redaction.unsafeInvoke(effects.copy()).take(as: RedactionReasons?.self) ?? []
    let luminance = try await effects.type.resolve(.swift(.getter("isLuminanceReduced", as: (() -> Bool).self, receiverABI: .pointer)))
    environment.isLuminanceReduced = try unsafe luminance.unsafeInvoke(on: effects)
    return family
}
#endif

@MainActor @safe
private final class WidgetVariantABI {
    private var pointer: OpaquePointer?
    private var call: OpaquePointer?
    isolated deinit {
        if let value = unsafe call { unsafe ABIReleaseSwiftCallInterface(value) }
        if let value = unsafe pointer { unsafe ABIReleaseValueType(value) }
    }
    func error(_ failure: inout OpaquePointer?) -> PreviewRendererError {
        let message = unsafe failure.map { unsafe String(cString: ABIResolutionFailureGetMessage($0)) } ?? "Widget variant preparation failed"
        if let value = unsafe failure { unsafe ABIReleaseResolutionFailure(value) }
        unsafe failure = nil
        return PreviewRendererError(message)
    }
    func makeCall() throws -> OpaquePointer {
        var failure: OpaquePointer?
        guard let pointer = unsafe ABICreateScalarType(Int32(ABIValuePointer), &failure) else { throw unsafe error(&failure) }
        unsafe self.pointer = pointer
        let parameters: [OpaquePointer?] = unsafe [pointer, pointer, pointer]
        guard let call = parameters.withUnsafeBufferPointer({
            unsafe ABICreateSwiftCallInterface(pointer, $0.baseAddress, $0.count, &failure)
        }) else { throw unsafe error(&failure) }
        unsafe self.call = call
        return unsafe call
    }
}
#endif
