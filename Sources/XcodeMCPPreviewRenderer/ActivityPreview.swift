#if os(iOS) && targetEnvironment(simulator)
import ABIBridge
import ABIBridgeCore
import ActivityKit
import Foundation
import SwiftUI
import UIKit
import WidgetKit

@MainActor
struct ActivityPreview {
    let controller: UIViewController
    let stateIndexes: [Int]
    let selectedStateIndex: Int
    let isStale: Bool
    let viewKind: ActivityPreviewViewKind
    let interfaceOrientation: UIInterfaceOrientation
    let cornerRadius: CGFloat
    let errors: [String]

    // The native controller supplies this after it participates in UIKit layout.
    var preferredContentSize: CGSize { controller.preferredContentSize }
}

@MainActor
func makeActivityPreview(source: NativeSwiftValue, timelineIndex: Int?, viewStyle: String?,
                         isStale: Bool, addStaleEntries: Bool,
                         environment: EnvironmentValues, appName: String,
                         payloadID: String) async throws -> ActivityPreview {
    let attributes = try source.withCopy { value -> any ActivityAttributes in
        guard let value = Mirror(reflecting: value).children.first(where: { $0.label == "attributes" })?.value,
              let attributes = value as? any ActivityAttributes else { throw NativePreviewPipelineRequired() }
        return attributes
    }
    @MainActor func open<Attributes: ActivityAttributes>(_ attributes: Attributes) async throws -> ActivityPreview {
        try await activityPreview(source: source, attributesType: Attributes.self, stateIndex: timelineIndex,
            isStale: isStale, environment: environment, appName: appName, payloadID: payloadID,
            viewStyle: viewStyle, addStaleEntries: addStaleEntries)
    }
    return try await _openExistential(attributes, do: open)
}

@MainActor
private func activityPreview<Attributes: ActivityAttributes>(source: NativeSwiftValue,
    attributesType: Attributes.Type, stateIndex: Int?, isStale: Bool,
    environment: EnvironmentValues, appName: String, payloadID: String,
    viewStyle: String?, addStaleEntries: Bool) async throws -> ActivityPreview {
    let makeWidgetGetter = try await source.type.resolveGetter(named: "makeWidget",
        as: (() -> NativeSwiftClosure<() -> NativeSwiftValue>).self, receiverABI: .opaque(named: source.type.name))
    let makeWidget = try unsafe makeWidgetGetter.unsafeInvoke(on: source)
    let widget = try unsafe makeWidget.unsafeInvoke()
    guard let typedWidget = try widget.withCopy({ $0 as? any Widget }) else { throw NativePreviewPipelineRequired() }
    @MainActor func body<W: Widget>(_ widget: W) async throws -> NativeSwiftValue { try await activityValue(widget.body) }
    let configuration = try await _openExistential(typedWidget, do: body)
    let descriptor = try await activityDescriptor(configuration)
    let descriptorFields = Mirror(reflecting: descriptor).children
    guard let viewSourceEnum = descriptorFields.first(where: { $0.label == "source" })?.value,
          let activitySource = Mirror(reflecting: viewSourceEnum).children.first(where: { $0.label == "activity" })?.value,
          let activityType = Mirror(reflecting: activitySource).children.first(where: { $0.label == ".0" })?.value,
          let viewSource = Mirror(reflecting: activitySource).children.first(where: { $0.label == ".1" })?.value,
          let families = descriptorFields.first(where: { $0.label == "supportedActivityFamilies" })?.value,
          let layouts = descriptorFields.first(where: { $0.label == "supportedDynamicIslandCompactLayouts" })?.value
    else { throw NativePreviewPipelineRequired() }
    let nativeActivityType = try await activityAnyValue(activityType)
    let nativeViewSource = try await activityAnyValue(viewSource)
    let nativeFamilies = try await activityAnyValue(families)
    let nativeLayouts = try await activityAnyValue(layouts)

    let makeContent = try await source.type.resolveMethod(named: "makeContent(for:)",
        as: ((Attributes.Type) async throws -> NativeSwiftValue).self,
        genericArguments: [.type(Attributes.self)], receiverABI: .opaque(named: source.type.name))
    let content = try unsafe await makeContent.unsafeInvoke(on: source, attributesType)
    let attributesGetter = try await content.type.resolveGetter(named: "attributes",
        as: (() -> NativeSwiftValue).self, receiverABI: .opaque(named: content.type.name))
    let nativeAttributes = try unsafe attributesGetter.unsafeInvoke(on: content)
    let attributes = try nativeAttributes.take(as: Attributes.self)
    let statesGetter = try await content.type.resolveGetter(named: "states",
        as: (() -> NativeSwiftValue).self, receiverABI: .opaque(named: content.type.name))
    let nativeStates = try unsafe statesGetter.unsafeInvoke(on: content)
    guard let states = try nativeStates.withCopy({ $0 as? [Attributes.ContentState] }) else {
        throw NativePreviewPipelineRequired()
    }
    // The native expander inserts each stale copy immediately after its fresh
    // state. An explicit Stale context selects allEntries before this toggle.
    let entries = states.indices.flatMap { index in
        isStale ? [(index, true)] : addStaleEntries ? [(index, false), (index, true)] : [(index, false)]
    }
    guard !entries.isEmpty else { throw PreviewRendererError("The Live Activity preview has no content states") }
    let requested = stateIndex ?? 0
    let selected = entries.indices.contains(requested) ? requested : 0
    let errors = entries.indices.contains(requested) ? [] : [
        "Unsupported timeline index \(requested); see the `supportedCanvasControlOverrides` field of the result for the list of supported indexes for rendering this preview in the currently active scheme."
    ]
    let kindType = try await activityTypeNamed("WidgetKit.ActivityPreviewViewKind")
    let kindGetter = try await source.type.resolveGetter(named: "viewKind", as: (() -> NativeSwiftValue).self,
        valueABIs: [kindType: .opaque(named: kindType.name)], receiverABI: .opaque(named: source.type.name))
    let sourceKind = try unsafe kindGetter.unsafeInvoke(on: source).take(as: ActivityPreviewViewKind.self)
    let style = try await activityStyle(viewStyle, defaultKind: sourceKind, environment: environment)
    if style.metrics == "small" {
        guard let families = families as? [ActivityFamily], families.contains(.small) else {
            throw PreviewRendererError("SmallActivityFamilyAbsentError: To display your Live Activity in Smart Stack, add .supplementalActivityFamilies([.small]) to ActivityConfiguration and adapt the layout with @Environment(\\.activityFamily).")
        }
    }
    let metrics = try await activitySystemMetrics(style: style.metrics)
    let attributesData = try JSONEncoder().encode(attributes)
    let archiveEnvironment = try await activityArchiveEnvironment(style.environment)
    var collections: [NativeSwiftValue] = []
    for entry in entries {
        collections.append(try await activityArchive(attributesType: nativeActivityType, viewSource: nativeViewSource,
            attributes: attributesData, state: JSONEncoder().encode(states[entry.0]), isStale: entry.1,
            environment: archiveEnvironment.copy(), metrics: metrics.definition, families: nativeFamilies,
            layouts: nativeLayouts, payloadID: payloadID))
    }
    let controller = try await activityController(collections: collections, selectedIndex: selected,
        locationDescription: style.location, environment: style.environment, kind: style.kind,
        metrics: metrics, appName: appName)
    let radius = try await activityCornerRadius(controller)
    controller.view.layer.cornerRadius = radius
    controller.view.layer.cornerCurve = .continuous
    controller.view.layer.masksToBounds = true
    return ActivityPreview(controller: controller, stateIndexes: Array(entries.indices),
        selectedStateIndex: selected, isStale: entries[selected].1, viewKind: style.kind,
        interfaceOrientation: style.orientation, cornerRadius: radius, errors: errors)
}

