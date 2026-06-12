import Foundation
import Logging
import NIOConcurrencyHelpers
import ProxyCore

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
