@testable import XcodeMCPProxyRuntimeTestSupport
@testable import XcodeMCPCore
import Dispatch
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
@testable import XcodeMCPProxyRuntime
import XcodeMCPProxyTestSupport

func makeTestUpstreamSlotScheduler(upstreamCount: Int) -> UpstreamSlotScheduler {
    let topology = UpstreamTopologyAuthority(
        (0..<upstreamCount).map { _ in TestUpstreamClient() as any UpstreamSlotControlling }
    )
    return UpstreamSlotScheduler(
        isLeaseLive: { _ in true },
        canUseUpstream: { upstreamIndex in
            UpstreamHealthManager.UseEvaluation(
                proof: topology.snapshot().proof(UpstreamSlotID(rawValue: upstreamIndex)),
                effects: []
            )
        },
        selectUpstream: { occupied in
            let selectedID = topology.snapshot().slotIDs.first {
                occupied.contains($0.rawValue) == false
            }
            return UpstreamHealthManager.SelectionResult(
                proof: selectedID.flatMap { topology.snapshot().proof($0) },
                effects: []
            )
        },
        operationLease: { topology.operationLease(for: $0) },
        validateOperationLease: { topology.validate($0) }
    )
}

func makeConfig(requestTimeout: TimeInterval) -> ProxyRuntimeConfiguration {
    ProxyRuntimeConfiguration(
        maxMessageBytes: 1024,
        requestTimeout: requestTimeout,
        prewarmToolsList: false
    )
}

func makeBridgeRuntimeConfig(
    _ config: ProxyRuntimeConfiguration
) throws -> NativeHostRuntime.Configuration {
    var config = config
    config.nativeHostBundleURL = try nativeHostBundleURLForTests()
    return config.nativeHostRuntimeConfiguration
}

private let nativeHostBundleFixture = NIOLockedValueBox<URL?>(nil)

func nativeHostBundleURLForTests() throws -> URL {
    try nativeHostBundleFixture.withLockedValue { value in
        if let value { return value }
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("NativeHostRuntimeTests-" + UUID().uuidString + ".app")
        let contents = bundle.appendingPathComponent("Contents")
        let binaries = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let executable = binaries.appendingPathComponent("xcode-mcp-native-host")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "test.XcodeMCPNativeHost", "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "xcode-mcp-native-host",
        ], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        value = bundle
        return bundle
    }
}

func jsonValue(_ object: [String: Any]) throws -> JSONValue {
    try #require(JSONValue(any: object))
}

func documentationDescriptor(version: String) -> JSONValue {
    JSONValue(any: [
        "name": "DocumentationSearch",
        "description": "docs-\(version)",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                ],
            ],
            "required": ["query"],
        ],
    ])!
}

func toolNames(in result: JSONValue) -> [String] {
    guard case .object(let object) = result,
          case .array(let tools)? = object["tools"] else {
        return []
    }
    return tools.compactMap { tool in
        guard case .object(let toolObject) = tool,
              case .string(let name)? = toolObject["name"] else {
            return nil
        }
        return name
    }
}

func documentationDescriptorDescription(in result: JSONValue) -> String? {
    guard let descriptor = ToolCatalogCodec.toolsByName(in: result)["DocumentationSearch"],
          case .object(let object) = descriptor,
          case .string(let description)? = object["description"] else {
        return nil
    }
    return description
}

func toolDescriptor(
    name: String,
    description: String? = nil,
    inputProperties: [String: Any] = [:],
    required: [String] = [],
    outputSchema: [String: Any]? = nil
) -> [String: Any] {
    var descriptor: [String: Any] = [
        "name": name,
    ]
    if let description {
        descriptor["description"] = description
    }
    if inputProperties.isEmpty == false || required.isEmpty == false {
        var inputSchema: [String: Any] = [
            "type": "object",
        ]
        if inputProperties.isEmpty == false {
            inputSchema["properties"] = inputProperties
        }
        if required.isEmpty == false {
            inputSchema["required"] = required
        }
        descriptor["inputSchema"] = inputSchema
    }
    if let outputSchema {
        descriptor["outputSchema"] = outputSchema
    }
    return descriptor
}