@MainActor
private func activityCornerRadius(_ controller: UIViewController) async throws -> CGFloat {
    let symbol = try await ABIRuntime.shared.resolve(.init(
        machOName: "_$s14WidgetRenderer28PreviewHostingViewControllerC12cornerRadius12CoreGraphics7CGFloatVvgTj",
        language: .swift), in: .framework(named: "WidgetRenderer"))
    // This exported virtual thunk has no explicit arguments and reads its
    // borrowed object from SwiftSelf/x20. CGFloat returns directly in d0.
    let abi = ActivityControllerABI()
    let result = try unsafe abi.scalar(Int32(ABIValueDouble))
    let call = try unsafe abi.call(result: result, parameters: [])
    var radius: Double = 0
    var failure: OpaquePointer?
    let success = withExtendedLifetime(controller) {
        unsafe symbol.withUnsafeAddress { function in
            unsafe ABIUnsafeInvokeSwiftCallInterface(call, ABIUnsafeFunctionAtAddress(function), &radius,
                nil, Unmanaged.passUnretained(controller).toOpaque(), &failure)
        }
    }
    guard success else { throw unsafe abi.error(&failure) }
    return CGFloat(radius)
}

@MainActor
private struct ActivityStyle {
    let kind: ActivityPreviewViewKind
    let environment: EnvironmentValues
    let orientation: UIInterfaceOrientation
    let metrics: String
    let location: String
}

