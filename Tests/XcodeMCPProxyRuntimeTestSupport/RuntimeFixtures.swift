import Foundation
import NIOCore
import Testing
import XcodeMCPCore
import XcodeMCPProxyTestSupport
@testable import XcodeMCPProxyRuntime

extension UpstreamHealthManager {
    func markRequestTimedOut(
        upstreamIndex: Int,
        nowUptimeNs: UInt64
    ) -> (shouldClearPins: Bool, timeoutCount: Int) {
        guard let proof = topologyProof(for: upstreamIndex) else { return (false, 0) }
        return markRequestTimedOut(proof, nowUptimeNs: nowUptimeNs)
    }

    func beginWarmInitialize(upstreamIndex: Int) -> Bool {
        claimWarmInitialize(upstreamIndex: upstreamIndex) != nil
    }

    func markInitInFlight(upstreamIndex: Int, upstreamID: Int64) {
        guard let claim = claimWarmInitialize(upstreamIndex: upstreamIndex) else { return }
        guard beginInitializeSend(claim) else { return }
        _ = setWarmInitializeUpstreamID(upstreamID, for: claim)
    }

    func clearUpstreamState(
        upstreamIndex: Int,
        expectedUpstreamID: Int64? = nil
    ) -> ClearedUpstreamState? {
        guard let proof = topologyProof(for: upstreamIndex) else { return nil }
        return clearUpstreamState(proof, expectedUpstreamID: expectedUpstreamID)
    }

    func markInitialized(
        upstreamIndex: Int,
        expectedUpstreamID: Int64? = nil
    ) -> UpstreamHealthManager.MarkInitializedTransition? {
        guard let proof = topologyProof(for: upstreamIndex) else { return nil }
        return markInitialized(proof, expectedUpstreamID: expectedUpstreamID)
    }
}

extension RuntimeCoordinator {
    func operationLeaseForTest(upstreamIndex: Int) -> UpstreamOperationLease {
        guard let lease = upstreamTopology.operationLease(
            for: UpstreamSlotID(rawValue: upstreamIndex)
        ) else {
            preconditionFailure("missing test upstream lease \(upstreamIndex)")
        }
        return lease
    }

    func routeUpstreamMessage(_ data: Data, upstreamIndex: Int) {
        routeUpstreamMessage(
            data,
            upstreamIndex: upstreamIndex,
            proof: operationLeaseForTest(upstreamIndex: upstreamIndex).proof
        )
    }

    func handleUpstreamExit(_ status: Int32, upstreamIndex: Int) {
        handleUpstreamExit(
            status,
            upstreamIndex: upstreamIndex,
            proof: operationLeaseForTest(upstreamIndex: upstreamIndex).proof
        )
    }

    func handleUpstreamProtocolViolation(
        _ protocolViolation: StdioFramer.ProtocolViolation,
        upstreamIndex: Int
    ) {
        handleUpstreamProtocolViolation(
            protocolViolation,
            upstreamIndex: upstreamIndex,
            proof: operationLeaseForTest(upstreamIndex: upstreamIndex).proof
        )
    }

    @discardableResult
    func clearUpstreamState(upstreamIndex: Int, expectedUpstreamID: Int64? = nil) -> Bool {
        clearUpstreamState(
            proof: operationLeaseForTest(upstreamIndex: upstreamIndex).proof,
            expectedUpstreamID: expectedUpstreamID
        )
    }

    func assignUpstreamID(
        sessionID: String,
        originalID: JSONRPC.ID,
        upstreamIndex: Int
    ) -> Int64 {
        guard let id = assignUpstreamID(
            sessionID: sessionID,
            originalID: originalID,
            operationLease: operationLeaseForTest(upstreamIndex: upstreamIndex)
        ) else {
            preconditionFailure("failed to assign test upstream id")
        }
        return id
    }

