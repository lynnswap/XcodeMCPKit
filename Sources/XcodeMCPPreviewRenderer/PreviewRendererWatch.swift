#if os(watchOS) && targetEnvironment(simulator)
import CoreGraphics
import DeveloperToolsSupport
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WatchKit
import XcodeMCPWire

@main
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
        let request = try loadPreviewRequest()
        if request.metadataOnly == true {
            let value = try await nativePreviewMetadata(request)
            write(PreviewRendererResult(nativeMetadata: value.metadata,
                nativeProviderPreviewDescription: value.providerDescription))
            return
        }
        let legacyPreview = try request.providerTypeName.map { try makeLegacyViewPreview(typeName: $0, index: 0) }
        let image: CGImage
        var result: PreviewRendererResult
        if let legacyPreview, let complication = try await makeClockKitPreview(from: legacyPreview, request: request) {
            image = try await captureWatchPreview(controller: complication.controller)
            result = complication.result
        } else {
            let content = try await makeGeneralPreview(request, legacyPreview: legacyPreview)
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
