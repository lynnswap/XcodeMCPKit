import Foundation
import NIO
import XcodeMCPCore

extension ControlPlaneCoordinator {
    func replaceToolsCatalogRequestLoad(
        _ current: ToolsCatalogLoadState,
        requestTimeout: TimeAmount?
    ) -> UUID {
        var previous = current
        toolsCatalogLoad = nil
        let migratedWaiters = removeForegroundToolsCatalogWaiters(from: &previous)
        cancelToolsCatalogLoad(previous, error: CancellationError())
        let newLoadID = startToolsCatalogLoad(origin: .request, requestTimeout: requestTimeout)
        if current.hasPublishedPartialResult, var replacement = currentToolsCatalogLoadState(loadID: newLoadID) {
            replacement.hasPublishedPartialResult = true
            setToolsCatalogLoadState(replacement)
        }
        attachToolsCatalogWaiters(loadID: newLoadID, waiters: migratedWaiters)
        return newLoadID
    }

    func promotePrewarmToolsCatalogLoad(
        _ current: ToolsCatalogLoadState,
        requestTimeout: TimeAmount?
    ) -> UUID {
        var previous = current
        prewarmToolsCatalogLoad = nil
        let migratedWaiters = removeForegroundToolsCatalogWaiters(from: &previous)
        cancelToolsCatalogLoad(previous, error: CancellationError())
        let newLoadID = startToolsCatalogLoad(origin: .request, requestTimeout: requestTimeout)
        if current.hasPublishedPartialResult, var replacement = currentToolsCatalogLoadState(loadID: newLoadID) {
            replacement.hasPublishedPartialResult = true
            setToolsCatalogLoadState(replacement)
        }
        attachToolsCatalogWaiters(loadID: newLoadID, waiters: migratedWaiters)
        return newLoadID
    }

    func removeForegroundToolsCatalogWaiters(
        from load: inout ToolsCatalogLoadState
    ) -> [(WaiterID, ToolsCatalogWaiterRecord)] {
        var migrated: [(WaiterID, ToolsCatalogWaiterRecord)] = []
        for (waiterID, waiter) in load.waiters where waiter.kind == .foreground {
            waiter.timeoutTask?.cancel()
            migrated.append((waiterID, waiter))
        }
        for (waiterID, _) in migrated {
            load.waiters.removeValue(forKey: waiterID)
        }
        load.foregroundWaiterCount = 0
        return migrated
    }

    func attachToolsCatalogWaiters(
        loadID: UUID,
        waiters: [(WaiterID, ToolsCatalogWaiterRecord)]
    ) {
        guard var load = currentToolsCatalogLoadState(loadID: loadID) else { return }
        for (waiterID, waiter) in waiters {
            if deadlineExceeded(waiter.deadlineUptimeNs) {
                waiter.continuation.resume(throwing: TimeoutError())
                continue
            }
            let phaseDeadline = waiter.partialPublicationUptimeNs.flatMap {
                $0 > clock.uptimeNanoseconds() ? $0 : nil
            } ?? waiter.deadlineUptimeNs
            let timeoutTask = makeTimeoutTask(deadlineUptimeNs: phaseDeadline) {
                await self.toolsCatalogWaiterPhaseReached(loadID: loadID, waiterID: waiterID)
            }
            load.waiters[waiterID] = ToolsCatalogWaiterRecord(
                continuation: waiter.continuation,
                kind: waiter.kind,
                deadlineUptimeNs: waiter.deadlineUptimeNs,
                partialPublicationUptimeNs: waiter.partialPublicationUptimeNs,
                timeoutTask: timeoutTask
            )
            if waiter.kind == .foreground {
                load.foregroundWaiterCount += 1
            }
        }
        setToolsCatalogLoadState(load)
        syncDebug()
    }

    func currentPhase() -> Phase {
        if toolsCatalogLoad != nil || prewarmToolsCatalogLoad != nil {
            return .loadingToolsCatalog
        }
        return .idle
    }

    func currentWaiterCounts() -> ControlPlane.WaiterCounts {
        let toolsCount =
            (toolsCatalogLoad?.foregroundWaiterCount ?? 0)
            + (prewarmToolsCatalogLoad?.foregroundWaiterCount ?? 0)
        return ControlPlane.WaiterCounts(
            initialize: 0,
            toolsCatalog: toolsCount
        )
    }

    func currentInFlightRequestLabels() -> [String] {
        var requests: [String] = []
        if toolsCatalogLoad != nil || prewarmToolsCatalogLoad != nil {
            requests.append("tools/list")
        }
        return requests
    }

    func syncDebug() {
        let handshakeSnapshot = handshakeState.snapshot()
        let cachedTools = cachedToolsCatalog()
        let snapshot = ControlPlane.DebugSnapshot(
            phase: currentPhase().rawValue,
            canonicalInitializeSourceUpstream: handshakeSnapshot.initializeSourceUpstream,
            canonicalToolsSourceUpstream: canonicalToolsSource(),
            canonicalReady: handshakeSnapshot.isInitialized && cachedTools != nil,
            upstreamHandshakeStates: upstreamHandshakeStates(),
            waiterCounts: currentWaiterCounts(),
            inFlightControlPlaneRequests: currentInFlightRequestLabels(),
            lastIncompatibility: handshakeSnapshot.lastIncompatibility
        )
        debugMirror.overwrite(snapshot)
    }
}