    func sendUpstream(_ data: Data, upstreamIndex: Int, ensureRunning: Bool = false) {
        _ = sendUpstream(
            data,
            operationLease: operationLeaseForTest(upstreamIndex: upstreamIndex),
            ensureRunning: ensureRunning,
            onRejected: {}
        )
    }

    func markToolsListRefreshFailed(
        upstreamIndex: Int,
        nowUptimeNs: UInt64,
        reason: String
    ) {
        markToolsListRefreshFailed(
            operationLeaseForTest(upstreamIndex: upstreamIndex).proof,
            nowUptimeNs: nowUptimeNs,
            reason: reason
        )
    }

    func onRequestTimeout(
        sessionID: String,
        requestIDKey: String,
        upstreamIndex: Int
    ) {
        onRequestTimeout(
            sessionID: sessionID,
            requestIDKey: requestIDKey,
            operationLease: operationLeaseForTest(upstreamIndex: upstreamIndex)
        )
    }

    func handleRequestLeaseTimeout(
        _ leaseID: LeaseManager.ID,
        sessionID: String,
        requestIDKeys: [String],
        upstreamIndex: Int
    ) {
        handleRequestLeaseTimeout(
            leaseID,
            sessionID: sessionID,
            requestIDKeys: requestIDKeys,
            operationLease: operationLeaseForTest(upstreamIndex: upstreamIndex)
        )
    }

    func abandonRequestLease(
        _ leaseID: LeaseManager.ID,
        sessionID: String,
        requestIDKeys: [String],
        upstreamIndex: Int?
    ) {
        abandonRequestLease(
            leaseID,
            sessionID: sessionID,
            requestIDKeys: requestIDKeys,
            operationLease: upstreamIndex.map(operationLeaseForTest(upstreamIndex:))
        )
    }

    func markUpstreamInitialized(upstreamIndex: Int) {
        guard let proof = upstreamTopology.operationLease(
            for: UpstreamSlotID(rawValue: upstreamIndex)
        )?.proof,
              let result = upstreamHealthManager.markInitialized(proof) else { return }
        result.timeout?.cancel()
        testHooks.upstreamInitialized?(upstreamIndex)
        noteUpstreamInitializationSucceeded()
    }

    /// Test-only `defer` hook that requires an `AsyncTestCleanupTrait` scope.
    func shutdownAndWait() {
        precondition(
            registerAsyncTestCleanup(
                description: "RuntimeCoordinator shutdown failed",
                operation: { [self] in await shutdown() }
            ),
            "shutdownAndWait requires an AsyncTestCleanupTrait scope"
        )
    }

    func drainRuntimeTasksForTesting() async {
        await runtimeTasks.waitUntilIdle()
    }

    func drainControlPlaneLoadsForTesting() async {
        await controlPlaneCoordinator.drainLoadsForTesting()
    }

    func seedCanonicalToolsCatalog(_ result: JSONValue, sourceUpstream: Int) {
        let proof = operationLeaseForTest(upstreamIndex: sourceUpstream).proof
        let (lease, transition) = toolsCatalog.beginLoad(sourceProof: proof)
        applyCatalogTransition(transition)
        switch toolsCatalog.complete(ToolCatalogProvider(sourceProof: proof, rawResult: result), lease: lease) {
        case .accepted(_, let transition), .discarded(let transition):
            applyCatalogTransition(transition)
        }
    }

    func clearCanonicalToolsCatalogForTesting() {
        applyCatalogTransition(toolsCatalog.invalidate())
    }
}

func responseID(in responseData: Data) throws -> Int64 {
    let object = try #require(
        JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any]
    )
    let id = try #require(object["id"] as? NSNumber)
    return id.int64Value
}

func upstreamEnvironment(from upstream: ManagedUpstreamSlot) throws -> [String: String] {
    let configMirror = try upstreamConfigMirror(from: upstream)
    return try upstreamEnvironment(fromConfigMirror: configMirror)
}

func upstreamEnvironment(from factory: any UpstreamSessionFactory) throws -> [String: String] {
    let configMirror = try upstreamConfigMirror(from: factory)
    return try upstreamEnvironment(fromConfigMirror: configMirror)
}

