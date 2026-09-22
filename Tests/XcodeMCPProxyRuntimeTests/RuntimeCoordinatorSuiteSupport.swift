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

func firstTabIdentifier(in message: String) -> String? {
    for line in message.split(separator: "\n") {
        let prefix = "* tabIdentifier: "
        guard line.hasPrefix(prefix),
            let delimiter = line.range(of: ", workspacePath: ")
        else {
            continue
        }
        return String(line[line.index(line.startIndex, offsetBy: prefix.count)..<delimiter.lowerBound])
    }
    return nil
}

func tabIdentifier(in data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
        let params = object["params"] as? [String: Any],
        let arguments = params["arguments"] as? [String: Any]
    else {
        return nil
    }
    return arguments["tabIdentifier"] as? String
}

final class ConcurrentSequencedXcodeTargetDiscovery:
    XcodeTargetDiscovering,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let actionQueue = DispatchQueue(
        label: "XcodeMCPKitTests.ConcurrentSequencedXcodeTargetDiscovery"
    )
    private let firstTargets: [XcodeProcessTarget]
    private let secondTargets: [XcodeProcessTarget]
    private var callCountValue = 0
    private var firstCallAction: (@Sendable () -> Void)?

    init(
        firstTargets: [XcodeProcessTarget],
        secondTargets: [XcodeProcessTarget]
    ) {
        self.firstTargets = firstTargets
        self.secondTargets = secondTargets
    }

    func runningXcodeTargets() -> [XcodeProcessTarget] {
        let result: (targets: [XcodeProcessTarget], action: (@Sendable () -> Void)?) =
            lock.withLock {
                callCountValue += 1
                guard callCountValue == 1 else {
                    return (targets: secondTargets, action: nil)
                }
                let action = firstCallAction
                firstCallAction = nil
                return (targets: firstTargets, action: action)
            }
        guard let action = result.action else {
            return result.targets
        }
        let actionFinished = DispatchSemaphore(value: 0)
        // Do not replace this with Task.detached: it shares the cooperative executor that
        // runningXcodeTargets() intentionally occupies while the external trigger runs.
        actionQueue.async {
            defer { actionFinished.signal() }
            action()
        }
        guard actionFinished.wait(timeout: .now() + 5) == .success else {
            Issue.record("concurrent reconcile action did not complete")
            return result.targets
        }
        return result.targets
    }

    func setFirstCallAction(_ action: @escaping @Sendable () -> Void) {
        lock.withLock {
            precondition(firstCallAction == nil)
            precondition(callCountValue == 0)
            firstCallAction = action
        }
    }

    func callCount() -> Int {
        lock.withLock { callCountValue }
    }
}

final class StartupChangingXcodeProcessMonitor:
    XcodeProcessEventMonitoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let firstTargets: [XcodeProcessTarget]
    private let latestTargets: [XcodeProcessTarget]
    private var changeHandler: (@Sendable (String) -> Void)?
    private var callCount = 0

    init(
        firstTargets: [XcodeProcessTarget],
        latestTargets: [XcodeProcessTarget]
    ) {
        self.firstTargets = firstTargets
        self.latestTargets = latestTargets
    }

    func start() {}

    func setChangeHandler(
        _ handler: @escaping @Sendable (String) -> Void
    ) {
        lock.withLock {
            changeHandler = handler
        }
    }

    func runningXcodeTargets() -> [XcodeProcessTarget] {
        let result = lock.withLock {
            () -> (
                targets: [XcodeProcessTarget],
                handler: (@Sendable (String) -> Void)?
            ) in
            callCount += 1
            return callCount == 1
                ? (firstTargets, changeHandler)
                : (latestTargets, nil)
        }
        result.handler?("inventory_changed_during_startup")
        return result.targets
    }

    func discoveryCallCount() -> Int {
        lock.withLock { callCount }
    }

    func permissionDialogProcessIDs() -> [pid_t] {
        []
    }

    func readinessSnapshot() -> UpstreamReadinessSnapshot {
        UpstreamReadinessSnapshot(isReady: true, generation: 0)
    }

    func waitForReadinessChange(after _: UInt64) async {}

    func stop() {
        lock.withLock {
            changeHandler = nil
        }
    }
}

final class StartRecordingXcodeProcessMonitor:
    XcodeProcessEventMonitoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var changeHandlers = 0

    func start() {
        lock.withLock { starts += 1 }
    }

    func setChangeHandler(
        _: @escaping @Sendable (String) -> Void
    ) {
        lock.withLock { changeHandlers += 1 }
        start()
    }

    func runningXcodeTargets() -> [XcodeProcessTarget] { [] }

    func permissionDialogProcessIDs() -> [pid_t] { [] }

    func readinessSnapshot() -> UpstreamReadinessSnapshot {
        UpstreamReadinessSnapshot(isReady: false, generation: 0)
    }

    func waitForReadinessChange(after _: UInt64) async {}

    func stop() {
        lock.withLock { stops += 1 }
    }

    func startCount() -> Int {
        lock.withLock { starts }
    }

    func stopCount() -> Int {
        lock.withLock { stops }
    }

    func changeHandlerCount() -> Int {
        lock.withLock { changeHandlers }
    }
}

final class RecordingXcodeTargetDiscovery: XcodeTargetDiscovering, @unchecked Sendable {
    let calls = LockedRecordedValues<Int>()

    private let lock = NSLock()
    private let targets: [XcodeProcessTarget]
    private var callCountValue = 0

    init(targets: [XcodeProcessTarget]) {
        self.targets = targets
    }

    func runningXcodeTargets() -> [XcodeProcessTarget] {
        let call = lock.withLock {
            callCountValue += 1
            return callCountValue
        }
        calls.append(call)
        return targets
    }
}

func paginatedToolsResponse(request: Data, names: [String], nextCursor: JSONValue? = nil) throws -> Data {
    var result: [String: JSONValue] = ["tools": .array(names.map { .object(["name": .string($0)]) })]
    result["nextCursor"] = nextCursor
    return try JSONRPC.Wire.resultResponseData(
        id: JSONRPC.ID(any: try extractUpstreamID(from: request))!, result: .object(result)
    )
}
