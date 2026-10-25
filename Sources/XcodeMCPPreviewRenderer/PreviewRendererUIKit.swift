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
    private var mountedPreview: (request: PreviewRendererRequest,
                                 capture: @MainActor (URL) async throws -> PreviewRendererResult,
                                 close: @MainActor () async throws -> Void)?

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
                    let result = try await render(readPreviewRequest(), in: window, directory: documents)
                    try await closeMountedPreview()
                    write(result)
                }
            }
            catch {
                let original = error
                do { try await closeMountedPreview() }
                catch {
                    write(PreviewRendererResult(error: "\(original); preview UI cleanup also failed: \(error)"))
                    return
                }
                if original is NativePreviewPipelineRequired { write(PreviewRendererResult(requiresNativePipeline: true)) }
                else { write(PreviewRendererResult(error: String(describing: original))) }
            }
        }
    }

    private func render(_ request: PreviewRendererRequest, in window: UIWindow, directory: URL) async throws -> PreviewRendererResult {
        do {
            if let mountedPreview, mountedPreview.request == request {
                return try await mountedPreview.capture(directory)
            }
            try await closeMountedPreview()
            return try await makePreview(request, in: window, directory: directory)
        } catch {
            let original = error
            do { try await closeMountedPreview() }
            catch { throw PreviewRendererError("\(original); preview UI cleanup also failed: \(error)") }
            throw original
        }
    }

    private func closeMountedPreview() async throws {
        guard let mounted = mountedPreview else { return }
        mountedPreview = nil
        try await mounted.close()
    }

    private func makePreview(_ request: PreviewRendererRequest, in window: UIWindow, directory: URL) async throws -> PreviewRendererResult {
        try loadPreviewLibraries(request)
        if request.metadataOnly == true {
            defer {
                window.rootViewController = nil
                window.isHidden = true
            }
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
            let background = try await ABIRuntime.shared.object(UIColor.self as AnyObject).resolve(
                .objc(.method("systemBackgroundColor", as: (() -> UIColor).self)))
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
        let snapshot = try await PreviewSnapshotWindow.open(from: window, size: size)
        let captureWindow = snapshot.window
        let close: @MainActor () async throws -> Void = { try await snapshot.close() }
        let resizeWindow: (@MainActor (CGSize) async throws -> Void)? = { size in try await snapshot.resize(to: size) }
        #else
        let captureWindow = window
        let close: @MainActor () async throws -> Void = {
            window.isHidden = true
            window.rootViewController = nil
        }
        let resizeWindow: (@MainActor (CGSize) async throws -> Void)? = nil
        #endif
        let capture: @MainActor (URL) async throws -> PreviewRendererResult
        do {
            capture = try await mount(in: captureWindow, controller: controller, layout: content.layout,
                                      size: size, result: content.result, resizeWindow: resizeWindow)
        } catch {
            let original = error
            do { try await close() }
            catch { throw PreviewRendererError("\(original); preview UI cleanup also failed: \(error)") }
            throw original
        }
        mountedPreview = (request, capture, close)
        let result = try await capture(directory)
        if request.nativeSource != nil || request.isLegacyComplication == true { try await closeMountedPreview() }
        return result
    }

    private func mount(in window: UIWindow, controller: UIHostingController<AnyView>,
                       layout: DeveloperToolsSupport.PreviewLayout, size initialSize: CGSize,
                       result initialResult: PreviewRendererResult,
                       resizeWindow: (@MainActor (CGSize) async throws -> Void)? = nil) async throws ->
        (@MainActor (URL) async throws -> PreviewRendererResult) {
        window.rootViewController = controller
        window.makeKeyAndVisible()
        #if os(tvOS)
        if case .sizeThatFits = layout {} else { controller.view.frame = CGRect(origin: .zero, size: initialSize) }
        #else
        controller.view.frame = CGRect(origin: .zero, size: initialSize)
        #endif
        controller.view.layoutIfNeeded()
        // Allow appearance tasks to deliver initial updates before sizing and capture.
        try await Task.sleep(for: .milliseconds(500))

        return { directory in
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            var size = initialSize
            switch layout {
            case .device: size = window.bounds.size
            case .sizeThatFits:
                #if os(tvOS)
                size = controller.sizeThatFits(in: window.screen.bounds.size)
                #else
                size = controller.view.intrinsicContentSize
                #endif
            default: break
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