private func upstreamEnvironment(fromConfigMirror configMirror: Mirror) throws -> [String: String] {
    return try #require(
        configMirror.children.first(where: { $0.label == "environment" })?.value
            as? [String: String],
        "UpstreamProcess.Config should include environment for tests"
    )
}

func upstreamMaxQueuedWriteBytes(from factory: any UpstreamSessionFactory) throws -> Int {
    let configMirror = try upstreamConfigMirror(from: factory)
    return try #require(
        configMirror.children.first(where: { $0.label == "maxQueuedWriteBytes" })?.value as? Int,
        "UpstreamProcess.Config should include maxQueuedWriteBytes for tests"
    )
}

func upstreamCommand(from upstream: ManagedUpstreamSlot) throws -> String {
    let configMirror = try upstreamConfigMirror(from: upstream)
    return try upstreamCommand(fromConfigMirror: configMirror)
}

func upstreamCommand(from factory: any UpstreamSessionFactory) throws -> String {
    let configMirror = try upstreamConfigMirror(from: factory)
    return try upstreamCommand(fromConfigMirror: configMirror)
}

private func upstreamCommand(fromConfigMirror configMirror: Mirror) throws -> String {
    return try #require(
        configMirror.children.first(where: { $0.label == "command" })?.value as? String,
        "UpstreamProcess.Config should include command for tests"
    )
}

func upstreamArgs(from upstream: ManagedUpstreamSlot) throws -> [String] {
    let configMirror = try upstreamConfigMirror(from: upstream)
    return try upstreamArgs(fromConfigMirror: configMirror)
}

func upstreamArgs(from factory: any UpstreamSessionFactory) throws -> [String] {
    let configMirror = try upstreamConfigMirror(from: factory)
    return try upstreamArgs(fromConfigMirror: configMirror)
}

private func upstreamArgs(fromConfigMirror configMirror: Mirror) throws -> [String] {
    return try #require(
        configMirror.children.first(where: { $0.label == "args" })?.value as? [String],
        "UpstreamProcess.Config should include args for tests"
    )
}

private func upstreamConfigMirror(from upstream: ManagedUpstreamSlot) throws -> Mirror {
    let upstreamMirror = Mirror(reflecting: upstream)
    let factory = try #require(
        upstreamMirror.children.first(where: { $0.label == "factory" })?.value,
        "ManagedUpstreamSlot should expose a stored factory for tests"
    )
    let typedFactory = try #require(factory as? any UpstreamSessionFactory)
    return try upstreamConfigMirror(from: typedFactory)
}

private func upstreamConfigMirror(from factory: any UpstreamSessionFactory) throws -> Mirror {
    if let factory = factory as? NativeHostSessionFactory {
        return Mirror(reflecting: try factory.processConfiguration(environment: factory.environment))
    }
    let factoryMirror = Mirror(reflecting: factory)
    let config = try #require(
        factoryMirror.children.first(where: { $0.label == "config" })?.value,
        "UpstreamProcess factory should expose a stored config for tests"
    )
    return Mirror(reflecting: config)
}

actor ToggleableOverloadUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let sentMessages = RecordedValues<Data>()
    private var overloaded = false
    private var overloadBudget = 0
    private var overloadNextInitializedNotification = false

    init() {
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

    func setOverloaded(_ value: Bool) {
        overloaded = value
    }

    func overloadNextSend() {
        overloadBudget &+= 1
    }

    func overloadNextInitializedNotificationSend() {
        overloadNextInitializedNotification = true
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        await sentMessages.append(data)
        if overloadNextInitializedNotification,
            methodName(from: data) == "notifications/initialized"
        {
            overloadNextInitializedNotification = false
            return .backpressure
        }
        if overloadBudget > 0 {
            overloadBudget -= 1
            return .backpressure
        }
        return overloaded ? .backpressure : .accepted
    }

    func yield(_ event: Upstream.Event) async {
        continuation.yield(event)
    }

    func sent() async -> [Data] {
        await sentMessages.snapshot()
    }

    func sentCount() async -> Int {
        await sentMessages.count()
    }

    func sentValue(at index: Int) async -> Data? {
        await sentMessages.value(at: index)
    }

    func nextSent(at index: Int) async throws -> Data {
        try await sentMessages.nextValue(at: index)
    }

    func nextSent(
        startingAt index: Int,
        matching predicate: @escaping @Sendable (Data) -> Bool
    ) async throws -> Data {
        try await sentMessages.nextValue(startingAt: index, matching: predicate)
    }
}

