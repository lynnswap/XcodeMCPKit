#if (os(iOS) || os(watchOS)) && targetEnvironment(simulator)
import ABIBridge
import Foundation
#if os(iOS)
import UIKit
#else
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif
import XcodeMCPWire

@MainActor
func renderNativeWidgetPreview(_ request: PreviewRendererRequest) async throws -> PreviewRendererResult {
    guard let source = request.nativeSource else { throw NativePreviewPipelineRequired() }
    return try await NativePreviewService.withService { service in
        let renderer = NativeWidgetPreview(service: service, request: request)
        let specificationType = try await service.messagingType("PreviewSpecification")
        let decoder = try await specificationType.resolveInitializer(
            named: "init(propertyListValue: PreviewsFoundationOS.PropertyList) throws -> PreviewsMessagingOS.PreviewSpecification",
            as: ((NativeSwiftValue) throws -> NativeSwiftValue).self,
            valueABIs: [service.propertyListType: .opaque(named: service.propertyListType.name),
                        specificationType: .opaque(named: specificationType.name)])
        let encodedSpecification = try await service.propertyList(source.specification)
        let specification = try unsafe decoder.unsafeInvoke(encodedSpecification)
        let metadataType = try await service.messagingType("PreviewMetadata")
        let metadataDecoder = try await metadataType.resolveInitializer(
            named: "init(propertyListValue: PreviewsFoundationOS.PropertyList) throws -> PreviewsMessagingOS.PreviewMetadata",
            as: ((NativeSwiftValue) throws -> NativeSwiftValue).self,
            valueABIs: [service.propertyListType: .opaque(named: service.propertyListType.name),
                        metadataType: .opaque(named: metadataType.name)])
        let encodedMetadata = try await service.propertyList(source.metadata)
        let metadata = try unsafe metadataDecoder.unsafeInvoke(encodedMetadata)
        let pid = try await service.relaunch(extensionIdentifier: source.extensionIdentifier, localization: request.localization)
        return try await renderer.render(pid: pid, specification: specification,
                                         metadata: metadata, variants: source.variantOverrides)
    }
}

@MainActor
private struct NativeWidgetPreview {
    let service: NativePreviewService
    let request: PreviewRendererRequest
    private var runtime: ABIRuntime { .shared }

