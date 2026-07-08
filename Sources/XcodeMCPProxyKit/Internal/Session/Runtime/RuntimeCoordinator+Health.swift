import Foundation
import NIO
import NIOFoundationCompat
import XcodeMCPKit

extension RuntimeCoordinator {
    enum WarmInitializeMode: Sendable, Equatable {
        case regular
        case processRouteActivation(processID: pid_t)
    }

    func markRequestSucceeded(upstreamIndex: Int) {
        upstreamHealthManager.markRequestSucceeded(upstreamIndex: upstreamIndex)
    }

    func markUpstreamOverloaded(upstreamIndex: Int) {
        _ = upstreamHealthManager.markUpstreamOverloaded(upstreamIndex: upstreamIndex)
    }

    func markRequestTimedOut(upstreamIndex: Int) {
        let nowUptimeNs = nowUptimeNanoseconds()
        let result = upstreamHealthManager.markRequestTimedOut(
            upstreamIndex: upstreamIndex,
            nowUptimeNs: nowUptimeNs
        )
        let timeoutCount = result.timeoutCount

        if result.shouldClearPins {
            logger.warning(
                "Upstream quarantined after repeated request timeouts",
                metadata: [
                    "upstream": .string("\(upstreamIndex)"),
                    "timeout_count": .string("\(timeoutCount)"),
                ]
            )
            failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
        }
    }

    func probeUpstreamHealth(upstreamIndex: Int, probeGeneration: UInt64) {
        let internalSessionID = controlPlaneSessionID(for: "health_probe", route: nil)
        _ = session(id: internalSessionID)
        let probeSession = session(id: internalSessionID)
        let probeTimeout: TimeAmount = .seconds(2)
        let originalID = JSONRPC.ID(any: "__probe-\(upstreamIndex)-\(UUID().uuidString)")!
        let registration = probeSession.router.registerRequestPending(
            idKey: originalID.key,
            on: eventLoop,
            timeout: probeTimeout
        )
        let upstreamID = assignUpstreamID(
            sessionID: internalSessionID,
            originalID: originalID,
            upstreamIndex: upstreamIndex
        )

        let request = JSONRPC.Wire.requestObject(id: upstreamID, method: "tools/list")
        guard let requestData = try? JSONRPC.Wire.data(from: request) else {
            finishHealthProbe(
                upstreamIndex: upstreamIndex,
                probeGeneration: probeGeneration,
                success: false,
                reason: "encode_request_failed"
            )
            return
        }

        sendUpstream(requestData, upstreamIndex: upstreamIndex)

        addRuntimeTask { [weak self, probeSession, registration] in
            guard let self else { return }
            do {
                var buffer = try await withTaskCancellationHandler {
                    try await registration.future.get()
                } onCancel: {
                    _ = probeSession.router.cancelPending(token: registration.token)
                    self.upstreamRouter.remove(upstreamIndex: upstreamIndex, upstreamID: upstreamID)
                }
                guard let responseData = buffer.readData(length: buffer.readableBytes),
                    let object = try JSONSerialization.jsonObject(with: responseData, options: [])
                        as? [String: Any],
                    object["error"] == nil,
                    object["result"] != nil
                else {
                    self.upstreamRouter.remove(upstreamIndex: upstreamIndex, upstreamID: upstreamID)
                    self.finishHealthProbe(
                        upstreamIndex: upstreamIndex,
                        probeGeneration: probeGeneration,
                        success: false,
                        reason: "invalid_response"
                    )
                    return
                }
                self.finishHealthProbe(
                    upstreamIndex: upstreamIndex,
                    probeGeneration: probeGeneration,
                    success: true,
                    reason: "ok"
                )
            } catch {
                if error is CancellationError {
                    self.upstreamRouter.remove(upstreamIndex: upstreamIndex, upstreamID: upstreamID)
                    return
                }
                self.upstreamRouter.remove(upstreamIndex: upstreamIndex, upstreamID: upstreamID)
                self.finishHealthProbe(
                    upstreamIndex: upstreamIndex,
                    probeGeneration: probeGeneration,
                    success: false,
                    reason: "timeout"
                )
            }
        }
    }

    func finishHealthProbe(
        upstreamIndex: Int,
        probeGeneration: UInt64,
        success: Bool,
        reason: String
    ) {
        let nowUptimeNs = nowUptimeNanoseconds()
        upstreamHealthManager.finishHealthProbe(
            upstreamIndex: upstreamIndex,
            probeGeneration: probeGeneration,
            success: success,
            nowUptimeNs: nowUptimeNs
        )
        if success {
            upstreamSlotScheduler.wake()
            refreshPendingProcessToolsCatalogForReadyUpstream(
                upstreamIndex: upstreamIndex,
                reason: "health_probe_\(upstreamIndex)"
            )
        } else {
            failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
        }
        logger.debug(
            "Upstream health probe completed",
            metadata: [
                "upstream": .string("\(upstreamIndex)"),
                "success": .string(success ? "true" : "false"),
                "reason": .string(reason),
            ]
        )
    }

    func markToolsListRefreshSucceeded(upstreamIndex: Int, nowUptimeNs: UInt64) {
        upstreamHealthManager.markToolsListRefreshSucceeded(upstreamIndex: upstreamIndex, nowUptimeNs: nowUptimeNs)
        testHooks.toolsListRefreshCompleted?(upstreamIndex, true)
    }

