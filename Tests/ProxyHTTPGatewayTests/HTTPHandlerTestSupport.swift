import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOHTTP1
import Testing
import ProxyCore
import ProxyMCP
import ProxySession
import ProxyXcodeFeatures
import ProxyXcodeSupport
import XcodeMCPTestSupport

@testable import ProxyHTTPGateway

enum HTTPTestError: Error {
    case missingResponseHead
}

private let httpTestSessionRegistry = NIOLockedValueBox<[String: any RuntimeCoordinating]>([:])

private func registerHTTPTestServer(
    url: URL,
    sessionManager: any RuntimeCoordinating
) {
    httpTestSessionRegistry.withLockedValue { registry in
        registry[url.absoluteString] = sessionManager
    }
}

private func unregisterHTTPTestServer(url: URL) {
    _ = httpTestSessionRegistry.withLockedValue { registry in
        registry.removeValue(forKey: url.absoluteString)
    }
}

private func prepareHTTPTestSession(url: URL, sessionID: String) {
    let sessionManager = httpTestSessionRegistry.withLockedValue { registry in
        registry[url.absoluteString]
    }
    _ = sessionManager?.session(id: sessionID)
}

struct UpstreamResponsePlan {
    let data: Data
    let delayNanos: UInt64?
    let deliverManually: Bool

    static func immediate(_ data: Data) -> UpstreamResponsePlan {
        UpstreamResponsePlan(data: data, delayNanos: nil, deliverManually: false)
    }

    static func delayed(
        _ data: Data,
        delayNanos: UInt64
    ) -> UpstreamResponsePlan {
        UpstreamResponsePlan(data: data, delayNanos: delayNanos, deliverManually: false)
    }

    static func manual(_ data: Data) -> UpstreamResponsePlan {
        UpstreamResponsePlan(data: data, delayNanos: nil, deliverManually: true)
    }
}

final class TestRuntimeCoordinator: RuntimeCoordinating {
    private struct UpstreamMapping: Sendable {
        let sessionID: String
        let originalID: RPCID
    }

    private struct ChooseUpstreamCall: Sendable {
        let sessionID: String?
    }

    private struct SentRequest: Sendable {
        let method: String
        let toolName: String?
        let upstreamIndex: Int
    }

    private struct State: Sendable {
        struct PendingResponse: Sendable {
            let sessionID: String
            let data: Data
        }

        var sessions: [String: SessionContext] = [:]
        var sessionProtocolVersions: [String: String] = [:]
        var nextUpstreamID: Int64 = 1
        var assignUpstreamIDCount = 0
        var initialized = false
        var cachedToolsList: JSONValue?
        var refreshToolsListCalls = 0
        var upstreamSendCount = 0
        var upstreamIDMapping: [Int64: UpstreamMapping] = [:]
        var chooseUpstreamCalls: [ChooseUpstreamCall] = []
        var availableUpstreamIndex: Int? = 0
        var requestTimeoutNotifications = 0
        var requestSuccessNotifications = 0
        var pendingResponses: [PendingResponse] = []
        var sentRequests: [SentRequest] = []
        var sentUpstreamPayloads: [Data] = []
        var availableUpstreamIndices: [Int?] = []
        var requeuedLeaseCount = 0
        var serverRequestResponseSendResults: [UpstreamSendResult] = []
    }

    private let state = NIOLockedValueBox(State())
    private let config: ProxyConfig
    private let upstreamRequestResponder:
        (@Sendable (_ method: String, _ toolName: String?, _ originalID: RPCID) throws -> UpstreamResponsePlan)?
    private let upstreamResponder:
        (@Sendable (_ method: String, _ originalID: RPCID) throws -> UpstreamResponsePlan)?
    private let legacyUpstreamResponder:
        (@Sendable (_ method: String, _ originalID: RPCID) throws -> Data)?
    private let documentationSearchResponder:
        (@Sendable (_ requestData: Data) async throws -> Data)?
    private let cancelAfterStartingEnqueueRequest: Bool
    private let requestLeaseRegistry = LeaseManager()

    init(
        config: ProxyConfig,
        upstreamResponder: (@Sendable (_ method: String, _ originalID: RPCID) throws -> Data)? = nil,
        documentationSearchResponder:
            (@Sendable (_ requestData: Data) async throws -> Data)? = nil,
        cancelAfterStartingEnqueueRequest: Bool = false
    ) {
        self.config = config
        self.upstreamRequestResponder = nil
        self.upstreamResponder = nil
        self.legacyUpstreamResponder = upstreamResponder
        self.documentationSearchResponder = documentationSearchResponder
        self.cancelAfterStartingEnqueueRequest = cancelAfterStartingEnqueueRequest
    }

