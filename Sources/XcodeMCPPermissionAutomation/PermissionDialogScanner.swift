import AppKit
import Foundation
import Logging

struct PermissionDialogScanner {
    struct Dependencies: Sendable {
        let configuration: XcodePermissionDialogAutomation.Configuration
        let axClient: any XcodePermissionDialogAutomation.AXAccessing
        let uptimeNanoseconds: @Sendable () -> UInt64
        let logger: Logger
        let sharedState: SharedState

        init(
            configuration: XcodePermissionDialogAutomation.Configuration,
            axClient: any XcodePermissionDialogAutomation.AXAccessing,
            uptimeNanoseconds: @escaping @Sendable () -> UInt64,
            logger: Logger,
            sharedState: SharedState = SharedState()
        ) {
            self.configuration = configuration
            self.axClient = axClient
            self.uptimeNanoseconds = uptimeNanoseconds
            self.logger = logger
            self.sharedState = sharedState
        }
    }

    struct ScanResult: Equatable, Sendable {
        let inspectedProcessCount: Int
        let inspectedWindowCount: Int
        let matchedWindowCount: Int
        let approvedWindowCount: Int

        static let untrusted = Self(
            inspectedProcessCount: 0,
            inspectedWindowCount: 0,
            matchedWindowCount: 0,
            approvedWindowCount: 0
        )
    }

    private struct MatchedWindow {
        let processID: pid_t
        let window: XcodePermissionDialogAutomation.AXWindow
        let decision: XcodePermissionDialogAutomation.MatchDecision
    }

    private struct State {
        var lastAttemptUptimeByFingerprint: [String: UInt64] = [:]
        var loggedInspectionFingerprints: Set<String> = []
        var didLogNoMatch = false
        var didLogSlowInspection = false
    }

    final class SharedState: @unchecked Sendable {
        enum MonitoringAction {
            case first
            case changed
            case unchanged
        }

        private struct State {
            var didRequestAccessibilityPermission = false
            var didLogTrustedMonitoring = false
            var loggedPathCandidateText: String?
        }

        private let lock = NSLock()
        private var state = State()

        func requestAccessibilityPermissionIfNeeded(
            axClient: any XcodePermissionDialogAutomation.AXAccessing,
            logger: Logger
        ) {
            let shouldRequest = lock.withLock {
                guard state.didRequestAccessibilityPermission == false else {
                    return false
                }
                state.didRequestAccessibilityPermission = true
                return true
            }
            guard shouldRequest else {
                return
            }

            _ = axClient.authorizationStatus(promptIfNeeded: true)
            logger.warning(
                "Accessibility permission is required to auto-approve the Xcode permission dialog; requested the system prompt and will keep waiting for permission."
            )
        }

        func monitoringAction(pathCandidateText: String) -> MonitoringAction {
            lock.withLock {
                guard state.didLogTrustedMonitoring else {
                    state.didLogTrustedMonitoring = true
                    state.loggedPathCandidateText = pathCandidateText
                    return .first
                }
                guard state.loggedPathCandidateText != pathCandidateText else {
                    return .unchanged
                }
                state.loggedPathCandidateText = pathCandidateText
                return .changed
            }
        }
    }

