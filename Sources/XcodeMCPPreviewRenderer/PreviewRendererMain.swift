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
        // Preview mode defers SwiftUI graph creation until its code is ready.
        __previewThunksHaveFinishedLoading()
        let widget: WidgetPreview?
        var view: AnyView
        let layout: DeveloperToolsSupport.PreviewLayout
        let displayName: String?
        let sourceLineNumber: Int?
        let groupItems: [String?]?
        var errors: [String] = []
        if let typeName = request.providerTypeName {
            guard request.widgetFamily == nil, request.timelineIndex == nil else { throw NativePreviewPipelineRequired() }
            let preview = try makeLegacyViewPreview(typeName: typeName, index: 0)
            guard preview.context == nil, preview.device == nil, preview.interfaceOrientation == .portrait else {
                throw NativePreviewPipelineRequired()
            }
            widget = nil
            view = preview.content
            if let colorScheme = preview.colorScheme { view = AnyView(view.environment(\.colorScheme, colorScheme)) }
            layout = preview.layout
            displayName = preview.displayName
            sourceLineNumber = request.lineNumber
            groupItems = nil
            if let index = request.groupItemIndex {
                errors.append(unsupportedPreviewGroupItemMessage(index, supportsGroups: false))
            }
        } else {
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
            switch source.type.name {
            case "DeveloperToolsSupport.DefaultPreviewSource<SwiftUI.ViewPreviewBody>",
                 "DeveloperToolsSupport.DefaultPreviewSource<__C.UIView>",
                 "DeveloperToolsSupport.DefaultPreviewSource<__C.UIViewController>":
                guard request.widgetFamily == nil, request.timelineIndex == nil else { throw NativePreviewPipelineRequired() }
                widget = nil
                let result = try await makeViewPreview(source: source, groupItemIndex: request.groupItemIndex)
                view = try await applyPreviewModifiers(result.view, preview: value)
                groupItems = result.groupItems
                errors = result.errors
                layout = try await viewPreviewLayout(value)
            case "WidgetKit.TimelineEntryPreviewSource", "WidgetKit.TimelineProviderPreviewSource":
                guard request.groupItemIndex == nil else { throw NativePreviewPipelineRequired() }
                let result = try await makeWidgetPreview(source: source, family: request.widgetFamily, timelineEntryIndex: request.timelineIndex)
                widget = result
                view = AnyView(result.view.clipShape(RoundedRectangle(cornerRadius: result.cornerRadius, style: .continuous)))
                groupItems = nil
                layout = .fixed(width: result.size.width, height: result.size.height)
            default: throw NativePreviewPipelineRequired()
            }
            let displayGetter = try await value.type.resolveGetter(named: "displayName", as: (() -> String?).self,
                receiverABI: .opaque(named: value.type.name))
            displayName = try unsafe displayGetter.unsafeInvoke(on: value)
            sourceLineNumber = registry.line
        }
        var size = window.bounds.size
        if let localization = request.localization { view = AnyView(view.environment(\.locale, Locale(identifier: localization))) }
        let controller = UIHostingController(rootView: view)
        if widget != nil { controller.view.backgroundColor = .clear }
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
        if widget != nil { format.opaque = false }
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var drawn = false
        let image = renderer.image { _ in
            drawn = controller.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        guard drawn, let data = image.pngData() else { throw PreviewRendererError("The preview host could not capture its rendered view") }
        try widget?.validate()
        try data.write(to: documents.appendingPathComponent("Preview.png"), options: .atomic)
        write(PreviewRendererResult(snapshotName: "Preview.png", displayName: displayName,
            sourceLineNumber: sourceLineNumber, timelineIndexes: widget?.timelineIndexes, widgetFamilies: widget?.supportedFamilies,
            groupItems: groupItems, errors: errors))
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
#elseif !os(macOS) && !os(watchOS) && !os(tvOS) && !os(visionOS) && !targetEnvironment(macCatalyst)
@main
enum PreviewRendererMain {
    static func main() throws {
        throw NSError(domain: "XcodeMCPPreviewRenderer", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "This executable requires an iOS Simulator"])
    }
}
#endif
