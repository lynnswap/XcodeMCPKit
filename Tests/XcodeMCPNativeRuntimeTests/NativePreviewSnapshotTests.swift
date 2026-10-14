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

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(unsafe CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