    init(
        config: ProxyConfig,
        upstreamPlanResponder: (@Sendable (_ method: String, _ originalID: RPCID) throws -> UpstreamResponsePlan)?,
        documentationSearchResponder:
            (@Sendable (_ requestData: Data) async throws -> Data)? = nil,
        cancelAfterStartingEnqueueRequest: Bool = false
    ) {
        self.config = config
        self.upstreamRequestResponder = nil
        self.upstreamResponder = upstreamPlanResponder
        self.legacyUpstreamResponder = nil
        self.documentationSearchResponder = documentationSearchResponder
        self.cancelAfterStartingEnqueueRequest = cancelAfterStartingEnqueueRequest
    }

    init(
        config: ProxyConfig,
        upstreamRequestResponder: (@Sendable (_ method: String, _ toolName: String?, _ originalID: RPCID) throws -> UpstreamResponsePlan)?,
        documentationSearchResponder:
            (@Sendable (_ requestData: Data) async throws -> Data)? = nil,
        cancelAfterStartingEnqueueRequest: Bool = false
    ) {
        self.config = config
        self.upstreamRequestResponder = upstreamRequestResponder
        self.upstreamResponder = nil
        self.legacyUpstreamResponder = nil
        self.documentationSearchResponder = documentationSearchResponder
        self.cancelAfterStartingEnqueueRequest = cancelAfterStartingEnqueueRequest
    }

    func session(id: String) -> SessionContext {
        state.withLockedValue { state in
            if let existing = state.sessions[id] {
                return existing
            }
            let context = SessionContext(id: id, config: config)
            state.sessions[id] = context
            state.sessionProtocolVersions[id] = MCPProtocolVersion.current
            return context
        }
    }

    func uninitializedSession(id: String) -> SessionContext {
        state.withLockedValue { state in
            if let existing = state.sessions[id] {
                state.sessionProtocolVersions.removeValue(forKey: id)
                return existing
            }
            let context = SessionContext(id: id, config: config)
            state.sessions[id] = context
            state.sessionProtocolVersions.removeValue(forKey: id)
            return context
        }
    }

    func hasSession(id: String) -> Bool {
        state.withLockedValue { state in
            state.sessions[id] != nil
        }
    }

    func negotiatedProtocolVersion(id: String) -> String? {
        state.withLockedValue { state in
            state.sessionProtocolVersions[id]
        }
    }

    func removeSession(id: String) {
        let context = state.withLockedValue { state in
            state.sessionProtocolVersions.removeValue(forKey: id)
            return state.sessions.removeValue(forKey: id)
        }
        context?.notificationHub.closeAll()
    }

    func debugReset() {
        state.withLockedValue { state in
            state.sessions.removeAll()
            state.sessionProtocolVersions.removeAll()
            state.cachedToolsList = nil
            state.pendingResponses.removeAll()
            state.sentRequests.removeAll()
            state.sentUpstreamPayloads.removeAll()
            state.upstreamIDMapping.removeAll()
        }
    }

    func shutdown() async {}

    func isInitialized() -> Bool {
        state.withLockedValue { state in
            state.initialized
        }
    }

    func cachedToolsListResult() -> JSONValue? {
        state.withLockedValue { $0.cachedToolsList }
    }

    func setCachedToolsListResult(_ result: JSONValue, sourceUpstream _: Int) {
        state.withLockedValue { state in
            state.cachedToolsList = result
        }
    }

    func refreshToolsListIfNeeded() {
        state.withLockedValue { state in
            state.refreshToolsListCalls += 1
        }
    }

    func registerInitialize(
        sessionID: String,
        originalID: RPCID,
        requestObject: [String: Any],
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ByteBuffer> {
        let negotiatedProtocolVersion =
            ((requestObject["params"] as? [String: Any])?["protocolVersion"] as? String)
            ?? MCPProtocolVersion.current
        _ = session(id: sessionID)
        state.withLockedValue { state in
            state.initialized = true
            state.sessionProtocolVersions[sessionID] = negotiatedProtocolVersion
        }
        _ = chooseUpstreamIndex()
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalID.value.foundationObject,
            "result": [
                "protocolVersion": negotiatedProtocolVersion,
                "capabilities": [String: Any]()
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: response, options: [])) ?? Data()
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return eventLoop.makeSucceededFuture(buffer)
    }

