import AppKit
import ApplicationServices
import Foundation
import Logging
import ProxyCore

package enum XcodePermissionDialogMatcher {
    private static let allowedProcessBundleIdentifiers = normalizedCandidates([
        "com.apple.dt.Xcode",
        "com.apple.dt.ExternalViewService",
        "com.apple.dt.Xcode.DeveloperSystemPolicyService",
    ])
    private static let allowedWindowRoles = normalizedCandidates([
        "AXWindow"
    ])
    private static let allowedWindowSubroles = normalizedCandidates([
        "AXDialog",
        "AXSystemDialog",
    ])

    package static func decision(
        for snapshot: XcodePermissionDialogWindowSnapshot,
        processID: pid_t,
        agentPathCandidates: Set<String> = [],
        assistantNameCandidates: Set<String>,
        serverProcessIDCandidates: Set<pid_t> = [ProcessInfo.processInfo.processIdentifier]
    ) -> XcodePermissionDialogMatchDecision? {
        guard passesStructuralChecks(snapshot) else {
            return nil
        }

        let normalizedAgentPaths = normalizedCandidates(agentPathCandidates)
        let normalizedAssistantNames = normalizedCandidates(assistantNameCandidates)
        let pidCandidates = normalizedPIDCandidates(serverProcessIDCandidates)
        let normalizedTextNodes = normalizedTextNodes(for: snapshot)
        let defaultButtonDescription = normalizedButtonDescription(snapshot.defaultButton)
        guard containsAssistantNameAndPID(
            in: normalizedTextNodes,
            agentPathCandidates: normalizedAgentPaths,
            assistantNameCandidates: normalizedAssistantNames,
            serverProcessIDCandidates: pidCandidates,
            defaultButtonDescription: defaultButtonDescription
        ) else {
            return nil
        }

        return XcodePermissionDialogMatchDecision(
            fingerprint: fingerprint(for: snapshot, processID: processID),
            defaultButtonTitle: defaultButtonDescription
        )
    }

    package static func fingerprint(
        for snapshot: XcodePermissionDialogWindowSnapshot,
        processID: pid_t
    ) -> String {
        let textFingerprint = normalizedTextNodes(for: snapshot).joined(separator: "\u{1F}")
        let bundleFingerprint = normalizedText(snapshot.processBundleIdentifier) ?? ""
        let roleFingerprint = normalizedText(snapshot.role) ?? ""
        let subroleFingerprint = normalizedText(snapshot.subrole) ?? ""
        return [
            "\(processID)",
            bundleFingerprint,
            roleFingerprint,
            subroleFingerprint,
            "\(snapshot.isModal)",
            textFingerprint,
        ].joined(separator: "|")
    }

    package static func passesStructuralChecks(_ snapshot: XcodePermissionDialogWindowSnapshot) -> Bool {
        guard
            let normalizedBundleIdentifier = normalizedText(snapshot.processBundleIdentifier),
            allowedProcessBundleIdentifiers.contains(normalizedBundleIdentifier)
        else {
            return false
        }
        guard snapshot.isModal else {
            return false
        }
        guard snapshot.defaultButton != nil else {
            return false
        }
        guard snapshot.isMinimized != true else {
            return false
        }
        if let normalizedRole = normalizedText(snapshot.role),
           allowedWindowRoles.contains(normalizedRole) == false {
            return false
        }
        if let normalizedSubrole = normalizedText(snapshot.subrole),
           allowedWindowSubroles.contains(normalizedSubrole) == false {
            return false
        }
        if looksLikeNormalWorkspaceWindow(snapshot) {
            return false
        }
        return true
    }

    private static func looksLikeNormalWorkspaceWindow(_ snapshot: XcodePermissionDialogWindowSnapshot) -> Bool {
        let hasDocument = normalizedText(snapshot.document) != nil
        return snapshot.isMain == true && (hasDocument || snapshot.hasProxy)
    }

    private static func normalizedTextNodes(for snapshot: XcodePermissionDialogWindowSnapshot) -> [String] {
        ([snapshot.title] + snapshot.textValues).compactMap(normalizedText)
    }

    private static func containsAssistantNameAndPID(
        in normalizedTextNodes: [String],
        agentPathCandidates: Set<String>,
        assistantNameCandidates: Set<String>,
        serverProcessIDCandidates: Set<String>,
        defaultButtonDescription: String
    ) -> Bool {
        let containsPath = normalizedTextNodes.contains { text in
            agentPathCandidates.contains(where: { text.contains($0) })
        }
        if assistantNameCandidates.isEmpty {
            return containsPath
        }

        let sameNodeMatch = normalizedTextNodes.contains { text in
            serverProcessIDCandidates.contains(where: { containsNumericToken($0, in: text) })
                && assistantNameCandidates.contains(where: { text.contains($0) })
        }
        if sameNodeMatch {
            return true
        }

        let containsAssistantName = normalizedTextNodes.contains { text in
            assistantNameCandidates.contains(where: { text.contains($0) })
        }
        let containsPID = normalizedTextNodes.contains { text in
            serverProcessIDCandidates.contains(where: { containsNumericToken($0, in: text) })
        }
        if containsAssistantName && containsPID {
            return true
        }
        let containsUnmatchedPIDReference = normalizedTextNodes.contains(where: containsPIDReference)
        if containsAssistantName && containsUnmatchedPIDReference {
            return false
        }
        if containsAssistantName && !containsUnmatchedPIDReference
            && looksLikeAllowButton(defaultButtonDescription)
        {
            return true
        }
        guard containsPID == false, containsPath else {
            return false
        }

        let sameNodePathMatch = normalizedTextNodes.contains { text in
            agentPathCandidates.contains(where: { text.contains($0) })
                && assistantNameCandidates.contains(where: { text.contains($0) })
        }
        if sameNodePathMatch {
            return true
        }
        return containsAssistantName
    }

    private static func looksLikeAllowButton(_ description: String) -> Bool {
        let allowDescriptions: Set<String> = [
            "allow",
            "許可",
            "action-button-1",
        ]
        return allowDescriptions.contains(description)
    }

    private static func normalizedButtonDescription(
        _ button: XcodePermissionDialogButtonSnapshot?
    ) -> String {
        normalizedText(button?.title)
            ?? normalizedText(button?.identifier)
            ?? normalizedText(button?.role)
            ?? "default"
    }

    private static func normalizedCandidates(_ candidates: some Sequence<String>) -> Set<String> {
        Set(candidates.compactMap(normalizedText))
    }

    private static func normalizedPIDCandidates(_ candidates: Set<pid_t>) -> Set<String> {
        Set(candidates.map(String.init))
    }

    private static func containsNumericToken(_ candidate: String, in text: String) -> Bool {
        guard candidate.isEmpty == false else {
            return false
        }

        var currentDigits = ""
        currentDigits.reserveCapacity(candidate.count)

        for scalar in text.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                currentDigits.unicodeScalars.append(scalar)
                continue
            }
            if currentDigits == candidate {
                return true
            }
            currentDigits.removeAll(keepingCapacity: true)
        }

        return currentDigits == candidate
    }

    private static func containsPIDReference(_ text: String) -> Bool {
        guard text.unicodeScalars.contains(where: { scalar in
            CharacterSet.decimalDigits.contains(scalar)
        }) else {
            return false
        }
        let labels = [
            "pid",
            "process id",
            "process identifier",
            "process-id",
            "process_identifier",
            "プロセス",
            "識別子",
        ]
        return labels.contains { text.contains($0) }
    }

    private static func normalizedText(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        let sanitizedScalars = text.unicodeScalars.filter { scalar in
            scalar.properties.generalCategory != .format
        }
        let sanitized = String(String.UnicodeScalarView(sanitizedScalars))
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        return trimmed.lowercased()
    }
}