func ownerBoundToolDescriptor(name: String) -> [String: Any] {
    toolDescriptor(
        name: name,
        inputProperties: [
            "tabIdentifier": [
                "type": "string",
            ],
            "workspaceIdentifier": [
                "type": "string",
            ],
        ]
    )
}

func toolDescription(in result: JSONValue, name expectedName: String) -> String? {
    guard case .object(let object) = result,
          case .array(let tools)? = object["tools"] else {
        return nil
    }
    for tool in tools {
        guard case .object(let toolObject) = tool,
              case .string(let name)? = toolObject["name"],
              name == expectedName,
              case .string(let description)? = toolObject["description"] else {
            continue
        }
        return description
    }
    return nil
}

func makeDocumentationSearchRequest(id: Int64, query: String) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": [
                "name": "DocumentationSearch",
                "arguments": [
                    "query": query,
                ],
            ],
        ],
        options: []
    )
}

func toolsCallObject(
    id: Int64?,
    name: String,
    arguments: [String: Any]
) -> [String: Any] {
    var request: [String: Any] = [
        "jsonrpc": "2.0",
        "method": "tools/call",
        "params": [
            "name": name,
            "arguments": arguments,
        ],
    ]
    if let id {
        request["id"] = id
    }
    return request
}

func seedNativeToolCatalog(
    on manager: RuntimeCoordinator,
    upstreamIndex: Int,
    tools: [[String: Any]]
) throws {
    manager.seedCanonicalToolsCatalog(try jsonValue(["tools": tools]), sourceUpstream: upstreamIndex)
}

struct ControlPlaneLoadTestSnapshot: Sendable {
    let loadID: UUID
    let waiterCount: Int
    let foregroundWaiterCount: Int
    let rpcHandle: ControlPlane.RPCHandle
}

extension ControlPlaneCoordinator {
    func requestToolsCatalogLoadSnapshotForTesting() -> ControlPlaneLoadTestSnapshot? {
        toolsCatalogLoad.map(loadSnapshotForTesting)
    }

    func prewarmToolsCatalogLoadSnapshotForTesting() -> ControlPlaneLoadTestSnapshot? {
        prewarmToolsCatalogLoad.map(loadSnapshotForTesting)
    }

    @discardableResult
    func timeoutForegroundToolsCatalogWaiterForTesting() -> Bool {
        let loads = [toolsCatalogLoad, prewarmToolsCatalogLoad].compactMap { $0 }
        guard loads.count == 1,
              let load = loads.first,
              let waiterID = load.waiters.first(where: {
                  if case .foreground = $0.value.kind {
                      return true
                  }
                  return false
              })?.key else {
            return false
        }
        timeoutToolsCatalogWaiter(loadID: load.loadID, waiterID: waiterID)
        return true
    }

    private func loadSnapshotForTesting(
        _ load: ToolsCatalogLoadState
    ) -> ControlPlaneLoadTestSnapshot {
        ControlPlaneLoadTestSnapshot(
            loadID: load.loadID,
            waiterCount: load.waiters.count,
            foregroundWaiterCount: load.foregroundWaiterCount,
            rpcHandle: load.rpcHandle
        )
    }
}

func makeJSONRPCResponse(id: Int64, result: [String: Any]) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ],
        options: []
    )
}

func toolContentText(in responseData: Data) throws -> String? {
    let object = try #require(
        JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any]
    )
    let result = try #require(object["result"] as? [String: Any])
    let content = try #require(result["content"] as? [[String: Any]])
    return content.first?["text"] as? String
}

func toolResultIsError(in responseData: Data) throws -> Bool {
    let object = try #require(
        JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any]
    )
    let result = try #require(object["result"] as? [String: Any])
    return result["isError"] as? Bool == true
}

func jsonRPCErrorMessage(in responseData: Data) throws -> String? {
    let object = try #require(
        JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any]
    )
    let error = try #require(object["error"] as? [String: Any])
    return error["message"] as? String
}

actor AlwaysOverloadedUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let sentMessages = RecordedValues<Data>()

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

    func send(_ data: Data) async -> Upstream.SendResult {
        await sentMessages.append(data)
        return .backpressure
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
}

