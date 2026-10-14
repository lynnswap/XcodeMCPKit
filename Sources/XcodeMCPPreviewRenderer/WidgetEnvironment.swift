#if os(iOS) && targetEnvironment(simulator)
import ABIBridge
import Foundation
import SwiftUI
import UIKit

@MainActor
func applyWidgetDisplayProperties(to environment: inout EnvironmentValues, screen: UIScreen) async throws {
    do {
        let runtime = ABIRuntime.shared
        let configurationGetter = try await runtime.object(screen)
            .resolveMethod(selector: "displayConfiguration", as: (() -> AnyObject).self)
        let configuration = try unsafe configurationGetter.unsafeInvoke()
        let symbol = try await runtime.resolve(
            .init(machOName: "_OBJC_CLASS_$_CHSWidgetDisplayProperties", language: .objectiveC, kind: .data),
            in: .framework(named: "ChronoServices"))
        guard let type = NSClassFromString("CHSWidgetDisplayProperties") else { throw NativePreviewPipelineRequired() }
        let allocate = try await runtime.object(type as AnyObject)
            .resolveMethod(selector: "alloc", as: (() -> AnyObject).self)
        let allocated = try unsafe allocate.unsafeInvoke()
        // The native constructor converts the screen's point scale and display
        // gamut to CHS properties; public displayScale alone leaves archive defaults.
        let initialize = try await runtime.object(allocated)
            .resolveMethod(selector: "initWithDisplayConfiguration:", as: ((AnyObject) -> AnyObject).self)
        let properties = try unsafe initialize.unsafeInvoke(configuration)
        guard let properties = properties as? NSObject else { throw NativePreviewPipelineRequired() }
        let values = try await ownedPreviewValue(environment)
        let setter = try await values.type.resolveSetter(
            named: "(extension in WidgetKit):SwiftUI.EnvironmentValues._widgetDisplayProperties.setter : __C.CHSWidgetDisplayProperties",
            as: NSObject.self, receiverABI: .opaque(named: values.type.name))
        try unsafe setter.unsafeInvoke(on: values, properties)
        environment = try values.take(as: EnvironmentValues.self)
        withExtendedLifetime((symbol, configuration, allocated, properties)) {}
    } catch ABIResolutionError.declarationNotFound {
        throw NativePreviewPipelineRequired()
    } catch ABIResolutionError.imageUnavailable {
        throw NativePreviewPipelineRequired()
    } catch ABIResolutionError.imageNotLoaded {
        throw NativePreviewPipelineRequired()
    }
}

#endif
