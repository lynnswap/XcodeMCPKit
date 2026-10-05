@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Foundation
import NIO
import NIOConcurrencyHelpers
import Testing
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
            isLeaseLive: { _ in true },
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
