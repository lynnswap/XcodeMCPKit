import Foundation

package struct XcodeWindowInfo: Sendable, Equatable {
    package let tabIdentifier: String
    package let workspacePath: String

    package init(tabIdentifier: String, workspacePath: String) {
        self.tabIdentifier = tabIdentifier
        self.workspacePath = workspacePath
    }
}
