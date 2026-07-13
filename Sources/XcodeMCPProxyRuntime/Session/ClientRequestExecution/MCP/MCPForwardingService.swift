import Foundation
import NIO
import XcodeMCPKit

struct MCPForwardingService: Sendable {
    typealias PreparedRequest = ProxyUpstreamRequestRuntime.PreparedRequest
    typealias StartedRequest = ProxyUpstreamRequestRuntime.StartedRequest

    enum ResponseResolution: Sendable {
        case success(Data)
        case timeout
        case upstreamUnavailable
        case invalidUpstreamResponse
    }

    private let config: ProxyRuntimeConfiguration
    private let sessionManager: any RuntimeMCPForwardingPort
    private let upstreamRuntime: ProxyUpstreamRequestRuntime
    private let toolSurface: ToolSurface

    init(configuration: ProxyRuntimeConfiguration, sessionManager: any RuntimeMCPForwardingPort) {
        self.config = configuration
        self.sessionManager = sessionManager
        self.upstreamRuntime = ProxyUpstreamRequestRuntime(port: sessionManager)
        self.toolSurface = ToolSurface(config: configuration, sessionManager: sessionManager)
    }

    func prepareRequest(
        bodyData: Data,
        parsedRequestJSON: Any,
        sessionID: String,
        operationLeaseOverride: UpstreamOperationLease? = nil,
        admission: RouteForwardingAdmission? = nil
    ) throws -> PreparedRequest? {
        try upstreamRuntime.prepareRequest(
            bodyData: bodyData,
            parsedRequestJSON: parsedRequestJSON,
            sessionID: sessionID,
            operationLeaseOverride: operationLeaseOverride,
            admission: admission
        )
    }

    func startRequest(
        _ prepared: PreparedRequest,
        session: SessionContext,
        on eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount? = nil,
        leaseID: LeaseManager.ID? = nil,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle? = nil,
        onTimeout: (@Sendable () -> Void)? = nil
    ) throws -> StartedRequest {
        let requestTimeout =
            requestTimeoutOverride
            ?? MCP.MethodDispatcher.timeoutForMethod(
                prepared.transform.method,
                defaultSeconds: config.requestTimeout
            )
        return try upstreamRuntime.startRequest(
            prepared,
            router: session.router,
            on: eventLoop,
            requestTimeout: requestTimeout,
            leaseID: leaseID,
            onRegistered: { registration in
                cancellationHandle?.activate(operationLease: registration.operationLease)
                cancellationHandle?.bindRouterPendingToken(registration.routerPendingToken)
            },
            onTimeout: onTimeout
        )
    }

    func resolveResponse(
        _ result: Result<ByteBuffer, Error>,
        started: StartedRequest,
        sessionID: String,
        accountSuccess: Bool = true,
        accountTimeout: Bool = true
    ) -> ResponseResolution {
        switch result {
        case .success(let buffer):
            var buffer = buffer
            guard let data = buffer.readData(length: buffer.readableBytes) else {
                return .invalidUpstreamResponse
            }
            let rewritten = toolSurface.rewriteForwardedResponse(
                method: started.transform.method,
                toolName: started.transform.toolName,
                originalID: started.transform.originalID,
                cachesToolsListResult: started.transform.isCacheableToolsListRequest,
                upstreamIndex: started.upstreamIndex,
                upstreamData: data
            )
            let responseData = rewritten.responseData
            if accountSuccess, toolSurface.shouldNotifyUpstreamSuccess(for: responseData) {
                upstreamRuntime.recordRequestSucceeded(
                    sessionID: sessionID,
                    started: started
                )
            }
            return .success(responseData)

        case .failure(let error):
            let staleUpstreamTopology: Bool
            if case ProxyUpstreamRequestRuntime.Error.staleUpstreamTopology = error {
                staleUpstreamTopology = true
            } else {
                staleUpstreamTopology = false
            }
            upstreamRuntime.recordRequestTimedOut(
                sessionID: sessionID,
                started: started,
                accountTimeout: accountTimeout && staleUpstreamTopology == false
            )
            if staleUpstreamTopology {
                return .upstreamUnavailable
            }
            return .timeout
        }
    }