    private let dependencies: Dependencies
    private var state = State()
    private let retryIntervalNanoseconds: UInt64 = 500_000_000

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    mutating func scanAndApprove(processIDs explicitProcessIDs: [pid_t]? = nil) -> ScanResult {
        let scanStartedAt = dependencies.uptimeNanoseconds()
        guard dependencies.axClient.authorizationStatus(promptIfNeeded: false) == .trusted else {
            dependencies.sharedState.requestAccessibilityPermissionIfNeeded(
                axClient: dependencies.axClient,
                logger: dependencies.logger
            )
            return .untrusted
        }

        let configuration = dependencies.configuration
        let agentPathCandidates = configuration.agentPathCandidates()
        let assistantNameCandidates = configuration.assistantNameCandidates()
        logMonitoringIfNeeded(agentPathCandidates: agentPathCandidates)

        var visibleFingerprints: Set<String> = []
        var visibleInspectionFingerprints: Set<String> = []
        var inspectedWindowTitles: [String] = []
        var matchedWindows: [MatchedWindow] = []
        let processIDs = explicitProcessIDs ?? configuration.permissionDialogProcessIDs()
        var agentProcessIDCandidates: Set<pid_t>?
        let nowUptimeNanoseconds = dependencies.uptimeNanoseconds()
        var inspectedWindowCount = 0

        for processID in processIDs {
            let inspectionStartedAt = dependencies.uptimeNanoseconds()
            let processBundleIdentifier = NSRunningApplication(processIdentifier: processID)?
                .bundleIdentifier
            let windows: [XcodePermissionDialogAutomation.AXWindow]
            do {
                windows = try dependencies.axClient.openWindows(for: processID)
            } catch {
                if XcodePermissionDialogAutomation.AXFailureClassifier.isBenignOpenWindowsFailure(
                    error,
                    processBundleIdentifier: processBundleIdentifier
                ) {
                    dependencies.logger.debug(
                        "Ignoring benign AX window inspection failure for an Xcode-related process.",
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

            let inspectionDuration = dependencies.uptimeNanoseconds() &- inspectionStartedAt
            if inspectionDuration >= 500_000_000, state.didLogSlowInspection == false {
                state.didLogSlowInspection = true
                dependencies.logger.debug(
                    "Xcode AX window inspection exceeded the permission-dialog poll interval.",
                    metadata: [
                        "pid": "\(processID)",
                        "duration_ms": "\(inspectionDuration / 1_000_000)",
                        "window_count": "\(windows.count)",
                    ]
                )
            }

            inspectedWindowCount += windows.count
            for window in windows {
                let trimmedTitle = window.snapshot.title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if trimmedTitle.isEmpty == false, inspectedWindowTitles.count < 8 {
                    inspectedWindowTitles.append(trimmedTitle)
                }
                guard
                    XcodePermissionDialogAutomation.Matcher.passesStructuralChecks(
                        window.snapshot
                    )
                else {
                    continue
                }

                if agentProcessIDCandidates == nil {
                    agentProcessIDCandidates = configuration.agentProcessIDCandidates()
                }
                guard let resolvedAgentProcessIDCandidates = agentProcessIDCandidates else {
                    preconditionFailure("agent process PID candidates were not resolved")
                }
                guard
                    let decision = XcodePermissionDialogAutomation.Matcher.decision(
                        for: window.snapshot,
                        processID: processID,
                        agentPathCandidates: agentPathCandidates,
                        assistantNameCandidates: assistantNameCandidates,
                        serverProcessIDCandidates: resolvedAgentProcessIDCandidates
                    )
                else {
                    visibleInspectionFingerprints.insert(
                        inspectionFingerprint(processID: processID, snapshot: window.snapshot)
                    )
                    logStructurallyEligibleWindowIfNeeded(
                        processID: processID,
                        snapshot: window.snapshot,
                        agentPathCandidates: agentPathCandidates,
                        assistantNameCandidates: assistantNameCandidates,
                        agentProcessIDCandidates: resolvedAgentProcessIDCandidates
                    )
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

        state.loggedInspectionFingerprints = state.loggedInspectionFingerprints.filter {
            visibleInspectionFingerprints.contains($0)
        }
        state.lastAttemptUptimeByFingerprint = state.lastAttemptUptimeByFingerprint.filter {
            visibleFingerprints.contains($0.key)
        }

        let resolvedAgentProcessIDCandidates = agentProcessIDCandidates ?? []
        var approvedWindowCount = 0
        for matchedWindow in matchedWindows {
            logMatchedWindowIfNeeded(
                matchedWindow,
                agentPathCandidates: agentPathCandidates,
                assistantNameCandidates: assistantNameCandidates,
                agentProcessIDCandidates: resolvedAgentProcessIDCandidates
            )

            if let lastAttempt = state.lastAttemptUptimeByFingerprint[
                matchedWindow.decision.fingerprint
            ], nowUptimeNanoseconds &- lastAttempt < retryIntervalNanoseconds {
                continue
            }
            state.lastAttemptUptimeByFingerprint[matchedWindow.decision.fingerprint] =
                nowUptimeNanoseconds

            do {
                try dependencies.axClient.pressDefaultButton(in: matchedWindow.window)
                approvedWindowCount += 1
                dependencies.logger.info(
                    "\(Self.approvalLogSummary(processID: matchedWindow.processID, buttonTitle: matchedWindow.decision.defaultButtonTitle))",
                    metadata: [
                        "scan_elapsed_ms": "\((dependencies.uptimeNanoseconds() &- scanStartedAt) / 1_000_000)"
                    ]
                )
                dependencies.logger.debug(
                    "Auto-approved Xcode permission dialog details.",
                    metadata: [
                        "pid": "\(matchedWindow.processID)",
                        "button": .string(matchedWindow.decision.defaultButtonTitle),
                        "agent_pid_candidates": .string(
                            resolvedAgentProcessIDCandidates.map(String.init).sorted().joined(
                                separator: ","
                            )
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

        if visibleFingerprints.isEmpty == false {
            state.didLogNoMatch = false
        } else if processIDs.isEmpty == false, state.didLogNoMatch == false {
            state.didLogNoMatch = true
            dependencies.logger.debug(
                "Xcode permission dialog auto-approver found running Xcode windows but no matching permission dialog yet.",
                metadata: [
                    "xcode_pids": .string(processIDs.map(String.init).joined(separator: ",")),
                    "window_titles": .string(inspectedWindowTitles.joined(separator: " | ")),
                ]
            )
        }

        return ScanResult(
            inspectedProcessCount: processIDs.count,
            inspectedWindowCount: inspectedWindowCount,
            matchedWindowCount: matchedWindows.count,
            approvedWindowCount: approvedWindowCount
        )
    }

    private mutating func logMonitoringIfNeeded(agentPathCandidates: Set<String>) {
        let pathCandidateText = agentPathCandidates.sorted().joined(separator: " | ")
        switch dependencies.sharedState.monitoringAction(pathCandidateText: pathCandidateText) {
        case .first:
            dependencies.logger.info("\(Self.monitoringLogSummary())")
            dependencies.logger.debug(
                "Xcode permission dialog auto-approver monitoring details.",
                metadata: ["agent_paths": .string(pathCandidateText)]
            )
        case .changed:
            dependencies.logger.debug(
                "Xcode permission dialog auto-approver candidate paths changed.",
                metadata: ["agent_paths": .string(pathCandidateText)]
            )
        case .unchanged:
            break
        }
    }

    private static func monitoringLogSummary() -> String {
        """
        Permission
          Auto-approver: monitoring
        """
    }

    private static func approvalLogSummary(processID: pid_t, buttonTitle: String) -> String {
        """
        Permission
          Auto-approved Xcode permission dialog
          Xcode PID: \(processID)
          Button: \(buttonTitle)
        """
    }

    private mutating func logStructurallyEligibleWindowIfNeeded(
        processID: pid_t,
        snapshot: XcodePermissionDialogAutomation.WindowSnapshot,
        agentPathCandidates: Set<String>,
        assistantNameCandidates: Set<String>,
        agentProcessIDCandidates: Set<pid_t>
    ) {
        let fingerprint = inspectionFingerprint(processID: processID, snapshot: snapshot)
        guard state.loggedInspectionFingerprints.insert(fingerprint).inserted else {
            return
        }

        dependencies.logger.debug(
            "Observed a structurally eligible Xcode modal window that did not match the assistant-name plus PID/path guard; auto-approve skipped.",
            metadata: inspectionMetadata(
                processID: processID,
                snapshot: snapshot,
                agentPathCandidates: agentPathCandidates,
                assistantNameCandidates: assistantNameCandidates,
                agentProcessIDCandidates: agentProcessIDCandidates
            )
        )
    }

    private mutating func logMatchedWindowIfNeeded(
        _ matchedWindow: MatchedWindow,
        agentPathCandidates: Set<String>,
        assistantNameCandidates: Set<String>,
        agentProcessIDCandidates: Set<pid_t>
    ) {
        guard
            state.loggedInspectionFingerprints.insert(
                matchedWindow.decision.fingerprint
            ).inserted
        else {
            return
        }

        let snapshot = matchedWindow.window.snapshot
        dependencies.logger.debug(
            "Observed AX metadata for a matched Xcode permission dialog candidate.",
            metadata: inspectionMetadata(
                processID: matchedWindow.processID,
                snapshot: snapshot,
                agentPathCandidates: agentPathCandidates,
                assistantNameCandidates: assistantNameCandidates,
                agentProcessIDCandidates: agentProcessIDCandidates
            )
        )
    }

    private func inspectionMetadata(
        processID: pid_t,
        snapshot: XcodePermissionDialogAutomation.WindowSnapshot,
        agentPathCandidates: Set<String>,
        assistantNameCandidates: Set<String>,
        agentProcessIDCandidates: Set<pid_t>
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
            "agent_pid_candidates": .string(
                agentProcessIDCandidates.map(String.init).sorted().joined(separator: ",")
            ),
        ]
    }

    private func inspectionFingerprint(
        processID: pid_t,
        snapshot: XcodePermissionDialogAutomation.WindowSnapshot
    ) -> String {
        "candidate|\(XcodePermissionDialogAutomation.Matcher.fingerprint(for: snapshot, processID: processID))"
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
