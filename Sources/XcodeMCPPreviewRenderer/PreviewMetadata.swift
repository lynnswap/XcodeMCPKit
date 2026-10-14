#if os(macOS)
import ABIBridge
import ABIBridgeCore
import CoreGraphics
import DeveloperToolsSupport
import Foundation
import SwiftUI
import XcodeMCPWire

@MainActor
func nativePreviewMetadata(_ request: PreviewRendererRequest) async throws -> Data {
    guard request.providerTypeName == nil else { throw NativePreviewPipelineRequired() }
    let registry = try previewRegistry(for: request)
    let preview = try await ownedPreview(registry.makePreview())
    let source = try await previewSource(preview)
    let runtime = ABIRuntime.shared
    let messaging = ImageSelector.framework(named: "PreviewsMessagingOS")
    let domainType = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.PreviewContentDomain", in: messaging)
    let sourceDomainType = try await runtime.resolveSwiftType(named: "DeveloperToolsSupport.PreviewSourceContentDomain",
        in: .framework(named: "DeveloperToolsSupport"))
    let sourceDomain = try await previewSourceValue(source, name: "contentDomain", resultType: sourceDomainType)
    let domain = try domainType.makeEnumCase(named: previewEnumCaseName(sourceDomain))
    let sourceCategoryType = try await runtime.resolveSwiftType(named: "DeveloperToolsSupport.PreviewSourceContentCategory",
        in: .framework(named: "DeveloperToolsSupport"))
    let sourceCategory = try await previewSourceValue(source, name: "contentCategory", resultType: sourceCategoryType)
    // This extension's image supplies the native category conversion.
    let categoryDeclaration = "(extension in PreviewsOSSupportUI):DeveloperToolsSupport.PreviewSourceContentCategory.contentCategory.getter : PreviewsMessagingOS.ContentCategory"
    let support = try await runtime.resolve(.init(name: categoryDeclaration, language: .swift),
        in: .framework(named: "PreviewsOSSupportUI"))
    let categoryType = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.ContentCategory", in: messaging)
    let categoryGetter = try await sourceCategory.type.resolveGetter(
        named: categoryDeclaration,
        as: (() -> NativeSwiftValue).self, valueABIs: [categoryType: .opaque(named: categoryType.name)],
        receiverABI: .opaque(named: sourceCategory.type.name))
    let category = try withExtendedLifetime(support) { try unsafe categoryGetter.unsafeInvoke(on: sourceCategory) }
    func flag(_ name: String) async throws -> Bool {
        let getter = try await source.type.resolveGetter(named: "DeveloperToolsSupport.PreviewSource.\(name).getter : Swift.Bool",
            as: (() -> Bool).self)
        return try unsafe getter.unsafeInvoke(on: source)
    }
    let onDevice = try await flag("supportsOnDevicePreviews")
    let interactive = try await flag("supportsInteractivePreviews")
    let traits = try await nativePreviewTraits(preview)
    let group = try await previewSourceIsGroup(source)
    let displayNameGetter = try await preview.type.resolveGetter(named: "displayName", as: (() -> String?).self,
        receiverABI: .opaque(named: preview.type.name))
    let displayName = try unsafe displayNameGetter.unsafeInvoke(on: preview)
    let metadataType = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.PreviewMetadata", in: messaging)
    let makeMetadata = try await metadataType.resolveInitializer(
        named: "init(contentDomain: PreviewsMessagingOS.PreviewContentDomain, contentCategory: PreviewsMessagingOS.ContentCategory, supportsOnDevice: Swift.Bool, supportsInteractive: Swift.Bool, requestedTraits: PreviewsMessagingOS.PreviewTraits, isPreviewGroup: Swift.Bool, displayName: Swift.String?) -> PreviewsMessagingOS.PreviewMetadata",
        as: ((NativeSwiftValue, NativeSwiftValue, Bool, Bool, NativeSwiftValue, Bool, String?) -> NativeSwiftValue).self,
        valueABIs: [domainType: .opaque(named: domainType.name), categoryType: .opaque(named: categoryType.name),
            traits.type: .opaque(named: traits.type.name), metadataType: .opaque(named: metadataType.name)])
    let metadata = try unsafe makeMetadata.unsafeInvoke(domain, category, onDevice, interactive, traits, group, displayName)
    let propertyListType = try await runtime.resolveSwiftType(named: "PreviewsFoundationOS.PropertyList",
        in: .framework(named: "PreviewsFoundationOS"))
    let encode = try await metadataType.resolveGetter(named: "propertyListValue", as: (() -> NativeSwiftValue).self,
        valueABIs: [propertyListType: .opaque(named: propertyListType.name)], receiverABI: .opaque(named: metadataType.name))
    let propertyList = try unsafe encode.unsafeInvoke(on: metadata)
    let dictionaryType = try await runtime.resolveSwiftType(named: "Swift.Dictionary",
        genericArguments: [.type(String.self), .type(Any.self)])
    let dictionaryGetter = try await propertyListType.resolveGetter(named: "serializableDictionary", as: (() -> NativeSwiftValue).self,
        valueABIs: [dictionaryType: .pointer], receiverABI: .opaque(named: propertyListType.name))
    let value = try unsafe dictionaryGetter.unsafeInvoke(on: propertyList)
    return try value.withCopy {
        guard let dictionary = $0 as? [String: Any] else {
            throw PreviewRendererError("Native preview metadata is not a serializable dictionary")
        }
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }
}

