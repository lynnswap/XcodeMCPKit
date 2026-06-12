import Foundation
import NIO
import ProxyCore
import ProxyMCP

extension RuntimeCoordinator {
    func startEagerInitializePrimary(applyBackoff: Bool = false) {
        runWhenUpstreamReady(
            reason: "primary_initialize",
            applyBackoff: applyBackoff
        ) { [weak self] in
            guard let self else { return }
            self.startPrimaryUpstreamSlot()
            self.startEagerInitializePrimaryWhenReady()
        }
    }

    private func startEagerInitializePrimaryWhenReady() {
        let decision = initializeManager.beginEagerInitializePrimary()
        let shouldSend = decision.shouldSendRequest
        let shouldScheduleTimeout = decision.shouldScheduleTimeout
        if shouldScheduleTimeout {
            scheduleInitTimeout()
        }
        guard shouldSend else { return }

        sendPrimaryInitializeRequestIfStillPending()
    }

    func startPrimaryInitializeRequestWhenReady(applyBackoff: Bool = false) {
        let token = upstreamReadinessGate.isEnabled ? UpstreamReadinessWaiterToken() : nil
        if let token {
            replacePrimaryInitializeReadinessWaiter(with: token)
        }
        runWhenUpstreamReady(
            reason: "primary_initialize_request",
            applyBackoff: applyBackoff,
            token: token
        ) { [weak self, token] in
            guard let self else { return }
            if let token {
                self.clearPrimaryInitializeReadinessWaiter(token)
                guard !token.isCancelled else { return }
            }
            self.startPrimaryUpstreamSlot()
            self.sendPrimaryInitializeRequestIfStillPending()
        }
    }

    private func sendPrimaryInitializeRequestIfStillPending() {
        let upstreamID = upstreamRouter.assignInitialize(upstreamIndex: 0)
        guard initializeManager.beginPrimaryInitializeSend(upstreamID: upstreamID) else {
            upstreamRouter.remove(upstreamIndex: 0, upstreamID: upstreamID)
            return
        }
        markUpstreamInitInFlight(upstreamIndex: 0, upstreamID: upstreamID)

        let request = makeInternalInitializeRequest(id: upstreamID)
        if let data = try? JSONSerialization.data(withJSONObject: request, options: []) {
            sendUpstream(data, upstreamIndex: 0, ensureRunning: true)
        } else {
            failInitPending(error: TimeoutError())
        }
    }

    func handleInitializeResponse(_ object: [String: Any], upstreamIndex: Int) {
        guard let resultValue = object["result"], let result = JSONValue(any: resultValue) else {
            if upstreamIndex == 0 {
                if let errorObject = object["error"] as? [String: Any], !errorObject.isEmpty {
                    completeInitPendingWithError(errorObject)
                } else {
                    failInitPending(error: TimeoutError())
                }
            } else {
                clearUpstreamState(upstreamIndex: upstreamIndex)
                failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
            }
            return
        }

        if upstreamIndex != 0 {
            if let canonicalInitialize = canonicalBrokerState.initializeResult(),
                !initializeResultsEquivalent(canonicalInitialize, result)
            {
                noteIncompatibleUpstream(
                    upstreamIndex: upstreamIndex,
                    kind: "initialize",
                    reason: "initialize.result mismatch"
                )
                failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
                return
            }
            sendInitializedNotificationIfNeeded(upstreamIndex: upstreamIndex) { [weak self] in
                self?.markUpstreamInitialized(upstreamIndex: upstreamIndex)
                self?.upstreamSlotScheduler.wake()
            } onRejected: { [weak self] in
                self?.handleInitializedNotificationSendOverload(upstreamIndex: upstreamIndex)
            }
            return
        }

        let update = initializeManager.preparePrimaryInitializeSuccess()
        guard let update else { return }
        update.timeout?.cancel()

        sendInitializedNotificationIfNeeded(upstreamIndex: upstreamIndex) { [weak self] in
            guard let self else { return }
            self.initializeManager.storeInitializeResultIfNeeded(result)
            self.canonicalBrokerState.syncCanonicalInitialize(
                result,
                sourceUpstream: upstreamIndex
            )
            guard let pending = self.initializeManager.finishPrimaryInitializeSuccess() else { return }
            self.markUpstreamInitialized(upstreamIndex: upstreamIndex)
            self.upstreamSlotScheduler.wake()
            if update.shouldWarmSecondary {
                self.initializeManager.markSecondaryWarmupStarted()
                self.warmUpSecondaryUpstreams()
            }
            self.refreshToolsListIfNeeded()
            self.completePendingInitializes(pending, result: result)
        } onRejected: { [weak self] in
            guard let self else { return }
            if upstreamIndex == 0,
                self.hasUsableInitializedSecondaryUpstreams(),
                let completion = self.initializeManager.finishPrimaryInitializeUsingCachedResult()
            {
                self.completePendingInitializes(completion.pending, result: completion.result)
                self.eventLoop.execute { [weak self] in
                    self?.handleInitializedNotificationSendOverload(upstreamIndex: upstreamIndex)
                }
                return
            }
            self.initializeManager.reopenPrimaryInitializeForRetry()
            self.handleInitializedNotificationSendOverload(upstreamIndex: upstreamIndex)
        }
    }

