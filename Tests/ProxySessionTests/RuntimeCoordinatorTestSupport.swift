import ProxyXcodeSupport
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
import ProxyCore
import ProxyMCP
import XcodeMCPTestSupport
@testable import ProxySession

func makeTestUpstreamSlotScheduler(upstreamCount: Int) -> UpstreamSlotScheduler {
    UpstreamSlotScheduler(
        canUseUpstream: { _ in UpstreamHealthManager.UseEvaluation(isUsable: true, effects: []) },
        selectUpstream: { occupied in
            UpstreamHealthManager.SelectionResult(
                upstreamIndex: (0..<upstreamCount).first { occupied.contains($0) == false },
                effects: []
            )
        }
    )
}

func makeConfig(requestTimeout: TimeInterval) -> ProxyConfig {
    ProxyConfig(
        listenHost: "127.0.0.1",
        listenPort: 0,
        upstreamCommand: "xcrun",
        upstreamArgs: ["mcpbridge"],
        upstreamSessionID: nil,
        maxBodyBytes: 1024,
        requestTimeout: requestTimeout,
        prewarmToolsList: false
    )
}

func jsonValue(_ object: [String: Any]) throws -> JSONValue {
    try #require(JSONValue(any: object))
}

func documentationDescriptor(version: String) -> JSONValue {
    JSONValue(any: [
        "name": DocumentationProvider.ToolCatalog.toolName,
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
    guard let descriptor = DocumentationProvider.ToolCatalog.descriptor(in: result),
          case .object(let object) = descriptor,
          case .string(let description)? = object["description"] else {
        return nil
    }
    return description
}

func makeDocumentationSearchRequest(id: Int64, query: String) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": [
                "name": DocumentationProvider.ToolCatalog.toolName,
                "arguments": [
                    "query": query,
                ],
            ],
        ],
        options: []
    )
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

func documentationProviderTarget(processID: pid_t) -> DocumentationProviderTarget {
    DocumentationProviderTarget(
        processID: processID,
        appPath: "/Applications/Xcode-\(processID).app",
        developerDir: "/Applications/Xcode-\(processID).app/Contents/Developer",
        mcpbridgePath: "/Applications/Xcode-\(processID).app/Contents/Developer/usr/bin/mcpbridge"
    )
}

struct StubXcodeTargetDiscovery: XcodeTargetDiscovering {
    let targets: [DocumentationProviderTarget]

    func runningXcodeTargets() -> [DocumentationProviderTarget] {
        targets
    }
}

enum ScriptedDocumentationResponse: Sendable {
    case success
    case successText(String)
    case hang
    case notEnabled
    case exit
}

struct ScriptedDocumentationSessionPlan: Sendable {
    let serverVersion: String
    let toolCount: Int
    let includesDocumentationSearch: Bool
    let probeResponse: ScriptedDocumentationResponse
    let userCallResponses: [ScriptedDocumentationResponse]
    let requiresNumericRequestIDs: Bool

    init(
        serverVersion: String,
        toolCount: Int,
        includesDocumentationSearch: Bool,
        probeResponse: ScriptedDocumentationResponse,
        userCallResponses: [ScriptedDocumentationResponse] = [],
        requiresNumericRequestIDs: Bool = false
    ) {
        self.serverVersion = serverVersion
        self.toolCount = toolCount
        self.includesDocumentationSearch = includesDocumentationSearch
        self.probeResponse = probeResponse
        self.userCallResponses = userCallResponses
        self.requiresNumericRequestIDs = requiresNumericRequestIDs
    }
}

