import Foundation

package struct XcodeProcessTarget: Sendable, Equatable {
    package let processID: pid_t
    package let appPath: String
    package let developerDir: String
    package let mcpbridgePath: String
    package let xcodeVersion: String

    package init(
        processID: pid_t,
        appPath: String,
        developerDir: String,
        mcpbridgePath: String,
        xcodeVersion: String
    ) {
        self.processID = processID
        self.appPath = appPath
        self.developerDir = developerDir
        self.mcpbridgePath = mcpbridgePath
        self.xcodeVersion = xcodeVersion
    }
}

package protocol XcodeTargetDiscovering: Sendable {
    func runningXcodeTargets() -> [XcodeProcessTarget]
}
