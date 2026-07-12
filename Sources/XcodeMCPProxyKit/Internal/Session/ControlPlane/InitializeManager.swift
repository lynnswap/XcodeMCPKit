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

    struct SuccessCompletion: Sendable {
        let pending: [PendingInitialize]
        let result: JSONValue
        let timeout: RuntimeScheduledTimeout?
        let recoveryTimeout: RuntimeScheduledTimeout?
        let shouldWarmSecondary: Bool
    }

    struct ParticipantCompletion: Sendable {
        let commit: CanonicalHandshakeState.InitializeCommit
        let publication: SuccessCompletion?
    }

    struct SupportEligibilityCompletion: Sendable {
        let update: CanonicalHandshakeState.SupportEligibilityUpdate
        let publication: SuccessCompletion?
    }

    struct PendingRecoveryLease: Sendable, Hashable {
        fileprivate let generation: UInt64
    }

    struct PendingRecoveryPreparation: Sendable {
        let lease: PendingRecoveryLease
        let recovery: UpstreamHealthManager.QuarantineRecoveryLease
        let replacedTimeout: RuntimeScheduledTimeout?
    }

    struct PendingRecoveryTimeoutAttachment: Sendable {
        let accepted: Bool
        let replaced: RuntimeScheduledTimeout?
    }

    struct FailureResult: Sendable {
        let pending: [PendingInitialize]
        let timeout: RuntimeScheduledTimeout?
        let recoveryTimeout: RuntimeScheduledTimeout?
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
        let recoveryTimeout: RuntimeScheduledTimeout?
        let cancelledPrimaryUpstreamIndex: Int?
        let cancelledPrimaryUpstreamID: Int64?
        let cancelledPrimaryReadinessToken: UpstreamReadinessWaiterToken?
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
        var primaryInitializeRequiresPendingWaiter = false
        var primaryInitializeReadinessToken: UpstreamReadinessWaiterToken?
        var cancelledPrimaryInitializeAttempts: [CancelledPrimaryInitializeAttempt] = []
        var initTimeout: RuntimeScheduledTimeout?
        var isShuttingDown = false
        var didWarmSecondary = false
        var warmInitRecoveryIntent: WarmInitRecoveryIntent = .none
        var pendingRecoveryGeneration: UInt64 = 0
        var pendingRecoveryTimeout: RuntimeScheduledTimeout?
    }

    private struct CancelledPrimaryInitializeAttempt: Sendable, Equatable {
        let upstreamIndex: Int
        let upstreamID: Int64
    }

    private let state = NIOLockedValueBox(State())
    /// Single owner of the cached initialize result. This manager only
    /// tracks in-flight/pending handshake state; the cached result lives in
    /// the canonical broker state so there is exactly one store to clear.
    private let brokerState: CanonicalHandshakeState

    init(brokerState: CanonicalHandshakeState) {
        self.brokerState = brokerState
    }

    func beginShutdown() -> (
        pending: [PendingInitialize],
        timeout: RuntimeScheduledTimeout?,
        recoveryTimeout: RuntimeScheduledTimeout?
    ) {
        state.withLockedValue { state in
            let recoveryTimeout = Self.invalidatePendingRecovery(state: &state)
            state.isShuttingDown = true
            state.primaryInitializePhase = .idle
            state.primaryInitializeRequiresPendingWaiter = false
            state.primaryInitializeReadinessToken = nil
            state.cancelledPrimaryInitializeAttempts.removeAll()
            let pending = state.initPending
            state.initPending.removeAll()
            let timeout = state.initTimeout
            state.initTimeout = nil
            return (pending, timeout, recoveryTimeout)
        }
    }

    func removePendingInitializes(sessionID: String) -> PendingRemovalResult {
        state.withLockedValue { state in
            let removed = state.initPending.filter { $0.sessionID == sessionID }
            guard removed.isEmpty == false else {
                return PendingRemovalResult(
                    pending: [],
                    timeout: nil,
                    recoveryTimeout: nil,
                    cancelledPrimaryUpstreamIndex: nil,
                    cancelledPrimaryUpstreamID: nil,
                    cancelledPrimaryReadinessToken: nil
                )
            }
            state.initPending.removeAll { $0.sessionID == sessionID }
            let timeout: RuntimeScheduledTimeout?
            let recoveryTimeout: RuntimeScheduledTimeout?
            let cancelledPrimaryUpstreamIndex: Int?
            let cancelledPrimaryUpstreamID: Int64?
            let cancelledPrimaryReadinessToken: UpstreamReadinessWaiterToken?
            if state.initPending.isEmpty {
                recoveryTimeout = Self.invalidatePendingRecovery(state: &state)
                if state.primaryInitializeRequiresPendingWaiter {
                    switch state.primaryInitializePhase {
                    case .pendingSend(let upstreamIndex):
                        cancelledPrimaryUpstreamIndex = upstreamIndex
                        cancelledPrimaryUpstreamID = nil
                    case .sent(let upstreamIndex, let upstreamID):
                        cancelledPrimaryUpstreamIndex = upstreamIndex
                        cancelledPrimaryUpstreamID = upstreamID
                        recordCancelledPrimaryInitializeAttemptLocked(
                            upstreamIndex: upstreamIndex,
                            upstreamID: upstreamID,
                            state: &state
                        )
                    case .idle:
                        cancelledPrimaryUpstreamIndex = nil
                        cancelledPrimaryUpstreamID = nil
                    }
                    cancelledPrimaryReadinessToken = state.primaryInitializeReadinessToken
                    state.primaryInitializePhase = .idle
                    state.primaryInitializeRequiresPendingWaiter = false
                    state.primaryInitializeReadinessToken = nil
                    timeout = state.initTimeout
                    state.initTimeout = nil
                } else if state.primaryInitializePhase.isInFlight == false {
                    cancelledPrimaryUpstreamIndex = nil
                    cancelledPrimaryUpstreamID = nil
                    cancelledPrimaryReadinessToken = nil
                    timeout = state.initTimeout
                    state.initTimeout = nil
                } else {
                    cancelledPrimaryUpstreamIndex = nil
                    cancelledPrimaryUpstreamID = nil
                    cancelledPrimaryReadinessToken = nil
                    timeout = nil
                }
            } else {
                recoveryTimeout = nil
                cancelledPrimaryUpstreamIndex = nil
                cancelledPrimaryUpstreamID = nil
                cancelledPrimaryReadinessToken = nil
                timeout = nil
            }
            return PendingRemovalResult(
                pending: removed,
                timeout: timeout,
                recoveryTimeout: recoveryTimeout,
                cancelledPrimaryUpstreamIndex: cancelledPrimaryUpstreamIndex,
                cancelledPrimaryUpstreamID: cancelledPrimaryUpstreamID,
                cancelledPrimaryReadinessToken: cancelledPrimaryReadinessToken
            )
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
            state.primaryInitializeRequiresPendingWaiter = state.initPending.isEmpty == false
            state.primaryInitializeReadinessToken = nil
            return (true, state.initTimeout == nil)
        }
    }

    func setPrimaryInitializeReadinessToken(_ token: UpstreamReadinessWaiterToken) -> Bool {
        state.withLockedValue { state in
            guard !state.isShuttingDown,
                  case .pendingSend = state.primaryInitializePhase
            else {
                return false
            }
            state.primaryInitializeReadinessToken = token
            return true
        }
    }

    func clearPrimaryInitializeReadinessToken(_ token: UpstreamReadinessWaiterToken) {
        state.withLockedValue { state in
            if state.primaryInitializeReadinessToken === token {
                state.primaryInitializeReadinessToken = nil
            }
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
            state.primaryInitializeReadinessToken = nil
            return true
        }
    }

    func yieldPrimaryInitializeToRouteActivation(
        upstreamIndex: Int,
        upstreamID: Int64? = nil
    ) -> Bool {
        state.withLockedValue { state in
            let matches: Bool
            switch state.primaryInitializePhase {
            case .pendingSend(let currentUpstreamIndex):
                matches = currentUpstreamIndex == upstreamIndex && upstreamID == nil
            case .sent(let currentUpstreamIndex, let currentUpstreamID):
                matches = currentUpstreamIndex == upstreamIndex
                    && currentUpstreamID == upstreamID
            case .idle:
                matches = false
            }
            guard matches else { return false }
            state.primaryInitializePhase = .idle
            state.primaryInitializeRequiresPendingWaiter = false
            state.primaryInitializeReadinessToken = nil
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
            state.primaryInitializeRequiresPendingWaiter = true
            state.primaryInitializeReadinessToken = nil
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
            state.primaryInitializeRequiresPendingWaiter = true
            state.primaryInitializeReadinessToken = nil
            return true
        }
    }

    /// Runs the topology/health/canonical commit while holding the same lock
    /// that owns downstream initialize waiters. A timeout can win before this
    /// transaction starts, or publication can win and drain the waiters, but
    /// it cannot fail them between canonical publication and waiter delivery.
    func finishInitializeParticipant(
        commit: () -> CanonicalHandshakeState.InitializeCommit
    ) -> ParticipantCompletion {
        state.withLockedValue { state in
            guard !state.isShuttingDown else {
                return ParticipantCompletion(commit: .stale, publication: nil)
            }
            let initializeCommit = commit()
            guard case .published(let publishedResult, _) = initializeCommit else {
                return ParticipantCompletion(
                    commit: initializeCommit,
                    publication: nil
                )
            }
            state.primaryInitializePhase = .idle
            state.primaryInitializeRequiresPendingWaiter = false
            state.primaryInitializeReadinessToken = nil
            state.warmInitRecoveryIntent = .none
            let recoveryTimeout = Self.invalidatePendingRecovery(state: &state)
            let shouldWarmSecondary = !state.didWarmSecondary
            state.didWarmSecondary = true
            let pending = state.initPending
            state.initPending.removeAll()
            let timeout = state.initTimeout
            state.initTimeout = nil
            return ParticipantCompletion(
                commit: initializeCommit,
                publication: SuccessCompletion(
                    pending: pending,
                    result: publishedResult,
                    timeout: timeout,
                    recoveryTimeout: recoveryTimeout,
                    shouldWarmSecondary: shouldWarmSecondary
                )
            )
        }
    }

    /// Serializes health eligibility changes with downstream initialize
    /// registration. The supplied closure must follow the established lock
    /// order: authoritative topology -> health -> canonical handshake.
    func finishSupportEligibilityUpdate(
        commit: () -> CanonicalHandshakeState.SupportEligibilityUpdate?
    ) -> SupportEligibilityCompletion? {
        state.withLockedValue { state in
            guard !state.isShuttingDown, let update = commit() else { return nil }
            guard update.becameAvailable,
                  let exposedResult = update.exposedResult else {
                return SupportEligibilityCompletion(update: update, publication: nil)
            }
            state.primaryInitializePhase = .idle
            state.primaryInitializeRequiresPendingWaiter = false
            state.primaryInitializeReadinessToken = nil
            state.warmInitRecoveryIntent = .none
            let recoveryTimeout = Self.invalidatePendingRecovery(state: &state)
            let pending = state.initPending
            state.initPending.removeAll()
            let timeout = state.initTimeout
            state.initTimeout = nil
            return SupportEligibilityCompletion(
                update: update,
                publication: SuccessCompletion(
                    pending: pending,
                    result: exposedResult,
                    timeout: timeout,
                    recoveryTimeout: recoveryTimeout,
                    shouldWarmSecondary: false
                )
            )
        }
    }

    func finishPrimaryInitializeUsingCachedResult() -> (
        pending: [PendingInitialize],
        result: JSONValue,
        timeout: RuntimeScheduledTimeout?,
        recoveryTimeout: RuntimeScheduledTimeout?
    )? {
        state.withLockedValue { state in
            guard !state.isShuttingDown, let result = brokerState.initializeResult() else { return nil }
            state.primaryInitializePhase = .idle
            state.primaryInitializeRequiresPendingWaiter = false
            state.primaryInitializeReadinessToken = nil
            let recoveryTimeout = Self.invalidatePendingRecovery(state: &state)
            let pending = state.initPending
            state.initPending.removeAll()
            let timeout = state.initTimeout
            state.initTimeout = nil
            return (pending, result, timeout, recoveryTimeout)
        }
    }

    func reopenPrimaryInitializeForRetry() {
        state.withLockedValue { state in
            state.primaryInitializePhase = .idle
            state.primaryInitializeRequiresPendingWaiter = false
            state.primaryInitializeReadinessToken = nil
        }
    }

    func completePrimaryInitializeFailure() -> FailureResult? {
        state.withLockedValue { state in
            guard !state.isShuttingDown else { return nil }
            let recoveryTimeout = Self.invalidatePendingRecovery(state: &state)
            let shouldRetryEagerInitialize = consumeWarmInitRecoveryIntentLocked(
                state: &state,
                policy: .onlyWithoutCachedInitialize
            )
            let upstreamID = state.primaryInitializePhase.upstreamID
            let upstreamIndex = state.primaryInitializePhase.upstreamIndex
            let timeout = state.initTimeout
            state.primaryInitializePhase = .idle
            state.primaryInitializeRequiresPendingWaiter = false
            state.primaryInitializeReadinessToken = nil
            state.initTimeout = nil
            let pending = state.initPending
            state.initPending.removeAll()
            return FailureResult(
                pending: pending,
                timeout: timeout,
                recoveryTimeout: recoveryTimeout,
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

    /// Re-arms the init timeout for a retry attempt, but only while pending
    /// initializes remain unresolved. A retry with no waiters (e.g. after
    /// pending initializes were satisfied from the cached result) must not
    /// leave a global timer armed: a stale timer would stop the next eager
    /// attempt from arming its own fresh window and could fail it early.
    /// Returns the timeout the caller must cancel.
    func rearmInitTimeoutForRetry(
        makeTimeout: () -> RuntimeScheduledTimeout?
    ) -> RuntimeScheduledTimeout? {
        state.withLockedValue { state in
            guard state.initPending.isEmpty == false else {
                let stale = state.initTimeout
                state.initTimeout = nil
                return stale
            }
            guard let timeout = makeTimeout() else {
                return nil
            }
            let previous = state.initTimeout
            state.initTimeout = timeout
            return previous
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
                state.primaryInitializeRequiresPendingWaiter = false
                state.primaryInitializeReadinessToken = nil
            }

            return result
        }
    }

    func resetWarmSecondaryForRetry() {
        state.withLockedValue { state in
            state.didWarmSecondary = false
        }
    }

    func resetForDebug() -> (
        pending: [PendingInitialize],
        timeout: RuntimeScheduledTimeout?,
        recoveryTimeout: RuntimeScheduledTimeout?
    ) {
        state.withLockedValue { state in
            let recoveryTimeout = Self.invalidatePendingRecovery(state: &state)
            let result = (
                pending: state.initPending,
                timeout: state.initTimeout,
                recoveryTimeout: recoveryTimeout
            )
            state.initPending.removeAll()
            state.primaryInitializePhase = .idle
            state.primaryInitializeRequiresPendingWaiter = false
            state.primaryInitializeReadinessToken = nil
            state.cancelledPrimaryInitializeAttempts.removeAll()
            state.initTimeout = nil
            state.isShuttingDown = false
            state.didWarmSecondary = false
            state.warmInitRecoveryIntent = .none
            // Debug reset must clear the cached result while initialize
            // registration is still excluded by this lock. Clearing it later
            // would let a concurrent registration observe the pre-reset cache.
            brokerState.clearInitialize()
            return result
        }
    }

    func preparePendingQuarantineRecovery(
        recovery: () -> UpstreamHealthManager.QuarantineRecoveryLease?
    ) -> PendingRecoveryPreparation? {
        state.withLockedValue { state in
            guard !state.isShuttingDown,
                  state.initPending.isEmpty == false,
                  brokerState.initializeResult() == nil,
                  let recovery = recovery() else { return nil }
            state.pendingRecoveryGeneration &+= 1
            let lease = PendingRecoveryLease(generation: state.pendingRecoveryGeneration)
            let replacedTimeout = state.pendingRecoveryTimeout
            state.pendingRecoveryTimeout = nil
            return PendingRecoveryPreparation(
                lease: lease,
                recovery: recovery,
                replacedTimeout: replacedTimeout
            )
        }
    }

    func attachPendingQuarantineRecoveryTimeout(
        _ timeout: RuntimeScheduledTimeout,
        lease: PendingRecoveryLease
    ) -> PendingRecoveryTimeoutAttachment {
        state.withLockedValue { state in
            guard !state.isShuttingDown,
                  state.initPending.isEmpty == false,
                  brokerState.initializeResult() == nil,
                  state.pendingRecoveryGeneration == lease.generation else {
                return PendingRecoveryTimeoutAttachment(accepted: false, replaced: nil)
            }
            let replaced = state.pendingRecoveryTimeout
            state.pendingRecoveryTimeout = timeout
            return PendingRecoveryTimeoutAttachment(accepted: true, replaced: replaced)
        }
    }

    func withPendingQuarantineRecovery<Result>(
        _ lease: PendingRecoveryLease,
        operation: () -> Result?
    ) -> Result? {
        state.withLockedValue { state in
            guard !state.isShuttingDown,
                  state.initPending.isEmpty == false,
                  brokerState.initializeResult() == nil,
                  state.pendingRecoveryGeneration == lease.generation else {
                return nil
            }
            state.pendingRecoveryGeneration &+= 1
            state.pendingRecoveryTimeout = nil
            return operation()
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

    func consumeCancelledPrimaryInitializeAttempt(upstreamIndex: Int, upstreamID: Int64) -> Bool {
        state.withLockedValue { state in
            guard let index = state.cancelledPrimaryInitializeAttempts.firstIndex(
                of: CancelledPrimaryInitializeAttempt(
                    upstreamIndex: upstreamIndex,
                    upstreamID: upstreamID
                )
            ) else {
                return false
            }
            state.cancelledPrimaryInitializeAttempts.remove(at: index)
            return true
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

    private static func invalidatePendingRecovery(
        state: inout State
    ) -> RuntimeScheduledTimeout? {
        state.pendingRecoveryGeneration &+= 1
        let timeout = state.pendingRecoveryTimeout
        state.pendingRecoveryTimeout = nil
        return timeout
    }

    private func recordCancelledPrimaryInitializeAttemptLocked(
        upstreamIndex: Int,
        upstreamID: Int64,
        state: inout State
    ) {
        let attempt = CancelledPrimaryInitializeAttempt(
            upstreamIndex: upstreamIndex,
            upstreamID: upstreamID
        )
        state.cancelledPrimaryInitializeAttempts.removeAll { $0 == attempt }
        state.cancelledPrimaryInitializeAttempts.append(attempt)
        if state.cancelledPrimaryInitializeAttempts.count > 16 {
            state.cancelledPrimaryInitializeAttempts.removeFirst(
                state.cancelledPrimaryInitializeAttempts.count - 16
            )
        }
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
