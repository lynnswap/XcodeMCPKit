import Foundation
import NIO
import NIOConcurrencyHelpers
import XcodeMCPKit

final class InitializeManager: Sendable {
    enum PrimaryInitializePhase: Sendable, Equatable {
        case idle
        case pendingSend(upstreamIndex: Int)
        case sent(upstreamIndex: Int, upstreamID: Int64)

        var isInFlight: Bool {
            switch self {
            case .idle:
                return false
            case .pendingSend, .sent:
                return true
            }
        }

        var upstreamID: Int64? {
            guard case .sent(_, let upstreamID) = self else { return nil }
            return upstreamID
        }

        var upstreamIndex: Int? {
            switch self {
            case .idle:
                return nil
            case .pendingSend(let upstreamIndex), .sent(let upstreamIndex, _):
                return upstreamIndex
            }
        }
    }

    enum WarmInitRecoveryIntent: Sendable, Equatable {
        case none
        case retryPrimaryWhenNoCachedInitialize
    }

    enum WarmInitRecoveryConsumptionPolicy: Sendable {
        case onlyWithoutCachedInitialize
        case regardlessOfCachedInitialize
    }

    struct PendingInitialize: Sendable {
        let eventLoop: EventLoop
        let promise: EventLoopPromise<ByteBuffer>
        let sessionID: String
        let sessionGeneration: UInt64
        let originalID: JSONRPC.ID
    }

    struct RegisterDecision: Sendable {
        let promise: EventLoopPromise<ByteBuffer>?
        let cachedResult: JSONValue?
        let shouldSendRequest: Bool
        let shouldScheduleTimeout: Bool
        let isShuttingDown: Bool
    }

    struct SuccessPreparation: Sendable {
        let timeout: RuntimeScheduledTimeout?
        let shouldWarmSecondary: Bool
        let cachedResult: JSONValue?
    }

    struct FailureResult: Sendable {
        let pending: [PendingInitialize]
        let timeout: RuntimeScheduledTimeout?
        let upstreamIndex: Int?
        let upstreamID: Int64?
        let shouldRetryEagerInitialize: Bool
    }

    struct ExitResult: Sendable {
        let pending: [PendingInitialize]
        let timeout: RuntimeScheduledTimeout?
        let hadGlobalInit: Bool
        let wasInFlight: Bool
        let primaryInitUpstreamIndex: Int?
        let primaryInitUpstreamID: Int64?
    }

    struct PendingRemovalResult: Sendable {
        let pending: [PendingInitialize]
        let timeout: RuntimeScheduledTimeout?
    }

    struct Snapshot: Sendable {
        let hasInitResult: Bool
        let initInFlight: Bool
        let activePrimaryUpstreamIndex: Int?
        let didWarmSecondary: Bool
        let shouldRetryEagerInitializePrimaryAfterWarmInitFailure: Bool
        let isShuttingDown: Bool
    }

    private struct State: Sendable {
        var initPending: [PendingInitialize] = []
        var primaryInitializePhase: PrimaryInitializePhase = .idle
        var initTimeout: RuntimeScheduledTimeout?
        var isShuttingDown = false
        var didWarmSecondary = false
        var warmInitRecoveryIntent: WarmInitRecoveryIntent = .none
    }

    private let state = NIOLockedValueBox(State())
    /// Single owner of the cached initialize result. This manager only
    /// tracks in-flight/pending handshake state; the cached result lives in
    /// the canonical broker state so there is exactly one store to clear.
    private let brokerState: CanonicalBrokerState

    init(brokerState: CanonicalBrokerState) {
        self.brokerState = brokerState
    }

    func beginShutdown() -> (pending: [PendingInitialize], timeout: RuntimeScheduledTimeout?) {
        state.withLockedValue { state in
            state.isShuttingDown = true
            state.primaryInitializePhase = .idle
            let pending = state.initPending
            state.initPending.removeAll()
            let timeout = state.initTimeout
            state.initTimeout = nil
            return (pending, timeout)
        }
    }

    func removePendingInitializes(sessionID: String) -> PendingRemovalResult {
        state.withLockedValue { state in
            let removed = state.initPending.filter { $0.sessionID == sessionID }
            guard removed.isEmpty == false else {
                return PendingRemovalResult(pending: [], timeout: nil)
            }
            state.initPending.removeAll { $0.sessionID == sessionID }
            let timeout: RuntimeScheduledTimeout?
            if state.initPending.isEmpty, state.primaryInitializePhase.isInFlight == false {
                timeout = state.initTimeout
                state.initTimeout = nil
            } else {
                timeout = nil
            }
            return PendingRemovalResult(pending: removed, timeout: timeout)
        }
    }

    func isInitialized() -> Bool {
        brokerState.initializeResult() != nil
    }

