import Testing
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

    @Test func otherVariantsAndControlsKeepNativeRendering() {
        #expect(NativePreviewCorrection.directOptions(variants: ["Widget Family": "Large"], controls: [:]).requiresNativePipeline)
        #expect(NativePreviewCorrection.directOptions(variants: ["Color Scheme": "Dark Appearance"], controls: [:]).requiresNativePipeline)
        #expect(NativePreviewCorrection.directOptions(variants: [:],
            controls: ["toggleState": Optional(false) as Any]).requiresNativePipeline)
        #expect(NativePreviewCorrection.directOptions(variants: [:],
            controls: ["futureControl": Optional(1) as Any]).requiresNativePipeline)
    }
}
