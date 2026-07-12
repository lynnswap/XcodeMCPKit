import Foundation
import XcodeMCPKit

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
        let snapshot = upstreamTopology.snapshot()
        for entry in snapshot.entries {
            guard let proof = snapshot.proof(entry.id) else { continue }
            addRuntimeTask { [weak self, entry, proof] in
                guard let self, self.upstreamTopology.validate(proof) else { return }
                await entry.slot.start()
            }
        }
    }

    func startPrimaryUpstreamSlot() {
        startUpstreamSlot(0)
    }

    func startUpstreamSlot(_ upstreamIndex: Int) {
        guard let context = upstreamSlotContext(upstreamIndex) else { return }
        addRuntimeTask { [weak self, context] in
            guard let self, self.upstreamTopology.validate(context.proof) else { return }
            let upstream = context.slot
            await upstream.start()
        }
    }

    func noteUpstreamInitializationSucceeded() {
        if prewarmDocumentationProviderOnStartup {
            prewarmDocumentationProvider()
        }
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
        initializeManager.clearPrimaryInitializeReadinessToken(token)
    }

    func cancelPrimaryInitializeReadinessWaiter() {
        let token = primaryInitializeReadinessTokenBox.withLockedValue { current in
            let token = current
            current = nil
            return token
        }
        if let token {
            initializeManager.clearPrimaryInitializeReadinessToken(token)
            cancelUpstreamReadinessWaiter(token)
        }
    }

    func cancelPrimaryInitializeReadinessWaiter(_ token: UpstreamReadinessWaiterToken) {
        primaryInitializeReadinessTokenBox.withLockedValue { current in
            if current === token {
                current = nil
            }
        }
        initializeManager.clearPrimaryInitializeReadinessToken(token)
        cancelUpstreamReadinessWaiter(token)
    }

}
