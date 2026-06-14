import Foundation
import Logging
import NIO
import ProxyCore
import ProxyMCP
import ProxyXcodeSupport

package struct RefreshCodeIssuesRequest: Sendable {
    package static let toolName = "XcodeRefreshCodeIssuesInFile"
    package static let globalQueueKey = "__global__"

    package let tabIdentifier: String?
    package let filePath: String?

    package init(tabIdentifier: String?, filePath: String?) {
        self.tabIdentifier = tabIdentifier
        self.filePath = filePath
    }

    /// The one place that recognizes this feature's tools/call shape.
    package init?(requestObject object: [String: Any]) {
        guard
            object["method"] as? String == "tools/call",
            let params = object["params"] as? [String: Any],
            params["name"] as? String == Self.toolName
        else {
            return nil
        }
        let arguments = params["arguments"] as? [String: Any]
        self.init(
            tabIdentifier: arguments?["tabIdentifier"] as? String,
            filePath: arguments?["filePath"] as? String
        )
    }

    /// Unwraps a single request object, accepting a batch of exactly one.
    package static func singleRequestObject(from requestJSON: Any) -> [String: Any]? {
        if let object = requestJSON as? [String: Any] {
            return object
        }
        guard let requests = requestJSON as? [Any],
            requests.count == 1,
            let object = requests.first as? [String: Any]
        else {
            return nil
        }
        return object
    }

    package var queueKey: String {
        guard let tabIdentifier, tabIdentifier.isEmpty == false else {
            return Self.globalQueueKey
        }
        return tabIdentifier
    }
}

package enum RefreshForwardAttemptResult: Sendable {
    case success(Data)
    case timeout(responseIDs: [RPCID], isBatch: Bool)
    case upstreamUnavailable(responseIDs: [RPCID], isBatch: Bool)
    case cancelled(responseIDs: [RPCID], isBatch: Bool)
    case invalidRequest
    case invalidUpstreamResponse
}

package enum RefreshInternalToolResult {
    case success([String: Any])
    case timeout
    case cancelled
    case unavailable
}