    func beginEagerInitializePrimary(upstreamIndex: Int) -> (
        shouldSendRequest: Bool,
        shouldScheduleTimeout: Bool
    ) {
        state.withLockedValue { state in
            guard brokerState.initializeResult() == nil,
                  state.primaryInitializePhase == .idle,
                  !state.isShuttingDown
            else {
                return (false, false)
            }
            state.primaryInitializePhase = .pendingSend(upstreamIndex: upstreamIndex)
            return (true, true)
        }
    }

    func beginPrimaryInitializeSend(upstreamIndex: Int, upstreamID: Int64) -> Bool {
        state.withLockedValue { state in
            guard !state.isShuttingDown,
                  brokerState.initializeResult() == nil,
                  state.primaryInitializePhase == .pendingSend(upstreamIndex: upstreamIndex)
            else {
                return false
            }
            state.primaryInitializePhase = .sent(
                upstreamIndex: upstreamIndex,
                upstreamID: upstreamID
            )
            return true
        }
    }

    func registerInitialize(
        sessionID: String,
        sessionGeneration: UInt64,
        originalID: JSONRPC.ID,
        primaryUpstreamIndex: Int?,
        on eventLoop: EventLoop
    ) -> RegisterDecision {
        state.withLockedValue { state in
            if state.isShuttingDown {
                return RegisterDecision(
                    promise: nil,
                    cachedResult: nil,
                    shouldSendRequest: false,
                    shouldScheduleTimeout: false,
                    isShuttingDown: true
                )
            }

            if let initResult = brokerState.initializeResult() {
                return RegisterDecision(
                    promise: nil,
                    cachedResult: initResult,
                    shouldSendRequest: false,
                    shouldScheduleTimeout: false,
                    isShuttingDown: false
                )
            }

            let hadPendingInitialize = state.initPending.isEmpty == false
            let promise = eventLoop.makePromise(of: ByteBuffer.self)
            state.initPending.append(
                PendingInitialize(
                    eventLoop: eventLoop,
                    promise: promise,
                    sessionID: sessionID,
                    sessionGeneration: sessionGeneration,
                    originalID: originalID
                )
            )

            if state.primaryInitializePhase.isInFlight {
                return RegisterDecision(
                    promise: promise,
                    cachedResult: nil,
                    shouldSendRequest: false,
                    shouldScheduleTimeout: false,
                    isShuttingDown: false
                )
            }

            guard let primaryUpstreamIndex else {
                return RegisterDecision(
                    promise: promise,
                    cachedResult: nil,
                    shouldSendRequest: false,
                    shouldScheduleTimeout: !hadPendingInitialize,
                    isShuttingDown: false
                )
            }

            state.primaryInitializePhase = .pendingSend(upstreamIndex: primaryUpstreamIndex)
            return RegisterDecision(
                promise: promise,
                cachedResult: nil,
                shouldSendRequest: true,
                shouldScheduleTimeout: !hadPendingInitialize,
                isShuttingDown: false
            )
        }
    }

    func pendingPrimaryInitializeUpstreamIndex() -> Int? {
        state.withLockedValue { state in
            guard case .pendingSend(let upstreamIndex) = state.primaryInitializePhase else {
                return nil
            }
            return upstreamIndex
        }
    }

    func activePrimaryInitializeUpstreamIndex() -> Int? {
        state.withLockedValue { $0.primaryInitializePhase.upstreamIndex }
    }

    func primaryInitializeMatches(upstreamIndex: Int, upstreamID: Int64) -> Bool {
        state.withLockedValue { state in
            state.primaryInitializePhase == .sent(
                upstreamIndex: upstreamIndex,
                upstreamID: upstreamID
            )
        }
    }

    func preparePrimaryInitializeRetry(upstreamIndex: Int) -> Bool {
        state.withLockedValue { state in
            guard !state.isShuttingDown,
                  brokerState.initializeResult() == nil,
                  state.primaryInitializePhase == .idle,
                  state.initPending.isEmpty == false
            else {
                return false
            }
            state.primaryInitializePhase = .pendingSend(upstreamIndex: upstreamIndex)
            return true
        }
    }

    func preparePrimaryInitializeSuccess() -> SuccessPreparation? {
        state.withLockedValue { state in
            guard !state.isShuttingDown else { return nil }
            let timeout = state.initTimeout
            state.initTimeout = nil
            let shouldWarmSecondary = !state.didWarmSecondary
            let cachedResult = brokerState.initializeResult()
            return SuccessPreparation(
                timeout: timeout,
                shouldWarmSecondary: shouldWarmSecondary,
                cachedResult: cachedResult
            )
        }
    }

    func finishPrimaryInitializeSuccess() -> [PendingInitialize]? {
        state.withLockedValue { state in
            guard !state.isShuttingDown else { return nil }
            state.primaryInitializePhase = .idle
            state.warmInitRecoveryIntent = .none
            let pending = state.initPending
            state.initPending.removeAll()
            return pending
        }
    }