actor AlwaysUnavailableUpstreamClient: UpstreamSlotControlling {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let sentMessages = RecordedValues<Data>()
    private let reason: Upstream.UnavailableReason

    init(reason: Upstream.UnavailableReason = .startFailed) {
        self.reason = reason
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
        return .unavailable(reason)
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
}

actor ReadinessFlag {
    private struct CheckWaiter {
        let id: UUID
        let index: Int
        let continuation: CheckedContinuation<Int, Error>
    }

    private struct ChangeWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var ready: Bool
    private var generation: UInt64 = 0
    private var checks = 0
    private var checkWaiters: [CheckWaiter] = []
    private var changeWaiters: [ChangeWaiter] = []
    private let observedChangeWaits = LockedRecordedValues<UInt64>()

    init(isReady: Bool) {
        self.ready = isReady
    }

    func setReady(_ value: Bool) {
        guard ready != value else { return }
        ready = value
        generation &+= 1
        let waiters = changeWaiters
        changeWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    func snapshot() -> UpstreamReadinessSnapshot {
        checks += 1
        resumeCheckWaiters()
        return UpstreamReadinessSnapshot(isReady: ready, generation: generation)
    }

    func waitForChange(after observedGeneration: UInt64) async {
        guard generation == observedGeneration, Task.isCancelled == false else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard generation == observedGeneration,
                      Task.isCancelled == false
                else {
                    continuation.resume()
                    return
                }
                changeWaiters.append(
                    ChangeWaiter(
                        id: id,
                        continuation: continuation
                    )
                )
                observedChangeWaits.append(observedGeneration)
            }
        } onCancel: {
            Task { await self.cancelChangeWaiter(id: id) }
        }
    }

    func checkCount() -> Int {
        checks
    }

    func nextChangeWait(at index: Int) async throws -> UInt64 {
        try await observedChangeWaits.nextValue(at: index)
    }

    func nextCheck(at index: Int) async throws -> Int {
        if checks > index {
            return checks
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if checks > index {
                    continuation.resume(returning: checks)
                    return
                }
                guard Task.isCancelled == false else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                checkWaiters.append(
                    CheckWaiter(id: id, index: index, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancelCheckWaiter(id: id) }
        }
    }

    private func resumeCheckWaiters() {
        var remaining: [CheckWaiter] = []
        for waiter in checkWaiters {
            if checks > waiter.index {
                waiter.continuation.resume(returning: checks)
            } else {
                remaining.append(waiter)
            }
        }
        checkWaiters = remaining
    }

    private func cancelCheckWaiter(id: UUID) {
        guard let index = checkWaiters.firstIndex(where: { $0.id == id }) else { return }
        checkWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func cancelChangeWaiter(id: UUID) {
        guard let index = changeWaiters.firstIndex(where: { $0.id == id }) else { return }
        changeWaiters.remove(at: index).continuation.resume()
    }
}

actor ControlledReadinessSleep {
    private struct SleepContinuation {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct SleepObservationWaiter {
        let id: UUID
        let index: Int
        let continuation: CheckedContinuation<UInt64, Error>
    }

    private var sleeps: [UInt64] = []
    private var sleepContinuations: [SleepContinuation] = []
    private var cancelledSleepIDs: Set<UUID> = []
    private var releaseCredits = 0
    private var waiters: [SleepObservationWaiter] = []
    private var cancelledWaiterIDs: Set<UUID> = []

    func sleep(nanoseconds: UInt64) async {
        sleeps.append(nanoseconds)
        resumeReadyWaiters()
        if releaseCredits > 0 {
            releaseCredits -= 1
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard cancelledSleepIDs.remove(id) == nil, Task.isCancelled == false else {
                    continuation.resume()
                    return
                }
                sleepContinuations.append(
                    SleepContinuation(id: id, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancelSleep(id: id) }
        }
        cancelledSleepIDs.remove(id)
    }

    func nextSleep(at index: Int) async throws -> UInt64 {
        if index < sleeps.count {
            return sleeps[index]
        }
        let id = UUID()
        do {
            let sleep = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if index < sleeps.count {
                        continuation.resume(returning: sleeps[index])
                        return
                    }
                    guard cancelledWaiterIDs.remove(id) == nil, Task.isCancelled == false else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    waiters.append(
                        SleepObservationWaiter(
                            id: id,
                            index: index,
                            continuation: continuation
                        )
                    )
                }
            } onCancel: {
                Task { await self.cancelWaiter(id: id) }
            }
            cancelledWaiterIDs.remove(id)
            return sleep
        } catch {
            cancelledWaiterIDs.remove(id)
            throw error
        }
    }

    func resumeNext() {
        guard !sleepContinuations.isEmpty else {
            releaseCredits += 1
            return
        }
        sleepContinuations.removeFirst().continuation.resume()
    }

    private func resumeReadyWaiters() {
        var remaining: [SleepObservationWaiter] = []
        for waiter in waiters {
            if waiter.index < sleeps.count {
                waiter.continuation.resume(returning: sleeps[waiter.index])
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    private func cancelSleep(id: UUID) {
        guard let index = sleepContinuations.firstIndex(where: { $0.id == id }) else {
            cancelledSleepIDs.insert(id)
            return
        }
        sleepContinuations.remove(at: index).continuation.resume()
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            cancelledWaiterIDs.insert(id)
            return
        }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

actor XcodeLaunchRecorder {
    private var count = 0
    private var outcomes: [Bool]
    private let launches = LockedRecordedValues<Int>()

    init(outcomes: [Bool] = []) {
        self.outcomes = outcomes
    }

    func launch() -> Bool {
        count += 1
        let currentCount = count
        launches.append(currentCount)
        guard outcomes.isEmpty == false else {
            return true
        }
        return outcomes.removeFirst()
    }

    func launchCount() -> Int {
        count
    }

    func nextLaunch(at index: Int) async throws -> Int {
        try await launches.nextValue(at: index)
    }
}

func makeTestReadinessGate(
    readiness: ReadinessFlag,
    sleepRecorder: ControlledReadinessSleep = ControlledReadinessSleep(),
    launchRecorder: XcodeLaunchRecorder? = nil
) -> UpstreamReadinessGate {
    let launchIfUnavailable: (@Sendable () async -> Bool)?
    if let launchRecorder {
        launchIfUnavailable = {
            await launchRecorder.launch()
        }
    } else {
        launchIfUnavailable = nil
    }

    return UpstreamReadinessGate(
        isEnabled: true,
        targetName: "mcpbridge",
        initialRetryBackoffNanoseconds: 1_000_000_000,
        maxRetryBackoffNanoseconds: 8_000_000_000,
        sleepNanoseconds: { nanoseconds in
            await sleepRecorder.sleep(nanoseconds: nanoseconds)
        },
        launchIfUnavailable: launchIfUnavailable,
        snapshot: {
            await readiness.snapshot()
        },
        waitForChange: { generation in
            await readiness.waitForChange(after: generation)
        }
    )
}

func makeInitializeRequest(id: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "session-manager-tests",
                "version": "0.0",
            ],
        ],
    ]
}

func makeInitializeErrorResponse(id: Int64, message: String = "initialize failed") throws -> Data {
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "error": [
            "code": -32000,
            "message": message,
        ],
    ]
    return try JSONSerialization.data(withJSONObject: response, options: [])
}

struct RuntimeCoordinatorFixture {
    let eventLoop: EventLoop
    let manager: RuntimeCoordinator

    init(
        config: ProxyRuntimeConfiguration = makeConfig(requestTimeout: 5),
        upstreams: [any UpstreamSlotControlling],
        clock: ClockClient = .liveValue,
        upstreamReadinessGate: UpstreamReadinessGate? = nil,
        nowUptimeNanoseconds: (@Sendable () -> UInt64)? = nil,
        scheduleRuntimeTimeout: (
            @Sendable (TimeAmount, @escaping @Sendable () -> Void) ->
                RuntimeScheduledTimeout
        )? = nil,

        nativeUpstreamFactory: NativeUpstreamFactory? = nil,
        testHooks: RuntimeCoordinatorTestHooks = RuntimeCoordinatorTestHooks(),
        startImmediately: Bool = true,
        runtimeBox: WeakRuntimeCoordinatorBox? = nil
    ) {
        // RuntimeCoordinator owns its tasks, but not the injected event loop. Reuse NIO's
        // process-scoped group so the package suite does not create hundreds of kernel threads.
        let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
        self.eventLoop = eventLoop
        self.manager = RuntimeCoordinator(
            config: config,
            eventLoop: eventLoop,
            upstreams: upstreams,
            clock: clock,
            upstreamReadinessGate: upstreamReadinessGate,
            nowUptimeNanoseconds: nowUptimeNanoseconds,
            scheduleRuntimeTimeout: scheduleRuntimeTimeout,
            nativeUpstreamFactory: nativeUpstreamFactory,
            testHooks: testHooks,
            startImmediately: startImmediately,
            runtimeBox: runtimeBox
        )
    }

    func shutdownAndWait() {
        manager.shutdownAndWait()
    }

    func registerInitialize(
        requestID: Int,
        sessionID: String? = nil,
        requestObject: [String: Any]? = nil
    ) -> EventLoopFuture<ByteBuffer> {
        let originalID = JSONRPC.ID(any: NSNumber(value: requestID))!
        let requestObject = requestObject ?? makeInitializeRequest(id: requestID)
        if let sessionID {
            return manager.registerInitialize(
                sessionID: sessionID,
                originalID: originalID,
                requestObject: requestObject,
                on: eventLoop
            )
        }
        return manager.registerInitialize(
            originalID: originalID,
            requestObject: requestObject,
            on: eventLoop
        )
    }

    @discardableResult
    func completeInitialize<UpstreamClient: InitializableTestUpstream>(
        on upstream: UpstreamClient,
        at sentIndex: Int = 0,
        serverName: String? = nil,
        timeout: Duration = .seconds(2)
    ) async throws -> Data {
        let initializeRequest = try await waitWithTimeout(
            "waiting for sent message \(sentIndex + 1)",
            timeout: timeout
        ) {
            try await upstream.nextSent(at: sentIndex)
        }
        let upstreamID = try extractUpstreamID(from: initializeRequest)
        await upstream.yield(.message(try makeInitializeResponse(
            id: upstreamID,
            serverName: serverName
        )))
        return initializeRequest
    }

    @discardableResult
    func initializePrimary<UpstreamClient: InitializableTestUpstream>(
        on upstream: UpstreamClient,
        requestID: Int = 1,
        sessionID: String? = nil,
        sentIndex: Int = 0,
        serverName: String? = nil,
        timeout: Duration = .seconds(2)
    ) async throws -> ByteBuffer {
        let future = registerInitialize(requestID: requestID, sessionID: sessionID)
        try await completeInitialize(
            on: upstream,
            at: sentIndex,
            serverName: serverName,
            timeout: timeout
        )
        return try await waitWithTimeout(
            "waiting for primary initialize response",
            timeout: timeout
        ) {
            try await future.get()
        }
    }
}

func extractUpstreamID(from data: Data) throws -> Int64 {
    let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    return (object?["id"] as? NSNumber)?.int64Value ?? 0
}

func extractCancellationRequestID(from data: Data) throws -> Int64 {
    let object = try #require(
        JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    )
    #expect(object["method"] as? String == "notifications/cancelled")
    let params = try #require(object["params"] as? [String: Any])
    return try #require((params["requestId"] as? NSNumber)?.int64Value)
}

func decodeJSON(from buffer: ByteBuffer) throws -> [String: Any] {
    var buffer = buffer
    guard let data = buffer.readData(length: buffer.readableBytes) else {
        return [:]
    }
    return (try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]) ?? [:]
}

