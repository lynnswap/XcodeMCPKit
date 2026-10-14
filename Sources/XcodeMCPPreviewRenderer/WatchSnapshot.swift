#if os(watchOS) && targetEnvironment(simulator)
import ABIBridge
import CoreGraphics
import DeveloperToolsSupport
import Foundation
import SwiftUI
import WatchKit

@MainActor
func captureWatchPreview(view: AnyView, layout: DeveloperToolsSupport.PreviewLayout) async throws -> CGImage {
    let runtime = ABIRuntime.shared
    let host = _makeUIHostingView(view)
    // watchOS provides this public SwiftUI host but no UIKit Swift module.
    // Keep UIKit's standard view and graphics APIs behind existing ABI calls.
    let applicationSymbol = try await runtime.resolve(
        .init(machOName: "_OBJC_CLASS_$_UIApplication", language: .objectiveC, kind: .data),
        in: .framework(named: "UIKitCore"))
    guard let applicationClass = NSClassFromString("UIApplication") else {
        throw PreviewRendererError("The watch preview's UIApplication class is unavailable")
    }
    let sharedApplication = try await runtime.object(applicationClass as AnyObject)
        .resolveMethod(selector: "sharedApplication", as: (() -> AnyObject).self)
    let application = try unsafe sharedApplication.unsafeInvoke()
    let keyWindow = try await runtime.object(application)
        .resolveMethod(selector: "keyWindow", as: (() -> AnyObject?).self)
    guard let window = try unsafe keyWindow.unsafeInvoke() else {
        throw PreviewRendererError("The running watch preview has no key window")
    }

    let setFrame = try await runtime.object(host)
        .resolveMethod(selector: "setFrame:", as: ((CGRect) -> Void).self)
    let setBounds = try await runtime.object(host)
        .resolveMethod(selector: "setBounds:", as: ((CGRect) -> Void).self)
    let layoutIfNeeded = try await runtime.object(host)
        .resolveMethod(selector: "layoutIfNeeded", as: (() -> Void).self)
    let addSubview = try await runtime.object(window)
        .resolveMethod(selector: "addSubview:", as: ((AnyObject) -> Void).self)
    let removeFromSuperview = try await runtime.object(host)
        .resolveMethod(selector: "removeFromSuperview", as: (() -> Void).self)
    let intrinsicContentSize = try await runtime.object(host)
        .resolveMethod(selector: "intrinsicContentSize", as: (() -> CGSize).self)
    var size: CGSize
    switch layout {
    case .device:
        size = WKInterfaceDevice.current().screenBounds.size
    case .fixed(let width, let height):
        size = CGSize(width: width, height: height)
    case .sizeThatFits:
        size = try unsafe intrinsicContentSize.unsafeInvoke()
    default:
        throw NativePreviewPipelineRequired()
    }
    try requireWatchDrawableSize(size)
    let frame = CGRect(origin: .zero, size: size)
    try unsafe setFrame.unsafeInvoke(frame)
    try unsafe setBounds.unsafeInvoke(frame)
    try unsafe addSubview.unsafeInvoke(host)
    do {
        try unsafe layoutIfNeeded.unsafeInvoke()
        try await Task.sleep(for: .milliseconds(500))
        if case .sizeThatFits = layout {
            size = try unsafe intrinsicContentSize.unsafeInvoke()
            try requireWatchDrawableSize(size)
            let frame = CGRect(origin: .zero, size: size)
            try unsafe setFrame.unsafeInvoke(frame)
            try unsafe setBounds.unsafeInvoke(frame)
        }
        try unsafe layoutIfNeeded.unsafeInvoke()
        let image = try await captureWatchHierarchy(host, size: size)
        try unsafe removeFromSuperview.unsafeInvoke()
        withExtendedLifetime((applicationSymbol, host, application, window)) {}
        return image
    } catch {
        do { try unsafe removeFromSuperview.unsafeInvoke() }
        catch let cleanupError {
            throw PreviewRendererError("\(error); the watch preview host could not be detached: \(cleanupError)")
        }
        throw error
    }
}

private func requireWatchDrawableSize(_ size: CGSize) throws {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
        throw PreviewRendererError("The preview has no drawable area: \(size)")
    }
}

@MainActor
private func captureWatchHierarchy(_ host: NSObject, size: CGSize) async throws -> CGImage {
    let runtime = ABIRuntime.shared
    let begin = try await runtime.resolveCFunction(named: "UIGraphicsBeginImageContextWithOptions",
        as: ((CGSize, Bool, Double) -> Void).self, in: .framework(named: "UIKitCore"))
    let end = try await runtime.resolveCFunction(named: "UIGraphicsEndImageContext",
        as: (() -> Void).self, in: .framework(named: "UIKitCore"))
    let currentImage = try await unsafe runtime.resolveCFunction(named: "UIGraphicsGetImageFromCurrentImageContext",
        as: (() -> UnsafeRawPointer?).self, in: .framework(named: "UIKitCore"))
    let drawHierarchy = try await runtime.object(host)
        .resolveMethod(selector: "drawViewHierarchyInRect:afterScreenUpdates:", as: ((CGRect, Bool) -> Bool).self)
    try unsafe begin.unsafeInvoke(size, false, Double(WKInterfaceDevice.current().screenScale))
    let image: CGImage
    do {
        guard try unsafe drawHierarchy.unsafeInvoke(CGRect(origin: .zero, size: size), true),
              let imagePointer = try unsafe currentImage.unsafeInvoke() else {
            throw PreviewRendererError("The watch preview host could not capture its rendered view")
        }
        let imageObject = unsafe Unmanaged<NSObject>.fromOpaque(imagePointer).takeUnretainedValue()
        let cgImage = try await unsafe runtime.object(imageObject)
            .resolveMethod(selector: "CGImage", as: (() -> UnsafeRawPointer?).self)
        guard let cgImagePointer = try unsafe cgImage.unsafeInvoke() else {
            throw PreviewRendererError("The watch preview snapshot has no CGImage")
        }
        // Both UIKit accessors return borrowed objects; Swift's strong image
        // reference keeps the CGImage alive after ending the image context.
        image = unsafe Unmanaged<CGImage>.fromOpaque(cgImagePointer).takeUnretainedValue()
        withExtendedLifetime(imageObject) {}
    } catch {
        do { try unsafe end.unsafeInvoke() }
        catch let cleanupError {
            throw PreviewRendererError("\(error); the watch graphics context could not be ended: \(cleanupError)")
        }
        throw error
    }
    try unsafe end.unsafeInvoke()
    return image
}
#endif
