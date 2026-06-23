import ProxyXcodeSupport
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing
import ProxyCore
import ProxyMCP
import ProxySessionControlPlane
import ProxySessionUpstream
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

private struct TestDocumentationAssetInfoPlist: Encodable {
    let properties: TestDocumentationAssetProperties

    private enum CodingKeys: String, CodingKey {
        case properties = "MobileAssetProperties"
    }
}

private struct TestDocumentationAssetProperties: Encodable {
    let documentationRelease: String
    let xcodeVersion: String
    let osVersion: String

    private enum CodingKeys: String, CodingKey {
        case documentationRelease = "DocumentationRelease"
        case xcodeVersion = "XcodeVersion"
        case osVersion = "OSVersion"
    }
}

func makeInstalledDocumentationAsset(
    root: URL,
    name: String,
    xcodeVersion: String,
    osVersion: String,
    documentationRelease: Int
) throws {
    let assetURL = root.appendingPathComponent("\(name).asset", isDirectory: true)
    let assetDataURL = assetURL.appendingPathComponent("AssetData", isDirectory: true)
    let databaseURL = assetDataURL.appendingPathComponent("documentation-db", isDirectory: true)
    try FileManager.default.createDirectory(
        at: databaseURL,
        withIntermediateDirectories: true
    )
    let plist = TestDocumentationAssetInfoPlist(
        properties: TestDocumentationAssetProperties(
            documentationRelease: String(documentationRelease),
            xcodeVersion: xcodeVersion,
            osVersion: osVersion
        )
    )
    try PropertyListEncoder().encode(plist).write(
        to: assetURL.appendingPathComponent("Info.plist", isDirectory: false)
    )
    try Data("{}".utf8).write(
        to: assetDataURL.appendingPathComponent("config.json", isDirectory: false)
    )
    try Data("-- sqlite index placeholder".utf8).write(
        to: databaseURL.appendingPathComponent("index.sql", isDirectory: false)
    )
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

func toolResultIsError(in responseData: Data) throws -> Bool {
    let object = try #require(
        JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any]
    )
    let result = try #require(object["result"] as? [String: Any])
    return result["isError"] as? Bool == true
}

func responseID(in responseData: Data) throws -> Int64 {
    let object = try #require(
        JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any]
    )
    let id = try #require(object["id"] as? NSNumber)
    return id.int64Value
}

func jsonRPCErrorMessage(in responseData: Data) throws -> String? {
    let object = try #require(
        JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any]
    )
    let error = try #require(object["error"] as? [String: Any])
    return error["message"] as? String
}

func xcodeProcessTarget(processID: pid_t) -> XcodeProcessTarget {
    XcodeProcessTarget(
        processID: processID,
        appPath: "/Applications/Xcode-\(processID).app",
        developerDir: "/Applications/Xcode-\(processID).app/Contents/Developer",
        mcpbridgePath: "/Applications/Xcode-\(processID).app/Contents/Developer/usr/bin/mcpbridge",
        xcodeVersion: "\(processID).0"
    )
}

func xcodeProcessTarget(
    processID: pid_t,
    xcodeVersion: String
) -> XcodeProcessTarget {
    XcodeProcessTarget(
        processID: processID,
        appPath: "/Applications/Xcode-\(processID).app",
        developerDir: "/Applications/Xcode-\(processID).app/Contents/Developer",
        mcpbridgePath: "/Applications/Xcode-\(processID).app/Contents/Developer/usr/bin/mcpbridge",
        xcodeVersion: xcodeVersion
    )
}

struct StubXcodeTargetDiscovery: XcodeTargetDiscovering {
    let targets: [XcodeProcessTarget]

    func runningXcodeTargets() -> [XcodeProcessTarget] {
        targets
    }
}

final class CountingXcodeTargetDiscovery: XcodeTargetDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private let targets: [XcodeProcessTarget]
    private var callCountValue = 0

    init(targets: [XcodeProcessTarget]) {
        self.targets = targets
    }

    func runningXcodeTargets() -> [XcodeProcessTarget] {
        lock.lock()
        callCountValue += 1
        lock.unlock()
        return targets
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountValue
    }
}

