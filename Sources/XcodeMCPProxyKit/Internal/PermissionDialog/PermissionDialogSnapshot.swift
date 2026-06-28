import AppKit
import ApplicationServices
import Foundation
import Logging

enum XcodePermissionDialog {}

extension XcodePermissionDialog {
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
        let defaultButton: XcodePermissionDialog.ButtonSnapshot?
        let cancelButton: XcodePermissionDialog.ButtonSnapshot?

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

    struct MatchDecision: Equatable, Sendable {
        let fingerprint: String
        let defaultButtonTitle: String

        init(fingerprint: String, defaultButtonTitle: String) {
            self.fingerprint = fingerprint
            self.defaultButtonTitle = defaultButtonTitle
        }
    }
}