func waitForSentCount(
    _ upstream: TestUpstreamClient,
    count: Int,
    timeoutSeconds: UInt64
) async throws {
    do {
        _ = try await waitWithTimeout(
            "waiting for sent message \(count)",
            timeout: .seconds(Int64(timeoutSeconds))
        ) {
            try await upstream.nextSent(at: count - 1)
        }
    } catch {
        let actual = await upstream.sentCount()
        throw WaitForSentCountError.timeout(expected: count, actual: actual)
    }
}

func waitForSentCount(
    _ upstream: ToggleableOverloadUpstreamClient,
    count: Int,
    timeoutSeconds: UInt64
) async throws {
    do {
        _ = try await waitWithTimeout(
            "waiting for sent message \(count)",
            timeout: .seconds(Int64(timeoutSeconds))
        ) {
            try await upstream.nextSent(at: count - 1)
        }
    } catch {
        let actual = await upstream.sentCount()
        throw WaitForSentCountError.timeout(expected: count, actual: actual)
    }
}

func waitForSentCount(
    _ upstream: AlwaysUnavailableUpstreamClient,
    count: Int,
    timeoutSeconds: UInt64
) async throws {
    do {
        _ = try await waitWithTimeout(
            "waiting for sent message \(count)",
            timeout: .seconds(Int64(timeoutSeconds))
        ) {
            try await upstream.nextSent(at: count - 1)
        }
    } catch {
        let actual = await upstream.sentCount()
        throw WaitForSentCountError.timeout(expected: count, actual: actual)
    }
}

