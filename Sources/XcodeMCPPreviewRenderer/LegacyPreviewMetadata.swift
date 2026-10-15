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
        if let context = preview.context, let category = try await legacyPreviewContextCategory(context) {
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
            in: previewFrameworkImage(named: "PreviewsOSSupportUI"))
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
        return try await nativeLegacyPreviewMetadata(description: description)
    } catch is ABIResolutionError {
        throw NativePreviewPipelineRequired()
    }
}

@MainActor
func nativeLegacyPreviewMetadata(description: NativeSwiftValue) async throws -> (metadata: Data, providerDescription: Data?) {
    let runtime = ABIRuntime.shared
    let image = ImageSelector.framework(named: "PreviewsMessagingOS")
    func value(_ name: String, typeName: String) async throws -> NativeSwiftValue {
        let type = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.\(typeName)", in: image)
        let getter = try await description.type.resolveGetter(named: name, as: (() -> NativeSwiftValue).self,
            valueABIs: [type: .opaque(named: type.name)], receiverABI: .opaque(named: description.type.name))
        return try unsafe getter.unsafeInvoke(on: description)
    }
    func flag(_ name: String) async throws -> Bool {
        let getter = try await description.type.resolveGetter(named: name, as: (() -> Bool).self,
            receiverABI: .opaque(named: description.type.name))
        return try unsafe getter.unsafeInvoke(on: description)
    }
    let domain = try await value("contentDomain", typeName: "PreviewContentDomain")
    let categoryType = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.ContentCategory", in: image)
    let optionalCategoryType = try await runtime.resolveSwiftType(named: "Swift.Optional",
        genericArguments: [.type(categoryType)])
    // The getter returns an Optional on older runtimes. Bind its actual
    // declaration before projecting the owned value into the metadata category.
    let categoryGetter = try await description.type.resolveGetter(named: "contentCategory",
        as: (() -> NativeSwiftValue).self,
        valueABIs: [categoryType: .opaque(named: categoryType.name),
            optionalCategoryType: .opaque(named: optionalCategoryType.name)],
        receiverABI: .opaque(named: description.type.name))
    let returnedCategory = try unsafe categoryGetter.unsafeInvoke(on: description)
    let category: NativeSwiftValue
    if returnedCategory.type == optionalCategoryType {
        guard let payload = try await returnedCategory.resolveEnumPayload(forCase: "some") else {
            throw PreviewRendererError("The native preview description is missing its content category")
        }
        category = payload
    } else {
        category = returnedCategory
    }
    let traits = try await value("previewTraits", typeName: "PreviewTraits")
    let onDevice = try await flag("supportsOnDevice")
    let interactive = try await flag("supportsLive")
    let displayNameGetter = try await description.type.resolveGetter(named: "displayName", as: (() -> String?).self,
        receiverABI: .opaque(named: description.type.name))
    let displayName = try unsafe displayNameGetter.unsafeInvoke(on: description)
    let metadata = try await makeNativePreviewMetadata(domain: domain, category: category,
        onDevice: onDevice, interactive: interactive, traits: traits, group: false, displayName: displayName)
    return (try await nativePreviewPropertyListData(metadata), try await nativePreviewPropertyListData(description))
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
        in: previewFrameworkImage(named: "PreviewsOSSupportUI"))
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
func legacyPreviewContextCategory(_ context: any PreviewContext) async throws -> NativeSwiftValue? {
    do {
        let widget = try await legacyPreviewContextValue(context,
            keyName: "WidgetKit.WidgetPreviewContextKey", mangledName: "9WidgetKit0A17PreviewContextKeyV")
        var category: NativeSwiftValue?
        if let widget { category = try await previewContextCategory(widget) }
        #if os(iOS) && targetEnvironment(simulator)
        if isLegacyActivityPreviewContext(context) {
            // Reading this context's Activity key requires Widget.main's provider.
            // Its category getter and this static factory produce the same category.
            let declaration = "static (extension in WidgetKit):DeveloperToolsSupport.PreviewSourceContentCategory.activityWidget.getter : DeveloperToolsSupport.PreviewSourceContentCategory"
            let runtime = ABIRuntime.shared
            let support = try await runtime.resolve(.init(name: declaration, language: .swift),
                in: previewFrameworkImage(named: "WidgetKit"))
            let type = try await runtime.resolveSwiftType(named: "DeveloperToolsSupport.PreviewSourceContentCategory",
                in: .framework(named: "DeveloperToolsSupport"))
            let getter = try await type.resolveStaticGetter(named: declaration, as: (() -> NativeSwiftValue).self,
                valueABIs: [type: .opaque(named: type.name)])
            return try withExtendedLifetime(support) { try unsafe getter.unsafeInvoke() }
        }
        if let activity = try await legacyPreviewContextValue(context,
            keyName: "WidgetKit.ActivityPreviewContextKey", mangledName: "9WidgetKit25ActivityPreviewContextKeyV") {
            // Native metadata reads Activity after Widget, so Activity takes precedence.
            category = try await previewContextCategory(activity)
        }
        #endif
        return category
    } catch is ABIResolutionError { throw NativePreviewPipelineRequired() }
}

@MainActor
private func previewContextCategory(_ value: NativeSwiftValue) async throws -> NativeSwiftValue {
    let categoryType = try await ABIRuntime.shared.resolveSwiftType(named: "DeveloperToolsSupport.PreviewSourceContentCategory",
        in: .framework(named: "DeveloperToolsSupport"))
    let getter = try await value.type.resolveGetter(named: "previewContentCategory", as: (() -> NativeSwiftValue).self,
        valueABIs: [categoryType: .opaque(named: categoryType.name)], receiverABI: .opaque(named: value.type.name))
    return try unsafe getter.unsafeInvoke(on: value)
}

#if os(iOS) && targetEnvironment(simulator)
func isLegacyActivityPreviewContext(_ context: any PreviewContext) -> Bool {
    String(reflecting: type(of: context)).hasPrefix("WidgetKit.ActivityPreviewContext<")
}
#endif

@MainActor
func legacyPreviewContextValue(_ context: any PreviewContext, keyName: String, mangledName: String) async throws -> NativeSwiftValue? {
    // Native PreviewsInjection loads WidgetKit even for non-Widget contexts.
    do {
        _ = try await ABIRuntime.shared.resolveSwiftType(named: keyName,
            in: previewFrameworkImage(named: "WidgetKit"))
        guard let key = _typeByName(mangledName) as? any PreviewContextKey.Type else {
            throw NativePreviewPipelineRequired()
        }
        @MainActor func read<Key: PreviewContextKey>(_ key: Key.Type) async throws -> NativeSwiftValue? {
            let optional = try await ownedPreviewValue(context[key])
            return try await optional.resolveEnumPayload(forCase: "some")
        }
        return try await _openExistential(key, do: read)
    } catch is ABIResolutionError { throw NativePreviewPipelineRequired() }
}
#endif
