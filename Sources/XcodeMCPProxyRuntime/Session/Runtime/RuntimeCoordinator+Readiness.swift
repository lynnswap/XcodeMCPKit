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
            startUpstreamSlot(entry.operationLease)
        }
    }

    func startPrimaryUpstreamSlot() {
        startUpstreamSlot(0)
    }

    func startUpstreamSlot(_ upstreamIndex: Int) {
        guard let operationLease = upstreamTopology.operationLease(
            for: UpstreamSlotID(rawValue: upstreamIndex)
        ) else { return }
        startUpstreamSlot(operationLease)
    }

    private func startUpstreamSlot(_ operationLease: UpstreamOperationLease) {
        addRuntimeTask { [weak self, operationLease] in
            guard let self,
                  await self.waitUntilUpstreamOperationActivatable(operationLease)
            else { return }
            await operationLease.slot.start()
        }
    }

    func retireUpstreamSlot(
        _ slot: any UpstreamSlotControlling,
        onStopped: @escaping @Sendable () -> Void = {}
    ) {
        let retirement: @Sendable () async -> Void = {
            await slot.stop()
            onStopped()
        }
        if upstreamRetirementTasks.run(retirement) == false {
            Task.detached(operation: retirement)
        }
    }

    func waitUntilUpstreamOperationActivatable(
        _ operationLease: UpstreamOperationLease
    ) async -> Bool {
        if let completion = operationLease.predecessorStopCompletion {
            await completion.wait()
        }
        guard Task.isCancelled == false else { return false }
        return upstreamTopology.validate(operationLease)
    }

    func deferInitializeUntilUpstreamActivatable(
        _ operationLease: UpstreamOperationLease,
        resume: @escaping @Sendable () -> Void
    ) -> Bool {
        guard operationLease.predecessorStopCompletion != nil else { return false }
        addRuntimeTask { [weak self, operationLease] in
            guard let self,
                  await self.waitUntilUpstreamOperationActivatable(operationLease),
                  self.initializeManager.snapshot().isShuttingDown == false
            else { return }
            resume()
        }
        return true
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
