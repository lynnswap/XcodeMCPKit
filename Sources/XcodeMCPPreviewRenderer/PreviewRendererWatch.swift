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
        PreviewRendererWatch.main()
    }
}

@MainActor
struct WatchPreviewSource {
    let request: PreviewRendererRequest
    let complication: ClockKitPreview?
}

struct PreviewRendererWatch: App {
    private let source: Result<WatchPreviewSource, any Error>

    init() {
        // ClockKit's source archive uses the environment before a display scene
        // exists; creating its controller and capturing remain in the UI task.
        source = Result {
            let request = try readPreviewRequest()
            let complication: ClockKitPreview?
            if request.isLegacyComplication == true {
                try loadPreviewLibraries(request)
                complication = try request.providerTypeName.map { typeName in
                    let preview = try makeLegacyViewPreview(typeName: typeName, index: 0)
                    return makeClockKitPreview(from: preview, request: request)
                }
            } else {
                complication = nil
            }
            return WatchPreviewSource(request: request, complication: complication)
        }
    }

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
        let source = try self.source.get()
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
            let content = try await makeGeneralPreview(request)
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
