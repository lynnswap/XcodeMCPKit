#if os(watchOS) && targetEnvironment(simulator)
import CoreGraphics
import Darwin
import DeveloperToolsSupport
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WatchKit
import XcodeMCPWire

@main
@MainActor
enum PreviewRendererWatchMain {
    static let preparation = Task { @MainActor in
        let request = try readPreviewRequest()
        let legacyPreview: SwiftUI._Preview?
        let complication: ClockKitPreview?
        if request.isLegacyComplication == true {
            try loadPreviewLibraries(request)
            legacyPreview = try request.providerTypeName.map { try makeLegacyViewPreview(typeName: $0, index: 0) }
            if let legacyPreview { complication = try await makeClockKitPreview(from: legacyPreview, request: request) }
            else { complication = nil }
        } else {
            legacyPreview = nil
            complication = nil
        }
        return WatchPreviewSource(request: request, legacyPreview: legacyPreview, complication: complication)
    }

    static func main() async {
        do {
            if let directory = try nativePreviewServiceResultDirectory() {
                try await writeNativeWidgetPreviewResult(to: directory)
                return
            }
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Preview result could not be written: \(error)\n".utf8))
            exit(1)
        }
        // ClockKit archives SwiftUI template content before the display scene
        // exists. The UI task consumes this same source and any preparation error.
        _ = await preparation.result
        PreviewRendererWatch.main()
    }
}

@MainActor
struct WatchPreviewSource {
    let request: PreviewRendererRequest
    let legacyPreview: SwiftUI._Preview?
    let complication: ClockKitPreview?
}

struct PreviewRendererWatch: App {
    var body: some Scene {
        WindowGroup {
            Color.clear.task {
                do { try await render() }
                catch is NativePreviewPipelineRequired { write(PreviewRendererResult(requiresNativePipeline: true)) }
                catch { write(PreviewRendererResult(error: String(describing: error))) }
            }
        }
    }

    @MainActor
    private func render() async throws {
        let source = try await PreviewRendererWatchMain.preparation.value
        let request = source.request
        if request.isLegacyComplication != true { try loadPreviewLibraries(request) }
        if request.metadataOnly == true {
            let value = try await nativePreviewMetadata(request)
            write(PreviewRendererResult(nativeMetadata: value.metadata,
                nativeProviderPreviewDescription: value.providerDescription))
            return
        }
        let image: CGImage
        var result: PreviewRendererResult
        if let complication = source.complication {
            let controller = try await makeClockKitPreviewController(complication)
            image = try await captureWatchPreview(controller: controller)
            result = complication.result
        } else {
            let content = try await makeGeneralPreview(request, legacyPreview: source.legacyPreview)
            image = try await captureWatchPreview(view: content.view, layout: content.layout)
            result = content.result
            if case .device = content.layout {
                result.usesDeviceLayout = true
                result.interfaceOrientation = "portrait"
            }
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PreviewRendererError("The preview host could not create a PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PreviewRendererError("The preview host could not encode its snapshot") }
        try (data as Data).write(to: documents.appendingPathComponent("Preview.png"), options: .atomic)
        result.snapshotName = "Preview.png"
        write(result)
    }

    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private func write(_ result: PreviewRendererResult) {
        do { try JSONEncoder().encode(result).write(to: documents.appendingPathComponent("PreviewResult.json"), options: .atomic) }
        catch { print("Preview result could not be written: \(error)") }
    }
}
#endif