    func sharedToolsList(
        sessionID: String,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue {
        _ = requestTimeoutOverride
        if let cached = state.withLockedValue({ $0.cachedToolsList }) {
            return cached
        }
        let responseData = try await performSharedControlPlaneRequest(
            method: "tools/list",
            toolName: nil,
            sessionID: sessionID
        )
        guard let object = try JSONSerialization.jsonObject(
            with: responseData,
            options: []
        ) as? [String: Any],
            let resultAny = object["result"],
            let result = JSONValue(any: resultAny)
        else {
            throw NSError(domain: "TestRuntimeCoordinator", code: 2)
        }
        state.withLockedValue { state in
            state.cachedToolsList = result
        }
        return result
    }


    func liveXcodeListWindowsResult(
        route _: ControlPlaneRoute,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> JSONValue {
        _ = requestTimeoutOverride
        let responseData = try await performSharedControlPlaneRequest(
            method: "tools/call",
            toolName: "XcodeListWindows",
            sessionID: "__test-control-plane__"
        )
        guard let object = try JSONSerialization.jsonObject(
            with: responseData,
            options: []
        ) as? [String: Any],
            let resultAny = object["result"],
            let result = JSONValue(any: resultAny)
        else {
            throw NSError(domain: "TestRuntimeCoordinator", code: 3)
        }
        return result
    }

    func callDocumentationSearch(
        requestData: Data,
        requestTimeoutOverride: TimeAmount?
    ) async throws -> DocumentationSearchOutcome {
        _ = requestTimeoutOverride
        guard let documentationSearchResponder else {
            return .unavailable(.noAvailableProvider)
        }
        do {
            return .handled(try await documentationSearchResponder(requestData))
        } catch is UpstreamSlotAcquisitionError {
            return .unavailable(.noAvailableProvider)
        }
    }

    func hasDocumentationProvider() -> Bool {
        documentationSearchResponder != nil
    }


    func chooseUpstreamIndex() -> Int? {
        state.withLockedValue { state in
            state.chooseUpstreamCalls.append(
                ChooseUpstreamCall(sessionID: nil)
            )
            if state.availableUpstreamIndices.isEmpty == false {
                return state.availableUpstreamIndices.removeFirst()
            }
            return state.availableUpstreamIndex
        }
    }

    func enqueueOnUpstreamSlot<Output: Sendable>(
        leaseID _: RequestLeaseID,
        descriptor _: SessionPipelineRequestDescriptor,
        on eventLoop: EventLoop,
        preferredUpstreamIndex: Int?,
        starter: @escaping @Sendable (Int) -> EventLoopFuture<Output>
    ) -> EventLoopFuture<Output> {
        let upstreamIndex = preferredUpstreamIndex ?? chooseUpstreamIndex()
        guard let upstreamIndex else {
            return eventLoop.makeFailedFuture(
                NSError(domain: "TestRuntimeCoordinator", code: 1)
            )
        }
        if cancelAfterStartingEnqueueRequest {
            _ = starter(upstreamIndex)
            return eventLoop.makeFailedFuture(CancellationError())
        }
        return starter(upstreamIndex)
    }

    func assignUpstreamID(sessionID: String, originalID: RPCID, upstreamIndex _: Int) -> Int64 {
        state.withLockedValue { state in
            state.assignUpstreamIDCount += 1
            let id = state.nextUpstreamID
            state.nextUpstreamID += 1
            state.upstreamIDMapping[id] = UpstreamMapping(
                sessionID: sessionID, originalID: originalID)
            return id
        }
    }

    func removeUpstreamIDMapping(sessionID: String, requestIDKey: String, upstreamIndex _: Int) {
        state.withLockedValue { state in
            let removed = state.upstreamIDMapping.first { _, mapping in
                mapping.sessionID == sessionID && mapping.originalID.key == requestIDKey
            }?.key
            if let removed {
                state.upstreamIDMapping.removeValue(forKey: removed)
            }
        }
    }

    func onRequestTimeout(sessionID: String, requestIDKey: String, upstreamIndex: Int) {
        state.withLockedValue { state in
            state.requestTimeoutNotifications += 1
        }
        removeUpstreamIDMapping(
            sessionID: sessionID, requestIDKey: requestIDKey, upstreamIndex: upstreamIndex)
    }

    func onRequestSucceeded(sessionID _: String, requestIDKey _: String, upstreamIndex _: Int) {
        state.withLockedValue { state in
            state.requestSuccessNotifications += 1
        }
    }

    func sendUpstream(_ data: Data, upstreamIndex: Int, ensureRunning: Bool) {
        _ = ensureRunning
        state.withLockedValue { state in
            state.upstreamSendCount += 1
            state.sentUpstreamPayloads.append(data)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return
        }
        if let object = json as? [String: Any] {
            handleSingleUpstreamRequest(object, upstreamIndex: upstreamIndex)
            return
        }
        if let array = json as? [Any] {
            handleBatchUpstreamRequest(array, upstreamIndex: upstreamIndex)
        }
    }

    func forwardServerRequestResponse(
        responseData: Data,
        sessionID: String,
        responseID: RPCID,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<ServerRequestResponseForwardingResult> {
        let session = session(id: sessionID)
        guard let route = session.serverRequestTracker.lookup(clientID: responseID) else {
            return eventLoop.makeSucceededFuture(.missingRoute)
        }
        guard var rewritten = try? JSONSerialization.jsonObject(
            with: responseData,
            options: []
        ) as? [String: Any] else {
            return eventLoop.makeSucceededFuture(.invalidResponse)
        }
        rewritten["id"] = route.upstreamID.value.foundationObject
        guard JSONSerialization.isValidJSONObject(rewritten),
            let data = try? JSONSerialization.data(withJSONObject: rewritten, options: [])
        else {
            return eventLoop.makeSucceededFuture(.invalidResponse)
        }

        let sendResult = state.withLockedValue { state -> UpstreamSendResult in
            state.upstreamSendCount += 1
            state.sentUpstreamPayloads.append(data)
            if state.serverRequestResponseSendResults.isEmpty {
                return .accepted
            }
            return state.serverRequestResponseSendResults.removeFirst()
        }
        switch sendResult {
        case .accepted:
            _ = session.serverRequestTracker.complete(clientID: responseID, route: route)
            return eventLoop.makeSucceededFuture(.accepted)
        case .backpressure, .unavailable:
            return eventLoop.makeSucceededFuture(.upstreamUnavailable)
        }
    }

    func setServerRequestResponseSendResults(_ results: [UpstreamSendResult]) {
        state.withLockedValue { state in
            state.serverRequestResponseSendResults = results
        }
    }

    private func handleSingleUpstreamRequest(_ object: [String: Any], upstreamIndex: Int) {
        guard let method = object["method"] as? String,
            let upstreamIDValue = object["id"]
        else {
            return
        }
        let toolName = ((object["params"] as? [String: Any])?["name"] as? String)
        state.withLockedValue { state in
            state.sentRequests.append(
                SentRequest(
                    method: method,
                    toolName: toolName,
                    upstreamIndex: upstreamIndex
                )
            )
        }
        let upstreamID = (upstreamIDValue as? NSNumber)?.int64Value ?? (upstreamIDValue as? Int64)
        guard let upstreamID,
            let mapping = state.withLockedValue({ $0.upstreamIDMapping[upstreamID] })
        else {
            return
        }

        let responsePlan = responsePlan(
            method: method,
            toolName: toolName,
            originalID: mapping.originalID
        )
        let deliverResponse = { [self] in
            let session = self.session(id: mapping.sessionID)
            session.router.handleIncoming(responsePlan.data)
        }
        if responsePlan.deliverManually {
            state.withLockedValue { state in
                state.pendingResponses.append(
                    State.PendingResponse(
                        sessionID: mapping.sessionID,
                        data: responsePlan.data
                    )
                )
            }
        } else if let delayNanos = responsePlan.delayNanos {
            Task {
                try? await Task.sleep(nanoseconds: delayNanos)
                deliverResponse()
            }
        } else {
            deliverResponse()
        }
    }

    private func handleBatchUpstreamRequest(_ array: [Any], upstreamIndex: Int) {
        var sessionID: String?
        var responseObjects: [Any] = []

        for item in array {
            guard let object = item as? [String: Any],
                let method = object["method"] as? String
            else {
                continue
            }
            let toolName = ((object["params"] as? [String: Any])?["name"] as? String)
            state.withLockedValue { state in
                state.sentRequests.append(
                    SentRequest(
                        method: method,
                        toolName: toolName,
                        upstreamIndex: upstreamIndex
                    )
                )
            }

            guard let upstreamIDValue = object["id"] else {
                continue
            }
            let upstreamID =
                (upstreamIDValue as? NSNumber)?.int64Value ?? (upstreamIDValue as? Int64)
            guard let upstreamID,
                let mapping = state.withLockedValue({ $0.upstreamIDMapping[upstreamID] })
            else {
                continue
            }
            sessionID = mapping.sessionID

            let planned = responsePlan(
                method: method,
                toolName: toolName,
                originalID: mapping.originalID
            )
            guard planned.deliverManually == false, planned.delayNanos == nil,
                let responseObject = try? JSONSerialization.jsonObject(
                    with: planned.data,
                    options: []
                )
            else {
                return
            }
            responseObjects.append(responseObject)
        }

        guard let sessionID,
            responseObjects.isEmpty == false,
            let responseData = try? JSONSerialization.data(
                withJSONObject: responseObjects,
                options: []
            )
        else {
            return
        }

        let session = self.session(id: sessionID)
        session.router.handleIncoming(responseData)
    }

    private func responsePlan(
        method: String,
        toolName: String?,
        originalID: RPCID
    ) -> UpstreamResponsePlan {
        if let upstreamRequestResponder,
            let planned = try? upstreamRequestResponder(method, toolName, originalID)
        {
            return planned
        }
        if let upstreamResponder,
            let planned = try? upstreamResponder(method, originalID)
        {
            return planned
        }
        if let legacyUpstreamResponder,
            let responseData = try? legacyUpstreamResponder(method, originalID)
        {
            return .immediate(responseData)
        }
        return .immediate(Data())
    }

    private func performSharedControlPlaneRequest(
        method: String,
        toolName: String?,
        sessionID: String
    ) async throws -> Data {
        _ = session(id: sessionID)
        guard let upstreamIndex = chooseUpstreamIndex() else {
            throw UpstreamSlotAcquisitionError.unavailable
        }
        state.withLockedValue { state in
            state.upstreamSendCount += 1
            state.sentRequests.append(
                SentRequest(
                    method: method,
                    toolName: toolName,
                    upstreamIndex: upstreamIndex
                )
            )
        }

        let originalID = RPCID(any: "__shared-\(method)-\(UUID().uuidString)")!
        let plan = responsePlan(
            method: method,
            toolName: toolName,
            originalID: originalID
        )
        if let delayNanos = plan.delayNanos {
            try await Task.sleep(nanoseconds: delayNanos)
        }
        guard plan.deliverManually == false else {
            throw ControlPlaneError.invalidResponse("timeout")
        }
        guard let object = try? JSONSerialization.jsonObject(
            with: plan.data,
            options: []
        ) as? [String: Any] else {
            throw ControlPlaneError.invalidResponse("invalid response")
        }
        if let errorObject = object["error"] as? [String: Any] {
            throw ControlPlaneError.upstreamRPC(
                code: (errorObject["code"] as? NSNumber)?.intValue ?? -32000,
                message: errorObject["message"] as? String ?? "upstream error"
            )
        }
        state.withLockedValue { state in
            state.requestSuccessNotifications += 1
        }
        return plan.data
    }

    func debugSnapshot() -> ProxyDebugSnapshot {
        debugSnapshot(includeSensitiveDebugPayloads: false)
    }

    func createRequestLease(descriptor: SessionPipelineRequestDescriptor) -> RequestLeaseID {
        requestLeaseRegistry.createLease(descriptor: descriptor)
    }

    func activateRequestLease(
        _ leaseID: RequestLeaseID,
        requestIDKey: String?,
        upstreamIndex: Int?,
        timeout: TimeAmount?
    ) {
        requestLeaseRegistry.activateLease(
            leaseID,
            requestIDKey: requestIDKey,
            upstreamIndex: upstreamIndex,
            timeoutAt: timeout.map {
                Date().addingTimeInterval(Double($0.nanoseconds) / 1_000_000_000)
            }
        )
    }

    func completeRequestLease(_ leaseID: RequestLeaseID) {
        _ = requestLeaseRegistry.completeLease(leaseID)
    }

    func requeueRequestLease(_ leaseID: RequestLeaseID) {
        state.withLockedValue { state in
            state.requeuedLeaseCount += 1
        }
        _ = requestLeaseRegistry.requeueLease(leaseID)
    }

    func failRequestLease(
        _ leaseID: RequestLeaseID,
        terminalState: RequestLeaseState,
        reason: RequestLeaseReleaseReason
    ) {
        _ = requestLeaseRegistry.failLease(
            leaseID,
            terminalState: terminalState,
            reason: reason
        )
    }

    func handleRequestLeaseTimeout(
        _ leaseID: RequestLeaseID,
        sessionID: String,
        requestIDKeys: [String],
        upstreamIndex: Int
    ) {
        _ = leaseID
        if let first = requestIDKeys.first {
            onRequestTimeout(
                sessionID: sessionID,
                requestIDKey: first,
                upstreamIndex: upstreamIndex
            )
            for requestIDKey in requestIDKeys.dropFirst() {
                removeUpstreamIDMapping(
                    sessionID: sessionID,
                    requestIDKey: requestIDKey,
                    upstreamIndex: upstreamIndex
                )
            }
        }
        _ = requestLeaseRegistry.timeoutLease(leaseID)
    }

    func abandonRequestLease(
        _ leaseID: RequestLeaseID,
        sessionID: String,
        requestIDKeys: [String],
        upstreamIndex: Int?
    ) {
        if let upstreamIndex {
            for requestIDKey in requestIDKeys {
                removeUpstreamIDMapping(
                    sessionID: sessionID,
                    requestIDKey: requestIDKey,
                    upstreamIndex: upstreamIndex
                )
            }
        }
        _ = requestLeaseRegistry.failLease(
            leaseID,
            terminalState: .abandoned,
            reason: .clientDisconnected
        )
    }

    func debugSnapshot(includeSensitiveDebugPayloads: Bool) -> ProxyDebugSnapshot {
        ProxyDebugSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            proxyInitialized: isInitialized(),
            cachedToolsListAvailable: cachedToolsListResult() != nil,
            warmupInFlight: false,
            controlPlane: nil,
            upstreams: [
                ProxyUpstreamDebugSnapshot(
                    upstreamIndex: 0,
                    isInitialized: isInitialized(),
                    initInFlight: false,
                    didSendInitialized: false,
                    healthState: "healthy",
                    consecutiveRequestTimeouts: 0,
                    consecutiveToolsListFailures: 0,
                    lastToolsListSuccessUptimeNs: nil,
                    recentStderr: [],
                    lastDecodeError: nil,
                    lastBridgeError: nil,
                    protocolViolationCount: 0,
                    lastProtocolViolationAt: nil,
                    lastProtocolViolationReason: nil,
                    lastProtocolViolationBufferedBytes: nil,
                    lastProtocolViolationPreview: includeSensitiveDebugPayloads ? "raw-preview" : nil,
                    lastProtocolViolationPreviewHex: includeSensitiveDebugPayloads ? "61 62" : nil,
                    lastProtocolViolationLeadingByteHex: includeSensitiveDebugPayloads ? "61" : nil,
                    bufferedStdoutBytes: 0
                )
            ],
            recentTraffic: [],
            sessions: [],
            leases: requestLeaseRegistry.debugSnapshots(),
            queuedRequestCount: 0
        )
    }

    func leaseDebugSnapshots() -> [RequestLeaseDebugSnapshot] {
        requestLeaseRegistry.debugSnapshots()
    }

    func sentUpstreamCount() -> Int {
        state.withLockedValue { $0.upstreamSendCount }
    }

    func sentUpstreamPayloads() -> [Data] {
        state.withLockedValue { $0.sentUpstreamPayloads }
    }

    func sentToolNames() -> [String] {
        state.withLockedValue { state in
            state.sentRequests.compactMap(\.toolName)
        }
    }

    func sentToolRequests() -> [String] {
        state.withLockedValue { state in
            state.sentRequests.compactMap { request in
                guard let toolName = request.toolName else { return nil }
                return "\(toolName)@\(request.upstreamIndex)"
            }
        }
    }

    func sentMethods() -> [String] {
        state.withLockedValue { state in
            state.sentRequests.map(\.method)
        }
    }

    func assignedUpstreamIDCount() -> Int {
        state.withLockedValue { $0.assignUpstreamIDCount }
    }

    func chooseUpstreamIndexCallCount() -> Int {
        state.withLockedValue { $0.chooseUpstreamCalls.count }
    }

    func lastChooseUpstreamShouldPin() -> Bool {
        false
    }

    func chooseUpstreamShouldPinValues() -> [Bool] {
        []
    }

    func refreshToolsListCallCount() -> Int {
        state.withLockedValue { $0.refreshToolsListCalls }
    }

    func mappedUpstreamRequestCount() -> Int {
        state.withLockedValue { $0.upstreamIDMapping.count }
    }

    func setAvailableUpstreamIndex(_ value: Int?) {
        state.withLockedValue { $0.availableUpstreamIndex = value }
    }

    func setAvailableUpstreamIndices(_ values: [Int?]) {
        state.withLockedValue { $0.availableUpstreamIndices = values }
    }

    func requestTimeoutNotificationCount() -> Int {
        state.withLockedValue { $0.requestTimeoutNotifications }
    }

    func requestSuccessNotificationCount() -> Int {
        state.withLockedValue { $0.requestSuccessNotifications }
    }

    func requeuedLeaseCount() -> Int {
        state.withLockedValue { $0.requeuedLeaseCount }
    }

    func pendingResponseCount() -> Int {
        state.withLockedValue { $0.pendingResponses.count }
    }

    func setInitialized(_ value: Bool) {
        state.withLockedValue { $0.initialized = value }
    }

    func deliverNextPendingResponse() {
        let pending = state.withLockedValue { state -> State.PendingResponse? in
            guard state.pendingResponses.isEmpty == false else { return nil }
            return state.pendingResponses.removeFirst()
        }
        guard let pending else { return }
        let session = session(id: pending.sessionID)
        session.router.handleIncoming(pending.data)
    }
}

func makeConfig(
    maxBodyBytes: Int = 1024,
    requestTimeout: TimeInterval = 1
) -> ProxyConfig {
    ProxyConfig(
        listenHost: "127.0.0.1",
        listenPort: 0,
        upstreamCommand: "xcrun",
        upstreamArgs: ["mcpbridge"],
        upstreamSessionID: nil,
        maxBodyBytes: maxBodyBytes,
        requestTimeout: requestTimeout
    )
}

func makeHTTPTemporaryWorkspaceRoot() -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

func waitForHTTPTestSemaphore(
    _ semaphore: DispatchSemaphore,
    timeoutSeconds: TimeInterval
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let timeoutMilliseconds = Int((timeoutSeconds * 1000).rounded(.up))
            continuation.resume(
                returning: semaphore.wait(
                    timeout: .now() + .milliseconds(timeoutMilliseconds)
                )
            )
        }
    }
}

