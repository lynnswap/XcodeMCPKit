#if (os(iOS) && targetEnvironment(macCatalyst)) || ((os(tvOS) || os(visionOS)) && targetEnvironment(simulator))
import DeveloperToolsSupport
import Foundation
import SwiftUI
import UIKit
import XcodeMCPWire

@main
@MainActor
final class PreviewRendererApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool { true }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Preview", sessionRole: session.role)
        configuration.delegateClass = PreviewRendererScene.self
        return configuration
    }
}

@MainActor
final class PreviewRendererScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        self.window = window
        Task { @MainActor in
            do { try await render(in: window) }
            catch is NativePreviewPipelineRequired { write(PreviewRendererResult(requiresNativePipeline: true)) }
            catch { write(PreviewRendererResult(error: String(describing: error))) }
        }
    }

    private func render(in window: UIWindow) async throws {
        let content = try await makeGeneralPreview(loadPreviewRequest())
        let controller = UIHostingController(rootView: content.view)
        var size = window.bounds.size
        switch content.layout {
        case .device: break
        case .fixed(let width, let height):
            controller.safeAreaRegions = []
            size = CGSize(width: width, height: height)
        case .sizeThatFits:
            controller.safeAreaRegions = []
            controller.sizingOptions = .intrinsicContentSize
            size = controller.view.intrinsicContentSize
        default: throw NativePreviewPipelineRequired()
        }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        if case .sizeThatFits = content.layout { size = controller.view.intrinsicContentSize }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw PreviewRendererError("The preview has no drawable area: \(size)")
        }
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        var drawn = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            drawn = controller.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        guard drawn, let data = image.pngData() else { throw PreviewRendererError("The preview host could not capture its rendered view") }
        var result = content.result
        #if targetEnvironment(macCatalyst)
        result.snapshotData = data
        #else
        try data.write(to: documents.appendingPathComponent("Preview.png"), options: .atomic)
        result.snapshotName = "Preview.png"
        #endif
        write(result)
    }

    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    private func write(_ result: PreviewRendererResult) {
        #if targetEnvironment(macCatalyst)
        writeDesktopPreviewResult(result)
        #else
        do { try JSONEncoder().encode(result).write(to: documents.appendingPathComponent("PreviewResult.json"), options: .atomic) }
        catch { print("Preview result could not be written: \(error)") }
        #endif
    }
}
#endif
