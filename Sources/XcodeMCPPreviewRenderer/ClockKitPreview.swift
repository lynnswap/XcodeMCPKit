#if os(watchOS) && targetEnvironment(simulator)
import ABIBridge
import ClockKit
import Foundation
import SwiftUI
import XcodeMCPWire

@MainActor
func makeClockKitPreview(from preview: SwiftUI._Preview, request: PreviewRendererRequest) async throws ->
    (controller: AnyObject, result: PreviewRendererResult)? {
    guard let context = preview.context else { return nil }
    // Watch's native metadata treats legacy contexts as complications unless
    // the WidgetKit context supplies a different content category.
    guard try await legacyPreviewContextCategory(context) == nil else { return nil }
    let timeline = _ComplicationPreviewContext._previewTimeline(from: preview)
    let runtime = ABIRuntime.shared
    let symbol = try await runtime.resolve(
        .init(machOName: "_OBJC_CLASS_$_NTKUVPreviewComplicationViewController", language: .objectiveC, kind: .data),
        in: .framework(named: "NanoTimeKit"))
    guard let type = NSClassFromString("NTKUVPreviewComplicationViewController") else {
        throw PreviewRendererError("The native complication preview controller is unavailable")
    }
    let allocate = try await runtime.object(type as AnyObject)
        .resolveMethod(selector: "alloc", as: (() -> AnyObject).self)
    let allocated = try unsafe allocate.unsafeInvoke()
    let initialize = try await runtime.object(allocated)
        .resolveMethod(selector: "initWithTimeline:", as: ((NSArray) -> AnyObject?).self)
    guard let controller = try unsafe initialize.unsafeInvoke(timeline as NSArray) else {
        throw PreviewRendererError("The native complication preview controller rejected the timeline")
    }
    let setLive = try await runtime.object(controller)
        .resolveMethod(selector: "setDisplayingLivePreview:", as: ((Bool) -> Void).self)
    try unsafe setLive.unsafeInvoke(false)
    var errors = request.generalPreviewOptions(supportedVariants: [:]).errors
    if let index = request.groupItemIndex {
        errors.append(unsupportedPreviewGroupItemMessage(index, supportsGroups: false))
    }
    let usesDeviceLayout: Bool
    if case .device = preview.layout { usesDeviceLayout = true }
    else { usesDeviceLayout = false }
    let result = PreviewRendererResult(displayName: preview.displayName, sourceLineNumber: request.lineNumber,
        errors: errors, supportedDisplayVariants: [:], usesDeviceLayout: usesDeviceLayout, interfaceOrientation: "portrait")
    withExtendedLifetime(symbol) {}
    return (controller, result)
}

@MainActor
func configureClockKitPreviewHosting(in rootView: AnyObject) async throws {
    guard let hostingClass = NSClassFromString("CDComplicationHostingView") else { return }
    let runtime = ABIRuntime.shared
    var views = [rootView]
    while let view = views.popLast() {
        if let object = view as? NSObject, object.isKind(of: hostingClass) {
            let hostingGetter = try await runtime.object(view)
                .resolveMethod(selector: "hosting", as: (() -> AnyObject).self)
            let hosting = try unsafe hostingGetter.unsafeInvoke()
            let viewGetter = try await runtime.object(hosting)
                .resolveMethod(selector: "view", as: (() -> AnyObject).self)
            let hostingView = try unsafe viewGetter.unsafeInvoke()
            let controllerGetter = try await runtime.object(hostingView)
                .resolveMethod(selector: "_viewDelegate", as: (() -> AnyObject?).self)
            guard let controller = try unsafe controllerGetter.unsafeInvoke() as? any _UIHostingViewable else {
                throw PreviewRendererError("The native complication view has no SwiftUI hosting controller")
            }
            // ComplicationDisplay enables this only in Apple's preview bundles.
            // The source app's identity remains intact in our preview host.
            controller._disableSafeArea = true
        }
        let subviews = try await runtime.object(view)
            .resolveMethod(selector: "subviews", as: (() -> NSArray).self)
        views.append(contentsOf: try unsafe subviews.unsafeInvoke().map { $0 as AnyObject })
    }
}

#endif