func addHTTPHandler(
    to channel: EmbeddedChannel,
    config: ProxyConfig,
    sessionManager: any RuntimeCoordinating,
    refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator? = nil,
    refreshCodeIssuesTargetResolver: RefreshCodeIssuesTargetResolver = RefreshCodeIssuesTargetResolver(),
    refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState? = nil
) throws {
    let handler = HTTPHandler(
        config: config,
        sessionManager: sessionManager,
        refreshCodeIssuesCoordinator: refreshCodeIssuesCoordinator,
        refreshCodeIssuesTargetResolver: refreshCodeIssuesTargetResolver,
        refreshCodeIssuesDebugState: refreshCodeIssuesDebugState,
        usesSynchronousLocalResolution: true
    )
    try channel.pipeline.addHandler(handler).wait()
}

func collectResponse(from channel: EmbeddedChannel) throws -> (
    head: HTTPResponseHead, body: String
) {
    var responseHead: HTTPResponseHead?
    var bodyBuffer = channel.allocator.buffer(capacity: 0)

    while let part = try channel.readOutbound(as: HTTPServerResponsePart.self) {
        switch part {
        case .head(let head):
            responseHead = head
        case .body(let body):
            switch body {
            case .byteBuffer(var buffer):
                bodyBuffer.writeBuffer(&buffer)
            case .fileRegion:
                break
            }
        case .end:
            break
        }
    }

    guard let responseHead else {
        throw HTTPTestError.missingResponseHead
    }
    let body = bodyBuffer.readString(length: bodyBuffer.readableBytes) ?? ""
    return (responseHead, body)
}