actor BlockingFallbackDocumentationProviderTransport: DocumentationProviderRouting {
    private let openStarted: TestSignal
    private let openGate: AsyncGate
    private let ignoresOpenCancellation: Bool
    private var openCountValue = 0
    private var closedRouteIDs: [String] = []

    init(
        openStarted: TestSignal,
        openGate: AsyncGate,
        ignoresOpenCancellation: Bool = false
    ) {
        self.openStarted = openStarted
        self.openGate = openGate
        self.ignoresOpenCancellation = ignoresOpenCancellation
    }

    func openRoute(
        for target: XcodeProcessTarget,
        requestTimeout _: TimeAmount?,
        initializeParams _: [String: JSONValue]
    ) async throws -> DocumentationProviderRoute {
        openCountValue += 1
        let routeID = "blocking-fallback-\(target.processID)-\(openCountValue)"
        openStarted.signal()
        if ignoresOpenCancellation {
            await openGate.waitIgnoringCancellation()
        } else {
            try await openGate.wait()
        }
        return DocumentationProviderRoute(
            id: routeID,
            target: target,
            upstreamIndex: nil,
            serverVersion: "fallback"
        )
    }

    func toolsList(
        route _: DocumentationProviderRoute,
        timeout _: TimeAmount?
    ) async throws -> JSONValue {
        try jsonValue([
            "tools": [
                documentationDescriptor(version: "fallback").foundationObject,
            ],
        ])
    }

    func callDocumentationSearch(
        route _: DocumentationProviderRoute,
        requestData: Data,
        timeout _: TimeAmount?
    ) async throws -> Data {
        let object = try JSONSerialization.jsonObject(with: requestData, options: [])
            as? [String: Any]
        let id = object?["id"] ?? 0
        return try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "content": [
                        [
                            "type": "text",
                            "text": "{\"answer\":\"fallback\"}",
                        ],
                    ],
                    "isError": false,
                ],
            ],
            options: []
        )
    }

    func close(route: DocumentationProviderRoute) async {
        closedRouteIDs.append(route.id)
    }

    func closeCount() -> Int {
        closedRouteIDs.count
    }

    func openCount() -> Int {
        openCountValue
    }
}

struct UnavailableDocumentationProviderTransport: DocumentationProviderRouting {
    func openRoute(
        for _: XcodeProcessTarget,
        requestTimeout _: TimeAmount?,
        initializeParams _: [String: JSONValue]
    ) async throws -> DocumentationProviderRoute {
        throw UpstreamSlotScheduler.AcquisitionError.unavailable
    }

    func toolsList(
        route _: DocumentationProviderRoute,
        timeout _: TimeAmount?
    ) async throws -> JSONValue {
        throw UpstreamSlotScheduler.AcquisitionError.unavailable
    }

    func callDocumentationSearch(
        route _: DocumentationProviderRoute,
        requestData _: Data,
        timeout _: TimeAmount?
    ) async throws -> Data {
        throw UpstreamSlotScheduler.AcquisitionError.unavailable
    }
}

actor StubDocumentationSearchServiceRepairer: DocumentationSearchServiceRepairing {
    private let result: DocumentationSearchServiceRepairResult
    private let gate: OperationGate<pid_t>?
    private var repairedProcessIDs: [pid_t] = []
    private var cancelledProcessIDs: [pid_t] = []
    private let cancelledPIDValues = RecordedValues<pid_t>()

    init(
        result: DocumentationSearchServiceRepairResult,
        gate: OperationGate<pid_t>? = nil
    ) {
        self.result = result
        self.gate = gate
    }

    func repairDocumentationSearch(
        for target: XcodeProcessTarget
    ) async -> DocumentationSearchServiceRepairResult {
        repairedProcessIDs.append(target.processID)
        if let gate {
            do {
                try await gate.wait(for: target.processID)
            } catch is CancellationError {
                cancelledProcessIDs.append(target.processID)
                await cancelledPIDValues.append(target.processID)
            } catch {
            }
        }
        return result
    }

    func repairedPIDs() -> [pid_t] {
        repairedProcessIDs
    }

    func cancelledPIDs() -> [pid_t] {
        cancelledProcessIDs
    }

    func nextCancelledPID(at index: Int) async throws -> pid_t {
        try await cancelledPIDValues.nextValue(at: index)
    }
}

