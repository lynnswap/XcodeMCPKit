import Foundation
import XcodeMCPKit
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
            addRuntimeTask { [upstream] in
                await upstream.start()
            }
        }
    }

    func startPrimaryUpstreamSlot() {
        startUpstreamSlot(0)
    }

    func startUpstreamSlot(_ upstreamIndex: Int) {
        guard upstreamIndex >= 0, upstreamIndex < upstreams.count else { return }
        let upstream = upstreams[upstreamIndex]
        addRuntimeTask { [upstream] in
            await upstream.start()
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
