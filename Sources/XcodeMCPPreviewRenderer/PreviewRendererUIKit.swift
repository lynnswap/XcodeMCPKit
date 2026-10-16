#if (os(iOS) && targetEnvironment(macCatalyst)) || ((os(tvOS) || os(visionOS)) && targetEnvironment(simulator))
import ABIBridge
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
        #if os(tvOS)
        if let snapshot = PreviewSnapshotWindow.configuration(for: session) { return snapshot }
        #endif
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
            do {
                if let directory = try previewRendererSessionDirectory() {
                    try await runPreviewRendererSession(in: directory) { request, output in
                        try await self.render(request, in: window, directory: output)
                    }
                } else {
                    write(try await render(readPreviewRequest(), in: window, directory: documents))
                }
            }
            catch is NativePreviewPipelineRequired { write(PreviewRendererResult(requiresNativePipeline: true)) }
            catch { write(PreviewRendererResult(error: String(describing: error))) }
        }
    }

    private func render(_ request: PreviewRendererRequest, in window: UIWindow, directory: URL) async throws -> PreviewRendererResult {
        defer {
            window.rootViewController = nil
            window.isHidden = true
        }
        try loadPreviewLibraries(request)
        if request.metadataOnly == true {
            let value = try await nativePreviewMetadata(request)
            return PreviewRendererResult(nativeMetadata: value.metadata,
                nativeProviderPreviewDescription: value.providerDescription)
        }
        let content = try await makeGeneralPreview(request)
        let controller = UIHostingController(rootView: content.view)
        applyDisplayVariants(to: controller, variants: content.variants)
        #if os(tvOS)
        do {
            // Native IOSHostingParadigm sets this color on TV; its Swift API is unavailable there.
            let background = try await ABIRuntime.shared.object(UIColor.self as AnyObject).resolveMethod(
                selector: "systemBackgroundColor", as: (() -> UIColor).self)
            controller.view.backgroundColor = try unsafe background.unsafeInvoke()
        } catch is ABIResolutionError { throw NativePreviewPipelineRequired() }
        #endif
        var size = window.bounds.size
        #if os(tvOS)
        size = window.screen.bounds.size
        #endif
        switch content.layout {
        case .device: break
        case .fixed(let width, let height):
            #if !os(tvOS)
            controller.safeAreaRegions = []
            #endif
            size = CGSize(width: width, height: height)
        case .sizeThatFits:
            #if !os(tvOS)
            controller.safeAreaRegions = []
            controller.sizingOptions = .intrinsicContentSize
            size = controller.view.intrinsicContentSize
            #endif
        default: throw NativePreviewPipelineRequired()
        }
        #if os(tvOS)
        let result = try await PreviewSnapshotWindow.withWindow(from: window, size: size) { snapshot in
            try await capture(in: snapshot.window, controller: controller, layout: content.layout,
                              size: size, result: content.result, directory: directory,
                              resizeWindow: { size in try await snapshot.resize(to: size) })
        }
        #else
        let result = try await capture(in: window, controller: controller, layout: content.layout,
                                       size: size, result: content.result, directory: directory)
        #endif
        return result
    }

    private func capture(in window: UIWindow, controller: UIHostingController<AnyView>,
                         layout: DeveloperToolsSupport.PreviewLayout, size initialSize: CGSize,
                         result initialResult: PreviewRendererResult,
                         directory: URL,
                         resizeWindow: ((CGSize) async throws -> Void)? = nil) async throws -> PreviewRendererResult {
        var size = initialSize
        window.rootViewController = controller
        window.makeKeyAndVisible()
        #if os(tvOS)
        if case .sizeThatFits = layout {} else { controller.view.frame = CGRect(origin: .zero, size: size) }
        #else
        controller.view.frame = CGRect(origin: .zero, size: size)
        #endif
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        if case .sizeThatFits = layout {
            #if os(tvOS)
            size = controller.sizeThatFits(in: window.screen.bounds.size)
            #else
            size = controller.view.intrinsicContentSize
            #endif
        }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw PreviewRendererError("The preview has no drawable area: \(size)")
        }
        if case .sizeThatFits = layout { try await resizeWindow?(size) }
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()
        #if os(tvOS)
        let data = try staticPreviewSnapshot(of: controller.view, size: size, scale: window.traitCollection.displayScale)
        #else
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        #if targetEnvironment(macCatalyst)
        format.preferredRange = .standard
        #endif
        var drawn = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            drawn = controller.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        guard drawn, let data = image.pngData() else { throw PreviewRendererError("The preview host could not capture its rendered view") }
        #endif
        var result = initialResult
        #if targetEnvironment(macCatalyst)
        result.snapshotData = data
        #else
        try data.write(to: directory.appendingPathComponent("Preview.png"), options: .atomic)
        result.snapshotName = "Preview.png"
        #endif
        return result
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
