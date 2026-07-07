import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPKit

final class XcodeProcessRouteActivationTracker: Sendable {
    enum Phase: Sendable, Equatable {
        case pending
        case attaching(upstreamIndex: Int, attempt: Int, startedAtUptimeNs: UInt64)
        case initialized(upstreamIndex: Int, attempt: Int, startedAtUptimeNs: UInt64)
        case cataloged(upstreamIndex: Int, attempt: Int)
        case abandoned(reason: String)
    }

    struct Start: Sendable {
        let attempt: Int
        let startedAtUptimeNs: UInt64
    }

    struct Initialized: Sendable {
        let attempt: Int
        let startedAtUptimeNs: UInt64
    }

    struct Retry: Sendable {
        let attempt: Int
        let delay: TimeAmount
        let delayMilliseconds: Int64
    }

    struct CatalogTimeout: Sendable {
        let rpcHandles: [ControlPlane.RPCHandle]
    }

    private struct Record: Sendable {
        var phase: Phase
        var attempt: Int
        var retryTimeout: RuntimeScheduledTimeout?
        var catalogTimeout: RuntimeScheduledTimeout?
        var catalogRPCHandles: [ControlPlane.RPCHandle]

        init(
            phase: Phase,
            attempt: Int = 0,
            retryTimeout: RuntimeScheduledTimeout? = nil,
            catalogTimeout: RuntimeScheduledTimeout? = nil,
            catalogRPCHandles: [ControlPlane.RPCHandle] = []
        ) {
            self.phase = phase
            self.attempt = attempt
            self.retryTimeout = retryTimeout
            self.catalogTimeout = catalogTimeout
            self.catalogRPCHandles = catalogRPCHandles
        }

        func cancelTimeouts() {
            retryTimeout?.cancel()
            catalogTimeout?.cancel()
            catalogRPCHandles.forEach { $0.cancel() }
        }
    }

    private let state = NIOLockedValueBox<[pid_t: Record]>([:])

    func prepare(processID: pid_t) {
        state.withLockedValue { records in
            if let record = records[processID] {
                switch record.phase {
                case .cataloged:
                    records[processID] = Record(phase: .pending, attempt: record.attempt)
                case .abandoned:
                    records[processID] = Record(phase: .pending, attempt: 0)
                case .pending, .attaching, .initialized:
                    break
                }
            } else {
                records[processID] = Record(phase: .pending)
            }
        }
    }

    func beginAttaching(
        processID: pid_t,
        upstreamIndex: Int,
        nowUptimeNs: UInt64
    ) -> Start? {
        state.withLockedValue { records in
            var record = records[processID] ?? Record(phase: .pending)
            switch record.phase {
            case .pending:
                guard record.retryTimeout == nil else {
                    records[processID] = record
                    return nil
                }
            case .abandoned:
                break
            case .attaching, .initialized, .cataloged:
                return nil
            }

            record.retryTimeout?.cancel()
            record.retryTimeout = nil
            record.catalogTimeout?.cancel()
            record.catalogTimeout = nil
            record.catalogRPCHandles.forEach { $0.cancel() }
            record.catalogRPCHandles.removeAll()
            record.attempt += 1
            record.phase = .attaching(
                upstreamIndex: upstreamIndex,
                attempt: record.attempt,
                startedAtUptimeNs: nowUptimeNs
            )
            records[processID] = record
            return Start(attempt: record.attempt, startedAtUptimeNs: nowUptimeNs)
        }
    }

    func markInitialized(
        processID: pid_t,
        upstreamIndex: Int,
        nowUptimeNs _: UInt64
    ) -> Initialized? {
        state.withLockedValue { records -> Initialized? in
            guard var record = records[processID] else { return nil }
            guard case .attaching(let currentUpstreamIndex, let attempt, let startedAt) = record.phase,
                  currentUpstreamIndex == upstreamIndex
            else {
                return nil
            }
            record.phase = .initialized(
                upstreamIndex: upstreamIndex,
                attempt: attempt,
                startedAtUptimeNs: startedAt
            )
            records[processID] = record
            return Initialized(attempt: attempt, startedAtUptimeNs: startedAt)
        }
    }

    func markCataloged(
        processID: pid_t,
        upstreamIndex: Int,
        catalogedUpstreamIndex: Int? = nil,
        attempt expectedAttempt: Int? = nil,
        nowUptimeNs: UInt64
    ) -> UInt64? {
        state.withLockedValue { records -> UInt64? in
            guard var record = records[processID] else { return nil }
            let duration: UInt64
            let catalogedAttempt: Int
            switch record.phase {
            case .initialized(let currentUpstreamIndex, let attempt, let startedAt)
                where currentUpstreamIndex == upstreamIndex:
                if let expectedAttempt, expectedAttempt != attempt {
                    return nil
                }
                duration = nowUptimeNs &- startedAt
                catalogedAttempt = attempt
            case .attaching(let currentUpstreamIndex, let attempt, let startedAt)
                where currentUpstreamIndex == upstreamIndex:
                if let expectedAttempt, expectedAttempt != attempt {
                    return nil
                }
                duration = nowUptimeNs &- startedAt
                catalogedAttempt = attempt
            case .cataloged(let currentUpstreamIndex, _) where currentUpstreamIndex == upstreamIndex:
                return nil
            case .pending, .abandoned, .attaching, .initialized, .cataloged:
                return nil
            }
            record.retryTimeout?.cancel()
            record.retryTimeout = nil
            record.catalogTimeout?.cancel()
            record.catalogTimeout = nil
            record.catalogRPCHandles.forEach { $0.cancel() }
            record.catalogRPCHandles.removeAll()
            record.phase = .cataloged(
                upstreamIndex: catalogedUpstreamIndex ?? upstreamIndex,
                attempt: catalogedAttempt
            )
            records[processID] = record
            return duration
        }
    }