actor ScriptedDocumentationSessionFactory: DocumentationProviderSessionMaking {
    private struct RequestCountWaiter {
        let id: UUID
        let processID: pid_t
        let method: String
        let count: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private var plansByPID: [pid_t: [ScriptedDocumentationSessionPlan]]
    private var startAttemptProcessIDs: [pid_t] = []
    private var startedProcessIDs: [pid_t] = []
    private var initializeParamsByPID: [pid_t: [JSONValue]] = [:]
    private var requestCountsByPID: [pid_t: [String: Int]] = [:]
    private var requestCountWaiters: [RequestCountWaiter] = []
    private let startDelayNanoseconds: UInt64?

    init(
        plansByPID: [pid_t: [ScriptedDocumentationSessionPlan]],
        startDelayNanoseconds: UInt64? = nil
    ) {
        self.plansByPID = plansByPID
        self.startDelayNanoseconds = startDelayNanoseconds
    }

    func startSession(for target: DocumentationProviderTarget) async throws -> any UpstreamSession {
        startAttemptProcessIDs.append(target.processID)
        if let startDelayNanoseconds {
            try await Task.sleep(nanoseconds: startDelayNanoseconds)
        }
        guard var plans = plansByPID[target.processID],
              plans.isEmpty == false else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        let plan = plans.removeFirst()
        plansByPID[target.processID] = plans
        startedProcessIDs.append(target.processID)
        return ScriptedDocumentationSession(
            processID: target.processID,
            plan: plan,
            recorder: self
        )
    }

    func startedPIDs() -> [pid_t] {
        startedProcessIDs
    }

    func startAttempts() -> [pid_t] {
        startAttemptProcessIDs
    }

    func recordInitializeParams(_ params: JSONValue, for processID: pid_t) {
        initializeParamsByPID[processID, default: []].append(params)
    }

    func initializeParams(for processID: pid_t) -> [JSONValue] {
        initializeParamsByPID[processID] ?? []
    }

    func recordRequest(method: String, for processID: pid_t) {
        requestCountsByPID[processID, default: [:]][method, default: 0] += 1
        resumeRequestCountWaiters()
    }

    func requestCount(processID: pid_t, method: String) -> Int {
        requestCountsByPID[processID]?[method] ?? 0
    }

    func waitForRequestCount(_ count: Int, processID: pid_t, method: String) async throws {
        if requestCount(processID: processID, method: method) >= count {
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if requestCount(processID: processID, method: method) >= count {
                    continuation.resume(returning: ())
                    return
                }
                requestCountWaiters.append(
                    RequestCountWaiter(
                        id: waiterID,
                        processID: processID,
                        method: method,
                        count: count,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task {
                await self.cancelRequestCountWaiter(id: waiterID)
            }
        }
    }

    private func resumeRequestCountWaiters() {
        var remaining: [RequestCountWaiter] = []
        for waiter in requestCountWaiters {
            if requestCount(processID: waiter.processID, method: waiter.method) >= waiter.count {
                waiter.continuation.resume(returning: ())
            } else {
                remaining.append(waiter)
            }
        }
        requestCountWaiters = remaining
    }

    private func cancelRequestCountWaiter(id: UUID) {
        guard let index = requestCountWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = requestCountWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

actor ScriptedDocumentationSession: UpstreamSession {
    nonisolated let events: AsyncStream<Upstream.Event>
    private let continuation: AsyncStream<Upstream.Event>.Continuation
    private let processID: pid_t
    private let plan: ScriptedDocumentationSessionPlan
    private let recorder: ScriptedDocumentationSessionFactory
    private var documentationCallCount = 0
    private var remainingUserCallResponses: [ScriptedDocumentationResponse]

    init(
        processID: pid_t,
        plan: ScriptedDocumentationSessionPlan,
        recorder: ScriptedDocumentationSessionFactory
    ) {
        self.processID = processID
        self.plan = plan
        self.recorder = recorder
        self.remainingUserCallResponses = plan.userCallResponses
        var streamContinuation: AsyncStream<Upstream.Event>.Continuation!
        self.events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation
    }

    func send(_ data: Data) async -> Upstream.SendResult {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [])
            as? [String: Any],
            let method = object["method"] as? String else {
            return .accepted
        }
        guard let requestID = object["id"] else {
            return .accepted
        }
        if plan.requiresNumericRequestIDs, !(requestID is NSNumber) {
            return .accepted
        }
        await recorder.recordRequest(method: method, for: processID)

        switch method {
        case "initialize":
            if let params = object["params"], let value = JSONValue(any: params) {
                await recorder.recordInitializeParams(value, for: processID)
            }
            yieldResponse(
                id: requestID,
                result: [
                    "serverInfo": [
                        "name": "mcpbridge",
                        "version": plan.serverVersion,
                    ],
                ]
            )
        case "tools/list":
            yieldResponse(
                id: requestID,
                result: [
                    "tools": toolsList(),
                ]
            )
        case "tools/call":
            documentationCallCount += 1
            let response: ScriptedDocumentationResponse
            if documentationCallCount == 1 {
                response = plan.probeResponse
            } else if remainingUserCallResponses.isEmpty == false {
                response = remainingUserCallResponses.removeFirst()
            } else {
                response = .success
            }
            yieldDocumentationResponse(id: requestID, response: response)
        default:
            break
        }
        return .accepted
    }

    func stop() async {
        continuation.finish()
    }

    private func toolsList() -> [[String: Any]] {
        let fillerCount = max(0, plan.toolCount - (plan.includesDocumentationSearch ? 1 : 0))
        var tools: [[String: Any]] = (0..<fillerCount).map { index in
            [
                "name": "Tool\(index)",
                "description": "tool-\(index)",
            ]
        }
        if plan.includesDocumentationSearch {
            if let descriptor = documentationDescriptor(version: plan.serverVersion).foundationObject
                as? [String: Any] {
                tools.append(descriptor)
            }
        }
        return tools
    }

    private func yieldDocumentationResponse(id: Any, response: ScriptedDocumentationResponse) {
        switch response {
        case .success:
            yieldToolResponse(id: id, text: "{\"ok\":true}", isError: false)
        case .successText(let text):
            yieldToolResponse(id: id, text: text, isError: false)
        case .hang:
            break
        case .notEnabled:
            yieldToolResponse(
                id: id,
                text: "Tool 'DocumentationSearch' is not enabled.",
                isError: true
            )
        case .exit:
            continuation.yield(.exit(1))
        }
    }

    private func yieldToolResponse(id: Any, text: String, isError: Bool) {
        yieldResponse(
            id: id,
            result: [
                "content": [
                    [
                        "type": "text",
                        "text": text,
                    ],
                ],
                "isError": isError,
            ]
        )
    }

    private func yieldResponse(id: Any, result: [String: Any]) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        guard JSONSerialization.isValidJSONObject(response),
              let data = try? JSONSerialization.data(withJSONObject: response, options: []) else {
            return
        }
        continuation.yield(.message(data))
    }
}

actor StubDocumentationProviderManager: DocumentationProviderManaging {
    private var update: DocumentationProvider.ToolListUpdate
    private var callOutcomes: [DocumentationProvider.CallOutcome]
    private var callCountValue = 0
    private var invalidateReasons: [String] = []
    private var prewarmTimeouts: [TimeAmount?] = []
    private var toolListTimeouts: [TimeAmount?] = []
    private var callTimeouts: [TimeAmount?] = []
    private let prewarmDelayNanoseconds: UInt64?
    private let toolListDelayNanoseconds: UInt64?
    private let prewarmStarted: TestSignal?
    private let prewarmBlocker: AsyncGate?

    init(
        toolListUpdate: DocumentationProvider.ToolListUpdate,
        callOutcomes: [DocumentationProvider.CallOutcome] = [],
        prewarmDelayNanoseconds: UInt64? = nil,
        toolListDelayNanoseconds: UInt64? = nil,
        prewarmStarted: TestSignal? = nil,
        prewarmBlocker: AsyncGate? = nil
    ) {
        self.update = toolListUpdate
        self.callOutcomes = callOutcomes
        self.prewarmDelayNanoseconds = prewarmDelayNanoseconds
        self.toolListDelayNanoseconds = toolListDelayNanoseconds
        self.prewarmStarted = prewarmStarted
        self.prewarmBlocker = prewarmBlocker
    }

    func prewarm(requestTimeout: TimeAmount?) async -> DocumentationProvider.ToolListUpdate {
        prewarmStarted?.signal()
        if let prewarmDelayNanoseconds {
            try? await Task.sleep(nanoseconds: prewarmDelayNanoseconds)
            guard !Task.isCancelled else { return .unavailable }
        }
        if let prewarmBlocker {
            do {
                try await prewarmBlocker.wait()
            } catch {
                return .unavailable
            }
            guard !Task.isCancelled else { return .unavailable }
        }
        prewarmTimeouts.append(requestTimeout)
        return await toolListUpdate(requestTimeout: requestTimeout)
    }

    func toolListUpdate(requestTimeout: TimeAmount?) async -> DocumentationProvider.ToolListUpdate {
        toolListTimeouts.append(requestTimeout)
        if let toolListDelayNanoseconds {
            try? await Task.sleep(nanoseconds: toolListDelayNanoseconds)
            guard !Task.isCancelled else { return .unavailable }
        }
        return update
    }

    func callDocumentationSearch(
        requestData _: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationProvider.CallOutcome {
        callCountValue += 1
        callTimeouts.append(requestTimeoutOverride)
        guard callOutcomes.isEmpty == false else {
            return .unavailable(.noAvailableProvider)
        }
        return callOutcomes.removeFirst()
    }

    func invalidate(reason: String) async {
        invalidateReasons.append(reason)
        update = .unavailable
    }

    func shutdown() async {
        invalidateReasons.append("shutdown")
    }

    func callCount() -> Int {
        callCountValue
    }

    func prewarmCount() -> Int {
        prewarmTimeouts.count
    }

    func toolListUpdateCount() -> Int {
        toolListTimeouts.count
    }

    func lastPrewarmTimeout() -> TimeAmount? {
        prewarmTimeouts.last ?? nil
    }

    func shutdownCount() -> Int {
        invalidateReasons.filter { $0 == "shutdown" }.count
    }

    func recordedInvalidateReasons() -> [String] {
        invalidateReasons
    }

    func lastToolListTimeout() -> TimeAmount? {
        toolListTimeouts.last ?? nil
    }

    func lastCallTimeout() -> TimeAmount? {
        callTimeouts.last ?? nil
    }
}

func defaultUpstreamEnvironment(sharedSessionID: String?) throws -> [String: String] {
    var config = makeConfig(requestTimeout: 5)
    config.upstreamSessionID = sharedSessionID
    let upstreams = RuntimeCoordinator.makeDefaultUpstreams(
        config: config,
        sharedSessionID: sharedSessionID,
        count: 1
    )
    let upstream = try #require(upstreams.first)
    return try upstreamEnvironment(from: upstream)
}

func upstreamEnvironment(from upstream: ManagedUpstreamSlot) throws -> [String: String] {
    let upstreamMirror = Mirror(reflecting: upstream)
    let factory = try #require(
        upstreamMirror.children.first(where: { $0.label == "factory" })?.value,
        "ManagedUpstreamSlot should expose a stored factory for tests"
    )
    let factoryMirror = Mirror(reflecting: factory)
    let config = try #require(
        factoryMirror.children.first(where: { $0.label == "config" })?.value,
        "UpstreamProcess factory should expose a stored config for tests"
    )
    let configMirror = Mirror(reflecting: config)
    return try #require(
        configMirror.children.first(where: { $0.label == "environment" })?.value
            as? [String: String],
        "UpstreamProcess.Config should include environment for tests"
    )
}

func withEnvironmentVariables<T>(
    _ values: [String: String],
    body: () throws -> T
) throws -> T {
    let originalValues = values.keys.reduce(into: [String: String?]()) { result, key in
        result[key] = ProcessInfo.processInfo.environment[key]
    }

    for (key, value) in values {
        _ = unsafe setenv(key, value, 1)
    }

    defer {
        for (key, value) in originalValues {
            if let value {
                _ = unsafe setenv(key, value, 1)
            } else {
                _ = unsafe unsetenv(key)
            }
        }
    }

    return try body()
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
}

actor ReadinessFlag {
    private struct Waiter {
        let index: Int
        let continuation: CheckedContinuation<Int, Error>
    }

    private var ready: Bool
    private var checks = 0
    private var waiters: [Waiter] = []

    init(isReady: Bool) {
        self.ready = isReady
    }

    func setReady(_ value: Bool) {
        ready = value
    }

    func isReady() -> Bool {
        checks += 1
        resumeReadyWaiters()
        return ready
    }

    func checkCount() -> Int {
        checks
    }

    func nextCheck(at index: Int) async throws -> Int {
        if checks > index {
            return checks
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(index: index, continuation: continuation))
        }
    }

    private func resumeReadyWaiters() {
        var remaining: [Waiter] = []
        for waiter in waiters {
            if checks > waiter.index {
                waiter.continuation.resume(returning: checks)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

actor AvailabilityFlag {
    private struct Waiter {
        let index: Int
        let continuation: CheckedContinuation<Int, Error>
    }

    private var available: Bool
    private var checks = 0
    private var waiters: [Waiter] = []

    init(isAvailable: Bool) {
        self.available = isAvailable
    }

    func setAvailable(_ value: Bool) {
        available = value
    }

    func isAvailable() -> Bool {
        checks += 1
        resumeReadyWaiters()
        return available
    }

    func nextCheck(at index: Int) async throws -> Int {
        if checks > index {
            return checks
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(index: index, continuation: continuation))
        }
    }

    private func resumeReadyWaiters() {
        var remaining: [Waiter] = []
        for waiter in waiters {
            if checks > waiter.index {
                waiter.continuation.resume(returning: checks)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

actor ControlledReadinessSleep {
    private var sleeps: [UInt64] = []
    private var sleepContinuations: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(index: Int, continuation: CheckedContinuation<UInt64, Error>)] = []

    func sleep(nanoseconds: UInt64) async {
        sleeps.append(nanoseconds)
        resumeReadyWaiters()
        await withCheckedContinuation { continuation in
            sleepContinuations.append(continuation)
        }
    }

    func nextSleep(at index: Int) async throws -> UInt64 {
        if index < sleeps.count {
            return sleeps[index]
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append((index, continuation))
        }
    }

    func resumeNext() {
        guard !sleepContinuations.isEmpty else { return }
        sleepContinuations.removeFirst().resume()
    }

    private func resumeReadyWaiters() {
        var remaining: [(index: Int, continuation: CheckedContinuation<UInt64, Error>)] = []
        for waiter in waiters {
            if waiter.index < sleeps.count {
                waiter.continuation.resume(returning: sleeps[waiter.index])
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

actor XcodeLaunchRecorder {
    private var count = 0
    private var outcomes: [Bool]

    init(outcomes: [Bool] = []) {
        self.outcomes = outcomes
    }

    func launch() -> Bool {
        count += 1
        guard outcomes.isEmpty == false else {
            return true
        }
        return outcomes.removeFirst()
    }

    func launchCount() -> Int {
        count
    }
}

func makeTestReadinessGate(
    readiness: ReadinessFlag,
    availability: AvailabilityFlag? = nil,
    sleepRecorder: ControlledReadinessSleep? = nil,
    launchRetryIntervalNanoseconds: UInt64 = 5_000_000_000,
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

    let isAvailable: (@Sendable () async -> Bool)?
    if let availability {
        isAvailable = {
            await availability.isAvailable()
        }
    } else {
        isAvailable = nil
    }

    return UpstreamReadinessGate(
        isEnabled: true,
        targetName: "mcpbridge",
        pollIntervalNanoseconds: 1_000_000,
        progressLogIntervalNanoseconds: 5_000_000_000,
        launchRetryIntervalNanoseconds: launchRetryIntervalNanoseconds,
        initialRetryBackoffNanoseconds: 1_000_000_000,
        maxRetryBackoffNanoseconds: 8_000_000_000,
        uptimeNanoseconds: {
            DispatchTime.now().uptimeNanoseconds
        },
        sleepNanoseconds: { nanoseconds in
            if let sleepRecorder, nanoseconds >= 1_000_000_000 {
                await sleepRecorder.sleep(nanoseconds: nanoseconds)
            } else {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        },
        isAvailable: isAvailable,
        launchIfUnavailable: launchIfUnavailable,
        isReady: {
            await readiness.isReady()
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

func makeTempProxyConfigFile(_ contents: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("proxy-config.toml")
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL.path
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

func extractUpstreamID(from data: Data) throws -> Int64 {
    let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    return (object?["id"] as? NSNumber)?.int64Value ?? 0
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

func waitForCondition(
    timeoutSeconds: UInt64,
    pollNanoseconds: UInt64 = 50_000_000,
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    _ = pollNanoseconds
    let reached = await waitUntil(timeout: .seconds(Int64(timeoutSeconds))) {
        condition()
    }
    if !reached {
        throw WaitForConditionError.timeout
    }
}

enum WaitForConditionError: Error {
    case timeout
}

func methodName(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    else {
        return nil
    }
    return object["method"] as? String
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

func yieldMessage(_ data: Data, to upstream: TestUpstreamClient) async {
    await upstream.yield(.message(data))
}

func sentValue(
    from upstream: TestUpstreamClient,
    at index: Int,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    try await nextValue(
        "waiting for sent message \(index + 1)",
        timeout: timeout
    ) {
        await upstream.sentValue(at: index)
    }
}

func sentValue(
    from upstream: ToggleableOverloadUpstreamClient,
    at index: Int,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    try await nextValue(
        "waiting for sent message \(index + 1)",
        timeout: timeout
    ) {
        await upstream.sentValue(at: index)
    }
}

func sentValue(
    from upstream: BlockingInitializedNotificationUpstreamClient,
    at index: Int,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    try await nextValue(
        "waiting for sent message \(index + 1)",
        timeout: timeout
    ) {
        await upstream.sentValue(at: index)
    }
}

func sentMessage(
    from upstream: TestUpstreamClient,
    matching predicate: @escaping @Sendable (Data) -> Bool,
    timeout: Duration = .seconds(5)
) async throws -> Data {
    try await nextValue(
        "waiting for matching sent message",
        timeout: timeout
    ) {
        try Task.checkCancellation()
        let sent = await upstream.sent()
        return sent.first(where: predicate)
    }
}

func nextBufferedNotifications(
    from router: ProxyRouter,
    timeout: Duration = .seconds(5)
) async throws -> [Data] {
    try await waitWithTimeout(
        "waiting for buffered notifications",
        timeout: timeout
    ) {
        while true {
            try Task.checkCancellation()
            let drained = router.drainBufferedNotifications()
            if !drained.isEmpty {
                return drained
            }
            await Task.yield()
        }
    }
}