func advanceEventLoopTime(on channel: EmbeddedChannel, by amount: TimeAmount) {
    channel.embeddedEventLoop.advanceTime(by: amount)
}

func toolsCallPayload(
    id: Int,
    name: String,
    arguments: [String: Any]
) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": [
            "name": name,
            "arguments": arguments,
        ],
    ]
}

func postJSON(
    _ payload: [String: Any],
    sessionID: String,
    to channel: EmbeddedChannel
) throws {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json, text/event-stream")
    head.headers.add(name: "Content-Type", value: "application/json")
    head.headers.add(name: "Mcp-Session-Id", value: sessionID)
    head.headers.add(name: "MCP-Protocol-Version", value: MCPProtocolVersion.current)
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))
}

func postJSONArray(
    _ payload: [Any],
    sessionID: String?,
    to channel: EmbeddedChannel
) throws {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    head.headers.add(name: "Accept", value: "application/json, text/event-stream")
    head.headers.add(name: "Content-Type", value: "application/json")
    if let sessionID {
        head.headers.add(name: "Mcp-Session-Id", value: sessionID)
        head.headers.add(name: "MCP-Protocol-Version", value: MCPProtocolVersion.current)
    }
    var body = channel.allocator.buffer(capacity: data.count)
    body.writeBytes(data)
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))
}

