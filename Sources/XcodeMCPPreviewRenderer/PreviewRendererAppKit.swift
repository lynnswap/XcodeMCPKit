#if os(macOS)
import AppKit
import DeveloperToolsSupport
import Foundation
import SwiftUI
import XcodeMCPWire

@main
@MainActor
struct PreviewRendererAppKit {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { writeDesktopPreviewResult(try await render()) }
            catch is NativePreviewPipelineRequired { writeDesktopPreviewResult(PreviewRendererResult(requiresNativePipeline: true)) }
            catch { writeDesktopPreviewResult(PreviewRendererResult(error: String(describing: error))) }
        }
        application.run()
    }

    private static func render() async throws -> PreviewRendererResult {
        let request = try loadPreviewRequest()
        let content = try await makeGeneralPreview(request)
        let controller = NSHostingController(rootView: content.view)
        var size: CGSize
        switch content.layout {
        case .device, .sizeThatFits:
            size = controller.view.fittingSize
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
        defer { window.close() }
        window.title = content.result.displayName ?? "Preview"
        controller.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController = controller
        window.setContentSize(size)
        window.makeKey()
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        switch content.layout {
        case .device, .sizeThatFits: window.setContentSize(controller.view.fittingSize)
        default: break
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
}
#endif
