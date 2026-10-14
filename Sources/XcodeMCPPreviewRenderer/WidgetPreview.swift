#if os(iOS) && targetEnvironment(simulator)
import ABIBridge
import Darwin
import SwiftUI
import UIKit
import WidgetKit

@MainActor
struct WidgetPreview {
    let view: AnyView
    let size: CGSize
    let cornerRadius: CGFloat
    let timelineIndexes: [Int]
    let supportedFamilies: [String]
    fileprivate let background: WidgetBackground

    func validate() throws { try background.validate() }
}

@MainActor
func makeWidgetPreview(source: NativeSwiftValue, family: String?, timelineEntryIndex: Int?) async throws -> WidgetPreview {
    let makeGetter = try await source.type.resolveGetter(named: "makeWidget",
        as: (() -> NativeSwiftClosure<() -> NativeSwiftValue>).self, receiverABI: .opaque(named: source.type.name))
    let make = try unsafe makeGetter.unsafeInvoke(on: source)
    let widget = try unsafe make.unsafeInvoke()
    guard let swiftWidget = try widget.withCopy({ $0 as? any Widget }) else { throw NativePreviewPipelineRequired() }
    func configuration<W: Widget>(_ widget: W) async throws -> NativeSwiftValue { try await widgetValue(widget.body) }
    let fullConfiguration = try await _openExistential(swiftWidget, do: configuration)
    let descriptor = try await widgetConfigurationDescriptor(fullConfiguration)
    var configuration = fullConfiguration
    if configuration.type.name == "SwiftUI.ModifiedContent" {
        let base = try await configuration.type.resolveGetter(named: "baseConfiguration", as: (() -> NativeSwiftValue).self,
            receiverABI: .opaque(named: configuration.type.name))
        let existential = try unsafe base.unsafeInvoke(on: configuration)
        configuration = try existential.copyUnderlyingValue()
    }

    let publicFamilyType = try await widgetType("WidgetKit.WidgetFamily")
    let familyValue: NativeSwiftValue
    if let family {
        switch family {
        case "Small": familyValue = try await widgetValue(WidgetFamily.systemSmall)
        case "Medium": familyValue = try await widgetValue(WidgetFamily.systemMedium)
        default: throw NativePreviewPipelineRequired()
        }
    } else {
        let getter = try await source.type.resolveGetter(named: "family", as: (() -> NativeSwiftValue).self,
            valueABIs: [publicFamilyType: .opaque(named: publicFamilyType.name)], receiverABI: .opaque(named: source.type.name))
        familyValue = try unsafe getter.unsafeInvoke(on: source)
    }
    let selectedFamily = try familyValue.withCopy { value in
        guard let family = value as? WidgetFamily else { throw NativePreviewPipelineRequired() }
        return family
    }
    guard [.systemSmall, .systemMedium].contains(selectedFamily) else {
        throw NativePreviewPipelineRequired()
    }
    let internalType = try await widgetType("WidgetKit.InternalWidgetFamily")
    let familyInit = try await internalType.resolveInitializer(named: "init(WidgetKit.WidgetFamily) -> WidgetKit.InternalWidgetFamily",
        as: ((NativeSwiftValue) -> NativeSwiftValue).self,
        valueABIs: [publicFamilyType: .opaque(named: publicFamilyType.name), internalType: .opaque(named: internalType.name)])
    let internalFamily = try unsafe familyInit.unsafeInvoke(familyValue)
    let familyGetter = try await internalType.resolveGetter(named: "chsWidgetFamily.getter : __C.CHSWidgetFamily",
        as: (() -> Int).self, receiverABI: .opaque(named: internalType.name))
    let rawFamily = try unsafe familyGetter.unsafeInvoke(on: internalFamily)
    guard descriptor.families.contains(rawFamily) else { throw NativePreviewPipelineRequired() }
    let (providedWidget, providedMetrics) = try await widgetIdentity(kind: descriptor.kind, family: rawFamily)

    let swiftEnvironment = try await widgetValue(EnvironmentValues())
    let widgetSetter = try await swiftEnvironment.type.resolveSetter(
        named: "(extension in WidgetKit):SwiftUI.EnvironmentValues.widget.setter : Swift.Optional<__C.CHSWidget>",
        as: (AnyObject?).self, receiverABI: .opaque(named: swiftEnvironment.type.name))
    try unsafe widgetSetter.unsafeInvoke(on: swiftEnvironment, providedWidget)
    let metricsSetter = try await swiftEnvironment.type.resolveSetter(
        named: "(extension in WidgetKit):SwiftUI.EnvironmentValues._widgetMetrics.setter : __C.CHSWidgetMetrics",
        as: AnyObject.self, receiverABI: .opaque(named: swiftEnvironment.type.name))
    try unsafe metricsSetter.unsafeInvoke(on: swiftEnvironment, providedMetrics)
    let familySetter = try await swiftEnvironment.type.resolveSetter(
        named: "(extension in WidgetKit):SwiftUI.EnvironmentValues._widgetFamily.setter : WidgetKit.InternalWidgetFamily",
        as: NativeSwiftValue.self, valueABIs: [internalType: .opaque(named: internalType.name)],
        receiverABI: .opaque(named: swiftEnvironment.type.name))
    try unsafe familySetter.unsafeInvoke(on: swiftEnvironment, internalFamily.copy())
    let environmentType = try await widgetType("WidgetKit.WidgetEnvironment")
    let environmentInit = try await environmentType.resolveInitializer(
        named: "init(from: SwiftUI.EnvironmentValues) -> WidgetKit.WidgetEnvironment", as: ((NativeSwiftValue) -> NativeSwiftValue).self,
        valueABIs: [swiftEnvironment.type: .opaque(named: swiftEnvironment.type.name), environmentType: .opaque(named: environmentType.name)])
    let environment = try unsafe environmentInit.unsafeInvoke(swiftEnvironment.copy())
    let variantsType = try await widgetType("WidgetKit.TimelineProviderContext.EnvironmentVariants")
    let variantsInit = try await variantsType.resolveInitializer(
        named: "init(WidgetKit.WidgetEnvironment) -> WidgetKit.TimelineProviderContext.EnvironmentVariants",
        as: ((NativeSwiftValue) -> NativeSwiftValue).self,
        valueABIs: [environmentType: .opaque(named: environmentType.name), variantsType: .opaque(named: variantsType.name)])
    let variants = try unsafe variantsInit.unsafeInvoke(environment)
    let contextType = try await widgetType("WidgetKit.TimelineProviderContext")
    let contextInit = try await contextType.resolveInitializer(named: "init(environmentVariants:family:isPreview:personaIdentifier:)",
        as: ((NativeSwiftValue, NativeSwiftValue, Bool, String?) -> NativeSwiftValue).self,
        valueABIs: [variantsType: .opaque(named: variantsType.name), internalType: .opaque(named: internalType.name),
                    contextType: .opaque(named: contextType.name)])
    let context = try unsafe contextInit.unsafeInvoke(variants, internalFamily, true, nil)
    let collection = try await widgetTimeline(configuration: configuration, source: source, context: context)
    guard let sequence = try collection.withCopy({ $0 as? any Sequence }) else { throw NativePreviewPipelineRequired() }
    func entries<S: Sequence>(_ sequence: S) -> [Any] { sequence.map { $0 as Any } }
    let values = _openExistential(sequence, do: entries)
    let selectedIndex = timelineEntryIndex ?? 0
    guard values.indices.contains(selectedIndex) else {
        throw PreviewRendererError("Widget timeline entry \(selectedIndex) is unavailable; available indexes: \(Array(values.indices))")
    }
    let entry = try await widgetAnyValue(values[selectedIndex])
    let anyViewType = try await widgetValue(AnyView(EmptyView())).type
    let viewGetter = try await entry.type.resolveGetter(named: "view", as: (() -> NativeSwiftValue).self,
        valueABIs: [anyViewType: .pointer], receiverABI: .opaque(named: entry.type.name))
    let nativeView = try unsafe viewGetter.unsafeInvoke(on: entry)
    let view = try nativeView.take(as: AnyView.self)
    let widgetGetter = try await collection.type.resolveGetter(named: "widget", as: (() -> NativeSwiftValue).self)
    let metricsGetter = try await collection.type.resolveGetter(named: "metrics", as: (() -> NativeSwiftValue).self)
    let nativeIdentity = try unsafe widgetGetter.unsafeInvoke(on: collection)
    let nativeMetrics = try unsafe metricsGetter.unsafeInvoke(on: collection)
    let identity = try nativeIdentity.withCopy { $0 as AnyObject }
    let metrics = try nativeMetrics.withCopy { $0 as AnyObject }
    let sizeGetter = try await ABIRuntime.shared.object(metrics).resolveMethod(selector: "size", as: (() -> CGSize).self)
    let size = try unsafe sizeGetter.unsafeInvoke()
    let radiusGetter = try await ABIRuntime.shared.object(metrics).resolveMethod(selector: "cornerRadius", as: (() -> Double).self)
    let radius = try unsafe radiusGetter.unsafeInvoke()
    let typedEnvironment = try swiftEnvironment.withCopy { value in
        guard let environment = value as? EnvironmentValues else { throw NativePreviewPipelineRequired() }
        return environment
    }
    let modifierEnvironment = try await widgetValue(Optional.some(typedEnvironment))
    let modifierType = try await widgetType("WidgetKit.CommonServerEnvironmentModifier")
    let modifierInit = try await modifierType.resolveInitializer(
        named: "init(widget: __C.CHSWidget, metrics: __C.CHSWidgetMetrics, environment: Swift.Optional<SwiftUI.EnvironmentValues>, applyWidgetIdiom: Swift.Bool) -> WidgetKit.CommonServerEnvironmentModifier",
        as: ((AnyObject, AnyObject, NativeSwiftValue, Bool) -> NativeSwiftValue).self,
        valueABIs: [modifierEnvironment.type: .opaque(named: modifierEnvironment.type.name), modifierType: .opaque(named: modifierType.name)])
    let nativeModifier = try unsafe modifierInit.unsafeInvoke(identity, metrics, modifierEnvironment, true)
    guard let modifier = try nativeModifier.withCopy({ $0 as? any ViewModifier }) else { throw NativePreviewPipelineRequired() }
    func apply<M: ViewModifier>(_ modifier: M) -> AnyView { AnyView(view.modifier(modifier)) }
    let modified = _openExistential(modifier, do: apply)
    let background = WidgetBackground()
    let hosted = try widgetBackground(AnyView(modified.frame(width: size.width, height: size.height)), state: background)
    var supported: [String] = []
    for (name, publicFamily) in [("Small", WidgetFamily.systemSmall), ("Medium", WidgetFamily.systemMedium)] {
        let value = try await widgetValue(publicFamily)
        let internalValue = try unsafe familyInit.unsafeInvoke(value)
        let raw = try unsafe familyGetter.unsafeInvoke(on: internalValue)
        if descriptor.families.contains(raw) { supported.append(name) }
    }
    return WidgetPreview(view: hosted, size: size, cornerRadius: CGFloat(radius),
        timelineIndexes: Array(values.indices), supportedFamilies: supported, background: background)
}

