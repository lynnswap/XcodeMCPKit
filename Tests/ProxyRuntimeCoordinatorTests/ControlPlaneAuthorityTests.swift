import Foundation
import NIO
import NIOConcurrencyHelpers
import Testing
import XcodeMCPKit
import XcodeMCPProxyTestSupport
@testable import XcodeMCPProxyInternalTestSupport
@testable import XcodeMCPProxyKit

@Suite(.serialized)
struct ControlPlaneAuthorityTests {
    @Test func catalogCommitPublishesProcessAndCanonicalStateAtomically() throws {
        let target = xcodeProcessTarget(processID: 41001, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstream: UpstreamSlotID(rawValue: 0),
            nowUptimeNanoseconds: 1
        ))

        let commit = authority.completeCatalog(
            .usable(catalog("BuildProject"), source: UpstreamSlotID(rawValue: 0)),
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

    @Test func routeMembershipChangeInvalidatesLeaseAndCatalogTogether() throws {
        let target = xcodeProcessTarget(processID: 41002, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let initialEpoch = authority.currentCatalogEpoch()
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstream: UpstreamSlotID(rawValue: 0),
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
            .usable(catalog("StaleTool"), source: UpstreamSlotID(rawValue: 0)),
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
            preferredUpstream: UpstreamSlotID(rawValue: 0),
            nowUptimeNanoseconds: 1
        ))
        _ = authority.resetAttempt(processID: target.processID)
        let (newLease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstream: UpstreamSlotID(rawValue: 0),
            nowUptimeNanoseconds: 2
        ))

        guard case .discarded(let reason, _) = authority.completeCatalog(
            .usable(catalog("OldTool"), source: UpstreamSlotID(rawValue: 0)),
            lease: oldLease,
            nowUptimeNanoseconds: 3
        ) else {
            Issue.record("expected superseded attempt to be discarded")
            return
        }
        #expect(reason == .attemptSuperseded)
        guard case .accepted = authority.completeCatalog(
            .usable(catalog("NewTool"), source: UpstreamSlotID(rawValue: 0)),
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
            preferredUpstream: UpstreamSlotID(rawValue: 0),
            nowUptimeNanoseconds: 1
        ))
        let (background, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstream: UpstreamSlotID(rawValue: 0),
            nowUptimeNanoseconds: 2
        ))
        #expect(foreground.attempt == background.attempt)
        #expect(foreground != background)

        let foregroundRPC = ControlPlane.RPCHandle()
        let backgroundRPC = ControlPlane.RPCHandle()
        _ = authority.attach(.rpc(foregroundRPC), to: foreground)
        _ = authority.attach(.rpc(backgroundRPC), to: background)
        guard case .accepted = authority.completeCatalog(
            .usable(catalog("Foreground"), source: UpstreamSlotID(rawValue: 0)),
            lease: foreground,
            nowUptimeNanoseconds: 3
        ) else {
            Issue.record("first logical load should commit")
            return
        }
        #expect(backgroundRPC.isCancelled() == false)
        #expect(authority.validateCatalogLoad(background) == false)
        guard case .discarded(let reason, _) = authority.completeCatalog(
            .usable(catalog("Background"), source: UpstreamSlotID(rawValue: 0)),
            lease: background,
            nowUptimeNanoseconds: 4
        ) else {
            Issue.record("sibling completion should be stale")
            return
        }
        #expect(reason == .attemptNotLoading)
        #expect(toolNames(authority.canonicalToolsCatalogRaw()) == ["Foreground"])
    }

    @Test func unrelatedRouteAdditionDoesNotInvalidateInFlightCatalogLoad() throws {
        let first = xcodeProcessTarget(processID: 41014, xcodeVersion: "27.0")
        let second = xcodeProcessTarget(processID: 41015, xcodeVersion: "26.4")
        let authority = makeAuthority([(first, [0])])
        let route = try #require(authority.route(forProcessID: first.processID))
        let epoch = authority.currentCatalogEpoch()
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstream: UpstreamSlotID(rawValue: 0),
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
            .usable(catalog("StillCurrent"), source: UpstreamSlotID(rawValue: 0)),
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
            upstreamIndex: 0,
            nowUptimeNs: 1,
            readinessToken: oldToken
        )).0
        #expect(authority.reserveActivation(
            routeID: route.id,
            upstreamIndex: 0,
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
            upstreamIndex: 0,
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

    @Test func windowUpdatesDoNotInvalidateCatalogLease() throws {
        let target = xcodeProcessTarget(processID: 41004, xcodeVersion: "27.0")
        let authority = makeAuthority([(target, [0])])
        let route = try #require(authority.route(forProcessID: target.processID))
        let (lease, _) = try #require(authority.beginCatalogAttempt(
            routeID: route.id,
            preferredUpstream: UpstreamSlotID(rawValue: 0),
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
            .usable(catalog("WindowTool"), source: UpstreamSlotID(rawValue: 0)),
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
        let requestID = router.assign(
            upstreamIndex: 0,
            sessionID: "session",
            originalID: JSONRPC.ID(any: 1)!,
            isInitialize: false
        )
        #expect(requestID != 0)
        #expect(health.beginWarmInitialize(upstreamIndex: 0))

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
        #expect(router.consume(upstreamIndex: 0, upstreamID: requestID) == nil)
        #expect(
            health.activeStatesSnapshot().first { $0.id == UpstreamSlotID(rawValue: 0) }?
                .state.initInFlight == false
        )
        let replacementInitializeID = router.assignInitialize(upstreamIndex: 0)
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
        #expect(router.assignInitialize(upstreamIndex: 1) == 0)

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

    @Test func catalogActivationSuccessAndTimeoutHaveSingleTerminalWinner() throws {
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

        let terminalWinners = NIOLockedValueBox<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 2) { contender in
            _ = topology.withValidated(proof) {
                if contender == 0 {
                    switch health.commitCatalogActivation(upstreamIndex: 0, commit: { _ in
                        .complete
                    }) {
                    case .completed:
                        terminalWinners.withLockedValue { $0.append("success") }
                    case .notOwned, .kept:
                        break
                    }
                    return
                }
                if health.timeoutCatalogActivation(claim, commit: { _ in true }) != nil {
                    terminalWinners.withLockedValue { $0.append("timeout") }
                }
            }
        }

        #expect(terminalWinners.withLockedValue(\.count) == 1)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        ]
        let manager = FileManager.default
        var source = ""
        for root in roots {
            let enumerator = try #require(manager.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard url.path != #filePath else { continue }
                source += try String(contentsOf: url, encoding: .utf8)
            }
        }
        for symbol in forbidden {
            #expect(source.contains(symbol) == false, "legacy Task A symbol remains: \(symbol)")
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
            preferredUpstream: UpstreamSlotID(rawValue: upstream),
            nowUptimeNanoseconds: 1
        ))
        guard case .accepted = authority.completeCatalog(
            .usable(catalog, source: UpstreamSlotID(rawValue: upstream)),
            lease: lease,
            nowUptimeNanoseconds: 2
        ) else {
            Issue.record("failed to seed process catalog")
            return
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
