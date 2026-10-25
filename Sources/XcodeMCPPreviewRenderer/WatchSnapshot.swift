#if os(watchOS) && targetEnvironment(simulator)
import ABIBridge
import CoreGraphics
import DeveloperToolsSupport
import Foundation
import SwiftUI
import WatchKit

@MainActor
func captureWatchPreview(view: AnyView, layout: DeveloperToolsSupport.PreviewLayout) async throws -> CGImage {
    let controller = _makeWatchKitUIHostingController(AnyView(view._statusBar(hidden: true)))
    // The native device entry point keeps WatchKit's safe-area layout active;
    // fixed and fitting previews use the unconstrained hosting layout.
    switch layout {
    case .device: controller._disableSafeArea = false
    default: controller._disableSafeArea = true
    }
    return try await captureWatchPreview(controller: controller, layout: layout, hostingController: controller)
}

@MainActor
func captureWatchPreview(controller: AnyObject) async throws -> CGImage {
    try await captureWatchPreview(controller: controller, layout: .device, hostingController: nil)
}

@MainActor
private func captureWatchPreview(controller: AnyObject, layout: DeveloperToolsSupport.PreviewLayout,
                                 hostingController: (any _UIHostingViewable)?) async throws -> CGImage {
    let runtime = ABIRuntime.shared
    // watchOS exposes SwiftUI's host protocol but marks UIKit controllers
    // unavailable. Use the existing ABI bridge for standard view containment.
    let applicationSymbol = try await runtime.resolve(
        .objc(.symbol(machOName: "_OBJC_CLASS_$_UIApplication", kind: .data)),
        in: .framework(named: "UIKitCore"))
    guard let applicationClass = NSClassFromString("UIApplication") else {
        throw PreviewRendererError("The watch preview's UIApplication class is unavailable")
    }
    let sharedApplication = try await runtime.object(applicationClass as AnyObject)
        .resolve(.objc(.method("sharedApplication", as: (() -> AnyObject).self)))
    let application = try unsafe sharedApplication.unsafeInvoke()
    let keyWindow = try await runtime.object(application)
        .resolve(.objc(.method("keyWindow", as: (() -> AnyObject?).self)))
    guard let window = try unsafe keyWindow.unsafeInvoke() else {
        throw PreviewRendererError("The running watch preview has no key window")
    }
    let rootController = try await runtime.object(window)
        .resolve(.objc(.method("rootViewController", as: (() -> AnyObject?).self)))
    guard let parent = try unsafe rootController.unsafeInvoke() else {
        throw PreviewRendererError("The watch preview window has no root controller")
    }
    let hostGetter = try await runtime.object(controller)
        .resolve(.objc(.method("view", as: (() -> AnyObject).self)))
    let host = try unsafe hostGetter.unsafeInvoke()
    let parentViewGetter = try await runtime.object(parent)
        .resolve(.objc(.method("view", as: (() -> AnyObject).self)))
    let parentView = try unsafe parentViewGetter.unsafeInvoke()
    let setFrame = try await runtime.object(host)
        .resolve(.objc(.method("setFrame:", as: ((CGRect) -> Void).self)))
    let setBounds = try await runtime.object(host)
        .resolve(.objc(.method("setBounds:", as: ((CGRect) -> Void).self)))
    let layoutIfNeeded = try await runtime.object(host)
        .resolve(.objc(.method("layoutIfNeeded", as: (() -> Void).self)))
    let addChild = try await runtime.object(parent)
        .resolve(.objc(.method("addChildViewController:", as: ((AnyObject) -> Void).self)))
    let addSubview = try await runtime.object(parentView)
        .resolve(.objc(.method("addSubview:", as: ((AnyObject) -> Void).self)))
    let didMove = try await runtime.object(controller)
        .resolve(.objc(.method("didMoveToParentViewController:", as: ((AnyObject?) -> Void).self)))
    let willMove = try await runtime.object(controller)
        .resolve(.objc(.method("willMoveToParentViewController:", as: ((AnyObject?) -> Void).self)))
    let removeFromSuperview = try await runtime.object(host)
        .resolve(.objc(.method("removeFromSuperview", as: (() -> Void).self)))
    let removeFromParent = try await runtime.object(controller)
        .resolve(.objc(.method("removeFromParentViewController", as: (() -> Void).self)))
    let screen = WKInterfaceDevice.current().screenBounds.size
    var size: CGSize
    switch layout {
    case .device, .sizeThatFits: size = screen
    case .fixed(let width, let height): size = CGSize(width: width, height: height)
    default: throw NativePreviewPipelineRequired()
    }
    try requireWatchDrawableSize(size)
    let frame = CGRect(origin: .zero, size: size)
    try unsafe setFrame.unsafeInvoke(frame)
    try unsafe setBounds.unsafeInvoke(frame)
    try unsafe addChild.unsafeInvoke(controller)
    func detach() throws {
        try unsafe willMove.unsafeInvoke(nil)
        try unsafe removeFromSuperview.unsafeInvoke()
        try unsafe removeFromParent.unsafeInvoke()
    }
    do {
        try unsafe addSubview.unsafeInvoke(host)
        try unsafe didMove.unsafeInvoke(parent)
        try unsafe layoutIfNeeded.unsafeInvoke()
        try await Task.sleep(for: .milliseconds(500))
        hostingController?._render(seconds: 0)
        if case .sizeThatFits = layout, let hostingController {
            size = hostingController.sizeThatFits(in: screen)
            try requireWatchDrawableSize(size)
            let frame = CGRect(origin: .zero, size: size)
            try unsafe setFrame.unsafeInvoke(frame)
            try unsafe setBounds.unsafeInvoke(frame)
        }
        try unsafe layoutIfNeeded.unsafeInvoke()
        hostingController?._render(seconds: 0)
        let image = try await captureWatchHierarchy(host, size: size)
        try detach()
        withExtendedLifetime((applicationSymbol, controller, host, application, window, parent)) {}
        return image
    } catch {
        do { try detach() }
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
private func captureWatchHierarchy(_ host: AnyObject, size: CGSize) async throws -> CGImage {
    let runtime = ABIRuntime.shared
    let begin = try await runtime.resolve(
        .c(.function("UIGraphicsBeginImageContextWithOptions", as: ((CGSize, Bool, Double) -> Void).self)), in: .framework(named: "UIKitCore"))
    let end = try await runtime.resolve(.c(.function("UIGraphicsEndImageContext", as: (() -> Void).self)), in: .framework(named: "UIKitCore"))
    let currentImage = try await unsafe runtime.resolve(
        .c(.function("UIGraphicsGetImageFromCurrentImageContext", as: (() -> UnsafeRawPointer?).self)), in: .framework(named: "UIKitCore"))
    let currentContext = try await unsafe runtime.resolve(
        .c(.function("UIGraphicsGetCurrentContext", as: (() -> UnsafeRawPointer?).self)), in: .framework(named: "UIKitCore"))
    let drawHierarchy = try await runtime.object(host)
        .resolve(.objc(.method("drawViewHierarchyInRect:afterScreenUpdates:", as: ((CGRect, Bool) -> Bool).self)))
    try unsafe begin.unsafeInvoke(size, true, Double(WKInterfaceDevice.current().screenScale))
    let image: CGImage
    do {
        guard let contextPointer = try unsafe currentContext.unsafeInvoke() else {
            throw PreviewRendererError("The watch preview has no graphics context")
        }
        let context = unsafe Unmanaged<CGContext>.fromOpaque(contextPointer).takeUnretainedValue()
        // Native watch previews include the window's opaque black backdrop.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        guard try unsafe drawHierarchy.unsafeInvoke(CGRect(origin: .zero, size: size), true),
              let imagePointer = try unsafe currentImage.unsafeInvoke() else {
            throw PreviewRendererError("The watch preview host could not capture its rendered view")
        }
        let imageObject = unsafe Unmanaged<NSObject>.fromOpaque(imagePointer).takeUnretainedValue()
        let cgImage = try await unsafe runtime.object(imageObject)
            .resolve(.objc(.method("CGImage", as: (() -> UnsafeRawPointer?).self)))
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
