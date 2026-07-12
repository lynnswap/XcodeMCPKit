import Foundation
import Logging
import NIO
import XcodeMCPKit

enum RefreshCodeIssues {}

extension RefreshCodeIssues {
    struct Request: Sendable {
        static let toolName = "XcodeRefreshCodeIssuesInFile"
        static let globalQueueKey = "__global__"

        let tabIdentifier: String?
        let filePath: String?

        init(tabIdentifier: String?, filePath: String?) {
            self.tabIdentifier = tabIdentifier
            self.filePath = filePath
        }

        /// The one place that recognizes this feature's tools/call shape.
        init?(requestObject object: [String: Any]) {
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

        static func singleRequestObject(from requestJSON: Any) -> [String: Any]? {
            requestJSON as? [String: Any]
        }

        var queueKey: String {
            guard let tabIdentifier, tabIdentifier.isEmpty == false else {
                return Self.globalQueueKey
            }
            return tabIdentifier
        }
    }
}

extension RefreshCodeIssues {
    struct Workflow {
        enum ForwardAttemptResult: Sendable {
            case success(Data)
            case timeout(responseID: JSONRPC.ID)
            case upstreamUnavailable(responseID: JSONRPC.ID)
            case cancelled(responseID: JSONRPC.ID)
            case invalidRequest
            case invalidUpstreamResponse
        }

        enum InternalToolResult {
            case success([String: Any])
            case timeout
            case cancelled
            case unavailable
        }

        typealias WindowsProvider =
            @Sendable (
                _ sessionID: String,
                _ eventLoop: EventLoop,
                _ upstreamIndexOverride: Int?,
                _ requestTimeoutOverride: TimeAmount?
            ) async throws -> [XcodeWindowInfo]?
        typealias InternalUpstreamChooser = @Sendable (_ sessionID: String) async -> Int?
        typealias InternalToolCaller =
            @Sendable (
                _ name: String,
                _ arguments: [String: Any],
                _ sessionID: String,
                _ eventLoop: EventLoop,
                _ upstreamIndexOverride: Int?,
                _ requestTimeoutOverride: TimeAmount?
            ) async -> RefreshCodeIssues.Workflow.InternalToolResult
        typealias Forwarder =
            @Sendable (
                _ bodyData: Data,
                _ sessionID: String,
                _ responseID: JSONRPC.ID,
                _ shouldRequeueLeaseOnRetryableFailure: @Sendable () -> Bool,
                _ eventLoop: EventLoop,
                _ requestTimeoutOverride: TimeAmount?
            ) async -> RefreshCodeIssues.Workflow.ForwardAttemptResult

        static let retryDelaysNanos: [UInt64] = [
            200_000_000,
            500_000_000,
        ]
        static let minimumUpstreamFallbackBudgetSeconds: TimeInterval = 0.05

        struct ExecutionBudget: Sendable {
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

        let mode: ProxyConfig.RefreshCodeIssuesMode
        let requestTimeout: TimeInterval
        let coordinator: RefreshCodeIssues.Coordinator
        let targetResolver: RefreshCodeIssues.TargetResolver
        let debugState: RefreshCodeIssues.DebugState
        let windowLookupTimeoutSeconds: TimeInterval
        let navigatorIssuesTimeoutSeconds: TimeInterval
        let clock: ClockClient
        let logger: Logger

        init(
            mode: ProxyConfig.RefreshCodeIssuesMode,
            requestTimeout: TimeInterval,
            coordinator: RefreshCodeIssues.Coordinator,
            targetResolver: RefreshCodeIssues.TargetResolver,
            debugState: RefreshCodeIssues.DebugState,
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

        func run(
            refreshRequest: RefreshCodeIssues.Request,
            bodyData: Data,
            sessionID: String,
            responseID: JSONRPC.ID,
            requestTimeoutOverride: TimeAmount? = nil,
            eventLoop: EventLoop,
            windowsProvider: @escaping WindowsProvider,
            internalUpstreamChooser: @escaping InternalUpstreamChooser,
            internalToolCaller: @escaping InternalToolCaller,
            forwarder: @escaping Forwarder
        ) async -> RefreshCodeIssues.Workflow.ForwardAttemptResult {
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
                return .timeout(responseID: responseID)
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
                        return .timeout(responseID: responseID)
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

                    let result: RefreshCodeIssues.Workflow.ForwardAttemptResult
                    if mode == .proxy,
                        let proxyResponseData = try await runProxyRefresh(
                            refreshRequest: refreshRequest,
                            sessionID: sessionID,
                            responseID: responseID,
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
                            responseID: responseID,
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
            } catch RefreshCodeIssues.Coordinator.AcquireError.queueWaitTimedOut {
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
                return .timeout(responseID: responseID)
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
                return .cancelled(responseID: responseID)
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
}
