#if os(iOS) && targetEnvironment(simulator)
import ABIBridge
import ActivityKit
import Foundation
import SwiftUI
import UIKit
import WidgetKit

@MainActor
func makeLegacyActivityPreview(context: any PreviewContext, programRootNames: [String],
    timelineIndex: Int?, viewStyle: String?, viewContext: String?, environment: EnvironmentValues,
    appName: String, payloadID: String) async throws -> ActivityPreview {
    do {
        let fields = Array(Mirror(reflecting: context).children)
        guard String(reflecting: type(of: context)).hasPrefix("WidgetKit.ActivityPreviewContext<"),
              let attributes = fields.first(where: { $0.label == "attributes" })?.value as? any ActivityAttributes,
              let state = fields.first(where: { $0.label == "contentState" })?.value,
              let stale = fields.first(where: { $0.label == "isStale" })?.value as? Bool,
              let kind = fields.first(where: { $0.label == "viewKind" })?.value as? ActivityPreviewViewKind else {
            throw NativePreviewPipelineRequired()
        }
        @MainActor func open<Attributes: ActivityAttributes>(_ attributes: Attributes) async throws -> ActivityPreview {
            guard let state = state as? Attributes.ContentState else { throw NativePreviewPipelineRequired() }
            let type = try await ABIRuntime.shared.resolveSwiftType(named: "ActivityKit.ActivityAttributesType",
                in: .framework(named: "ActivityKit"))
            let initialize = try await type.resolveInitializer(
                named: "init<A where A: ActivityKit.ActivityAttributes>(from: A.Type) -> ActivityKit.ActivityAttributesType",
                as: ((Attributes.Type) -> NativeSwiftValue).self, genericArguments: [.type(Attributes.self)],
                valueABIs: [type: .opaque(named: type.name)])
            let nativeType = try unsafe initialize.unsafeInvoke(Attributes.self)
            let descriptors = try await legacyActivityDescriptors(programRootNames: programRootNames, environment: environment)
            let configuration = try await matchingLegacyActivityConfiguration(descriptors, attributesType: nativeType)
            // The legacy context supplies one payload. Its native producer does
            // not run the macro source's duplicate/stale-entry expander.
            let isStale = viewContext.map { $0 == "Stale" } ?? stale
            let content = ActivityPreviewContent(configuration: configuration,
                attributes: try JSONEncoder().encode(attributes),
                states: [(try JSONEncoder().encode(state), isStale)], viewKind: kind)
            return try await makeActivityPreview(content: content, timelineIndex: timelineIndex, viewStyle: viewStyle,
                environment: environment, appName: appName, payloadID: payloadID)
        }
        return try await _openExistential(attributes, do: open)
    } catch is ABIResolutionError {
        // These private host/preference declarations vary by runtime. An
        // unavailable representation is handled by the native preview pipeline.
        throw NativePreviewPipelineRequired()
    }
}

@MainActor
private func legacyActivityDescriptors(programRootNames: [String], environment: EnvironmentValues) async throws -> [Any] {
    let roots = programRootNames.compactMap { _typeByName($0) }.filter {
        $0 is any WidgetBundle.Type || $0 is any Widget.Type
    }
    guard roots.count == 1, let root = roots.first else { throw NativePreviewPipelineRequired() }
    if let bundle = root as? any WidgetBundle.Type {
        @MainActor func open<Bundle: WidgetBundle>(_ type: Bundle.Type) async throws -> [Any] {
            let root = try await ownedPreviewValue(Bundle())
            let hostType = try await ABIRuntime.shared.resolveSwiftType(named: "SwiftUI.WidgetBundleHost",
                in: .framework(named: "SwiftUI"))
            let initialize = try await hostType.resolveInitializer(
                named: "init<A where A: SwiftUI.WidgetBundle>(bundle: A) -> SwiftUI.WidgetBundleHost",
                as: ((NativeSwiftValue) -> NativeSwiftValue).self, genericArguments: [.type(root.type)],
                valueABIs: [root.type: .opaque(named: root.type.name), hostType: .pointer])
            let host = try unsafe initialize.unsafeInvoke(root.copy())
            let nativeEnvironment = try await ownedPreviewValue(environment)
            let set = try await hostType.resolveMethod(named: "setEnvironment(_:)",
                as: ((NativeSwiftValue) -> Void).self,
                valueABIs: [nativeEnvironment.type: .opaque(named: nativeEnvironment.type.name)], receiverABI: .pointer)
            try unsafe set.unsafeInvoke(on: host, nativeEnvironment.copy())
            return try await legacyBundleDescriptors(host)
        }
        return try await _openExistential(bundle, do: open)
    }
    guard let widget = root as? any Widget.Type else { throw NativePreviewPipelineRequired() }
    @MainActor func open<Content: Widget>(_ type: Content.Type) async throws -> [Any] {
        let configuration = try await ownedPreviewValue(Content().body)
        return [try await activityDescriptor(configuration)]
    }
    return try await _openExistential(widget, do: open)
}

@MainActor
private func legacyBundleDescriptors(_ host: NativeSwiftValue) async throws -> [Any] {
    guard let key = _typeByName("9WidgetKit0A13DescriptorKeyV") as? any PreferenceKey.Type else {
        throw NativePreviewPipelineRequired()
    }
    @MainActor func read<Key: PreferenceKey>(_ key: Key.Type) async throws -> [Any] {
        // Key.Value supplies the actual array metadata even when its private
        // element type has no exported nominal descriptor. The generic getter
        // retains its formal indirect result ABI.
        let defaultValue = try await ownedPreviewValue(Key.defaultValue)
        let read = try await host.type.resolveMethod(named: "readPreference(_:)",
            as: ((Key.Type) -> NativeSwiftValue).self, genericArguments: [.type(Key.self)],
            valueABIs: [defaultValue.type: .pointer], receiverABI: .pointer)
        let result = try unsafe read.unsafeInvoke(on: host, key)
        return try result.withCopy { value in
            guard let values = value as? any Collection else { throw NativePreviewPipelineRequired() }
            return values.map { $0 as Any }
        }
    }
    return try await _openExistential(key, do: read)
}

@MainActor
private func matchingLegacyActivityConfiguration(_ descriptors: [Any], attributesType: NativeSwiftValue) async throws -> ActivityPreviewConfiguration {
    let requested = try attributesType.withCopy { $0 }
    for descriptor in descriptors {
        guard let source = Mirror(reflecting: descriptor).children.first(where: { $0.label == "source" })?.value,
              let activity = Mirror(reflecting: source).children.first(where: { $0.label == "activity" })?.value,
              let type = Mirror(reflecting: activity).children.first(where: { $0.label == ".0" })?.value as? any Equatable else { continue }
        func equal<Value: Equatable>(_ value: Value) -> Bool {
            guard let requested = requested as? Value else { return false }
            return value == requested
        }
        if _openExistential(type, do: equal) { return try await activityPreviewConfiguration(descriptor) }
    }
    throw NativePreviewPipelineRequired()
}
#endif