    func render(pid: Int32, specification: NativeSwiftValue, metadata: NativeSwiftValue,
                variants: [String: String]) async throws -> PreviewRendererResult {
        let identifierType = try await service.messagingType("ContentIdentifier")
        let makeIdentifier = try await identifierType.resolveInitializer(
            named: "init(rawValue: Swift.String) -> PreviewsMessagingOS.ContentIdentifier",
            as: ((String) -> NativeSwiftValue).self, valueABIs: [identifierType: .opaque(named: identifierType.name)])
        let categoryType = try await service.messagingType("ContentCategory")
        let categoryGetter = try await metadata.type.resolveGetter(named: "contentCategory", as: (() -> NativeSwiftValue).self,
            valueABIs: [categoryType: .opaque(named: categoryType.name)], receiverABI: .opaque(named: metadata.type.name))
        let previewCategory = try unsafe categoryGetter.unsafeInvoke(on: metadata)
        let catalog = try await variantCatalog(category: previewCategory)
        var selections: [String: String] = [:]
        var errors: [String] = []
        for (group, name) in variants.sorted(by: { $0.key < $1.key }) {
            if catalog.supported[group]?.contains(name) == true { selections[group] = name }
            else {
                let unsupported = catalog.supported[group] == nil ? "Unsupported variant group ‘\(group)’" : "Unsupported variant ‘\(name)’ for group ‘\(group)’"
                errors.append(unsupported + "; see the `supportedPreviewVariantOverrides` field of the result for the list of supported groups and variants for rendering this preview in the currently active scheme.")
            }
        }
        let effects = try await catalog.effects(for: selections)
        let payloadType = try await service.messagingType("PreviewPayload")
        let makePayload = try await payloadType.resolveInitializer(
            named: "init(previewSpecification: PreviewsMessagingOS.PreviewSpecification, renderEffects: [PreviewsMessagingOS.RenderEffect]) -> PreviewsMessagingOS.PreviewPayload",
            as: ((NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [specification.type: .opaque(named: specification.type.name), effects.type: .pointer,
                        payloadType: .opaque(named: payloadType.name)])
        let payload = try unsafe makePayload.unsafeInvoke(specification, effects)
        let encoded = try await service.encode(payload)
        let identifier = try unsafe makeIdentifier.unsafeInvoke(UUID().uuidString)
        let initialUpdate = try await update(pid: pid, identifier: identifier,
            category: previewCategory, content: encoded.copy(), controls: nil)
        let initialReply = try await service.sendUpdate(initialUpdate)
        let initial = try await staticReply(initialReply)
        let initialEncoded = try await service.encode(initial)
        let initialMetadata = try await service.dictionary(initialEncoded)
        let initialDescriptions = initialMetadata["controlDescriptions"] as? [[String: Any]] ?? []
        let requested = try await requestedControls(descriptions: initialDescriptions, reply: initial)
        errors += requested.errors
        let final: NativeSwiftValue
        if let controls = requested.states {
            // The native CanvasBox decodes incoming states only after its first
            // result has installed the actual control configuration.
            let requestedUpdate = try await update(pid: pid, identifier: identifier,
                category: previewCategory, content: encoded, controls: controls)
            let reply = try await service.sendUpdate(requestedUpdate)
            final = try await staticReply(reply)
        } else { final = initial }
        let finalEncoded = try await service.encode(final)
        let resultMetadata = try await service.dictionary(finalEncoded)
        let descriptions = resultMetadata["controlDescriptions"] as? [[String: Any]] ?? []
        let displayGetter = try await metadata.type.resolveGetter(named: "displayName", as: (() -> String?).self,
            receiverABI: .opaque(named: metadata.type.name))
        let snapshot = try await image(final)
        let indexes = descriptions.compactMap { description -> [Int]? in
            guard let type = description["controlType"] as? [String: Any], type["discriminant"] as? String == "timeline",
                  let configuration = type["configuration"] as? [String: Any],
                  let stops = configuration["stops"] as? [[String: Any]] else { return nil }
            return stops.compactMap { $0["id"] as? Int }
        }.first
        if let index = request.groupItemIndex { errors.append(unsupportedPreviewGroupItemMessage(index, supportsGroups: false)) }
        return PreviewRendererResult(snapshotData: snapshot, displayName: try unsafe displayGetter.unsafeInvoke(on: metadata),
            sourceLineNumber: request.lineNumber, timelineIndexes: indexes, errors: errors,
            toggleStates: descriptions.contains(where: { ($0["controlType"] as? [String: Any])?["discriminant"] as? String == "toggle" }) ? [true, false] : nil,
            supportedDisplayVariants: catalog.supported, usesDeviceLayout: false)
    }

    private func variantCatalog(category: NativeSwiftValue) async throws -> WidgetVariantCatalog {
        let strategy = try await archivingStrategy()
        let request = try await service.messagingType("RequestPreviewVariantsPayload")
        let make = try await request.resolveInitializer(
            named: "init(contentCategory: PreviewsMessagingOS.ContentCategory, archivingStrategy: PreviewsMessagingOS.ArchivingStrategy) -> PreviewsMessagingOS.RequestPreviewVariantsPayload",
            as: ((NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [category.type: .opaque(named: category.type.name), strategy.type: .opaque(named: strategy.type.name),
                        request: .opaque(named: request.name)])
        let payload = try unsafe make.unsafeInvoke(category.copy(), strategy)
        let encoded = try await service.encode(payload)
        let reply = try await service.send("variants", payload: encoded)
        let responseType = try await service.messagingType("PreviewVariantsPayload")
        let decode = try await responseType.resolveInitializer(
            named: "init(propertyListValue: PreviewsFoundationOS.PropertyList) throws -> PreviewsMessagingOS.PreviewVariantsPayload",
            as: ((NativeSwiftValue) throws -> NativeSwiftValue).self,
            valueABIs: [service.propertyListType: .opaque(named: service.propertyListType.name), responseType: .opaque(named: responseType.name)])
        let response = try unsafe decode.unsafeInvoke(reply)
        let group = try await service.messagingType("PreviewVariantGroup")
        let array = try await runtime.resolveSwiftType(named: "Swift.Array", genericArguments: [.type(group)])
        let getter = try await responseType.resolveGetter(named: "groups", as: (() -> NativeSwiftValue).self,
            valueABIs: [array: .pointer], receiverABI: .opaque(named: responseType.name))
        return try unsafe getter.unsafeInvoke(on: response).withCopy { try WidgetVariantCatalog(nativeGroups: $0) }
    }

    private func archivingStrategy() async throws -> NativeSwiftValue {
        let type = try await service.messagingType("ArchivingStrategy")
        let getter = try await type.resolveStaticGetter(named: "default", as: (() -> NativeSwiftValue).self,
            valueABIs: [type: .opaque(named: type.name)])
        return try unsafe getter.unsafeInvoke()
    }

    private func update(pid: Int32, identifier: NativeSwiftValue, category: NativeSwiftValue,
                        content: NativeSwiftValue, controls: NativeSwiftValue?) async throws -> NativeSwiftValue {
        let dynamicType = try await service.messagingType("DynamicLoadablePreviewProduct")
        let staticType = try await service.messagingType("StaticLinkablePreviewProduct")
        let incrementalType = try await service.messagingType("PreviewIncrementalUpdate")
        let setupType = try await service.messagingType("UpdateSetupPayload")
        let dynamic = try await service.emptyArray(element: dynamicType)
        let products = try await service.emptyArray(element: staticType)
        let increments = try await service.emptyArray(element: incrementalType)
        let setupInitializer = try await setupType.resolveInitializer(
            named: "init(dynamicProducts: [PreviewsMessagingOS.DynamicLoadablePreviewProduct], staticProducts: [PreviewsMessagingOS.StaticLinkablePreviewProduct], shellDidLoadStaticProducts: Swift.Bool, updates: [PreviewsMessagingOS.PreviewIncrementalUpdate], loggingOutputPath: Swift.String?) -> PreviewsMessagingOS.UpdateSetupPayload",
            as: ((NativeSwiftValue, NativeSwiftValue, Bool, NativeSwiftValue, String?) -> NativeSwiftValue).self,
            valueABIs: [dynamic.type: .pointer, products.type: .pointer, increments.type: .pointer,
                        setupType: .opaque(named: setupType.name)])
        let setup = try unsafe setupInitializer.unsafeInvoke(dynamic, products.copy(), false, increments, nil)
        let seedType = try await service.messagingType("HostUpdateSeed")
        let groupSeedType = try await service.messagingType("HostUpdateGroupSeed")
        let seed = try await service.none(of: seedType)
        let groupSeed = try await service.none(of: groupSeedType)
        let previewType = try await service.messagingType("PreviewType")
        let preview = try previewType.makeEnumCase(named: "static")
        let box = try await service.messagingType("PlistValueBox")
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
        let strategy = try await archivingStrategy()
        let type = try await service.messagingType("ShellUpdatePayload")
        let make = try await type.resolveInitializer(
            named: "init(pid: Swift.Int32, hostUpdateSeed: PreviewsMessagingOS.HostUpdateSeed?, hostUpdateGroupSeed: PreviewsMessagingOS.HostUpdateGroupSeed?, previewType: PreviewsMessagingOS.PreviewType, contentIdentifier: PreviewsMessagingOS.ContentIdentifier, contentCategory: PreviewsMessagingOS.ContentCategory, archivingStrategy: PreviewsMessagingOS.ArchivingStrategy, contentPayload: PreviewsFoundationOS.PropertyList, staticProducts: [PreviewsMessagingOS.StaticLinkablePreviewProduct], setupPayload: PreviewsMessagingOS.UpdateSetupPayload, controlStates: [PreviewsMessagingOS.PlistValueBox]?) -> PreviewsMessagingOS.ShellUpdatePayload",
            as: ((Int32, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue,
                  NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: [seed.type: .opaque(named: seed.type.name), groupSeed.type: .opaque(named: groupSeed.type.name),
                preview.type: .opaque(named: preview.type.name), identifier.type: .opaque(named: identifier.type.name),
                category.type: .opaque(named: category.type.name), strategy.type: .opaque(named: strategy.type.name),
                service.propertyListType: .opaque(named: service.propertyListType.name), products.type: .pointer,
                setupType: .opaque(named: setupType.name), states.type: .pointer, type: .opaque(named: type.name)])
        let value = try unsafe make.unsafeInvoke(pid, seed, groupSeed, preview, identifier.copy(), category.copy(),
            strategy, content, products, setup, states)
        return try await service.encode(value)
    }

    private func staticReply(_ value: NativeSwiftValue) async throws -> NativeSwiftValue {
        let type = try await service.messagingType("StaticPreviewReply")
        let decoder = try await type.resolveInitializer(
            named: "init(propertyListValue: PreviewsFoundationOS.PropertyList) throws -> PreviewsMessagingOS.StaticPreviewReply",
            as: ((NativeSwiftValue) throws -> NativeSwiftValue).self,
            valueABIs: [service.propertyListType: .opaque(named: service.propertyListType.name), type: .opaque(named: type.name)])
        return try unsafe decoder.unsafeInvoke(value)
    }

    private func requestedControls(descriptions: [[String: Any]], reply: NativeSwiftValue) async throws ->
        (states: NativeSwiftValue?, errors: [String]) {
        guard request.timelineIndex != nil || request.activityToggleState != nil else { return (nil, []) }
        let type = try await service.messagingType("PlistValueBox")
        let arrayType = try await runtime.resolveSwiftType(named: "Swift.Array", genericArguments: [.type(type)])
        let getter = try await reply.type.resolveGetter(named: "controlStates", as: (() -> NativeSwiftValue).self,
            valueABIs: [arrayType: .pointer], receiverABI: .opaque(named: reply.type.name))
        let initial = try unsafe getter.unsafeInvoke(on: reply)
        var boxes = try initial.withCopy { value -> [Any] in
            guard let values = value as? [Any], values.count == descriptions.count else {
                throw PreviewRendererError("Native preview control descriptions and states do not match")
            }
            return values
        }
        var appliedTimeline = false
        var appliedToggle = false
        for (index, description) in descriptions.enumerated() {
            let kind = (description["controlType"] as? [String: Any])?["discriminant"] as? String
            let value: NativeSwiftValue
            if kind == "timeline", request.timelineIndex != nil {
                let initializer = try await type.resolveInitializer(named: "init<A where A: PreviewsFoundationOS.PropertyListRepresentable>(value: A?) -> PreviewsMessagingOS.PlistValueBox",
                    as: ((Int?) -> NativeSwiftValue).self, genericArguments: [.type(Int.self)], valueABIs: [type: .opaque(named: type.name)])
                value = try unsafe initializer.unsafeInvoke(request.timelineIndex)
                appliedTimeline = true
            } else if kind == "toggle", request.activityToggleState != nil {
                let initializer = try await type.resolveInitializer(named: "init<A where A: PreviewsFoundationOS.PropertyListRepresentable>(value: A?) -> PreviewsMessagingOS.PlistValueBox",
                    as: ((Bool?) -> NativeSwiftValue).self, genericArguments: [.type(Bool.self)], valueABIs: [type: .opaque(named: type.name)])
                value = try unsafe initializer.unsafeInvoke(request.activityToggleState)
                appliedToggle = true
            } else { continue }
            boxes[index] = try value.withCopy { $0 }
        }
        var errors: [String] = []
        if let index = request.timelineIndex, !appliedTimeline {
            errors.append("Unsupported timeline index \(index); the specified preview doesn't support timeline indexes in the currently active scheme.")
        }
        if let state = request.activityToggleState, !appliedToggle {
            errors.append("Unsupported toggle state \(state); the specified preview doesn't support a toggle control in the currently active scheme.")
        }
        guard appliedTimeline || appliedToggle, let first = boxes.first else { return (nil, errors) }
        @MainActor func array<Box>(_ first: Box) async throws -> NativeSwiftValue {
            let values = try boxes.map { value -> Box in
                guard let value = value as? Box else { throw NativePreviewPipelineRequired() }
                return value
            }
            return try await ownedPreviewValue(Optional(values))
        }
        return (try await _openExistential(first, do: array), errors)
    }

    private func image(_ reply: NativeSwiftValue) async throws -> Data {
        let propertyList = service.propertyListType
        let getter = try await reply.type.resolveGetter(named: "contentPayload", as: (() -> NativeSwiftValue).self,
            valueABIs: [propertyList: .opaque(named: propertyList.name)], receiverABI: .opaque(named: reply.type.name))
        let content = try unsafe getter.unsafeInvoke(on: reply)
        let renderType = try await service.messagingType("RenderPayload")
        let decoder = try await renderType.resolveInitializer(
            named: "init(propertyListValue: PreviewsFoundationOS.PropertyList) throws -> PreviewsMessagingOS.RenderPayload",
            as: ((NativeSwiftValue) throws -> NativeSwiftValue).self,
            valueABIs: [propertyList: .opaque(named: propertyList.name), renderType: .opaque(named: renderType.name)])
        let render = try unsafe decoder.unsafeInvoke(content)
        let bitmapType = try await service.messagingType("BitmapDescription")
        let bitmapGetter = try await renderType.resolveGetter(named: "bitmapDescription", as: (() -> NativeSwiftValue).self,
            valueABIs: [bitmapType: .opaque(named: bitmapType.name)], receiverABI: .opaque(named: renderType.name))
        let bitmap = try unsafe bitmapGetter.unsafeInvoke(on: render)
        let makeImage = try await bitmapType.resolveMethod(named: "makeImage() throws -> __C.CGImageRef",
            as: (() throws -> CGImage).self, receiverABI: .opaque(named: bitmapType.name))
        let image = try unsafe makeImage.unsafeInvoke(on: bitmap)
        #if os(iOS)
        guard let data = UIImage(cgImage: image).pngData() else { throw PreviewRendererError("The native preview bitmap could not encode as PNG") }
        return data
        #else
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PreviewRendererError("The native preview bitmap could not create a PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PreviewRendererError("The native preview bitmap could not encode as PNG")
        }
        return data as Data
        #endif
    }
}
#endif
