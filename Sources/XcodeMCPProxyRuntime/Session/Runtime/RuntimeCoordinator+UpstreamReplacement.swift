import XcodeMCPCore

extension RuntimeCoordinator {
    struct InitializeChannelReplacement: Sendable {
        let operationLease: UpstreamOperationLease
    }

    @discardableResult
    func replaceOrRetireInitializeChannel(
        _ initializeClaim: UpstreamHealthManager.InitializeClaim
    ) -> InitializeChannelReplacement? {
        guard let proof = initializeClaim.topologyProof else { return nil }
        return replaceOrRetireInitializeChannel(proof)
    }

    @discardableResult
    func replaceOrRetireInitializeChannel(
        _ proof: UpstreamTopologyProof,
        restart: Bool = true
    ) -> InitializeChannelReplacement? {
        var replacement: InitializeChannelReplacement?
        guard initializeManager.performIfRunning({
            replacement = replaceOrRetireInitializeChannelWhileRunning(proof, restart: restart)
        }) else { return nil }
        return replacement
    }

    private func replaceOrRetireInitializeChannelWhileRunning(
        _ proof: UpstreamTopologyProof,
        restart: Bool
    ) -> InitializeChannelReplacement? {
        if let replacement = nativeUpstreamFactory?() {
            let previousStopCompletion = AsyncTerminalSignal()
            if let transition = commitUpstreamTopologyMutation({
                upstreamTopology.replace(
                    proof,
                    with: replacement,
                    predecessorStopCompletion: previousStopCompletion
                )
            }),
                let previous = transition.replaced?.slot,
                let replacementLease = transition.snapshot.operationLease(proof.slotID) {
                observeUpstreamEvents(replacementLease)
                let replacementProof = replacementLease.proof
                let upstreamTopology = upstreamTopology
                let finishPreviousStop: @Sendable () -> Void = {
                    upstreamTopology.clearPredecessorStopCompletion(
                        previousStopCompletion,
                        for: replacementProof
                    )
                    previousStopCompletion.signal()
                }
                retireUpstreamSlot(previous, onStopped: finishPreviousStop)
                if restart {
                    addRuntimeTask { [weak self, replacementLease] in
                        guard let self,
                              await self.waitUntilUpstreamOperationActivatable(replacementLease),
                              self.initializeManager.snapshot().isShuttingDown == false
                        else { return }
                        self.startUpstreamWarmInitialize(
                            upstreamIndex: replacementLease.upstreamIndex,
                            applyBackoff: true
                        )
                    }
                }
                return InitializeChannelReplacement(
                    operationLease: replacementLease
                )
            }
            retireUpstreamSlot(replacement)
        }
        guard let transition = commitUpstreamTopologyMutation({
            upstreamTopology.retire(proof)
        }) else { return nil }
        for retired in transition.retired {
            retireUpstreamSlot(retired.slot)
        }
        return nil
    }

}
