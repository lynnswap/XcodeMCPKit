import AppKit
import ApplicationServices
import Foundation
import Logging
import ProxyCore

package final class XcodePermissionDialogAutoApprover: @unchecked Sendable {
    package struct Dependencies: DependencyClient {
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

        package static var liveValue: Self {
            live()
        }

        package static let testValue = Self(
            axClient: NoopXcodePermissionDialogAXClient(),
            agentPathCandidates: { [] },
            assistantNameCandidates: { [] },
            serverProcessIDCandidates: { [] },
            sleep: { _ in
                try? await Task.sleep(for: .milliseconds(1))
            },
            pollInterval: .milliseconds(1),
            logger: ProxyLogging.make("xcode.permission.test")
        )
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

private struct NoopXcodePermissionDialogAXClient: XcodePermissionDialogAXAccessing {
    func authorizationStatus(promptIfNeeded _: Bool) -> XcodePermissionDialogAccessibilityStatus {
        .untrusted
    }

    func runningXcodeProcessIDs() -> [pid_t] {
        []
    }

    func openWindows(for _: pid_t) throws -> [XcodePermissionDialogAXWindow] {
        []
    }

    func pressDefaultButton(in _: XcodePermissionDialogAXWindow) throws {}
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