    func isCataloged(processID: pid_t, attempt expectedAttempt: Int? = nil) -> Bool {
        state.withLockedValue { records in
            guard case .cataloged(_, let attempt)? = records[processID]?.phase else {
                return false
            }
            if let expectedAttempt {
                return attempt == expectedAttempt
            }
            return true
        }
    }

    func handleTimeout(
        processID: pid_t,
        upstreamIndex: Int,
        attempt: Int
    ) -> Retry? {
        state.withLockedValue { records in
            guard var record = records[processID] else { return nil }
            guard case .attaching(let currentUpstreamIndex, let currentAttempt, _) = record.phase,
                  currentUpstreamIndex == upstreamIndex,
                  currentAttempt == attempt
            else {
                return nil
            }
            record.phase = .pending
            records[processID] = record
            return Self.retry(forAttempt: currentAttempt)
        }
    }

    func handleCatalogTimeout(
        processID: pid_t,
        upstreamIndex: Int,
        attempt: Int
    ) -> CatalogTimeout? {
        state.withLockedValue { records in
            guard var record = records[processID] else { return nil }
            guard case .initialized(let currentUpstreamIndex, let currentAttempt, _) = record.phase,
                  currentUpstreamIndex == upstreamIndex,
                  currentAttempt == attempt
            else {
                return nil
            }
            let rpcHandles = record.catalogRPCHandles
            record.catalogRPCHandles.removeAll()
            record.catalogTimeout = nil
            record.phase = .pending
            records[processID] = record
            return CatalogTimeout(rpcHandles: rpcHandles)
        }
    }

    func handleRetryFired(processID: pid_t) -> Bool {
        state.withLockedValue { records in
            guard var record = records[processID] else { return false }
            record.retryTimeout = nil
            switch record.phase {
            case .pending:
                records[processID] = record
                return true
            case .attaching, .initialized, .cataloged, .abandoned:
                records[processID] = record
                return false
            }
        }
    }

    func storeRetry(
        processID: pid_t,
        timeout: RuntimeScheduledTimeout
    ) {
        state.withLockedValue { records in
            var record = records[processID] ?? Record(phase: .pending)
            record.retryTimeout?.cancel()
            record.retryTimeout = timeout
            records[processID] = record
        }
    }

    func storeCatalogTimeout(
        processID: pid_t,
        upstreamIndex: Int,
        attempt: Int,
        timeout: RuntimeScheduledTimeout
    ) {
        let shouldCancelTimeout = state.withLockedValue { records -> Bool in
            guard var record = records[processID],
                  case .initialized(let currentUpstreamIndex, let currentAttempt, _) = record.phase,
                  currentUpstreamIndex == upstreamIndex,
                  currentAttempt == attempt
            else {
                return true
            }
            record.catalogTimeout?.cancel()
            record.catalogTimeout = timeout
            records[processID] = record
            return false
        }
        if shouldCancelTimeout {
            timeout.cancel()
        }
    }

    func storeCatalogRPCHandle(
        processID: pid_t,
        upstreamIndex: Int,
        attempt: Int,
        rpcHandle: ControlPlane.RPCHandle
    ) {
        let shouldCancelHandle = state.withLockedValue { records -> Bool in
            guard var record = records[processID],
                  case .initialized(let currentUpstreamIndex, let currentAttempt, _) = record.phase,
                  currentUpstreamIndex == upstreamIndex,
                  currentAttempt == attempt
            else {
                return true
            }
            record.catalogRPCHandles.append(rpcHandle)
            records[processID] = record
            return false
        }
        if shouldCancelHandle {
            rpcHandle.cancel()
        }
    }

    func abandon(processID: pid_t, reason: String) {
        state.withLockedValue { records in
            var record = records[processID] ?? Record(phase: .pending)
            record.cancelTimeouts()
            record.retryTimeout = nil
            record.catalogTimeout = nil
            record.catalogRPCHandles.removeAll()
            record.phase = .abandoned(reason: reason)
            records[processID] = record
        }
    }

    @discardableResult
    func reset(processID: pid_t) -> Bool {
        state.withLockedValue { records in
            guard let record = records.removeValue(forKey: processID) else {
                return false
            }
            record.cancelTimeouts()
            return true
        }
    }

    func resetAll() -> [pid_t] {
        state.withLockedValue { records in
            let processIDs = Array(records.keys)
            for record in records.values {
                record.cancelTimeouts()
            }
            records.removeAll()
            return processIDs
        }
    }

    func phase(processID: pid_t) -> Phase? {
        state.withLockedValue { $0[processID]?.phase }
    }

    func catalogAttempt(processID: pid_t, upstreamIndex: Int) -> Int? {
        state.withLockedValue { records in
            guard let record = records[processID] else {
                return nil
            }
            switch record.phase {
            case .initialized(let currentUpstreamIndex, let attempt, _)
                where currentUpstreamIndex == upstreamIndex:
                return attempt
            case .pending, .attaching, .initialized, .cataloged, .abandoned:
                return nil
            }
        }
    }

    private static func retry(forAttempt attempt: Int) -> Retry {
        let delayMilliseconds: Int64
        switch attempt {
        case ...1:
            delayMilliseconds = 250
        case 2:
            delayMilliseconds = 500
        case 3:
            delayMilliseconds = 1_000
        default:
            delayMilliseconds = 2_000
        }
        return Retry(
            attempt: attempt,
            delay: .milliseconds(delayMilliseconds),
            delayMilliseconds: delayMilliseconds
        )
    }
}
