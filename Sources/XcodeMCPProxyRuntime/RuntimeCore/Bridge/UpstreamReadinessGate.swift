import XcodeMCPKit
import Foundation
import Logging
import NIOConcurrencyHelpers

final class UpstreamReadinessWaiterToken: Sendable {
    private let isCancelledBox = NIOLockedValueBox(false)

    init() {}

    func cancel() {
        isCancelledBox.withLockedValue { isCancelled in
            isCancelled = true
        }
    }

    var isCancelled: Bool {
        isCancelledBox.withLockedValue { $0 }
    }
}

final class UpstreamReadinessCoordinator: Sendable {
    private struct Waiter: Sendable {
        let reason: String
        let applyBackoff: Bool
        let token: UpstreamReadinessWaiterToken?
        let operation: @Sendable () -> Void

        var isCancelled: Bool {
            token?.isCancelled ?? false
        }
    }

    private struct State: Sendable {
        var waiters: [Waiter] = []
        var waitTask: Task<Void, Never>?
        var deferredTask: Task<Void, Never>?
        var isShutdown = false
        var retryBackoffAttempt = 0
        var epoch: UInt64 = 0
    }

    private enum ReadyAction: Sendable {
        case none
        case fire(waiters: [Waiter], epoch: UInt64)
        case deferWaiters(delayNanoseconds: UInt64)
    }

    private let gate: UpstreamReadinessGate
    private let logger: Logger
    private let state = NIOLockedValueBox(State())

    init(gate: UpstreamReadinessGate, logger: Logger) {
        self.gate = gate
        self.logger = logger
    }

    func runWhenReady(
        reason: String,
        applyBackoff: Bool = false,
        token: UpstreamReadinessWaiterToken? = nil,
        operation: @escaping @Sendable () -> Void
    ) {
        let shouldStartWaitTask = state.withLockedValue { state in
            guard !state.isShutdown else { return false }
            guard token?.isCancelled != true else { return false }
            state.waiters.append(
                Waiter(
                    reason: reason,
                    applyBackoff: applyBackoff,
                    token: token,
                    operation: operation
                )
            )
            return state.waitTask == nil && state.deferredTask == nil
        }
        if shouldStartWaitTask {
            startWaitTaskIfNeeded()
        }
    }

    func cancelWaiter(_ token: UpstreamReadinessWaiterToken) {
        token.cancel()
        state.withLockedValue { state in
            state.waiters.removeAll { waiter in
                waiter.token === token
            }
        }
    }

    func resetBackoff() {
        state.withLockedValue { state in
            state.retryBackoffAttempt = 0
        }
    }

    func reset() {
        let tasks = state.withLockedValue { state -> (Task<Void, Never>?, Task<Void, Never>?) in
            let tasks = (state.waitTask, state.deferredTask)
            state.epoch &+= 1
            state.waitTask = nil
            state.deferredTask = nil
            state.waiters.removeAll()
            state.retryBackoffAttempt = 0
            return tasks
        }
        tasks.0?.cancel()
        tasks.1?.cancel()
    }

    func shutdown() {
        let tasks = state.withLockedValue { state -> (Task<Void, Never>?, Task<Void, Never>?) in
            let tasks = (state.waitTask, state.deferredTask)
            state.epoch &+= 1
            state.isShutdown = true
            state.waitTask = nil
            state.deferredTask = nil
            state.waiters.removeAll()
            return tasks
        }
        tasks.0?.cancel()
        tasks.1?.cancel()
    }

    private func startWaitTaskIfNeeded() {
        state.withLockedValue { state in
            guard !state.isShutdown,
                  state.waiters.isEmpty == false,
                  state.waitTask == nil,
                  state.deferredTask == nil
            else {
                return
            }
            let epoch = state.epoch
            state.waitTask = Task { [weak self] in
                await self?.waitUntilReady(epoch: epoch)
            }
        }
    }