@MainActor
private func widgetValue<Value>(_ value: Value) async throws -> NativeSwiftValue {
    let identity = try await ABIRuntime.shared.resolveSwiftFunction(named: "XcodeMCPPreviewRenderer.previewValue<A>(A) -> A",
        as: ((Value) -> NativeSwiftValue).self, genericArguments: [.type(Value.self)])
    return try unsafe identity.unsafeInvoke(value)
}

@MainActor
private func widgetAnyValue(_ value: Any) async throws -> NativeSwiftValue {
    func open<Value>(_ value: Value) async throws -> NativeSwiftValue { try await widgetValue(value) }
    return try await _openExistential(value, do: open)
}

private func widgetType(_ name: String) async throws -> NativeSwiftType {
    try await ABIRuntime.shared.resolveSwiftType(named: name, in: .framework(named: "WidgetKit"))
}

@MainActor
private final class WidgetMetricsDelegate: NSObject {
    @objc let listLayoutProvider: AnyObject
    init(_ listLayoutProvider: AnyObject) { self.listLayoutProvider = listLayoutProvider }
}

@MainActor
private func widgetObject(_ name: String, framework: String) async throws -> AnyObject {
    if NSClassFromString(name) == nil {
        guard unsafe dlopen("/System/Library/PrivateFrameworks/\(framework).framework/\(framework)", RTLD_NOW | RTLD_GLOBAL) != nil else {
            throw NativePreviewPipelineRequired()
        }
    }
    guard let type = NSClassFromString(name) else { throw NativePreviewPipelineRequired() }
    let allocate = try await ABIRuntime.shared.object(type as AnyObject).resolveMethod(selector: "alloc", as: (() -> AnyObject).self)
    return try unsafe allocate.unsafeInvoke()
}