@MainActor
private func previewSourceValue(_ source: NativeSwiftValue, name: String, resultType: NativeSwiftType) async throws -> NativeSwiftValue {
    let getter = try await source.type.resolveGetter(
        named: "DeveloperToolsSupport.PreviewSource.\(name).getter : \(resultType.name)",
        as: (() -> NativeSwiftValue).self, valueABIs: [resultType: .opaque(named: resultType.name)])
    return try unsafe getter.unsafeInvoke(on: source)
}

@MainActor
private func nativePreviewTraits(_ preview: NativeSwiftValue) async throws -> NativeSwiftValue {
    let runtime = ABIRuntime.shared
    let image = ImageSelector.framework(named: "PreviewsMessagingOS")
    let layoutType = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.PreviewTraits.Layout", in: image)
    let layout: NativeSwiftValue
    switch try await viewPreviewLayout(preview) {
    case .device: layout = try layoutType.makeEnumCase(named: "device")
    case .sizeThatFits: layout = try layoutType.makeEnumCase(named: "sizeThatFits")
    case .fixed(let width, let height):
        layout = try await layoutType.makeEnumCase(named: "fixed", payload: ownedPreviewValue((width: width, height: height)))
    default: throw NativePreviewPipelineRequired()
    }
    // The macOS metadata producer supplies portrait independently of view traits.
    let orientationType = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.PreviewTraits.Orientation", in: image)
    let orientation = try orientationType.makeEnumCase(named: "portrait")
    let traitsType = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.PreviewTraits", in: image)
    let makeTraits = try await traitsType.resolveInitializer(
        named: "init(layout: PreviewsMessagingOS.PreviewTraits.Layout, orientation: PreviewsMessagingOS.PreviewTraits.Orientation) -> PreviewsMessagingOS.PreviewTraits",
        as: ((NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
        valueABIs: [layoutType: .opaque(named: layoutType.name), orientationType: .opaque(named: orientationType.name),
            traitsType: .opaque(named: traitsType.name)])
    return try unsafe makeTraits.unsafeInvoke(layout, orientation)
}

@MainActor
private func previewSourceIsGroup(_ source: NativeSwiftValue) async throws -> Bool {
    guard source.type.name.hasPrefix("DeveloperToolsSupport.DefaultPreviewSource<") else { return false }
    let bodyType: Any.Type = try source.withCopy { value in
        func body<Source>(_ value: Source) throws -> Any.Type {
            var failure: OpaquePointer?
            defer { if let failure = unsafe failure { unsafe ABIReleaseResolutionFailure(failure) } }
            guard let metadata = unsafe ABICopySwiftTypeMetadata(unsafeBitCast(Source.self, to: UnsafeRawPointer.self), &failure) else {
                throw PreviewRendererError("The native preview source generic metadata is unavailable")
            }
            defer { unsafe ABIReleaseSwiftTypeMetadata(metadata) }
            guard unsafe ABISwiftTypeMetadataArgumentCount(metadata) == 1,
                  let argument = unsafe ABISwiftTypeMetadataArgumentElement(metadata, 0, 0) else {
                throw PreviewRendererError("The native preview source body metadata is unavailable")
            }
            return unsafe unsafeBitCast(argument, to: Any.Type.self)
        }
        return try _openExistential(value, do: body)
    }
    func structure<Body>(_ type: Body.Type) async throws -> NativeSwiftValue {
        let structureType = try await ABIRuntime.shared.resolveSwiftType(named: "DeveloperToolsSupport.DefaultPreviewSource.Structure",
            in: .framework(named: "DeveloperToolsSupport"), genericArguments: [.type(Body.self)])
        let getter = try await source.type.resolveGetter(named: "structure", as: (() -> NativeSwiftValue).self,
            valueABIs: [structureType: .opaque(named: structureType.name)], receiverABI: .opaque(named: source.type.name))
        return try unsafe getter.unsafeInvoke(on: source)
    }
    let value = try await _openExistential(bodyType, do: structure)
    return try ["previewGroup", "emptyPreviewGroup"].contains(previewEnumCaseName(value))
}

private func previewEnumCaseName(_ value: NativeSwiftValue) throws -> String {
    try value.withCopy { copy in
        func name<Value>(_ value: Value) throws -> String {
            let metadata = unsafe unsafeBitCast(Value.self, to: UnsafeRawPointer.self)
            var tag: UInt32 = 0
            let found = withUnsafePointer(to: value) { unsafe ABISwiftGetEnumTag(metadata, $0, &tag) }
            var info = unsafe ABISwiftEnumCaseInfo()
            guard found, unsafe ABISwiftGetEnumCaseInfo(metadata, Int(tag), &info), let name = unsafe info.name else {
                throw PreviewRendererError("The native preview enum case metadata is unavailable")
            }
            return unsafe String(cString: name)
        }
        return try _openExistential(copy, do: name)
    }
}
#endif
