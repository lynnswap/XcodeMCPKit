import AppKit
import ApplicationServices
import Foundation
import Logging
import ProxyCore

package enum XcodePermissionDialogAccessibilityStatus: Sendable {
    case trusted
    case untrusted
}

package struct XcodePermissionDialogButtonSnapshot: Equatable, Sendable {
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

package struct XcodePermissionDialogWindowSnapshot: Equatable, Sendable {
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
    package let defaultButton: XcodePermissionDialogButtonSnapshot?
    package let cancelButton: XcodePermissionDialogButtonSnapshot?

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
        defaultButton: XcodePermissionDialogButtonSnapshot? = nil,
        cancelButton: XcodePermissionDialogButtonSnapshot? = nil
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

package struct XcodePermissionDialogMatchDecision: Equatable, Sendable {
    package let fingerprint: String
    package let defaultButtonTitle: String

    package init(fingerprint: String, defaultButtonTitle: String) {
        self.fingerprint = fingerprint
        self.defaultButtonTitle = defaultButtonTitle
    }
}

package enum XcodePermissionDialogMatcher {
    private static let allowedProcessBundleIdentifiers = normalizedCandidates([
        "com.apple.dt.Xcode",
        "com.apple.dt.ExternalViewService",
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
        guard containsAssistantNameAndPID(
            in: normalizedTextNodes(for: snapshot),
            agentPathCandidates: normalizedAgentPaths,
            assistantNameCandidates: normalizedAssistantNames,
            serverProcessIDCandidates: pidCandidates
        ) else {
            return nil
        }

        return XcodePermissionDialogMatchDecision(
            fingerprint: fingerprint(for: snapshot, processID: processID),
            defaultButtonTitle: normalizedButtonDescription(snapshot.defaultButton)
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
        serverProcessIDCandidates: Set<String>
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

package protocol XcodePermissionDialogAXAccessing: Sendable {
    func authorizationStatus(promptIfNeeded: Bool) -> XcodePermissionDialogAccessibilityStatus
    func runningXcodeProcessIDs() -> [pid_t]
    func openWindows(for processID: pid_t) throws -> [XcodePermissionDialogAXWindow]
    func pressDefaultButton(in window: XcodePermissionDialogAXWindow) throws
}

package final class XcodePermissionDialogAXWindow {
    package let processID: pid_t
    package let snapshot: XcodePermissionDialogWindowSnapshot
    private let defaultButton: AXUIElement

    package init(
        processID: pid_t,
        snapshot: XcodePermissionDialogWindowSnapshot,
        defaultButton: AXUIElement
    ) {
        self.processID = processID
        self.snapshot = snapshot
        self.defaultButton = defaultButton
    }

    fileprivate func pressDefaultButton() throws {
        let error = AXUIElementPerformAction(defaultButton, kAXPressAction as CFString)
        guard error == .success else {
            throw XcodePermissionDialogAXError.performActionFailed(error)
        }
    }
}

package enum XcodePermissionDialogAXError: Error, CustomStringConvertible {
    case copyAttributeFailed(attribute: String, error: AXError)
    case performActionFailed(AXError)

    package var description: String {
        switch self {
        case .copyAttributeFailed(let attribute, let error):
            return "AX attribute '\(attribute)' failed: \(error.rawValue)"
        case .performActionFailed(let error):
            return "AX action failed: \(error.rawValue)"
        }
    }
}

package enum XcodePermissionDialogAXFailureClassifier {
    private static let externalViewServiceBundleIdentifier = "com.apple.dt.ExternalViewService"
    private static let windowsAttribute = kAXWindowsAttribute as String

    package static func isBenignOpenWindowsFailure(
        _ error: Error,
        processBundleIdentifier: String?
    ) -> Bool {
        guard processBundleIdentifier == externalViewServiceBundleIdentifier else {
            return false
        }
        guard let error = error as? XcodePermissionDialogAXError else {
            return false
        }
        guard case .copyAttributeFailed(let attribute, let axError) = error else {
            return false
        }
        return attribute == windowsAttribute && axError == .cannotComplete
    }
}

package struct LiveXcodePermissionDialogAXClient: XcodePermissionDialogAXAccessing {
    private let maxDescendantCount = 128

    package init() {}

    package func authorizationStatus(promptIfNeeded: Bool) -> XcodePermissionDialogAccessibilityStatus {
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
        ]
        let processIDs = NSWorkspace.shared.runningApplications.compactMap { application -> pid_t? in
            guard let bundleIdentifier = application.bundleIdentifier else {
                return nil
            }
            guard bundleIdentifiers.contains(bundleIdentifier), application.isTerminated == false else {
                return nil
            }
            return application.processIdentifier
        }
        return Array(Set(processIDs)).sorted()
    }

    package func openWindows(for processID: pid_t) throws -> [XcodePermissionDialogAXWindow] {
        let app = AXUIElementCreateApplication(processID)
        return try copyElementArray(attribute: kAXWindowsAttribute as CFString, from: app).compactMap { window in
            try makeWindow(processID: processID, window: window)
        }
    }

    package func pressDefaultButton(in window: XcodePermissionDialogAXWindow) throws {
        try window.pressDefaultButton()
    }

    private func makeWindow(
        processID: pid_t,
        window: AXUIElement
    ) throws -> XcodePermissionDialogAXWindow? {
        guard let defaultButton = copyElement(attribute: kAXDefaultButtonAttribute as CFString, from: window) else {
            return nil
        }
        let children = (try? copyElementArray(attribute: kAXChildrenAttribute as CFString, from: window)) ?? []
        let processBundleIdentifier = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier

        let snapshot = XcodePermissionDialogWindowSnapshot(
            processBundleIdentifier: processBundleIdentifier,
            title: copyString(attribute: kAXTitleAttribute as CFString, from: window) ?? "",
            textValues: collectTextValues(from: window),
            role: copyString(attribute: kAXRoleAttribute as CFString, from: window),
            subrole: copyString(attribute: kAXSubroleAttribute as CFString, from: window),
            windowIdentifier: copyString(attribute: kAXIdentifierAttribute as CFString, from: window),
            isModal: copyBool(attribute: kAXModalAttribute as CFString, from: window) ?? false,
            isMain: copyBool(attribute: kAXMainAttribute as CFString, from: window),
            isMinimized: copyBool(attribute: kAXMinimizedAttribute as CFString, from: window),
            document: copyString(attribute: kAXDocumentAttribute as CFString, from: window),
            childCount: children.count,
            hasProxy: copyElement(attribute: kAXProxyAttribute as CFString, from: window) != nil,
            defaultButton: buttonSnapshot(from: defaultButton),
            cancelButton: copyElement(attribute: kAXCancelButtonAttribute as CFString, from: window)
                .flatMap(buttonSnapshot(from:))
        )

        return XcodePermissionDialogAXWindow(
            processID: processID,
            snapshot: snapshot,
            defaultButton: defaultButton
        )
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

    private func buttonSnapshot(from element: AXUIElement) -> XcodePermissionDialogButtonSnapshot {
        XcodePermissionDialogButtonSnapshot(
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
            throw XcodePermissionDialogAXError.copyAttributeFailed(
                attribute: attribute as String,
                error: error
            )
        }
    }
}

package final class XcodePermissionDialogAutoApprover: @unchecked Sendable {
    package struct Dependencies: Sendable {
        package var axClient: any XcodePermissionDialogAXAccessing
        package var agentPathCandidates: @Sendable () -> Set<String>
        package var assistantNameCandidates: @Sendable () -> Set<String>
        package var serverProcessIDCandidates: @Sendable () -> Set<pid_t>
        package var sleep: @Sendable (Duration) async -> Void
        package var pollInterval: Duration
        package var logger: Logger

        package init(
            axClient: any XcodePermissionDialogAXAccessing,
            agentPathCandidates: @escaping @Sendable () -> Set<String>,
            assistantNameCandidates: @escaping @Sendable () -> Set<String>,
            serverProcessIDCandidates: @escaping @Sendable () -> Set<pid_t>,
            sleep: @escaping @Sendable (Duration) async -> Void,
            pollInterval: Duration,
            logger: Logger
        ) {
            self.axClient = axClient
            self.agentPathCandidates = agentPathCandidates
            self.assistantNameCandidates = assistantNameCandidates
            self.serverProcessIDCandidates = serverProcessIDCandidates
            self.sleep = sleep
            self.pollInterval = pollInterval
            self.logger = logger
        }

        package static func live(
            agentPathCandidates: @escaping @Sendable () -> Set<String> = {
                XcodePermissionDialogAutoApprover.defaultAgentPathCandidates()
            },
            assistantNameCandidates: @escaping @Sendable () -> Set<String> = {
                ["XcodeMCPKit"]
            },
            serverProcessIDCandidates: @escaping @Sendable () -> Set<pid_t> = {
                XcodePermissionDialogAutoApprover.defaultServerProcessIDCandidates()
            }
        ) -> Self {
            Self(
                axClient: LiveXcodePermissionDialogAXClient(),
                agentPathCandidates: agentPathCandidates,
                assistantNameCandidates: assistantNameCandidates,
                serverProcessIDCandidates: serverProcessIDCandidates,
                sleep: { duration in
                    try? await Task.sleep(for: duration)
                },
                pollInterval: .milliseconds(250),
                logger: ProxyLogging.make("xcode.permission")
            )
        }
    }

    private struct State {
        var started = false
        var task: Task<Void, Never>?
        var lastAttemptUptimeByFingerprint: [String: UInt64] = [:]
        var loggedInspectionFingerprints: Set<String> = []
        var didLogNoMatch = false
    }

    private struct MatchedWindow {
        let processID: pid_t
        let window: XcodePermissionDialogAXWindow
        let decision: XcodePermissionDialogMatchDecision
    }

    private let dependencies: Dependencies
    private let stateLock = NSLock()
    private var state = State()
    private let retryIntervalNanoseconds: UInt64 = 500_000_000

    package init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
    }

    package func start() {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard state.started == false else {
            return
        }
        state.started = true

        switch dependencies.axClient.authorizationStatus(promptIfNeeded: false) {
        case .trusted:
            let task = Task { [dependencies, weak self] in
                guard let self else {
                    return
                }
                await self.runMonitorLoop(dependencies: dependencies)
            }
            state.task = task
        case .untrusted:
            _ = dependencies.axClient.authorizationStatus(promptIfNeeded: true)
            dependencies.logger.warning(
                "Accessibility permission is required to auto-approve the Xcode permission dialog; requested the system prompt and will keep waiting for permission."
            )
            let task = Task { [dependencies, weak self] in
                guard let self else {
                    return
                }
                await self.runMonitorLoop(dependencies: dependencies)
            }
            state.task = task
        }
    }

    package func stop() {
        let task: Task<Void, Never>? = stateLock.withLock {
            state.started = false
            state.lastAttemptUptimeByFingerprint.removeAll()
            state.loggedInspectionFingerprints.removeAll()
            let task = state.task
            state.task = nil
            return task
        }

        task?.cancel()
    }

    package static func defaultAgentPathCandidates(
        arguments: [String] = CommandLine.arguments,
        executableURL: URL? = Bundle.main.executableURL,
        additionalExecutableCandidates: [String] = []
    ) -> Set<String> {
        var candidates: Set<String> = []

        if let raw = arguments.first, raw.isEmpty == false {
            candidates.insert(raw)
            let rawURL = URL(fileURLWithPath: raw)
            candidates.insert(rawURL.standardizedFileURL.path)
            candidates.insert(rawURL.resolvingSymlinksInPath().path)
        }

        if let executablePath = executableURL?.path, executablePath.isEmpty == false {
            let executableURL = URL(fileURLWithPath: executablePath)
            candidates.insert(executablePath)
            candidates.insert(executableURL.standardizedFileURL.path)
            candidates.insert(executableURL.resolvingSymlinksInPath().path)
        }

        for candidate in additionalExecutableCandidates where candidate.isEmpty == false {
            let candidateURL = URL(fileURLWithPath: candidate)
            candidates.insert(candidate)
            candidates.insert(candidateURL.standardizedFileURL.path)
            candidates.insert(candidateURL.resolvingSymlinksInPath().path)
        }

        return Set(candidates.filter { $0.isEmpty == false })
    }

    package static func defaultServerProcessIDCandidates(
        parentProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Set<pid_t> {
        var candidates: Set<pid_t> = [parentProcessID]
        var pending = [parentProcessID]

        while let currentProcessID = pending.popLast() {
            for childProcessID in childProcessIDs(of: currentProcessID)
            where candidates.insert(childProcessID).inserted {
                pending.append(childProcessID)
            }
        }

        return candidates
    }

    private func runMonitorLoop(dependencies: Dependencies) async {
        let agentPathCandidates = dependencies.agentPathCandidates()
        let assistantNameCandidates = dependencies.assistantNameCandidates()
        let pathCandidateText = agentPathCandidates.sorted().joined(separator: " | ")
        var hasLoggedTrustedMonitoring = false

        while Task.isCancelled == false {
            if dependencies.axClient.authorizationStatus(promptIfNeeded: false) != .trusted {
                await dependencies.sleep(dependencies.pollInterval)
                continue
            }

            if hasLoggedTrustedMonitoring == false {
                dependencies.logger.info(
                    "Xcode permission dialog auto-approver is monitoring Xcode.",
                    metadata: [
                        "agent_paths": .string(pathCandidateText)
                    ]
                )
                hasLoggedTrustedMonitoring = true
            }

            let visibleFingerprints = scanAndApprove(
                agentPathCandidates: agentPathCandidates,
                assistantNameCandidates: assistantNameCandidates,
                dependencies: dependencies
            )
            stateLock.withLock {
                state.lastAttemptUptimeByFingerprint =
                    state.lastAttemptUptimeByFingerprint.filter { visibleFingerprints.contains($0.key) }
            }

            await dependencies.sleep(dependencies.pollInterval)
        }
    }

    private func scanAndApprove(
        agentPathCandidates: Set<String>,
        assistantNameCandidates: Set<String>,
        dependencies: Dependencies
    ) -> Set<String> {
        var visibleFingerprints: Set<String> = []
        var visibleInspectionFingerprints: Set<String> = []
        var inspectedWindowTitles: [String] = []
        var matchedWindows: [MatchedWindow] = []
        let processIDs = dependencies.axClient.runningXcodeProcessIDs()
        let serverProcessIDCandidates = dependencies.serverProcessIDCandidates()
        let nowUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds

        for processID in processIDs {
            let processBundleIdentifier = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
            let windows: [XcodePermissionDialogAXWindow]
            do {
                windows = try dependencies.axClient.openWindows(for: processID)
            } catch {
                if XcodePermissionDialogAXFailureClassifier.isBenignOpenWindowsFailure(
                    error,
                    processBundleIdentifier: processBundleIdentifier
                ) {
                    dependencies.logger.debug(
                        "Ignoring benign AX window inspection failure for ExternalViewService.",
                        metadata: [
                            "pid": "\(processID)",
                            "error": "\(error)",
                        ]
                    )
                    continue
                }
                dependencies.logger.warning(
                    "Failed to inspect AX windows for a running Xcode-related process.",
                    metadata: [
                        "pid": "\(processID)",
                        "error": "\(error)",
                    ]
                )
                continue
            }
            for window in windows {
                let trimmedTitle = window.snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedTitle.isEmpty == false, inspectedWindowTitles.count < 8 {
                    inspectedWindowTitles.append(trimmedTitle)
                }
                let isStructurallyEligible =
                    XcodePermissionDialogMatcher.passesStructuralChecks(window.snapshot)
                guard let decision = XcodePermissionDialogMatcher.decision(
                    for: window.snapshot,
                    processID: processID,
                    agentPathCandidates: agentPathCandidates,
                    assistantNameCandidates: assistantNameCandidates,
                    serverProcessIDCandidates: serverProcessIDCandidates
                ) else {
                    if isStructurallyEligible {
                        visibleInspectionFingerprints.insert(
                            inspectionFingerprint(processID: processID, snapshot: window.snapshot)
                        )
                        logStructurallyEligibleWindowIfNeeded(
                            processID: processID,
                            snapshot: window.snapshot,
                            agentPathCandidates: agentPathCandidates,
                            assistantNameCandidates: assistantNameCandidates,
                            dependencies: dependencies
                        )
                    }
                    continue
                }

                visibleFingerprints.insert(decision.fingerprint)
                visibleInspectionFingerprints.insert(decision.fingerprint)
                matchedWindows.append(
                    MatchedWindow(
                        processID: processID,
                        window: window,
                        decision: decision
                    )
                )
            }
        }

        stateLock.withLock {
            state.loggedInspectionFingerprints =
                state.loggedInspectionFingerprints.filter { visibleInspectionFingerprints.contains($0) }
        }

        for matchedWindow in matchedWindows {
            logMatchedWindowIfNeeded(matchedWindow, dependencies: dependencies)

            let shouldPress = stateLock.withLock { () -> Bool in
                if let lastAttempt = state.lastAttemptUptimeByFingerprint[matchedWindow.decision.fingerprint],
                   nowUptimeNanoseconds &- lastAttempt < retryIntervalNanoseconds
                {
                    return false
                }
                state.lastAttemptUptimeByFingerprint[matchedWindow.decision.fingerprint] =
                    nowUptimeNanoseconds
                return true
            }
            guard shouldPress else {
                continue
            }

            do {
                try dependencies.axClient.pressDefaultButton(in: matchedWindow.window)
                dependencies.logger.info(
                    "Auto-approved the Xcode permission dialog.",
                    metadata: [
                        "pid": "\(matchedWindow.processID)",
                        "button": .string(matchedWindow.decision.defaultButtonTitle),
                        "server_pid_candidates": .string(
                            serverProcessIDCandidates.map(String.init).sorted().joined(separator: ",")
                        ),
                    ]
                )
            } catch {
                dependencies.logger.warning(
                    "Matched the Xcode permission dialog but could not press its default button.",
                    metadata: [
                        "pid": "\(matchedWindow.processID)",
                        "error": "\(error)",
                    ]
                )
            }
        }

        let shouldLogNoMatch = stateLock.withLock { () -> Bool in
            if visibleFingerprints.isEmpty == false {
                state.didLogNoMatch = false
                return false
            }
            guard processIDs.isEmpty == false, state.didLogNoMatch == false else {
                return false
            }
            state.didLogNoMatch = true
            return true
        }
        if shouldLogNoMatch {
            dependencies.logger.debug(
                "Xcode permission dialog auto-approver found running Xcode windows but no matching permission dialog yet.",
                metadata: [
                    "xcode_pids": .string(processIDs.map(String.init).joined(separator: ",")),
                    "window_titles": .string(inspectedWindowTitles.joined(separator: " | ")),
                ]
            )
        }

        return visibleFingerprints
    }

    private func logStructurallyEligibleWindowIfNeeded(
        processID: pid_t,
        snapshot: XcodePermissionDialogWindowSnapshot,
        agentPathCandidates: Set<String>,
        assistantNameCandidates: Set<String>,
        dependencies: Dependencies
    ) {
        let fingerprint = inspectionFingerprint(processID: processID, snapshot: snapshot)
        let shouldLog = stateLock.withLock {
            state.loggedInspectionFingerprints.insert(fingerprint).inserted
        }
        guard shouldLog else {
            return
        }

        dependencies.logger.debug(
            "Observed a structurally eligible Xcode modal window that did not match the assistant-name plus PID/path guard; auto-approve skipped.",
            metadata: inspectionMetadata(
                processID: processID,
                snapshot: snapshot,
                agentPathCandidates: agentPathCandidates,
                assistantNameCandidates: assistantNameCandidates,
                serverProcessIDCandidates: dependencies.serverProcessIDCandidates()
            )
        )
    }

    private func logMatchedWindowIfNeeded(
        _ matchedWindow: MatchedWindow,
        dependencies: Dependencies
    ) {
        let shouldLog = stateLock.withLock {
            state.loggedInspectionFingerprints.insert(matchedWindow.decision.fingerprint).inserted
        }
        guard shouldLog else {
            return
        }

        let snapshot = matchedWindow.window.snapshot
        dependencies.logger.debug(
            "Observed AX metadata for a matched Xcode permission dialog candidate.",
            metadata: inspectionMetadata(
                processID: matchedWindow.processID,
                snapshot: snapshot,
                agentPathCandidates: dependencies.agentPathCandidates(),
                assistantNameCandidates: dependencies.assistantNameCandidates(),
                serverProcessIDCandidates: dependencies.serverProcessIDCandidates()
            )
        )
    }

    private func inspectionMetadata(
        processID: pid_t,
        snapshot: XcodePermissionDialogWindowSnapshot,
        agentPathCandidates: Set<String>,
        assistantNameCandidates: Set<String>,
        serverProcessIDCandidates: Set<pid_t>
    ) -> Logger.Metadata {
        [
            "pid": "\(processID)",
            "bundle_id": .string(snapshot.processBundleIdentifier ?? ""),
            "window_identifier": .string(snapshot.windowIdentifier ?? ""),
            "window_role": .string(snapshot.role ?? ""),
            "window_subrole": .string(snapshot.subrole ?? ""),
            "window_main": .string("\(snapshot.isMain ?? false)"),
            "window_minimized": .string("\(snapshot.isMinimized ?? false)"),
            "window_document": .string(snapshot.document ?? ""),
            "window_children": .string("\(snapshot.childCount)"),
            "window_has_proxy": .string("\(snapshot.hasProxy)"),
            "default_button_identifier": .string(snapshot.defaultButton?.identifier ?? ""),
            "default_button_role": .string(snapshot.defaultButton?.role ?? ""),
            "cancel_button_identifier": .string(snapshot.cancelButton?.identifier ?? ""),
            "cancel_button_role": .string(snapshot.cancelButton?.role ?? ""),
            "agent_paths": .string(agentPathCandidates.sorted().joined(separator: " | ")),
            "assistant_names": .string(assistantNameCandidates.sorted().joined(separator: " | ")),
            "server_pid_candidates": .string(
                serverProcessIDCandidates.map(String.init).sorted().joined(separator: ",")
            ),
        ]
    }

    private func inspectionFingerprint(
        processID: pid_t,
        snapshot: XcodePermissionDialogWindowSnapshot
    ) -> String {
        "candidate|\(XcodePermissionDialogMatcher.fingerprint(for: snapshot, processID: processID))"
    }

    private static func childProcessIDs(of parentProcessID: pid_t) -> [pid_t] {
        let childCount = max(0, proc_listchildpids(parentProcessID, nil, 0))
        guard childCount > 0 else {
            return []
        }

        var childProcessIDs = Array<pid_t>(repeating: 0, count: Int(childCount))
        let copiedCount = unsafe childProcessIDs.withUnsafeMutableBufferPointer { buffer in
            unsafe proc_listchildpids(
                parentProcessID,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.stride)
            )
        }
        guard copiedCount > 0 else {
            return []
        }

        return childProcessIDs.prefix(Int(copiedCount)).filter { $0 > 0 }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
