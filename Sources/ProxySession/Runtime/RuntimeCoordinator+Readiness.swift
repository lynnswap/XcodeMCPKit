import Foundation
import ProxyCore

extension RuntimeCoordinator {
    func runWhenUpstreamReady(
        reason: String,
        applyBackoff: Bool = false,
        token: UpstreamReadinessWaiterToken? = nil,
        operation: @escaping @Sendable () -> Void
    ) {
        guard upstreamReadinessGate.isEnabled else {
            operation()
            return
        }

        let generation = currentUpstreamReadinessGeneration()
        let guardedOperation: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            guard self.currentUpstreamReadinessGeneration() == generation else { return }
            operation()
        }
        Task { [upstreamReadinessCoordinator] in
            await upstreamReadinessCoordinator.runWhenReady(
                reason: reason,
                applyBackoff: applyBackoff,
                token: token,
                operation: guardedOperation
            )
        }
    }

    func cancelUpstreamReadinessWaiter(_ token: UpstreamReadinessWaiterToken) {
        guard upstreamReadinessGate.isEnabled else { return }
        Task { [upstreamReadinessCoordinator] in
            await upstreamReadinessCoordinator.cancelWaiter(token)
        }
    }

    func startAllUpstreamSlots() {
        for upstream in upstreams {
            Task {
                await upstream.start()
            }
        }
    }

    func startPrimaryUpstreamSlot() {
        guard let primary = upstreams.first else { return }
        Task {
            await primary.start()
        }
    }

    func noteUpstreamInitializationSucceeded() {
        guard upstreamReadinessGate.isEnabled else { return }
        Task { [upstreamReadinessCoordinator] in
            await upstreamReadinessCoordinator.resetBackoff()
        }
    }

    func resetUpstreamReadinessWaiters() {
        guard upstreamReadinessGate.isEnabled else { return }
        Task { [upstreamReadinessCoordinator] in
            await upstreamReadinessCoordinator.reset()
        }
    }

    func advanceUpstreamReadinessGeneration() {
        upstreamReadinessGenerationBox.withLockedValue { generation in
            generation &+= 1
        }
    }

    func currentUpstreamReadinessGeneration() -> UInt64 {
        upstreamReadinessGenerationBox.withLockedValue { $0 }
    }

    func replacePrimaryInitializeReadinessWaiter(
        with token: UpstreamReadinessWaiterToken
    ) {
        let previous = primaryInitializeReadinessTokenBox.withLockedValue { current in
            let previous = current
            current = token
            return previous
        }
        if let previous {
            cancelUpstreamReadinessWaiter(previous)
        }
    }

    func clearPrimaryInitializeReadinessWaiter(
        _ token: UpstreamReadinessWaiterToken
    ) {
        primaryInitializeReadinessTokenBox.withLockedValue { current in
            if current === token {
                current = nil
            }
        }
    }

    func cancelPrimaryInitializeReadinessWaiter() {
        let token = primaryInitializeReadinessTokenBox.withLockedValue { current in
            let token = current
            current = nil
            return token
        }
        if let token {
            cancelUpstreamReadinessWaiter(token)
        }
    }

}
