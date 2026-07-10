import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
import XcodeMCPKit
@testable import XcodeMCPProxyKit

@Suite
struct ProxyUpstreamRequestRuntimeTests {
    @Test func prepareRequestSelectsUpstreamAndAssignsRuntimeIDs() throws {
        let port = RecordingUpstreamRuntimePort(chosenUpstreamIndex: 2)
        let runtime = ProxyUpstreamRequestRuntime(port: port)
        let requestData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": "client-1",
                "method": "tools/list",
            ],
            options: []
        )
        let parsed = try JSONSerialization.jsonObject(with: requestData, options: [])

        let prepared = try #require(
            try runtime.prepareRequest(
                bodyData: requestData,
                parsedRequestJSON: parsed,
                sessionID: "session-1"
            )
        )

        #expect(prepared.upstreamIndex == 2)
        #expect(port.assignments() == [
            RecordingUpstreamRuntimePort.Assignment(
                sessionID: "session-1",
                requestIDKey: "client-1",
                upstreamIndex: 2
            )
        ])
        let upstreamObject = try #require(
            try JSONSerialization.jsonObject(
                with: prepared.transform.upstreamData,
                options: []
            ) as? [String: Any]
        )
        let upstreamID = try #require(upstreamObject["id"] as? NSNumber)
        #expect(upstreamID.int64Value == 100)
    }

    @Test func startRequestRegistersPendingActivatesLeaseAndSends() throws {
        let port = RecordingUpstreamRuntimePort(chosenUpstreamIndex: 1)
        let runtime = ProxyUpstreamRequestRuntime(port: port)
        let requestData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": "client-2",
                "method": "tools/list",
            ],
            options: []
        )
        let parsed = try JSONSerialization.jsonObject(with: requestData, options: [])
        let prepared = try #require(
            try runtime.prepareRequest(
                bodyData: requestData,
                parsedRequestJSON: parsed,
                sessionID: "session-2"
            )
        )
        let eventLoop = EmbeddedEventLoop()
        let router = JSONRPCResponseRouter(
            requestTimeout: nil,
            hasActiveClients: { false },
            sendNotification: { _ in }
        )
        let leaseID = LeaseManager.ID()
        let registered = NIOLockedValueBox<ProxyUpstreamRequestRuntime.StartedRegistration?>(nil)

        let started = try runtime.startRequest(
            prepared,
            router: router,
            on: eventLoop,
            requestTimeout: .seconds(3),
            leaseID: leaseID,
            onRegistered: { registration in
                registered.withLockedValue { $0 = registration }
            }
        )

        #expect(registered.withLockedValue { $0?.routerPendingToken } == started.routerPendingToken)
        #expect(registered.withLockedValue { $0?.upstreamIndex } == 1)
        #expect(port.activations() == [
            RecordingUpstreamRuntimePort.Activation(
                leaseID: leaseID,
                requestIDKey: "client-2",
                upstreamIndex: 1,
                timeout: .seconds(3)
            )
        ])
        #expect(port.sentRequests().map(\.upstreamIndex) == [1])

        let responseData = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": "client-2",
                "result": ["ok": true],
            ],
            options: []
        )
        router.handleIncoming(responseData)
        eventLoop.run()
        var buffer = try started.future.wait()
        let readBytes = buffer.readBytes(length: buffer.readableBytes)
        let responseBytes = try #require(readBytes)
        #expect(Data(responseBytes) == responseData)
    }

    @Test func completionAccountingCoversAllResponseIDs() throws {
        let port = RecordingUpstreamRuntimePort(chosenUpstreamIndex: 0)
        let runtime = ProxyUpstreamRequestRuntime(port: port)
        let requestData = try JSONSerialization.data(
            withJSONObject: [
                [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "tools/list",
                ],
                [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/list",
                ],
            ],
            options: []
        )
        let parsed = try JSONSerialization.jsonObject(with: requestData, options: [])
        let prepared = try #require(
            try runtime.prepareRequest(
                bodyData: requestData,
                parsedRequestJSON: parsed,
                sessionID: "session-3"
            )
        )
        let eventLoop = EmbeddedEventLoop()
        let started = ProxyUpstreamRequestRuntime.StartedRequest(
            transform: prepared.transform,
            operationLease: prepared.operationLease,
            requestTimeout: nil,
            routerPendingToken: UUID(),
            future: eventLoop.makeSucceededFuture(ByteBuffer())
        )

        runtime.recordRequestSucceeded(sessionID: "session-3", started: started)
        #expect(port.successes().map(\.requestIDKey) == ["1", "2"])

        runtime.recordRequestTimedOut(
            sessionID: "session-3",
            started: started,
            accountTimeout: true
        )
        #expect(port.timeouts().map(\.requestIDKey) == ["1"])
        #expect(port.removals().map(\.requestIDKey) == ["2"])

        let alreadyAccountedPort = RecordingUpstreamRuntimePort(chosenUpstreamIndex: 0)
        let alreadyAccountedRuntime = ProxyUpstreamRequestRuntime(port: alreadyAccountedPort)
        let alreadyAccountedPrepared = try #require(
            try alreadyAccountedRuntime.prepareRequest(
                bodyData: requestData,
                parsedRequestJSON: parsed,
                sessionID: "session-4"
            )
        )
        let alreadyAccountedStarted = ProxyUpstreamRequestRuntime.StartedRequest(
            transform: alreadyAccountedPrepared.transform,
            operationLease: alreadyAccountedPrepared.operationLease,
            requestTimeout: nil,
            routerPendingToken: UUID(),
            future: eventLoop.makeSucceededFuture(ByteBuffer())
        )
        alreadyAccountedRuntime.recordRequestTimedOut(
            sessionID: "session-4",
            started: alreadyAccountedStarted,
            accountTimeout: false
        )
        #expect(alreadyAccountedPort.timeouts().isEmpty)
        #expect(alreadyAccountedPort.removals().map(\.requestIDKey) == ["1", "2"])
    }
}

