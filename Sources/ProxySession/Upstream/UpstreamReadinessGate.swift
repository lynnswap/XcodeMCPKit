import Foundation
import ApplicationServices
import Logging
import NIOConcurrencyHelpers

package struct UpstreamReadinessGate: Sendable {
    package let isEnabled: Bool
    package let targetName: String
    package let pollIntervalNanoseconds: UInt64
    package let progressLogIntervalNanoseconds: UInt64
    package let launchRetryIntervalNanoseconds: UInt64
    package let initialRetryBackoffNanoseconds: UInt64
    package let maxRetryBackoffNanoseconds: UInt64
    package let uptimeNanoseconds: @Sendable () -> UInt64
    package let sleepNanoseconds: @Sendable (UInt64) async -> Void
    package let isAvailable: (@Sendable () async -> Bool)?
    package let launchIfUnavailable: (@Sendable () async -> Bool)?
    package let isReady: @Sendable () async -> Bool

    package init(
        isEnabled: Bool,
        targetName: String,
        pollIntervalNanoseconds: UInt64,
        progressLogIntervalNanoseconds: UInt64,
        launchRetryIntervalNanoseconds: UInt64,
        initialRetryBackoffNanoseconds: UInt64,
        maxRetryBackoffNanoseconds: UInt64,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64,
        sleepNanoseconds: @escaping @Sendable (UInt64) async -> Void,
        isAvailable: (@Sendable () async -> Bool)? = nil,
        launchIfUnavailable: (@Sendable () async -> Bool)? = nil,
        isReady: @escaping @Sendable () async -> Bool
    ) {
        self.isEnabled = isEnabled
        self.targetName = targetName
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.progressLogIntervalNanoseconds = progressLogIntervalNanoseconds
        self.launchRetryIntervalNanoseconds = launchRetryIntervalNanoseconds
        self.initialRetryBackoffNanoseconds = initialRetryBackoffNanoseconds
        self.maxRetryBackoffNanoseconds = maxRetryBackoffNanoseconds
        self.uptimeNanoseconds = uptimeNanoseconds
        self.sleepNanoseconds = sleepNanoseconds
        self.isAvailable = isAvailable
        self.launchIfUnavailable = launchIfUnavailable
        self.isReady = isReady
    }

    package static func alwaysReady(
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) -> Self {
        Self(
            isEnabled: false,
            targetName: "upstream",
            pollIntervalNanoseconds: 0,
            progressLogIntervalNanoseconds: 0,
            launchRetryIntervalNanoseconds: 0,
            initialRetryBackoffNanoseconds: 0,
            maxRetryBackoffNanoseconds: 0,
            uptimeNanoseconds: uptimeNanoseconds,
            sleepNanoseconds: { _ in },
            isAvailable: { true },
            launchIfUnavailable: nil,
            isReady: { true }
        )
    }

    package static func xcodeMCPBridge(
        uptimeNanoseconds: @escaping @Sendable () -> UInt64,
        sleepNanoseconds: @escaping @Sendable (UInt64) async -> Void,
        runProcess: @escaping @Sendable (ProcessRequest) async throws -> ProcessOutput
    ) -> Self {
        Self(
            isEnabled: true,
            targetName: "mcpbridge",
            pollIntervalNanoseconds: 1_000_000_000,
            progressLogIntervalNanoseconds: 5_000_000_000,
            launchRetryIntervalNanoseconds: 5_000_000_000,
            initialRetryBackoffNanoseconds: 1_000_000_000,
            maxRetryBackoffNanoseconds: 8_000_000_000,
            uptimeNanoseconds: uptimeNanoseconds,
            sleepNanoseconds: sleepNanoseconds,
            isAvailable: {
                let output = try? await runProcess(
                    ProcessRequest(
                        label: "detect-xcode-process",
                        executablePath: "/usr/bin/pgrep",
                        arguments: ["-x", "Xcode"],
                        input: nil
                    )
                )
                guard let output else { return false }
                return XcodeReadinessProbe.processIDs(fromPGrepOutput: output).isEmpty == false
            },
            launchIfUnavailable: {
                let output = try? await runProcess(
                    ProcessRequest(
                        label: "launch-xcode",
                        executablePath: "/usr/bin/open",
                        arguments: ["-a", "Xcode"],
                        input: nil
                    )
                )
                return output?.terminationStatus == 0
            },
            isReady: {
                let output = try? await runProcess(
                    ProcessRequest(
                        label: "detect-xcode-process",
                        executablePath: "/usr/bin/pgrep",
                        arguments: ["-x", "Xcode"],
                        input: nil
                    )
                )
                guard let output else { return false }
                let processIDs = XcodeReadinessProbe.processIDs(fromPGrepOutput: output)
                return XcodeReadinessProbe.isReady(
                    xcodeProcessIDs: processIDs,
                    windows: XcodeReadinessProbe.visibleWindowSnapshots(
                        xcodeProcessIDs: processIDs
                    )
                )
            }
        )
    }
}

