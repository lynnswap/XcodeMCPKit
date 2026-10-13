import Foundation

#if os(iOS) && targetEnvironment(simulator)
import ABIBridge
import Darwin
import DeveloperToolsSupport
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
        let requestURL = Bundle.main.bundleURL.appendingPathComponent("PreviewRequest.json")
        let request = try JSONDecoder().decode(PreviewRendererRequest.self, from: Data(contentsOf: requestURL))
        guard unsafe setenv("XCODE_RUNNING_FOR_PREVIEWS", "1", 1) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        for name in request.libraryNames {
            let path = Bundle.main.bundleURL.appendingPathComponent(name).path
            // The request owns this process; keep code and Swift metadata loaded
            // until the Simulator app exits.
            guard unsafe dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil else {
                let message = unsafe String(cString: dlerror())
                throw PreviewRendererError("Cannot load \(name): \(message)")
            }
        }
        let registries = request.registryNames.compactMap { _typeByName($0) as? any PreviewRegistry.Type }
            .filter { registry in
                let components = registry.fileID.split(separator: "/")
                return components.last.map(String.init) == request.fileName
                    && (request.moduleName == nil || components.first.map(String.init) == request.moduleName)
                    && (request.lineNumber == nil || registry.line == request.lineNumber)
                    && (request.columnNumber == nil || registry.column == request.columnNumber)
            }
            .sorted { ($0.line, $0.column) < ($1.line, $1.column) }
        let index = request.lineNumber == nil ? request.definitionIndex : 0
        guard registries.indices.contains(index), request.lineNumber == nil || registries.count == 1 else {
            throw NativePreviewPipelineRequired()
        }
        let registry = registries[index]
        let preview = try registry.makePreview()
        try requireSupportedTraits(preview)
        let value = try await ownedPreview(preview)
        let source = try await previewSource(value)
        guard source.type.name == "DeveloperToolsSupport.DefaultPreviewSource<SwiftUI.ViewPreviewBody>" else {
            throw NativePreviewPipelineRequired()
        }
        var view = try await makeViewPreview(source: source)
        // Preview mode defers SwiftUI graph creation until its code is ready.
        __previewThunksHaveFinishedLoading()
        var size = window.bounds.size
        let layout = try await viewPreviewLayout(value)
        if let localization = request.localization { view = AnyView(view.environment(\.locale, Locale(identifier: localization))) }
        let controller = UIHostingController(rootView: view)
        switch layout {
        case .device: break
        case .fixed(let width, let height):
            controller.safeAreaRegions = []
            size = CGSize(width: width, height: height)
        case .sizeThatFits:
            controller.safeAreaRegions = []
            // Intrinsic sizing asks SwiftUI for its ideal size with an unspecified proposal.
            controller.sizingOptions = .intrinsicContentSize
            size = controller.view.intrinsicContentSize
        default: throw NativePreviewPipelineRequired()
        }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw PreviewRendererError("The preview has no drawable area: \(size)")
        }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        if case .sizeThatFits = layout {
            size = controller.view.intrinsicContentSize
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                throw PreviewRendererError("The preview has no drawable area: \(size)")
            }
        }
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var drawn = false
        let image = renderer.image { _ in
            drawn = controller.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        guard drawn, let data = image.pngData() else { throw PreviewRendererError("The preview host could not capture its rendered view") }
        try data.write(to: documents.appendingPathComponent("Preview.png"), options: .atomic)
        let displayGetter = try await value.type.resolveGetter(named: "displayName", as: (() -> String?).self,
            receiverABI: .opaque(named: value.type.name))
        write(PreviewRendererResult(snapshotName: "Preview.png", displayName: try unsafe displayGetter.unsafeInvoke(on: value),
            sourceLineNumber: registry.line))
    }

    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    private func write(_ result: PreviewRendererResult) {
        do {
            try JSONEncoder().encode(result).write(to: documents.appendingPathComponent("PreviewResult.json"), options: .atomic)
        } catch {
            print("Preview result could not be written: \(error)")
        }
    }
}
#else
@main
enum PreviewRendererMain {
    static func main() throws {
        throw NSError(domain: "XcodeMCPPreviewRenderer", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "This executable requires an iOS Simulator"])
    }
}
#endif
