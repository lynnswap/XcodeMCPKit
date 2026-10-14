import Foundation
import Testing
import XcodeMCPWire
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewOptionsTests {
    @Test func generalPreviewReportsUnsupportedControlsAndVariantGroups() {
        let request = PreviewRendererRequest(libraryNames: [], registryNames: [], fileName: "View.swift",
            moduleName: nil, lineNumber: nil, columnNumber: nil, definitionIndex: 0, localization: nil,
            widgetPresentation: "Placeholder", timelineIndex: 42, displayVariantOverrides: ["Color Scheme": "Dark Appearance"],
            activityViewStyle: "Compact", activityViewContext: "Stale", activityToggleState: false)
        #expect(request.unsupportedGeneralPreviewOptions == [
            "Unsupported timeline index 42; the specified preview doesn't support timeline indexes in the currently active scheme.",
            "Unsupported toggle state false; the specified preview doesn't support a toggle control in the currently active scheme.",
            "Unsupported variant group ‘Activity View Context’; see the `supportedPreviewVariantOverrides` field of the result for the list of supported groups and variants for rendering this preview in the currently active scheme.",
            "Unsupported variant group ‘Presentation’; see the `supportedPreviewVariantOverrides` field of the result for the list of supported groups and variants for rendering this preview in the currently active scheme.",
            "Unsupported variant group ‘View Style’; see the `supportedPreviewVariantOverrides` field of the result for the list of supported groups and variants for rendering this preview in the currently active scheme.",
        ])
        var supported = request
        supported.widgetPresentation = nil
        supported.timelineIndex = nil
        supported.activityViewStyle = nil
        supported.activityViewContext = nil
        supported.activityToggleState = nil
        #expect(supported.unsupportedGeneralPreviewOptions.isEmpty)
    }

    @Test func widgetFamilyPresentationAndTimelineUseDirectRenderer() {
        let options = NativePreviewCorrection.directOptions(variants: [
            "Widget Family": "Large", "Presentation": "Placeholder", "Color Scheme": "Dark Appearance",
        ],
            controls: ["timelineIndex": Optional(1) as Any, "toggleState": Optional<Bool>.none as Any])
        #expect(options.widgetFamily == "Large")
        #expect(options.widgetPresentation == "Placeholder")
        #expect(options.timelineIndex == 1)
        #expect(options.displayVariants == ["Color Scheme": "Dark Appearance"])
        #expect(!options.requiresNativePipeline)
    }

    @Test func firstTimelineIndexIsPreserved() {
        let options = NativePreviewCorrection.directOptions(variants: [:],
            controls: ["timelineIndex": Optional(0) as Any])
        #expect(options.timelineIndex == 0)
        #expect(!options.requiresNativePipeline)
    }

    @Test func groupItemSelectionUsesDirectRenderer() {
        let options = NativePreviewCorrection.directOptions(variants: [:],
            controls: ["groupItemIndex": Optional(1) as Any, "timelineIndex": Optional<Int>.none as Any])
        #expect(options.groupItemIndex == 1)
        #expect(options.timelineIndex == nil)
        #expect(!options.requiresNativePipeline)
    }

    @Test func activityControlsPreserveStaleSelectionAndDisabledToggle() {
        let options = NativePreviewCorrection.directOptions(
            variants: ["View Style": "Content (Smart Stack)", "Activity View Context": "Stale",
                       "Color Scheme": "Dark Appearance"],
            controls: ["timelineIndex": Optional(1) as Any, "toggleState": Optional(false) as Any])
        #expect(options.activityViewStyle == "Content (Smart Stack)")
        #expect(options.activityViewContext == "Stale")
        #expect(options.activityToggleState == false)
        #expect(options.timelineIndex == 1)
        #expect(options.displayVariants == ["Color Scheme": "Dark Appearance"])
        #expect(!options.requiresNativePipeline)
    }

    @Test func advertisesGroupItemObjectsMatchingNativeOutput() throws {
        let native = #"{"name":"RenderPreview","inputSchema":{"properties":[]},"outputSchema":{"properties":[{"name":"previewSnapshotPath","isRequired":false,"type":{"string":{}}},{"name":"supportedCanvasControlOverrides","isRequired":false,"type":{"object":{"schema":{"properties":[{"name":"groupItems","isRequired":false,"type":{"array":{"itemType":{"integer":{}}}}}]}}}}]}}"#
        let tool = try NativeSchemaConverter.tool(from: Data(native.utf8), workspaceScoped: true)
        let corrected = NativePreviewCorrection.describe(tool)
        let item = try nativeTestField(corrected.descriptor, "outputSchema", "properties", "supportedCanvasControlOverrides", "properties", "groupItems", "items")
        #expect(try nativeTestField(item, "type") == .string("object"))
        #expect(try nativeTestField(item, "properties", "index", "type") == .string("integer"))
        #expect(try nativeTestField(item, "properties", "title", "type") == .string("string"))
        #expect(try nativeTestField(item, "required") == .array([.string("index")]))
    }

    @Test func otherVariantsAndControlsKeepNativeRendering() {
        #expect(NativePreviewCorrection.directOptions(variants: ["View Style": "Unknown Style"], controls: [:]).requiresNativePipeline)
        #expect(NativePreviewCorrection.directOptions(variants: ["Color Scheme": "Unknown Appearance"], controls: [:]).requiresNativePipeline)
        #expect(NativePreviewCorrection.directOptions(variants: [:],
            controls: ["futureControl": Optional(1) as Any]).requiresNativePipeline)
    }

    @Test func displayVariantsUseDirectRenderer() {
        let options = NativePreviewCorrection.directOptions(variants: [
            "Color Scheme": "Dark Appearance", "Contrast": "Increased Contrast",
            "Dynamic Type": "AX 1", "Control Borders": "Shown", "Orientation": "Landscape Left",
        ], controls: [:])
        #expect(!options.requiresNativePipeline)
    }

    @Test func displayVariantsWithWidgetOptionsUseDirectRenderer() {
        #expect(!NativePreviewCorrection.directOptions(variants: [
            "Widget Family": "Medium", "Color Scheme": "Dark Appearance", "Dynamic Type": "AX 1",
        ], controls: [:]).requiresNativePipeline)
    }

    @Test func activityDefaultStylePreservesTimelineAndAppearance() {
        let options = NativePreviewCorrection.directOptions(variants: ["Color Scheme": "Dark Appearance"],
            controls: ["timelineIndex": Optional(1) as Any])
        #expect(options.timelineIndex == 1)
        #expect(options.displayVariants == ["Color Scheme": "Dark Appearance"])
        #expect(options.activityViewStyle == nil)
        #expect(!options.requiresNativePipeline)
    }
}