@MainActor
private func activityStyle(_ name: String?, defaultKind: ActivityPreviewViewKind,
                           environment: EnvironmentValues) async throws -> ActivityStyle {
    guard let name else {
        return ActivityStyle(kind: defaultKind, environment: try activityStyleEnvironment(environment, kind: defaultKind, standBy: false), orientation: .portrait,
            metrics: "default", location: "lockScreen")
    }
    let factories = ["Compact": "dynamicIslandCompact", "Compact (Landscape)": "dynamicIslandCompactLandscape",
        "Minimal": "dynamicIslandMinimal", "Minimal (Landscape)": "dynamicIslandMinimalLandscape",
        "Expanded": "dynamicIslandExpanded", "Content (Lock Screen)": "contentLockScreen",
        "Content (StandBy)": "contentStandBy", "Content (Smart Stack)": "contentSmartStack"]
    guard let factory = factories[name] else { throw PreviewRendererError("Unknown Activity View Style: \(name)") }
    let runtime = ABIRuntime.shared
    let scope = ImageSelector.path(URL(fileURLWithPath:
        "/System/Library/PrivateFrameworks/ChronoCore.framework/Support/WidgetPreviewsSupport.framework/WidgetPreviewsSupport"))
    let namespace = try await runtime.resolveSwiftType(
        named: "(extension in WidgetPreviewsSupport):PreviewsMessagingOS.RenderEffect.ActivityViewKind", in: scope)
    let effectType = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.RenderEffect", in: .framework(named: "PreviewsMessagingOS"))
    let effectGetter = try await namespace.resolveStaticGetter(named: factory, as: (() -> NativeSwiftValue).self,
        valueABIs: [effectType: .opaque(named: effectType.name)])
    let effect = try unsafe effectGetter.unsafeInvoke()
    let effects = try await activityArray([effect])
    func flag(_ name: String) async throws -> Bool {
        let getter = try await effects.type.resolveGetter(named: name, as: (() -> Bool).self, receiverABI: .pointer)
        return try unsafe getter.unsafeInvoke(on: effects)
    }
    let standBy = try await flag("isStandBy")
    let small = try await flag("useSmallActivityFamily")
    let narrow = try await flag("useNarrowCompactLayout")
    let orientationType = try await runtime.resolveSwiftType(named: "PreviewsServicesUI.PreviewPreferences.InterfaceOrientation",
        in: .framework(named: "PreviewsServicesUI"))
    let orientationGetter = try await effects.type.resolveGetter(named: "previewInterfaceOrientation", as: (() -> NativeSwiftValue).self,
        valueABIs: [orientationType: .opaque(named: orientationType.name)], receiverABI: .pointer)
    let nativeOrientation = try unsafe orientationGetter.unsafeInvoke(on: effects)
    let description = try await nativeOrientation.type.resolveGetter(named: "description", as: (() -> String).self,
        receiverABI: .opaque(named: nativeOrientation.type.name))
    let orientation: UIInterfaceOrientation
    switch try unsafe description.unsafeInvoke(on: nativeOrientation) {
    case "portrait": orientation = .portrait
    case "portraitUpsideDown": orientation = .portraitUpsideDown
    case "landscapeLeft": orientation = .landscapeLeft
    case "landscapeRight": orientation = .landscapeRight
    default: throw NativePreviewPipelineRequired()
    }
    let kindType = try await activityTypeNamed("WidgetKit.ActivityPreviewViewKind")
    let optionalKind = try await activityValue(Optional<ActivityPreviewViewKind>.none)
    let initializeKind = try await kindType.resolveInitializer(
        named: "init(from: Swift.Array<PreviewsMessagingOS.RenderEffect>) -> Swift.Optional<WidgetKit.ActivityPreviewViewKind>",
        as: ((NativeSwiftValue) -> NativeSwiftValue).self,
        valueABIs: [effects.type: .pointer, optionalKind.type: .opaque(named: optionalKind.type.name)])
    guard let kind = try unsafe initializeKind.unsafeInvoke(effects.copy()).take(as: ActivityPreviewViewKind?.self) else {
        throw NativePreviewPipelineRequired()
    }
    var environment = environment
    environment.activityFamily = small ? .small : .medium
    if narrow {
        let layoutType = try await activityTypeNamed("WidgetKit.DynamicIslandCompactLayout")
        let getter = try await layoutType.resolveStaticGetter(named: "narrow", as: (() -> NativeSwiftValue).self,
            valueABIs: [layoutType: .opaque(named: layoutType.name)])
        let layout = try unsafe getter.unsafeInvoke()
        let values = try await activityValue(environment)
        let setter = try await values.type.resolveSetter(
            named: "(extension in WidgetKit):SwiftUI.EnvironmentValues.dynamicIslandCompactLayout.setter : WidgetKit.DynamicIslandCompactLayout",
            as: NativeSwiftValue.self,
            valueABIs: [layoutType: .opaque(named: layoutType.name)], receiverABI: .opaque(named: values.type.name))
        try unsafe setter.unsafeInvoke(on: values, layout)
        environment = try values.take(as: EnvironmentValues.self)
    }
    return ActivityStyle(kind: kind, environment: try activityStyleEnvironment(environment, kind: kind, standBy: standBy), orientation: orientation,
        metrics: standBy ? "standBy" : small ? "small" : "default",
        location: standBy ? "ambient" : "lockScreen")
}

@MainActor
private func activityStyleEnvironment(_ environment: EnvironmentValues, kind: ActivityPreviewViewKind,
                                      standBy: Bool) throws -> EnvironmentValues {
    var environment = environment
    switch kind {
    case .content:
        if standBy || environment.isLuminanceReduced { environment.colorScheme = .dark }
    case .dynamicIsland:
        // The native extension agent forces Dark appearance for Dynamic Island
        // archives, including when the canvas requests Light appearance.
        environment.colorScheme = .dark
    @unknown default: throw NativePreviewPipelineRequired()
    }
    return environment
}

@MainActor
private func activityDescriptor(_ configuration: NativeSwiftValue) async throws -> Any {
    func unwrap(_ value: Any) throws -> (base: Any, modifiers: [Any]) {
        guard String(reflecting: type(of: value)).hasPrefix("SwiftUI.ModifiedContent<") else { return (value, []) }
        let fields = Mirror(reflecting: value).children
        guard let content = fields.first(where: { $0.label == "content" })?.value,
              let modifier = fields.first(where: { $0.label == "modifier" })?.value else { throw NativePreviewPipelineRequired() }
        let inner = try unwrap(content)
        return (inner.base, inner.modifiers + [modifier])
    }
    let unwrapped = try configuration.withCopy { try unwrap($0) }
    guard String(reflecting: type(of: unwrapped.base)).hasPrefix("WidgetKit.ActivityConfiguration<"),
          let configuration = unwrapped.base as? any WidgetConfiguration else { throw NativePreviewPipelineRequired() }
    func seed<C: WidgetConfiguration>(_ configuration: C) throws -> Any {
        guard let descriptor = Mirror(reflecting: configuration.body).children.first(where: { $0.label == "descriptor" })?.value,
              String(reflecting: type(of: descriptor)) == "WidgetKit.WidgetDescriptor" else { throw NativePreviewPipelineRequired() }
        return descriptor
    }
    let seed = try _openExistential(configuration, do: seed)
    guard let keyType = _typeByName("9WidgetKit0A13DescriptorKeyV") as? any PreferenceKey.Type else {
        throw NativePreviewPipelineRequired()
    }
    func apply<Key: PreferenceKey>(_ key: Key.Type) throws -> Any {
        guard var values = [seed] as? Key.Value else { throw NativePreviewPipelineRequired() }
        for modifier in unwrapped.modifiers {
            guard let transform = modifier as? _PreferenceTransformModifier<Key> else { throw NativePreviewPipelineRequired() }
            transform.transform(&values)
        }
        let descriptors = Mirror(reflecting: values).children.map(\.value)
        guard descriptors.count == 1 else { throw NativePreviewPipelineRequired() }
        return descriptors[0]
    }
    return try _openExistential(keyType, do: apply)
}

