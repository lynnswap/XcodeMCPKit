import Foundation
import NIO
import NIOConcurrencyHelpers

package final class UpstreamHealthManager: Sendable {
    package struct ProbeRequest: Sendable {
        package let upstreamIndex: Int
        package let probeGeneration: UInt64
    }

    package enum Effect: Sendable {
        case cancelInitTimeout(RuntimeScheduledTimeout)
        case startHealthProbe(UpstreamHealthManager.ProbeRequest)
        case clearPins
        case failQueuedIfNoRecovery
    }

    package struct UseEvaluation: Sendable {
        package let isUsable: Bool
        package let effects: [UpstreamHealthManager.Effect]

        package init(isUsable: Bool, effects: [UpstreamHealthManager.Effect]) {
            self.isUsable = isUsable
            self.effects = effects
        }
    }

    package struct SelectionResult: Sendable {
        package let upstreamIndex: Int?
        package let effects: [UpstreamHealthManager.Effect]

        package init(upstreamIndex: Int?, effects: [UpstreamHealthManager.Effect]) {
            self.upstreamIndex = upstreamIndex
            self.effects = effects
        }
    }

    package struct ProtocolViolationTransition: Sendable {
        package let quarantineUntil: UInt64
        package let cancelledInitTimeout: RuntimeScheduledTimeout?
    }

    package struct IncompatibilityTransition: Sendable {
        package let quarantineUntil: UInt64
        package let cancelledInitTimeout: RuntimeScheduledTimeout?
        package let initUpstreamID: Int64?
    }

    package enum InitPhase: Sendable, Equatable {
        case idle
        case initializing(upstreamID: Int64?)
        case initialized

        var isInitialized: Bool {
            guard case .initialized = self else { return false }
            return true
        }

        var isInFlight: Bool {
            guard case .initializing = self else { return false }
            return true
        }

        var upstreamID: Int64? {
            guard case .initializing(let upstreamID) = self else { return nil }
            return upstreamID
        }
    }

    package enum Event: Sendable {
        case requestSucceeded(upstreamIndex: Int)
        case upstreamOverloaded(upstreamIndex: Int)
        case healthProbeFinished(
            upstreamIndex: Int,
            probeGeneration: UInt64,
            success: Bool,
            nowUptimeNs: UInt64
        )
        case toolsListRefreshSucceeded(upstreamIndex: Int, nowUptimeNs: UInt64)
    }

    package struct UpstreamState: Sendable {
        package var initPhase: InitPhase = .idle
        package var initTimeout: RuntimeScheduledTimeout?
        package var didSendInitialized = false
        package var healthState: UpstreamHealthState = .healthy
        package var consecutiveRequestTimeouts = 0
        package var healthProbeInFlight = false
        package var healthProbeGeneration: UInt64 = 0
        package var consecutiveToolsListFailures: Int = 0
        package var lastToolsListSuccessUptimeNs: UInt64?
        package var requestPickCount: Int = 0

        package var isInitialized: Bool {
            get { initPhase.isInitialized }
            set {
                if newValue {
                    initPhase = .initialized
                } else if initPhase.isInitialized {
                    initPhase = .idle
                }
            }
        }

        package var initInFlight: Bool {
            get { initPhase.isInFlight }
            set {
                if newValue {
                    initPhase = .initializing(upstreamID: initPhase.upstreamID)
                } else if initPhase.isInFlight {
                    initPhase = .idle
                }
            }
        }

        package var initUpstreamID: Int64? {
            get { initPhase.upstreamID }
            set {
                if initPhase.isInFlight || newValue != nil {
                    initPhase = .initializing(upstreamID: newValue)
                }
            }
        }
    }

    private struct State: Sendable {
        var upstreamStates: [UpstreamState] = []
        var nextPick: Int = 0
    }

    private let state: NIOLockedValueBox<State>

    package init(upstreamCount: Int) {
        self.state = NIOLockedValueBox(State(
            upstreamStates: Array(repeating: UpstreamState(), count: upstreamCount),
            nextPick: 0
        ))
    }

    package func statesSnapshot() -> [UpstreamState] {
        state.withLockedValue { $0.upstreamStates }
    }

    package func count() -> Int {
        state.withLockedValue { $0.upstreamStates.count }
    }

    package func clearInitTimeoutsForShutdown() -> [RuntimeScheduledTimeout?] {
        state.withLockedValue { state -> [RuntimeScheduledTimeout?] in
            var timeouts: [RuntimeScheduledTimeout?] = []
            timeouts.reserveCapacity(state.upstreamStates.count)
            for index in 0..<state.upstreamStates.count {
                timeouts.append(state.upstreamStates[index].initTimeout)
                state.upstreamStates[index].initTimeout = nil
                state.upstreamStates[index].initInFlight = false
                state.upstreamStates[index].initUpstreamID = nil
            }
            return timeouts
        }
    }

    package func anyInitialized() -> Bool {
        state.withLockedValue { $0.upstreamStates.contains { $0.isInitialized } }
    }

    package func primaryInitInFlight() -> Bool {
        state.withLockedValue { state in
            guard !state.upstreamStates.isEmpty else { return false }
            return state.upstreamStates[0].initInFlight
        }
    }

    package func anyRecoveryInFlight() -> Bool {
        state.withLockedValue { state in
            state.upstreamStates.contains { $0.initInFlight || $0.healthProbeInFlight }
        }
    }

    package func initializedHealthyishCount() -> Int {
        state.withLockedValue { state in
            state.upstreamStates.reduce(into: 0) { count, upstream in
                guard upstream.isInitialized else { return }
                switch upstream.healthState {
                case .healthy, .degraded:
                    count += 1
                case .quarantined:
                    break
                }
            }
        }
    }

    package func evaluateUsableInitialized(
        index: Int,
        nowUptimeNs: UInt64
    ) -> UpstreamHealthManager.UseEvaluation {
        var effects: [UpstreamHealthManager.Effect] = []
        let usable = state.withLockedValue { state in
            guard index >= 0, index < state.upstreamStates.count else { return false }
            let health = Self.classifyHealthAndCollectEffectsIfNeeded(
                upstreamIndex: index,
                nowUptimeNs: nowUptimeNs,
                state: &state,
                effects: &effects
            )
            let isHealthyEnough: Bool
            switch health {
            case .healthy, .degraded:
                isHealthyEnough = true
            case .quarantined:
                isHealthyEnough = false
            }
            return isHealthyEnough && state.upstreamStates[index].isInitialized
        }
        return UpstreamHealthManager.UseEvaluation(isUsable: usable, effects: effects)
    }

    package func chooseBestInitializedUpstream(
        nowUptimeNs: UInt64,
        occupiedUpstreams: Set<Int>
    ) -> UpstreamHealthManager.SelectionResult {
        var effects: [UpstreamHealthManager.Effect] = []
        let chosen = state.withLockedValue { state -> Int? in
            let count = state.upstreamStates.count
            guard count > 0 else { return nil }

            let rawStart = state.nextPick % count
            let start = rawStart >= 0 ? rawStart : rawStart + count
            state.nextPick &+= 1

            var degradedCandidate: Int?
            for offset in 0..<count {
                let candidate = (start + offset) % count
                if occupiedUpstreams.contains(candidate) {
                    continue
                }
                guard state.upstreamStates[candidate].isInitialized else { continue }
                let health = Self.classifyHealthAndCollectEffectsIfNeeded(
                    upstreamIndex: candidate,
                    nowUptimeNs: nowUptimeNs,
                    state: &state,
                    effects: &effects
                )
                switch health {
                case .healthy:
                    state.upstreamStates[candidate].requestPickCount += 1
                    return candidate
                case .degraded:
                    if degradedCandidate == nil {
                        degradedCandidate = candidate
                    }
                case .quarantined:
                    continue
                }
            }
            if let degradedCandidate {
                state.upstreamStates[degradedCandidate].requestPickCount += 1
            }
            return degradedCandidate
        }
        return UpstreamHealthManager.SelectionResult(upstreamIndex: chosen, effects: effects)
    }

    package func markRequestSucceeded(upstreamIndex: Int) {
        _ = apply(event: .requestSucceeded(upstreamIndex: upstreamIndex))
    }

    package func markUpstreamOverloaded(upstreamIndex: Int) -> Bool {
        apply(event: .upstreamOverloaded(upstreamIndex: upstreamIndex)).isEmpty == false
    }

    package func markRequestTimedOut(upstreamIndex: Int, nowUptimeNs: UInt64) -> (shouldClearPins: Bool, timeoutCount: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else {
                return (false, 0)
            }
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts += 1
            let timeoutCount = state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts
            if timeoutCount >= 3 {
                let quarantineUntil = nowUptimeNs &+ 15_000_000_000
                state.upstreamStates[upstreamIndex].healthState = .quarantined(untilUptimeNs: quarantineUntil)
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
                state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
                return (true, timeoutCount)
            } else {
                state.upstreamStates[upstreamIndex].healthState = .degraded
                return (false, timeoutCount)
            }
        }
    }

    package func markProtocolViolation(
        upstreamIndex: Int,
        nowUptimeNs: UInt64
    ) -> UpstreamHealthManager.ProtocolViolationTransition? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            let quarantineUntil = nowUptimeNs &+ 15_000_000_000
            let cancelledInitTimeout = state.upstreamStates[upstreamIndex].initTimeout
            state.upstreamStates[upstreamIndex].isInitialized = false
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].initTimeout = nil
            state.upstreamStates[upstreamIndex].initUpstreamID = nil
            state.upstreamStates[upstreamIndex].didSendInitialized = false
            state.upstreamStates[upstreamIndex].healthState = .quarantined(
                untilUptimeNs: quarantineUntil
            )
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
            return UpstreamHealthManager.ProtocolViolationTransition(
                quarantineUntil: quarantineUntil,
                cancelledInitTimeout: cancelledInitTimeout
            )
        }
    }

    package func quarantineIncompatibleUpstream(
        upstreamIndex: Int,
        nowUptimeNs: UInt64
    ) -> UpstreamHealthManager.IncompatibilityTransition? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            let quarantineUntil = nowUptimeNs &+ 30_000_000_000
            let cancelledInitTimeout = state.upstreamStates[upstreamIndex].initTimeout
            let initUpstreamID = state.upstreamStates[upstreamIndex].initUpstreamID
            state.upstreamStates[upstreamIndex].isInitialized = false
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].initTimeout = nil
            state.upstreamStates[upstreamIndex].initUpstreamID = nil
            state.upstreamStates[upstreamIndex].didSendInitialized = false
            state.upstreamStates[upstreamIndex].healthState = .quarantined(
                untilUptimeNs: quarantineUntil
            )
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
            return UpstreamHealthManager.IncompatibilityTransition(
                quarantineUntil: quarantineUntil,
                cancelledInitTimeout: cancelledInitTimeout,
                initUpstreamID: initUpstreamID
            )
        }
    }

    package func finishHealthProbe(
        upstreamIndex: Int,
        probeGeneration: UInt64,
        success: Bool,
        nowUptimeNs: UInt64
    ) {
        _ = apply(event: .healthProbeFinished(
            upstreamIndex: upstreamIndex,
            probeGeneration: probeGeneration,
            success: success,
            nowUptimeNs: nowUptimeNs
        ))
    }

    package func markToolsListRefreshSucceeded(upstreamIndex: Int, nowUptimeNs: UInt64) {
        _ = apply(event: .toolsListRefreshSucceeded(
            upstreamIndex: upstreamIndex,
            nowUptimeNs: nowUptimeNs
        ))
    }

    package func markToolsListRefreshFailed(upstreamIndex: Int, nowUptimeNs: UInt64) -> (failures: Int, quarantineUntil: UInt64)? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            let quarantineUntil = nowUptimeNs &+ 30 * 1_000_000_000
            state.upstreamStates[upstreamIndex].healthState = .quarantined(untilUptimeNs: quarantineUntil)
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            state.upstreamStates[upstreamIndex].consecutiveToolsListFailures += 1
            return (state.upstreamStates[upstreamIndex].consecutiveToolsListFailures, quarantineUntil)
        }
    }

    package func shouldSendInitializedNotification(upstreamIndex: Int) -> Bool {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else {
                return false
            }
            return state.upstreamStates[upstreamIndex].didSendInitialized == false
        }
    }

    package func markInitializedNotificationSent(upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].didSendInitialized = true
        }
    }

    package func resetForDebug() -> [RuntimeScheduledTimeout?] {
        state.withLockedValue { state in
            let timeouts = state.upstreamStates.map(\.initTimeout)
            state.upstreamStates = Array(repeating: UpstreamState(), count: state.upstreamStates.count)
            state.nextPick = 0
            return timeouts
        }
    }

    package func beginWarmInitialize(upstreamIndex: Int) -> Bool {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return false }
            if state.upstreamStates[upstreamIndex].isInitialized || state.upstreamStates[upstreamIndex].initInFlight {
                return false
            }
            state.upstreamStates[upstreamIndex].initInFlight = true
            return true
        }
    }

    package func setWarmInitializeUpstreamID(_ upstreamID: Int64, for upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].initUpstreamID = upstreamID
        }
    }

    package func replaceInitTimeout(
        _ timeout: RuntimeScheduledTimeout,
        upstreamIndex: Int
    ) -> RuntimeScheduledTimeout? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            let existing = state.upstreamStates[upstreamIndex].initTimeout
            state.upstreamStates[upstreamIndex].initTimeout = timeout
            return existing
        }
    }

    package func clearWarmInitializeIfMatching(upstreamIndex: Int, upstreamID: Int64) -> Bool {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return false }
            guard state.upstreamStates[upstreamIndex].initUpstreamID == upstreamID else { return false }
            state.upstreamStates[upstreamIndex].initTimeout = nil
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].isInitialized = false
            state.upstreamStates[upstreamIndex].initUpstreamID = nil
            return true
        }
    }

    package func markInitInFlight(upstreamIndex: Int, upstreamID: Int64) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].initInFlight = true
            state.upstreamStates[upstreamIndex].initUpstreamID = upstreamID
            state.upstreamStates[upstreamIndex].isInitialized = false
        }
    }

    package func clearInitInFlight(upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].initUpstreamID = nil
            state.upstreamStates[upstreamIndex].initTimeout = nil
        }
    }

    package func clearUpstreamState(upstreamIndex: Int) -> (
        timeout: RuntimeScheduledTimeout?,
        initUpstreamID: Int64?
    )? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            let timeout = state.upstreamStates[upstreamIndex].initTimeout
            let initUpstreamID = state.upstreamStates[upstreamIndex].initUpstreamID
            state.upstreamStates[upstreamIndex].initTimeout = nil
            state.upstreamStates[upstreamIndex].isInitialized = false
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].didSendInitialized = false
            state.upstreamStates[upstreamIndex].initUpstreamID = nil
            state.upstreamStates[upstreamIndex].healthState = .healthy
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
            state.upstreamStates[upstreamIndex].consecutiveToolsListFailures = 0
            state.upstreamStates[upstreamIndex].lastToolsListSuccessUptimeNs = nil
            state.upstreamStates[upstreamIndex].requestPickCount = 0
            return (timeout, initUpstreamID)
        }
    }

    package func markInitialized(upstreamIndex: Int) -> RuntimeScheduledTimeout? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            state.upstreamStates[upstreamIndex].isInitialized = true
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].initUpstreamID = nil
            state.upstreamStates[upstreamIndex].healthState = .healthy
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            let timeout = state.upstreamStates[upstreamIndex].initTimeout
            state.upstreamStates[upstreamIndex].initTimeout = nil
            return timeout
        }
    }

    package func debugHealthStateString(_ state: UpstreamHealthState) -> String {
        switch state {
        case .healthy:
            return "healthy"
        case .degraded:
            return "degraded"
        case .quarantined(let untilUptimeNs):
            return "quarantined(untilUptimeNs:\(untilUptimeNs))"
        }
    }

    package func apply(event: Event) -> [UpstreamHealthManager.Effect] {
        state.withLockedValue { state in
            switch event {
            case .requestSucceeded(let upstreamIndex):
                guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return [] }
                state.upstreamStates[upstreamIndex].healthState = .healthy
                state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
                if state.upstreamStates[upstreamIndex].healthProbeInFlight {
                    state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
                }
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
                return [.failQueuedIfNoRecovery]

            case .upstreamOverloaded(let upstreamIndex):
                guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return [] }
                if case .healthy = state.upstreamStates[upstreamIndex].healthState {
                    state.upstreamStates[upstreamIndex].healthState = .degraded
                }
                if state.upstreamStates[upstreamIndex].healthProbeInFlight {
                    state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
                }
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
                return [.failQueuedIfNoRecovery]

            case .healthProbeFinished(
                let upstreamIndex,
                let probeGeneration,
                let success,
                let nowUptimeNs
            ):
                guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return [] }
                guard state.upstreamStates[upstreamIndex].healthProbeGeneration == probeGeneration else {
                    return []
                }
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
                if success {
                    state.upstreamStates[upstreamIndex].healthState = .healthy
                    state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
                } else {
                    state.upstreamStates[upstreamIndex].healthState = .quarantined(
                        untilUptimeNs: nowUptimeNs &+ 15_000_000_000
                    )
                }
                return success ? [] : [.failQueuedIfNoRecovery]

            case .toolsListRefreshSucceeded(let upstreamIndex, let nowUptimeNs):
                guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return [] }
                state.upstreamStates[upstreamIndex].healthState = .healthy
                state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
                state.upstreamStates[upstreamIndex].healthProbeInFlight = false
                state.upstreamStates[upstreamIndex].consecutiveToolsListFailures = 0
                state.upstreamStates[upstreamIndex].lastToolsListSuccessUptimeNs = nowUptimeNs
                return []
            }
        }
    }

    private static func classifyHealthAndCollectEffectsIfNeeded(
        upstreamIndex: Int,
        nowUptimeNs: UInt64,
        state: inout State,
        effects: inout [UpstreamHealthManager.Effect]
    ) -> UpstreamHealthState {
        guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else {
            return .quarantined(untilUptimeNs: nowUptimeNs)
        }
        let current = state.upstreamStates[upstreamIndex].healthState
        switch current {
        case .healthy:
            return .healthy
        case .degraded:
            return .degraded
        case .quarantined(let untilUptimeNs):
            if nowUptimeNs < untilUptimeNs {
                return .quarantined(untilUptimeNs: untilUptimeNs)
            }
            if state.upstreamStates[upstreamIndex].healthProbeInFlight == false {
                state.upstreamStates[upstreamIndex].healthProbeInFlight = true
                state.upstreamStates[upstreamIndex].healthProbeGeneration &+= 1
                effects.append(
                    .startHealthProbe(UpstreamHealthManager.ProbeRequest(
                        upstreamIndex: upstreamIndex,
                        probeGeneration: state.upstreamStates[upstreamIndex].healthProbeGeneration
                    ))
                )
            }
            return .quarantined(untilUptimeNs: untilUptimeNs)
        }
    }
}
