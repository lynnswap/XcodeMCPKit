import Foundation
import Testing
import XcodeMCPWire
@testable import XcodeMCPNativeRuntime

@Suite
@MainActor
struct NativePreviewOptionsTests {
    @Test func widgetFamilyAndTimelineUseDirectRenderer() {
        let options = NativePreviewCorrection.directOptions(variants: ["Widget Family": "Medium"],
            controls: ["timelineIndex": Optional(1) as Any, "toggleState": Optional<Bool>.none as Any])
        #expect(options.widgetFamily == "Medium")
        #expect(options.timelineIndex == 1)
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
        #expect(NativePreviewCorrection.directOptions(variants: ["Widget Family": "Large"], controls: [:]).requiresNativePipeline)
        #expect(NativePreviewCorrection.directOptions(variants: ["Color Scheme": "Dark Appearance"], controls: [:]).requiresNativePipeline)
        #expect(NativePreviewCorrection.directOptions(variants: [:],
            controls: ["toggleState": Optional(false) as Any]).requiresNativePipeline)
        #expect(NativePreviewCorrection.directOptions(variants: [:],
            controls: ["futureControl": Optional(1) as Any]).requiresNativePipeline)
    }
}