@MainActor
private func activityArchive(attributesType: NativeSwiftValue, viewSource: NativeSwiftValue,
    attributes: Data, state: Data, isStale: Bool, environment: NativeSwiftValue, metrics: NativeSwiftValue,
    families: NativeSwiftValue, layouts: NativeSwiftValue, payloadID: String) async throws -> NativeSwiftValue {
    let nativeAttributes = try await activityValue(attributes)
    let nativeState = try await activityValue(state)
    let environmentType = try await activityTypeNamed("WidgetKit.WidgetEnvironment")
    let tagType = try await activityTypeNamed("WidgetKit.ActivityViewTag")
    let tagsType = try await ABIRuntime.shared.resolveSwiftType(named: "Swift.Array", genericArguments: [.type(tagType)])
    let allCases = try await tagType.resolveStaticGetter(named: "allCases", as: (() -> NativeSwiftValue).self,
        valueABIs: [tagsType: .pointer])
    let tags = try unsafe allCases.unsafeInvoke()
    let dataABI = try NativeType.structure(named: nativeAttributes.type.name, fields: [.uint64, .uint64])
    let archiver = try await activityTypeNamed("WidgetKit.ActivityArchiver")
    let archive = try await archiver.resolveStaticMethod(
        named: "makeArchivedViewCollection(attributesType:attributesData:contentStatePayload:isStale:viewSource:metricsDefinition:environment:payloadID:supportedFamilies:supportedDynamicIslandCompactLayouts:viewTags:isPublic:)",
        as: ((NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, Bool, NativeSwiftValue, NativeSwiftValue,
              NativeSwiftValue, String, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, Bool) throws -> NativeSwiftValue).self,
        valueABIs: [nativeAttributes.type: dataABI, attributesType.type: .opaque(named: attributesType.type.name),
                    viewSource.type: .opaque(named: viewSource.type.name), metrics.type: .opaque(named: metrics.type.name),
                    environmentType: .opaque(named: environmentType.name), families.type: .pointer,
                    layouts.type: .pointer, tagsType: .pointer])
    let data = try unsafe archive.unsafeInvoke(attributesType, nativeAttributes, nativeState, isStale,
        viewSource, metrics, environment, payloadID, families, layouts, tags, false)
    let collectionType = try await activityTypeNamed("WidgetKit.ActivityArchivedViewCollection")
    let collection = try await collectionType.resolveInitializer(named: "init(contentsOf: Foundation.Data) throws -> WidgetKit.ActivityArchivedViewCollection",
        as: ((NativeSwiftValue) throws -> NativeSwiftValue).self,
        valueABIs: [nativeAttributes.type: dataABI, collectionType: .opaque(named: collectionType.name)])
    return try unsafe collection.unsafeInvoke(data)
}

@MainActor
private struct ActivitySystemMetrics {
    let request: AnyObject
    let definition: NativeSwiftValue
    let apertureTopMargin: CGFloat
    let islandSize: CGSize?
}

@MainActor
private func activitySystemMetrics(style: String) async throws -> ActivitySystemMetrics {
    let runtime = ABIRuntime.shared
    let symbol = try await runtime.resolve(
        .init(machOName: "_OBJC_CLASS_$_SBUILiveActivityMetrics", language: .objectiveC, kind: .data),
        in: .framework(named: "SpringBoardUIServices"))
    guard let type = NSClassFromString("SBUILiveActivityMetrics") else { throw NativePreviewPipelineRequired() }
    let request: AnyObject
    if style == "small" {
        request = try await activitySmallMetricsRequest()
    } else {
        let factory = try await runtime.object(type as AnyObject).resolveMethod(
            selector: style == "standBy" ? "ambientWidgetMetrics" : "defaultMetrics", as: (() -> AnyObject).self)
        request = try unsafe factory.unsafeInvoke()
    }
    guard let list = try await activityObject(request, "lockScreenMetrics") else { throw NativePreviewPipelineRequired() }
    var json: [String: Any] = ["_rawListItemMetrics": try await activityItemJSON(list)]
    let aperture = try await activityObject(request, "systemApertureMetrics")
    let narrow = try await activityObject(request, "limitedWidthSystemApertureMetrics")
    if let aperture { json["_rawJindoMetrics"] = try await activityIslandJSON(aperture) }
    if let narrow { json["_rawNarrowJindoMetrics"] = try await activityIslandJSON(narrow) }
    let data = try JSONSerialization.data(withJSONObject: json)
    let metricsType = try await activityTypeNamed("WidgetKit.ActivityMetricsDefinition")
    let defaultMetrics = try await metricsType.resolveStaticGetter(named: "default", as: (() -> NativeSwiftValue).self,
        valueABIs: [metricsType: .opaque(named: metricsType.name)])
    let template = try unsafe defaultMetrics.unsafeInvoke()
    guard let decodingType = try template.withCopy({ Swift.type(of: $0) as? any Decodable.Type }) else {
        throw NativePreviewPipelineRequired()
    }
    // Native CodingKeys plus native Decodable build the private values; no enum
    // tags or field offsets are assembled. Actual 27.2 round-trip was verified.
    func decode<Value: Decodable>(_ type: Value.Type) throws -> Any { try JSONDecoder().decode(type, from: data) }
    let definition = try await activityAnyValue(_openExistential(decodingType, do: decode))
    let margin: Double
    let size: CGSize?
    if let aperture {
        margin = try await activityDouble(aperture, "obstructionTopMargin")
        let getter = try await runtime.object(aperture).resolveMethod(selector: "obstructionSize", as: (() -> CGSize).self)
        size = try unsafe getter.unsafeInvoke()
    } else { margin = 0; size = nil }
    withExtendedLifetime(symbol) {}
    return ActivitySystemMetrics(request: request, definition: definition,
        apertureTopMargin: CGFloat(margin), islandSize: size)
}

