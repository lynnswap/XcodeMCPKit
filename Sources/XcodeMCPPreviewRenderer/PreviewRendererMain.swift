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
enum PreviewRendererMain {
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
        let status = unsafe UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv,
            nil, NSStringFromClass(PreviewRendererApp.self))
        exit(status)
    }
}

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
            let preview = try makeLegacyViewPreview(typeName: typeName, index: 0)
            if variants["Color Scheme"] == nil, let colorScheme = preview.colorScheme {
                variants["Color Scheme"] = colorScheme == .dark ? "Dark Appearance" : "Light Appearance"
            }
            if let context = preview.context, try await legacyPreviewContextCategory(context) != nil {
                guard request.widgetFamily == nil, request.widgetPresentation == nil,
                      request.activityViewStyle.map({ PreviewRendererRequest.activityViewStyles.contains($0) }) ?? true,
                      request.activityViewContext.map({ PreviewRendererRequest.activityViewContexts.contains($0) }) ?? true,
                      variants.keys.allSatisfy({ ["Color Scheme", "Dynamic Type"].contains($0) }) else {
                    throw NativePreviewPipelineRequired()
                }
                var environment = EnvironmentValues()
                try await applyWidgetDisplayProperties(to: &environment, screen: window.screen)
                try applyDisplayVariants(to: &environment, variants: variants)
                if let localization = request.localization { environment.locale = Locale(identifier: localization) }
                let result = try await makeLegacyActivityPreview(context: context,
                    programRootNames: request.programRootNames ?? [], timelineIndex: request.timelineIndex,
                    viewStyle: request.activityViewStyle, viewContext: request.activityViewContext,
                    environment: environment,
                    appName: request.appName ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "",
                    payloadID: UUID().uuidString)
                widget = nil
                activity = result
                view = nil
                layout = .device
                sourceOrientation = result.interfaceOrientation
                errors = result.errors
            } else {
                widget = nil
                activity = nil
                view = preview.content
                let options = request.generalPreviewOptions(supportedVariants: supportedPreviewDisplayVariants)
                variants = options.displayVariants
                if variants["Color Scheme"] == nil, let colorScheme = preview.colorScheme {
                    variants["Color Scheme"] = colorScheme == .dark ? "Dark Appearance" : "Light Appearance"
                }
                errors = options.errors
                switch preview.interfaceOrientation {
                case .portrait: sourceOrientation = .portrait
                case .portraitUpsideDown: sourceOrientation = .portraitUpsideDown
                case .landscapeLeft: sourceOrientation = .landscapeLeft
                case .landscapeRight: sourceOrientation = .landscapeRight
                default: throw NativePreviewPipelineRequired()
                }
                layout = preview.layout
            }
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
                widget = nil
                activity = nil
                let result = try await makeViewPreview(source: source, groupItemIndex: request.groupItemIndex)
                view = try await applyViewPreviewTraits(result.view, preview: value)
                groupItems = result.groupItems
                let options = request.generalPreviewOptions(supportedVariants: supportedPreviewDisplayVariants)
                variants = options.displayVariants
                errors = result.errors + options.errors
                layout = try await viewPreviewLayout(value)
                sourceOrientation = try await viewPreviewOrientation(value)
            case "WidgetKit.TimelineEntryPreviewSource", "WidgetKit.TimelineProviderPreviewSource":
                guard request.groupItemIndex == nil, request.activityViewStyle == nil,
                      request.activityViewContext == nil, request.activityToggleState == nil,
                      variants.keys.allSatisfy({ ["Color Scheme", "Dynamic Type"].contains($0) }) else {
                    throw NativePreviewPipelineRequired()
                }
                let result = try await makeWidgetPreview(source: source, family: request.widgetFamily,
                    presentation: request.widgetPresentation, timelineEntryIndex: request.timelineIndex,
                    variants: variants, localization: request.localization, screen: window.screen)
                widget = result
                activity = nil
                view = AnyView(result.view.clipShape(RoundedRectangle(cornerRadius: result.cornerRadius, style: .continuous)))
                groupItems = nil
                layout = .fixed(width: result.size.width, height: result.size.height)
                sourceOrientation = .portrait
            case "WidgetKit.ActivityPreviewSource":
                guard request.widgetFamily == nil, request.widgetPresentation == nil,
                      request.activityViewStyle.map({ PreviewRendererRequest.activityViewStyles.contains($0) }) ?? true,
                      request.activityViewContext.map({ PreviewRendererRequest.activityViewContexts.contains($0) }) ?? true,
                      variants.keys.allSatisfy({ ["Color Scheme", "Dynamic Type"].contains($0) }) else {
                    throw NativePreviewPipelineRequired()
                }
                var environment = EnvironmentValues()
                try await applyWidgetDisplayProperties(to: &environment, screen: window.screen)
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

        @MainActor func mount(in window: UIWindow) async throws -> (@MainActor (URL) async throws -> PreviewRendererResult) {
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
            if activity != nil {
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
            // Allow appearance tasks to deliver initial updates before sizing and capture.
            try await Task.sleep(for: .milliseconds(500))

            let mountedSize = size
            var cachedExclusion: (geometry: PreviewExclusionGeometry, data: Data)?
            return { directory in
                window.layoutIfNeeded()
                controller.view.layoutIfNeeded()
                var size = mountedSize
                if let activity {
                    size = activity.preferredContentSize
                } else {
                    switch layout {
                    case .device: size = window.bounds.size
                    case .sizeThatFits: size = controller.view.intrinsicContentSize
                    default: break
                    }
                }
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                    throw PreviewRendererError("The preview has no drawable area: \(size)")
                }
                layoutController.view.frame = CGRect(origin: .zero, size: size)
                layoutController.view.layoutIfNeeded()
                let data = try staticPreviewSnapshot(of: controller.view, size: size, scale: window.screen.scale)
                try widget?.validate()
                try data.write(to: directory.appendingPathComponent("Preview.png"), options: .atomic)
                let deviceLayout: Bool
                if case .device = layout { deviceLayout = activity == nil } else { deviceLayout = false }
                var exclusionSnapshotName: String?
                if deviceLayout, let geometry = try await previewExclusionGeometry(in: window) {
                    let exclusionData: Data
                    if let cachedExclusion, cachedExclusion.geometry == geometry { exclusionData = cachedExclusion.data }
                    else {
                        exclusionData = try geometry.pngData(in: window)
                        cachedExclusion = (geometry, exclusionData)
                    }
                    exclusionSnapshotName = "PreviewExclusion.png"
                    try exclusionData.write(to: directory.appendingPathComponent("PreviewExclusion.png"), options: .atomic)
                } else { cachedExclusion = nil }
                return PreviewRendererResult(snapshotName: "Preview.png", displayName: displayName,
                    sourceLineNumber: sourceLineNumber, timelineIndexes: widget?.timelineIndexes ?? activity?.stateIndexes,
                    groupItems: groupItems, errors: errors,
                    toggleStates: activity == nil ? nil : [true, false],
                    activityViewStyles: activity == nil ? nil : PreviewRendererRequest.activityViewStyles,
                    activityViewContexts: activity == nil ? nil : PreviewRendererRequest.activityViewContexts,
                    supportedDisplayVariants: widget?.supportedVariants ?? (activity == nil ? PreviewRendererRequest.displayVariantValues : nil),
                    usesDeviceLayout: deviceLayout, interfaceOrientation: try interfaceOrientationName(orientation),
                    exclusionSnapshotName: exclusionSnapshotName)
            }
        }

        if widget == nil && activity == nil {
            defer {
                window.rootViewController = nil
                window.isHidden = true
            }
            let snapshot = try await PreviewSnapshotWindow.open(from: window, orientation: orientation)
            let capture: @MainActor (URL) async throws -> PreviewRendererResult
            do { capture = try await mount(in: snapshot.window) }
            catch {
                let original = error
                do { try await snapshot.close() }
                catch { throw PreviewRendererError("\(original); snapshot scene cleanup also failed: \(error)") }
                throw original
            }
            mountedPreview = (request, capture, { try await snapshot.close() })
            let result = try await capture(directory)
            if request.nativeSource != nil || request.isLegacyComplication == true { try await closeMountedPreview() }
            return result
        }
        let close: @MainActor () async throws -> Void = {
            window.rootViewController = nil
            window.isHidden = true
        }
        let capture: @MainActor (URL) async throws -> PreviewRendererResult
        do { capture = try await mount(in: window) }
        catch {
            let original = error
            do { try await close() }
            catch { throw PreviewRendererError("\(original); preview window cleanup also failed: \(error)") }
            throw original
        }
        mountedPreview = (request, capture, close)
        let result = try await capture(directory)
        if request.nativeSource != nil || request.isLegacyComplication == true { try await closeMountedPreview() }
        return result
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
