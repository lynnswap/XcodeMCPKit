import Foundation

package struct PreviewRendererRequest: Codable, Sendable {
    package static let displayVariantValues: [String: [String]] = [
        "Color Scheme": ["Light Appearance", "Dark Appearance"],
        "Contrast": ["Standard Contrast", "Increased Contrast"],
        "Control Borders": ["Hidden", "Shown"],
        "Dynamic Type": ["X Small", "Small", "Medium", "Large", "X Large", "XX Large", "XXX Large",
                         "AX 1", "AX 2", "AX 3", "AX 4", "AX 5"],
        "Orientation": ["Portrait", "Landscape Left", "Landscape Right"],
    ]
    package static let activityViewStyles = ["Compact", "Compact (Landscape)", "Minimal", "Minimal (Landscape)",
        "Expanded", "Content (Lock Screen)", "Content (StandBy)", "Content (Smart Stack)"]
    package static let activityViewContexts = ["Normal", "Stale"]

    package var libraryNames: [String]
    package var registryNames: [String]
    package var fileName: String
    package var moduleName: String?
    package var lineNumber: Int?
    package var columnNumber: Int?
    package var definitionIndex: Int
    package var localization: String?
    package var widgetFamily: String?
    package var timelineIndex: Int?
    package var groupItemIndex: Int?
    package var providerTypeName: String?
    package var displayVariantOverrides: [String: String]
    package var activityViewStyle: String?
    package var activityViewContext: String?
    package var activityToggleState: Bool?
    package var appName: String?

    package init(libraryNames: [String], registryNames: [String], fileName: String,
                 moduleName: String?, lineNumber: Int?, columnNumber: Int?, definitionIndex: Int,
                 localization: String?, widgetFamily: String? = nil, timelineIndex: Int? = nil,
                 groupItemIndex: Int? = nil, providerTypeName: String? = nil,
                 displayVariantOverrides: [String: String] = [:], activityViewStyle: String? = nil,
                 activityViewContext: String? = nil, activityToggleState: Bool? = nil,
                 appName: String? = nil) {
        self.libraryNames = libraryNames
        self.registryNames = registryNames
        self.fileName = fileName
        self.moduleName = moduleName
        self.lineNumber = lineNumber
        self.columnNumber = columnNumber
        self.definitionIndex = definitionIndex
        self.localization = localization
        self.widgetFamily = widgetFamily
        self.timelineIndex = timelineIndex
        self.groupItemIndex = groupItemIndex
        self.providerTypeName = providerTypeName
        self.displayVariantOverrides = displayVariantOverrides
        self.activityViewStyle = activityViewStyle
        self.activityViewContext = activityViewContext
        self.activityToggleState = activityToggleState
        self.appName = appName
    }
}

package struct PreviewRendererResult: Codable, Sendable {
    package var snapshotName: String?
    package var displayName: String?
    package var sourceLineNumber: Int?
    package var error: String?
    package var requiresNativePipeline: Bool?
    package var timelineIndexes: [Int]?
    package var widgetFamilies: [String]?
    package var groupItems: [String?]?
    package var errors: [String]?
    package var toggleStates: [Bool]?
    package var activityViewStyles: [String]?
    package var activityViewContexts: [String]?
    package var supportedDisplayVariants: [String: [String]]?
    package var usesDeviceLayout: Bool?
    package var interfaceOrientation: String?

    package init(snapshotName: String? = nil, displayName: String? = nil,
                 sourceLineNumber: Int? = nil, error: String? = nil,
                 requiresNativePipeline: Bool? = nil, timelineIndexes: [Int]? = nil, widgetFamilies: [String]? = nil,
                 groupItems: [String?]? = nil, errors: [String]? = nil,
                 toggleStates: [Bool]? = nil, activityViewStyles: [String]? = nil,
                 activityViewContexts: [String]? = nil,
                 supportedDisplayVariants: [String: [String]]? = nil, usesDeviceLayout: Bool? = nil,
                 interfaceOrientation: String? = nil) {
        self.snapshotName = snapshotName
        self.displayName = displayName
        self.sourceLineNumber = sourceLineNumber
        self.error = error
        self.requiresNativePipeline = requiresNativePipeline
        self.timelineIndexes = timelineIndexes
        self.widgetFamilies = widgetFamilies
        self.groupItems = groupItems
        self.errors = errors
        self.toggleStates = toggleStates
        self.activityViewStyles = activityViewStyles
        self.activityViewContexts = activityViewContexts
        self.supportedDisplayVariants = supportedDisplayVariants
        self.usesDeviceLayout = usesDeviceLayout
        self.interfaceOrientation = interfaceOrientation
    }
}