func assertBatchRejected(_ response: (head: HTTPResponseHead, body: String)) {
    #expect(response.head.status == .badRequest)
    #expect(response.head.headers.first(name: "Content-Type") == "text/plain; charset=utf-8")
    #expect(response.body == "JSON-RPC batching is not supported")
}

struct TestHTTPHandlerServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let url: URL
    let sessionManager: any RuntimeCoordinating
    let childChannelTracker: HTTPTestServerChannelTracker

    static func start(
        config: ProxyConfig,
        sessionManager: any RuntimeCoordinating,
        refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator? = nil,
        refreshCodeIssuesTargetResolver: RefreshCodeIssuesTargetResolver = RefreshCodeIssuesTargetResolver()
    ) throws -> TestHTTPHandlerServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let childChannelTracker = HTTPTestServerChannelTracker()
        let refreshCoordinator =
            refreshCodeIssuesCoordinator
            ?? RefreshCodeIssuesCoordinator.makeDefault()
        let refreshDebugState = RefreshCodeIssuesDebugState(
            defaultRequestTimeoutSeconds: config.requestTimeout
        )
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            config: config,
                            sessionManager: sessionManager,
                            refreshCodeIssuesCoordinator: refreshCoordinator,
                            refreshCodeIssuesTargetResolver: refreshCodeIssuesTargetResolver,
                            refreshCodeIssuesDebugState: refreshDebugState
                        )
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: config.listenHost, port: 0).wait()
        try channel.pipeline.addHandler(
            HTTPTestServerAcceptedChannelHandler(tracker: childChannelTracker)
        ).wait()
        let port = channel.localAddress?.port ?? 0
        let url = URL(string: "http://\(config.listenHost):\(port)/mcp")!
        registerHTTPTestServer(url: url, sessionManager: sessionManager)
        return TestHTTPHandlerServer(
            group: group,
            channel: channel,
            url: url,
            sessionManager: sessionManager,
            childChannelTracker: childChannelTracker
        )
    }

    func shutdown() async throws {
        unregisterHTTPTestServer(url: url)
        try await shutdownHTTPTestServer(
            listenChannel: channel,
            childChannelTracker: childChannelTracker,
            group: group,
            beforeClose: {
                await sessionManager.shutdown()
            }
        )
    }
}

