import AppKit
import ApplicationServices
import Foundation
import Logging

package enum XcodePermissionDialog {}

extension XcodePermissionDialog {
    package enum AccessibilityStatus: Sendable {
        case trusted
        case untrusted
    }

    package struct ButtonSnapshot: Equatable, Sendable {
        package let title: String?
        package let role: String?
        package let subrole: String?
        package let identifier: String?

        package init(
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

    package struct WindowSnapshot: Equatable, Sendable {
        package let processBundleIdentifier: String?
        package let title: String
        package let textValues: [String]
        package let role: String?
        package let subrole: String?
        package let windowIdentifier: String?
        package let isModal: Bool
        package let isMain: Bool?
        package let isMinimized: Bool?
        package let document: String?
        package let childCount: Int
        package let hasProxy: Bool
        package let defaultButton: XcodePermissionDialog.ButtonSnapshot?
        package let cancelButton: XcodePermissionDialog.ButtonSnapshot?

        package init(
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
            defaultButton: XcodePermissionDialog.ButtonSnapshot? = nil,
            cancelButton: XcodePermissionDialog.ButtonSnapshot? = nil
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

    package struct MatchDecision: Equatable, Sendable {
        package let fingerprint: String
        package let defaultButtonTitle: String

        package init(fingerprint: String, defaultButtonTitle: String) {
            self.fingerprint = fingerprint
            self.defaultButtonTitle = defaultButtonTitle
        }
    }
}