actor StubDocumentationSearchProvider: DocumentationSearchProviding {
    private let descriptorValue: JSONValue?
    private let responseData: Data
    private let failsCalls: Bool
    private let failAfterSuccessfulCallCount: Int?
    private let timeoutOnceAfterSuccessfulCallCount: Int?
    private var descriptorPIDs: [pid_t] = []
    private var callPIDs: [pid_t] = []
    private var queries: [String] = []
    private var successfulCallCount = 0
    private var didThrowTimeout = false

    init(
        descriptor: JSONValue?,
        responseData: Data,
        failsCalls: Bool = false,
        failAfterSuccessfulCallCount: Int? = nil,
        timeoutOnceAfterSuccessfulCallCount: Int? = nil
    ) {
        self.descriptorValue = descriptor
        self.responseData = responseData
        self.failsCalls = failsCalls
        self.failAfterSuccessfulCallCount = failAfterSuccessfulCallCount
        self.timeoutOnceAfterSuccessfulCallCount = timeoutOnceAfterSuccessfulCallCount
    }

    func descriptor(for target: XcodeProcessTarget) async -> JSONValue? {
        descriptorPIDs.append(target.processID)
        return descriptorValue
    }

    func callDocumentationSearch(
        requestData: Data,
        for target: XcodeProcessTarget,
        timeout _: TimeAmount?
    ) async throws -> Data {
        callPIDs.append(target.processID)
        if let query = try documentationSearchQuery(in: requestData) {
            queries.append(query)
        }
        if failsCalls {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        if let timeoutOnceAfterSuccessfulCallCount,
           successfulCallCount >= timeoutOnceAfterSuccessfulCallCount,
           didThrowTimeout == false
        {
            didThrowTimeout = true
            throw TimeoutError()
        }
        if let failAfterSuccessfulCallCount,
           successfulCallCount >= failAfterSuccessfulCallCount
        {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        successfulCallCount += 1
        return responseData
    }

    func requestedDescriptorPIDs() -> [pid_t] {
        descriptorPIDs
    }

    func requestedCallPIDs() -> [pid_t] {
        callPIDs
    }

    func requestedQueries() -> [String] {
        queries
    }
}

actor StubProcessRunner: ProcessRunning {
    private let output: ProcessOutput
    private let gate: OperationGate<Int>?
    private var requests: [ProcessRequest] = []
    private var cancelledRunCountValue = 0
    private let cancelledRunValues = RecordedValues<Int>()

    init(output: ProcessOutput, gate: OperationGate<Int>? = nil) {
        self.output = output
        self.gate = gate
    }

    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        requests.append(request)
        let runIndex = requests.count
        if let gate {
            do {
                try await gate.wait(for: runIndex)
            } catch is CancellationError {
                cancelledRunCountValue += 1
                await cancelledRunValues.append(cancelledRunCountValue)
                throw CancellationError()
            }
        }
        return output
    }

    func recordedRequests() -> [ProcessRequest] {
        requests
    }

    func cancelledRunCount() -> Int {
        cancelledRunCountValue
    }

    func nextCancelledRunCount(at index: Int) async throws -> Int {
        try await cancelledRunValues.nextValue(at: index)
    }
}

actor TransientUnavailableDescriptorTransport: DocumentationProviderRouting {
    private var toolsListCountValue = 0
    private let toolsListCountValues = RecordedValues<Int>()

    func openRoute(
        for target: XcodeProcessTarget,
        requestTimeout _: TimeAmount?,
        initializeParams _: [String: JSONValue]
    ) async throws -> DocumentationProviderRoute {
        DocumentationProviderRoute(
            id: "transient-\(target.processID)",
            target: target,
            upstreamIndex: nil,
            serverVersion: target.xcodeVersion
        )
    }

    func toolsList(
        route _: DocumentationProviderRoute,
        timeout _: TimeAmount?
    ) async throws -> JSONValue {
        toolsListCountValue += 1
        await toolsListCountValues.append(toolsListCountValue)
        if toolsListCountValue == 1 {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        return try jsonValue([
            "tools": [
                documentationDescriptor(version: "transient").foundationObject,
            ],
        ])
    }

    func callDocumentationSearch(
        route _: DocumentationProviderRoute,
        requestData _: Data,
        timeout _: TimeAmount?
    ) async throws -> Data {
        throw UpstreamSlotScheduler.AcquisitionError.unavailable
    }

    func toolsListCount() -> Int {
        toolsListCountValue
    }

    func waitForToolsListCount(_ count: Int) async throws {
        guard count > 0 else {
            return
        }
        _ = try await toolsListCountValues.nextValue(at: count - 1)
    }
}

actor ReusedRouteRepairTransport: DocumentationProviderRouting {
    private var openCountValue = 0
    private var toolsListCountValue = 0
    private var closedRouteIDs: [String] = []

    func openRoute(
        for target: XcodeProcessTarget,
        requestTimeout _: TimeAmount?,
        initializeParams _: [String: JSONValue]
    ) async throws -> DocumentationProviderRoute {
        openCountValue += 1
        return DocumentationProviderRoute(
            id: "reused-\(target.processID)",
            target: target,
            upstreamIndex: 0,
            serverVersion: target.xcodeVersion
        )
    }

    func toolsList(
        route _: DocumentationProviderRoute,
        timeout _: TimeAmount?
    ) async throws -> JSONValue {
        toolsListCountValue += 1
        let tools: [Any]
        if toolsListCountValue == 1 {
            tools = []
        } else {
            tools = [documentationDescriptor(version: "reused").foundationObject]
        }
        return try jsonValue(["tools": tools])
    }

    func callDocumentationSearch(
        route: DocumentationProviderRoute,
        requestData: Data,
        timeout _: TimeAmount?
    ) async throws -> Data {
        guard closedRouteIDs.contains(route.id) == false else {
            throw UpstreamSlotScheduler.AcquisitionError.unavailable
        }
        let object = try JSONSerialization.jsonObject(with: requestData, options: [])
            as? [String: Any]
        let id = object?["id"] ?? 0
        return try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "content": [
                        [
                            "type": "text",
                            "text": "{\"answer\":\"reused\"}",
                        ],
                    ],
                    "isError": false,
                ],
            ],
            options: []
        )
    }

    func close(route: DocumentationProviderRoute) async {
        closedRouteIDs.append(route.id)
    }

    func openCount() -> Int {
        openCountValue
    }

    func toolsListCount() -> Int {
        toolsListCountValue
    }

    func closedRoutes() -> [String] {
        closedRouteIDs
    }
}