struct RawHTTPResponse: Sendable {
    let statusCode: Int
    let bodyData: Data
}

func postHTTPJSON(
    url: URL,
    sessionID: String,
    payload: [String: Any],
    prepareSession: Bool = true
) async throws -> (HTTPURLResponse, [String: Any]) {
    if prepareSession {
        prepareHTTPTestSession(url: url, sessionID: sessionID)
    }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    request.setValue(MCPProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")

    return try await withTestURLSession { session in
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPTestError.missingResponseHead
        }
        let object =
            (try? JSONSerialization.jsonObject(with: responseData, options: [])) as? [String: Any]
            ?? [:]
        return (httpResponse, object)
    }
}

func postHTTPAnyJSON(
    url: URL,
    sessionID: String,
    payload: [Any],
    prepareSession: Bool = true
) async throws -> (HTTPURLResponse, Any) {
    if prepareSession {
        prepareHTTPTestSession(url: url, sessionID: sessionID)
    }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    request.setValue(MCPProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")

    return try await withTestURLSession { session in
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPTestError.missingResponseHead
        }
        let object = try JSONSerialization.jsonObject(with: responseData, options: [])
        return (httpResponse, object)
    }
}

func postHTTPAnyData(
    url: URL,
    sessionID: String,
    payload: [Any],
    prepareSession: Bool = true
) async throws -> RawHTTPResponse {
    if prepareSession {
        prepareHTTPTestSession(url: url, sessionID: sessionID)
    }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    request.setValue(MCPProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")

    return try await withTestURLSession { session in
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPTestError.missingResponseHead
        }
        return RawHTTPResponse(statusCode: httpResponse.statusCode, bodyData: responseData)
    }
}