@MainActor
private func widgetIdentity(kind: String, family: Int) async throws -> (AnyObject, AnyObject) {
    guard let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen,
          let bundleIdentifier = Bundle.main.bundleIdentifier else { throw NativePreviewPipelineRequired() }
    let allocatedProvider = try await widgetObject("SBHWidgetMetricsProvider", framework: "SpringBoardHome")
    let screenType = try await ABIRuntime.shared.object(screen).resolveMethod(selector: "sbh_screenType", as: (() -> UInt64).self)
    let providerInit = try await ABIRuntime.shared.object(allocatedProvider).resolveMethod(selector: "initWithScreenType:",
        as: ((UInt64) -> AnyObject).self)
    let provider = try unsafe providerInit.unsafeInvoke(screenType.unsafeInvoke())
    let allocatedLayout = try await widgetObject("SBHDefaultIconListLayoutProvider", framework: "SpringBoardHome")
    let layoutInit = try await ABIRuntime.shared.object(allocatedLayout).resolveMethod(selector: "initWithScreen:",
        as: ((AnyObject) -> AnyObject).self)
    let layout = try unsafe layoutInit.unsafeInvoke(screen)
    let delegate = WidgetMetricsDelegate(layout)
    let setDelegate = try await ABIRuntime.shared.object(provider).resolveMethod(selector: "setDelegate:", as: ((AnyObject) -> Void).self)
    try unsafe setDelegate.unsafeInvoke(delegate)
    let factory = try await ABIRuntime.shared.object(provider).resolveMethod(selector: "systemMetricsForFamily:",
        as: ((Int64) -> AnyObject?).self)
    guard let metrics = try unsafe factory.unsafeInvoke(Int64(family)) else { throw NativePreviewPipelineRequired() }
    withExtendedLifetime(delegate) {}
    let allocatedWidget = try await widgetObject("CHSWidget", framework: "ChronoServices")
    let widgetInit = try await ABIRuntime.shared.object(allocatedWidget).resolveMethod(
        selector: "initWithExtensionBundleIdentifier:kind:family:intent:",
        as: ((String, String, Int64, AnyObject?) -> AnyObject).self)
    let widget = try unsafe widgetInit.unsafeInvoke(bundleIdentifier, kind, Int64(family), nil)
    return (widget, metrics)
}

