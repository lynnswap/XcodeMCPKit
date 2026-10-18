import Foundation

package enum XcodePermissionDialogAutomation {}

extension XcodePermissionDialogAutomation {
    private static let allowedProcessBundleIdentifiers: Set<String> = [
        "com.apple.dt.xcode",
        "com.apple.dt.externalviewservice",
        "com.apple.dt.xcode.developersystempolicyservice",
    ]

    package static func isAllowedProcessBundleIdentifier(_ identifier: String?) -> Bool {
        guard let identifier else {
            return false
        }
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowedProcessBundleIdentifiers.contains(normalized)
    }

    enum AccessibilityStatus: Sendable {
        case trusted
        case untrusted
    }

    struct ButtonSnapshot: Equatable, Sendable {
        let title: String?
        let role: String?
        let subrole: String?
        let identifier: String?

        init(
            title: String? = nil,
            role: String? = nil,
            subrole: String? = nil,
            identifier: String? = nil
        ) {
            self.title = title
            self.role = role
            self.subrole = subrole
            self.identifier = identifier
        }
    }

    struct WindowSnapshot: Equatable, Sendable {
        let processBundleIdentifier: String?
        let title: String
        let textValues: [String]
        let role: String?
        let subrole: String?
        let windowIdentifier: String?
        let isModal: Bool
        let isMain: Bool?
        let isMinimized: Bool?
        let document: String?
        let childCount: Int
        let hasProxy: Bool
        let defaultButton: XcodePermissionDialogAutomation.ButtonSnapshot?
        let cancelButton: XcodePermissionDialogAutomation.ButtonSnapshot?

        init(
            processBundleIdentifier: String? = nil,
            title: String,
            textValues: [String],
            role: String? = nil,
            subrole: String? = nil,
            windowIdentifier: String? = nil,
            isModal: Bool,
            isMain: Bool? = nil,
            isMinimized: Bool? = nil,
            document: String? = nil,
            childCount: Int = 0,
            hasProxy: Bool = false,
            defaultButton: XcodePermissionDialogAutomation.ButtonSnapshot? = nil,
            cancelButton: XcodePermissionDialogAutomation.ButtonSnapshot? = nil
        ) {
            self.processBundleIdentifier = processBundleIdentifier
            self.title = title
            self.textValues = textValues
            self.role = role
            self.subrole = subrole
            self.windowIdentifier = windowIdentifier
            self.isModal = isModal
            self.isMain = isMain
            self.isMinimized = isMinimized
            self.document = document
            self.childCount = childCount
            self.hasProxy = hasProxy
            self.defaultButton = defaultButton
            self.cancelButton = cancelButton
        }
    }

    struct MatchDecision: Equatable, Sendable {
        let fingerprint: String
        let defaultButtonTitle: String

        init(fingerprint: String, defaultButtonTitle: String) {
            self.fingerprint = fingerprint
            self.defaultButtonTitle = defaultButtonTitle
        }
    }
}
