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

        upstreamReadinessCoordinator.runWhenReady(
            reason: reason,
            applyBackoff: applyBackoff,
            token: token,
            operation: operation
        )
    }

    func cancelUpstreamReadinessWaiter(_ token: UpstreamReadinessWaiterToken) {
        guard upstreamReadinessGate.isEnabled else { return }
        upstreamReadinessCoordinator.cancelWaiter(token)
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
        upstreamReadinessCoordinator.resetBackoff()
    }

    func resetUpstreamReadinessWaiters() {
        guard upstreamReadinessGate.isEnabled else { return }
        upstreamReadinessCoordinator.reset()
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
