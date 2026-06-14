import Foundation
import NIO
import NIOConcurrencyHelpers
import ProxyCore
import ProxyMCP

package final class InitializeManager: Sendable {
    package enum PrimaryInitializePhase: Sendable, Equatable {
        case idle
        case pendingSend
        case sent(upstreamID: Int64)

        var isInFlight: Bool {
            switch self {
            case .idle:
                return false
            case .pendingSend, .sent:
                return true
            }
        }

        var upstreamID: Int64? {
            guard case .sent(let upstreamID) = self else { return nil }
            return upstreamID
        }
    }

    package enum WarmInitRecoveryIntent: Sendable, Equatable {
        case none
        case retryPrimaryWhenNoCachedInitialize
    }

    package enum WarmInitRecoveryConsumptionPolicy: Sendable {
        case onlyWithoutCachedInitialize
        case regardlessOfCachedInitialize
    }

    package struct PendingInitialize: Sendable {
        package let eventLoop: EventLoop
        package let promise: EventLoopPromise<ByteBuffer>
        package let sessionID: String
        package let sessionGeneration: UInt64
        package let originalID: RPCID
    }

    package struct RegisterDecision: Sendable {
        package let promise: EventLoopPromise<ByteBuffer>?
        package let cachedResult: JSONValue?
        package let shouldSendRequest: Bool
        package let shouldScheduleTimeout: Bool
        package let isShuttingDown: Bool
    }

    package struct SuccessPreparation: Sendable {
        package let timeout: RuntimeScheduledTimeout?
        package let shouldWarmSecondary: Bool
        package let cachedResult: JSONValue?
    }

    package struct FailureResult: Sendable {
        package let pending: [PendingInitialize]
        package let timeout: RuntimeScheduledTimeout?
        package let upstreamID: Int64?
        package let shouldRetryEagerInitialize: Bool
    }

    package struct ExitResult: Sendable {
        package let pending: [PendingInitialize]
        package let timeout: RuntimeScheduledTimeout?
        package let hadGlobalInit: Bool
        package let wasInFlight: Bool
        package let primaryInitUpstreamID: Int64?
    }

    package struct Snapshot: Sendable {
        package let hasInitResult: Bool
        package let initInFlight: Bool
        package let didWarmSecondary: Bool
        package let shouldRetryEagerInitializePrimaryAfterWarmInitFailure: Bool
        package let isShuttingDown: Bool
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

    package init(brokerState: CanonicalBrokerState) {
        self.brokerState = brokerState
    }

    package func beginShutdown() -> (pending: [PendingInitialize], timeout: RuntimeScheduledTimeout?) {
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

    package func isInitialized() -> Bool {
        brokerState.initializeResult() != nil
    }

    package func beginEagerInitializePrimary() -> (
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
            state.primaryInitializePhase = .pendingSend
            return (true, true)
        }
    }

    package func beginPrimaryInitializeSend(upstreamID: Int64) -> Bool {
        state.withLockedValue { state in
            guard !state.isShuttingDown,
                  brokerState.initializeResult() == nil,
                  state.primaryInitializePhase == .pendingSend
            else {
                return false
            }
            state.primaryInitializePhase = .sent(upstreamID: upstreamID)
            return true
        }
    }

    package func registerInitialize(
        sessionID: String,
        sessionGeneration: UInt64,
        originalID: RPCID,
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

            state.primaryInitializePhase = .pendingSend
            return RegisterDecision(
                promise: promise,
                cachedResult: nil,
                shouldSendRequest: true,
                shouldScheduleTimeout: true,
                isShuttingDown: false
            )
        }
    }

    package func preparePrimaryInitializeSuccess() -> SuccessPreparation? {
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

    package func finishPrimaryInitializeSuccess() -> [PendingInitialize]? {
        state.withLockedValue { state in
            guard !state.isShuttingDown else { return nil }
            state.primaryInitializePhase = .idle
            state.warmInitRecoveryIntent = .none
            let pending = state.initPending
            state.initPending.removeAll()
            return pending
        }
    }

    package func finishPrimaryInitializeUsingCachedResult() -> (pending: [PendingInitialize], result: JSONValue)? {
        state.withLockedValue { state in
            guard !state.isShuttingDown, let result = brokerState.initializeResult() else { return nil }
            state.primaryInitializePhase = .idle
            let pending = state.initPending
            state.initPending.removeAll()
            return (pending, result)
        }
    }

    package func reopenPrimaryInitializeForRetry() {
        state.withLockedValue { state in
            state.primaryInitializePhase = .idle
        }
    }

    package func markSecondaryWarmupStarted() {
        state.withLockedValue { state in
            state.didWarmSecondary = true
        }
    }

    package func completePrimaryInitializeFailure() -> FailureResult? {
        state.withLockedValue { state in
            guard !state.isShuttingDown else { return nil }
            let shouldRetryEagerInitialize = consumeWarmInitRecoveryIntentLocked(
                state: &state,
                policy: .onlyWithoutCachedInitialize
            )
            let upstreamID = state.primaryInitializePhase.upstreamID
            let timeout = state.initTimeout
            state.primaryInitializePhase = .idle
            state.initTimeout = nil
            let pending = state.initPending
            state.initPending.removeAll()
            return FailureResult(
                pending: pending,
                timeout: timeout,
                upstreamID: upstreamID,
                shouldRetryEagerInitialize: shouldRetryEagerInitialize
            )
        }
    }

    package func replaceInitTimeout(_ timeout: RuntimeScheduledTimeout) -> RuntimeScheduledTimeout? {
        state.withLockedValue { state in
            let existing = state.initTimeout
            state.initTimeout = timeout
            return existing
        }
    }

    package func handleUpstreamExit(upstreamIndex: Int) -> ExitResult? {
        state.withLockedValue { state in
            guard !state.isShuttingDown else { return nil }
            let result = ExitResult(
                pending: state.initPending,
                timeout: state.initTimeout,
                hadGlobalInit: brokerState.initializeResult() != nil,
                wasInFlight: state.primaryInitializePhase.isInFlight,
                primaryInitUpstreamID: state.primaryInitializePhase.upstreamID
            )

            if upstreamIndex == 0, state.primaryInitializePhase.isInFlight {
                state.primaryInitializePhase = .idle
                state.initTimeout = nil
                state.initPending.removeAll()
            }

            return result
        }
    }

    package func resetWarmSecondaryForRetry() {
        state.withLockedValue { state in
            state.didWarmSecondary = false
        }
    }

    package func resetForDebug() -> (pending: [PendingInitialize], timeout: RuntimeScheduledTimeout?) {
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

    package func setWarmInitRecoveryIntent(_ intent: WarmInitRecoveryIntent) {
        state.withLockedValue { state in
            state.warmInitRecoveryIntent = intent
        }
    }

    package func consumeWarmInitRecoveryIntent(
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

    package func snapshot() -> Snapshot {
        state.withLockedValue { state in
            Snapshot(
                hasInitResult: brokerState.initializeResult() != nil,
                initInFlight: state.primaryInitializePhase.isInFlight,
                didWarmSecondary: state.didWarmSecondary,
                shouldRetryEagerInitializePrimaryAfterWarmInitFailure: state
                    .warmInitRecoveryIntent == .retryPrimaryWhenNoCachedInitialize,
                isShuttingDown: state.isShuttingDown
            )
        }
    }

    package func pendingInitializes() -> [PendingInitialize] {
        state.withLockedValue { $0.initPending }
    }
}