// The callback may arrive off actor. Transfer one owned copy through the lock;
// cancellation discards late callbacks without giving them renderer state.
private final class WidgetTimelineMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<NativeSwiftValue, any Error>?
    private var finished = false
    func put(_ value: Result<NativeSwiftValue, any Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        result = value
    }
    func take() -> Result<NativeSwiftValue, any Error>? {
        lock.lock(); defer { lock.unlock() }
        defer { result = nil }
        return result
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        finished = true
        result = nil
    }
}

@MainActor
private func widgetTimeline(configuration: NativeSwiftValue, source: NativeSwiftValue,
                            context: NativeSwiftValue) async throws -> NativeSwiftValue {
    let mailbox = WidgetTimelineMailbox()
    let callback = try NativeSwiftClosure<(NativeSwiftValue) -> Void> { value in
        do { mailbox.put(.success(try value.copy())) }
        catch { mailbox.put(.failure(error)) }
    }
    defer { mailbox.cancel(); withExtendedLifetime(callback) {} }
    let collectionType = try await widgetType("WidgetKit.WidgetViewCollection")
    let resultType = try await ABIRuntime.shared.resolveSwiftType(named: "Swift.Result",
        genericArguments: [.type(collectionType), .type((any Error).self)])
    // The arm64 Swift ABI for Result<native class, Error> is a pointer and i8 tag.
    let resultABI = try NativeType.structure(named: resultType.name, fields: [.uint64, .uint8])
    let timeline = try await configuration.type.resolveMethod(named: "previewTimeline(source:with:completion:)",
        as: ((NativeSwiftValue, NativeSwiftValue, NativeSwiftClosure<(NativeSwiftValue) -> Void>) -> Void).self,
        genericArguments: [.type(source.type)],
        valueABIs: [source.type: .opaque(named: source.type.name), context.type: .opaque(named: context.type.name), resultType: resultABI],
        receiverABI: .opaque(named: configuration.type.name))
    try Task.checkCancellation()
    try unsafe timeline.unsafeInvoke(on: configuration, source, context, callback)
    while true {
        try Task.checkCancellation()
        if let completion = mailbox.take() {
            let result = try completion.get()
            if let success = try await result.resolveEnumPayload(forCase: "success") { return success }
            guard let failure = try await result.resolveEnumPayload(forCase: "failure"),
                  let error = try failure.withCopy({ $0 as? any Error }) else { throw NativePreviewPipelineRequired() }
            throw error
        }
        try await Task.sleep(for: .milliseconds(25))
    }
}