final class RecordingRuntimeTimeoutScheduler: @unchecked Sendable {
    private struct Operation {
        let delay: TimeAmount
        let operation: @Sendable () -> Void
        var isCancelled = false
    }

    private let operations = NIOLockedValueBox<[Operation]>([])
    private let scheduledIndices = LockedRecordedValues<Int>()

    func scheduler() -> @Sendable (TimeAmount, @escaping @Sendable () -> Void) -> RuntimeScheduledTimeout {
        { delay, operation in
            let index = self.operations.withLockedValue { operations in
                let index = operations.count
                operations.append(Operation(delay: delay, operation: operation))
                return index
            }
            self.scheduledIndices.append(index)
            return RuntimeScheduledTimeout {
                self.operations.withLockedValue { operations in
                    guard operations.indices.contains(index) else { return }
                    operations[index].isCancelled = true
                }
            }
        }
    }

    func scheduledCount() -> Int {
        operations.withLockedValue(\.count)
    }

    func scheduledEventCount() -> Int {
        scheduledIndices.count()
    }

    func nextScheduled(at index: Int) async throws -> Int {
        try await scheduledIndices.nextValue(at: index)
    }

    func isCancelled(at index: Int) -> Bool {
        operations.withLockedValue { operations in
            guard operations.indices.contains(index) else { return false }
            return operations[index].isCancelled
        }
    }

