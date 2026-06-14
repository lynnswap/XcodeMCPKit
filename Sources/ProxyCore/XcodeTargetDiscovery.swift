import Foundation

package struct DocumentationProviderTarget: Sendable, Equatable {
    package let processID: pid_t
    package let appPath: String
    package let developerDir: String
    package let mcpbridgePath: String

    package init(
        processID: pid_t,
        appPath: String,
        developerDir: String,
        mcpbridgePath: String
    ) {
        self.processID = processID
        self.appPath = appPath
        self.developerDir = developerDir
        self.mcpbridgePath = mcpbridgePath
    }
}

package protocol XcodeTargetDiscovering: Sendable {
    func runningXcodeTargets() -> [DocumentationProviderTarget]
}
