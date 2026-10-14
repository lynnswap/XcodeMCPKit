#if os(iOS) && targetEnvironment(simulator)
import ABIBridge
import CoreFoundation
import UIKit

@MainActor
func previewExclusionImage(in window: UIWindow) async throws -> UIImage? {
    let runtime = ABIRuntime.shared
    let available = try await runtime.resolveCFunction(named: "SBSIsSystemApertureAvailable",
        as: (() -> Bool).self, in: .framework(named: "SpringBoardServices"))
    let enabled: Bool
    if try unsafe available.unsafeInvoke() { enabled = true }
    else { enabled = try await drawsLegacySystemAperture(using: runtime) }
    guard enabled else { return nil }
    let getter = try await runtime.object(window.screen).resolveMethod(selector: "_exclusionArea", as: (() -> AnyObject?).self)
    guard let shape = try unsafe getter.unsafeInvoke(), let object = shape as? NSObject,
          let shapeClass = NSClassFromString("UISDisplaySingleRectShape"), object.isKind(of: shapeClass) else { return nil }
    let rectGetter = try await runtime.object(shape).resolveMethod(selector: "rect", as: (() -> CGRect).self)
    let rect = try unsafe rectGetter.unsafeInvoke()
    let bounds = CGRect(origin: .zero, size: window.screen.fixedCoordinateSpace.bounds.size)
    let overlay = UIView(frame: bounds)
    overlay.backgroundColor = .clear
    let exclusion = UIView(frame: rect)
    exclusion.backgroundColor = .black
    // PreviewShell.ExclusionView uses the canonical display rect with these layer settings.
    exclusion.layer.cornerRadius = rect.height * 0.5
    exclusion.layer.cornerCurve = .continuous
    overlay.addSubview(exclusion)
    window.addSubview(overlay)
    defer { overlay.removeFromSuperview() }
    let format = UIGraphicsImageRendererFormat()
    format.scale = window.screen.scale
    format.opaque = false
    var drawn = false
    let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
        drawn = overlay.drawHierarchy(in: bounds, afterScreenUpdates: true)
    }
    guard drawn else { throw PreviewRendererError("The preview display exclusion could not be captured") }
    return image
}

@MainActor
private func drawsLegacySystemAperture(using runtime: ABIRuntime) async throws -> Bool {
    let copy = try unsafe await runtime.resolveCFunction(named: "MGCopyAnswer",
        as: ((Unmanaged<CFString>, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?).self,
        in: .installName("/usr/lib/libMobileGestalt.dylib"))
    let key = "ArtworkTraits" as CFString
    guard let answer = try unsafe copy.unsafeInvoke(.passUnretained(key), nil)?.takeRetainedValue() else { return false }
    let subtype = (answer as NSDictionary)["ArtworkDeviceSubType"] as? NSNumber
    // PreviewShell enables the exclusion for these legacy display artwork subtypes even if SBS reports false.
    return subtype?.intValue == 2556 || subtype?.intValue == 2796
}
#endif