    func callInternalTool(
        name: String,
        arguments: [String: Any],
        sessionID: String,
        eventLoop: EventLoop,
        cancellationHandle: ClientMCPRequestExecutor.CancellationHandle? = nil,
        upstreamIndexOverride: Int? = nil,
        requestTimeoutOverride: TimeAmount? = nil
    ) async -> RefreshCodeIssues.Workflow.InternalToolResult {
        guard let argumentValue = JSONValue(any: arguments) else {
            return .unavailable
        }
        let requestObject = JSONRPC.Wire.requestObject(
            id: "__internal-\(UUID().uuidString)",
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": argumentValue,
            ])
        )
        let internalRequestID = JSONRPC.ID(any: requestObject["id"]!)!

        guard let bodyData = try? JSONRPC.Wire.data(from: requestObject)
        else {
            return .unavailable
        }
        guard let parsedRequestJSONValue = JSONValue(any: requestObject) else {
            return .unavailable
        }
        if upstreamIndexOverride == nil,
            name == "XcodeListWindows"
        {
            do {
                let result = try await sessionManager.liveXcodeListWindowsResult(
                    route: .anyHealthy,
                    requestTimeoutOverride: requestTimeoutOverride
                )
                guard let resultObject = result.foundationObject as? [String: Any] else {
                    return .unavailable
                }
                if let isError = resultObject["isError"] as? Bool,
                    isError
                {
                    return .unavailable
                }
                return .success(resultObject)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .unavailable
            }
        }

        let preferredUpstreamIndices: [Int]?
        let admission: RouteForwardingAdmission?
        if let upstreamIndexOverride {
            preferredUpstreamIndices = [upstreamIndexOverride]
            admission = nil
        } else {
            switch await sessionManager.toolRoutingDecision(
                for: requestObject,
                requestTimeoutOverride: requestTimeoutOverride
            ) {
            case .forward(let resolvedUpstreamIndex):
                preferredUpstreamIndices = resolvedUpstreamIndex.map { [$0] }
                admission = nil
            case .forwardAny(let resolvedUpstreamIndices):
                preferredUpstreamIndices = resolvedUpstreamIndices
                admission = nil
            case .forwardAdmitted(let resolvedUpstreamIndices, let resolvedAdmission):
                preferredUpstreamIndices = resolvedUpstreamIndices
                admission = resolvedAdmission
            case .localXcodeListWindows:
                return .unavailable
            case .reject:
                return .unavailable
            }
        }

        let descriptor = SessionRequestPipeline.Descriptor(
            sessionID: sessionID,
            label: "tools/call:\(name)",
            expectsResponse: true,
            isTopLevelClientRequest: false
        )
        let leaseID = sessionManager.createRequestLease(descriptor: descriptor)
        let internalCancellationHandle = ClientMCPRequestExecutor.CancellationHandle(
            leaseID: leaseID,
            sessionID: sessionID,
            requestIDKeys: []
        )
        let session = sessionManager.session(id: sessionID)

        let resolution: ResponseResolution
        do {
            resolution = try await sessionManager.enqueueOnUpstreamSlot(
                leaseID: leaseID,
                descriptor: descriptor,
                on: eventLoop,
                preferredUpstreamIndices: preferredUpstreamIndices
            ) { selectedOperationLease in
                internalCancellationHandle.activate(operationLease: selectedOperationLease)
                let parsedRequestJSON = parsedRequestJSONValue.foundationObject
                let prepared: PreparedRequest
                do {
                    guard let candidate = try prepareRequest(
                        bodyData: bodyData,
                        parsedRequestJSON: parsedRequestJSON,
                        sessionID: sessionID,
                        operationLeaseOverride: selectedOperationLease,
                        admission: admission
                    ) else {
                        return eventLoop.makeSucceededFuture(.invalidUpstreamResponse)
                    }
                    prepared = candidate
                    internalCancellationHandle.bindRequestIDKeys(
                        prepared.transform.responseID.map { [$0.key] } ?? []
                    )
                    if let cancellationHandle,
                        cancellationHandle.bindChildHandle(internalCancellationHandle) == false
                    {
                        internalCancellationHandle.cancel(using: sessionManager)
                        return eventLoop.makeFailedFuture(CancellationError())
                    }
                } catch ProxyUpstreamRequestRuntime.Error.staleUpstreamTopology {
                    return eventLoop.makeSucceededFuture(.upstreamUnavailable)
                } catch {
                    return eventLoop.makeSucceededFuture(.invalidUpstreamResponse)
                }

                let started: StartedRequest
                do {
                    started = try startRequest(
                        prepared,
                        session: session,
                        on: eventLoop,
                        requestTimeoutOverride: requestTimeoutOverride,
                        leaseID: leaseID,
                        cancellationHandle: internalCancellationHandle,
                        onTimeout: {
                            self.sessionManager.handleRequestLeaseTimeout(
                                leaseID,
                                sessionID: sessionID,
                                requestIDKeys: prepared.transform.responseID.map { [$0.key] } ?? [],
                                operationLease: prepared.operationLease
                            )
                        }
                    )
                } catch ProxyUpstreamRequestRuntime.Error.staleUpstreamTopology {
                    return eventLoop.makeSucceededFuture(.upstreamUnavailable)
                } catch {
                    return eventLoop.makeSucceededFuture(.invalidUpstreamResponse)
                }

                return started.future.map { buffer in
                    self.resolveResponse(
                        .success(buffer),
                        started: started,
                        sessionID: sessionID
                    )
                }.flatMapErrorThrowing { error in
                    if error is CancellationError {
                        throw error
                    }
                    return self.resolveResponse(
                        .failure(error),
                        started: started,
                        sessionID: sessionID
                    )
                }
            }.get()
        } catch is CancellationError {
            internalCancellationHandle.cancel(using: sessionManager)
            return .cancelled
        } catch {
            internalCancellationHandle.markCompleted()
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .upstreamUnavailable
            )
            return .unavailable
        }

        switch resolution {
        case .success(let responseData):
            internalCancellationHandle.markCompleted()
            sessionManager.completeRequestLease(leaseID)
            guard let object = ToolSurface.responseObject(
                from: responseData,
                matching: internalRequestID.key
            ),
                let result = object["result"] as? [String: Any]
            else {
                return .unavailable
            }
            if let isError = result["isError"] as? Bool, isError {
                return .unavailable
            }
            return .success(result)
        case .timeout:
            internalCancellationHandle.markCompleted()
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .timedOut,
                reason: .timedOut
            )
            return .timeout
        case .upstreamUnavailable:
            internalCancellationHandle.markCompleted()
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .upstreamUnavailable
            )
            return .unavailable
        case .invalidUpstreamResponse:
            internalCancellationHandle.markCompleted()
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .invalidUpstreamResponse
            )
            return .unavailable
        }
    }

}
