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
    private enum Source {
        case session(URL)
        case oneShot(WatchPreviewSource)
    }

    private let source: Result<Source, any Error>

    init() {
        // ClockKit's source archive uses the environment before a display scene
        // exists; creating its controller and capturing remain in the UI task.
        source = Result {
            if let directory = try previewRendererSessionDirectory() { return .session(directory) }
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
            return .oneShot(WatchPreviewSource(request: request, complication: complication))
        }
    }

    var body: some Scene {
        WindowGroup {
            Color.clear.task {
                do {
                    switch try source.get() {
                    case .session(let directory):
                        try await runPreviewRendererSession(in: directory) { request, output in
                            // ClockKit archives need the pre-scene environment from the one-shot entry point.
                            guard request.isLegacyComplication != true else { throw NativePreviewPipelineRequired() }
                            return try await render(WatchPreviewSource(request: request, complication: nil), directory: output)
                        }
                    case .oneShot(let source):
                        write(try await render(source, directory: documents))
                    }
                }
                catch is NativePreviewPipelineRequired { write(PreviewRendererResult(requiresNativePipeline: true)) }
                catch { write(PreviewRendererResult(error: String(describing: error))) }
            }
        }
    }

    @MainActor
    private func render(_ source: WatchPreviewSource, directory: URL) async throws -> PreviewRendererResult {
        let request = source.request
        if request.isLegacyComplication != true { try loadPreviewLibraries(request) }
        if request.metadataOnly == true {
            let value = try await nativePreviewMetadata(request)
            return PreviewRendererResult(nativeMetadata: value.metadata,
                nativeProviderPreviewDescription: value.providerDescription)
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
        try (data as Data).write(to: directory.appendingPathComponent("Preview.png"), options: .atomic)
        result.snapshotName = "Preview.png"
        return result
    }

    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private func write(_ result: PreviewRendererResult) {
        do { try JSONEncoder().encode(result).write(to: documents.appendingPathComponent("PreviewResult.json"), options: .atomic) }
        catch { print("Preview result could not be written: \(error)") }
    }
}
#endif
