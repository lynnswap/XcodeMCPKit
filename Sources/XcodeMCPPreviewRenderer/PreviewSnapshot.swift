#if (os(iOS) || os(tvOS)) && targetEnvironment(simulator)
import Foundation
import UIKit

@MainActor
func staticPreviewSnapshot(of view: UIView, size: CGSize, scale: CGFloat) throws -> Data {
    // The native static FBS snapshot allocates pixels with NSNumber.unsignedIntValue.
    let pixels = CGSize(width: CGFloat(NSNumber(value: Double(size.width * scale)).uint32Value),
                        height: CGFloat(NSNumber(value: Double(size.height * scale)).uint32Value))
    guard pixels.width > 0, pixels.height > 0 else {
        throw PreviewRendererError("The preview has no drawable bitmap area: \(size)")
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    format.preferredRange = .standard
    var drawn = false
    let image = UIGraphicsImageRenderer(size: pixels, format: format).image { context in
        context.cgContext.scaleBy(x: scale, y: scale)
        drawn = view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
    }
    guard drawn, let data = image.pngData() else {
        throw PreviewRendererError("The preview host could not capture its rendered view")
    }
    return data
}
#endif

#if os(iOS) && targetEnvironment(simulator)
import ABIBridge
import CoreFoundation
import UIKit

@MainActor
struct PreviewExclusionGeometry: Equatable {
    let rect: CGRect
    let bounds: CGRect
    let scale: CGFloat

    func pngData(in window: UIWindow) throws -> Data {
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
        format.scale = scale
        format.opaque = false
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            drawn = overlay.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        guard drawn else { throw PreviewRendererError("The preview display exclusion could not be captured") }
        guard let data = image.pngData() else {
            throw PreviewRendererError("The preview display exclusion could not be encoded")
        }
        return data
    }
}

@MainActor
func previewExclusionGeometry(in window: UIWindow) async throws -> PreviewExclusionGeometry? {
    let runtime = ABIRuntime.shared
    let available = try await runtime.resolve(
        .c(.function("SBSIsSystemApertureAvailable", as: (() -> Bool).self)), in: .framework(named: "SpringBoardServices"))
    let enabled: Bool
    if try unsafe available.unsafeInvoke() { enabled = true }
    else { enabled = try await drawsLegacySystemAperture(using: runtime) }
    guard enabled else { return nil }
    let getter = try await runtime.object(window.screen).resolve(.objc(.method("_exclusionArea", as: (() -> AnyObject?).self)))
    guard let shape = try unsafe getter.unsafeInvoke(), let object = shape as? NSObject,
          let shapeClass = NSClassFromString("UISDisplaySingleRectShape"), object.isKind(of: shapeClass) else { return nil }
    let rectGetter = try await runtime.object(shape).resolve(.objc(.method("rect", as: (() -> CGRect).self)))
    return try unsafe PreviewExclusionGeometry(rect: rectGetter.unsafeInvoke(),
        bounds: CGRect(origin: .zero, size: window.screen.fixedCoordinateSpace.bounds.size), scale: window.screen.scale)
}

@MainActor
private func drawsLegacySystemAperture(using runtime: ABIRuntime) async throws -> Bool {
    let copy = try unsafe await runtime.resolve(
        .c(.function("MGCopyAnswer", as: ((Unmanaged<CFString>, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?).self)),
        in: .installName("/usr/lib/libMobileGestalt.dylib"))
    let key = "ArtworkTraits" as CFString
    guard let answer = try unsafe copy.unsafeInvoke(.passUnretained(key), nil)?.takeRetainedValue() else { return false }
    let subtype = (answer as NSDictionary)["ArtworkDeviceSubType"] as? NSNumber
    // PreviewShell enables the exclusion for these legacy display artwork subtypes even if SBS reports false.
    return subtype?.intValue == 2556 || subtype?.intValue == 2796
}
#endif
