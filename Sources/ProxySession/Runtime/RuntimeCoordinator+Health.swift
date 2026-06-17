import Foundation
import NIO
import NIOFoundationCompat
import ProxyCore
import ProxyMCP

extension RuntimeCoordinator {
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
        let future = probeSession.router.registerRequest(
            idKey: originalID.key,
            on: eventLoop,
            timeout: probeTimeout
        )
        let upstreamID = assignUpstreamID(
            sessionID: internalSessionID,
            originalID: originalID,
            upstreamIndex: upstreamIndex
        )

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": upstreamID,
            "method": "tools/list",
        ]
        guard JSONSerialization.isValidJSONObject(request),
            let requestData = try? JSONSerialization.data(withJSONObject: request, options: [])
        else {
            finishHealthProbe(
                upstreamIndex: upstreamIndex,
                probeGeneration: probeGeneration,
                success: false,
                reason: "encode_request_failed"
            )
            return
        }

        sendUpstream(requestData, upstreamIndex: upstreamIndex)

        Task { [weak self] in
            guard let self else { return }
            do {
                var buffer = try await future.get()
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
    }

    func isValidToolsListResult(_ value: JSONValue) -> Bool {
        guard case .object(let object) = value else { return false }
        guard let toolsValue = object["tools"] else { return false }
        if case .array = toolsValue {
            return true
        }
        return false
    }

    func startUpstreamWarmInitialize(upstreamIndex: Int, applyBackoff: Bool = false) {
        runWhenUpstreamReady(
            reason: "warm_initialize_\(upstreamIndex)",
            applyBackoff: applyBackoff
        ) { [weak self] in
            self?.startUpstreamWarmInitializeWhenReady(upstreamIndex: upstreamIndex)
        }
    }

    private func startUpstreamWarmInitializeWhenReady(upstreamIndex: Int) {
        guard upstreamHealthManager.beginWarmInitialize(upstreamIndex: upstreamIndex) else { return }

        let upstreamID = upstreamRouter.assignInitialize(upstreamIndex: upstreamIndex)
        upstreamHealthManager.setWarmInitializeUpstreamID(upstreamID, for: upstreamIndex)
        scheduleUpstreamInitTimeout(upstreamIndex: upstreamIndex, upstreamID: upstreamID)

        let request = makeInternalInitializeRequest(id: upstreamID)
        if let data = try? JSONSerialization.data(withJSONObject: request, options: []) {
            sendUpstream(data, upstreamIndex: upstreamIndex, ensureRunning: true)
        } else {
            clearUpstreamState(upstreamIndex: upstreamIndex)
        }
    }

    func scheduleUpstreamInitTimeout(upstreamIndex: Int, upstreamID: Int64) {
        guard
            let timeoutAmount = MCP.MethodDispatcher.timeoutForInitialize(
                defaultSeconds: config.requestTimeout)
        else {
            return
        }
        let timeout = scheduleRuntimeTimeout(timeoutAmount) { [weak self] in
            guard let self else { return }
            self.handleUpstreamInitTimeout(upstreamIndex: upstreamIndex, upstreamID: upstreamID)
        }
        let previous = upstreamHealthManager.replaceInitTimeout(timeout, upstreamIndex: upstreamIndex)
        previous?.cancel()
    }

    func handleUpstreamInitTimeout(upstreamIndex: Int, upstreamID: Int64) {
        let shouldClear = upstreamHealthManager.clearWarmInitializeIfMatching(
            upstreamIndex: upstreamIndex,
            upstreamID: upstreamID
        )
        guard shouldClear else { return }
        upstreamRouter.remove(upstreamIndex: upstreamIndex, upstreamID: upstreamID)

        if upstreamIndex == 0 {
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
