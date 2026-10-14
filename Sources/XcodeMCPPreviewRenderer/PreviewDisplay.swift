#if os(iOS) || os(tvOS) || os(visionOS) || os(macOS) || os(watchOS)
import ABIBridge
import DeveloperToolsSupport
import SwiftUI
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
import XcodeMCPWire

let supportedPreviewDisplayVariants: [String: [String]] = {
    #if os(macOS) || targetEnvironment(macCatalyst)
    let keys = ["Color Scheme"]
    #elseif os(tvOS)
    let keys = ["Color Scheme", "Contrast", "Control Borders"]
    #elseif os(watchOS)
    let keys = ["Dynamic Type"]
    #elseif os(visionOS)
    let keys: [String] = []
    #else
    return PreviewRendererRequest.displayVariantValues
    #endif
    #if !os(iOS) || targetEnvironment(macCatalyst)
    return PreviewRendererRequest.displayVariantValues.filter { keys.contains($0.key) }
    #endif
}()

private let dynamicTypeSizes: [String: DynamicTypeSize] = [
    "X Small": .xSmall, "Small": .small, "Medium": .medium, "Large": .large,
    "X Large": .xLarge, "XX Large": .xxLarge, "XXX Large": .xxxLarge,
    "AX 1": .accessibility1, "AX 2": .accessibility2, "AX 3": .accessibility3,
    "AX 4": .accessibility4, "AX 5": .accessibility5,
]

#if canImport(UIKit) && !os(watchOS)
@MainActor
private let contentSizeCategories: [String: UIContentSizeCategory] = [
    "X Small": .extraSmall, "Small": .small, "Medium": .medium, "Large": .large,
    "X Large": .extraLarge, "XX Large": .extraExtraLarge, "XXX Large": .extraExtraExtraLarge,
    "AX 1": .accessibilityMedium, "AX 2": .accessibilityLarge, "AX 3": .accessibilityExtraLarge,
    "AX 4": .accessibilityExtraExtraLarge, "AX 5": .accessibilityExtraExtraExtraLarge,
]

#endif

@MainActor
func applyDisplayVariants(to content: AnyView, variants: [String: String]) throws -> AnyView {
    var view = content
    for (key, value) in variants {
        guard PreviewRendererRequest.displayVariantValues[key]?.contains(value) == true else {
            throw NativePreviewPipelineRequired()
        }
        switch (key, value) {
        case ("Color Scheme", "Light Appearance"): view = AnyView(view.preferredColorScheme(.light))
        case ("Color Scheme", "Dark Appearance"): view = AnyView(view.preferredColorScheme(.dark))
        case ("Contrast", "Standard Contrast"): view = AnyView(view.environment(\._colorSchemeContrast, .standard))
        case ("Contrast", "Increased Contrast"): view = AnyView(view.environment(\._colorSchemeContrast, .increased))
        case ("Control Borders", "Hidden"): view = AnyView(view.environment(\._accessibilityShowButtonShapes, false))
        case ("Control Borders", "Shown"): view = AnyView(view.environment(\._accessibilityShowButtonShapes, true))
        case ("Dynamic Type", _):
            guard let size = dynamicTypeSizes[value] else { throw NativePreviewPipelineRequired() }
            view = AnyView(view.dynamicTypeSize(size))
        case ("Orientation", _): break
        default: throw NativePreviewPipelineRequired()
        }
    }
    return view
}

#if canImport(UIKit) && !os(watchOS)
@MainActor
func applyDisplayVariants(to controller: UIViewController, variants: [String: String]) {
    if let style = variants["Color Scheme"] {
        controller.traitOverrides.userInterfaceStyle = style == "Dark Appearance" ? .dark : .light
    }
    if let contrast = variants["Contrast"] {
        controller.traitOverrides.accessibilityContrast = contrast == "Increased Contrast" ? .high : .normal
    }
    if let category = variants["Dynamic Type"].flatMap({ contentSizeCategories[$0] }) {
        controller.traitOverrides.preferredContentSizeCategory = category
    }
}

