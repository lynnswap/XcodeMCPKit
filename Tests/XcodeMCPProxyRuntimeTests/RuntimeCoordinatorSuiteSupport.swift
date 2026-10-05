@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

func seedCoordinatorSuiteInitialize(
    on manager: RuntimeCoordinator,
    result: JSONValue,
    sourceUpstream: Int
) {
    let slotID = UpstreamSlotID(rawValue: sourceUpstream)
    guard let health = manager.upstreamHealthManager.state(for: slotID),
        health.isInitialized,
        case .healthy = health.healthState
    else {
        preconditionFailure("canonical initialize fixture requires a healthy initialized source")
    }
    let proof = manager.operationLeaseForTest(upstreamIndex: sourceUpstream).proof
    guard
        case .accepted(let participant) = manager.canonicalHandshakeState
            .offerInitializeResult(result, sourceProof: proof)
    else {
        preconditionFailure("canonical initialize fixture result is incompatible")
    }
    switch manager.canonicalHandshakeState.commitInitializeParticipant(participant) {
    case .published, .joined:
        return
    case .incompatible, .stale:
        preconditionFailure("canonical initialize fixture commit was rejected")
    }
}

enum UpstreamSlotOccupationOutcome: Sendable {
    case activated(upstreamIndex: Int)
    case failed(String)
}

struct UpstreamSlotOccupationError: Error, CustomStringConvertible, Sendable {
    let description: String
}

@discardableResult
func occupyUpstreamSlot(
    on manager: RuntimeCoordinator,
    leaseID: LeaseManager.ID,
    descriptor: SessionRequestPipeline.Descriptor,
    eventLoop: EventLoop,
    completionPromise: EventLoopPromise<Void>,
    requestIDKey: String? = nil
) async throws -> Int {
    let outcomes = LockedRecordedValues<UpstreamSlotOccupationOutcome>()
    let future: EventLoopFuture<Void> = manager.enqueueOnUpstreamSlot(
        leaseID: leaseID,
        descriptor: descriptor,
        on: eventLoop
    ) { selectedUpstream in
        manager.activateRequestLease(
            leaseID,
            requestIDKey: requestIDKey,
            upstreamIndex: selectedUpstream.upstreamIndex,
            timeout: nil
        )
        outcomes.append(.activated(upstreamIndex: selectedUpstream.upstreamIndex))
        return completionPromise.futureResult
    }
    future.whenFailure { error in
        outcomes.append(.failed(String(describing: error)))
    }

    let outcome = try await waitForRecordedValue(
        outcomes,
        at: 0,
        description: "waiting for upstream slot occupation",
        timeout: .seconds(5)
    )
    switch outcome {
    case .activated(let upstreamIndex):
        return upstreamIndex
    case .failed(let description):
        throw UpstreamSlotOccupationError(description: description)
    }
}

actor AutoToolsListUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let sentMessages = RecordedValues<Data>()
    private let toolNames: [String]

    init(toolNames: [String]) {
        self.toolNames = toolNames
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        await sentMessages.append(data)
        guard methodName(from: data) == "tools/list",
            let upstreamID = try? extractUpstreamID(from: data),
            let response = try? makeDocumentationToolsListResponse(
                id: upstreamID,
                tools: toolNames.map { toolDescriptor(name: $0) }
            )
        else {
            return .accepted
        }
        continuation.yield(.message(response))
        return .accepted
    }

    func sentCount() async -> Int {
        await sentMessages.count()
    }
}

func paginatedToolsResponse(request: Data, names: [String], nextCursor: JSONValue? = nil) throws -> Data {
    var result: [String: JSONValue] = ["tools": .array(names.map { .object(["name": .string($0)]) })]
    result["nextCursor"] = nextCursor
    return try JSONRPC.Wire.resultResponseData(
        id: JSONRPC.ID(any: try extractUpstreamID(from: request))!, result: .object(result)
    )
}