@MainActor
private func activitySmallMetricsRequest() async throws -> AnyObject {
    // The observed 27.2 ShellPlugin small-family factory uses these constructors
    // and exact values. Insets, scale and clipping retain the native defaults.
    func allocate(_ name: String) async throws -> AnyObject {
        let symbol = try await ABIRuntime.shared.resolve(
            .init(machOName: "_OBJC_CLASS_$_" + name, language: .objectiveC, kind: .data),
            in: .framework(named: "ActivityUIServices"))
        guard let type = NSClassFromString(name) else { throw NativePreviewPipelineRequired() }
        let alloc = try await ABIRuntime.shared.object(type as AnyObject).resolveMethod(selector: "alloc", as: (() -> AnyObject).self)
        let value = try unsafe alloc.unsafeInvoke()
        withExtendedLifetime(symbol) {}
        return value
    }
    func dimension(_ value: Double) async throws -> AnyObject {
        let object = try await allocate("ACUISSizeDimensionRequest")
        let initialize = try await ABIRuntime.shared.object(object).resolveMethod(selector: "initWithMinimum:maximum:",
            as: ((Double, Double) -> AnyObject).self)
        return try unsafe initialize.unsafeInvoke(value, value)
    }
    func item(width: Double, height: Double, radius: Double) async throws -> AnyObject {
        let width = try await dimension(width)
        let height = try await dimension(height)
        let object = try await allocate("ACUISActivityItemMetricsRequest")
        let initialize = try await ABIRuntime.shared.object(object).resolveMethod(selector: "initWithWidth:height:cornerRadius:",
            as: ((AnyObject, AnyObject, Double) -> AnyObject).self)
        return try unsafe initialize.unsafeInvoke(width, height, radius)
    }
    let list = try await item(width: 184, height: 80.5, radius: 14)
    let object = try await allocate("ACUISActivityMetricsRequest")
    let initialize = try await ABIRuntime.shared.object(object).resolveMethod(selector: "initWithLockScreenMetrics:",
        as: ((AnyObject) -> AnyObject).self)
    let request = try unsafe initialize.unsafeInvoke(list)
    let compact = try await item(width: 61.333333333333336, height: 36.6, radius: 18.3)
    let allocatedAperture = try await allocate("ACUISSystemApertureMetricsRequest")
    let initializeAperture = try await ABIRuntime.shared.object(allocatedAperture).resolveMethod(
        selector: "initWithObstructionSize:obstructionTopMargin:expandedMetricsRequest:compactLeadingMetricsRequest:compactTrailingMetricsRequest:minimalMetricsRequest:",
        as: ((CGSize, Double, AnyObject, AnyObject, AnyObject, AnyObject) -> AnyObject).self)
    let aperture = try unsafe initializeAperture.unsafeInvoke(.zero, 0, list, compact, compact, compact)
    let assign = try await ABIRuntime.shared.object(request).resolveMethod(selector: "setSystemApertureMetrics:",
        as: ((AnyObject) -> Void).self)
    try unsafe assign.unsafeInvoke(aperture)
    return request
}

@MainActor
private func activityItemJSON(_ item: AnyObject) async throws -> [String: Any] {
    var json: [String: Any] = [:]
    for (name, selector) in [("width", "widthRequest"), ("height", "heightRequest")] {
        guard let dimension = try await activityObject(item, selector) else { throw NativePreviewPipelineRequired() }
        let getter = try await ABIRuntime.shared.object(dimension).resolveMethod(selector: "type", as: (() -> Int64).self)
        let minimum = try await activityDouble(dimension, "minimum")
        let maximum = try await activityDouble(dimension, "maximum")
        switch try unsafe getter.unsafeInvoke() {
        case 0: json[name] = ["requestType": "fixed", "fixed": minimum]
        case 1: json[name] = ["requestType": "dynamic", "min": minimum, "max": maximum]
        default: throw NativePreviewPipelineRequired()
        }
    }
    for name in ["cornerRadius", "clipMargin", "scaleFactor"] { json[name] = try await activityDouble(item, name) }
    if let insets = try await activityObject(item, "edgeInsets") {
        for edge in ["Top", "Leading", "Bottom", "Trailing"] {
            json["inset" + edge] = try await activityDouble(insets, edge.lowercased())
        }
    }
    return json
}

@MainActor
private func activityIslandJSON(_ island: AnyObject) async throws -> [String: Any] {
    let getter = try await ABIRuntime.shared.object(island).resolveMethod(selector: "obstructionSize", as: (() -> CGSize).self)
    let size = try unsafe getter.unsafeInvoke()
    var json: [String: Any] = ["obstructionSizeWidth": size.width, "obstructionSizeHeight": size.height]
    for (key, selector) in [("expandedMetrics", "expandedMetricsRequest"), ("compactLeadingMetrics", "compactLeadingMetricsRequest"),
                            ("compactTrailingMetrics", "compactTrailingMetricsRequest"), ("compactMinimalMetrics", "minimalMetricsRequest")] {
        guard let item = try await activityObject(island, selector) else { throw NativePreviewPipelineRequired() }
        json[key] = try await activityItemJSON(item)
    }
    return json
}