    func completePendingInitializes(
        _ pending: [InitializeManager.PendingInitialize],
        result: JSONValue
    ) {
        for item in pending {
            sessionRegistry.markInitialized(id: item.sessionID)
            if let buffer = encodeInitializeResponse(
                originalID: item.originalID,
                result: result
            ) {
                item.eventLoop.execute {
                    item.promise.succeed(buffer)
                }
            } else {
                item.eventLoop.execute {
                    item.promise.fail(TimeoutError())
                }
            }
        }
    }

    func encodeInitializeResponse(originalID: RPCID, result: JSONValue) -> ByteBuffer? {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalID.value.foundationObject,
            "result": result.foundationObject,
        ]
        guard JSONSerialization.isValidJSONObject(response),
            let data = try? JSONSerialization.data(withJSONObject: response, options: [])
        else {
            return nil
        }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    func encodeInitializeErrorResponse(originalID: RPCID, errorObject: [String: Any])
        -> ByteBuffer?
    {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalID.value.foundationObject,
            "error": errorObject,
        ]
        guard JSONSerialization.isValidJSONObject(response),
            let data = try? JSONSerialization.data(withJSONObject: response, options: [])
        else {
            return nil
        }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    func completeInitPendingWithError(_ errorObject: [String: Any]) {
        let result = initializeManager.completePrimaryInitializeFailure()
        guard let result else { return }
        cancelPrimaryInitializeReadinessWaiter()
        result.timeout?.cancel()
        if let upstreamID = result.upstreamID {
            upstreamRouter.remove(upstreamIndex: 0, upstreamID: upstreamID)
        }
        clearUpstreamInitInFlight(upstreamIndex: 0)
        for item in result.pending {
            if let buffer = encodeInitializeErrorResponse(
                originalID: item.originalID, errorObject: errorObject)
            {
                item.eventLoop.execute {
                    item.promise.succeed(buffer)
                }
            } else {
                item.eventLoop.execute {
                    item.promise.fail(TimeoutError())
                }
            }
        }

        if result.shouldRetryEagerInitialize {
            startEagerInitializePrimary(applyBackoff: true)
        }
        failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
    }

