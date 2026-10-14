#if os(iOS) || os(tvOS) || os(visionOS) || os(macOS) || os(watchOS)
import ABIBridge
import Darwin
import DeveloperToolsSupport
import Foundation
import SwiftUI
import XcodeMCPWire

@MainActor
func loadPreviewRequest() throws -> PreviewRendererRequest {
    let url = Bundle.main.resourceURL!.appendingPathComponent("PreviewRequest.json")
    let request = try JSONDecoder().decode(PreviewRendererRequest.self, from: Data(contentsOf: url))
    guard unsafe setenv("XCODE_RUNNING_FOR_PREVIEWS", "1", 1) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    for name in request.libraryNames {
        let path = Bundle.main.bundleURL.appendingPathComponent(name).path
        // The process owns loaded preview code and its Swift metadata.
        guard unsafe dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil else {
            throw PreviewRendererError("Cannot load \(name): \(unsafe String(cString: dlerror()))")
        }
    }
    __previewThunksHaveFinishedLoading()
    return request
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
    guard request.displayVariantOverrides.allSatisfy({ supportedPreviewDisplayVariants[$0.key]?.contains($0.value) == true }) else {
        throw NativePreviewPipelineRequired()
    }
    var variants = request.displayVariantOverrides
    var view: AnyView
    let layout: DeveloperToolsSupport.PreviewLayout
    var result: PreviewRendererResult
    if let typeName = request.providerTypeName {
        let preview = try makeLegacyViewPreview(typeName: typeName, index: 0)
        guard preview.context == nil else {
            throw NativePreviewPipelineRequired()
        }
        #if !os(macOS)
        guard preview.device == nil, preview.interfaceOrientation == .portrait else {
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
    result.errors = (result.errors ?? []) + request.unsupportedGeneralPreviewOptions
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