func makeInitializeResponse(id: Int64) throws -> Data {
    try makeInitializeResponse(id: id, serverName: nil)
}

func makeInitializeResponse(id: Int64, serverName: String?) throws -> Data {
    var result: [String: Any] = [
        "protocolVersion": MCP.ProtocolVersion.current,
        "capabilities": [String: Any]()
    ]
    if let serverName {
        result["serverInfo"] = ["name": serverName]
    }
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "result": result,
    ]
    return try JSONSerialization.data(withJSONObject: response, options: [])
}

protocol InitializableTestUpstream: AnyObject, Sendable {
    func nextSent(at index: Int) async throws -> Data
    func yield(_ event: Upstream.Event) async
}

extension TestUpstreamClient: InitializableTestUpstream {}
extension ToggleableOverloadUpstreamClient: InitializableTestUpstream {}
extension BlockingInitializedNotificationUpstreamClient: InitializableTestUpstream {}

func methodName(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    else {
        return nil
    }
    return object["method"] as? String
}

func sentValue(
    from upstream: TestUpstreamClient,
    at index: Int,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    try await waitWithTimeout(
        "waiting for sent message \(index + 1)",
        timeout: timeout
    ) {
        try await upstream.nextSent(at: index)
    }
}

func sentValue(
    from upstream: ToggleableOverloadUpstreamClient,
    at index: Int,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    try await waitWithTimeout(
        "waiting for sent message \(index + 1)",
        timeout: timeout
    ) {
        try await upstream.nextSent(at: index)
    }
}

func sentValue(
    from upstream: BlockingInitializedNotificationUpstreamClient,
    at index: Int,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    try await waitWithTimeout(
        "waiting for sent message \(index + 1)",
        timeout: timeout
    ) {
        try await upstream.nextSent(at: index)
    }
}

func sentValue(
    from upstream: TestUpstreamClient,
    startingAt index: Int,
    matching predicate: @escaping @Sendable (Data) -> Bool,
    timeout: Duration = .seconds(5),
    description: String = "waiting for matching sent message"
) async throws -> Data {
    try await waitWithTimeout(description, timeout: timeout) {
        try await upstream.nextSent(startingAt: index, matching: predicate)
    }
}

func sentValue(
    from upstream: ToggleableOverloadUpstreamClient,
    startingAt index: Int,
    matching predicate: @escaping @Sendable (Data) -> Bool,
    timeout: Duration = .seconds(5),
    description: String = "waiting for matching sent message"
) async throws -> Data {
    try await waitWithTimeout(description, timeout: timeout) {
        try await upstream.nextSent(startingAt: index, matching: predicate)
    }
}

extension ControlPlaneCoordinator {
    func drainLoadsForTesting() async {
        while completionTasks.isEmpty == false {
            let tasks = Array(completionTasks.values)
            for task in tasks {
                await task.value
            }
        }
    }

}

func makeDeterministicRuntimeTimeoutScheduler(
    clock: TestClock
) -> @Sendable (TimeAmount, @escaping @Sendable () -> Void) -> RuntimeScheduledTimeout {
    { amount, operation in
        let task = Task {
            do {
                try await clock.sleep(for: .nanoseconds(amount.nanoseconds))
                operation()
            } catch {
                return
            }
        }
        return RuntimeScheduledTimeout {
            task.cancel()
        }
    }
}
