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
        let style: NSWindow.StyleMask = usesDeviceLayout ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: style, backing: .buffered, defer: false)
        if let color = content.variants["Color Scheme"] {
            window.appearance = NSAppearance(named: color == "Dark Appearance" ? .darkAqua : .aqua)
        }
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.title = content.result.displayName ?? "Preview"
        controller.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController = controller
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let snapshotView = unsafe usesDeviceLayout ? (window.contentView?.superview ?? controller.view) : controller.view
        guard let image = snapshotView.bitmapImageRepForCachingDisplay(in: snapshotView.bounds) else {
            throw PreviewRendererError("The preview host could not create a bitmap representation")
        }
        snapshotView.cacheDisplay(in: snapshotView.bounds, to: image)
        guard let png = image.representation(using: .png, properties: [:]) else {
            throw PreviewRendererError("The preview host could not encode its snapshot")
        }
        var result = content.result
        result.snapshotData = png
        return result
    }
}
#endif