@MainActor
private func activityObject(_ object: AnyObject, _ selector: String) async throws -> AnyObject? {
    let getter = try await ABIRuntime.shared.object(object).resolveMethod(selector: selector, as: (() -> AnyObject?).self)
    return try unsafe getter.unsafeInvoke()
}

@MainActor
private func activityDouble(_ object: AnyObject, _ selector: String) async throws -> Double {
    let getter = try await ABIRuntime.shared.object(object).resolveMethod(selector: selector, as: (() -> Double).self)
    return try unsafe getter.unsafeInvoke()
}

@inline(never)
@MainActor
private func activityValue<Value>(_ value: Value) async throws -> NativeSwiftValue {
    let identity = try await ABIRuntime.shared.resolveSwiftFunction(named: "XcodeMCPPreviewRenderer.previewValue<A>(A) -> A",
        as: ((Value) -> NativeSwiftValue).self, genericArguments: [.type(Value.self)])
    return try unsafe identity.unsafeInvoke(value)
}

@MainActor
private func activityAnyValue(_ value: Any) async throws -> NativeSwiftValue {
    @MainActor func open<Value>(_ value: Value) async throws -> NativeSwiftValue { try await activityValue(value) }
    return try await _openExistential(value, do: open)
}

@MainActor
private func activityArray(_ values: [NativeSwiftValue]) async throws -> NativeSwiftValue {
    let copies = try values.map { try $0.withCopy { $0 } }
    guard let first = copies.first else { throw NativePreviewPipelineRequired() }
    func open<Value>(_ type: Value.Type) throws -> Any {
        guard let array = copies as? [Value] else { throw NativePreviewPipelineRequired() }
        return array
    }
    return try await activityAnyValue(_openExistential(Swift.type(of: first), do: open))
}

private func activityTypeNamed(_ name: String) async throws -> NativeSwiftType {
    try await ABIRuntime.shared.resolveSwiftType(named: name, in: .framework(named: "WidgetKit"))
}

@MainActor
private func activityController(collections values: [NativeSwiftValue], selectedIndex: Int,
    locationDescription: String, environment: EnvironmentValues,
    kind: ActivityPreviewViewKind, metrics: ActivitySystemMetrics, appName: String) async throws -> UIViewController {
    let runtime = ABIRuntime.shared
    let describeLocation = try unsafe await runtime.resolveCFunction(named: "CHSWidgetLocationDescription",
        as: ((Int64) -> UnsafeRawPointer).self, in: .framework(named: "ChronoServices"))
    // The observed native mapping has twelve entries and an unknown fallback.
    // Select the native description rather than assuming the C enum ordinal.
    let locations = try (Int64(0)...Int64(11)).filter { value in
        let pointer = try unsafe describeLocation.unsafeInvoke(value)
        return unsafe Unmanaged<NSString>.fromOpaque(pointer).takeUnretainedValue() as String == locationDescription
    }
    guard locations.count == 1, let location = locations.first else { throw NativePreviewPipelineRequired() }
    let collections = try await activityArray(values)
    let controllerType = try await runtime.resolveSwiftType(named: "WidgetRenderer.ActivityPreviewHostingViewController",
        in: .framework(named: "WidgetRenderer"))
    let prefix = "_$s14WidgetRenderer36ActivityPreviewHostingViewControllerC15viewCollections17currentStateIndex14widgetLocation11environment0H4Kind21apertureTopEdgeMetric10islandSize14metricsRequest"
    let suffix = "7appNameACSay0A3Kit0c8ArchivedF10CollectionVG_SiSo09CHSWidgetN0V7SwiftUI17EnvironmentValuesVAN0cdfP0O12CoreGraphics7CGFloatVSo6CGSizeVSgSo020ACUISActivityMetricsX0CSgSbSStcfC"
    let withoutMetrics = "_$s14WidgetRenderer36ActivityPreviewHostingViewControllerC15viewCollections17currentStateIndex14widgetLocation11environment0H4Kind21apertureTopEdgeMetric10islandSize30renderBoxRendersAsynchronously7appNameACSay0A3Kit0c8ArchivedF10CollectionVG_SiSo09CHSWidgetN0V7SwiftUI17EnvironmentValuesVAM0cdfP0O12CoreGraphics7CGFloatVSo6CGSizeVSgSbSStcfC"
    let candidates = [
        (name: prefix + "30renderBoxRendersAsynchronously" + suffix, metricsRequest: true, flag: false),
        (name: prefix + "11forSnapshot" + suffix, metricsRequest: true, flag: true),
        (name: withoutMetrics, metricsRequest: false, flag: false),
    ]
    var selected: (symbol: ResolvedSymbol, metricsRequest: Bool, flag: Bool)?
    for candidate in candidates {
        do {
            let symbol = try await runtime.resolve(.init(machOName: candidate.name,
                language: .swift), in: .framework(named: "WidgetRenderer"))
            selected = (symbol, candidate.metricsRequest, candidate.flag)
            break
        } catch ABIResolutionError.declarationNotFound {
            continue
        }
    }
    guard let selected else { throw NativePreviewPipelineRequired() }
    guard let controllerClass = NSClassFromString("WidgetRenderer.ActivityPreviewHostingViewController") else {
        throw NativePreviewPipelineRequired()
    }
    // The high-level initializer requires an unexported CHSWidgetLocation
    // descriptor. Public Core uses the compiler/text-proven complete call ABI.
    let abi = ActivityControllerABI()
    let pointer = try unsafe abi.scalar(Int32(ABIValuePointer))
    let integer = try unsafe abi.scalar(Int32(ABIValueInt64))
    let word = try unsafe abi.scalar(Int32(ABIValueUInt64))
    let byte = try unsafe abi.scalar(Int32(ABIValueUInt8))
    let double = try unsafe abi.scalar(Int32(ABIValueDouble))
    var arguments: [ActivityControllerArgument] = []
    arguments.append(try collections.withCopy { value in
        @MainActor func open<Value>(_ value: Value) throws -> ActivityControllerArgument {
            try unsafe abi.argument(value, components: [pointer])
        }
        return try _openExistential(value, do: open)
    })
    arguments.append(try unsafe abi.argument(selectedIndex, components: [integer]))
    arguments.append(try unsafe abi.argument(location, components: [integer]))
    arguments.append(try abi.indirectArgument(environment))
    arguments.append(try abi.indirectArgument(kind))
    arguments.append(try unsafe abi.argument(metrics.apertureTopMargin, components: [double]))
    arguments.append(try unsafe abi.argument(metrics.islandSize, components: [word, word, byte]))
    if selected.metricsRequest {
        arguments.append(try unsafe abi.argument(Optional<AnyObject>.some(metrics.request), components: [pointer]))
    }
    arguments.append(try unsafe abi.argument(selected.flag, components: [byte]))
    arguments.append(try unsafe abi.argument(appName, components: [word, word]))
    let call = try unsafe abi.call(result: pointer, parameters: unsafe arguments.map { unsafe $0.type })
    let output = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 1)
    defer { unsafe output.deallocate() }
    var failure: OpaquePointer?
    let success = withExtendedLifetime((values, collections, controllerType, metrics, arguments)) {
        unsafe selected.symbol.withUnsafeAddress { function in
            let addresses = unsafe arguments.map { unsafe Optional($0.address) }
            return addresses.withUnsafeBufferPointer {
                unsafe ABIUnsafeInvokeSwiftCallInterface(call, ABIUnsafeFunctionAtAddress(function), output,
                    $0.baseAddress, unsafeBitCast(controllerClass, to: UnsafeRawPointer.self), &failure)
            }
        }
    }
    guard success else { throw unsafe abi.error(&failure) }
    // Allocating initializers consume these independent compiler-created copies.
    // The successful callee owns the values; the adapter frees only their bytes.
    for argument in arguments { argument.transferred = true }
    guard let object = unsafe output.move() else { throw PreviewRendererError("The native Activity controller initializer returned null") }
    let controller = unsafe Unmanaged<UIViewController>.fromOpaque(object).takeRetainedValue()
    controller.loadViewIfNeeded()
    return controller
}

