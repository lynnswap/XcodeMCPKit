#if os(watchOS) && targetEnvironment(simulator)
import ABIBridge
import ClockKit
import Foundation
import SwiftUI
import XcodeMCPWire

@MainActor
struct ClockKitPreview {
    let timeline: [CLKComplicationTimelineEntry]
    let result: PreviewRendererResult
}

@MainActor
func makeClockKitPreview(from preview: SwiftUI._Preview, request: PreviewRendererRequest) -> ClockKitPreview {
    let timeline = _ComplicationPreviewContext._previewTimeline(from: preview)
    var errors = request.generalPreviewOptions(supportedVariants: [:]).errors
    if let index = request.groupItemIndex {
        errors.append(unsupportedPreviewGroupItemMessage(index, supportsGroups: false))
    }
    let usesDeviceLayout: Bool
    if case .device = preview.layout { usesDeviceLayout = true }
    else { usesDeviceLayout = false }
    let result = PreviewRendererResult(displayName: preview.displayName, sourceLineNumber: request.lineNumber,
        errors: errors, supportedDisplayVariants: [:], usesDeviceLayout: usesDeviceLayout, interfaceOrientation: "portrait")
    return ClockKitPreview(timeline: timeline, result: result)
}

@MainActor
func makeClockKitPreviewController(_ preview: ClockKitPreview) async throws -> AnyObject {
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
    guard let controller = try unsafe initialize.unsafeInvoke(preview.timeline as NSArray) else {
        throw PreviewRendererError("The native complication preview controller rejected the timeline")
    }
    let setLive = try await runtime.object(controller)
        .resolveMethod(selector: "setDisplayingLivePreview:", as: ((Bool) -> Void).self)
    try unsafe setLive.unsafeInvoke(false)
    withExtendedLifetime(symbol) {}
    return controller
}

#endif