    func delay(at index: Int) -> TimeAmount? {
        operations.withLockedValue { operations in
            guard operations.indices.contains(index) else { return nil }
            return operations[index].delay
        }
    }

    func activeTimeoutIndex(
        delay: TimeAmount,
        startingAt startIndex: Int = 0
    ) -> Int? {
        operations.withLockedValue { operations in
            guard startIndex <= operations.count else { return nil }
            return operations.indices[startIndex...].first { index in
                operations[index].isCancelled == false
                    && operations[index].delay.nanoseconds == delay.nanoseconds
            }
        }
    }

    func nextActiveTimeoutIndex(
        delay: TimeAmount,
        startingAtEventIndex startIndex: Int = 0
    ) async throws -> Int {
        var scheduledValueIndex = startIndex
        while true {
            let operationIndex = try await nextScheduled(at: scheduledValueIndex)
            scheduledValueIndex += 1
            if isCancelled(at: operationIndex) == false,
               self.delay(at: operationIndex)?.nanoseconds == delay.nanoseconds {
                return operationIndex
            }
        }
    }

    @discardableResult
    func fire(at index: Int) -> Bool {
        let operation: (@Sendable () -> Void)? = operations.withLockedValue { operations in
            guard operations.indices.contains(index), operations[index].isCancelled == false else {
                return nil
            }
            return operations[index].operation
        }
        guard let operation else {
            return false
        }
        operation()
        return true
    }

    /// Delivers a recorded callback even after cancellation, modeling an already-enqueued timer
    /// callback that races with its owner's lifecycle transition.
    @discardableResult
    func fireIgnoringCancellation(at index: Int) -> Bool {
        let operation: (@Sendable () -> Void)? = operations.withLockedValue { operations in
            guard operations.indices.contains(index) else { return nil }
            return operations[index].operation
        }
        guard let operation else {
            return false
        }
        operation()
        return true
    }
}

func makeDeterministicClockClient(
    timeoutClock: TestClock,
    uptimeClock: TestUptimeClock
) -> ClockClient {
    ClockClient(
        now: {
            Date(timeIntervalSince1970: Double(uptimeClock.now()) / 1_000_000_000)
        },
        uptimeNanoseconds: uptimeClock.now,
        sleep: { duration in
            try? await timeoutClock.sleep(for: duration)
        },
        sleepForTimeInterval: { _ in }
    )
}

