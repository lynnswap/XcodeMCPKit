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
    var errors = try await complicationPreviewErrors(in: timeline)
    errors += request.generalPreviewOptions(supportedVariants: [:]).errors
    if let index = request.groupItemIndex {
        errors.append(unsupportedPreviewGroupItemMessage(index, supportsGroups: false))
    }
    let result = PreviewRendererResult(displayName: preview.displayName, sourceLineNumber: request.lineNumber,
        errors: errors, supportedDisplayVariants: [:], usesDeviceLayout: true, interfaceOrientation: "portrait")
    withExtendedLifetime(symbol) {}
    return (controller, result)
}

@MainActor
private func complicationPreviewErrors(in timeline: [CLKComplicationTimelineEntry]) async throws -> [String] {
    let runtime = ABIRuntime.shared
    var result: [String] = []
    for entry in timeline {
        let errors = try await runtime.object(entry)
            .resolveMethod(selector: "tl_errors", as: (() -> NSArray?).self)
        for error in try unsafe errors.unsafeInvoke() ?? [] {
            let description = try await runtime.object(error as AnyObject)
                .resolveMethod(selector: "errorDescription", as: (() -> NSString).self)
            result.append(try unsafe description.unsafeInvoke() as String)
        }
    }
    return result
}
#endif