#endif

#if os(iOS) && targetEnvironment(simulator)
@MainActor
func viewPreviewOrientation(_ preview: NativeSwiftValue) async throws -> UIInterfaceOrientation {
    do {
        let value = try await previewTraitValue(preview, named: "21DeveloperToolsSupport32PreviewInterfaceOrientationTraitV")
        let runtime = ABIRuntime.shared
        // The extension lives in a different image from the trait's enum.
        let support = try await runtime.resolveSwiftType(named: "PreviewsOSSupportUI.CounterRotationViewController",
            in: .framework(named: "PreviewsOSSupportUI"))
        let type = try await runtime.resolveSwiftType(named: "PreviewsMessagingOS.PreviewTraits.Orientation",
            in: .framework(named: "PreviewsMessagingOS"))
        let converter = try await value.type.resolveGetter(named: "previewOrientation", as: (() -> NativeSwiftValue).self,
            valueABIs: [type: .opaque(named: type.name)], receiverABI: .opaque(named: value.type.name))
        let orientation = try withExtendedLifetime(support) { try unsafe converter.unsafeInvoke(on: value) }
        let getter = try await orientation.type.resolveGetter(named: "rawValue", as: (() -> String).self,
            receiverABI: .opaque(named: orientation.type.name))
        return try interfaceOrientation(rawValue: unsafe getter.unsafeInvoke(on: orientation))
    } catch is ABIResolutionError { throw NativePreviewPipelineRequired() }
}

func interfaceOrientation(rawValue: String) throws -> UIInterfaceOrientation {
    switch rawValue {
    case "portrait": .portrait
    case "portraitUpsideDown": .portraitUpsideDown
    case "landscapeLeft": .landscapeLeft
    case "landscapeRight": .landscapeRight
    default: throw NativePreviewPipelineRequired()
    }
}

func interfaceOrientation(variant: String?, source: UIInterfaceOrientation) throws -> UIInterfaceOrientation {
    guard let variant else { return source }
    return switch variant {
    case "Portrait": .portrait
    case "Landscape Left": .landscapeLeft
    case "Landscape Right": .landscapeRight
    default: throw NativePreviewPipelineRequired()
    }
}

func interfaceOrientationName(_ orientation: UIInterfaceOrientation) throws -> String {
    switch orientation {
    case .portrait: "portrait"
    case .portraitUpsideDown: "portraitUpsideDown"
    case .landscapeLeft: "landscapeLeft"
    case .landscapeRight: "landscapeRight"
    default: throw NativePreviewPipelineRequired()
    }
}

@MainActor
func makeCounterRotationController(content: UIHostingController<AnyView>, orientation: UIInterfaceOrientation) async throws -> UIViewController {
    do {
        let type = try await ABIRuntime.shared.resolveSwiftType(named: "PreviewsOSSupportUI.CounterRotationViewController",
            in: .framework(named: "PreviewsOSSupportUI"))
        // UIKit's imported enum has no discoverable nominal descriptor. Owning a
        // compiled value supplies its metadata; NS_ENUM(NSInteger) uses Int64 on arm64.
        let value = try await ownedPreviewValue(orientation)
        let initializer = try await type.resolveInitializer(
            named: "init(contentView: __C.UIView, contentOrientation: __C.UIInterfaceOrientation) -> PreviewsOSSupportUI.CounterRotationViewController",
            as: ((UIView, NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: [value.type: .int64])
        let result = try unsafe initializer.unsafeInvoke(content.view, value)
        guard let controller = try result.withCopy({ $0 as? UIViewController }) else {
            throw NativePreviewPipelineRequired()
        }
        controller.addChild(content)
        _ = controller.view
        content.didMove(toParent: controller)
        return controller
    } catch is ABIResolutionError { throw NativePreviewPipelineRequired() }
}

@MainActor
func requestPreviewOrientation(_ target: UIInterfaceOrientation, in scene: UIWindowScene) async throws {
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
#endif
#endif