package struct RefreshCodeIssuesWorkflow {
    package typealias WindowsProvider =
        @Sendable (
            _ sessionID: String,
            _ eventLoop: EventLoop,
            _ upstreamIndexOverride: Int?,
            _ requestTimeoutOverride: TimeAmount?
        ) async throws -> [XcodeWindowInfo]?
    package typealias InternalUpstreamChooser = @Sendable (_ sessionID: String) async -> Int?
    package typealias InternalToolCaller =
        @Sendable (
            _ name: String,
            _ arguments: [String: Any],
            _ sessionID: String,
            _ eventLoop: EventLoop,
            _ upstreamIndexOverride: Int?,
            _ requestTimeoutOverride: TimeAmount?
        ) async -> RefreshInternalToolResult
    package typealias Forwarder =
        @Sendable (
            _ bodyData: Data,
            _ sessionID: String,
            _ requestIDs: [RPCID],
            _ requestIsBatch: Bool,
            _ shouldRequeueLeaseOnRetryableFailure: @Sendable () -> Bool,
            _ eventLoop: EventLoop,
            _ requestTimeoutOverride: TimeAmount?
        ) async -> RefreshForwardAttemptResult

    package static let retryDelaysNanos: [UInt64] = [
        200_000_000,
        500_000_000,
    ]
    package static let minimumUpstreamFallbackBudgetSeconds: TimeInterval = 0.05

    package struct ExecutionBudget: Sendable {
        let deadlineUptimeNs: UInt64?
        let nowUptimeNanoseconds: @Sendable () -> UInt64

        init(
            requestTimeout: TimeInterval,
            requestTimeoutOverride: TimeAmount?,
            clock: ClockClient
        ) {
            self.nowUptimeNanoseconds = clock.uptimeNanoseconds
            if let requestTimeoutOverride, requestTimeoutOverride.nanoseconds > 0 {
                let timeoutNs = UInt64(requestTimeoutOverride.nanoseconds)
                self.deadlineUptimeNs = clock.uptimeNanoseconds() &+ timeoutNs
            } else if requestTimeout > 0 {
                let timeoutNs = Self.nanoseconds(from: requestTimeout)
                self.deadlineUptimeNs = clock.uptimeNanoseconds() &+ timeoutNs
            } else {
                self.deadlineUptimeNs = nil
            }
        }

        func remainingNanoseconds() -> UInt64? {
            guard let deadlineUptimeNs else {
                return nil
            }
            let now = nowUptimeNanoseconds()
            if now >= deadlineUptimeNs {
                return 0
            }
            return deadlineUptimeNs - now
        }

        func remainingTimeout(
            cappedAt capSeconds: TimeInterval? = nil,
            reserving reserveSeconds: TimeInterval = 0
        ) -> TimeAmount? {
            guard let remainingNs = remainingNanoseconds() else {
                return nil
            }
            let reservedNs = Self.nanoseconds(from: reserveSeconds)
            guard remainingNs > reservedNs else { return nil }

            var cappedNs = remainingNs - reservedNs
            if let capSeconds {
                cappedNs = min(cappedNs, Self.nanoseconds(from: capSeconds))
            }
            guard cappedNs > 0 else { return nil }

            let maxTimeAmountNs = UInt64(Int64.max)
            return .nanoseconds(Int64(min(cappedNs, maxTimeAmountNs)))
        }

        func stepTimeout(
            cappedAt capSeconds: TimeInterval,
            reserving reserveSeconds: TimeInterval = 0
        ) -> TimeAmount? {
            remainingTimeout(cappedAt: capSeconds, reserving: reserveSeconds)
        }

        func waitTimeout() -> TimeAmount? {
            guard let remainingNs = remainingNanoseconds() else {
                return nil
            }
            let maxTimeAmountNs = UInt64(Int64.max)
            return .nanoseconds(Int64(min(remainingNs, maxTimeAmountNs)))
        }

        func canDelay(_ delayNanoseconds: UInt64) -> Bool {
            guard let remainingNanoseconds = remainingNanoseconds() else {
                return true
            }
            return remainingNanoseconds > delayNanoseconds
        }

        var isExhausted: Bool {
            guard let remainingNanoseconds = remainingNanoseconds() else {
                return false
            }
            return remainingNanoseconds == 0
        }

        var hasDeadline: Bool {
            deadlineUptimeNs != nil
        }

        private static func nanoseconds(from interval: TimeInterval) -> UInt64 {
            let clamped = max(0, interval)
            let nanoseconds = clamped * 1_000_000_000
            if nanoseconds >= Double(UInt64.max) {
                return UInt64.max
            }
            return UInt64(nanoseconds.rounded(.up))
        }
    }

    package let mode: RefreshCodeIssuesMode
    package let requestTimeout: TimeInterval
    package let coordinator: RefreshCodeIssuesCoordinator
    package let targetResolver: RefreshCodeIssuesTargetResolver
    package let debugState: RefreshCodeIssuesDebugState
    package let windowLookupTimeoutSeconds: TimeInterval
    package let navigatorIssuesTimeoutSeconds: TimeInterval
    package let clock: ClockClient
    package let logger: Logger

    package init(
        mode: RefreshCodeIssuesMode,
        requestTimeout: TimeInterval,
        coordinator: RefreshCodeIssuesCoordinator,
        targetResolver: RefreshCodeIssuesTargetResolver,
        debugState: RefreshCodeIssuesDebugState,
        windowLookupTimeout: TimeInterval = 5,
        navigatorIssuesTimeout: TimeInterval = 15,
        clock: ClockClient = .liveValue,
        logger: Logger
    ) {
        self.mode = mode
        self.requestTimeout = requestTimeout
        self.coordinator = coordinator
        self.targetResolver = targetResolver
        self.debugState = debugState
        self.windowLookupTimeoutSeconds = windowLookupTimeout
        self.navigatorIssuesTimeoutSeconds = navigatorIssuesTimeout
        self.clock = clock
        self.logger = logger
    }

    package func run(
        refreshRequest: RefreshCodeIssuesRequest,
        bodyData: Data,
        sessionID: String,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        requestTimeoutOverride: TimeAmount? = nil,
        eventLoop: EventLoop,
        windowsProvider: @escaping WindowsProvider,
        internalUpstreamChooser: @escaping InternalUpstreamChooser,
        internalToolCaller: @escaping InternalToolCaller,
        forwarder: @escaping Forwarder
    ) async -> RefreshForwardAttemptResult {
        let executionBudget = ExecutionBudget(
            requestTimeout: requestTimeout,
            requestTimeoutOverride: requestTimeoutOverride,
            clock: clock
        )
        let debugRequestID = debugState.beginRequest(
            sessionID: sessionID,
            queueKey: refreshRequest.queueKey,
            tabIdentifier: refreshRequest.tabIdentifier,
            filePath: refreshRequest.filePath,
            mode: mode.rawValue
        )
        let baseMetadata: Logger.Metadata = [
            "session": .string(sessionID),
            "mode": .string(mode.rawValue),
            "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
            "queue_key": .string(refreshRequest.queueKey),
        ]

        if executionBudget.isExhausted {
            debugState.updateStep(
                requestID: debugRequestID,
                step: .requestTimeoutExhausted,
                state: .timedOut
            )
            debugState.finishRequest(
                requestID: debugRequestID,
                outcome: .timeout
            )
            return .timeout(responseIDs: requestIDs, isBatch: requestIsBatch)
        }

        do {
            return try await coordinator.withPermit(
                key: refreshRequest.queueKey,
                requestTimeout: executionBudget.waitTimeout()
            ) { permit in
                let queueMetadata: Logger.Metadata = [
                    "pending_for_key": .string("\(permit.pendingForKey)"),
                    "pending_total": .string("\(permit.pendingTotal)"),
                ]
                if permit.queuePosition > 0 {
                    logger.debug(
                        "Queued refresh code issues request",
                        metadata: baseMetadata.merging(
                            queueMetadata.merging(
                                ["queued_ahead": .string("\(permit.queuePosition)")],
                                uniquingKeysWith: { _, new in new }
                            ),
                            uniquingKeysWith: { _, new in new }
                        )
                    )
                }
                logger.debug(
                    "Dequeued refresh code issues request",
                    metadata: baseMetadata.merging(
                        queueMetadata,
                        uniquingKeysWith: { _, new in new }
                    )
                )

                debugState.markPermitAcquired(
                    requestID: debugRequestID,
                    queuePosition: permit.queuePosition,
                    pendingForKey: permit.pendingForKey,
                    pendingTotal: permit.pendingTotal
                )
                try Self.throwIfCancelled(
                    debugState: debugState,
                    requestID: debugRequestID
                )

                if executionBudget.isExhausted {
                    debugState.updateStep(
                        requestID: debugRequestID,
                        step: .queueWaitTimedOut,
                        state: .timedOut
                    )
                    debugState.finishRequest(
                        requestID: debugRequestID,
                        outcome: .timeout
                    )
                    return .timeout(responseIDs: requestIDs, isBatch: requestIsBatch)
                }
                debugState.updateStep(
                    requestID: debugRequestID,
                    step: .executionBudgetStarted,
                    metadata: [
                        "execution_timeout_ms": Self.timeoutDescription(
                            executionBudget.remainingTimeout()
                        )
                    ]
                )

                let result: RefreshForwardAttemptResult
                if mode == .proxy,
                    let proxyResponseData = try await runProxyRefresh(
                        refreshRequest: refreshRequest,
                        sessionID: sessionID,
                        requestIDs: requestIDs,
                        requestIsBatch: requestIsBatch,
                        eventLoop: eventLoop,
                        baseMetadata: baseMetadata,
                        executionBudget: executionBudget,
                        debugRequestID: debugRequestID,
                        windowsProvider: windowsProvider,
                        internalUpstreamChooser: internalUpstreamChooser,
                        internalToolCaller: internalToolCaller
                    )
                {
                    debugState.updateStep(
                        requestID: debugRequestID,
                        step: .proxyCompleted
                    )
                    result = .success(proxyResponseData)
                } else {
                    try Self.throwIfCancelled(
                        debugState: debugState,
                        requestID: debugRequestID
                    )
                    result = await runForwardAttempts(
                        bodyData: bodyData,
                        sessionID: sessionID,
                        requestIDs: requestIDs,
                        requestIsBatch: requestIsBatch,
                        eventLoop: eventLoop,
                        baseMetadata: baseMetadata,
                        executionBudget: executionBudget,
                        debugRequestID: debugRequestID,
                        forwarder: forwarder
                    )
                }

                debugState.finishRequest(
                    requestID: debugRequestID,
                    outcome: Self.debugOutcome(for: result)
                )
                return result
            }
        } catch RefreshCodeIssuesCoordinator.AcquireError.queueWaitTimedOut {
            logger.warning(
                "Refresh code issues request timed out while waiting for permit",
                metadata: [
                    "session": .string(sessionID),
                    "mode": .string(mode.rawValue),
                    "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
                    "queue_key": .string(refreshRequest.queueKey),
                ]
            )
            debugState.updateStep(
                requestID: debugRequestID,
                step: .queueWaitTimedOut
            )
            debugState.finishRequest(
                requestID: debugRequestID,
                outcome: .timeout
            )
            return .timeout(responseIDs: requestIDs, isBatch: requestIsBatch)
        } catch is CancellationError {
            logger.debug(
                "Cancelled queued refresh code issues request",
                metadata: [
                    "session": .string(sessionID),
                    "mode": .string(mode.rawValue),
                    "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
                    "queue_key": .string(refreshRequest.queueKey),
                ]
            )
            debugState.updateStep(
                requestID: debugRequestID,
                step: .cancelled,
                state: .cancelled
            )
            debugState.finishRequest(
                requestID: debugRequestID,
                outcome: .cancelled
            )
            return .cancelled(responseIDs: requestIDs, isBatch: requestIsBatch)
        } catch {
            debugState.updateStep(
                requestID: debugRequestID,
                step: .invalidRequest,
                state: .failed
            )
            debugState.finishRequest(
                requestID: debugRequestID,
                outcome: .invalidRequest
            )
            return .invalidRequest
        }
    }

}
