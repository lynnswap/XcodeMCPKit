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
        if let snapshot = PreviewSnapshotWindow.configuration(for: session) { return snapshot }
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
        let activity: ActivityPreview?
        var view: AnyView?
        let layout: DeveloperToolsSupport.PreviewLayout
        let displayName: String?
        let sourceLineNumber: Int?
        let groupItems: [String?]?
        let sourceOrientation: UIInterfaceOrientation
        var variants = request.displayVariantOverrides
        var errors: [String] = []
        if let typeName = request.providerTypeName {
            guard request.widgetFamily == nil, request.timelineIndex == nil,
                  request.activityViewStyle == nil, request.activityViewContext == nil, request.activityToggleState == nil else {
                throw NativePreviewPipelineRequired()
            }
            let preview = try makeLegacyViewPreview(typeName: typeName, index: 0)
            guard preview.context == nil, preview.device == nil else {
                throw NativePreviewPipelineRequired()
            }
            widget = nil
            activity = nil
            view = preview.content
            if variants["Color Scheme"] == nil, let colorScheme = preview.colorScheme {
                variants["Color Scheme"] = colorScheme == .dark ? "Dark Appearance" : "Light Appearance"
            }
            switch preview.interfaceOrientation {
            case .portrait: sourceOrientation = .portrait
            case .portraitUpsideDown: sourceOrientation = .portraitUpsideDown
            case .landscapeLeft: sourceOrientation = .landscapeLeft
            case .landscapeRight: sourceOrientation = .landscapeRight
            default: throw NativePreviewPipelineRequired()
            }
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
                guard request.widgetFamily == nil, request.timelineIndex == nil,
                      request.activityViewStyle == nil, request.activityViewContext == nil, request.activityToggleState == nil else {
                    throw NativePreviewPipelineRequired()
                }
                widget = nil
                activity = nil
                let result = try await makeViewPreview(source: source, groupItemIndex: request.groupItemIndex)
                view = try await applyPreviewModifiers(result.view, preview: value)
                groupItems = result.groupItems
                errors = result.errors
                layout = try await viewPreviewLayout(value)
                sourceOrientation = try await viewPreviewOrientation(value)
            case "WidgetKit.TimelineEntryPreviewSource", "WidgetKit.TimelineProviderPreviewSource":
                guard request.groupItemIndex == nil, request.activityViewStyle == nil,
                      request.activityViewContext == nil, request.activityToggleState == nil,
                      variants.isEmpty else { throw NativePreviewPipelineRequired() }
                let result = try await makeWidgetPreview(source: source, family: request.widgetFamily, timelineEntryIndex: request.timelineIndex)
                widget = result
                activity = nil
                view = AnyView(result.view.clipShape(RoundedRectangle(cornerRadius: result.cornerRadius, style: .continuous)))
                groupItems = nil
                layout = .fixed(width: result.size.width, height: result.size.height)
                sourceOrientation = .portrait
            case "WidgetKit.ActivityPreviewSource":
                guard request.widgetFamily == nil,
                      variants.keys.allSatisfy({ ["Color Scheme", "Dynamic Type"].contains($0) }) else {
                    throw NativePreviewPipelineRequired()
                }
                var environment = EnvironmentValues()
                try await applyActivityDisplayProperties(to: &environment, screen: window.screen)
                try applyDisplayVariants(to: &environment, variants: variants)
                if let localization = request.localization { environment.locale = Locale(identifier: localization) }
                let result = try await makeActivityPreview(source: source, timelineIndex: request.timelineIndex,
                    viewStyle: request.activityViewStyle, isStale: request.activityViewContext == "Stale",
                    addStaleEntries: request.activityToggleState ?? false, environment: environment,
                    appName: request.appName ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "",
                    payloadID: UUID().uuidString)
                widget = nil
                activity = result
                view = nil
                groupItems = nil
                layout = .device
                sourceOrientation = result.interfaceOrientation
                errors = result.errors
                if let index = request.groupItemIndex { errors.append(unsupportedPreviewGroupItemMessage(index, supportsGroups: false)) }
            default: throw NativePreviewPipelineRequired()
            }
            let displayGetter = try await value.type.resolveGetter(named: "displayName", as: (() -> String?).self,
                receiverABI: .opaque(named: value.type.name))
            displayName = try unsafe displayGetter.unsafeInvoke(on: value)
            sourceLineNumber = registry.line
        }
        let orientation = try interfaceOrientation(variant: variants["Orientation"], source: sourceOrientation)

        @MainActor func capture(in window: UIWindow) async throws -> PreviewRendererResult {
            var size = window.bounds.size
            let controller: UIViewController
            let rootController: UIViewController
            if let activity {
                controller = activity.controller
                rootController = ActivityOrientationController(content: controller)
            } else {
                guard var view else { throw NativePreviewPipelineRequired() }
                if let localization = request.localization { view = AnyView(view.environment(\.locale, Locale(identifier: localization))) }
                view = try applyDisplayVariants(to: view, variants: variants)
                let hosting = UIHostingController(rootView: view)
                applyDisplayVariants(to: hosting, variants: variants)
                if widget != nil { hosting.view.backgroundColor = .clear }
                switch layout {
                case .device: break
                case .fixed(let width, let height):
                    hosting.safeAreaRegions = []
                    size = CGSize(width: width, height: height)
                case .sizeThatFits:
                    hosting.safeAreaRegions = []
                    // Intrinsic sizing asks SwiftUI for its ideal size with an unspecified proposal.
                    hosting.sizingOptions = .intrinsicContentSize
                    size = hosting.view.intrinsicContentSize
                default: throw NativePreviewPipelineRequired()
                }
                controller = hosting
                if orientation == .portrait { rootController = hosting }
                else { rootController = try await makeCounterRotationController(content: hosting, orientation: orientation) }
            }
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                throw PreviewRendererError("The preview has no drawable area: \(size)")
            }
            window.rootViewController = rootController
            window.makeKeyAndVisible()
            if activity != nil, orientation != .portrait {
                guard let scene = window.windowScene else { throw NativePreviewPipelineRequired() }
                try await requestActivityPreviewOrientation(orientation, in: scene)
            }
            if activity != nil {
                window.layoutIfNeeded()
                controller.view.layoutIfNeeded()
            }
            if case .device = layout { size = window.bounds.size }
            let layoutController = activity == nil ? rootController : controller
            layoutController.view.frame = CGRect(origin: .zero, size: size)
            layoutController.view.setNeedsLayout()
            layoutController.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            if let activity {
                size = activity.preferredContentSize
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                    throw PreviewRendererError("The preview has no drawable area: \(size)")
                }
            } else if case .sizeThatFits = layout {
                size = controller.view.intrinsicContentSize
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                    throw PreviewRendererError("The preview has no drawable area: \(size)")
                }
            }
            layoutController.view.frame = CGRect(origin: .zero, size: size)
            layoutController.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = window.screen.scale
            if widget != nil || activity != nil { format.opaque = false }
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            var drawn = false
            let image = renderer.image { _ in
                drawn = controller.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            guard drawn, let data = image.pngData() else { throw PreviewRendererError("The preview host could not capture its rendered view") }
            try widget?.validate()
            try data.write(to: documents.appendingPathComponent("Preview.png"), options: .atomic)
            let deviceLayout: Bool
            if case .device = layout { deviceLayout = activity == nil } else { deviceLayout = false }
            var exclusionSnapshotName: String?
            if deviceLayout, let exclusion = try await previewExclusionImage(in: window) {
                guard let exclusionData = exclusion.pngData() else {
                    throw PreviewRendererError("The preview display exclusion could not be encoded")
                }
                exclusionSnapshotName = "PreviewExclusion.png"
                try exclusionData.write(to: documents.appendingPathComponent("PreviewExclusion.png"), options: .atomic)
            }
            return PreviewRendererResult(snapshotName: "Preview.png", displayName: displayName,
                sourceLineNumber: sourceLineNumber, timelineIndexes: widget?.timelineIndexes ?? activity?.stateIndexes,
                widgetFamilies: widget?.supportedFamilies, groupItems: groupItems, errors: errors,
                toggleStates: activity == nil ? nil : [true, false],
                activityViewStyles: activity == nil ? nil : PreviewRendererRequest.activityViewStyles,
                activityViewContexts: activity == nil ? nil : PreviewRendererRequest.activityViewContexts,
                supportedDisplayVariants: widget == nil && activity == nil ? PreviewRendererRequest.displayVariantValues : nil,
                usesDeviceLayout: deviceLayout, interfaceOrientation: try interfaceOrientationName(orientation),
                exclusionSnapshotName: exclusionSnapshotName)
        }

        let result: PreviewRendererResult
        if widget == nil && activity == nil {
            result = try await PreviewSnapshotWindow.withWindow(from: window, orientation: orientation, perform: capture)
        } else {
            result = try await capture(in: window)
        }
        write(result)
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