    private func waitUntilReady(epoch: UInt64) async {
        var didLogWaiting = false
        var didAttemptLaunch = false

        while Task.isCancelled == false {
            guard pruneCancelledWaitersAndKeepWaiting(epoch: epoch) else { return }

            let snapshot = await gate.snapshot()
            if snapshot.isReady {
                scheduleReadyWaiters(didWait: didLogWaiting, epoch: epoch)
                return
            }

            if didLogWaiting == false {
                logger.info(
                    "Waiting for Xcode before starting mcpbridge",
                    metadata: [
                        "target": .string(gate.targetName)
                    ]
                )
                didLogWaiting = true
            }

            if didAttemptLaunch == false {
                didAttemptLaunch = true
                _ = await launchUnavailableTarget()
            }
            await gate.waitForChange(snapshot.generation)
        }

        clearWaitTask(epoch: epoch)
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

    private func scheduleReadyWaiters(didWait: Bool, epoch: UInt64) {
        let action = state.withLockedValue { state -> ReadyAction in
            guard state.epoch == epoch, !state.isShutdown else { return .none }
            state.waitTask = nil
            state.waiters.removeAll { $0.isCancelled }
            guard state.waiters.isEmpty == false else { return .none }

            let shouldBackoff = !didWait && state.waiters.contains { $0.applyBackoff }
            guard shouldBackoff else {
                let readyWaiters = state.waiters.filter { !$0.isCancelled }
                state.waiters.removeAll()
                state.deferredTask = nil
                return .fire(waiters: readyWaiters, epoch: epoch)
            }

            let delay = Self.nextRetryBackoffNanoseconds(state: &state, gate: gate)
            state.deferredTask = Task { [weak self] in
                await self?.sleepThenFireReadyWaiters(
                    delayNanoseconds: delay,
                    epoch: epoch
                )
            }
            return .deferWaiters(delayNanoseconds: delay)
        }

        if didWait {
            logger.info(
                "Detected Xcode; starting mcpbridge",
                metadata: [
                    "target": .string(gate.targetName)
                ]
            )
        }

        switch action {
        case .none:
            return
        case .fire(let waiters, let epoch):
            fire(waiters: waiters, epoch: epoch)
        case .deferWaiters(let delay):
            logger.debug(
                "Backing off before restarting mcpbridge",
                metadata: [
                    "target": .string(gate.targetName),
                    "delay_ms": .string("\(delay / 1_000_000)"),
                ]
            )
        }
    }

    private func sleepThenFireReadyWaiters(delayNanoseconds: UInt64, epoch: UInt64) async {
        await gate.sleepNanoseconds(delayNanoseconds)
        guard Task.isCancelled == false else { return }
        let shouldContinue = state.withLockedValue { state in
            guard state.epoch == epoch, !state.isShutdown else { return false }
            state.deferredTask = nil
            state.waiters.removeAll { $0.isCancelled }
            return state.waiters.isEmpty == false
        }
        guard shouldContinue else { return }

        if await gate.snapshot().isReady {
            fireReadyWaiters(epoch: epoch)
        } else {
            startWaitTaskIfNeeded()
        }
    }

    private func fireReadyWaiters(epoch: UInt64) {
        let readyWaiters = state.withLockedValue { state -> [Waiter] in
            guard state.epoch == epoch, !state.isShutdown else {
                if state.epoch == epoch {
                    state.waiters.removeAll()
                }
                return []
            }
            let readyWaiters = state.waiters.filter { !$0.isCancelled }
            state.waiters.removeAll()
            state.waitTask = nil
            state.deferredTask = nil
            return readyWaiters
        }
        fire(waiters: readyWaiters, epoch: epoch)
    }

    private func fire(waiters readyWaiters: [Waiter], epoch: UInt64) {
        for waiter in readyWaiters where !waiter.isCancelled {
            let shouldRun = state.withLockedValue { state in
                state.epoch == epoch && !state.isShutdown
            }
            guard shouldRun else { return }
            waiter.operation()
        }
    }

    private func pruneCancelledWaitersAndKeepWaiting(epoch: UInt64) -> Bool {
        state.withLockedValue { state in
            guard state.epoch == epoch, !state.isShutdown else { return false }
            state.waiters.removeAll { $0.isCancelled }
            guard state.waiters.isEmpty == false else {
                state.waitTask = nil
                return false
            }
            return true
        }
    }

    private func clearWaitTask(epoch: UInt64) {
        state.withLockedValue { state in
            if state.epoch == epoch {
                state.waitTask = nil
            }
        }
    }

    private static func nextRetryBackoffNanoseconds(
        state: inout State,
        gate: UpstreamReadinessGate
    ) -> UInt64 {
        let shift = min(state.retryBackoffAttempt, 20)
        let base = gate.initialRetryBackoffNanoseconds
        let delay: UInt64
        if shift >= UInt64.bitWidth || base > UInt64.max >> UInt64(shift) {
            delay = UInt64.max
        } else {
            delay = base << UInt64(shift)
        }
        state.retryBackoffAttempt &+= 1
        return min(delay, gate.maxRetryBackoffNanoseconds)
    }
}
