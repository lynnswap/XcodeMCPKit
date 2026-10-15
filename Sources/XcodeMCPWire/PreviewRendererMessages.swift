import Foundation

package enum PreviewRendererNativeSource: Codable, Sendable {
    case providerMetadata(extensionIdentifier: String, providerName: String)
    case preview(extensionIdentifier: String, specification: Data, metadata: Data, variantOverrides: [String: String])

    package var extensionIdentifier: String {
        switch self {
        case .providerMetadata(let identifier, _), .preview(let identifier, _, _, _): identifier
        }
    }
}

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
    package var widgetPresentation: String?
    package var timelineIndex: Int?
    package var groupItemIndex: Int?
    package var providerTypeName: String?
    package var programRootNames: [String]?
    package var displayVariantOverrides: [String: String]
    package var activityViewStyle: String?
    package var activityViewContext: String?
    package var activityToggleState: Bool?
    package var appName: String?
    package var nativeSource: PreviewRendererNativeSource?
    package var nativeEnvironment: [String: String]?
    package var metadataOnly: Bool?
    package var isLegacyComplication: Bool?

    package init(libraryNames: [String], registryNames: [String], fileName: String,
                 moduleName: String?, lineNumber: Int?, columnNumber: Int?, definitionIndex: Int,
                 localization: String?, widgetFamily: String? = nil, widgetPresentation: String? = nil,
                 timelineIndex: Int? = nil, groupItemIndex: Int? = nil, providerTypeName: String? = nil,
                 programRootNames: [String]? = nil,
                 displayVariantOverrides: [String: String] = [:], activityViewStyle: String? = nil,
                 activityViewContext: String? = nil, activityToggleState: Bool? = nil,
                 appName: String? = nil, nativeSource: PreviewRendererNativeSource? = nil, nativeEnvironment: [String: String]? = nil,
                 metadataOnly: Bool? = nil,
                 isLegacyComplication: Bool? = nil) {
        self.libraryNames = libraryNames
        self.registryNames = registryNames
        self.fileName = fileName
        self.moduleName = moduleName
        self.lineNumber = lineNumber
        self.columnNumber = columnNumber
        self.definitionIndex = definitionIndex
        self.localization = localization
        self.widgetFamily = widgetFamily
        self.widgetPresentation = widgetPresentation
        self.timelineIndex = timelineIndex
        self.groupItemIndex = groupItemIndex
        self.providerTypeName = providerTypeName
        self.programRootNames = programRootNames
        self.displayVariantOverrides = displayVariantOverrides
        self.activityViewStyle = activityViewStyle
        self.activityViewContext = activityViewContext
        self.activityToggleState = activityToggleState
        self.appName = appName
        self.nativeSource = nativeSource
        self.nativeEnvironment = nativeEnvironment
        self.metadataOnly = metadataOnly
        self.isLegacyComplication = isLegacyComplication
    }

    package func generalPreviewOptions(supportedVariants: [String: [String]]) ->
        (displayVariants: [String: String], errors: [String]) {
        var errors: [String] = []
        if let timelineIndex {
            errors.append("Unsupported timeline index \(timelineIndex); the specified preview doesn't support timeline indexes in the currently active scheme.")
        }
        if let activityToggleState {
            errors.append("Unsupported toggle state \(activityToggleState); the specified preview doesn't support a toggle control in the currently active scheme.")
        }
        var requestedVariants = displayVariantOverrides
        for (group, value) in [("Widget Family", widgetFamily), ("Presentation", widgetPresentation),
                               ("View Style", activityViewStyle), ("Activity View Context", activityViewContext)] {
            if let value { requestedVariants[group] = value }
        }
        var displayVariants: [String: String] = [:]
        for (group, value) in requestedVariants.sorted(by: { $0.key < $1.key }) {
            let message: String
            if let values = supportedVariants[group] {
                if values.contains(value) {
                    displayVariants[group] = value
                    continue
                }
                message = "Unsupported variant ‘\(value)’ for group ‘\(group)’"
            } else {
                message = "Unsupported variant group ‘\(group)’"
            }
            errors.append("\(message); see the `supportedPreviewVariantOverrides` field of the result for the list of supported groups and variants for rendering this preview in the currently active scheme.")
        }
        return (displayVariants, errors)
    }
}

package struct PreviewRendererResult: Codable, Sendable {
    package var snapshotName: String?
    package var snapshotData: Data?
    package var displayName: String?
    package var sourceLineNumber: Int?
    package var error: String?
    package var requiresNativePipeline: Bool?
    package var timelineIndexes: [Int]?
    package var groupItems: [String?]?
    package var errors: [String]?
    package var toggleStates: [Bool]?
    package var activityViewStyles: [String]?
    package var activityViewContexts: [String]?
    package var supportedDisplayVariants: [String: [String]]?
    package var usesDeviceLayout: Bool?
    package var interfaceOrientation: String?
    package var exclusionSnapshotName: String?
    package var nativeMetadata: Data?
    package var nativeProviderPreviewDescription: Data?

    package init(snapshotName: String? = nil, snapshotData: Data? = nil, displayName: String? = nil,
                 sourceLineNumber: Int? = nil, error: String? = nil,
                 requiresNativePipeline: Bool? = nil, timelineIndexes: [Int]? = nil,
                 groupItems: [String?]? = nil, errors: [String]? = nil,
                 toggleStates: [Bool]? = nil, activityViewStyles: [String]? = nil,
                 activityViewContexts: [String]? = nil,
                 supportedDisplayVariants: [String: [String]]? = nil, usesDeviceLayout: Bool? = nil,
                 interfaceOrientation: String? = nil, exclusionSnapshotName: String? = nil,
                 nativeMetadata: Data? = nil, nativeProviderPreviewDescription: Data? = nil) {
        self.snapshotName = snapshotName
        self.snapshotData = snapshotData
        self.displayName = displayName
        self.sourceLineNumber = sourceLineNumber
        self.error = error
        self.requiresNativePipeline = requiresNativePipeline
        self.timelineIndexes = timelineIndexes
        self.groupItems = groupItems
        self.errors = errors
        self.toggleStates = toggleStates
        self.activityViewStyles = activityViewStyles
        self.activityViewContexts = activityViewContexts
        self.supportedDisplayVariants = supportedDisplayVariants
        self.usesDeviceLayout = usesDeviceLayout
        self.interfaceOrientation = interfaceOrientation
        self.exclusionSnapshotName = exclusionSnapshotName
        self.nativeMetadata = nativeMetadata
        self.nativeProviderPreviewDescription = nativeProviderPreviewDescription
    }
}
