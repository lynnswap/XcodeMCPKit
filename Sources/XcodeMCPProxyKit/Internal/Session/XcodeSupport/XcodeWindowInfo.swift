import Foundation

struct XcodeWindowInfo: Sendable, Equatable {
    let tabIdentifier: String
    let workspacePath: String

    init(tabIdentifier: String, workspacePath: String) {
        self.tabIdentifier = tabIdentifier
        self.workspacePath = workspacePath
    }
}