@MainActor
@safe
private final class ActivityControllerArgument {
    let type: OpaquePointer
    let address: UnsafeMutableRawPointer
    var transferred = false
    private let destroy: () -> Void
    private let free: () -> Void

    init<Value>(_ value: Value, type: OpaquePointer) {
        let storage = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        unsafe storage.initialize(to: value)
        unsafe self.type = type
        unsafe self.address = UnsafeMutableRawPointer(storage)
        destroy = { unsafe storage.deinitialize(count: 1) }
        free = { unsafe storage.deallocate() }
    }

    isolated deinit {
        if !transferred { destroy() }
        free()
    }
}

@MainActor
@safe
private final class ActivityControllerABI {
    private var types: [OpaquePointer] = unsafe []
    private var calls: [OpaquePointer] = unsafe []

    isolated deinit {
        for unsafe call in unsafe calls { unsafe ABIReleaseSwiftCallInterface(call) }
        for unsafe type in unsafe types.reversed() { unsafe ABIReleaseValueType(type) }
    }

    func error(_ failure: inout OpaquePointer?) -> PreviewRendererError {
        let message = unsafe failure.map { unsafe String(cString: ABIResolutionFailureMessage($0)) } ?? "Core preparation failed"
        if let value = unsafe failure { unsafe ABIReleaseResolutionFailure(value) }
        unsafe failure = nil
        return PreviewRendererError(message)
    }

    private func require(_ value: OpaquePointer?, _ failure: inout OpaquePointer?) throws -> OpaquePointer {
        guard let value = unsafe value else { throw unsafe error(&failure) }
        return unsafe value
    }

    func scalar(_ value: Int32) throws -> OpaquePointer {
        var failure: OpaquePointer?
        let type = try unsafe require(ABICreateScalarType(value, &failure), &failure)
        unsafe types.append(type)
        return unsafe type
    }

    func argument<Value>(_ value: Value, components: [OpaquePointer]) throws -> ActivityControllerArgument {
        var failure: OpaquePointer?
        let fields = unsafe components.map(Optional.some)
        let structure = try unsafe require(fields.withUnsafeBufferPointer {
            unsafe ABICreateStructType($0.baseAddress, $0.count, &failure)
        }, &failure)
        unsafe types.append(structure)
        let storage = try unsafe require(ABICreateSwiftStorageType(structure,
            MemoryLayout<Value>.size, MemoryLayout<Value>.alignment, &failure), &failure)
        unsafe types.append(storage)
        return unsafe ActivityControllerArgument(value, type: storage)
    }

    func indirectArgument<Value>(_ value: Value) throws -> ActivityControllerArgument {
        var failure: OpaquePointer?
        let storage = try unsafe require(ABICreateSwiftIndirectStorageType(
            MemoryLayout<Value>.size, MemoryLayout<Value>.alignment, &failure), &failure)
        unsafe types.append(storage)
        return unsafe ActivityControllerArgument(value, type: storage)
    }

    func call(result: OpaquePointer, parameters: [OpaquePointer]) throws -> OpaquePointer {
        var failure: OpaquePointer?
        let parameters = unsafe parameters.map(Optional.some)
        let call = try unsafe require(parameters.withUnsafeBufferPointer {
            unsafe ABICreateSwiftCallInterface(result, $0.baseAddress, $0.count, &failure)
        }, &failure)
        unsafe calls.append(call)
        return unsafe call
    }
}