final class SequencedXcodeTargetDiscovery: XcodeTargetDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingSequences: [[XcodeProcessTarget]]
    private var lastSequence: [XcodeProcessTarget]

    init(_ sequences: [[XcodeProcessTarget]]) {
        self.remainingSequences = sequences
        self.lastSequence = sequences.last ?? []
    }

    func runningXcodeTargets() -> [XcodeProcessTarget] {
        lock.lock()
        defer { lock.unlock() }
        guard remainingSequences.isEmpty == false else {
            return lastSequence
        }
        let targets = remainingSequences.removeFirst()
        lastSequence = targets
        return targets
    }
}

enum ScriptedDocumentationResponse: Sendable {
    case success
    case successText(String)
    case toolErrorText(String)
    case jsonRPCError(code: Int, message: String)
    case hang
    case notEnabled
    case exit
}

struct ScriptedDocumentationSessionPlan: Sendable {
    let serverVersion: String
    let toolCount: Int
    let includesDocumentationSearch: Bool
    let hangsToolsList: Bool
    let firstDocumentationResponse: ScriptedDocumentationResponse
    let userCallResponses: [ScriptedDocumentationResponse]
    let requiresNumericRequestIDs: Bool

    init(
        serverVersion: String,
        toolCount: Int,
        includesDocumentationSearch: Bool,
        hangsToolsList: Bool = false,
        firstDocumentationResponse: ScriptedDocumentationResponse,
        userCallResponses: [ScriptedDocumentationResponse] = [],
        requiresNumericRequestIDs: Bool = false
    ) {
        self.serverVersion = serverVersion
        self.toolCount = toolCount
        self.includesDocumentationSearch = includesDocumentationSearch
        self.hangsToolsList = hangsToolsList
        self.firstDocumentationResponse = firstDocumentationResponse
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
    private var stoppedProcessIDs: [pid_t] = []
    private var initializeParamsByPID: [pid_t: [JSONValue]] = [:]
    private var requestCountsByPID: [pid_t: [String: Int]] = [:]
    private var documentationQueriesByPID: [pid_t: [String]] = [:]
    private var requestCountWaiters: [RequestCountWaiter] = []
    private let startGate: OperationGate<pid_t>?

    init(
        plansByPID: [pid_t: [ScriptedDocumentationSessionPlan]],
        startGate: OperationGate<pid_t>? = nil
    ) {
        self.plansByPID = plansByPID
        self.startGate = startGate
    }

    func startSession(for target: XcodeProcessTarget) async throws -> any UpstreamSession {
        startAttemptProcessIDs.append(target.processID)
        if let startGate {
            try await startGate.wait(for: target.processID)
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

    func stoppedPIDs() -> [pid_t] {
        stoppedProcessIDs
    }

    func startAttempts() -> [pid_t] {
        startAttemptProcessIDs
    }

    func recordStop(for processID: pid_t) {
        stoppedProcessIDs.append(processID)
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

    func recordDocumentationQuery(_ query: String, for processID: pid_t) {
        documentationQueriesByPID[processID, default: []].append(query)
    }

    func documentationQueries(for processID: pid_t) -> [String] {
        documentationQueriesByPID[processID] ?? []
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
            guard plan.hangsToolsList == false else {
                return .accepted
            }
            yieldResponse(
                id: requestID,
                result: [
                    "tools": toolsList(),
                ]
            )
        case "tools/call":
            if let params = object["params"] as? [String: Any],
               let arguments = params["arguments"] as? [String: Any],
               let query = arguments["query"] as? String {
                await recorder.recordDocumentationQuery(query, for: processID)
            }
            documentationCallCount += 1
            let response: ScriptedDocumentationResponse
            if documentationCallCount == 1 {
                response = plan.firstDocumentationResponse
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
        await recorder.recordStop(for: processID)
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
        case .toolErrorText(let text):
            yieldToolResponse(id: id, text: text, isError: true)
        case .jsonRPCError(let code, let message):
            yieldJSONRPCError(id: id, code: code, message: message)
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

    private func yieldJSONRPCError(id: Any, code: Int, message: String) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message,
            ],
        ]
        guard JSONSerialization.isValidJSONObject(response),
              let data = try? JSONSerialization.data(withJSONObject: response, options: []) else {
            return
        }
        continuation.yield(.message(data))
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
    private let prewarmCountValues = RecordedValues<Int>()
    private let prewarmStarted: TestSignal?
    private let prewarmBlocker: AsyncGate?
    private let toolListStarted: TestSignal?
    private let toolListBlocker: AsyncGate?

    init(
        toolListUpdate: DocumentationProvider.ToolListUpdate,
        callOutcomes: [DocumentationProvider.CallOutcome] = [],
        prewarmStarted: TestSignal? = nil,
        prewarmBlocker: AsyncGate? = nil,
        toolListStarted: TestSignal? = nil,
        toolListBlocker: AsyncGate? = nil
    ) {
        self.update = toolListUpdate
        self.callOutcomes = callOutcomes
        self.prewarmStarted = prewarmStarted
        self.prewarmBlocker = prewarmBlocker
        self.toolListStarted = toolListStarted
        self.toolListBlocker = toolListBlocker
    }

    func startBackgroundDiscovery(requestTimeout: TimeAmount?) async
        -> DocumentationProvider.ToolListUpdate
    {
        prewarmStarted?.signal()
        if let prewarmBlocker {
            do {
                try await prewarmBlocker.wait()
            } catch {
                return .unavailable
            }
            guard !Task.isCancelled else { return .unavailable }
        }
        prewarmTimeouts.append(requestTimeout)
        await prewarmCountValues.append(prewarmTimeouts.count)
        return update
    }

    func toolListUpdate(requestTimeout: TimeAmount?) async -> DocumentationProvider.ToolListUpdate {
        toolListTimeouts.append(requestTimeout)
        toolListStarted?.signal()
        if let toolListBlocker {
            do {
                try await toolListBlocker.wait()
            } catch {
                return .unavailable
            }
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

    func waitForPrewarmCount(_ count: Int) async throws {
        guard count > 0 else {
            return
        }
        _ = try await prewarmCountValues.nextValue(at: count - 1)
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

    func setToolListUpdate(_ update: DocumentationProvider.ToolListUpdate) {
        self.update = update
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
    let configMirror = try upstreamConfigMirror(from: upstream)
    return try #require(
        configMirror.children.first(where: { $0.label == "environment" })?.value
            as? [String: String],
        "UpstreamProcess.Config should include environment for tests"
    )
}

func upstreamCommand(from upstream: ManagedUpstreamSlot) throws -> String {
    let configMirror = try upstreamConfigMirror(from: upstream)
    return try #require(
        configMirror.children.first(where: { $0.label == "command" })?.value as? String,
        "UpstreamProcess.Config should include command for tests"
    )
}

func upstreamArgs(from upstream: ManagedUpstreamSlot) throws -> [String] {
    let configMirror = try upstreamConfigMirror(from: upstream)
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
    let factoryMirror = Mirror(reflecting: factory)
    let config = try #require(
        factoryMirror.children.first(where: { $0.label == "config" })?.value,
        "UpstreamProcess factory should expose a stored config for tests"
    )
    return Mirror(reflecting: config)
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

    func nextSent(
        startingAt index: Int,
        matching predicate: @escaping @Sendable (Data) -> Bool
    ) async throws -> Data {
        try await sentMessages.nextValue(startingAt: index, matching: predicate)
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
    private var releaseCredits = 0
    private var waiters: [(index: Int, continuation: CheckedContinuation<UInt64, Error>)] = []

    func sleep(nanoseconds: UInt64) async {
        sleeps.append(nanoseconds)
        resumeReadyWaiters()
        if releaseCredits > 0 {
            releaseCredits -= 1
            return
        }
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
        guard !sleepContinuations.isEmpty else {
            releaseCredits += 1
            return
        }
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
    availability: AvailabilityFlag? = nil,
    sleepRecorder: ControlledReadinessSleep? = nil,
    recordPollSleeps: Bool = false,
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
            if let sleepRecorder, recordPollSleeps || nanoseconds >= 1_000_000_000 {
                await sleepRecorder.sleep(nanoseconds: nanoseconds)
            } else {
                // Readiness polling models OS process availability. Tests that
                // need to assert a poll point pass sleepRecorder instead.
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
) async {
    await timeoutClock.sleep(untilSuspendedBy: suspendedSleepers)
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

func methodName(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    else {
        return nil
    }
    return object["method"] as? String
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

func makeXcodeListWindowsResponse(id: Int64, message: String) throws -> Data {
    let encodedMessage = String(
        decoding: try JSONSerialization.data(
            withJSONObject: ["message": message],
            options: [.sortedKeys]
        ),
        as: UTF8.self
    )
    return try JSONSerialization.data(
        withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": encodedMessage,
                    ],
                ],
                "structuredContent": [
                    "message": message,
                ],
            ],
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