func makeRuntimeCoordinatorDeterministicClocks()
    -> (clock: ClockClient, timeoutClock: TestClock, uptimeClock: TestUptimeClock)
{
    let timeoutClock = TestClock()
    let uptimeClock = TestUptimeClock()
    return (
        makeDeterministicClockClient(timeoutClock: timeoutClock, uptimeClock: uptimeClock),
        timeoutClock,
        uptimeClock
    )
}

func advanceRuntimeCoordinatorTimeout(
    timeoutClock: TestClock,
    uptimeClock: TestUptimeClock,
    by duration: Duration,
    suspendedSleepers: Int = 1
) async throws {
    try await waitForSuspendedSleepers(on: timeoutClock, count: suspendedSleepers)
    uptimeClock.advance(by: duration)
    timeoutClock.advance(by: duration)
}

func spinUntilSentCount(
    _ upstream: TestUpstreamClient,
    count: Int,
    description: String
) async throws {
    guard count > 0 else {
        return
    }
    _ = try await waitWithTimeout(description, timeout: .seconds(5)) {
        try await upstream.nextSent(at: count - 1)
    }
}

func spinUntilSentCount(
    _ upstream: ToggleableOverloadUpstreamClient,
    count: Int,
    description: String
) async throws {
    guard count > 0 else {
        return
    }
    _ = try await waitWithTimeout(description, timeout: .seconds(5)) {
        try await upstream.nextSent(at: count - 1)
    }
}

enum WaitForSentCountError: Error {
    case timeout(expected: Int, actual: Int)
}

func waitForRecordedValue<Value: Sendable>(
    _ values: LockedRecordedValues<Value>,
    at index: Int,
    description: String,
    timeout: Duration = .seconds(2)
) async throws -> Value {
    try await waitWithTimeout(description, timeout: timeout) {
        try await values.nextValue(at: index)
    }
}

func waitForInitializedUpstreams(
    _ initializedUpstreams: LockedRecordedValues<Int>,
    expected: [Int]
) async throws {
    for (eventIndex, expectedUpstreamIndex) in expected.enumerated() {
        let actualUpstreamIndex = try await waitForRecordedValue(
            initializedUpstreams,
            at: eventIndex,
            description: "waiting for upstream \(expectedUpstreamIndex) initialization commit"
        )
        #expect(actualUpstreamIndex == expectedUpstreamIndex)
    }
}

func nextRecordedValue<Value: Sendable>(
    _ values: LockedRecordedValues<Value>,
    at index: Int
) async throws -> Value {
    try await values.nextValue(at: index)
}

func toolCallName(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
          let params = object["params"] as? [String: Any] else {
        return nil
    }
    return params["name"] as? String
}

func makeToolListRequest(id: Int64) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/list",
        ],
        options: []
    )
}

func makeToolListResponse(id: Int64) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": [:],
        ],
        options: []
    )
}

func makeDocumentationToolsListResponse(id: Int64, version: String) throws -> Data {
    try makeDocumentationToolsListResponse(
        id: id,
        tools: [
            documentationDescriptor(version: version).foundationObject,
        ]
    )
}

func makeDocumentationToolsListResponse(id: Int64, tools: [Any]) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "tools": tools,
            ],
        ],
        options: []
    )
}

func makeDocumentationSearchResponse(id: Int64, text: String) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": text,
                    ],
                ],
                "isError": false,
            ],
        ],
        options: []
    )
}

func makeDocumentationSearchToolErrorResponse(id: Int64, text: String) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": text,
                    ],
                ],
                "isError": true,
            ],
        ],
        options: []
    )
}

func documentationSearchQuery(in data: Data) throws -> String? {
    let object = try #require(
        JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    )
    let params = try #require(object["params"] as? [String: Any])
    let arguments = try #require(params["arguments"] as? [String: Any])
    return arguments["query"] as? String
}

func yieldMessage(_ data: Data, to upstream: TestUpstreamClient) async {
    await upstream.yield(.message(data))
}

func sentMessage(
    from upstream: TestUpstreamClient,
    matching predicate: @escaping @Sendable (Data) -> Bool,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    try await waitWithTimeout(
        "waiting for matching sent message",
        timeout: timeout
    ) {
        try await upstream.nextSent(matching: predicate)
    }
}