@MainActor
fileprivate final class WidgetBackground {
    var failure: (any Error)?
    func validate() throws { if let failure { throw failure } }
}

@MainActor
private func widgetBackground(_ view: AnyView, state: WidgetBackground) throws -> AnyView {
    guard let preferenceType = _typeByName("7SwiftUI23ContainerBackgroundKeysO9CustomKeyV") as? any PreferenceKey.Type,
          let placementType = _typeByName("7SwiftUI28ContainerBackgroundPlacementV9WidgetKitE0F3KeyV") else {
        throw NativePreviewPipelineRequired()
    }
    func open<Key: PreferenceKey>(_ key: Key.Type) -> AnyView {
        let transform: (Key.Value) -> AnyView?? = { value in
            do {
                guard let field = Mirror(reflecting: value).children.first(where: { $0.label == "views" }),
                      let views = field.value as? [AnyHashable: AnyView] else { throw NativePreviewPipelineRequired() }
                for (key, background) in views {
                    guard let field = Mirror(reflecting: key.base).children.first(where: { $0.label == "type" }),
                          let type = field.value as? Any.Type else { throw NativePreviewPipelineRequired() }
                    if ObjectIdentifier(type) == ObjectIdentifier(placementType) { return .some(.some(background)) }
                }
                return .some(nil)
            } catch {
                if state.failure == nil { state.failure = error }
                return .some(nil)
            }
        }
        return AnyView(view.modifier(_BackgroundPreferenceModifier<Key, AnyView??>(alignment: .center, transform: transform)))
    }
    return _openExistential(preferenceType, do: open)
}

@MainActor
private struct WidgetConfigurationDescriptor {
    let kind: String
    let families: [Int]
}

