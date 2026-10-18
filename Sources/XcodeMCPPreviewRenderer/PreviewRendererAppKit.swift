#if os(macOS)
import AppKit
import DeveloperToolsSupport
import Foundation
import SwiftUI
import XcodeMCPWire

@main
@MainActor
struct PreviewRendererAppKit {
    private static var mountedPreview: (request: PreviewRendererRequest, window: NSWindow,
        capture: @MainActor () async throws -> PreviewRendererResult)?

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                if let directory = try previewRendererSessionDirectory() {
                    try await runPreviewRendererSession(in: directory) { request, _ in
                        try await render(request)
                    }
                } else {
                    writeDesktopPreviewResult(try await render(readPreviewRequest()))
                }
            }
            catch is NativePreviewPipelineRequired { writeDesktopPreviewResult(PreviewRendererResult(requiresNativePipeline: true)) }
            catch { writeDesktopPreviewResult(PreviewRendererResult(error: String(describing: error))) }
        }
        application.run()
    }

    private static func render(_ request: PreviewRendererRequest) async throws -> PreviewRendererResult {
        do {
            if let mountedPreview, mountedPreview.request == request { return try await mountedPreview.capture() }
            closeMountedPreview()
            return try await makePreview(request)
        } catch {
            closeMountedPreview()
            throw error
        }
    }

    private static func closeMountedPreview() {
        let mounted = mountedPreview
        mountedPreview = nil
        mounted?.window.close()
    }

    private static func makePreview(_ request: PreviewRendererRequest) async throws -> PreviewRendererResult {
        try loadPreviewLibraries(request)
        if request.metadataOnly == true {
            let value = try await nativePreviewMetadata(request)
            return PreviewRendererResult(nativeMetadata: value.metadata,
                nativeProviderPreviewDescription: value.providerDescription)
        }
        let content = try await makeGeneralPreview(request)
        let controller = NSHostingController(rootView: content.view)
        let proposal = CGSize(width: 600, height: 400)
        let size: CGSize
        switch content.layout {
        case .device:
            size = proposal
        case .sizeThatFits:
            size = controller.sizeThatFits(in: proposal)
        case .fixed(let width, let height):
            size = CGSize(width: width, height: height)
        default: throw NativePreviewPipelineRequired()
        }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw PreviewRendererError("The preview has no drawable area: \(size)")
        }
        let usesDeviceLayout: Bool
        if case .device = content.layout { usesDeviceLayout = true }
        else { usesDeviceLayout = false }
        let window = try makeAppKitPreviewWindow(size: size, usesDeviceLayout: usesDeviceLayout)
        if let color = content.variants["Color Scheme"] {
            window.appearance = NSAppearance(named: color == "Dark Appearance" ? .darkAqua : .aqua)
        }
        window.isReleasedWhenClosed = false
        do {
            window.title = content.result.displayName ?? "Preview"
            controller.view.frame = NSRect(origin: .zero, size: size)
            window.contentViewController = controller
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let capture: @MainActor () async throws -> PreviewRendererResult = {
                if case .sizeThatFits = content.layout {
                    let size = controller.sizeThatFits(in: proposal)
                    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                        throw PreviewRendererError("The preview has no drawable area: \(size)")
                    }
                    controller.view.frame = NSRect(origin: .zero, size: size)
                    window.setContentSize(size)
                }
                window.layoutIfNeeded()
                controller.view.layoutSubtreeIfNeeded()
                let image = try await captureAppKitPreview(window: window)
                guard let png = image.representation(using: .png, properties: [:]) else {
                    throw PreviewRendererError("The preview host could not encode its snapshot")
                }
                var result = content.result
                result.snapshotData = png
                return result
            }
            let result = try await capture()
            mountedPreview = (request, window, capture)
            return result
        } catch {
            window.close()
            throw error
        }
    }
}
#endif
