#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
import ABIBridge
import CoreGraphics
import DeveloperToolsSupport
import Foundation
import SwiftUI
#if os(watchOS)
import _ClockKit_SwiftUI
#endif

@MainActor
func nativeLegacyPreviewMetadata(typeName: String) async throws -> (metadata: Data, providerDescription: Data?) {
    do {
        // The native MCP provider runnable selects child zero independently of
        // the parsed source-definition index and the arguments grid control.
        let preview = try makeLegacyViewPreview(typeName: typeName, index: 0)
        let runtime = ABIRuntime.shared
        let image = ImageSelector.framework(named: "PreviewsMessagingOS")
        let domainType = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.PreviewContentDomain", in: image)
        let sourceCategoryType = try await runtime.resolveSwiftType(named: "DeveloperToolsSupport.PreviewSourceContentCategory",
            in: .framework(named: "DeveloperToolsSupport"))
        var domain = try domainType.makeEnumCase(named: "view")
        let categoryGetter = try await sourceCategoryType.resolveStaticGetter(
            named: "static (extension in SwiftUI):DeveloperToolsSupport.PreviewSourceContentCategory.swiftUIView.getter : DeveloperToolsSupport.PreviewSourceContentCategory",
            as: (() -> NativeSwiftValue).self,
            valueABIs: [sourceCategoryType: .opaque(named: sourceCategoryType.name)])
        var sourceCategory = try unsafe categoryGetter.unsafeInvoke()
        var onDevice = true
        #if os(watchOS)
        if let context = preview.context {
            // This key's Value is nonoptional. Native optional chaining tests
            // context presence, after evaluating its subscript.
            withExtendedLifetime(context[_ComplicationPreviewContextKey.self]) {}
            domain = try domainType.makeEnumCase(named: "complication")
            sourceCategory = try await legacyComplicationCategory(sourceCategoryType)
            onDevice = false
        }
        #endif
        #if !os(tvOS)
        if let context = preview.context, let category = try await legacyWidgetCategory(context) {
            domain = try domainType.makeEnumCase(named: "widget")
            sourceCategory = category
            #if os(iOS) && targetEnvironment(simulator)
            onDevice = false
            #endif
        }
        #endif
        let categoryType = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.ContentCategory", in: image)
        let categoryDeclaration = "(extension in PreviewsOSSupportUI):DeveloperToolsSupport.PreviewSourceContentCategory.contentCategory.getter : PreviewsMessagingOS.ContentCategory"
        let support = try await runtime.resolve(.init(name: categoryDeclaration, language: .swift),
            in: .framework(named: "PreviewsOSSupportUI"))
        let nativeCategoryGetter = try await sourceCategory.type.resolveGetter(named: categoryDeclaration,
            as: (() -> NativeSwiftValue).self, valueABIs: [categoryType: .opaque(named: categoryType.name)],
            receiverABI: .opaque(named: sourceCategory.type.name))
        let category = try withExtendedLifetime(support) { try unsafe nativeCategoryGetter.unsafeInvoke(on: sourceCategory) }
        let layout = try await legacyPreviewLayout(preview.layout)
        let orientation = try await legacyPreviewOrientation(preview)
        let descriptionType = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.PreviewDescription", in: image)
        let initialize = try await descriptionType.resolveInitializer(
            named: "init(index: Swift.Int, contentType: Swift.String, device: Swift.String?, displayName: Swift.String?, layout: PreviewsMessagingOS.PreviewTraits.Layout, contentDomain: PreviewsMessagingOS.PreviewContentDomain, supportsLive: Swift.Bool, supportsOnDevice: Swift.Bool, interfaceOrientation: PreviewsMessagingOS.PreviewTraits.Orientation, contentCategory: PreviewsMessagingOS.ContentCategory) -> PreviewsMessagingOS.PreviewDescription",
            as: ((Int, String, String?, String?, NativeSwiftValue, NativeSwiftValue, Bool, Bool, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [layout.type: .opaque(named: layout.type.name), domainType: .opaque(named: domainType.name),
                orientation.type: .opaque(named: orientation.type.name), categoryType: .opaque(named: categoryType.name),
                descriptionType: .opaque(named: descriptionType.name)])
        let description = try unsafe initialize.unsafeInvoke(preview.id, preview.contentType,
            preview.device?.rawValue, preview.displayName, layout, domain.copy(), true, onDevice, orientation, category.copy())
        let traitsType = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.PreviewTraits", in: image)
        let traitsGetter = try await descriptionType.resolveGetter(named: "previewTraits", as: (() -> NativeSwiftValue).self,
            valueABIs: [traitsType: .opaque(named: traitsType.name)], receiverABI: .opaque(named: descriptionType.name))
        let traits = try unsafe traitsGetter.unsafeInvoke(on: description)
        let metadata = try await makeNativePreviewMetadata(domain: domain, category: category,
            onDevice: onDevice, interactive: true, traits: traits, group: false, displayName: preview.displayName)
        return (try await nativePreviewPropertyListData(metadata), try await nativePreviewPropertyListData(description))
    } catch is ABIResolutionError {
        throw NativePreviewPipelineRequired()
    }
}

@MainActor
private func legacyPreviewLayout(_ layout: DeveloperToolsSupport.PreviewLayout) async throws -> NativeSwiftValue {
    let type = try await ABIRuntime.shared.resolveSwiftType(named: "PreviewsMessagingOS.PreviewTraits.Layout",
        in: .framework(named: "PreviewsMessagingOS"))
    switch layout {
    case .device: return try type.makeEnumCase(named: "device")
    case .sizeThatFits: return try type.makeEnumCase(named: "sizeThatFits")
    case .fixed(let width, let height):
        return try await type.makeEnumCase(named: "fixed", payload: ownedPreviewValue((width: CGFloat(width), height: CGFloat(height))))
    default: throw NativePreviewPipelineRequired()
    }
}

@MainActor
private func legacyPreviewOrientation(_ preview: SwiftUI._Preview) async throws -> NativeSwiftValue {
    let type = try await ABIRuntime.shared.resolveSwiftType(named: "PreviewsMessagingOS.PreviewTraits.Orientation",
        in: .framework(named: "PreviewsMessagingOS"))
    #if os(macOS) || os(tvOS) || os(watchOS)
    // These native provider producers supply portrait rather than converting
    // the source orientation.
    return try type.makeEnumCase(named: "portrait")
    #else
    let source = try await ownedPreviewValue(preview.interfaceOrientation)
    let declaration = "(extension in PreviewsOSSupportUI):SwiftUI.InterfaceOrientation.previewOrientation.getter : PreviewsMessagingOS.PreviewTraits.Orientation"
    let support = try await ABIRuntime.shared.resolve(.init(name: declaration, language: .swift),
        in: .framework(named: "PreviewsOSSupportUI"))
    let getter = try await source.type.resolveGetter(named: declaration, as: (() -> NativeSwiftValue).self,
        valueABIs: [type: .opaque(named: type.name)], receiverABI: .opaque(named: source.type.name))
    return try withExtendedLifetime(support) { try unsafe getter.unsafeInvoke(on: source) }
    #endif
}

#if os(watchOS)
@MainActor
private func legacyComplicationCategory(_ sourceCategoryType: NativeSwiftType) async throws -> NativeSwiftValue {
    let runtime = ABIRuntime.shared
    let type = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.ContentCategory",
        in: .framework(named: "PreviewsMessagingOS"))
    let getter = try await type.resolveStaticGetter(named: "complicationPreviewInstance.getter : PreviewsMessagingOS.ContentCategory",
        as: (() -> NativeSwiftValue).self, valueABIs: [type: .opaque(named: type.name)])
    let category = try unsafe getter.unsafeInvoke()
    let rawValue = try await type.resolveGetter(named: "rawValue.getter : Swift.String", as: (() -> String).self,
        receiverABI: .opaque(named: type.name))
    let initialize = try await sourceCategoryType.resolveInitializer(
        named: "init(stringLiteral: Swift.String) -> DeveloperToolsSupport.PreviewSourceContentCategory",
        as: ((String) -> NativeSwiftValue).self,
        valueABIs: [sourceCategoryType: .opaque(named: sourceCategoryType.name)])
    return try unsafe initialize.unsafeInvoke(rawValue.unsafeInvoke(on: category))
}
#endif

@MainActor
private func legacyWidgetCategory(_ context: any PreviewContext) async throws -> NativeSwiftValue? {
    // Native PreviewsInjection loads WidgetKit even for non-Widget contexts.
    _ = try await ABIRuntime.shared.resolveSwiftType(named: "WidgetKit.WidgetPreviewContextKey",
        in: .framework(named: "WidgetKit"))
    guard let key = _typeByName("9WidgetKit0A17PreviewContextKeyV") as? any PreviewContextKey.Type else {
        throw NativePreviewPipelineRequired()
    }
    @MainActor func read<Key: PreviewContextKey>(_ key: Key.Type) async throws -> NativeSwiftValue? {
        let optional = try await ownedPreviewValue(context[key])
        guard let value = try await optional.resolveEnumPayload(forCase: "some") else { return nil }
        let categoryType = try await ABIRuntime.shared.resolveSwiftType(named: "DeveloperToolsSupport.PreviewSourceContentCategory",
            in: .framework(named: "DeveloperToolsSupport"))
        let getter = try await value.type.resolveGetter(named: "previewContentCategory", as: (() -> NativeSwiftValue).self,
            valueABIs: [categoryType: .opaque(named: categoryType.name)], receiverABI: .opaque(named: value.type.name))
        return try unsafe getter.unsafeInvoke(on: value)
    }
    return try await _openExistential(key, do: read)
}
#endif