    func markToolsListRefreshFailed(upstreamIndex: Int, nowUptimeNs: UInt64, reason: String)
    {
        guard let result = upstreamHealthManager.markToolsListRefreshFailed(
            upstreamIndex: upstreamIndex,
            nowUptimeNs: nowUptimeNs
        ) else { return }
        let failures = result.failures
        let quarantineUntil = result.quarantineUntil

        logger.debug(
            "tools/list warmup failed (best-effort)",
            metadata: [
                "upstream": .string("\(upstreamIndex)"),
                "reason": .string(reason),
                "failures": .string("\(failures)"),
                "quarantine_until_uptime_ns": .string("\(quarantineUntil)"),
                "uptime_ns": .string("\(nowUptimeNs)"),
            ]
        )
        testHooks.toolsListRefreshCompleted?(upstreamIndex, false)
    }

    func isValidToolsListResult(_ value: JSONValue) -> Bool {
        guard case .object(let object) = value else { return false }
        guard let toolsValue = object["tools"] else { return false }
        if case .array = toolsValue {
            return true
        }
        return false
    }

    func recoveryAwareUsableInitializedUpstreamIndices(in route: XcodeProcessRoute) -> [Int] {
        processRouteExposure(policy: .toolsCatalog)
            .routes
            .first { $0.route.id == route.id }?
            .usableUpstreamIndices ?? []
    }

    func startUpstreamWarmInitialize(
        upstreamIndex: Int,
        applyBackoff: Bool = false,
        mode: WarmInitializeMode = .regular
    ) {
        guard isActiveProcessBoundUpstream(upstreamIndex) else { return }
        runWhenUpstreamReady(
            reason: "warm_initialize_\(upstreamIndex)",
            applyBackoff: applyBackoff
        ) { [weak self, mode] in
            self?.startUpstreamWarmInitializeWhenReady(
                upstreamIndex: upstreamIndex,
                mode: mode
            )
        }
    }

    private func startUpstreamWarmInitializeWhenReady(
        upstreamIndex: Int,
        mode: WarmInitializeMode
    ) {
        guard isActiveProcessBoundUpstream(upstreamIndex) else { return }
        guard upstreamHealthManager.beginWarmInitialize(upstreamIndex: upstreamIndex) else { return }

        let upstreamID = upstreamRouter.assignInitialize(upstreamIndex: upstreamIndex)
        upstreamHealthManager.setWarmInitializeUpstreamID(upstreamID, for: upstreamIndex)
        let activationStart = beginProcessRouteActivationIfNeeded(
            mode: mode,
            upstreamIndex: upstreamIndex
        )
        if case .processRouteActivation = mode, activationStart == nil {
            upstreamRouter.remove(upstreamIndex: upstreamIndex, upstreamID: upstreamID)
            clearUpstreamState(upstreamIndex: upstreamIndex, expectedUpstreamID: upstreamID)
            return
        }
        scheduleUpstreamInitTimeout(
            upstreamIndex: upstreamIndex,
            upstreamID: upstreamID,
            mode: mode,
            activationAttempt: activationStart?.attempt
        )

        let request = makeInternalInitializeRequest(id: upstreamID)
        if let data = try? JSONRPC.Wire.data(from: request) {
            sendUpstream(data, upstreamIndex: upstreamIndex, ensureRunning: true)
        } else {
            clearUpstreamState(upstreamIndex: upstreamIndex)
        }
    }

    func scheduleUpstreamInitTimeout(
        upstreamIndex: Int,
        upstreamID: Int64,
        mode: WarmInitializeMode = .regular,
        activationAttempt: Int? = nil
    ) {
        guard
            let timeoutAmount = upstreamInitTimeoutAmount(for: mode)
        else {
            return
        }
        let timeout = scheduleRuntimeTimeout(timeoutAmount) { [weak self, mode] in
            guard let self else { return }
            switch mode {
            case .regular:
                self.handleUpstreamInitTimeout(
                    upstreamIndex: upstreamIndex,
                    upstreamID: upstreamID
                )
            case .processRouteActivation(let processID):
                self.handleProcessRouteActivationTimeout(
                    processID: processID,
                    upstreamIndex: upstreamIndex,
                    upstreamID: upstreamID,
                    attempt: activationAttempt
                )
            }
        }
        let previous = upstreamHealthManager.replaceInitTimeout(timeout, upstreamIndex: upstreamIndex)
        previous?.cancel()
    }

    func upstreamInitTimeoutAmount(for mode: WarmInitializeMode) -> TimeAmount? {
        switch mode {
        case .regular:
            return MCP.MethodDispatcher.timeoutForInitialize(defaultSeconds: config.requestTimeout)
        case .processRouteActivation:
            guard config.autoApproveXcodeDialog else {
                return MCP.MethodDispatcher.timeoutForInitialize(defaultSeconds: config.requestTimeout)
            }
            return .seconds(3)
        }
    }

    func handleUpstreamInitTimeout(upstreamIndex: Int, upstreamID: Int64) {
        let shouldClear = upstreamHealthManager.clearWarmInitializeIfMatching(
            upstreamIndex: upstreamIndex,
            upstreamID: upstreamID
        )
        guard shouldClear else { return }
        upstreamRouter.remove(upstreamIndex: upstreamIndex, upstreamID: upstreamID)

        if isCurrentPrimaryInitializeUpstream(upstreamIndex) {
            let shouldRetryEagerInit = initializeManager.consumeWarmInitRecoveryIntent(
                policy: .onlyWithoutCachedInitialize
            )
            if shouldRetryEagerInit {
                startEagerInitializePrimary(applyBackoff: true)
            }
        }
        failQueuedRequestsIfNoHealthyOrRecoveringUpstream()
    }
}
