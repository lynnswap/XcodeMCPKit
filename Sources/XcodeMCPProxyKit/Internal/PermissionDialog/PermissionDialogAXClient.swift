import AppKit
import ApplicationServices
import Foundation
import Logging
import ProxySession

extension XcodePermissionDialog {
    package protocol AXAccessing: Sendable {
        func authorizationStatus(promptIfNeeded: Bool) -> XcodePermissionDialog.AccessibilityStatus
        func runningXcodeProcessIDs() -> [pid_t]
        func openWindows(for processID: pid_t) throws -> [XcodePermissionDialog.AXWindow]
        func pressDefaultButton(in window: XcodePermissionDialog.AXWindow) throws
    }

    package final class AXWindow {
        package let processID: pid_t
        package let snapshot: XcodePermissionDialog.WindowSnapshot
        private let defaultButton: AXUIElement

        package init(
            processID: pid_t,
            snapshot: XcodePermissionDialog.WindowSnapshot,
            defaultButton: AXUIElement
        ) {
            self.processID = processID
            self.snapshot = snapshot
            self.defaultButton = defaultButton
        }

        fileprivate func pressDefaultButton() throws {
            let error = AXUIElementPerformAction(defaultButton, kAXPressAction as CFString)
            guard error == .success else {
                throw XcodePermissionDialog.AXError.performActionFailed(error)
            }
        }
    }

    package enum AXError: Error, CustomStringConvertible {
        case copyAttributeFailed(attribute: String, error: ApplicationServices.AXError)
        case performActionFailed(ApplicationServices.AXError)

        package var description: String {
            switch self {
            case .copyAttributeFailed(let attribute, let error):
                return "AX attribute '\(attribute)' failed: \(error.rawValue)"
            case .performActionFailed(let error):
                return "AX action failed: \(error.rawValue)"
            }
        }
    }

    package enum AXFailureClassifier {
        private static let externalViewServiceBundleIdentifier = "com.apple.dt.ExternalViewService"
        private static let windowsAttribute = kAXWindowsAttribute as String

        package static func isBenignOpenWindowsFailure(
            _ error: Error,
            processBundleIdentifier: String?
        ) -> Bool {
            guard processBundleIdentifier == externalViewServiceBundleIdentifier else {
                return false
            }
            guard let error = error as? XcodePermissionDialog.AXError else {
                return false
            }
            guard case .copyAttributeFailed(let attribute, let axError) = error else {
                return false
            }
            return attribute == windowsAttribute && axError == .cannotComplete
        }
    }

