#if os(iOS) || os(tvOS) || os(visionOS) || os(macOS) || os(watchOS)
import ABIBridge
import Darwin
import DeveloperToolsSupport
import Foundation
import SwiftUI
import XcodeMCPWire

@MainActor
func loadPreviewRequest() throws -> PreviewRendererRequest {
    let request = try readPreviewRequest()
    try loadPreviewLibraries(request)
    return request
}

@MainActor
func readPreviewRequest() throws -> PreviewRendererRequest {
    let url: URL
    if let index = CommandLine.arguments.firstIndex(of: "--preview-request-file") {
        guard CommandLine.arguments.indices.contains(index + 1) else {
            throw PreviewRendererError("The preview renderer requires a request file")
        }
        url = URL(filePath: CommandLine.arguments[index + 1])
    } else {
        url = Bundle.main.resourceURL!.appendingPathComponent("PreviewRequest.json")
    }
    return try JSONDecoder().decode(PreviewRendererRequest.self, from: Data(contentsOf: url))
}

@MainActor
private var loadedPreviewLibraryPaths: Set<String> = []
private let initialPackageResourceDirectory = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]

@MainActor
func loadPreviewLibraries(_ request: PreviewRendererRequest) throws {
    let initialDirectory = initialPackageResourceDirectory
    guard unsafe setenv("XCODE_RUNNING_FOR_PREVIEWS", "1", 1) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let packageDirectory = request.packageResourceDirectory.map { Bundle.main.bundleURL.appendingPathComponent($0).path }
        ?? initialDirectory
    if let path = packageDirectory {
        guard unsafe setenv("PACKAGE_RESOURCE_BUNDLE_PATH", path, 1) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    } else {
        guard unsafe unsetenv("PACKAGE_RESOURCE_BUNDLE_PATH") == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    for name in request.libraryNames {
        let path = Bundle.main.bundleURL.appendingPathComponent(name).path
        guard !loadedPreviewLibraryPaths.contains(path) else { continue }
        // The process owns loaded preview code and its Swift metadata.
        guard unsafe dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil else {
            throw PreviewRendererError("Cannot load \(name): \(unsafe String(cString: dlerror()))")
        }
        loadedPreviewLibraryPaths.insert(path)
    }
    // Preview mode defers SwiftUI graph creation until its code is ready.
    __previewThunksHaveFinishedLoading()
}

@MainActor
func previewRegistry(for request: PreviewRendererRequest) throws -> any PreviewRegistry.Type {
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
    return registries[index]
}

@MainActor
func makeGeneralPreview(_ request: PreviewRendererRequest) async throws ->
    (view: AnyView, layout: DeveloperToolsSupport.PreviewLayout, variants: [String: String], result: PreviewRendererResult) {
    #if os(visionOS)
    guard request.displayVariantOverrides.isEmpty,
          request.activityViewStyle.map(PreviewRendererRequest.activityViewStyles.contains) ?? true,
          request.activityViewContext.map(PreviewRendererRequest.activityViewContexts.contains) ?? true else {
        throw NativePreviewPipelineRequired()
    }
    #endif
    let options = request.generalPreviewOptions(supportedVariants: supportedPreviewDisplayVariants)
    var variants = options.displayVariants
    var view: AnyView
    let layout: DeveloperToolsSupport.PreviewLayout
    var result: PreviewRendererResult
    if let typeName = request.providerTypeName {
        let preview = try makeLegacyViewPreview(typeName: typeName, index: 0)
        #if os(macOS) || targetEnvironment(macCatalyst)
        if let context = preview.context {
            // Native metadata classifies recognized context keys; a custom
            // context returning their defaults still describes a plain view.
            guard try await legacyPreviewContextCategory(context) == nil else {
                throw NativePreviewPipelineRequired()
            }
        }
        #elseif !os(tvOS)
        guard preview.context == nil else {
            throw NativePreviewPipelineRequired()
        }
        #endif
        #if os(visionOS)
        guard preview.interfaceOrientation == .portrait else {
            throw NativePreviewPipelineRequired()
        }
        #endif
        view = preview.content
        if variants["Color Scheme"] == nil, let colorScheme = preview.colorScheme {
            variants["Color Scheme"] = colorScheme == .dark ? "Dark Appearance" : "Light Appearance"
        }
        layout = preview.layout
        result = PreviewRendererResult(displayName: preview.displayName, sourceLineNumber: request.lineNumber,
            errors: request.groupItemIndex.map { [unsupportedPreviewGroupItemMessage($0, supportsGroups: false)] } ?? [])
    } else {
        let registry = try previewRegistry(for: request)
        let preview = try registry.makePreview()
        try requireSupportedTraits(preview)
        let value = try await ownedPreview(preview)
        let source = try await previewSource(value)
        let content = try await makeViewPreview(source: source, groupItemIndex: request.groupItemIndex)
        view = try await applyViewPreviewTraits(content.view, preview: value)
        layout = try await viewPreviewLayout(value)
        let getter = try await value.type.resolveGetter(named: "displayName", as: (() -> String?).self,
            receiverABI: .opaque(named: value.type.name))
        result = PreviewRendererResult(displayName: try unsafe getter.unsafeInvoke(on: value), sourceLineNumber: registry.line,
            groupItems: content.groupItems, errors: content.errors)
    }
    if let localization = request.localization { view = AnyView(view.environment(\.locale, Locale(identifier: localization))) }
    view = try applyDisplayVariants(to: view, variants: variants)
    result.errors = (result.errors ?? []) + options.errors
    result.supportedDisplayVariants = supportedPreviewDisplayVariants
    return (view, layout, variants, result)
}

@MainActor
func writeDesktopPreviewResult(_ result: PreviewRendererResult) -> Never {
    do {
        let data = try JSONEncoder().encode(result)
        // Inherited stdout also works with the source app's sandbox entitlements;
        // it avoids writing into the user's Documents or the source app container.
        try FileHandle.standardOutput.write(contentsOf: Data("\nXcodeMCPPreviewResult:".utf8) + data + Data("\n".utf8))
        exit(0)
    } catch {
        try? FileHandle.standardError.write(contentsOf: Data("Preview result could not be written: \(error)\n".utf8))
        exit(1)
    }
}
#endif
