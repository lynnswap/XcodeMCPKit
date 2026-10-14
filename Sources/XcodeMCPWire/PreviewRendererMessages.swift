import Foundation

package struct PreviewRendererRequest: Codable, Sendable {
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

    package init(libraryNames: [String], registryNames: [String], fileName: String,
                 moduleName: String?, lineNumber: Int?, columnNumber: Int?, definitionIndex: Int,
                 localization: String?, widgetFamily: String? = nil, timelineIndex: Int? = nil) {
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

    package init(snapshotName: String? = nil, displayName: String? = nil,
                 sourceLineNumber: Int? = nil, error: String? = nil,
                 requiresNativePipeline: Bool? = nil, timelineIndexes: [Int]? = nil, widgetFamilies: [String]? = nil) {
        self.snapshotName = snapshotName
        self.displayName = displayName
        self.sourceLineNumber = sourceLineNumber
        self.error = error
        self.requiresNativePipeline = requiresNativePipeline
        self.timelineIndexes = timelineIndexes
        self.widgetFamilies = widgetFamilies
    }
}