    package struct AXClient: XcodePermissionDialog.AXAccessing {
        private let maxDescendantCount = 128

        package init() {}

        package func authorizationStatus(promptIfNeeded: Bool) -> XcodePermissionDialog.AccessibilityStatus {
            if promptIfNeeded {
                let options: NSDictionary = [
                    "AXTrustedCheckOptionPrompt" as NSString: true
                ]
                return AXIsProcessTrustedWithOptions(options) ? .trusted : .untrusted
            }
            return AXIsProcessTrusted() ? .trusted : .untrusted
        }

        package func runningXcodeProcessIDs() -> [pid_t] {
            let bundleIdentifiers: Set<String> = [
                "com.apple.dt.Xcode",
                "com.apple.dt.ExternalViewService",
                "com.apple.dt.Xcode.DeveloperSystemPolicyService",
            ]
            var processIDs = Set(NSWorkspace.shared.runningApplications.compactMap { application -> pid_t? in
                guard let bundleIdentifier = application.bundleIdentifier else {
                    return nil
                }
                guard bundleIdentifiers.contains(bundleIdentifier), application.isTerminated == false else {
                    return nil
                }
                return application.processIdentifier
            })
        processIDs.formUnion(ProcessEnumeration.processIDs(named: "Xcode"))
        return processIDs.sorted()
    }

    package func openWindows(for processID: pid_t) throws -> [XcodePermissionDialog.AXWindow] {
        let app = AXUIElementCreateApplication(processID)
        return try copyElementArray(attribute: kAXWindowsAttribute as CFString, from: app).compactMap { window in
                try makeWindow(processID: processID, window: window)
            }
        }

        package func pressDefaultButton(in window: XcodePermissionDialog.AXWindow) throws {
            try window.pressDefaultButton()
        }

        private func makeWindow(
            processID: pid_t,
            window: AXUIElement
        ) throws -> XcodePermissionDialog.AXWindow? {
            let role = copyString(attribute: kAXRoleAttribute as CFString, from: window)
            if let role, role != kAXWindowRole as String {
                return nil
            }

            let subrole = copyString(attribute: kAXSubroleAttribute as CFString, from: window)
            if let subrole,
               subrole != kAXDialogSubrole as String,
               subrole != "AXSystemDialog" {
                return nil
            }

            let isModal = copyBool(attribute: kAXModalAttribute as CFString, from: window) ?? false
            guard isModal else {
                return nil
            }

            let isMinimized = copyBool(attribute: kAXMinimizedAttribute as CFString, from: window)
            guard isMinimized != true else {
                return nil
            }

            let isMain = copyBool(attribute: kAXMainAttribute as CFString, from: window)
            let document = copyString(attribute: kAXDocumentAttribute as CFString, from: window)
            let hasProxy = copyElement(attribute: kAXProxyAttribute as CFString, from: window) != nil
            if isMain == true && (hasNonEmptyText(document) || hasProxy) {
                return nil
            }

            let children = (try? copyElementArray(attribute: kAXChildrenAttribute as CFString, from: window)) ?? []
            guard let defaultButton = copyElement(attribute: kAXDefaultButtonAttribute as CFString, from: window)
                ?? fallbackAllowButton(in: window)
            else {
                return nil
            }
            let processBundleIdentifier = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier

            let snapshot = XcodePermissionDialog.WindowSnapshot(
                processBundleIdentifier: processBundleIdentifier,
                title: copyString(attribute: kAXTitleAttribute as CFString, from: window) ?? "",
                textValues: collectTextValues(from: window),
                role: role,
                subrole: subrole,
                windowIdentifier: copyString(attribute: kAXIdentifierAttribute as CFString, from: window),
                isModal: isModal,
                isMain: isMain,
                isMinimized: isMinimized,
                document: document,
                childCount: children.count,
                hasProxy: hasProxy,
                defaultButton: buttonSnapshot(from: defaultButton),
                cancelButton: copyElement(attribute: kAXCancelButtonAttribute as CFString, from: window)
                    .flatMap(buttonSnapshot(from:))
            )

            return XcodePermissionDialog.AXWindow(
                processID: processID,
                snapshot: snapshot,
                defaultButton: defaultButton
            )
        }

        private func fallbackAllowButton(in root: AXUIElement) -> AXUIElement? {
            var queue: [AXUIElement] = [root]
            var visited = 0

            while queue.isEmpty == false, visited < maxDescendantCount {
                let element = queue.removeFirst()
                visited += 1

                if isAllowButton(element) {
                    return element
                }
                let children = (try? copyElementArray(attribute: kAXChildrenAttribute as CFString, from: element)) ?? []
                queue.append(contentsOf: children)
            }

            return nil
        }

        private func isAllowButton(_ element: AXUIElement) -> Bool {
            let role = copyString(attribute: kAXRoleAttribute as CFString, from: element)
            guard role == kAXButtonRole as String else { return false }
            let title = copyString(attribute: kAXTitleAttribute as CFString, from: element)
                .flatMap(normalizedButtonText)
            let identifier = copyString(attribute: kAXIdentifierAttribute as CFString, from: element)
                .flatMap(normalizedButtonText)
            return title == "allow"
                || title == "許可"
                || identifier == "action-button-1"
        }

        private func normalizedButtonText(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            return trimmed.lowercased()
        }

        private func hasNonEmptyText(_ value: String?) -> Bool {
            guard let value else { return false }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }

        private func collectTextValues(from root: AXUIElement) -> [String] {
            var queue: [AXUIElement] = [root]
            var values: [String] = []
            var visited = 0

            while queue.isEmpty == false, visited < maxDescendantCount {
                let element = queue.removeFirst()
                visited += 1

                if let title = copyString(attribute: kAXTitleAttribute as CFString, from: element) {
                    values.append(title)
                }
                if let value = copyString(attribute: kAXValueAttribute as CFString, from: element) {
                    values.append(value)
                }
                if let description = copyString(attribute: kAXDescriptionAttribute as CFString, from: element) {
                    values.append(description)
                }

                if let children = try? copyElementArray(attribute: kAXChildrenAttribute as CFString, from: element) {
                    queue.append(contentsOf: children)
                }
            }

            var seen = Set<String>()
            return values.filter { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false else {
                    return false
                }
                return seen.insert(trimmed).inserted
            }
        }

        private func buttonSnapshot(from element: AXUIElement) -> XcodePermissionDialog.ButtonSnapshot {
            XcodePermissionDialog.ButtonSnapshot(
                title: copyString(attribute: kAXTitleAttribute as CFString, from: element)
                    ?? copyString(attribute: kAXDescriptionAttribute as CFString, from: element)
                    ?? copyString(attribute: kAXValueAttribute as CFString, from: element),
                role: copyString(attribute: kAXRoleAttribute as CFString, from: element),
                subrole: copyString(attribute: kAXSubroleAttribute as CFString, from: element),
                identifier: copyString(attribute: kAXIdentifierAttribute as CFString, from: element)
            )
        }

        private func copyString(attribute: CFString, from element: AXUIElement) -> String? {
            guard let value = try? copyAttribute(attribute: attribute, from: element) else {
                return nil
            }
            return value as? String
        }

        private func copyBool(attribute: CFString, from element: AXUIElement) -> Bool? {
            guard let value = try? copyAttribute(attribute: attribute, from: element) else {
                return nil
            }
            return value as? Bool
        }

        private func copyElement(attribute: CFString, from element: AXUIElement) -> AXUIElement? {
            guard let value = try? copyAttribute(attribute: attribute, from: element) else {
                return nil
            }
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafe unsafeDowncast(value, to: AXUIElement.self)
        }

        private func copyElementArray(attribute: CFString, from element: AXUIElement) throws -> [AXUIElement] {
            guard let value = try copyAttribute(attribute: attribute, from: element) else {
                return []
            }
            if let elements = value as? [AXUIElement] {
                return elements
            }
            if let array = value as? [AnyObject] {
                return array.compactMap { candidate in
                    guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else {
                        return nil
                    }
                    return unsafe unsafeDowncast(candidate, to: AXUIElement.self)
                }
            }
            return []
        }

        private func copyAttribute(attribute: CFString, from element: AXUIElement) throws -> CFTypeRef? {
            var value: CFTypeRef?
            let error = unsafe AXUIElementCopyAttributeValue(element, attribute, &value)
            switch error {
            case .success, .noValue:
                return value
            default:
                throw XcodePermissionDialog.AXError.copyAttributeFailed(
                    attribute: attribute as String,
                    error: error
                )
            }
        }
    }
}