@MainActor
private func widgetConfigurationDescriptor(_ configuration: NativeSwiftValue) async throws -> WidgetConfigurationDescriptor {
    func unwrap(_ value: Any) throws -> (base: Any, modifiers: [Any]) {
        guard String(reflecting: type(of: value)).hasPrefix("SwiftUI.ModifiedContent<") else { return (value, []) }
        let fields = Mirror(reflecting: value).children
        guard let content = fields.first(where: { $0.label == "content" })?.value,
              let modifier = fields.first(where: { $0.label == "modifier" })?.value else {
            throw NativePreviewPipelineRequired()
        }
        let inner = try unwrap(content)
        return (inner.base, inner.modifiers + [modifier])
    }
    let unwrapped = try configuration.withCopy { try unwrap($0) }
    guard String(reflecting: type(of: unwrapped.base)).hasPrefix("WidgetKit.StaticConfiguration<"),
          let base = unwrapped.base as? any WidgetConfiguration else { throw NativePreviewPipelineRequired() }
    func seed<Configuration: WidgetConfiguration>(_ configuration: Configuration) throws -> Any {
        guard let descriptor = Mirror(reflecting: configuration.body).children.first(where: { $0.label == "descriptor" })?.value,
              String(reflecting: type(of: descriptor)) == "WidgetKit.WidgetDescriptor" else {
            throw NativePreviewPipelineRequired()
        }
        return descriptor
    }
    let descriptor = try _openExistential(base, do: seed)
    guard let keyType = _typeByName("9WidgetKit0A13DescriptorKeyV") as? any PreferenceKey.Type else {
        throw NativePreviewPipelineRequired()
    }
    func apply<Key: PreferenceKey>(_ key: Key.Type) throws -> WidgetConfigurationDescriptor {
        guard var descriptors = [descriptor] as? Key.Value else { throw NativePreviewPipelineRequired() }
        for modifier in unwrapped.modifiers {
            guard let transform = modifier as? _PreferenceTransformModifier<Key> else { throw NativePreviewPipelineRequired() }
            transform.transform(&descriptors)
        }
        let values = Mirror(reflecting: descriptors).children.map(\.value)
        guard values.count == 1 else { throw NativePreviewPipelineRequired() }
        let fields = Mirror(reflecting: values[0]).children
        let originalFields = Mirror(reflecting: descriptor).children
        guard let source = fields.first(where: { $0.label == "source" })?.value,
              let timeline = Mirror(reflecting: source).children.first(where: { $0.label == "timeline" })?.value,
              let kind = Mirror(reflecting: timeline).children.first(where: { $0.label == "kind" })?.value as? String,
              let families = fields.first(where: { $0.label == "supportedFamilies" })?.value,
              let marginsDisabled = fields.first(where: { $0.label == "contentMarginsDisabled" })?.value as? Bool,
              !marginsDisabled else { throw NativePreviewPipelineRequired() }
        // Descriptor-driven background styles require the native widget host.
        guard let originalStyle = originalFields.first(where: { $0.label == "preferredBackgroundStyle" })?.value as? AnyHashable,
              let modifiedStyle = fields.first(where: { $0.label == "preferredBackgroundStyle" })?.value as? AnyHashable,
              originalStyle == modifiedStyle else { throw NativePreviewPipelineRequired() }
        let rawFamilies = try Mirror(reflecting: families).children.map { try widgetRawInteger($0.value) }
        return WidgetConfigurationDescriptor(kind: kind, families: rawFamilies)
    }
    return try _openExistential(keyType, do: apply)
}

private func widgetRawInteger(_ value: Any) throws -> Int {
    guard let value = value as? any RawRepresentable else { throw NativePreviewPipelineRequired() }
    func raw<Value: RawRepresentable>(_ value: Value) throws -> Int {
        guard let number = value.rawValue as? any BinaryInteger else { throw NativePreviewPipelineRequired() }
        func integer<Number: BinaryInteger>(_ value: Number) throws -> Int {
            guard let value = Int(exactly: value) else { throw NativePreviewPipelineRequired() }
            return value
        }
        return try _openExistential(number, do: integer)
    }
    return try _openExistential(value, do: raw)
}

#endif