@MainActor
private func activityArchiveEnvironmentValue<Value>(_ environment: NativeSwiftValue,
    value: Value, keyPath: WritableKeyPath<EnvironmentValues, Value>) async throws -> NativeSwiftValue {
    let symbol = try await ABIRuntime.shared.resolve(.init(machOName:
        "_$s9WidgetKit0A11EnvironmentV13dynamicMemberSayxGSgs15WritableKeyPathCy7SwiftUI0C6ValuesVxG_tcluis",
        language: .swift), in: .framework(named: "WidgetKit"))
    let original = try environment.withCopy { $0 }
    @MainActor func opened<Environment>(_ original: Environment) async throws -> NativeSwiftValue {
        var modified = original
        let abi = ActivityControllerABI()
        let word = try unsafe abi.scalar(Int32(ABIValueUInt64))
        let pointer = try unsafe abi.scalar(Int32(ABIValuePointer))
        let void = try unsafe abi.scalar(Int32(ABIValueVoid))
        // The matching compiler-generated subscript setter consumes its Array?
        // and WritableKeyPath copies and mutates self inout. KeyPath metadata
        // provides Value metadata; there is no extra generic argument register.
        let arguments = [
            try unsafe abi.argument(Optional([value]), components: [word]),
            try unsafe abi.argument(keyPath, components: [pointer])
        ]
        let interface = try unsafe abi.call(result: void, parameters: unsafe arguments.map { unsafe $0.type })
        var failure: OpaquePointer?
        let success = withExtendedLifetime((environment, symbol, arguments)) {
            unsafe symbol.withUnsafeAddress { function in
                withUnsafeMutablePointer(to: &modified) { receiver in
                    let addresses = unsafe arguments.map { unsafe Optional($0.address) }
                    return addresses.withUnsafeBufferPointer {
                        unsafe ABIUnsafeInvokeSwiftCallInterface(interface, ABIUnsafeFunctionAtAddress(function), nil,
                            $0.baseAddress, UnsafeRawPointer(receiver), &failure)
                    }
                }
            }
        }
        guard success else { throw unsafe abi.error(&failure) }
        for argument in arguments { argument.transferred = true }
        return try await activityValue(modified)
    }
    return try await _openExistential(original, do: opened)
}

@MainActor
private func activityArchiveEnvironment(_ values: EnvironmentValues) async throws -> NativeSwiftValue {
    let nativeValues = try await activityValue(values)
    let environmentType = try await activityTypeNamed("WidgetKit.WidgetEnvironment")
    let initialize = try await environmentType.resolveInitializer(named: "init(from: SwiftUI.EnvironmentValues) -> WidgetKit.WidgetEnvironment",
        as: ((NativeSwiftValue) -> NativeSwiftValue).self,
        valueABIs: [nativeValues.type: .opaque(named: nativeValues.type.name),
                    environmentType: .opaque(named: environmentType.name)])
    let initial = try unsafe initialize.unsafeInvoke(nativeValues.copy())
    let family = try await activityArchiveEnvironmentValue(initial, value: values.activityFamily,
        keyPath: \EnvironmentValues.activityFamily)
    let environment = try await activityArchiveEnvironmentValue(family, value: values.colorScheme,
        keyPath: \EnvironmentValues.colorScheme)
    let root = nativeValues.type
    let layoutType = try await activityTypeNamed("WidgetKit.DynamicIslandCompactLayout")
    let property = "(extension in WidgetKit):SwiftUI.EnvironmentValues.dynamicIslandCompactLayout"
    let keyPath = try await root.resolveWritableKeyPath(named: property, valueType: layoutType)
    let path = try keyPath.withCopy { value in
        guard let path = value as? AnyKeyPath else { throw NativePreviewPipelineRequired() }
        return path
    }
    let getter = try await root.resolveGetter(named: property + ".getter : WidgetKit.DynamicIslandCompactLayout",
        as: (() -> NativeSwiftValue).self, valueABIs: [layoutType: .opaque(named: layoutType.name)],
        receiverABI: .opaque(named: root.name))
    let layout = try unsafe getter.unsafeInvoke(on: nativeValues)
    let value = try layout.withCopy { $0 }
    @MainActor func opened<Value>(_ value: Value) async throws -> NativeSwiftValue {
        guard let path = path as? WritableKeyPath<EnvironmentValues, Value> else { throw NativePreviewPipelineRequired() }
        // init(from:) omits these widget archive keys. The canonical property
        // key path makes the selected layout visible to WidgetEnvironment.
        return try await activityArchiveEnvironmentValue(environment, value: value, keyPath: path)
    }
    return try await _openExistential(value, do: opened)
}

@MainActor
func requestActivityPreviewOrientation(_ target: UIInterfaceOrientation, in scene: UIWindowScene) async throws {
    let mask: UIInterfaceOrientationMask
    switch target {
    case .portrait: mask = .portrait
    case .portraitUpsideDown: mask = .portraitUpsideDown
    case .landscapeLeft: mask = .landscapeLeft
    case .landscapeRight: mask = .landscapeRight
    default: throw NativePreviewPipelineRequired()
    }
    var failure: (any Error)?
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { failure = $0 }
    while scene.effectiveGeometry.interfaceOrientation != target {
        if let failure { throw failure }
        try await Task.sleep(for: .milliseconds(16))
    }
    if let failure { throw failure }
}

@MainActor
final class ActivityOrientationController: UIViewController {
    private let content: UIViewController

    init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }
}
#endif
