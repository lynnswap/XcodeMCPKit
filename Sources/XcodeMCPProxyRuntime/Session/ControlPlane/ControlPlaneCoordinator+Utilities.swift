import Foundation
import NIO
import XcodeMCPKit

extension ControlPlaneCoordinator {
    private var sharedLoadPromotionGraceNanoseconds: UInt64 { 100_000_000 }

    func cancelToolsCatalogLoad(
        _ load: ToolsCatalogLoadState,
        error: Error
    ) {
        load.rpcHandle.cancel()
        load.task.cancel()
        for waiter in load.waiters.values {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }

    func cancelWindowLoad(
        _ load: WindowLoadState,
        error: Error
    ) {
        load.rpcHandle.cancel()
        load.task.cancel()
        for waiter in load.waiters.values {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }

    func makeTimeoutTask(
        deadlineUptimeNs: UInt64?,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never>? {
        guard let deadlineUptimeNs else { return nil }
        let now = clock.uptimeNanoseconds()
        guard deadlineUptimeNs > now else { return nil }
        let remaining = deadlineUptimeNs - now
        return Task {
            await clock.sleep(.nanoseconds(Int64(min(remaining, UInt64(Int64.max)))))
            guard Task.isCancelled == false else { return }
            await operation()
        }
    }

    func deadlineExceeded(_ deadlineUptimeNs: UInt64?) -> Bool {
        guard let deadlineUptimeNs else { return false }
        return clock.uptimeNanoseconds() >= deadlineUptimeNs
    }

    func requestTimeout(until deadlineUptimeNs: UInt64?) -> TimeAmount? {
        guard let deadlineUptimeNs else { return nil }
        let now = clock.uptimeNanoseconds()
        guard deadlineUptimeNs > now else {
            return .nanoseconds(0)
        }
        let remaining = deadlineUptimeNs - now
        let maxNanos = UInt64(Int64.max)
        return .nanoseconds(Int64(min(remaining, maxNanos)))
    }

    func requestDeadline(for requestTimeout: TimeAmount?) -> UInt64? {
        guard let requestTimeout, requestTimeout.nanoseconds > 0 else { return nil }
        let now = clock.uptimeNanoseconds()
        let remainingToMax = UInt64.max &- now
        let clamped = min(UInt64(requestTimeout.nanoseconds), remainingToMax)
        return now &+ clamped
    }

    func promotionDeadlineUptimeNs(forWaiterDeadlineUptimeNs deadlineUptimeNs: UInt64?) -> UInt64? {
        deadlineUptimeNs ?? requestDeadline(for: controlPlaneDefaultTimeout)
    }

    func currentToolsCatalogLoadState(loadID: UUID) -> ToolsCatalogLoadState? {
        if let load = toolsCatalogLoad, load.loadID == loadID {
            return load
        }
        if let load = prewarmToolsCatalogLoad, load.loadID == loadID {
            return load
        }
        return nil
    }

    func setToolsCatalogLoadState(_ load: ToolsCatalogLoadState) {
        switch load.origin {
        case .request:
            toolsCatalogLoad = load
        case .prewarm:
            prewarmToolsCatalogLoad = load
        }
    }

    func clearToolsCatalogLoadState(loadID: UUID) {
        if toolsCatalogLoad?.loadID == loadID {
            toolsCatalogLoad = nil
        } else if prewarmToolsCatalogLoad?.loadID == loadID {
            prewarmToolsCatalogLoad = nil
        }
    }

    func takeToolsCatalogLoadIfMatching(loadID: UUID) -> ToolsCatalogLoadState? {
        if let load = toolsCatalogLoad, load.loadID == loadID {
            toolsCatalogLoad = nil
            return load
        }
        if let load = prewarmToolsCatalogLoad, load.loadID == loadID {
            prewarmToolsCatalogLoad = nil
            return load
        }
        return nil
    }

    func shouldCancelToolsCatalogLoadAfterWaiterRemoval(
        _ load: ToolsCatalogLoadState
    ) -> Bool {
        switch load.origin {
        case .request:
            return load.waiters.isEmpty
        case .prewarm:
            return load.foregroundWaiterCount == 0
        }
    }

    func sharedRequestTimeout(for deadlineUptimeNs: UInt64?) -> TimeAmount? {
        let waiterTimeout = requestTimeout(until: deadlineUptimeNs)
        switch (controlPlaneDefaultTimeout, waiterTimeout) {
        case let (.some(defaultTimeout), .some(waiterTimeout)):
            return waiterTimeout.nanoseconds > defaultTimeout.nanoseconds ? waiterTimeout : defaultTimeout
        case let (.some(defaultTimeout), .none):
            return defaultTimeout
        case let (.none, .some(waiterTimeout)):
            return waiterTimeout
        case (.none, .none):
            return nil
        }
    }

    func shouldPromoteSharedLoad(
        currentRequestDeadlineUptimeNs: UInt64?,
        requestedRequestDeadlineUptimeNs: UInt64?
    ) -> Bool {
        switch (currentRequestDeadlineUptimeNs, requestedRequestDeadlineUptimeNs) {
        case let (.some(current), .some(requested)):
            guard requested > current else { return false }
            return requested - current > sharedLoadPromotionGraceNanoseconds
        case (.some, .none):
            return true
        case (.none, _):
            return false
        }
    }
}