private final class RecordingUpstreamRuntimePort: ProxyUpstreamRequestRuntimePort {
    struct Assignment: Equatable, Sendable {
        let sessionID: String
        let requestIDKey: String
        let upstreamIndex: Int
    }

    struct Activation: Equatable, Sendable {
        let leaseID: LeaseManager.ID
        let requestIDKey: String?
        let upstreamIndex: Int?
        let timeout: TimeAmount?
    }

    struct SentRequest: Equatable, Sendable {
        let data: Data
        let upstreamIndex: Int
        let ensureRunning: Bool
    }

    struct RequestEvent: Equatable, Sendable {
        let sessionID: String
        let requestIDKey: String
        let upstreamIndex: Int
    }

    private struct State: Sendable {
        var chosenUpstreamIndex: Int?
        var nextID: Int64 = 100
        var assignments: [Assignment] = []
        var activations: [Activation] = []
        var sentRequests: [SentRequest] = []
        var removals: [RequestEvent] = []
        var timeouts: [RequestEvent] = []
        var successes: [RequestEvent] = []
    }

    private let state: NIOLockedValueBox<State>
    private let topology: UpstreamTopologyAuthority

    init(chosenUpstreamIndex: Int?) {
        self.state = NIOLockedValueBox(State(chosenUpstreamIndex: chosenUpstreamIndex))
        let count = chosenUpstreamIndex.map { max(1, $0 + 1) } ?? 0
        self.topology = UpstreamTopologyAuthority(
            (0..<count).map { _ in TestOperationSlot() as any UpstreamSlotControlling }
        )
    }

    func chooseUpstreamOperationLease() -> UpstreamOperationLease? {
        state.withLockedValue { state in
            state.chosenUpstreamIndex.flatMap {
                topology.operationLease(for: UpstreamSlotID(rawValue: $0))
            }
        }
    }

    func assignUpstreamID(
        sessionID: String,
        originalID: JSONRPC.ID,
        operationLease: UpstreamOperationLease
    ) -> Int64? {
        state.withLockedValue { state in
            let id = state.nextID
            state.nextID += 1
            state.assignments.append(
                Assignment(
                    sessionID: sessionID,
                    requestIDKey: originalID.key,
                    upstreamIndex: operationLease.upstreamIndex
                )
            )
            return id
        }
    }

    func removeUpstreamIDMapping(
        sessionID: String,
        requestIDKey: String,
        operationLease: UpstreamOperationLease
    ) {
        state.withLockedValue { state in
            state.removals.append(
                RequestEvent(
                    sessionID: sessionID,
                    requestIDKey: requestIDKey,
                    upstreamIndex: operationLease.upstreamIndex
                )
            )
        }
    }

    func onRequestTimeout(
        sessionID: String,
        requestIDKey: String,
        operationLease: UpstreamOperationLease
    ) {
        state.withLockedValue { state in
            state.timeouts.append(
                RequestEvent(
                    sessionID: sessionID,
                    requestIDKey: requestIDKey,
                    upstreamIndex: operationLease.upstreamIndex
                )
            )
        }
    }

    func onRequestSucceeded(
        sessionID: String,
        requestIDKey: String,
        operationLease: UpstreamOperationLease
    ) {
        state.withLockedValue { state in
            state.successes.append(
                RequestEvent(
                    sessionID: sessionID,
                    requestIDKey: requestIDKey,
                    upstreamIndex: operationLease.upstreamIndex
                )
            )
        }
    }

    func sendUpstream(
        _ data: Data,
        operationLease: UpstreamOperationLease,
        ensureRunning: Bool,
        admission _: RouteForwardingAdmission?,
        onRejected _: @escaping @Sendable () -> Void
    ) -> Bool {
        state.withLockedValue { state in
            state.sentRequests.append(
                SentRequest(
                    data: data,
                    upstreamIndex: operationLease.upstreamIndex,
                    ensureRunning: ensureRunning
                )
            )
        }
        return true
    }

    func activateRequestLease(
        _ leaseID: LeaseManager.ID,
        requestIDKey: String?,
        upstreamIndex: Int?,
        timeout: TimeAmount?
    ) {
        state.withLockedValue { state in
            state.activations.append(
                Activation(
                    leaseID: leaseID,
                    requestIDKey: requestIDKey,
                    upstreamIndex: upstreamIndex,
                    timeout: timeout
                )
            )
        }
    }

    func assignments() -> [Assignment] {
        state.withLockedValue { $0.assignments }
    }

    func activations() -> [Activation] {
        state.withLockedValue { $0.activations }
    }

    func sentRequests() -> [SentRequest] {
        state.withLockedValue { $0.sentRequests }
    }

    func removals() -> [RequestEvent] {
        state.withLockedValue { $0.removals }
    }

    func timeouts() -> [RequestEvent] {
        state.withLockedValue { $0.timeouts }
    }

    func successes() -> [RequestEvent] {
        state.withLockedValue { $0.successes }
    }
}

private actor TestOperationSlot: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event> = AsyncStream { _ in }

    func start() async {}
    func stop() async {}
    func send(_ data: Data) async -> Upstream.SendResult { .accepted }
}