package enum XcodeReadinessProbe {
    package struct WindowSnapshot: Equatable, Sendable {
        package let ownerPID: pid_t
        package let title: String
        package let layer: Int
        package let alpha: Double

        package init(ownerPID: pid_t, title: String, layer: Int, alpha: Double) {
            self.ownerPID = ownerPID
            self.title = title
            self.layer = layer
            self.alpha = alpha
        }
    }

    package static func processIDs(fromPGrepOutput output: ProcessOutput) -> Set<pid_t> {
        guard output.terminationStatus == 0 else { return [] }
        return Set(
            output.stdout
                .split(whereSeparator: \.isNewline)
                .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    package static func hasReadyWorkspaceWindow(
        xcodeProcessIDs: Set<pid_t>,
        windows: [WindowSnapshot]
    ) -> Bool {
        guard xcodeProcessIDs.isEmpty == false else { return false }
        return windows.contains { window in
            xcodeProcessIDs.contains(window.ownerPID)
                && window.layer == 0
                && window.alpha > 0
                && isReadyWorkspaceTitle(window.title)
        }
    }

    package static func isReady(
        xcodeProcessIDs: Set<pid_t>,
        windows: [WindowSnapshot]?
    ) -> Bool {
        guard xcodeProcessIDs.isEmpty == false else { return false }
        guard let windows else {
            return true
        }
        return hasReadyWorkspaceWindow(xcodeProcessIDs: xcodeProcessIDs, windows: windows)
    }

    package static func visibleWindowSnapshots(xcodeProcessIDs: Set<pid_t>) -> [WindowSnapshot]? {
        guard AXIsProcessTrusted() else {
            return nil
        }
        return accessibilityWindowSnapshots(xcodeProcessIDs: xcodeProcessIDs)
    }

    private static func accessibilityWindowSnapshots(
        xcodeProcessIDs: Set<pid_t>
    ) -> [WindowSnapshot] {
        xcodeProcessIDs.flatMap { processID -> [WindowSnapshot] in
            let app = AXUIElementCreateApplication(processID)
            var rawWindows: CFTypeRef?
            let error = unsafe AXUIElementCopyAttributeValue(
                app,
                kAXWindowsAttribute as CFString,
                &rawWindows
            )
            guard error == .success, let windows = rawWindows as? [AXUIElement] else {
                return []
            }
            return windows.map { window in
                let minimized = accessibilityBoolAttribute(
                    window,
                    attribute: kAXMinimizedAttribute
                ) ?? false
                return WindowSnapshot(
                    ownerPID: processID,
                    title: accessibilityStringAttribute(window, attribute: kAXTitleAttribute) ?? "",
                    layer: 0,
                    alpha: minimized ? 0 : 1
                )
            }
        }
    }

    private static func isReadyWorkspaceTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        guard trimmed.localizedCaseInsensitiveCompare("Welcome to Xcode") != .orderedSame else {
            return false
        }
        return true
    }

    private static func accessibilityStringAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> String? {
        var value: CFTypeRef?
        let error = unsafe AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? String
    }

    private static func accessibilityBoolAttribute(
        _ element: AXUIElement,
        attribute: String
    ) -> Bool? {
        var value: CFTypeRef?
        let error = unsafe AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? Bool
    }
}

package final class UpstreamReadinessWaiterToken: Sendable {
    private let isCancelledBox = NIOLockedValueBox(false)

    package init() {}

    package func cancel() {
        isCancelledBox.withLockedValue { isCancelled in
            isCancelled = true
        }
    }

    package var isCancelled: Bool {
        isCancelledBox.withLockedValue { $0 }
    }
}

package actor UpstreamReadinessCoordinator {
    private struct Waiter: Sendable {
        let reason: String
        let applyBackoff: Bool
        let token: UpstreamReadinessWaiterToken?
        let operation: @Sendable () -> Void

        var isCancelled: Bool {
            token?.isCancelled ?? false
        }
    }

    private let gate: UpstreamReadinessGate
    private let logger: Logger
    private var waiters: [Waiter] = []
    private var waitTask: Task<Void, Never>?
    private var deferredTask: Task<Void, Never>?
    private var isShutdown = false
    private var retryBackoffAttempt = 0

    package init(gate: UpstreamReadinessGate, logger: Logger) {
        self.gate = gate
        self.logger = logger
    }

    package func runWhenReady(
        reason: String,
        applyBackoff: Bool = false,
        token: UpstreamReadinessWaiterToken? = nil,
        operation: @escaping @Sendable () -> Void
    ) {
        guard !isShutdown else { return }
        guard token?.isCancelled != true else { return }
        waiters.append(
            Waiter(
                reason: reason,
                applyBackoff: applyBackoff,
                token: token,
                operation: operation
            )
        )
        guard waitTask == nil, deferredTask == nil else { return }
        startWaitTask()
    }

    package func cancelWaiter(_ token: UpstreamReadinessWaiterToken) {
        token.cancel()
        waiters.removeAll { waiter in
            waiter.token === token
        }
    }

    package func resetBackoff() {
        retryBackoffAttempt = 0
    }

    package func reset() {
        waitTask?.cancel()
        deferredTask?.cancel()
        waitTask = nil
        deferredTask = nil
        waiters.removeAll()
        retryBackoffAttempt = 0
    }

    package func shutdown() {
        isShutdown = true
        waitTask?.cancel()
        deferredTask?.cancel()
        waitTask = nil
        deferredTask = nil
        waiters.removeAll()
    }

    private func startWaitTask() {
        waitTask = Task { [weak self] in
            await self?.waitUntilReady()
        }
    }

    private func waitUntilReady() async {
        var didLogWaiting = false
        var lastUnavailableLaunchUptimeNs: UInt64?
        var didLogRunningWait = false
        var lastProgressLogUptimeNs: UInt64?
        var indicatorIndex = 0
        let indicators = ["exploring.", "exploring..", "exploring..."]

        while Task.isCancelled == false {
            guard !isShutdown else {
                waitTask = nil
                return
            }
            waiters.removeAll { $0.isCancelled }
            guard !waiters.isEmpty else {
                waitTask = nil
                return
            }

            if await gate.isReady() {
                waitTask = nil
                scheduleReadyWaiters(didWait: didLogWaiting)
                return
            }

            let nowUptimeNs = gate.uptimeNanoseconds()
            if didLogWaiting == false {
                logger.info(
                    "Waiting for Xcode before starting mcpbridge",
                    metadata: [
                        "target": .string(gate.targetName)
                    ]
                )
                didLogWaiting = true
                lastProgressLogUptimeNs = nowUptimeNs
            } else if let lastProgress = lastProgressLogUptimeNs,
                      nowUptimeNs &- lastProgress >= gate.progressLogIntervalNanoseconds
            {
                logger.info(
                    "Still waiting for Xcode",
                    metadata: [
                        "target": .string(gate.targetName),
                        "indicator": .string(indicators[indicatorIndex % indicators.count]),
                    ]
                )
                indicatorIndex &+= 1
                lastProgressLogUptimeNs = nowUptimeNs
            }

            let launchState = await updateLaunchStateIfNeeded(
                lastUnavailableLaunchUptimeNs: lastUnavailableLaunchUptimeNs,
                didLogRunningWait: didLogRunningWait,
                nowUptimeNs: nowUptimeNs
            )
            lastUnavailableLaunchUptimeNs = launchState.lastUnavailableLaunchUptimeNs
            didLogRunningWait = launchState.didLogRunningWait

            await gate.sleepNanoseconds(gate.pollIntervalNanoseconds)
        }

        waitTask = nil
    }

    private func updateLaunchStateIfNeeded(
        lastUnavailableLaunchUptimeNs: UInt64?,
        didLogRunningWait: Bool,
        nowUptimeNs: UInt64
    ) async -> (lastUnavailableLaunchUptimeNs: UInt64?, didLogRunningWait: Bool) {
        guard gate.launchIfUnavailable != nil else {
            return (lastUnavailableLaunchUptimeNs, didLogRunningWait)
        }

        let canObserveAvailability = gate.isAvailable != nil
        if let isAvailable = gate.isAvailable, await isAvailable() {
            if didLogRunningWait == false {
                logger.info(
                    "Xcode is running; waiting for an Xcode workspace window before starting mcpbridge",
                    metadata: [
                        "target": .string(gate.targetName)
                    ]
                )
            }
            return (nil, true)
        }

        if let lastLaunch = lastUnavailableLaunchUptimeNs,
           (canObserveAvailability == false
            || nowUptimeNs &- lastLaunch < gate.launchRetryIntervalNanoseconds) {
            return (lastUnavailableLaunchUptimeNs, didLogRunningWait)
        }
        let didLaunch = await launchUnavailableTarget()
        return (didLaunch ? gate.uptimeNanoseconds() : nil, didLogRunningWait)
    }

    private func launchUnavailableTarget() async -> Bool {
        guard let launchIfUnavailable = gate.launchIfUnavailable else { return false }
        logger.info(
            "Xcode is not running; launching Xcode",
            metadata: [
                "target": .string(gate.targetName)
            ]
        )
        if await launchIfUnavailable() {
            logger.info(
                "Launched Xcode; waiting for it to become ready",
                metadata: [
                    "target": .string(gate.targetName)
                ]
            )
            return true
        } else {
            logger.warning(
                "Could not launch Xcode automatically; waiting for Xcode",
                metadata: [
                    "target": .string(gate.targetName)
                ]
            )
            return false
        }
    }

    private func scheduleReadyWaiters(didWait: Bool) {
        guard !isShutdown, !waiters.isEmpty else {
            waiters.removeAll()
            return
        }

        if didWait {
            logger.info(
                "Detected Xcode; starting mcpbridge",
                metadata: [
                    "target": .string(gate.targetName)
                ]
            )
        }

        let shouldBackoff = !didWait && waiters.contains { $0.applyBackoff }
        guard shouldBackoff else {
            fireReadyWaiters()
            return
        }

        let delay = nextRetryBackoffNanoseconds()
        logger.info(
            "Backing off before restarting mcpbridge",
            metadata: [
                "target": .string(gate.targetName),
                "delay_ms": .string("\(delay / 1_000_000)"),
            ]
        )
        deferredTask = Task { [weak self] in
            await self?.sleepThenFireReadyWaiters(delayNanoseconds: delay)
        }
    }

    private func sleepThenFireReadyWaiters(delayNanoseconds: UInt64) async {
        await gate.sleepNanoseconds(delayNanoseconds)
        guard Task.isCancelled == false else { return }
        deferredTask = nil
        guard !isShutdown else {
            waiters.removeAll()
            return
        }
        waiters.removeAll { $0.isCancelled }
        guard !waiters.isEmpty else { return }

        if await gate.isReady() {
            fireReadyWaiters()
        } else {
            startWaitTask()
        }
    }

    private func fireReadyWaiters() {
        guard !isShutdown else {
            waiters.removeAll()
            return
        }
        let readyWaiters = waiters.filter { !$0.isCancelled }
        waiters.removeAll()
        waitTask = nil
        deferredTask = nil
        for waiter in readyWaiters {
            waiter.operation()
        }
    }

    private func nextRetryBackoffNanoseconds() -> UInt64 {
        let shift = min(retryBackoffAttempt, 20)
        let base = gate.initialRetryBackoffNanoseconds
        let delay: UInt64
        if shift >= UInt64.bitWidth || base > UInt64.max >> UInt64(shift) {
            delay = UInt64.max
        } else {
            delay = base << UInt64(shift)
        }
        retryBackoffAttempt &+= 1
        return min(delay, gate.maxRetryBackoffNanoseconds)
    }
}
