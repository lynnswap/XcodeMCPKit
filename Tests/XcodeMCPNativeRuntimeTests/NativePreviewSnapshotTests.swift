import AppKit
import CoreGraphics
import Testing
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewSnapshotTests {
    @Test func thumbnailCapsTheLongestSideWithoutUpscaling() throws {
        let large = try image(width: 2622, height: 1206)
        let thumbnail = try #require(NativePreviewCorrection.thumbnail(from: large, maximumDimension: 1500,
            framebufferMask: nil, rotationDegrees: nil, swapsAxes: false))
        #expect(thumbnail.width == 1500)
        #expect(thumbnail.height == 689)
        let small = try image(width: 180, height: 90)
        let unchanged = try #require(NativePreviewCorrection.thumbnail(from: small, maximumDimension: 1500,
            framebufferMask: nil, rotationDegrees: nil, swapsAxes: false))
        #expect(unchanged.width == 180)
        #expect(unchanged.height == 90)
    }

    @Test func deviceMaskUsesTheContentOrientation() throws {
        let mask = NSImage(size: NSSize(width: 40, height: 80), flipped: false) { _ in
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 40, height: 40)).fill()
            return true
        }
        let source = try image(width: 80, height: 40)
        let left = try #require(NativePreviewCorrection.thumbnail(from: source, maximumDimension: 1500,
            framebufferMask: mask, rotationDegrees: 90, swapsAxes: true))
        let right = try #require(NativePreviewCorrection.thumbnail(from: source, maximumDimension: 1500,
            framebufferMask: mask, rotationDegrees: 270, swapsAxes: true))
        let leftBitmap = NSBitmapImageRep(cgImage: left)
        let rightBitmap = NSBitmapImageRep(cgImage: right)
        #expect(leftBitmap.colorAt(x: 10, y: 20)?.alphaComponent == 1)
        #expect(leftBitmap.colorAt(x: 70, y: 20)?.alphaComponent == 0)
        #expect(rightBitmap.colorAt(x: 10, y: 20)?.alphaComponent == 0)
        #expect(rightBitmap.colorAt(x: 70, y: 20)?.alphaComponent == 1)
    }

    @Test func portraitDeviceMaskClipsCornersAndPreservesContent() throws {
        let mask = NSImage(size: NSSize(width: 80, height: 100), flipped: false) { _ in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 80, height: 100), xRadius: 20, yRadius: 20).fill()
            return true
        }
        let source = try image(width: 80, height: 100)
        let thumbnail = try #require(NativePreviewCorrection.thumbnail(from: source, maximumDimension: 1500,
            framebufferMask: mask, rotationDegrees: 0, swapsAxes: false))
        let bitmap = NSBitmapImageRep(cgImage: thumbnail)
        #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        #expect(bitmap.colorAt(x: 79, y: 99)?.alphaComponent == 0)
        #expect(bitmap.colorAt(x: 40, y: 50)?.alphaComponent == 1)
    }

    @Test func displayExclusionRotatesAndRetainsContentOutsideIt() throws {
        let context = try #require(unsafe CGContext(data: nil, width: 40, height: 80, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 70, width: 20, height: 10))
        let overlay = try #require(context.makeImage())
        let source = try image(width: 80, height: 40)
        let left = try #require(NativePreviewCorrection.thumbnail(from: source, maximumDimension: 1500,
            framebufferMask: nil, rotationDegrees: 90, swapsAxes: true, exclusionImage: overlay))
        let right = try #require(NativePreviewCorrection.thumbnail(from: source, maximumDimension: 1500,
            framebufferMask: nil, rotationDegrees: 270, swapsAxes: true, exclusionImage: overlay))
        let leftBitmap = NSBitmapImageRep(cgImage: left)
        let rightBitmap = NSBitmapImageRep(cgImage: right)
        #expect(leftBitmap.colorAt(x: 75, y: 20)?.redComponent == 0)
        #expect(leftBitmap.colorAt(x: 5, y: 20)?.redComponent == 1)
        #expect(rightBitmap.colorAt(x: 5, y: 20)?.redComponent == 0)
        #expect(rightBitmap.colorAt(x: 75, y: 20)?.redComponent == 1)
        #expect(leftBitmap.colorAt(x: 40, y: 20)?.alphaComponent == 1)
    }

    @Test func thinPreviewRetainsADrawableThumbnail() throws {
        let source = try image(width: 1, height: 6000)
        let thumbnail = try #require(NativePreviewCorrection.thumbnail(from: source, maximumDimension: 1500,
            framebufferMask: nil, rotationDegrees: nil, swapsAxes: false))
        #expect(thumbnail.width == 1)
        #expect(thumbnail.height == 1500)
        #expect(NSBitmapImageRep(cgImage: thumbnail).colorAt(x: 0, y: 750)?.alphaComponent == 1)
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(unsafe CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