func assertHTTPBatchRejected(
    url: URL,
    sessionID: String,
    payload: [Any],
    prepareSession: Bool = true
) async throws -> RawHTTPResponse {
    let response = try await postHTTPAnyData(
        url: url,
        sessionID: sessionID,
        payload: payload,
        prepareSession: prepareSession
    )
    #expect(response.statusCode == 400)
    #expect(String(data: response.bodyData, encoding: .utf8) == "JSON-RPC batching is not supported")
    return response
}

func postHTTPData(
    url: URL,
    sessionID: String,
    payload: [String: Any],
    prepareSession: Bool = true
) async throws -> RawHTTPResponse {
    if prepareSession {
        prepareHTTPTestSession(url: url, sessionID: sessionID)
    }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    request.setValue(MCPProtocolVersion.current, forHTTPHeaderField: "MCP-Protocol-Version")

    return try await withTestURLSession { session in
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPTestError.missingResponseHead
        }
        return RawHTTPResponse(statusCode: httpResponse.statusCode, bodyData: responseData)
    }
}

func getHTTPData(url: URL) async throws -> (HTTPURLResponse, Data) {
    try await withTestURLSession { session in
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPTestError.missingResponseHead
        }
        return (httpResponse, data)
    }
}

func makeDebugSnapshotURL(from mcpURL: URL, includeSensitive: Bool = false) -> URL {
    var components = URLComponents(url: mcpURL, resolvingAgainstBaseURL: false)!
    components.path = "/debug/upstreams"
    components.queryItems = includeSensitive
        ? [URLQueryItem(name: "includeSensitive", value: "1")]
        : nil
    return components.url!
}

typealias AsyncSignal = TestSignal
typealias SyncSignal = TestSignal

func initializeHTTPChannel(_ channel: EmbeddedChannel) throws -> String {
    let initPayload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "capabilities": [String: Any]()
        ],
    ]
    let initData = try JSONSerialization.data(withJSONObject: initPayload, options: [])
    var initHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    initHead.headers.add(name: "Accept", value: "application/json, text/event-stream")
    initHead.headers.add(name: "Content-Type", value: "application/json")
    var initBody = channel.allocator.buffer(capacity: initData.count)
    initBody.writeBytes(initData)
    try channel.writeInbound(HTTPServerRequestPart.head(initHead))
    try channel.writeInbound(HTTPServerRequestPart.body(initBody))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    let initResponse = try collectResponse(from: channel)
    return try #require(initResponse.head.headers.first(name: "Mcp-Session-Id"))
}

func makeToolSuccessResponse(id: RPCID, text: String) throws -> Data {
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id.value.foundationObject,
        "result": [
            "content": [
                [
                    "type": "text",
                    "text": text,
                ]
            ]
        ],
    ]
    return try JSONSerialization.data(withJSONObject: response, options: [])
}

func makeToolResultResponse(id: RPCID, result: [String: Any]) throws -> Data {
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id.value.foundationObject,
        "result": result,
    ]
    return try JSONSerialization.data(withJSONObject: response, options: [])
}

func makeToolErrorResponse(id: RPCID, text: String) throws -> Data {
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id.value.foundationObject,
        "result": [
            "content": [
                [
                    "type": "text",
                    "text": text,
                ]
            ],
            "isError": true,
        ],
    ]
    return try JSONSerialization.data(withJSONObject: response, options: [])
}
