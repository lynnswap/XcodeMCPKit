import Darwin
import Foundation

extension XcodePermissionDialogAutomation {
    enum Matcher {
        private static let allowedWindowRoles = normalizedCandidates([
            "AXWindow"
        ])
        private static let allowedWindowSubroles = normalizedCandidates([
            "AXDialog",
            "AXSystemDialog",
        ])

        static func connectionDecision(
            for snapshot: XcodePermissionDialogAutomation.WindowSnapshot,
            processID: pid_t
        ) -> XcodePermissionDialogAutomation.MatchDecision? {
            guard passesStructuralChecks(snapshot),
                normalizedText(snapshot.defaultButton?.role) == "axbutton",
                looksLikeAllowButton(normalizedButtonDescription(snapshot.defaultButton))
            else {
                return nil
            }

            // Xcode can expose the heading as AXStaticText while AXTitle is empty.
            let textNodes = normalizedTextNodes(for: snapshot).map {
                $0.replacingOccurrences(of: "’", with: "'")
            }
            let hasConnectionTitle = textNodes.contains { text in
                text.range(
                    of: #"(?s)^allow (?:“.+”|".+") to access xcode\?$"#,
                    options: .regularExpression
                ) != nil
            }
            let namedToolRequests = [
                #"^エージェント .+ が xcode のツール使用を要求しています。$"#,
                #"^the agent .+ wants to use xcode's tools(?: for .+)?\.$"#,
            ]
            let hasNamedToolRequest = textNodes.contains { text in
                namedToolRequests.contains { request in
                    text.range(of: request, options: .regularExpression) != nil
                }
            }
            guard hasConnectionTitle || hasNamedToolRequest else {
                return nil
            }
            return XcodePermissionDialogAutomation.MatchDecision(
                fingerprint: fingerprint(for: snapshot, processID: processID),
                defaultButtonTitle: normalizedButtonDescription(snapshot.defaultButton)
            )
        }

        static func decision(
            for snapshot: XcodePermissionDialogAutomation.WindowSnapshot,
            processID: pid_t,
            agentPathCandidates: Set<String> = [],
            assistantNameCandidates: Set<String>,
            serverProcessIDCandidates: Set<pid_t> = [ProcessInfo.processInfo.processIdentifier]
        ) -> XcodePermissionDialogAutomation.MatchDecision? {
            guard let connection = connectionDecision(for: snapshot, processID: processID) else {
                return nil
            }

            let normalizedAgentPaths = normalizedCandidates(agentPathCandidates)
            let normalizedAssistantNames = normalizedCandidates(assistantNameCandidates)
            let pidCandidates = normalizedPIDCandidates(serverProcessIDCandidates)
            let normalizedTextNodes = normalizedTextNodes(for: snapshot)
            guard
                matchesConfiguredAgent(
                    in: normalizedTextNodes,
                    agentPathCandidates: normalizedAgentPaths,
                    assistantNameCandidates: normalizedAssistantNames,
                    serverProcessIDCandidates: pidCandidates
                )
            else {
                return nil
            }

            return connection
        }

        static func fingerprint(
            for snapshot: XcodePermissionDialogAutomation.WindowSnapshot,
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

        static func passesStructuralChecks(_ snapshot: XcodePermissionDialogAutomation.WindowSnapshot) -> Bool {
            guard
                XcodePermissionDialogAutomation.isAllowedProcessBundleIdentifier(
                    snapshot.processBundleIdentifier
                )
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
                allowedWindowRoles.contains(normalizedRole) == false
            {
                return false
            }
            if let normalizedSubrole = normalizedText(snapshot.subrole),
                allowedWindowSubroles.contains(normalizedSubrole) == false
            {
                return false
            }
            if looksLikeNormalWorkspaceWindow(snapshot) {
                return false
            }
            return true
        }

        private static func looksLikeNormalWorkspaceWindow(_ snapshot: XcodePermissionDialogAutomation.WindowSnapshot)
            -> Bool
        {
            let hasDocument = normalizedText(snapshot.document) != nil
            return snapshot.isMain == true && (hasDocument || snapshot.hasProxy)
        }

        private static func normalizedTextNodes(for snapshot: XcodePermissionDialogAutomation.WindowSnapshot)
            -> [String]
        {
            ([snapshot.title] + snapshot.textValues).compactMap(normalizedText)
        }

        private static func matchesConfiguredAgent(
            in normalizedTextNodes: [String],
            agentPathCandidates: Set<String>,
            assistantNameCandidates: Set<String>,
            serverProcessIDCandidates: Set<String>
        ) -> Bool {
            if assistantNameCandidates.isEmpty {
                return normalizedTextNodes.contains { text in
                    agentPathCandidates.contains(where: { text.contains($0) })
                }
            }
            guard normalizedTextNodes.contains(where: { text in
                assistantNameCandidates.contains(where: { text.contains($0) })
            }) else {
                return false
            }
            if normalizedTextNodes.contains(where: { text in
                serverProcessIDCandidates.contains(where: { containsNumericToken($0, in: text) })
            }) {
                return true
            }
            return normalizedTextNodes.contains(where: containsPIDReference) == false
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
            _ button: XcodePermissionDialogAutomation.ButtonSnapshot?
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
            guard
                text.unicodeScalars.contains(where: { scalar in
                    CharacterSet.decimalDigits.contains(scalar)
                })
            else {
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
}
