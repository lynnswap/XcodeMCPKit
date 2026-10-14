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
        if request.nativeSource != nil {
            var result = try await renderNativeWidgetPreview(request)
            if let data = result.snapshotData {
                try data.write(to: documents.appendingPathComponent("Preview.png"), options: .atomic)
                result.snapshotName = "Preview.png"
                result.snapshotData = nil
            }
            write(result)
            return
        }
        if request.metadataOnly == true {
            let value = try await nativePreviewMetadata(request)
            write(PreviewRendererResult(nativeMetadata: value.metadata,
                nativeProviderPreviewDescription: value.providerDescription))
            return
        }
        let content = try await makeGeneralPreview(request)
        let image = try await captureWatchPreview(view: content.view, layout: content.layout)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PreviewRendererError("The preview host could not create a PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PreviewRendererError("The preview host could not encode its snapshot") }
        try (data as Data).write(to: documents.appendingPathComponent("Preview.png"), options: .atomic)
        var result = content.result
        result.snapshotName = "Preview.png"
        if case .device = content.layout {
            result.usesDeviceLayout = true
            result.interfaceOrientation = "portrait"
        }
        write(result)
    }

    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private func write(_ result: PreviewRendererResult) {
        do { try JSONEncoder().encode(result).write(to: documents.appendingPathComponent("PreviewResult.json"), options: .atomic) }
        catch { print("Preview result could not be written: \(error)") }
    }
}
#endif
