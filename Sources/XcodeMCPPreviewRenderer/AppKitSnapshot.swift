#if os(macOS)
import ABIBridge
import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import QuartzCore

@MainActor
func makeAppKitPreviewWindow(size: CGSize, usesDeviceLayout: Bool) throws -> NSWindow {
    guard let framework = Bundle(path: "/System/Library/PrivateFrameworks/PreviewsInjection.framework") else {
        throw NativePreviewPipelineRequired()
    }
    do { try framework.loadAndReturnError() }
    catch { throw NativePreviewPipelineRequired() }
    guard let type = NSClassFromString("_TtC17PreviewsInjection25MacOSPreviewHostingWindow") as? NSWindow.Type else {
        throw NativePreviewPipelineRequired()
    }
    // Native preview windows supply key/main appearance without activating
    // the renderer. Full-size content lets AppKit include titlebar safe areas.
    let style: NSWindow.StyleMask = usesDeviceLayout
        ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
    let window = type.init(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
        styleMask: style, backing: .buffered, defer: false)
    window.hasShadow = false
    return window
}

@MainActor
func captureAppKitPreview(window: NSWindow) async throws -> NSBitmapImageRep {
    do { return try await captureAppKitWindow(window) }
    catch is ABIResolutionError { throw NativePreviewPipelineRequired() }
}

@MainActor
private func captureAppKitWindow(_ window: NSWindow) async throws -> NSBitmapImageRep {
    let runtime = ABIRuntime.shared
    var leases: [ResolvedSymbol] = []
    func constant(_ name: String) async throws -> NSString {
        let symbol = try await runtime.resolve(.init(machOName: "_\(name)", language: .c, kind: .data),
            in: .framework(named: "QuartzCore"))
        leases.append(symbol)
        return try unsafe symbol.withUnsafeAddress { address in
            guard let pointer = unsafe address.load(as: UnsafeRawPointer?.self) else {
                throw NativePreviewPipelineRequired()
            }
            return unsafe Unmanaged<NSString>.fromOpaque(pointer).takeUnretainedValue()
        }
    }
    guard let displayClass = NSClassFromString("CADisplay") else { throw NativePreviewPipelineRequired() }
    let mainDisplay = try await runtime.object(displayClass as AnyObject)
        .resolveMethod(selector: "mainDisplay", as: (() -> AnyObject?).self)
    guard let display = try unsafe mainDisplay.unsafeInvoke() else { throw NativePreviewPipelineRequired() }
    let nameGetter = try await runtime.object(display)
        .resolveMethod(selector: "name", as: (() -> NSString?).self)
    guard let displayName = try unsafe nameGetter.unsafeInvoke(), displayName.length > 0 else {
        throw NativePreviewPipelineRequired()
    }
    let contextGetter = try await runtime.object(window)
        .resolveMethod(selector: "layerHostingContextID", as: (() -> UInt32).self)
    let contextID = try unsafe contextGetter.unsafeInvoke()
    let modeKey = try await constant("kCASnapshotMode")
    let mode = try await constant("kCASnapshotModeIncludeContextList")
    let destinationKey = try await constant("kCASnapshotDestination")
    let displayKey = try await constant("kCASnapshotDisplayName")
    let originXKey = try await constant("kCASnapshotOriginX")
    let originYKey = try await constant("kCASnapshotOriginY")
    let contextListKey = try await constant("kCASnapshotContextList")
    let contextIDKey = try await constant("kCASnapshotContextId")
    let transformKey = try await constant("kCASnapshotTransform")
    let bottomLeftKey = try await constant("kCASnapshotBottomLeftOrigin")
    // The macOS 26.6.2 native caller and callee use a 32-bit port, an
    // NSDictionary pointer, and a return register normalized to 0/1.
    // This private C entry point has no declaration in the public SDK.
    let snapshot = try await unsafe runtime.resolveCFunction(named: "CARenderServerSnapshot",
        as: ((UInt32, UnsafeRawPointer) -> UInt32).self, in: .framework(named: "QuartzCore"))
    try Task.checkCancellation()
    let originalAlpha = window.alphaValue
    window.alphaValue = 0
    window.order(.above, relativeTo: window.windowNumber)
    defer {
        window.orderOut(nil)
        window.alphaValue = originalAlpha
    }
    window.display()
    window.layoutIfNeeded()
    window.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    let scale = window.backingScaleFactor
    guard let width = Int(exactly: (max(window.frame.width, 1) * scale).rounded(.towardZero)),
          let height = Int(exactly: (max(window.frame.height, 1) * scale).rounded(.towardZero)),
          width > 0, height > 0 else { throw PreviewRendererError("The preview window has no drawable surface") }
    let properties: [String: Any] = [
        kIOSurfaceWidth as String: width,
        kIOSurfaceHeight as String: height,
        kIOSurfaceBytesPerElement as String: 4,
        kIOSurfacePixelFormat as String: kCVPixelFormatType_32BGRA,
    ]
    guard let surface = IOSurfaceCreate(properties as CFDictionary),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let colorSpacePropertyList = colorSpace.copyPropertyList() else {
        throw PreviewRendererError("The preview window could not create its snapshot surface")
    }
    IOSurfaceSetValue(surface, kIOSurfaceColorSpace, colorSpacePropertyList)
    let translation = CATransform3DMakeTranslation(0, scale == 1 ? -0.01 : -CGFloat(height) / scale, 0)
    let transform = CATransform3DConcat(translation, CATransform3DMakeScale(scale, scale, 1))
    let context = NSMutableDictionary()
    context.setObject(NSNumber(value: contextID), forKey: contextIDKey)
    context.setObject(NSValue(caTransform3D: transform), forKey: transformKey)
    let options = NSMutableDictionary()
    // The renderer compares this mode object by identity, not string contents.
    options.setObject(mode, forKey: modeKey)
    options.setObject(surface, forKey: destinationKey)
    options.setObject(displayName, forKey: displayKey)
    options.setObject(NSNumber(value: 0), forKey: originXKey)
    options.setObject(NSNumber(value: 0), forKey: originYKey)
    options.setObject([context] as NSArray, forKey: contextListKey)
    options.setObject(NSNumber(value: true), forKey: bottomLeftKey)
    let pointer = unsafe Unmanaged.passUnretained(options).toOpaque()
    guard try unsafe snapshot.unsafeInvoke(0, UnsafeRawPointer(pointer)) == 1 else {
        throw PreviewRendererError("The preview window could not capture its rendered surface")
    }
    try Task.checkCancellation()
    let lockStatus = IOSurfaceLock(surface, .readOnly, nil)
    guard lockStatus == 0 else { throw NSError(domain: NSMachErrorDomain, code: Int(lockStatus)) }
    let base = unsafe IOSurfaceGetBaseAddress(surface)
    let copied = unsafe Data(bytes: base, count: IOSurfaceGetAllocSize(surface))
    let unlockStatus = IOSurfaceUnlock(surface, .readOnly, nil)
    guard unlockStatus == 0 else { throw NSError(domain: NSMachErrorDomain, code: Int(unlockStatus)) }
    guard let provider = CGDataProvider(data: copied as CFData),
          let image = unsafe CGImage(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface),
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: IOSurfaceGetBytesPerRow(surface),
            space: colorSpace, bitmapInfo: .byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        throw PreviewRendererError("The preview window could not create its snapshot image")
    }
    withExtendedLifetime((leases, options, context, display, displayName, surface)) {}
    return NSBitmapImageRep(cgImage: image)
}
#endif