    func finishPrimaryInitializeUsingCachedResult() -> (pending: [PendingInitialize], result: JSONValue)? {
        state.withLockedValue { state in
            guard !state.isShuttingDown, let result = brokerState.initializeResult() else { return nil }
            state.primaryInitializePhase = .idle
            let pending = state.initPending
            state.initPending.removeAll()
            return (pending, result)
        }
    }

    func reopenPrimaryInitializeForRetry() {
        state.withLockedValue { state in
            state.primaryInitializePhase = .idle
        }
    }

    func markSecondaryWarmupStarted() {
        state.withLockedValue { state in
            state.didWarmSecondary = true
        }
    }

    func completePrimaryInitializeFailure() -> FailureResult? {
        state.withLockedValue { state in
            guard !state.isShuttingDown else { return nil }
            let shouldRetryEagerInitialize = consumeWarmInitRecoveryIntentLocked(
                state: &state,
                policy: .onlyWithoutCachedInitialize
            )
            let upstreamID = state.primaryInitializePhase.upstreamID
            let upstreamIndex = state.primaryInitializePhase.upstreamIndex
            let timeout = state.initTimeout
            state.primaryInitializePhase = .idle
            state.initTimeout = nil
            let pending = state.initPending
            state.initPending.removeAll()
            return FailureResult(
                pending: pending,
                timeout: timeout,
                upstreamIndex: upstreamIndex,
                upstreamID: upstreamID,
                shouldRetryEagerInitialize: shouldRetryEagerInitialize
            )
        }
    }

    func replaceInitTimeout(_ timeout: RuntimeScheduledTimeout) -> RuntimeScheduledTimeout? {
        state.withLockedValue { state in
            let existing = state.initTimeout
            state.initTimeout = timeout
            return existing
        }
    }

    func handleUpstreamExit(upstreamIndex: Int) -> ExitResult? {
        state.withLockedValue { state in
            guard !state.isShuttingDown else { return nil }
            let result = ExitResult(
                pending: state.initPending,
                timeout: state.initTimeout,
                hadGlobalInit: brokerState.initializeResult() != nil,
                wasInFlight: state.primaryInitializePhase.isInFlight,
                primaryInitUpstreamIndex: state.primaryInitializePhase.upstreamIndex,
                primaryInitUpstreamID: state.primaryInitializePhase.upstreamID
            )

            if state.primaryInitializePhase.upstreamIndex == upstreamIndex,
               state.primaryInitializePhase.isInFlight
            {
                state.primaryInitializePhase = .idle
            }

            return result
        }
    }

    func resetWarmSecondaryForRetry() {
        state.withLockedValue { state in
            state.didWarmSecondary = false
        }
    }

    func resetForDebug() -> (pending: [PendingInitialize], timeout: RuntimeScheduledTimeout?) {
        state.withLockedValue { state in
            let result = (pending: state.initPending, timeout: state.initTimeout)
            state.initPending.removeAll()
            state.primaryInitializePhase = .idle
            state.initTimeout = nil
            state.isShuttingDown = false
            state.didWarmSecondary = false
            state.warmInitRecoveryIntent = .none
            return result
        }
    }

    func setWarmInitRecoveryIntent(_ intent: WarmInitRecoveryIntent) {
        state.withLockedValue { state in
            state.warmInitRecoveryIntent = intent
        }
    }

    func consumeWarmInitRecoveryIntent(
        policy: WarmInitRecoveryConsumptionPolicy
    ) -> Bool {
        state.withLockedValue { state in
            consumeWarmInitRecoveryIntentLocked(state: &state, policy: policy)
        }
    }

    private func consumeWarmInitRecoveryIntentLocked(
        state: inout State,
        policy: WarmInitRecoveryConsumptionPolicy
    ) -> Bool {
        guard state.warmInitRecoveryIntent == .retryPrimaryWhenNoCachedInitialize else {
            return false
        }
        switch policy {
        case .onlyWithoutCachedInitialize:
            guard brokerState.initializeResult() == nil else {
                return false
            }
        case .regardlessOfCachedInitialize:
            break
        }
        state.warmInitRecoveryIntent = .none
        return true
    }

    func snapshot() -> Snapshot {
        state.withLockedValue { state in
            Snapshot(
                hasInitResult: brokerState.initializeResult() != nil,
                initInFlight: state.primaryInitializePhase.isInFlight,
                activePrimaryUpstreamIndex: state.primaryInitializePhase.upstreamIndex,
                didWarmSecondary: state.didWarmSecondary,
                shouldRetryEagerInitializePrimaryAfterWarmInitFailure: state
                    .warmInitRecoveryIntent == .retryPrimaryWhenNoCachedInitialize,
                isShuttingDown: state.isShuttingDown
            )
        }
    }

    func pendingInitializes() -> [PendingInitialize] {
        state.withLockedValue { $0.initPending }
    }
}
