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

    package init(libraryNames: [String], registryNames: [String], fileName: String,
                 moduleName: String?, lineNumber: Int?, columnNumber: Int?, definitionIndex: Int,
                 localization: String?) {
        self.libraryNames = libraryNames
        self.registryNames = registryNames
        self.fileName = fileName
        self.moduleName = moduleName
        self.lineNumber = lineNumber
        self.columnNumber = columnNumber
        self.definitionIndex = definitionIndex
        self.localization = localization
    }
}

package struct PreviewRendererResult: Codable, Sendable {
    package var snapshotName: String?
    package var displayName: String?
    package var sourceLineNumber: Int?
    package var error: String?
    package var requiresNativePipeline: Bool?

    package init(snapshotName: String? = nil, displayName: String? = nil,
                 sourceLineNumber: Int? = nil, error: String? = nil,
                 requiresNativePipeline: Bool? = nil) {
        self.snapshotName = snapshotName
        self.displayName = displayName
        self.sourceLineNumber = sourceLineNumber
        self.error = error
        self.requiresNativePipeline = requiresNativePipeline
    }
}
