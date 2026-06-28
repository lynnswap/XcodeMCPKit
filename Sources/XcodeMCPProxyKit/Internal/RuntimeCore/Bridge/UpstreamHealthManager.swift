import XcodeMCPCore
import XcodeMCPProcessRuntime
import Foundation
import NIO
import NIOConcurrencyHelpers

final class UpstreamHealthManager: Sendable {
    struct ProbeRequest: Sendable {
        let upstreamIndex: Int
        let probeGeneration: UInt64
    }

    enum Effect: Sendable {
        case cancelInitTimeout(RuntimeScheduledTimeout)
        case startHealthProbe(UpstreamHealthManager.ProbeRequest)
        case clearPins
        case failQueuedIfNoRecovery
    }

    struct UseEvaluation: Sendable {
        let isUsable: Bool
        let effects: [UpstreamHealthManager.Effect]

        init(isUsable: Bool, effects: [UpstreamHealthManager.Effect]) {
            self.isUsable = isUsable
            self.effects = effects
        }
    }

    struct SelectionResult: Sendable {
        let upstreamIndex: Int?
        let effects: [UpstreamHealthManager.Effect]

        init(upstreamIndex: Int?, effects: [UpstreamHealthManager.Effect]) {
            self.upstreamIndex = upstreamIndex
            self.effects = effects
        }
    }

    struct ProtocolViolationTransition: Sendable {
        let quarantineUntil: UInt64
        let cancelledInitTimeout: RuntimeScheduledTimeout?
    }

    struct IncompatibilityTransition: Sendable {
        let quarantineUntil: UInt64
        let cancelledInitTimeout: RuntimeScheduledTimeout?
        let initUpstreamID: Int64?
    }

    struct MarkInitializedTransition: Sendable {
        let timeout: RuntimeScheduledTimeout?
    }

    enum InitPhase: Sendable, Equatable {
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

    enum Event: Sendable {
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

    struct UpstreamState: Sendable {
        var initPhase: InitPhase = .idle
        var initTimeout: RuntimeScheduledTimeout?
        var didSendInitialized = false
        var healthState: Upstream.HealthState = .healthy
        var consecutiveRequestTimeouts = 0
        var healthProbeInFlight = false
        var healthProbeGeneration: UInt64 = 0
        var consecutiveToolsListFailures: Int = 0
        var lastToolsListSuccessUptimeNs: UInt64?
        var requestPickCount: Int = 0

        var isInitialized: Bool {
            get { initPhase.isInitialized }
            set {
                if newValue {
                    initPhase = .initialized
                } else if initPhase.isInitialized {
                    initPhase = .idle
                }
            }
        }

        var initInFlight: Bool {
            get { initPhase.isInFlight }
            set {
                if newValue {
                    initPhase = .initializing(upstreamID: initPhase.upstreamID)
                } else if initPhase.isInFlight {
                    initPhase = .idle
                }
            }
        }

        var initUpstreamID: Int64? {
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

    init(upstreamCount: Int) {
        self.state = NIOLockedValueBox(State(
            upstreamStates: Array(repeating: UpstreamState(), count: upstreamCount),
            nextPick: 0
        ))
    }

    func statesSnapshot() -> [UpstreamState] {
        state.withLockedValue { $0.upstreamStates }
    }

    func count() -> Int {
        state.withLockedValue { $0.upstreamStates.count }
    }

    func clearInitTimeoutsForShutdown() -> [RuntimeScheduledTimeout?] {
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

    func anyInitialized() -> Bool {
        state.withLockedValue { $0.upstreamStates.contains { $0.isInitialized } }
    }

    func primaryInitInFlight() -> Bool {
        state.withLockedValue { state in
            guard !state.upstreamStates.isEmpty else { return false }
            return state.upstreamStates[0].initInFlight
        }
    }

    func anyRecoveryInFlight() -> Bool {
        state.withLockedValue { state in
            state.upstreamStates.contains { $0.initInFlight || $0.healthProbeInFlight }
        }
    }

    func initializedHealthyishCount() -> Int {
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

    func evaluateUsableInitialized(
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

    func chooseBestInitializedUpstream(
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

    func markRequestSucceeded(upstreamIndex: Int) {
        _ = apply(event: .requestSucceeded(upstreamIndex: upstreamIndex))
    }

    func markUpstreamOverloaded(upstreamIndex: Int) -> Bool {
        apply(event: .upstreamOverloaded(upstreamIndex: upstreamIndex)).isEmpty == false
    }

    func markRequestTimedOut(upstreamIndex: Int, nowUptimeNs: UInt64) -> (shouldClearPins: Bool, timeoutCount: Int) {
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

    func markProtocolViolation(
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

    func quarantineIncompatibleUpstream(
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

    func finishHealthProbe(
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

    func markToolsListRefreshSucceeded(upstreamIndex: Int, nowUptimeNs: UInt64) {
        _ = apply(event: .toolsListRefreshSucceeded(
            upstreamIndex: upstreamIndex,
            nowUptimeNs: nowUptimeNs
        ))
    }

    func markToolsListRefreshFailed(upstreamIndex: Int, nowUptimeNs: UInt64) -> (failures: Int, quarantineUntil: UInt64)? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            let quarantineUntil = nowUptimeNs &+ 30 * 1_000_000_000
            state.upstreamStates[upstreamIndex].healthState = .quarantined(untilUptimeNs: quarantineUntil)
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            state.upstreamStates[upstreamIndex].consecutiveToolsListFailures += 1
            return (state.upstreamStates[upstreamIndex].consecutiveToolsListFailures, quarantineUntil)
        }
    }

    func shouldSendInitializedNotification(upstreamIndex: Int) -> Bool {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else {
                return false
            }
            return state.upstreamStates[upstreamIndex].didSendInitialized == false
        }
    }

    func markInitializedNotificationSent(
        upstreamIndex: Int,
        expectedUpstreamID: Int64
    ) -> Bool {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else {
                return false
            }
            guard state.upstreamStates[upstreamIndex].initUpstreamID == expectedUpstreamID else {
                return false
            }
            state.upstreamStates[upstreamIndex].didSendInitialized = true
            return true
        }
    }

    func initializeAttemptMatches(
        upstreamIndex: Int,
        expectedUpstreamID: Int64
    ) -> Bool {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else {
                return false
            }
            return state.upstreamStates[upstreamIndex].initUpstreamID == expectedUpstreamID
        }
    }

    func resetForDebug() -> [RuntimeScheduledTimeout?] {
        state.withLockedValue { state in
            let timeouts = state.upstreamStates.map(\.initTimeout)
            state.upstreamStates = Array(repeating: UpstreamState(), count: state.upstreamStates.count)
            state.nextPick = 0
            return timeouts
        }
    }

    func beginWarmInitialize(upstreamIndex: Int) -> Bool {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return false }
            if state.upstreamStates[upstreamIndex].isInitialized || state.upstreamStates[upstreamIndex].initInFlight {
                return false
            }
            state.upstreamStates[upstreamIndex].initInFlight = true
            return true
        }
    }

    func setWarmInitializeUpstreamID(_ upstreamID: Int64, for upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].initUpstreamID = upstreamID
        }
    }

