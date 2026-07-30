import Foundation
import NIO
import NIOConcurrencyHelpers
import Testing
import XcodeMCPKit
import XcodeMCPProxyTestSupport
@testable import XcodeMCPProxyRuntime

func testTopologyProof(_ upstreamIndex: Int, generation: UInt64 = 1) -> UpstreamTopologyProof {
    UpstreamTopologyProof(
        slotID: UpstreamSlotID(rawValue: upstreamIndex),
        slotGeneration: generation
    )
}

func testOperationLease(_ upstreamIndex: Int, generation: UInt64 = 1) -> UpstreamOperationLease {
    UpstreamOperationLease(
        proof: testTopologyProof(upstreamIndex, generation: generation),
        slot: TestUpstreamClient()
    )
}

@Suite(.serialized, .asyncTestCleanup)
struct ControlPlaneAuthorityTests {
    @Test func catalogCommitPublishesProcessAndCanonicalStateAtomically() throws {
        let target = xcodeProcessTarget(processID: 41001, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: testTopologyProof(0),
            nowUptimeNanoseconds: 1
        ))

        let commit = authority.completeCatalog(
            .usable(catalog("BuildProject"), source: testTopologyProof(0)),
            lease: lease,
            nowUptimeNanoseconds: 2
        )

        guard case .accepted(let snapshot, _) = commit else {
            Issue.record("expected catalog commit to be accepted")
            return
        }
        #expect(snapshot.catalogProcessIDs == [target.processID])
        #expect(snapshot.canonicalToolsCatalogRaw != nil)
        #expect(snapshot.canonicalSourceUpstream == 0)
    }

    @Test func bridgeRecoveryBeginsBeforeCatalogAndUsesProcessOwnerEffect() throws {
        let target = xcodeProcessTarget(processID: 41031, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1])])
        let route = try #require(authority.route(forProcessID: target.processID))

        let bootstrap = authority.beginBridgePoolRecovery(routeID: route.id)
        guard case .restoreBridgePool(let bootstrapRecovery) = bootstrap.effects.first else {
            Issue.record("expected catalog bootstrap bridge recovery")
            return
        }
        #expect(bootstrapRecovery.routeID == route.id)
        #expect(bootstrapRecovery.upstreamID == UpstreamSlotID(rawValue: 1))
        #expect(authority.beginBridgePoolRecovery(routeID: route.id).effects.isEmpty)

        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: testTopologyProof(0),
            nowUptimeNanoseconds: 1
        ))
        guard case .accepted(_, let catalogTransition) = authority.completeCatalog(
            .usable(catalog("BuildProject"), source: testTopologyProof(0)),
            lease: lease,
            nowUptimeNanoseconds: 2
        ) else {
            Issue.record("expected sibling catalog to be accepted")
            return
        }
        #expect(catalogTransition.effects.isEmpty)

        let duplicate = authority.requestBridgePoolRecovery(
            routeID: route.id,
            upstreamID: UpstreamSlotID(rawValue: 1)
        )
        #expect(duplicate.effects.isEmpty)

        let completed = authority.completeBridgeRecovery(bootstrapRecovery)
        #expect(completed.effects.isEmpty)

        let immediate = authority.requestBridgePoolRecovery(
            routeID: route.id,
            upstreamID: UpstreamSlotID(rawValue: 1)
        )
        let immediateEffect = try #require(immediate.effects.first { effect in
            if case .restoreBridgePool = effect { return true }
            return false
        })
        guard case .restoreBridgePool(let immediateRecovery) = immediateEffect else {
            Issue.record("expected immediate bridge recovery effect")
            return
        }
        #expect(immediateRecovery.routeID == route.id)
        #expect(immediateRecovery.upstreamID == UpstreamSlotID(rawValue: 1))
    }

    @Test func bridgeRecoveryCompletionKeepsReservationWhenCommitIsRejected() throws {
        let target = xcodeProcessTarget(processID: 41040, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1])])
        let route = try #require(authority.route(forProcessID: target.processID))
        guard case .restoreBridgePool(let recovery) = authority
            .beginBridgePoolRecovery(routeID: route.id).effects.first else {
            Issue.record("expected bridge recovery reservation")
            return
        }

        #expect(
            authority.completeBridgeRecoveryIfCurrent(
                recovery,
                commit: { false }
            ) == nil
        )
        #expect(authority.validateBridgeRecovery(recovery))
        #expect(authority.completeBridgeRecoveryIfCurrent(recovery) != nil)
    }

    @Test func bridgeRecoverySerializesSlotsAndOwnsRetryCadence() throws {
        let target = xcodeProcessTarget(processID: 41032, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1, 2])])
        let route = try #require(authority.route(forProcessID: target.processID))
        guard case .restoreBridgePool(let firstAttempt) = authority
            .beginBridgePoolRecovery(routeID: route.id).effects.first else {
            Issue.record("expected first serialized bootstrap recovery")
            return
        }
        #expect(firstAttempt.upstreamID == UpstreamSlotID(rawValue: 1))

        let firstRetry = try #require(authority.prepareBridgeRecoveryRetry(
            firstAttempt,
            failure: .other
        ))
        #expect(firstRetry.delay.nanoseconds == TimeAmount.seconds(1).nanoseconds)
        #expect(firstRetry.consecutiveFailureCount == 1)
        #expect(firstRetry.shouldLogToolsUnavailableWarning == false)
        guard case .restoreBridgePool(let secondAttempt) = authority
            .handleBridgeRecoveryRetryFired(firstRetry.reservation).effects.first else {
            Issue.record("expected early bridge recovery retry")
            return
        }
        #expect(secondAttempt.upstreamID == firstAttempt.upstreamID)
        #expect(secondAttempt != firstAttempt)

        let cancelled = NIOLockedValueBox(false)
        let staleTimeout = RuntimeScheduledTimeout {
            cancelled.withLockedValue { $0 = true }
        }
        let staleAttachment = authority.attachBridgeRecoveryRetryTimeout(
            staleTimeout,
            to: firstRetry.reservation
        )
        guard case .cancelTimeout(let rejectedTimeout) = staleAttachment.effects.first else {
            Issue.record("expected stale retry timeout cancellation")
            return
        }
        rejectedTimeout.cancel()
        #expect(cancelled.withLockedValue { $0 })
        #expect(authority.handleBridgeRecoveryRetryFired(firstRetry.reservation).effects.isEmpty)

        let periodicRetry = try #require(authority.prepareBridgeRecoveryRetry(
            secondAttempt,
            failure: .toolsListTimeout
        ))
        #expect(periodicRetry.delay.nanoseconds == TimeAmount.seconds(10).nanoseconds)
        #expect(periodicRetry.consecutiveFailureCount == 2)
        #expect(periodicRetry.shouldLogToolsUnavailableWarning)
        guard case .restoreBridgePool(let thirdAttempt) = authority
            .handleBridgeRecoveryRetryFired(periodicRetry.reservation).effects.first else {
            Issue.record("expected periodic bridge recovery retry")
            return
        }
        let repeatedTimeoutRetry = try #require(authority.prepareBridgeRecoveryRetry(
            thirdAttempt,
            failure: .toolsListTimeout
        ))
        #expect(repeatedTimeoutRetry.shouldLogToolsUnavailableWarning == false)
        guard case .restoreBridgePool(let recoveredAttempt) = authority
            .handleBridgeRecoveryRetryFired(repeatedTimeoutRetry.reservation).effects.first else {
            Issue.record("expected repeated timeout recovery retry")
            return
        }
        guard case .restoreBridgePool(let nextSlot) = authority
            .completeBridgeRecovery(recoveredAttempt).effects.first else {
            Issue.record("expected next serialized bridge slot")
            return
        }
        #expect(nextSlot.upstreamID == UpstreamSlotID(rawValue: 2))
        let resetRetry = try #require(authority.prepareBridgeRecoveryRetry(
            nextSlot,
            failure: .toolsListTimeout
        ))
        #expect(resetRetry.delay.nanoseconds == TimeAmount.seconds(1).nanoseconds)
        #expect(resetRetry.consecutiveFailureCount == 1)
        #expect(resetRetry.shouldLogToolsUnavailableWarning)
    }

    @Test func bridgeRecoveryRetryContinuesWhenCatalogDisappears() throws {
        let target = xcodeProcessTarget(processID: 41034, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let sourceProof = testTopologyProof(0)
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: sourceProof,
            nowUptimeNanoseconds: 1
        ))
        guard case .accepted(_, let catalogTransition) = authority.completeCatalog(
            .usable(catalog("BuildProject"), source: sourceProof),
            lease: lease,
            nowUptimeNanoseconds: 2
        ), case .restoreBridgePool(let firstAttempt) = catalogTransition.effects.first else {
            Issue.record("expected bridge recovery after catalog commit")
            return
        }
        let retry = try #require(authority.prepareBridgeRecoveryRetry(
            firstAttempt,
            failure: .other
        ))

        _ = authority.invalidateCatalogSource(
            processID: target.processID,
            source: sourceProof
        )
        #expect(authority.catalog(forProcessID: target.processID) == nil)
        guard case .restoreBridgePool(let resumedAttempt) = authority
            .handleBridgeRecoveryRetryFired(retry.reservation).effects.first else {
            Issue.record("expected bridge recovery to continue without a catalog")
            return
        }
        #expect(resumedAttempt.upstreamID == firstAttempt.upstreamID)
        let periodicRetry = try #require(authority.prepareBridgeRecoveryRetry(
            resumedAttempt,
            failure: .other
        ))
        #expect(periodicRetry.delay.nanoseconds == TimeAmount.seconds(10).nanoseconds)
    }

    @Test func rejectedCancellationReplacesFailedAttemptWithFreshActivation() throws {
        let target = xcodeProcessTarget(processID: 41041, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let failedProof = testTopologyProof(0)
        let replacementProof = testTopologyProof(0, generation: 2)
        let (failedLease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: failedProof,
            nowUptimeNanoseconds: 1
        ))
        let failedRPC = ControlPlane.RPCHandle()
        _ = authority.attach(.rpc(failedRPC), to: failedLease)

        let result = try #require(authority.recoverAfterRejectedCancellation(
            routeID: route.id,
            failedProof: failedProof,
            replacementProof: replacementProof,
            rejectedBridgeRecovery: nil,
            nowUptimeNs: 2
        ))

        guard case .freshActivation(let activation, let retry, let transition) = result else {
            Issue.record("expected a fresh activation on the replacement proof")
            return
        }
        #expect(activation.upstreamProof == replacementProof)
        #expect(retry.delay == .milliseconds(250))
        let attempt = try #require(authority.attemptSnapshot(processID: target.processID))
        #expect(attempt.attemptID == activation.attemptID)
        #expect(attempt.upstreamProof == replacementProof)
        #expect(attempt.phase == .backoff)
        for effect in transition.effects {
            if case .cancelRPC(let handle) = effect {
                handle.cancel()
            }
        }
        #expect(failedRPC.isCancelled())
    }

    @Test func rejectedCancellationPreservesSiblingAttemptAndQueuesReplacementRecovery() throws {
        let target = xcodeProcessTarget(processID: 41042, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let failedProof = testTopologyProof(0)
        let replacementProof = testTopologyProof(0, generation: 2)
        let siblingProof = testTopologyProof(1)
        let (siblingLease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: siblingProof,
            nowUptimeNanoseconds: 1
        ))

        let result = try #require(authority.recoverAfterRejectedCancellation(
            routeID: route.id,
            failedProof: failedProof,
            replacementProof: replacementProof,
            rejectedBridgeRecovery: nil,
            nowUptimeNs: 2
        ))

        guard case .preserved(let transition) = result,
              case .restoreBridgePool(let recovery) = transition.effects.first else {
            Issue.record("expected the replacement slot to enter bridge recovery")
            return
        }
        #expect(recovery.routeID == route.id)
        #expect(recovery.upstreamID == replacementProof.slotID)
        let attempt = try #require(authority.attemptSnapshot(processID: target.processID))
        #expect(attempt.attemptID.rawValue == siblingLease.attempt)
        #expect(attempt.upstreamProof == siblingProof)
        #expect(attempt.phase == .loadingCatalog)
    }

    @Test func rejectedCancellationPreservesAttemptAlreadyUsingReplacementProof() throws {
        let target = xcodeProcessTarget(processID: 41043, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let failedProof = testTopologyProof(0)
        let replacementProof = testTopologyProof(0, generation: 2)
        let (replacementLease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: replacementProof,
            nowUptimeNanoseconds: 1
        ))

        let result = try #require(authority.recoverAfterRejectedCancellation(
            routeID: route.id,
            failedProof: failedProof,
            replacementProof: replacementProof,
            rejectedBridgeRecovery: nil,
            nowUptimeNs: 2
        ))

        guard case .preserved(let transition) = result else {
            Issue.record("expected replacement-proof attempt to survive")
            return
        }
        #expect(transition.effects.isEmpty)
        let attempt = try #require(authority.attemptSnapshot(processID: target.processID))
        #expect(attempt.attemptID.rawValue == replacementLease.attempt)
        #expect(attempt.upstreamProof == replacementProof)
        guard case .restoreBridgePool(let pendingSibling) = authority
            .beginBridgePoolRecovery(routeID: route.id).effects.first else {
            Issue.record("expected only the configured sibling to remain pending")
            return
        }
        #expect(pendingSibling.upstreamID == UpstreamSlotID(rawValue: 1))
    }

    @Test func staleRejectedCancellationPreservesNewerSameSlotOwners() throws {
        let attemptTarget = xcodeProcessTarget(processID: 41048, xcodeVersion: "27.0")
        let attemptAuthority = makeAuthority([(attemptTarget, [0])])
        let attemptRoute = try #require(
            attemptAuthority.route(forProcessID: attemptTarget.processID)
        )
        let newerProof = testTopologyProof(0, generation: 3)
        let (newerLease, _) = try #require(attemptAuthority.beginCatalogAttempt(
            routeID: attemptRoute.id,
            preferredUpstreamProof: newerProof,
            nowUptimeNanoseconds: 1
        ))
        let attemptResult = try #require(attemptAuthority.recoverAfterRejectedCancellation(
            routeID: attemptRoute.id,
            failedProof: testTopologyProof(0),
            replacementProof: testTopologyProof(0, generation: 2),
            rejectedBridgeRecovery: nil,
            nowUptimeNs: 2
        ))
        guard case .preserved(let attemptTransition) = attemptResult else {
            Issue.record("expected the newer same-slot attempt to survive")
            return
        }
        #expect(attemptTransition.effects.isEmpty)
        #expect(
            attemptAuthority.attemptSnapshot(processID: attemptTarget.processID)?
                .attemptID.rawValue == newerLease.attempt
        )

        let catalogTarget = xcodeProcessTarget(processID: 41049, xcodeVersion: "27.0")
        let catalogAuthority = makeAuthority([(catalogTarget, [0])])
        let catalogRoute = try #require(
            catalogAuthority.route(forProcessID: catalogTarget.processID)
        )
        let (catalogLease, _) = try #require(catalogAuthority.beginCatalogAttempt(
            routeID: catalogRoute.id,
            preferredUpstreamProof: newerProof,
            nowUptimeNanoseconds: 1
        ))
        guard case .accepted = catalogAuthority.completeCatalog(
            .usable(catalog("NewerTool"), source: newerProof),
            lease: catalogLease,
            nowUptimeNanoseconds: 2
        ) else {
            Issue.record("expected newer catalog")
            return
        }
        let catalogResult = try #require(catalogAuthority.recoverAfterRejectedCancellation(
            routeID: catalogRoute.id,
            failedProof: testTopologyProof(0),
            replacementProof: testTopologyProof(0, generation: 2),
            rejectedBridgeRecovery: nil,
            nowUptimeNs: 3
        ))
        guard case .preserved(let catalogTransition) = catalogResult else {
            Issue.record("expected the newer same-slot catalog to survive")
            return
        }
        #expect(catalogTransition.effects.isEmpty)
        #expect(
            catalogAuthority.catalog(forProcessID: catalogTarget.processID)?
                .upstreamProof == newerProof
        )
    }

    @Test func rejectedCancellationPreservesCatalogAndSerializesReplacementRecovery() throws {
        let target = xcodeProcessTarget(processID: 41044, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let sourceProof = testTopologyProof(1)
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: sourceProof,
            nowUptimeNanoseconds: 1
        ))
        guard case .accepted(_, let catalogTransition) = authority.completeCatalog(
            .usable(catalog("BuildProject"), source: sourceProof),
            lease: lease,
            nowUptimeNanoseconds: 2
        ), case .restoreBridgePool(let existingRecovery) = catalogTransition.effects.first else {
            Issue.record("expected the existing sibling recovery")
            return
        }

        let replacementProof = testTopologyProof(0, generation: 2)
        let result = try #require(authority.recoverAfterRejectedCancellation(
            routeID: route.id,
            failedProof: testTopologyProof(0),
            replacementProof: replacementProof,
            rejectedBridgeRecovery: nil,
            nowUptimeNs: 3
        ))

        guard case .preserved(let transition) = result else {
            Issue.record("expected the usable catalog to survive")
            return
        }
        #expect(transition.effects.isEmpty)
        #expect(authority.catalog(forProcessID: target.processID)?.upstreamProof == sourceProof)
        guard case .restoreBridgePool(let replacementRecovery) = authority
            .completeBridgeRecovery(existingRecovery).effects.first else {
            Issue.record("expected serialized recovery of the replacement slot")
            return
        }
        #expect(replacementRecovery.upstreamID == replacementProof.slotID)
    }

    @Test func rejectedBridgeCancellationAtomicallyBecomesRetry() throws {
        let target = xcodeProcessTarget(processID: 41045, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1])])
        let route = try #require(authority.route(forProcessID: target.processID))
        guard case .restoreBridgePool(let rejectedRecovery) = authority
            .beginBridgePoolRecovery(routeID: route.id).effects.first else {
            Issue.record("expected bridge recovery reservation")
            return
        }

        let result = try #require(authority.recoverAfterRejectedCancellation(
            routeID: route.id,
            failedProof: testTopologyProof(1),
            replacementProof: testTopologyProof(1, generation: 2),
            rejectedBridgeRecovery: rejectedRecovery,
            nowUptimeNs: 1
        ))

        guard case .bridgeRecovery(let retry) = result else {
            Issue.record("expected the rejected reservation to enter retry")
            return
        }
        #expect(retry.reservation == rejectedRecovery)
        #expect(retry.delay == .seconds(1))
        #expect(authority.attemptSnapshot(processID: target.processID) == nil)
        #expect(authority.prepareBridgeRecoveryRetry(
            rejectedRecovery,
            failure: .other
        ) == nil)
        guard case .restoreBridgePool(let retried) = authority
            .handleBridgeRecoveryRetryFired(retry.reservation).effects.first else {
            Issue.record("expected the atomic retry to remain schedulable")
            return
        }
        #expect(retried.upstreamID == rejectedRecovery.upstreamID)
        #expect(retried != rejectedRecovery)
    }

    @Test func staleRejectedBridgeCancellationPreservesNewerRecoveryState() throws {
        let target = xcodeProcessTarget(processID: 41046, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1])])
        let route = try #require(authority.route(forProcessID: target.processID))
        guard case .restoreBridgePool(let staleRecovery) = authority
            .beginBridgePoolRecovery(routeID: route.id).effects.first else {
            Issue.record("expected initial bridge recovery")
            return
        }
        let staleRetry = try #require(authority.prepareBridgeRecoveryRetry(
            staleRecovery,
            failure: .other
        ))
        guard case .restoreBridgePool(let currentRecovery) = authority
            .handleBridgeRecoveryRetryFired(staleRetry.reservation).effects.first else {
            Issue.record("expected a newer bridge recovery")
            return
        }

        let attemptingResult = try #require(authority.recoverAfterRejectedCancellation(
            routeID: route.id,
            failedProof: testTopologyProof(1),
            replacementProof: testTopologyProof(1, generation: 2),
            rejectedBridgeRecovery: staleRecovery,
            nowUptimeNs: 1
        ))
        guard case .preserved(let attemptingTransition) = attemptingResult else {
            Issue.record("expected newer attempting recovery to survive")
            return
        }
        #expect(attemptingTransition.effects.isEmpty)
        #expect(authority.validateBridgeRecovery(currentRecovery))

        let currentRetry = try #require(authority.prepareBridgeRecoveryRetry(
            currentRecovery,
            failure: .other
        ))
        let waitingResult = try #require(authority.recoverAfterRejectedCancellation(
            routeID: route.id,
            failedProof: testTopologyProof(1),
            replacementProof: testTopologyProof(1, generation: 2),
            rejectedBridgeRecovery: staleRecovery,
            nowUptimeNs: 2
        ))
        guard case .preserved(let waitingTransition) = waitingResult else {
            Issue.record("expected newer waiting recovery to survive")
            return
        }
        #expect(waitingTransition.effects.isEmpty)
        guard case .restoreBridgePool(let resumed) = authority
            .handleBridgeRecoveryRetryFired(currentRetry.reservation).effects.first else {
            Issue.record("expected preserved waiting recovery to resume")
            return
        }
        #expect(resumed.upstreamID == currentRecovery.upstreamID)
        #expect(authority.attemptSnapshot(processID: target.processID) == nil)
    }

    @Test func staleRejectedBridgeEvidenceFallsThroughAfterRecoveryCompleted() throws {
        let target = xcodeProcessTarget(processID: 41047, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1])])
        let route = try #require(authority.route(forProcessID: target.processID))
        guard case .restoreBridgePool(let completedRecovery) = authority
            .beginBridgePoolRecovery(routeID: route.id).effects.first else {
            Issue.record("expected bridge recovery")
            return
        }
        _ = authority.completeBridgeRecovery(completedRecovery)
        let replacementProof = testTopologyProof(1, generation: 2)

        let result = try #require(authority.recoverAfterRejectedCancellation(
            routeID: route.id,
            failedProof: testTopologyProof(1),
            replacementProof: replacementProof,
            rejectedBridgeRecovery: completedRecovery,
            nowUptimeNs: 1
        ))

        guard case .freshActivation(let activation, _, _) = result else {
            Issue.record("expected stale evidence to fall through to route activation")
            return
        }
        #expect(activation.upstreamProof == replacementProof)
    }

    @Test func bridgeVerificationIsNotUsableUntilExactProbeSucceeds() throws {
        let target = xcodeProcessTarget(processID: 41035, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: testTopologyProof(0),
            nowUptimeNanoseconds: 1
        ))
        guard case .accepted(_, let catalogTransition) = authority.completeCatalog(
            .usable(catalog("BuildProject"), source: testTopologyProof(0)),
            lease: lease,
            nowUptimeNanoseconds: 2
        ), case .restoreBridgePool(let reservation) = catalogTransition.effects.first else {
            Issue.record("expected bridge recovery reservation")
            return
        }

        let topology = UpstreamTopologyAuthority([
            TestUpstreamClient(), TestUpstreamClient(),
        ])
        let health = UpstreamHealthManager()
        health.applyTopology(topology.snapshot())
        let proof = try #require(
            topology.operationLease(for: reservation.upstreamID)?.proof
        )
        let recovery = ProcessBridgeRecovery(
            reservation: reservation,
            topologyProof: proof
        )
        let claim = try #require(health.claimWarmInitialize(
            upstreamIndex: reservation.upstreamID.rawValue,
            owner: .processBridgeRecovery(recovery)
        ))
        #expect(health.setWarmInitializeUpstreamID(42, for: claim))
        #expect(health.beginInitializeSend(claim))
        #expect(health.transferInitializeResponse(claim, expectedUpstreamID: 42))
        let canonical = CanonicalHandshakeState()
        let participant: CanonicalHandshakeState.InitializeParticipantLease
        switch canonical.offerInitializeResult(
            try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
            ]),
            sourceProof: proof
        ) {
        case .accepted(let lease):
            participant = lease
        case .incompatible:
            Issue.record("expected initialize participant")
            return
        }
        let verification = try #require(health.beginBridgeAttachVerification(
            claim,
            expectedUpstreamID: 42,
            initializeParticipant: participant
        ))
        let probe = verification.probe

        #expect(health.evaluateUsableInitialized(index: 1, nowUptimeNs: 3).proof == nil)
        #expect(health.markUpstreamOverloaded(proof))
        #expect(health.state(for: proof.slotID)?.healthProbeInFlight == true)
        _ = health.markRequestTimedOut(proof, nowUptimeNs: 3)
        _ = health.markRequestTimedOut(proof, nowUptimeNs: 3)
        _ = health.markRequestTimedOut(proof, nowUptimeNs: 3)
        #expect(health.state(for: proof.slotID)?.healthProbeInFlight == true)
        _ = try #require(health.markToolsListRefreshFailed(proof, nowUptimeNs: 3))
        #expect(health.state(for: proof.slotID)?.healthProbeInFlight == true)
        #expect(health.markToolsListRefreshSucceeded(proof, nowUptimeNs: 3))
        #expect(health.state(for: proof.slotID)?.healthProbeInFlight == true)
        _ = try #require(health.finishBridgeAttachVerification(
            probe,
            success: true,
            nowUptimeNs: 4,
            commit: {
                authority.completeBridgeRecoveryIfCurrent(
                    reservation,
                    commit: {
                        canonical.commitInitializeParticipant(participant).isAccepted
                    }
                ) != nil
            }
        ))
        #expect(health.evaluateUsableInitialized(index: 1, nowUptimeNs: 5).proof == proof)
    }

    @Test func bridgeVerificationCannotBecomeUsableAfterCatalogResetAtCommit() throws {
        let target = xcodeProcessTarget(processID: 41039, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let sourceProof = testTopologyProof(0)
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: sourceProof,
            nowUptimeNanoseconds: 1
        ))
        guard case .accepted(_, let catalogTransition) = authority.completeCatalog(
            .usable(catalog("BuildProject"), source: sourceProof),
            lease: lease,
            nowUptimeNanoseconds: 2
        ), case .restoreBridgePool(let reservation) = catalogTransition.effects.first else {
            Issue.record("expected bridge recovery reservation")
            return
        }

        let topology = UpstreamTopologyAuthority([
            TestUpstreamClient(), TestUpstreamClient(),
        ])
        let health = UpstreamHealthManager()
        health.applyTopology(topology.snapshot())
        let proof = try #require(
            topology.operationLease(for: reservation.upstreamID)?.proof
        )
        let recovery = ProcessBridgeRecovery(
            reservation: reservation,
            topologyProof: proof
        )
        let claim = try #require(health.claimWarmInitialize(
            upstreamIndex: reservation.upstreamID.rawValue,
            owner: .processBridgeRecovery(recovery)
        ))
        #expect(health.setWarmInitializeUpstreamID(42, for: claim))
        #expect(health.beginInitializeSend(claim))
        #expect(health.transferInitializeResponse(claim, expectedUpstreamID: 42))
        let canonical = CanonicalHandshakeState()
        let participant: CanonicalHandshakeState.InitializeParticipantLease
        switch canonical.offerInitializeResult(
            try jsonValue([
                "protocolVersion": MCP.ProtocolVersion.current,
                "capabilities": [String: Any](),
            ]),
            sourceProof: proof
        ) {
        case .accepted(let lease):
            participant = lease
        case .incompatible:
            Issue.record("expected initialize participant")
            return
        }
        let verification = try #require(health.beginBridgeAttachVerification(
            claim,
            expectedUpstreamID: 42,
            initializeParticipant: participant
        ))
        let probe = verification.probe

        let result = health.finishBridgeAttachVerification(
            probe,
            success: true,
            nowUptimeNs: 3,
            commit: {
                _ = authority.invalidateCatalog(.reset)
                return authority.completeBridgeRecoveryIfCurrent(reservation) != nil
            }
        )

        #expect(result == nil)
        #expect(authority.validateBridgeRecovery(reservation) == false)
        #expect(health.evaluateUsableInitialized(index: 1, nowUptimeNs: 4).proof == nil)
        #expect(
            health.state(for: proof.slotID)?.initPhase
                == .initialized(.verifyingBridge(route.id))
        )
    }

    @Test func bridgeRecoverySuccessStartsNextSlotWithoutCatalog() throws {
        let target = xcodeProcessTarget(processID: 41036, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1, 2])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let sourceProof = testTopologyProof(0)
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: sourceProof,
            nowUptimeNanoseconds: 1
        ))
        guard case .accepted(_, let catalogTransition) = authority.completeCatalog(
            .usable(catalog("BuildProject"), source: sourceProof),
            lease: lease,
            nowUptimeNanoseconds: 2
        ), case .restoreBridgePool(let firstAttempt) = catalogTransition.effects.first else {
            Issue.record("expected first bridge recovery")
            return
        }

        _ = authority.invalidateCatalogSource(
            processID: target.processID,
            source: sourceProof
        )
        guard case .restoreBridgePool(let nextAttempt) = authority
            .completeBridgeRecovery(firstAttempt).effects.first else {
            Issue.record("expected successful recovery to release the next bridge slot")
            return
        }
        #expect(nextAttempt.upstreamID == UpstreamSlotID(rawValue: 2))

        let replacementProof = testTopologyProof(0, generation: 2)
        let (replacementLease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: replacementProof,
            nowUptimeNanoseconds: 3
        ))
        guard case .accepted(_, let resumedTransition) = authority.completeCatalog(
            .usable(catalog("BuildProject"), source: replacementProof),
            lease: replacementLease,
            nowUptimeNanoseconds: 4
        ) else {
            Issue.record("expected restored catalog commit")
            return
        }
        #expect(resumedTransition.effects.isEmpty)
    }

    @Test func retiringRouteCancelsBridgeRecoveryRetryAndRejectsLateCallback() throws {
        let target = xcodeProcessTarget(processID: 41033, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: testTopologyProof(0),
            nowUptimeNanoseconds: 1
        ))
        guard case .accepted(_, let catalogTransition) = authority.completeCatalog(
            .usable(catalog("BuildProject"), source: testTopologyProof(0)),
            lease: lease,
            nowUptimeNanoseconds: 2
        ), case .restoreBridgePool(let recovery) = catalogTransition.effects.first else {
            Issue.record("expected bridge recovery")
            return
        }
        let retry = try #require(authority.prepareBridgeRecoveryRetry(
            recovery,
            failure: .other
        ))
        let cancelled = NIOLockedValueBox(false)
        let timeout = RuntimeScheduledTimeout {
            cancelled.withLockedValue { $0 = true }
        }
        #expect(authority.attachBridgeRecoveryRetryTimeout(
            timeout,
            to: retry.reservation
        ).effects.isEmpty)

        let retired = authority.retireRoute(
            routeID: route.id,
            reason: "test_retire",
            nowUptimeNs: 3
        )
        for effect in retired.effects {
            if case .cancelTimeout(let cancelledTimeout) = effect {
                cancelledTimeout.cancel()
            }
        }
        #expect(cancelled.withLockedValue { $0 })
        #expect(authority.handleBridgeRecoveryRetryFired(retry.reservation).effects.isEmpty)
    }

    @Test func routeMembershipChangeInvalidatesLeaseAndCatalogTogether() throws {
        let target = xcodeProcessTarget(processID: 41002, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let initialEpoch = authority.currentCatalogEpoch()
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: testTopologyProof(0),
            nowUptimeNanoseconds: 1
        ))

        _ = authority.reconcileRoutes(
            [XcodeProcessRoute(target: target, upstreamIndices: [1])],
            reason: "membership_changed",
            nowUptimeNs: 2,
            usability: usability([1])
        )

        let replacement = try #require(authority.route(forProcessID: target.processID))
        #expect(replacement.id != route.id)
        #expect(authority.currentCatalogEpoch() == initialEpoch)
        guard case .discarded(let reason, _) = authority.completeCatalog(
            .usable(catalog("StaleTool"), source: testTopologyProof(0)),
            lease: lease,
            nowUptimeNanoseconds: 3
        ) else {
            Issue.record("expected old membership lease to be discarded")
            return
        }
        #expect(reason == .routeRetired)
        #expect(authority.catalog(forProcessID: target.processID) == nil)
        #expect(authority.canonicalToolsCatalogRaw() == nil)
    }

    @Test func supersededAttemptCannotMutateNewAttempt() throws {
        let target = xcodeProcessTarget(processID: 41003, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let (oldLease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: testTopologyProof(0),
            nowUptimeNanoseconds: 1
        ))
        _ = authority.resetAttempt(processID: target.processID)
        let (newLease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: testTopologyProof(0),
            nowUptimeNanoseconds: 2
        ))

        guard case .discarded(let reason, _) = authority.completeCatalog(
            .usable(catalog("OldTool"), source: testTopologyProof(0)),
            lease: oldLease,
            nowUptimeNanoseconds: 3
        ) else {
            Issue.record("expected superseded attempt to be discarded")
            return
        }
        #expect(reason == .attemptSuperseded)
        guard case .accepted = authority.completeCatalog(
            .usable(catalog("NewTool"), source: testTopologyProof(0)),
            lease: newLease,
            nowUptimeNanoseconds: 4
        ) else {
            Issue.record("expected current attempt to commit")
            return
        }
        #expect(toolNames(authority.canonicalToolsCatalogRaw()) == ["NewTool"])
    }

    @Test func logicalCatalogLoadsHaveDistinctLeasesAndStaleSiblingReturnsSnapshot() throws {
        let target = xcodeProcessTarget(processID: 41013, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let (foreground, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: testTopologyProof(0),
            nowUptimeNanoseconds: 1
        ))
        let (background, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: testTopologyProof(0),
            nowUptimeNanoseconds: 2
        ))
        #expect(foreground.attempt == background.attempt)
        #expect(foreground != background)

        let foregroundRPC = ControlPlane.RPCHandle()
        let backgroundRPC = ControlPlane.RPCHandle()
        _ = authority.attach(.rpc(foregroundRPC), to: foreground)
        _ = authority.attach(.rpc(backgroundRPC), to: background)
        foregroundRPC.markFinished()
        guard case .accepted(_, let transition) = authority.completeCatalog(
            .usable(catalog("Foreground"), source: testTopologyProof(0)),
            lease: foreground,
            nowUptimeNanoseconds: 3
        ) else {
            Issue.record("first logical load should commit")
            return
        }
        for effect in transition.effects {
            if case .cancelRPC(let handle) = effect {
                handle.cancel()
            }
        }
        #expect(foregroundRPC.isCancelled() == false)
        #expect(backgroundRPC.isCancelled())
        #expect(authority.validateCatalogLoad(background) == false)
        guard case .discarded(let reason, _) = authority.completeCatalog(
            .usable(catalog("Background"), source: testTopologyProof(0)),
            lease: background,
            nowUptimeNanoseconds: 4
        ) else {
            Issue.record("sibling completion should be stale")
            return
        }
        #expect(reason == .attemptNotLoading)
        #expect(toolNames(authority.canonicalToolsCatalogRaw()) == ["Foreground"])
    }

    @Test func catalogCommitUsesActualFallbackResponseProof() throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let target = xcodeProcessTarget(processID: 41016, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 1),
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        let preferredProof = try #require(
            manager.upstreamTopology.operationLease(
                for: UpstreamSlotID(rawValue: 0)
            )?.proof
        )
        let actualProof = try #require(
            manager.upstreamTopology.operationLease(
                for: UpstreamSlotID(rawValue: 1)
            )?.proof
        )
        manager.applyProcessControlPlaneTransition(
            manager.processControlPlane.updateUsability(
                usability([0, 1]),
                nowUptimeNs: 0
            )
        )
        let route = try #require(manager.processControlPlane.route(forProcessID: target.processID))
        let (lease, transition) = try #require(
            manager.processControlPlane.beginCatalogAttempt(
                routeID: route.id,
                preferredUpstreamProof: preferredProof,
                nowUptimeNanoseconds: 1
            )
        )
        manager.applyProcessControlPlaneTransition(transition)

        guard case .accepted = manager.commitProcessCatalog(
            .usable(catalog("FallbackTool"), source: actualProof),
            lease: lease,
            nowUptimeNanoseconds: 2
        ) else {
            Issue.record("expected fallback response to commit")
            return
        }

        #expect(manager.processControlPlane.catalog(forProcessID: target.processID)?.upstreamProof == actualProof)
        #expect(manager.processControlPlane.canonicalSourceProof() == actualProof)
        #expect(actualProof != preferredProof)
    }

    @Test func supportEligibilityKeepsSiblingFallbackLoadAlive() throws {
        let target = xcodeProcessTarget(processID: 41019, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0, 1])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let lostProof = testTopologyProof(0)
        let fallbackProof = testTopologyProof(1)
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: lostProof,
            nowUptimeNanoseconds: 1
        ))
        let lostRPC = ControlPlane.RPCHandle()
        let fallbackRPC = ControlPlane.RPCHandle()
        _ = authority.attach(.rpc(lostRPC), to: lease)
        _ = authority.attach(.rpc(fallbackRPC), to: lease)
        #expect(lostRPC.installCancel { _ in })
        #expect(fallbackRPC.installCancel { _ in })
        #expect(lostRPC.markRegistered(
            registrationToken: UUID(),
            operationLease: testOperationLease(0)
        ))
        #expect(fallbackRPC.markRegistered(
            registrationToken: UUID(),
            operationLease: testOperationLease(1)
        ))

        let eligibility = authority.applySupportEligibility(
            usability: usability([1]),
            newlyIneligibleProofs: [lostProof],
            nowUptimeNs: 2
        )
        for effect in eligibility.transition.effects {
            guard case .cancelRPC(let handle) = effect else { continue }
            handle.cancel()
        }

        #expect(lostRPC.isCancelled())
        #expect(fallbackRPC.isCancelled() == false)
        #expect(authority.validateCatalogLoad(lease))
        guard case .accepted = authority.completeCatalog(
            .usable(catalog("FallbackTool"), source: fallbackProof),
            lease: lease,
            nowUptimeNanoseconds: 3
        ) else {
            Issue.record("healthy sibling should complete the retained catalog load")
            return
        }
        #expect(authority.catalog(forProcessID: target.processID)?.upstreamProof == fallbackProof)
    }

    @Test func catalogEligibilityMilestoneSurvivesQuarantineUntilRetireOrReset() throws {
        let older = xcodeProcessTarget(processID: 41020, xcodeVersion: "26.6")
        let latest = xcodeProcessTarget(processID: 41021, xcodeVersion: "27.0")
        let authority = ProcessControlPlaneAuthority(initialRoutes: [
            XcodeProcessRoute(target: older, upstreamIndices: [0]),
            XcodeProcessRoute(target: latest, upstreamIndices: [1]),
        ])
        #expect(authority.snapshot().catalogEligibilityEstablishedProcessIDs.isEmpty)
        #expect(authority.snapshot().catalogRequiredProcessIDs.isEmpty)

        _ = authority.updateUsability(usability([0]), nowUptimeNs: 1)
        try commit(catalog("OlderTool"), processID: older.processID, upstream: 0, to: authority)
        #expect(authority.snapshot().catalogEligibilityEstablishedProcessIDs == [older.processID])
        #expect(authority.snapshot().catalogRequiredProcessIDs == [older.processID])
        #expect(toolNames(authority.canonicalToolsCatalogRaw()) == ["OlderTool"])

        _ = authority.updateUsability(usability([0, 1]), nowUptimeNs: 2)
        #expect(authority.snapshot().catalogEligibilityEstablishedProcessIDs == [
            older.processID,
            latest.processID,
        ])
        #expect(authority.snapshot().catalogRequiredProcessIDs == [
            older.processID,
            latest.processID,
        ])
        #expect(authority.canonicalToolsCatalogRaw() == nil)

        _ = authority.applySupportEligibility(
            usability: usability([0]),
            newlyIneligibleProofs: [testTopologyProof(1)],
            nowUptimeNs: 3
        )

        #expect(authority.catalog(forProcessID: older.processID) != nil)
        #expect(authority.catalog(forProcessID: latest.processID) == nil)
        #expect(authority.snapshot().catalogEligibilityEstablishedProcessIDs == [
            older.processID,
            latest.processID,
        ])
        #expect(authority.snapshot().catalogRequiredProcessIDs == [
            older.processID,
            latest.processID,
        ])
        #expect(authority.canonicalToolsCatalogRaw() == nil)
        #expect(authority.canonicalSourceProof() == nil)

        let latestRoute = try #require(authority.route(forProcessID: latest.processID))
        _ = authority.retireRoute(
            routeID: latestRoute.id,
            reason: "test_retire_health_hidden_route",
            nowUptimeNs: 4
        )
        #expect(authority.snapshot().catalogEligibilityEstablishedProcessIDs == [older.processID])
        #expect(authority.snapshot().catalogRequiredProcessIDs == [older.processID])
        #expect(toolNames(authority.canonicalToolsCatalogRaw()) == ["OlderTool"])

        _ = authority.reset()
        #expect(authority.snapshot().catalogEligibilityEstablishedProcessIDs.isEmpty)
        #expect(authority.snapshot().catalogRequiredProcessIDs.isEmpty)

        _ = authority.updateUsability(usability([0]), nowUptimeNs: 5)
        #expect(authority.snapshot().catalogEligibilityEstablishedProcessIDs == [older.processID])
        #expect(authority.snapshot().catalogRequiredProcessIDs == [older.processID])
    }

    @Test func exactCooldownExpiryWithdrawsPartialProjectionUntilFreshCatalog() throws {
        let older = xcodeProcessTarget(processID: 41022, xcodeVersion: "26.6")
        let latest = xcodeProcessTarget(processID: 41023, xcodeVersion: "27.0")
        let authority = makeAuthority([
            (older, [0]),
            (latest, [1]),
        ])
        try commit(catalog("OlderTool"), processID: older.processID, upstream: 0, to: authority)
        try commit(catalog("LatestTool"), processID: latest.processID, upstream: 1, to: authority)
        #expect(toolNames(authority.canonicalToolsCatalogRaw()) == ["LatestTool", "OlderTool"])

        let unavailable = try #require(authority.markUnavailable(
            upstreamIndex: 1,
            scope: .catalog,
            nowUptimeNs: 10,
            unavailableUntilUptimeNs: 100
        ))
        #expect(authority.snapshot().catalogRequiredProcessIDs == [older.processID])
        #expect(toolNames(authority.canonicalToolsCatalogRaw()) == ["OlderTool"])
        let extended = try #require(authority.markUnavailable(
            upstreamIndex: 1,
            scope: .catalog,
            nowUptimeNs: 50,
            unavailableUntilUptimeNs: 200
        ))
        #expect(authority.expireCooldown(
            unavailable.cooldownLease,
            nowUptimeNs: 100
        ) == nil)
        #expect(authority.unavailableProcessIDs(nowUptimeNs: 201).contains(latest.processID))
        #expect(
            authority.routingSnapshot(policy: .toolsCatalog, nowUptimeNs: 201)
                .processIDs.contains(latest.processID) == false
        )
        #expect(toolNames(authority.canonicalToolsCatalogRaw()) == ["OlderTool"])

        _ = try #require(authority.expireCooldown(
            extended.cooldownLease,
            nowUptimeNs: 200
        ))
        #expect(authority.snapshot().catalogRequiredProcessIDs == [
            older.processID,
            latest.processID,
        ])
        #expect(authority.canonicalToolsCatalogRaw() == nil)
        #expect(authority.canonicalSourceProof() == nil)

        try commit(catalog("LatestFresh"), processID: latest.processID, upstream: 1, to: authority)
        #expect(toolNames(authority.canonicalToolsCatalogRaw()) == ["LatestFresh", "OlderTool"])
    }

    @Test func cooldownTimerAttachmentBelongsToExactAuthorityLease() throws {
        let target = xcodeProcessTarget(processID: 41026, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])

        let first = try #require(authority.markUnavailable(
            upstreamIndex: 0,
            scope: .catalog,
            nowUptimeNs: 0,
            unavailableUntilUptimeNs: 100
        ))
        let firstCancelled = NIOLockedValueBox(false)
        applyEffects(authority.attachCooldownTimeout(
            RuntimeScheduledTimeout { firstCancelled.withLockedValue { $0 = true } },
            to: first.cooldownLease
        ))
        #expect(firstCancelled.withLockedValue { $0 } == false)

        let extended = try #require(authority.markUnavailable(
            upstreamIndex: 0,
            scope: .catalog,
            nowUptimeNs: 1,
            unavailableUntilUptimeNs: 200
        ))
        applyEffects(extended.transition)
        #expect(firstCancelled.withLockedValue { $0 })

        let staleFirstCancelled = NIOLockedValueBox(false)
        applyEffects(authority.attachCooldownTimeout(
            RuntimeScheduledTimeout { staleFirstCancelled.withLockedValue { $0 = true } },
            to: first.cooldownLease
        ))
        #expect(staleFirstCancelled.withLockedValue { $0 })

        let extendedCancelled = NIOLockedValueBox(false)
        applyEffects(authority.attachCooldownTimeout(
            RuntimeScheduledTimeout { extendedCancelled.withLockedValue { $0 = true } },
            to: extended.cooldownLease
        ))
        #expect(extendedCancelled.withLockedValue { $0 } == false)

        // Detach the old timer, but deliberately delay delivery of its cancel effect.
        let available = authority.markAvailable(
            upstreamIndex: 0,
            scope: .catalog,
            nowUptimeNs: 2
        )
        let replacement = try #require(authority.markUnavailable(
            upstreamIndex: 0,
            scope: .catalog,
            nowUptimeNs: 2,
            unavailableUntilUptimeNs: 200
        ))
        #expect(replacement.cooldownLease.generation != extended.cooldownLease.generation)
        let replacementCancelled = NIOLockedValueBox(false)
        applyEffects(authority.attachCooldownTimeout(
            RuntimeScheduledTimeout { replacementCancelled.withLockedValue { $0 = true } },
            to: replacement.cooldownLease
        ))

        applyEffects(available)
        #expect(extendedCancelled.withLockedValue { $0 })
        #expect(replacementCancelled.withLockedValue { $0 } == false)

        let reset = authority.reset()
        let preResetLeaseCancelled = NIOLockedValueBox(false)
        applyEffects(authority.attachCooldownTimeout(
            RuntimeScheduledTimeout { preResetLeaseCancelled.withLockedValue { $0 = true } },
            to: replacement.cooldownLease
        ))
        #expect(preResetLeaseCancelled.withLockedValue { $0 })
        applyEffects(reset)
        #expect(replacementCancelled.withLockedValue { $0 })
    }

    @Test func membershipReplacementEstablishesCatalogEligibilityFromNewUsableSlot() throws {
        let target = xcodeProcessTarget(processID: 41024, xcodeVersion: "27.0")
        let authority = ProcessControlPlaneAuthority(initialRoutes: [
            XcodeProcessRoute(target: target, upstreamIndices: [0]),
        ])
        #expect(authority.snapshot().catalogEligibilityEstablishedProcessIDs.isEmpty)

        _ = authority.reconcileRoutes(
            [XcodeProcessRoute(target: target, upstreamIndices: [1])],
            reason: "replace_with_usable_slot",
            nowUptimeNs: 1,
            usability: usability([1])
        )

        #expect(authority.snapshot().catalogEligibilityEstablishedProcessIDs == [target.processID])
        #expect(authority.snapshot().catalogRequiredProcessIDs == [target.processID])
    }

    @Test func membershipReplacementPreservesEstablishedCatalogEligibility() throws {
        let target = xcodeProcessTarget(processID: 41025, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])

        _ = authority.reconcileRoutes(
            [XcodeProcessRoute(target: target, upstreamIndices: [1])],
            reason: "replace_with_unusable_slot",
            nowUptimeNs: 1,
            usability: usability([])
        )

        #expect(authority.snapshot().catalogEligibilityEstablishedProcessIDs == [target.processID])
        #expect(authority.snapshot().catalogRequiredProcessIDs == [target.processID])
    }

    @Test func catalogSourceInvalidationRequiresExactProof() throws {
        let target = xcodeProcessTarget(processID: 41019, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let sourceProof = testTopologyProof(0)
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: sourceProof,
            nowUptimeNanoseconds: 1
        ))
        guard case .accepted = authority.completeCatalog(
            .usable(catalog("SourceBoundTool"), source: sourceProof),
            lease: lease,
            nowUptimeNanoseconds: 2
        ) else {
            Issue.record("expected catalog commit to be accepted")
            return
        }

        let staleTransition = authority.invalidateCatalogSource(
            processID: target.processID,
            source: testTopologyProof(0, generation: 2)
        )
        #expect(staleTransition.publishesToolsListChanged == false)
        #expect(authority.catalog(forProcessID: target.processID) != nil)
        #expect(authority.canonicalSourceProof() == sourceProof)

        let (lateLease, lateTransition) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: sourceProof,
            nowUptimeNanoseconds: 3
        ))
        #expect(lateTransition.effects.isEmpty)
        let lateRPC = ControlPlane.RPCHandle()
        _ = authority.attach(.rpc(lateRPC), to: lateLease)

        let invalidation = authority.invalidateCatalogSource(
            processID: target.processID,
            source: sourceProof
        )
        #expect(invalidation.publishesToolsListChanged)
        #expect(invalidation.effects.count == 1)
        #expect(authority.validateCatalogLoad(lateLease) == false)
        guard case .discarded(.attemptSuperseded, _) = authority.completeCatalog(
            .usable(catalog("LateStaleTool"), source: sourceProof),
            lease: lateLease,
            nowUptimeNanoseconds: 4
        ) else {
            Issue.record("source invalidation must reject a late load from the cleared proof")
            return
        }
        #expect(authority.catalog(forProcessID: target.processID) == nil)
        #expect(authority.canonicalToolsCatalogRaw() == nil)
        #expect(authority.canonicalSourceProof() == nil)
    }

    @Test func catalogCommitRejectsTopologicallyCurrentButClearedResponseSource() throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let target = xcodeProcessTarget(processID: 41020, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 1),
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient(), TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0, 1]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        manager.markUpstreamInitialized(upstreamIndex: 0)
        manager.markUpstreamInitialized(upstreamIndex: 1)
        let clearedProof = manager.operationLeaseForTest(upstreamIndex: 0).proof
        let preferredProof = manager.operationLeaseForTest(upstreamIndex: 1).proof
        let route = try #require(
            manager.processControlPlane.route(forProcessID: target.processID)
        )
        let (lease, transition) = try #require(
            manager.processControlPlane.beginCatalogAttempt(
                routeID: route.id,
                preferredUpstreamProof: preferredProof,
                nowUptimeNanoseconds: 1
            )
        )
        manager.applyProcessControlPlaneTransition(transition)
        _ = try #require(manager.upstreamHealthManager.clearUpstreamState(clearedProof))

        guard case .discarded(let reason, _) = manager.commitProcessCatalog(
            .usable(catalog("LateClearedTool"), source: clearedProof),
            lease: lease,
            nowUptimeNanoseconds: 2
        ) else {
            Issue.record("cleared source must not commit a late catalog response")
            return
        }

        #expect(reason == .upstreamReplaced)
        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) == nil)
        #expect(manager.processControlPlane.canonicalToolsCatalogRaw() == nil)
    }

    @Test func catalogCommitRejectsActualResponseFromReplacedGeneration() throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let target = xcodeProcessTarget(processID: 41017, xcodeVersion: "27.0")
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 1),
            eventLoop: group.next(),
            upstreams: [TestUpstreamClient()],
            xcodeProcessRoutes: [
                XcodeProcessRoute(target: target, upstreamIndices: [0]),
            ],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        let oldProof = try #require(
            manager.upstreamTopology.operationLease(
                for: UpstreamSlotID(rawValue: 0)
            )?.proof
        )
        let route = try #require(manager.processControlPlane.route(forProcessID: target.processID))
        let (lease, transition) = try #require(
            manager.processControlPlane.beginCatalogAttempt(
                routeID: route.id,
                preferredUpstreamProof: oldProof,
                nowUptimeNanoseconds: 1
            )
        )
        manager.applyProcessControlPlaneTransition(transition)
        _ = try #require(
            manager.upstreamTopology.replace(oldProof, with: TestUpstreamClient())
        )

        guard case .discarded(let reason, _) = manager.commitProcessCatalog(
            .usable(catalog("StaleTool"), source: oldProof),
            lease: lease,
            nowUptimeNanoseconds: 2
        ) else {
            Issue.record("expected replaced response generation to be rejected")
            return
        }

        #expect(reason == .upstreamReplaced)
        #expect(manager.processControlPlane.catalog(forProcessID: target.processID) == nil)
        #expect(manager.processControlPlane.canonicalToolsCatalogRaw() == nil)
    }

    @Test func unrelatedRouteAdditionDoesNotInvalidateInFlightCatalogLoad() throws {
        let first = xcodeProcessTarget(processID: 41014, xcodeVersion: "27.0")
        let second = xcodeProcessTarget(processID: 41015, xcodeVersion: "26.4")
        let authority = makeAuthority([(first, [0])])
        let route = try #require(authority.route(forProcessID: first.processID))
        let epoch = authority.currentCatalogEpoch()
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: testTopologyProof(0),
            nowUptimeNanoseconds: 1
        ))
        let rpc = ControlPlane.RPCHandle()
        _ = authority.attach(.rpc(rpc), to: lease)

        _ = authority.reconcileRoutes(
            [
                XcodeProcessRoute(target: first, upstreamIndices: [0]),
                XcodeProcessRoute(target: second, upstreamIndices: [1]),
            ],
            reason: "add_unrelated_route",
            nowUptimeNs: 2,
            usability: usability([0, 1])
        )

        #expect(authority.currentCatalogEpoch() == epoch)
        #expect(authority.validateCatalogLoad(lease))
        #expect(rpc.isCancelled() == false)
        guard case .accepted = authority.completeCatalog(
            .usable(catalog("StillCurrent"), source: testTopologyProof(0)),
            lease: lease,
            nowUptimeNanoseconds: 3
        ) else {
            Issue.record("unrelated route addition must preserve the load")
            return
        }
    }

    @Test func supersededReadinessReservationCannotStartNewAttempt() throws {
        let target = xcodeProcessTarget(processID: 41012, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let oldToken = UpstreamReadinessWaiterToken()
        let oldReservation = try #require(authority.reserveActivation(
            routeID: route.id,
            upstreamProof: testTopologyProof(0),
            nowUptimeNs: 1,
            readinessToken: oldToken
        )).0
        #expect(authority.reserveActivation(
            routeID: route.id,
            upstreamProof: testTopologyProof(0),
            nowUptimeNs: 2,
            readinessToken: UpstreamReadinessWaiterToken()
        ) == nil)
        let pending = try #require(authority.attemptSnapshot(processID: target.processID))
        #expect(pending.phase == .pending)
        #expect(pending.readinessWaiterCount == 1)

        let reset = authority.resetAttempt(processID: target.processID)
        for effect in reset.effects {
            if case .cancelReadinessWaiter(let token) = effect {
                token.cancel()
            }
        }
        #expect(oldToken.isCancelled)

        let newReservation = try #require(authority.reserveActivation(
            routeID: route.id,
            upstreamProof: testTopologyProof(0),
            nowUptimeNs: 3,
            readinessToken: UpstreamReadinessWaiterToken()
        )).0
        #expect(authority.beginAttaching(oldReservation, nowUptimeNs: 4) == nil)
        let stillPending = try #require(authority.attemptSnapshot(processID: target.processID))
        #expect(stillPending.attemptID.rawValue == 2)
        #expect(stillPending.phase == .pending)
        #expect(stillPending.readinessWaiterCount == 1)

        _ = try #require(authority.beginAttaching(newReservation, nowUptimeNs: 5))
        let attaching = try #require(authority.attemptSnapshot(processID: target.processID))
        #expect(attaching.attemptID.rawValue == 2)
        #expect(attaching.phase == .attaching)
        #expect(attaching.readinessWaiterCount == 0)
    }

    @Test func channelInitializationPreservesCatalogLoadStartedByForegroundRequest() throws {
        let target = xcodeProcessTarget(processID: 41031, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let proof = testTopologyProof(0)
        let reservation = try #require(authority.reserveActivation(
            routeID: route.id,
            upstreamProof: proof,
            nowUptimeNs: 1,
            readinessToken: UpstreamReadinessWaiterToken()
        )).0
        _ = try #require(authority.beginAttaching(reservation, nowUptimeNs: 2))
        let (catalogLease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: proof,
            nowUptimeNanoseconds: 3
        ))

        let initialized = try #require(authority.markChannelInitialized(
            routeID: route.id,
            upstreamProof: proof
        ))

        #expect(initialized.attempt == catalogLease.attempt)
        #expect(initialized.shouldStartCatalogLoad == false)
        #expect(initialized.activeCatalogLeases == [catalogLease])
        #expect(authority.validateCatalogLoad(catalogLease))
        #expect(
            authority.attemptSnapshot(processID: target.processID)?.phase
                == .loadingCatalog
        )
    }

    @Test func catalogTimeoutBackoffBlocksLoadsAndAdvancesRetryOrdinal() throws {
        let target = xcodeProcessTarget(processID: 41032, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let proof = testTopologyProof(0)
        let (firstLease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: proof,
            nowUptimeNanoseconds: 1
        ))
        let firstTimeoutReservation = try #require(
            authority.reserveCatalogTimeout(for: firstLease)
        )
        _ = authority.attachCatalogTimeout(
            RuntimeScheduledTimeout {},
            to: firstTimeoutReservation
        )

        guard case .retryRequired(_, let firstRetry, let firstRetryLease, let firstTimeoutCount) =
            authority.handleCatalogRequestTimeout(firstTimeoutReservation, nowUptimeNs: 2)
        else {
            Issue.record("expected the final load timeout to require retry")
            return
        }

        #expect(firstRetryLease.attempt == firstLease.attempt)
        #expect(firstRetry.attempt == 1)
        #expect(firstRetry.delay == .milliseconds(250))
        #expect(firstTimeoutCount == 1)
        #expect(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: proof,
            nowUptimeNanoseconds: 3
        ) == nil)

        #expect(authority.handleRetryFired(firstRetryLease))
        let (secondLease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: proof,
            nowUptimeNanoseconds: 4
        ))
        let secondTimeoutReservation = try #require(
            authority.reserveCatalogTimeout(for: secondLease)
        )
        _ = authority.attachCatalogTimeout(
            RuntimeScheduledTimeout {},
            to: secondTimeoutReservation
        )
        guard case .retryRequired(_, let secondRetry, _, let secondTimeoutCount) =
            authority.handleCatalogRequestTimeout(secondTimeoutReservation, nowUptimeNs: 5)
        else {
            Issue.record("expected the retry load timeout to require another retry")
            return
        }

        #expect(secondLease.attempt == firstLease.attempt)
        #expect(secondRetry.attempt == 2)
        #expect(secondRetry.delay == .milliseconds(500))
        #expect(secondTimeoutCount == 2)
    }

    @Test func catalogTimeoutFiringBeforeAttachmentConsumesReservation() throws {
        let target = xcodeProcessTarget(processID: 41035, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: testTopologyProof(0),
            nowUptimeNanoseconds: 1
        ))
        let reservation = try #require(
            authority.reserveCatalogTimeout(for: lease)
        )

        guard case .retryRequired =
            authority.handleCatalogRequestTimeout(reservation, nowUptimeNs: 2)
        else {
            Issue.record("a reserved timeout must fire before its handle is attached")
            return
        }

        let lateTimeoutCancelled = NIOLockedValueBox(false)
        applyEffects(authority.attachCatalogTimeout(
            RuntimeScheduledTimeout {
                lateTimeoutCancelled.withLockedValue { $0 = true }
            },
            to: reservation
        ))

        #expect(lateTimeoutCancelled.withLockedValue { $0 })
        #expect(authority.validateCatalogLoad(lease) == false)
    }

    @Test func catalogTimeoutCountIgnoresNonTimeoutRetryAndRejectsStaleReservation() throws {
        let target = xcodeProcessTarget(processID: 41033, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let proof = testTopologyProof(0)
        let (firstLease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: proof,
            nowUptimeNanoseconds: 1
        ))
        let staleTimeoutReservation = try #require(
            authority.reserveCatalogTimeout(for: firstLease)
        )
        _ = authority.attachCatalogTimeout(
            RuntimeScheduledTimeout {},
            to: staleTimeoutReservation
        )
        guard case .accepted = authority.completeCatalog(
            .unusable,
            lease: firstLease,
            nowUptimeNanoseconds: 2
        ) else {
            Issue.record("expected the first load to complete")
            return
        }
        let scheduled = try #require(authority.scheduleRetry(lease: firstLease))
        #expect(authority.handleRetryFired(scheduled.lease))
        let (retryLease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: proof,
            nowUptimeNanoseconds: 3
        ))

        #expect(authority.handleCatalogRequestTimeout(
            staleTimeoutReservation,
            nowUptimeNs: 4
        ) == nil)
        #expect(authority.validateCatalogLoad(retryLease))
        #expect(
            authority.attemptSnapshot(processID: target.processID)?.phase
                == .loadingCatalog
        )
        let retryTimeoutReservation = try #require(
            authority.reserveCatalogTimeout(for: retryLease)
        )
        guard case .retryRequired(_, let retry, _, let timeoutCount) =
            authority.handleCatalogRequestTimeout(retryTimeoutReservation, nowUptimeNs: 5)
        else {
            Issue.record("expected the current load timeout to require retry")
            return
        }
        #expect(retry.attempt == 2)
        #expect(timeoutCount == 1)
    }

    @Test func catalogLoadTimeoutPreservesSiblingLoad() throws {
        let target = xcodeProcessTarget(processID: 41034, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let proof = testTopologyProof(0)
        let (firstLease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: proof,
            nowUptimeNanoseconds: 1
        ))
        let (siblingLease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: proof,
            nowUptimeNanoseconds: 2
        ))
        let firstTimeoutReservation = try #require(
            authority.reserveCatalogTimeout(for: firstLease)
        )
        let siblingTimeoutReservation = try #require(
            authority.reserveCatalogTimeout(for: siblingLease)
        )
        let firstTimeoutCancelled = NIOLockedValueBox(false)
        let siblingTimeoutCancelled = NIOLockedValueBox(false)
        applyEffects(authority.attachCatalogTimeout(
            RuntimeScheduledTimeout {
                firstTimeoutCancelled.withLockedValue { $0 = true }
            },
            to: firstTimeoutReservation
        ))
        applyEffects(authority.attachCatalogTimeout(
            RuntimeScheduledTimeout {
                siblingTimeoutCancelled.withLockedValue { $0 = true }
            },
            to: siblingTimeoutReservation
        ))
        #expect(authority.reserveCatalogTimeout(for: siblingLease) == nil)
        let firstRPC = ControlPlane.RPCHandle()
        let siblingRPC = ControlPlane.RPCHandle()
        _ = authority.attach(.rpc(firstRPC), to: firstLease)
        _ = authority.attach(.rpc(siblingRPC), to: siblingLease)

        guard case .loadTimedOut(let transition) =
            authority.handleCatalogRequestTimeout(firstTimeoutReservation, nowUptimeNs: 3)
        else {
            Issue.record("a sibling load must suppress retry")
            return
        }
        for effect in transition.effects {
            switch effect {
            case .cancelTimeout(let timeout):
                timeout.cancel()
            case .cancelRPC(let handle):
                handle.cancel()
            case .cancelReadinessWaiter, .restoreBridgePool:
                break
            }
        }

        #expect(firstTimeoutCancelled.withLockedValue { $0 })
        #expect(firstRPC.isCancelled())
        #expect(siblingTimeoutCancelled.withLockedValue { $0 } == false)
        #expect(siblingRPC.isCancelled() == false)
        #expect(authority.validateCatalogLoad(siblingLease))
        #expect(
            authority.attemptSnapshot(processID: target.processID)?.phase
                == .loadingCatalog
        )
    }

    @Test func windowUpdatesDoNotInvalidateCatalogLease() throws {
        let target = xcodeProcessTarget(processID: 41004, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: testTopologyProof(0),
            nowUptimeNanoseconds: 1
        ))
        let catalogEpoch = authority.currentCatalogEpoch()
        let windows = WindowOwnershipAuthority()

        _ = windows.record(
            processID: target.processID,
            entries: [XcodeListWindowsEntry(tabIdentifier: "tab", workspacePath: "/tmp/App.xcworkspace")]
        )

        #expect(authority.currentCatalogEpoch() == catalogEpoch)
        guard case .accepted = authority.completeCatalog(
            .usable(catalog("WindowTool"), source: testTopologyProof(0)),
            lease: lease,
            nowUptimeNanoseconds: 2
        ) else {
            Issue.record("window epoch must not stale catalog lease")
            return
        }
    }

    @Test func retiringRouteReprojectsRemainingCatalog() throws {
        let newer = xcodeProcessTarget(processID: 41005, xcodeVersion: "27.0")
        let older = xcodeProcessTarget(processID: 41006, xcodeVersion: "26.4")
        let authority = makeAuthority([(newer, [0]), (older, [1])])
        try commit(catalog("NewerTool"), processID: newer.processID, upstream: 0, to: authority)
        try commit(catalog("OlderTool"), processID: older.processID, upstream: 1, to: authority)
        #expect(Set(toolNames(authority.canonicalToolsCatalogRaw())) == ["NewerTool", "OlderTool"])

        _ = authority.reconcileRoutes(
            [XcodeProcessRoute(target: older, upstreamIndices: [1])],
            reason: "retire_newer",
            nowUptimeNs: 3,
            usability: usability([1])
        )

        #expect(toolNames(authority.canonicalToolsCatalogRaw()) == ["OlderTool"])
        #expect(authority.processIDsWithCatalog() == [older.processID])
    }

    @Test func windowRecordIsOrderIndependentAndDeduplicated() {
        let authority = WindowOwnershipAuthority()
        let first = authority.record(
            processID: 41007,
            entries: [
                XcodeListWindowsEntry(tabIdentifier: "b", workspacePath: "/tmp/B.xcworkspace"),
                XcodeListWindowsEntry(tabIdentifier: "a", workspacePath: "/tmp/A.xcworkspace"),
                XcodeListWindowsEntry(tabIdentifier: "a", workspacePath: "/tmp/A.xcworkspace"),
            ]
        )
        let second = authority.record(
            processID: 41007,
            entries: [
                XcodeListWindowsEntry(tabIdentifier: "a", workspacePath: "/tmp/A.xcworkspace"),
                XcodeListWindowsEntry(tabIdentifier: "b", workspacePath: "/tmp/B.xcworkspace"),
            ]
        )

        #expect(first.didChange)
        #expect(second.didChange == false)
        #expect(first.epoch == second.epoch)
        #expect(authority.snapshot().identities.map(\.rawTabIdentifier) == ["a", "b"])
    }

    @Test func topologyReplacementAndRetirementRejectOldState() throws {
        let first = TestUpstreamClient()
        let second = TestUpstreamClient()
        let topology = UpstreamTopologyAuthority([first, second])
        let initial = topology.snapshot()
        let oldProof = try #require(initial.proof(UpstreamSlotID(rawValue: 0)))
        let router = UpstreamRouter(upstreamCount: 2)
        let health = UpstreamHealthManager()
        router.applyTopology(initial)
        health.applyTopology(initial)
        let requestID = try #require(router.assign(
            proof: oldProof,
            sessionID: "session",
            originalID: JSONRPC.ID(any: 1)!,
            isInitialize: false
        ))
        #expect(requestID != 0)
        #expect(health.claimWarmInitialize(upstreamIndex: 0) != nil)

        let replacement = try #require(topology.replace(
            oldProof,
            with: TestUpstreamClient()
        ))
        let replacementProof = try #require(
            replacement.snapshot.proof(UpstreamSlotID(rawValue: 0))
        )
        router.applyTopology(replacement.snapshot)
        health.applyTopology(replacement.snapshot)

        #expect(topology.validate(oldProof) == false)
        #expect(topology.validate(replacementProof))
        var replacementEventCount = 0
        if topology.validate(oldProof) {
            replacementEventCount += 1
        }
        #expect(replacementEventCount == 0)
        #expect(router.consume(proof: oldProof, upstreamID: requestID) == nil)
        #expect(
            health.activeStatesSnapshot().first { $0.id == UpstreamSlotID(rawValue: 0) }?
                .state.initInFlight == false
        )
        let replacementInitializeID = try #require(
            router.assignInitialize(proof: replacementProof)
        )
        let replacementClaim = try #require(health.claimWarmInitialize(upstreamIndex: 0))
        #expect(router.consume(proof: oldProof, upstreamID: replacementInitializeID) == nil)
        #expect(health.markProtocolViolation(oldProof, nowUptimeNs: 1) == nil)
        #expect(health.validate(replacementClaim))
        #expect(
            router.consume(
                proof: replacementProof,
                upstreamID: replacementInitializeID
            )?.isInitialize == true
        )

        let retired = topology.retire([UpstreamSlotID(rawValue: 1)])
        router.applyTopology(retired.snapshot)
        health.applyTopology(retired.snapshot)
        #expect(health.activeStatesSnapshot().map(\.id) == [UpstreamSlotID(rawValue: 0)])
        #expect(retired.snapshot.proof(UpstreamSlotID(rawValue: 1)) == nil)

        let appended = topology.append([TestUpstreamClient()])
        health.applyTopology(appended.snapshot)
        #expect(
            health.activeStatesSnapshot().map(\.id)
                == [UpstreamSlotID(rawValue: 0), UpstreamSlotID(rawValue: 2)]
        )
        #expect(health.state(for: UpstreamSlotID(rawValue: 1)) == nil)

        let staleTimeout = health.markRequestTimedOut(oldProof, nowUptimeNs: 0)
        #expect(staleTimeout.timeoutCount == 0)
        guard case .healthy = health.state(
            for: UpstreamSlotID(rawValue: 0)
        )?.healthState else {
            Issue.record("stale topology proof must not mutate the replacement health state")
            return
        }
    }

    @Test func schedulerRejectsReservedLeaseAfterSameSlotGenerationReplacement() async throws {
        let oldSlot = TestUpstreamClient()
        let replacementSlot = TestUpstreamClient()
        let topology = UpstreamTopologyAuthority([oldSlot])
        let oldProof = try #require(
            topology.snapshot().proof(UpstreamSlotID(rawValue: 0))
        )
        let eventLoop = EmbeddedEventLoop()
        let started = NIOLockedValueBox<[UpstreamTopologyProof]>([])
        let failedUnavailable = NIOLockedValueBox(0)
        let scheduler = UpstreamSlotScheduler(
            canUseUpstream: { _ in .init(proof: oldProof, effects: []) },
            selectUpstream: { _ in .init(proof: oldProof, effects: []) },
            operationLease: { topology.operationLease(for: $0) },
            validateOperationLease: { topology.validate($0) }
        )
        scheduler.enqueueRequest(
            leaseID: UUID(),
            descriptor: .init(
                sessionID: "generation-race",
                label: "tools/list",
                expectsResponse: true,
                isTopLevelClientRequest: true
            ),
            on: eventLoop,
            starter: { lease in
                started.withLockedValue { $0.append(lease.proof) }
            },
            failUnavailable: {
                failedUnavailable.withLockedValue { $0 += 1 }
            },
            failCancelled: {
                Issue.record("generation replacement is unavailable, not cancellation")
            }
        )

        _ = try #require(topology.replace(oldProof, with: replacementSlot))
        eventLoop.run()

        #expect(started.withLockedValue { $0 }.isEmpty)
        #expect(failedUnavailable.withLockedValue { $0 } == 1)
        #expect(await oldSlot.sentCount() == 0)
        #expect(await replacementSlot.sentCount() == 0)
        #expect(scheduler.debugSnapshot().activeLeaseCountByUpstream.isEmpty)
    }

    @Test func observerCannotBindRetiredSlotEventsToCurrentGeneration() async throws {
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 1),
            eventLoop: group.next(),
            upstreams: [],
            processRoutingEnabled: true,
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        let retiredSlot = TestUpstreamClient()
        let currentSlot = TestUpstreamClient()
        let appended = manager.upstreamTopology.append([retiredSlot])
        manager.publishUpstreamTopology(appended.snapshot)
        let retiredLease = try #require(
            appended.snapshot.operationLease(UpstreamSlotID(rawValue: 0))
        )
        let replacement = try #require(
            manager.upstreamTopology.replace(retiredLease.proof, with: currentSlot)
        )
        manager.publishUpstreamTopology(replacement.snapshot)
        manager.observeUpstreamEvents(retiredLease)

        await retiredSlot.yield(.stdoutProtocolViolation(.init(
            reason: .invalidJSON,
            bufferedByteCount: 7,
            preview: "{stale"
        )))
        await retiredSlot.stop()
        await manager.upstreamEventTasks.drainCurrentTasks().wait()

        guard case .healthy = manager.upstreamHealthManager.state(
            for: UpstreamSlotID(rawValue: 0)
        )?.healthState else {
            Issue.record("retired slot event must not quarantine the replacement generation")
            return
        }
    }

    @Test func serverResponseFromOldGenerationCannotSendThroughReplacementSlot() async throws {
        let oldSlot = TestUpstreamClient()
        let replacementSlot = TestUpstreamClient()
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let eventLoop = group.next()
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 1),
            eventLoop: eventLoop,
            upstreams: [oldSlot],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        let operationLease = try #require(
            manager.upstreamTopology.operationLease(for: UpstreamSlotID(rawValue: 0))
        )
        let sessionID = "old-generation-server-response"
        let session = manager.session(id: sessionID)
        let clientID = session.serverRequestTracker.record(
            upstreamID: JSONRPC.ID(any: 91)!,
            operationLease: operationLease
        )
        _ = try #require(
            manager.upstreamTopology.replace(operationLease.proof, with: replacementSlot)
        )
        let response = try JSONRPC.Wire.data(from: [
            "jsonrpc": "2.0",
            "id": clientID.value.foundationObject,
            "result": ["ok": true],
        ])

        let result = try await manager.forwardServerRequestResponse(
            responseData: response,
            sessionID: sessionID,
            responseID: clientID,
            on: eventLoop
        ).get()

        #expect(result == .upstreamUnavailable)
        #expect(await oldSlot.sentCount() == 0)
        #expect(await replacementSlot.sentCount() == 0)
        #expect(session.serverRequestTracker.lookup(clientID: clientID) != nil)
    }

    @Test func catalogRequestTimeoutPreservesActivationForRetry() throws {
        let topology = UpstreamTopologyAuthority([TestUpstreamClient()])
        let snapshot = topology.snapshot()
        let proof = try #require(snapshot.proof(UpstreamSlotID(rawValue: 0)))
        let health = UpstreamHealthManager()
        health.applyTopology(snapshot)
        let claim = try #require(health.claimWarmInitialize(
            upstreamIndex: 0,
            owner: .processRouteActivation
        ))
        #expect(health.beginInitializeSend(claim))
        #expect(health.setWarmInitializeUpstreamID(41, for: claim))
        #expect(health.transferInitializeResponse(claim, expectedUpstreamID: 41))
        #expect(health.markInitializedNotificationSent(claim, expectedUpstreamID: 41))
        _ = try #require(health.markInitialized(
            claim,
            expectedUpstreamID: 41,
            commit: { true }
        ))

        #expect(health.timeoutInitializeClaim(claim) == nil)
        #expect(topology.withValidated(proof) {
            health.timeoutCatalogRequest(claim, commit: { _ in true })
        } == true)
        let completion = try #require(topology.withValidated(proof) {
            health.commitCatalogActivation(
                claim,
                sourceProof: proof,
                commit: { _ in .complete }
            )
        })
        guard case .completed = completion else {
            Issue.record("catalog request timeout must preserve the initialized activation")
            return
        }
    }

    @Test func forwardingAdmissionRejectsRouteAndTopologyChangesIndependently() throws {
        let target = xcodeProcessTarget(processID: 41008, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let routeProof = try #require(authority.routeProof(routeID: route.id))
        let routeLease = try #require(authority.admit(routeProof))
        let topology = UpstreamTopologyAuthority([TestUpstreamClient()])
        let topologyProof = try #require(
            topology.snapshot().proof(UpstreamSlotID(rawValue: 0))
        )

        #expect(authority.validate(routeLease))
        #expect(topology.validate(topologyProof))

        _ = authority.reconcileRoutes(
            [],
            reason: "route_retired",
            nowUptimeNs: 1,
            usability: .empty
        )
        #expect(authority.validate(routeLease) == false)
        #expect(topology.validate(topologyProof))

        let replacementAuthority = makeAuthority([(target, [0])])
        let replacementRoute = try #require(
            replacementAuthority.route(forProcessID: target.processID)
        )
        let replacementRouteProof = try #require(
            replacementAuthority.routeProof(routeID: replacementRoute.id)
        )
        let replacementRouteLease = try #require(
            replacementAuthority.admit(replacementRouteProof)
        )
        _ = try #require(topology.replace(
            topologyProof,
            with: TestUpstreamClient()
        ))
        #expect(replacementAuthority.validate(replacementRouteLease))
        #expect(topology.validate(topologyProof) == false)
    }

    @Test func routeAdmissionLeaseIsInvalidatedOnlyByItsRoute() throws {
        let targetA = xcodeProcessTarget(processID: 41009, xcodeVersion: "27.0")
        let targetB = xcodeProcessTarget(processID: 41010, xcodeVersion: "26.4")
        let authority = makeAuthority([(targetA, [0]), (targetB, [1])])
        let routeA = try #require(authority.route(forProcessID: targetA.processID))
        let proofA = try #require(authority.routeProof(routeID: routeA.id))
        let leaseA = try #require(authority.admit(proofA))

        _ = authority.markUnavailable(
            upstreamIndex: 1,
            scope: .route,
            nowUptimeNs: 1,
            unavailableUntilUptimeNs: 100
        )
        #expect(authority.validate(leaseA))

        _ = authority.reconcileRoutes(
            [
                XcodeProcessRoute(target: targetA, upstreamIndices: [0]),
                XcodeProcessRoute(target: targetB, upstreamIndices: [2]),
            ],
            reason: "replace_unrelated_route",
            nowUptimeNs: 2,
            usability: usability([0, 2])
        )
        #expect(authority.validate(leaseA))

        _ = authority.reconcileRoutes(
            [
                XcodeProcessRoute(target: targetA, upstreamIndices: [3]),
                XcodeProcessRoute(target: targetB, upstreamIndices: [2]),
            ],
            reason: "replace_admitted_route",
            nowUptimeNs: 3,
            usability: usability([2, 3])
        )
        #expect(authority.validate(leaseA) == false)

        let replacementA = try #require(authority.route(forProcessID: targetA.processID))
        let replacementProofA = try #require(authority.routeProof(routeID: replacementA.id))
        let replacementLeaseA = try #require(authority.admit(replacementProofA))
        _ = authority.reconcileRoutes(
            [XcodeProcessRoute(target: targetB, upstreamIndices: [2])],
            reason: "retire_admitted_route",
            nowUptimeNs: 4,
            usability: usability([2])
        )
        #expect(authority.validate(replacementLeaseA) == false)

        let availabilityAuthority = makeAuthority([(targetA, [0])])
        let availabilityRoute = try #require(
            availabilityAuthority.route(forProcessID: targetA.processID)
        )
        let availabilityProof = try #require(
            availabilityAuthority.routeProof(routeID: availabilityRoute.id)
        )
        let availabilityLease = try #require(availabilityAuthority.admit(availabilityProof))
        _ = availabilityAuthority.markUnavailable(
            upstreamIndex: 0,
            scope: .route,
            nowUptimeNs: 1,
            unavailableUntilUptimeNs: 100
        )
        #expect(availabilityAuthority.validate(availabilityLease) == false)
    }

    @Test func sendBoundaryRejectsRouteReplacedWhileRuntimeTaskIsSuspended() async throws {
        let target = xcodeProcessTarget(processID: 41011, xcodeVersion: "27.0")
        let upstream = StartGateUpstreamClient()
        let group = borrowSharedTestEventLoopGroup()
        defer { shutdownAndWait(group) }
        let manager = RuntimeCoordinator(
            config: makeConfig(requestTimeout: 1),
            eventLoop: group.next(),
            upstreams: [upstream],
            xcodeProcessRoutes: [XcodeProcessRoute(target: target, upstreamIndices: [0])],
            startImmediately: false
        )
        defer { manager.shutdownAndWait() }
        _ = manager.processControlPlane.updateUsability(
            usability([0]),
            nowUptimeNs: 0
        )
        let route = try #require(manager.processControlPlane.route(forProcessID: target.processID))
        let routeProof = try #require(manager.processControlPlane.routeProof(routeID: route.id))
        let routeLease = try #require(manager.processControlPlane.admit(routeProof))
        let topologyProof = try #require(
            manager.upstreamTopology.snapshot().proof(UpstreamSlotID(rawValue: 0))
        )
        let admission = RouteForwardingAdmission(
            route: routeLease,
            upstreamProofs: [topologyProof]
        )

        manager.sendUpstream(
            try makeToolListRequest(id: 1),
            upstreamIndex: 0,
            ensureRunning: true,
            admission: admission
        )
        try await upstream.waitForStart()
        _ = manager.processControlPlane.reconcileRoutes(
            [XcodeProcessRoute(target: target, upstreamIndices: [0, 1])],
            reason: "replace_during_send",
            nowUptimeNs: 1,
            usability: usability([0])
        )
        await upstream.releaseStart()
        await manager.drainRuntimeTasksForTesting()

        #expect(await upstream.sendCount() == 0)
    }

    @Test func taskASourceInventoryHasNoLegacyMutableOwnersOrSequencingHooks() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repository = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let roots = [
            repository.appendingPathComponent("Sources/XcodeMCPProxyKit"),
            repository.appendingPathComponent("Tests/ProxyRuntimeCoordinatorTests"),
        ]
        let productionRoot = roots[0]
        let forbidden = [
            "ProcessRouteStore",
            "ProcessRouteReadinessStore",
            "ProcessToolSurfaceStore",
            "WindowOwnerIndex",
            "CanonicalBrokerState",
            "upstreamsBox",
            "appendUpstreams",
            "cacheableAsCanonical",
            "processToolsCatalogLoadedBeforeRecord",
            "processToolsCatalogFailureCleanupBeforeApply",
            "processToolCatalogSurfaceUpdatePassedInitialGenerationCheck",
            "processRouteActivationEvent",
            "initializedNotificationStaleIgnored",
            "activeUpstreamIndices",
            "generationByUpstream",
            "setCachedToolsListResult",
            "processToolSurfaceMutationLock",
            "availableToolsCatalogRefreshKeys",
            "cancelLoadsStartedBeforeGeneration",
            "recordAvailableToolsCatalog",
            "func recordCatalog(",
            "xcodeProcessCooldownSchedules",
        ]
        let manager = FileManager.default
        var source = ""
        var productionSource = ""
        for root in roots {
            let enumerator = try #require(manager.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard url.path != #filePath else { continue }
                let fileSource = try String(contentsOf: url, encoding: .utf8)
                source += fileSource
                if url.path.hasPrefix(productionRoot.path) {
                    productionSource += fileSource
                }
            }
        }
        for symbol in forbidden {
            #expect(source.contains(symbol) == false, "legacy Task A symbol remains: \(symbol)")
        }
        let prooflessProductionFragments = [
            "proof suppliedProof: UpstreamTopologyProof?",
            "upstreamTopology.snapshot().proof",
        ]
        for fragment in prooflessProductionFragments {
            #expect(
                productionSource.contains(fragment) == false,
                "production remints current topology proof: \(fragment)"
            )
        }
        let indexOnlyMutationPatterns = [
            #"func\s+(?:markRequestSucceeded|markUpstreamOverloaded|markRequestTimedOut|markProtocolViolation|quarantineIncompatibleUpstream|markToolsListRefreshSucceeded|markToolsListRefreshFailed|clearUpstreamState|markInitialized)\s*\(\s*upstreamIndex\s*:"#,
            #"func\s+(?:assign|assignInitialize|consume|remove|reset)\s*\(\s*upstreamIndex\s*:"#,
            #"func\s+sendUpstream\s*\([^)]*upstreamIndex\s*:"#,
        ]
        for pattern in indexOnlyMutationPatterns {
            let expression = try NSRegularExpression(
                pattern: pattern,
                options: [.dotMatchesLineSeparators]
            )
            let range = NSRange(productionSource.startIndex..., in: productionSource)
            #expect(
                expression.firstMatch(in: productionSource, range: range) == nil,
                "production index-only topology mutation remains: \(pattern)"
            )
        }
    }

    private func makeAuthority(
        _ entries: [(target: XcodeProcessTarget, upstreams: [Int])]
    ) -> ProcessControlPlaneAuthority {
        let authority = ProcessControlPlaneAuthority(
            initialRoutes: entries.map {
                XcodeProcessRoute(target: $0.target, upstreamIndices: $0.upstreams)
            },
            nowUptimeNs: 0
        )
        _ = authority.updateUsability(
            usability(entries.flatMap(\.upstreams)),
            nowUptimeNs: 0
        )
        return authority
    }

    private func usability(
        _ upstreams: [Int]
    ) -> ProcessControlPlaneAuthority.UpstreamUsabilitySnapshot {
        let ids = Set(upstreams.map(UpstreamSlotID.init(rawValue:)))
        return .init(
            snapshotUsableUpstreamIDs: ids,
            recoveryAwareUsableUpstreamIDs: ids
        )
    }

    private func catalog(_ name: String) -> JSONValue {
        .object([
            "tools": .array([
                .object(["name": .string(name)]),
            ]),
        ])
    }

    private func toolNames(_ catalog: JSONValue?) -> [String] {
        ProcessToolCatalogCodec.toolsByName(in: catalog).keys.sorted()
    }

    private func commit(
        _ catalog: JSONValue,
        processID: pid_t,
        upstream: Int,
        to authority: ProcessControlPlaneAuthority
    ) throws {
        let route = try #require(authority.route(forProcessID: processID))
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstreamProof: testTopologyProof(upstream),
            nowUptimeNanoseconds: 1
        ))
        guard case .accepted = authority.completeCatalog(
            .usable(catalog, source: testTopologyProof(upstream)),
            lease: lease,
            nowUptimeNanoseconds: 2
        ) else {
            Issue.record("failed to seed process catalog")
            return
        }
    }

    private func applyEffects(_ transition: ProcessControlPlaneTransition) {
        for effect in transition.effects {
            if case .cancelTimeout(let timeout) = effect {
                timeout.cancel()
            }
        }
    }
}

private actor StartGateUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let startSignal = TestSignal()
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var sentCountValue = 0

    init() {
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        events = AsyncStream { streamContinuation = $0 }
        continuation = streamContinuation
    }

    func start() async {
        startSignal.signal()
        await withCheckedContinuation { startContinuation = $0 }
    }

    func stop() async {
        releaseStart()
        continuation.finish()
    }

    func send(_: Data) async -> Upstream.SendResult {
        sentCountValue += 1
        return .accepted
    }

    func waitForStart() async throws {
        if startContinuation != nil { return }
        try await startSignal.wait(description: "waiting for gated upstream start")
    }

    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func sendCount() -> Int {
        sentCountValue
    }
}
