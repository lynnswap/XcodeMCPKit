import ABIBridge
import AppKit
import CoreGraphics
import Foundation
import ImageIO

extension NativePreviewCorrection {
    func writeSnapshot(from source: Data, to destination: URL, deviceType: URL?,
                       usesDeviceLayout: Bool, orientation: String?, exclusion: Data? = nil) async throws {
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw NativeRuntimeError.invocation("The preview snapshot could not be decoded")
        }
        let mask: NSImage?
        if usesDeviceLayout, let deviceType {
            mask = try snapshotImages.framebufferMask(in: deviceType, geometry: CGSize(width: image.width, height: image.height))
        } else { mask = nil }
        let exclusionImage: CGImage?
        if usesDeviceLayout, let exclusion {
            exclusionImage = try snapshotImages.exclusionImage(from: exclusion)
        } else { exclusionImage = nil }
        let degrees: Double?
        if mask != nil || exclusionImage != nil {
            guard let orientation else { throw NativePipelineRequired() }
            do { degrees = try await snapshotRotationDegrees(orientation) }
            catch is ABIResolutionError { throw NativePipelineRequired() }
        } else { degrees = nil }
        let png = try snapshotImages.png(from: source, image: image, framebufferMask: mask,
            rotationDegrees: degrees, swapsAxes: orientation == "landscapeLeft" || orientation == "landscapeRight",
            exclusion: exclusion, exclusionImage: exclusionImage)
        try png.write(to: destination)
    }

    @MainActor
    final class SnapshotImages {
        private var mask: (resource: URL, data: Data, geometry: CGSize, image: NSImage)?
        private var exclusion: (data: Data, image: CGImage)?
        private var snapshot: (source: Data, mask: NSImage?, exclusion: Data?, rotationDegrees: Double?, swapsAxes: Bool, png: Data)?

        func png(from source: Data, image: CGImage, framebufferMask: NSImage?, rotationDegrees: Double?,
                 swapsAxes: Bool, exclusion: Data?, exclusionImage: CGImage?) throws -> Data {
            if let snapshot, snapshot.source == source, snapshot.mask === framebufferMask,
               snapshot.exclusion == exclusion, snapshot.rotationDegrees == rotationDegrees, snapshot.swapsAxes == swapsAxes {
                return snapshot.png
            }
            let data = NSMutableData()
            guard let thumbnail = NativePreviewCorrection.thumbnail(from: image, maximumDimension: 1500,
                framebufferMask: framebufferMask, rotationDegrees: rotationDegrees, swapsAxes: swapsAxes,
                exclusionImage: exclusionImage),
                  let output = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
                throw NativeRuntimeError.invocation("The preview thumbnail could not be created")
            }
            CGImageDestinationAddImage(output, thumbnail, nil)
            guard CGImageDestinationFinalize(output) else {
                throw NativeRuntimeError.invocation("The preview thumbnail could not be saved")
            }
            let png = data as Data
            snapshot = (source, framebufferMask, exclusion, rotationDegrees, swapsAxes, png)
            return png
        }

        func framebufferMask(in deviceType: URL, geometry: CGSize) throws -> NSImage? {
            let resources = deviceType.appendingPathComponent("Contents/Resources", isDirectory: true)
            let data = try Data(contentsOf: resources.appendingPathComponent("profile.plist"))
            guard let profile = try unsafe PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw NativePipelineRequired()
            }
            guard let value = profile["framebufferMask"] else { return nil }
            guard let name = value as? String else { throw NativePipelineRequired() }
            var resource = resources.appendingPathComponent(name)
            if resource.pathExtension.isEmpty { resource.appendPathExtension("pdf") }
            // The Simulator retains a device-type URL, so the resource bytes must still be checked.
            guard let maskData = try? Data(contentsOf: resource) else {
                throw NativeRuntimeError.unavailable("The selected device's framebuffer mask could not be loaded: \(resource.path)")
            }
            if let mask, mask.resource == resource, mask.data == maskData, mask.geometry == geometry { return mask.image }
            guard let image = NSImage(data: maskData) else {
                throw NativeRuntimeError.unavailable("The selected device's framebuffer mask could not be loaded: \(resource.path)")
            }
            mask = (resource, maskData, geometry, image)
            return image
        }

        func exclusionImage(from data: Data) throws -> CGImage {
            if let exclusion, exclusion.data == data { return exclusion.image }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw NativeRuntimeError.invocation("The preview display exclusion could not be decoded")
            }
            exclusion = (data, image)
            return image
        }
    }

    private func snapshotRotationDegrees(_ rawValue: String) async throws -> Double {
        let runtime = ABIRuntime.shared
        let type = try await runtime.resolve(.swift(.type("PreviewsMessagingHost.PreviewTraits.Orientation")), in: .framework(named: "PreviewsMessagingHost"))
        let optional = try await runtime.resolve(.swift(.type("Swift.Optional", genericArguments: [.type(type)])))
        let initializer = try await type.resolve(
            .swift(
                .initializer(
                    "init(rawValue: Swift.String) -> Swift.Optional<PreviewsMessagingHost.PreviewTraits.Orientation>", as: ((String) -> NativeSwiftValue).self,
                    valueABIs: [type: .opaque(named: type.name), optional: .opaque(named: optional.name)])))
        let value = try unsafe initializer.unsafeInvoke(rawValue)
        guard let orientation = try await value.copyEnumPayload(forCase: "some") else { throw NativePipelineRequired() }
        let getter = try await type.resolve(.swift(.getter("rotationDegrees", as: (() -> Double).self, receiverABI: .opaque(named: type.name))))
        return try unsafe getter.unsafeInvoke(on: orientation)
    }

    static func thumbnail(from image: CGImage, maximumDimension: CGFloat, framebufferMask: NSImage?,
                          rotationDegrees: Double?, swapsAxes: Bool, exclusionImage: CGImage? = nil) -> CGImage? {
        let source: CGImage
        if let exclusionImage, let rotationDegrees {
            let size = CGSize(width: image.width, height: image.height)
            guard let composite = unsafe CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            composite.draw(image, in: CGRect(origin: .zero, size: size))
            let rotatedSize = swapsAxes ? CGSize(width: size.height, height: size.width) : size
            composite.translateBy(x: size.width / 2, y: size.height / 2)
            composite.rotate(by: -rotationDegrees * .pi / 180)
            composite.draw(exclusionImage, in: CGRect(x: -rotatedSize.width / 2, y: -rotatedSize.height / 2,
                width: rotatedSize.width, height: rotatedSize.height))
            guard let merged = composite.makeImage() else { return nil }
            source = merged
        } else { source = image }
        let scale = min(1, maximumDimension / CGFloat(max(image.width, image.height)))
        let size = CGSize(width: max(1, CGFloat(image.width) * scale), height: max(1, CGFloat(image.height) * scale))
        guard let context = unsafe CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(origin: .zero, size: size))
        if let framebufferMask, let rotationDegrees {
            var proposed = CGRect(origin: .zero, size: size)
            guard let mask = unsafe framebufferMask.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
            let rotatedSize = swapsAxes ? CGSize(width: size.height, height: size.width) : size
            context.saveGState()
            context.setBlendMode(.destinationIn)
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: -rotationDegrees * .pi / 180)
            context.translateBy(x: -rotatedSize.width / 2, y: -rotatedSize.height / 2)
            context.draw(mask, in: CGRect(origin: .zero, size: rotatedSize))
            context.restoreGState()
        }
        return context.makeImage()
    }
}