    func replaceInitTimeout(
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

    func clearWarmInitializeIfMatching(upstreamIndex: Int, upstreamID: Int64) -> Bool {
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

    func markInitInFlight(upstreamIndex: Int, upstreamID: Int64) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].initInFlight = true
            state.upstreamStates[upstreamIndex].initUpstreamID = upstreamID
            state.upstreamStates[upstreamIndex].isInitialized = false
        }
    }

    func clearInitInFlight(upstreamIndex: Int) {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return }
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].initUpstreamID = nil
            state.upstreamStates[upstreamIndex].initTimeout = nil
        }
    }

    func clearUpstreamState(upstreamIndex: Int) -> (
        timeout: RuntimeScheduledTimeout?,
        initUpstreamID: Int64?
    )? {
        clearUpstreamState(upstreamIndex: upstreamIndex, expectedUpstreamID: nil)
    }

    func clearUpstreamState(
        upstreamIndex: Int,
        expectedUpstreamID: Int64?
    ) -> (
        timeout: RuntimeScheduledTimeout?,
        initUpstreamID: Int64?
    )? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            if let expectedUpstreamID,
               state.upstreamStates[upstreamIndex].initUpstreamID != expectedUpstreamID
            {
                return nil
            }
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

    func markInitialized(upstreamIndex: Int) -> UpstreamHealthManager.MarkInitializedTransition? {
        markInitialized(upstreamIndex: upstreamIndex, expectedUpstreamID: nil)
    }

    func markInitialized(
        upstreamIndex: Int,
        expectedUpstreamID: Int64?
    ) -> UpstreamHealthManager.MarkInitializedTransition? {
        state.withLockedValue { state in
            guard upstreamIndex >= 0, upstreamIndex < state.upstreamStates.count else { return nil }
            if let expectedUpstreamID,
               state.upstreamStates[upstreamIndex].initUpstreamID != expectedUpstreamID
            {
                return nil
            }
            state.upstreamStates[upstreamIndex].isInitialized = true
            state.upstreamStates[upstreamIndex].initInFlight = false
            state.upstreamStates[upstreamIndex].initUpstreamID = nil
            state.upstreamStates[upstreamIndex].healthState = .healthy
            state.upstreamStates[upstreamIndex].consecutiveRequestTimeouts = 0
            state.upstreamStates[upstreamIndex].healthProbeInFlight = false
            let timeout = state.upstreamStates[upstreamIndex].initTimeout
            state.upstreamStates[upstreamIndex].initTimeout = nil
            return UpstreamHealthManager.MarkInitializedTransition(timeout: timeout)
        }
    }

    func debugHealthStateString(_ state: Upstream.HealthState) -> String {
        switch state {
        case .healthy:
            return "healthy"
        case .degraded:
            return "degraded"
        case .quarantined(let untilUptimeNs):
            return "quarantined(untilUptimeNs:\(untilUptimeNs))"
        }
    }

    func apply(event: Event) -> [UpstreamHealthManager.Effect] {
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
    ) -> Upstream.HealthState {
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
