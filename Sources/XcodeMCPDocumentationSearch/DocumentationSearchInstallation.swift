package struct DocumentationSearchInstallation: Sendable, Equatable {
    package let appPath: String
    package let xcodeVersion: String

    package init(appPath: String, xcodeVersion: String) {
        self.appPath = appPath
        self.xcodeVersion = xcodeVersion
    }
}