    func sendInitializedNotificationIfNeeded(
        upstreamIndex: Int,
        onAccepted: @escaping @Sendable () -> Void = {},
        onRejected: @escaping @Sendable () -> Void = {}
    ) {
        let shouldSend = upstreamHealthManager.shouldSendInitializedNotification(
            upstreamIndex: upstreamIndex
        )
        guard shouldSend else {
            onAccepted()
            return
        }

        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: notification, options: []) else {
            onAccepted()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let result = await self.upstreams[upstreamIndex].send(data)
            if result == .accepted {
                self.upstreamHealthManager.markInitializedNotificationSent(upstreamIndex: upstreamIndex)
                self.recordTraffic(
                    upstreamIndex: upstreamIndex,
                    direction: "outbound",
                    data: data
                )
                onAccepted()
                return
            }
            onRejected()
        }
    }

    func handleInitializedNotificationSendOverload(upstreamIndex: Int) {
        clearUpstreamState(upstreamIndex: upstreamIndex)
        let hasHealthySecondary = upstreamIndex == 0 && hasUsableInitializedSecondaryUpstreams()
        if canonicalBrokerState.toolsSourceUpstream() == upstreamIndex && !hasHealthySecondary {
            invalidateControlPlane(
                reason: "initialized_notification_overload_\(upstreamIndex)",
                clearInitialize: false,
                clearToolsCatalog: true
            )
        }
        if upstreamIndex == 0 {
            if hasUsableInitializedSecondaryUpstreams() {
                initializeManager.setShouldRetryEagerInitializePrimaryAfterWarmInitFailure(true)
                startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
            } else {
                resetSecondaryUpstreamsForPrimaryRetry()
                startPrimaryEagerRetry()
            }
        } else {
            startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
        }
        failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
    }

    func scheduleInitTimeout() {
        guard
            let timeoutAmount = MCPMethodDispatcher.timeoutForInitialize(
                defaultSeconds: config.requestTimeout)
        else {
            return
        }
        let timeout = scheduleRuntimeTimeout(timeoutAmount) { [weak self] in
            guard let self else { return }
            self.failInitPending(error: TimeoutError())
        }
        let previous = initializeManager.replaceInitTimeout(timeout)
        previous?.cancel()
    }

    func failInitPending(error: Error) {
        let result = initializeManager.completePrimaryInitializeFailure()
        guard let result else { return }
        cancelPrimaryInitializeReadinessWaiter()
        result.timeout?.cancel()
        if let upstreamID = result.upstreamID {
            upstreamRouter.remove(upstreamIndex: 0, upstreamID: upstreamID)
        }
        clearUpstreamInitInFlight(upstreamIndex: 0)
        for item in result.pending {
            item.eventLoop.execute {
                item.promise.fail(error)
            }
        }

        if result.shouldRetryEagerInitialize {
            startEagerInitializePrimary(applyBackoff: true)
        }
        failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
    }

    func markUpstreamInitInFlight(upstreamIndex: Int, upstreamID: Int64) {
        upstreamHealthManager.markInitInFlight(upstreamIndex: upstreamIndex, upstreamID: upstreamID)
    }

    func clearUpstreamInitInFlight(upstreamIndex: Int) {
        upstreamHealthManager.clearInitInFlight(upstreamIndex: upstreamIndex)
    }

    func clearUpstreamState(upstreamIndex: Int) {
        guard let cleared = upstreamHealthManager.clearUpstreamState(upstreamIndex: upstreamIndex) else {
            return
        }
        cleared.timeout?.cancel()
        if let initUpstreamID = cleared.initUpstreamID {
            upstreamRouter.remove(
                upstreamIndex: upstreamIndex,
                upstreamID: initUpstreamID
            )
        }
        debugRecorder.resetUpstream(upstreamIndex)
    }

    func markUpstreamInitialized(upstreamIndex: Int) {
        let timeout = upstreamHealthManager.markInitialized(upstreamIndex: upstreamIndex)
        timeout?.cancel()
        noteUpstreamInitializationSucceeded()
    }

    func warmUpSecondaryUpstreams() {
        guard upstreams.count > 1 else { return }
        for upstreamIndex in 1..<upstreams.count {
            startUpstreamWarmInitialize(upstreamIndex: upstreamIndex)
        }
    }

    func resetSecondaryUpstreamsForPrimaryRetry() {
        guard upstreams.count > 1 else { return }
        for upstreamIndex in 1..<upstreams.count {
            clearUpstreamState(upstreamIndex: upstreamIndex)
        }
    }

    func startPrimaryEagerRetry() {
        clearUpstreamState(upstreamIndex: 0)
        initializeManager.resetCachedInitializeResult()
        invalidateControlPlane(
            reason: "primary_eager_retry",
            clearInitialize: true,
            clearToolsCatalog: true
        )
        startEagerInitializePrimary(applyBackoff: true)
    }

    func hasUsableInitializedSecondaryUpstreams() -> Bool {
        upstreamHealthManager.statesSnapshot().dropFirst().contains { upstream in
            guard upstream.isInitialized else { return false }
            switch upstream.healthState {
            case .healthy, .degraded:
                return true
            case .quarantined:
                return false
            }
        }
    }
    func makeInternalInitializeRequest(id: Int64) -> [String: Any] {
        let mergedParams = resolvedInitializeParams().mapValues(\.foundationObject)

        return [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": mergedParams,
        ]
    }

    func resolvedInitializeParams() -> [String: JSONValue] {
        Self.resolvedInitializeParams(initializeParamsOverride: initializeParamsOverride)
    }

    package static func resolvedInitializeParams(config: ProxyConfig) -> [String: JSONValue] {
        let override = ProxyFileConfigLoader.loadInitializeParamsOverride(
            configPath: config.configPath,
            logger: ProxyLogging.make("config")
        )
        return resolvedInitializeParams(initializeParamsOverride: override)
    }

    package static func resolvedInitializeParams(
        initializeParamsOverride: [String: JSONValue]?
    ) -> [String: JSONValue] {
        let mergedParams = ProxyFileConfigLoader.mergeJSONObjects(
            defaultInitializeParams(),
            overriding: initializeParamsOverride ?? [:]
        )
        guard hasExplicitClientVersionOverride(initializeParamsOverride: initializeParamsOverride) == false else {
            return mergedParams
        }
        return applyingAutomaticClientVersion(to: mergedParams)
    }

    func defaultInitializeParams() -> [String: JSONValue] {
        Self.defaultInitializeParams()
    }

    package static func defaultInitializeParams() -> [String: JSONValue] {
        [
            "protocolVersion": .string("2025-03-26"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(defaultProxyClientName()),
                "version": .string(defaultProxyClientVersion()),
            ]),
        ]
    }

    func hasExplicitClientVersionOverride() -> Bool {
        Self.hasExplicitClientVersionOverride(initializeParamsOverride: initializeParamsOverride)
    }

    package static func hasExplicitClientVersionOverride(
        initializeParamsOverride: [String: JSONValue]?
    ) -> Bool {
        guard case .object(let clientInfo)? = initializeParamsOverride?["clientInfo"] else {
            return false
        }
        return clientInfo["version"] != nil
    }

    func applyingAutomaticClientVersion(to params: [String: JSONValue]) -> [String: JSONValue] {
        Self.applyingAutomaticClientVersion(to: params)
    }

    package static func applyingAutomaticClientVersion(to params: [String: JSONValue]) -> [String: JSONValue] {
        guard case .object(var clientInfo)? = params["clientInfo"],
              case .string(let clientName)? = clientInfo["name"] else {
            return params
        }

        guard let resolvedVersion = xcodeChatClientVersion(for: clientName) else {
            return params
        }

        clientInfo["version"] = .string(resolvedVersion)
        var updated = params
        updated["clientInfo"] = .object(clientInfo)
        return updated
    }

    func defaultClientVersion(for clientName: String) -> String {
        Self.defaultClientVersion(for: clientName)
    }

    package static func defaultClientVersion(for clientName: String) -> String {
        xcodeChatClientVersion(for: clientName) ?? defaultProxyClientVersion()
    }

    func defaultProxyClientName() -> String {
        Self.defaultProxyClientName()
    }

    package static func defaultProxyClientName() -> String {
        "XcodeMCPKit"
    }

    func defaultProxyClientVersion() -> String {
        Self.defaultProxyClientVersion()
    }

    package static func defaultProxyClientVersion() -> String {
        "dev"
    }

    func xcodeChatClientVersion(for clientName: String) -> String? {
        Self.xcodeChatClientVersion(for: clientName)
    }

    package static func xcodeChatClientVersion(for clientName: String) -> String? {
        let defaults = UserDefaults(suiteName: "com.apple.dt.Xcode")?.dictionaryRepresentation() ?? [:]
        return xcodeChatClientVersion(for: clientName, defaults: defaults)
    }

    func xcodeChatClientVersion(for clientName: String, defaults: [String: Any]) -> String? {
        Self.xcodeChatClientVersion(for: clientName, defaults: defaults)
    }

    package static func xcodeChatClientVersion(for clientName: String, defaults: [String: Any]) -> String? {
        let normalizedName = normalizedChatClientName(clientName)
        guard !normalizedName.isEmpty else { return nil }

        var exactMatches: [(stem: String, version: String)] = []
        var aliasMatches: [(stem: String, version: String)] = []

        for (key, value) in defaults {
            guard key.hasPrefix("IDEChat"), key.hasSuffix("Version") else { continue }
            guard let raw = value as? String, let version = xcodeChatVersionValue(from: raw) else {
                continue
            }

            let stem = String(
                key
                    .dropFirst("IDEChat".count)
                    .dropLast("Version".count)
            )

            let normalizedStem = normalizedChatClientName(stem)
            if normalizedStem == normalizedName {
                exactMatches.append((stem, version))
                continue
            }

            if chatClientAliases(forVersionStem: stem).contains(normalizedName) {
                aliasMatches.append((stem, version))
            }
        }

        let orderedExactMatches = exactMatches.sorted { lhs, rhs in
            lhs.stem.localizedStandardCompare(rhs.stem) == .orderedAscending
        }
        if let match = orderedExactMatches.first {
            return match.version
        }

        let orderedAliasMatches = aliasMatches.sorted { lhs, rhs in
            lhs.stem.localizedStandardCompare(rhs.stem) == .orderedAscending
        }
        return orderedAliasMatches.first?.version
    }

    func xcodeChatVersionValue(forDefaultsKey defaultsKey: String) -> String? {
        Self.xcodeChatVersionValue(forDefaultsKey: defaultsKey)
    }

    package static func xcodeChatVersionValue(forDefaultsKey defaultsKey: String) -> String? {
        guard let raw = UserDefaults(suiteName: "com.apple.dt.Xcode")?.string(forKey: defaultsKey) else {
            return nil
        }
        return xcodeChatVersionValue(from: raw)
    }

    func xcodeChatVersionValue(from raw: String) -> String? {
        Self.xcodeChatVersionValue(from: raw)
    }

    package static func xcodeChatVersionValue(from raw: String) -> String? {
        guard
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let version = object["version"] as? String,
            !version.isEmpty
        else {
            return nil
        }
        return version
    }

    func chatClientAliases(forVersionStem stem: String) -> Set<String> {
        Self.chatClientAliases(forVersionStem: stem)
    }

    package static func chatClientAliases(forVersionStem stem: String) -> Set<String> {
        var aliases: Set<String> = []
        let normalizedStem = normalizedChatClientName(stem)
        if !normalizedStem.isEmpty {
            aliases.insert(normalizedStem)
        }

        if stem.hasSuffix("Code") {
            let baseStem = String(stem.dropLast("Code".count))
            let normalizedBaseStem = normalizedChatClientName(baseStem)
            if !normalizedBaseStem.isEmpty {
                aliases.insert(normalizedBaseStem)
            }
        }

        return aliases
    }

    func normalizedChatClientName(_ name: String) -> String {
        Self.normalizedChatClientName(name)
    }

    package static func normalizedChatClientName(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter(CharacterSet.alphanumerics.contains)
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }
}
