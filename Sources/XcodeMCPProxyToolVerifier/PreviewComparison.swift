import CoreGraphics
import Foundation
import ImageIO
import XcodeMCPKit

struct PreviewMetadataComparison: Codable {
    let native: MCPJSONValue?
    let headless: MCPJSONValue?
    var matches: Bool { native == headless }
}

struct PreviewImageComparison: Codable {
    let nativeSize: [Int]
    let headlessSize: [Int]
    let differentPixels: Int?
    let exactPixels: Bool
}

struct PreviewComparison: Codable {
    let nativeDirectory: String
    let headlessDirectory: String
    var unavailableReasons: [String] = []
    var metadata: [String: PreviewMetadataComparison] = [:]
    var image: PreviewImageComparison?
    var inputsMatch = false
    var passed = false

    static func compare(native: URL, headless: URL) throws -> Self {
        var result = Self(nativeDirectory: native.path, headlessDirectory: headless.path)
        let nativeCapture: PreviewCaptureReport
        let headlessCapture: PreviewCaptureReport
        do {
            nativeCapture = try JSONDecoder().decode(PreviewCaptureReport.self, from: Data(contentsOf: native.appendingPathComponent("capture.json")))
            headlessCapture = try JSONDecoder().decode(PreviewCaptureReport.self, from: Data(contentsOf: headless.appendingPathComponent("capture.json")))
        } catch {
            result.unavailableReasons.append("Cannot load both captures: \(errorDescription(error))")
            return result
        }
        if nativeCapture.backend != .native || headlessCapture.backend != .headless {
            result.unavailableReasons.append("The inputs must contain a native capture and a headless capture")
        }
        if !nativeCapture.passed { result.unavailableReasons.append("Native capture did not succeed, including cleanup") }
        if !headlessCapture.passed { result.unavailableReasons.append("Headless capture did not succeed, including cleanup") }
        result.inputsMatch = nativeCapture.fixture == headlessCapture.fixture
            && nativeCapture.preview == headlessCapture.preview
            && nativeCapture.inputFiles == headlessCapture.inputFiles
            && nativeCapture.xcodeVersion != nil && nativeCapture.xcodeVersion == headlessCapture.xcodeVersion
            && nativeCapture.requestedDestination == headlessCapture.requestedDestination
        if !result.inputsMatch { result.unavailableReasons.append("Case, source/project inputs, Xcode build, or requested destination differ") }
        guard result.unavailableReasons.isEmpty else { return result }
        guard let nativeMetadata = nativeCapture.metadata?.objectValue,
              let headlessMetadata = headlessCapture.metadata?.objectValue,
              let nativeSnapshot = nativeCapture.snapshot, let headlessSnapshot = headlessCapture.snapshot else {
            result.unavailableReasons.append("Both captures need metadata and a snapshot")
            return result
        }
        for key in ["displayName", "sourceLineNumber", "errors", "supportedLocalizations",
                    "supportedPreviewVariantOverrides", "supportedCanvasControlOverrides", "renderedDestination"] {
            result.metadata[key] = PreviewMetadataComparison(native: nativeMetadata[key], headless: headlessMetadata[key])
        }
        do {
            result.image = try comparePreviewImages(native.appendingPathComponent(nativeSnapshot), headless.appendingPathComponent(headlessSnapshot))
        } catch { result.unavailableReasons.append("Cannot compare snapshots: \(errorDescription(error))") }
        result.passed = result.unavailableReasons.isEmpty && result.metadata.values.allSatisfy(\.matches) && result.image?.exactPixels == true
        return result
    }
}

func comparePreviewImages(_ native: URL, _ headless: URL) throws -> PreviewImageComparison {
    let lhs = try previewPixels(native)
    let rhs = try previewPixels(headless)
    let sameSize = lhs.width == rhs.width && lhs.height == rhs.height
    var differentPixels: Int?
    if sameSize {
        differentPixels = stride(from: 0, to: lhs.data.count, by: 4).reduce(into: 0) { count, offset in
            if lhs.data[offset..<(offset + 4)] != rhs.data[offset..<(offset + 4)] { count += 1 }
        }
    }
    return PreviewImageComparison(nativeSize: [lhs.width, lhs.height], headlessSize: [rhs.width, rhs.height],
        differentPixels: differentPixels, exactPixels: sameSize && differentPixels == 0)
}

private func previewPixels(_ file: URL) throws -> (width: Int, height: Int, data: Data) {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = unsafe CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
              bytesPerRow: image.width * 4, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw VerifierFailure("Cannot decode PNG pixels: \(file.path)")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let bytes = unsafe context.data else { throw VerifierFailure("Cannot read snapshot pixels: \(file.path)") }
    return (image.width, image.height, unsafe Data(bytes: bytes, count: context.bytesPerRow * image.height))
}
